---
name: upgrading
description: >-
  Use before and during any risky change to the live joggo runner — cutting over to the
  containerized slot, upgrading the runner version, editing the self-heal layers, or changing WSL
  config. Covers the proven order (restore point → verify it → baseline smoke → change → smoke →
  keep or roll back), the one-command rollback, the runner-smoke workflow and how to read it, the
  fault injections that validate self-heal, and the verification traps that make a broken runner
  look healthy. Operator skill for the joggo platform repo. Trigger on "cut over to the
  containerized runner", "upgrade the runner", "roll back the runner", "smoke test the runner",
  "is it safe to change the runner", "test the self-heal", "restore point for joggo".
---

# Change the runner without losing CI

`joggo` is a single box serving twelve repos with no fallback. Every change to it is a change
to production CI, and the failure mode is *silent*: the runner looks `active` while taking no
jobs. This is the order that has actually worked, and the traps that have actually bitten.

**Never skip step 0 or step 2.** A cutover attempt on 2026-09-05 failed in 49 s; it cost nothing
because the restore point existed and the baseline had already proven the smoke test.

| Step | Why it is not optional |
|---|---|
| 0. Restore point | The tag in git is **not** a restore point — see §1 |
| 1. Verify the restore point | An untested backup is a hope, not a rollback |
| 2. **Baseline** smoke on the CURRENT runner | Proves the *test* works while the proven runner still serves |
| 3. Change | — |
| 4. Smoke again, compare | The only proof a real job survives the change |
| 5. Keep or roll back | Decide on evidence, not on the absence of errors |

## 1. Restore point (~450 MB, 2 minutes)

`git tag v1.0.0` captures the **repo**, not the machine. The live registration
(`.runner`, `.credentials`), the installed systemd units and the chrony drop-in are not in git and
correctly never will be. "Restore to the tag" means *re-run setup and re-register*, which needs a
registration token — and minting one returns **403** without `admin:org`. So take the real thing:

Since 2026-09-06 this is a script rather than a recipe to retype, because the recipe was
written down three times and executed zero times — the finding stayed open through an entire
architecture change:

```bash
# from WSL, as root. Stage on ext4 and copy: writing the stream straight to /mnt/c
# takes >10 min, staging locally takes ~2.
/usr/local/sbin/take-restore-point.sh /var/tmp/rp
cp -p /var/tmp/rp/* /mnt/c/Users/you/joggo-restore/ && rm -rf /var/tmp/rp
```

It captures the runner root (minus `_work` and `_diag`), `/etc/systemd/system`,
`/usr/local/sbin` and `/etc/chrony`, and writes a **MANIFEST** beside and inside the archive
carrying unit states, script checksums, image ids and the restore steps. `_work` is excluded on
purpose now, not just for size: it is throwaway by design since the cutover, and restoring it
would restore the exact root-owned poisoning this architecture exists to end.

The local **images** are deliberately not in the archive — a 700 MB layer inside a
secret-bearing tarball is a poor trade for a one-line build. Since 2026-09-12 there are
**two** of them, and a slot will not start without both:

```bash
docker build -t joggo/actions-runner:local tools/runner-image
slots/dind-image/build.sh          # joggo/dind:local — dind + digest-pinned buildkit
```

If only the dind image is missing, the fallback is one variable:
`DIND_IMAGE=docker:28-dind systemctl restart joggo-slot@1` — jobs then pull buildkit from
Docker Hub per job again, which works but reinstates the 2026-09-11 failure mode.

⚠ **The archive contains runner credentials and lands world-readable.** `chmod 600` does not stick
on `/mnt/c` — DrvFs ignores Unix modes, so the file reports `0600` from Linux and lists as
`-rwxrwxrwx`. The script now warns when `DEST` is under `/mnt/`, but it cannot fix it from Linux.
Set the ACL from PowerShell:

```powershell
# Inheritable ACEs on the DIRECTORY, then push them down with /reset.
$d = "$env:USERPROFILE\joggo-restore"
icacls $d /inheritance:r `
  /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F"
icacls $d /reset /T
```

⚠ **Do not add `/T` to the `/grant:r ...(OI)(CI)F` line.** `(OI)(CI)` are
*container* inheritance flags; applied directly to a file they grant nothing, and
`/T` applies them to every existing file. The result is an archive with an
**empty DACL** — unreadable by everyone including the owner, and `icacls` reports
`Successfully processed`. Found 2026-09-12: both restore points on this box had
empty DACLs, so the 2026-09-06 one had been unusable as a rollback *since the day
it was taken*, through the cutover it was supposed to cover. The failure is
silent from Windows and shows up in WSL as `tar: Cannot open: Permission denied`.

Owner can always repair it (`icacls $d /reset /T`), so the data is not lost — but
an unreadable restore point is not a restore point, which is exactly why step 1
exists. **Verify before locking down, and verify by reading the archive.**

⚠ **Do not run the capture unniced on this box.** The 2026-09-07 run went at full tilt and starved
the VM hard enough that WSL refused every new interop session for ~30 minutes
(`Wsl/Service/0x8007274c`) — while already-running containers kept serving, so Postgres still
answered on 5432 and the failure looked like a wedged distro rather than an overloaded one. The
script now wraps `tar` in `nice -n 19 ionice -c3`. If interop does start refusing, **do not
`wsl --shutdown`** (it takes the dev databases with it): confirm the distro is alive by connecting
to a service port from Windows, and wait.

**Verify it before trusting it** — extract to a temp dir and compare against live:

```bash
T=$(mktemp -d); tar -xzf "$DEST/runner-root.tar.gz" -C "$T" actions-runner/.runner actions-runner/.credentials
for f in .runner .credentials; do
  a=$(sha256sum "$T/actions-runner/$f" | cut -c1-16); b=$(sha256sum "/home/ghrunner/actions-runner/$f" | cut -c1-16)
  [ "$a" = "$b" ] && echo "$f MATCH" || echo "$f DIFFER"
done; rm -rf "$T"
```

## 2. The smoke test — `runner-smoke`

`.github/workflows/runner-smoke.yml`. `workflow_dispatch` only, builds nothing, pushes nothing,
needs no secrets, every step ends `exit 0` so it can never itself be the reason CI looks broken.
`runs-on` is the **subset** label set (`self-hosted, linux, x64`) that 10 of 12 callers use, so it
lands on whichever model is serving.

```bash
gh workflow run runner-smoke.yml --repo example-org/joggo
gh run list --repo example-org/joggo --workflow=runner-smoke.yml --limit 1
gh run view <id> --repo example-org/joggo --log | grep -aE 'host docker socket|in container|runner \.env|server '
```

Read it against this. The two models are unambiguous:

| Signal | Persistent runner (baseline) | Containerized slot | Discriminates? |
|---|---|---|---|
| `in container` | no | **yes** | ✅ |
| `host docker socket` | **PRESENT** | absent | ✅ |
| `DOCKER_HOST` | `<unset>` | `tcp://dind:2375` | ✅ |
| `docker server` | 29.1.3 (host) | 28.5.2 (dind) | ✅ |
| `uid` | `1001(ghrunner)` | `1001(runner)` | ✅ |
| `runner .env` writable | WRITABLE | **also WRITABLE** | ❌ |

⚠ **`.env` writability does NOT discriminate, and an earlier version of this table wrongly said it
did.** The slot's runner root is a *writable throwaway volume* — it has to be, because `run.sh`
rewrites `run-helper.sh` there on every loop. So a job can write `.env` on both models. The
difference is **persistence, not permission**:

```bash
# measured 2026-09-05, with a slot live
docker exec joggo-runner-1 sh -c 'echo MALICIOUS_HOOK=1 >> /home/ghrunner/actions-runner/.env'
cat /home/ghrunner/actions-runner/.env      # -> LANG=C.UTF-8   (host untouched, mtime unchanged)
```

On the persistent runner that write lands on the **host** install and runs for every future job of
every repo. On a slot it lands in a volume destroyed at the next job boundary. So test the host:
`stat -c %y /home/ghrunner/actions-runner/.env` must not move.

The baseline reading remains the standing evidence for *why* the slot exists: jobs run as the uid
that owns the install, so on the persistent runner an ordinary workflow with no special privileges
can plant that hook permanently. Permissions cannot fix it — only process isolation can.

⚠ The "workspace freshness" step measures `$GITHUB_WORKSPACE/..`, which is `_work/<repo>`, not
`_work`. It reads `count: 1` on **both** models. Ignore it or fix it to `../..`.

## 3. Cutover and rollback (containerized slot)

```bash
# CUT OVER — refuses if a job is in flight; Conflicts= stops both running at once
systemctl stop actions.runner.example-org.joggo.service && systemctl enable --now joggo-slot@1

# ROLL BACK — one command, no state to unwind
systemctl disable --now joggo-slot@1 && systemctl start actions.runner.example-org.joggo.service
```

Rollback is **proven**: after the 2026-09-05 failure it left **zero** containers, volumes and
networks (the launcher's EXIT trap covers volumes — appfour's §4.1 sketch does not), the persistent
runner was listening again in seconds, and a real smoke job went green immediately after.

Confirm recovery properly — see §5, the stale-marker trap.

## 4. Validating self-heal by fault injection

All three layers were validated only by surviving real incidents. Inject deliberately, at night,
with no job in flight. Both of these are safe and recoverable.

```bash
# A — WEDGE (layer 3). Reproduces the 2026-09-01 signature exactly: STAT=Tl, 0% CPU,
#     unit still "active", systemd blind to it.
kill -STOP $(pgrep -f 'Runner\.Listener' | head -1)
SILENCE_LIMIT=60 MIN_RESTART_INTERVAL=0 /usr/local/sbin/runner-watchdog.sh   # expect ~113s, RECOVERED

# B — CRASH (layer 2).
kill -9 $(pgrep -f 'Runner\.Listener' | head -1)     # back in ~5s, listening in ~136s

# C — WEDGE ON THE SLOT (layer 3, containerized). Forces the verdict instead of the
#     symptom: SILENCE_LIMIT=1 is the only lie told, every other input is the live box.
#     Wait for idle first — guard 2 will (correctly) refuse under a job, which proves
#     the guard but not the act path.
pgrep -f 'Runner\.Worker' && echo "job in flight — wait" || true
before=$(ls -t /var/log/joggo-slots/1/_diag/Runner_*.log | head -1)
SILENCE_LIMIT=1 /usr/local/sbin/runner-watchdog.sh   # measured 2026-09-06: RECOVERED in 46s
[ "$before" != "$(ls -t /var/log/joggo-slots/1/_diag/Runner_*.log | head -1)" ] && echo "PASS: new listener log"
rm -f /var/lib/runner-watchdog/last-restart          # don't leave a real wedge rate-limited out
```

That last `rm` matters. A successful injection writes the rate-limit stamp, so for the
next 30 minutes a **genuine** wedge would be answered with `SKIP: refusing to loop`. Clear
it, or your test has bought a half-hour blind spot.

B recovers in ~5 s, **not** the unit's `RestartSec=2min`: `ExecStart` is `runsvc.sh`, which
respawns the listener itself. Layer 2 covers `runsvc.sh` dying; the inner loop covers the listener.

🚫 **Do not inject clock drift (layer 1).** If the skew causes GitHub to delete the registration,
recovery needs a registration token — 403 without `admin:org`. The one test whose *recovery* you
cannot perform is the one test you must not run.

## 5. Verification traps — how a broken runner looks healthy

Each of these produced a false "healthy" reading on this box. They are the reason to verify with a
real job rather than by inspection.

**A live process is not a working runner.** After any restart the runner sits in
`A session for this runner already exists` / `Retrying until reconnected` for **~95 s** (measured
2026-09-05) — process up, unit active, `pgrep` satisfied, accepting no jobs. `runner-watchdog` used
to report `RECOVERED` in that window; it now waits for the runner's own `Listening for Jobs`
(`RECOVER_TIMEOUT` — 180 s persistent, 360 s slot). A *clean* `--once` exit releases the session, so
normal slot turnover does not pay this; abrupt kills do.

**A stale marker matches.** `grep -q 'Listening for Jobs' <newest log>` matches a line from *hours
ago*. Require it in a log **newer than the restart**, or count occurrences before and after. On the
slot this is easier than it sounds — every job rolls a brand-new `Runner_*.log`, so "did the
filename change" is itself the freshness test:

```bash
D=/var/log/joggo-slots/1/_diag          # slot;  persistent: /home/ghrunner/actions-runner/_diag
L=$(ls -t $D/Runner_*.log | head -1)
echo "$(basename $L) age=$(( $(date +%s) - $(stat -c %Y $L) ))s"; tail -3 "$L"   # want: Session created + Listening
```

**An idle slot looks exactly like a wedged one, and so does a paused one.** Between jobs there is
no container and no listener at all; `docker ps` shows nothing and `systemctl status` shows
`active`. Check `joggo-pause status` and the newest log's age before concluding anything is wrong —
guard 0 in the watchdog exists precisely because a 17370 s hold was recorded on 2026-09-06 and is
indistinguishable from a hang by any other signal.

**WSL interop silently expands variables to empty.** `wsl.exe -d Ubuntu -u root bash -c '...$VAR...'`
from Windows can mangle quoting, so `find $W -user root` becomes `find -user root` over the *current
Windows directory* and reports a triumphant zero. This produced a false "workspace is clean" during
the 2026-09-02 incident. **Write a script to a file and run it:**

```bash
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -u root bash /mnt/c/.../script.sh
```

**Docker commands hang.** `docker system df` and `docker volume prune` routinely exceed 120 s here.
Wrap in `timeout` and run them in the background rather than concluding the daemon is dead.

## 6. Wedge cover on the slot — closed 2026-09-06

This section used to describe a gap: the slot ran with two self-heal layers instead of three,
because `runner-watchdog` targeted the retired persistent unit and three blockers were believed to
stand in the way of porting it. Two of the three did not exist.

| Believed blocker | What was actually true |
| --- | --- |
| `_diag` is a per-job volume, so the host cannot read it | It is already a **host bind** (`/var/log/joggo-slots/N/_diag`) — moved there on 09-05 so `deploy-monitor.ps1` could see a deploy at all |
| host `pgrep` cannot see a `Runner.Worker` inside a container | It can. The containers get no separate PID view from the host, and the runner root is mounted at the **same absolute path**, so the command line matches verbatim |
| the 65-min silence threshold must be re-measured for `--once` | It is the same listener binary doing the same long poll. `--once` changes when it *exits*, not how often it *writes* while waiting |

What did need changing was the target and one timeout. `runner-watchdog.sh` now selects its
target by asking which runner is live — it prefers `joggo-slot@N` when that unit is **enabled**, not
merely active, because normal `--once` turnover makes the slot briefly inactive between every job
and a watchdog that fell back in that window would assess a unit nobody is running and pronounce
the box healthy. `RECOVER_TIMEOUT` is **360 s** for a slot against 180 s for the persistent unit,
because a slot restart pays teardown (`TimeoutStopSec=180`) *plus* a cold start.

Verified by injection C above: forced verdict on an idle slot → restart → new listener log →
`RECOVERED` in 46 s, slot active. And with a job in flight the same command correctly refuses:
`OK: a job is in flight (Runner.Worker present)`.

**The threshold is inherited, not re-measured, and that is stated deliberately.** The box has not
been idle for 50 minutes since the cutover, so the idle ceiling on a slot is untested. The
inheritance errs long, so the untested case is *acts late*, not *acts wrongly*.

**Current posture — three layers, and the boot winner is the slot.**

```
joggo-slot@1          active / enabled      <- what comes back on boot
persistent runner  inactive / disabled   <- the documented fallback, one command away
```

This is the inverse of the pre-cutover posture and it is now the correct one: the slot has wedge
cover, so failing *back* on boot would trade per-job isolation away for nothing. Never enable both
— they `Conflicts=`, and the boot winner would be nondeterministic. To fall back deliberately:

```bash
systemctl disable --now joggo-slot@1 && systemctl enable --now actions.runner.example-org.joggo.service
```
