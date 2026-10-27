---
name: add-ci-slot
description: >
  Use when the marathon box needs MORE CONCURRENCY — jobs queuing behind each other, or
  GitHub dropping them with "The job was not acquired by Runner of type self-hosted even
  after multiple attempts". Covers why a second slot needs a second REGISTRATION (not just
  a second systemd instance), the one-command preparation, the human-only token step, how
  to prove real parallelism rather than two runners trading one session, and what to
  re-check afterwards. Operator skill for the marathon platform repo. Trigger on
  "add a slot", "second slot", "more capacity", "jobs are queuing", "jobs being dropped",
  "not acquired by runner", "run two jobs at once", "parallel runners".
---

# Add a runner slot

⚠ **A second systemd instance is NOT a second slot.** `systemctl enable --now marathon-slot@2`
on its own gives you **zero** extra concurrency. A GitHub runner registration holds exactly
one session, so slot 2 would point at slot 1's `.credentials`, lose the session, and retry
about every 95 seconds forever. The launcher says so in its own preflight:

```
missing $RUNNER_ROOT/.credentials — this slot reuses the EXISTING registration
```

**A slot is a registration, not a unit instance.** Everything else is already per-slot.

## Why this is mostly free

`run-containerized-slot.sh` keys almost everything on `$SLOT` already, so there is **no
launcher change to make**:

| already per-slot | value |
|---|---|
| network | `marathon-slot-$SLOT` |
| containers | `marathon-runner-$SLOT`, `marathon-dind-$SLOT` |
| volumes | `marathon-slot-${SLOT}-work`, `marathon-slot-${SLOT}-root` |
| diag | `/var/log/marathon-slots/${SLOT}/_diag` |
| pause / fail flags | `/var/lib/ci-slot/${SLOT}.paused`, `.fails` |

Exactly one thing is shared: `RUNNER_ROOT="${RUNNER_ROOT:-/home/ghrunner/actions-runner}"`.
It is already env-overridable, so a **per-instance** drop-in fixes it without touching the
template or the running slot.

## Before you start

**Do not do this under a live job.** The preparation copies ~450 MB, and this box is
IO-bound — measured 30–40% of tasks stalled on IO with a *single* job running. Adding IO
under load slows the running job and lengthens the queue behind it, which is precisely how
jobs get dropped here. Wait for:

```bash
wsl -d Ubuntu -u root bash -c 'ci-pause status' | grep 'job in flight'
# want: job in flight: none
```

**Take a restore point first and verify it** — `watchdog/take-restore-point.sh`, then read it
back. On 2026-09-12 both restore points on this box turned out unreadable. An unverified
backup is a hope, not a rollback. See **upgrade-ci-runner** §1.

**Baseline smoke on the current slot**, so you know the test works while the proven setup
still serves:

```bash
gh workflow run runner-smoke.yml --repo example-org/marathon
gh run list --repo example-org/marathon --workflow=runner-smoke.yml --limit 1
```

## The procedure

```bash
sudo slots/add-slot.sh 2          # prepare: root + drop-in, no registration, no start
```

That copies the runner install to `/home/ghrunner/actions-runner-2`, **strips the copied
credentials** (a copied credential set is the same registration — that is the whole bug),
and writes `/etc/systemd/system/marathon-slot@2.service.d/root.conf`. It then prints the two
commands only a human can run.

**The token step is deliberately not automated.** It expires in ~1 hour and the hardening
rule is no privileged secrets on the CI box (**setup-ci-runner** §6):

1. Mint at `https://github.com/organizations/example-org/settings/actions/runners/new`
2. Register **as `ghrunner`, not root**:

```bash
sudo -u ghrunner bash -c 'cd /home/ghrunner/actions-runner-2 && ./config.sh \
  --url https://github.com/example-org --token <TOKEN> \
  --name marathon-2 --labels self-hosted,linux,x64,marathon --unattended'
```

**Same labels** so GitHub dispatches the same jobs. **Different name.** Do **not** pass
`--replace` — that takes over slot 1's identity and leaves you with one runner again,
which looks like success right up until nothing runs in parallel.

3. Start it and watch the first acquisition rather than discovering it later:

```bash
systemctl enable --now marathon-slot@2
journalctl -u marathon-slot@2.service -f
```

## Prove it — two runners trading one session looks identical at a glance

Dispatch two smokes **at once**. One after the other proves nothing.

```bash
gh workflow run runner-smoke.yml --repo example-org/marathon
gh workflow run runner-smoke.yml --repo example-org/marathon
gh run list --repo example-org/marathon --workflow=runner-smoke.yml --limit 2
```

Both must be `in_progress` **simultaneously**, on `marathon` and `marathon-2`. If the second
waits for the first, the registration did not take — check that `marathon-slot@2` is really using
its own root:

```bash
systemctl show marathon-slot@2.service -p Environment
ls -l /home/ghrunner/actions-runner-2/.credentials
```

## Afterwards — three things that change

**The watchdog's assumption.** `runner-watchdog.sh` picks its target by asking which runner
is live. With two slots that may no longer resolve sensibly, and a wedge guard aimed at the
wrong unit is worse than none. Check before trusting it:

```bash
/usr/local/sbin/runner-watchdog.sh --check   # reports state, never acts
```

**IO, which was already the binding constraint.** Two concurrent jobs roughly double demand
on the resource that is saturated. The postgres healthcheck failures on this box
(`Initialize containers`, "unhealthy") are an IO-latency symptom — first-boot `initdb` took
**3m07s** against a default ~75s budget. Expect that to get *worse* with two slots, not
better. Land a persistent dind image cache first if you can: every job currently re-pulls
`node:22` and `postgres:16-alpine` because the inner image store is destroyed per job, which
is 55–100s of pure IO per job on the saturated layer.

**Memory.** Each idle slot is small (~265 MB: dind 227 + runner 7 + job 3 + a service
container), but a *running* Node/Next build is not. The WSL VM has ~7.9 GB and the Windows
host has little spare, so the cap cannot simply be raised. Watch `free -m` under two real
jobs before declaring victory.

## Rollback

Slot 1 is untouched throughout, which is what makes this safer than the original cutover.

```bash
systemctl disable --now marathon-slot@2
sudo slots/add-slot.sh 2 --undo        # removes the drop-in and the runner root
```

`--undo` does **not** de-register server-side. Remove the `marathon-2` runner in the GitHub
org settings too, or it lingers as an offline entry.

## Gotcha: measuring whether it helped

Judge it on **queue wait**, not throughput. One slot turns a parallel workflow serial with a
multiplier of roughly the job count — appone's `workflow-lint` is four jobs designed to
run at once, and on one slot they waited 18m57s, 27m23s, 46m40s and 51m28s to do about six
minutes of work between them. The number that should fall is the gap between a job's
`created_at` and its `started_at`. Use `started_at`, never `created_at`, when timing this:
`created_at` is when the job was queued, and confusing the two makes jobs look like they
overlap on a single slot.
