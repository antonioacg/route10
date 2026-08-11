# OMCI ME 351 — the vendor ME our OLT polls and we cannot answer

Researched 2026-08-11, after the OMCI log capture was fixed and the very first
real cycle surfaced it. Confidence is marked per claim: **[CONFIRMED]** with a
source, or **[UNVERIFIED]**. The unverified parts are the interesting ones and
should not be quoted as fact.

## What we observe

Inside the OLT's 15-minute performance-monitoring sweep:

```
[31049.940] 0x4b67 UnknowME 351
[31049.940] 0x4b67 UnknowME 351
```

`UnknowME <n>` is the Realtek OMCI stack's log string for a message class it does
not implement. **The same transaction ID twice is a retransmission**, not two
requests — see the G.988 quote below.

Context: the rest of the sweep is `GemPortPmhd`, `EthExtPmData`,
`EthPmHistoryData`, `EthPmData3`, `FecPmhd`,
`MacBridgePortPmMonitorHistoryData` — all `Get`/`GetCurrentData`, **zero writes**.

## Why the OLT asks us at all

Our stick presents as Huawei: GPON SN `HWTC370F0BAE`, ME 257 `EqtID =
EG8145X6` (a Huawei **HGU/router** ONT). So the OLT is speaking Huawei-vendor to
what it believes is a Huawei home gateway. We are a bridge/SFU and do not
implement the Huawei private set beyond what the firmware ships.

This is a *direct consequence of the SN spoof* — see
`project_odi_mac_key_fix` / `project_odi_pppoe_working`. It is the price of the
identity that makes PPPoE work, and it is cheap.

## The standard: 351 is deliberately undefined

**[CONFIRMED]** ITU-T G.988 (11/2022) §11.2.4, Table 11.2.4-1:

```
349          PoE control
350-399      Reserved for vendor-specific use
400          Ethernet pseudowire parameters
```

There are **three** vendor blocks, not one: `240-255`, `350-399`,
`65280-65535`. (`467-65279` is reserved for future standardization.)

**[CONFIRMED]** In G.988 (10/2010) the table stopped at 342 and the 350–399
vendor block did not exist; it was carved out in a later revision. Either way
**351 has never had a standard meaning in any edition**. So no standards body
can tell us what it is — by design.

## Whose is it, and what is it?

**[CONFIRMED]** It is **not** in the Huawei set this chipset family calls
Huawei's, which is exactly `{350, 370, 373}`:
- `tripleoxygen/realtek-libohwtc` needs precisely `mib_Me350.so`,
  `mib_Me370.so`, `mib_Me373.so` in `/lib/omci`. There is no `mib_Me351.so`.
- Anime4000/RTL960x Discussion #328 (about *this* stick): *"none of this support
  ME 350, 370 & 373 (Huawei Proprietary OMCI)"* — and treats 351 separately:
  *"for Telekom Malaysia … **ME 351 is needed which only exist on Nijika Fw**"*.
  No public Nijika source or changelog, and it never says who owns 351.

**[UNVERIFIED — leading hypothesis]** A Huawei ONT console log names a handler
`omci_me_me351_get_curr_op`, printing `PortId`, `RxuniPktCnt`, `RxmutiPktCnt`,
`RxbroadPktCnt`, `TxuniPktCnt`, `TxmutiPktCnt`, `TxbroadPktCnt`. **The only
source is a paywalled Scribd document (id 766570762) that was never opened** —
this is search-index snippets, not a read source. If it holds, 351 is a **Huawei
per-port packet-counter ME**, and `get_curr_op` maps to OMCI *Get Current Data*,
the action that exists to read the in-progress interval of a **PM history ME**.
That fits perfectly with it riding inside the 15-minute PM sweep.

**[CONFIRMED]** 351 is absent from every public catalogue: tripleoxygen's
proprietary-ME wiki (which *does* list 350/370/373 as Huawei),
`opencord/omci-lib-go` `classidmap.go` (jumps 348 → 400), hack-gpon.org/mib/,
cboling/omci, pyvoltha.

## What our silence costs — the operationally useful part

**[CONFIRMED]** G.988 Annex B.2.1:

> "If a valid AK message is not received by the OLT after timer Ti expires …
> the OLT re-sends the original transaction request message. **A retransmitted
> acknowledged transaction request message carries the same transaction
> correlation ID as the original.**"
>
> "When Ri reaches the maximum retry value, Rmaxi, the OLT stops retransmitting
> and **declares an OMCC link state error**. … Threshold values … **are not
> subject to standardization**."

So the doubled TCI is the standard's own retransmit path. Ours stops at two ⇒
this OLT retries once, gives up, continues the sweep. **No escalation observed.**

Two caveats worth carrying:

1. **[CONFIRMED]** G.988 Table A.1.1-1 defines result code **`0100` = "Unknown
   managed entity"**. The *compliant* answer is to reply `0100`, not to go
   silent. Our silence is what forces the retransmit. (Whether the Realtek stack
   truly sends nothing, or replies and the OLT retries anyway, cannot be
   determined from this log — it would need a capture of the response direction.)
2. **[CONFIRMED]** OMCI is stop-and-wait per priority level, so each unanswered
   351 stalls that queue until Tmax. At two events per 15 min this is
   negligible — a real but tiny cost, not free.

**[CONFIRMED]** No evidence anywhere of an ONU being deprovisioned, alarmed or
deactivated for failing a vendor-ME query. Closest citable statement
(`realtek-libohwtc`): missing Huawei MEs *"may prevent the ONT/ONU to work with
Huawei OLTs (… it should still authenticate and reach O5 status, however)"*.

## ⛔ What this is NOT

The RTL960x README mentions vendor MEs 350–399 being *"sometimes mandated by
ISPs for authentication or additional configuration"* — but that appears in its
**"Fake O5 State"** section, describing an ONU that reaches O5 and then never
receives VLAN config (ME 84 & 171). **That is not us.** We have ME 84/171,
PPPoE, and traffic. Do not read the 351 probe as an auth failure.

## Is the log shape unusual? No.

`UnknowME` with a doubled TCI is ordinary. Two public GPON examples show the
identical signature — RTL960x issue #261 (`UnknowME 241` ×2) and #299
(`UnknowME 65304` ×2). Both sit in the *other* two vendor blocks.

## Search barriers (so nobody re-runs the dead ends)

GitHub **code** search API → 401 (never found the source emitting `UnknowME`);
`jameywine/GPL-for-GP3000` tree exceeds the 10 MB fetch limit; Scribd paywall;
**forum.adrenaline.com.br → 403 on every page**, and its 320-page Brazilian
ODI-stick thread is the biggest remaining hole; CSDN 521, Zhihu 403, Reddit
blocked.

⚠ **Trap:** the GitHub issue-search API does **not** index Discussions, so
`"351" repo:Anime4000/RTL960x` returns 0 while Discussion #328 demonstrably
contains it. A false negative that looks like an answer.

## The one lead that would settle it

Scribd document **766570762** ("Huawei OMCI consolelog") — a Huawei ONT's own
log, which would confirm both the counter semantics and Huawei ownership.

## How we monitor it now

`pon-collect.sh` records every `UnknowME <n>` **once per ME number** and stays
quiet thereafter (`/cfg/scripts/.omci-unknown-me`). It was briefly in the
management-*write* alert tier, which was wrong twice: it is a read, and at the
15-minute cadence it would have fired ~96×/day and buried the write alerts next
to it. A **previously-unseen** vendor ME still warns — that is the most likely
shape for an ISP pushing config to a device it believes is an HGU.
