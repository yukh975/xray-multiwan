#!/bin/bash
#
# tunnel-monitor.sh — проверка xray-выходов, рестарт упавших, алерт в Telegram.
# Читает EXITS из config.sh и параметры из tunnel-monitor.conf (рядом).
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SH="${SCRIPT_DIR}/config.sh"
MON_CONF="${SCRIPT_DIR}/tunnel-monitor.conf"
LOG="${SCRIPT_DIR}/tunnel-monitor.log"

# --- defaults (переопределяются в tunnel-monitor.conf) ---
TG_BOT_TOKEN=""
TG_CHAT_ID=""
PRIMARY_SOCKS=""
ALERT_MODE="always"
RESTART_WAIT=10
CHECK_URLS="https://ifconfig.me/ip https://netadm.pro/ip"
SOCKS_PORT=10808

[ -f "$CONFIG_SH" ] || { echo "no config.sh"; exit 1; }
[ -f "$MON_CONF" ]  || { echo "no tunnel-monitor.conf"; exit 1; }
. "$CONFIG_SH"
. "$MON_CONF"

MONITOR_NAME="${MONITOR_NAME:-}"
HOSTNAME_S="${MONITOR_NAME:-$(hostname -s 2>/dev/null || hostname)}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# Проверка одного выхода через socks5. Возвращает 0 + печатает IP, или 1.
check_exit() {
    local socks="$1" out u
    for u in $CHECK_URLS; do
        out=$(curl --socks5 "$socks" -s -m 10 "$u" 2>/dev/null | tr -d '"' | sed 's/\\n$//')
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    done
    return 1
}

# Отправка в Telegram. Сначала PRIMARY_SOCKS, потом перебор живых выходов.
send_telegram() {
    local text="$1"
    local api="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    [ -z "$TG_BOT_TOKEN" ] && { log "TG: no token, skip"; return 1; }

    # список socks-кандидатов: сначала PRIMARY, потом все локальные выходы
    local candidates=()
    [ -n "$PRIMARY_SOCKS" ] && candidates+=("$PRIMARY_SOCKS")
    local item ip
    for item in "${EXITS[@]}"; do
        ip=$(echo "$item" | cut -d: -f2)
        candidates+=("${ip}:${SOCKS_PORT}")
    done

    local c
    for c in "${candidates[@]}"; do
        if curl --socks5-hostname "$c" -s -m 15 "$api" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=HTML" 2>/dev/null | grep -q '"ok":true'; then
            log "TG: sent via $c"
            return 0
        fi
    done
    log "TG: FAILED to send via all channels"
    return 1
}

# --- основная логика ---
main() {
    echo "" >> "$LOG"
    local item code ip socks res ip_out alert_lines=""

    for item in "${EXITS[@]}"; do
        code=$(echo "$item" | cut -d: -f1)
        ip=$(echo "$item" | cut -d: -f2)
        socks="${ip}:${SOCKS_PORT}"

        if ip_out=$(check_exit "$socks"); then
            log "OK   $code ($socks) -> $ip_out"
            continue
        fi

        # упал — рестарт
        log "FAIL $code ($socks) — restarting xray@$code + tun2socks@$code"
        systemctl restart "xray@${code}.service" 2>/dev/null
        systemctl restart "tun2socks@${code}.service" 2>/dev/null
        sleep "$RESTART_WAIT"

        if ip_out=$(check_exit "$socks"); then
            log "RECOVERED $code ($socks) -> $ip_out after restart"
            if [ "$ALERT_MODE" = "always" ]; then
                alert_lines+="⚠️ <b>${code}</b> упал, восстановлен после рестарта (${ip_out})"$'\n'
            fi
        else
            log "STILL DOWN $code ($socks) after restart"
            alert_lines+="🔴 <b>${code}</b> НЕ восстановлен после рестарта"$'\n'
        fi
    done

    if [ -n "$alert_lines" ]; then
        send_telegram "<b>[${HOSTNAME_S}] tunnel-monitor</b>"$'\n'"${alert_lines}"
    fi
}

main
