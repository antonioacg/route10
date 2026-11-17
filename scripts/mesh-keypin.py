#!/usr/bin/env python3
"""mesh-keypin.py — decide which mesh allowlist entries may forward, and emit their rules.

Called by mesh-allow.sh once a minute. Pure logic: no iptables, no logging, so it can be
tested anywhere against a saved `tailscale status --json`.

Contract: ops/NETWORK-CONTRACT.md §"Mesh → LAN / exit-node allowlist + node-key pins".

Usage:  mesh-keypin.py <status.json>   (the allowlist table on stdin)

Table rows (whitespace-separated, '#' comments and blank lines ignored):
    <name> <v4|-> <v6|-> <lan|-|ip:port|[ip6]:port> <exit|-> <nodekey:hex64>
  lan       = forward to every br-lan+, all protocols
  ip:port   = forward to that one address and port only, TCP and UDP, on br-lan+
  exit      = forward out the WAN devices (MESH_WAN_DEVS env, default "pppoe+ eth0")

Key pin, per listed address: EVERY peer whose AllowedIPs covers it must carry the
pinned key. AllowedIPs, not TailscaleIPs — WireGuard admits a packet's source by
AllowedIPs, and a hostile control server can show one address and route another.
"Any covering peer", not "the longest prefix": tailscale lazily trims idle peers out
of wireguard-go, so an idle legit /32 can be absent from the engine while a wider
prefix from another key is present. Strict on purpose; a legitimate peer advertising
an exit node or a route over the tailnet range therefore closes every entry.

Output lines:
    v <name> <addr> ok|mismatch|absent <detail>
    4 <iptables rule args>        (RETURN rules for the v4 chain)
    6 <ip6tables rule args>
Exit: 0 = verdicts + rules printed; 2 = peer status unusable (close everything);
      3 = table malformed (close everything). On 2/3 nothing but one reason line.
"""
import ipaddress
import json
import os
import re
import sys

NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,48}$")
KEY_RE = re.compile(r"^nodekey:[0-9a-f]{64}$")


def die(code, why):
    print(why)
    sys.exit(code)


def parse_scope(tok):
    """'lan' | '-' | 'ip:port' | '[ip6]:port' -> ('lan',) | None | ('one', ip, port)."""
    if tok == "lan":
        return ("lan",)
    if tok == "-":
        return None
    m = re.match(r"^\[([0-9A-Fa-f:.]+)\]:(\d{1,5})$", tok) or re.match(r"^([0-9.]+):(\d{1,5})$", tok)
    if not m:
        raise ValueError("bad scope %r" % tok)
    ip = ipaddress.ip_address(m.group(1))
    port = int(m.group(2))
    if not 0 < port < 65536:
        raise ValueError("bad port in %r" % tok)
    return ("one", ip, port)


def parse_table(text):
    rows = []
    for n, line in enumerate(text.splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        f = line.split()
        if len(f) != 6:
            raise ValueError("row %d: want 6 fields, got %d" % (n, len(f)))
        name, v4, v6, scope, exit_, key = f
        if not NAME_RE.match(name):
            raise ValueError("row %d: bad name %r" % (n, name))
        if not KEY_RE.match(key):
            raise ValueError("row %d (%s): bad key" % (n, name))
        if exit_ not in ("exit", "-"):
            raise ValueError("row %d (%s): exit must be 'exit' or '-'" % (n, name))
        a4 = None if v4 == "-" else ipaddress.IPv4Address(v4)
        a6 = None if v6 == "-" else ipaddress.IPv6Address(v6)
        if a4 is None and a6 is None:
            raise ValueError("row %d (%s): no address" % (n, name))
        rows.append({"name": name, "addrs": [a for a in (a4, a6) if a is not None],
                     "scope": parse_scope(scope), "exit": exit_ == "exit", "key": key})
    seen = set()
    for r in rows:
        for a in r["addrs"]:
            if a in seen:
                raise ValueError("address %s listed twice" % a)
            seen.add(a)
    return rows


def load_peers(path):
    try:
        with open(path) as fh:
            st = json.load(fh)
    except (OSError, ValueError) as e:
        die(2, "status unreadable (%s)" % e.__class__.__name__)
    if st.get("BackendState") != "Running":
        die(2, "BackendState=%s" % st.get("BackendState"))
    peers = []
    for p in (st.get("Peer") or {}).values():
        nets = []
        for pfx in p.get("AllowedIPs") or []:
            try:
                nets.append(ipaddress.ip_network(pfx, strict=False))
            except ValueError:
                die(2, "unparseable AllowedIPs entry")
        peers.append((p.get("PublicKey") or "", p.get("HostName") or "?", nets))
    return peers


def verdict(addr, pinned, peers):
    holders = [(k, h) for k, h, nets in peers if any(addr in n for n in nets if n.version == addr.version)]
    if not holders:
        return "absent", "no peer holds it"
    foreign = [(k, h) for k, h in holders if k != pinned]
    if foreign:
        return "mismatch", "pinned %s, also held by %s" % (
            pinned[8:20], ",".join("%s(%s)" % (k[8:20] or "nokey", h) for k, h in foreign))
    return "ok", "pinned key %s" % pinned[8:20]


def rules_for(row, addr, wan_devs):
    fam = "4" if addr.version == 4 else "6"
    src = "-s %s/%d" % (addr, addr.max_prefixlen)
    tag = "-m comment --comment %s" % row["name"]
    out = []
    sc = row["scope"]
    if sc and sc[0] == "lan":
        out.append("%s -o br-lan+ %s -j RETURN" % (src, tag))
    elif sc and sc[0] == "one" and sc[1].version == addr.version:
        for proto in ("tcp", "udp"):
            out.append("%s -d %s/%d -o br-lan+ -p %s --dport %d %s -j RETURN"
                       % (src, sc[1], sc[1].max_prefixlen, proto, sc[2], tag))
    if row["exit"]:
        for dev in wan_devs:
            out.append("%s -o %s %s -j RETURN" % (src, dev, tag))
    return [(fam, r) for r in out]


def main():
    if len(sys.argv) != 2:
        die(3, "usage: mesh-keypin.py <status.json> < table")
    try:
        rows = parse_table(sys.stdin.read())
    except ValueError as e:
        die(3, "table malformed: %s" % e)
    wan_devs = os.environ.get("MESH_WAN_DEVS", "pppoe+ eth0").split()
    for d in wan_devs:
        if not re.match(r"^[A-Za-z0-9._-]+\+?$", d):
            die(3, "bad WAN device %r" % d)
    peers = load_peers(sys.argv[1])
    lines, rules = [], []
    for row in rows:
        for addr in row["addrs"]:
            v, detail = verdict(addr, row["key"], peers)
            lines.append("v %s %s %s %s" % (row["name"], addr, v, detail))
            if v == "ok":
                rules += rules_for(row, addr, wan_devs)
    print("\n".join(lines + ["%s %s" % r for r in rules]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
