# Quickstart — nothing to a green build

**Target: Windows 10 2004+ or Windows 11 with WSL2.** That is the only supported configuration;
there is no native-Linux or VM path. Run the commands below in PowerShell on the Windows host,
**elevated if you can**:

| | Elevated | Not elevated |
|---|---|---|
| Runner slots, Docker, watchdog, monitor | yes | yes |
| Keepalive (holds the WSL distro up) | SYSTEM, at startup: works with nobody logged on | as you, at logon: works while you are logged in |
| Memory guard + 5-minute sampler | yes | no (pass `-NoGuard -NoSampler`, or the installer stops and says why) |

Without some keepalive WSL powers the distro off about 30 seconds after the installer exits,
and the runner goes with it — so there always is one; elevation decides which.

You need: virtualization enabled in firmware, 8 GB RAM (16 GB if you want two slots — see
[How many slots](adding-a-slot.md#how-many-slots)), 30 GB free on the drive your WSL distro
lives on, and a GitHub registration token. Tailscale is **not** required.

## 1. Check the box before changing it

```powershell
git clone https://github.com/<owner>/joggo.git; cd joggo
./install.ps1 -PreflightOnly
```

Exit `0` means nothing blocks; `3` means something does, and each failing line names the fix. It
changes nothing either way. Fix the `[FAIL]` lines before going on; `[WARN]` lines are survivable
and tell you what you are accepting.

## 2. Get a registration token

Short-lived (~1 hour), never commit or store it. The installer keeps it in memory only.

- **Organisation:** `https://github.com/organizations/<org>/settings/actions/runners/new`
- **Personal account / one repo:** `https://github.com/<owner>/<repo>/settings/actions/runners/new`

Either paste it at the wizard's prompt, which reads without echo, or put it in `JOGGO_TOKEN` for
the one-line form. It is never written to the config, a log, or a transcript.

## 3. Install

```powershell
./install.ps1 -Wizard        # a human: it asks, shows the config, then runs

# an agent, personal account, one repository:
./install.ps1 -NonInteractive -Json -Yes -Scope repo -Repo me/my-app -Token $env:JOGGO_TOKEN -Slots 1

# an agent, organisation:
./install.ps1 -NonInteractive -Json -Yes -Scope org -Org example-org -Token $env:JOGGO_TOKEN
```

`-Scope repo` is a first-class path, not a workaround. Runner groups are an organisation-only
feature, so a personal account registers the runner **per repository** — and that registered list
*is* your security boundary, the role the group plays on an org.

`-DryRun` prints every step's intent and changes nothing. Re-running converges rather than
duplicating: each step detects "already done" and says so. Step `10-wsl-feature` may need a reboot;
it says so and tells you how to resume. Exit codes: `0` success, `1` blocking failure, `2` bad
usage, `3` preflight failed.

Defaults worth knowing: `-Slots` defaults to what fits the WSL VM's memory cap (~3 GB a slot on
a 1 GB base) and stops at 2 — see [How many slots](adding-a-slot.md#how-many-slots); the
memory guard's thresholds scale too (warn 15% of RAM, critical 7.5% — 2500 and 1200 MB on the
16 GB box they were measured on), the WPF monitor is off, and `-Tailscale` is off.

## 4. Prove it with a real build

`99-verify` ends by printing the workflow to paste into the repo you just allowed:

```yaml
# .github/workflows/ci.yml
name: CI
on: { push: { branches: [main] }, workflow_dispatch: {} }
jobs:
  build:
    uses: <owner>/joggo/.github/workflows/build-and-push.yml@main
    with: { image-name: my-service, context: ., dockerfile: ./Dockerfile }
    permissions: { contents: read, packages: write }   # packages: write is REQUIRED for GHCR
```

Push it. The job should land on the runner and go green with zero GitHub-hosted minutes billed.
**An install that has not produced a green build is not finished.**

## Before you point anything else at it

A self-hosted runner executes whatever the allowed repositories tell it to, on your hardware,
inside your network. **Never allow a public repository, and never allow fork PRs from outside
collaborators.** Read [`../SECURITY.md`](../SECURITY.md) before the second repository, not after.

One cost to know up front: each job rebuilds its container — measured **83–108 seconds** — and
GitHub's runner-acquisition timeout races that at *every* job boundary, so an 11-job workflow gets
eleven chances to die with *"not acquired by Runner of type self-hosted"*. On one repository that
killed ~11% of jobs. [`runner-setup.md`](runner-setup.md) §6.5 has the trade-off in full.

## Next

[`runner-setup.md`](runner-setup.md) to understand or deviate from any step ·
[`onboarding-a-repo.md`](onboarding-a-repo.md) to point more repos at it ·
[`operations.md`](operations.md) day to day · [`recovery.md`](recovery.md) when it stops taking
jobs, which opens with a triage table because the failure modes have opposite fixes ·
[`memory-pressure.md`](memory-pressure.md) for why the guard exists ·
[`adding-a-slot.md`](adding-a-slot.md) to add a slot by hand.
