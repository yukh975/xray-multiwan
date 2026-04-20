#!/bin/bash
#
# diag.sh — проверка multi-country gateway
#
# Проверяет, что все компоненты схемы настроены и работают:
#   - sysctl (ARP, forward, rp_filter)
#   - таблицы маршрутизации
#   - systemd-юниты (setup-macvlan, setup-routing, xray@*, tun2socks@*)
#   - macvlan-интерфейсы и их IP
#   - tun-интерфейсы
#   - ip rule и таблицы via_*
#   - iptables mangle и NAT
#   - работоспособность туннелей (curl через каждый tun)
#
# Использование:
#   bash diag.sh
#   bash diag.sh --quiet    # только итоговая сводка
#
# Exit code:
#   0 — всё хорошо
#   1 — найдены проблемы
#

set -uo pipefail

# ---- КОНФИГУРАЦИЯ (должна совпадать с install.sh) ----

PARENT_IF="${PARENT_IF:-global}"
NETMASK_BITS="${NETMASK_BITS:-24}"

COUNTRIES=(
    "fr:192.168.0.232:100"
    "se:192.168.0.233:101"
    "fi:192.168.0.234:102"
)

# ---- конец конфигурации ----

QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet) QUIET=1; shift ;;
        -h|--help)
            cat <<'HELP'
Usage: diag.sh [options]

Options:
  -q, --quiet   Показывать только итоговую сводку.
  -h, --help    Эта справка.
HELP
            exit 0
            ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

# ---- цветной вывод ----

if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'
    C_DIM=$'\033[2m'
    C_RST=$'\033[0m'
else
    C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_RST=''
fi

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

ok()   { OK_COUNT=$((OK_COUNT+1));     [ $QUIET -eq 0 ] && printf "  %s✓%s %s\n" "$C_OK"   "$C_RST" "$1"; return 0; }
warn() { WARN_COUNT=$((WARN_COUNT+1));                    printf "  %s!%s %s\n" "$C_WARN" "$C_RST" "$1"; return 0; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1));                    printf "  %s✗%s %s\n" "$C_ERR"  "$C_RST" "$1"; return 0; }

section() {
    [ $QUIET -eq 0 ] && printf "\n%s== %s ==%s\n" "$C_DIM" "$1" "$C_RST"
    return 0
}

# ---- проверки ----

check_sysctl() {
    section "sysctl"

    local v
    for pair in \
        "net.ipv4.ip_forward=1" \
        "net.ipv4.conf.all.rp_filter=0" \
        "net.ipv4.conf.all.arp_ignore=1" \
        "net.ipv4.conf.all.arp_announce=2"; do
        local key="${pair%%=*}"
        local want="${pair##*=}"
        v=$(sysctl -n "$key" 2>/dev/null)
        if [ "$v" = "$want" ]; then
            ok "$key = $v"
        else
            fail "$key = ${v:-<не задан>} (ожидалось $want)"
        fi
    done

    # Проверка persistent-файлов
    for f in /etc/sysctl.d/99-arp.conf /etc/sysctl.d/99-forward.conf; do
        if [ -f "$f" ]; then
            ok "есть $f"
        else
            fail "нет $f — после ребута sysctl не восстановятся"
        fi
    done
}

check_rt_tables() {
    section "таблицы маршрутизации (/etc/iproute2/rt_tables)"

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local tbl="via_${code}"
        if grep -qE "^[[:space:]]*${mark}[[:space:]]+${tbl}\b" /etc/iproute2/rt_tables 2>/dev/null; then
            ok "${mark} ${tbl}"
        else
            fail "нет записи '${mark} ${tbl}' в /etc/iproute2/rt_tables"
        fi
    done
}

check_systemd_units() {
    section "systemd-юниты"

    # Наши собственные юниты
    for unit in setup-macvlan.service setup-routing.service; do
        if [ -f "/etc/systemd/system/$unit" ]; then
            ok "$unit (файл юнита есть)"
        else
            fail "$unit — файла юнита нет в /etc/systemd/system/"
            continue
        fi
        if systemctl is-enabled "$unit" >/dev/null 2>&1; then
            ok "$unit — enabled"
        else
            warn "$unit — не enabled (не стартанёт после ребута)"
        fi
        if systemctl is-active "$unit" >/dev/null 2>&1; then
            ok "$unit — active"
        else
            fail "$unit — неактивен"
        fi
    done

    # Drop-in для tun2socks
    if [ -f /etc/systemd/system/tun2socks@.service.d/link-up.conf ]; then
        ok "drop-in link-up.conf для tun2socks@"
    else
        fail "нет /etc/systemd/system/tun2socks@.service.d/link-up.conf — tun-интерфейсы не поднимутся"
    fi

    # xray и tun2socks по странам
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        for svc in "xray@${code}.service" "tun2socks@${code}.service"; do
            if systemctl is-enabled "$svc" >/dev/null 2>&1; then
                ok "$svc — enabled"
            else
                warn "$svc — не enabled"
            fi
            if systemctl is-active "$svc" >/dev/null 2>&1; then
                ok "$svc — active"
            else
                fail "$svc — неактивен"
            fi
        done
    done
}

check_scripts() {
    section "скрипты"

    for s in /usr/local/sbin/setup-macvlan.sh /usr/local/sbin/setup-routing.sh; do
        if [ -x "$s" ]; then
            ok "$s"
        else
            fail "$s — нет или не исполняемый"
        fi
    done
}

check_interfaces() {
    section "интерфейсы"

    # Родительский интерфейс
    if ip link show "$PARENT_IF" >/dev/null 2>&1; then
        ok "родительский интерфейс $PARENT_IF существует"
    else
        fail "родительский интерфейс $PARENT_IF не найден"
        return
    fi

    # macvlan + IP
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local ip="${rest%%:*}"
        local iface="xray-${code}"

        if ! ip link show "$iface" >/dev/null 2>&1; then
            fail "интерфейс $iface отсутствует"
            continue
        fi

        # macvlan поверх нужного родителя
        if ip -d link show "$iface" 2>/dev/null | grep -q "macvlan mode"; then
            ok "$iface — macvlan"
        else
            warn "$iface — не macvlan (или ip -d не поддерживает)"
        fi

        # Свой MAC (отличается от родителя)
        local mac_parent mac_child
        mac_parent=$(ip link show "$PARENT_IF" | awk '/link\/ether/ {print $2}')
        mac_child=$(ip link show "$iface" | awk '/link\/ether/ {print $2}')
        if [ -n "$mac_child" ] && [ "$mac_child" != "$mac_parent" ]; then
            ok "$iface имеет свой MAC ($mac_child)"
        else
            fail "$iface: MAC совпадает с $PARENT_IF — клиент не различит шлюзы"
        fi

        # IP на месте
        if ip -4 -o addr show dev "$iface" | awk '{print $4}' | grep -qx "${ip}/${NETMASK_BITS}"; then
            ok "$iface: IP $ip/${NETMASK_BITS}"
        else
            fail "$iface: нет IP $ip/${NETMASK_BITS}"
        fi

        # Линк UP
        if ip link show "$iface" | grep -q 'state UP\|NO-CARRIER.*UP'; then
            ok "$iface: state UP"
        else
            fail "$iface: линк не UP"
        fi

        # rp_filter=0 на интерфейсе
        local rpf
        rpf=$(sysctl -n "net.ipv4.conf.${iface}.rp_filter" 2>/dev/null)
        if [ "$rpf" = "0" ]; then
            ok "$iface: rp_filter=0"
        else
            warn "$iface: rp_filter=${rpf:-?} (ожидалось 0)"
        fi
    done

    # tun-интерфейсы
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local tun="tun${code}"

        if ! ip link show "$tun" >/dev/null 2>&1; then
            fail "$tun отсутствует"
            continue
        fi

        if ip link show "$tun" | grep -qE 'state (UP|UNKNOWN)'; then
            ok "$tun: поднят"
        else
            fail "$tun: линк не поднят"
        fi

        local rpf
        rpf=$(sysctl -n "net.ipv4.conf.${tun}.rp_filter" 2>/dev/null)
        if [ "$rpf" = "0" ]; then
            ok "$tun: rp_filter=0"
        else
            warn "$tun: rp_filter=${rpf:-?} (ожидалось 0)"
        fi
    done
}

check_ip_rules() {
    section "ip rule (policy routing)"

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local tbl="via_${code}"

        if ip rule show | grep -qE "fwmark 0x$(printf '%x' "$mark")\b.*lookup ${tbl}"; then
            ok "fwmark $mark → $tbl"
        else
            fail "нет правила: fwmark $mark → $tbl"
        fi
    done
}

check_routes() {
    section "таблицы маршрутов (via_*)"

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local tbl="via_${code}"
        local tun="tun${code}"

        local route
        route=$(ip route show table "$tbl" 2>/dev/null | grep '^default')
        if [ -n "$route" ]; then
            if echo "$route" | grep -q "dev $tun"; then
                ok "$tbl: $route"
            else
                fail "$tbl: default есть, но не через $tun: $route"
            fi
        else
            fail "$tbl: нет default-маршрута"
        fi
    done
}

check_iptables() {
    section "iptables mangle"

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local iface="xray-${code}"
        # iptables отображает метку в hex (0x64 для 100, 0x65 для 101, и т.д.)
        local mark_hex
        mark_hex=$(printf '0x%x' "$mark")

        if iptables -t mangle -S PREROUTING 2>/dev/null | \
            grep -qE -- "-i ${iface}\b.*--set-(xmark|mark) (${mark_hex}|${mark})(/0x[0-9a-f]+)?\b"; then
            ok "mangle: -i $iface → mark $mark ($mark_hex)"
        else
            fail "mangle: нет правила -i $iface → mark $mark ($mark_hex)"
        fi
    done

    section "iptables NAT POSTROUTING"

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local tun="tun${code}"

        if iptables -t nat -S POSTROUTING 2>/dev/null | \
            grep -qE -- "-o ${tun}\b.*-j MASQUERADE"; then
            ok "NAT: MASQUERADE -o $tun"
        else
            fail "NAT: нет MASQUERADE на $tun"
        fi
    done
}

check_tunnels() {
    section "работоспособность туннелей (curl через каждый tun)"

    if ! command -v curl >/dev/null 2>&1; then
        warn "curl не найден — пропускаю проверку связности"
        return
    fi

    local ips=()
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local tun="tun${code}"
        local out
        out=$(curl --interface "$tun" -s -m 10 https://api.ipify.org 2>/dev/null)
        if [ -n "$out" ]; then
            ok "$tun → $out"
            ips+=("$out")
        else
            fail "$tun: нет ответа"
        fi
    done

    # Проверка, что все IP разные (если кто-то настроен криво и два tun'а ведут в одно место)
    if [ "${#ips[@]}" -ge 2 ]; then
        local unique_count
        unique_count=$(printf '%s\n' "${ips[@]}" | sort -u | wc -l)
        if [ "$unique_count" -eq "${#ips[@]}" ]; then
            ok "все exit-IP разные"
        else
            warn "exit-IP повторяются — возможно, два tun'а ведут в одну страну"
        fi
    fi
}

summary() {
    echo
    printf "%s======== Сводка ========%s\n" "$C_DIM" "$C_RST"
    printf "  %sOK:     %d%s\n" "$C_OK"   "$OK_COUNT"   "$C_RST"
    printf "  %sWARN:   %d%s\n" "$C_WARN" "$WARN_COUNT" "$C_RST"
    printf "  %sFAIL:   %d%s\n" "$C_ERR"  "$FAIL_COUNT" "$C_RST"
    echo

    if [ "$FAIL_COUNT" -eq 0 ]; then
        printf "%sВсё работает.%s\n" "$C_OK" "$C_RST"
        return 0
    else
        printf "%sНайдены проблемы. См. строки с ✗ выше.%s\n" "$C_ERR" "$C_RST"
        return 1
    fi
}

main() {
    check_sysctl
    check_rt_tables
    check_scripts
    check_systemd_units
    check_interfaces
    check_ip_rules
    check_routes
    check_iptables
    check_tunnels
    summary
}

main
