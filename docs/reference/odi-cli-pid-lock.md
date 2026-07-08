# ODI M114 — Single-CLI Lock at /var/run/cli.pid

*Custom /bin/login enforces one CLI globally via /var/run/cli.pid. Ungraceful telnet close orphans the lock; only stick reboot reliably clears it (no periodic configd sweep). odi-health.sh probe_w2_optical was patched 2026-05-25 to clean-exit and avoid orphaning.*

**Mechanism (verified 2026-05-25 from M114 squashfs + live empirical test):**
- `/bin/login` on the stick is a 5.1KB custom Realtek binary (`v1.0.2`), not busybox. Its strings include: `/var/run/cli.pid`, `CLI busy !!`, `Authentication successful…`, `Login incorrect`.
- Imports: `fopen64, fclose, getpass, getpwnam, crypt, openlog, syslog, execlp, sleep, signal, pause, strstr` — **no `unlink`, no `kill`, no `access`**. login cannot remove the lock or check pid liveness.
- On successful auth: writes own PID to `/var/run/cli.pid`, then execlp's shell. On stale pid present: prints `CLI busy !!` and exits → telnetd closes socket → client sees TCP-accept + zero banner + RST at t≈10ms (EMPTY_BANNER).
- **configd is theoretically the cleanup path** (has `unlink`, `kill`, `killall`, `checkPidExist`; lists `cli.pid` alongside `boa.pid`, `telnetd.pid`, `dropbear.pid`, `udhcpd.pid`) — BUT in practice configd has **no periodic sweep**: only `usleep` as timing primitive, no `alarm`/`setitimer`/`select`/`poll`/`timerfd`/`nanosleep`. `checkPidExist` is presumably called on demand via IPC `msgProcess`, and we never identified the trigger. Empirically tested 2026-05-25: login/status.asp, pon-stats.asp, save_cs dump, multi_wan_generic.asp, formPing-loopback, saveconf.asp — **none triggered a sweep**. My earlier "20–30 min cadence" claim was wrong; the apparent clearing was actually the stick rebooting (proven by inspecting stick uptime in `/admin/status.asp` — was ~2h, matched the WAN3 re-dial event).
- `/var` is `ramfs` (rc2 mounts `ramfs ramfs /var`), so **stick reboot is the only reliable unwedge primitive.** Via Boa: `POST /boaform/admin/formReboot` with `reboot_now=Reboot` after a login POST. Empirically: stick ping returns in ~77s, WAN3 PPPoE re-establishes in ~85s total. User accepts this as a "quick blip" for unwedging when needed.

**The wedge trigger (empirically confirmed):**
1 ungraceful socket close → 1 orphan → next ~N login attempts wedge. Phase A test (2026-05-25): 1st ugly close OK, attempts 2–5 all EMPTY_BANNER. Phase B (subsequent clean closes against the existing orphan): 5/5 EMPTY_BANNER — clean exit prevents *new* orphans but cannot remove an existing one.

**The clean-exit pattern (prevents new orphans):**
```python
s.send(b'exit\r\n')             # tell shell to terminate normally
# drain until FIN
while True:
    s.settimeout(0.5)
    try: d = s.recv(4096)
    except socket.timeout: break  # or break on time budget
    if not d: break
s.shutdown(socket.SHUT_RDWR); s.close()
```

**The bug in /cfg/scripts/odi-health.sh — PATCHED 2026-05-25:**
`probe_w2_optical()` was opening telnet via `socket.create_connection`, running OMCI commands, then calling `s.close()` without sending `exit\r\n`. Every successful poll orphaned `/var/run/cli.pid`. That was the `W2_probe_err=[Errno_32]_Broken_pipe` saturation pattern. **Patched:** the function now sends `exit\r\n`, drains until FIN, then closes. Live-verified: 4 consecutive odi-health cycles produce `W2_OntState=1 W2_rx_dBm=… W2_tx_dBm=…` with no error.
`restore_mgmt()` was also gutted at the same time — went from 7 hacks (alias + /32 route + ip rule + iptables) to a 2-line self-heal that re-runs `/cfg/post-cfg.sh` only if `ont_mgmt0` is missing, since the MACVLAN mgmt path (see the Alta MACVLAN mgmt-path pattern reference) handles routing/firewall now.

**Companion tools in `this repo (scripts/ + tools/)`:**
- `stick-exec.py` — clean-exit telnet CLI: `stick-exec.py 'omcicli mib get 256' 'omcicli mib get 263'`. Multi-cmd output attribution fixed (marker matched as standalone line, not within echoed `echo MARKER`).
- `stick-relay.py` — persistent-session Unix-socket daemon (`/var/run/stick-relay.sock`). Holds one global CLI session so no per-poll login → no lock contention. Same parser fix applied. **Not deployed**; on the shelf as insurance if per-call clean-exit ever proves insufficient. Currently per-call is reliable enough (11+ consecutive clean probes, 4+ odi-health cycles).
- Both files now live persistently at `/cfg/scripts/stick-exec.py` and `/cfg/scripts/stick-relay.py` on Route10 (moved from `/tmp/` 2026-05-25). Smoke-tested from new path. Local source-of-truth: `this repo (scripts/ + tools/)`.

**Parser gotcha worth remembering (applies to any "run shell cmd over telnet" tool):**
The stick echoes the input line back BEFORE the command runs. If you send `cmd; echo MARKER\r\n` and recv-until `MARKER` in buffer, you exit on the echo, miss the output, and the next cmd inherits the previous one's bytes. Fix: match marker only as a standalone line (`\r?\nMARKER\r?\n` regex), not as bare substring.

**How to apply:** if writing new code that opens telnet to the stick, ALWAYS use the clean-exit pattern (or call `stick-exec.py`). If telnet probes return EMPTY_BANNER, the lock is held — don't retry-storm; wait or use HTTP (Boa) instead.

# Banner-only telnet probes ALSO orphan the lock (added 2026-05-26)

**Hard-learned this session: opening a telnet socket, reading the `login:` banner, and TCP-closing without ever authenticating ALSO orphans `/var/run/cli.pid` — after a delay of tens of seconds.** Wedged the stick FOUR TIMES in one session by using "is the stick CLI up?" probes like:
```python
s = socket.create_connection(('192.168.1.1', 23), timeout=3)
recv-until-FIN-or-timeout; close()
# ← orphan trigger, even though we never sent username
```

Empirical pattern matched the documented Phase A: first banner probe gets `login:` (22 bytes), subsequent attempts get `banner_bytes=0` after ~30-60s. The wedge-onset delay led me to mistakenly attribute it to `close_session` regressions in stick-exec.py — the real cause was the until-loop's banner check at line `until ping ... && python3 -c "<banner-check>"; do ...`.

**Best hypothesis for the mechanism (not verified at binary level):** /bin/login on this stick writes `/var/run/cli.pid` earlier than the prior memory note assumed (probably right after spawn, not after auth). TCP-close before sending credentials leaves /bin/login as a zombie or background process; cli.pid is never unlinked. Subsequent connections see the orphan and bail.

**Rules for the future:**
- **NEVER do banner-only telnet probes.** Even one is enough to start the wedge.
- For "is stick CLI up?" liveness: use **Boa HTTP** (`curl --http0.9 -s -m 3 --interface 192.168.1.2 http://192.168.1.1/admin/login.asp` — exits 0 if Boa responds).
- For "is the stick rebooted yet?" wait loops: use ping (`ping -c 1 -W 1 -I 192.168.1.2 192.168.1.1`) AND Boa, NOT telnet banner.
- For full CLI access, use `stick-exec.py` / `diag-drive.py` which always do full auth + clean-exit.
- If you need to detect a *running orphan*, just try `stick-exec.py` once — it raises `WEDGED` cleanly without making things worse (its `open_session` exits on empty banner without engaging /bin/login further).

Once orphaned, **only stick reboot clears it.** Reboot via Boa:
```sh
curl --http0.9 -s -m 5 --interface 192.168.1.2 -o /dev/null \
    -X POST -d 'username=admin&password=admin&challenge=&save=Login&submit-url=%2Fadmin%2Flogin.asp' \
    http://192.168.1.1/boaform/admin/formLogin
curl --http0.9 -s -m 5 --interface 192.168.1.2 -o /dev/null \
    -X POST -d 'reboot_now=Reboot' http://192.168.1.1/boaform/admin/formReboot
# ~81s for CLI to return; WAN3 PPPoE re-establishes around the same time.
```
