# Declarative config & cross-agent coordination for Route10

*How to manage the Route10 as-code from our side (firewall + the `post-cfg.sh`
tweaks), how that goal interacts with getting off Alta's cloud, and how this
agent and the homelab (`ops`) agent should coordinate on the one thing they
actually share — the mesh seam. Research note, 2026-07-14; no implementation yet.*

## Two goals that look like one

"Apply firewall rules declaratively from our side" contains **two independent
goals**, and keeping them apart is the whole key:

- **A — Config-as-code.** Rules live in git; apply is idempotent and repeatable;
  drift is detectable. A property of the *workflow*.
- **B — Data sovereignty.** The config *master* is a box we own, not Alta's
  cloud. A property of the *hosting*.

They're orthogonal. You can have A without B (git-tracked rules pushed into
Alta's cloud), B without A (self-hosted Alta Control — still click-ops), both, or
neither (today). **Both matter to us**, so this note runs them as two tracks —
and flags the one place where choosing B *removes* an option for A.

## The constraint: how Route10 config actually works

Route10 is OpenWrt underneath (fw3/uci firewall). Its config is **cloud-mastered**:

- The device holds a persistent outbound **MQTT-over-WebSocket** link to
  `manage.alta.inc`; the cloud *pushes* config. It's an **incremental diff**
  apply ("Found firewall/NAT config changes, applying." → targeted
  `/etc/init.d/{firewall,network} reload`), not a blind overwrite.
- On each sync the agent **regenerates `/etc/config/*` from `/cfg/config.json`**.
  That is precisely why a local `uci set` evaporates — it isn't in the master.
- Files under **`/cfg/` survive** the push (eMMC): `config.json` (master),
  `hash.txt` (change detection), `siteid.txt`, and crucially **`post-cfg.sh`**,
  which the agent runs *after* every apply.
- Hard-coded hosts: `manage.alta.inc` (config/API), `dl.alta.inc` (firmware
  auto-update — **suppressible via `/cfg/.no-auto-update`**), `ping.alta.inc`
  (the mwan3 track-IP; see [mwan3-anycast-false-drop.md](./mwan3-anycast-false-drop.md)).

So there are exactly **two write paths that survive a sync**: the **cloud master**
(supported, but the master lives at Alta) and **`post-cfg.sh`** (ours, runs last,
therefore wins). Everything below hangs off that fact.

## The Alta config surface (what's reachable, and how mature)

| # | Path | What it is | Maturity | Notes |
|---|------|-----------|----------|-------|
| 1 | **NDA API** | The real backend at `manage.alta.inc/api/`, Cognito-auth. Writes the whole per-site JSON (incl. `firewall`, `vlans`, `wans`) via `sites/update`. | Officially supported, **private** | Ask `Alta-Jeff` on forum.alta.inc — they're granting NDA access on request (as of Jun 2026). NDA constrains what we can open-source. |
| 2 | **Community Go SDK** `mikeee/altalabs-go` | Reverse-engineered client for the same API. `GetSite` reads the full blob; `UpdateSite` writes it back. | v0, ~2 stars, no releases | Reads well; writes only the **whole-site blob** (per-rule helpers are `not implemented`). Cognito with your real creds. Breaks silently if Alta changes schema. |
| 3 | **Dashboard JSON import/export** | The firewall-filters and port-forward screens have Import/Export JSON buttons. | Officially supported | Git the JSON, re-import on change. **Manual UI click**, and **partial** — firewall filters + port-forward/NAT only, not VLANs/routes/whole config. |
| 4 | **`post-cfg.sh`** override | Arbitrary idempotent `uci`/nft that runs after every cloud apply and wins. | Unofficial but staff-acknowledged; **we already use it** | The only path that survives *and* needs no Alta cooperation. Great for gap-filling; it layers *on top of* the cloud, it doesn't replace it. |
| 5 | **Self-hosted Alta Control** | Alta's own controller as a Docker/LXD image (free since 2024). | Officially shipped | Local *management*, **not** config-as-code — same click-ops UI on our box. This is the "configurer docker." See the sovereignty track below. |
| — | Terraform / Ansible / Pulumi | — | **Does not exist** | No provider, official or community. |

The dashboard firewall surface itself is rich (zone rules, port-forward, NAT,
firewall groups, static routes, PBR, even BGP/OSPF/IPS) — well beyond a consumer
wizard, but **not** a raw nft editor.

## Track B — data sovereignty (Alta Control), since off-cloud matters

**What it gives you:** the config master moves from Alta's cloud onto a box you
run. That's the sovereignty win, and it's real.

**What it does *not* give you:**

- **It is not declarative.** It's the identical dashboard, self-hosted. Goal A is
  untouched — you'd still click, or still lean on `post-cfg.sh`.
- **It does not cut the `dl.alta.inc` firmware tie.** The Route10 still needs
  internet for its first firmware update during setup, and firmware still comes
  from Alta. Sovereignty over *config*, not over *firmware*.
- **Operational tax:** 90-day Let's Encrypt cert that must be **manually renewed
  over SSH** or devices refuse to connect; a 24/7 NTP dependency; a self-hosted
  Control is a **separate world** from your `manage.alta.inc` account (no config
  migration between them); community threads report real Route10↔self-host
  adoption pain.
- **Chicken-and-egg:** it would run in the homelab, which sits *behind* the very
  router it configures. Bootstrap and outage ordering need thought.

> **The load-bearing interaction (verify before committing):** paths 1 and 2 (the
> NDA API and the Go SDK) point at `manage.alta.inc` — the **cloud**. A
> self-hosted Control is a separate world. So **going off-cloud likely removes the
> automated-push option**, leaving Track A on `post-cfg.sh` + manual UI import.
> *Unconfirmed:* whether self-hosted Control exposes the same `/api/` locally
> (it's the same app — it might). If it does, the SDK could be re-pointed; if not,
> B and "automated A" are mutually exclusive today. **This is the single most
> decision-relevant unknown — worth a spike before choosing B.**

**The ultimate sovereignty exit (flag, not a recommendation):** a mainline
**OpenWrt port** of the Route10 is in progress (UART gives a root shell by
default; secure boot is disabled; RE dump at `SkytheFolf/Alta-Route10-RE`). That
would replace Alta's whole stack with stock OpenWrt — full A *and* B — at the
cost of losing the dashboard, the cloud, and every `post-cfg.sh` workaround we've
tuned. A big, separate project. Watch it; don't depend on it.

## Track A — declarative firewall (works today, cloud-agnostic)

This is the good news: **A doesn't depend on the B decision.** `post-cfg.sh` is
device-side and controller-agnostic — it runs the same whether the master is
Alta's cloud or a self-hosted Control.

**The model — two tiers, one rule:**

- **Dashboard-expressible rules → the cloud master.** Zones, filter rules,
  port-forward, NAT, static routes. Git the JSON export; re-import on change
  (path 3), or automate via 1/2 if you accept the NDA/SDK tradeoffs.
- **Everything else → `post-cfg.sh`.** Idempotent uci that wins after each sync.
- **Never double-own a rule.** A rule defined in *both* the cloud and
  `post-cfg.sh` invites drift and ordering surprises. Pick one home per rule.

**The mesh firewall is forced into `post-cfg.sh`.** The rules that gate what
tailnet peers reach over the advertised LAN routes reference `tailscale0` —
installed by the community fork, invisible to Alta's dashboard. So the INFRA-68
firewall lives in `post-cfg.sh`, full stop, regardless of A/B choices.

**Recommendation — mirror the pattern you already built for the edge.** The
homelab's `ops/edge/firewall/` is exactly this shape and is battle-tested:

| edge (already built) | Route10 equivalent |
|---|---|
| `edge/firewall/rules.json` (+ `rules.schema.json`) | a versioned rules file in this repo |
| `edge/scripts/apply-firewall.sh` (idempotent reconcile) | the apply already lives in `post-cfg.sh` — make it **data-driven** from the rules file instead of inline uci |
| `edge/scripts/verify-firewall.sh` (zero-drift + off-box probe) | a `verify` that asserts the running uci matches the file |

This turns [`post-cfg.sh`](../../scripts/post-cfg.sh) from an imperative script
into a declarative reconciler — the edge idiom, on the box we already control.
Guaranteed to work today, no NDA, no cloud cooperation.

## "Not just firewall" — correct, and it's additive

`post-cfg.sh` is *already* the reconciler for macvlan mgmt-path, eth4 MAC, LCP
tuning, mwan3 `flush_conntrack`, the default-route hook, and daemon launches.
Making it data-driven is **additive, not a rewrite** — a rules file the existing
apply logic consumes. Worth doing precisely because the ruleset is about to grow
(the mesh firewall is coming).

*Adjacent nugget:* `/cfg/.no-auto-update` suppresses Alta firmware auto-updates,
which directly blunts INFRA-68's **R8** ("firmware updates wipe the tailscale
installer"). It has a security tradeoff (you stop getting firmware fixes) — a
discussion item, not a default.

## Cross-agent coordination — a contract, not a bus

Two repos, two agents: **this repo** (`route10`) and the homelab **`ops`**
(a mature Flux GitOps platform with its own issue tracker and `.claude/rules/`).
They share **exactly one seam**:

> **INFRA-68 / the mesh.** Headscale ACLs on the edge ↔ Route10 firewall on the
> advertised LAN routes. Plus the LAN contract: subnets, service VIPs, ACL tags,
> what Route10 advertises — concrete values live in `ops/NETWORK-CONTRACT.md`
> (see postscript), deliberately not duplicated here.

Everything else is independent. **The gap today:** `ops` tracks INFRA-68 in its
`ISSUES.md`; this repo has **zero awareness of it**. That invisibility *is* the
coordination problem — there's no shared source of truth for the seam.

**Right-sized fix, using conventions that already exist** (don't build a message
bus for one async seam):

1. **One shared "network contract" file** — the seam's source of truth:
   advertised subnets, reserved VIPs, ACL tags + what each grants, the firewall
   policy on advertised routes, and who-owns-which-half. Home it in **`ops`** (the
   platform system-of-record); this repo *references* it. Change the contract
   *first*, then each side reconciles to it — neither side moves the seam
   unilaterally.
2. **A `.claude/rules/mesh-seam.md` in both repos**, modelled on `ops`'s
   `.claude/rules/media-boundary.md` (a hard, imperative, cross-repo binding).
   States the contract's location and the "contract-first" discipline so *both*
   agents obey it without a live channel.
3. **Handoff = git + the existing issue tracker.** The agents run async; INFRA-68
   already exists in `ops`. Add a one-line pointer here (in `CLAUDE.md` or a
   memory) so INFRA-68 stops being invisible to this side. That single line closes
   the gap agent-mapping found.

A literal shared inbox / real-time message bus is overkill for one asynchronous
seam; git PRs + the contract file give durable, reviewable, replayable handoff.
Reach for something heavier only if the seam grows many moving parts.

> Implementing items 1–2 touches **both** repos, so it's coordinated work with the
> homelab agent, not a route10-only edit — a future step, once we decide to build.

## Ranked options (the summary)

| Rank | Move | Serves | Effort | Risk |
|---|---|---|---|---|
| **1** | Make `post-cfg.sh` a data-driven firewall reconciler (mirror `edge/firewall/`) | A | Low | Low — extends a proven path |
| **2** | Network-contract file in `ops` + `mesh-seam.md` rule in both repos | Coordination | Low | Low — pure docs/convention |
| **3** | Git-track the dashboard firewall JSON; import on change | A (supported tier) | Low | Low, but manual apply |
| **4** | Spike: does self-hosted Alta Control expose `/api/` locally? | Unblocks B-vs-automated-A | Med | Answers the load-bearing unknown |
| **5** | Evaluate self-hosted Alta Control as the config master | B | Med-High | Cert/NTP/firmware tax; may cost automated A |
| **6** | Request Alta's NDA API | A (automated + supported) | Low | NDA limits what we open-source |
| — | Watch the OpenWrt mainline port | A **and** B, ultimate | — | Loses dashboard/cloud/all workarounds; long horizon |

**Sequence when we're ready to build:** 1 and 2 are the no-regret moves — they
help under *every* B decision. 4 (the Control-API spike) is the thing to resolve
*before* committing to B, because it decides whether off-cloud and automated
config-as-code can coexist.

## Postscript (same day, 2026-07-14)

The ops-side agent built items 1–2 within hours: **`ops/NETWORK-CONTRACT.md`**
(the seam's source of truth) and **`ops/.claude/rules/mesh-seam.md`**; this
repo's mirror is [mesh-seam.md](./mesh-seam.md), summarized in `CLAUDE.md`.
One discipline was added on review: **contract values are never duplicated into
committed files on either side** — repo files point at the contract; only the
reconciler's rendered state on the router itself carries the values.

## Sources

Alta Control (Docker/LXD), NDA API, firewall JSON import/export, community Go SDK
`mikeee/altalabs-go`, cloud-sync RE (`SkytheFolf/Alta-Route10-RE`,
`forum.openwrt.org/t/alta-labs-route10/219841`) — full URLs in the 2026-07-14
research session. Homelab seam: `ops` `ISSUES.md` INFRA-68, `runbooks/edge.md`,
`epics/EPIC-01.md`. Segmentation context: [network-segmentation.md](./network-segmentation.md).
