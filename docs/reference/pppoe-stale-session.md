# PPPoE stale-session-by-MAC wedge — recovery via fresh dialing MAC

*When pppd terminates without sending PADT (e.g. LCP-echo failure during ISP downstream loss), the BNG retains the session keyed by GPON SN + dialing MAC. Same-MAC redials get `AUTH_TOPEER_FAILED` for 15 min–2 h until the BNG times us out. Fix: use a locally-administered eth4 MAC the BNG has never seen.*

**Captured live 2026-05-28 22:16 BRT, resolved 2026-05-28 ~23:22 BRT.**

## What happens

PPPoE Access Concentrators (BNGs) at Brazilian residential ISPs key the
active subscriber session by **`(GPON SN, dialing MAC address)`**, possibly
with a side index on subscriber username. Spoofing the SN is fine — the
OLT/BNG accepts our cloned `HWTC370F0BAE` because PLOAM doesn't use the SN
for auth. But once a session is up, the BNG remembers which MAC dialed it.

When pppd terminates **without sending a PADT** (e.g. the upstream `pppd
2.4.8` from OpenWrt on a 5 s LCP-echo-failure with `lcp-echo-failure 5
lcp-echo-interval 1`), the BNG has no signal that we're gone. It keeps the
session "active" in its state table. Subsequent dials from the same
`(SN, MAC)` pair get `AUTH_TOPEER_FAILED` because the BNG sees them as
"duplicate session for already-authenticated subscriber."

The wedge clears in **15 min to 2 h** depending on the BNG's session
inactivity timeout. Inside that window, **nothing on our side helps**:
- Stick reboots → OLT re-ranges fine, BNG state unchanged
- Cloning Huawei's WAN MAC (`E0:DA:90:C4:F8:86`) → also rejected if the
  BNG wedged on it from a prior session, OR if it's the same as the
  Huawei's currently-active dialing MAC
- Waiting → only thing that works long-term

## Why the Huawei "swap trick" worked historically

The user's previous fix when this happened was to swap fibre to the
factory Huawei EG8145X6 in bridge mode. That works because:
1. Huawei's `wan` interface on Route10 sits on **eth3**, with a *different*
   eth3 MAC (`bc:b9:23:81:97:15`) than eth4 (`bc:b9:23:81:97:16`).
2. The OLT performs **fresh ranging** on the Huawei (different physical
   ONU → different RTT, different equipment ID), propagating a "new
   subscriber session" signal to the BNG.
3. The combination of different MAC + different ranged identity is enough
   for the BNG to treat it as a fresh subscriber.

Timing matters: even Huawei swaps don't work immediately after a wedge if
the BNG hasn't yet released the old session. Wait at least 5–10 min after
the original death.

## The persistent fix (deployed in `/cfg/post-cfg.sh`)

**Set eth4 MAC to `02:11:22:33:44:56`** — a locally-administered MAC (IEEE
802 `02:` prefix indicating "private use, no OUI assigned"). This MAC has
*never been seen* by any equipment on this ISP, so even if the BNG keeps
state for every MAC it has ever encountered, ours is invisible.

Combined with the `keepalive='5 5'` change (25 s LCP tolerance instead of
5 s), the probability of triggering this wedge in the first place is much
lower — we now survive 20+ second downstream loss bursts.

If the wedge ever does recur:
- Wait 30+ min for the BNG to clear
- Swap fibre to Huawei as a manual backup (eth3 MAC is also fresh from the
  BNG's perspective since we never dialed PPP on it before)
- Recovery on stick path takes <10 s once BNG state is clear

## Signature in flap-hunt.log

```
22:16:40  EVENT ppp_reconnect prev_uptime=N now_uptime=0
… loop of …
{redial} → CONNECT_FAILED or AUTH_TOPEER_FAILED
```

with `pppup` resetting to 0 every ~30–60 s and never climbing. If you see
this pattern AND the GPON layer is healthy (stick at O5, no ANI-G alarms,
Boa responsive), it's the BNG wedge — wait or do the fibre swap.

## Related

- The mwan3 anycast false-drop note — the upstream trigger (ICMP loss
  burst tightening into LCP echo failures).
- The single-fiber internet-path note — single fibre, only one path,
  ask before doing anything destructive.
- The no-ISP-calls rule — never call the ISP, even when it's a real
  BNG-side issue. Solve in-house only.
