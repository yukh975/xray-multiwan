#!/bin/bash
# setup-routing.sh — config-driven policy routing for the multi-WAN gateway.
#
# Reads EXITS from config.sh at RUNTIME and rebuilds per-exit default routes,
# fwmark ip-rules, mangle marks and NAT to match it. Anything belonging to an
# exit that is no longer listed is flushed (stale ip-rules, mangle marks and
# tun* MASQUERADE do not survive). Edit config.sh, not this file.
# Installed to /usr/local/sbin by install.sh.
set -u

CONFIG_SH="${CONFIG_SH:-__CONFIG_SH__}"
# shellcheck source=/dev/null
. "$CONFIG_SH"

CODES=(); MARKS=()
for item in "${EXITS[@]}"; do
    CODES+=("${item%%:*}")
    MARKS+=("$(echo "$item" | cut -d: -f3)")
done

# Wait for the configured tun interfaces to appear (up to 30s each).
for c in "${CODES[@]}"; do
    for _ in $(seq 1 30); do ip link show "tun${c}" &>/dev/null && break; sleep 1; done
done

# --- ip rules: drop every fwmark→via_* rule, then add the configured ones. ---
ip rule show | sed -n 's/.*fwmark \([0-9a-fx]\+\).*lookup \(via_[A-Za-z0-9]\+\).*/\1 \2/p' | \
    while read -r m tbl; do
        ip rule del fwmark "$m" table "$tbl" 2>/dev/null || true
    done

# --- per-exit default route (in its table) + fwmark rule. ---
for i in "${!CODES[@]}"; do
    c="${CODES[$i]}"; m="${MARKS[$i]}"; tbl="via_${c}"
    ip route replace default dev "tun${c}" table "$tbl"
    ip rule add fwmark "$m" table "$tbl"
done

# --- mangle: mark packets by ingress macvlan. ---
# ICMP bypasses the tunnels: VLESS/SOCKS5 cannot carry ICMP, so tun2socks answers
# every echo-request by itself and any address would look alive. Unmarked ICMP
# falls through to the main table and leaves via the normal WAN.
iptables -t mangle -F PREROUTING
iptables -t mangle -A PREROUTING -p icmp -j ACCEPT
for i in "${!CODES[@]}"; do
    iptables -t mangle -A PREROUTING -i "xray-${CODES[$i]}" -j MARK --set-mark "${MARKS[$i]}"
done

# --- NAT: drop every tun* MASQUERADE, then add the configured ones. ---
# Rebuilding from scratch removes MASQUERADE left behind by a removed exit.
# The parent-interface MASQUERADE (-o $PARENT_IF) is left untouched.
iptables -t nat -S POSTROUTING \
    | sed -n 's/^-A POSTROUTING -o \(tun[A-Za-z0-9]\+\) -j MASQUERADE$/\1/p' | sort -u | \
    while read -r t; do
        while iptables -t nat -C POSTROUTING -o "$t" -j MASQUERADE 2>/dev/null; do
            iptables -t nat -D POSTROUTING -o "$t" -j MASQUERADE
        done
    done
for c in "${CODES[@]}"; do
    iptables -t nat -C POSTROUTING -o "tun${c}" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "tun${c}" -j MASQUERADE
done

# --- rp_filter=0 on every interface we touch. ---
for c in "${CODES[@]}"; do
    for i in "xray-${c}" "tun${c}"; do
        sysctl -w "net.ipv4.conf.${i}.rp_filter=0" >/dev/null 2>&1 || true
    done
done
sysctl -w "net.ipv4.conf.${PARENT_IF}.rp_filter=0" >/dev/null 2>&1 || true

ip route flush cache

# Persist iptables if /etc/sysconfig exists (restored on boot before this runs).
[ -d /etc/sysconfig ] && iptables-save > /etc/sysconfig/iptables
