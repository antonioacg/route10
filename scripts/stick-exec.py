#!/usr/bin/env python3
# stick-exec.py — run one or more shell commands on the ODI stick (192.168.1.1)
# over telnet, with the clean-exit handshake that prevents /var/run/cli.pid orphans.
#
# Usage:
#   stick-exec.py 'cat /proc/uptime'
#   stick-exec.py 'omcicli mib get 256' 'omcicli mib get 263'
#   stick-exec.py --json 'cmd1' 'cmd2'    # JSON output keyed by command
#
# Exit 0 on success, 1 on connection/auth failure, 2 on wedge (cli.pid stuck).
#
# Why: odi-health.sh's probe_w2_optical() opens telnet, runs OMCI, then closes
# the socket without sending `exit` — orphans /var/run/cli.pid, wedges the next
# login attempt until configd's stale-pid sweep clears it. This module always
# sends `exit\r\n` and drains the FIN, so /bin/login's shell unlinks the lock.

import socket, sys, time, argparse, json, re, random

SRC = '192.168.1.2'
DST = '192.168.1.1'
PORT = 23
USER = b'admin'
PASS = b'admin'
PROMPT_RE = re.compile(rb'[#\$]\s*$')

class StickError(Exception): pass
class Wedged(StickError): pass
class AuthFailed(StickError): pass

def _recv_until(s, deadline, pred):
    """Recv until pred(buf) is True or deadline. Returns accumulated buf."""
    buf = b''
    while True:
        remaining = deadline - time.time()
        if remaining <= 0: return buf
        s.settimeout(min(remaining, 1.0))
        try:
            d = s.recv(4096)
        except socket.timeout:
            if pred(buf): return buf
            continue
        if not d: return buf
        buf += d
        if pred(buf): return buf

def open_session(timeout=8.0):
    deadline = time.time() + timeout
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind((SRC, 0))
    s.settimeout(min(timeout, 5.0))
    s.connect((DST, PORT))
    banner = _recv_until(s, deadline,
        lambda b: b'login:' in b or b'busy' in b.lower())
    if not banner:
        s.close(); raise Wedged("empty banner — /var/run/cli.pid is stuck (wait for configd sweep)")
    if b'busy' in banner.lower():
        s.close(); raise Wedged(f"CLI busy: {banner!r}")
    if b'login:' not in banner:
        s.close(); raise StickError(f"no login prompt: {banner!r}")
    s.send(USER + b'\r\n')
    _recv_until(s, deadline, lambda b: b'assword' in b)
    s.send(PASS + b'\r\n')
    sh = _recv_until(s, deadline, lambda b: PROMPT_RE.search(b) is not None)
    if not PROMPT_RE.search(sh):
        if b'incorrect' in sh.lower(): s.close(); raise AuthFailed("login incorrect")
        s.close(); raise StickError(f"no shell prompt: {sh!r}")
    return s

def run_cmd(s, cmd, timeout=10.0):
    """Send one command, return stdout bytes (prompt + echo stripped).

    Subtle: the stick echoes the input line back, so `cmd; echo MARKER` appears
    in the recv buffer BEFORE the actual command output arrives. If we just
    `marker in buf` we exit the read on the echo, get an empty body, and the
    next command's recv inherits the previous command's output. Fix: only
    consider the marker matched when it's on its OWN line (preceded and
    followed by a newline) — the echoed `echo MARKER\\n` does not satisfy that.
    """
    deadline = time.time() + timeout
    marker = f"__EOC_{int(time.time()*1000)}_{random.randint(1000,9999)}__"
    marker_line_re = re.compile(b'\r?\n' + re.escape(marker.encode()) + b'\r?\n')
    s.send(f'{cmd}; echo {marker}\r\n'.encode())
    out = _recv_until(s, deadline, lambda b: marker_line_re.search(b) is not None)
    m = marker_line_re.search(out)
    if not m:
        raise StickError(f"command timeout: {cmd!r}, partial={out[-200:]!r}")
    text = out[:m.start()].decode('latin1', errors='replace')
    # Drop any line containing the marker literal (the echoed `; echo MARKER`).
    # Drop any line that's a shell prompt leak from before our send.
    body = [ln for ln in text.splitlines()
            if marker not in ln and not re.match(r'^[#\$]\s*$', ln)]
    # Also drop the echoed command line if it's the first remaining line.
    if body and cmd.split(';')[0].strip() in body[0]:
        body = body[1:]
    return '\n'.join(body).strip()

def close_session(s, drain_timeout=2.0, interrupted=False):
    """Send `exit`, drain until FIN, then close.

    Without this, /var/run/cli.pid is orphaned and the next login wedges.

    If `interrupted=True` (run_cmd timed out), the shell is still executing
    that command, so `exit` would sit in stdin. We send telnet IAC-IP first
    (TCP-level interrupt-process, properly translated to SIGINT by telnetd —
    safer than raw Ctrl-C which the shell would interpret as input mid-cmd),
    then proceed with the normal exit flow.
    """
    if interrupted:
        # IAC IP = 0xFF 0xF4 — telnet's "interrupt process" command.
        # telnetd sends SIGINT to the shell's foreground process group.
        try: s.send(b'\xff\xf4')
        except Exception: pass
        time.sleep(0.5)
        # Discard whatever came back (^C, partial output, fresh prompt)
        s.settimeout(0.4)
        try:
            while True:
                d = s.recv(4096)
                if not d: break
        except Exception: pass
    # Normal exit
    try: s.send(b'exit\r\n')
    except Exception: pass
    deadline = time.time() + drain_timeout
    while time.time() < deadline:
        try:
            s.settimeout(min(deadline - time.time(), 0.5))
            d = s.recv(4096)
            if not d: break
        except socket.timeout: continue
        except Exception: break
    try: s.shutdown(socket.SHUT_RDWR)
    except Exception: pass
    try: s.close()
    except Exception: pass

def exec_all(cmds, per_cmd_timeout=10.0, session_timeout=8.0):
    """Open one session, run all cmds, close cleanly. Returns dict {cmd: output}."""
    s = open_session(session_timeout)
    interrupted = False
    try:
        results = {}
        for c in cmds:
            try:
                results[c] = run_cmd(s, c, per_cmd_timeout)
            except StickError:
                interrupted = True
                raise
        return results
    finally:
        close_session(s, interrupted=interrupted)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('cmds', nargs='+')
    p.add_argument('--json', action='store_true', help='emit JSON keyed by cmd')
    p.add_argument('--timeout', type=float, default=10.0)
    args = p.parse_args()
    try:
        results = exec_all(args.cmds, per_cmd_timeout=args.timeout)
    except Wedged as e:
        print(f"WEDGED: {e}", file=sys.stderr); sys.exit(2)
    except AuthFailed as e:
        print(f"AUTH_FAIL: {e}", file=sys.stderr); sys.exit(1)
    except StickError as e:
        print(f"ERR: {e}", file=sys.stderr); sys.exit(1)
    except Exception as e:
        print(f"FATAL: {type(e).__name__}: {e}", file=sys.stderr); sys.exit(1)
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for c, out in results.items():
            print(f"=== {c} ==="); print(out)

if __name__ == '__main__':
    main()
