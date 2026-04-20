#!/bin/bash
#
# Multi-country gateway installer
#
# Разворачивает в одном контейнере схему: N macvlan-интерфейсов на global,
# каждый со своим IP; клиент, указывающий определённый IP как шлюз,
# попадает через xray+tun2socks в соответствующую страну.
#
# Перед запуском:
#  - в контейнере должен быть поднят интерфейс PARENT_IF (по умолчанию global)
#    с основным IP (например, 172.31.255.230/24);
#  - должны быть установлены xray и tun2socks (xjasonlyu);
#  - должен быть systemd-шаблон tun2socks@.service;
#  - для каждой страны должен быть конфиг /etc/tun2socks/<код>.yaml,
#    в котором tun2socks подключается к своему xray socks5.
#
# Запускать от root.
#
# ---- КОНФИГУРАЦИЯ ----
#
# COUNTRIES — массив строк "код:IP:mark", по одной на страну.
# Коды совпадают с именами файлов в /etc/tun2socks/<код>.yaml и с именами
# инстансов tun2socks@<код>.service. Tun-интерфейсы должны называться tun<код>,
# macvlan-интерфейсы создаются как xray-<код>.
#
# PARENT_IF — родительский физический/veth интерфейс, на котором делаем macvlan.
# NETMASK_BITS — маска подсети для всех IP (обычно 24).

set -uo pipefail

PARENT_IF="${PARENT_IF:-global}"
NETMASK_BITS="${NETMASK_BITS:-24}"

COUNTRIES=(
    "fr:172.31.255.232:100"
    "se:172.31.255.233:101"
    "fi:172.31.255.234:102"
)

# ---- конец конфигурации ----

DRY_RUN=0

print_help() {
    cat <<'HELP'
Usage: install.sh [options]

Options:
  -n, --dry-run    Показать, что будет сделано, без внесения изменений.
  -h, --help       Эта справка.

Переменные окружения:
  PARENT_IF        Родительский интерфейс для macvlan (по умолчанию: global).
  NETMASK_BITS     Длина маски для адресов (по умолчанию: 24).
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        *)            echo "Неизвестный аргумент: $1" >&2; print_help; exit 1 ;;
    esac
done

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

# run — выполняет команду или только печатает её в dry-run режиме.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  + $*"
        return 0
    else
        "$@"
    fi
}

# write_file — создаёт файл с содержимым (читает из stdin).
# В dry-run режиме печатает путь и содержимое, не пишет реально.
write_file() {
    local path="$1"
    local mode="${2:-}"  # optional, e.g. 755

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  + записал бы файл: $path${mode:+ (mode $mode)}"
        echo "  +--- содержимое ---"
        sed 's/^/  + | /'
        echo "  +------------------"
    else
        local dir
        dir="$(dirname "$path")"
        [ -d "$dir" ] || mkdir -p "$dir"
        cat > "$path"
        if [ -n "$mode" ]; then
            chmod "$mode" "$path"
        fi
    fi
    return 0
}

require_root() {
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    [ "$(id -u)" -eq 0 ] || die "Запускать от root"
}

require_parent_if() {
    ip link show "$PARENT_IF" &>/dev/null || \
        die "Интерфейс $PARENT_IF не найден. Задай PARENT_IF=<имя> или проверь сеть."
}

require_tun2socks() {
    [ -x /usr/bin/tun2socks ] || die "/usr/bin/tun2socks не найден"
    [ -f /usr/lib/systemd/system/tun2socks@.service ] || \
        die "tun2socks@.service не найден в /usr/lib/systemd/system/"
}

require_configs() {
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        [ -f "/etc/tun2socks/${code}.yaml" ] || \
            die "Нет /etc/tun2socks/${code}.yaml для страны '${code}'"
    done
}

require_xray_units() {
    # Проверяем, что шаблон xray@.service существует.
    # Конкретные инстансы xray@<code>.service — порождаются динамически
    # и в list-unit-files не отображаются.
    if [ ! -f /usr/lib/systemd/system/xray@.service ] && \
       [ ! -f /etc/systemd/system/xray@.service ] && \
       [ ! -f /lib/systemd/system/xray@.service ]; then
        die "Не найден systemd-шаблон xray@.service"
    fi
}

write_sysctl() {
    log "Записываю sysctl"

    write_file /etc/sysctl.d/99-arp.conf <<'EOF'
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.conf.default.arp_announce = 2
EOF

    write_file /etc/sysctl.d/99-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

    run sysctl -p /etc/sysctl.d/99-arp.conf >/dev/null
    run sysctl -p /etc/sysctl.d/99-forward.conf >/dev/null
}

write_rt_tables() {
    log "Добавляю таблицы маршрутизации в /etc/iproute2/rt_tables"
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local tbl="via_${code}"
        if ! grep -qE "^[[:space:]]*${mark}[[:space:]]+${tbl}$" /etc/iproute2/rt_tables 2>/dev/null; then
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "  + добавил бы в /etc/iproute2/rt_tables: ${mark} ${tbl}"
            else
                echo "${mark} ${tbl}" >> /etc/iproute2/rt_tables
            fi
        else
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "  = уже есть в /etc/iproute2/rt_tables: ${mark} ${tbl}"
            fi
        fi
    done
    return 0
}

write_tun2socks_dropin() {
    log "Добавляю ExecStartPost для tun2socks@.service (поднятие tun)"
    write_file /etc/systemd/system/tun2socks@.service.d/link-up.conf <<'EOF'
[Service]
ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5; do ip link show tun%i >/dev/null 2>&1 && break; sleep 1; done; ip link set tun%i up'
EOF
}

write_macvlan_script() {
    log "Создаю /usr/local/sbin/setup-macvlan.sh"

    local pairs=""
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local ip="${rest%%:*}"
        pairs+="setup_iface xray-${code} ${ip}"$'\n'
    done

    write_file /usr/local/sbin/setup-macvlan.sh 755 <<EOF
#!/bin/bash
# Создаёт macvlan-подинтерфейсы поверх ${PARENT_IF}
setup_iface() {
    local name="\$1"
    local addr="\$2"
    ip link show "\$name" &>/dev/null || \\
        ip link add link ${PARENT_IF} name "\$name" type macvlan mode bridge
    if ! ip -4 -o addr show dev "\$name" | awk '{print \$4}' | grep -qx "\${addr}/${NETMASK_BITS}"; then
        ip addr add "\${addr}/${NETMASK_BITS}" dev "\$name" 2>/dev/null || true
    fi
    ip link set "\$name" up
}
${pairs}
EOF
}

write_macvlan_unit() {
    log "Создаю setup-macvlan.service"

    local before_list=""
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        before_list+=" tun2socks@${code}.service xray@${code}.service"
    done

    write_file /etc/systemd/system/setup-macvlan.service <<EOF
[Unit]
Description=Setup macvlan subinterfaces on ${PARENT_IF}
After=network.target
Before=${before_list# }

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-macvlan.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_routing_script() {
    log "Создаю /usr/local/sbin/setup-routing.sh"

    # Собираем секции скрипта на основе COUNTRIES
    local tuns=""
    local xrays=""
    local wait_tun_list=""
    local default_routes=""
    local ip_rules=""
    local mangle_rules=""
    local nat_loop=""
    local rp_list=""

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local rest="${item#*:}"
        local ip="${rest%%:*}"
        local mark="${rest##*:}"
        local tbl="via_${code}"

        tuns+=" tun${code}"
        xrays+=" xray-${code}"
        wait_tun_list+=" tun${code}"

        default_routes+="ip route replace default dev tun${code} table ${tbl}"$'\n'
        ip_rules+="ip rule del fwmark ${mark} table ${tbl} 2>/dev/null"$'\n'
        ip_rules+="ip rule add fwmark ${mark} table ${tbl}"$'\n'
        mangle_rules+="iptables -t mangle -A PREROUTING -i xray-${code} -j MARK --set-mark ${mark}"$'\n'
    done

    write_file /usr/local/sbin/setup-routing.sh 755 <<EOF
#!/bin/bash
# Policy routing для multi-country tun

# Ждём появления tun-интерфейсов (до 30 сек)
for t in${wait_tun_list}; do
    for i in \$(seq 1 30); do
        ip link show "\$t" &>/dev/null && break
        sleep 1
    done
done

# Default-маршруты в таблицах
${default_routes}
# ip rule: fwmark → таблица
${ip_rules}
# Маркировка по входному интерфейсу
iptables -t mangle -F PREROUTING
${mangle_rules}
# NAT на выходе
for t in${tuns}; do
    iptables -t nat -C POSTROUTING -o "\$t" -j MASQUERADE 2>/dev/null || \\
        iptables -t nat -A POSTROUTING -o "\$t" -j MASQUERADE
done

# rp_filter=0 для всех задействованных интерфейсов
for i in${xrays}${tuns} ${PARENT_IF}; do
    sysctl -w net.ipv4.conf.\$i.rp_filter=0 >/dev/null 2>&1 || true
done

ip route flush cache

# Сохраняем iptables для persistence, если есть /etc/sysconfig
if [ -d /etc/sysconfig ]; then
    iptables-save > /etc/sysconfig/iptables
fi
EOF
}

write_routing_unit() {
    log "Создаю setup-routing.service"

    local after_list="setup-macvlan.service iptables.service"
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        after_list+=" tun2socks@${code}.service xray@${code}.service"
    done

    write_file /etc/systemd/system/setup-routing.service <<EOF
[Unit]
Description=Policy routing for multi-country tun
After=${after_list}
Wants=setup-macvlan.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

enable_services() {
    log "Перезагружаю systemd и включаю сервисы"
    run systemctl daemon-reload

    run systemctl enable setup-macvlan.service
    run systemctl enable setup-routing.service

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        run systemctl enable "tun2socks@${code}.service"
        run systemctl enable "xray@${code}.service"
    done
}

start_services() {
    log "Запускаю сервисы"
    run systemctl restart setup-macvlan.service

    # xray слушает socks5 на адресах macvlan — поэтому стартует после него,
    # но до tun2socks, который к xray подключается.
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        run systemctl restart "xray@${code}.service"
    done

    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        run systemctl restart "tun2socks@${code}.service"
    done

    # Даём tun2socks'ам пару секунд, чтобы tun-интерфейсы точно поднялись
    run sleep 2

    run systemctl restart setup-routing.service
}

verify() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Пропуск verify (dry-run)"
        return 0
    fi

    log "Проверяю результат"

    echo "--- IP addresses ---"
    ip -4 addr show | grep -E 'inet |^[0-9]+:'

    echo "--- ip rule ---"
    ip rule show

    echo "--- mangle PREROUTING ---"
    iptables -t mangle -L PREROUTING -v -n

    echo "--- NAT POSTROUTING ---"
    iptables -t nat -L POSTROUTING -v -n

    echo
    log "Проверка связности (curl через каждый tun):"
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local tun="tun${code}"
        printf "  %s: " "$tun"
        if out=$(curl --interface "$tun" -s -m 10 https://api.ipify.org 2>/dev/null); then
            echo "$out"
        else
            echo "FAIL"
        fi
    done
}

main() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "===== DRY RUN: команды и файлы выводятся, реальных изменений не будет ====="
        echo
    fi

    require_root
    require_parent_if
    require_tun2socks
    require_configs
    require_xray_units

    write_sysctl
    write_rt_tables
    write_tun2socks_dropin
    write_macvlan_script
    write_macvlan_unit
    write_routing_script
    write_routing_unit

    enable_services
    start_services

    echo
    verify

    echo
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Dry-run завершён. Запусти без --dry-run, чтобы применить изменения."
    else
        log "Готово. После перезагрузки контейнера вся конфигурация поднимется автоматически."
    fi
}

main "$@"
