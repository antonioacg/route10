#!/bin/sh
# /cfg/post-cfg.sh — Alta-blessed MACVLAN mgmt path to the GPON SFP stick in W2.
# Source: forum.alta.inc/t/4589 (Alta-MikeD, posts 36/45/48/51).
#
# What it does:
#   - Creates a MACVLAN child device `ont_mgmt0` on eth4 (parent = stick cage).
#   - Gives Route10 192.168.1.2/24 on that child, so it can reach stick at 192.168.1.1.
#   - Puts the child in its own firewall zone `ont_mgmt` with FORWARD=REJECT.
#   - DOES NOT add any lan→ont_mgmt forwarding rule — stick UI is reachable ONLY
#     from Route10's own root shell (Level-1 restriction per user choice 2026-05-25).
#
# What it does NOT touch:
#   - route-swd (stays running — no SerDes flap concern)
#   - any existing LAN config
#
# What it does touch on pppd:
#   - Loosens wan3's LCP-echo tolerance from the upstream OpenWrt default
#     "5 1" (5s) to "5 5" (25s). See the wan3 section below.
#
# Idempotent. Safe to re-run (Alta configd calls this after every config reapply).

set -e

# ── seam values (rendered from ops/NETWORK-CONTRACT.md; router-local, NOT in repo) ─
# /cfg/seam.env carries the shared LAN/mesh contract values (e.g. the LAN ULA)
# so they are never committed into this repo — a committed copy of a contract
# value would be a second authority for it (the coupling the seam rule forbids;
# see docs/reference/mesh-seam.md). Absent file or unset var → every consumer
# below is a clean no-op. Render it on the router from the contract; never here.
[ -f /cfg/seam.env ] && . /cfg/seam.env

# ── tailscale mesh boot hook (INFRA-68) ──────────────────────────────────────
# Launch the Tailscale boot script if installed. It re-creates the tmpfs-wiped
# /etc/init.d/tailscale, re-adds the tailscale0 firewall + WAN MASQUERADE
# (WAN_IFACE=pppoe-wan3), and starts tailscaled — internet-waiting and
# self-reverting on failure. Idempotent; absent file = clean no-op. Installed by
# the route10-owned fork antonioacg/alta-route10-tailscale, whose installer also
# adds this same line to the live /cfg/post-cfg.sh — keeping it here is what
# survives a future post-cfg redeploy (drift protection).
[ -x /cfg/tailscale-post-cfg.sh ] && /cfg/tailscale-post-cfg.sh &

# ── network ────────────────────────────────────────────────────────────────
uci set network.ont_mgmt_dev=device
uci set network.ont_mgmt_dev.type='macvlan'
uci set network.ont_mgmt_dev.ifname='eth4'
uci set network.ont_mgmt_dev.mode='bridge'
uci set network.ont_mgmt_dev.name='ont_mgmt0'

uci set network.ont_mgmt=interface
uci set network.ont_mgmt.device='ont_mgmt0'
uci set network.ont_mgmt.proto='static'
uci set network.ont_mgmt.ipaddr='192.168.1.2'
uci set network.ont_mgmt.netmask='255.255.255.0'

uci commit network

# ── firewall ───────────────────────────────────────────────────────────────
uci set firewall.ont_mgmt=zone
uci set firewall.ont_mgmt.name='ont_mgmt'
uci -q delete firewall.ont_mgmt.network 2>/dev/null || true
uci add_list firewall.ont_mgmt.network='ont_mgmt'
uci set firewall.ont_mgmt.input='ACCEPT'    # Route10 itself can talk to stick
uci set firewall.ont_mgmt.output='ACCEPT'
uci set firewall.ont_mgmt.forward='REJECT'  # no LAN forwarding (Level 1)

uci commit firewall

# ── eth4 MAC override (fresh identity for stuck-BNG-session recovery) ─────
# Brazilian residential BNGs key the PPPoE session by GPON SN + dialing MAC.
# When our pppd terminates without a PADT (e.g. LCP-echo failure during an
# ISP-side packet-loss burst), the BNG retains the session keyed by the
# dialing MAC. Subsequent redials from the same MAC get AUTH_TOPEER_FAILED
# until the BNG times us out (15 min–2 h observed).
#
# We use a locally-administered MAC (`02:` prefix per IEEE 802) that has
# definitely never been used on this ISP — so even if the BNG remembers
# every MAC it has ever seen, this one is fresh. We deliberately avoid
# cloning the Huawei WAN MAC (E0:DA:90:C4:F8:86) because:
#   1. That MAC may carry other ghost state at the ISP from past dials.
#   2. If the user ever swaps fibre to the actual Huawei in bridge mode,
#      its internal PPPoE client could conflict with our cloned identity.
#
# See incident memory `project_mwan3_anycast_false_drop.md` for the full
# causal chain.
#
# This must be on the `eth4` device (the PPP underlay), not on `pppoe-wan3`
# itself — pppd inherits the source MAC of its underlying device.
#
# Side-effects:
#   - Brief eth4 link bounce on first application (≤2 s).
#   - ont_mgmt0 MACVLAN keeps its own derived MAC, unaffected.
WANT_ETH4_MAC='02:11:22:33:44:56'
ETH4_DEV_SECTION=$(uci show network 2>/dev/null | awk -F. '/\.name=.eth4./ {print $2; exit}')
CUR_ETH4_MAC=""
if [ -n "$ETH4_DEV_SECTION" ]; then
    CUR_ETH4_MAC=$(uci -q get "network.$ETH4_DEV_SECTION.macaddr" 2>/dev/null || true)
fi
# Compare lowercase to be tolerant of EUI case differences.
if [ "$(echo "$CUR_ETH4_MAC" | tr 'A-Z' 'a-z')" != "$(echo "$WANT_ETH4_MAC" | tr 'A-Z' 'a-z')" ]; then
    if [ -z "$ETH4_DEV_SECTION" ]; then
        ETH4_DEV_SECTION=$(uci add network device)
        uci set "network.$ETH4_DEV_SECTION.name=eth4"
    fi
    uci set "network.$ETH4_DEV_SECTION.macaddr=$WANT_ETH4_MAC"
    uci commit network
    # Reload network so the device-level MAC override is consumed and pppd
    # is restarted with the new source MAC. `ifup wan3` alone won't reset
    # eth4's hardware MAC.
    /etc/init.d/network reload >/dev/null 2>&1 || true
fi

# ── pppd LCP echo tolerance (wan + wan3) ───────────────────────────────────
# Upstream OpenWrt netifd ppp.sh default is keepalive="5 1" → 5 misses × 1 s =
# 5 s tolerance. Too tight for a residential GPON path that sees occasional
# ISP-side packet-loss bursts. At ~30% loss, P(5-in-a-row miss) ≈ 0.24 % per
# cycle → ~once every 7 min pppd will terminate. The session then needs a PADT
# we never send → BNG retains a stale session → next dial gets AUTH_TOPEER_FAILED
# until the BNG times us out (15 min–2 h observed). See incident memory
# `project_mwan3_anycast_false_drop.md` and the 2026-05-28 22:16 outage.
#
# Loosening to "5 5" (5 misses × 5 s = 25 s tolerance) survives realistic loss
# bursts while still detecting a genuine outage within ~half a minute.
#
# Applied to both wan (eth3 — Huawei PPPoE) and wan3 (eth4 — ODI stick PPPoE)
# since they are interchangeable paths to the same ISP / same BNG.
WANT_KEEPALIVE='5 5'
keepalive_pppoe() {
    iface=$1
    # `|| true` because under `set -e` an unset uci key would otherwise abort.
    cur=$(uci -q get "network.$iface.keepalive" 2>/dev/null || true)
    if [ "$cur" != "$WANT_KEEPALIVE" ]; then
        uci set "network.$iface.keepalive=$WANT_KEEPALIVE"
        uci commit network
        # Apply by reloading the interface — picks up the new pppd args. If
        # pppd is in a redial loop (e.g. AUTH_TOPEER_FAILED post-outage)
        # restarting it is at worst a no-op for that scenario; at best it
        # clears stale netifd state.
        ifup "$iface" >/dev/null 2>&1 || true
    fi
}
keepalive_pppoe wan
keepalive_pppoe wan3

# ── LAN IPv6: unbind ip6class so the LAN follows the ACTIVE WAN ─────────────
# Alta's cloud-config pins `network.lan.ip6class` to one WAN's prefix class.
# Their firmware has a staff-confirmed bug (Alta-MikeD, forum.alta.inc
# "No IPv6 on VLAN" #21): "ip6class is not following the active WAN, but
# instead the most recently provisioned/saved WAN (which could be inactive)."
# Staff also note "IPv6 over PPPoE is broken" and "IPv6 isn't supported on
# multiple WANs (yet)".
#
# After we swapped the fibre from the Huawei (eth3 / wan → class `wan6`) to the
# ODI stick (eth4 / wan3 → class `wan36`), the LAN stayed pinned to `wan6`,
# which is now down. So br-lan never receives a /64 from the live `wan36` /60
# PD and the ENTIRE LAN (wired + WiFi) gets no global IPv6 — verified: the
# wan36 PD `2804:2488:5080:4c80::/60` is healthy, but br-lan had only fe80 and
# this Mac on the cable got no v6 (Router field blank in macOS TCP/IP).
#
# Deleting ip6class removes the filter: the LAN then accepts the PD from
# WHICHEVER WAN is delegating (wan36 today, wan6 if we ever swap back to the
# Huawei). `ip6assign='64'` and the dhcpv6/ra server are left untouched, so
# IPv6 stays ENABLED — it just stops being pinned to a dead upstream. Safe
# because we are single-fibre: only one WAN is ever up, so there is no
# multi-prefix conflict. See `project_route10_lan_ipv6_ip6class`.
if [ -n "$(uci -q get network.lan.ip6class 2>/dev/null || true)" ]; then
    uci -q delete network.lan.ip6class 2>/dev/null || true
    uci commit network
    # Re-trigger LAN prefix selection from the active PD. We use `network reload`,
    # NOT `ifup lan`: a full `ifup lan` restarts the bridge interface and MUTES
    # dnsmasq's DHCP until a manual restart (confirmed 5/5 — the 2026-06-24 surge
    # outage; see the post-mortem). `network reload` re-selects the PD and re-pulls
    # the /64 WITHOUT muting dnsmasq (confirmed 3/3) and without bouncing wan3/PPP.
    # dnsmasq (enable-ra, constructor:br-lan) then advertises the new /64 via SLAAC.
    /etc/init.d/network reload >/dev/null 2>&1 || true
fi

# ── LAN ULA — stable v6 for the LAN (the ISP GUA churns on reconnect) ────────
# The Alta portal has NO ULA field: its only LAN IPv6 knobs are "IPv6 Router IP"
# and "IPv6 Prefix ID" (= ip6hint), and that hint is shared with the /60 GUA
# assignment (only 16 subnets, 0-15) — so it cannot reach the contract's ULA
# subnet without breaking the GUA. So we add the ULA as a STATIC address on
# br-lan; Alta's dnsmasq (constructor:br-lan) then advertises this /64 via SLAAC
# ALONGSIDE the untouched GUA. Verified 2026-07-15: LAN clients autoconf a
# ULA address end-to-end, GUA + v4 + wan3/PPP unaffected.
#
# $LAN_ULA comes from /cfg/seam.env (rendered from ops/NETWORK-CONTRACT.md) — the
# value is NEVER hard-coded here (no second authority; see the seam mirror rule).
# This makes the v6 VIPs (…::240/::241) on-link so they become reachable.
if [ -n "$LAN_ULA" ] && ! uci -q get network.lan.ip6addr 2>/dev/null | grep -q "$LAN_ULA"; then
    uci add_list "network.lan.ip6addr=$LAN_ULA"
    uci commit network
    # `network reload` (not `ifup lan`) — re-applies without muting dnsmasq or
    # bouncing wan3/PPP, same rationale as the ip6class block above.
    /etc/init.d/network reload >/dev/null 2>&1 || true
fi

# ── routedns: health-gated AdGuard-primary / DoH-fallback (dnsmasq's upstream) ──
# dnsmasq CANNOT do "AdGuard-first with a public fallback" itself: `strict-order`
# does not apply to `server=` config lines (only /etc/resolv.conf — confirmed by the
# dnsmasq author), so the ~0 ms loopback DoH wins dnsmasq's periodic re-race and
# AdGuard gets bypassed entirely (blocks never apply); and any co-equal DoH sibling
# leaks blocks regardless. routedns (folbricht/routedns — a single static aarch64 Go
# binary sideloaded to /a like tailscaled) fixes it: a `fail-back` group forwards to
# AdGuard (primary) and fails over to the route10-local DoH proxy ONLY on
# no-response/SERVFAIL. A block (0.0.0.0 / NXDOMAIN) is a valid answer, never a
# failure (empty-error/servfail-error default false), so it is NEVER undone; it fails
# back to AdGuard ~60 s after recovery (reset-after default). dnsmasq's GENERAL
# upstream then becomes just 127.0.0.1#5300 (routedns). If the binary is absent or
# fails to come up, RDNS_GENERAL stays unset and the DNS job below degrades to the old
# direct AdGuard+DoH chain — leaky, but never a dead upstream. See
# project_route10_dns_resolver.md.
RDNS_BIN=/a/routedns/routedns
RDNS_CFG=/a/routedns/routedns.toml
RDNS_GENERAL=
if [ -x "$RDNS_BIN" ] && [ -n "$LAN_DNS4" ]; then
    rdns_want=$(cat <<RDNSCFG
[resolvers.adguard]
address = "$LAN_DNS4:53"
protocol = "udp"

[resolvers.doh-fallback]
address = "127.0.0.1:5054"
protocol = "udp"

[groups.failback]
type = "fail-back"
resolvers = ["adguard", "doh-fallback"]

[listeners.local-udp]
address = "127.0.0.1:5300"
protocol = "udp"
resolver = "failback"

[listeners.local-tcp]
address = "127.0.0.1:5300"
protocol = "tcp"
resolver = "failback"
RDNSCFG
)
    # Re-render from the seam AdGuard VIP; restart routedns only on a real diff.
    if [ "$rdns_want" != "$(cat "$RDNS_CFG" 2>/dev/null || true)" ]; then
        printf '%s\n' "$rdns_want" > "$RDNS_CFG"
        kill "$(pidof routedns)" 2>/dev/null || true
    fi
    # Launch if not running; only point dnsmasq at it once it's actually up.
    if ! pidof routedns >/dev/null 2>&1; then
        setsid "$RDNS_BIN" "$RDNS_CFG" </dev/null >/dev/null 2>&1 &
        sleep 1
    fi
    pidof routedns >/dev/null 2>&1 && RDNS_GENERAL="127.0.0.1#5300"
fi

# ── LAN DNS: route10 as the SOLE resolver ────────────────────────────────────
# The Alta cloud hands clients TWO co-equal resolvers (AdGuard + Cloudflare). A
# client-side secondary is NOT failover: OSes race / round-robin them, so a client
# intermittently queries the public resolver directly and gets the split-horizon
# STUB (e.g. searxng.$SPLIT_DOMAIN → 192.0.2.1 → hang — the "searxng drops" report).
# Fix: advertise ONLY route10 as the resolver (Alta portal DNS-Servers field → the
# router itself) and forward from here:
#   - GENERAL names → routedns (127.0.0.1#5300, health-gated AdGuard/DoH failover).
#   - pin $SPLIT_DOMAIN → AdGuard-direct (v4+v6), NO fallback: inside-view names never
#     reach a public resolver, so they SERVFAIL (not the misleading 192.0.2.1 stub/
#     hang) during an AdGuard outage — the services behind them are down then anyway.
#   - ECS (add-subnet): once route10 (.1) is the forwarder, single-box AdGuard would
#     see one source and lose per-client identity; add-subnet re-injects the client
#     subnet so AdGuard can identify clients again (ops enables ECS consumption).
# WAN-safe: `dnsmasq reload` only (re-reads uci + conf-dir) — no fw3/network reload,
# no eth4 flap. The cloud resets the upstream each boot, so this re-asserts on every
# post-cfg run (idempotent; reloads only on a real diff).
#
# Contract values ($LAN_DNS4/$LAN_DNS6 = AdGuard resolver VIPs, $SPLIT_DOMAIN = the
# split-horizon zone) come from /cfg/seam.env — NEVER hardcoded here (no second
# authority; same rule as $LAN_ULA above). Absent → clean no-op: route10 keeps its
# cloud-set upstream, exactly today's behaviour. The 127.0.0.1#505x DoH fallbacks
# are route10-local (https-dns-proxy instances), not contract values.
if [ -n "$LAN_DNS4" ] && [ -n "$LAN_DNS6" ] && [ -n "$SPLIT_DOMAIN" ]; then
    # Upstream: pin(v4)+pin(v6) → AdGuard-direct for $SPLIT_DOMAIN (no fallback →
    # SERVFAIL, never a stub-leak, when AdGuard is down); everything else → routedns
    # (health-gated failover). If routedns is unavailable, degrade to the old direct
    # AdGuard+DoH chain rather than point dnsmasq at a dead upstream.
    if [ -n "$RDNS_GENERAL" ]; then
        set -- "/$SPLIT_DOMAIN/$LAN_DNS4" "/$SPLIT_DOMAIN/$LAN_DNS6" "$RDNS_GENERAL"
    else
        set -- \
            "/$SPLIT_DOMAIN/$LAN_DNS4" "/$SPLIT_DOMAIN/$LAN_DNS6" \
            "$LAN_DNS4" "$LAN_DNS6" \
            "127.0.0.1#5054" "127.0.0.1#5053" "127.0.0.1#5055"
    fi
    DNS_DIRTY=0
    # server list — rewrite only if it differs (cloud resets it to DoH-only each boot).
    want=$(printf '%s\n' "$@")
    have=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | tr ' ' '\n' || true)
    if [ "$want" != "$have" ]; then
        uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
        for s in "$@"; do uci add_list dhcp.@dnsmasq[0].server="$s"; done
        DNS_DIRTY=1
    fi
    # strict-order ON, allservers OFF. Cloud ships allservers='1' (parallel query) —
    # that would let a DoH fallback beat AdGuard and return the stub. Both required.
    [ "$(uci -q get dhcp.@dnsmasq[0].strictorder 2>/dev/null || true)" = "1" ] || { uci set dhcp.@dnsmasq[0].strictorder=1; DNS_DIRTY=1; }
    [ "$(uci -q get dhcp.@dnsmasq[0].allservers  2>/dev/null || true)" = "0" ] || { uci set dhcp.@dnsmasq[0].allservers=0;  DNS_DIRTY=1; }
    # rebind allow-list: AdGuard returns a PRIVATE v4 (.240) for the PUBLIC
    # $SPLIT_DOMAIN — textbook DNS-rebind shape. Allow it so the answer survives if
    # rebind_protection is ever enabled (keeps the cloud's /manage.alta.inc/ entry).
    if ! uci -q get dhcp.@dnsmasq[0].rebind_domain 2>/dev/null | grep -qF "/$SPLIT_DOMAIN/"; then
        uci add_list dhcp.@dnsmasq[0].rebind_domain="/$SPLIT_DOMAIN/"; DNS_DIRTY=1
    fi
    # ECS: no uci mapping for add-subnet on this dnsmasq build (only addmac), so
    # write it into the conf-dir dnsmasq already includes (/tmp/dnsmasq.d). /tmp is
    # tmpfs → recreate each run, same boot-reinstall idiom as the hooks below.
    ECS_CONF=/tmp/dnsmasq.d/10-route10-ecs.conf
    if ! grep -qs '^add-subnet=32,128$' "$ECS_CONF"; then
        mkdir -p /tmp/dnsmasq.d && printf 'add-subnet=32,128\n' > "$ECS_CONF"; DNS_DIRTY=1
    fi
    # Mesh split-DNS (seam point 3): let dnsmasq also ANSWER on tailscale0 so a mesh
    # client pointed at route10 (Headscale split-DNS net.aac.gd -> 192.168.10.1, via
    # the advertised subnet route) gets this same AdGuard-first + DoH chain instead of
    # hitting AdGuard .241 directly with no fallback. dnsmasq is interface=br-lan +
    # bind-dynamic, so it neither binds the tailnet address nor accepts a query that
    # INGRESSES on tailscale0 (even one destined to the br-lan .1) — bind-dynamic does
    # per-arrival-interface access control. Adding tailscale0 to the interface list
    # fixes both (binds 100.64.0.2/fd7a::2 AND accepts .1-dest arrivals on tailscale0).
    # Firewall already accepts it (-A INPUT -i tailscale0 -j ACCEPT). DNS-only — DHCP/RA
    # is driven by the `config dhcp` sections (dhcp.lan->'lan'), not this list. Guarded
    # on tailscale0 existing; bind-dynamic tolerates the iface coming/going.
    if [ -d /sys/class/net/tailscale0 ] \
       && ! uci -q get dhcp.@dnsmasq[0].interface 2>/dev/null | grep -qw tailscale0; then
        uci add_list dhcp.@dnsmasq[0].interface='tailscale0'; DNS_DIRTY=1
    fi
    if [ "$DNS_DIRTY" = "1" ]; then
        uci commit dhcp
        # reload, NOT restart — re-reads uci + conf-dir without an interface bounce.
        /etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
    fi
fi

# ── mwan3 flush_conntrack — drop 'connected' / 'disconnected' ──────────────
# Alta ships `flush_conntrack = ['ifup','ifdown','connected','disconnected']`
# in their cloud-config generator for every WAN interface. Upstream OpenWrt
# mwan3 ships an EMPTY list. The two extra entries are the foot-gun: when
# mwan3 false-flags any WAN as offline/online (e.g. an ICMP-loss burst that
# beats reliability), it runs `conntrack -F` and every live TCP session
# through that WAN dies.
#
# We're effectively single-WAN at any given moment (one fibre, plugged into
# either W2/stick→wan3 or eth3/Huawei→wan, with wan2 unused). There is no
# failover target whose NAT state needs clearing — those two entries serve
# zero defensive purpose for us on any of the three. Keeping `ifup`/`ifdown`
# is correct: those are REAL netifd events that fire on actual PPP
# renegotiation, when the public IP can change and stale NAT entries would
# blackhole returns.
#
# We apply to wan, wan2, wan3 so the protection covers every fibre-swap
# permutation without needing to know which is currently primary.
#
# Risk: post-cfg.sh re-firing after each cloud reapply should keep this
# alive (verified empirically for network/firewall/dhcp; extrapolated for
# mwan3). See `project_mwan3_anycast_false_drop.md` and the cloud-overwrite
# memory.
WANT_FLUSH='ifup ifdown'
flush_conntrack_minimize() {
    iface=$1
    # `|| true` because under `set -e` an unset uci key or missing section
    # would otherwise abort the whole script.
    cur=$(uci -q get "mwan3.$iface.flush_conntrack" 2>/dev/null || true)
    # uci returns the list space-separated; normalize for compare.
    cur_norm=$(echo "$cur" | tr -d "'" | tr -s ' ' | sed 's/^ //;s/ $//')
    if [ "$cur_norm" = "$WANT_FLUSH" ]; then
        return 0
    fi
    uci -q delete "mwan3.$iface.flush_conntrack" 2>/dev/null || true
    uci add_list "mwan3.$iface.flush_conntrack=ifup"
    uci add_list "mwan3.$iface.flush_conntrack=ifdown"
    # Mark "did something" so we can do a single reload at the end (cheaper
    # than reloading per-iface).
    MWAN3_DIRTY=1
}
MWAN3_DIRTY=0
flush_conntrack_minimize wan
flush_conntrack_minimize wan2
flush_conntrack_minimize wan3
if [ "$MWAN3_DIRTY" = "1" ]; then
    uci commit mwan3
    /etc/init.d/mwan3 reload >/dev/null 2>&1 || true
fi

# ── terminfo for non-standard $TERM values (e.g. xterm-ghostty) ────────────
# Route10's `/` is tmpfs — /usr/share/terminfo and /etc/terminfo evaporate
# on reboot. We keep additional terminfo entries persistently in
# /cfg/terminfo/<first-letter>/<term-name> and surface them in BOTH
# canonical ncurses lookup paths:
#   - /etc/terminfo                            (some ncurses builds search this)
#   - /usr/share/terminfo/<letter>/<term-name> (the compiled-in default)
#
# ncurses on this image only has `/usr/share/terminfo` in its hardcoded
# search list (verified with `strings /usr/lib/libncursesw.so.6`), so the
# /usr/share/terminfo symlinks are the load-bearing ones. Keeping the
# /etc/terminfo symlink as a backup for tools that bypass the hardcoded path.
#
# Currently shipped: /cfg/terminfo/x/xterm-ghostty  (for Ghostty SSH).
# To add another terminal: scp its compiled terminfo file into the right
# subdir under /cfg/terminfo/ (organized by first letter, lowercase).
if [ -d /cfg/terminfo ]; then
    [ -L /etc/terminfo ] || ln -sfn /cfg/terminfo /etc/terminfo
    for srcdir in /cfg/terminfo/*/; do
        [ -d "$srcdir" ] || continue
        letter=$(basename "$srcdir")
        mkdir -p "/usr/share/terminfo/$letter"
        for f in "$srcdir"*; do
            [ -f "$f" ] || continue
            name=$(basename "$f")
            ln -sfn "$f" "/usr/share/terminfo/$letter/$name"
        done
    done
fi

# ── apply ──────────────────────────────────────────────────────────────────
# Only reload if something actually changed (avoids needless flaps on every reapply).
if ! ip link show ont_mgmt0 >/dev/null 2>&1; then
    ifup ont_mgmt
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
elif ! ip -4 addr show ont_mgmt0 | grep -q "192.168.1.2"; then
    ifup ont_mgmt
fi

# ── per-host connection cap — CGNAT session-exhaustion guard ────────────────
# A single LAN host running a P2P/torrent client opens ~1000+ simultaneous flows
# (DHT + peer swarm). Each needs a NAT mapping on our SHARED CGNAT WAN IP. The
# ISP CGNAT enforces a per-subscriber session cap; the swarm exhausts it, and the
# ISP CGNAT hop then rejects our OTHER new connections (any v4 dest) with ICMP
# "admin prohibited filter" → the kernel surfaces EHOSTUNREACH. Confirmed
# 2026-07-18: orangepi5pro (192.168.10.200) torrent client → 1384 flows →
# intermittent 40-92% failure to github/all v4. IPv6 was immune (native GUA, no
# CGNAT). See memory project_route10_cgnat_torrent_exhaustion.
#
# Guard: cap concurrent NEW connections per LAN host on the internet-bound path
# (br-lan → pppoe-wan3), two tiers —
#   WARN  logs (tag route10.connlimit: greppable in /var/log/messages and
#         forwarded to the homelab syslog collector once log_ip is set),
#   BLOCK rejects further NEW flows so no single host can run the CGNAT table dry.
# Only --ctstate NEW is matched, so ESTABLISHED flows are never touched and
# under-limit hosts are unaffected — a capped host just can't open MORE. Two
# families, two jobs, so thresholds differ (set below):
#   v4 = TIGHT CGNAT defense. The exhaustion vector is the ISP's per-subscriber
#        CGNAT session table — v4-only (v6 has native per-device GUAs, no CGNAT).
#   v6 = LOOSE anomaly SMELL. No CGNAT to protect, and route10's conntrack table is
#        500k (verified 2026-07-20 — never the bottleneck), so the v6 tier exists
#        only as a "something is very wrong" signal: WARN logs a host opening a
#        wildly abnormal number of flows (compromised / runaway app), with a high
#        BLOCK as a last-ditch runaway stop that ~never fires. Set well above any
#        legit heavy host so it never false-positives. Per-/128 catches the common
#        single-address case; a client spraying SLAAC privacy addresses evades it —
#        fine for a smell heuristic, not a hard cap.
#
# Portal-inexpressible (advanced firewall) → belongs here, not the Alta dashboard
# (portal-first rule). Implemented as direct iptables into a dedicated chain,
# rebuilt each run so threshold edits below apply cleanly, plus a single guarded
# jump from FORWARD. No fw3 reload → no eth4/WAN bounce. Thresholds are per-host,
# per-family concurrent-connection counts — tune here. Data from the 2026-07-18
# incident: the ISP CGNAT starves this WHOLE subscriber at ~1000 concurrent
# mappings — github was clean with orangepi5pro (.200) holding ~870, but a
# WHOLE-LAN v4 outage hit once it reached ~1130 (BLOCK=800 let it). Also note the
# per-host footprint runs ~250-330 ABOVE the BLOCK number right after a rebuild
# (connlimit counts only flows it has observed; older ones linger), so BLOCK≈500
# keeps that host + the rest of the LAN under the ~1000 cap with margin. A normal
# heavy desktop rarely exceeds ~300. Going laxer trades LAN-wide CGNAT safety for
# one host's torrent headroom — 800 was too lax and caused the outage above. The
# durable fix is taming the client (peer-limit) or moving it to IPv6 (no CGNAT).
CONNLIMIT_V4_WARN=300;  CONNLIMIT_V4_BLOCK=500    # v4: tight — ISP CGNAT ceiling (800 caused an outage; keep <~900)
CONNLIMIT_V6_WARN=1000; CONNLIMIT_V6_BLOCK=2000   # v6: loose — anomaly smell only (conntrack_max is 500k)
install_connlimit_guard() {
    # -w: wait for the xtables lock. post-cfg launches the tailscale boot hook in
    # the background (top of file), which also edits iptables; without -w our
    # calls race it, fail, and get swallowed by `|| true`, leaving the guard half
    # applied (confirmed 2026-07-18: missing v6 jump + duplicated rules).
    ipt="$1 -w 10"; mask=$2; icmpreject=$3; warn=$4; block=$5
    mark="route10-connlimit-w${warn}b${block}"
    $ipt -N RT10_CONNLIMIT 2>/dev/null || true
    # Rebuild the chain ONLY when it is absent or the thresholds changed — the
    # trailing marker rule encodes the active WARN/BLOCK. Skipping an unchanged
    # rebuild preserves connlimit's live accounting, so a post-cfg re-run (e.g.
    # after a cloud reapply) never flushes the counters and briefly un-protects a
    # host mid-flood. A real threshold edit changes the marker → clean rebuild.
    if ! $ipt -S RT10_CONNLIMIT 2>/dev/null | grep -q -- "$mark"; then
        $ipt -F RT10_CONNLIMIT 2>/dev/null || true
        # WARN: log (rate-limited, non-terminating) — the "rogue client" smell signal.
        $ipt -A RT10_CONNLIMIT -m conntrack --ctstate NEW \
            -m connlimit --connlimit-above "$warn" --connlimit-mask "$mask" --connlimit-saddr \
            -m limit --limit 6/hour --limit-burst 5 \
            -j LOG --log-prefix "route10.connlimit warn: " --log-level warning 2>/dev/null || true
        # BLOCK: reject further NEW flows from an over-cap host (existing flows survive).
        # A firewall reject can't carry text — the client only gets an errno — so pick
        # the one that reads as "something said no", not "the network is broken":
        #   TCP  → tcp-reset             → app sees "Connection refused" (fast, no retry)
        #   else → ICMP port-unreachable → the UDP "refused" equivalent
        # We deliberately do NOT use admin/host-unreachable: those surface as the
        # misleading "Host is unreachable" — the string the ISP CGNAT sent when IT
        # starved us. The real "why" lives in the route10.connlimit WARN log above.
        $ipt -A RT10_CONNLIMIT -p tcp -m conntrack --ctstate NEW \
            -m connlimit --connlimit-above "$block" --connlimit-mask "$mask" --connlimit-saddr \
            -j REJECT --reject-with tcp-reset 2>/dev/null || true
        $ipt -A RT10_CONNLIMIT -m conntrack --ctstate NEW \
            -m connlimit --connlimit-above "$block" --connlimit-mask "$mask" --connlimit-saddr \
            -j REJECT --reject-with "$icmpreject" 2>/dev/null || true
        # Marker: encodes the active thresholds so the next run can skip an unchanged
        # rebuild. RETURN is a no-op (the chain returns at its end anyway).
        $ipt -A RT10_CONNLIMIT -m comment --comment "$mark" -j RETURN 2>/dev/null || true
    fi
    # Single guarded jump, scoped to internet-bound LAN traffic only.
    if ! $ipt -C FORWARD -i br-lan -o pppoe-wan3 -j RT10_CONNLIMIT 2>/dev/null; then
        $ipt -I FORWARD 1 -i br-lan -o pppoe-wan3 -j RT10_CONNLIMIT 2>/dev/null || true
    fi
}
install_connlimit_guard iptables  32  icmp-port-unreachable  "$CONNLIMIT_V4_WARN" "$CONNLIMIT_V4_BLOCK"
install_connlimit_guard ip6tables 128 icmp6-port-unreachable "$CONNLIMIT_V6_WARN" "$CONNLIMIT_V6_BLOCK"

# ── WAN default-route hook (netifd proto_set_keep reconnect bug) ─────────────
# netifd drops the WAN default route on PPP reconnect: its cache still believes
# the route is installed, so it never reprograms the kernel (confirmed in netifd
# source). `/` is tmpfs, so on every boot install our fix two ways — no daemon:
#   1. symlink the ip-up.d hook so pppd re-asserts the v4+v6 default route on
#      every link-up (instant recovery);
#   2. a 1-minute cron backstop running the SAME hook (idempotent, silent when
#      healthy). See the 2026-07-08 wan3-route-loss post-mortem.
HOOK=/cfg/scripts/route-defaultroute-hook.sh
if [ -x "$HOOK" ]; then
    ln -sfn "$HOOK" /etc/ppp/ip-up.d/50-route10-defaultroute
    if ! grep -qF "$HOOK" /etc/crontabs/root 2>/dev/null; then
        echo "* * * * * $HOOK" >> /etc/crontabs/root
        /etc/init.d/cron reload >/dev/null 2>&1 || true
    fi
fi

# ── LAN IPv6 prefix-rotation deprecation (stale-prefix self-heal) ─────────────
# When the ISP rotates our delegated /64 (PPP reconnect / cloud reapply), dnsmasq
# stops advertising the old prefix but never DEPRECATES it — the rotation
# coincides with a dnsmasq restart that wipes its memory of the outgoing prefix,
# so no preferred-lifetime-0 RA ever goes out. Every LAN host then keeps the dead
# /64 *preferred* for up to 24 h (RFC 4862) and source-selects it for new flows
# the ISP no longer routes → the whole LAN is stuck. lan-prefix-track.sh watches
# for the rotation and emits the deprecation RA (via ra-deprecate.py) itself.
# Same tmpfs-reinstall + 1-minute-cron pattern as the route hook; no daemon.
# Confirmed 2026-07-15 (stale 2804:2488:5083:8830:: on every device after the
# 2026-07-14 flap). See lan-prefix-track.sh + ra-deprecate.py.
TRACK=/cfg/scripts/lan-prefix-track.sh
PFXHOTPLUG=/cfg/scripts/hotplug-lan-prefix.sh
if [ -x "$TRACK" ]; then
    # Event (near-instant): a hotplug.d/iface hook fires the tracker on netifd
    # ifup/ifupdate — the DHCPv6-PD rotation lands as ifupdate. /etc is tmpfs so
    # (re)install the symlink each boot, same as the route hook's ip-up.d symlink.
    [ -x "$PFXHOTPLUG" ] && ln -sfn "$PFXHOTPLUG" /etc/hotplug.d/iface/89-lan-prefix
    # Backstop (guaranteed): 1-minute cron catches any transition the event misses.
    if ! grep -qF "$TRACK" /etc/crontabs/root 2>/dev/null; then
        echo "* * * * * $TRACK" >> /etc/crontabs/root
        /etc/init.d/cron reload >/dev/null 2>&1 || true
    fi
fi

# ── mesh drift smoke tests (tailscale ACL enforcement) ───────────────────────
# mesh-health.sh asserts every 5 min that (1) tailscaled isn't running a stale/
# deleted binary and (2) the compiled ACL filter admits every advertised subnet
# route. Catches the 2026-07-20 failure class — a stale daemon silently dropping
# all mesh→subnet traffic while the policy still granted it (declared intent vs
# live enforcement). Cron-driven, quiet when healthy, no daemon; reinstalled each
# boot (/etc is tmpfs), same idiom as the hooks above. See scripts/mesh-health.sh
# + project_route10_tailscale_stale_binary_filter.md.
MESHHEALTH=/cfg/scripts/mesh-health.sh
if [ -x "$MESHHEALTH" ]; then
    if ! grep -qF "$MESHHEALTH" /etc/crontabs/root 2>/dev/null; then
        echo "*/5 * * * * $MESHHEALTH" >> /etc/crontabs/root
        /etc/init.d/cron reload >/dev/null 2>&1 || true
    fi
fi

# ── daemons ────────────────────────────────────────────────────────────────
# Idempotent launchers — only start each daemon if not already running.
# pgrep -f matches the full command line, including the script path, so the
# check survives shells that exec the script as $0.
launch_if_absent() {
    script="$1"
    # Match only the actual /bin/sh execution of the script — not a random
    # `ash -c "...$script..."` wrapper (e.g. an ad-hoc SSH command whose argv
    # happens to contain the script path), which a bare `pgrep -f $script`
    # would falsely treat as "already running".
    if [ -x "$script" ] && ! pgrep -f "^/bin/sh $script\$" >/dev/null 2>&1; then
        # </dev/null is essential — without it the child inherits the caller's
        # stdin (often an SSH pty); when SSH disconnects, the child eventually
        # dies on the next stdin operation even with nohup. setsid fully
        # detaches from the controlling terminal as a belt-and-suspenders.
        setsid nohup "$script" </dev/null >/dev/null 2>&1 &
    fi
}

# odi-health.sh — 5-min health log (PPP, ping RTT, thermals, L4+W2 DDM, switch
# Rx-error/CRC counters). Absorbed flap-hunt's switch-CRC sampling on retirement.
launch_if_absent /cfg/scripts/odi-health.sh
# daemon-odi-w2-ddm.sh — bridge Boa /status_pon.asp -> i2c slave A2 page
# so rcstats picks up W2 DDM and the Alta dashboard shows full 5-field DDM
# the same way it does for the L4 cage. See reference_odi_ddm_blocker.md.
launch_if_absent /cfg/scripts/daemon-odi-w2-ddm.sh
# dhcp-watchdog.sh — detect & auto-recover a MUTE dnsmasq (the 2026-06-24 surge
# failure mode). Safety net for ANY dnsmasq DHCP mute, whatever the cause.
launch_if_absent /cfg/scripts/dhcp-watchdog.sh
# NOTE: flap-hunt.sh + lcp-watch.sh were RETIRED 2026-07-15 (deletion test): flap-hunt
# was ~95% redundant (carrier→kernel log, ppp→pppd log, boa-liveness dup of the ddm
# daemon, heartbeat dup of odi-health) with its one unique bit (switch CRC) folded
# above; lcp-watch never fired (lcp-echo-adaptive => LCP_SENT=0) and its only
# consumer was flap-hunt. Recoverable from git if a future LCP/flap probe is needed.
exit 0
