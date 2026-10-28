#!/usr/bin/env bash
#
# joggo-pause.sh — put the containerized runner slot on HOLD and get the RAM back,
#               without unregistering it and without losing a single queued run.
#
# WHY THIS EXISTS
# ---------------
# joggo is one 8GB WSL2 VM shared by CI, the dev Postgres instances and whatever
# the operator is doing on Windows. A CI job is the largest single memory consumer
# on the box and it arrives unannounced. This is the lever for "not for the next
# hour" — the alternative people reach for is `systemctl stop`, which kills the job
# that happens to be running and leaves no record of why the runner went away.
#
# WHAT PAUSE ACTUALLY DOES
# ------------------------
# It writes a flag file. run-containerized-slot.sh reads that flag BEFORE it builds
# anything and, instead of starting a listener, sleeps until the flag goes away. So
# a hold costs one bash and one sleep — roughly 4MB. While paused there is no runner
# container, no dind, no _work volume and no job.
#
#   $ joggo-pause pause
#   $ joggo-pause status
#   $ joggo-pause resume
#
# "LEAVE THE LISTENER LIVE TO COLLECT QUEUED JOBS" — WHAT REALLY HAPPENS
# ----------------------------------------------------------------------
# A listener that is up but declines work is not a thing that exists: the listener's
# only behaviour on being handed a job is to run it, and the memory you are trying to
# free is the job's, not the listener's. It does not matter, because THE QUEUE WAS
# NEVER OURS TO HOLD — it lives on GitHub's side.
#
# This slot reuses a permanent registration (it has never used --ephemeral), so the
# runner stays registered to the org while it is paused. GitHub keeps queueing runs
# against joggo and hands them over oldest-first the moment it comes back. Nothing
# is dropped and nothing needs re-running. deploy-monitor's INCOMING·QUEUED list is
# fed from the GitHub API rather than from the runner, so you can literally watch the
# queue build while paused.
#
# The one limit worth knowing: GitHub expires a queued job after 24 hours. This is an
# afternoon lever, not a weekend one. `status` tells you how long you have been paused.
#
# DRAINING, NOT KILLING
# ---------------------
#   slot idle      -> the listener is stopped GRACEFULLY right now. A clean stop hands
#                     the GitHub session back; an abrupt one makes the next start pay
#                     ~95s of "a session for this runner already exists" (measured
#                     2026-09-04, see run-containerized-slot.sh).
#   job in flight  -> the flag is set and the job is LEFT ALONE. The slot holds when it
#                     finishes. That is not a special case: it is exactly what --once
#                     turnover does on every job boundary anyway.
#   --now          -> stops the in-flight job too. GitHub reports that job as failed.
#                     The script names the job before it does it.
#
# WSL2 MEMORY — WHERE THE FREED PAGES ACTUALLY GO
# -----------------------------------------------
# Freeing memory INSIDE the WSL2 VM does not hand it back to Windows. Without
# `autoMemoryReclaim` in %USERPROFILE%\.wslconfig the VM keeps every page it has ever
# touched, so a pause frees memory for the dev DBs and for other WSL work — which is
# usually what you wanted — but Windows still shows the same commit.
#
# On this box that setting is DELIBERATELY OFF, sitting commented out in .wslconfig.
# Reclaim runs against the whole VM, so it also claws pages back from long-running WSL
# work that is only briefly idle, and that work pays for them again on the next touch.
# The box is used for more than CI, so paying that all day to make an occasional pause
# visible to Windows is the wrong trade. Turn it on for the occasion instead:
#
#     [experimental]
#     autoMemoryReclaim=gradual     # or dropcache: frees more, costs more on next read
#
# then `wsl --shutdown` (which stops the dev DBs — `docker start` them after).
#
# wslconfig_note() below reports which of the three states the box is in, and warns in
# only one of them. See its comment for why nagging about state two would be wrong.
#
# INSTALL
#   install -m 0755 slots/slot-pause.sh /usr/local/sbin/joggo-pause
#
# The flag path is the actual contract between this script, the launcher and the
# monitor. Anything that can create/remove /var/lib/joggo-slot/<slot>.paused can pause the
# runner; this script is the ergonomic front end (drain, reclaim, reporting), not a
# gatekeeper.
set -uo pipefail

SLOT="${SLOT:-1}"
ACTION=""
FORCE_NOW=0
REASON=""

while [ $# -gt 0 ]; do
    case "$1" in
        pause|resume|status) ACTION="$1"; shift ;;
        --now)               FORCE_NOW=1; shift ;;
        --slot)              SLOT="${2:-1}"; shift 2 ;;
        -h|--help)           sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                   REASON="${REASON:+$REASON }$1"; shift ;;
    esac
done
[ -n "$ACTION" ] || { echo "usage: joggo-pause <pause|resume|status> [--now] [--slot N] [reason]" >&2; exit 2; }

PAUSE_FLAG="${PAUSE_FLAG:-/var/lib/joggo-slot/${SLOT}.paused}"
UNIT="joggo-slot@${SLOT}.service"
LEGACY_UNIT="actions.runner.example-org.joggo.service"
RUNNER_C="joggo-runner-${SLOT}"
DIND_C="joggo-dind-${SLOT}"
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"

say()  { echo "[joggo-pause] $*"; }
warn() { echo "[joggo-pause] $*" >&2; }

need_root() {
    [ "$(id -u)" = "0" ] || { warn "must run as root (the flag lives under /var/lib). Try: sudo joggo-pause $ACTION"; exit 1; }
}

# The Runner.Worker process exists only while a job is executing, so this is an exact
# answer to "is a job in flight", not a guess from log tailing. Read with `docker top`
# rather than `docker exec` so it still works if the container is unresponsive.
job_in_flight() {
    docker top "$RUNNER_C" 2>/dev/null | grep -q 'Runner\.Worker'
}

# The runner floods the journal with per-process WORKER debug lines while a job runs, so the
# "Running job:" line is thousands of entries back within seconds. Scan a time window, not a
# line count — a tail of 200 finds nothing and reports "<unknown job>" exactly when a job IS
# running, which is the one moment this has to be right (it names what --now would kill).
current_job() {
    journalctl -u "$UNIT" -u "$LEGACY_UNIT" --no-pager --since "-12 hours" 2>/dev/null \
        | grep -a 'Running job:' | tail -1 | sed -E 's/.*Running job: //'
}
slot_containers() {
    docker ps --filter "name=^${RUNNER_C}$" --filter "name=^${DIND_C}$" \
        --format "{{.Names}}" 2>/dev/null | paste -sd", " -
}

# Only ever touches THIS slot's two containers by exact name. The same daemon runs the
# operator's dev databases (handsfree-clinic-postgres, appsix-db-1, …) and they must
# never be caught by a pause.
stop_listener() {
    say "stopping the listener gracefully (up to ${STOP_TIMEOUT}s so the GitHub session is released cleanly)"
    docker stop -t "$STOP_TIMEOUT" "$RUNNER_C" >/dev/null 2>&1 || true
    # No further teardown here: run.sh exiting returns from `docker run`, the launcher's
    # own EXIT trap removes dind, the network and the volumes, and systemd restarts it
    # straight into the hold. Doing it by hand would race that trap.
}

# Three states, and only one of them is a problem worth interrupting for.
#
#   set        -> report the mode, no advice needed.
#   commented  -> the operator has an option they deliberately left off. Say it is there and
#                 move on. Warning about a choice already made is nagging, and this runs on
#                 every pause and every status.
#   absent     -> the one case where someone might not know the lever under-delivers. Warn.
#
# Off is a defensible default on this box: reclaim runs against the WHOLE VM, so it also
# claws pages back from long-running WSL work that is only briefly idle, and that work pays
# for them again on the next touch. Paying that all day to make an occasional pause visible
# to Windows is the wrong trade unless you are actively waiting on Windows memory.
wslconfig_note() {
    local cfg found="" mode=""
    for cfg in /mnt/c/Users/*/.wslconfig; do
        [ -r "$cfg" ] || continue
        found="$cfg"
        mode="$(grep -Ei '^[[:space:]]*autoMemoryReclaim[[:space:]]*=' "$cfg" | tail -1 | sed -E 's/.*=[[:space:]]*//' | tr -d '\r')"
        if [ -n "$mode" ]; then
            say "autoMemoryReclaim=$mode — freed memory is handed back to Windows."
            return 0
        fi
        if grep -qi 'autoMemoryReclaim' "$cfg"; then
            say "autoMemoryReclaim available but off (commented in $cfg) — freed memory stays in the WSL VM."
            say "  Uncomment it and 'wsl --shutdown' when you need a pause to give memory back to Windows."
            return 0
        fi
    done
    if [ -n "$found" ]; then
        warn "NOTE: $found has no autoMemoryReclaim — memory freed here stays inside the WSL VM"
        warn "      and Windows will not see it come back. Add [experimental] autoMemoryReclaim=gradual"
        warn "      and 'wsl --shutdown' to make this lever visible to Windows."
    fi
}

reclaim() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
}

mem_report() {
    free -m 2>/dev/null | awk '/^Mem:/{printf "[joggo-pause] WSL VM memory: %sMB used of %sMB, %sMB available\n",$3,$2,$7}'
}

case "$ACTION" in

status)
    if [ -e "$PAUSE_FLAG" ]; then
        say "PAUSED — $(head -1 "$PAUSE_FLAG" 2>/dev/null)"
        since="$(stat -c %Y "$PAUSE_FLAG" 2>/dev/null || echo 0)"
        if [ "$since" -gt 0 ]; then
            held=$(( $(date +%s) - since ))
            say "held for $((held/3600))h $(((held%3600)/60))m"
            # GitHub drops a queued job after 24h. Say it while it can still be acted on.
            [ "$held" -gt 72000 ] && warn "over 20h — GitHub expires queued jobs at 24h. Resume soon or those runs are lost."
        fi
    else
        say "LIVE — the slot takes jobs normally"
    fi
    say "unit $UNIT: $(systemctl is-active "$UNIT" 2>/dev/null || echo unknown)"
    ctrs="$(slot_containers)"
    say "slot containers: ${ctrs:-none}"
    if job_in_flight; then say "job in flight: $(current_job)"; else say "job in flight: none"; fi
    mem_report
    wslconfig_note
    ;;

pause)
    need_root
    if [ -e "$PAUSE_FLAG" ]; then
        say "already paused — $(head -1 "$PAUSE_FLAG" 2>/dev/null)"
        exit 0
    fi
    # The flag only governs the containerized slot. The legacy persistent runner has no
    # job boundary to hold at, so silently writing a flag there would be a lie.
    if systemctl is-active --quiet "$LEGACY_UNIT" 2>/dev/null; then
        warn "$LEGACY_UNIT is active — this box is on the PERSISTENT runner, which this lever does not cover."
        warn "There is no per-job boundary to hold at there. Use: systemctl stop $LEGACY_UNIT (kills any running job)."
        exit 1
    fi

    mkdir -p "$(dirname "$PAUSE_FLAG")"
    printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${REASON:-paused by $(logname 2>/dev/null || echo root)}" > "$PAUSE_FLAG"
    say "flag set: $PAUSE_FLAG"

    if job_in_flight; then
        job="$(current_job)"
        if [ "$FORCE_NOW" = "1" ]; then
            warn "--now: stopping a job that is CURRENTLY RUNNING — GitHub will report it as failed:"
            warn "    ${job:-<unknown job>}"
            stop_listener
            say "stopped. Re-run that job from the Actions page after you resume."
        else
            say "DRAINING — a job is running and is being left alone:"
            say "    ${job:-<unknown job>}"
            say "The slot holds as soon as it finishes. Add --now to stop it immediately instead."
            mem_report
            wslconfig_note
            exit 0
        fi
    elif [ -n "$(slot_containers)" ]; then
        say "slot is idle — stopping the listener now"
        stop_listener
    else
        say "no slot containers running — the hold takes effect at the next start"
    fi

    # Give the launcher's EXIT trap room to remove dind, the network and the volumes
    # before we report what was actually freed.
    for _ in $(seq 1 20); do
        [ -z "$(slot_containers)" ] && break
        sleep 1
    done
    left="$(slot_containers)"
    [ -n "$left" ] && warn "still up after 20s: $left (teardown may still be in progress)"

    reclaim
    say "PAUSED. No listener, no dind, no job — the queue keeps building on GitHub and lands on resume."
    mem_report
    wslconfig_note
    ;;

resume)
    need_root
    if [ ! -e "$PAUSE_FLAG" ]; then
        say "not paused — nothing to do"
        exit 0
    fi
    was="$(head -1 "$PAUSE_FLAG" 2>/dev/null)"
    rm -f "$PAUSE_FLAG"
    say "flag cleared (was: $was)"
    # The launcher polls the flag every PAUSE_POLL seconds (10 by default) from inside its
    # hold loop, so there is nothing to restart — but if the unit died while paused, or the
    # box was rebooted, start it.
    if ! systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        say "$UNIT was not active — starting it"
        systemctl start "$UNIT" || warn "could not start $UNIT"
    fi
    say "RESUMED. The slot picks the queue up oldest-first within ~10s (first job pays the usual ~83s cold start)."
    ;;

esac
