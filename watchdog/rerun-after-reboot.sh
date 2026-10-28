#!/usr/bin/env bash
# Re-run GitHub Actions jobs that failed because THIS box rebooted.
#
# joggo is an always-on Windows+WSL2 box that still takes Windows Update
# reboots. A reboot produces TWO classes of bogus failure, both infrastructure
# noise rather than code faults:
#
#   1. the in-flight job is killed outright when the VM goes down;
#   2. the job GitHub re-dispatches straight afterwards fails too, because the
#      WSL2 network stack is still settling -- in particular Docker's embedded
#      DNS resolver cannot reach its upstreams yet, so checkout reports
#      "Could not resolve host: github.com" and corepack times out on the npm
#      registry.
#
# Reference incident (2026-09-08, example-org/appone run 34279623096): three
# consecutive Windows Update reboots at 02:29-02:35 IDT killed a Build & Deploy
# that had been running since 21:16 UTC; the retry landed 8 minutes after the
# VM came back and died on DNS. Hence the post-boot watch window below -- a
# one-shot check at boot would have been too early to catch it.
#
# Auth: uses the Windows gh.exe over WSL interop, which is already signed in
# via the Windows keyring, so this needs no PAT of its own. If interop or the
# keyring is unavailable, falls back to a token in /etc/ci-rerun/token.
set -uo pipefail

CONF_DIR=/etc/ci-rerun
STATE_DIR=/var/lib/ci-rerun
STATE_FILE="$STATE_DIR/state.json"
REPOS_FILE="$CONF_DIR/repos"
TOKEN_FILE="$CONF_DIR/token"
LOG_FILE=/var/log/ci-rerun.log
GH_BIN="${CI_RERUN_GH_BIN:-/mnt/c/Program Files/GitHub CLI/gh.exe}"
# Windows-side, reached the same way as gh.exe. Used only to file the root-cause
# note into the CI day report; both are optional and failure is non-fatal.
PWSH_BIN="${CI_RERUN_PWSH_BIN:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}"
DAY_REPORT_PS1="${CI_RERUN_DAY_REPORT:-C:/Users/you/joggo/monitor/day-report.ps1}"

# What identifies work belonging to this box. A run is only ever retried if one
# of its FAILED jobs matches.
#
# Match on runner_name FIRST, not on the label set: 10 of the 12 callers use the
# SUBSET labels (self-hosted, linux, x64) with no "joggo" in them -- only
# appone and appfour spell the full set. Every job that lands here reports
# runner_name "joggo" regardless of which label set requested it, so keying on
# the name is what actually covers the fleet. The label stays as a fallback.
RUNNER_NAME="${CI_RERUN_RUNNER_NAME:-joggo}"
RUNNER_LABEL="${CI_RERUN_LABEL:-joggo}"

# How long after boot to keep watching, and how often to look. The incident's
# post-reboot failure landed ~8 min after the VM came up.
WATCH_MINUTES="${CI_RERUN_WATCH_MINUTES:-35}"
POLL_SECONDS="${CI_RERUN_POLL_SECONDS:-180}"
# Fallback lookback when the previous boot's end cannot be read from the
# journal. Windows Update can chain several reboots, so keep this generous.
PRE_MINUTES="${CI_RERUN_PRE_MINUTES:-30}"
# Safety rails: never retry the same run twice, never storm the API, and give
# up on a run that has already been attempted many times.
MAX_RERUNS_PER_PASS="${CI_RERUN_MAX:-10}"
MAX_RUN_ATTEMPTS="${CI_RERUN_MAX_ATTEMPTS:-3}"

DRY_RUN=0
ONCE=0
WINDOW_START_OVERRIDE=""
WINDOW_END_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: ci-rerun-after-reboot.sh [options]

  --once                 run a single pass instead of watching for WATCH_MINUTES
  --dry-run              report what would be re-run, change nothing
  --window-start EPOCH   override the start of the reboot window
  --window-end EPOCH     override the end of the reboot window
  -h, --help             this text

Normally invoked at boot by ci-rerun-after-reboot.service. Use --dry-run with
an explicit window to replay a past incident.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --window-start) WINDOW_START_OVERRIDE="$2"; shift 2 ;;
    --window-end) WINDOW_END_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

log() {
  local msg="[ci-rerun] $(date -Is) $*"
  echo "$msg"
  printf '%s\n' "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

# --- auth -------------------------------------------------------------------
# Prefer the Windows gh.exe (already authenticated, no secret stored on this
# box). gh.exe emits CRLF, so every call is stripped before it reaches jq.
GH_MODE=""

detect_auth() {
  if [[ -x "$GH_BIN" ]] && "$GH_BIN" auth status >/dev/null 2>&1; then
    GH_MODE=gh
    return 0
  fi
  if [[ -r "$TOKEN_FILE" ]]; then
    GH_MODE=curl
    return 0
  fi
  return 1
}

api() {
  # api <method> <path>   -- path is relative to the API root
  #
  # stdin is closed for both clients on purpose. These are called from inside
  # `while read` loops, and a client that inherits the loop's stdin will drain
  # the repo list / candidate-run list out from under it -- which silently
  # limits a pass to a single repo and a single run.
  local method="$1" path="$2"
  case "$GH_MODE" in
    gh)
      "$GH_BIN" api --method "$method" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$path" </dev/null 2>/dev/null | tr -d '\r'
      ;;
    curl)
      curl -fsSL -X "$method" \
        -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/${path#/}" </dev/null 2>/dev/null
      ;;
  esac
}

# --- window -----------------------------------------------------------------
# The window spans from the moment the previous boot ended (i.e. when the
# reboot began to take the runner down) to WATCH_MINUTES after this boot.
compute_window() {
  local boot_start prev_end_us
  boot_start=$(date -d "$(uptime -s)" +%s 2>/dev/null) || boot_start=$(date +%s)

  prev_end_us=$(journalctl --list-boots -o json 2>/dev/null \
    | jq -r '.[-2].last_entry // empty' 2>/dev/null)

  if [[ -n "$prev_end_us" && "$prev_end_us" =~ ^[0-9]+$ ]]; then
    # journal reports microseconds; step back a minute for slow shutdowns.
    WINDOW_START=$(( prev_end_us / 1000000 - 60 ))
  else
    WINDOW_START=$(( boot_start - PRE_MINUTES * 60 ))
  fi
  WINDOW_END=$(( boot_start + WATCH_MINUTES * 60 ))

  [[ -n "$WINDOW_START_OVERRIDE" ]] && WINDOW_START="$WINDOW_START_OVERRIDE"
  [[ -n "$WINDOW_END_OVERRIDE" ]] && WINDOW_END="$WINDOW_END_OVERRIDE"
}

# --- state ------------------------------------------------------------------
# One entry per run we have already retried, so a run is never retried twice
# even across reboots. Trimmed to the most recent 500 entries.
state_seen() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 1
  jq -e --arg k "$key" 'has($k)' "$STATE_FILE" >/dev/null 2>&1
}

state_record() {
  local key="$1" tmp
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || echo '{}' >"$STATE_FILE"
  tmp=$(mktemp)
  jq --arg k "$key" --arg t "$(date -Is)" \
    '. + {($k): $t} | to_entries | sort_by(.value) | .[-500:] | from_entries' \
    "$STATE_FILE" >"$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" || rm -f "$tmp"
}

# --- root-cause note --------------------------------------------------------
# day-report.ps1 renders the daily failure page and keeps operator-written
# root-cause prose in notes.json, keyed by run id. The reboot class is the one
# diagnosis a script CAN make with confidence -- this function is the same code
# that decided the run was reboot-caused -- so write it rather than leaving the
# card blank for a human to re-derive. Best-effort: never fail a retry over it.
note_run() {
  local run_id="$1" text="$2"
  [[ -x "$PWSH_BIN" && -n "$DAY_REPORT_PS1" ]] || return 0
  "$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -File "$DAY_REPORT_PS1" \
    -Note "$run_id" -Text "$text" </dev/null >/dev/null 2>&1 \
    && log "NOTE  recorded root cause for run $run_id" \
    || log "WARN  could not record root-cause note for run $run_id"
}

# --- core -------------------------------------------------------------------
# A run qualifies when it completed as a failure inside the window AND at least
# one of its FAILED jobs ran on this box. That second test is what keeps us
# from retrying genuine failures in ubuntu-latest jobs of the same workflow.
process_repo() {
  local repo="$1" runs run_id updated_at attempt jobs failed_here key

  runs=$(api GET "/repos/$repo/actions/runs?status=failure&per_page=50")
  [[ -z "$runs" ]] && { log "WARN  $repo: could not list runs"; return 0; }

  while read -r run_id updated_at attempt; do
    [[ -z "$run_id" ]] && continue
    key="$repo#$run_id"

    state_seen "$key" && continue

    if [[ "$attempt" =~ ^[0-9]+$ ]] && (( attempt >= MAX_RUN_ATTEMPTS )); then
      log "SKIP  $key: already at attempt $attempt (>= $MAX_RUN_ATTEMPTS)"
      (( DRY_RUN )) || state_record "$key"
      continue
    fi

    jobs=$(api GET "/repos/$repo/actions/runs/$run_id/jobs?per_page=100")
    failed_here=$(printf '%s' "$jobs" | jq -r --arg lbl "$RUNNER_LABEL" --arg rn "$RUNNER_NAME" \
      '[.jobs[]? | select(.conclusion=="failure")
                 | select(.runner_name == $rn or ((.labels // []) | index($lbl)))] | length' 2>/dev/null)
    [[ "$failed_here" =~ ^[0-9]+$ ]] || failed_here=0

    if (( failed_here == 0 )); then
      continue
    fi

    if (( DRY_RUN )); then
      log "DRY   would re-run $key (failed $updated_at, attempt $attempt)"
      continue
    fi

    if api POST "/repos/$repo/actions/runs/$run_id/rerun-failed-jobs" >/dev/null; then
      log "RERUN $key (failed $updated_at, attempt $attempt)"
      state_record "$key"
      note_run "$run_id" "Infrastructure, not code: the joggo host rebooted during this run (Windows Update), which kills the in-flight job and usually breaks the one GitHub re-dispatches straight after, while WSL2's network stack is still settling. Retried automatically by ci-rerun-after-reboot."
      RERUNS_THIS_PASS=$(( RERUNS_THIS_PASS + 1 ))
    else
      # Most often the run is already re-running (someone beat us to it).
      log "WARN  $key: rerun request rejected"
      state_record "$key"
    fi

    (( RERUNS_THIS_PASS >= MAX_RERUNS_PER_PASS )) && {
      log "WARN  hit MAX_RERUNS_PER_PASS=$MAX_RERUNS_PER_PASS; stopping this pass"
      return 0
    }
  done < <(printf '%s' "$runs" | jq -r \
      --argjson ws "$WINDOW_START" --argjson we "$WINDOW_END" '
      .workflow_runs[]?
      | select(.status == "completed" and .conclusion == "failure")
      | select((.updated_at | fromdateiso8601) >= $ws)
      | select((.updated_at | fromdateiso8601) <= $we)
      | "\(.id) \(.updated_at) \(.run_attempt // 1)"' 2>/dev/null)
}

main() {
  mkdir -p "$STATE_DIR" "$CONF_DIR"
  touch "$LOG_FILE" 2>/dev/null || true

  if [[ ! -r "$REPOS_FILE" ]]; then
    log "ERROR $REPOS_FILE missing; nothing to watch"
    exit 0
  fi

  # At boot the network, WSL interop and the Windows keyring all come up on
  # their own schedule, so give auth a few minutes before giving up. This is
  # also the de facto "wait until the box is really back" gate.
  local auth_deadline=$(( $(date +%s) + 600 ))
  until detect_auth; do
    if (( $(date +%s) >= auth_deadline )); then
      log "ERROR no usable GitHub auth after 10m: gh.exe interop failed and $TOKEN_FILE is absent"
      exit 0
    fi
    sleep 15
  done

  compute_window
  log "start mode=$GH_MODE window=$(date -d "@$WINDOW_START" -Is)..$(date -d "@$WINDOW_END" -Is) dry_run=$DRY_RUN"

  local deadline
  deadline="$WINDOW_END"

  while :; do
    RERUNS_THIS_PASS=0
    while read -r repo; do
      [[ -z "$repo" || "$repo" == \#* ]] && continue
      process_repo "$repo"
    done <"$REPOS_FILE"

    (( ONCE )) && break
    (( $(date +%s) >= deadline )) && break
    sleep "$POLL_SECONDS"
  done

  log "done"
}

main
