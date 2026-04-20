#!/bin/bash
#
# diag.sh — multi-WAN gateway diagnostics (xray + tun2socks)
#
# Walks every layer of the setup and prints ok / warn / fail:
#   - sysctl (ARP, forward, rp_filter)
#   - routing tables
#   - systemd units (setup-macvlan, setup-routing, xray@*, tun2socks@*)
#   - macvlan interfaces and their IPs
#   - tun interfaces
#   - ip rule and via_* tables
#   - iptables mangle and NAT
#   - tunnel connectivity (curl through each tun)
#
# Usage:
#   bash diag.sh
#   bash diag.sh --quiet    # summary only
#
# Exit code:
#   0 — all good
#   1 — problems found
#

set -uo pipefail

# ---- unified config ----
# Tunables live in config.sh next to this script (see install.sh for format).
# Override via env: CONFIG_SH=/path/config.sh bash diag.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SH="${CONFIG_SH:-$SCRIPT_DIR/config.sh}"
if [ ! -f "$CONFIG_SH" ]; then
    echo "ERROR: config file not found: $CONFIG_SH" >&2
    echo "       copy config.sh.example to config.sh and edit it" >&2
    exit 1
fi
# shellcheck source=config.sh disable=SC1091
. "$CONFIG_SH"

# Backwards compat: old config.sh used COUNTRIES=, new one uses EXITS=.
if declare -p COUNTRIES >/dev/null 2>&1 && ! declare -p EXITS >/dev/null 2>&1; then
    EXITS=("${COUNTRIES[@]}")
fi

# ---- i18n ----
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
    ru*|RU*) LANG_CODE=ru ;;
    *)       LANG_CODE=en ;;
esac

# t "english" "russian" — pick message by current locale
t() {
    if [ "$LANG_CODE" = ru ]; then echo "$2"; else echo "$1"; fi
}

QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet) QUIET=1; shift ;;
        -h|--help)
            if [ "$LANG_CODE" = ru ]; then
                cat <<'HELP'
Использование: diag.sh [опции]

Опции:
  -q, --quiet   Показывать только итоговую сводку.
  -h, --help    Эта справка.
HELP
            else
                cat <<'HELP'
Usage: diag.sh [options]

Options:
  -q, --quiet   Show summary only.
  -h, --help    This help.
HELP
            fi
            exit 0
            ;;
        *) echo "$(t "Unknown argument: $1" "Неизвестный аргумент: $1")" >&2; exit 1 ;;
    esac
done

# ---- color output ----

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

# ---- checks ----

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
            fail "$key = ${v:-$(t "<unset>" "<не задан>")} $(t "(expected" "(ожидалось") $want)"
        fi
    done

    for f in /etc/sysctl.d/99-arp.conf /etc/sysctl.d/99-forward.conf; do
        if [ -f "$f" ]; then
            ok "$(t "present" "есть") $f"
        else
            fail "$(t "missing $f — sysctl will not persist across reboot" "нет $f — после ребута sysctl не восстановятся")"
        fi
    done
}

check_rt_tables() {
    section "$(t "routing tables (/etc/iproute2/rt_tables)" "таблицы маршрутизации (/etc/iproute2/rt_tables)")"

    for item in "${EXITS[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local tbl="via_${code}"
        if grep -qE "^[[:space:]]*${mark}[[:space:]]+${tbl}\b" /etc/iproute2/rt_tables 2>/dev/null; then
            ok "${mark} ${tbl}"
        else
            fail "$(t "no '${mark} ${tbl}' entry in /etc/iproute2/rt_tables" "нет записи '${mark} ${tbl}' в /etc/iproute2/rt_tables")"
        fi
    done
}

check_systemd_units() {
    section "$(t "systemd units" "systemd-юниты")"

    for unit in setup-macvlan.service setup-routing.service; do
        if [ -f "/etc/systemd/system/$unit" ]; then
            ok "$unit $(t "(unit file present)" "(файл юнита есть)")"
        else
            fail "$unit — $(t "unit file missing from /etc/systemd/system/" "файла юнита нет в /etc/systemd/system/")"
            continue
        fi
        if systemctl is-enabled "$unit" >/dev/null 2>&1; then
            ok "$unit — enabled"
        else
            warn "$unit — $(t "not enabled (will not start after reboot)" "не enabled (не стартанёт после ребута)")"
        fi
        if systemctl is-active "$unit" >/dev/null 2>&1; then
            ok "$unit — active"
        else
            fail "$unit — $(t "inactive" "неактивен")"
        fi
    done

    if [ -f /etc/systemd/system/tun2socks@.service.d/link-up.conf ]; then
        ok "$(t "drop-in link-up.conf for tun2socks@" "drop-in link-up.conf для tun2socks@")"
    else
        fail "$(t "missing /etc/systemd/system/tun2socks@.service.d/link-up.conf — tun interfaces will not come up" "нет /etc/systemd/system/tun2socks@.service.d/link-up.conf — tun-интерфейсы не поднимутся")"
    fi

    for item in "${EXITS[@]}"; do
        local code="${item%%:*}"
        for svc in "xray@${code}.service" "tun2socks@${code}.service"; do
            if systemctl is-enabled "$svc" >/dev/null 2>&1; then
                ok "$svc — enabled"
            else
                warn "$svc — $(t "not enabled" "не enabled")"
            fi
            if systemctl is-active "$svc" >/dev/null 2>&1; then
                ok "$svc — active"
            else
                fail "$svc — $(t "inactive" "неактивен")"
            fi
        done
    done
}

check_scripts() {
    section "$(t "scripts" "скрипты")"

    for s in /usr/local/sbin/setup-macvlan.sh /usr/local/sbin/setup-routing.sh; do
        if [ -x "$s" ]; then
            ok "$s"
        else
            fail "$s — $(t "missing or not executable" "нет или не исполняемый")"
        fi
    done
}

check_interfaces() {
    section "$(t "interfaces" "интерфейсы")"

    if ip link show "$PARENT_IF" >/dev/null 2>&1; then
        ok "$(t "parent interface $PARENT_IF exists" "родительский интерфейс $PARENT_IF существует")"
    else
        fail "$(t "parent interface $PARENT_IF not found" "родительский интерфейс $PARENT_IF не найден")"
        return
    fi

    for item in "${EXITS[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local ip="${rest%%:*}"
        local iface="xray-${code}"

        if ! ip link show "$iface" >/dev/null 2>&1; then
            fail "$(t "interface $iface missing" "интерфейс $iface отсутствует")"
            continue
        fi

        if ip -d link show "$iface" 2>/dev/null | grep -q "macvlan mode"; then
            ok "$iface — macvlan"
        else
            warn "$iface — $(t "not macvlan (or ip -d unsupported)" "не macvlan (или ip -d не поддерживает)")"
        fi

        local mac_parent mac_child
        mac_parent=$(ip link show "$PARENT_IF" | awk '/link\/ether/ {print $2}')
        mac_child=$(ip link show "$iface" | awk '/link\/ether/ {print $2}')
        if [ -n "$mac_child" ] && [ "$mac_child" != "$mac_parent" ]; then
            ok "$(t "$iface has its own MAC ($mac_child)" "$iface имеет свой MAC ($mac_child)")"
        else
            fail "$(t "$iface: MAC matches $PARENT_IF — client cannot distinguish gateways" "$iface: MAC совпадает с $PARENT_IF — клиент не различит шлюзы")"
        fi

        if ip -4 -o addr show dev "$iface" | awk '{print $4}' | grep -qx "${ip}/${NETMASK_BITS}"; then
            ok "$iface: IP $ip/${NETMASK_BITS}"
        else
            fail "$(t "$iface: missing IP $ip/${NETMASK_BITS}" "$iface: нет IP $ip/${NETMASK_BITS}")"
        fi

        if ip link show "$iface" | grep -q 'state UP\|NO-CARRIER.*UP'; then
            ok "$iface: state UP"
        else
            fail "$(t "$iface: link not UP" "$iface: линк не UP")"
        fi

        local rpf
        rpf=$(sysctl -n "net.ipv4.conf.${iface}.rp_filter" 2>/dev/null)
        if [ "$rpf" = "0" ]; then
            ok "$iface: rp_filter=0"
        else
            warn "$iface: rp_filter=${rpf:-?} $(t "(expected 0)" "(ожидалось 0)")"
        fi
    done

    for item in "${EXITS[@]}"; do
        local code="${item%%:*}"
        local tun="tun${code}"

        if ! ip link show "$tun" >/dev/null 2>&1; then
            fail "$(t "$tun missing" "$tun отсутствует")"
            continue
        fi

        if ip link show "$tun" | grep -qE 'state (UP|UNKNOWN)'; then
            ok "$tun: $(t "up" "поднят")"
        else
            fail "$(t "$tun: link not up" "$tun: линк не поднят")"
        fi

        local rpf
        rpf=$(sysctl -n "net.ipv4.conf.${tun}.rp_filter" 2>/dev/null)
        if [ "$rpf" = "0" ]; then
            ok "$tun: rp_filter=0"
        else
            warn "$tun: rp_filter=${rpf:-?} $(t "(expected 0)" "(ожидалось 0)")"
        fi
    done
}

check_ip_rules() {
    section "ip rule (policy routing)"

    for item in "${EXITS[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local tbl="via_${code}"

        if ip rule show | grep -qE "fwmark 0x$(printf '%x' "$mark")\b.*lookup ${tbl}"; then
            ok "fwmark $mark → $tbl"
        else
            fail "$(t "no rule: fwmark $mark → $tbl" "нет правила: fwmark $mark → $tbl")"
        fi
    done
}

check_routes() {
    section "$(t "route tables (via_*)" "таблицы маршрутов (via_*)")"

    for item in "${EXITS[@]}"; do
        local code="${item%%:*}"
        local tbl="via_${code}"
        local tun="tun${code}"

        local route
        route=$(ip route show table "$tbl" 2>/dev/null | grep '^default')
        if [ -n "$route" ]; then
            if echo "$route" | grep -q "dev $tun"; then
                ok "$tbl: $route"
            else
                fail "$(t "$tbl: default present, but not via $tun: $route" "$tbl: default есть, но не через $tun: $route")"
            fi
        else
            fail "$(t "$tbl: no default route" "$tbl: нет default-маршрута")"
        fi
    done
}

check_iptables() {
    section "iptables mangle"

    for item in "${EXITS[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local iface="xray-${code}"
        local mark_hex
        mark_hex=$(printf '0x%x' "$mark")

        if iptables -t mangle -S PREROUTING 2>/dev/null | \
            grep -qE -- "-i ${iface}\b.*--set-(xmark|mark) (${mark_hex}|${mark})(/0x[0-9a-f]+)?\b"; then
            ok "mangle: -i $iface → mark $mark ($mark_hex)"
        else
            fail "$(t "mangle: no rule -i $iface → mark $mark ($mark_hex)" "mangle: нет правила -i $iface → mark $mark ($mark_hex)")"
        fi
    done

    section "iptables NAT POSTROUTING"

    for item in "${EXITS[@]}"; do
        local code="${item%%:*}"
        local tun="tun${code}"

        if iptables -t nat -S POSTROUTING 2>/dev/null | \
            grep -qE -- "-o ${tun}\b.*-j MASQUERADE"; then
            ok "NAT: MASQUERADE -o $tun"
        else
            fail "$(t "NAT: no MASQUERADE on $tun" "NAT: нет MASQUERADE на $tun")"
        fi
    done
}

check_tunnels() {
    section "$(t "tunnel connectivity (curl through each tun)" "работоспособность туннелей (curl через каждый tun)")"

    if ! command -v curl >/dev/null 2>&1; then
        warn "$(t "curl not found — skipping connectivity check" "curl не найден — пропускаю проверку связности")"
        return
    fi

    local ips=()
    for item in "${EXITS[@]}"; do
        local code="${item%%:*}"
        local tun="tun${code}"
        local out
        out=$(curl --interface "$tun" -s -m 10 https://api.ipify.org 2>/dev/null)
        if [ -n "$out" ]; then
            ok "$tun → $out"
            ips+=("$out")
        else
            fail "$(t "$tun: no response" "$tun: нет ответа")"
        fi
    done

    if [ "${#ips[@]}" -ge 2 ]; then
        local unique_count
        unique_count=$(printf '%s\n' "${ips[@]}" | sort -u | wc -l)
        if [ "$unique_count" -eq "${#ips[@]}" ]; then
            ok "$(t "all exit IPs are distinct" "все exit-IP разные")"
        else
            warn "$(t "exit IPs repeat — possibly two tuns route to the same upstream" "exit-IP повторяются — возможно, два tun'а ведут в один и тот же upstream")"
        fi
    fi
}

summary() {
    echo
    printf "%s======== %s ========%s\n" "$C_DIM" "$(t "Summary" "Сводка")" "$C_RST"
    printf "  %sOK:     %d%s\n" "$C_OK"   "$OK_COUNT"   "$C_RST"
    printf "  %sWARN:   %d%s\n" "$C_WARN" "$WARN_COUNT" "$C_RST"
    printf "  %sFAIL:   %d%s\n" "$C_ERR"  "$FAIL_COUNT" "$C_RST"
    echo

    if [ "$FAIL_COUNT" -eq 0 ]; then
        printf "%s%s%s\n" "$C_OK" "$(t "Everything works." "Всё работает.")" "$C_RST"
        return 0
    else
        printf "%s%s%s\n" "$C_ERR" "$(t "Problems found. See ✗ lines above." "Найдены проблемы. См. строки с ✗ выше.")" "$C_RST"
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
