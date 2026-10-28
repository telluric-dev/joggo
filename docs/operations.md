---
name: operations
description: >-
  Use for day-2 operations and debugging of the live self-hosted runner on this Windows+WSL2 box:
  watching jobs land, diagnosing failed runs from the slot's worker logs, jobs killed by Windows
  Update reboots and the automatic retry that covers them, the WSL2 command-quirks that bite shell
  automation, restarting WSL after config changes, and handling the dev-box/CI collisions. Operator
  skill for the joggo platform repo. Trigger on "watch the runner", "why did the job fail",
  "tail the runner log", "restart WSL", "job failed on joggo", "service container port collision",
  "runner lost communication with the server", "job died after a reboot", "could not resolve host
  github.com in CI", "is this an OOM".
---

# Operate & debug the live runner (`joggo`, Windows + WSL2)

The box is **both a dev machine and the CI runner**. Org is `example-org`; runner user `ghrunner`;
runner dir `/home/ghrunner/actions-runner`.

⚠ **Since the 2026-09-05 containerized-slot cutover, jobs do NOT run under
`actions.runner.example-org.joggo.service`.** That unit is `disabled` *by design* — finding it
inactive is not a fault, and not the reason a job is missing.

| | Unit | Per-job logs |
|---|---|---|
| **Current** — containerized slot | `joggo-slot@1.service` (`run-containerized-slot.sh`; containers `joggo-runner-1` + `joggo-dind-1`) | **`/var/log/joggo-slots/1/_diag/`** |
| Fallback — persistent runner | `actions.runner.example-org.joggo.service` (disabled) | `/home/ghrunner/actions-runner/_diag/` |

Never enable both — they `Conflicts=`. See [`docs/upgrading.md`](upgrading.md) for cutover/rollback and posture.

⚠ **`journalctl` prints LOCAL time (UTC+3, IDT); the runner's own log lines are UTC.** A job GitHub
reports at 23:43 UTC sits at **02:43** in the journal. Query the UTC figure and the window comes
back empty — which reads as "nothing happened" rather than "wrong window". Convert first:
`date -d '2026-09-08T23:43:00Z' '+%F %T'`.

## Driving the box
- **Privileged, no sudo password:** `wsl -d Ubuntu -u root bash -c '...'`. As the runner user:
  `wsl -d Ubuntu -u ghrunner bash -c '...'`.
- **WSL command quirks (these have caused real failures — avoid them):**
  - **Don't `var=$(...)` capture** through the tool boundary — it frequently comes back empty.
    Use direct pipelines (`ls -t … | head -1 | xargs grep …`) or hardcode the value.
  - **Keep it single-line** for anything with loops/`$i`/`$(…)` — multi-line scripts pick up CRLF,
    so a `for`/`if` body can mis-split (a container ID gets run as a command). Stop containers by
    **name**, not `docker stop $(docker ps -q)`.
  - **Keep absolute Linux paths inside `bash -c '...'`** — passing `/home/...` as a *direct arg* to
    `wsl.exe grep` triggers Git-Bash path mangling (`C:/Program Files/Git/home/...`).

## Watch jobs land
```bash
journalctl -u joggo-slot@1.service -f --no-pager -n 0 \
  | grep --line-buffered -E 'Running job:|completed with result:|error|Error'
```
A green pipeline is `test → build-and-push → verify-deploy`, each a separate "Running job …" line.

## Diagnose a failed job
Authoritative per-job logs are in `/var/log/joggo-slots/1/_diag/Worker_*.log` (newest = latest run):
```bash
wsl -d Ubuntu -u root bash -c 'cd /var/log/joggo-slots/1/_diag && ls -t Worker_*.log | head -1 \
  | xargs grep -nE "##\[error\]|ERR |Docker start fail|Process completed with exit code|self-installer"'
```
On the slot every job rolls a **new** `Worker_*.log`, so "did the newest filename change" is itself
a freshness test. If the newest file is days old, jobs are not reaching this unit at all — check
`systemctl is-enabled joggo-slot@1` before reading anything into the log's contents.
Read the surrounding lines with `sed -n "<start>,<end>p"` (via the same `ls … | xargs sed` pattern).
To get a step's real stderr, **reproduce it** as `ghrunner` using the runner's bundled node and the
checked-out repo at `~/actions-runner/_work/<repo>/<repo>` (set `GITHUB_WORKSPACE`, the action inputs
as `INPUT_*`, etc.).

## Failure classes seen here
- **`Docker start fail` on a service container** → host **port collision**. The shared box runs dev
  DBs (`handsfree-clinic-postgres` on 5432, `appsix-pg` on 5433). Check `ss -ltnp | grep :5432` and
  `docker ps`. **Do not remove the user's dev DBs.** `docker stop <name>` (reversible) only with
  consent; the durable fix is the client repo adopting `node-test.yml` (no host port). See the
  client **containerized-tests** skill.
- **`pnpm/action-setup` "self-installer exits with code 1" / missing `node`** → Windows-PATH leak +
  no clean Linux node. Fix on the runner: `appendWindowsPath=false`, clean `.path`, install Node LTS
  (see [`runner-setup.md`](runner-setup.md) §2). Verify a job's PATH: `node -v; pnpm -v` resolve under `/usr/bin`.
- **A Windows Update reboot ate the job.** This box still takes unattended update reboots, and they
  are *not* rare — 2026-09-09 took **three** in six minutes (02:29→02:35 IDT). One reboot produces
  two different-looking failures, and neither mentions rebooting:
  - the **in-flight** job dies with the annotation *"The self-hosted runner lost communication with
    the server"* (seen on `appthree#34279403976`, killed 2h25m into a Build step);
  - the job GitHub **re-dispatches straight afterwards** fails too, because WSL2's network stack has
    not settled — Docker's embedded resolver cannot reach its upstreams, so checkout reports
    `Could not resolve host: github.com` and corepack times out on the npm registry
    (`appone#34279623096`, 8 min after the VM came back).

  Confirm rather than guess — the reboot is unambiguous in the event log and the boot table:
  ```powershell
  Get-WinEvent -FilterHashtable @{LogName='System';Id=1074,109} -MaxEvents 10 |
    Select-Object TimeCreated, Message      # 1074 names the process that forced it
  ```
  ```bash
  wsl -d Ubuntu -u root journalctl --list-boots --no-pager | tail -4   # short boots = update chain
  ```
  Neither is an OOM — check before assuming one: `journalctl -k | grep -i "Out of memory"` and
  `docker inspect --format '{{.State.OOMKilled}}' <container>` were both clean in that incident.
  **Retrying is handled automatically** — see below. The durable fix is Windows Update policy
  (active hours / `NoAutoRebootWithLoggedOnUsers`), which is a host decision, not a runner one.

## Automatic retry after a reboot
`joggo-rerun-after-reboot.service` (oneshot, enabled, ordered after `joggo-slot@1`) re-runs jobs this box
lost to a reboot, so neither failure class above needs a human.

```bash
/usr/local/sbin/joggo-rerun-after-reboot.sh --once --dry-run       # what it would do, changes nothing
tail -20 /var/log/joggo-rerun.log                                  # what it has done
```
- **Window** — previous boot's end (from `journalctl --list-boots -o json`) through boot + 35 min.
  It *polls* across that window rather than checking once, because the post-reboot failure lands
  several minutes after boot; a one-shot check at boot is too early to see it.
- **Scope** — a run qualifies only if one of its **failed** jobs reports `runner_name: joggo`.
  Match on the runner *name*, not the label set: 10 of the 12 callers use the subset labels
  (`self-hosted, linux, x64`) with no `joggo` in them. Repo list: `/etc/joggo-rerun/repos`, kept in
  step with the `-Repos` default in `monitor/day-report.ps1`.
- **Rails** — one retry per run ever (`/var/lib/joggo-rerun/state.json`, survives reboots), skips runs
  already at attempt ≥3, caps at 10 per pass, never fails the boot transaction.
- **Auth** — the Windows `gh.exe` over WSL interop, already signed in via the Windows keyring, so
  **no PAT is stored on the box**. Verified to work from inside a systemd unit, not just an
  interactive shell. Falls back to `/etc/joggo-rerun/token`.
- ⚠ **Editing it:** any `gh`/`curl` call inside a `while read` loop needs `</dev/null`, or the
  client drains the loop's stdin and the pass silently processes one repo and one run.

## The CI day report (what failed, and why)
`monitor/day-report.ps1` renders every job that finished today to
`~/.claude/joggo-day/joggo-day.html` — successes as one row, failures as a card with the failed job, the
error lines from the run log, and a root-cause note if one exists. Root-cause prose lives in
`~/.claude/joggo-day/notes.json`, keyed by run id.

`day-report.timer` refreshes it **hourly** (oneshot service driving Windows `powershell.exe` over
interop; `Persistent=true` so it catches up after the box was off). The page empties itself when the
UTC date rolls — the CI day is 03:00→03:00 local — so there is no end-of-day render to schedule.

```bash
systemctl list-timers day-report.timer --no-pager    # next run
systemctl start day-report.service                   # render now (~45 s)
```
`joggo-rerun-after-reboot` **writes its own note** for every run it retries, because the reboot class is
the one diagnosis a script can make with confidence — the same code that decided the run was
reboot-caused records why. Everything else still wants a human:

```bash
pwsh monitor/day-report.ps1 -Note <run-id> -Text "<what actually broke>"
```
⚠ `notes.json` is written by Windows PowerShell 5.1 as **UTF-8 with BOM**. `ConvertFrom-Json` copes;
`json.load` in Python does not — read it with `encoding='utf-8-sig'`.

We deliberately do **not** open GitHub issues for CI failures. The report already carries unresolved
failures forward for 14 days, and this is a single-operator box, so issues would duplicate the
tracking while adding noise across 12 repos.

## Restart WSL after config changes (`/etc/wsl.conf`, `.path`)
```powershell
wsl --shutdown
Start-ScheduledTask -TaskName 'WSL2-keepalive'   # reboots the distro headless + holds the VM up
```
Then verify services come back (`docker` may lag a few seconds — `systemctl start docker` if needed),
the runner shows **Listening for Jobs**, `$PATH` has zero `/mnt/c`, and — only if you run Tailscale
— that it is back online.

## Guardrails
- Never delete/overwrite the user's running dev containers, databases, or data without asking; prefer
  `stop` over `rm` and say how to restart (`docker start <name>`).
- The reusable workflows' `uses: example-org/joggo/...@main` only resolve once this repo is
  pushed to the `example-org` org on GitHub.
- Before **changing** the runner (cutover, version upgrade, self-heal edits, WSL config), use the
  [`docs/upgrading.md`](upgrading.md) skill: restore point → baseline `runner-smoke` → change → smoke → keep or
  roll back. It also lists the verification traps that make a broken runner read as healthy.
