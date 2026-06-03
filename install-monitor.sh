#!/bin/bash
#
# install-monitor.sh — установка tunnel-monitor (health-check xray-выходов
# + рестарт упавших + алерты в Telegram) как systemd timer.
#
# Копирует файлы проекта в целевой каталог (по умолчанию /opt/xray-multiwan),
# генерирует systemd-юниты с правильным путём и включает таймер.
#

set -uo pipefail

DEFAULT_DIR="/opt/xray-multiwan"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запускать от root"

read -rp "Каталог установки [${DEFAULT_DIR}]: " TARGET_DIR
TARGET_DIR="${TARGET_DIR:-$DEFAULT_DIR}"

echo "Источник:   $SRC_DIR"
echo "Назначение: $TARGET_DIR"

if [ "$SRC_DIR" != "$TARGET_DIR" ]; then
    mkdir -p "$TARGET_DIR"
    for f in tunnel-monitor.sh install-monitor.sh config.sh config.sh.example \
             tunnel-monitor.conf.example install.sh diag.sh migrate.sh \
             README.md README_RU.md .gitignore; do
        [ -f "$SRC_DIR/$f" ] && cp -a "$SRC_DIR/$f" "$TARGET_DIR/"
    done
    [ -d "$SRC_DIR/systemd" ] && cp -a "$SRC_DIR/systemd" "$TARGET_DIR/"
    if [ -f "$SRC_DIR/tunnel-monitor.conf" ] && [ ! -f "$TARGET_DIR/tunnel-monitor.conf" ]; then
        cp -a "$SRC_DIR/tunnel-monitor.conf" "$TARGET_DIR/"
    fi
    echo "Файлы скопированы в $TARGET_DIR"
fi

chmod +x "$TARGET_DIR/tunnel-monitor.sh" 2>/dev/null || true

[ -f "$TARGET_DIR/config.sh" ] || \
    echo "WARNING: нет $TARGET_DIR/config.sh — создай из config.sh.example"
if [ ! -f "$TARGET_DIR/tunnel-monitor.conf" ]; then
    echo "WARNING: нет $TARGET_DIR/tunnel-monitor.conf"
    echo "  cp $TARGET_DIR/tunnel-monitor.conf.example $TARGET_DIR/tunnel-monitor.conf"
    echo "  и заполни TG_BOT_TOKEN, TG_CHAT_ID, PRIMARY_SOCKS"
fi

cat > /etc/systemd/system/tunnel-monitor.service <<UNIT
[Unit]
Description=Tunnel monitor (xray exits health check + Telegram alerts)
After=network-online.target setup-routing.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${TARGET_DIR}/tunnel-monitor.sh
UNIT

cat > /etc/systemd/system/tunnel-monitor.timer <<'UNIT'
[Unit]
Description=Run tunnel-monitor hourly

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now tunnel-monitor.timer

echo
echo "Готово. Таймер включён:"
systemctl list-timers tunnel-monitor.timer --no-pager 2>/dev/null | head -3
echo
echo "Ручной запуск проверки:  ${TARGET_DIR}/tunnel-monitor.sh"
echo "Лог:                     ${TARGET_DIR}/tunnel-monitor.log"
