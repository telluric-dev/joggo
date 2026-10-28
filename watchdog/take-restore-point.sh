#!/usr/bin/env bash
#
# take-restore-point.sh — capture a RESTORABLE snapshot of the joggo runner.
#
# WHY THIS EXISTS. Three git tags (v1.0.0, v1.1.0, v2.0.0) were created so the runner
# would be "easy to restore", and none of them can do it. A tag captures THIS REPO. The
# thing that actually runs is a machine: a registration bound to this host, systemd units,
# the launcher scripts in /usr/local/sbin, and a locally-built runner image that exists in
# no registry. Restoring from a tag means re-running setup and re-registering — which is a
# rebuild, not a rollback. That gap was recorded as finding A8 on 2026-09-03 and was still
# open three days and one architecture change later. This closes it.
#
# WHAT IT CAPTURES
#   /home/ghrunner/actions-runner   minus _work and _diag  (the registration + binaries)
#   /etc/systemd/system/            the units, drop-ins and timers that drive it
#   /usr/local/sbin/                the launcher, watchdog and pause scripts
#   /etc/chrony/                    layer-1 self-heal config
#   MANIFEST.txt                    versions, unit states, image ids, and the restore steps
#
# WHAT IT DELIBERATELY DOES NOT CAPTURE
#   _work   — throwaway by design since the containerized cutover; 4.3G of pre-cutover
#             workspace that nothing reads any more. Restoring it would restore the exact
#             root-owned poisoning this architecture was built to end.
#   _diag   — logs, not state.
#   the runner image — rebuildable from tools/runner-image/Dockerfile, and reproducing it
#             is a documented one-liner in the MANIFEST. A 700MB image layer in a secret
#             tarball is a poor trade for a `docker build`.
#
# *** THIS TARBALL CONTAINS RUNNER CREDENTIALS ***
# .credentials and .credentials_rsaparams authenticate as this runner to the example-org
# org. The registration is NOT ephemeral, so they stay valid until someone removes the
# runner in GitHub's UI. Treat the file as a secret: it is written 0600, it must never be
# committed, and it should not sit on shared storage.
#
# USAGE
#   ./take-restore-point.sh                 # -> /mnt/c/Users/you/joggo-restore/
#   ./take-restore-point.sh /some/other/dir
#   VERIFY_ONLY=1 ./take-restore-point.sh   # list what would be captured, write nothing
#
# Run as root. Safe to run with the slot live: it reads only, and the runner root is not
# modified by a running job (the job writes to a container volume, not here).
set -uo pipefail

DEST="${1:-/mnt/c/Users/you/joggo-restore}"
RUNNER_ROOT="${RUNNER_ROOT:-/home/ghrunner/actions-runner}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="$DEST/joggo-restore-${STAMP}.tar.gz"
MANIFEST="$DEST/joggo-restore-${STAMP}.MANIFEST.txt"

die() { echo "[restore-point] FATAL: $*" >&2; exit 1; }
log() { echo "[restore-point] $*"; }

[ "$(id -u)" = "0" ] || die "must run as root (needs to read .credentials and /etc)"
[ -d "$RUNNER_ROOT" ] || die "no runner root at $RUNNER_ROOT"
for f in .runner .credentials .credentials_rsaparams; do
    [ -r "$RUNNER_ROOT/$f" ] || die "missing $RUNNER_ROOT/$f — this would be a useless restore point"
done

if [ "$VERIFY_ONLY" = "1" ]; then
    log "VERIFY_ONLY — would write $OUT"
    du -sh --exclude=_work --exclude=_diag "$RUNNER_ROOT"
    exit 0
fi

mkdir -p "$DEST" || die "cannot create $DEST"

# Build the manifest FIRST, so it describes the box as it was at capture time and travels
# inside the tarball as well as beside it. A snapshot nobody knows how to restore is not a
# restore point — that is the whole lesson of A8.
{
    echo "joggo runner restore point"
    echo "captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)  host: $(hostname)"
    echo
    echo "== runner =="
    echo "version:  $(cat "$RUNNER_ROOT"/bin/../*.version 2>/dev/null || readlink -f "$RUNNER_ROOT/bin")"
    echo "agent:    $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["agentName"])' "$RUNNER_ROOT/.runner" 2>/dev/null || grep -o '"agentName"[^,]*' "$RUNNER_ROOT/.runner" 2>/dev/null)"
    echo "repo url: $(grep -o '"gitHubUrl"[^,]*' "$RUNNER_ROOT/.runner" 2>/dev/null)"
    echo
    echo "== units =="
    for u in joggo-slot@1.service actions.runner.example-org.joggo.service runner-watchdog.timer runner-watchdog.service; do
        printf '%-48s %s / %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)" "$(systemctl is-enabled "$u" 2>/dev/null)"
    done
    echo
    echo "== scripts (md5) =="
    md5sum /usr/local/sbin/run-containerized-slot.sh /usr/local/sbin/runner-watchdog.sh \
           /usr/local/sbin/joggo-pause.sh 2>/dev/null
    echo
    echo "== images =="
    docker image inspect joggo/actions-runner:local --format '{{.RepoTags}} {{.Id}}' 2>/dev/null || echo "runner image ABSENT"
    docker image inspect docker:28-dind --format '{{.RepoTags}} {{.Id}}' 2>/dev/null || echo "dind image ABSENT"
    echo
    cat <<'RESTORE'
== HOW TO RESTORE ==

This restores the RUNNING MACHINE. Pair it with the matching git tag for the repo side.

  1. Stop whatever is live, so nothing fights for the registration:
       systemctl disable --now joggo-slot@1.service
       systemctl stop actions.runner.example-org.joggo.service

  2. Unpack (paths inside are absolute; -C / is intentional):
       tar -xzpf joggo-restore-<stamp>.tar.gz -C /

  3. Rebuild the runner image — it is deliberately NOT in this tarball:
       docker build -t joggo/actions-runner:local <repo>/tools/runner-image

  4. Reload and start the shape you want:
       systemctl daemon-reload
       systemctl enable --now joggo-slot@1.service          # containerized (current)
     or, to fall back to the pre-cutover persistent runner:
       systemctl enable --now actions.runner.example-org.joggo.service

  5. Verify it is actually taking jobs — an active unit is not proof:
       runner-watchdog.sh --check
       journalctl -u joggo-slot@1.service -f | grep 'Listening for Jobs'

IF THE REGISTRATION WAS REMOVED IN GITHUB'S UI while this snapshot sat on the shelf, the
credentials in it are dead and no amount of unpacking will help. That is the one failure
this cannot cover, and it is the argument for re-taking a restore point after any change
to the runner in GitHub's settings.
RESTORE
} > "$MANIFEST" 2>/dev/null

log "capturing (this reads ~1.4G and compresses it; expect a minute or two)"
# THE EXCLUDES MUST BE RELATIVE, because -C / makes every member relative
# (home/ghrunner/... with no leading slash) and tar matches --exclude against the member
# name, not the filesystem path. Writing --exclude=/home/ghrunner/actions-runner/_work
# looks obviously correct and silently matches NOTHING: the first attempt on 2026-09-07
# archived the full 5.7G including 4.3G of _work, ran for 25 minutes, and pushed the box
# hard enough that WSL stopped accepting new interop sessions.
# Verify with:  tar -tzf <archive> | grep -c '_work/'   -> must be 0
#
# nice/ionice, because this shares a box with CI and with the user's dev databases. The
# 2026-09-07 run at full tilt starved the VM badly enough that WSL refused new interop
# sessions for ~30 minutes (Wsl/Service/0x8007274c) while already-running containers kept
# serving. Nothing was lost, but a backup that takes the box out is not a backup.
nice -n 19 ionice -c3 \
tar -czpf "$OUT" \
    --exclude="${RUNNER_ROOT#/}/_work" \
    --exclude="${RUNNER_ROOT#/}/_diag" \
    --warning=no-file-changed \
    -C / \
    "${RUNNER_ROOT#/}" \
    etc/systemd/system \
    usr/local/sbin \
    etc/chrony \
    2>/dev/null
rc=$?
# tar exits 1 for "file changed as we read it", which is routine on a live box and is not a
# corrupt archive. Only 2 means it actually failed.
[ "$rc" -ge 2 ] && die "tar failed (rc=$rc)"

# The manifest stays a SIDECAR. An earlier cut tried to append it into the archive with
# `tar -rf ${OUT%.gz}` — but you cannot append to a gzipped archive, and that expression
# names a .tar file that does not exist, so tar would have quietly created a second stray
# archive containing nothing but the manifest. Keep the two files together instead; they
# share a timestamp in their names for exactly that reason.

chmod 0600 "$OUT" "$MANIFEST"
log "wrote $OUT ($(du -h "$OUT" | cut -f1)) — CONTAINS CREDENTIALS"
log "wrote $MANIFEST"

# THE chmod ABOVE IS A LIE ON /mnt/c. DrvFs ignores Unix modes: the same file that reports
# 0600 from Linux lists as -rwxrwxrwx, and the archive holds credentials that authenticate
# as this runner to the whole org. Verified 2026-09-07. Permissions have to be set on the
# Windows side, so say so rather than letting a green chmod imply the file is protected.
case "$DEST" in
  /mnt/*)
    log "WARNING: $DEST is a Windows drive — DrvFs IGNORES the chmod above; this file is"
    log "         effectively world-readable and it contains runner credentials. Run, in PowerShell:"
    log "         icacls \"\$env:USERPROFILE\\joggo-restore\" /inheritance:r /grant:r \"\$env:USERNAME:(OI)(CI)F\" /grant:r \"SYSTEM:(OI)(CI)F\" /T"
    ;;
esac

log "verifying the archive holds what makes it a restore point:"
listing="$(tar -tzf "$OUT" 2>/dev/null)" || die "archive is not readable"
grep -E '(\.credentials$|\.runner$|joggo-slot@\.service|run-containerized-slot\.sh|runner-watchdog\.sh)' \
    <<<"$listing" | sed 's/^/    /'

# NEVER `echo "$listing" | grep -q ...` HERE. Under `set -o pipefail` that construct reports
# FAILURE on a SUCCESSFUL match: grep -q exits the instant it matches, echo is still writing,
# takes SIGPIPE, exits 141, and pipefail promotes that to the pipeline's status. The first cut
# did exactly this and aborted with "archive is missing \.credentials$" one line after
# printing home/ghrunner/actions-runner/.credentials from the very same listing.
#
# What makes it worth a comment is that IT PASSES ON SMALL INPUTS. If the whole listing fits
# in the 64K pipe buffer, echo finishes before grep exits and nothing is signalled — so a
# toy reproduction says the code is fine. Measured 2026-09-07:
#     seq 1 200000 | ... grep -q '^1$'       -> rc=141   (early match, big input)
#     seq 1 200000 | ... grep -q '^200000$'  -> rc=0     (match on the last line)
#     3-line input, any match                -> rc=0
# This archive lists ~30k entries and .credentials sits near the front: worst case for it.
# A here-string has no pipeline, so there is nothing to be killed by an early exit.
for must in '\.credentials$' '\.runner$' 'joggo-slot@\.service'; do
    grep -qE "$must" <<<"$listing" || die "archive is missing $must — not a restore point"
done

# The exclude bug was invisible to every other check: the archive was valid, readable, and
# held the registration — it was simply four times too big. Assert the exclusion directly.
leaked="$(grep -cE '/_work/|/_diag/' <<<"$listing" || true)"
[ "${leaked:-0}" = "0" ] || die "archive leaked $leaked _work//_diag entries — the --exclude patterns did not match"
log "OK: no _work or _diag entries, registration present."
