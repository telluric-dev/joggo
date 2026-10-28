# joggo install — the contract

This file is the authoritative interface between the installer's parts. Anything
building one part reads this and builds to it, rather than negotiating with the
others. **WSL2 on Windows is the only supported target.** There is no native-Ubuntu
or VM path; do not add one, and remove references to one where they survive.

## Design rules

1. **Fail fast, with an action item.** Never a bare "failed". Every failure names what
   is wrong, what the user must do, and — where possible — the exact command.
2. **Preflight checks everything the WHOLE run needs, before changing anything.** A
   user must never get halfway and discover virtualization is off in the BIOS. If a
   later step needs a thing, preflight checks that thing.
3. **Idempotent.** Re-running must converge, not duplicate. Every step detects "already
   done" and says so.
4. **Two front doors, one engine.** A human gets a wizard; an agent gets flags. Both
   produce the same config object and run the same steps.
5. **Nothing silent.** Each step prints what it is about to do and what happened. A
   destructive action asks first unless `-Yes`.
6. **Honest exits.** `0` success, `1` blocking failure, `2` bad usage, `3` preflight
   failed. Never exit 0 on a failure — this repo's own docs are full of what that costs.

## Layout

```
install.ps1                   entry point: wizard, flags, or -PreflightOnly
install/CONTRACT.md           this file
install/preflight.ps1         every check; writes a report; exits 0 or 3
install/config.ps1            schema, RAM-scaled defaults, flag parse, wizard prompts
install/steps/*.ps1           ordered idempotent steps, one concern each
install/inside-wsl.sh         the Linux half, invoked with the config as JSON on stdin
install/joggo.config.example.json
uninstall.ps1                 reverses everything the installer created
```

## Config schema

Written to `%ProgramData%\joggo\joggo.config.json` by the installer and read by every
step. One object, flat, no nesting.

| Key | Type | Default | Notes |
|---|---|---|---|
| `scope` | `"org"` \| `"repo"` | asked | `repo` is the personal-account path |
| `org` | string | — | required when `scope=org` |
| `repo` | `owner/name` | — | required when `scope=repo` |
| `runnerName` | string | `joggo` | |
| `labels` | string | `self-hosted,linux,x64,joggo` | |
| `slots` | int | 1 if <12 GB RAM, otherwise 2. **Never more than 2 by default.** | see below |
| `filterAaaa` | bool | `false` | install `network/filter-aaaa.conf`; offer it when preflight warns |
| `distro` | string | `Ubuntu-24.04` | |
| `runnerUser` | string | `ghrunner` | |
| `guard` | bool | `true` | the memory guard |
| `guardWarnMB` | int | `round(RAM_MB * 0.15)` | 2500 on a 16 GB box, which is where it was measured |
| `guardCriticalMB` | int | `round(RAM_MB * 0.075)` | 1200 on 16 GB |
| `guardIntervalMin` | int | `5` | |
| `sampler` | bool | `true` | mem-watch.ps1, the 5-minute trail |
| `watchdog` | bool | `true` | the wedge detector |
| `monitor` | bool | `false` | the WPF monitor; off by default, it is a desktop app |
| `startOnBoot` | bool | `true` | keepalive task + enabled units. Runs as the installing user at logon (SYSTEM cannot see a user's WSL distro) |
| `dockerDns` | string | `''` | comma-separated container DNS servers. Empty = the Windows adapters that are up, then 1.1.1.1/8.8.8.8; each is queried before use, and only applied when WSL tunnels DNS and daemon.json sets none |
| `tailscale` | bool | `false` | OPTIONAL. Only for remote management. |
| `registrationToken` | string | — | never written to the config file; held in memory only |

### On `slots`, and why the default stops at 2

An earlier draft of this contract said "3 if >32 GB". **That was an unmeasured claim and
it is withdrawn.** Nothing in this repo has ever run more than two slots, and
`docs/adding-a-slot.md` is explicit that the second slot is only *"mostly free"* and that
this workload is IO-bound rather than RAM-bound — so RAM is the wrong axis to scale on
past two, and a tier table implying otherwise invents evidence.

So: **1 slot under 12 GB, 2 otherwise, and never more by default.** `-Slots 3` and above
must work, because somebody with a big box should be able to try it, but the installer
must print one line saying the configuration is untested here and that the limit is
likely disk throughput, not memory. Caught by the docs agent, which was right.

### On `filterAaaa`

Preflight warns when DNS returns AAAA records that do not route, because that makes
build-time fetches and `docker login ghcr.io` hang rather than fail — it cost this box a
stalled production pin. But nothing installed the fix, so the warning had no remedy
attached. Step `45-dns-aaaa` installs `network/filter-aaaa.conf` when `filterAaaa` is
true. Keep it **opt-in**: it changes name resolution inside the distro, and that is not a
thing to do to someone silently. When preflight raises the warning it should name the
flag.

**The registration token must never be persisted.** Not in the config, not in a log,
not in a transcript. Accept it via `-Token`, an env var, or a wizard prompt that reads
without echo, and keep it in memory. `SECURITY.md` is the reason.

## Flags on `install.ps1`

Every config key above is a flag in PascalCase: `-Scope`, `-Org`, `-Repo`,
`-RunnerName`, `-Labels`, `-Slots`, `-Guard`/`-NoGuard`, `-GuardWarnMB`,
`-Watchdog`/`-NoWatchdog`, `-Monitor`, `-StartOnBoot`/`-NoStartOnBoot`,
`-Tailscale`, `-Token`.

Plus:

```
-Wizard            interactive. The default when no scope-determining flag is given.
-NonInteractive    never prompt; fail with exit 2 if something required is missing.
-PreflightOnly     run preflight, report, exit. Changes nothing.
-Json              machine-readable output on stdout; human text to stderr. For agents.
-DryRun            print every step's intent, change nothing.
-Yes               assume yes for confirmations.
-ConfigFile <p>    load config from JSON; flags override it.
```

An agent-run install must be a single line, e.g.:

```powershell
./install.ps1 -NonInteractive -Json -Yes -Scope repo -Repo me/my-app -Token $env:JOGGO_TOKEN -Slots 2
```

## Preflight contract

`install/preflight.ps1` emits one line per check and a summary. Exit `0` if nothing
blocks, `3` if anything does. With `-Json`, print a single JSON object:

```json
{ "ok": false,
  "checks": [ { "id": "wsl2", "status": "pass|warn|fail", "detail": "...", "action": "..." } ],
  "blocking": 1, "warnings": 2 }
```

Human form, which is what most people will see:

```
[PASS] Windows 11 build 26200 — WSL2 supported
[FAIL] Virtualization is disabled in firmware
       -> Reboot into UEFI and enable Intel VT-x / AMD-V, then re-run.
[WARN] 9.8 GB RAM detected — guard thresholds will scale, 1 slot recommended
```

**Checks it must make**, because every one of these has actually bitten on the box this
came from, or is needed by a later step:

*Host* — Windows 10 2004+ / 11; x86-64; admin rights; virtualization enabled in
firmware; Hyper-V/WSL optional features available; ≥8 GB RAM (warn under 12); ≥40 GB
free on the system drive; power plan will not sleep (fail with the exact `powercfg`
command if it will).

**DISK — the blocking check is the VHDX drive, not the system drive.** An earlier draft
said "≥40 GB free on the system drive" and that was wrong: the distro's disk lives
wherever WSL put it, which is not necessarily `C:`. On the box this came from, `C:` has
22.5 GB free while the VHDX sits on `D:` with 1.7 TB — so a system-drive check **fails a
machine with ample room**, and would **pass** one with a roomy `C:` and a full `D:`. Read
`BasePath` from `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss` and check that
drive for ≥40 GB. The system drive stays advisory (≥5 GB, for logs and task state).
Caught by the preflight agent against this machine, which its own check failed.

*WSL* — `wsl.exe` present; WSL **2**; a usable distro installed or installable;
`systemd=true` reachable in that distro (this is a hard requirement — `svc.sh`,
`systemctl`, docker and the slot units all depend on it); the distro is not
`docker-desktop`.

*Conflicts* — Docker **Desktop** not running and not providing the docker socket inside
the distro (this repo needs Docker Engine native in the distro, and the two fight).

*Network* — `api.github.com`, `github.com`, `ghcr.io` reachable over HTTPS; a warning if
DNS returns AAAA records that do not route, since that silently hangs build-time
fetches and registry logins (`network/filter-aaaa.conf` is the fix, and preflight
should say so).

*GitHub* — a registration token or `gh` CLI authenticated; resolve the account TYPE rather than warning
blindly, because an unconditional warning fires on every correct org install:
Organization -> PASS (name runner groups as the boundary), User -> WARN with the
`-Scope repo` path, undetermined -> WARN "could not determine"; never print the token.

*Tools* — `curl`, `tar` inside the distro; `pwsh` or `powershell` for the scheduled
tasks; `gh` only if the user asked for the CLI path.

*Disk inside the distro* — ≥20 GB free, and inodes, because they exhaust separately and
read as "disk full" only if you look. NOTE: btrfs, xfs and overlay report 0
or "-" for inode totals. That is "nothing to exhaust", not "nothing free", and not a
pass either -- report WARN "not reportable on this fs".

## Steps

Ordered, idempotent, each a file under `install/steps/`, each printing
`== N/M <name> ==` then what it did or why it was already done.

```
10-wsl-feature        enable WSL + VM Platform features if absent (may need a reboot:
                      detect, say so clearly, and exit with a resume instruction)
20-distro             install/confirm the distro; set systemd=true; restart it
30-runner-user        create the unprivileged runner user
40-docker             Docker Engine native inside the distro; enable + start
45-dns-aaaa           OPT-IN (filterAaaa): install network/filter-aaaa.conf so
                      unroutable AAAA records fail fast instead of hanging
50-dind-image         build the per-slot Docker-in-Docker image
60-runner             download the runner, register it, install the service
70-slots              install the launcher + joggo-slot@ template; create N slots
80-guard              install guard + sampler, register the scheduled tasks
                      (THIS IS THE GAP THE REPO HAS TODAY — nothing registers them)
90-watchdog           install runner-watchdog + its systemd timer
95-boot               keepalive task; enable units; verify everything is up
99-verify             prove it: runner Idle/online, slots LIVE, guard task scheduled,
                      and print the exact next action — the workflow YAML to paste
```

`99-verify` must end by telling the user what to do next, with the snippet to paste into
a consuming repo. An install that finishes without a green build is not finished.

## Uninstall

`uninstall.ps1` reverses the above in reverse order: deregisters the runner (needs a
fresh token; say so), removes the scheduled tasks, disables and removes the units,
removes the dind image and the slot volumes, and leaves the distro and Docker alone
unless `-Deep`. It must list what it will do and ask, unless `-Yes`.

## Tone

Terse, specific, no cheerleading. The reader is trying to get work done. Where a step
encodes something learned the hard way, one line of why is worth more than three of
reassurance — that is the existing style in this repo and it should survive.
