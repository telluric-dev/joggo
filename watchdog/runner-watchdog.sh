#!/usr/bin/env bash
#
# runner-watchdog.sh — detect and recover a WEDGED (hung-but-alive) runner listener.
#
# COVERS BOTH RUNNER SHAPES. Since 2026-09-06 this targets whichever runner is actually
# live on the box: the containerized slot (marathon-slot@N) or the retired persistent unit.
# See "TARGET SELECTION" below. Before that it hardcoded the persistent unit, which after
# the cutover meant it woke every 5 minutes, found that unit 'inactive', and correctly did
# nothing — leaving the slot with no wedge cover at all.
#
# THE GAP THIS FILLS. The runner service carries Restart=always, which recovers
# a listener that CRASHES. On 2026-09-01 the listener did something worse: it
# hung. The broker's TLS connection died mid-read at 12:44:22Z
# (SocketException 125), the listener retried, then hung inside its ~50-minute
# OAuth token refresh on that already-dead socket. The process stayed alive at
# 0% CPU in futex_wait_queue holding an ESTABLISHED socket, so systemd saw a
# perfectly healthy unit while 7 jobs piled up in the queue. Restart=always
# cannot fire for a process that never exits.
#
# THE SIGNAL. A healthy listener refreshes its OAuth token every ~50 minutes and
# logs the pair:
#     [.. INFO RSAFileKeyManager] Loading RSA key parameters from file ..
#     [.. INFO GitHubActionsService] AAD Correlation ID for this token request: ..
# Measured over 2 days / 5422 log lines on this box, the LONGEST gap between
# consecutive listener log writes while idle was 3021s (50.35 min). A wedged
# listener writes nothing, ever again. So "newest Runner_*.log untouched for
# more than SILENCE_LIMIT" separates the two, provided SILENCE_LIMIT sits
# comfortably above 50.35 min. Default is 65 min — ~15 min of margin.
#
# DO NOT lower SILENCE_LIMIT toward 20-30 minutes. An idle-but-healthy listener
# is routinely silent for 50 minutes; a shorter threshold restarts it constantly.
#
# THE SIGNAL IS UNCHANGED ON THE SLOT, and that is a deliberate inheritance rather than a
# fresh measurement. The slot runs the SAME Runner.Listener binary doing the SAME long
# poll; --once changes when it exits, not how often it writes while waiting. Two facts
# measured on the slot on 2026-09-06 back this up:
#   * while a job runs, JobDispatcher logs "Successfully renew job .." every ~60s, so a
#     busy slot is never near the threshold;
#   * a slot rolls a NEW Runner_*.log per job (82 of them in a day), so "newest log" is
#     always the current container's.
# What is NOT re-measured is the idle ceiling on the slot specifically — the box has not
# been idle for 50 minutes since the cutover. The threshold errs in the safe direction
# (too long, not too short), so the untested case is "acts late", not "acts wrongly".
#
# WHY FALSE POSITIVES ARE CHEAP. The watchdog never acts while a job is running
# (guard 2), and a restart of an IDLE listener costs ~3 seconds of reconnect and
# loses nothing. So the design deliberately errs toward acting.
# On the SLOT a false positive costs more — a full teardown plus a ~45s cold start
# (p50 44s / p90 69s, measured over 75 starts on 2026-09-06) — but it still loses no
# work, because guard 2 refuses to act under a job.
#
# GUARDS (all must pass before a restart):
#   0. not paused          — ci-pause.sh holds on purpose; that is not a wedge.
#   1. unit is 'active'    — never fight an operator who deliberately stopped it,
#                            and never race Restart=always on a crash.
#   2. no Runner.Worker    — never kill an in-flight job.
#   3. log silent > limit  — the actual wedge signal.
#   4. rate limit          — at most one restart per MIN_RESTART_INTERVAL, so a
#                            genuinely broken box cannot enter a restart loop.
#
# GUARD 2 WORKS THROUGH THE CONTAINER BOUNDARY. This was written down as an open blocker
# ("pgrep cannot see a Runner.Worker inside a container") and it is wrong. The slot's
# containers do not get a PID namespace of their own from the host's point of view, so a
# host-side pgrep sees the containerized processes by their real command lines. Verified
# on 2026-09-06 with a job in flight:
#     $ pgrep -af 'Runner\.Worker'
#     56192 /home/ghrunner/actions-runner/bin.2.337.0/Runner.Worker spawnclient 149 152
# The paths match because the slot mounts the runner root at the SAME absolute path inside
# the container. Guard 2 therefore needed no porting at all.
#
# USAGE
#   ./runner-watchdog.sh --check     # report state, never restart (safe anywhere)
#   ./runner-watchdog.sh             # enforce (what the systemd timer runs)
#   SILENCE_LIMIT=3900 ./runner-watchdog.sh
#   SERVICE=marathon-slot@1.service DIAG=/var/log/marathon-slots/1/_diag ./runner-watchdog.sh --check
#
# Installed on marathon as /usr/local/sbin/runner-watchdog.sh, driven by
# runner-watchdog.timer every 5 minutes. Runs as root (needs systemctl restart).
# See the restore-runner-after-clock-mismatch skill for the incident history.

set -uo pipefail

SLOT="${SLOT:-1}"
SLOT_SERVICE="marathon-slot@${SLOT}.service"
HOST_SERVICE="actions.runner.example-org.marathon.service"

# --- TARGET SELECTION -------------------------------------------------------
# Exactly one of these two runners may hold the registration at a time (the slot unit
# carries Conflicts= against the persistent one), so "which is live" is unambiguous and
# there is no need to make the caller state it.
#
# Prefer the SLOT when it is ENABLED, not merely when it is active. Normal --once turnover
# means the slot is genuinely inactive for a second or two between every job; a watchdog
# that fell back to the retired unit in that window would assess a unit nobody is running,
# find it 'inactive', and cheerfully report the box healthy.
#
# SERVICE/DIAG stay overridable so --check can be pointed anywhere, and so the fault
# injection in the upgrade-ci-runner skill can drive a specific target.
if [ -z "${SERVICE:-}" ]; then
    if systemctl is-enabled --quiet "$SLOT_SERVICE" 2>/dev/null \
       || systemctl is-active --quiet "$SLOT_SERVICE" 2>/dev/null; then
        SERVICE="$SLOT_SERVICE"
    else
        SERVICE="$HOST_SERVICE"
    fi
fi

# _diag lives in a different place for each shape. On the slot it is a HOST bind
# (/var/log/marathon-slots/N/_diag) precisely so this watchdog and deploy-monitor.ps1 can read
# it from outside the container; on the persistent runner it is the install's own _diag.
if [ -z "${DIAG:-}" ]; then
    case "$SERVICE" in
        marathon-slot@*) DIAG="/var/log/marathon-slots/${SLOT}/_diag" ;;
        *)         DIAG="/home/ghrunner/actions-runner/_diag" ;;
    esac
fi

SILENCE_LIMIT="${SILENCE_LIMIT:-3900}"          # 65 min; healthy idle max is ~3021s
MIN_RESTART_INTERVAL="${MIN_RESTART_INTERVAL:-1800}"   # 30 min between watchdog restarts
STAMP="${STAMP:-/var/lib/runner-watchdog/last-restart}"

# How long to wait for the restarted listener to actually announce "Listening for Jobs".
#
# Persistent unit: measured 2026-09-04 by fault injection — after a restart the runner
# spends ~95s in a session-conflict retry loop ("A session for this runner already
# exists") before it is genuinely available. 180s gives that ~2x headroom.
#
# Slot: a restart is much more expensive, and the two costs ADD. systemd first stops the
# unit, and the launcher's EXIT trap tears down two containers, a network and two volumes
# under TimeoutStopSec=180; only then does a fresh slot start and pay its own cold start
# (p50 44s, p90 69s, max 139s over 75 starts on 2026-09-06). 180s could expire during the
# teardown alone and report a false ERROR on a recovery that was still in progress.
if [ -z "${RECOVER_TIMEOUT:-}" ]; then
    case "$SERVICE" in
        marathon-slot@*) RECOVER_TIMEOUT=360 ;;
        *)         RECOVER_TIMEOUT=180 ;;
    esac
fi

DRY=0
[ "${1:-}" = "--check" ] && DRY=1

log() { echo "[runner-watchdog] $*"; [ "$DRY" -eq 1 ] || logger -t runner-watchdog -- "$*" 2>/dev/null || true; }

# --- guard 0: a deliberate hold is not a wedge ------------------------------
# ci-pause.sh holds INSIDE the launcher, which from here looks exactly like the failure
# this watchdog exists to fix: unit active, no worker, _diag going stale for hours (a
# 17370s hold was recorded on 2026-09-06). Restarting a paused slot would drop it straight
# back into the same hold, having destroyed nothing but time — and would then be rate
# limited out of acting on a REAL wedge for the next 30 minutes. Refuse up front.
PAUSE_FLAG="${PAUSE_FLAG:-/var/lib/ci-slot/${SLOT}.paused}"
if [ -e "$PAUSE_FLAG" ]; then
    log "paused by $PAUSE_FLAG ($(head -1 "$PAUSE_FLAG" 2>/dev/null)) — deliberate hold, not a wedge. Nothing to do."
    exit 0
fi

# --- gather state -----------------------------------------------------------
active="$(systemctl is-active "$SERVICE" 2>/dev/null)"

worker=""
if pgrep -f 'Runner\.Worker' >/dev/null 2>&1; then worker="yes"; fi

newest="$(ls -t "$DIAG"/Runner_*.log 2>/dev/null | head -1)"
now="$(date +%s)"
if [ -n "$newest" ]; then
    mtime="$(stat -c %Y "$newest" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
else
    age=-1
fi

last_restart=0
[ -r "$STAMP" ] && last_restart="$(cat "$STAMP" 2>/dev/null || echo 0)"
since_restart=$(( now - last_restart ))

printf 'target=%s diag=%s service=%s worker=%s log=%s age=%ss limit=%ss since_last_restart=%ss\n' \
    "$SERVICE" "$DIAG" "$active" "${worker:-none}" "$(basename "${newest:-none}")" "$age" "$SILENCE_LIMIT" "$since_restart"

# --- guards -----------------------------------------------------------------
if [ "$active" != "active" ]; then
    log "OK: unit is '$active', not active — leaving alone (deliberate stop, or Restart=always is handling a crash)."
    exit 0
fi

if [ -n "$worker" ]; then
    log "OK: a job is in flight (Runner.Worker present) — never restarting under a running job."
    exit 0
fi

if [ "$age" -lt 0 ]; then
    log "WARN: no Runner_*.log found in $DIAG — cannot assess liveness, taking no action."
    exit 0
fi

if [ "$age" -le "$SILENCE_LIMIT" ]; then
    log "OK: listener wrote ${age}s ago (<= ${SILENCE_LIMIT}s) — healthy."
    exit 0
fi

if [ "$since_restart" -lt "$MIN_RESTART_INTERVAL" ]; then
    log "SKIP: wedge suspected (silent ${age}s) but last watchdog restart was ${since_restart}s ago (< ${MIN_RESTART_INTERVAL}s) — refusing to loop."
    exit 0
fi

# --- act --------------------------------------------------------------------
log "WEDGED: listener silent for ${age}s (> ${SILENCE_LIMIT}s), $SERVICE active, no job in flight. Restarting."

if [ "$DRY" -eq 1 ]; then
    echo "[runner-watchdog] --check: would restart now (no action taken)."
    exit 10
fi

mkdir -p "$(dirname "$STAMP")"
echo "$now" > "$STAMP"

# Snapshot the listening-marker state BEFORE the restart, so we can tell a NEW
# "Listening for Jobs" from the one this log already had.
prev_log="$newest"
prev_listening=0
# NB: grep -c already prints "0" when there are no matches AND exits 1, so a
# "|| echo 0" fallback would append a SECOND zero and produce "0\n0", which then
# blows up every [ ] integer test below. Swallow the exit status, not the output.
[ -n "$prev_log" ] && prev_listening="$(grep -c 'Listening for Jobs' "$prev_log" 2>/dev/null || true)"
prev_listening="${prev_listening:-0}"

if systemctl restart "$SERVICE"; then
    # A LIVE PROCESS IS NOT RECOVERY. Fault injection on 2026-09-04 showed the runner
    # sitting in a session-conflict retry loop for ~95s after a restart — process up,
    # unit active, pgrep satisfied, and accepting no jobs the whole time. Reporting
    # RECOVERED there hides a real outage behind a green log line, and the next attempt
    # is then gated behind MIN_RESTART_INTERVAL. So wait for the runner's own
    # "Listening for Jobs" before claiming success.
    #
    # On the slot the new listener ALWAYS writes a brand-new Runner_*.log, so the
    # cur_log != prev_log branch is the one that fires there; the counter branch is what
    # the persistent unit needs, since it appends to the log it already had.
    deadline=$(( $(date +%s) + RECOVER_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        cur_log="$(ls -t "$DIAG"/Runner_*.log 2>/dev/null | head -1)"
        if [ -n "$cur_log" ]; then
            cur_listening="$(grep -c 'Listening for Jobs' "$cur_log" 2>/dev/null || true)"
            cur_listening="${cur_listening:-0}"
            if [ "$cur_log" != "$prev_log" ]; then
                # runner rolled a new log: any marker in it is new
                [ "$cur_listening" -ge 1 ] && { log "RECOVERED: $SERVICE restarted and the listener reports 'Listening for Jobs' (new log $(basename "$cur_log"))."; exit 0; }
            elif [ "$cur_listening" -gt "$prev_listening" ]; then
                log "RECOVERED: $SERVICE restarted and the listener reports 'Listening for Jobs'."
                exit 0
            fi
        fi
        sleep 5
    done
    if pgrep -f 'Runner\.Listener' >/dev/null 2>&1; then
        log "ERROR: restarted $SERVICE — listener process is up but never reported 'Listening for Jobs' within ${RECOVER_TIMEOUT}s. Runner is NOT taking jobs; investigate (session conflict? auth? network?)."
    else
        log "ERROR: restarted $SERVICE but no Runner.Listener process appeared."
    fi
    exit 1
fi

log "ERROR: systemctl restart $SERVICE failed."
exit 1
