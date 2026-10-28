#!/usr/bin/env bash
# ci-slots-status.sh — what every runner slot is doing, right now.
#
# WHY THIS EXISTS. The joggo board is a FAILURE LEDGER: one card per deploy
# identity, opened by a red run and closed only by a green one. In-flight work
# appears nowhere on it, so "is anything running?" was being answered by reading
# a card that describes a run from hours ago. `ci-pause status` answers it for
# one slot; since 2026-09-29 there are two, and there will be more.
#
# Health here means three separate things, and they fail independently:
#   unit      — is systemd running the slot at all
#   listener  — is a runner connected to GitHub and offerable a job
#   job       — is it executing one, and which
# A slot with `--once` is legitimately listener-less for ~83s between jobs
# (teardown + cold start), so "no listener" is NOT by itself a fault.
#
# Usage:
#   slots/slots-status.sh          # human readable
#   slots/slots-status.sh --json   # machine readable, for the board page

set -uo pipefail
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

slots=$(systemctl list-units 'joggo-slot@*' --all --no-legend --no-pager 2>/dev/null \
        | sed -n 's/^[[:space:]]*joggo-slot@\([0-9]\+\)\.service.*/\1/p' | sort -n)
[ -n "$slots" ] || slots=1

now_epoch=$(date +%s)
rows=""

for s in $slots; do
  unit=$(systemctl is-active "joggo-slot@${s}.service" 2>/dev/null || echo unknown)
  paused=no
  [ -f "/var/lib/ci-slot/${s}.paused" ] && paused=yes

  # The worker container is the job. Its absence means idle, not broken.
  runner_c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -x "joggo-runner-${s}" || true)
  dind_c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -x "joggo-dind-${s}" || true)

  # Which job: a Worker_*.log is created per job and written continuously while it
  # runs, so FRESHNESS is the signal -- not a log line. The obvious-looking grep
  # for "Running job:" finds nothing in these logs (they record step names, not a
  # job banner), which made an earlier version report "idle" while two jobs were
  # demonstrably executing.
  diag="/var/log/joggo-slots/${s}/_diag"
  job=""
  job_age=0
  newest=$(ls -t "$diag"/Worker_*.log 2>/dev/null | head -1)
  if [ -n "$newest" ] && [ -n "$runner_c" ]; then
    mt=$(stat -c %Y "$newest" 2>/dev/null || echo 0)
    if [ $(( now_epoch - mt )) -lt 90 ]; then
      # The repo under _work is the most useful identifier the log reliably has.
      job=$(grep -ahoE "_work/[A-Za-z0-9._-]+" "$newest" 2>/dev/null \
            | sed 's|_work/||' | grep -vE "^_" | head -1)
      [ -n "$job" ] || job="(job running)"
      # The job's real start is the timestamp on the log's FIRST line:
      #   [2026-09-29 20:15:24Z INFO HostContext] ...
      # Neither %W (not recorded here) nor %Z (moves with appends, which reported
      # a two-minute-old job as "0m00s") is usable.
      first=$(head -1 "$newest" 2>/dev/null | cut -c2-21)
      start=$(date -u -d "${first}" +%s 2>/dev/null)
      [ "${start:-0}" -le 0 ] && start=$mt
      job_age=$(( now_epoch - start ))
    fi
  fi

  state=idle
  [ "$unit" != "active" ] && state=down
  [ "$paused" = yes ]     && state=paused
  [ -n "$job" ]           && state=busy

  if [ "$JSON" = "1" ]; then
    rows="$rows{\"slot\":$s,\"state\":\"$state\",\"unit\":\"$unit\",\"paused\":\"$paused\",\"job\":\"${job//\"/}\",\"seconds\":${job_age:-0}},"
  else
    printf '  slot %-3s %-7s unit=%-8s containers=%s%s\n' \
      "$s" "$state" "$unit" \
      "${runner_c:+runner }${dind_c:+dind}" \
      "${runner_c:-${dind_c:+ (dind only — cold start or teardown)}}" >/dev/null
    printf '  slot %s: %-6s  unit=%-7s  paused=%-3s  containers=[%s%s]\n' \
      "$s" "$state" "$unit" "$paused" "${runner_c:+runner }" "${dind_c:+dind}"
    [ -n "$job" ] && printf '           job: %s  (running %dm%02ds)\n' \
      "$job" $(( job_age / 60 )) $(( job_age % 60 ))
  fi
done

if [ "$JSON" = "1" ]; then
  printf '{"at":"%s","slots":[%s]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${rows%,}"
else
  echo
  busy=$(ps -eo cmd | grep -ac '[R]unner.Worker')
  echo "  Runner.Worker processes: $busy   (this is the honest count of jobs executing)"
  free -m | awk '/^Mem:/{printf "  memory: %sMB used of %sMB, %sMB available\n",$3,$2,$7}'
  awk -F'[= ]' '/^some/{printf "  io stall (some avg60): %s%%\n",$3}' /proc/pressure/io 2>/dev/null
fi
