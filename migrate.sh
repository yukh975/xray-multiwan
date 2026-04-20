#!/bin/bash
#
# migrate.sh — migrate the multi-WAN gateway to a new address plan.
#
# The new plan is taken from config.sh (PARENT_IF, NETMASK_BITS, COUNTRIES).
# Edit config.sh *before* running this script — migrate.sh itself has no
# tunables, it reads everything from the config.
#
# Assumes the parent interface IP on the PVE host has already been moved
# to the new subnet and the container rebooted with the new IP/mask.
#
# What it does:
#   1. Verifies PARENT_IF has an IPv4 address.
#   2. Backs up affected configs (xray, tun2socks, config.sh).
#   3. Updates the "listen" IP in xray configs (/etc/xray/<code>.json),
#      using the old IP currently written in the file as the "from" value.
#   4. Updates proxy: socks5://... in tun2socks configs similarly.
#   5. Strips stale IPs from macvlan interfaces.
#   6. Restarts xray@<code> with the new configs.
#   7. Runs install.sh --install to regenerate macvlan/routing/iptables.
#   8. Runs diag.sh.
#
# Usage:
#   bash migrate.sh
#   bash migrate.sh --dry-run
#

set -uo pipefail

# ---- unified config ----
# Target values (PARENT_IF, NETMASK_BITS, COUNTRIES) come from config.sh,
# the same file install.sh and diag.sh read. Edit config.sh only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SH="${CONFIG_SH:-$SCRIPT_DIR/config.sh}"
if [ ! -f "$CONFIG_SH" ]; then
    echo "ERROR: config file not found: $CONFIG_SH" >&2
    echo "       copy config.sh.example to config.sh and edit it" >&2
    exit 1
fi
# shellcheck source=config.sh disable=SC1091
. "$CONFIG_SH"

INSTALL_SH="${INSTALL_SH:-$SCRIPT_DIR/install.sh}"
DIAG_SH="${DIAG_SH:-$SCRIPT_DIR/diag.sh}"

XRAY_CONFDIR="${XRAY_CONFDIR:-/etc/xray}"
TUN2SOCKS_CONFDIR="${TUN2SOCKS_CONFDIR:-/etc/tun2socks}"

# ---- i18n ----
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
    ru*|RU*) LANG_CODE=ru ;;
    *)       LANG_CODE=en ;;
esac

t() {
    if [ "$LANG_CODE" = ru ]; then echo "$2"; else echo "$1"; fi
}

DRY_RUN=0
BACKUP_DIR="/root/migrate-backup-$(date +%Y%m%d-%H%M%S)"

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            if [ "$LANG_CODE" = ru ]; then
                cat <<'HELP'
Использование: migrate.sh [опции]

Переводит multi-WAN gateway на новую адресацию.
Целевые значения (PARENT_IF, NETMASK_BITS, COUNTRIES) берутся из config.sh
— отредактируй config.sh перед запуском. В самом скрипте ничего править
не нужно.

Опции:
  -n, --dry-run   Показать, что будет сделано, без изменений.
  -h, --help      Эта справка.

Переменные окружения (необязательно):
  INSTALL_SH      Путь к install.sh (default: рядом со скриптом).
  DIAG_SH         Путь к diag.sh (default: рядом со скриптом).
  CONFIG_SH       Путь к config.sh (default: рядом со скриптом).
HELP
            else
                cat <<'HELP'
Usage: migrate.sh [options]

Migrates the multi-WAN gateway to a new address plan.
Target values (PARENT_IF, NETMASK_BITS, COUNTRIES) are read from config.sh
— edit config.sh before running. Nothing in this script needs editing.

Options:
  -n, --dry-run   Print what would be done, without applying changes.
  -h, --help      This help.

Environment variables (optional):
  INSTALL_SH      Path to install.sh (default: next to this script).
  DIAG_SH         Path to diag.sh (default: next to this script).
  CONFIG_SH       Path to config.sh (default: next to this script).
HELP
            fi
            exit 0
            ;;
        *) echo "$(t "Unknown argument: $1" "Неизвестный аргумент: $1")" >&2; exit 1 ;;
    esac
done

die()  { echo "ERROR: $*" >&2; exit 1; }
log()  { echo "[$(date +%H:%M:%S)] $*"; }
info() { echo "  $*"; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  + $*"
        return 0
    else
        "$@"
    fi
}

# ---- checks ----

require_root() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ "$(id -u)" -eq 0 ] || die "$(t "run as root" "запускать от root")"
}

require_files() {
    [ -f "$INSTALL_SH" ] || die "$(t "$INSTALL_SH not found (set via INSTALL_SH=...)" "не найден $INSTALL_SH (установи через INSTALL_SH=...)")"
    [ -f "$DIAG_SH" ]    || die "$(t "$DIAG_SH not found (set via DIAG_SH=...)" "не найден $DIAG_SH (установи через DIAG_SH=...)")"
}

check_parent_ip() {
    log "$(t "Checking address on $PARENT_IF" "Проверяю адрес $PARENT_IF")"
    local current
    current=$(ip -4 -o addr show dev "$PARENT_IF" 2>/dev/null | awk '{print $4}' | head -n1)

    if [ -z "$current" ]; then
        die "$(t "$PARENT_IF has no IPv4 address. Make sure PVE reconfigured the container and it was rebooted." "$PARENT_IF не имеет IPv4-адреса. Убедись, что PVE сменил адресацию и контейнер перезагружен.")"
    fi

    info "$PARENT_IF = $current"

    # Sanity check: the parent IP prefix should match one of the new COUNTRIES IPs'
    # first three octets (same subnet, coarse /24 check — works for /24 and /28 alike).
    local parent_ip="${current%%/*}"
    local parent_prefix="${parent_ip%.*}"
    local first_item="${COUNTRIES[0]}"
    local first_rest="${first_item#*:}"
    local first_ip="${first_rest%%:*}"
    local target_prefix="${first_ip%.*}"

    if [ "$parent_prefix" != "$target_prefix" ]; then
        echo
        echo "$(t "Parent IP $parent_ip is not in the same /24 as the new COUNTRIES IPs (expected prefix $target_prefix.*)." "IP родителя $parent_ip не в одной /24 с новыми COUNTRIES (ожидается префикс $target_prefix.*).")"
        echo "$(t "Reconfigure the container on the PVE host and reboot it:" "Обнови конфиг контейнера на хосте PVE и перезагрузи его:")"
        echo "  pct set <VMID> -net0 name=eth0,bridge=<...>,ip=<$(t "new-ip" "новый-IP")>/${NETMASK_BITS},gw=<$(t "new-gw" "новый-gw")>"
        exit 1
    fi
}

# ---- operations ----

make_backup() {
    log "$(t "Backing up configs to $BACKUP_DIR" "Бэкап конфигов в $BACKUP_DIR")"
    run mkdir -p "$BACKUP_DIR"

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local xray_cfg="${XRAY_CONFDIR}/${code}.json"
        local tun_cfg="${TUN2SOCKS_CONFDIR}/${code}.yaml"
        [ -f "$xray_cfg" ] && run cp -a "$xray_cfg" "$BACKUP_DIR/"
        [ -f "$tun_cfg" ]  && run cp -a "$tun_cfg"  "$BACKUP_DIR/"
    done

    [ -f "$CONFIG_SH" ]  && run cp -a "$CONFIG_SH"  "$BACKUP_DIR/config.sh.bak"
    info "$(t "Backup: $BACKUP_DIR" "Бэкап: $BACKUP_DIR")"
}

update_xray_configs() {
    log "$(t "Updating IPs in xray configs" "Обновляю IP в xray-конфигах")"

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local new_ip="${rest%%:*}"
        local cfg="${XRAY_CONFDIR}/${code}.json"

        if [ ! -f "$cfg" ]; then
            info "$cfg: $(t "file missing, skipping" "нет файла, пропуск")"
            continue
        fi

        local old_ip
        old_ip=$(grep -oE '"listen"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$cfg" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)

        if [ -z "$old_ip" ]; then
            info "$cfg: $(t "no listen field, skipping" "не найдено поле listen, пропуск")"
            continue
        fi

        if [ "$old_ip" = "$new_ip" ]; then
            info "$cfg: $(t "already" "уже") $new_ip"
            continue
        fi

        info "$cfg: $old_ip → $new_ip"
        if [ "$DRY_RUN" -eq 0 ]; then
            sed -i -E "s/(\"listen\"[[:space:]]*:[[:space:]]*\")${old_ip//./\\.}(\")/\1${new_ip}\2/" "$cfg"
        fi
    done
}

update_tun2socks_configs() {
    log "$(t "Updating IPs in tun2socks configs" "Обновляю IP в tun2socks-конфигах")"

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local new_ip="${rest%%:*}"
        local cfg="${TUN2SOCKS_CONFDIR}/${code}.yaml"

        if [ ! -f "$cfg" ]; then
            info "$cfg: $(t "file missing, skipping" "нет файла, пропуск")"
            continue
        fi

        local old_ip
        old_ip=$(grep -oE 'socks5://[0-9.]+:' "$cfg" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)

        if [ -z "$old_ip" ]; then
            info "$cfg: $(t "no socks5://... found, skipping" "не найдено socks5://..., пропуск")"
            continue
        fi

        if [ "$old_ip" = "$new_ip" ]; then
            info "$cfg: $(t "already" "уже") $new_ip"
            continue
        fi

        info "$cfg: $old_ip → $new_ip"
        if [ "$DRY_RUN" -eq 0 ]; then
            sed -i -E "s|socks5://${old_ip//./\\.}:|socks5://${new_ip}:|" "$cfg"
        fi
    done
}

cleanup_old_ips() {
    log "$(t "Stripping old IPs from macvlan interfaces" "Снимаю старые IP с macvlan-интерфейсов")"

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local want_ip="${rest%%:*}"
        local iface="xray-${code}"

        if ! ip link show "$iface" >/dev/null 2>&1; then
            info "$iface: $(t "no such interface, skipping" "нет такого интерфейса, пропуск")"
            continue
        fi

        ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | while read -r addr; do
            local addr_ip="${addr%%/*}"
            if [ "$addr_ip" != "$want_ip" ]; then
                info "$iface: $(t "removing" "удаляю") $addr"
                run ip addr del "$addr" dev "$iface"
            fi
        done
    done
}

restart_xray() {
    log "$(t "Restarting xray@* with new configs" "Перезапускаю xray@* с новыми конфигами")"
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        run systemctl restart "xray@${code}.service"
    done
}

run_install() {
    log "$(t "Running install.sh --install" "Запускаю install.sh --install")"
    if [ "$DRY_RUN" -eq 1 ]; then
        bash "$INSTALL_SH" --install --dry-run
        return 0
    fi
    bash "$INSTALL_SH" --install
}

run_diag() {
    log "$(t "Running diag.sh" "Запускаю diag.sh")"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "+ bash $DIAG_SH"
        return 0
    fi
    bash "$DIAG_SH" || true
}

# ---- main ----

main() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "$(t "===== DRY RUN: no changes will be applied =====" "===== DRY RUN: изменений не будет =====")"
        echo
    fi

    require_root
    require_files
    check_parent_ip

    make_backup
    update_xray_configs
    update_tun2socks_configs
    cleanup_old_ips
    restart_xray
    run_install

    echo
    run_diag

    echo
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$(t "Dry-run complete. Run without --dry-run to apply." "Dry-run завершён. Запусти без --dry-run для применения.")"
    else
        log "$(t "Migration complete. Backups: $BACKUP_DIR" "Миграция завершена. Бэкапы: $BACKUP_DIR")"
    fi
}

main
