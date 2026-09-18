# terraform-provider-alta — evaluation

*Does `TwilightCoders/terraform-provider-alta` give us declarative config for this
router? Evaluated 2026-09-18, read-only throughout: no cloud write was made, and
nothing was pointed at the router except an SSH read. Referenced by the retraction
banner in [declarative-config-and-coordination.md](./declarative-config-and-coordination.md),
which this note supersedes on the "no provider exists" question.*

## Verdict

**Yes, and it fits our constraints better than anything we would have built.** Not
adopted yet — see "What is not done". The decisive evidence is not the README, it
is that the provider's own compile-mapping test **passes against our actual
router** (below). Everything else is a reading; that is a measurement.

## Why it fits constraints we already hold

| Our constraint | What the provider does |
|---|---|
| Portal-first — the dashboard must stay the truthful view of router config | Writes **through the Alta cloud**, so the portal shows what Terraform applied. Enforced by the tool, not by our discipline. |
| Every cloud write bounces eth4, and we have one fibre | Each apply is **one gated, commit-confirmed transaction**: agent paused, all writes staged, **one** push released, router self-restores unless health probes pass and the provider confirms. N changes become one bounce, with automatic recovery. |
| Clean-room only — the NDA was declined | `api/schema.json` is fitted from the portal bundle and captured responses, dated and re-checked by tests. No NDA material. |
| Most of our config is portal-inexpressible | `alta_device_file` / `alta_device_hook` manage router-side scripts **without a cloud write**, so no push and no bounce. |

The transaction shape is `PREPARE → STAGE → COMMIT → CONFIRM → ROLLBACK → REPAIR`.
The rollback timer disarms only when told to, so it needs nothing off the router;
the journal lives on the router, so an interrupted run can be finished from any
machine. Its DNS probe resolves a random name under a wildcard, so a cached answer
cannot pass — the same "a probe that cannot fail proves nothing" discipline we
apply here.

## What was actually verified, and what it showed

Run with `TF_ACC=1 go test ./internal/apischema -run Live` (read-only by
construction) against our live site and router:

- ✅ **`TestLiveCompileMappingHolds` PASSES.** This is the load-bearing result. It
  checks the cloud→router mapping against the configuration **our** router is
  actually running — not the cloud's read-back, which cannot show whether a stored
  value ever reached a device. The provider's model of this hardware is correct.
- ⚠ **`TestLiveSiteConforms` reports three schema gaps** — not provider defects;
  this is the mechanism working as designed ("drift shows up as a failing test
  instead of a surprise at apply time"). On our site:
  - `vlan: undescribed field "ipv6" (bool)` — twice, one per VLAN.
  - `vlan: field "notes" is described as always present but was missing from 1 of
    2 instances.`
- ✅ Full offline suite passes on Terraform 1.16.3 (10/10 packages), including
  `internal/provider`, which fails on 1.6.6 — that earlier failure was the version
  gap, not a defect.

## Blockers — all three cleared

| Blocker | Resolution |
|---|---|
| Provider hard-refuses MFA accounts (`cognito: account requires MFA`) | The automation account has **no MFA** — measured by a one-shot login probe, not assumed. |
| Needs config-write permission | `admin: true` / `allPasswords: true` on our site. |
| Terraform 1.14+ required | Was a hand-placed 1.6.6 binary from Dec 2023 at `~/.local/bin` (PATH 50). Now `terraform = "latest"` in the chezmoi-managed mise config → **1.16.3** via mise shim (PATH 3), which shadows the old binary without deleting it. |

Firmware minimum is 1.5g; we run exactly 1.5g.

## Operational gotchas (both cost a failed run)

- ⛔ **`ALTA_LABS_DEVICE_ID` is the router's base MAC without separators**
  (`bcb923819714` here — read `/sys/class/net/br-lan/address`). It is **NOT**
  `/cfg/mid.txt`, which is a different identifier entirely and produces
  `site has no device "…"`. `ALTA_LABS_SITE_ID` *is* `/cfg/siteid.txt`.
- ⛔ **Pin the RSA host key, not the ED25519 one.** The router offers both; the
  provider's Go SSH client negotiates **RSA**. Scanning with `ssh-keyscan -t
  ed25519` yields a fingerprint that fails with `host key mismatch`. Use bare
  `ssh-keyscan <host> | ssh-keygen -lf -` and take the RSA line.

## Scope finding: the provider and `post-cfg.sh` barely overlap

`post-cfg.sh` is 1067 lines across 32 sections. Classified by mechanism:

| What it does | Sections | Lands where |
|---|---|---|
| Installs a script + cron/hotplug entry | ~13 | `alta_device_file` (declarative content + drift detection) |
| Raw `iptables` using modules the portal has no concept of (`connlimit`, `recent`, REDIRECT-by-MAC) | 2 | device-side, permanently |
| `uci` tweaks (crond level, syslog ring, NTP, eth4 MAC, LCP, ip6class, ULA, mwan3, DNS internals) | ~11 | mostly portal-unmodeled — **exact split still needs a portal check** |
| Pure logic (clock sanity, seam values, apply, observability) | ~6 | device-side |

⭐ **Zero sections manage anything the provider's cloud resources own.**
`alta_vlan`, `alta_static_route`, `alta_port_forward`, `alta_firewall_rule`,
`alta_dhcp_reservation` and `alta_switch_port` map to things that were *never* in
`post-cfg.sh` — precisely because portal-first already sent them to the portal.

So **the provider does not shrink `post-cfg.sh`.** The 2026-07-14 plan aimed at
the wrong target: it assumed our rules wanted moving to the cloud, when our config
is overwhelmingly inexpressible there by nature. The real value is three other
things:

1. The portal-modeled set stops being click-ops and enters git.
2. Our ~13 deployed scripts get declarative content with drift detection,
   replacing the `scp`-then-diff-by-hand loop.
3. Portal writes become safe on a single fibre — the reason we batch and warn today.

## Open concern before adoption

`alta_device_hook` wants a managed loader block **inside** `post-cfg.sh`, giving a
load-bearing file mixed ownership: a Terraform-managed region beside a hand-written
one. That is a drift and ordering hazard in the single file that must never fail
silently. Prefer `alta_device_file` for whole files we already own end-to-end, and
resolve the hook question deliberately rather than discovering the failure mode.

## What is not done

- **Not adopted.** No cloud write has been made through it; no `terraform apply`
  has ever run against this site.
- The provider's safety-rails section has not been read closely. Do that before
  pointing it at the live router — the gated transaction is the whole reason this
  is safe, and an unexamined safety mechanism is an assumption.
- The portal-capability check that would turn the "~11 uci sections" row into an
  exact list needs `alta-portal-recon` (blocked while the playwriter MCP server
  fails to connect).

## Upstream contributions available

Both are things we verified live and their schema does not record:

1. **`vlans[].ipv6` (bool)** — reported by the conformance run as undescribed. We
   have it in our own verified key list (`id, notes, routerIP, poolSize,
   dnsServers, ipv6`) from the 2026-07-15 spike.
2. **`vlans[].dnsServers` drives *both* DHCP families.** Their schema says
   "comma-joined in cloud, list on device"; we verified the firmware splits it into
   `option:dns-server` (v4 opt 6) **and** `option6:dns-server` (DHCPv6) — one field,
   two protocols.
3. Measured **~8 s cloud→router propagation** via MQTT, change confirmed landing in
   live dnsmasq — useful for sizing a confirm timeout.
