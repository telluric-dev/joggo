# joggo

A self-hosted GitHub Actions runner built to run for weeks on a machine someone is
also using.

Not a Kubernetes operator, not an autoscaler, not a fleet. One ordinary Windows PC
with 16 GB of RAM, WSL2, and two containerised runner slots that have taken
production builds for ten months — through clock drift, power loss, Windows Update
reboots, memory exhaustion down to 445 MB available, and a Docker daemon that
occasionally stops answering.

The code is maybe half of it. The other half is the comments: most files carry the
failure that produced them, what was measured, and what was tried and did not work.
That is deliberate. **[`docs/memory-pressure.md`](docs/memory-pressure.md) is the
single most useful page here** even if you never run any of this.

> **If you are an AI agent operating this box**, skip to
> [For agents](#for-agents--operating-contract). It has the invariants, the paths, the
> safe/destructive command split, and the failure-mode discriminators in one place.

---

## What you get

```
slots/      Two containerised runner slots. Each is a runner container plus its own
            Docker daemon, on its own network, with a throwaway work volume.
            run.sh --once per job, so no job ever sees another's workspace.
              run-containerized-slot.sh    the launcher (read its header first)
              add-slot.sh                  add slot N
              slot-pause.sh                drain/hold a slot without killing its job
              slots-status.sh              one-line state of every slot
              dind-image/                  the per-slot Docker-in-Docker image
              systemd/joggo-slot@.service  the template unit

guard/      Memory guard. Samples every 5 min and escalates: drop the VM page cache,
            then HOLD the slots so no NEW job starts while running jobs finish, then
            restart the VM only if the slots are idle.
              wsl-mem-guard.ps1            the guard
              mem-watch.ps1                the 5-minute sampler + snapshots

watchdog/   The three failure modes that actually took this runner down, each with a
            self-heal: a frozen clock that invalidates every OAuth token, a listener
            that hangs alive at 0% CPU, and a Windows Update reboot that kills an
            in-flight job.
              runner-watchdog.sh           wedge detector (65-min threshold; see docs)
              rerun-after-reboot.sh        re-dispatches jobs killed by a reboot
              take-restore-point.sh        ~450 MB rollback point before upgrades

monitor/    deploy-monitor.ps1   WPF monitor that reconstructs deploys from the
                                 runner's own journal. No GitHub token needed.
            day-report.ps1       daily "what failed, and why" page

network/    filter-aaaa.conf     dnsmasq drop-in for hosts that advertise AAAA
                                 records they cannot route (see Known limits)

tailscale/  acl.hujson           default-deny tailnet policy; admin devices, SSH only

.github/    build-and-push.yml   reusable workflow_call image build (buildx → GHCR)
            node-test.yml        reusable containerised Node test job, with a
                                 no-host-port Postgres service
```

---

## Setup

Three phases, in order. **Phase 2 is the GitHub side**, and it is the part people miss.

### Phase 1 — the box

Full runbook: **[`docs/runner-setup.md`](docs/runner-setup.md)**. In outline:

1. A dedicated unprivileged user (`ghrunner`). Never run the runner as root.
2. Docker Engine inside WSL2 — **native, not Docker Desktop**.
3. Disable sleep, in Windows *and* in the BIOS. An asleep runner is a CI outage for
   every repository pointed at it.
4. Tailscale, then `tailscale/acl.hujson` — default-deny, admin devices only, SSH only.
5. Host firewall: default-deny inbound, management over the tailnet only.

### Phase 2 — register with GitHub

**Where to click:**
`https://github.com/organizations/<your-org>/settings/actions/runners/new` → Linux x64.
Copy the **registration token** it shows you.

**That token is short-lived (~1 hour) and must never be committed or stored.** Minting
it is deliberately a human step — [`SECURITY.md`](SECURITY.md) and
[`docs/recovery.md`](docs/recovery.md) §5 explain why automating it is left undone.

```bash
# as the runner user, inside WSL
sudo -iu ghrunner bash -c '
  cd ~/actions-runner &&
  ./config.sh \
    --url https://github.com/<your-org> \
    --token <REG_TOKEN> \
    --name joggo \
    --labels self-hosted,linux,x64,joggo \
    --unattended --replace'
```

Register at the **organisation** level, not per repository — one registration serves
every repo you allow. `--replace` matters: a ghost entry with the same name usually
survives server-side and will block a fresh registration without it.

**Then the runner group, which is the actual security boundary.**
`Settings → Actions → Runner groups` — create one (these docs call it `joggo-runners`)
and choose which repositories may reach it:

```
Allow public repositories     MUST stay unchecked
Repository access             private repos only, chosen explicitly
Fork PR workflows             require approval for outside collaborators
```

**A self-hosted runner executes whatever the allowed repositories tell it to, on your
hardware, inside your home network.** That group page is the whole threat model.

Install it as a service so it survives reboots, then confirm **Idle / online** on the
org Runners page:

```bash
cd /home/ghrunner/actions-runner
sudo ./svc.sh install ghrunner && sudo ./svc.sh start && sudo ./svc.sh status
```

For the containerised two-slot setup rather than one plain runner, carry on into
[`docs/adding-a-slot.md`](docs/adding-a-slot.md).

### Phase 3 — point a repository at it

Full runbook: **[`docs/onboarding-a-repo.md`](docs/onboarding-a-repo.md)**. The fast
path calls the reusable workflow, which keeps a consuming repo to a few lines:

```yaml
# .github/workflows/ci.yml in YOUR project repo
name: CI
on:
  push:
    branches: [main]
    paths: ['apps/**', 'packages/**', 'Dockerfile', 'package.json']
  workflow_dispatch:

jobs:
  build:
    uses: <your-org>/joggo/.github/workflows/build-and-push.yml@main
    with:
      image-name: my-service        # defaults to the repo name
      context: .
      dockerfile: ./Dockerfile
      # publish-latest: false       # see the sharp edge below
    permissions:
      contents: read
      packages: write               # REQUIRED for the job's GITHUB_TOKEN to push to GHCR
```

That is all. The reusable workflow already sets
`runs-on: [self-hosted, linux, x64, joggo]`, logs into GHCR with the job's own
`GITHUB_TOKEN`, and tags the image.

**One sharp edge, worth reading before you rely on `:latest`.**
`build-and-push.yml` appends `:latest` itself, gated on `enable={{is_default_branch}}`.
Two consequences:

- If your repo publishes **several** images and anything downstream keys off `:latest`,
  pass `publish-latest: false` and retag deliberately once every image for the commit
  exists. Otherwise the `:latest` pushes race each other.
- If your **deploy branch is not your default branch**, that gate never fires and
  `:latest` silently freezes. Check before trusting it:

  ```bash
  gh api repos/<owner>/<repo> --jq .default_branch    # vs the branch in your `on:`
  ```

  Equal → a separate retag job is redundant. Different → that retag job is the *only*
  thing publishing `:latest`, and deleting it breaks your deploys.

---

## Operating it

```bash
slots/slots-status.sh                       # what every slot is doing
slots/slot-pause.sh status --slot 1         # one slot, in detail
slots/slot-pause.sh pause  --slot 1 "why"   # drain: no NEW jobs; running job finishes
slots/slot-pause.sh resume --slot 1         # take jobs again
pwsh guard/wsl-mem-guard.ps1 -DryRun        # what the guard would do, changing nothing
```

Day to day: **[`docs/operations.md`](docs/operations.md)**.
When it stops taking jobs: **[`docs/recovery.md`](docs/recovery.md)** — it opens with a
triage table, because the failure modes have *opposite* fixes and guessing makes things
worse.

---

## For agents — operating contract

If you are an AI agent asked to run or repair this box, this section is for you.

### Invariants — do not violate these

| Invariant | Why |
|---|---|
| **No privileged secrets on the box.** No org-admin PAT; never store a registration token. | A self-hosted runner executes other repositories' code. See [`SECURITY.md`](SECURITY.md). |
| **Never point a public repo, or fork PRs, at this runner.** | Arbitrary code on the operator's hardware, inside their network. |
| **A hold must never kill a running job.** `pause` writes a flag and the job finishes. Only `--now` interrupts, and it names the job first. | A hold that destroys work is worse than no hold at all. |
| **Ask before restarting the runner, the VM, or anything that drops a job.** | Hard to reverse, and the cost lands on other people's builds. |
| **Do not move the guard's thresholds to make a symptom go away.** | They came from measurements — see `docs/memory-pressure.md`. |

### Where state lives

```
/var/lib/joggo-slot/<N>.paused           the pause flag — the contract between
                                          slot-pause, the launcher and the guard
/var/log/joggo-slots/<N>/_diag/          that slot's Runner_*.log and Worker_*.log
C:\ProgramData\joggo\mem-watch.csv       the 5-minute sample trail
C:\ProgramData\joggo\snapshots\          full snapshots, written when free memory trips
C:\ProgramData\joggo\wsl-mem-guard.log   every guard decision, with its reasoning
```

### Command safety

```
READ-ONLY     slots-status.sh · slot-pause.sh status · wsl-mem-guard.ps1 -DryRun
              systemctl is-active|is-enabled · docker ps · journalctl
              gh run list · gh api .../jobs

MUTATING      slot-pause.sh pause|resume        reversible; loses no job
              systemctl restart joggo-slot@N    CHECK for an in-flight job first

DESTRUCTIVE   slot-pause.sh --now               kills the running job
              wsl --shutdown                    kills every job on the box
              config.sh remove                  deregisters; needs a fresh token
              ASK FIRST. Each of these costs somebody a build.
```

### Discriminators — read these before diagnosing

Several failure modes here are indistinguishable without the right test. These are the
tests, each learned by getting it wrong first.

**A job that never ran, versus a job that failed.** From the payload, no logs needed —
all four conditions together:

```
conclusion cancelled|failure · runner_name empty · steps 0 · labels include self-hosted
```

Every clause excludes a real case. *Zero **failed** steps* alone also matches a job a
human cancelled mid-flight, which reports its runner and its executed steps. Without
the `self-hosted` clause, every **hosted** job killed by a billing problem gets
misattributed to your runner.

**Queued forever — four causes with opposite fixes.**
[`docs/recovery.md`](docs/recovery.md) has the table: clock drift (re-register), wedged
listener (restarting *is* the fix), Actions outage (do **not** restart), or the box
rebooted (already retried automatically).

**`--once` makes "inactive" normal.** A slot is genuinely `inactive` between every job.
Read `is-enabled` and the age of the newest `Runner_*.log` instead.

**A run's conclusion says nothing about whether anything was published**, in either
direction: a red run may have pushed its image already, and a green run may have
published nothing. Key off the publishing job, not the run.

**A read that cannot fail loudly returns a number, not an error.** Before trusting a
count, ask what the query would return if its basis were missing. If that is a
plausible number rather than an error, check the basis separately — with a positive
control in the same call, or the same quantity from a second instrument at a different
layer. `docs/memory-pressure.md` §9 has five instances from this box, every one of
which fooled somebody first.

---

## Three findings worth your time even if you close the tab

**`FreePhysicalMemory` is not free memory.** It is *available* memory — standby cache
plus free pages. The genuinely-empty portion swung between 3 MB and 4 GB on this box
within a day. Threshold on available; the other number is noise.

**This box runs 2× oversubscribed and has never paged out.** Committed memory sits at
26–33 GB against 16.3 GB of RAM, and `Pages Output/sec` was zero across ten days.
Memory compression absorbs it, paying in CPU rather than I/O — which makes
`pagefileMB` (a level, sticky for hours after a spike) the wrong signal, and the rate
the right one.

**The largest process on a CI box was a terminal emulator.** 24.2 MB/hour, dead steady
across 118 hourly samples, 6 GB by the end — bigger than the WSL VM. Nothing to do
with CI, and it eventually starved the runner into a seven-hour outage. If you build
monitoring, expect the answer to be something you were not watching.

---

## Status and honesty

Extracted from a working private setup, generalised, with organisation names and host
identifiers removed. It has run continuously for months in its original form.

**It has no CI of its own**, which is a slightly embarrassing thing for a CI project to
admit. The shell scripts pass `bash -n`; the reusable workflows are exercised daily by
real builds but are not validated in this repository.

**Known limits, documented in place rather than in a tracker:**

- `--once` costs **83–108 s** of container rebuild per job, and GitHub's
  runner-acquisition timeout races it at *every* job boundary — so an 11-job workflow
  has eleven chances to die with *"not acquired by Runner of type self-hosted"*, not
  one. Measured on one repository: **~11% of jobs**. Persisting the Docker daemon and
  network while recreating only the runner container would recover most of it; that is
  not done here.
- **Nothing watches queue age.** A job that is never acquired looks exactly like a job
  that is merely slow.
- The Docker-in-Docker daemon is probed once at slot start and never again.
- Container memory limits are unset; the guard works at the VM level instead.
- `GET /actions/runs/{id}/jobs` returns only the **latest** attempt, so a green re-run
  erases the record of an earlier acquisition death. Any rate computed from it is a
  floor.
- Some hosts advertise AAAA records they cannot route, which makes build-time fetches
  and registry logins hang rather than fail fast. `network/filter-aaaa.conf` is the
  dnsmasq drop-in for that.

Issues and findings are both welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md).
A measurement beats an opinion, and a method beats a measurement.

## License

MIT — see [`LICENSE`](LICENSE). Provided as is, without warranty of any kind.
