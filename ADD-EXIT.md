# Добавление нового выхода (exit) в xray-multiwan

Пошаговая инструкция на примере добавления выхода `pl`
(IP `172.31.254.25`, интерфейс `xray-pl`/`tunpl`, fwmark `104`,
upstream `pl-war.netadm.pro`).

Подставляй свои значения:
- `<code>`      — короткое имя выхода (pl)
- `<IP>`        — адрес macvlan в подсети PARENT_IF (172.31.254.25)
- `<fwmark>`    — следующая свободная метка (100, 101, ... → 104)
- `<upstream>`  — домен ноды на принимающей стороне (pl-war.netadm.pro)
- `<tun>`       — имя tun-устройства (tunpl)

Проект предполагается в `/opt/xray-multiwan`.

---

## Перед началом: собрать данные

Текущие интерфейсы и какой номер fwmark/IP свободен:

```bash
ip -4 -br addr show | grep xray-
grep via_ /etc/iproute2/rt_tables
sed -n '/^EXITS=/,/^)/p' /opt/xray-multiwan/config.sh
```

Определи:
- свободный IP в подсети (по порядку после существующих)
- свободный fwmark (по порядку: fr=100, se=101, fi=102, ru=103 → pl=104)
- имя parent-интерфейса (на этом хосте — `global`, маска `/28`)

UUID и WS-path берутся из настроек ноды на принимающей стороне
(панель 3x-ui на мастере). Они уникальны для каждой ноды.

---

## Шаг 1. Конфиг xray для нового выхода

Скопировать с рабочего выхода (например fr) и поменять поля.
Если готовишь вручную — структура должна быть как у fr.json,
с заменами:
- `inbounds[].listen`           → `<IP>`           (172.31.254.25)
- `outbounds[].tag`             → `<code>-...`     (pl-war)
- `outbounds[].settings.vnext[].address` → `<upstream>` (pl-war.netadm.pro)
- `outbounds[].settings.vnext[].users[].id` → UUID ноды
- `streamSettings.wsSettings.path` → WS-path ноды
- `streamSettings.wsSettings.headers.Host` → `<upstream>`
- `streamSettings.tlsSettings.serverName`  → `<upstream>`
- `routing.rules[].outboundTag` (последнее правило) → `<code>-...`
- лог-файлы (`<code>-access.log`, `<code>-error.log`)

Файл: `/etc/xray/<code>.json`

Проверить ключевые поля:

```bash
grep -E '"listen"|"address"|"id"|"path"|"Host"|"serverName"|"tag"' /etc/xray/pl.json
```

---

## Шаг 2. Конфиг tun2socks для нового выхода

```bash
cat > /etc/tun2socks/pl.yaml <<'EOF'
proxy: socks5://172.31.254.25:10808
device: tunpl
mtu: 1500
loglevel: info
EOF
```

(socks-адрес = `<IP>:10808` — это inbound нового xray; device = `<tun>`)

---

## Шаг 3. Добавить таблицу маршрутизации

```bash
# проверить, что номер свободен:
grep -E '^\s*104\s' /etc/iproute2/rt_tables && echo "ЗАНЯТ" || echo "свободен"
# добавить:
echo "104 via_pl" >> /etc/iproute2/rt_tables
grep via_ /etc/iproute2/rt_tables
```

---

## Шаг 4. Добавить выход в config.sh

```bash
cd /opt/xray-multiwan
cp config.sh config.sh.bak.$(date +%H%M%S)

# добавить строку pl после ru (формат: code:IP:fwmark):
sed -i 's#    "ru:172.31.254.24:103"#    "ru:172.31.254.24:103"\n    "pl:172.31.254.25:104"#' config.sh

sed -n '/^EXITS=/,/^)/p' config.sh
bash -n config.sh && echo "Syntax OK"
```

Примечание: на этом хосте EXITS без MAC (формат из 3 полей).
Если на хосте используется фиксированный MAC (4-е поле) — добавляй
с MAC: `"pl:172.31.254.25:104:02:xx:xx:xx:xx:xx"`.

---

## Шаг 5. Проверить предусловия

```bash
ls -l /etc/xray/pl.json /etc/tun2socks/pl.yaml
grep via_pl /etc/iproute2/rt_tables
grep 'pl:172.31.254.25' /opt/xray-multiwan/config.sh
```

Всё должно быть на месте.

---

## Шаг 6. Dry-run и установка

```bash
cd /opt/xray-multiwan
# посмотреть, что будет сделано:
bash install.sh --install --dry-run 2>&1 | grep -E 'xray-pl|tunpl|via_pl|172.31.254.25|mark 104'

# применить (ВНИМАНИЕ: короткий разрыв 2-5с на работающих туннелях —
# install.sh рестартует все xray/tun2socks и делает iptables -F mangle):
bash install.sh --install
```

---

## Шаг 7. Проверка

```bash
bash diag.sh
```

Ожидается: новый выход во всех секциях (via_pl, mangle mark 104,
NAT tunpl) и в connectivity-check `xray-pl (socks ...:10808) → <exit-IP>`.
Должно быть `FAIL: 0`.

Предупреждение `! exit IPs repeat` — нормально, если выход через
tier-failover ведёт на ту же ноду, что другой выход.

---

## Откат (если что-то пошло не так)

```bash
# вернуть config.sh:
cp /opt/xray-multiwan/config.sh.bak.<timestamp> /opt/xray-multiwan/config.sh
# убрать таблицу:
sed -i '/^104 via_pl$/d' /etc/iproute2/rt_tables
# остановить и выключить инстансы:
systemctl disable --now xray@pl tun2socks@pl
# убрать конфиги:
rm -f /etc/xray/pl.json /etc/tun2socks/pl.yaml
# перенакатить без pl:
cd /opt/xray-multiwan && bash install.sh --install
```
