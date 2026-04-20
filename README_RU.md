[🇬🇧 English](README.md) | **🇷🇺 Русский**

# Multi-WAN шлюз на xray + tun2socks

[![Shell](https://img.shields.io/badge/shell-bash-121011?logo=gnu-bash&logoColor=white)](#)
[![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20ALT-FCC624?logo=linux&logoColor=black)](#)
[![Proxmox](https://img.shields.io/badge/Proxmox-LXC-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com/)
[![Xray](https://img.shields.io/badge/xray--core-VLESS-blue)](https://github.com/XTLS/Xray-core)
[![tun2socks](https://img.shields.io/badge/tun2socks-xjasonlyu-green)](https://github.com/xjasonlyu/tun2socks)
[![Idempotent](https://img.shields.io/badge/install-idempotent-success)](#повторный-запуск-installsh-поверх-рабочей-системы)

Один контейнер Proxmox с несколькими связками xray+tun2socks — по одной на WAN-выход. Клиент выбирает выход, указывая разные IP в качестве шлюза: например, `.232` → первый выход, `.233` → второй, `.234` → третий.

## Архитектура

```
Клиент (192.168.0.100)
  │
  │ gateway = 192.168.0.232 (или .233, .234)
  ↓
┌────────────────────────────────────────────────────────┐
│ Контейнер (ALT Linux / Debian)                         │
│                                                        │
│ eth0 (192.168.0.230) ─ physical veth                   │
│   ├─ xray-wan1 (192.168.0.232) ─ macvlan               │
│   │     └→ xray@wan1 socks5 :10808 ─→ tunwan1 ─→ out   │
│   ├─ xray-wan2 (192.168.0.233) ─ macvlan               │
│   │     └→ xray@wan2 socks5 :10808 ─→ tunwan2 ─→ out   │
│   └─ xray-wan3 (192.168.0.234) ─ macvlan               │
│         └→ xray@wan3 socks5 :10808 ─→ tunwan3 ─→ out   │
└────────────────────────────────────────────────────────┘
```

**Как работает различение шлюзов:**

1. На `eth0` создаются три macvlan-подинтерфейса с отдельными MAC'ами — каждому свой IP.
2. Клиент, указав шлюз `.232`, через ARP получает MAC `xray-wan1` — и кадры летят именно на этот интерфейс.
3. `iptables -t mangle` по `-i xray-wan1` ставит fwmark 100.
4. `ip rule fwmark 100` отправляет пакет в таблицу `via_wan1`.
5. В таблице — default через `tunwan1`.
6. tun2socks забирает пакет, передаёт в xray socks5, xray через VLESS выпускает его на upstream.
7. На выходе из tun — `MASQUERADE`, чтобы внешняя сторона видела source IP контейнера, а не клиента.

## Предварительные требования

1. **Контейнер Proxmox** с одним интерфейсом (`eth0`), привилегированный (нужен для macvlan и TUN).
2. **Проброс TUN** на хосте PVE — в `/etc/pve/lxc/<VMID>.conf`:
   ```
   lxc.cgroup2.devices.allow: c 10:200 rwm
   lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
   ```
3. **xray** установлен и оформлен как systemd-шаблон `xray@.service`, по одному инстансу на выход:
   - `xray@wan1` слушает socks5 на `192.168.0.232:10808`
   - `xray@wan2` слушает socks5 на `192.168.0.233:10808`
   - `xray@wan3` слушает socks5 на `192.168.0.234:10808`
4. **tun2socks** (xjasonlyu/tun2socks) установлен как `/usr/bin/tun2socks`, есть systemd-шаблон `/usr/lib/systemd/system/tun2socks@.service`.
5. **Конфиги tun2socks** в `/etc/tun2socks/<n>.yaml`, где `<n>` = `wan1`, `wan2`, `wan3`. Обязательные поля:
   - `device: tun://tun<n>` (tun2socks сам создаст tun-устройство с этим именем)
   - `proxy: socks5://192.168.0.<IP>:10808` — указывает на свой xray
6. **iptables-service** (обычный sysvinit-init) с файлом `/etc/sysconfig/iptables`. На ALT он ставится из коробки, на Debian может потребоваться `iptables-persistent`.

## Перед первым запуском: правим `config.sh`

Все настройки живут в [`config.sh`](config.sh), который `install.sh`, `diag.sh` и `migrate.sh` читают через `source`. Правится в одном месте:

```bash
PARENT_IF="eth0"                      # родительский интерфейс (e.g. eth0)
NETMASK_BITS="24"                       # длина маски подсети

COUNTRIES=(
    "wan1:192.168.0.232:100"              # код:IP:fwmark
    "wan2:192.168.0.233:101"
    "wan3:192.168.0.234:102"
)
```

Каждая запись в `COUNTRIES` — это WAN-выход: `код` совпадает с именем `/etc/tun2socks/<код>.yaml`, `xray@<код>.service`, `tun<код>` и `xray-<код>`; `IP` — адрес macvlan, который клиент ставит как шлюз по умолчанию; `fwmark` — любое уникальное число (по соглашению 100+).

## Удаление

```bash
bash install.sh --uninstall
```

Удаляет всё, что создаёт `install.sh` — сервисы, скрипты, systemd-юниты, правила iptables, записи `ip rule`, macvlan-интерфейсы, sysctl-файлы. Пользовательские конфиги (`/etc/xray/*.json`, `/etc/tun2socks/*.yaml`) и бинари сохраняются.

## Пошаговая установка

### Шаг 1. Поднять три IP на `eth0` через macvlan

Каждый macvlan получит свой MAC — это критично, чтобы ARP-ответы клиенту различались.

```bash
# Создать macvlan-подинтерфейсы:
ip link add link eth0 name xray-wan1 type macvlan mode bridge
ip link add link eth0 name xray-wan2 type macvlan mode bridge
ip link add link eth0 name xray-wan3 type macvlan mode bridge

# Назначить IP:
ip addr add 192.168.0.232/24 dev xray-wan1
ip addr add 192.168.0.233/24 dev xray-wan2
ip addr add 192.168.0.234/24 dev xray-wan3

# Поднять линки:
ip link set xray-wan1 up
ip link set xray-wan2 up
ip link set xray-wan3 up

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

`rp_filter=0` нужен, потому что при асимметричном роутинге (пакет пришёл на `xray-wan1`, ответ выйдет через `tunwan1`) строгая проверка reverse path дропает пакеты.

### Шаг 4. Таблицы маршрутизации

```bash
cat >> /etc/iproute2/rt_tables <<'EOF'
100 via_wan1
101 via_wan2
102 via_wan3
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
        ip link add link eth0 name "$name" type macvlan mode bridge
    if ! ip -4 -o addr show dev "$name" | awk '{print $4}' | grep -qx "${addr}/24"; then
        ip addr add "${addr}/24" dev "$name" 2>/dev/null || true
    fi
    ip link set "$name" up
}
setup_iface xray-wan1 192.168.0.232
setup_iface xray-wan2 192.168.0.233
setup_iface xray-wan3 192.168.0.234
EOF
chmod +x /usr/local/sbin/setup-macvlan.sh

cat > /etc/systemd/system/setup-macvlan.service <<'EOF'
[Unit]
Description=Setup macvlan subinterfaces on eth0
After=network.target
Before=tun2socks@wan1.service tun2socks@wan2.service tun2socks@wan3.service xray@wan1.service xray@wan2.service xray@wan3.service

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
for t in tunwan1 tunwan2 tunwan3; do
    for i in $(seq 1 30); do
        ip link show "$t" &>/dev/null && break
        sleep 1
    done
done

# Default-маршруты в таблицах
ip route replace default dev tunwan1 table via_wan1
ip route replace default dev tunwan2 table via_wan2
ip route replace default dev tunwan3 table via_wan3

# ip rule: fwmark → таблица (с предварительным удалением, чтобы не плодить дубли)
for mark_table in "100:via_wan1" "101:via_wan2" "102:via_wan3"; do
    mark="${mark_table%%:*}"
    table="${mark_table##*:}"
    ip rule del fwmark "$mark" table "$table" 2>/dev/null
    ip rule add fwmark "$mark" table "$table"
done

# Маркировка по входному интерфейсу
iptables -t mangle -F PREROUTING
iptables -t mangle -A PREROUTING -i xray-wan1 -j MARK --set-mark 100
iptables -t mangle -A PREROUTING -i xray-wan2 -j MARK --set-mark 101
iptables -t mangle -A PREROUTING -i xray-wan3 -j MARK --set-mark 102

# NAT на выходе
for t in tunwan1 tunwan2 tunwan3; do
    iptables -t nat -C POSTROUTING -o "$t" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$t" -j MASQUERADE
done

# rp_filter=0 для всех задействованных интерфейсов
for i in xray-wan1 xray-wan2 xray-wan3 tunwan1 tunwan2 tunwan3 eth0; do
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
Description=Policy routing for multi-WAN tun
After=setup-macvlan.service iptables.service tun2socks@wan1.service tun2socks@wan2.service tun2socks@wan3.service xray@wan1.service xray@wan2.service xray@wan3.service
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
systemctl enable --now xray@wan1 xray@wan2 xray@wan3
systemctl enable --now tun2socks@wan1 tun2socks@wan2 tun2socks@wan3
```

### Шаг 9. Запустить роутинг

```bash
systemctl start setup-routing.service
```

### Шаг 10. Проверка

С самого контейнера (обход клиентской части):

```bash
curl --interface tunwan1 -s -m 10 https://api.ipify.org; echo
curl --interface tunwan2 -s -m 10 https://api.ipify.org; echo
curl --interface tunwan3 -s -m 10 https://api.ipify.org; echo
```

Должны вернуться три **разных** IP — upstream-выходы соответствующих WAN.

С клиента (Windows):

```cmd
route delete 0.0.0.0
route add 0.0.0.0 mask 0.0.0.0 192.168.0.232
arp -d *
```

Открой `https://api.ipify.org` в браузере — должен показать IP первого upstream'а. Меняй шлюз на `.233` / `.234` — получишь IP второго и третьего.

**Важно:** ICMP (`ping`, `tracert`) через VLESS **не работает**. Проверять исключительно по TCP (HTTP/HTTPS).

## Диагностика

### diag.sh

Самый быстрый способ проверить живую систему. `diag.sh` проходит по всем слоям схемы и печатает по строке на каждую проверку: зелёная ✓ / жёлтая ! / красная ✗, плюс итоговая сводка.

```bash
bash diag.sh          # полный отчёт
bash diag.sh --quiet  # только итоговая сводка
```

Exit code: `0` — всё зелёное, `1` — есть падения. Все скрипты читают один и тот же `config.sh`, поэтому то, что проверяется, автоматически совпадает с тем, что установлено.

Что проверяет:

- **sysctl** — `ip_forward`, `rp_filter`, `arp_ignore`, `arp_announce`, плюс наличие `/etc/sysctl.d/99-*.conf` (чтобы настройки пережили ребут).
- **Таблицы маршрутизации** — все `via_<код>` присутствуют в `/etc/iproute2/rt_tables`.
- **Скрипты** — `/usr/local/sbin/setup-macvlan.sh` и `/usr/local/sbin/setup-routing.sh` существуют и исполняемые.
- **systemd-юниты** — `setup-macvlan.service`, `setup-routing.service`, `xray@<код>`, `tun2socks@<код>` enabled и active, плюс drop-in `link-up.conf` для `tun2socks@`.
- **Интерфейсы** — родительский (`eth0`) есть; каждый `xray-<код>` — macvlan, имеет свой MAC (отличается от родителя — критично для ARP), нужный IP, `UP`, `rp_filter=0`; каждый `tun<код>` поднят, `rp_filter=0`.
- **ip rule** — правило fwmark → таблица присутствует для каждого выхода.
- **Маршруты в таблицах** — у `via_<код>` есть default через нужный `tun<код>`.
- **iptables** — правила mangle `-i xray-<код> → MARK` и NAT `-o tun<код> → MASQUERADE` на месте.
- **Реальная связность** — `curl --interface tun<код> https://api.ipify.org` для каждого выхода + проверка, что все exit-IP разные.

### Ручные команды

Если `diag.sh` мало — команды, которые он за кулисами и проверяет:

```bash
# Все ли macvlan/tun подняты:
ip -4 addr show
ip link show

# Правила и таблицы:
ip rule show
ip route show table via_wan1
ip route show table via_wan2
ip route show table via_wan3

# Счётчики mangle — растут при клиентском трафике:
iptables -t mangle -L PREROUTING -v -n

# Счётчики NAT:
iptables -t nat -L POSTROUTING -v -n

# Статус сервисов:
systemctl status setup-macvlan setup-routing
systemctl status xray@wan1 xray@wan2 xray@wan3
systemctl status tun2socks@wan1 tun2socks@wan2 tun2socks@wan3

# Куда реально идут пакеты:
tcpdump -ni xray-wan1 -c 10 'host <IP-клиента> and not port 22'
tcpdump -ni tunwan1  -c 10 'host <IP-клиента> and not port 22'
```

## Повторный запуск install.sh поверх рабочей системы

`install.sh` идемпотентен — его можно безопасно накатывать поверх уже работающей конфигурации (например, когда меняется список выходов или нужно актуализировать версию).

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
bash install.sh --install
```

Запуск `bash install.sh` без аргументов показывает справку.

**Как проверить, что именно будет сделано, без реального запуска:**

```bash
bash install.sh --install --dry-run
```

В этом режиме скрипт показывает все команды, которые он выполнил бы, и содержимое всех файлов, которые он создал бы, — но реальных изменений в системе не делает. Проверки предусловий (наличие интерфейса, tun2socks, конфигов, xray-юнитов) выполняются как обычно — dry-run имеет смысл запускать там, где система уже готова.

Если нужно поменять список выходов — отредактируй массив `COUNTRIES` в [`config.sh`](config.sh) и запусти `install.sh` заново. Скрипт перенастроит всё, включая удаление правил для выходов, которых больше нет, только для тех артефактов, которые он контролирует (скрипты, юниты, mangle-правила — они полностью перегенерируются). Имя массива осталось `COUNTRIES` исторически; концептуально это WAN-выходы.

**Что НЕ удалится автоматически при уменьшении списка выходов:**

- Старые macvlan-интерфейсы (нужно `ip link del xray-<код>` вручную).
- Старые записи в `/etc/iproute2/rt_tables` (безвредны, но можно почистить).
- Старые включённые сервисы `xray@<код>` и `tun2socks@<код>` — их нужно `systemctl disable --now` вручную.

## Добавление нового выхода

Чтобы добавить четвёртый выход (код `wan4`, IP `.235`, tun `tunwan4`, xray socks5 на `.235:10808`):

1. Подготовить конфиг xray для `xray@wan4` и конфиг `/etc/tun2socks/nl.yaml`.
2. Добавить `103 via_wan4` в `/etc/iproute2/rt_tables`.
3. В `/usr/local/sbin/setup-macvlan.sh` добавить `setup_iface xray-wan4 192.168.0.235`.
4. В `/usr/local/sbin/setup-routing.sh`:
   - Добавить `ip route replace default dev tunwan4 table via_wan4` в блоке default'ов.
   - Добавить `"103:via_wan4"` в цикл `ip rule`.
   - Добавить `iptables -t mangle -A PREROUTING -i xray-wan4 -j MARK --set-mark 103`.
   - Добавить `tunwan4` и `xray-wan4` в циклы NAT и rp_filter.
5. В `setup-macvlan.service` добавить `tun2socks@wan4.service xray@wan4.service` в `Before=`.
6. В `setup-routing.service` добавить `tun2socks@wan4.service xray@wan4.service` в `After=`.
7. Включить и запустить: `systemctl enable --now xray@wan4 tun2socks@wan4`, потом `systemctl restart setup-routing.service`.

Либо проще: добавить новый выход в массив `COUNTRIES` в [`config.sh`](config.sh) и запустить `install.sh` заново — он идемпотентен и перенастроит всё с учётом нового выхода.

## Миграция на новую адресацию

`migrate.sh` — для случая, когда меняется вся подсеть: провайдер переделал IP-план, или контейнер переезжает на другой бридж с другим диапазоном. Скрипт за один проход переписывает xray-конфиги, tun2socks-конфиги и живые macvlan-интерфейсы.

### Конфигурация

В самом `migrate.sh` править нечего — он читает целевой план из [`config.sh`](config.sh). Отредактируй `config.sh` под новое состояние (новый `NETMASK_BITS` и новые IP выходов в `COUNTRIES`) и запусти `migrate.sh`. Коды выходов и fwmark'и не меняются — только IP и префикс.

### Предусловие: IP на хосте PVE меняется сначала

Скрипт **не** меняет IP на `eth0` сам — он только проверяет, что новый адрес уже прописан. На хосте PVE до запуска:

```bash
pct set <VMID> -net0 name=eth0,bridge=<...>,ip=192.168.1.20/28,gw=<новый-gw>
pct reboot <VMID>
```

Дальше в контейнере:

```bash
bash migrate.sh --dry-run   # посмотреть, что будет сделано
bash migrate.sh             # применить
```

Если `eth0` ещё не в ожидаемой подсети, скрипт останавливается и печатает нужную команду `pct set`.

### Что делает (по порядку)

1. **Проверки** — `eth0` в подсети первого элемента `COUNTRIES` (грубое сравнение по /24); `install.sh`, `diag.sh`, `config.sh` есть по ожидаемым путям (`/root/files/` по умолчанию, переопределяется через `INSTALL_SH=` / `DIAG_SH=` / `CONFIG_SH=`).
2. **Бэкап** — `/etc/xray/<код>.json`, `/etc/tun2socks/<код>.yaml`, `install.sh`, `diag.sh` копируются в `/root/migrate-backup-<YYYYMMDD-HHMMSS>/`.
3. **xray-конфиги** — в каждом `/etc/xray/<код>.json` переписывается поле `"listen"` на новый IP выхода из `config.sh`.
4. **tun2socks-конфиги** — в каждом `/etc/tun2socks/<код>.yaml` переписывается `proxy: socks5://<старый-ip>:10808` на новый.
5. **Снятие старых IP** — любые адреса на `xray-<код>`, которых нет в новом плане, снимаются через `ip addr del`.
6. **Перезапуск xray** — `xray@<код>` перечитывает конфиг с новым `listen`.
7. **Запуск install.sh** — перегенерирует `/usr/local/sbin/setup-*.sh` и systemd-юниты, перезапускает все сервисы, сохраняет iptables.
8. **Запуск diag.sh** — печатает итоговый отчёт, чтобы сразу видеть, что миграция отработала.

### Чего НЕ делает

- **Не** меняет IP на `eth0` (это делается на стороне PVE).
- **Не** чистит устаревшие записи в `/etc/iproute2/rt_tables` (они безвредны — ключ там fwmark).
- **Не** удаляет macvlan-интерфейсы тех выходов, которых больше нет в `COUNTRIES` — снимаются только IP.

### Dry run

```bash
bash migrate.sh --dry-run
```

Печатает каждый файл, который был бы записан, и каждую команду, которая была бы выполнена, — без реальных изменений. Проверки предусловий (parent IP, пути к скриптам) при этом выполняются как обычно.
