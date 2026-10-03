#!/bin/bash
# setup-macvlan.sh — config-driven macvlan + per-exit service reconcile.
#
# Reads EXITS / PARENT_IF / NETMASK_BITS from config.sh at RUNTIME and makes the
# live state match it: creates the configured macvlan sub-interfaces, removes any
# xray-* macvlan whose exit is no longer listed, enables the configured
# xray@/tun2socks@ services and stops+disables the ones that are gone.
#
# So removing an exit = delete its line from config.sh and reboot; nothing from
# the old exit comes back. Adding an exit still goes through install.sh (it also
# creates the per-exit /etc/xray/<code>.json / /etc/tun2socks/<code>.yaml).
#
# Edit config.sh, not this file. Installed to /usr/local/sbin by install.sh.
set -u

CONFIG_SH="${CONFIG_SH:-__CONFIG_SH__}"
# shellcheck source=/dev/null
. "$CONFIG_SH"

setup_iface() {
    local name="$1" addr="$2" mac="${3:-}"
    if ! ip link show "$name" &>/dev/null; then
        if [ -n "$mac" ]; then
            ip link add link "$PARENT_IF" name "$name" address "$mac" type macvlan mode bridge
        else
            ip link add link "$PARENT_IF" name "$name" type macvlan mode bridge
        fi
    elif [ -n "$mac" ]; then
        local cur
        cur=$(ip link show "$name" | awk '/link\/ether/ {print $2}')
        if [ "$cur" != "$mac" ]; then
            ip link del "$name"
            ip link add link "$PARENT_IF" name "$name" address "$mac" type macvlan mode bridge
        fi
    fi
    if ! ip -4 -o addr show dev "$name" | awk '{print $4}' | grep -qx "${addr}/${NETMASK_BITS}"; then
        ip addr add "${addr}/${NETMASK_BITS}" dev "$name" 2>/dev/null || true
    fi
    ip link set "$name" up
    local gw
    gw=$(ip route show default 2>/dev/null | awk '/^default/{print $3; exit}')
    [ -n "$gw" ] && ping -c 1 -W 1 -I "$addr" "$gw" >/dev/null 2>&1 || true
}

# Create the configured macvlan sub-interfaces. WANT_CODES is a space-padded list
# of configured exit codes (plain string membership — no bash 4 assoc arrays).
WANT_CODES=""
for item in "${EXITS[@]}"; do
    code="${item%%:*}"
    rest="${item#*:}"; addr="${rest%%:*}"
    mac="$(echo "$item" | cut -d: -f4-)"
    WANT_CODES="${WANT_CODES} ${code}"
    setup_iface "xray-${code}" "$addr" "$mac"
done

in_want() { case " ${WANT_CODES} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Remove macvlan sub-interfaces whose exit is no longer in config.
for ifc in $(ip -o link show type macvlan 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'); do
    case "$ifc" in
        xray-*)
            c="${ifc#xray-}"
            in_want "$c" || ip link del "$ifc" 2>/dev/null || true
            ;;
    esac
done

# Reconcile per-exit services with config: enable+start the configured ones,
# stop+disable any xray@/tun2socks@ instance that is no longer listed.
# --no-block: this runs as a boot oneshot ordered Before= the configured units,
# so a blocking start would deadlock; --no-block just queues them. A newly added
# exit (not yet in any ordering) is started here, so "add = config.sh + reboot".
for code in ${WANT_CODES}; do
    systemctl enable "xray@${code}.service" "tun2socks@${code}.service" >/dev/null 2>&1 || true
    systemctl --no-block start "xray@${code}.service" >/dev/null 2>&1 || true
    systemctl --no-block start "tun2socks@${code}.service" >/dev/null 2>&1 || true
done
for lnk in /etc/systemd/system/multi-user.target.wants/xray@*.service \
           /etc/systemd/system/multi-user.target.wants/tun2socks@*.service; do
    [ -e "$lnk" ] || continue
    inst="$(basename "$lnk" .service)"
    c="${inst##*@}"
    in_want "$c" || systemctl disable --now "${inst}.service" >/dev/null 2>&1 || true
done
