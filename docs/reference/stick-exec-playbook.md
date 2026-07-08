# stick-exec.py — Canonical Safe Shell on the ODI Stick

*Path + invocation form for running shell/omcicli on the stick via Route10. Wraps clean-exit telnet (no cli.pid orphan). Use this whenever you need ME / MIB / debug data from the stick.*

**Path on Route10 (deployed, source-of-truth in repo):**
- `/cfg/scripts/stick-exec.py` ← run here
- `scripts/stick-exec.py` ← edit here, `scp` to deploy

**Canonical invocation** (one telnet session, all commands, clean `exit` + FIN drain, then close):
```sh
ssh route10 'python3 /cfg/scripts/stick-exec.py --json \
    "omcicli mib get 262" \
    "omcicli mib get 280" \
    "omcicli dump qmap" \
    "omcicli dump conn"'
```

**Common OMCI MEs worth knowing** (from this troubleshooting session):
- 256 ONU-G — Vendor/SN/Equipment, TraffMgtOpt, OntState
- 257 ONU2-G — Equipment ID, NumOfPriQ/Scheduler/GemPort, QoSConfigFlex
- 262 Tcont — AllocID per T-CONT (the OLT-pushed upstream alloc)
- 263 ANI-G — Rx/Tx levels, thresholds (OLT's view)
- 266 GemIwTp — GEM IW TP, points to GemPortCtp
- 268 GemPortCtp — PortID, TcAdapterPtr (T-CONT), **UsTraffDescPtr** (rate cap pointer)
- 277 PriQ — priority queues
- 280 TrafficDescriptor — CIR/PIR. **Empty MIB = no ONU-side rate cap; cap is OLT-DBA.**
- 84 VlanTagFilterData / 78 VlanTagOpCfgData — VLAN handling (verify VID 1011 us-tag)
- `omcicli dump qmap` — queue→T-CONT mapping with CIR(8K)/PIR(8K)
- `omcicli dump conn` — per-GEM VID filters (which GEM carries which VLAN)
- `omcicli mib getalm` — active alarms
- `omcicli mib getcurr <class>` — PM accumulators (296 = EthPmData3 for octets/packets/drops)

**Empirical reliability (2026-05-28 session):** 6+ back-to-back `stick-exec.py` calls with multi-command batches, zero wedges. Boa form path (`/boaform/admin/formReboot`) also works for reboots when needed.

**Why this file exists:** the ODI M114 single-CLI lock reference (project_odi_cli_pid_lock) has the full mechanism, but in the moment you just need the path and command form. This is that.
