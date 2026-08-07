# Portal-owned Tailscale — migration evaluation (OPEN, no Go)

**Status:** evaluation only. Nothing saved in the Alta portal. `tailscale-reconcile.sh`
remains the single owner. This document tracks what the portal can and cannot express,
what is still unknown, and the conditions under which a migration would be attempted.

**Why now:** the 2026-08-07 firmware added `tailscale.settings.login_url` (defaulting to
Tailscale SaaS) and its init logs the node out on a control-URL mismatch — see the
incident notes in `CLAUDE.md`. That option is also what makes a portal-owned control
plane possible for the first time, so the same change created both the outage and the
opportunity.

## Baseline (rollback reference, captured 2026-08-07)

```
uci tailscale.settings
  port                 41641
  state_file           /cfg/tailscaled.state
  log_stdout           0
  log_stderr           0
  advertise_exit_node  1
  advertise_routes     <LAN /24>  <LAN ULA /64>
  login_url            <TS_LOGIN_URL>

live prefs
  ControlURL       <TS_LOGIN_URL>
  AdvertiseRoutes  0.0.0.0/0, ::/0, <LAN /24>, <LAN ULA /64>
  WantRunning      true
```

Values are seam-owned and live in `/cfg/seam.env` (`LAN_ULA`, `TS_LOGIN_URL`,
`TS_NODE_TAG`); they are deliberately not written literally here — a second copy is a
second authority. Deployed `tailscale-reconcile.sh` and `mesh-health.sh` verified
identical to git at capture time.

## What the portal can express

The card is **Route10: Tailscale**: `Enable`, `Advertise subnets`, `Run as exit node`,
and — behind a collapsed **Advanced** disclosure — **`Login URL`**.

Cloud-agent evidence (`strings /usr/sbin/black`, the binary that rewrites uci from the
cloud master on every reapply):

```
uci set      tailscale.settings.login_url='%s'
uci set      tailscale.settings.advertise_exit_node='%d'
uci add_list tailscale.settings.advertise_routes='%s'
uci delete   tailscale.settings.advertise_routes
https://controlplane.tailscale.com          <- embedded default
```

Cloud-side config keys: `loginURL`, `advertiseSubnets`, `advertiseExitNode`.

| Reconcile responsibility | Portal | Note |
|---|---|---|
| `login_url` (control plane) | **Yes** | Behind *Advanced*. Format string in the agent. |
| `advertise_routes` | **Yes** | Free-form entry confirmed — see below. |
| `advertise_exit_node` | **Yes** | Toggle. |
| tailscale0 firewall accepts + NAT (v4+v6) | **No** | fw3 reloads flush these; must stay ours. |
| `br-lan` GRO off | **No** | Mesh bulk-transfer blackhole fix. |
| daemon log silencing (`log_stdout/stderr`) | **No** | Alta build dumps verbose stderr to syslog. |
| `state_file` under `/cfg` | n/a | Firmware default already correct. |

**Migration would shrink reconcile, not retire it.** The three it cannot express are the
ones with outage history.

### Subnet picker — verified free-form

The picker enumerates configured LAN subnets (only `Main: <LAN /24>`) and offers a
free-form text box. Typing the LAN ULA /64 flipped the summary label to **Custom**, left
the enumerated list unfiltered, and enabled **Save** — so it is an entry field, not a
search filter. The ULA is *accepted*; what it *writes* is unverified (see below).

## Open unknowns — only answerable by saving

1. **Custom + checkbox semantics.** With a custom prefix entered, the `Main` checkbox is
   independent and currently unchecked. Whether checking it *adds* to the custom entry or
   is *replaced* by it is unknown. Getting this wrong advertises the ULA and silently
   drops the LAN /24.
2. **Multiple custom prefixes.** The agent uses `add_list` (a list), so multiple entries
   are representable, but whether the field takes a comma-separated list is unverified.
3. **What `Enable` writes.** No `enable`/`enabled` key was found in the agent's key set,
   yet it contains `/etc/init.d/tailscale running && /etc/init.d/tailscale stop`. A save
   with `Enable` **off** may stop the daemon.
4. **Reversibility.** Unknown whether a cloud-modeled tailscale block can be un-modeled.
   Today the block is absent and the agent provably leaves our uci alone; after a save it
   may be permanent. Assume **one-way** until proven otherwise. Ops has **no Alta cloud
   visibility** and cannot answer this — it is an Alta support question, worth asking
   *before* the experiment.
5. **Can `login_url` be saved without the card also writing `advertiseSubnets`?**
   This is the one to test first — it decides whether a good version of this exists at
   all. See the flap analysis below.

### The route-flap problem with a login_url-only migration

The attractive shape is *portal owns `login_url`, routes stay reconcile-derived, the ULA
never enters the portal* — it keeps the contract-owned value with a deriving agent and
makes unknown 4 irrelevant by design rather than by information.

But the card's fields commit as a unit, and the agent rebuilds the route list
destructively:

```
uci delete   tailscale.settings.advertise_routes
uci add_list tailscale.settings.advertise_routes='%s'    (per entry)
```

So if a save writes `advertiseSubnets` as **empty**, every cloud reapply deletes our
advertised routes. `post-cfg.sh` calls `tailscale-reconcile.sh` in the **foreground**
after every reapply, so reconcile re-adds them seconds later and mesh-health assertion 2
covers the gap — but the steady state becomes a **route flap plus uci ping-pong on every
reapply, permanently**, visible as repeated converge events in `ts-reconcile.log`.

That is only avoided if unknown 5 resolves favourably — i.e. the card omits the
`advertiseSubnets` key entirely when untouched, rather than writing it empty.

### Three-way comparison

| Option | Cost |
|---|---|
| **A. Full portal ownership** | ULA becomes a hand-typed second authority, stops tracking the contract. **Ops veto, independent of all unknowns.** |
| **B. Portal owns `login_url` only** | If unknown 5 resolves badly: route flap + uci ping-pong on *every* reapply, forever. |
| **C. Stay on reconcile** | The boot race — rare, only on firmware update, now alarmed on both sides. |

B trades a rare, bounded, alarmed failure for frequent permanent churn. That is a bad
trade **unless** unknown 5 resolves favourably, which is why it is the first test.

## Gaps worth raising with Alta

Ordered by how much they cost a custom-control-server user.

1. **The upgrade logged out every custom control-server user, with no migration path.**
   The init compares live `.ControlURL` against a uci value that defaults to SaaS and
   logs out on mismatch. For anyone already logged in to a self-hosted control plane, the
   first boot after the update silently de-authenticates the node. Suggested fix: when
   `login_url` is unset, preserve the existing `ControlURL` rather than treating the
   default as intent.
2. **`Login URL` is buried behind *Advanced*** with a placeholder that reads like a value.
   Saving the card with the field left empty is the failure mode, and nothing signals it.
3. **No way to express a control plane without also taking ownership of everything else**
   on the card — the fields are saved as a unit.
4. **Subnet picker semantics are undiscoverable** (custom vs enumerated interaction).
5. **No portal surface for the tailscale0 firewall/NAT rules**, which an Alta config
   reapply flushes — so the mesh data path depends on config the portal cannot restore.
6. **No portal surface for per-interface GRO**, needed here for mesh→LAN bulk transfers.

## Go / No-Go

**Current recommendation: No-Go.** The gain is narrow (`login_url` surviving the tmpfs
config regeneration natively, retiring the boot race), and reconcile already covers it.
The costs are a hand-maintained ULA that stops tracking the contract, a reconcile scope
change that must land first, and unknowns answerable only by the irreversible act.

Preconditions for a future Go:

- [ ] Reconcile scope changed **first** so the portal and reconcile do not write the same
      uci keys on different schedules. Note they only conflict when they *disagree*: if
      both assert identical values reconcile stays quiet and acts as a repair path.
- [ ] Unknown 4 (reversibility) answered, or accepted as one-way in writing.
- [ ] A window agreed with ops, who must be available to re-register — a `login_url`
      mismatch costs a manual Headscale registration.
- [ ] **One atomic save**: `Enable` ON, `Login URL` = `TS_LOGIN_URL` exactly (no trailing
      slash), exit node ON, both subnets present. Never a partial save.
- [ ] Accept one eth4 bounce (portal writes reapply config; single-fiber WAN → PPP drops).

### Seam gate (agreed with ops, all three required before any save)

1. Picker demonstrably **holds** the LAN ULA /64 — entered and persisted, not inferred.
2. All four routes Approved **+ Serving**, verified ops-side post-save.
3. `dig` at both peer IPs, both families — route *presence* and route *function* are
   different claims.

The ULA is an ops-owned contract value. If the portal cannot express it, that is a
**contract break** and the migration does not proceed on that basis alone.

### Rollback

Re-save the card with correct values (Enable ON, `Login URL`, both subnets, exit node).
If unknown 4 turns out badly, "rollback" means a working cloud-owned config rather than a
return to reconcile-owned. Reconcile's firewall/NAT/GRO responsibilities are unaffected
either way.

## Fallback is not a loss

Staying on `tailscale-reconcile.sh` costs nothing we currently have. Its one structural
weakness — the boot race between the firmware init and our uci write — is now visible and
alarmed from both sides (mesh-health assertion 5 router-side, an independent control-plane
poll ops-side). "We stay as we are" is an acceptable outcome.
