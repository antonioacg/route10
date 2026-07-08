#!/usr/bin/env python3
# stick-relay.py — persistent single-session telnet relay to the ODI stick.
#
# Runs as a daemon on Route10. Holds ONE long-lived telnet to 192.168.1.1:23
# (the stick allows exactly one CLI session globally via /var/run/cli.pid).
# Exposes a Unix socket at /var/run/stick-relay.sock — clients submit a
# command per connection, get the output back, then disconnect.
#
# Why over stick-exec.py: never opens/closes telnet → never trips the cli.pid
# lock under any client bug; per-poll latency drops from ~100ms to ~30ms; one
# pid file orphan over the daemon's entire lifetime instead of N per N polls.
#
# Risks:
#   - if the daemon dies without sending `exit`, it orphans cli.pid until
#     configd's stale-pid sweep runs. Handled by SIGTERM/SIGINT trap.
#   - if the stick reboots, the telnet session FINs; daemon reconnects after
#     a backoff (5s, 30s, 60s, …). First reconnect after a wedge will fail
#     until configd clears the orphan.
#
# Wire protocol (per connection):
#   client →   {"cmd": "...", "timeout": 10.0}\n
#   daemon →   {"ok": true, "out": "...", "took": 0.041}\n
#   daemon →   {"ok": false, "err": "wedged"|"timeout"|"disconnected"|...}\n
#
# Usage:
#   stick-relay.py                 # foreground
#   stick-relay.py --sock /tmp/...  --log /tmp/relay.log
# Client:
#   echo '{"cmd":"uptime"}' | nc -U /var/run/stick-relay.sock

import socket, os, sys, time, json, signal, re, argparse, threading, errno, random

SRC = '192.168.1.2'
DST = '192.168.1.1'
PORT = 23
USER = b'admin'
PASS = b'admin'
PROMPT_RE = re.compile(rb'[#\$]\s*$')
SOCK_PATH = '/var/run/stick-relay.sock'
LOG_PATH = '/var/log/stick-relay.log'

logfile = sys.stderr  # rebound in main()

def log(msg):
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    try: logfile.write(f"{ts} {msg}\n"); logfile.flush()
    except Exception: pass

# ────────────────────────────────────────────────────────────────────────────
# Telnet session
# ────────────────────────────────────────────────────────────────────────────
class StickSession:
    def __init__(self):
        self.s = None
        self.lock = threading.Lock()
        self.connected_at = 0

    def _recv_until(self, deadline, pred):
        buf = b''
        while True:
            remaining = deadline - time.time()
            if remaining <= 0: return buf
            self.s.settimeout(min(remaining, 1.0))
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                if pred(buf): return buf
                continue
            if not d: return buf
            buf += d
            if pred(buf): return buf

    def open(self, timeout=8.0):
        deadline = time.time() + timeout
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind((SRC, 0))
        s.settimeout(min(timeout, 5.0))
        s.connect((DST, PORT))
        self.s = s
        banner = self._recv_until(deadline,
            lambda b: b'login:' in b or b'busy' in b.lower())
        if not banner:
            self._hard_close(); raise RuntimeError("empty banner (wedged)")
        if b'busy' in banner.lower():
            self._hard_close(); raise RuntimeError(f"cli busy: {banner!r}")
        if b'login:' not in banner:
            self._hard_close(); raise RuntimeError(f"no login: {banner!r}")
        s.send(USER + b'\r\n')
        self._recv_until(deadline, lambda b: b'assword' in b)
        s.send(PASS + b'\r\n')
        sh = self._recv_until(deadline, lambda b: PROMPT_RE.search(b) is not None)
        if not PROMPT_RE.search(sh):
            self._hard_close()
            raise RuntimeError(f"no shell: {sh!r}")
        self.connected_at = time.time()
        log(f"session OPEN")

    def run(self, cmd, timeout=10.0):
        # See stick-exec.py run_cmd() for why we match the marker only as a
        # standalone line: the stick echoes our `echo MARKER`, which would
        # otherwise be matched on first recv and leak cmd-N's output into cmd-N+1.
        deadline = time.time() + timeout
        marker = f"__EOC_{int(time.time()*1000)}_{random.randint(1000,9999)}__"
        marker_line_re = re.compile(b'\r?\n' + re.escape(marker.encode()) + b'\r?\n')
        self.s.send(f'{cmd}; echo {marker}\r\n'.encode())
        out = self._recv_until(deadline, lambda b: marker_line_re.search(b) is not None)
        m = marker_line_re.search(out)
        if not m:
            raise RuntimeError(f"cmd timeout, last={out[-200:]!r}")
        text = out[:m.start()].decode('latin1', errors='replace')
        body = [ln for ln in text.splitlines()
                if marker not in ln and not re.match(r'^[#\$]\s*$', ln)]
        if body and cmd.split(';')[0].strip() in body[0]:
            body = body[1:]
        return '\n'.join(body).strip()

    def close_clean(self, drain=2.0):
        if not self.s: return
        try: self.s.send(b'exit\r\n')
        except Exception: pass
        deadline = time.time() + drain
        while time.time() < deadline:
            try:
                self.s.settimeout(min(deadline - time.time(), 0.5))
                d = self.s.recv(4096)
                if not d: break
            except socket.timeout: continue
            except Exception: break
        try: self.s.shutdown(socket.SHUT_RDWR)
        except Exception: pass
        self._hard_close()
        log(f"session CLOSED clean")

    def _hard_close(self):
        try:
            if self.s: self.s.close()
        except Exception: pass
        self.s = None

    def alive(self):
        return self.s is not None

# ────────────────────────────────────────────────────────────────────────────
# Daemon: client loop + reconnect with backoff
# ────────────────────────────────────────────────────────────────────────────
class Relay:
    BACKOFF = [5, 15, 30, 60, 120, 300]  # seconds; last value sticks

    def __init__(self, sock_path):
        self.sock_path = sock_path
        self.sess = StickSession()
        self.stop = False
        self.fail_idx = 0

    def ensure_session(self):
        if self.sess.alive(): return True
        try:
            self.sess.open()
            self.fail_idx = 0
            return True
        except Exception as e:
            wait = self.BACKOFF[min(self.fail_idx, len(self.BACKOFF)-1)]
            log(f"open FAIL ({e}) — backoff {wait}s")
            self.fail_idx += 1
            time.sleep(wait)
            return False

    def handle_client(self, c):
        c.settimeout(5.0)
        try:
            buf = b''
            while b'\n' not in buf and len(buf) < 8192:
                d = c.recv(4096)
                if not d: break
                buf += d
            if not buf: return
            try:
                req = json.loads(buf.decode('latin1').split('\n',1)[0])
                cmd = req['cmd']; tout = float(req.get('timeout', 10.0))
            except Exception as e:
                c.send(json.dumps({"ok": False, "err": f"bad request: {e}"}).encode() + b'\n')
                return
            with self.sess.lock:
                if not self.sess.alive():
                    if not self.ensure_session():
                        c.send(json.dumps({"ok": False, "err": "session not ready"}).encode() + b'\n')
                        return
                t0 = time.time()
                try:
                    out = self.sess.run(cmd, timeout=tout)
                    c.send(json.dumps({"ok": True, "out": out, "took": round(time.time()-t0,3)}).encode() + b'\n')
                except Exception as e:
                    log(f"run error ({e!r}) — dropping session")
                    self.sess._hard_close()
                    c.send(json.dumps({"ok": False, "err": str(e)}).encode() + b'\n')
        finally:
            try: c.close()
            except Exception: pass

    def serve(self):
        try: os.unlink(self.sock_path)
        except FileNotFoundError: pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock_path)
        os.chmod(self.sock_path, 0o660)
        srv.listen(8)
        srv.settimeout(1.0)
        log(f"listening on {self.sock_path}")
        # Eager-connect on startup
        self.ensure_session()
        while not self.stop:
            try:
                c, _ = srv.accept()
            except socket.timeout:
                # Periodic keepalive — push a no-op to detect dead sessions
                if self.sess.alive():
                    with self.sess.lock:
                        try:
                            self.sess.run('true', timeout=3.0)
                        except Exception as e:
                            log(f"keepalive FAIL ({e}) — dropping session")
                            self.sess._hard_close()
                continue
            threading.Thread(target=self.handle_client, args=(c,), daemon=True).start()
        # Shutdown
        log("shutting down")
        try:
            with self.sess.lock:
                if self.sess.alive(): self.sess.close_clean()
        except Exception: pass
        try: os.unlink(self.sock_path)
        except Exception: pass

def main():
    global logfile
    ap = argparse.ArgumentParser()
    ap.add_argument('--sock', default=SOCK_PATH)
    ap.add_argument('--log', default=LOG_PATH)
    args = ap.parse_args()
    try: logfile = open(args.log, 'a')
    except Exception: logfile = sys.stderr
    relay = Relay(args.sock)
    def stop(*_):
        log("SIGTERM/SIGINT received")
        relay.stop = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    relay.serve()

if __name__ == '__main__':
    main()
