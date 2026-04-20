# shellcheck shell=bash
#
# config.sh — единый конфиг для install.sh, diag.sh, migrate.sh.
# Unified config file sourced by install.sh, diag.sh, migrate.sh.
#
# Правь этот файл. Скрипты сами его читают.
# Edit this file. The scripts source it.
#
# =============================================================================
# !!!  ПРАВИТЬ ПЕРЕД ПЕРВЫМ ЗАПУСКОМ  /  EDIT BEFORE FIRST RUN  !!!
# =============================================================================
#
# PARENT_IF — имя родительского сетевого интерфейса в контейнере, поверх
#             которого создаются macvlan-подинтерфейсы. Узнать текущее имя
#             можно командой `ip -br link show`. Часто это `eth0`, у меня
#             исторически `global`.
#             Parent interface inside the container on top of which macvlan
#             sub-interfaces are created. Check with `ip -br link show`.
#
# NETMASK_BITS — длина маски подсети (обычно 24, может быть 28 и т.п.).
#             Prefix length for the subnet where PARENT_IF and macvlan IPs
#             live (commonly 24, may be 28, etc.).
#
# COUNTRIES — список WAN-выходов в формате "код:IP:fwmark":
#   * код     — короткое имя выхода (fr, se, nl, ...). Совпадает с именами
#               /etc/tun2socks/<код>.yaml, xray@<код>.service,
#               tun2socks@<код>.service, tun<код>, macvlan xray-<код>.
#   * IP      — адрес macvlan-интерфейса в той же подсети, что и PARENT_IF.
#               Клиент указывает этот IP как default gateway.
#   * fwmark  — уникальная метка iptables (обычно 100+) для policy routing.
#
#   List of WAN exits in "code:IP:fwmark" format. Code matches tun2socks
#   config / service instance / macvlan name. IP is the macvlan address a
#   client sets as its default gateway. fwmark is any unique integer.
#
PARENT_IF="global"
NETMASK_BITS="24"

COUNTRIES=(
    "fr:192.168.0.232:100"
    "se:192.168.0.233:101"
    "fi:192.168.0.234:102"
)
