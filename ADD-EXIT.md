# Adding a new exit to xray-multiwan

Step-by-step, using the example of adding exit `wan4`
(IP `192.168.0.104`, interfaces `xray-wan4`/`tunwan4`, fwmark `103`,
upstream `node4.example.com`).

The setup scripts are **config-driven**: `setup-macvlan.sh` and
`setup-routing.sh` read `EXITS` from `config.sh` at runtime, so after you create
the per-exit configs the only source of truth is `config.sh`. `install.sh`
applies the change (and a reboot would too).

Substitute your own values:
- `<code>`      — short exit name (wan4)
- `<IP>`        — macvlan address in the PARENT_IF subnet (192.168.0.104)
- `<fwmark>`    — next free mark (100, 101, ... → 103)
- `<upstream>`  — the receiving node's address (node4.example.com)
- `<tun>`       — tun device name (tunwan4)

The project is assumed to live in `/opt/xray-multiwan`.

---

## Before you start: gather the data

Current interfaces and which fwmark/IP are free:

```bash
ip -4 -br addr show | grep xray-
grep via_ /etc/iproute2/rt_tables
sed -n '/^EXITS=/,/^)/p' /opt/xray-multiwan/config.sh
```

Determine:
- a free IP in the subnet (next after the existing ones)
- a free fwmark (in order: wan1=100, wan2=101, wan3=102 → wan4=103)
- the parent interface name and prefix (from `config.sh`: `PARENT_IF`, `NETMASK_BITS`)

The UUID / transport parameters come from the receiving node's settings — they
are unique per node.

---

## Step 1. xray config for the new exit

Copy it from a working exit (e.g. wan1) and change the fields. If writing it by
hand, keep the same structure as `wan1.json`, replacing:
- `inbounds[].listen`           → `<IP>`           (192.168.0.104)
- `outbounds[].tag`             → `<code>-...`
- `outbounds[].settings.vnext[].address` → `<upstream>` (node4.example.com)
- `outbounds[].settings.vnext[].users[].id` → node UUID
- transport-specific fields (path / Host / serverName) → node values
- `routing.rules[].outboundTag` (last rule) → `<code>-...`
- log files (`<code>-access.log`, `<code>-error.log`)

File: `/etc/xray/<code>.json`

Check the key fields:

```bash
grep -E '"listen"|"address"|"id"|"path"|"Host"|"serverName"|"tag"' /etc/xray/wan4.json
```

---

## Step 2. tun2socks config for the new exit

```bash
cat > /etc/tun2socks/wan4.yaml <<'EOF'
proxy: socks5://192.168.0.104:10808
device: tunwan4
mtu: 1500
loglevel: info
EOF
```

(socks address = `<IP>:10808` — the new xray inbound; device = `<tun>`)

---

## Step 3. Add the routing table

```bash
# check the number is free:
grep -E '^\s*103\s' /etc/iproute2/rt_tables && echo "TAKEN" || echo "free"
# add it:
echo "103 via_wan4" >> /etc/iproute2/rt_tables
grep via_ /etc/iproute2/rt_tables
```

(`install.sh` also adds this line, but adding it up front keeps the dry-run tidy.)

---

## Step 4. Add the exit to config.sh

```bash
cd /opt/xray-multiwan
cp config.sh config.sh.bak.$(date +%H%M%S)

# add the wan4 line (format: code:IP:fwmark):
sed -i 's#    "wan3:192.168.0.103:102"#    "wan3:192.168.0.103:102"\n    "wan4:192.168.0.104:103"#' config.sh

sed -n '/^EXITS=/,/^)/p' config.sh
bash -n config.sh && echo "Syntax OK"
```

Note: if the host pins MAC addresses (a 4th field), add it with the MAC:
`"wan4:192.168.0.104:103:02:00:00:00:01:04"`.

---

## Step 5. Verify the preconditions

```bash
ls -l /etc/xray/wan4.json /etc/tun2socks/wan4.yaml
grep via_wan4 /etc/iproute2/rt_tables
grep 'wan4:192.168.0.104' /opt/xray-multiwan/config.sh
```

Everything should be in place.

---

## Step 6. Dry-run and install

```bash
cd /opt/xray-multiwan
# see what will happen:
bash install.sh --install --dry-run 2>&1 | grep -E 'wan4|192.168.0.104|103'

# apply (NOTE: a short 2-5s drop on running tunnels — install.sh restarts all
# xray/tun2socks and does iptables -F mangle):
bash install.sh --install
```

---

## Step 7. Check

```bash
bash diag.sh
```

Expected: the new exit in every section (via_wan4, mangle mark 103, NAT tunwan4)
and in the connectivity check `xray-wan4 (socks ...:10808) → <exit-IP>`.
`FAIL: 0` is the goal.

A `! exit IPs repeat` warning is fine if the exit lands on the same upstream as
another one (e.g. via failover).

---

## Rollback (if something went wrong)

Because the setup scripts are config-driven, removing the exit is just the
reverse: drop its line from `config.sh` and re-apply (or reboot) — the stale
macvlan, routes, ip-rules, mangle marks and NAT are cleaned up automatically.

```bash
# restore config.sh (or delete just the wan4 line):
cp /opt/xray-multiwan/config.sh.bak.<timestamp> /opt/xray-multiwan/config.sh
# remove the routing table line:
sed -i '/^103 via_wan4$/d' /etc/iproute2/rt_tables
# remove the per-exit configs:
rm -f /etc/xray/wan4.json /etc/tun2socks/wan4.yaml
# re-apply without wan4 (stops+disables xray@wan4/tun2socks@wan4, drops its
# interface/routes/NAT); a reboot would do the same:
cd /opt/xray-multiwan && bash install.sh --install
```
