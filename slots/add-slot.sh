#!/usr/bin/env bash
# add-ci-slot.sh — prepare a second (or third) containerized runner slot.
#
# WHY THIS EXISTS. `joggo-slot@.service` is a template and nearly everything in
# run-containerized-slot.sh is already keyed on the slot number — the network,
# both container names, both volumes, the _diag directory, the pause flag and the
# fail stamp. Exactly ONE thing is not: RUNNER_ROOT, which defaults to
# /home/ghrunner/actions-runner for every instance.
#
# That single shared default is the whole problem. A GitHub runner registration
# holds exactly ONE session, so two slots pointed at one .credentials do not run
# two jobs — the second loses the session and retries roughly every 95 seconds,
# forever. The launcher's own preflight says it out loud: "this slot reuses the
# EXISTING registration". A real second slot therefore needs a second runner root
# with its OWN registration, and a per-instance drop-in pointing at it.
#
# WHAT THIS SCRIPT DOES (and deliberately does not do):
#   - copies the runner install to /home/ghrunner/actions-runner-<N>
#   - strips the copied credentials, because a copied credential set IS the same
#     registration and would reproduce the bug this script exists to avoid
#   - writes /etc/systemd/system/joggo-slot@<N>.service.d/root.conf
#   - prints the exact config.sh line to run next
#
#   - it does NOT register the runner. That needs an org registration token which
#     expires in ~1 hour and must never be stored on this box (setup-ci-runner §6),
#     so a human mints it and runs one command. See the printed instructions.
#   - it does NOT start the slot. You start it after registering, so the first
#     acquisition is something you watch rather than something you discover.
#
# Usage:
#   sudo slots/add-slot.sh 2            # prepare slot 2
#   sudo slots/add-slot.sh 2 --force    # prepare it even with a job in flight
#   sudo slots/add-slot.sh 2 --undo     # remove the root and the drop-in
#
# Exit codes: 0 ok, 2 bad usage, 3 refused (job in flight, or already prepared).

set -uo pipefail

SLOT="${1:-}"
FORCE=0
UNDO=0
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --undo)  UNDO=1;  shift ;;
    *) echo "add-ci-slot: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$SLOT" in
  ''|*[!0-9]*) echo "usage: add-ci-slot.sh <slot-number> [--force|--undo]" >&2; exit 2 ;;
  1) echo "add-ci-slot: slot 1 is the existing runner root; this script is for ADDITIONAL slots" >&2; exit 2 ;;
esac

SRC="/home/ghrunner/actions-runner"
DST="/home/ghrunner/actions-runner-${SLOT}"
DROPIN_DIR="/etc/systemd/system/joggo-slot@${SLOT}.service.d"
DROPIN="$DROPIN_DIR/root.conf"
RUNNER_USER="${RUNNER_USER:-ghrunner}"

die()  { echo "add-ci-slot: $*" >&2; exit "${2:-2}"; }
say()  { echo "[add-ci-slot] $*"; }

[ "$(id -u)" = "0" ] || die "run as root (sudo)" 2

# ---- undo -------------------------------------------------------------------
if [ "$UNDO" = "1" ]; then
  if systemctl is-active --quiet "joggo-slot@${SLOT}.service"; then
    die "joggo-slot@${SLOT} is ACTIVE — 'systemctl disable --now joggo-slot@${SLOT}' first" 3
  fi
  say "removing $DROPIN_DIR"
  rm -rf "$DROPIN_DIR"
  systemctl daemon-reload
  if [ -d "$DST" ]; then
    say "removing $DST"
    say "NOTE: this de-registers nothing server-side. Remove the 'joggo-${SLOT}' runner"
    say "      in the GitHub org settings too, or it lingers as an offline entry."
    rm -rf "$DST"
  fi
  say "undone. Slot 1 was never touched."
  exit 0
fi

# ---- guards -----------------------------------------------------------------
# A ~450MB copy is real IO, and this box is IO-bound: measured 30-40% of tasks
# stalled on IO with a SINGLE job running. Doing it under a live job slows that
# job and, worse, lengthens the queue for anything waiting behind it — which is
# how jobs get dropped here.
if [ "$FORCE" != "1" ] && ps -eo cmd | grep -qa '[R]unner.Worker'; then
  die "a job is in flight — wait for 'ci-pause status' to read 'job in flight: none', or pass --force" 3
fi

[ -d "$SRC" ] || die "source runner root $SRC does not exist" 2
for f in .runner .credentials; do
  [ -r "$SRC/$f" ] || die "$SRC/$f missing — slot 1 is not registered; fix that first" 2
done

if [ -r "$DST/.credentials" ]; then
  die "$DST is already registered — nothing to do (use --undo to start over)" 3
fi

# ---- 1. the runner root -----------------------------------------------------
if [ -d "$DST" ]; then
  say "$DST already exists, reusing it (no re-copy)"
else
  say "copying $SRC -> $DST (bin/ and externals/ are version-stamped symlinks the"
  say "launcher resolves and bind-mounts at their own absolute paths, so each slot"
  say "needs its own copy rather than a shared one)"
  # EXCLUDE _work and _diag. They belong to the OTHER slot: _work holds its old job
  # checkouts and on a long-lived root runs to gigabytes, _diag its logs. Copying
  # them and deleting them afterwards is what a naive `cp -a` does, and on this
  # IO-bound box that cost 17 minutes and 1.2GB of pointless writes on 2026-09-29
  # before this exclusion existed. tar, not cp, because cp cannot exclude.
  mkdir -p "$DST" || die "could not create $DST" 3
  tar -C "$SRC" --exclude=./_work --exclude=./_diag -cf - .     | tar -C "$DST" -xpf - || die "copy failed" 3
fi

# A copied credential set is the SAME registration. Removing these is the point.
# .runner_migrated and .service matter just as much: config.sh treats EITHER as
# "already configured" and refuses to register, which is how this failed on
# 2026-09-29 with a root that had no .credentials at all.
for f in .runner .credentials .credentials_rsaparams .runner_migrated .service; do
  rm -f "$DST/$f"
done

# REPOINT bin/ and externals/. They are symlinks with ABSOLUTE targets under the
# SOURCE root, so a copy leaves slot 2 pointing at slot 1's directories. That is
# not cosmetic: config.sh then executes slot 1's binaries, which resolve slot 1's
# config and report "already configured" (2026-09-29), and the launcher would
# bind-mount slot 1's paths into slot 2's containers.
# Paths are written INLINE. A bare VAR=... assignment inside `wsl ... bash -c` can
# arrive EMPTY, and on 2026-09-29 that turned `ln -sfn $D/bin.2.337.0 $D/bin` into
# `ln -sfn /bin.2.337.0 /bin`, replacing the system /bin and breaking the VM.
for link in bin externals; do
  target="$(readlink "$SRC/$link" 2>/dev/null)" || continue
  base="$(basename "$target")"                 # e.g. bin.2.337.0
  if [ -d "$DST/$base" ]; then
    ln -sfn "$DST/$base" "$DST/$link"
    chown -h "$RUNNER_USER:$RUNNER_USER" "$DST/$link"
    say "repointed $link -> $DST/$base"
  else
    die "$DST/$base missing — cannot repoint $link (copy incomplete?)" 3
  fi
done
# Belt and braces: _work is excluded from the copy above, but an earlier prepared
# root (or a --force re-run) may still have one, and it is never ours to keep.
rm -rf "$DST/_work"
chown -R "$RUNNER_USER:$RUNNER_USER" "$DST" || die "chown failed" 3
say "runner root ready at $DST (unregistered, by design)"

# ---- 2. the per-instance drop-in -------------------------------------------
# Per-INSTANCE, not on the template: slot 1 keeps its existing path untouched,
# so this change cannot affect the runner that is currently serving.
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<EOF
# Generated by slots/add-slot.sh — points THIS instance at its own runner
# root, so it uses its own registration instead of fighting slot 1 for one
# session. Slot 1 keeps the launcher's default (/home/ghrunner/actions-runner).
[Service]
Environment=RUNNER_ROOT=${DST}
EOF
systemctl daemon-reload
say "wrote $DROPIN"

# ---- 3. what a human has to do next ----------------------------------------
cat <<EOF

================ NEXT: register it (this part is yours) ================

The token expires in about an hour and must not be stored on this box, so it is
minted by a person and used immediately:

  1. Mint a registration token (org admin):
     https://github.com/organizations/example-org/settings/actions/runners/new

  2. Register, AS ${RUNNER_USER} (not root):

     sudo -u ${RUNNER_USER} bash -c 'cd ${DST} && ./config.sh \\
       --url https://github.com/example-org \\
       --token <TOKEN> \\
       --name joggo-${SLOT} \\
       --labels self-hosted,linux,x64,joggo \\
       --unattended'

     SAME labels, so GitHub dispatches the same jobs to it.
     DIFFERENT name. Do NOT pass --replace: that would take over slot 1's
     identity and leave you with one runner again.

  3. Start it and watch the first acquisition:

     systemctl enable --now joggo-slot@${SLOT}
     journalctl -u joggo-slot@${SLOT}.service -f

  4. Prove it is real parallelism, not two runners trading one session:

     gh workflow run runner-smoke.yml --repo example-org/joggo
     gh workflow run runner-smoke.yml --repo example-org/joggo
     # both should run AT THE SAME TIME, on joggo and joggo-${SLOT}

Rollback is one command and slot 1 is untouched throughout:

     systemctl disable --now joggo-slot@${SLOT}
     sudo slots/add-slot.sh ${SLOT} --undo

========================================================================
EOF
exit 0
