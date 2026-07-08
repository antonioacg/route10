# ODI Stick PPPoE Bring-Up Recipe

*The actual working procedure to get PPPoE flowing through the ODI DFP-34X-2C3 spoofed as a Huawei EG8145X6-10. Resolves all prior "no PADO returns" theories.*

**Status as of 2026-05-25 ~01:13 UTC: PPPoE works.** WAN3 dialing through stick gives `100.68.x.x` IPv4 + `2804:2488:50c0::/64` IPv6 via BNG `NE8000-TTR`. Default route via `pppoe-wan3`, 10ms ping to 1.1.1.1.

# The Working Recipe

## Prerequisites
- Stick at PLOAM O5 (broadcasting `GPON_SN=HWTC370F0BAE`, OLT auth via Huawei account)
- MAC_KEY correct: `4b17b17d6b04f12e16cfad0e8a62895e` (= MD5("hsgq1.9a"+UPPER(ELAN_MAC)))
- Firmware: `M114_sfp_ODI_hybrid_221209` (M110 cannot do this — needs hybrid for VEIP/bridge)
- Fiber on stick (Huawei off)
- Route10 mgmt path to stick: `eth4` UP + `192.168.1.2/24` alias + `ip route replace 192.168.1.1/32 dev eth4 src 192.168.1.2` (CRITICAL — without /32, kernel sends via br-lan_2) + `ip rule add to 192.168.1.0/24 lookup main priority 100` (mwan3 bypass)

## Step-by-step (all via UI, from Route10 with --interface 192.168.1.2)

### 1. Login (must use these EXACT fields — NOT `psd` as old memory claimed)
```sh
curl --http0.9 -X POST --interface 192.168.1.2 \
  -d "username=admin&password=admin&challenge=&save=Login&submit-url=%2Fadmin%2Flogin.asp" \
  http://192.168.1.1/boaform/admin/formLogin
```
- Field is `password`, NOT `psd`. Response 200 or 301 = success.
- Stick speaks HTTP/0.9 → `--http0.9` is mandatory.

### 2. OMCI identity (Huawei spoof) — `/boaform/admin/formOmciInfo`
```sh
curl --http0.9 -X POST --interface 192.168.1.2 \
  --data-urlencode "omci_vendor_id=HWTC" \
  --data-urlencode "omci_sw_ver1=V5R022C00S265" \
  --data-urlencode "omci_sw_ver2=V5R022C00S265" \
  --data-urlencode "omcc_ver=128" \
  --data-urlencode "omci_tm_opt=2" \
  --data-urlencode "cwmp_productclass=EG8145X6-10" \
  --data-urlencode "cwmp_hw_ver=343D.D" \
  --data-urlencode "apply=Apply Changes" \
  --data-urlencode "submit-url=/omci_info.asp" \
  http://192.168.1.1/boaform/admin/formOmciInfo
```

### 3. WAN entry — `/boaform/admin/formWanEth` (create new)
```sh
curl --http0.9 -X POST --interface 192.168.1.2 \
  --data-urlencode "lkname=new" \
  --data-urlencode "lst=" \
  --data-urlencode "vlan=ON" \
  --data-urlencode "vid=1011" \
  --data-urlencode "vprio=1" \
  --data-urlencode "adslConnectionMode=0" \
  --data-urlencode "ctype=2" \
  --data-urlencode "chEnable=1" \
  --data-urlencode "mtu=1500" \
  --data-urlencode "IpProtocolType=1" \
  --data-urlencode "droute=0" \
  --data-urlencode "chkpt=ON" \
  --data-urlencode "itfGroup=1" \
  --data-urlencode "apply=Apply Changes" \
  http://192.168.1.1/boaform/admin/formWanEth
```

**`vprio=1` is CRITICAL and off-by-one:**
- `vprio=0` → UI displays "none" → no 802.1p priority field in tag → malformed frame
- `vprio=1` → UI displays "0" → PCP=0 explicit → matches working neighbor frames
- `vprio=2` → PCP=1, etc.

### 4. VERIFY persistence (mandatory — Boa lies)
"Change setting successfully!" response from Boa does NOT mean the MIB layer accepted the change. Always verify via `save_cs` dump:
```sh
curl --http0.9 -X POST --interface 192.168.1.2 \
  -d "save_cs=Backup..." \
  http://192.168.1.1/boaform/formSaveConfig -o cfg.xml
grep -iE "OMCI_SW_VER1.*Value=.V5R022|vid.*Value=.1011" cfg.xml
```
Both must show the values you set. If not, re-POST.

### 5. REBOOT STICK — this is the step that was missing
```sh
curl --http0.9 -X POST --interface 192.168.1.2 \
  -d "reboot_now=Reboot" \
  http://192.168.1.1/boaform/admin/formReboot
```
Wait ~50-70s for boot. Poll i2c `0x50 byte 0` + ping `192.168.1.1` until responsive.

**Why reboot is mandatory:** the `nas0_0` bridge entry is stored in `/var/config/lastgood.xml` immediately on form POST, but the actual Realtek switch-fabric GEM↔host bridge wiring only happens at boot when `omci_app` reads the config. Dialing PPPoE before reboot = bridge isn't there yet = frames hit the floor.

### 6. Dial PPPoE on Route10
```sh
uci set network.wan3.device=eth4   # NOT eth4.1011 — stick adds the tag
uci set network.wan3.maxfail=10    # default 1 is too low if pppd has any transients
uci commit network
ifup wan3
```

### 7. Verify success
```sh
tcpdump -i eth4 -nn -e -p0 -s 0 "(ether proto 0x8863 or ether proto 0x8864) or (vlan and (ether proto 0x8863 or ether proto 0x8864))"
# Look for: PADO from BNG, PADS, CHAP success, IPCP
ifstatus wan3 | grep ipv4-address
ip route show default
ping -c 3 -I pppoe-wan3 1.1.1.1
```

# What was the actual bug (in one sentence)

**The M114 bridge data-path doesn't apply user-added WAN entries until reboot — every prior attempt was running pppd before the stick had rebooted with the WAN entry in lastgood.xml, so the bridge was never wired and frames disappeared inside the stick.**

# Wrong theories that wasted time (debunked)

| Theory | Status | Reality |
|---|---|---|
| "Stuck at PLOAM O2" | ❌ wrong | OntState=1 in Realtek enum is O5 — we were already auth'd |
| "OLT slot-cache from Huawei tenant" | ❌ wrong | Stick was at O5 with our SN happily; no OLT-side caching issue |
| "BNG MAC ACL bound to Huawei WAN MAC" | ❌ wrong | Huawei dialing uses Route10's eth3 MAC and works — proving no MAC binding |
| "Runt frame undersize" | ❌ wrong | Sent hand-crafted byte-perfect padded PADIs via raw socket — still no PADO when stick wasn't rebooted |
| "OMCI VEIP push needs hybrid firmware" | ✓ partially right | M114 does accept VEIP+bridge wiring (M110 didn't). But it wasn't sufficient alone |
| "Missing PPTP-Eth UNI bridge port = unicast PADO blackhole" | ✓ partially right | The bridge wiring IS the issue, but the fix is to reboot the stick with nas0_0 in lastgood.xml — not to add OMCI MEs manually |
| "Need to selectively de-spoof OMCI identity" | ❌ wrong | Full Huawei spoof actually works — the OLT pushes the right config and stick handles it after reboot |

# Stable working state (snapshot)

| Field | Value |
|---|---|
| Firmware | `M114_sfp_ODI_hybrid_221209` (V1.2.2-221209) |
| GPON_SN | `HWTC370F0BAE` |
| ELAN_MAC_ADDR | `e0da90c4f885` |
| MAC_KEY | `4b17b17d6b04f12e16cfad0e8a62895e` |
| OMCI Vendor ID | `HWTC` |
| OMCI_SW_VER1/2 | `V5R022C00S265` |
| CWMP Product Class | `EG8145X6-10` |
| HW_HWVER | `343D.D` |
| OMCC version | `128` (0x80) |
| Traffic Mgmt option | `2` |
| nas0_0 | vid=1011, vprio=1, Bridged, LAN_1, applicationtype=2 |
| Route10 wan3.device | `eth4` (untagged from Route10) |
| Route10 wan3.maxfail | `10` |
| BNG | `NE8000-TTR` (Huawei) |
| WAN MAC seen by BNG | `bc:b9:23:81:97:16` (Route10 eth4 MAC — not spoofed) |
| Account | `410563@btt` |
| BNG IPv4 we get | `100.68.x.x` (CGNAT) |
| Gateway | `168.195.103.5` |
| ISP DNS | `190.109.67.237`, `190.109.67.240` |
| IPv6 prefix range | `2804:2488:50c0::/64` |
| Ping 1.1.1.1 RTT | ~10ms (fiber) |

# Reboot safety (verified 2026-05-25 01:28 UTC)

**Route10 reboot test PASSED. Auto-recovers in ~65 s. No startup scripts needed.**

Timeline of clean reboot:
- t+0s: `ssh route10 'reboot'`
- t+20s: ssh back up
- t+45s: `eth4 carrier=1`, pppd dialing
- t+45s: PPPoE up, `IPv4 100.68.194.241`, default route via `pppoe-wan3`
- t+50s: external ping works (8.8.8.8 = 8.9ms)

Why it works without intervention:
- **`wan3` IS in `/cfg/config.json` cloud master** — survives reboot (Alta cloud sync overwrites local uci on boot, so local-only changes like `uci set network.wan3.maxfail=10` evaporate, but cloud-tracked settings persist).
- **Stick stays powered** through Route10 reboot (W2 cage power independent of host CPU reboot). Stick stays at O5 with bridge wired (config in stick's lastgood.xml from prior reboot).
- **`maxfail=1` is not a hard wall**: netifd's pppoe proto-handler auto-respawns pppd after die. First PADI cycle succeeds clean on boot test.

Things NOT needed for PPPoE (all session debris that gets wiped on Route10 reboot — fine):
- `192.168.1.2/24` IP alias on eth4 (was for stick mgmt UI)
- `ip rule pri 100 to 192.168.1.0/24` (was for mwan3 bypass during mgmt)
- iptables INPUT/FORWARD/OUTPUT for `192.168.1.0/24` (mgmt punches)
- `eth4 promisc` (was for tcpdump diagnostics)

# Troubleshooting flowchart

## Symptom: no internet, PPPoE down (wan3.up=false)

1. **Check fiber**: `i2cget -y 1 0x50 0x00 b` on Route10 should return `0x03` (= SFP module present in W2). If error → stick not seated.
2. **Check carrier**: `cat /sys/class/net/eth4/carrier` → 1 means stick host SerDes up at 1G. If 0 → either stick is rebooting (~60s after a stick reboot is normal) or stick is wedged.
3. **Check pppd**: `pgrep -af "pppd.*wan3"` → should be one process. If not, `ifup wan3`.
4. **Check ifstatus**: `ifstatus wan3 | grep -E "up|errors"` → look for `"up":true` and `"ipv4-address"`. If `pending:true` for >2 min, problem with PADO/auth.
5. **tcpdump for PPPoE**: `tcpdump -i eth4 -nn -e -s 0 "(ether proto 0x8863 or ether proto 0x8864) or (vlan and (ether proto 0x8863 or ether proto 0x8864))"` — should see PADI from us → PADO from `d4:4f:67:bc:58:01` (BNG `NE8000-TTR`) → PADS → CHAP → IPCP within ~1s.

## Symptom: PADI leaves, no PADO

This means the bridge data path in the stick is wedged or wasn't wired. Possible causes:
- **Stick rebooted but config didn't persist**: re-verify via `save_cs` dump:
  ```sh
  curl --http0.9 -X POST --interface 192.168.1.2 -d "save_cs=Backup..." \
    http://192.168.1.1/boaform/formSaveConfig -o cfg.xml
  grep -iE "OMCI_SW_VER1.*V5R022|vid.*1011" cfg.xml
  ```
- **nas0_0 entry missing or wrong vprio**: re-POST formWanEth with vprio=1
- **Stick at O0/O2 not O5**: `omcicli mib get 256` from telnet — `OntState=1` = O5 (Realtek enum), pon-stats counters incrementing = data flowing
- **MAC_KEY wrong**: re-verify via `flash get MAC_KEY` matches `MD5("hsgq1.9a"+UPPER(ELAN_MAC))`. If not, `flash set MAC_KEY <correct>` AND form POST. Reboot stick.

## Symptom: stick HTTP unreachable from Route10 (`192.168.1.1` no response)

This is mgmt path issue, doesn't break PPPoE — but blocks investigation. Restore via:
```sh
ip link set eth4 up
ip addr show eth4 | grep -q 192.168.1.2 || ip addr add 192.168.1.2/24 dev eth4
ip route replace 192.168.1.1/32 dev eth4 src 192.168.1.2   # CRITICAL — without /32, kernel sends via br-lan_2
ip rule add to 192.168.1.0/24 lookup main priority 100     # mwan3 bypass
ip neigh flush dev eth4
ping -c 2 -W 1 -I 192.168.1.2 192.168.1.1
```

If still unreachable after this AND eth4 carrier=1: stick's HTTP/telnet daemons are wedged. **Physical reseat is the only recovery** (pull stick from W2 + reinsert; fiber can stay attached).

The `formWanEth delete=Delete` operation reliably wedges the stick — avoid unless ready to reseat.

## Symptom: stick wedge cascade (pppd repeated dials wedge stick)

If pppd is rapidly failing on wan3 (`ifup wan3` repeatedly with pppd dying), the stick's bridge code may wedge. Recovery:
```sh
ifdown wan3                                   # stop pppd flap
ip link set eth4 up                           # re-bring up host port
# wait 30-60s for stick to recover
# then ifup wan3
```

If still no response: reseat stick.

# Optical / telemetry monitoring (since Alta UI shows no DDM for W2)

**ODI DFP-34X-2C3 doesn't implement SFF-8472 DDM** — the i2c 0xA2 page (where Alta reads temp/volt/Tx/Rx) is empty. So Alta's "SFP DDM" feature shows N/A for W2 even though the stick is healthy.

**Get the metrics via OMCI ME 263 (Anig) from the stick** instead:
```sh
# From Route10, via telnet to stick:
# Returns OpticalSignalLevel (Rx) + TransmitOpticalLevel (Tx) as signed-16-bit values
# Encoding: value × (1/500) dB → divide raw signed-int by 500 for dBm
omcicli mib get 263
```
Sample working values: `OpticalSignalLevel: 0xde34` = -8652/500 = **-17.3 dBm Rx**, `TransmitOpticalLevel: 0x037a` = 890/500 = **+1.78 dBm Tx**.

For a continuous monitoring solution (long-term: extend `ont-monitor` go project to query these via SSH→telnet bridge to stick, expose as Prometheus metrics).

# Reference: stick's WAN MAC vs LAN MAC

- `ELAN_MAC_ADDR` = `e0:da:90:c4:f8:85` → LAN-side (stick admin UI, br0)
- WAN-side MAC = `e0:da:90:c4:f8:86` (LAN+1) → seen in `multi_wan_generic.asp` nas0_0 entry, used by stick when participating in WAN side bridging

The BNG sees **Route10's eth4 MAC** (`bc:b9:23:81:97:16`) as the PPPoE source, NOT the stick's WAN MAC. Stick is a transparent L2 bridge for our purposes (despite the Realtek "HGU bridge" wiring complexity internally).
