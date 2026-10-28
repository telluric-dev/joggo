---
name: restore-runner-after-clock-mismatch
description: >-
  Use when the joggo runner is not taking jobs and it is NOT a GitHub outage — either the
  clock-drift incident (OAuth "token expired" with a large local-vs-server time gap, "runner
  registration has been deleted from the server") or a WEDGED listener (service active, process
  alive at 0% CPU, log silent, jobs queued forever). Covers telling the two apart, the log
  signatures, re-registering with --replace, restarting a wedge, and the three self-heal layers.
  Operator skill for the joggo platform repo. Trigger on "token expired", "clock drift",
  "clock mismatch", "registration deleted", "runner dead after power outage", "re-register the
  runner", "jobs stuck but runner looks fine", "runner idle but not picking up jobs", "wedged
  listener", "hanging jobs".
---

# Runner alive-but-not-working: triage and repair

⚠ **Post-cutover unit names.** Since 2026-09-05 the serving unit is **`joggo-slot@1.service`** with
logs in **`/var/log/joggo-slots/1/_diag/`**; `actions.runner.example-org.joggo.service` is `disabled`
by design and its `_diag` is frozen at the cutover date. The commands below name the slot; the
persistent paths remain valid only if you have deliberately rolled back ([`docs/upgrading.md`](upgrading.md) §3).

⚠ **A fourth cause now has its own coverage: the box rebooted.** Windows Update reboots kill
in-flight jobs (annotation *"The self-hosted runner lost communication with the server"*) and break
the job re-dispatched right after. That is **not** any of A/B/C below — the runner is fine by the
time you look — and it is retried automatically by `joggo-rerun-after-reboot.service`. Check
`journalctl --list-boots | tail -4` and `/var/log/joggo-rerun.log` before triaging further. See
[`docs/operations.md`](operations.md).

⚠ **A fifth cause: the box was HARD RESET** (power button, or a freeze the operator reset out of).
This is not A/B/C and not a Windows Update reboot — it leaves **two** faults at once, and fixing
only the first leaves the box down:

1. **The clock comes back off CMOS.** If `w32time` is not syncing (`w32tm /query /status` showing
   `Source: Local CMOS Clock` / `not synchronized`), the host is wrong and **WSL follows it**.
   chrony inside WSL cannot win — it steps the clock and the hypervisor puts it straight back —
   so layer 1 looks healthy (sources reachable, microsecond offsets) while
   `chronyc tracking` still reports seconds of skew. The slot's preflight guard then refuses to
   start, correctly. Fix on the HOST, elevated: `w32tm /config /update; Restart-Service W32Time;
   w32tm /resync /force`. WSL follows within a poll.
2. **Every docker object the slot owns survives.** `cleanup()` runs from an EXIT trap, and a hard
   reset SIGKILLs it, so `joggo-slot-N`, `joggo-dind-N` and `joggo-runner-N` are all still there. Since
   2026-09-19 `reclaim_stale()` clears them automatically at startup; on any box still running an
   older script, `docker network rm joggo-slot-1` and `docker rm -f joggo-dind-1 joggo-runner-1` by hand.

Measured 2026-09-19: the reset happened at 15:44, the clock fault blocked the slot, and after the
clock was fixed the slot *still* could not start for 80 minutes because of the leftover network —
with six jobs queued. **Fix the clock first, then confirm the slot actually starts; do not assume
the clock fix was the whole job.** `joggo-rerun-after-reboot` fires but retries nothing useful here,
because it polls a runner that cannot start.

Three further faults produce the identical symptom — **jobs queued forever, nothing running**.
Do not guess; they have opposite fixes, and applying the wrong one makes things worse.

| | Clock drift (A) | Wedged listener (B) | Actions outage (C) |
|---|---|---|---|
| `systemctl is-active` | **inactive/dead** | **active** | active |
| Listener process | gone | **alive, 0% CPU, `futex_wait_queue`** | alive, busy |
| Log signature | `token expired` + `registration has been deleted` | **silent > 65 min**, no errors after the last entry | `acquirejob` **503/502** retries |
| githubstatus | operational | operational | **Actions degraded** |
| Fix | re-register (§2) | **restart the service** (§3) | do NOT restart — `deploy-during-outage` |

The "never restart the runner" rule belongs to **C only**. In B, restarting is exactly right.

⚠ **Row 1 does not transfer to the slot.** `--once` turnover makes `joggo-slot@1` genuinely
`inactive` between every job, so "inactive" no longer means "dead" — read **`is-enabled`**
(should be `enabled`/`indirect`) and the age of the newest `Runner_*.log` instead. A paused slot
(`joggo-pause status`) looks the same again. Treating a normal idle slot as failure A and
re-registering it would be an unforced outage.

```bash
# one-shot triage
wsl -d Ubuntu -u root bash -c 'systemctl is-active joggo-slot@1.service; systemctl is-enabled joggo-slot@1.service; ps -eo pid,etime,%cpu,wchan:20,cmd | grep -a "[R]unner\."'
wsl -d Ubuntu -u root bash -c 'ls -t /var/log/joggo-slots/1/_diag/Runner_*.log | head -1 | xargs tail -25'
curl -s https://www.githubstatus.com/api/v2/summary.json | python -c "import json,sys;d=json.load(sys.stdin);print(d['status']['description'])"
```

## 1. Confirm the queue from GitHub's side

Counts the jobs the user is actually staring at, and tells you which repos are affected:

```bash
for r in $(gh api "/orgs/example-org/repos?per_page=100" --jq '.[].name'); do
  n=$(gh api "/repos/example-org/$r/actions/runs?status=queued&per_page=20" --jq '.workflow_runs|length' 2>/dev/null)
  [ "${n:-0}" != "0" ] && echo "== $r: $n queued"
done
```

## 2. Failure A — clock drift killed the registration

Seen 2026-08-29 (and once before, after a power outage). The WSL2 VM clock freezes while the host
sleeps or loses power, resumes hours behind, every OAuth token looks expired, and GitHub
eventually deletes the registration:

```
ERR ...] VssOAuthTokenRequestException: The token expired on 08/29 04:10:59.
         Current server time is 08/29 06:31:18.        <-- hours of skew
ERR ...] Failed to create a session. The runner registration has been deleted
         from the server, please re-configure.
```

Registration is gone server-side, so a restart does nothing. Re-register:

1. **Mint a fresh registration token** (org admin; expires in ~1 hour — never store one):
   https://github.com/organizations/example-org/settings/actions/runners/new
   Trying to *remove* the old runner in the UI hands you a token too — it works for both.
2. **Clear stale local config.** The server-side remove fails; the fallback still deletes
   `.credentials`/`.runner`, which is all that matters — the systemd unit stays installed:
   ```bash
   wsl -d Ubuntu -u ghrunner bash -c 'cd /home/ghrunner/actions-runner && ./config.sh remove --token <TOKEN> || ./config.sh remove --local'
   ```
3. **Re-register — `--replace` is required.** A ghost `joggo` entry usually still exists
   server-side ("A runner exists with the same name"):
   ```bash
   wsl -d Ubuntu -u ghrunner bash -c 'cd /home/ghrunner/actions-runner && ./config.sh --url https://github.com/example-org --token <TOKEN> --name joggo --labels self-hosted,linux,x64,joggo --unattended --replace'
   ```
4. **Start and verify** — want `Listening for Jobs`. Re-registering writes `.runner`/`.credentials`
   in the shared runner root, which the **slot** also uses, so start the slot, not the retired unit:
   ```bash
   wsl -d Ubuntu -u root bash -c 'systemctl start joggo-slot@1.service && journalctl -u joggo-slot@1.service -n5 --no-pager'
   ```

## 3. Failure B — wedged listener (hung, but alive)

Seen 2026-09-01: 7 jobs queued across `appthree` and `appthree` while the service sat
`active` and looked perfect. The listener had been alive 1d20h at **0.0% CPU**, blocked in
`futex_wait_queue`, still holding one ESTABLISHED socket to the broker.

What happened, from the log: the broker's TLS connection died mid-read, then the listener hung
**inside its ~50-minute OAuth token refresh** on that already-dead socket and never logged again.

```
[12:44:22Z ERR  BrokerServer] SocketException (125): Operation canceled
[12:44:22Z WARN BrokerServer] Back off 10.692 seconds before next retry. 4 attempt left.
[13:16:12Z INFO RSAFileKeyManager] Loading RSA key parameters from file ...
[13:16:13Z INFO GitHubActionsService] AAD Correlation ID for this token request: Unknown
                                       <-- nothing, ever again
```

**Fix: restart the service.** Check no job is in flight first, then restart — it reconnects in
~3s and queued jobs land immediately:

```bash
wsl -d Ubuntu -u root bash -c 'ps -eo cmd | grep -a "[R]unner.Worker" || echo "no job in flight - safe"'
wsl -d Ubuntu -u root bash -c 'systemctl restart joggo-slot@1.service'
```
(Host `pgrep`/`ps` sees a `Runner.Worker` **inside** the slot container — same PID namespace, same
absolute runner path — so the in-flight check works unchanged. See [`docs/upgrading.md`](upgrading.md) §6.)

## 4. Self-heal layers (verify these are still in place)

```bash
wsl -d Ubuntu -u root bash -c 'grep ^makestep /etc/chrony/chrony.conf; systemctl show joggo-slot@1.service -p Restart,RestartUSec; systemctl list-timers runner-watchdog.timer --no-pager; /usr/local/sbin/runner-watchdog.sh --check'
```
`runner-watchdog.sh --check` reports its own target — expect `target=joggo-slot@1.service
diag=/var/log/joggo-slots/1/_diag`. If it still names the persistent unit, layer 3 is guarding
something nobody is running.

- **Host clock (the gap layer 1 cannot close).** chrony only owns the GUEST clock, and on WSL2 the
  guest is slaved to Windows — so when the HOST is wrong, `makestep` is powerless no matter how it
  is tuned. Nothing on this box can fix that automatically: setting Windows time needs elevation,
  and an admin-capable agent on the CI box is the thing [`runner-setup.md`](runner-setup.md) §6 exists to prevent. What
  IS automated is *detection*: the slot guard names the host and prints the `w32tm` fix, and
  deploy-monitor's fail-reason reports "Runner is REFUSING to start: clock off NTP" with the same
  command instead of leaving the card blank. Check the host's own health periodically:
  `w32tm /query /status` should show a stratum of 2-3 and a real Last Successful Sync Time;
  `Source: Local CMOS Clock` means it has never synced and the next reset will do this again.
- **Unclean shutdown (installed 2026-09-19).** `reclaim_stale()` in run-containerized-slot.sh
  removes the slot's own leftover containers and network before creating anything, so a hard reset
  no longer needs a human with `docker rm`. It refuses, deliberately, when a container is RUNNING
  or the network has something attached — that is a live second instance, not debris.
- **Clock (installed 2026-08-30).** Ubuntu's default `makestep 1 3` only *steps* the clock in the
  first 3 updates after boot; a multi-hour offset appearing later is slewed at minutes-per-day —
  effectively never. `/etc/chrony/chrony.conf` now has `makestep 1 -1` (step any offset over 1s,
  always), so a future freeze corrects within one poll instead of killing the registration.
- **Crash (installed 2026-08-30).** GitHub's unit ships no `Restart=`. Override at
  `/etc/systemd/system/actions.runner.example-org.joggo.service.d/override.conf`:
  `Restart=always`, `RestartSec=120`.
- **Wedge (installed 2026-09-01).** `Restart=always` cannot fire for a process that never exits,
  which is exactly why layer 2 did not catch failure B. `watchdog/runner-watchdog.sh` +
  `runner-watchdog.timer` (every 5 min) close it: restart only when the unit is active, **no
  `Runner.Worker` is running**, the newest `Runner_*.log` has been silent over 65 min, and no
  watchdog restart happened in the last 30 min. Run it by hand with `--check` — it reports state
  and never acts.

### Why the threshold is 65 minutes — do not lower it

A healthy **idle** listener is legitimately silent for long stretches: it refreshes its OAuth
token every ~50 minutes and logs only

```
INFO RSAFileKeyManager] Loading RSA key parameters from file ...
INFO GitHubActionsService] AAD Correlation ID for this token request: ...
```

Measured over 2 days / 5422 log lines on this box, the **longest healthy gap was 3021s (50.35
min)** — and the observed wedge was a 49-minute silence, i.e. *indistinguishable from healthy* at
any shorter threshold. 65 min leaves ~15 min of margin. A 20–30 min threshold would restart the
runner constantly. False positives are tolerable only because the worker guard means a restart
never lands on a running job.

## 5. Remaining gap — a deleted registration still needs a human

If GitHub deletes the registration (failure A) before the clock recovers, the restart loop
reconnects the listener but session creation keeps failing: someone must mint a token (§2).
Automating that needs an org-admin PAT on the box, which contradicts the hardening rule "no
privileged secrets on the CI box" ([`runner-setup.md`](runner-setup.md) §6). With layers 1 and 3 the window for GitHub
to delete a registration is minutes rather than days, so the trade-off is deliberately unresolved.
If it recurs anyway, a fine-grained PAT scoped to *only* org self-hosted runners is the least-bad
shape.

## 6. Gotcha: Git Bash mangles paths passed to `wsl.exe`

Debugging any of this from the Windows Bash tool, MSYS path conversion silently rewrites
POSIX-looking arguments: `DIAG=/tmp/wd-test` arrived inside WSL as
`DIAG=C:/Users/you/AppData/Local/Temp/wd-test`, and a bare `T=/tmp/x` assignment came through
empty — so tests appear to pass while actually running against the wrong path. Also, `$?` read
*inside* a `wsl ... bash -c '...'` string is unreliable; read the exit code from the outer shell.

```bash
export MSYS_NO_PATHCONV=1     # before any wsl.exe call that carries a linux path
wsl -d Ubuntu -u root bash -c '...'; echo "rc=$?"   # rc from the OUTER shell
```

## 7. Slots "active" but offline, and the runner log says `Resource temporarily unavailable`

Every WSL2 distro on a machine shares **one network stack**: one kernel, one route table, one
set of iptables chains. So two things in different distros that each create Docker networks can
collide, and a collision does not look like an error. The slot starts, its container runs, it
never comes online, and the runner's own log shows DNS failing:

```
System.Net.Sockets.SocketException (11): Resource temporarily unavailable
```

Check from inside the distro, and look for **two** routes for one slot subnet:

```bash
ip -4 route | grep '10\.211\.'          # one line per slot is right; two for the same /24 is the fault
```

The launcher refuses to *create* a network on a subnet something else already routes, and says
so in `journalctl -u joggo-slot@1`. If you are running joggo next to another runner or Docker
daemon in the same WSL VM, move joggo's range:

```bash
echo 'SLOT_NET_BASE=10.212' | sudo tee /etc/default/joggo-slot
sudo systemctl restart 'joggo-slot@*'
```

Found on the first real install: joggo inherited a hardcoded `10.201.<slot>` from the runner it
was extracted from, and installed next to that runner both had a bridge on each subnet.

**A different cause with the same symptom:** containers on Docker's default network cannot
reach WSL's tunnelled DNS (`nameserver 10.255.255.254` in `/etc/resolv.conf`). The installer
writes `/etc/docker/daemon.json` `"dns"` for that case (step 40); if you installed Docker by
hand, check that file first.
