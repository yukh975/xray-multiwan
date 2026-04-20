#!/bin/bash
#
# migrate.sh — migrate the multi-WAN gateway to a new address plan.
#
# Assumes the parent interface (global) on the PVE host has already been
# moved to the new subnet and the container rebooted with the new IP/mask.
#
# What it does:
#   1. Verifies global is on the new subnet.
#   2. Backs up affected configs.
#   3. Updates the "listen" IP in xray configs (/etc/xray/<code>.json).
#   4. Updates proxy: socks5://... in tun2socks configs (/etc/tun2socks/<code>.yaml).
#   5. Rewrites COUNTRIES and NETMASK_BITS in config.sh.
#   6. Strips stale IPs from macvlan interfaces.
#   7. Restarts xray@<code> with the new configs.
#   8. Runs install.sh to regenerate macvlan/routing/iptables.
#   9. Runs diag.sh.
#
# Usage:
#   bash migrate.sh
#   bash migrate.sh --dry-run
#
# New address plan is configured in the NEW_* block below.
#

set -uo pipefail

# ---- NEW ADDRESS PLAN ----

NEW_PARENT_IP="192.168.1.20"
NEW_NETMASK_BITS="28"

NEW_COUNTRIES=(
    "fr:192.168.1.21:100"
    "se:192.168.1.22:101"
    "fi:192.168.1.23:102"
)

PARENT_IF="${PARENT_IF:-global}"

# File paths
INSTALL_SH="${INSTALL_SH:-/root/files/install.sh}"
DIAG_SH="${DIAG_SH:-/root/files/diag.sh}"
CONFIG_SH="${CONFIG_SH:-/root/files/config.sh}"

XRAY_CONFDIR="/etc/xray"
TUN2SOCKS_CONFDIR="/etc/tun2socks"

# ---- end configuration ----

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
Параметры новой адресации задаются в блоке NEW_* в начале скрипта.

Опции:
  -n, --dry-run   Показать, что будет сделано, без изменений.
  -h, --help      Эта справка.

Переменные окружения:
  PARENT_IF       Родительский интерфейс (default: global).
  INSTALL_SH      Путь к install.sh (default: /root/files/install.sh).
  DIAG_SH         Путь к diag.sh (default: /root/files/diag.sh).
  CONFIG_SH       Путь к config.sh (default: /root/files/config.sh).
HELP
            else
                cat <<'HELP'
Usage: migrate.sh [options]

Migrates the multi-WAN gateway to a new address plan.
New plan is configured in the NEW_* block at the top of the script.

Options:
  -n, --dry-run   Print what would be done, without applying changes.
  -h, --help      This help.

Environment variables:
  PARENT_IF       Parent interface (default: global).
  INSTALL_SH      Path to install.sh (default: /root/files/install.sh).
  DIAG_SH         Path to diag.sh (default: /root/files/diag.sh).
  CONFIG_SH       Path to config.sh (default: /root/files/config.sh).
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
    [ -f "$CONFIG_SH" ]  || die "$(t "$CONFIG_SH not found (set via CONFIG_SH=...)" "не найден $CONFIG_SH (установи через CONFIG_SH=...)")"
}

check_parent_ip() {
    log "$(t "Checking address on $PARENT_IF" "Проверяю адрес $PARENT_IF")"
    local current
    current=$(ip -4 -o addr show dev "$PARENT_IF" 2>/dev/null | awk '{print $4}' | head -n1)

    if [ -z "$current" ]; then
        die "$(t "$PARENT_IF has no IPv4 address. Make sure PVE reconfigured the container and it was rebooted." "$PARENT_IF не имеет IPv4-адреса. Убедись, что PVE сменил адресацию и контейнер перезагружен.")"
    fi

    local expected="${NEW_PARENT_IP}/${NEW_NETMASK_BITS}"
    if [ "$current" = "$expected" ]; then
        info "$PARENT_IF = $current ✓"
    else
        echo
        echo "$(t "Address $PARENT_IF = $current, expected $expected." "Адрес $PARENT_IF = $current, ожидается $expected.")"
        echo "$(t "First update the container config on the PVE host:" "Сначала обнови конфиг контейнера на хосте PVE:")"
        echo "  pct set <VMID> -net0 name=global,bridge=<...>,ip=$expected,gw=<$(t "new-gw" "новый-gw")>"
        echo "$(t "Then reboot the container and run migrate.sh again." "Потом перезагрузи контейнер и запусти migrate.sh снова.")"
        exit 1
    fi
}

# ---- operations ----

make_backup() {
    log "$(t "Backing up configs to $BACKUP_DIR" "Бэкап конфигов в $BACKUP_DIR")"
    run mkdir -p "$BACKUP_DIR"

    for item in "${NEW_COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local xray_cfg="${XRAY_CONFDIR}/${code}.json"
        local tun_cfg="${TUN2SOCKS_CONFDIR}/${code}.yaml"
        [ -f "$xray_cfg" ] && run cp -a "$xray_cfg" "$BACKUP_DIR/"
        [ -f "$tun_cfg" ]  && run cp -a "$tun_cfg"  "$BACKUP_DIR/"
    done

    [ -f "$INSTALL_SH" ] && run cp -a "$INSTALL_SH" "$BACKUP_DIR/install.sh.bak"
    [ -f "$DIAG_SH" ]    && run cp -a "$DIAG_SH"    "$BACKUP_DIR/diag.sh.bak"
    [ -f "$CONFIG_SH" ]  && run cp -a "$CONFIG_SH"  "$BACKUP_DIR/config.sh.bak"
    info "$(t "Backup: $BACKUP_DIR" "Бэкап: $BACKUP_DIR")"
}

get_new_ip_for_code() {
    local needed_code="$1"
    for item in "${NEW_COUNTRIES[@]}"; do
        local code="${item%%:*}"
        if [ "$code" = "$needed_code" ]; then
            local rest="${item#*:}"
            echo "${rest%%:*}"
            return 0
        fi
    done
    return 1
}

update_xray_configs() {
    log "$(t "Updating IPs in xray configs" "Обновляю IP в xray-конфигах")"

    for item in "${NEW_COUNTRIES[@]}"; do
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

    for item in "${NEW_COUNTRIES[@]}"; do
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

update_config_sh() {
    log "$(t "Updating NETMASK_BITS and COUNTRIES in $CONFIG_SH" "Обновляю NETMASK_BITS и COUNTRIES в $CONFIG_SH")"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "$(t "would set NETMASK_BITS=$NEW_NETMASK_BITS in $CONFIG_SH" "в $CONFIG_SH был бы установлен NETMASK_BITS=$NEW_NETMASK_BITS")"
        for item in "${NEW_COUNTRIES[@]}"; do
            info "  $item"
        done
        return 0
    fi

    # Strip old COUNTRIES block, replace NETMASK_BITS.
    local tmp
    tmp=$(mktemp)
    awk -v new_mask="$NEW_NETMASK_BITS" '
        BEGIN { in_countries = 0 }
        /^NETMASK_BITS=/ {
            print "NETMASK_BITS=\"" new_mask "\""
            next
        }
        /^COUNTRIES=\(/ {
            in_countries = 1
            print "COUNTRIES=("
            next
        }
        in_countries && /^\)/ {
            in_countries = 0
            print "### MIGRATE_COUNTRIES_END ###"
            print ")"
            next
        }
        in_countries { next }
        { print }
    ' "$CONFIG_SH" > "$tmp"

    # Insert fresh COUNTRIES block.
    local countries_block=""
    for item in "${NEW_COUNTRIES[@]}"; do
        countries_block+="    \"${item}\""$'\n'
    done

    awk -v block="$countries_block" '
        /^### MIGRATE_COUNTRIES_END ###$/ {
            printf "%s", block
            next
        }
        { print }
    ' "$tmp" > "${tmp}.2"

    mv "${tmp}.2" "$CONFIG_SH"
    rm -f "$tmp"
}

cleanup_old_ips() {
    log "$(t "Stripping old IPs from macvlan interfaces" "Снимаю старые IP с macvlan-интерфейсов")"

    for item in "${NEW_COUNTRIES[@]}"; do
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
    for item in "${NEW_COUNTRIES[@]}"; do
        local code="${item%%:*}"
        run systemctl restart "xray@${code}.service"
    done
}

run_install() {
    log "$(t "Running install.sh" "Запускаю install.sh")"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "+ bash $INSTALL_SH"
        return 0
    fi
    bash "$INSTALL_SH"
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
    update_config_sh
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
