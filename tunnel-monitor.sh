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


# --- честное состояние выхода для мониторинга в OPNsense ---
# Зачем: OPNsense мониторит сам адрес выхода он-линк пингом, а раньше мерил
# анкасты через туннель — и мёртвый выход оставался "зелёным", failover не срабатывал
# (поймано 19.08.2026). Мёртвый выход теперь: маршрут в blackhole + адрес молчит
# на ICMP. Живой: маршрут через tun<код> + ICMP отвечает.
STATE_DIR=/run/tunnel-monitor
mkdir -p "$STATE_DIR"

vip_iface() { echo "xray-$1"; }

vip_present() {
    local code="$1" ip="$2"
    ip addr show dev "$(vip_iface "$code")" 2>/dev/null | grep -q "inet ${ip}/"
}

# Общее для обоих переходов: адрес выхода должен быть на месте ВСЕГДА.
# Без него OPNsense не может разрешить ARP, dpinger перестаёт слать пробы и
# замирает на последних значениях — шлюз остаётся «Online» с нулевыми потерями
# (проверено 19.08.2026). Гасим не адрес, а ответ на ICMP.
# Длину префикса берём с интерфейса, на котором маршрут по умолчанию:
# на одной площадке сеть /28, на другой /24 — хардкод сюда не годится.
vip_prefix() {
    local dev pfx
    dev=$(ip -4 route show default table main 2>/dev/null | awk '{print $5; exit}')
    pfx=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{split($4,a,"/"); print a[2]; exit}')
    echo "${pfx:-24}"
}

vip_ensure_addr() {
    local code="$1" ip="$2"
    if ! vip_present "$code" "$ip"; then
        ip addr add "${ip}/$(vip_prefix)" dev "$(vip_iface "$code")" 2>/dev/null \
            && log "VIP  $code: адрес $ip возвращён"
    fi
}

vip_down() {
    local code="$1" ip="$2"
    vip_ensure_addr "$code" "$ip"
    # Трафику некуда идти: чёрная дыра вместо маршрута по умолчанию в таблице выхода.
    if ip route replace blackhole default table "via_${code}" 2>/dev/null; then
        log "GW   $code: таблица via_${code} переведена в blackhole — шлюз в OPNsense погашен"
    fi
    # OPNsense мониторит сам адрес выхода (он-линк пинг). Пока адрес отвечает,
    # шлюз считается живым, поэтому перестаём отвечать на ICMP: dpinger видит
    # 100 % потерь и failover срабатывает честно.
    if ! iptables -C INPUT -d "$ip" -p icmp --icmp-type echo-request -j DROP 2>/dev/null; then
        iptables -I INPUT -d "$ip" -p icmp --icmp-type echo-request -j DROP 2>/dev/null \
            && log "GW   $code: ICMP на $ip заблокирован — шлюз в OPNsense погаснет"
    fi
    # tun2socks НЕ останавливаем: устройство tun<код> нужно, чтобы при
    # восстановлении было куда вернуть маршрут (иначе выход «оживает» по SOCKS,
    # ICMP разблокируется, а трафик продолжает уходить в blackhole).
}

vip_up() {
    local code="$1" ip="$2" i
    vip_ensure_addr "$code" "$ip"
    # устройства нет (например, сервис упал) — поднимаем и ждём появления
    if ! ip link show "tun${code}" >/dev/null 2>&1; then
        systemctl is-active --quiet "tun2socks@${code}.service" \
            || systemctl start "tun2socks@${code}.service" 2>/dev/null
        for i in $(seq 1 10); do
            ip link show "tun${code}" >/dev/null 2>&1 && break
            sleep 1
        done
    fi
    # возвращаем маршрут через туннель вместо чёрной дыры
    if ip route show table "via_${code}" 2>/dev/null | grep -q "^blackhole"; then
        if ip link show "tun${code}" >/dev/null 2>&1; then
            ip route replace default dev "tun${code}" table "via_${code}" 2>/dev/null \
                && log "GW   $code: маршрут через tun${code} восстановлен"
        else
            log "GW   $code: tun${code} не появился — оставляю blackhole и блокировку ICMP"
            return 0
        fi
    fi
    # ICMP разблокируем ПОСЛЕДНИМ: только когда трафику есть куда идти,
    # иначе шлюз в OPNsense зеленеет, а пакеты уходят в чёрную дыру.
    while iptables -C INPUT -d "$ip" -p icmp --icmp-type echo-request -j DROP 2>/dev/null; do
        iptables -D INPUT -d "$ip" -p icmp --icmp-type echo-request -j DROP 2>/dev/null \
            && log "GW   $code: ICMP на $ip разблокирован"
    done
}

# состояние выхода между запусками: чтобы слать в Telegram только смену состояния
state_get() { cat "$STATE_DIR/$1.state" 2>/dev/null || echo up; }
state_set() { echo "$2" > "$STATE_DIR/$1.state"; }

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
            vip_up "$code" "$ip"
            if [ "$(state_get "$code")" = "down" ]; then
                alert_lines+="✅ <b>${code}</b> снова работает (${ip_out}), маршрут и ICMP возвращены"$'\n'
            fi
            state_set "$code" up
            continue
        fi

        # упал — рестарт
        log "FAIL $code ($socks) — restarting xray@$code + tun2socks@$code"
        systemctl restart "xray@${code}.service" 2>/dev/null
        systemctl restart "tun2socks@${code}.service" 2>/dev/null
        sleep "$RESTART_WAIT"

        if ip_out=$(check_exit "$socks"); then
            log "RECOVERED $code ($socks) -> $ip_out after restart"
            vip_up "$code" "$ip"
            state_set "$code" up
            if [ "$ALERT_MODE" = "always" ]; then
                alert_lines+="⚠️ <b>${code}</b> упал, восстановлен после рестарта (${ip_out})"$'\n'
            fi
        else
            log "STILL DOWN $code ($socks) after restart"
            vip_down "$code" "$ip"
            if [ "$(state_get "$code")" != "down" ]; then
                alert_lines+="🔴 <b>${code}</b> НЕ восстановлен после рестарта (маршрут в blackhole, шлюз в OPNsense погашен)"$'\n'
            fi
            state_set "$code" down
        fi
    done

    if [ -n "$alert_lines" ]; then
        send_telegram "<b>[${HOSTNAME_S}] tunnel-monitor</b>"$'\n'"${alert_lines}"
    fi
}

main
