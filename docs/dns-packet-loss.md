# "Could not resolve host" in self-hosted CI: one lost DNS packet, five seconds

**Symptom.** Builds on a self-hosted runner fail now and then on a network step, with
the code untouched and a re-run usually green:

```
dial udp 127.0.0.11:53: i/o timeout
getaddrinfo ENOTFOUND registry.npmjs.org
Could not resolve host: github.com
Temporary failure in name resolution
```

Terraform, `docker pull` and corepack were the usual victims on this box: four failures
across three repositories in five days. It looks like flaky network, or like the registry being down.
It was neither.

## What was measured

From inside a slot's job container (2026-11-01): **about 1 in 4 UDP lookups to the
configured public resolvers (8.8.8.8, 1.1.1.1) lost a packet.** Not the resolver failing;
a packet going missing somewhere between a WSL2 VM, Docker's NAT and the upstream.

On its own that is harmless, because resolvers retry. The damage is in **how long glibc
waits before retrying: 5 seconds by default.** A job container's lookup goes through two
embedded resolvers (the job's Docker network at `127.0.0.11`, then the slot's
Docker-in-Docker daemon), and one lost packet was enough to run past the 5-second timeout
of the tool that asked. The tool then reported a resolution failure, which is what you
see in the log.

So the bug is not "DNS is down". It is **one dropped packet multiplied by a 5-second
retry**, landing on a tool with a 5-second budget.

## The fix

Make the resolver retry fast. Docker passes resolver options to every container it
creates with `--dns-opt`. joggo starts each slot's daemon with:

```
--dns-opt=no-aaaa --dns-opt=timeout:1 --dns-opt=attempts:3
```

which lands in every job container's `/etc/resolv.conf` as:

```
options no-aaaa timeout:1 attempts:3
```

A lost packet now costs 1 second, three tries are allowed, and a lossy lookup finishes
well inside 5 seconds. (`no-aaaa` is a separate fix for hosts that hand out IPv6 addresses
they cannot route; see [Known limits](../README.md#status-and-honesty).)

If you are not using joggo, the same options work on any Docker host. For the containers a
daemon starts, put them in `/etc/docker/daemon.json`:

```json
{ "dns": ["8.8.8.8", "1.1.1.1"], "dns-opts": ["timeout:1", "attempts:3"] }
```

Or, for a single job, pass `--dns-opt timeout:1 --dns-opt attempts:3` to `docker run`.

## How to check you have this problem

1. **Look at the pattern, not one failure.** Intermittent resolution errors across
   unrelated repositories and tools, green on re-run, point at the path, not at the code.
2. **Measure the loss from where the job runs**, not from your desktop. From inside a
   container on the runner, time a few hundred lookups and count the slow ones:

   ```bash
   for i in $(seq 200); do
     s=$(date +%s%N); getent hosts github.com >/dev/null; e=$(( ($(date +%s%N)-s)/1000000 ))
     [ $e -gt 900 ] && echo "slow: ${e} ms"
   done | wc -l
   ```

   A lookup that took about 5 seconds is a lost packet that waited out glibc's retry.
3. **Check what the job's container actually got:** `cat /etc/resolv.conf` inside a job.
   If there is no `options` line, the defaults (5 seconds, 2 attempts) apply.

## Limits

- These are resolver options, so they cut the cost of loss. They do not stop the loss.
  If the loss rate is high, find out where packets go missing.
- Measured with glibc clients (Debian and Ubuntu images). musl (Alpine) also reads
  `timeout` and `attempts` per its source, but that was not measured here. musl ignores
  `no-aaaa`.
- Only containers started after the change get the new options. Restart the daemon, or the
  slot, and check `resolv.conf` in a fresh job.

The change is in [`slots/run-containerized-slot.sh`](../slots/run-containerized-slot.sh),
where the comment above the `docker run` for dind carries the same history.
