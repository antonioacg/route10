"""signatures.py — every failure shape seen on this network, as code. THIS FILE IS THE MEMORY
of the net-triage skill: the classification table lives here, not in prose.

Each rule reads ONLY the facts dict built by analyze.build_facts (plus the derived
coverage curve) and returns one of:
    hit(evidence)   it matches; evidence = the numbers that made it match
    miss(why)       checked and it doesn't; say what was seen (negative results are data)
    na(why)         can't be checked from this capture (missing source, no --client, ...)

Adding a rule (STEP 5 of the skill):
  1. `since` = the incident date and its entry in docs/incidents/net-triage-log.md.
  2. `conf` = CONFIRMED only when the measurement that proved it is written there;
     otherwise SUSPECTED. A suspicion repeated is still a suspicion.
  3. Save the capture that taught it as a fixture (net-triage --save-fixture) and make
     expect.json say the TRUE verdict, then `net-triage --selftest`.
  4. Thresholds come from measured incidents. Write the measurement next to the number.
"""
import statistics

RULES = []


class Rule:
    def __init__(self, id_, since, conf, weight, fn):
        self.id, self.since, self.conf, self.weight, self.fn = id_, since, conf, weight, fn


def rule(id_, since, conf, weight):
    def deco(fn):
        RULES.append(Rule(id_, since, conf, weight, fn))
        return fn
    return deco


def hit(ev):
    return "hit", ev


def miss(ev):
    return "miss", ev


def na(ev):
    return "na", ev


def evaluate(f, cov):
    out = []
    for r in RULES:
        try:
            st, ev = r.fn(f, cov)
        except Exception as e:      # one broken rule must not hide the others
            st, ev = "na", "rule crashed: %s: %s" % (e.__class__.__name__, e)
        out.append({"id": r.id, "status": st, "evidence": ev, "confidence": r.conf,
                    "since": r.since, "weight": r.weight})
    return out

# ── shared predicates ───────────────────────────────────────────────────────


def _hm(t):
    import time
    return time.strftime("%H:%MZ", time.gmtime(t)) if t else "?"


def wan_problems(f):
    """[] when the WAN/PON path looks clean in this capture, else the reasons."""
    w, p, why = f.get("wan") or {}, f.get("pon"), []
    if not w.get("wan3_up") and not w.get("wan2_up"):
        why.append("no WAN up")
    if not w.get("default4"):
        why.append("no v4 default route")
    if w.get("mwan_policy") == []:
        why.append("mwan3 balance policy is empty (no usable WAN)")
    if p and (p.get("non_o5") or any(p["alarms"].values()) or p.get("fec_unc_delta", 0) > 0):
        why.append("PON not clean")
    rtt = [o["rtt"] for o in w.get("odi", []) if o.get("rtt")]
    if rtt and max(rtt) > 60:
        why.append("PPP-gw RTT %.0f ms" % max(rtt))
    return why


def client_stations(f):
    c = f.get("client") or {}
    macs = set(c.get("macs", [])) | set((c.get("linked") or {}).keys())
    return {m: s for m, s in f["wifi"]["stations"].items() if m in macs}


def retry_of(s):
    r = s.get("retry_15m")
    if r is None and s.get("live"):
        r = s["live"].get("retry_pct")
    return r

# ── WAN / ISP ───────────────────────────────────────────────────────────────


@rule("probe-broken", "2026-08-12", "CONFIRMED", 99)
def _probe_broken(f, cov):
    """v4 AND v6 dead to every host = the probe, not the network (BusyBox nc + self-inflicted
    rate limit read as an outage, while another machine pulled 500 Mbit/s)."""
    tp = (f.get("mac") or {}).get("tput") or []
    if not tp:
        return na("no throughput run (--no-speed or retrospective)")
    if all(t["mbps"] is None for t in tp):
        return hit("all %d downloads (v4+v6, 2 hosts) failed: suspect THIS probe/vantage before the network" % len(tp))
    return miss("%d/%d downloads worked" % (sum(1 for t in tp if t["mbps"]), len(tp)))


@rule("wan-down", "2026-10-29", "CONFIRMED", 100)
def _wan_down(f, cov):
    w = f.get("wan") or {}
    if w.get("wan3_up") is None and not w.get("odi"):
        return na("no WAN status (route10 collector failed?)")
    if not w.get("wan3_up") and not w.get("wan2_up"):
        return hit("wan3 DOWN and no fallback WAN up")
    if not w.get("default4"):
        return hit("no IPv4 default route (2026-07 wan3-reconnect class: route-defaultroute-hook should heal)")
    down = [o for o in w.get("odi", []) if o.get("up") == "false"]
    if down:
        return hit("odi-health saw wan3 down at %s" % ", ".join(_hm(o["t"]) for o in down[:5]))
    return miss("wan3 up %.1f d, v4 via %s" % ((w.get("wan3_uptime") or 0) / 86400, w.get("default4")))


@rule("mwan3-policy-drift", "2026-11-04", "CONFIRMED", 95)
def _mwan3(f, cov):
    """iface_state online while the tracker says offline: all v4 stuck on a dead WAN (4h51m on 11-04)."""
    m = (f.get("wan") or {}).get("mwan") or {}
    if not m:
        return na("no mwan3 state")
    bad = ["%s state=%s track=%s" % (k, v.get("iface_state"), v.get("track")) for k, v in m.items()
           if v.get("iface_state") and v.get("track") and v["iface_state"] != v["track"]]
    return hit("; ".join(bad) + " (route-hook cron heals on its 2nd run)") if bad else miss("states agree")


@rule("no-ipv6-prefix", "2026-11-06", "CONFIRMED", 60)
def _no_pd(f, cov):
    """PPP up but no delegated prefix: LAN has no v6 egress while the router's own v6 works."""
    w = f.get("wan") or {}
    if w.get("v6_prefix") is None:
        return na("no wan36 status")
    if w.get("wan36_up") and not w["v6_prefix"]:
        return hit("wan36 up with ipv6-prefix [] — LAN v6 dead; route-hook redials after 10 min")
    return miss("prefix %s" % ",".join(w["v6_prefix"]))


@rule("pon-layer-fault", "2026-10-29", "CONFIRMED", 90)
def _pon(f, cov):
    """Stick out of O5, or DS PLOAM/BWMAP CRC errors with LOS clear and flat Rx power."""
    p = f.get("pon")
    if not p:
        return na("no pon rows in window (pon-collect stale or stick dark)")
    why = []
    if p["non_o5"]:
        why.append("states %s from %s" % (sorted({s for _, s in p["non_o5"]}), _hm(p["non_o5"][0][0])))
    if any(p["alarms"].values()):
        why.append("alarms %s" % p["alarms"])
    for k in ("ploam_crc_delta", "bw_crc_delta", "fec_unc_delta"):
        if p.get(k, 0) > 0:
            why.append("%s +%d" % (k[:-6], p[k]))
    if p.get("ranging_req_max", 0) >= 3:
        why.append("ranging_req %d/cycle (admit-then-drop loop)" % p["ranging_req_max"])
    if p.get("omci_req", 0) >= 20 and p.get("omci_retx", 0) / p["omci_req"] > 0.05:
        why.append("OMCI upstream loss %.0f%%" % (100 * p["omci_retx"] / p["omci_req"]))
    return hit("; ".join(why)) if why else miss("O5 throughout, alarms 0, CRC/FEC flat")


@rule("stick-reload-loop", "2026-10-30", "CONFIRMED", 95)
def _reload_loop(f, cov):
    """CHAP OK then the session dies ~0.3 s later: `cfg -r vpns` reloading the network (post-cfg job 14)."""
    n = (f.get("logs") or {}).get("cfg_reload_after_ppp", 0)
    return hit("%d PPP sessions followed by 'cfg: Found interface config changes' within 5 s" % n) if n >= 2 \
        else miss("%d" % n)


@rule("upstream-of-onu", "2026-08-13", "SUSPECTED", 80)
def _upstream(f, cov):
    """Clean local stack (O5, FEC 0, DNS fast, gateway clean) yet a WIRED vantage gets little."""
    mc = f.get("mac") or {}
    tp = [t["mbps"] for t in mc.get("tput") or [] if t["mbps"] is not None]
    if len(tp) < 2:
        return na("needs ≥2 throughput results")
    if mc.get("medium") != "wired":
        return na("vantage is not wired (%s): its Wi-Fi would confound it" % mc.get("medium"))
    if wan_problems(f):
        return miss("local path not clean: %s" % ", ".join(wan_problems(f)))
    if max(tp) < 50:
        return hit("best of %d downloads %.0f Mbit/s on a wired vantage with PON/gateway/DNS clean" % (len(tp), max(tp)))
    return miss("best download %.0f Mbit/s" % max(tp))


@rule("bufferbloat", "2026-05-28", "SUSPECTED", 50)
def _bloat(f, cov):
    mc = f.get("mac") or {}
    a, b = (mc.get("inet") or {}).get("avg"), (mc.get("loaded") or {}).get("avg")
    if a is None or b is None:
        return na("no idle/loaded latency pair")
    return hit("8.8.8.8 %.0f → %.0f ms under load" % (a, b)) if b - a >= 30 else miss("+%.1f ms under load" % (b - a))


@rule("cgnat-pressure", "2026-08-05", "CONFIRMED", 60)
def _cgnat(f, cov):
    """One LAN host's flows exhausting the ISP CGNAT (v4 EHOSTUNREACH, v6 fine). Torrents on .200.
    ⚠ connlimit is blind to churn-shaped hosts (the decoder .20, 2026-08-20): read top4 too."""
    cl = f.get("connlimit") or []
    ct = f.get("ct")
    if cl:
        srcs = {}
        for x in cl:
            srcs[x[3]] = srcs.get(x[3], 0) + 1
        return hit("connlimit lines: %s" % ", ".join("%s ×%d" % kv for kv in srcs.items()))
    if not ct:
        return na("no conntrack samples")
    # Measured: the CGNAT starved at ~1400 WAN v4 flows; a BLOCK at 800 still caused an outage.
    # One host near 300 is .200's normal p2p level, not pressure (2026-11-18 first run).
    big = {ip: n for ip, n in ct["top4_max"].items() if n >= 300}
    if ct["wan4_max"] >= 800:
        return hit("WAN v4 flows max %d (danger from ~800, starved at ~1400); hosts ≥300: %s" % (ct["wan4_max"], big))
    return miss("WAN v4 flows max %d; hosts ≥300: %s" % (ct["wan4_max"], big or "none"))


@rule("dns-path-down", "2026-08-10", "CONFIRMED", 60)
def _dns(f, cov):
    """AdGuard rung down (opi5pro) = every LAN query slower and ad-blocking OFF; routedns ≥800 ms =
    the DoH fallback is carrying everything."""
    d = f.get("dns_ladder")
    mc = (f.get("mac") or {}).get("dns") or []
    why = []
    if d:
        if d["down_minutes"]:
            why.append("ladder rungs down: %s (first %s)" % (d["down_minutes"], {k: _hm(v) for k, v in d["down_first"].items()}))
        if d["rdns_ms_max"] >= 800:
            why.append("routedns up to %d ms (DoH fallback active)" % d["rdns_ms_max"])
    bad = [x for x in mc if x["kind"] == "uncached" and x["status"] not in ("NOERROR", "NXDOMAIN")]
    if mc and len(bad) == len([x for x in mc if x["kind"] == "uncached"]):
        why.append("this Mac's uncached lookups failed on every resolver")
    if not d and not mc:
        return na("no DNS data")
    return hit("; ".join(why)) if why else miss("ladder up; Mac lookups %s" % ", ".join("%s %s" % (x["server"], x["status"]) for x in mc if x["kind"] == "uncached"))

# ── mesh / fences ───────────────────────────────────────────────────────────


@rule("mesh-down", "2026-10-02", "CONFIRMED", 70)
def _mesh_down(f, cov):
    """route10 off the mesh: tailnet clients lose *.net.aac.gd and, with an exit node, everything."""
    m = f.get("mesh")
    if not m:
        return na("no tailscale status")
    return miss("Running") if m.get("state") == "Running" else hit("BackendState=%s" % m.get("state"))


@rule("mesh-netmap-churn", "2026-10-26", "CONFIRMED", 50)
def _churn(f, cov):
    """Route set flapping → full tunnel rebuild on every peer (VPN icon, Chrome 'network changed').
    ⛔ probes can't see it: confirm with `route -n monitor` on a peer across a :x0:01 tick."""
    lg = f.get("logs") or {}
    if lg.get("mesh_drift", 0) >= 2 or lg.get("rc_rerun", 0) >= 3:
        return hit("%d mesh-health drift heals, %d Alta agent re-applies in window" % (lg.get("mesh_drift", 0), lg.get("rc_rerun", 0)))
    return miss("%d drift heals, %d re-applies" % (lg.get("mesh_drift", 0), lg.get("rc_rerun", 0)))


@rule("edge-node-into-lan", "2026-11-16", "CONFIRMED", 85)
def _edge(f, cov):
    """RT10_EDGEMESH dropped something: the edge's mesh node tried the LAN. Nothing legitimate does."""
    b = [x for x in f["fence"]["blocks"] if x[1] == "route10.edge-mesh"]
    d = sum((v.get("delta_8s") or 0) for v in f["fence"]["chains"].get("RT10_EDGEMESH", {}).values())
    return hit("%d log lines, +%d drops in 8 s — tell ops (security)" % (len(b), d)) if b or d else miss("quiet")


@rule("mesh-allow-closed", "2026-11-17", "CONFIRMED", 55)
def _mesh_allow(f, cov):
    """An allowlist entry is closed (key mismatch / status unreadable) or the chain is dropping."""
    m = f.get("mesh") or {}
    states = [s for s in m.get("allow_states", []) if " err " in " %s " % s or " warn " in " %s " % s]
    b = [x for x in f["fence"]["blocks"] if x[1] == "route10.mesh-fwd"]
    d = sum((v.get("delta_8s") or 0) for v in f["fence"]["chains"].get("RT10_MESHFWD", {}).values())
    if states or b or d:
        return hit("states %s; %d block lines; +%d drops in 8 s" % (states, len(b), d))
    return miss("no closed entries, no drops")


@rule("lan-fence-hits-client", "2026-11-18", "CONFIRMED", 45)
def _lancgnat(f, cov):
    """The client hit RT10_LANCGNAT (LAN → 100.64/10). One hit right at join is an iPhone's
    MagicDNS query leaking before its tunnel is up: benign (2026-11-18, 1 packet). Repeated hits
    mean something on the device really depends on a mesh/CGNAT address via the LAN."""
    c = f.get("client")
    if not c:
        return na("no --client")
    hits = c.get("fence_hits", {}).get("lancgnat") or []
    if len(hits) >= 3:
        return hit("%d hits, last %s" % (len(hits), _hm(hits[-1])))
    return miss("%d hit(s)%s" % (len(hits), " at %s — join-time leak, benign" % _hm(hits[0]) if hits else ""))

# ── Wi-Fi / LAN ─────────────────────────────────────────────────────────────


@rule("weak-wifi-coverage", "2026-11-18", "CONFIRMED", 40)
def _coverage(f, cov):
    """The client is at the edge of the AP's range and the rest of the band says so too: retries
    follow RSSI across every station. Measured 2026-11-18: iPhone on 2.4 GHz at −69…−77 dBm,
    55–136% retries, 11 Mbit/s uplink, WAN clean; −43 dBm peer 2%, −60 ~20%, −66 ~35%."""
    if not f.get("client"):
        weak = ["%s %s %d dBm %s%%" % (s.get("name") or m, s.get("band"), s["rssi"], retry_of(s))
                for m, s in f["wifi"]["stations"].items()
                if s.get("rssi") is not None and s["rssi"] <= -70 and (retry_of(s) or 0) >= 50]
        return na("no --client; weak stations now: %s" % (", ".join(weak) or "none"))
    st = client_stations(f)
    if not st:
        return na("client not associated to the AX73 now (wired, other AP, or gone)")
    out = []
    for mac, s in st.items():
        r, rssi = retry_of(s), s.get("rssi")
        if r is None or rssi is None:
            continue
        floor = -68 if s.get("band") == "2.4G" else -70
        if rssi <= floor and r >= 50:
            c = (cov.get(s.get("band")) or {})
            corr = c.get("rank_corr")
            n = len(c.get("points") or [])
            curve = "curve unverified (%d stations)" % n if corr is None else \
                "retries follow RSSI across %d stations (corr %.2f)" % (n, corr) if corr <= -0.5 else \
                "retries only loosely follow RSSI (corr %.2f, %d stations)" % (corr, n) if corr < 0 else \
                "retries do NOT follow RSSI (corr %.2f): range alone doesn't explain it" % corr
            hist = (f["wifi"]["history"].get(mac) or {}).get("rssi") or []
            moved = ""
            for lm in (f["client"].get("linked") or {}):
                h = (f["wifi"]["history"].get(lm) or {}).get("rssi") or []
                if h:
                    moved = "; before switching it was on %s, %d → %d dBm" % ((f["wifi"]["history"][lm].get("ssid") or "?"), max(v for _, v in h), h[-1][1])
            prob = wan_problems(f)
            out.append("%s on %s at %d dBm (%s), retries %d%%, uplink %s Mbit/s; %s%s; WAN %s" % (
                s.get("name") or mac, s.get("band"), rssi, "range %d…%d" % (min(v for _, v in hist), max(v for _, v in hist)) if hist else "now",
                r, s.get("rx_rate_mbps"), curve, moved, "clean" if not prob else "NOT clean: " + ", ".join(prob)))
    if out:
        return hit(" | ".join(out))
    return miss("; ".join("%s %s %s dBm retries %s%%" % (s.get("name") or m, s.get("band"), s.get("rssi"), retry_of(s)) for m, s in st.items()))


@rule("client-radio-outlier", "2026-11-18", "SUSPECTED", 40)
def _outlier(f, cov):
    """The client retries far more than stations at the same signal: its own radio/driver/power
    save, not range or the AP."""
    st = client_stations(f)
    if not st:
        return na("client not on the AX73" if f.get("client") else "no --client")
    out = []
    for mac, s in st.items():
        r, rssi = retry_of(s), s.get("rssi")
        if r is None or rssi is None:
            continue
        peers = [p[1] for p in (cov.get(s.get("band")) or {}).get("points", []) if p[2] != mac and abs(p[0] - rssi) <= 6]
        if len(peers) >= 2 and r >= 50 and r >= 2 * max(statistics.median(peers), 10):
            out.append("%s %d%% at %d dBm vs peers ±6 dB median %d%%" % (s.get("name") or mac, r, rssi, statistics.median(peers)))
    return hit("; ".join(out)) if out else miss("in line with peers at similar signal (or too few peers)")


@rule("airtime-congestion-2g4", "2026-11-18", "SUSPECTED", 20)
def _airtime(f, cov):
    """Channel airtime eaten by neighbours (obss) or non-Wi-Fi energy. First reading 2026-11-18:
    2.4 GHz ch10 48% busy, obss 32%, knoise −83 (5 GHz: 7% busy)."""
    rs = [(r, c) for r, c in f["wifi"]["radios"].items() if c.get("band") == "2.4G" and c.get("busy") is not None]
    if not rs:
        return na("no chanim_stats (ax73 ssh collector)")
    r, c = rs[0]
    s = "%s ch%s busy %s%% (max %s), obss %s%%, non-wifi %s%%" % (r, c.get("channel"), c["busy"], c.get("busy_max"), c.get("obss"), c.get("nocat"))
    return hit(s) if c["busy"] >= 60 or (c.get("obss") or 0) >= 40 or (c.get("nocat") or 0) >= 20 else miss(s)


@rule("tuya-join-outage", "2026-10-01", "CONFIRMED", 40)
def _tuya(f, cov):
    """A Tuya device (re)joining 2.4 GHz precedes multi-minute downstream loss to 2.4 GHz clients
    (14/16 vacuum outages). Trigger CONFIRMED, mechanism inside the AP UNKNOWN. Needs a LAN probe
    target that is really ON the AX73 2.4 GHz radio: the vacuum moved off it by 2026-11-18."""
    tuya = ("70:89:76", "84:e3:42", "50:8b:b9")
    joins = sorted({x[0] for x in f.get("dhcp", []) if x[2] and x[2][:8] in tuya and x[1] in ("DHCPDISCOVER", "DHCPREQUEST")}
                   | {e[0] for e in f["wifi"]["events"] if e[2][:8] in tuya and e[3] in ("E_ASSOC_IND", "E_REASSOC_IND")})
    # A canary must answer ICMP when healthy: a dozing iPhone lost ≥80% in 35 of 45 minutes and a
    # firewalled laptop in all of them (2026-11-18), which read as endless "outages".
    canaries, deaf = {}, []
    for n, q in (f.get("lanq") or {}).items():
        if not (q.get("where") or "").startswith("wifi:2.4G"):
            continue
        rows = [r for r in q["rows"] if r[1]]
        if rows and sum(1 for r in rows if (r[2] or 0) >= 80) <= 0.3 * len(rows):
            canaries[n] = q
        else:
            deaf.append(n)
    if not canaries:
        where = {n: q.get("where") for n, q in (f.get("lanq") or {}).items() if q.get("medium") == "wifi"}
        return na("no usable LAN-probe target on the AX73 2.4 GHz radio (wifi targets at %s; deaf to ICMP: %s); Tuya (re)joins in window: %d" % (where, deaf or "none", len(joins)))
    out = []
    for n, q in canaries.items():
        rows = q["rows"]
        for i in range(1, len(rows)):
            a, b = rows[i - 1], rows[i]
            if a[1] and b[1] and (a[2] or 0) >= 80 and (b[2] or 0) >= 80 and (i < 2 or not ((rows[i - 2][2] or 0) >= 80)):
                onset = a[0]
                pre = [j for j in joins if 0 <= onset - j <= 300]
                out.append("%s lost from %s%s" % (n, _hm(onset), ", Tuya joined %d s before" % (onset - pre[-1]) if pre else ", no Tuya join before"))
    if any("Tuya joined" in o for o in out):
        return hit("; ".join(out))
    return miss("; ".join(out) if out else "no ≥2-min loss on %s; Tuya (re)joins in window: %d" % (", ".join(canaries), len(joins)))


@rule("ap-deauth-storm", "2026-11-18", "SUSPECTED", 15)
def _deauth(f, cov):
    """A station in an auth/deauth loop (seen: Tuya 84:e3:42:08:76:fe, ~10/s at 11:51Z 11-18).
    Effect on other clients unmeasured."""
    if not f["wifi"]["events"]:
        return na("no AP association log")
    n = {}
    for e in f["wifi"]["events"]:
        if e[3] in ("E_DEAUTH", "E_DEAUTH_IND", "E_DISASSOC_IND") and e[0] >= f["meta"]["from"]:
            n[e[2]] = n.get(e[2], 0) + 1
    loud = {m: c for m, c in n.items() if c >= 10}
    return hit(", ".join("%s ×%d" % kv for kv in loud.items())) if loud else miss("max %d per station" % max(n.values() or [0]))


@rule("ssid-switch", "2026-11-18", "CONFIRMED", 5)
def _ssid_switch(f, cov):
    """Info: the client changed network mid-window (iOS: one private MAC per SSID, so it shows as a
    new device). Often the user fleeing a weak band — read both identities' timelines."""
    c = f.get("client")
    if not c:
        return na("no --client")
    return hit("; ".join("%s: %s" % kv for kv in c["linked"].items())) if c.get("linked") else miss("one identity")


@rule("client-unanswered-syn", "2026-08-19", "CONFIRMED", 30)
def _syn(f, cov):
    """The reported symptom itself: SYNs that never establish. ⚠ p2p hosts (.200) sit at 27–37%
    while healthy — read a host against its own baseline."""
    c = f.get("client")
    if not c:
        return na("no --client")
    cap, st = c.get("capture") or {}, c.get("stall") or {}
    if any(v.get("syn", 0) >= 10 for v in st.values()):
        return hit("obs-collect stall %s" % st)
    if cap.get("syn_out", 0) >= 5 and cap.get("synack_in", 0) == 0:
        return hit("live capture: %d SYN out, 0 SYN-ACK in" % cap["syn_out"])
    return miss("stall %s; capture SYN %s/%s" % (st or "none", cap.get("syn_out"), cap.get("synack_in")))


@rule("lan-fiber-eth5", "2026-08-20", "CONFIRMED", 50)
def _eth5(f, cov):
    """Office LAN fiber CRC/flaps mimic an ISP outage for everything behind eth5."""
    g = f.get("guards")
    if not g:
        return na("no samples")
    if (g.get("eth5_crc") or 0) > 0 or (g.get("eth5_flaps") or 0) > 0:
        return hit("eth5 CRC +%s, flaps +%s" % (g.get("eth5_crc"), g.get("eth5_flaps")))
    return miss("eth5 CRC/flaps flat")


@rule("mesh-egress-guard", "2026-10-27", "CONFIRMED", 30)
def _meg(f, cov):
    """Something tried to leave the WAN with a tailnet source (RT10_MESHEGRESS; baseline 0)."""
    g = f.get("guards")
    if not g:
        return na("no samples")
    d = (g.get("mesh_egress_v4") or 0) + (g.get("mesh_egress_v6") or 0)
    return hit("+%d v4 / +%d v6 in window" % (g.get("mesh_egress_v4") or 0, g.get("mesh_egress_v6") or 0)) if d else miss("flat")
