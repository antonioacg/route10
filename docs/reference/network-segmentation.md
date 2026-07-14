# Home network segmentation

Design note for the LAN-side segmentation of the home network — how Route10, the
managed switch, opi5pro (k3s), the Wi-Fi bulbs, and the planned EPIC-01 edge cluster
fit together, and what's actually worth building.

> Interactive version: [`network-segmentation.html`](./network-segmentation.html)
> (open in a browser — toggle **Today / Proposed**, click any node for the why + the fix).

## The one idea

Defenses live in **three layers**, and VLANs are the *smallest* of them. Remote access
and workload rules are already handled by the mesh and by Kubernetes. A VLAN only earns
its keep for **one** job: stopping a hacked smart bulb from reaching your laptop — and
that job is blocked by the current Wi-Fi AP. So: fix the real exposure cheaply, don't
over-build VLANs.

## The three layers

| Layer | Stops | Status |
|-------|-------|--------|
| **1 · Mesh & firewall** (Headscale ACLs + Route10 rules on advertised routes) | Strangers reaching your stuff *remotely* | **Decided** — "Tailscale-native, no client VLAN" (EPIC-01) |
| **2 · Kubernetes NetworkPolicy** (default-deny; qBittorrent egress excludes RFC1918) | A *workload* reaching your LAN | **Live** — torrent pod already can't touch private IPs |
| **3 · L2 VLAN** | A hacked bulb reaching your laptop/server *on the wire* | **Blocked** — single-SSID AP can't tag the bulbs |

The punchline: a big VLAN build-out mostly duplicates layers 1 and 2. The thing VLANs
uniquely give you (L2 isolation of untrusted local devices) is gated on the **AP**, not
on the router or switch.

## The map — Today vs Proposed

Current LAN is one flat segment: `192.168.10.0/24`, Route10 = router + DHCP. MetalLB (L2)
publishes cluster services onto it — **ingress `.240`**, **AdGuard DNS `.241`**. AdGuard
rewrites `*.net.aac.gd` / `*.internal` → the ingress VIP.

Node-by-node (what's exposed today → the fix):

| Node | Today | Proposed |
|------|-------|----------|
| **You, away** | No private way in — VPN not built yet | Join the Headscale mesh; no open ports on the router |
| **Public viewer** (Jellyfin) | Nothing exposed | Public name → edge → mesh → Jellyfin; nothing else reachable |
| **Edge cluster** (OCI VPS, EPIC-01) | Planned | The only machine with a public IP; terminates public TLS, pipes home over the mesh |
| **Route10** | One flat net — can't firewall device-to-device on the same wire | Enforces zone rules; its admin page moves onto a locked **Mgmt VLAN**. Also becomes the mesh subnet-router |
| **Managed switch** | Carrying one flat VLAN | Trunks Mgmt today; ready for Servers/IoT later |
| **Your devices** (Trust) | Share one L2 with the bulbs and the k3s API | Own zone; reaches services + controls bulbs, nothing untrusted reaches back |
| **opi5pro** (Servers) | **k3s API `:6443` open to every LAN device** ⚠️ | `ufw` locks `:6443` to you + tailnet; separate Servers VLAN optional later |
| **Smart bulbs** (IoT) | **Can't be isolated — AP can't tag them** ⚠️ | A VLAN-capable AP moves them to an IoT zone — the one job VLANs are truly for |

The two red items today are the k3s API being open to the whole LAN, and the bulbs sharing
an L2 with your trusted devices.

## Do this, in order

Highest impact for least effort first.

1. **Firewall the k3s API — `ufw` on opi5pro.** Allow `:6443` only from you + the tailnet.
   Biggest local exposure, zero rewiring, and `ufw` already runs on that host.
   *(effort low · impact high)*
2. **A Management VLAN** for router/switch/AP admin pages. Extra-justified because Route10
   is about to bridge the mesh into the LAN, making it security-critical.
   *(effort low · impact med)*
3. **A VLAN-capable Access Point (Alta).** The gate for *any* real bulb isolation — one
   SSID → IoT VLAN, same controller. Everything IoT (incl. a clean HomeAssistant split)
   waits on this. *(effort med · impact high for IoT)*

Deliberately **not** to-dos:

4. **HOLD — a separate Servers VLAN for opi5pro.** Only a modest gain over the `ufw` rule,
   and it collides with the edge plan's hard-wired `192.168.10.240` (reverse-ingress
   upstream + Route10 subnet-route advertisement + AdGuard split-DNS + MetalLB pool). If
   ever done, pick the subnet *before* the edge cluster bakes it in. Note also: with
   HomeAssistant coming, splitting opi5pro off adds a cross-VLAN mDNS-discovery problem to
   reach the bulbs — verify Route10 even supports mDNS reflection first.
5. **DON'T — a dedicated VLAN for your own devices.** Already replaced by Tailscale-native
   segmentation in the edge plan; building it just duplicates the mesh layer.

## Context locked by other plans

These were decided elsewhere and constrain the above:

- **VPN = Headscale** (self-hosted on the OCI edge cluster), not NetBird. The "tunnel" is
  **mesh-as-transport reverse ingress**: edge ingress-nginx terminates public TLS and
  proxies to the home ingress VIP `192.168.10.240` over the mesh (Route10 advertises the
  LAN). No Cloudflare Tunnel — Cloudflare is retired entirely.
- **DNS = split-horizon.** AdGuard = LAN "inside" view (keeps its MetalLB VIP); edge
  PowerDNS = outside authoritative for `aac.gd`. A DNS secondary was consciously declined
  → if opi5pro is down, the LAN loses inside-view resolution (accepted).
- **MetalLB stays** — it's how AdGuard + ingress get stable LAN IPs. It's the LAN door;
  the mesh is the internet door. Not in conflict with the "tunnel-only WAN" architecture.
- **Torrent = classic qBittorrent, no egress VPN for now**, contained by a `p2pEgress`
  NetworkPolicy that allows all TCP/UDP to `0.0.0.0/0` *except* RFC1918 — so the torrent
  pod already can't reach the LAN. That's segmentation at the netpol layer, not the VLAN
  layer. ("No VPN" is an egress/privacy call — the home IP sits in swarms — which no VLAN
  would change anyway.)
