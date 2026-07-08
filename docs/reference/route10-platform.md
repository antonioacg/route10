# Route10 platform gotchas

*Three hardware/platform traps on the Alta Route10: the SFP cage port map (and the one port you must never touch), the cloud-config sync that silently reverts local uci changes on boot, and the per-cage LED sysfs files that are telemetry, not control.*

## Cage layout & port map

*L4 cage is now a 10G office-switch BiDi; only W2 is available for the GPON stick. Touching port 6 breaks office connectivity.*

Route10 SFP cage assignment as of 2026-05-24:

- **L4 (eth5, ssdk port 6, mode `10gbase_r`)** — 10G BiDi SFP+ to office switch. Member of `br-lan`, `br-lan_2`, `br-lan_7` (LAN VLAN trunk). Production traffic.
- **W2 (eth4, ssdk port 5)** — empty / available for the ODI DFP-34X-2C3 GPON stick.

**Why:** topology changed between 2026-05-13 and 2026-05-24. Previous-session scripts (`stick-mgmt.sh`, `cutover-monitor.sh`) assumed L4 was a free stick test cage and would run `ssdk port interfaceMode set 6 sgmii_fiber` — which would reconfigure the office BiDi to a slower SerDes mode and drop the office link.

**How to apply:**
- Never run anything that writes to ssdk port 6 / eth5.
- The ODI stick goes in W2 only. WAN3 (`network.wan3.device=eth4`) is pre-armed to dial PPPoE there.
- `stick-mgmt.sh` in this repo has been updated to W2-only and explicitly refuses an `l4` arg.
- `cutover-monitor.sh` polls W2 only.
- If a future session sees a stick in L4 again, the office switch was moved — verify before un-fencing port 6.

## Cloud config overwrites local uci on boot

*Local uci changes that aren't pushed to Alta cloud silently disappear on reboot. `/cfg/config.json` is rewritten from cloud at boot, not preserved.*

Route10 (Alta) runs cloud config sync. On boot, `/cfg/config.json` is overwritten from the Alta cloud master, not preserved across reboot.

Concrete: 2026-05-24 session set `uci network.wan3.maxfail=10` (was `1`) and uci-committed. `uci show` reflected it. After 2026-05-25 reboot, `uci get network.wan3.maxfail` returns `Entry not found` — gone. WAN3 `device=eth4` and `proto=pppoe` survived because they were already in the cloud master (set earlier via Alta UI). The `maxfail=10` change was local-only, so cloud sync wiped it.

**Why:** important because the persistence map in earlier notes incorrectly claims `/cfg/` survives reboot. It does as a filesystem (loop0 ext4), but `config.json` specifically is treated as cache for the cloud master and gets rewritten. So `/cfg/scripts/`, `/cfg/firmware/`, and other non-config.json files DO persist; uci changes only persist if also pushed to the Alta cloud UI/API.

**How to apply:**
- For uci changes that must survive reboot on Route10: make them via Alta cloud UI/API, not local `uci set` + `uci commit`.
- Local `uci set` is fine for ephemeral runtime tweaks within a session.
- `/cfg/scripts/`, `/cfg/firmware/`, ssh authorized_keys (cloud-restored per user) do survive — only the uci-config-json layer is rewritten.
- When in doubt about whether a setting survived: reboot and verify, don't assume.

## Cage LED sysfs is telemetry, not control

*The `brightness` sysfs files for per-cage LEDs oscillate 0↔255 at ~1Hz from Alta daemon polling. They don't reliably drive the physical LED. Trust the physical LED, not the file.*

On Route10, the per-cage LED sysfs files behave as telemetry written by an Alta cage-poll daemon, NOT as direct hardware control:

```
/sys/class/leds/led10g_p5   ← W2 cage, 10G label
/sys/class/leds/led1g_p5    ← W2 cage, 1G label
/sys/class/leds/led10g_p6   ← L4 cage, 10G label
/sys/class/leds/led1g_p6    ← L4 cage, 1G label
```

Observed 2026-05-25: each file's `brightness` value oscillates 0↔255 at ~1Hz independent of any external probing. Writing `echo 0 > .../brightness` lasts 1-2 reads before something writes 255 back. The writer was not identifiable through obvious means (stopped `route-swd`, `rcstats`, no `/proc/*/fd` open on the file).

**Critically: the sysfs value does NOT predict the physical LED.** In 2026-05-25 post-reboot state, the file was still oscillating but the physical W2 LED was OFF (correct — empty/unfibered cage). Don't infer LED state from sysfs.

System status LEDs (`/sys/class/leds/{B,G,R,W}`) are different — those are uci/rcstats-controlled per `strings /usr/sbin/rcstats` (`echo 255 > .../B/brightness`, pattern triggers, etc.) and likely do reflect what they're driven to.

**How to apply:**
- When diagnosing a stuck-on/off Route10 cage LED: trust the physical LED, ignore `brightness` sysfs.
- If something IS lighting the physical LED that shouldn't be, the cause is more likely residual runtime state (iptables, ip aliases, ip rules on the underlying netdev) than the brightness file.
- A reboot is the cheapest way to distinguish "physically driven by hardware (e.g. MOD_PRESENT)" from "residual runtime state we injected".
