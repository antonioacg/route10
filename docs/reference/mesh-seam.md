# route10 ↔ ops seam (mirror rule)

*The route10-side mirror of `ops/.claude/rules/mesh-seam.md`. The home router
(this repo) and the homelab GitOps platform (`~/git/ops`) are two worlds with
two agents. They share exactly one seam: the LAN/mesh values in the contract.
This file binds the route10 side to the same discipline.*

## The one shared thing

**`ops/NETWORK-CONTRACT.md`** (in the `ops` repo root) is the single source of
truth for every value where the two worlds meet: LAN VIPs, the site ULA prefix,
advertised mesh routes, and the Headscale ACL tags. **Do not copy those values
into this repo** — reference the contract so there's one place to change.

Ownership split: **`ops` owns** the cluster / VIP / MetalLB side. **route10 owns**
RA / DHCP / firewall / uci on the router.

## Rules (route10 side)

- ⛔ **route10 never edits `ops` manifests or cluster config.** A cluster-side
  need is expressed as a contract entry and handed to the ops side — not patched
  from here.
- **Contract-first.** To move a shared value (a VIP, the ULA prefix, an
  advertised route, an ACL tag), change `ops/NETWORK-CONTRACT.md` *first*, then
  reconcile the router to it. Never move the seam unilaterally.
- **Router-side changes respect Route10's persistence reality.** Anything the
  contract asks of the router is a uci/RA/firewall change, so it lands via the
  Alta dashboard (cloud master) or `scripts/post-cfg.sh` (the watchdog that
  survives cloud sync) — a bare `uci set` evaporates on reboot. See
  [route10-platform.md](./route10-platform.md) and
  [declarative-config-and-coordination.md](./declarative-config-and-coordination.md).
- **Issue tracking stays separate.** ops `INFRA-*` never tracks router work;
  router-side tasks are tracked on this side (CLAUDE.md "open investigations" /
  memory). INFRA-68 is the ops-side umbrella for the mesh; the router half is ours.
- The ops side is bound by the reciprocal rule: it does read-only router
  inspection only, and respects this repo's hard rules (never ssdk port 6; never
  kill pppd / reboot the stick unasked — single fiber).

## Pending router-side asks

`ops/NETWORK-CONTRACT.md` is the authoritative list of pending router-side asks.
The values are deliberately **not** mirrored here — a second committed copy is a
second authority (the coupling this rule exists to prevent). As of 2026-07-14
two are open: an RA ask (LAN ULA on br-lan) and a DHCP-pool reservation for the
VIP range. Read the contract for the values; session memory may carry working
detail (private, not shipped — the same exception the ops rules use).
