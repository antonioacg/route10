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

Ownership split: **`ops` owns** the cluster / VIP / MetalLB side, plus the mesh
*control plane* (Headscale at `vpn.net.aac.gd`, ACL tags/policy, pre-auth keys,
route approval). **route10 owns** RA / DHCP / firewall / uci on the router **and
the entire router-side mesh join** — the Tailscale fork
`antonioacg/alta-route10-tailscale` (install, WAN-interface, `post-cfg.sh`
integration, R8 re-join). Don't hand fork/router-join work across the seam; the
only thing route10 needs from ops for the join is a pre-auth key, out-of-band.

## Async message channel (stop hand-relaying)

Shared *values* always go through the contract (contract-first). Async *messages*
— asks, acks, ownership, status:

- **Files in `~/git/agent-seam/mail/`** (agreed 2026-08-09; route10 proposed, ops
  accepted). One message = one file, `<UTC YYYYMMDDTHHMMSSZ>-<from>--<slug>.md`,
  YAML front matter (from/to/subject/topic/importance/thread) + markdown body.
  Send = write + git commit in that repo; receive = list the dir and read what's
  new from the peer. Agent names: route10 = `fiber-edge`, ops = `homelab-core`.
  **When seam work starts, list the dir and read new peer mail, then arm a
  watcher** — that's the whole habit. Protocol + monitor snippet live in
  `~/git/agent-seam/SEAM.md` (jointly owned by both agents — it is loaded into
  BOTH sides' instruction context, so announce changes to it like a contract change).
- **RETIRED 2026-08-09: the `mcp_agent_mail` server** (`127.0.0.1:8765`,
  `project_key=/seam/route10-ops`). It was the seam's only component that could
  fail, and it failed every way available to it — a stale "paused" banner, a
  contact gate that silently dropped first messages, env-less restarts that lost
  the DB, and a sandbox-blocked `/dev/tcp` liveness probe that lied "closed" and
  led BOTH agents to stack duplicate servers on 2026-08-08. A directory cannot be
  down, so the whole "is the channel up" question is deleted rather than probed —
  the same no-ambiguous-silence principle we apply to alerting. History #1–#114
  stays read-only in `~/git/agent-seam/mailbox/`.

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
second authority (the coupling this rule exists to prevent). Read the contract
for the values; session memory may carry working detail (private, not shipped —
the same exception the ops rules use).

As of 2026-07-15: the VIP reservation, LAN ULA, and DNS delegation are **done**;
the open item is the **mesh join** (INFRA-68) — a deliberate, windowed job (fork
WAN-iface fix → install → advertise the two LAN routes → verify → rollback-ready),
route10-owned, pending only a pre-auth key from ops.
