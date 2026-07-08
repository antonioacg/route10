# Route10 ↔ ODI DFP-34X-2C3 cutover — session 2026-05-13

Second attempt at the migration. Companion to `ROUTE10_CUTOVER.local.md` (session 2026-04-25). To be consolidated later.

## End-of-session state

- **WAN1 PPPoE working through Huawei.** Final topology: ISP fiber → Huawei (Bridge WAN, VLAN 1011 enabled, bound to LAN1) → Ethernet to Route10 W1 (eth3, **untagged**) → PPPoE `eth3` → internet. Huawei does the VLAN 1011 tagging upstream; Route10 sends untagged PADIs.
- **TP-Link removed from the path.** Route10 now does the PPPoE directly.
- **ODI stick failed to range.** Despite hard power cycle, factory-equivalent XML reimport (with PLOAM cleared, 802.1p PRI fixed to 0), and multiple cage moves, the stick stayed at `ONU State O0 / Tx -inf dBm / Bias 0 mA`. The Huawei on the same fiber/OLT reached O5 fine — so the OLT and fiber are healthy; the stick itself is wedged.
- **Route10 cleanly reverted** at session end (no `/cfg/scripts/`, no leftover iptables, no IP aliases on eth4). Alta UI saves are intact.

## The one new persistent change

Route10's **WAN1 PPPoE interface = `eth3`** (untagged) in Alta UI saved config. Previously the Alta UI had it as `eth3.1011` (tagged) which causes double-tagging when Huawei is also in VLAN-tagging bridge mode.

| Side | Setting | Effect |
|---|---|---|
| Huawei | Bridge WAN, **Enable VLAN ✓**, VLAN 1011, bound to LAN1 | Adds VLAN 1011 tag upstream on PON; strips on LAN1 |
| Route10 | WAN1 PPPoE on `eth3` (**no VLAN**) | Sends untagged PADIs on W1 |

Only this combination passes traffic correctly to the ISP BNG (`NE8000-TTR`). The Huawei firmware in "Bridge WAN + VLAN OFF" does NOT pass tagged frames transparently — it expects untagged in on LAN1 and tags going up. So Route10 must be untagged.

## Key learnings (in priority for next session)

### 1. The ISP topology details (verified by tcpdump in session)

- **BNG MAC:** `00:e4:06:8a:3f:10` (AC-Name "NE8000-TTR" — Huawei NE8000 BNG)
- **PADO source:** `d4:4f:67:bc:58:01` (intermediate hop, Huawei OLT)
- **PPPoE encapsulation:** standard, no service-name required
- **CGNAT:** assigned `100.68.x.x` (RFC 6598 CGNAT space) — normal for `btt`
- **Session establishes in < 1 s** once PADI reaches BNG. If "Timeout waiting for PADO" → frames aren't reaching BNG (tagging issue, fiber issue, or soft-block).

### 2. The ODI stick is wedged in a deep state

Earlier today (session start) the stick reached O5 once in L4. After many failed PADI / link-flap cycles, the stick's GPON ASIC entered a state where:

- Rx Power reads correctly (~-17.5 dBm — light is arriving)
- Tx Power = -inf dBm; Bias = 0 mA (laser never lights)
- ONU State sticks at O0 (initial / not synchronized)
- Multiple soft reboots from UI: no change
- XML import (PLOAM cleared, 802.1p=0): no change
- Hard power cycle (pull from cage, wait, reinsert): no change
- Both cages (L4 / W2) tested in this session: both O0

**Hypothesis:** the Realtek RTL9601 GPON chip's CDR / frame-sync / state machine has wedged into a persistent state that survives even cold boot. Either:
- The firmware writes some state to flash that doesn't reset on power cycle, or
- The OLT has a per-stick block (different from Huawei) that we have no way to clear or even observe.

### 3. No useful diagnostics via I²C

We probed both buses (bus 0 = L4, bus 1 = W2) and all SFP addresses:

- **0x50** EEPROM: ODI / DFP-34X-2C3 / XPON26020216 — same as factory
- **0x51 DDM**: bytes 0-127 are all `0xff` (SFF-8472 DDM **never implemented** on this stick — the Tx/Rx/Bias values in the UI come from internal firmware calls, not standard registers)
- **0x51 vendor area (128+)**: static "ESFP\x83" magic + "IPUIAG5RAB10-2094-02V02" + "GLC-BX-U" Cisco compatibility ID. No live state.
- **0x52-0x57, 0x5E-0x5F**: nothing — no vendor-specific I²C extensions

The stick's GPON state machine is **completely opaque from I²C**. To get deeper diagnostics, you'd need Realtek SDK access (via UART pads on the stick PCB, or custom firmware with telnet enabled). Neither is exposed.

### 4. Identity / config gap vs Huawei

| Field | Huawei | Stick | Match |
|---|---|---|---|
| GPON SN ASCII | `HWTC370F0BAE` | `HWTC370F0BAE` | ✓ |
| SW Ver 1/2 | `V5R022C00S265` | `V5R022C00S265` | ✓ |
| HW Ver | `343D.D` | `343D.D` | ✓ |
| Product Class | `EG8145X6-10` | `EG8145X6-10` | ✓ |
| LAN MAC | `E0:DA:90:C4:F8:85` | `e0:da:90:c4:f8:85` | ✓ |
| PLOAM Password | (Huawei has none — Antonio confirmed not just hidden) | `1234567890` factory default, then `""` after XML import | matched after import |
| 802.1p VLAN PCP | `0` (specified) | `255` (preserve), then `0` after XML import | matched after import |
| OMCC version | (unknown — Huawei firmware) | `0x80` (Realtek default) | unknown |
| Optical burst-mode profile | Huawei-specific | Realtek RTL9601 | likely differs — invisible to us |

**Conclusion:** software-visible identity matches. Remaining gap is invisible firmware/silicon behavior. Stick reached O5 once today with the Realtek-default config, so the gap is NOT the blocker — but the wedged state is.

### 5. Realtek RTL9601 community ecosystem (not explored)

If the next attempt also fails with stock firmware, consider:

- **[Anime4000/RTL960x](https://github.com/Anime4000/RTL960x)** — main hub for Realtek 960x firmware/mods. Has firmware images, modding guides, recovery procedures.
- **[andrewz1/DFP-34X-2C2](https://github.com/andrewz1/DFP-34X-2C2)** — specific to our stick family (2C2 ~ 2C3, same Realtek).
- **[hack-gpon.org](https://hack-gpon.org/)** — general PON-stick docs.

Custom firmware typically enables **telnet on the stick** (real shell into the RTL9601, can poke GPON registers and run debug commands), which is what we'd actually need to diagnose the wedge. Risk: brick on bad flash; recovery requires UART/JTAG hardware access.

### 6. ISP-side cleanup

If we're convinced this stick is fine but OLT is holding a per-stick block, the only fix is to call the ISP and ask them to "deregister" or "kick" the ONU on their side. Brazilian ISPs vary on whether front-line will do this — usually you need to ask for an "ONU reset" or "rerangear" in Portuguese ("rerangear a ONU" / "deslogar e religar a ONU"). Provide the GPON SN (`HWTC370F0BAE`).

## Scripts (saved to `route10-scripts/` in this repo)

All three are now in `./route10-scripts/`. None of them auto-run anywhere — they're manual SSH tools.

### `stick-mgmt.sh` — break-glass mgmt access to stick UI

Self-contained. Stops `route-swd` and any PPPoE attempts (which flap the SerDes), enables MAC TX/RX, configures L3 + firewall path to `192.168.1.1` regardless of which cage the stick is in.

```sh
# Copy to Route10's persistent storage
scp -i ~/.ssh/route10_debug ./route10-scripts/stick-mgmt.sh root@192.168.10.1:/cfg/scripts/

# Auto-detect cage, enable mgmt
ssh -i ~/.ssh/route10_debug root@192.168.10.1 '/cfg/scripts/stick-mgmt.sh on'

# Force a specific cage
... '/cfg/scripts/stick-mgmt.sh l4'
... '/cfg/scripts/stick-mgmt.sh w2'

# Revert: restart route-swd + wan*, clean rules
... '/cfg/scripts/stick-mgmt.sh off'

# State / reachability test
... '/cfg/scripts/stick-mgmt.sh status'
```

**Important:** Mac must have a static route for the stick's subnet. Run on Mac:
```sh
sudo route -n add 192.168.1.0/24 192.168.10.1
```

### `cutover-monitor.sh` — phase tracker

Logs L4/W2 link, port state, MAC enable bits, PPPoE state, and phase transitions. Writes to `/tmp/cutover-<ts>.log`. Use during active cutover attempts.

Bug from session: the `los=` field reads column 3 of `/sys/kernel/debug/gpio` (direction `in`) instead of column 4 (value `high`/`low`). Doesn't affect functionality but log shows `los=in` always. Trivial fix for next time.

### `poke-monitor.sh` — quick-and-dirty stick PON state watcher

Polls eth4 carrier, port 5 status, and stick PON UI every 2 s. Emits a line on every state change. Lower-overhead than cutover-monitor.sh. Used at end of session to watch hard-power-cycle outcome.

## Persistence map (refresher)

Critical to remember for next time:

| Path | Type | Auto-run? |
|---|---|---|
| `/cfg/config.json` | Alta config | yes (consumed by Alta at boot) |
| `/cfg/scripts/*.sh` | shell scripts | **no** — manual invocation only |
| `/cfg/rc.local` | shell | **yes** — sourced by `/etc/rc.local` at boot |
| `/etc/init.d/*`, `/root/*`, `/tmp/*` | anything | gone on reboot (tmpfs) |
| iptables, `ip addr/route`, ssdk runtime | runtime | gone on reboot |

If we want any of the scripts to run automatically at boot, put a one-liner in `/cfg/rc.local`. We never did this — all our setup was manual.

## Updated runbook for next attempt

Wait at least 24 h from this session before trying again — give the OLT plenty of time to forget about this stick.

### Pre-flight
```sh
ssh -i ~/.ssh/route10_debug root@192.168.10.1 '
ip -br addr show br-lan_2;
ip -br link | grep eth4.1011;
printf "port interfaceMode get 5\nport interfaceMode get 6\nquit\n" | ssdk_sh | grep Mode'
```
Expect: `br-lan_2 ... 192.168.1.2/24`; `eth4.1011 LOWERLAYERDOWN`; modes whatever (will be set when module inserted).

### Cutover (this is now Plan B — Plan A is "keep using Huawei")

1. Copy scripts persistently:
   ```sh
   ssh -i ~/.ssh/route10_debug root@192.168.10.1 'mkdir -p /cfg/scripts'
   scp -i ~/.ssh/route10_debug ./route10-scripts/*.sh root@192.168.10.1:/cfg/scripts/
   ssh ... 'chmod +x /cfg/scripts/*.sh'
   ```
2. On Mac, add static route + flip default to iPhone:
   ```sh
   sudo route -n add 192.168.1.0/24 192.168.10.1
   sudo route -n change default 172.20.10.1   # iPhone hotspot active
   ```
3. Verify stick has correct config (still has `HWTC370F0BAE`, SW/HW versions, MAC clone, PLOAM cleared, 802.1p=0, VLAN Manual → Transparent OR PVID 1011 depending on which side does the tagging).
4. **Decide which side does VLAN tagging — only one!** (Mirror Huawei: PVID 1011 on stick + untagged Route10 WAN.)
5. Insert stick in **L4** (the only cage where ranging was observed). Plug fiber.
6. SSH: `/cfg/scripts/stick-mgmt.sh on` (auto-detect L4).
7. Wait 90 s. Browser to `http://192.168.1.1`, verify O5 in PON Status.
8. If O5: `/cfg/scripts/stick-mgmt.sh off`. Switch WAN1 in Alta UI to PPPoE on `eth5` instead of `eth3` (if Alta UI allows). Verify pppoe-wan comes up.
9. If still O0: don't retry repeatedly — that's what got us stuck this session. Move on to firmware option or ISP call.

### Critical rules
- **Only one side tags VLAN 1011** — never both, never neither.
- **Don't let pppd thrash** — if PPPoE is failing, stop wan immediately so you don't enter the flap loop that wedged the stick this time.
- **Don't soft-reboot the stick from the UI repeatedly** — each "Apply Changes" cycle stresses the GPON state machine. Make all stick UI changes before plugging fiber.

## Open questions for future investigation

1. **Why does soft + hard power cycle not unstick the GPON ASIC?** Suggests state is in flash, not just registers. Custom firmware reflash would test this hypothesis.
2. **Does ISP soft-block on a per-stick basis** (separate from SN-level), based on optical burst-mode fingerprint or other invisible characteristic? Would explain why Huawei works on the same SN but stick doesn't.
3. **Is `OMCC version = 0x80` (Realtek default) different from Huawei's, and does this OLT care?** OMCC is post-O5 OMCI — shouldn't affect ranging. But worth confirming.
4. **What's `FIBER_MODE = 0` in the stick config?** Could be auto-detect (GPON/EPON) — confirm it's locked to GPON.
5. **Does `RTK_DEVID_*` (TR-069 device identity fields) being empty matter?** Probably not for PON ranging.
