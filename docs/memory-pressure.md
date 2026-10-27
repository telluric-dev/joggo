# Running CI on a 16GB machine that is also someone's desktop

This is what ten days of five-minute sampling taught us about memory on a
Windows box running a self-hosted GitHub Actions runner inside WSL2. Some of it
is counter-intuitive, and several of the conclusions here are the *second* thing
we believed — the first version is kept where it was wrong, because the way it
was wrong is the useful part.

The box: 16,338 MB of RAM, Windows 11, WSL2, two runner slots, each slot a
container pair (runner + its own Docker daemon). It is also a desktop someone
uses.

## 1. `FreePhysicalMemory` is not free memory

Everything downstream of this was wrong until we checked it.

`Win32_OperatingSystem.FreePhysicalMemory` — what `Get-CimInstance` hands you,
and what most scripts treat as "free" — is **available** memory: the standby
cache plus the free/zero page list. Most of what it reports is file cache that
happens to be reclaimable, not memory nobody is using.

Decomposed on this box, within three hours of each other:

```
standby cache   1,334 MB     free+zero   4,066 MB     available  5,400 MB
standby cache   2,940 MB     free+zero       4 MB     available  2,944 MB
standby cache   2,002 MB     free+zero   1,110 MB     available  3,112 MB
```

`free+zero` — pages genuinely holding nothing — ranged from **3 MB to 4,066 MB**
over a single day. It is far too noisy to threshold on, and a monitor that
alarms on it will alarm constantly and mean nothing. We lost about two hours to
a 3 MB reading before taking a second sample, which came back at 220 MB.

**Use available memory for decisions.** It is what the OS can give a new
allocation without going to disk, which is the question you actually have.

## 2. 2× oversubscribed, and it never paged out

Committed memory on this box runs **26–33 GB against 16.3 GB of RAM** — routinely
double, at complete idle as well as under load. By the usual rule of thumb that
should mean constant paging.

`\Memory\Pages Output/sec` was **0** on every sample we took, for ten days,
including at an observed trough of **445 MB available with two jobs running**.

What absorbs it is memory compression. `MemCompression`'s working set tracked the
pressure closely — 66 MB at the quietest, 844 MB at the busiest — and the
pagefile *level* stayed flat or fell while compression rose. The cost is CPU, not
I/O.

Two practical consequences:

- **`pagefileMB` is a level, not a rate.** It is sticky: it rises during a spike
  and does not come back down for hours, so it reads as a trend when it is a
  high-water mark. We flagged it as "growing" on a +385 MB move and it fell
  below its starting point within two hours. `Pages Output/sec` answers the
  question that level was being used as a proxy for, and answers it correctly.
- **Oversubscription on its own is not a fault.** It is the normal state of this
  machine. Watch what it costs, not what it measures.

## 3. The VM's cache is not your cache, and the exchange rate is not 1:1

The guard reclaims memory by dropping the page cache *inside* the WSL VM. That
works, and the amount it returns to Windows is much smaller than the amount it
frees in the VM.

One measured drop:

```
vmmem working set   2,521 MB -> 1,823 MB     released ~698 MB
Windows available   2,455 MB -> 2,700 MB     gained    245 MB
```

The remainder went to Windows standby cache rather than to the free list. We made
the mistake of reading the VM's internal `buff/cache` figure as a Windows lever
twice — once estimating ~1,962 MB of headroom when the real recovery was 245 MB,
an error of roughly tenfold. **A number from inside the VM is a number about the
VM.**

Drop strength across ten days: **+184, +245, +267, +276, +355, +953, +977,
+1,027, +1,160, +1,226, +1,293, +1,399, +1,430 MB.** We briefly called that a
declining trend on the strength of the first two. It is variance.

## 4. Jobs leave the memory behind

After two builds finished, with no workers running and load at 0.19, the VM held
**~1.3 GB** and kept it for ninety minutes. `vmmem` sat at 2,969–3,011 MB across
twelve consecutive samples with nothing executing.

It came back in one cache drop: `vmmem` to ~1,580 MB, commit down 937 MB, and
available up a gigabyte. **The box does not return to its pre-job baseline on its
own.** If you only ever look after a job, you will conclude the runner is using
memory it is not using — a high `vmmem` is not evidence that a job is running,
and we asserted that it was before checking.

## 5. The guard's design, and what it got right

`guard/wsl-mem-guard.ps1` runs every five minutes and escalates in order: drop
the VM's page cache; if still below the warn line, hold the slots so no *new* job
starts while running jobs finish; if the slots are idle, restart the VM.

Over ten days: **~250 cache drops, ~60 escalations, 3 VM restarts, and zero jobs
killed** — including the 445 MB trough with two jobs in flight, and a 563 MB
trough with one. The hold-and-drain path is what makes that record: it never
interrupts work, it only declines to accept more.

The restart branch is the one to be careful with. It fires when the slots are
idle, and the guard's own log once said the useful thing about it:

> STILL LOW after a restart. That points away from WSL — check the Windows side.

Twice the restart could not have helped, because the memory was held by a browser
and a file-sync client, not by the VM. **A restart is a remedy for stale VM
cache, not for pressure from elsewhere**, and nothing in the signal distinguishes
those two cases.

## 6. The biggest consumer was not the runner

The single largest process on this box, for the whole observation window, was
**`WindowsTerminal`** — one process, growing at a very steady **24.2 MB/hour**
across 118 clean hourly samples, reaching **4.8 GB**. Larger than the WSL VM.
Larger than every other process combined, by the end.

It survives a VM restart, because it is a Windows process and has nothing to do
with CI. Restarting the terminal returns the whole 4.8 GB.

This is worth saying plainly: **we instrumented a CI runner and found a terminal
emulator.** If you build this kind of monitoring, expect the answer to be
something you were not watching.

## 7. `--once` costs 83–108 seconds per job, and that has a second-order effect

Each slot runs `run.sh --once`: one job, clean session release, then the launcher
destroys the runner container, the Docker daemon, the network and the volumes and
rebuilds them. Measured from the launcher's own log:

```
22:15:43Z  Listening for Jobs
22:16:16   systemd restarts the slot
22:17:31Z  Listening for Jobs      = 108 seconds
```

The launcher documents ~83 s as expected. The isolation that matters comes from
`--once` and the throwaway work volume; **destroying the Docker daemon and the
network is not load-bearing for it**, and persisting those while recreating only
the runner container recovers most of the cost.

The second-order effect is the expensive one. GitHub's runner-acquisition timeout
is around ten minutes, and it races that rebuild at **every job boundary** — so
an eleven-job workflow has eleven chances to die with *"The job was not acquired
by Runner of type self-hosted even after multiple attempts"*, not one. Measured
on one repository by enumerating every attempt of its last 30 runs: **7 deaths in
65 jobs, ~11%**, spread across six different job names.

Two of those seven were invisible to the obvious query, which is its own lesson:
`GET /actions/runs/{id}/jobs` returns **only the latest attempt**, so a green
re-run erases the death. Any rate computed from that endpoint is a floor.

## 8. How to tell an acquisition death from a real failure

From the job payload, without reading a log. All four conditions:

```
conclusion    cancelled or failure
runner_name   empty
steps         0
labels         include self-hosted
```

Each clause excludes a real case we hit:

- **"zero *failed* steps" is not enough.** A job cancelled mid-flight by a person
  also has zero failed steps — one we saw reported `runner_name` set and 13
  executed steps.
- **The `self-hosted` label is not optional.** `runner=[] steps=0` is equally the
  signature of a *hosted* job that never ran, and an account with a billing
  problem kills every hosted job in about three seconds having executed nothing.
  Without this clause every billing failure is misattributed to your runner. We
  wrote that bug and the test caught it.

One ambiguity the payload cannot settle: a job never *dispatched* because its
dependency was cancelled looks identical. The job's annotation distinguishes
them.

## 9. The instrumentation lessons, which generalise past CI

Four of the wrong answers above came from the same shape: **a read that returns a
plausible number when its basis is missing.**

- `journalctl | grep -ic 'oom'` returned 480 and we nearly reported 480 OOM
  kills. It was matching the substring in container metadata; the word-anchored
  count was **zero**.
- Counting guard CRITICAL events by grepping for `CRITICAL` returned 28, because
  every warning line prints the threshold label `critical=1200`. The real count
  was **6**.
- A casualty check filtering jobs on `runner_name == <our runner>` structurally
  **cannot see** a job that failed *because* it was never assigned to that
  runner — the exact failure mode it existed to catch.
- A watched repository was never watched: the filter defaulted to the repo's
  *default* branch, which was dead, while every deploy ran on another branch. The
  pass reported "nothing new" for weeks, correctly and uselessly.

The test we use now: **ask what a read would return if its basis were missing. If
that is a plausible number rather than an error, check the basis separately.**

Three things that have actually caught these:

1. **A positive control in the same call.** Prove the query can find something
   before believing that it found nothing.
2. **The same quantity from a second instrument at a different layer.** Reading
   the guard's own log rather than the five-minute sampler surfaced a 302 MB
   trough the sampler never captured.
3. **Query the failure mode directly rather than filtering the success path.**

And one about the sampler itself: it fires a snapshot when free memory drops
below a threshold, and the monitoring process *is* one of the things that lowers
free memory — so the snapshots preferentially capture the monitor working. We
attributed an hour's decline to the largest mover in such a snapshot before
noticing it returned to baseline immediately afterwards.
