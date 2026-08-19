# ODI DFP-34X-2C3 — runtime environment facts (measured 2026-08-19)

All measured live during the post-collapse instrumented session (see
[`2026-08-18-odi-stick-userspace-collapse.md`](../postmortems/2026-08-18-odi-stick-userspace-collapse.md)
§4a for the method). These are the constraints any future stick-side design must fit.

## Memory — the number that killed us

```
MemTotal:  23296 kB     ← the WHOLE BOX. Not a filesystem quota.
MemFree:   ~2172 kB     ← fresh boot, 0-byte log. Healthy observed range 1.97–2.23 MB.
```

- `/var` is **ramfs** (`ramfs /var ramfs rw,relatime`): no backing store, pages freed only by
  truncate/unlink. **Reading a sparse hole materialises a page per 4 KB read**
  (`simple_readpage` allocates and keeps it) — reading is not free, it is allocation.
- Observed kill point for a transient whole-file read: **~10 MB** (9.9 MB reads survived
  for days once a minute; collapse at 10,014,726 B). Reclaimable page cache absorbs far more
  than MemFree suggests — but the collapse order (daemons → TCP accept → ICMP → ARP-only,
  resident `omci_app` survived) is what running out looks like.
- Exported every minute since 2026-08-19: `route10_pon_stick_mem_free_bytes`,
  `route10_pon_omci_log_bytes`.

## busybox v1.12.4 — the complete applet list

Checked at the **applet level** (`busybox` bare + `busybox <name>`), not just `$PATH` —
a capability proven on route10's busybox proves nothing here, they are different builds:

```
ash awk cat chmod cksum cmp cp cut date df diff echo egrep expr fuser grep halt
ifconfig init insmod kill killall klogd linuxrc ln ls lsmod md5sum mdev mkdir mknod
mount mv nc pidof ping ping6 poweroff ps reboot rm rmmod route sed sh sleep stty
tar telnet telnetd top traceroute umount vconfig
```

- **No seeking reader exists**: no `tail`, `head`, `dd`, `od`, `hexdump`, `wc`, `tr`, `du`,
  `split`, `truncate`. Nothing on this box can read a file from an offset. Any design that
  needs "read only the new bytes" must prevent the old bytes instead (see below).
- `grep` is minimal — no `-A/-B/-C`.
- `awk`, `sed`, `cut`, `expr`, `cmp`, `md5sum`, `cksum` DO exist (all stream from byte 0).

## /proc is a real instrument (kernel 2.6.30.9)

- `/proc/<pid>/fdinfo/<fd>` works: **pos + flags per fd**. This is how the OMCI write offset
  was measured directly (`omci_app` pid 357, log fds 9 = raw, 10 = `.par`).
- `omci_app` writes its log with **plain `write()` on a held O_RDWR fd** (flags 02, no
  O_APPEND): `: > file` resets the size but the offset survives, so the next write re-creates
  a hole exactly as deep as everything ever written. Hole depth ≡ bytes since offset was
  last 0.

## `omcicli set logfile` semantics (all three measured)

| Command | Effect on log fds |
|---|---|
| `set logfile 6 0x3FFFFFFF` (bare re-arm) | **none** — pos and fds untouched |
| `set logfile 0 0` then `6 0x3FFFFFFF` (toggle) | truncates the files, fds NOT reopened, pos survives |
| `set logfile 6 0x3FFFFFFF <fileName>` | **close + reopen at the path, pos 0** — fd numbers reused (no leak), works with the SAME name (proven via mv marker) |

The fileName form is the only offset-reset lever short of restarting `omci_app` (which is the
GPON MAC — never restart it for logging). `pon-collect.sh` issues it after every drain.
Parsed mode still writes to `<fileName>.par`.

## Session/tooling constraints (unchanged, for completeness)

- Single CLI via `/bin/login` + `cli.pid` — [`odi-cli-pid-lock.md`](odi-cli-pid-lock.md).
- No SSH possible, telnet via `stick-exec.py` only; Lexra-MIPS ⇒ stock MIPS binaries trap;
  building needs RSDK-1.5.6p2 (gcc 4.4.6). Cross-compiling a seeking reader was evaluated
  2026-08-19 and rejected: the fileName reopen made it unnecessary, and a pushed binary would
  live in `/var` — the very RAM being defended.
