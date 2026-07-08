# Route10 ↔ ODI DFP-34X-2C3 cutover journal

Investigation log + runbook from the 2026-04-25 session. Companion to `ONU_CONFIG.local.md`.

## Current state (end of 2026-05-13 session)

Reverted to known-working baseline mid-session. ODI stick reached **O5 in L4** but **never re-ranged after moving to W2** — almost certainly an **ISP soft-block** from repeated failed PPPoE auth attempts during the link-flapping window. Fiber unplugged from the stick to give the OLT time to clear the block. Route10 restored to normal operation with `stick-mgmt.sh off`. Alta config and persistent files in `/cfg/` are intact — see "What's persistent" below.

## What we learned this session

1. **MAC TX/RX confirmation (the key persistent piece).** On cold boot with stick inserted, both SFP ports have `txmacstatus = DISABLE` and `rxmacstatus = DISABLE` — `route-swd` does NOT auto-enable them. Until they're ENABLE, `port linkstatus` stays DISABLE and no PHY link trains. Manual `ssdk_sh port txmacstatus/rxmacstatus set <port> enable` is required after a module is inserted. This is the regression we suspected from last session, now confirmed.

2. **Two flap sources causing the SerDes to bounce every 15 s.** When PPPoE doesn't authenticate, the link develops a deadly cycle:
   - **`route-swd`** polls SFP and re-applies `interfaceMode` every ~15 s. Each set bounces the SerDes lane for ~3 ms. Logs in `logread` show `sfp0: set mode to 10gbase_r` / `sfp0: set mode to sgmii_fiber` alternating.
   - **`pppd`** has a ~15 s PADI timeout. On failure, netifd tears down/up `wan2`, bouncing `eth4.1011`.
   These two interact: every flap kills pppd's in-flight PADI, which causes another retry, which causes more flaps. With both stopped, link is rock-stable (0 flaps in 30 s observed).

3. **Stick mgmt UI from W2 requires more than just NAT.** `eth4` (untagged) is in the WAN firewall zone with default-DROP for INPUT/FORWARD/OUTPUT. ARP works (L2 isn't filtered) but ICMP/TCP gets dropped. Need explicit ACCEPT rules for `192.168.1.0/24` on `eth4` in all three chains plus NAT MASQUERADE for the outbound.

4. **Stick clones the Huawei MAC + identity persistently.** When stick is reachable, ARP shows `e0:da:90:c4:f8:85` — the configured LAN MAC clone. Vendor/SW/HW/Product Class strings also persist across power cycles, confirmed.

5. **Stick reaches O5 with the right config.** PON Status during the working L4 window: `Tx Power 1.82 dBm`, `Rx Power -17.57 dBm`, `Bias 12.45 mA`, `ONU State O5`, `ONU ID 0`. The OLT accepts the cloned `HWTC370F0BAE` SN. So the stick + ISP combo works.

6. **`LOID Status: WRONG` is harmless** under `Auth Mode = Password`. The Huawei (and the cloned stick) use Password auth, not LOID. The "WRONG" indicator just reflects an empty LOID field; OLT never asked.

7. **Stick's `Fiber Reset: Enable` setting is dangerous during cutover.** When host link flaps, it resets the PON side too — preventing ranging from ever completing. **Set Fiber Reset to Disable** before plugging fiber, so the stick's PON can range independent of host SerDes glitches.

8. **Stick VLAN setting must be Transparent** (not PVID-tagging). Route10 sends already-tagged VLAN 1011 frames on `eth4.1011`; stick should pass them through. Set Manual → Transparent Mode in stick's VLAN Settings.

9. **Soft-block exists and is real.** After many failed PADI / failed-ranging attempts, the ISP/OLT temporarily refuses to acknowledge this SN — even though the same stick had reached O5 earlier in the same session. Symptom: `Tx Power -inf`, `Bias 0`, `ONU State O0` despite valid `Rx Power` (~-17 dBm). Clears with 15–30 min of idle (fiber out of stick, no PPPoE retries).

## Persistence map (what survives a reboot)

| Path | Type | Auto-run? | Notes |
|---|---|---|---|
| `/cfg/config.json` | Alta config | yes (consumed at boot) | All UI settings live here |
| `/cfg/scripts/*.sh` | shell scripts | **no** | Persist on ext4, but inert unless invoked |
| `/cfg/rc.local` | shell script | **yes** | `/etc/rc.local` sources it at boot if exists |
| `/etc/init.d/*` | service scripts | yes | But `/etc` is tmpfs → only firmware-supplied ones survive |
| `/etc/rc.local` | shell script | yes | tmpfs — firmware ships it; sources `/cfg/rc.local` |
| Runtime `iptables`/`ip addr`/`ip route` | in-memory | no | Cleared on reboot |
| `ssdk_sh port` runtime overrides | in-memory | no | Cleared on reboot |
| Stopped services (`route-swd`, `wan2`) | runtime state | no | procd respawns route-swd after ~6 min |

So the "real" persistent customization hooks are `/cfg/config.json` (Alta UI) and `/cfg/rc.local` (boot hook). Everything else is either a one-shot script you invoke manually or a runtime tweak that resets on reboot.

## Tools available in `/cfg/scripts/`

Persistent files but **not auto-invoked** — call them manually via SSH.

### `stick-mgmt.sh` — break-glass mgmt access

Self-contained. Stops the flap sources (`route-swd`, `wan2`/`pppd`), sets up L3+firewall for `192.168.1.1`, and `off` reverses everything.

```sh
/cfg/scripts/stick-mgmt.sh on        # auto-detect cage, enable
/cfg/scripts/stick-mgmt.sh l4        # force L4 mode (eth5)
/cfg/scripts/stick-mgmt.sh w2        # force W2 mode (eth4)
/cfg/scripts/stick-mgmt.sh off       # revert
/cfg/scripts/stick-mgmt.sh status    # show state + reachability test
```

Designed to be invoked only when you actively need the stick UI — *not* something to leave running. After configuring the stick, run `off` to restore normal Alta operation.

Key behaviors:
- Re-enables `txmac`/`rxmac` on both ports after stopping route-swd (route-swd may flip them off on shutdown).
- For W2 path: adds `192.168.1.2/24` alias to `eth4`, host route `192.168.1.1/32 dev eth4`, MASQUERADE rule, and FORWARD/INPUT/OUTPUT ACCEPT punches.
- For L4 path: relies on Alta's existing `192.168.1.2/24` on `br-lan_2`, only adds MASQUERADE.

### `cutover-monitor.sh` — phase tracker

Logs L4/W2 link, port state, MAC enable bits, PPPoE state, and phase transitions to `/tmp/cutover-<ts>.log`. Mostly diagnostic. Heavy-ish (polls `ssdk_sh` every 2s). Useful during an active cutover to confirm transitions, less so after.

## Updated runbook (next attempt)

Wait at least 30 min from the last failed auth attempt before retrying. While idle, fiber should be unplugged from the stick (it's plugged back into the Huawei now — internet works).

Pre-flight from your Mac:
```sh
ssh -i ~/.ssh/route10_debug root@192.168.10.1 '
ip -br addr show br-lan_2;
ls /cfg/scripts/;
printf "port interfaceMode get 5\nport interfaceMode get 6\nquit\n" | ssdk_sh | grep Mode'
```

Expect: `br-lan_2 ... 192.168.1.2/24`, scripts present, modes `sgmii_fiber` (or `10gbase_r` if no module — both fine pre-insertion).

Cutover:
1. **Make sure stick has `Fiber Reset: Disable` and `VLAN: Manual → Transparent`** before plugging fiber. (These persist from this session — verify.)
2. Insert stick in W2 cage (no fiber yet).
3. SSH to Route10. Run `/cfg/scripts/stick-mgmt.sh w2` — this stops `route-swd` + `wan2`, sets up mgmt path, enables MAC TX/RX.
4. Plug fiber into stick.
5. Wait 60–90 s for stick to range. Browse `http://192.168.1.1` from Mac → PON Status should show `ONU State: O5`, `Tx Power: ~1-3 dBm`.
6. **Only after O5 confirmed**, run `/cfg/scripts/stick-mgmt.sh off` — this restarts `route-swd` and `wan2`. pppd will start sending PADI. If stick is genuinely at O5, PADO should come back within seconds and PPPoE will authenticate before pppd's 15s timeout — no flap cycle.
7. Verify: `ip route show default` should show `default via ... dev pppoe-wan2`.

If O5 isn't reached in 90 s after fiber, do NOT restart `wan2` — that just re-triggers the soft-block cycle. Instead: pull fiber for 5 s, plug back in, wait. If still stuck after a clean re-range, walk away another 30 min.

## Old runbook section below is superseded

Keep for reference but the new procedure above is the one to follow.

## TL;DR

- The stick's host link comes up at **1G fiber (`sgmii_fiber`)** on Alta Route10 once **two** things are true: port `speed=1000` is set in Alta UI for the SFP cage, **and** the stick has fiber connected so its `RX_LOS` line goes low. `qca-ssdk` refuses to train the SerDes lane while LOS is asserted — that is the whole reason it looked dead before fiber was plugged in.
- The stick's mgmt UI is at **`http://192.168.1.1`** (default Realtek RTL9601 — the seller listing's `192.168.0.1` was wrong). HTTP server is `Boa/0.93.15`, login at `/admin/login.asp`.
- Inter-VLAN routing on Route10 from your laptop on `br-lan` (`192.168.10.0/24`) to the stick on `br-lan_2` (`192.168.1.0/24`) Just Works once `br-lan_2` has its `192.168.1.2/24` IP applied — Alta's default firewall has both LAN VLANs in the same zone with `forwardAction: ACCEPT`.
- **Open regression** as of session end: after a Route10 reboot, neither L4 nor W2 lit up when fiber was plugged in. We did not get post-reboot diagnostic data with the stick inserted. Most likely culprits, in order: (1) `txmacstatus`/`rxmacstatus` not auto-enabled by route-swd at boot — I had manually enabled these on port 6 during the working session, runtime-only, so a reboot wipes them; (2) the stick's GPON config got overwritten with values that put it in "wait for OLT registration before enabling host port" mode; (3) physical (fiber, connector). See "Open issues" below.

---

## Hardware & topology (recap, see `ONU_CONFIG.local.md` for details)

- Alta Route10. Qualcomm IPQ95xx. OpenWrt 21.02.1, kernel 5.4.213. Switch fabric driven by `qca-ssdk` + `nss-dp`, port modes brokered by Alta's `route-swd` daemon based on `/cfg/config.json`.
- Route10 ports: `W1 L1 L2 L3 L4 W2` ↔ `eth3 eth0 eth1 eth2 eth5 eth4`. SFP+ cages are `L4=eth5` (qca port 6) and `W2=eth4` (qca port 5). Cages support **1G/5G/10G fiber and 2.5G NBASE-T copper** — no 2.5G fiber, no 1.25/2.5G GPON-style negotiation.
- ODI DFP-34X-2C3. Realtek RTL9601-class XPON/GPON SFP. Host SerDes is **1000BASE-X or 2500BASE-X**; only the 1G mode lines up with what Route10 supports. EEPROM byte 6 = `0x02` (1000BASE-LX), BR nominal `0x0d` (1300 Mbps).
- ISP: PPPoE on **VLAN 1011**, user `410563@btt`. SN-only auth — clone `HWTC370F0BAE` into the stick.
- Plan: stick lives in **W2 (production, PPPoE)** but is **configured in L4 (mgmt path)** because L4 is bridged to Route10's `br-lan_2` and reaches `192.168.1.1` from a browser easily. L4 cannot serve as a PPPoE-WAN port without reconfiguring Alta's WAN bindings — easier to physically swap cages once the stick is configured.

## Alta UI state — what's saved as of session end

From `/cfg/config.json`:

```json
"interfaces": [
  ...
  {"type":"bridge","ifAlias":"lan_2","ifName":"br-lan_2",
   "bridgeMembers":["eth2.2","eth1.2","eth0.2","eth5"],
   "addresses":[{"source":"static","cidr":"192.168.1.2/24"}]},
  {"ifAlias":"wan2","type":"pppoe","ifName":"pppoe0",
   "pppoe":{"username":"410563@btt","password":"<redacted>","interface":"eth4.1011"},
   "addresses":[{"source":"dhcpv6"}], "speed":"1000"}
],
"portsCfg": {"ports": {
   "0":{},
   "4":{"vlan":2, "speed":"1000"},   // L4 = eth5
   "5":{"speed":"1000"}              // W2 = eth4
}}
```

So saved-and-persistent:
- VLAN 2 (`br-lan_2`) at `192.168.1.2/24`, members include `eth5` (untagged, the L4 path). DHCP off.
- L4 port (4): native VLAN 2, speed 1G.
- W2 port (5): speed 1G (no VLAN — relies on Alta to auto-create `eth4.1011` for PPPoE).
- WAN2: PPPoE on `eth4.1011`, dhcpv6 on `eth4`. PPPoE creds saved.

Things you do **not** need to redo via UI for next session.

## What was the actual problem before fiber was connected

EEPROM byte 65 = `0x1a`. `loss_invert_signal` bit = `0` → **active-high LOS**. With no fiber, the stick reports LOS asserted. Route10 wires that to GPIOs:

- `gpio31` = `sfp_rx_p6` = LOS for L4 (port 6)
- `gpio25` = `sfp_rx_p5` = LOS for W2 (port 5)
- `gpio28` = `sfp_tx_p6` = TX_DISABLE for L4 (default `out low` = laser enabled)
- `gpio23` = `sfp_tx_p5` = TX_DISABLE for W2 (default `out low` = laser enabled)

While the LOS GPIO reads high, `qca-ssdk` keeps the switch port in `linkstatus = DISABLE` regardless of `interfaceMode`. That's why no kernel link events fire and no LED lights up. Connect fiber → LOS goes low → `route-swd` finishes its mode dance → `nss-dp 3a514000.dp6 eth5: PHY Link up speed: 1000` → bridge enters forwarding state.

Confirmed sequence from kernel ring buffer during the working session:
```
[2707] PHY Link up speed: 1000   (49 s up)
[2756] PHY Link is down
[3547] PHY Link up speed: 1000   (47 s up)
[3594] PHY Link is down
[3988] PHY Link up speed: 1000   (7 min 45 s up — long enough to reach UI)
[4453] PHY Link is down
```

The first two cycles were too short for either the stick to fully boot its HTTP server *or* for the laptop's browser to retry into a stable window. The third cycle is when `route-swd` settled and gave us a usable session.

## What was the actual problem reaching `192.168.1.1` after the link came up

In the second cutover attempt, the cutover-monitor's initial snapshot showed:

```
br-lan_2 IPs:     UP fe80::beb9:23ff:fe81:9714/64
```

No IPv4 on `br-lan_2`. Without an IPv4 address in the stick's subnet, Route10 has no path to ARP for `192.168.1.1`. The cause was **Alta UI saves during cutover** — saving the WAN2 PPPoE/speed change reloads `netifd`, which tears down `br-lan_2` and re-applies it, including a likely full reboot. Until the IP came back, no traffic to `192.168.1.x` could land. The keepalive script's `ip addr add 192.168.1.2/24 dev br-lan_2` masked this by re-adding the IP manually; it has no other reachability-affecting effect.

→ **Rule for next time: do NOT change Alta UI settings while fiber is plugged in.**

## Common-mistakes list (things that wasted time)

1. Speculating the speed should be 2.5G or 10G — Route10 doesn't do 2.5G fiber, stick's host SerDes won't do 10G. The only meeting point is **1G fiber**.
2. Speculating EEPROM Vendor/PN spoof to `HUAWEI MA5671A` — that's the upstream Linux SFP-quirk path, but Route10 uses Qualcomm's `qca-ssdk` SFP framework which has no PN whitelist (verified via strings on `qca-ssdk.ko`). EEPROM spoof would not have helped.
3. Trying ssdk port poweron/reset/linkforcemode — most return "not supported" or "item not initialized" on this build.
4. Trusting the seller's `192.168.0.1` mgmt IP — actual is `192.168.1.1`.
5. Editing Alta UI config while the stick has fiber connected — causes multi-minute reachability gaps.

## What might've made it work the first time and not after reboot

Honest list of suspects, in priority order:

1. **`txmacstatus` / `rxmacstatus` not auto-enabled by route-swd**. During session 1 I ran `port txmacstatus set 6 enable` and `port rxmacstatus set 6 enable` immediately before the link came up. These are runtime-only; a reboot resets them to whatever the boot path leaves them as. If route-swd does *not* enable them on first module insertion, the port stays DISABLE on every cold boot. **Untested post-reboot.** First thing to verify next session.
2. **Stick GPON config caused a behavior change**. The user said "overwrote GPON configs this time" before the soft block. Some Realtek 9601 firmware images have a "host link disabled until OLT registration" toggle. If that got enabled, post-reboot the stick will not bring up the host SerDes until it registers — and if the SN is not yet matched on the OLT side, registration won't happen.
3. **Physical / fiber**. SC-APC connector cleanliness, jumper integrity, wrong port on the stick. Cheap to verify by inspection.
4. **Stick stuck in a weird internal state from the prior session's auth thrashing**. ISP soft-block lasted ~30 min on user's side; the stick may also have its own back-off counter. Power-cycling the stick (pull from cage, wait, reinsert) is worth a try.

## Operational procedures (runbook for next session)

### A. Pre-flight check (run before plugging fiber)

One ssh:
```sh
ssh -i ~/.ssh/route10_debug root@192.168.10.1 '
ip -br addr show br-lan_2;
ip -br link | grep -E "eth4\.1011|eth5";
printf "port linkstatus get 5\nport linkstatus get 6\nport interfaceMode get 5\nport interfaceMode get 6\nport txmacstatus get 5\nport txmacstatus get 6\nport rxmacstatus get 5\nport rxmacstatus get 6\nquit\n" | ssdk_sh | grep -vE "SSDK|Welcome|^dev0|^$|^quit"
'
```

Expected (no module inserted):
- `br-lan_2 UP 192.168.1.2/24 ...`
- `eth4.1011@eth4 LOWERLAYERDOWN ...`
- `eth5 ... DOWN ...`
- All four port states: `[Status]:DISABLE` (normal — no module)
- `[Interface Mode]:` should be `sgmii_fiber` for port 6, **probably** `sgmii_fiber` for port 5 once route-swd has settled. If port 5 still shows `SGMII_BASET` or `10gbase_r`, that's expected when no module — route-swd applies `sgmii_fiber` only when a module is detected with `speed=1000` configured.

### B. Cutover, version "no UI changes during fiber"

Background the monitor in its own SSH session:
```sh
ssh -i ~/.ssh/route10_debug root@192.168.10.1 '/root/cutover-monitor.sh' &
```

Then:
1. Plug fiber into stick (in **L4**).
2. Wait until monitor prints `>>> PHASE_2_L4_STICK_REACHABLE` (means ARP succeeded for 192.168.1.1).
3. Open `http://192.168.1.1`. Login `admin` / `admin` (or `admin` / `password`, `root` / `admin`).
4. Configure the stick:
   - GPON SN: `HWTC370F0BAE`
   - Vendor ID / Equipment ID: `HWTC` if asked
   - HW/SW version: `343D.D` / `V5R022C00S265` (only if the stick lets you set them and your ISP fingerprints — usually not required for residential).
   - Bridge mode (default).
   - LAN MAC clone: `E0:DA:90:C4:F8:85` (the Huawei's LAN MAC). Stick-side, not Route10-side.
5. Save. Watch the **stick's PON LED** (on the stick body, visible through the cage) for solid = ranged with OLT.
6. Pull fiber. Move stick **L4 → W2**. Plug fiber back into the stick.
7. Wait for monitor to print `>>> PHASE_3_W2_LINK_UP`, then `>>> PHASE_4_PPPOE_UP`.
8. Confirm: `ip route show default` should show `default via ... dev pppoe-wan2`.

### C. When monitor is silent for too long after fiber plug-in

While fiber is plugged in, in another SSH window:
```sh
ssh -i ~/.ssh/route10_debug root@192.168.10.1 '
echo "-- LOS GPIOs (low = fiber light, high = no signal) --";
awk "/^ gpio25 / || /^ gpio31 /{print}" /sys/kernel/debug/gpio;
echo "-- ssdk port states --";
printf "port linkstatus get 5\nport linkstatus get 6\nport interfaceMode get 5\nport interfaceMode get 6\nport txmacstatus get 5\nport txmacstatus get 6\nport rxmacstatus get 5\nport rxmacstatus get 6\nquit\n" | ssdk_sh | grep -vE "SSDK|Welcome|^dev0|^$|^quit";
echo "-- carriers --";
ip -br link | grep -E "eth4|eth5";
ethtool eth5 | grep -E "Speed|Link det";
ethtool eth4 | grep -E "Speed|Link det";
echo "-- recent kernel link events --";
dmesg | grep -iE "PHY Link|nss-dp.*eth" | tail -10;
echo "-- recent route-swd --";
logread 2>/dev/null | grep -E "route-swd|sfp" | tail -10
'
```

Decision tree from output:

- LOS still high on the cage with the stick → fiber is not lit. Inspect connector / fiber.
- LOS low, port still `DISABLE`, `interfaceMode` correct (`sgmii_fiber`) → suspect `txmacstatus`/`rxmacstatus` disabled. Try the manual enable below.
- LOS low, port `ENABLE`, carrier still `DOWN` → very unusual. Watch a few seconds for `nss-dp ... PHY Link up` to fire.

### D. Manual port enable (RUNTIME ONLY — does not survive reboot)

```sh
ssh -i ~/.ssh/route10_debug root@192.168.10.1 '
printf "port txmacstatus set 6 enable\nport rxmacstatus set 6 enable\nport interfaceMode apply 6\n
        port txmacstatus set 5 enable\nport rxmacstatus set 5 enable\nport interfaceMode apply 5\nquit\n" | ssdk_sh
ip link set eth5 down; ip link set eth5 up
ip link set eth4 down; ip link set eth4 up
'
```

If this is what unsticks the link **after a reboot** with the stick already inserted, then we have confirmation that route-swd is not auto-enabling MAC TX/RX, and we should make this persistent (see "Things to try next").

## Files written to Route10 (`/root/`)

All shell scripts, executable, syntax-checked. None of them modify Alta config. None of them survive a flash reset, but they survive reboots.

- `/root/onu-monitor.sh [duration]` — initial 5-min default monitor; one-shot reachability sweep; verbose. Use for first probe of a new setup.
- `/root/onu-keepalive.sh [duration]` — adds `192.168.1.2/24` alias to `br-lan_2` (idempotent — no-op if Alta has it), watches link state, on link-up auto-runs targeted probe of `192.168.1.1` (ping, TCP scan 22/23/53/80/443/8080/8443/7547, HTTP banner). `0` = forever, Ctrl-C to stop.
- `/root/cutover-monitor.sh [duration]` — phase-tracking monitor (PHASE_0..4) for the actual L4-then-W2 cutover. Logs every state change. `0` = forever (default).

All write to `/tmp/onu-*-<ts>.log` or `/tmp/cutover-*.log`.

To pull them locally for archiving:
```sh
scp -i ~/.ssh/route10_debug root@192.168.10.1:/root/{onu-monitor,onu-keepalive,cutover-monitor}.sh ./route10-scripts/
```

## Reference: SSDK CLI (`ssdk_sh`)

Interactive shell. Read-only useful commands:

| Command | What it shows |
|---|---|
| `port linkstatus get <p>` | `ENABLE`/`DISABLE` (switch fabric state, not carrier) |
| `port speed get <p>` | Current negotiated speed |
| `port duplex get <p>` | Duplex |
| `port interfaceMode get <p>` | `sgmii_fiber` / `SGMII_BASET` / `10gbase_r` / `sgmii_plus` etc. |
| `port preferMedium get <p>` | `FIBER` / `COPPER` |
| `port txmacstatus get <p>` | MAC TX enable bit |
| `port rxmacstatus get <p>` | MAC RX enable bit |
| `port mediumType get <p>` | Often "not support" on this build |
| `sfp Option get <p>` | Decoded EEPROM Options byte (`tx_disable`, `loss_signal`, etc.) |
| `sfp VendorInfo get <p>` | Vendor name/PN/SN/date — sometimes segfaults |
| `sfp Data get <p>` | Raw EEPROM dump — segfaults frequently on this build |

Write commands that work runtime-only:
- `port interfaceMode set <p> <mode>` — modes: `psgmii_baset`, `psgmii_bx1000`, `psgmii_fx100`, `psgmii_amdet`, `sgmii_baset`, `qsgmii`, `usxgmii`, `sgmii_plus`, `10gbase_r`, `sgmii_fiber`, `psgmii_fiber`, `auto`
- `port interfaceMode apply <p>` — commits the set
- `port txmacstatus set <p> enable|disable`
- `port rxmacstatus set <p> enable|disable`
- `port autoNeg enable <p>` — succeeded only sometimes
- `port autoNeg restart <p>` — sometimes "not supported"

Write commands that returned errors on this build:
- `port poweron set <p>` → "item not initialized"
- `port reset set <p>` → "not support"
- `port linkforcemode set <p> enable` → "not support"
- `port speed set <p> 1000` → "not support"
- `port duplex set <p> full` → "not support"

Pattern to call non-interactively:
```sh
printf 'port linkstatus get 6\nport interfaceMode get 6\nquit\n' | ssdk_sh \
  | grep -vE 'SSDK|Welcome|^dev0|^$|^quit'
```

## Reference: Alta-specific bits

- `route-swd` (`/usr/sbin/route-swd`, symlinked → `black`): the daemon that owns SFP module detection, mode selection, and LED state. It calls `ssdk_sh port interfaceMode set/apply` based on `/cfg/config.json` `portsCfg` and the EEPROM read via I2C. State files in `/var/run/sfp{0,1}.txt` (current desired mode) and `/var/run/.sfp{0,1}.bin` (cached EEPROM).
- `fiber_led` (`/usr/bin/fiber_led`): just LED-pattern controller, not relevant to link state.
- Pinmux for SFP cages is in DT under `/sys/firmware/devicetree/base/soc/pinctrl@1000000/sfp_pinmux/`. Standard SFF-8431 pin assignments per port:
  - L4: gpio25 = RX (LOS), gpio23 = TX (TX_DIS) — *labeled by Alta*. Wait — re-reading earlier dump: `sfp_rx_p5` = gpio25 (W2/port5), `sfp_rx_p6` = gpio31 (L4/port6), `sfp_tx_p5` = gpio23, `sfp_tx_p6` = gpio28. **Confirmed: L4 LOS = gpio31, W2 LOS = gpio25.**
- DT only declares `sfp_rx_los_pin` for each port — no `sfp_mod_def` or `sfp_tx_disable_pin` from qca-ssdk's perspective. TX_DISABLE is driven by static pinmux (`output-low`, laser always enabled). Module presence is detected by I2C polling at addr `0x50` on `/dev/i2c-1`, not by a presence GPIO.

## Reference: I2C / EEPROM access

Both SFP cages multiplex onto **`/dev/i2c-1`** (only the inserted module shows up at addresses 0x50 / 0x51). `i2cdump`, `i2cget`, `i2cset`, `i2ctransfer`, `i2cdetect` are all installed in `/usr/sbin/`.

```sh
i2cdetect -y 1                       # scan; expect 0x50 + 0x51 when module present
i2cdump -y -r 0-255 1 0x50 b         # full A0 page (vendor info)
i2cdump -y -r 0-255 1 0x51 b         # A2 / DDM page
```

EEPROM modification is **possible from Route10** if ever needed (`i2cset`/`i2ctransfer` against `/dev/i2c-1`), since we have raw I2C access. We did not have to go there.

## Open issues / things to try next session

In rough priority order:

1. **Confirm `txmacstatus`/`rxmacstatus` on a cold-boot link-up.** Cleanest test: reboot Route10, wait for it to settle, plug fiber in (no Alta UI changes), watch `port txmacstatus get 5/6` over time. If they remain DISABLE while LOS goes low, route-swd doesn't auto-enable them. Then run procedure D ("manual port enable") and see if link comes up. If yes → make persistent.
2. **Make the manual enable persistent**: drop a small `/etc/init.d/sfp-mac-enable` script that runs after `qca-nss-dp` (START=20+) and executes the procedure-D ssdk commands. Or shell out from a `/etc/hotplug.d/iface/` event when `eth5`/`eth4` come up. This is the "out of the box" SSH-only fix the user asked for if hypothesis 1 holds.
3. **Stick factory reset** if hypothesis 2 (corrupted GPON config) is right. RTL960x sticks usually have a reset path documented in `Anime4000/RTL960x` (referenced earlier). Pull stick, hold reset (varies by model), reinsert.
4. **Read DDM telemetry on the stick** with `ssdk_sh sfp DiagRealTimeData get <port>` (when stick is inserted and fiber connected). Confirms whether the stick is lasing and receiving optical power.
5. **Try a different host with the stick** to rule out stick hardware. Any Linux box with an SFP+ cage and `phylink` will do. If link won't come up on a known-good host, the stick itself is the problem.
6. **Expose the stick UI by VLAN tagging on W2 in production**, so we can manage the stick *while* PPPoE is running. Plan: add a tagged "mgmt VLAN" (e.g., 4093) on W2 that the stick is configured to also expose on its host port, mapped to a Route10 VLAN that lives on `br-lan_2`. Most ODI sticks support this.
7. **VLAN 1011 explicit allow on W2** in Alta UI — currently relying on Alta auto-creating `eth4.1011`. Should work, but adding 1011 to "Allowed VLANs (tagged)" on W2 is one click and makes the path explicit.
8. **Disable WAN1 (eth3) during cutover** to remove the `metric 100` route ambiguity and force traffic via the new PPPoE.
9. **Prove the laptop-side hypothesis was not the cause**: clear laptop ARP/route caches before retrying so we know any failure is router-side (`sudo arp -d -a` on macOS).
10. **Inspect `qca-ssdk` source** — Qualcomm releases this. If we want to know definitively whether route-swd autoenables `txmacstatus`, the source (or the route-swd binary disassembly) is the answer.

## Things explicitly **not** worth chasing (negative results)

- EEPROM Vendor/PN spoof to `HUAWEI MA5671A`. The kernel SFP-quirk infrastructure exists but `qca-ssdk` overrides it; verified via `strings qca-ssdk.ko` — no PN whitelist.
- Forcing `2.5G` anywhere. Route10 cages only do 2.5G via NBASE-T copper modules, not fiber.
- `port speed/duplex set` via ssdk on these SFP ports — not supported on this build.
- `port poweron/reset/linkforcemode` — not supported / not initialized.

## Captured stick metadata (one specific unit)

```
Vendor:    ODI
Model:     DFP-34X-2C3
Serial:    XPON26020216
Date code: 260207
MAC seen:  38:3a:21:29:98:e0  (stick's own MAC — not the LAN MAC to clone)
HTTP:      Boa/0.93.15 at /admin/login.asp
Mgmt IP:   192.168.1.1
EEPROM:
  byte 6 = 0x02   (1000BASE-LX compliance)
  byte 12 = 0x0d  (1300 Mbps nominal)
  byte 65 = 0x1a  (TX_DISABLE+TX_FAULT+LOS impl, LOS active-high)
  byte 63 (CC_BASE) = 0x71
A2 / DDM page has cached "GLC-BX-U" Cisco PN at offset 0xc0 and an alt-PN
  "IPUIAG5RAB10-2094-02V02" at offset 0x80 — likely set by manufacturer for
  ISPs that whitelist by Cisco PN. Not used by qca-ssdk.
```

## Conventions / glossary

- **L4 / port 6 / eth5**: SFP+ cage on the LAN side (used as mgmt path).
- **W2 / port 5 / eth4**: SFP+ cage on the WAN side (production PPPoE path).
- **ssdk port id ≠ Alta port id ≠ eth index**. Mapping: Alta `port 4` (L4 in UI) = qca `port 6` = `eth5`. Alta `port 5` (W2 in UI) = qca `port 5` = `eth4`.
- **`sgmii_fiber`** = qca-ssdk's name for 1000BASE-X. **`SGMII_BASET`** = 1000BASE-T copper. **`sgmii_plus`** = 2500BASE-X (won't work with Route10's cage hardware on fiber).
