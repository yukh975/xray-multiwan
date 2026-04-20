#!/bin/bash
#
# Multi-WAN gateway installer (xray + tun2socks)
#
# Разворачивает в одном контейнере схему: N macvlan-интерфейсов на global,
# каждый со своим IP; клиент, указывающий определённый IP как шлюз,
# попадает через xray+tun2socks в соответствующий WAN-выход.
#
# Перед запуском:
#  - в контейнере должен быть поднят интерфейс PARENT_IF (по умолчанию global)
#    с основным IP (например, 192.168.0.230/24);
#  - должны быть установлены xray и tun2socks (xjasonlyu);
#  - должен быть systemd-шаблон tun2socks@.service;
#  - для каждого выхода должен быть конфиг /etc/tun2socks/<код>.yaml,
#    в котором tun2socks подключается к своему xray socks5.
#
# Запускать от root.

set -uo pipefail

# ---- unified config ----
# All tunables (PARENT_IF, NETMASK_BITS, COUNTRIES) live in config.sh next
# to this script. Edit config.sh, not this file.
# To use a different config file: CONFIG_SH=/path/config.sh bash install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SH="${CONFIG_SH:-$SCRIPT_DIR/config.sh}"
if [ ! -f "$CONFIG_SH" ]; then
    echo "ERROR: config file not found: $CONFIG_SH" >&2
    echo "       copy config.sh.example to config.sh and edit it:" >&2
    echo "         cp $SCRIPT_DIR/config.sh.example $SCRIPT_DIR/config.sh" >&2
    exit 1
fi
# shellcheck source=config.sh disable=SC1091
. "$CONFIG_SH"

XRAY_CONFDIR="${XRAY_CONFDIR:-/etc/xray}"
TUN2SOCKS_CONFDIR="${TUN2SOCKS_CONFDIR:-/etc/tun2socks}"

# ---- i18n ----
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
    ru*|RU*) LANG_CODE=ru ;;
    *)       LANG_CODE=en ;;
esac

# t "english" "russian" — pick message by current locale
t() {
    if [ "$LANG_CODE" = ru ]; then echo "$2"; else echo "$1"; fi
}

DRY_RUN=0
INSTALL=0
UNINSTALL=0

print_help() {
    if [ "$LANG_CODE" = ru ]; then
        cat <<'HELP'
Использование: install.sh <действие> [опции]

Действия (обязательно одно из):
  -i, --install    Выполнить установку/переконфигурирование (идемпотентно).
  -u, --uninstall  Удалить всё, что создаёт install.sh (сервисы, скрипты,
                   юниты, iptables, ip rule, macvlan-интерфейсы, sysctl).
                   Конфиги /etc/xray/*.json и /etc/tun2socks/*.yaml НЕ
                   удаляются — их пишет пользователь.

Опции:
  -n, --dry-run    Показать, что будет сделано, без внесения изменений.
                   Комбинируется с --install или --uninstall.
  -h, --help       Эта справка.

Настройки (PARENT_IF, NETMASK_BITS, COUNTRIES) — в файле config.sh
рядом со скриптом. Отредактируй его перед первым запуском.

Примеры:
  bash install.sh --install
  bash install.sh --install --dry-run
  bash install.sh --uninstall
HELP
    else
        cat <<'HELP'
Usage: install.sh <action> [options]

Actions (exactly one required):
  -i, --install    Install / reconfigure (idempotent).
  -u, --uninstall  Remove everything install.sh creates (services, scripts,
                   units, iptables, ip rule, macvlan interfaces, sysctl).
                   User configs /etc/xray/*.json and /etc/tun2socks/*.yaml
                   are preserved.

Options:
  -n, --dry-run    Print what would be done, without applying changes.
                   Combine with --install or --uninstall.
  -h, --help       This help.

Tunables (PARENT_IF, NETMASK_BITS, COUNTRIES) live in config.sh next to
this script. Edit it before the first run.

Examples:
  bash install.sh --install
  bash install.sh --install --dry-run
  bash install.sh --uninstall
HELP
    fi
}

# No arguments — show help and exit 0 (help is the default action now).
if [ $# -eq 0 ]; then
    print_help
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--install)   INSTALL=1;   shift ;;
        -u|--uninstall) UNINSTALL=1; shift ;;
        -n|--dry-run)   DRY_RUN=1;   shift ;;
        -h|--help)      print_help; exit 0 ;;
        *) echo "$(t "Unknown argument: $1" "Неизвестный аргумент: $1")" >&2
           echo >&2
           print_help >&2
           exit 1 ;;
    esac
done

if [ "$INSTALL" -eq 1 ] && [ "$UNINSTALL" -eq 1 ]; then
    echo "$(t "--install and --uninstall are mutually exclusive" "--install и --uninstall взаимоисключающие")" >&2
    exit 1
fi

if [ "$INSTALL" -eq 0 ] && [ "$UNINSTALL" -eq 0 ]; then
    echo "$(t "No action specified. Use --install or --uninstall (see --help)." "Не указано действие. Используй --install или --uninstall (см. --help).")" >&2
    exit 1
fi

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
write_file() {
    local path="$1"
    local mode="${2:-}"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  + $(t "would write file:" "записал бы файл:") $path${mode:+ (mode $mode)}"
        echo "  +--- $(t "content" "содержимое") ---"
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

# remove_file — удаляет файл (или печатает в dry-run).
remove_file() {
    local path="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -e "$path" ]; then
            echo "  + $(t "would remove:" "удалил бы:") $path"
        else
            echo "  = $(t "missing (skip):" "отсутствует, пропуск:") $path"
        fi
    else
        [ -e "$path" ] && rm -f "$path"
    fi
}

require_root() {
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    [ "$(id -u)" -eq 0 ] || die "$(t "Must run as root" "Запускать от root")"
}

require_parent_if() {
    ip link show "$PARENT_IF" &>/dev/null || \
        die "$(t "Interface $PARENT_IF not found. Set PARENT_IF=<name> or check the network." \
               "Интерфейс $PARENT_IF не найден. Задай PARENT_IF=<имя> или проверь сеть.")"
}

require_tun2socks() {
    if [ ! -x /usr/bin/tun2socks ]; then
        if [ "$LANG_CODE" = ru ]; then
            cat >&2 <<'EOF'
ОШИБКА: /usr/bin/tun2socks не найден.

Как установить (xjasonlyu/tun2socks):
  ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; *) A=$ARCH;; esac
  curl -L -o /tmp/tun2socks.zip \
    https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-${A}.zip
  unzip -p /tmp/tun2socks.zip > /usr/bin/tun2socks && chmod +x /usr/bin/tun2socks

Шаблон systemd-юнита (/usr/lib/systemd/system/tun2socks@.service) —
см. в README, раздел «Prerequisites».
EOF
        else
            cat >&2 <<'EOF'
ERROR: /usr/bin/tun2socks not found.

How to install (xjasonlyu/tun2socks):
  ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; *) A=$ARCH;; esac
  curl -L -o /tmp/tun2socks.zip \
    https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-${A}.zip
  unzip -p /tmp/tun2socks.zip > /usr/bin/tun2socks && chmod +x /usr/bin/tun2socks

systemd unit template (/usr/lib/systemd/system/tun2socks@.service) —
see the "Prerequisites" section in README.
EOF
        fi
        exit 1
    fi
    if [ ! -f /usr/lib/systemd/system/tun2socks@.service ]; then
        die "$(t "tun2socks@.service not found in /usr/lib/systemd/system/ — see README (Prerequisites)" \
               "tun2socks@.service не найден в /usr/lib/systemd/system/ — см. README (Prerequisites)")"
    fi
}

require_xray() {
    if ! command -v xray >/dev/null 2>&1 && [ ! -x /usr/local/bin/xray ] && [ ! -x /usr/bin/xray ]; then
        if [ "$LANG_CODE" = ru ]; then
            cat >&2 <<'EOF'
ОШИБКА: бинарник xray не найден (искал в PATH, /usr/local/bin, /usr/bin).

Как установить (XTLS/Xray-core, официальный скрипт):
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

После установки положи per-exit конфиги в ${XRAY_CONFDIR}/<code>.json
(по одному на каждый WAN-выход из COUNTRIES).
EOF
        else
            cat >&2 <<'EOF'
ERROR: xray binary not found (checked PATH, /usr/local/bin, /usr/bin).

How to install (XTLS/Xray-core, official script):
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

Then put per-exit configs at ${XRAY_CONFDIR}/<code>.json
(one per WAN exit in COUNTRIES).
EOF
        fi
        exit 1
    fi
}

require_configs() {
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        [ -f "${TUN2SOCKS_CONFDIR}/${code}.yaml" ] || \
            die "$(t "Missing ${TUN2SOCKS_CONFDIR}/${code}.yaml for exit '${code}'" \
                   "Нет ${TUN2SOCKS_CONFDIR}/${code}.yaml для выхода '${code}'")"
    done
}

require_xray_units() {
    # Шаблон xray@.service должен существовать. Конкретные инстансы
    # xray@<code>.service порождаются динамически и в list-unit-files
    # не отображаются.
    if [ ! -f /usr/lib/systemd/system/xray@.service ] && \
       [ ! -f /etc/systemd/system/xray@.service ] && \
       [ ! -f /lib/systemd/system/xray@.service ]; then
        die "$(t "xray@.service systemd template not found — install xray via XTLS/Xray-install and see README (Prerequisites)" \
               "systemd-шаблон xray@.service не найден — поставь xray через XTLS/Xray-install и см. README (Prerequisites)")"
    fi
}

write_sysctl() {
    log "$(t "Writing sysctl config" "Записываю sysctl")"

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
    log "$(t "Adding routing tables to /etc/iproute2/rt_tables" \
           "Добавляю таблицы маршрутизации в /etc/iproute2/rt_tables")"
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local tbl="via_${code}"
        if ! grep -qE "^[[:space:]]*${mark}[[:space:]]+${tbl}$" /etc/iproute2/rt_tables 2>/dev/null; then
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "  + $(t "would append to /etc/iproute2/rt_tables:" \
                            "добавил бы в /etc/iproute2/rt_tables:") ${mark} ${tbl}"
            else
                echo "${mark} ${tbl}" >> /etc/iproute2/rt_tables
            fi
        else
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "  = $(t "already in /etc/iproute2/rt_tables:" \
                            "уже есть в /etc/iproute2/rt_tables:") ${mark} ${tbl}"
            fi
        fi
    done
    return 0
}

write_tun2socks_dropin() {
    log "$(t "Adding ExecStartPost drop-in for tun2socks@.service" \
           "Добавляю ExecStartPost для tun2socks@.service (поднятие tun)")"
    write_file /etc/systemd/system/tun2socks@.service.d/link-up.conf <<'EOF'
[Service]
ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5; do ip link show tun%i >/dev/null 2>&1 && break; sleep 1; done; ip link set tun%i up'
EOF
}

write_macvlan_script() {
    log "$(t "Writing /usr/local/sbin/setup-macvlan.sh" \
           "Создаю /usr/local/sbin/setup-macvlan.sh")"

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
    log "$(t "Writing setup-macvlan.service" "Создаю setup-macvlan.service")"

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
    log "$(t "Writing /usr/local/sbin/setup-routing.sh" \
           "Создаю /usr/local/sbin/setup-routing.sh")"

    local tuns=""
    local xrays=""
    local wait_tun_list=""
    local default_routes=""
    local ip_rules=""
    local mangle_rules=""

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
# Policy routing для multi-WAN tun

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
    log "$(t "Writing setup-routing.service" "Создаю setup-routing.service")"

    local after_list="setup-macvlan.service iptables.service"
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        after_list+=" tun2socks@${code}.service xray@${code}.service"
    done

    write_file /etc/systemd/system/setup-routing.service <<EOF
[Unit]
Description=Policy routing for multi-WAN tun
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
    log "$(t "Reloading systemd and enabling services" \
           "Перезагружаю systemd и включаю сервисы")"
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
    log "$(t "Starting services" "Запускаю сервисы")"
    run systemctl restart setup-macvlan.service

    # xray слушает socks5 на адресах macvlan — стартует после macvlan,
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
        log "$(t "Skipping verify (dry-run)" "Пропуск verify (dry-run)")"
        return 0
    fi

    log "$(t "Verifying result" "Проверяю результат")"

    echo "--- IP addresses ---"
    ip -4 addr show | grep -E 'inet |^[0-9]+:'

    echo "--- ip rule ---"
    ip rule show

    echo "--- mangle PREROUTING ---"
    iptables -t mangle -L PREROUTING -v -n

    echo "--- NAT POSTROUTING ---"
    iptables -t nat -L POSTROUTING -v -n

    echo
    log "$(t "Connectivity check (curl per tun):" \
           "Проверка связности (curl через каждый tun):")"
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

# ---- uninstall ----

uninstall_all() {
    log "$(t "Uninstalling multi-WAN gateway" \
           "Удаляю multi-WAN gateway")"

    # 1. Остановить и отключить инстансные сервисы
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        run systemctl stop    "tun2socks@${code}.service" 2>/dev/null || true
        run systemctl disable "tun2socks@${code}.service" 2>/dev/null || true
        run systemctl stop    "xray@${code}.service"      2>/dev/null || true
        run systemctl disable "xray@${code}.service"      2>/dev/null || true
    done

    # 2. Остановить и отключить собственные юниты
    run systemctl stop    setup-routing.service 2>/dev/null || true
    run systemctl stop    setup-macvlan.service 2>/dev/null || true
    run systemctl disable setup-routing.service 2>/dev/null || true
    run systemctl disable setup-macvlan.service 2>/dev/null || true

    # 3. Чистим iptables
    log "$(t "Clearing iptables rules" "Чищу правила iptables")"
    run iptables -t mangle -F PREROUTING 2>/dev/null || true
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        # Удаляем NAT-правило, если есть (повторяем пока -D возвращает 0)
        while iptables -t nat -C POSTROUTING -o "tun${code}" -j MASQUERADE 2>/dev/null; do
            run iptables -t nat -D POSTROUTING -o "tun${code}" -j MASQUERADE
        done
    done

    # 4. Снять ip rule
    log "$(t "Removing ip rules and routing tables" \
           "Удаляю ip rule и таблицы маршрутов")"
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local tbl="via_${code}"
        # del в цикле — вдруг правило добавлено несколько раз
        while ip rule show | grep -qE "fwmark 0x$(printf '%x' "$mark")\b.*lookup ${tbl}"; do
            run ip rule del fwmark "$mark" table "$tbl" 2>/dev/null || break
        done
        run ip route flush table "$tbl" 2>/dev/null || true
    done

    # 5. Удалить macvlan-интерфейсы
    log "$(t "Removing macvlan interfaces" "Удаляю macvlan-интерфейсы")"
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        if ip link show "xray-${code}" &>/dev/null; then
            run ip link del "xray-${code}" 2>/dev/null || true
        fi
    done

    # 6. Удалить файлы
    log "$(t "Removing scripts, units and sysctl files" \
           "Удаляю скрипты, юниты и sysctl-файлы")"
    remove_file /usr/local/sbin/setup-macvlan.sh
    remove_file /usr/local/sbin/setup-routing.sh
    remove_file /etc/systemd/system/setup-macvlan.service
    remove_file /etc/systemd/system/setup-routing.service
    remove_file /etc/systemd/system/tun2socks@.service.d/link-up.conf
    if [ "$DRY_RUN" -eq 0 ]; then
        rmdir /etc/systemd/system/tun2socks@.service.d 2>/dev/null || true
    fi
    remove_file /etc/sysctl.d/99-arp.conf
    remove_file /etc/sysctl.d/99-forward.conf

    # 7. Удалить записи из /etc/iproute2/rt_tables
    log "$(t "Cleaning /etc/iproute2/rt_tables" \
           "Чищу /etc/iproute2/rt_tables")"
    for item in "${COUNTRIES[@]}"; do
        local code="${item%%:*}"
        local mark="${item##*:}"
        local tbl="via_${code}"
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "  + $(t "would remove line:" "удалил бы строку:") ${mark} ${tbl}"
        else
            sed -i -E "/^[[:space:]]*${mark}[[:space:]]+${tbl}[[:space:]]*$/d" \
                /etc/iproute2/rt_tables 2>/dev/null || true
        fi
    done

    # 8. Сохранить пустые iptables (persist)
    if [ -d /etc/sysconfig ] && [ "$DRY_RUN" -eq 0 ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    fi

    # 9. Перезагрузка systemd
    run systemctl daemon-reload

    echo
    log "$(t "Uninstall done. User configs kept: ${XRAY_CONFDIR}/*.json, ${TUN2SOCKS_CONFDIR}/*.yaml, xray/tun2socks binaries." \
           "Удаление завершено. Сохранены: ${XRAY_CONFDIR}/*.json, ${TUN2SOCKS_CONFDIR}/*.yaml, бинарники xray/tun2socks.")"
}

# ---- main ----

main() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "===== $(t "DRY RUN: no real changes will be made" "DRY RUN: команды и файлы выводятся, реальных изменений не будет") ====="
        echo
    fi

    require_root

    if [ "$UNINSTALL" -eq 1 ]; then
        uninstall_all
        echo
        if [ "$DRY_RUN" -eq 1 ]; then
            log "$(t "Dry-run finished. Re-run without --dry-run to apply." \
                   "Dry-run завершён. Запусти без --dry-run, чтобы применить.")"
        fi
        return 0
    fi

    require_parent_if
    require_xray
    require_xray_units
    require_tun2socks
    require_configs

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
        log "$(t "Dry-run finished. Re-run without --dry-run to apply." \
               "Dry-run завершён. Запусти без --dry-run, чтобы применить изменения.")"
    else
        log "$(t "Done. After container reboot everything comes up automatically." \
               "Готово. После перезагрузки контейнера вся конфигурация поднимется автоматически.")"
    fi
}

main "$@"
