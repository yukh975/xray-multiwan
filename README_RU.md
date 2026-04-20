[🇬🇧 English](README.md) | **🇷🇺 Русский**

# Multi-country gateway на одном контейнере

[![Shell](https://img.shields.io/badge/shell-bash-121011?logo=gnu-bash&logoColor=white)](#)
[![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20ALT-FCC624?logo=linux&logoColor=black)](#)
[![Proxmox](https://img.shields.io/badge/Proxmox-LXC-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com/)
[![Xray](https://img.shields.io/badge/xray--core-VLESS-blue)](https://github.com/XTLS/Xray-core)
[![tun2socks](https://img.shields.io/badge/tun2socks-xjasonlyu-green)](https://github.com/xjasonlyu/tun2socks)
[![Idempotent](https://img.shields.io/badge/install-idempotent-success)](#повторный-запуск-installsh-поверх-рабочей-системы)

Контейнер Proxmox с несколькими xray+tun2socks (по одной связке на страну). Клиент выбирает страну, указывая разные IP в качестве шлюза: `.232` → Франция, `.233` → Швеция, `.234` → Финляндия.

## Архитектура

```
Клиент (192.168.0.245)
  │
  │ gateway = 192.168.0.232 (или .233, .234)
  ↓
┌─────────────────────────────────────────────────┐
│ Контейнер (ALT Linux / Debian)                  │
│                                                 │
│ global (192.168.0.230) ─ physical veth          │
│   ├─ xray-fr (192.168.0.232) ─ macvlan          │
│   │     └→ xray@fr socks5 :10808 ─→ tunfr ─→ FR │
│   ├─ xray-se (192.168.0.233) ─ macvlan          │
│   │     └→ xray@se socks5 :10808 ─→ tunse ─→ SE │
│   └─ xray-fi (192.168.0.234) ─ macvlan          │
│         └→ xray@fi socks5 :10808 ─→ tunfi ─→ FI │
└─────────────────────────────────────────────────┘
```

**Как работает различение шлюзов:**

1. На `global` создаются три macvlan-подинтерфейса с отдельными MAC'ами — каждому свой IP.
2. Клиент, указав шлюз `.232`, через ARP получает MAC `xray-fr` — и кадры летят именно на этот интерфейс.
3. `iptables -t mangle` по `-i xray-fr` ставит fwmark 100.
4. `ip rule fwmark 100` отправляет пакет в таблицу `via_fr`.
5. В таблице — default через `tunfr`.
6. tun2socks забирает пакет, передаёт в xray socks5, xray через VLESS выпускает в интернет во Франции.
7. На выходе из tun — `MASQUERADE`, чтобы внешняя сторона видела source IP контейнера, а не клиента.

## Предварительные требования

1. **Контейнер Proxmox** с одним интерфейсом (`global`), привилегированный (нужен для macvlan и TUN).
2. **Проброс TUN** на хосте PVE — в `/etc/pve/lxc/<VMID>.conf`:
   ```
   lxc.cgroup2.devices.allow: c 10:200 rwm
   lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
   ```
3. **xray** установлен и оформлен как systemd-шаблон `xray@.service`, по одному инстансу на страну:
   - `xray@fr` слушает socks5 на `192.168.0.232:10808`
   - `xray@se` слушает socks5 на `192.168.0.233:10808`
   - `xray@fi` слушает socks5 на `192.168.0.234:10808`
4. **tun2socks** (xjasonlyu/tun2socks) установлен как `/usr/bin/tun2socks`, есть systemd-шаблон `/usr/lib/systemd/system/tun2socks@.service`.
5. **Конфиги tun2socks** в `/etc/tun2socks/<n>.yaml`, где `<n>` = `fr`, `se`, `fi`. Обязательные поля:
   - `device: tun://tun<n>` (tun2socks сам создаст tun-устройство с этим именем)
   - `proxy: socks5://192.168.0.<IP>:10808` — указывает на свой xray
6. **iptables-service** (обычный sysvinit-init) с файлом `/etc/sysconfig/iptables`. На ALT он ставится из коробки, на Debian может потребоваться `iptables-persistent`.

## Пошаговая установка

### Шаг 1. Поднять три IP на `global` через macvlan

Каждый macvlan получит свой MAC — это критично, чтобы ARP-ответы клиенту различались.

```bash
# Создать macvlan-подинтерфейсы:
ip link add link global name xray-fr type macvlan mode bridge
ip link add link global name xray-se type macvlan mode bridge
ip link add link global name xray-fi type macvlan mode bridge

# Назначить IP:
ip addr add 192.168.0.232/24 dev xray-fr
ip addr add 192.168.0.233/24 dev xray-se
ip addr add 192.168.0.234/24 dev xray-fi

# Поднять линки:
ip link set xray-fr up
ip link set xray-se up
ip link set xray-fi up

# Проверка:
ip -4 addr show
ip link show | grep ether
```

### Шаг 2. ARP-настройки

Без этого интерфейс ответит ARP не только за свой IP, но и за чужие — MAC'и на стороне клиента совпадут, и различить шлюзы будет невозможно.

```bash
cat > /etc/sysctl.d/99-arp.conf <<'EOF'
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.conf.default.arp_announce = 2
EOF
sysctl -p /etc/sysctl.d/99-arp.conf
```

### Шаг 3. Форвардинг и rp_filter

```bash
cat > /etc/sysctl.d/99-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl -p /etc/sysctl.d/99-forward.conf
```

`rp_filter=0` нужен, потому что при асимметричном роутинге (пакет пришёл на `xray-fr`, ответ выйдет через `tunfr`) строгая проверка reverse path дропает пакеты.

### Шаг 4. Таблицы маршрутизации

```bash
cat >> /etc/iproute2/rt_tables <<'EOF'
100 via_fr
101 via_se
102 via_fi
EOF
```

### Шаг 5. ExecStartPost для tun2socks (поднятие tun-интерфейсов)

xjasonlyu/tun2socks создаёт tun, но не поднимает его. Добавляем drop-in:

```bash
mkdir -p /etc/systemd/system/tun2socks@.service.d
cat > /etc/systemd/system/tun2socks@.service.d/link-up.conf <<'EOF'
[Service]
ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5; do ip link show tun%i >/dev/null 2>&1 && break; sleep 1; done; ip link set tun%i up'
EOF
systemctl daemon-reload
```

### Шаг 6. Скрипт поднятия macvlan + systemd-юнит

Чтобы macvlan поднимался при каждой загрузке:

```bash
cat > /usr/local/sbin/setup-macvlan.sh <<'EOF'
#!/bin/bash
setup_iface() {
    local name="$1"
    local addr="$2"
    ip link show "$name" &>/dev/null || \
        ip link add link global name "$name" type macvlan mode bridge
    if ! ip -4 -o addr show dev "$name" | awk '{print $4}' | grep -qx "${addr}/24"; then
        ip addr add "${addr}/24" dev "$name" 2>/dev/null || true
    fi
    ip link set "$name" up
}
setup_iface xray-fr 192.168.0.232
setup_iface xray-se 192.168.0.233
setup_iface xray-fi 192.168.0.234
EOF
chmod +x /usr/local/sbin/setup-macvlan.sh

cat > /etc/systemd/system/setup-macvlan.service <<'EOF'
[Unit]
Description=Setup macvlan subinterfaces on global
After=network.target
Before=tun2socks@fr.service tun2socks@se.service tun2socks@fi.service xray@fr.service xray@se.service xray@fi.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-macvlan.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now setup-macvlan.service
```

### Шаг 7. Скрипт policy routing + systemd-юнит

```bash
cat > /usr/local/sbin/setup-routing.sh <<'EOF'
#!/bin/bash
# Ждём tun-интерфейсы (до 30 сек)
for t in tunfr tunse tunfi; do
    for i in $(seq 1 30); do
        ip link show "$t" &>/dev/null && break
        sleep 1
    done
done

# Default-маршруты в таблицах
ip route replace default dev tunfr table via_fr
ip route replace default dev tunse table via_se
ip route replace default dev tunfi table via_fi

# ip rule: fwmark → таблица (с предварительным удалением, чтобы не плодить дубли)
for mark_table in "100:via_fr" "101:via_se" "102:via_fi"; do
    mark="${mark_table%%:*}"
    table="${mark_table##*:}"
    ip rule del fwmark "$mark" table "$table" 2>/dev/null
    ip rule add fwmark "$mark" table "$table"
done

# Маркировка по входному интерфейсу
iptables -t mangle -F PREROUTING
iptables -t mangle -A PREROUTING -i xray-fr -j MARK --set-mark 100
iptables -t mangle -A PREROUTING -i xray-se -j MARK --set-mark 101
iptables -t mangle -A PREROUTING -i xray-fi -j MARK --set-mark 102

# NAT на выходе
for t in tunfr tunse tunfi; do
    iptables -t nat -C POSTROUTING -o "$t" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$t" -j MASQUERADE
done

# rp_filter=0 для всех задействованных интерфейсов
for i in xray-fr xray-se xray-fi tunfr tunse tunfi global; do
    sysctl -w net.ipv4.conf.$i.rp_filter=0 >/dev/null 2>&1 || true
done

ip route flush cache

# Сохранить iptables для persistence (на ALT/RHEL-совместимых)
if [ -d /etc/sysconfig ]; then
    iptables-save > /etc/sysconfig/iptables
fi
EOF
chmod +x /usr/local/sbin/setup-routing.sh

cat > /etc/systemd/system/setup-routing.service <<'EOF'
[Unit]
Description=Policy routing for multi-country tun
After=setup-macvlan.service iptables.service tun2socks@fr.service tun2socks@se.service tun2socks@fi.service xray@fr.service xray@se.service xray@fi.service
Wants=setup-macvlan.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable setup-routing.service
```

### Шаг 8. Включить xray и tun2socks сервисы

Важен порядок: xray должен стартовать **до** tun2socks, потому что tun2socks подключается к socks5 xray при запуске. Systemd с учётом `Before=`/`After=` это обеспечит, но при ручном рестарте — сначала xray, потом tun2socks.

```bash
systemctl enable --now xray@fr xray@se xray@fi
systemctl enable --now tun2socks@fr tun2socks@se tun2socks@fi
```

### Шаг 9. Запустить роутинг

```bash
systemctl start setup-routing.service
```

### Шаг 10. Проверка

С самого контейнера (обход клиентской части):

```bash
curl --interface tunfr -s -m 10 https://api.ipify.org; echo
curl --interface tunse -s -m 10 https://api.ipify.org; echo
curl --interface tunfi -s -m 10 https://api.ipify.org; echo
```

Должны вернуться три **разных** IP — exit-nodes соответствующих стран.

С клиента (Windows):

```cmd
route delete 0.0.0.0
route add 0.0.0.0 mask 0.0.0.0 192.168.0.232
arp -d *
```

Открой `https://api.ipify.org` в браузере — должен показать французский IP. Меняй шлюз на `.233` / `.234` — получишь шведский / финский.

**Важно:** ICMP (`ping`, `tracert`) через VLESS **не работает**. Проверять исключительно по TCP (HTTP/HTTPS).

## Диагностика

Куда смотреть, если что-то не работает:

```bash
# Все ли macvlan/tun подняты:
ip -4 addr show
ip link show

# Правила и таблицы:
ip rule show
ip route show table via_fr
ip route show table via_se
ip route show table via_fi

# Счётчики mangle — растут при клиентском трафике:
iptables -t mangle -L PREROUTING -v -n

# Счётчики NAT:
iptables -t nat -L POSTROUTING -v -n

# Статус сервисов:
systemctl status setup-macvlan setup-routing
systemctl status xray@fr xray@se xray@fi
systemctl status tun2socks@fr tun2socks@se tun2socks@fi

# Куда реально идут пакеты:
tcpdump -ni xray-fr -c 10 'host <IP-клиента> and not port 22'
tcpdump -ni tunfr  -c 10 'host <IP-клиента> and not port 22'
```

Либо скриптом:

```bash
bash diag.sh          # полный отчёт
bash diag.sh --quiet  # только итоговая сводка
```

## Повторный запуск install.sh поверх рабочей системы

`install.sh` идемпотентен — его можно безопасно накатывать поверх уже работающей конфигурации (например, когда меняется список стран или нужно актуализировать версию).

**Что перезаписывается своим же содержимым (безопасно):**

- `/etc/sysctl.d/99-arp.conf`, `/etc/sysctl.d/99-forward.conf`
- `/etc/systemd/system/tun2socks@.service.d/link-up.conf`
- `/usr/local/sbin/setup-macvlan.sh`, `/usr/local/sbin/setup-routing.sh`
- `/etc/systemd/system/setup-macvlan.service`, `/etc/systemd/system/setup-routing.service`

**Идемпотентно по логике:**

- `/etc/iproute2/rt_tables` — строки добавляются только если их ещё нет (через `grep -q`).
- macvlan-интерфейсы создаются только если отсутствуют; IP добавляется, только если его нет.
- iptables mangle — `iptables -t mangle -F PREROUTING` очищает старое, потом ставятся актуальные правила.
- iptables NAT — через `-C ... || -A ...`.
- `ip rule` — `del ... 2>/dev/null; add ...` (снимаем возможный старый вариант, ставим свежий).
- `systemctl enable` для всех сервисов — если уже enabled, это no-op.

**Что скрипт НЕ трогает:**

- Конфиги `/etc/tun2socks/*.yaml`.
- Конфиги xray.
- `/etc/sysconfig/iptables` — он перезапишется в самом конце скриптом `setup-routing.sh` через `iptables-save`.

**Единственный заметный эффект:**

Все сервисы будут `restart`'нуты (macvlan → xray@* → tun2socks@* → setup-routing). **Будет кратковременный разрыв клиентских соединений на ~2–5 секунд.** Если критично — запускай в окно обслуживания.

**Как запустить повторно:**

```bash
bash install.sh
```

**Как проверить, что именно будет сделано, без реального запуска:**

```bash
bash install.sh --dry-run
```

В этом режиме скрипт показывает все команды, которые он выполнил бы, и содержимое всех файлов, которые он создал бы, — но реальных изменений в системе не делает. Проверки предусловий (наличие интерфейса, tun2socks, конфигов, xray-юнитов) выполняются как обычно — dry-run имеет смысл запускать там, где система уже готова.

Если нужно поменять список стран — отредактируй массив `COUNTRIES` в начале скрипта и запусти заново. Скрипт перенастроит всё, включая удаление правил для стран, которых больше нет, только для тех артефактов, которые он контролирует (скрипты, юниты, mangle-правила — они полностью перегенерируются).

**Что НЕ удалится автоматически при уменьшении списка стран:**

- Старые macvlan-интерфейсы (нужно `ip link del xray-<код>` вручную).
- Старые записи в `/etc/iproute2/rt_tables` (безвредны, но можно почистить).
- Старые включённые сервисы `xray@<код>` и `tun2socks@<код>` — их нужно `systemctl disable --now` вручную.

## Добавление новой страны

Чтобы добавить, например, Нидерланды (код `nl`, IP `.235`, tun `tunnl`, xray socks5 на `.235:10808`):

1. Подготовить конфиг xray для `xray@nl` и конфиг `/etc/tun2socks/nl.yaml`.
2. Добавить `103 via_nl` в `/etc/iproute2/rt_tables`.
3. В `/usr/local/sbin/setup-macvlan.sh` добавить `setup_iface xray-nl 192.168.0.235`.
4. В `/usr/local/sbin/setup-routing.sh`:
   - Добавить `ip route replace default dev tunnl table via_nl` в блоке default'ов.
   - Добавить `"103:via_nl"` в цикл `ip rule`.
   - Добавить `iptables -t mangle -A PREROUTING -i xray-nl -j MARK --set-mark 103`.
   - Добавить `tunnl` и `xray-nl` в циклы NAT и rp_filter.
5. В `setup-macvlan.service` добавить `tun2socks@nl.service xray@nl.service` в `Before=`.
6. В `setup-routing.service` добавить `tun2socks@nl.service xray@nl.service` в `After=`.
7. Включить и запустить: `systemctl enable --now xray@nl tun2socks@nl`, потом `systemctl restart setup-routing.service`.

Либо проще: отредактировать массив `COUNTRIES` в `install.sh` и запустить его заново — он идемпотентен и перенастроит всё с учётом новой страны.

## Миграция на новую адресацию

Скрипт `migrate.sh` переводит всю установку на новую подсеть (например, при смене IP-плана провайдером). Параметры новой адресации задаются в блоке `NEW_*` в начале скрипта.

Что делает:

1. Проверяет, что `global` уже в новой подсети (если нет — подсказывает команду `pct set` для PVE).
2. Делает бэкап конфигов в `/root/migrate-backup-<timestamp>/`.
3. Меняет `listen` в xray-конфигах и `proxy: socks5://...` в tun2socks-конфигах.
4. Обновляет массив `COUNTRIES` и `NETMASK_BITS` в `install.sh` и `diag.sh`.
5. Снимает старые IP с macvlan-интерфейсов.
6. Перезапускает xray, запускает `install.sh` (он перегенерирует всё), прогоняет `diag.sh`.

Сухой прогон без изменений:

```bash
bash migrate.sh --dry-run
```
