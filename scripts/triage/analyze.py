#!/usr/bin/env python3
"""analyze.py — turn a net-triage capture into facts, run the signatures, print the report.

    analyze.py <capture-dir>                  (net-triage runs this; also `net-triage --replay`)
    analyze.py --selftest                     every fixture in fixtures/ against signatures.py
    analyze.py --save-fixture <name> <dir>    sanitised facts + expect.json -> fixtures/<name>/

Three layers, and keep the boundary: parse_* (raw text -> python), build_facts (one
JSON-able dict, the ONLY thing signatures see), render. A fixture is a facts.json, so a
rule that reached past the facts into raw text could not be replayed or self-tested.

All times are epoch seconds UTC inside; the report prints HH:MMZ.
"""
import calendar
import copy
import hashlib
import json
import os
import re
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True     # no __pycache__ in the repo
import signatures  # noqa: E402

V6_GUA_RE = re.compile(r"\b[23][0-9a-fA-F]{3}:[0-9a-fA-F:]*[0-9a-fA-F:]")
MAC_RE = re.compile(r"\b([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\b")
MON = {m: i for i, m in enumerate("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)}
SYSLOG_RE = re.compile(r"^(\w{3}) +(\d+) (\d\d):(\d\d):(\d\d)(\.\d+)? (\S+) (\S+?)\.(\w+) ([^:\[\s]+)(?:\[\d+\])?: ?(.*)$")
BACKGROUND_CHAINS = ("RT10_ONTEDGE",)   # drops all day by design (neighbours on the ISP segment)
FENCE_RE = re.compile(r"(route10\.[\w-]+) (block|warn|srcwarn): ?(v[46])?")
# AX73 radio prefix -> band is derived from the channel, never assumed from the name.

# ── small helpers ───────────────────────────────────────────────────────────


def hm(t):
    return time.strftime("%H:%MZ", time.gmtime(t)) if t else "--:--"


def hms(t):
    return time.strftime("%H:%M:%SZ", time.gmtime(t)) if t else "--:--:--"


def mac_norm(s):
    s = (s or "").lower().replace("-", ":")
    if re.fullmatch(r"[0-9a-f]{12}", s):
        s = ":".join(s[i:i + 2] for i in range(0, 12, 2))
    return s if re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", s) else None


def short(mac):
    return mac[:8] + ".." + mac[-2:] if mac else "?"


def num(s, default=None):
    try:
        return float(s)
    except (TypeError, ValueError):
        return default


def read(path):
    try:
        with open(path, errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def sections(text, marker="@@ "):
    out, took, cur = {}, {}, None
    for line in text.splitlines():
        if line.startswith("@@took "):
            p = line.split()
            took[p[1]] = num(p[2]) if len(p) > 2 else None
            continue
        if line.startswith(marker):
            cur = line[len(marker):].strip()
            out.setdefault(cur, [])
            continue
        if cur is not None:
            out[cur].append(line)
    return {k: "\n".join(v) for k, v in out.items()}, took


def subsections(text):
    out, cur = {"": []}, ""
    for line in text.splitlines():
        if line.startswith("## "):
            cur = line[3:].strip()
            out.setdefault(cur, [])
            continue
        out.setdefault(cur, []).append(line)
    return {k: "\n".join(v) for k, v in out.items()}


def kv(line):
    return dict(m.groups() for m in re.finditer(r"(\w+)=(\S*)", line))


def rows_ts_json(text):
    rows = {}
    for line in text.splitlines():
        ts, _, js = line.partition("|")
        if not ts.isdigit() or not js.strip():
            continue
        try:
            rows[int(ts)] = json.loads(js)
        except ValueError:
            pass
    return [(t, rows[t]) for t in sorted(rows)]


def rank_corr(xs, ys):
    """Spearman rank correlation, or None under 4 points."""
    if len(xs) < 4:
        return None

    def ranks(v):
        order = sorted(range(len(v)), key=lambda i: v[i])
        r = [0.0] * len(v)
        for pos, i in enumerate(order):
            r[i] = float(pos)
        return r
    rx, ry = ranks(xs), ranks(ys)
    mx, my = statistics.mean(rx), statistics.mean(ry)
    num_ = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = (sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry)) ** 0.5
    return num_ / den if den else None

# ── parsers: route10 ─────────────────────────────────────────────────────────


def parse_syslog(text, now, frm, to):
    year = time.gmtime(now).tm_year
    out = []
    for line in text.splitlines():
        m = SYSLOG_RE.match(line)
        if not m:
            continue
        mon, day, hh, mi, ss, frac, host, fac, sev, prog, msg = m.groups()
        try:
            t = calendar.timegm((year, MON[mon], int(day), int(hh), int(mi), int(ss)))
        except (KeyError, ValueError):
            continue
        if t > now + 86400:
            t = calendar.timegm((year - 1, MON[mon], int(day), int(hh), int(mi), int(ss)))
        t += num(frac, 0.0) or 0.0
        if frm - 600 <= t <= to + 60:
            out.append({"t": t, "sev": sev, "prog": prog, "msg": msg})
    return out


def parse_dhcp(lines):
    ev = []
    for e in lines:
        m = re.match(r"(DHCP\w+)\((\S+)\)\s*(.*)", e["msg"])
        if not m:
            continue
        kind, _, rest = m.groups()
        toks = rest.split()
        mac = ip = host = None
        for tok in toks:
            mn = mac_norm(tok)
            if mn:
                mac = mn
            elif re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){7,}", tok.lower()):   # DUID: MAC is the tail
                mac = mac or mac_norm(tok.lower()[-17:])
            elif re.fullmatch(r"\d+\.\d+\.\d+\.\d+", tok) or (":" in tok and re.fullmatch(r"[0-9a-f:]+", tok.lower())):
                ip = ip or tok
            elif mac:
                host = tok
        ev.append([round(e["t"], 3), kind, mac, ip, host])
    return ev


def parse_fence_lines(lines):
    blocks, connlimit = [], []
    for e in lines:
        if e["prog"] != "kernel":
            continue
        m = FENCE_RE.search(e["msg"])
        if not m:
            continue
        fence, kind, fam = m.groups()
        f = kv(e["msg"])
        srcmac = None
        if f.get("MAC") and len(f["MAC"]) >= 35:
            srcmac = mac_norm(f["MAC"][18:35])
        rec = [round(e["t"], 3), fence, kind, f.get("SRC"), f.get("DST"), f.get("PROTO"), f.get("DPT"), srcmac]
        (connlimit if fence == "route10.connlimit" else blocks).append(rec)
    return blocks, connlimit


def parse_ipt_save(text):
    """{chain: drops} summed over DROP/REJECT rules, per family block."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"\[(\d+):(\d+)\] -A (RT10_\w+) .*-j (DROP|REJECT)", line)
        if m:
            out[m.group(3)] = out.get(m.group(3), 0) + int(m.group(1))
    return out


def parse_recent(text, uptime, hz, now):
    """xt_recent hit times -> epoch. jiffies = uptime*HZ + INITIAL_JIFFIES (64-bit: 2^32-300*HZ)."""
    if not (uptime and hz):
        return {}
    jnow = uptime * hz + (2 ** 32 - 300 * hz)
    out, cur = {}, None
    for line in text.splitlines():
        if line.startswith("### "):
            cur = line[4:].strip()
            out[cur] = {}
            continue
        m = re.match(r"src=(\S+) .*oldest_pkt: \d+ (.*)$", line)
        if cur and m:
            hits = sorted(now - (jnow - int(j)) / hz for j in re.findall(r"\d+", m.group(2)))
            out[cur][m.group(1)] = [round(h, 1) for h in hits]
    return out


def parse_leases(text):
    v4, v6 = {}, []
    for line in text.splitlines():
        p = line.split()
        if len(p) < 4:
            continue
        mac = mac_norm(p[1])
        if mac:
            v4[mac] = {"ip": p[2], "host": None if p[3] == "*" else p[3], "exp": int(p[0]) if p[0].isdigit() else None}
        elif len(p) >= 5:
            v6.append({"ip": p[2], "host": None if p[3] == "*" else p[3], "mac": mac_norm(p[4][-17:])})
    return v4, v6


_OUI = None


def vendor(mac):
    """Vendor from the OUI, via nmap's local table if present. Offline only, by design."""
    global _OUI
    if _OUI is None:
        _OUI = {}
        for path in ("/opt/homebrew/share/nmap/nmap-mac-prefixes", "/usr/local/share/nmap/nmap-mac-prefixes",
                     "/usr/share/nmap/nmap-mac-prefixes"):
            for line in read(path).splitlines():
                if len(line) > 7 and not line.startswith("#"):
                    _OUI[line[:6].upper()] = line[7:].strip()
            if _OUI:
                break
    return _OUI.get((mac or "").replace(":", "")[:6].upper()) if mac else None


def parse_targets(text):
    out = []
    for line in text.splitlines():
        p = line.split()
        if len(p) >= 3:
            out.append({"ip": p[0], "name": p[1], "medium": p[2], "dhcp": p[3] if len(p) > 3 else None})
    return out


def parse_bridge(text):
    ports, macs = {}, {}
    sub = subsections(text)
    for line in sub.get("", "").splitlines():
        m = re.match(r"(\S+) \((\d+)\)", line)
        if m:
            ports[m.group(2)] = m.group(1)
    for line in sub.get("macs", "").splitlines():
        p = line.split()
        if len(p) >= 4 and p[0].isdigit() and mac_norm(p[1]):
            macs[mac_norm(p[1])] = {"port": ports.get(p[0], p[0]), "age": num(p[3]), "local": p[2] == "yes"}
    return macs


def parse_tcpdump(text, ips):
    out = {"pkts": 0, "out": 0, "in": 0, "dns_q": 0, "dns_a": 0, "syn_out": 0, "synack_in": 0,
           "rst_in": 0, "icmp_unreach_from_client": 0, "first": None, "last": None}
    for line in text.splitlines():
        m = re.match(r"(\d+\.\d+) IP6? (\S+) > (\S+?):? (.*)$", line)
        if not m:
            continue
        t, src, dst, rest = float(m.group(1)), m.group(2), m.group(3), m.group(4)
        out["pkts"] += 1
        out["first"] = out["first"] or t
        out["last"] = t
        outbound = any(src.startswith(ip + ".") or src == ip for ip in ips)
        out["out" if outbound else "in"] += 1
        if outbound and dst.rsplit(".", 1)[-1].rstrip(":") == "53":
            out["dns_q"] += 1
        if not outbound and src.rsplit(".", 1)[-1] == "53":
            out["dns_a"] += 1
        if "Flags [S]" in rest and outbound:
            out["syn_out"] += 1
        if "Flags [S.]" in rest and not outbound:
            out["synack_in"] += 1
        if "Flags [R" in rest and not outbound:
            out["rst_in"] += 1
        if outbound and "unreachable" in rest:
            out["icmp_unreach_from_client"] += 1
    return out


def parse_conntrack(text):
    out = {"flows": 0, "tcp": 0, "syn_sent": 0, "established": 0, "udp": 0, "unreplied": 0}
    for line in text.splitlines():
        p = line.split()
        if not p or p[0] not in ("tcp", "udp", "icmp"):
            continue
        out["flows"] += 1
        if p[0] == "tcp":
            out["tcp"] += 1
            out["syn_sent"] += "SYN_SENT" in line
            out["established"] += "ESTABLISHED" in line
        elif p[0] == "udp":
            out["udp"] += 1
        out["unreplied"] += "[UNREPLIED]" in line
    return out

# ── parsers: AX73 ────────────────────────────────────────────────────────────


def parse_prom_text(text):
    stations, radios, wlc = {}, {}, {}
    for line in text.splitlines():
        if not line.startswith("ax73_"):
            continue
        m = re.match(r"(\w+)\{(.*)\} (\S+)$", line)
        if not m:
            continue
        name, labels, val = m.group(1), dict(re.findall(r'(\w+)="([^"]*)"', m.group(2))), num(m.group(3))
        if name.startswith("ax73_sta_") and labels.get("mac"):
            st = stations.setdefault(mac_norm(labels["mac"]), {"bss": labels.get("bss"), "ssid": labels.get("ssid")})
            st[name[9:].replace("_total", "")] = val
        elif name.startswith("ax73_wifi_radio_") and labels.get("radio"):
            r = radios.setdefault(labels["radio"], {})
            r[name[16:]] = val
            if labels.get("band"):
                r["band"] = labels["band"]
        elif name == "ax73_wl_counter" and labels.get("radio"):
            wlc.setdefault(labels["radio"], {})[labels.get("name")] = val
    return stations, radios, wlc


CHANIM_COLS = "chanspec tx inbss obss nocat nopkt doze txop goodtx badtx glitch badplcp knoise idle busy timestamp".split()


def parse_ax73(text):
    sec, _ = sections(text)
    out = {"now": None, "bss": {}, "rssi": {}, "events": [], "fdb": {}, "chanim": {}}
    out["now"] = num(kv(sec.get("meta", "")).get("now"))
    for line in sec.get("bss", "").splitlines():
        p = line.split()
        if not p:
            continue
        f = kv(line)
        ssid = line.split("ssid=", 1)[1] if "ssid=" in line else ""
        ch = re.match(r"(\d+)", f.get("chanspec", "") or "")
        out["bss"][p[0]] = {"up": f.get("up"), "chanspec": f.get("chanspec"), "n": int(f.get("n") or 0),
                            "ssid": ssid, "channel": int(ch.group(1)) if ch else None}
    for line in sec.get("rssi", "").splitlines():
        p = line.split()
        if len(p) >= 3 and mac_norm(p[1]):
            out["rssi"][mac_norm(p[1])] = {"bss": p[0], "rssi": num(p[2])}
    for line in sec.get("events", "").splitlines():
        p = line.split()
        if len(p) >= 8 and p[0].isdigit() and mac_norm(p[2]):
            out["events"].append([int(p[0]) / 1000.0, p[1], mac_norm(p[2]), p[7].split("/")[0], int(p[5]) if p[5].isdigit() else None])
    out["events"].sort()
    out["fdb"] = parse_bridge(sec.get("fdb", ""))
    samples = {}
    for line in sec.get("chanim", "").splitlines():
        p = line.split()
        if len(p) >= 2 + len(CHANIM_COLS):
            row = dict(zip(CHANIM_COLS, p[2:2 + len(CHANIM_COLS)]))
            samples.setdefault(p[0], []).append({k: num(v) for k, v in row.items() if k != "chanspec"} | {"chanspec": row["chanspec"]})
    for r, rows in samples.items():
        agg = {k: round(statistics.mean(x[k] for x in rows if x.get(k) is not None), 1)
               for k in ("busy", "idle", "obss", "inbss", "tx", "nocat", "nopkt", "glitch", "badplcp", "knoise")}
        ch = re.match(r"(\d+)", rows[-1]["chanspec"] or "")
        agg["chanspec"] = rows[-1]["chanspec"]
        agg["channel"] = int(ch.group(1)) if ch else None
        agg["samples"] = len(rows)
        agg["busy_max"] = max(x["busy"] for x in rows if x.get("busy") is not None)
        out["chanim"][r] = agg
    return out


def parse_grafana(text):
    try:
        d = json.loads(text)
    except ValueError:
        return None
    res = (d.get("results") or {}).get("A") or {}
    if "error" in res or "error" in d:
        return None
    out = {}
    for fr in res.get("frames", []):
        fields = fr.get("schema", {}).get("fields", [])
        if len(fields) < 2:
            continue
        lab = fields[1].get("labels") or {}
        mac = mac_norm(lab.get("mac"))
        vals = fr.get("data", {}).get("values", [[], []])
        if mac:
            out[mac] = {"bss": lab.get("bss"), "ssid": lab.get("ssid"),
                        "series": [[int(t / 1000), v] for t, v in zip(vals[0], vals[1]) if v is not None]}
    return out

# ── parsers: this Mac ────────────────────────────────────────────────────────


def ping_summary(text):
    m = re.search(r"(\d+) packets transmitted, (\d+) (?:packets )?received.*?([\d.]+)% packet loss", text, re.S)
    r = re.search(r"= ([\d.]+)/([\d.]+)/([\d.]+)", text)
    if not (m or r):
        return None
    return {"loss": num(m.group(3)) if m else None, "avg": num(r.group(2)) if r else None,
            "max": num(r.group(3)) if r else None}


def parse_mac(cap):
    out = {}
    v = read(os.path.join(cap, "mac-vantage.txt"))
    if v:
        f = kv(v.splitlines()[0]) if v.splitlines() else {}
        port = v.splitlines()[0].split("port=", 1)[1] if "port=" in v else ""
        out.update({"iface": f.get("iface"), "port": port,
                    "medium": "wifi" if "Wi-Fi" in port else "wired" if port else None,
                    "wifi": [x.strip() for x in v.splitlines()[1:] if x.strip()]})
    sub = subsections(read(os.path.join(cap, "mac-ping.txt")))
    out["gw"] = ping_summary(sub.get("gw", ""))
    out["inet"] = ping_summary(sub.get("inet", ""))
    sp = read(os.path.join(cap, "mac-speed.txt"))
    out["loaded"] = ping_summary(subsections(sp).get("loaded", ""))
    tput = []
    for line in sp.splitlines():
        p = line.split()
        if len(p) >= 4 and p[0] == "tput":
            bps = num(p[4]) if len(p) > 4 else None
            tput.append({"fam": p[1], "host": p[2], "t": int(p[3]),
                         "mbps": round(bps * 8 / 1e6, 1) if bps else None, "code": p[5] if len(p) > 5 else None})
    out["tput"] = tput
    dns = []
    for line in read(os.path.join(cap, "mac-dns.txt")).splitlines():
        p = line.split()
        if len(p) >= 3 and p[0] == "dns":
            f = kv(line)
            dns.append({"server": p[1], "kind": p[2], "status": f.get("status") or None, "ms": num(f.get("ms"))})
    out["dns"] = dns
    return out

# ── facts ───────────────────────────────────────────────────────────────────


def collector_status(cap, name):
    s = kv(read(os.path.join(cap, name + ".status")))
    rc = s.get("rc")
    size = os.path.getsize(os.path.join(cap, name + ".out")) if os.path.exists(os.path.join(cap, name + ".out")) else None
    err = read(os.path.join(cap, name + ".err")).strip().splitlines()
    err = [e for e in err if "post-quantum" not in e and "store now" not in e and "upgraded" not in e]
    return {"rc": int(rc) if rc and rc.lstrip("-").isdigit() else None, "took": num(s.get("took")),
            "limit": num(s.get("limit")), "bytes": size, "err": err[-1][:160] if err else None,
            "ok": rc == "0" and bool(size)}


def build_facts(cap):
    meta = json.loads(read(os.path.join(cap, "meta.json")) or "{}")
    now, frm, to = int(meta.get("now", time.time())), int(meta.get("from", 0)), int(meta.get("to", 0))
    f = {"meta": {"stamp": meta.get("stamp"), "now": now, "from": frm, "to": to, "live": meta.get("live") == "1",
                  "note": meta.get("note"), "client_query": meta.get("client") or None, "collectors": {}}}
    for n in ("route10", "ax73", "ap0", "ap1", "mac"):
        if os.path.exists(os.path.join(cap, n + ".status")):
            f["meta"]["collectors"][n] = collector_status(cap, n)

    r10, took = sections(read(os.path.join(cap, "route10.out")))
    f["meta"]["route10_took"] = took
    rm = kv(r10.get("meta", "").replace("\n", " "))
    uptime, hz = num(rm.get("uptime")), num(rm.get("hz"))

    # WAN
    w = subsections(r10.get("wan", ""))
    ifs = {}
    for name in ("wan3", "wan36", "wan", "wan2"):
        try:
            ifs[name] = json.loads(w.get("ifstatus " + name, "") or "null")
        except ValueError:
            ifs[name] = None
    w3, w36 = ifs.get("wan3") or {}, ifs.get("wan36") or {}
    odi = []
    for line in w.get("odi", "").splitlines():
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)", line)
        if not m:
            continue
        tz = rm.get("tz", "+0000")
        off = (int(tz[1:3]) * 3600 + int(tz[3:5]) * 60) * (-1 if tz.startswith("-") else 1)
        t = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")) - off
        if frm - 300 <= t <= to + 60:
            g = kv(m.group(2))
            rtt = re.search(r"min/avg/max = [\d.]+/([\d.]+)/", m.group(2))
            odi.append({"t": t, "up": g.get("wan3_up"), "rtt": num(rtt.group(1)) if rtt else None,
                        "crc": g.get("crc"), "carrier": g.get("carrier")})
    try:
        pol = json.loads(w.get("mwan3policy", "").strip() or "null") or {}
    except ValueError:
        pol = {}
    # the policy LAN traffic uses: "balance" here; fall back to any non-empty one
    mwan_policy = pol.get("balance") or next((v for v in pol.values() if v), None)
    mwan = {}
    for line in w.get("mwan3", "").splitlines():
        p = line.split()
        if p:
            mwan[p[0]] = kv(line)
    carrier = {}
    for line in w.get("carrier", "").splitlines():
        p = line.split()
        if len(p) == 3:
            carrier[p[0]] = {"up": p[1] == "1", "changes": int(p[2]) if p[2].isdigit() else None}
    f["wan"] = {
        "wan3_up": w3.get("up"), "wan3_uptime": w3.get("uptime"), "wan3_l3": w3.get("l3_device"),
        "wan36_up": w36.get("up"),
        "v6_prefix": [p.get("address") for p in (w36.get("ipv6-prefix") or [])] if w36 else None,
        "wan2_up": (ifs.get("wan2") or {}).get("up"),
        "default4": (w.get("route4", "").split("dev ") + [""])[1].split(" ")[0] or None,
        "default6": (w.get("route6", "").split("dev ") + [""])[1].split(" ")[0] or None,
        "defaults4": [" ".join(x for x in (re.search(r"dev (\S+)", l).group(1), (re.search(r"metric (\d+)", l) or [None, ""])[1]) if x)
                      for l in w.get("route4", "").splitlines() if "dev " in l],
        "mwan_policy": mwan_policy,
        "mwan": mwan, "odi": odi, "carrier": carrier,
    }

    # PON / samples
    pon = rows_ts_json(r10.get("pon", ""))
    f["pon"] = None
    if pon:
        def g(d, path):
            for k in path.split("."):
                d = (d or {}).get(k)
            return d
        first, last = pon[0][1], pon[-1][1]
        f["pon"] = {"rows": len(pon), "last_t": pon[-1][0], "state_last": last.get("onu_state"),
                    "states": sorted({r.get("onu_state") for _, r in pon if r.get("onu_state") is not None}),
                    "non_o5": [[t, r.get("onu_state")] for t, r in pon if r.get("onu_state") != 5],
                    "alarms": {k: max((g(r, "alarm." + k) or 0) for _, r in pon) for k in ("los", "lof", "sf", "sd")},
                    "fec_unc_delta": (g(last, "ds.fec_uncor_cw") or 0) - (g(first, "ds.fec_uncor_cw") or 0),
                    "ploam_crc_delta": (g(last, "ds.ploam_crc") or 0) - (g(first, "ds.ploam_crc") or 0),
                    "bw_crc_delta": (g(last, "bw.crc_err") or 0) - (g(first, "bw.crc_err") or 0),
                    "ranging_req_max": max((g(r, "act.ranging_req") or 0) for _, r in pon),
                    "omci_retx": sum((g(r, "omci_tx.retx") or 0) for _, r in pon),
                    "omci_req": sum((g(r, "omci_tx.req") or 0) for _, r in pon)}
    samp = rows_ts_json(r10.get("samples", ""))
    f["dns_ladder"] = None
    f["ct"] = None
    f["guards"] = None
    if samp:
        down = {}
        for t, s in samp:
            for k, v in (s.get("dns") or {}).items():
                if k.endswith("_up") and v == 0:
                    down.setdefault(k[:-3], []).append(t)
        f["dns_ladder"] = {"rows": len(samp), "last": samp[-1][1].get("dns"), "down_minutes": {k: len(v) for k, v in down.items()},
                           "down_first": {k: min(v) for k, v in down.items()},
                           "rdns_ms_max": max(((s.get("dns") or {}).get("rdns_ms") or 0) for _, s in samp)}
        top4, stall4 = {}, {}
        for t, s in samp:
            for h in (s.get("ct") or {}).get("top4") or []:
                top4[h["ip"]] = max(top4.get(h["ip"], 0), h.get("n", 0))
            for h in (s.get("ct") or {}).get("stall4") or []:
                cur = stall4.setdefault(h["ip"], {"tcp": 0, "syn": 0, "host": h.get("h")})
                cur["tcp"] = max(cur["tcp"], h.get("tcp", 0))
                cur["syn"] = max(cur["syn"], h.get("syn", 0))
        f["ct"] = {"n_max": max(((s.get("ct") or {}).get("n") or 0) for _, s in samp),
                   "wan4_max": max(((s.get("ct") or {}).get("wan4") or 0) for _, s in samp),
                   "top4_max": top4, "stall4_max": stall4}

        def delta(key, sub):
            a = (samp[0][1].get(key) or {}).get(sub)
            b = (samp[-1][1].get(key) or {}).get(sub)
            return (b - a) if a is not None and b is not None else None
        f["guards"] = {"mesh_egress_v4": delta("meg", "v4"), "mesh_egress_v6": delta("meg", "v6"),
                       "stick_guard_v4": delta("guard", "v4"), "stick_guard_v6": delta("guard", "v6"),
                       "eth5_crc": delta("crc", "eth5"), "eth4_flaps": delta("flap", "eth4"),
                       "eth5_flaps": delta("flap", "eth5"), "brlan_flaps": delta("flap", "brlan"),
                       "addr_missing": sorted({k for _, s in samp for k, v in (s.get("addr") or {}).items() if v == 0})}

    # identities
    v4, v6 = parse_leases(r10.get("leases", "").split("## targets")[0])
    targets = parse_targets(subsections(r10.get("leases", "")).get("targets", ""))
    r10_bridge = parse_bridge(r10.get("bridge", ""))
    ip2mac = {v["ip"]: m for m, v in v4.items()}

    def name_of(mac):
        h = (v4.get(mac) or {}).get("host")
        if h:
            return h
        for x in v6:
            if x["mac"] == mac and x["host"]:
                return x["host"]
        ip = (v4.get(mac) or {}).get("ip")
        for t in targets:
            if t["ip"] == ip:
                return t["name"]
        return None

    # per-client bytes (rcstats minutes; ts = start of the minute)
    clients = {}
    for t, d in rows_ts_json(r10.get("minutes", "")):
        for c in (d.get("wired") or []) + (d.get("wireless") or []):
            mac = mac_norm(c.get("id"))
            if not mac or not (c.get("rx") or c.get("tx")):
                continue
            cl = clients.setdefault(mac, {"ip": c.get("ip"), "minutes": []})
            cl["ip"] = c.get("ip") or cl["ip"]
            cl["minutes"].append([t, c.get("rx", 0), c.get("tx", 0), ",".join(x[0] for x in (c.get("dpi") or [])[:2])])
    f["minutes_span"] = None
    mins = rows_ts_json(r10.get("minutes", ""))
    if mins:
        f["minutes_span"] = [mins[0][0], mins[-1][0], len(mins)]
        f["net_rx_per_min"] = [[t, sum((c.get("rx") or 0) for c in (d.get("wired") or []) + (d.get("wireless") or []))] for t, d in mins]

    # LAN probes
    lanq = {}
    for t, rows in rows_ts_json(r10.get("lanq", "")):
        for r in rows if isinstance(rows, list) else []:
            q = lanq.setdefault(r.get("n"), {"ip": r.get("ip"), "medium": r.get("m"), "rows": []})
            q["ip"] = r.get("ip") or q["ip"]
            q["rows"].append([t, r.get("present"), r.get("loss"), r.get("rtt")])

    # syslog
    logs = parse_syslog(r10.get("log", ""), now, frm, to)
    dhcp = parse_dhcp([e for e in logs if e["prog"].startswith("dnsmasq-dhcp")])
    blocks, connlimit = parse_fence_lines(logs)
    comp = [[round(e["t"], 1), e["prog"], e["sev"], e["msg"][:200]] for e in logs
            if e["prog"].startswith("route10.") and e["sev"] in ("warn", "warning", "err", "crit", "alert", "emerg")
            and frm <= e["t"] <= to]
    f["logs"] = {
        "lines": len(logs),
        "first_t": logs[0]["t"] if logs else None,
        "warn_err": comp[-40:],
        "mesh_drift": sum(1 for e in logs if e["prog"] == "route10.mesh-health" and "drift" in e["msg"] and frm <= e["t"] <= to),
        "rc_rerun": sum(1 for e in logs if e["prog"] == "rc" and "Re-running" in e["msg"] and frm <= e["t"] <= to),
        "cfg_reload_after_ppp": 0,
    }
    ppp_ip = [e["t"] for e in logs if e["prog"] == "pppd" and "local" in e["msg"] and "IP" in e["msg"]]
    cfg_ch = [e["t"] for e in logs if e["prog"] == "cfg" and "Found interface config changes" in e["msg"]]
    f["logs"]["cfg_reload_after_ppp"] = sum(1 for a in ppp_ip if any(0 <= c - a <= 5 for c in cfg_ch))
    f["dhcp"] = [x for x in dhcp if frm - 600 <= x[0] <= to]
    f["connlimit"] = [x for x in connlimit if frm <= x[0] <= to]

    # firewall
    fw = subsections(r10.get("fw", ""))
    chains = {}
    for fam, tool in (("v4", "iptables"), ("v6", "ip6tables")):
        a, b = parse_ipt_save(fw.get(tool + " t0", "")), parse_ipt_save(fw.get(tool + " t1", ""))
        for ch, n in a.items():
            chains.setdefault(ch, {})[fam] = {"total": n, "delta_8s": (b[ch] - n) if ch in b else None}
    recent = parse_recent(fw.get("recent", ""), uptime, hz, now)
    f["fence"] = {"blocks": [x for x in blocks if frm - 600 <= x[0] <= to], "chains": chains,
                  "recent": {k: {ip: [h for h in v if frm - 600 <= h <= to] for ip, v in d.items()} for k, d in recent.items()}}

    # mesh
    ms = subsections(r10.get("mesh", ""))
    try:
        mesh = json.loads(ms.get("", "").strip().splitlines()[0]) if ms.get("", "").strip() else None
    except (ValueError, IndexError):
        mesh = None
    f["mesh"] = {"state": (mesh or {}).get("state"), "version": (mesh or {}).get("version"),
                 "peers": (mesh or {}).get("peers") or [],
                 "allow_states": [line for line in ms.get("mesh-allow", "").splitlines() if line.strip()]} if mesh else None

    # AX73: live scrapes, ssh view, history
    ap0, radios, wlc = parse_prom_text(read(os.path.join(cap, "ap0.out")))
    ap1, radios1, _ = parse_prom_text(read(os.path.join(cap, "ap1.out")))
    ax = parse_ax73(read(os.path.join(cap, "ax73.out")))
    hist = {}
    rssi_h = parse_grafana(read(os.path.join(cap, "prom-rssi.out")))
    retr_h = parse_grafana(read(os.path.join(cap, "prom-retries.out")))
    frm_h = parse_grafana(read(os.path.join(cap, "prom-frames.out")))
    for mac, s in (rssi_h or {}).items():
        hist.setdefault(mac, {"bss": s["bss"], "ssid": s["ssid"]})["rssi"] = s["series"]
    if retr_h and frm_h:
        for mac, s in retr_h.items():
            fr = dict((t, v) for t, v in (frm_h.get(mac) or {}).get("series", []))
            pts = []
            for t, v in s["series"]:
                fps = fr.get(t)
                if fps and fps * 300 >= 60:              # ≥60 unicast frames in the 5-min window
                    pts.append([t, round(100 * v / fps), round(fps * 300)])
            hist.setdefault(mac, {"bss": s["bss"], "ssid": s["ssid"]})["retry"] = pts
    bands = {}
    for b, info in ax["bss"].items():
        ch = info.get("channel") or (ax["chanim"].get(b.split(".")[0]) or {}).get("channel")
        bands[b] = None if ch is None else ("2.4G" if ch <= 14 else "5G")
    for r, rr in radios.items():
        if rr.get("channel"):
            bands.setdefault(r, "2.4G" if rr["channel"] <= 14 else "5G")

    def band_of(bss):
        if not bss:
            return None
        return bands.get(bss) or bands.get(bss.split(".")[0])

    stations = {}
    # Retrospective: stations come from history too (a phone that has since left still
    # counts), and their signal is the last point inside the window, never "now".
    live = f["meta"]["live"]
    for mac in set(ap1) | set(ap0) | set(ax["rssi"]) | (set() if live else {m for m, h in hist.items() if h.get("rssi")}):
        a, b = ap0.get(mac, {}), ap1.get(mac, {})
        cur = b or a
        st = {"bss": cur.get("bss") or (ax["rssi"].get(mac) or {}).get("bss"), "ssid": cur.get("ssid"),
              "rssi": cur.get("rssi_dbm") if cur else (ax["rssi"].get(mac) or {}).get("rssi"),
              "tx_rate_mbps": round(cur["last_tx_rate_kbps"] / 1000, 1) if cur.get("last_tx_rate_kbps") else None,
              "rx_rate_mbps": round(cur["last_rx_rate_kbps"] / 1000, 1) if cur.get("last_rx_rate_kbps") else None,
              "idle_s": cur.get("idle_seconds"), "in_network_s": cur.get("in_network_seconds"),
              "ip": (v4.get(mac) or {}).get("ip"), "name": name_of(mac)}
        st["band"] = band_of(st["bss"])
        if a and b:
            du = (b.get("tx_ucast_packets") or 0) - (a.get("tx_ucast_packets") or 0)
            dr = (b.get("tx_retries") or 0) - (a.get("tx_retries") or 0)
            st["live"] = {"ucast": du, "retries": dr, "fail": (b.get("tx_failures") or 0) - (a.get("tx_failures") or 0),
                          "retry_pct": round(100 * dr / du) if du >= 20 else None}
        h = hist.get(mac, {})
        if not live:
            past = [v for t, v in h.get("rssi", []) if t <= to]
            st.update({"rssi": past[-1] if past else None, "tx_rate_mbps": None, "rx_rate_mbps": None,
                       "idle_s": None, "in_network_s": None, "live": None,
                       "bss": h.get("bss") or st.get("bss"), "ssid": h.get("ssid") or st.get("ssid")})
            st["band"] = band_of(st["bss"])
            if st["rssi"] is None:
                continue
        recent = [x for x in h.get("retry", []) if x[0] >= to - 900]
        if recent and sum(x[2] for x in recent) >= 150:
            st["frames_15m"] = sum(x[2] for x in recent)
            st["retry_15m"] = round(sum(x[1] * x[2] for x in recent) / st["frames_15m"])
        stations[mac] = st
    radio_out = {}
    for r, c in ax["chanim"].items():
        radio_out[r] = dict(c, band="2.4G" if (c.get("channel") or 99) <= 14 else "5G")
    for r, rr in radios.items():
        radio_out.setdefault(r, {"band": rr.get("band"), "channel": rr.get("channel")})
        radio_out[r]["noise"] = rr.get("noise_dbm")
        if wlc.get(r, {}).get("txframe"):
            radio_out[r]["lifetime_retrans_pct"] = round(100 * wlc[r].get("txretrans", 0) / wlc[r]["txframe"])
    events = [e for e in ax["events"] if frm - 600 <= e[0] <= to + 60]
    f["wifi"] = {"radios": radio_out,
                 "bss": {b: dict(v, band=band_of(b)) for b, v in ax["bss"].items() if v.get("ssid")},
                 "stations": stations, "events": events, "ap_fdb": {m: v["port"] for m, v in ax["fdb"].items() if not v.get("local")},
                 "history": {m: h for m, h in hist.items()},
                 "sources": {"ap_scrape": bool(ap1 or ap0), "ssh": bool(ax["bss"]), "prom": rssi_h is not None}}

    # where each LAN device sits (route10 bridge port; AX73 bridge port)
    # Uplinks: route10's port where the AP's own (local) MACs are learned, and the AP's port
    # where route10's are. Everything upstream shows on the AP's uplink, so ask route10 first.
    ap_local = {m for m, v in ax["fdb"].items() if v.get("local")}
    r10_local = {m for m, v in r10_bridge.items() if v.get("local")}
    up_r10 = next((v["port"] for m, v in r10_bridge.items() if m in ap_local and not v.get("local")), None)
    up_ap = next((v["port"] for m, v in ax["fdb"].items() if m in r10_local and not v.get("local")), None)

    def location(mac):
        if mac in stations:
            return "wifi:" + (stations[mac].get("band") or "?") + ":" + (stations[mac].get("bss") or "?")
        p = (r10_bridge.get(mac) or {}).get("port")
        if p and up_r10 and p != up_r10:
            return "route10:" + p
        ap_port = (ax["fdb"].get(mac) or {}).get("port")
        if ap_port and ap_port != up_ap:
            return ("wifi:" + (band_of(ap_port) or "?") + ":" + ap_port) if ap_port.startswith("wl") else "ap-port:" + ap_port
        return "route10:" + p if p else None
    host2mac = {v["host"].lower(): m for m, v in v4.items() if v.get("host")}
    for name, q in lanq.items():
        t = next((t for t in targets if t["name"] == name), {})
        q["dhcp"] = t.get("dhcp")
        q["dhcp_mac"] = host2mac.get(t["dhcp"].lower()) if t.get("dhcp") else None
        q["ip_vendor"] = vendor(ip2mac.get(q["ip"]))
        q["mac"] = ip2mac.get(q["ip"])
        q["where"] = location(q["mac"]) if q["mac"] else None
    f["lanq"] = lanq
    f["clients"] = {m: dict(c, name=name_of(m), where=location(m)) for m, c in clients.items()}

    f["mac"] = parse_mac(cap)
    f["client"] = build_client(f, r10, v4, v6, targets, name_of, location)
    return f


def build_client(f, r10, v4, v6, targets, name_of, location):
    q = (f["meta"].get("client_query") or "").strip().lower()
    if not q:
        return None
    macs = set()
    if mac_norm(q):
        macs.add(mac_norm(q))
    for m, v in v4.items():
        if v["ip"] == q or (v.get("host") and q in v["host"].lower()):
            macs.add(m)
    for x in v6:
        if x["mac"] and (x["ip"] == q or (x.get("host") and q in x["host"].lower())):
            macs.add(x["mac"])
    for t in targets:
        if q in t["name"].lower() or t["ip"] == q:
            for m, v in v4.items():
                if v["ip"] == t["ip"]:
                    macs.add(m)
    # Linked identities: iOS/Android use one private MAC per SSID, so a band/SSID switch
    # looks like a NEW device. A RELEASE (or AP deauth) of another MAC <=30 s before this
    # MAC's first DHCP/assoc in the window is that same phone changing network.
    linked = {}
    for m in list(macs):
        seen_at = [x[0] for x in f["dhcp"] if x[2] == m] + [e[0] for e in f["wifi"]["events"] if e[2] == m]
        if not seen_at:
            continue
        first = min(seen_at)
        for x in f["dhcp"]:
            if x[1] == "DHCPRELEASE" and x[2] and x[2] not in macs and 0 <= first - x[0] <= 30:
                linked[x[2]] = "DHCPRELEASE %s, %.0f s before %s first appeared" % (hms(x[0]), first - x[0], short(m))
    allm = sorted(macs | set(linked))
    ips = sorted({(v4.get(m) or {}).get("ip") for m in allm if v4.get(m)} | {x["ip"] for x in v6 if x["mac"] in allm})
    cs = subsections(r10.get("client", ""))
    neigh_ips = [line.split()[0] for line in cs.get("neigh", "").splitlines() if line.strip()]
    cap = parse_tcpdump(cs.get("tcpdump", ""), set(ips) | set(neigh_ips)) if cs.get("tcpdump") else None
    ct = parse_conntrack(cs.get("conntrack", "")) if cs.get("conntrack") else None
    # timeline: one row per minute per MAC (bytes) + events
    tl = []
    hist = f["wifi"]["history"]
    for m in allm:
        h = hist.get(m, {})
        for t, rx, tx, dpi in (f["clients"].get(m) or {}).get("minutes", []):
            rs = [v for ts, v in h.get("rssi", []) if t - 150 <= ts <= t + 90]
            rt = [v for ts, v, _ in h.get("retry", []) if t - 150 <= ts <= t + 90]
            tl.append({"t": t, "mac": m, "rx": rx, "tx": tx, "dpi": dpi,
                       "band": "5G" if (h.get("bss") or "").startswith("wl0") else "2.4G" if (h.get("bss") or "").startswith("wl1") else None,
                       "rssi": rs[-1] if rs else None, "retry": rt[-1] if rt else None})
    tl.sort(key=lambda r: (r["t"], r["mac"]))
    ev = []
    for x in f["dhcp"]:
        if x[2] in allm and x[1] in ("DHCPDISCOVER", "DHCPREQUEST", "DHCPRELEASE", "DHCPACK", "DHCPNAK", "DHCPDECLINE"):
            ev.append([x[0], "%s %s %s" % (x[1], short(x[2]), x[3] or "")])
    for e in f["wifi"]["events"]:
        if e[2] in allm and e[3] in ("E_ASSOC_IND", "E_REASSOC_IND", "E_DEAUTH_IND", "E_DISASSOC_IND", "E_DEAUTH", "E_DISASSOC"):
            ev.append([e[0], "AP %s %s on %s" % (e[3][2:], short(e[2]), e[1])])
    for b in f["fence"]["blocks"]:
        if b[3] in ips or b[7] in allm:
            ev.append([b[0], "%s %s %s->%s %s/%s" % (b[1], b[2], b[3], b[4], b[5], b[6])])
    fence_hits = {}
    for setname, d in f["fence"]["recent"].items():
        for ip, hits in d.items():
            if ip in ips and hits:
                fence_hits[setname] = hits
    # dedupe repeating DHCP lines (dnsmasq logs each retransmit)
    seen, evs = set(), []
    for t, s in sorted(ev):
        key = (int(t), s)
        if key not in seen:
            seen.add(key)
            evs.append([t, s])
    return {"query": q, "macs": sorted(macs), "linked": linked, "ips": ips,
            "names": sorted({n for n in (name_of(m) for m in allm) if n}),
            "where": {m: location(m) for m in allm}, "timeline": tl, "events": evs[-40:],
            "fence_hits": fence_hits, "capture": cap, "conntrack": ct,
            "stall": {ip: f["ct"]["stall4_max"][ip] for ip in ips if f["ct"] and ip in f["ct"]["stall4_max"]} if f["ct"] else {}}

# ── derived: the coverage curve ─────────────────────────────────────────────


def coverage(f):
    """Per band: do retries rise as RSSI falls across ALL stations? Then a weak client is on
    the curve (coverage), not an outlier (its own radio/driver)."""
    out = {}
    for band in ("2.4G", "5G"):
        pts = []
        for mac, s in f["wifi"]["stations"].items():
            if s.get("band") != band or s.get("rssi") is None:
                continue
            r = s.get("retry_15m")
            if r is None and s.get("live"):
                r = s["live"].get("retry_pct")
            if r is not None:
                pts.append((s["rssi"], r, mac))
        out[band] = {"points": sorted(pts, reverse=True), "rank_corr": rank_corr([p[0] for p in pts], [p[1] for p in pts])}
    return out

# ── render ──────────────────────────────────────────────────────────────────


def fmt(v, unit="", nd=0):
    if v is None:
        return "?"
    return ("%." + str(nd) + "f%s") % (v, unit)


def render(f, results):
    m = f["meta"]
    L = []
    say = L.append
    loc = time.strftime("%H:%M", time.localtime(m["now"]))
    say("NET-TRIAGE %s  now %s (%s local)  window %s–%s  %s" % (
        m["stamp"], hm(m["now"]), loc, hm(m["from"]), hm(m["to"]), "LIVE" if m["live"] else "RETROSPECTIVE"))
    if m.get("note"):
        say("note: " + m["note"])
    hits = [r for r in results if r["status"] == "hit"]
    say("")
    say("VERDICT (automatic: check it against the evidence below)")
    if not hits:
        say("  no known signature matched. Unknown shape: dig by hand, then teach signatures.py (STEP 5).")
    for r in sorted(hits, key=lambda r: -r["weight"]):
        say("  ● %-26s %s  [%s, %s]" % (r["id"], r["evidence"], r["confidence"], r["since"]))
    miss = [r["id"] for r in results if r["status"] == "miss"]
    if miss:
        say("  checked, not matched: " + ", ".join(miss))
    na = [r for r in results if r["status"] == "na"]
    if na:
        say("  could not check: " + "; ".join("%s (%s)" % (r["id"], r["evidence"]) for r in na))

    # layer checklist
    say("")
    say("LAYERS")
    w = f["wan"]
    odi = [o["rtt"] for o in w.get("odi", []) if o.get("rtt")]
    pol = ", ".join("%s %s%%" % (x.get("interface"), x.get("percent")) for x in (w.get("mwan_policy") or [])) or "?"
    say("  WAN    wan3 %s %s; LAN v4 egress (mwan3) %s; v6 via %s; PPP-gw RTT max %s ms (odi, %d samples)%s" % (
        "UP" if w.get("wan3_up") else "DOWN", "%.1f d" % (w["wan3_uptime"] / 86400) if w.get("wan3_uptime") else "",
        pol, w.get("default6"), fmt(max(odi) if odi else None, nd=1) if odi else "?", len(odi),
        "" if w.get("v6_prefix") else "  ⚠ NO IPv6 PREFIX on wan36"))
    p = f.get("pon")
    if p:
        say("  PON    O%s now, states seen %s, LOS/LOF/SF/SD max %s, FEC-unc +%s, PLOAM-CRC +%s, BWMAP-CRC +%s, OMCI retx %s/%s" % (
            p["state_last"], p["states"], "/".join(str(p["alarms"][k]) for k in ("los", "lof", "sf", "sd")),
            p["fec_unc_delta"], p["ploam_crc_delta"], p["bw_crc_delta"], p["omci_retx"], p["omci_req"]))
    else:
        say("  PON    ? (no rows — pon-collect stale, or stick dark)")
    d = f.get("dns_ladder")
    if d:
        last = d["last"] or {}
        say("  DNS    ladder now: " + ", ".join("%s %s/%sms" % (k, "up" if last.get(k + "_up") else "DOWN", last.get(k + "_ms"))
                                            for k in ("agh", "agh6", "doh", "rdns", "dnsmasq") if k + "_up" in last)
            + ("  ⚠ down minutes %s" % d["down_minutes"] if d["down_minutes"] else ""))
    mc = f.get("mac") or {}
    if mc.get("dns"):
        say("         from this Mac: " + ", ".join("%s %s %s %s" % (x["server"], x["kind"], x["status"] or "TIMEOUT", fmt(x["ms"], "ms")) for x in mc["dns"]))
    if mc.get("gw") or mc.get("tput"):
        tp = ", ".join("v%s %s %s" % (t["fam"][-1], t["host"].split(".")[0], fmt(t["mbps"], nd=0) if t["mbps"] else "n/a") for t in mc.get("tput", []))
        say("  VANTAGE this Mac %s (%s): gw %s ms loss %s%%, 8.8.8.8 idle %s ms → loaded %s ms; Mbit/s: %s" % (
            mc.get("iface"), mc.get("medium"), fmt((mc.get("gw") or {}).get("avg"), nd=1), fmt((mc.get("gw") or {}).get("loss")),
            fmt((mc.get("inet") or {}).get("avg"), nd=1), fmt((mc.get("loaded") or {}).get("avg"), nd=1), tp or "not run"))
    fe = f["fence"]
    act, bg = [], []
    for ch, fams in sorted(fe["chains"].items()):
        for fam, v in fams.items():
            if v.get("delta_8s"):
                # RT10_ONTEDGE drops the ISP segment's neighbour traffic all day: background
                (bg if ch in BACKGROUND_CHAINS else act).append("%s/%s +%d in 8 s" % (ch, fam, v["delta_8s"]))
    nb = {}
    for b in fe["blocks"]:
        if b[0] >= m["from"]:
            nb[b[1]] = nb.get(b[1], 0) + 1
    say("  FENCES dropping now: %s; logged in window: %s; connlimit lines: %d; background: %s" % (
        ", ".join(act) or "none", ", ".join("%s %d" % kv_ for kv_ in nb.items()) or "none", len(f["connlimit"]), ", ".join(bg) or "-"))
    me = f.get("mesh")
    if me:
        say("  MESH   %s %s, %d peers (%d online), mesh-allow states: %s, drift heals in window: %d, agent re-applies: %d" % (
            me["state"], me.get("version") or "", len(me["peers"]), sum(1 for x in me["peers"] if x.get("online")),
            ", ".join(me["allow_states"]) or "none", f["logs"]["mesh_drift"], f["logs"]["rc_rerun"]))
    if f.get("ct"):
        top = sorted(f["ct"]["top4_max"].items(), key=lambda x: -x[1])[:3]
        say("  FLOWS  conntrack max %d, WAN v4 max %d; top v4 hosts %s" % (
            f["ct"]["n_max"], f["ct"]["wan4_max"], ", ".join("%s:%d" % t for t in top)))
    g = f.get("guards") or {}
    gl = ["%s +%s" % (k, v) for k, v in g.items() if isinstance(v, (int, float)) and v and k not in ("stick_guard_v4", "stick_guard_v6")]
    if g.get("addr_missing"):
        gl.append("addr missing: " + ",".join(g["addr_missing"]))
    say("  GUARDS %s" % (", ".join(gl) or "quiet (mesh egress, eth5 CRC, flaps, addresses)"))
    if f["logs"]["warn_err"]:
        say("  LOGS   %d route10.* warn/err in window; last: %s %s %s" % (
            len(f["logs"]["warn_err"]), hms(f["logs"]["warn_err"][-1][0]), f["logs"]["warn_err"][-1][1], f["logs"]["warn_err"][-1][3][:90]))

    # Wi-Fi
    wf = f["wifi"]
    say("")
    say("WI-FI (AX73)  sources: scrape=%s ssh=%s prom-history=%s" % (
        "ok" if wf["sources"]["ap_scrape"] else "MISSING", "ok" if wf["sources"]["ssh"] else "MISSING",
        "ok" if wf["sources"]["prom"] else "MISSING"))
    for r, c in sorted(wf["radios"].items()):
        say("  %s %-4s ch %-7s busy %s%% (obss/neighbours %s%%, ours %s%%, non-wifi %s%%) knoise %s noise %s, lifetime retrans %s%%" % (
            r, c.get("band"), c.get("chanspec") or c.get("channel"), fmt(c.get("busy")), fmt(c.get("obss")),
            fmt((c.get("tx") or 0) + (c.get("inbss") or 0)) if c.get("tx") is not None else "?", fmt(c.get("nocat")),
            fmt(c.get("knoise")), fmt(c.get("noise")), fmt(c.get("lifetime_retrans_pct"))))
    cov = coverage(f)
    for band, c in cov.items():
        if c["points"]:
            say("  %s retry-vs-RSSI across stations: %s  (rank corr %s; strongly negative = retries follow signal = coverage)" % (
                band, "  ".join("%d→%d%%" % (p[0], p[1]) for p in c["points"]), fmt(c["rank_corr"], nd=2)))
    say("  %-20s %-17s %-5s %5s %8s %8s %5s %11s %6s" % ("station", "mac", "band", "rssi", "retry15m", "retry12s", "fail", "rate tx/rx", "idle"))
    for mac, s in sorted(wf["stations"].items(), key=lambda x: (x[1].get("band") or "", -(x[1].get("rssi") or -999))):
        lv = s.get("live") or {}
        say("  %-20s %-17s %-5s %5s %8s %8s %5s %11s %6s" % (
            (s.get("name") or "?")[:20], mac, s.get("band") or "?", fmt(s.get("rssi")),
            fmt(s.get("retry_15m"), "%"), (fmt(lv.get("retry_pct"), "%") + "/" + str(lv.get("ucast"))) if lv else "?",
            lv.get("fail", "?"), "%s/%s" % (fmt(s.get("tx_rate_mbps")), fmt(s.get("rx_rate_mbps"))), fmt(s.get("idle_s"))))
    joins = [e for e in wf["events"] if e[3] in ("E_ASSOC_IND", "E_REASSOC_IND") and e[0] >= m["from"]]
    leaves = [e for e in wf["events"] if e[3] in ("E_DEAUTH_IND", "E_DISASSOC_IND", "E_DEAUTH", "E_DISASSOC") and e[0] >= m["from"]]
    if wf["events"]:
        say("  AP events in window: %d joins, %d leaves/deauths (association log reaches back to %s)" % (
            len(joins), len(leaves), hm(wf["events"][0][0])))
        storm = {}
        for e in leaves:
            storm[e[2]] = storm.get(e[2], 0) + 1
        loud = [(k, v) for k, v in storm.items() if v >= 10]
        if loud:
            say("  ⚠ deauth storms: " + ", ".join("%s %s ×%d" % (short(k), (wf["stations"].get(k) or {}).get("name") or "", v) for k, v in loud))

    # LAN probes
    if f["lanq"]:
        say("")
        say("LAN PROBES (router → device ICMP, per minute)")
        for name, q in f["lanq"].items():
            rows = [r for r in q["rows"] if r[0] >= m["from"]]
            lossy = [r for r in rows if r[1] and (r[2] or 0) >= 80]
            say("  %-20s %-15s %-6s at %-22s present %d/%d min, ≥80%% loss %d min%s" % (
                name, q["ip"], q["medium"], q.get("where") or "?", sum(1 for r in rows if r[1]), len(rows), len(lossy),
                "" if not lossy else " (%s–%s)" % (hm(lossy[0][0]), hm(lossy[-1][0]))))

    # client focus
    c = f.get("client")
    if c:
        say("")
        say("CLIENT '%s' → %s  ips %s  names %s" % (c["query"], ", ".join(c["macs"]) or "NOT FOUND", ", ".join(c["ips"]) or "-", ", ".join(c["names"]) or "-"))
        for lm, why in c["linked"].items():
            say("  linked identity %s: %s (same device on another SSID? iOS uses one private MAC per network)" % (lm, why))
        for mm, where in c["where"].items():
            say("  %s is at %s" % (mm, where or "nowhere now (left the AP and the LAN bridge)"))
        if c["fence_hits"]:
            say("  fence hits on its address: " + ", ".join("%s ×%d (%s)" % (k, len(v), ",".join(hms(x) for x in v[-3:])) for k, v in c["fence_hits"].items()))
        if c["stall"]:
            say("  conntrack stall (obs-collect max in window): %s" % c["stall"])
        if c["capture"]:
            cp = c["capture"]
            say("  live 8 s capture: %d pkts (out %d / in %d), DNS %d q / %d a, SYN out %d / SYN-ACK in %d, RST in %d, ICMP-unreach from client %d" % (
                cp["pkts"], cp["out"], cp["in"], cp["dns_q"], cp["dns_a"], cp["syn_out"], cp["synack_in"], cp["rst_in"], cp["icmp_unreach_from_client"]))
        if c["conntrack"]:
            say("  conntrack now: %s" % c["conntrack"])
        if c["timeline"]:
            say("  %-6s %-12s %8s %8s %-5s %5s %6s  %s" % ("min", "mac", "rx KB", "tx KB", "band", "rssi", "retry", "dpi"))
            for r in c["timeline"][-30:]:
                say("  %-6s %-12s %8.0f %8.0f %-5s %5s %6s  %s" % (
                    hm(r["t"]), short(r["mac"]), r["rx"] / 1e3, r["tx"] / 1e3, r["band"] or "?", fmt(r["rssi"]), fmt(r["retry"], "%"), r["dpi"]))
        if c["events"]:
            say("  events:")
            for t, s in c["events"][-15:]:
                say("    %s %s" % (hms(t), s))

    # self-improvement prompts
    say("")
    say("COLLECTION")
    for n, s in m["collectors"].items():
        say("  %-8s %s took %ss/%ss %s" % (n, "ok " if s["ok"] else "FAIL", fmt(s["took"]), fmt(s["limit"]), s["err"] or ""))
    slow = {k: v for k, v in (m.get("route10_took") or {}).items() if v and v >= 6}
    if slow:
        say("  slow route10 sections: %s" % slow)
    say("  ⭐ STEP 5: anything you then found BY HAND belongs in a collector; a wrong verdict means a")
    say("     rule fix + a fixture (net-triage --save-fixture). Log only real incidents.")
    return "\n".join(L)

# ── fixtures ────────────────────────────────────────────────────────────────


def _h(s):
    return hashlib.sha256(s.encode()).hexdigest()[:6]


def sanitize(f):
    """Facts for a PUBLIC repo (route10 is public). MACs keep their OUI (rules key on it) plus a
    hash; hostnames, probe names (people's names), SSIDs, the client query, per-minute app
    names (DPI) and free-text log messages are hashed or dropped. Check the diff anyway."""
    f = copy.deepcopy(f)
    secret_keys = ("name", "host", "ssid", "query", "client_query", "note", "dhcp")

    def walk(x):
        if isinstance(x, dict):
            out = {}
            for k, v in x.items():
                nk = walk(k) if isinstance(k, str) else k
                if k in secret_keys and isinstance(v, str):
                    out[nk] = "x-" + _h(v)
                elif k == "names" and isinstance(v, list):
                    out[nk] = ["x-" + _h(n) for n in v]
                elif k == "dpi":
                    out[nk] = ""
                else:
                    out[nk] = walk(v)
            return out
        if isinstance(x, list):
            return [walk(v) for v in x]
        if isinstance(x, str):
            x = MAC_RE.sub(lambda mm: mm.group(1).lower()[:8] + ":h" + _h(mm.group(1).lower())[:4], x)
            # global IPv6 (our delegated prefix and its hosts) -> documentation range, hashed
            return V6_GUA_RE.sub(lambda mm: "2001:db8:" + _h(mm.group(0))[:4] + "::" + _h(mm.group(0) + "h")[:4], x)
        return x
    f["lanq"] = {"probe-" + _h(k): v for k, v in (f.get("lanq") or {}).items()}
    f["dhcp"] = [x[:4] + ["x-" + _h(x[4]) if x[4] else None] for x in f.get("dhcp") or []]
    for c in (f.get("clients") or {}).values():
        c["minutes"] = [m[:3] + [""] for m in c.get("minutes", [])]
    f = walk(f)
    f["logs"]["warn_err"] = [[t, comp, sev, "<redacted>"] for t, comp, sev, _ in f["logs"]["warn_err"]]
    if f.get("client"):
        f["client"]["events"] = []
    if f.get("mac"):
        f["mac"]["wifi"] = []
    if f.get("mesh"):
        f["mesh"]["peers"] = [{k: v for k, v in p.items() if k in ("online", "active", "exit_node", "exit_opt")} for p in f["mesh"]["peers"]]
    return f


def selftest():
    base = os.path.join(HERE, "fixtures")
    fails = 0
    cases = sorted(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d))) if os.path.isdir(base) else []
    for case in cases:
        facts = json.loads(read(os.path.join(base, case, "facts.json")))
        exp = json.loads(read(os.path.join(base, case, "expect.json")))
        res = {r["id"]: r["status"] for r in signatures.evaluate(facts, coverage(facts))}
        bad = [i for i in exp.get("hit", []) if res.get(i) != "hit"] + [i for i in exp.get("not_hit", []) if res.get(i) == "hit"]
        unknown = [i for i in exp.get("hit", []) + exp.get("not_hit", []) if i not in res]
        fails += bool(bad or unknown)
        print("%-4s %-40s %s" % ("FAIL" if bad or unknown else "ok", case,
                                 ("wrong: %s " % bad if bad else "") + ("unknown ids: %s" % unknown if unknown else "")))
    print("%d fixture(s), %d failing; %d rule(s) loaded" % (len(cases), fails, len(signatures.RULES)))
    return 1 if fails or not cases else 0


def save_fixture(name, cap):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,60}", name):
        sys.exit("fixture name: lowercase words-with-dashes, e.g. 2026-11-18-weak-2g4-coverage")
    facts = json.loads(read(os.path.join(cap, "facts.json")) or "null")
    if not facts:
        sys.exit("no facts.json in %s (run net-triage --replay %s first)" % (cap, cap))
    s = sanitize(facts)
    res = signatures.evaluate(s, coverage(s))
    d = os.path.join(HERE, "fixtures", name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "facts.json"), "w") as fh:
        json.dump(s, fh, indent=1, sort_keys=True)
    exp = {"hit": [r["id"] for r in res if r["status"] == "hit"], "not_hit": [],
           "why": "EDIT ME: what this capture proves, and which ids must NOT fire"}
    with open(os.path.join(d, "expect.json"), "w") as fh:
        json.dump(exp, fh, indent=1)
    print("wrote %s — now edit expect.json to the TRUE verdict (not just what fired), then --selftest" % d)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) == 4 and sys.argv[1] == "--save-fixture":
        save_fixture(sys.argv[2], sys.argv[3])
        return
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit(__doc__)
    cap = sys.argv[1]
    facts = build_facts(cap)
    with open(os.path.join(cap, "facts.json"), "w") as fh:
        json.dump(facts, fh, indent=1, sort_keys=True, default=str)
    results = signatures.evaluate(facts, coverage(facts))
    text = render(facts, results)
    with open(os.path.join(cap, "report.txt"), "w") as fh:
        fh.write(text + "\n")
    print(text)
    print("\nraw + facts.json + report.txt: %s" % cap)


if __name__ == "__main__":
    main()
