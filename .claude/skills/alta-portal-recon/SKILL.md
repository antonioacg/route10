---
name: alta-portal-recon
description: Read-only reconnaissance of the Alta Labs cloud portal (manage.alta.inc) to map its API surface and check whether a capability we currently work around in scripts has landed natively yet. Use when asked to "check the Alta portal", "map Alta's APIs", "can the portal do X yet", "has Alta caught up", or before building/keeping any router-side workaround that shadows portal config. Drives the browser via the playwriter skill.
---

# Alta portal recon (read-only)

The Route10's config is cloud-mastered. Anything the portal can express **should** live
in the portal (`feedback_portal_first_config`), so before building or keeping a
`post-cfg.sh` / script workaround, check whether the portal covers it — and re-check
periodically, because Alta ships features and our workarounds should be retired when
they do.

## ⛔ RULE ZERO — this is READ-ONLY. Never click Save.

**A portal write rewrites `/cfg/config.json`, re-applies config, and flaps eth4 — the
single WAN port on a single fibre. That is a real internet outage, not a nuisance.**
(`feedback_portal_change_bounces_wan`, confirmed 2026-07-15.)

Navigating, opening dialogs, and inspecting fields are all safe. **Saving is not.**
- Never click `Save`, `Apply`, `Reset`, `Import`, or `Delete`.
- To dismiss a dialog, **reload the page** — do not hunt for a Cancel button.
  (Measured: `Escape` does NOT close the Add-rule dialog.)
- Finish every run with the verification in step 5. Do not skip it.

## Step 1 — load playwriter first

Call the **`playwriter`** skill, then run `playwriter skill` and read the output in
full. This skill does not restate playwriter's rules; it composes on top of them.

If `playwriter` is not on PATH, use `npx playwriter@latest` for every command.

## Step 2 — attach to the user's logged-in tab

The user is normally already authenticated at `manage.alta.inc`. Reuse that tab —
do not try to log in.

```bash
npx playwriter@latest session new
npx playwriter@latest -s <N> -e 'console.log(JSON.stringify(context.pages().map((p,i)=>({i,url:p.url()})),null,1))'
```

Attach interception **before** navigating, so you capture the API surface instead of
guessing at it:

```js
state.page = context.pages().find(p => p.url().includes('manage.alta.inc'));
if (!state.page) throw new Error('no alta tab — ask the user to open manage.alta.inc');
state.reqs = []; state.resps = [];
const skip = /\.(js|css|png|jpg|svg|woff2?|ico)(\?|$)/;
state.page.on('request', r => { if(!skip.test(r.url())) state.reqs.push({m:r.method(), u:r.url(), pd:(r.postData()||'').slice(0,400)}); });
state.page.on('response', async r => { if(!skip.test(r.url())){ let b=''; try{ b=(await r.text()).slice(0,300);}catch{} state.resps.push({s:r.status(), u:r.url(), b}); } });
```

Then `reload()` and list distinct `METHOD url` pairs.

## Step 3 — grep the SPA bundle (fastest way to map the surface)

The portal is a React SPA; its bundle names every capability it has, including ones
not reachable from the current page.

```js
state.bundle = await state.page.evaluate(async () => {
  const srcs = Array.from(document.querySelectorAll('script[src]')).map(s => s.src);
  let all = ''; for (const s of srcs) { try { all += await (await fetch(s)).text(); } catch(e){} }
  return all;
});
// then regex state.bundle for the vocabulary you care about
```

⚠ **There are no literal `/api/...` strings in the bundle** — paths are built
dynamically, so a `/api/` regex returns zero and that is a false negative. Grep for
**vocabulary** instead (`firewall`, `redirect`, `portForward`, `dnat`, route
definitions like `path:"firewall"`), then pull ±300 chars of context around hits.

## Step 4 — walk the UI to ground-truth the schema

⚠ **A hard `goto()` to a settings URL renders the dashboard** — client-side routing.
Navigate by clicking (`Settings` → the section button), and use
`--timeout 60000`; the default 10 s times out on this SPA.

Open the relevant Add/Edit dialog and snapshot it **scoped to the dialog** so the
output is readable:

```js
await snapshot({ locator: state.page.locator('[role="dialog"]'), showDiffSinceLastCall: false })
```

The dialog's field list *is* the answer: what the portal can and cannot express.

## Step 5 — MANDATORY verification that you changed nothing

```bash
ssh route10 'date -u -d @$(stat -c %Y /cfg/config.json); date -u'
```

The mtime must be **unchanged and old**. If it just moved, a write happened —
say so immediately and check WAN state (`/sys/class/net/eth4/carrier_changes`).
Also confirm no non-GET calls to anything but the read endpoints below.

## Known API surface (baseline 2026-08-12)

Auth is an **AWS Cognito JWT passed in the POST body** (not a header).

| Endpoint | Method | Notes |
|---|---|---|
| `/api/sites/list` | GET | |
| `/api/device/list` | GET | |
| `/api/wifi/ssid/list` | GET | |
| `/api/sites/stats` | POST | read-only despite POST; token in body |
| `/api/profile/list` | POST | read-only despite POST; token in body |

Static, unauthenticated: `dl.alta.inc/do-not-distribute/fw/{router,ap,switch,public}.json`
(firmware manifests), `dl.alta.inc/static/ouis.json`.

### ⭐ The WRITE path (derived clean-room from the served bundle, 2026-08-12)

Every config write is the **same endpoint with one domain key** — read straight out of
the portal's own Redux thunks, no write performed:

```
POST {api}/site        body: { token, id, <domain>: <value> }
```

```js
// sites/saveFirewall — token from localStorage, id = currentSiteId
fetchjson(`${api}/site`, { method:"POST", body:{ token, id, firewall } })
// identical shape for the rest:
//   saveVlans  -> { token, id, vlans }
//   saveWans   -> { token, id, wans }
//   saveRoutes -> { token, id, routes }
```

Domains seen: `firewall, vlans, wans, routes, portColors, portConfig, radii, pbrRules`
(plus `sites/{addSite,copySite,renameSite,deleteSite}` and
`sites/{createOrUpdateFilter,deleteFilter,deleteProfile,deleteSchedule}`).

⚠ On writes the token goes **in the JSON body** (this resolves the header-vs-query
disagreement between the public Go and Ruby clients, which only covers GETs).
⚠ `saveFirewall` POSTs the firewall object **with** its rule `id`s and merely returns
a `stripFirewallIds()` copy for local state — so ids are sent, not stripped.
⚠ **This shape is read from the client, NOT confirmed by a successful round-trip.**
Executing one is a real config write ⇒ eth4 flap ⇒ WAN drop. Do not "just test it".

This is precisely the gap in `mikeee/altalabs-go` (`UpdateFirewall`/`AddFirewallRule`
return "not implemented"). One generic `saveDomain(siteID, key, value)` implements all
of them — good upstream contribution, and clean-room so it can be offered.

## Capability baseline — diff against this on every run

Settings → **Firewall** has five tabs: **Filter · Port-forward/NAT · Firewall Groups ·
Policy Routing · Intrusion Prevention**.

Filter → `Add` dialog fields: `Enable`, `IP Version` (IPv4/IPv6), `Protocols`,
`Source` (Any|Custom), `Destination` (Any|Custom), `Zone In`, `Zone Out`, `Limit`.

✅ **The portal CAN express an IPv6 WAN→LAN inbound accept** (`Zone In=WAN`,
`Zone Out=LAN`, IPv6, TCP/UDP, custom destination). Do not repeat the 2026-08-12
mistake of concluding otherwise from `/cfg/config.json` — a site with no custom rules
simply has **no `rules` key**, because the portal falls back to a firmware default set
(`r.firewall ? cloneDeep(r.firewall) : cloneDeep(defaults)`). **Absence of the key
means "never configured", NOT "unsupported."**

### Open questions — the reason to re-run this

1. ⛔ **Can `Destination` be prefix-relative?** As of 2026-08-12: **NO** — free-text
   literal CIDR only (`e.g. 1.2.3.4/24`); no variable, prefix token, or client
   reference. **This is the only reason the router-side v6 pinhole exists**: our ISP
   /64 rotates (3× in 2 days), so a literal rule goes stale within hours and repairing
   it costs a WAN flap. **If this gains a variable/host reference, RETIRE the router
   script to the portal.** A community request for exactly this was filed 2024-11-16
   and has **never been answered** — this is the highest-value thing to endorse.
2. ⭐ **Firewall Groups may already be the answer — VERIFY BEFORE BUILDING ANYTHING.**
   The tab exists (`Add` → `Name`, `Type` [default *IPv4 Network*], `Contents`
   textarea "one entry per line"). Published sources say a group of type **IPv6
   Network** can hold an **exact hostname**, resolved backend-side and refreshed on
   DNS TTL — which would convert "track a rotating prefix" into "keep an AAAA
   current", something our prefix-tracker could feed. **NOT independently verified**:
   the Type dropdown detaches on re-render and resisted inspection. Confirm the IPv6
   type exists AND that Contents accepts a hostname before treating this as real.
3. ✅ **Port-forward/NAT** — v4-shaped, no IP-version selector, no IPv6. Closed as a
   path for v6 work; v6 needs a Filter rule, not DNAT.
4. **Is there an API write path that avoids a full reapply?** UNKNOWN, and no public
   client implements a firewall **write** — the Go SDK's `UpdateFirewall()` /
   `AddFirewallRule()` return "not implemented". Likely `POST /api/site`
   partial-per-domain. If a light write path exists, the eth4-flap objection weakens.
5. **Does a firewall-only save actually flap eth4?** UNVERIFIED — the measurement is
   for portal writes generally. Untestable without writing, so do not "just try it".

### Corroborating sources (cheaper than re-deriving)

- **Vendor docs** at `help.alta.inc`. The `/hc/` HTML path **403s**; fetch via the
  Zendesk API instead: `/api/v2/help_center/en-us/articles/<id>.json`. Relevant:
  *Creating Firewall Rules*, *Firewall Groups*, *Port Forwarding*.
- **Reverse-engineered clients**: `mikeee/altalabs-go` (Go, has the rule struct),
  `TwilightCoders/alta_labs` (Ruby). Read paths proven; **no firewall write**.
- **Auth is AWS Cognito SRP** (`USER_SRP_AUTH`, us-east-1), not a portal-minted key.
  The two clients **disagree on token transport** on GET (header vs query param) —
  test both. Config read: `GET /api/site?id=<siteid>`.
- Filter rules are **zone-only**: Alta removed interface in/out because they had no
  effect, so per-VLAN v6 rules are not expressible. Rule `id` is **max 6 alphanumeric**.

## ⛔ CLEAN-ROOM CONSTRAINT — do not pursue the NDA docs

Official API docs exist but are **NDA-gated**. The NDA **was offered to the operator
in a DM and deliberately DECLINED**, because its terms would forbid exactly this kind
of open work and block contributing findings back to the community.

**That is a standing decision, not an open question.** Therefore:

- **Never** suggest signing the NDA, requesting the docs, or nudging staff for them.
  Do not treat "the NDA docs would settle this" as a next step — it is a closed door,
  chosen on purpose.
- Every finding must come from **observable, public sources**: our own browser traffic,
  the client-side bundle we are served, public repos, public help-centre articles,
  public forum posts. Keep it clean-room so it stays publishable and upstreamable.
- The payoff is that anything learned here **can** be shared, filed as a precise
  feature request, or contributed to an open-source client. Protect that.

## Workaround inventory — the audit checklist

Every item below is something the router does **outside** the portal. Each one is a
standing bet that the portal cannot express it. **Most of these bets have never been
tested against the actual portal UI** — that is the gap this skill exists to close.

Mark each as `portal-native now` / `still a gap (field X missing)` / `not checked`.

| Router-side workaround | The portal question to actually test |
|---|---|
| ONU/ONT **management path** (MACVLAN on the WAN port + its own firewall zone) | Can `Networks` create a second L3 address / management interface on a WAN port? Can `Firewall → Firewall Groups`/zones scope it? |
| **v6 inbound pinhole** for the p2p listener | See open question 1 — needs a non-literal destination |
| **LAN ULA** as a static br-lan address | Does `Networks` expose a ULA / secondary IPv6 prefix field? |
| **pppd LCP keepalive** loosened | Any WAN tuning fields? |
| **mwan3 `flush_conntrack`** minimised | Exposed at all? |
| **Per-host connlimit** guard | Anything under `Firewall → Filter`'s `Limit` field, or IPS? |
| **LAN DNS** forwarding order / split domain | Portal DNS fields are known-partial — where exactly does it stop? |
| **LAN NTP server** | Any time-service toggle under `System`? |

⚠ Do not answer these from `/cfg/config.json` or from memory of the portal. **Open the
dialog and read the fields.** The 2026-08-12 firewall error was exactly that shortcut.

## Turning a finding into a forum post worth endorsing

Alta has a community forum, and several of these gaps likely already have requests
filed. An endorsement is only persuasive if it names the gap precisely — "please add
X" is noise; **"the portal gets me 90% there and stops at exactly this field"** is a
spec someone can implement.

So when a gap is confirmed, write it up as:

1. **What the portal already does** — name the exact page, tab, and fields. This shows
   you used the product and stops the reply "that already exists".
2. **The precise field or value that is missing** — e.g. *"`Destination` accepts only a
   literal CIDR; with a rotating ISP prefix there is no way to express `<current
   /64>:<stable IID>`, so the rule goes stale within hours."*
3. **Why the workaround is worse for Alta, not just for us** — a router-side script
   that re-applies firewall state is invisible to the cloud config model and will fight
   it. Vendors care about that.
4. **The smallest change that would close it** — a variable/token, a "track LAN client"
   destination type, or a prefix-relative form. One concrete ask, not a wishlist.

Never post credentials, tokens, site IDs, public IPs, delegated prefixes, or the
contents of `/cfg/seam.env`. Describe the shape of the problem, not our addressing.

## Reporting

State plainly whether each open question changed since the baseline. If a capability
landed, say which router-side workaround it now allows us to **delete** — that is the
entire point of running this. Update the baseline in this file when it moves, and note
the date so the next run knows how stale it is.
