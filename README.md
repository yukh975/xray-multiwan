**🇬🇧 English** | [🇷🇺 Русский](README_RU.md)

# Multi-WAN gateway on xray + tun2socks

[![Shell](https://img.shields.io/badge/shell-bash-121011?logo=gnu-bash&logoColor=white)](#)
[![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20ALT-FCC624?logo=linux&logoColor=black)](#)
[![Proxmox](https://img.shields.io/badge/Proxmox-LXC-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com/)
[![Xray](https://img.shields.io/badge/xray--core-VLESS-blue)](https://github.com/XTLS/Xray-core)
[![tun2socks](https://img.shields.io/badge/tun2socks-xjasonlyu-green)](https://github.com/xjasonlyu/tun2socks)
[![Idempotent](https://img.shields.io/badge/install-idempotent-success)](#re-running-installsh-on-a-live-system)

A single Proxmox container running multiple xray+tun2socks stacks — one per WAN exit. The client picks an exit by pointing its default gateway at a different IP: e.g. `.232` → France, `.233` → Sweden, `.234` → Finland.

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
3. **xray** installed as a systemd template `xray@.service`, one instance per exit:
   - `xray@fr` listens on socks5 at `192.168.0.232:10808`
   - `xray@se` listens on socks5 at `192.168.0.233:10808`
   - `xray@fi` listens on socks5 at `192.168.0.234:10808`
4. **tun2socks** (xjasonlyu/tun2socks) installed at `/usr/bin/tun2socks`, with a systemd template `/usr/lib/systemd/system/tun2socks@.service`.
5. **tun2socks configs** in `/etc/tun2socks/<n>.yaml`, where `<n>` = `fr`, `se`, `fi`. Required fields:
   - `device: tun://tun<n>` (tun2socks will create the tun device with that name)
   - `proxy: socks5://192.168.0.<IP>:10808` — points to the matching xray instance
6. **iptables-service** (classic sysvinit-style) with `/etc/sysconfig/iptables`. Ships with ALT Linux by default; on Debian you may need `iptables-persistent`.

## Before first run: edit `config.sh`

All tunables live in [`config.sh`](config.sh), sourced by `install.sh`, `diag.sh` and `migrate.sh`. Edit it in one place:

```bash
PARENT_IF="${PARENT_IF:-global}"        # parent interface (eth0 / global / ...)
NETMASK_BITS="${NETMASK_BITS:-24}"      # subnet prefix length

COUNTRIES=(
    "fr:192.168.0.232:100"              # code:IP:fwmark
    "se:192.168.0.233:101"
    "fi:192.168.0.234:102"
)
```

Each `COUNTRIES` entry is a WAN exit: `code` matches `/etc/tun2socks/<code>.yaml`, `xray@<code>.service`, `tun<code>` and `xray-<code>`; `IP` is the macvlan address the client sets as its default gateway; `fwmark` is any unique integer (convention: 100+).

Env vars override the file values for one-off runs:

```bash
PARENT_IF=eth0 bash install.sh
```

## Uninstall

```bash
bash install.sh --uninstall
```

Removes every artifact `install.sh` creates — services, scripts, systemd units, iptables rules, `ip rule` entries, macvlan interfaces, sysctl drop-ins. User configs (`/etc/xray/*.json`, `/etc/tun2socks/*.yaml`) and binaries are preserved.

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
Description=Policy routing for multi-WAN tun
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

You should see three **different** IPs — the upstream exit for each WAN.

From a Windows client:

```cmd
route delete 0.0.0.0
route add 0.0.0.0 mask 0.0.0.0 192.168.0.232
arp -d *
```

Open `https://api.ipify.org` in a browser — you should see a French IP. Switch the gateway to `.233` / `.234` to get a Swedish / Finnish IP.

**Important:** ICMP (`ping`, `tracert`) does **not** work through VLESS. Test strictly over TCP (HTTP/HTTPS).

## Diagnostics

### diag.sh

The fastest way to check a live system. `diag.sh` walks through every layer of the setup and prints a green ✓ / yellow ! / red ✗ line per check, plus a summary at the end.

```bash
bash diag.sh          # full report
bash diag.sh --quiet  # summary only
```

Exit code: `0` if everything is green, `1` if any check failed. All scripts source the same `config.sh`, so what's checked matches what's installed automatically.

What it checks:

- **sysctl** — `ip_forward`, `rp_filter`, `arp_ignore`, `arp_announce`, plus presence of `/etc/sysctl.d/99-*.conf` (so settings survive reboot).
- **Routing tables** — every `via_<code>` entry is present in `/etc/iproute2/rt_tables`.
- **Scripts** — `/usr/local/sbin/setup-macvlan.sh` and `/usr/local/sbin/setup-routing.sh` exist and are executable.
- **systemd units** — `setup-macvlan.service`, `setup-routing.service`, `xray@<code>`, `tun2socks@<code>` all enabled and active, plus the `tun2socks@` `link-up.conf` drop-in.
- **Interfaces** — parent (`global`) exists; each `xray-<code>` is macvlan, has its own MAC (distinct from the parent — critical for ARP), has the expected IP, is `UP`, has `rp_filter=0`; each `tun<code>` is up with `rp_filter=0`.
- **ip rule** — fwmark → table routing rule present for every exit.
- **Routing per table** — `via_<code>` has a default route through the right `tun<code>`.
- **iptables** — mangle `-i xray-<code> → MARK` and NAT `-o tun<code> → MASQUERADE` rules present.
- **Live connectivity** — `curl --interface tun<code> https://api.ipify.org` for each exit, plus a check that all exit IPs are distinct.

### Manual commands

If `diag.sh` isn't enough, drop to the raw commands it wraps:

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

## Re-running install.sh on a live system

`install.sh` is idempotent — it can be safely re-applied on top of an already-configured container (e.g. when changing the exit list or bumping a version).

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

To change the exit list, edit the `COUNTRIES` array in [`config.sh`](config.sh) and re-run `install.sh` — it's idempotent and will reconfigure everything (including mangle rules), but only for artifacts it manages (scripts, units, and mangle rules are fully regenerated). The array name stayed `COUNTRIES` for historical reasons; conceptually these entries are WAN exits.

**What does NOT get cleaned up automatically when shrinking the exit list:**

- Orphaned macvlan interfaces (remove manually with `ip link del xray-<code>`).
- Stale entries in `/etc/iproute2/rt_tables` (harmless, but can be cleaned up).
- Previously-enabled `xray@<code>` and `tun2socks@<code>` services — disable them manually with `systemctl disable --now`.

## Adding a new exit

To add e.g. a Netherlands exit (code `nl`, IP `.235`, tun `tunnl`, xray socks5 on `.235:10808`):

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

Or — simpler — add the new entry to the `COUNTRIES` array in [`config.sh`](config.sh) and re-run `install.sh`. It's idempotent and will reconfigure everything including the new exit.

## Migration to a new address plan

Use `migrate.sh` when the whole subnet changes — your provider shuffles IPs, or you move the container to a different bridge with a different address range. It rewires xray configs, tun2socks configs, `config.sh`, and the live macvlan interfaces in one pass.

### Configuration

Edit the `NEW_*` block at the top of `migrate.sh`:

```bash
NEW_PARENT_IP="192.168.1.20"
NEW_NETMASK_BITS="28"

NEW_COUNTRIES=(
    "fr:192.168.1.21:100"
    "se:192.168.1.22:101"
    "fi:192.168.1.23:102"
)
```

- `NEW_PARENT_IP` / `NEW_NETMASK_BITS` — the new address and prefix on `global`. Must match what you configured on the PVE host side.
- `NEW_COUNTRIES` — same `code:IP:mark` format as `install.sh`. Exit codes and fwmarks stay the same; only IPs change.

### Precondition: change the IP on the PVE host first

The script **will not** change the `global` IP for you — it only verifies the new address is already in place. On the PVE host, before running the script:

```bash
pct set <VMID> -net0 name=global,bridge=<...>,ip=192.168.1.20/28,gw=<new-gw>
pct reboot <VMID>
```

Then, inside the container, run:

```bash
bash migrate.sh --dry-run   # preview every change
bash migrate.sh             # apply
```

If `global` isn't on the expected subnet yet, the script stops with the exact `pct set` command to run.

### What it does (in order)

1. **Checks** — `global` is on `NEW_PARENT_IP/NEW_NETMASK_BITS`; `install.sh`, `diag.sh`, `config.sh` exist at the expected paths (`/root/files/` by default, override via `INSTALL_SH=` / `DIAG_SH=` / `CONFIG_SH=`).
2. **Backup** — `/etc/xray/<code>.json`, `/etc/tun2socks/<code>.yaml`, `install.sh`, `diag.sh` are copied to `/root/migrate-backup-<YYYYMMDD-HHMMSS>/`.
3. **xray configs** — rewrites the `"listen"` field in each `/etc/xray/<code>.json` to the new per-exit IP.
4. **tun2socks configs** — rewrites `proxy: socks5://<old-ip>:10808` to the new IP in each `/etc/tun2socks/<code>.yaml`.
5. **config.sh** — rewrites the `COUNTRIES` array and `NETMASK_BITS` value in `config.sh` (old block removed, new block inserted in place). `install.sh`/`diag.sh` read these values on their next run, so only one file needs editing.
6. **Strip old IPs** — any address still sitting on `xray-<code>` interfaces that isn't in the new plan gets removed with `ip addr del`.
7. **Restart xray** — `xray@<code>` reloads with the new `listen` address.
8. **Run install.sh** — regenerates `/usr/local/sbin/setup-*.sh` and systemd units, restarts all services, saves iptables.
9. **Run diag.sh** — prints a final report so you see immediately whether the migration landed cleanly.

### What it does NOT do

- Does **not** change the IP on `global` itself (you do that on the PVE host).
- Does **not** clean up stale routing-table entries in `/etc/iproute2/rt_tables` (they're harmless, keyed by fwmark).
- Does **not** remove old macvlan interfaces whose codes no longer exist in `NEW_COUNTRIES` — only IPs are stripped.

### Dry run

```bash
bash migrate.sh --dry-run
```

Prints every file it would write and every command it would run, without touching anything. Preconditions (parent IP, script paths) are still enforced.
