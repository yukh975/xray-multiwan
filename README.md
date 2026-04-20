**🇬🇧 English** | [🇷🇺 Русский](README_RU.md)

# Multi-country gateway in a single container

[![Shell](https://img.shields.io/badge/shell-bash-121011?logo=gnu-bash&logoColor=white)](#)
[![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20ALT-FCC624?logo=linux&logoColor=black)](#)
[![Proxmox](https://img.shields.io/badge/Proxmox-LXC-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com/)
[![Xray](https://img.shields.io/badge/xray--core-VLESS-blue)](https://github.com/XTLS/Xray-core)
[![tun2socks](https://img.shields.io/badge/tun2socks-xjasonlyu-green)](https://github.com/xjasonlyu/tun2socks)
[![Idempotent](https://img.shields.io/badge/install-idempotent-success)](#re-running-installsh-on-a-live-system)

A Proxmox container running multiple xray+tun2socks stacks (one per country). The client selects a country by pointing its default gateway at a different IP: `.232` → France, `.233` → Sweden, `.234` → Finland.

## Architecture

```
Client (192.168.0.245)
  │
  │ gateway = 192.168.0.232 (or .233, .234)
  ↓
┌─────────────────────────────────────────────────┐
│ Container (ALT Linux / Debian)                  │
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

**How gateway differentiation works:**

1. Three macvlan sub-interfaces are created on top of `global`, each with its own MAC and IP.
2. When the client sets `.232` as its gateway, ARP resolves that IP to the `xray-fr` MAC — and frames arrive at that specific interface.
3. `iptables -t mangle` matches `-i xray-fr` and stamps `fwmark 100` on the packet.
4. `ip rule fwmark 100` routes the packet through table `via_fr`.
5. That table's default route goes through `tunfr`.
6. tun2socks picks up the packet, forwards it to the local xray socks5, and xray tunnels it out via VLESS to France.
7. On the tun output side, `MASQUERADE` rewrites the source IP so the remote endpoint sees the container, not the client.

## Prerequisites

1. **Proxmox container** with a single interface (`global`), privileged (required for macvlan and TUN).
2. **TUN passthrough** on the PVE host — in `/etc/pve/lxc/<VMID>.conf`:
   ```
   lxc.cgroup2.devices.allow: c 10:200 rwm
   lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
   ```
3. **xray** installed as a systemd template `xray@.service`, one instance per country:
   - `xray@fr` listens on socks5 at `192.168.0.232:10808`
   - `xray@se` listens on socks5 at `192.168.0.233:10808`
   - `xray@fi` listens on socks5 at `192.168.0.234:10808`
4. **tun2socks** (xjasonlyu/tun2socks) installed at `/usr/bin/tun2socks`, with a systemd template `/usr/lib/systemd/system/tun2socks@.service`.
5. **tun2socks configs** in `/etc/tun2socks/<n>.yaml`, where `<n>` = `fr`, `se`, `fi`. Required fields:
   - `device: tun://tun<n>` (tun2socks will create the tun device with that name)
   - `proxy: socks5://192.168.0.<IP>:10808` — points to the matching xray instance
6. **iptables-service** (classic sysvinit-style) with `/etc/sysconfig/iptables`. Ships with ALT Linux by default; on Debian you may need `iptables-persistent`.

## Step-by-step installation

### Step 1. Bring up three IPs on `global` via macvlan

Each macvlan gets its own MAC — this is critical so the client's ARP cache can tell the gateways apart.

```bash
# Create macvlan sub-interfaces:
ip link add link global name xray-fr type macvlan mode bridge
ip link add link global name xray-se type macvlan mode bridge
ip link add link global name xray-fi type macvlan mode bridge

# Assign IPs:
ip addr add 192.168.0.232/24 dev xray-fr
ip addr add 192.168.0.233/24 dev xray-se
ip addr add 192.168.0.234/24 dev xray-fi

# Bring links up:
ip link set xray-fr up
ip link set xray-se up
ip link set xray-fi up

# Verify:
ip -4 addr show
ip link show | grep ether
```

### Step 2. ARP tuning

Without this, the interface answers ARP for any IP on the host — the client sees identical MACs for all gateways, and gateway differentiation breaks.

```bash
cat > /etc/sysctl.d/99-arp.conf <<'EOF'
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.conf.default.arp_announce = 2
EOF
sysctl -p /etc/sysctl.d/99-arp.conf
```

### Step 3. Forwarding and rp_filter

```bash
cat > /etc/sysctl.d/99-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl -p /etc/sysctl.d/99-forward.conf
```

`rp_filter=0` is required because routing here is asymmetric (packet arrives on `xray-fr`, reply goes out via `tunfr`) — strict reverse-path filtering would drop these packets.

### Step 4. Routing tables

```bash
cat >> /etc/iproute2/rt_tables <<'EOF'
100 via_fr
101 via_se
102 via_fi
EOF
```

### Step 5. ExecStartPost for tun2socks (bringing tun interfaces up)

xjasonlyu/tun2socks creates the tun device but doesn't bring it up. Add a drop-in:

```bash
mkdir -p /etc/systemd/system/tun2socks@.service.d
cat > /etc/systemd/system/tun2socks@.service.d/link-up.conf <<'EOF'
[Service]
ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5; do ip link show tun%i >/dev/null 2>&1 && break; sleep 1; done; ip link set tun%i up'
EOF
systemctl daemon-reload
```

### Step 6. macvlan setup script + systemd unit

So macvlan interfaces come back on every boot:

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

### Step 7. Policy-routing script + systemd unit

```bash
cat > /usr/local/sbin/setup-routing.sh <<'EOF'
#!/bin/bash
# Wait for tun interfaces (up to 30s)
for t in tunfr tunse tunfi; do
    for i in $(seq 1 30); do
        ip link show "$t" &>/dev/null && break
        sleep 1
    done
done

# Default routes in each table
ip route replace default dev tunfr table via_fr
ip route replace default dev tunse table via_se
ip route replace default dev tunfi table via_fi

# ip rule: fwmark → table (delete first to avoid duplicates)
for mark_table in "100:via_fr" "101:via_se" "102:via_fi"; do
    mark="${mark_table%%:*}"
    table="${mark_table##*:}"
    ip rule del fwmark "$mark" table "$table" 2>/dev/null
    ip rule add fwmark "$mark" table "$table"
done

# Mark packets by input interface
iptables -t mangle -F PREROUTING
iptables -t mangle -A PREROUTING -i xray-fr -j MARK --set-mark 100
iptables -t mangle -A PREROUTING -i xray-se -j MARK --set-mark 101
iptables -t mangle -A PREROUTING -i xray-fi -j MARK --set-mark 102

# Egress NAT
for t in tunfr tunse tunfi; do
    iptables -t nat -C POSTROUTING -o "$t" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$t" -j MASQUERADE
done

# rp_filter=0 on every involved interface
for i in xray-fr xray-se xray-fi tunfr tunse tunfi global; do
    sysctl -w net.ipv4.conf.$i.rp_filter=0 >/dev/null 2>&1 || true
done

ip route flush cache

# Persist iptables (on ALT / RHEL-like distros)
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

### Step 8. Enable xray and tun2socks services

Ordering matters: xray must start **before** tun2socks, because tun2socks connects to xray's socks5 at startup. Systemd's `Before=`/`After=` handles this automatically; for manual restarts, start xray first, then tun2socks.

```bash
systemctl enable --now xray@fr xray@se xray@fi
systemctl enable --now tun2socks@fr tun2socks@se tun2socks@fi
```

### Step 9. Start routing

```bash
systemctl start setup-routing.service
```

### Step 10. Verify

From inside the container (bypassing the client path):

```bash
curl --interface tunfr -s -m 10 https://api.ipify.org; echo
curl --interface tunse -s -m 10 https://api.ipify.org; echo
curl --interface tunfi -s -m 10 https://api.ipify.org; echo
```

You should see three **different** IPs — the exit nodes for each country.

From a Windows client:

```cmd
route delete 0.0.0.0
route add 0.0.0.0 mask 0.0.0.0 192.168.0.232
arp -d *
```

Open `https://api.ipify.org` in a browser — you should see a French IP. Switch the gateway to `.233` / `.234` to get a Swedish / Finnish IP.

**Important:** ICMP (`ping`, `tracert`) does **not** work through VLESS. Test strictly over TCP (HTTP/HTTPS).

## Diagnostics

Where to look when something breaks:

```bash
# Are all macvlan/tun interfaces up:
ip -4 addr show
ip link show

# Rules and tables:
ip rule show
ip route show table via_fr
ip route show table via_se
ip route show table via_fi

# Mangle counters — these grow under client traffic:
iptables -t mangle -L PREROUTING -v -n

# NAT counters:
iptables -t nat -L POSTROUTING -v -n

# Service status:
systemctl status setup-macvlan setup-routing
systemctl status xray@fr xray@se xray@fi
systemctl status tun2socks@fr tun2socks@se tun2socks@fi

# Where packets actually go:
tcpdump -ni xray-fr -c 10 'host <client-IP> and not port 22'
tcpdump -ni tunfr  -c 10 'host <client-IP> and not port 22'
```

Or just run the included diagnostic script:

```bash
bash diag.sh          # full report
bash diag.sh --quiet  # summary only
```

## Re-running install.sh on a live system

`install.sh` is idempotent — it can be safely re-applied on top of an already-configured container (e.g. when changing the country list or bumping a version).

**Files overwritten with identical content (safe):**

- `/etc/sysctl.d/99-arp.conf`, `/etc/sysctl.d/99-forward.conf`
- `/etc/systemd/system/tun2socks@.service.d/link-up.conf`
- `/usr/local/sbin/setup-macvlan.sh`, `/usr/local/sbin/setup-routing.sh`
- `/etc/systemd/system/setup-macvlan.service`, `/etc/systemd/system/setup-routing.service`

**Idempotent by logic:**

- `/etc/iproute2/rt_tables` — entries are appended only if not already present (via `grep -q`).
- macvlan interfaces are created only if missing; IPs are added only if not already assigned.
- iptables mangle — `iptables -t mangle -F PREROUTING` flushes old rules, fresh rules are added.
- iptables NAT — guarded by `-C ... || -A ...`.
- `ip rule` — `del ... 2>/dev/null; add ...` (remove any stale version, add the fresh one).
- `systemctl enable` on all services — a no-op if already enabled.

**What the script does NOT touch:**

- `/etc/tun2socks/*.yaml` configs.
- xray configs.
- `/etc/sysconfig/iptables` — gets rewritten at the very end by `setup-routing.sh` via `iptables-save`.

**Only visible side effect:**

All services get `restart`'ed (macvlan → xray@* → tun2socks@* → setup-routing). **Client connections will drop for ~2–5 seconds.** Schedule a maintenance window if that matters.

**Running it:**

```bash
bash install.sh
```

**Previewing without applying changes:**

```bash
bash install.sh --dry-run
```

In dry-run mode the script prints every command it would execute and every file it would create, without making any real changes. Preconditions (interface presence, tun2socks, configs, xray units) are still checked — dry-run only makes sense on an already-prepared system.

To change the country list, edit the `COUNTRIES` array at the top of the script and re-run — it's idempotent and will reconfigure everything (including mangle rules), but only for artifacts it manages (scripts, units, and mangle rules are fully regenerated).

**What does NOT get cleaned up automatically when shrinking the country list:**

- Orphaned macvlan interfaces (remove manually with `ip link del xray-<code>`).
- Stale entries in `/etc/iproute2/rt_tables` (harmless, but can be cleaned up).
- Previously-enabled `xray@<code>` and `tun2socks@<code>` services — disable them manually with `systemctl disable --now`.

## Adding a new country

To add e.g. the Netherlands (code `nl`, IP `.235`, tun `tunnl`, xray socks5 on `.235:10808`):

1. Prepare an xray config for `xray@nl` and `/etc/tun2socks/nl.yaml`.
2. Add `103 via_nl` to `/etc/iproute2/rt_tables`.
3. In `/usr/local/sbin/setup-macvlan.sh` add `setup_iface xray-nl 192.168.0.235`.
4. In `/usr/local/sbin/setup-routing.sh`:
   - Add `ip route replace default dev tunnl table via_nl` to the default-route block.
   - Add `"103:via_nl"` to the `ip rule` loop.
   - Add `iptables -t mangle -A PREROUTING -i xray-nl -j MARK --set-mark 103`.
   - Add `tunnl` and `xray-nl` to the NAT and rp_filter loops.
5. In `setup-macvlan.service` add `tun2socks@nl.service xray@nl.service` to `Before=`.
6. In `setup-routing.service` add `tun2socks@nl.service xray@nl.service` to `After=`.
7. Enable and start: `systemctl enable --now xray@nl tun2socks@nl`, then `systemctl restart setup-routing.service`.

Or — simpler — edit the `COUNTRIES` array in `install.sh` and re-run it. It's idempotent and will reconfigure everything including the new country.

## Migration to a new address plan

`migrate.sh` moves the whole installation to a new subnet (e.g. when the provider changes your IP block). New-addressing parameters live in the `NEW_*` block at the top of the script.

What it does:

1. Verifies that `global` is already on the new subnet (if not, it prints the `pct set` command to run on the PVE host).
2. Backs configs up to `/root/migrate-backup-<timestamp>/`.
3. Updates `listen` in xray configs and `proxy: socks5://...` in tun2socks configs.
4. Updates `COUNTRIES` and `NETMASK_BITS` in `install.sh` and `diag.sh`.
5. Removes the old IPs from macvlan interfaces.
6. Restarts xray, runs `install.sh` (which regenerates everything), runs `diag.sh`.

Dry run:

```bash
bash migrate.sh --dry-run
```
