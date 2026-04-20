#!/bin/bash
#
# migrate.sh — перевод multi-country gateway на новую адресацию.
#
# Предполагается, что на хосте PVE уже сменены адреса родительского
# интерфейса (global) и контейнер перезагружен с новым IP/маской.
#
# Что делает скрипт:
#   1. Проверяет, что global действительно в новой подсети.
#   2. Делает бэкап затрагиваемых конфигов.
#   3. Меняет IP в xray-конфигах (/etc/xray/<код>.json) — поле "listen".
#   4. Меняет IP в tun2socks-конфигах (/etc/tun2socks/<код>.yaml) — строка proxy: socks5://...
#   5. Обновляет COUNTRIES и NETMASK_BITS в install.sh.
#   6. Снимает старые IP с macvlan-интерфейсов (если остались).
#   7. Перезапускает xray@<код> с новыми конфигами.
#   8. Запускает install.sh, который перегенерирует macvlan/routing/iptables под новые IP.
#   9. Прогоняет diag.sh.
#
# Использование:
#   bash migrate.sh
#   bash migrate.sh --dry-run
#
# Параметры миграции задаются в блоке NEW_* ниже.
#

set -uo pipefail

# ---- НОВАЯ АДРЕСАЦИЯ ----

NEW_PARENT_IP="172.31.254.20"
NEW_NETMASK_BITS="28"

NEW_COUNTRIES=(
    "fr:172.31.254.21:100"
    "se:172.31.254.22:101"
    "fi:172.31.254.23:102"
)

PARENT_IF="${PARENT_IF:-global}"

# Пути к файлам
INSTALL_SH="${INSTALL_SH:-/root/files/install.sh}"
DIAG_SH="${DIAG_SH:-/root/files/diag.sh}"

XRAY_CONFDIR="/etc/xray"
TUN2SOCKS_CONFDIR="/etc/tun2socks"

# ---- конец конфигурации ----

DRY_RUN=0
BACKUP_DIR="/root/migrate-backup-$(date +%Y%m%d-%H%M%S)"

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            cat <<'HELP'
Usage: migrate.sh [options]

Переводит multi-country gateway на новую адресацию.
Параметры новой адресации задаются в блоке NEW_* в начале скрипта.

Options:
  -n, --dry-run   Показать, что будет сделано, без изменений.
  -h, --help      Эта справка.

Переменные окружения:
  PARENT_IF       Родительский интерфейс (default: global).
  INSTALL_SH      Путь к install.sh (default: /root/files/install.sh).
  DIAG_SH         Путь к diag.sh (default: /root/files/diag.sh).
HELP
            exit 0
            ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
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

# ---- проверки ----

require_root() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ "$(id -u)" -eq 0 ] || die "Запускать от root"
}

require_files() {
    [ -f "$INSTALL_SH" ] || die "Не найден $INSTALL_SH (установи через INSTALL_SH=...)"
    [ -f "$DIAG_SH" ]    || die "Не найден $DIAG_SH (установи через DIAG_SH=...)"
}

check_parent_ip() {
    log "Проверяю адрес $PARENT_IF"
    local current
    current=$(ip -4 -o addr show dev "$PARENT_IF" 2>/dev/null | awk '{print $4}' | head -n1)

    if [ -z "$current" ]; then
        die "$PARENT_IF не имеет IPv4-адреса. Убедись, что PVE сменил адресацию и контейнер перезагружен."
    fi

    local expected="${NEW_PARENT_IP}/${NEW_NETMASK_BITS}"
    if [ "$current" = "$expected" ]; then
        info "$PARENT_IF = $current ✓"
    else
        echo
        echo "Адрес $PARENT_IF = $current, ожидается $expected."
        echo "Сначала обнови конфиг контейнера на хосте PVE:"
        echo "  pct set <VMID> -net0 name=global,bridge=<...>,ip=$expected,gw=<новый-gw>"
        echo "Потом перезагрузи контейнер и запусти migrate.sh снова."
        exit 1
    fi
}

# ---- операции ----

make_backup() {
    log "Бэкап конфигов в $BACKUP_DIR"
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
    info "Бэкап: $BACKUP_DIR"
}

# Парсит элемент NEW_COUNTRIES "код:IP:mark" и извлекает IP
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
    log "Обновляю IP в xray-конфигах"

    for item in "${NEW_COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local new_ip="${rest%%:*}"
        local cfg="${XRAY_CONFDIR}/${code}.json"

        if [ ! -f "$cfg" ]; then
            info "$cfg: нет файла, пропуск"
            continue
        fi

        # Находим текущий listen IP
        local old_ip
        old_ip=$(grep -oE '"listen"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$cfg" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)

        if [ -z "$old_ip" ]; then
            info "$cfg: не найдено поле listen, пропуск"
            continue
        fi

        if [ "$old_ip" = "$new_ip" ]; then
            info "$cfg: уже $new_ip"
            continue
        fi

        info "$cfg: $old_ip → $new_ip"
        if [ "$DRY_RUN" -eq 0 ]; then
            sed -i -E "s/(\"listen\"[[:space:]]*:[[:space:]]*\")${old_ip//./\\.}(\")/\1${new_ip}\2/" "$cfg"
        fi
    done
}

update_tun2socks_configs() {
    log "Обновляю IP в tun2socks-конфигах"

    for item in "${NEW_COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local new_ip="${rest%%:*}"
        local cfg="${TUN2SOCKS_CONFDIR}/${code}.yaml"

        if [ ! -f "$cfg" ]; then
            info "$cfg: нет файла, пропуск"
            continue
        fi

        local old_ip
        old_ip=$(grep -oE 'socks5://[0-9.]+:' "$cfg" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)

        if [ -z "$old_ip" ]; then
            info "$cfg: не найдено socks5://..., пропуск"
            continue
        fi

        if [ "$old_ip" = "$new_ip" ]; then
            info "$cfg: уже $new_ip"
            continue
        fi

        info "$cfg: $old_ip → $new_ip"
        if [ "$DRY_RUN" -eq 0 ]; then
            sed -i -E "s|socks5://${old_ip//./\\.}:|socks5://${new_ip}:|" "$cfg"
        fi
    done
}

update_install_sh() {
    log "Обновляю COUNTRIES и NETMASK_BITS в $INSTALL_SH"
    _update_sh_config "$INSTALL_SH"
}

update_diag_sh() {
    log "Обновляю COUNTRIES в $DIAG_SH"
    _update_sh_config "$DIAG_SH"
}

# Внутренняя функция: обновляет блок COUNTRIES и NETMASK_BITS
# в install.sh / diag.sh / любом другом скрипте с этой структурой.
_update_sh_config() {
    local target="$1"

    if [ ! -f "$target" ]; then
        info "$target: нет файла, пропуск"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "в $target был бы установлен NETMASK_BITS=$NEW_NETMASK_BITS"
        for item in "${NEW_COUNTRIES[@]}"; do
            info "  $item"
        done
        return 0
    fi

    # Удаляем старый блок COUNTRIES и меняем NETMASK_BITS.
    local tmp
    tmp=$(mktemp)
    awk -v new_mask="$NEW_NETMASK_BITS" '
        BEGIN { in_countries = 0 }
        /^NETMASK_BITS=/ {
            print "NETMASK_BITS=\"${NETMASK_BITS:-" new_mask "}\""
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
    ' "$target" > "$tmp"

    # Вставляем актуальный блок COUNTRIES
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

    mv "${tmp}.2" "$target"
    rm -f "$tmp"
}

cleanup_old_ips() {
    log "Снимаю старые IP с macvlan-интерфейсов"

    for item in "${NEW_COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local want_ip="${rest%%:*}"
        local iface="xray-${code}"

        if ! ip link show "$iface" >/dev/null 2>&1; then
            info "$iface: нет такого интерфейса, пропуск"
            continue
        fi

        # Снимаем все IP, кроме нужного
        ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | while read -r addr; do
            local addr_ip="${addr%%/*}"
            if [ "$addr_ip" != "$want_ip" ]; then
                info "$iface: удаляю $addr"
                run ip addr del "$addr" dev "$iface"
            fi
        done
    done
}

restart_xray() {
    log "Перезапускаю xray@* с новыми конфигами"
    for item in "${NEW_COUNTRIES[@]}"; do
        local code="${item%%:*}"
        run systemctl restart "xray@${code}.service"
    done
}

run_install() {
    log "Запускаю install.sh"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "+ bash $INSTALL_SH"
        return 0
    fi
    bash "$INSTALL_SH"
}

run_diag() {
    log "Запускаю diag.sh"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "+ bash $DIAG_SH"
        return 0
    fi
    bash "$DIAG_SH" || true
}

# ---- main ----

main() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "===== DRY RUN: изменений не будет ====="
        echo
    fi

    require_root
    require_files
    check_parent_ip

    make_backup
    update_xray_configs
    update_tun2socks_configs
    update_install_sh
    update_diag_sh
    cleanup_old_ips
    restart_xray
    run_install

    echo
    run_diag

    echo
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Dry-run завершён. Запусти без --dry-run для применения."
    else
        log "Миграция завершена. Бэкапы: $BACKUP_DIR"
    fi
}

main
