#!/usr/bin/env python3
# Bidirectional TCP proxy with source-IP bind. Used as SSH ProxyCommand.
# Self-heals the destination route on Route10 before connecting — Alta's
# configd silently removes our 192.168.1.1/32 dev eth4 override.
import socket, sys, os, threading, subprocess
if len(sys.argv) != 4:
    sys.stderr.write("usage: tcppipe.py SRC_IP DST_IP DST_PORT\n"); sys.exit(2)
src_ip, dst_ip, dst_port = sys.argv[1], sys.argv[2], int(sys.argv[3])
# Self-heal route: ensure DST_IP is reachable via the interface owning SRC_IP
# (idempotent; cheap; only matters when src/dst are in same /24 conflict).
try:
    r = subprocess.run(["ip", "-o", "route", "get", dst_ip], capture_output=True, text=True, timeout=2)
    if r.returncode == 0 and ("src " + src_ip) not in r.stdout:
        # Wrong source IP → wrong outgoing interface. Find iface owning src_ip.
        a = subprocess.run(["ip", "-o", "-4", "addr"], capture_output=True, text=True, timeout=2)
        iface = next((ln.split()[1] for ln in a.stdout.splitlines() if " " + src_ip + "/" in ln), None)
        if iface:
            subprocess.run(["ip", "route", "replace", dst_ip + "/32", "dev", iface, "src", src_ip], timeout=2)
except Exception as e:
    sys.stderr.write("route-heal: %s\n" % e)
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind((src_ip, 0))
s.connect((dst_ip, dst_port))
def s2stdout():
    try:
        while True:
            d = s.recv(4096)
            if not d: break
            os.write(1, d)
    except: pass
    try: os.close(1)
    except: pass
    os._exit(0)
threading.Thread(target=s2stdout, daemon=True).start()
try:
    while True:
        d = os.read(0, 4096)
        if not d: break
        s.send(d)
except: pass
try: s.shutdown(socket.SHUT_WR)
except: pass
