# marathon

A self-hosted GitHub Actions runner built to run for weeks on a machine someone
is also using.

Not a Kubernetes operator, not an autoscaler, not a fleet. One ordinary Windows
PC with 16 GB of RAM, WSL2, and two containerised runner slots that have taken
production builds for ten months — through clock drift, power loss, Windows
Update reboots, memory exhaustion down to 445 MB available, and a Docker daemon
that occasionally stops answering.

The code is maybe half of it. The other half is the comments: most files carry
the failure that produced them, what was measured, and what was tried and did
not work. That is deliberate. **[`docs/memory-pressure.md`](docs/memory-pressure.md)
is the single most useful page here** even if you never run any of this.

## What it actually does

```
slots/      two containerised runner slots. Each is a runner container plus its
            own Docker daemon, on its own network, with a throwaway work volume.
            `--once` per job, so no job sees another's workspace.

guard/      a memory guard that samples every 5 minutes and escalates: drop the
            VM's page cache, then HOLD the slots so no new job starts while
            running jobs finish, then restart the VM only if the slots are idle.
            ~250 drops, ~60 holds, 3 restarts, zero jobs killed in ten days.

watchdog/   the three failure modes that actually took this runner down, each
            with its own self-heal: a frozen clock that invalidates every OAuth
            token, a listener that hangs alive at 0% CPU, and a Windows Update
            reboot that kills an in-flight job.

monitor/    a WPF desktop monitor that reconstructs deploys from the runner's own
            journal over WSL. No GitHub token required.

.github/    two reusable workflows — a buildx image build-and-push, and a
            containerised Node test job with a no-host-port Postgres service.
```

## Why you might want this

Because GitHub-hosted minutes are not free and a desktop is idle most of the day.
That is the whole pitch. What makes it non-trivial is that a runner on a machine
you also *use* has constraints a cloud runner does not: it has to yield memory to
the person at the keyboard, survive the machine sleeping, and never leave a job
half-dead because something unrelated needed RAM.

## Why you might not

**Do not point a public repository's pull-request workflows at this.** A PR from
a stranger is arbitrary code on your hardware, inside your home network.
[`SECURITY.md`](SECURITY.md) has the rest, including the one rule the whole
design is organised around: no privileged secrets on the box.

## Start here

| You want to | Read |
|---|---|
| understand the interesting problem | [`docs/memory-pressure.md`](docs/memory-pressure.md) |
| stand one up | [`docs/runner-setup.md`](docs/runner-setup.md) |
| let a repo use it | [`docs/onboarding-a-repo.md`](docs/onboarding-a-repo.md) |
| run it day to day | [`docs/operations.md`](docs/operations.md) |
| fix it when it stops taking jobs | [`docs/recovery.md`](docs/recovery.md) |
| add a third slot | [`docs/adding-a-slot.md`](docs/adding-a-slot.md) |
| upgrade the runner version | [`docs/upgrading.md`](docs/upgrading.md) |
| lock down network access | [`tailscale/acl.hujson`](tailscale/acl.hujson) |

## Three findings worth your time even if you close the tab

**`FreePhysicalMemory` is not free memory.** It is *available* memory — standby
cache plus free pages. The genuinely-empty portion swung between 3 MB and 4 GB on
this box within a day. Threshold on available; the other number is noise.

**This box runs 2× oversubscribed and has never paged out.** Committed memory
sits at 26–33 GB against 16.3 GB of RAM, and `Pages Output/sec` was zero for ten
days. Memory compression absorbs it, paying in CPU rather than I/O. Which means
`pagefileMB` — a level, sticky for hours after a spike — is the wrong signal, and
the rate is the right one.

**The largest process on a CI box was a terminal emulator.** 24.2 MB/hour, dead
steady across 118 hourly samples, 4.8 GB by the end — bigger than the WSL VM.
Nothing to do with CI. If you build monitoring, expect the answer to be something
you were not watching.

## Status and honesty

This is extracted from a working private setup, generalised, with organisation
names and host identifiers removed. It has run continuously for months in its
original form.

**It has no CI of its own**, which is a slightly embarrassing thing for a CI
project to admit. The shell scripts pass `bash -n`; the reusable workflows have
been exercised daily by real builds but are not validated in this repository.

**Known limits, all documented in place rather than in a tracker:**

- `--once` costs 83–108 s of container rebuild per job, and GitHub's acquisition
  timeout races it at *every* job boundary. On one repository that killed ~11% of
  jobs. Persisting the Docker daemon and network while recreating only the runner
  container would recover most of it, and is not done here.
- Nothing watches queue age, so a job that is never acquired looks exactly like a
  job that is merely slow.
- The Docker-in-Docker daemon's health is probed once at slot start and never
  again.
- Container memory limits are unset. The guard works at the VM level instead.

Issues and findings are both welcome; see [`CONTRIBUTING.md`](CONTRIBUTING.md).
A measurement beats an opinion, and a method beats a measurement.

## License

MIT — see [`LICENSE`](LICENSE).
