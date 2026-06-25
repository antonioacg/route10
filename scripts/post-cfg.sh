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

# odi-health.sh — overnight + daytime health log (was launched manually before)
launch_if_absent /cfg/scripts/odi-health.sh
# daemon-odi-w2-ddm.sh — bridge Boa /status_pon.asp -> i2c slave A2 page
# so rcstats picks up W2 DDM and the Alta dashboard shows full 5-field DDM
# the same way it does for the L4 cage. See reference_odi_ddm_blocker.md.
launch_if_absent /cfg/scripts/daemon-odi-w2-ddm.sh
# lcp-watch.sh — PPPoE LCP-echo headroom telemetry on `pppoe-wan3`.
# Tiny event-driven daemon; state file /var/run/.lcp-state.env is constant
# size and overwritten atomically. flap-hunt consumes its output. Start it
# BEFORE flap-hunt so the state file exists when flap-hunt's first heartbeat
# fires.
launch_if_absent /cfg/scripts/lcp-watch.sh
# flap-hunt.sh — sub-minute event detector (2 s polling, EVENT-only logging)
# Catches mwan3 track-loss windows, PPP reconnects, eth4 carrier flaps, CRC
# growth, stick Boa liveness fails, LCP miss streaks. See CLAUDE.md.
launch_if_absent /cfg/scripts/flap-hunt.sh
# dhcp-watchdog.sh — detect & auto-recover a MUTE dnsmasq (the 2026-06-24 surge
# failure mode). Safety net for ANY dnsmasq DHCP mute, whatever the cause.
launch_if_absent /cfg/scripts/dhcp-watchdog.sh

exit 0
