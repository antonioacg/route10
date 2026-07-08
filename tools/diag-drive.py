#!/usr/bin/env python3
# diag-drive.py — drive the stick's interactive diag (RTK.0>) shell non-interactively.
#
# Usage:
#   diag-drive.py 'debug europa dump a2' 'debug europa dump a0'
#
# Why this exists: stick-exec.py runs commands in /bin/sh (single prompt). diag is
# a different cparser-based shell with its own RTK.0> prompt and its own command
# tree. After all commands, we need to exit diag (back to /bin/sh), THEN exit /bin/sh
# (so /var/run/cli.pid clears cleanly). Wedging this is easy if you blast exits
# without waiting for each prompt back. See project_odi_cli_pid_lock.md.
#
# Robustness pattern (same as stick-exec.py):
#  - Wait for each prompt back between commands (no blast-and-sleep)
#  - On ANY exit path: send Ctrl-C first to interrupt anything running, drain,
#    then exit diag, drain, exit shell, drain FIN
#  - Lifeline timeout on every recv so we never hang the parent caller

import socket, sys, time, argparse, re

SRC = '192.168.1.2'
DST = '192.168.1.1'
PORT = 23
USER = b'admin'
PASS = b'admin'
SH_PROMPT = re.compile(rb'[#\$]\s*$')
DIAG_PROMPT = re.compile(rb'RTK\.\d+>\s*$')

class StickError(Exception): pass
class Wedged(StickError): pass

def _recv_until(s, deadline, pred):
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
    s.bind((SRC, 0)); s.settimeout(min(timeout, 5.0))
    s.connect((DST, PORT))
    banner = _recv_until(s, deadline, lambda b: b'login:' in b or b'busy' in b.lower())
    if not banner:
        s.close(); raise Wedged("empty banner — /var/run/cli.pid is stuck")
    if b'busy' in banner.lower():
        s.close(); raise Wedged(f"CLI busy: {banner!r}")
    s.send(USER + b'\r\n')
    _recv_until(s, deadline, lambda b: b'assword' in b)
    s.send(PASS + b'\r\n')
    sh = _recv_until(s, deadline, lambda b: SH_PROMPT.search(b) is not None)
    if not SH_PROMPT.search(sh):
        s.close(); raise StickError(f"no shell prompt: {sh!r}")
    return s

def enter_diag(s, timeout=6.0):
    """From shell prompt, enter diag and wait for RTK.0>."""
    deadline = time.time() + timeout
    s.send(b'diag\r\n')
    buf = _recv_until(s, deadline, lambda b: DIAG_PROMPT.search(b) is not None)
    if not DIAG_PROMPT.search(buf):
        raise StickError(f"diag prompt never appeared: {buf[-200:]!r}")
    return buf

def run_diag_cmd(s, cmd, timeout=15.0):
    """Send one diag command, wait for RTK.0> back, return the body."""
    deadline = time.time() + timeout
    s.send(cmd.encode() + b'\r\n')
    out = _recv_until(s, deadline, lambda b: DIAG_PROMPT.search(b) is not None)
    if not DIAG_PROMPT.search(out):
        raise StickError(f"diag cmd timeout: {cmd!r}, partial={out[-200:]!r}")
    # Strip the echoed input line and the trailing prompt
    text = out.decode('latin1', errors='replace')
    # remove trailing prompt
    text = DIAG_PROMPT.sub(b'', out).decode('latin1', errors='replace')
    # drop echoed command line(s) at the top
    lines = text.splitlines()
    body = []
    skip_echo = True
    for ln in lines:
        if skip_echo and cmd.strip() in ln:
            skip_echo = False
            continue
        body.append(ln)
    return '\n'.join(body).rstrip()

def close_session(s, drain_timeout=4.0, interrupted=False):
    """Clean exit: exit diag, wait shell, exit shell, drain FIN.

    Two shells deep (/bin/sh -> diag -> back to /bin/sh -> logout).

    On interrupted=True (a diag cmd timed out): send telnet IAC-IP first to
    signal the foreground process group. cparser shells handle SIGINT by
    returning to the prompt. See stick-exec.py close_session for rationale.
    """
    if interrupted:
        try: s.send(b'\xff\xf4')  # IAC IP
        except Exception: pass
        time.sleep(0.5)
        s.settimeout(0.4)
        try:
            while True:
                d = s.recv(4096)
                if not d: break
        except Exception: pass
    # 1) Exit diag → returns to /bin/sh prompt
    try: s.send(b'exit\r\n')
    except Exception: pass
    # 2) Wait for shell prompt back (up to 3s)
    sh_deadline = time.time() + 3.0
    buf = b''
    while time.time() < sh_deadline:
        try:
            s.settimeout(min(sh_deadline - time.time(), 0.5))
            d = s.recv(4096)
            if not d: break
            buf += d
            if SH_PROMPT.search(buf): break
        except socket.timeout: continue
        except Exception: break
    # 3) Exit shell → /bin/login exits → FIN
    try: s.send(b'exit\r\n')
    except Exception: pass
    # 4) Drain until FIN (or timeout)
    fin_deadline = time.time() + drain_timeout
    while time.time() < fin_deadline:
        try:
            s.settimeout(min(fin_deadline - time.time(), 0.5))
            d = s.recv(4096)
            if not d: break
        except socket.timeout: continue
        except Exception: break
    try: s.shutdown(socket.SHUT_RDWR)
    except Exception: pass
    try: s.close()
    except Exception: pass

def main():
    p = argparse.ArgumentParser()
    p.add_argument('cmds', nargs='+')
    p.add_argument('--timeout', type=float, default=15.0)
    args = p.parse_args()
    s = None
    interrupted = False
    try:
        s = open_session()
        enter_diag(s)
        for c in args.cmds:
            print(f"\n===CMD: {c}===")
            try:
                out = run_diag_cmd(s, c, timeout=args.timeout)
                print(out)
            except StickError as e:
                print(f"[CMD ERROR] {e}", file=sys.stderr)
                interrupted = True
                break
    except Wedged as e:
        print(f"WEDGED: {e}", file=sys.stderr); sys.exit(2)
    except StickError as e:
        interrupted = True
        print(f"ERR: {e}", file=sys.stderr); sys.exit(1)
    finally:
        if s is not None:
            close_session(s, interrupted=interrupted)

if __name__ == '__main__':
    main()
