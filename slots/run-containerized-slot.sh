#!/usr/bin/env bash
#
# run-containerized-slot.sh — run ONE job in a throwaway containerized runner.
#
# WHAT THIS BUYS (and what it deliberately does not)
# --------------------------------------------------
# The exposure it closes: on the persistent runner, jobs execute as `ghrunner`, the
# same uid that OWNS /home/ghrunner/actions-runner. So any job can overwrite the
# runner's binaries, read its credentials, or write .env to install an
# ACTIONS_RUNNER_HOOK_* that then runs for every future job of every repo. That
# persistence lives OUTSIDE _work, so no amount of workspace cleanup touches it.
#
# Here the runner install is read-only to the job and it gets a fresh _work volume that
# is destroyed on exit. A job cannot modify the runner, cannot keep its credentials, and
# cannot leave anything for the next job. (_diag is the one deliberate exception — it is
# host-side so the monitor and watchdog can read it; see DIAG_DIR below.)
#
# It does NOT use --ephemeral, so it needs NO GitHub App and NO token minting: the
# existing registration is reused. What you give up versus ephemeral registration is
# auto-de-registration, and the fact that a stolen .credentials keeps working. See
# the "right column" table in the hardening plan.
#
# ONE JOB PER CONTAINER via `run.sh --once`. The runner takes a single job, exits
# cleanly (releasing its GitHub session — this matters, see SESSION CONFLICT below),
# the container and its volumes are destroyed, systemd starts a fresh one.
#
# MUTUAL EXCLUSION. One registration = one session. This CANNOT run alongside
# actions.runner.example-org.joggo.service — the second one to connect loses with
# "A session for this runner already exists". The unit enforces this with Conflicts=.
#
# SESSION CONFLICT. Measured 2026-09-04: after an UNCLEAN stop, GitHub holds the old
# session and the next connect retries for ~95s. A clean `--once` exit releases it, so
# normal turnover does not pay that cost. Abrupt kills do.
#
# WHY dind AND NOT THE HOST SOCKET. Mounting /var/run/docker.sock into the runner is
# root-equivalent on the box and shares one image store and build cache across every
# repo. Each slot gets its own daemon instead; the socket the runner hands to job
# containers then resolves to the SLOT's daemon, so container jobs keep working and
# lose host access as a side effect (spike check D).
#
# PATHS MUST MATCH IN BOTH CONTAINERS. The runner asks its daemon to bind-mount
# ABSOLUTE HOST PATHS into job containers. That daemon is the slot's dind, which
# resolves them on ITS OWN filesystem. So dind must see the runner root and _work at
# byte-identical paths, or job containers silently come up with an empty workspace
# (spike check A — the dind helpfully creates the missing mount sources).
#
# USAGE
#   ./run-containerized-slot.sh <slot>     # runs one job, then exits
#   PULL_ONLY=1 ./run-containerized-slot.sh 1   # pre-pull images, verify, exit
#   DRY_RUN=1  ./run-containerized-slot.sh 1    # print the plan, touch nothing
#
# PAUSE. If /var/lib/ci-slot/<slot>.paused exists this script holds instead of starting a
# listener — no containers at all. See slots/slot-pause.sh; that flag path is the contract.
set -uo pipefail

SLOT="${1:-1}"
RUNNER_ROOT="${RUNNER_ROOT:-/home/ghrunner/actions-runner}"
# Thin ORG image, not the upstream one: see tools/runner-image/Dockerfile. The stock
# ghcr.io/actions/actions-runner lacks libatomic1 (every pnpm repo fails), zstd
# (actions/cache) and git-lfs — all of which the persistent host runner had for free.
# Build with: docker build -t joggo/actions-runner:local tools/runner-image
RUNNER_IMAGE="${RUNNER_IMAGE:-joggo/actions-runner:local}"
DIND_IMAGE="${DIND_IMAGE:-joggo/dind:local}"
NET="joggo-slot-$SLOT"
RUNNER_C="joggo-runner-$SLOT"
DIND_C="joggo-dind-$SLOT"
# The slot's PINNED subnet. Deterministic so a recreate cannot hand a job a different range,
# and so slot 1 and slot 2 can never swap (they did, between 2026-10-05 and 10-06, which is why
# the same fault looked like it moved between slots).
#
# 10.201.x is outside Docker's default pool and free on this box - the host sits on
# 172.24.224.0/20, docker0 on 172.17, and Tailscale routes only 100.100.100.100. Picking inside
# the default pool would risk a future auto-created network overlapping it.
SLOT_SUBNET="10.201.$SLOT.0/24"
SLOT_GATEWAY="10.201.$SLOT.1"
WORK_VOL="joggo-slot-${SLOT}-work"
ROOT_VOL="joggo-slot-${SLOT}-root"
# _diag is the ONE deliberate exception to "nothing survives a job boundary". It is
# bind-mounted to the HOST, not a throwaway volume, because two things depend on those
# logs OUTSIDE the container:
#   * deploy-monitor.ps1 recovers repo / run id / workflow name / the planId that groups
#     jobs into a deploy from _diag/Worker_*.log — the journal alone carries none of it.
#   * the wedge watchdog detects a hung listener from _diag/Runner_*.log mtime.
# With _diag in a volume both go blind: the control plane showed no card at all for
# appthree on 2026-09-05. Logs are not a poisoning vector, so the trade is worth
# it — but it IS a deliberate exception, not an oversight.
DIAG_DIR="${DIAG_DIR:-/var/log/joggo-slots/${SLOT}/_diag}"
DRY_RUN="${DRY_RUN:-0}"
PULL_ONLY="${PULL_ONLY:-0}"

log() { echo "[slot $SLOT] $*"; }

# Backoff on FAILURE only — and it lives HERE, not in the unit, because only this script knows
# the difference between "took a job, finished, exiting cleanly" (restart immediately: that is
# normal turnover) and "could not start" (back off: something is wrong).
#
# systemd's RestartSteps cannot make that distinction. Using it added a 5-minute delay before
# every job on 2026-09-06, because with --once every SUCCESS drives the restart counter.
#
# The counter is a file so it survives the process; a successful run clears it. Escalates
# 0s -> 15s -> 30s -> 60s -> 120s (capped), so a genuinely broken box settles at ~30 attempts
# an hour instead of hammering the GitHub API, while a healthy one pays nothing.
FAILSTAMP="${FAILSTAMP:-/var/lib/ci-slot/${SLOT}.fails}"
die() {
    log "FATAL: $*"
    local n=0
    [ -r "$FAILSTAMP" ] && n="$(cat "$FAILSTAMP" 2>/dev/null || echo 0)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    n=$((n+1))
    mkdir -p "$(dirname "$FAILSTAMP")" 2>/dev/null
    echo "$n" > "$FAILSTAMP" 2>/dev/null
    local wait=0
    case "$n" in 1) wait=0 ;; 2) wait=15 ;; 3) wait=30 ;; 4) wait=60 ;; *) wait=120 ;; esac
    if [ "$wait" -gt 0 ]; then
        log "consecutive failure #$n — sleeping ${wait}s before exiting so systemd does not hot-loop"
        sleep "$wait"
    fi
    exit 1
}
clear_failures() { rm -f "$FAILSTAMP" 2>/dev/null || true; }

# --- pause ------------------------------------------------------------------
# The operator lever for "give me the RAM back for a while" (slots/slot-pause.sh). Read
# BEFORE preflight and before anything is built, so a hold costs one bash and one sleep:
# no runner container, no dind, no volumes, no job.
#
# It deliberately does NOT stop the unit. Holding inside the launcher keeps joggo-slot@N
# active, so resume is just an rm of the flag and the next poll picks a job up; and
# Restart=always never fights it, because there is no exit to restart.
#
# Nothing is lost by holding. The registration stays (this slot is not --ephemeral), so
# GitHub keeps queueing runs against joggo and hands them over oldest-first on resume.
# GitHub does expire a queued job after 24h, which makes this an afternoon lever rather
# than a weekend one — see the header of ci-pause.sh.
PAUSE_FLAG="${PAUSE_FLAG:-/var/lib/ci-slot/${SLOT}.paused}"
PAUSE_POLL="${PAUSE_POLL:-10}"
hold_while_paused() {
    [ -e "$PAUSE_FLAG" ] || return 0
    log "PAUSED — $(head -1 "$PAUSE_FLAG" 2>/dev/null || echo 'no reason recorded')"
    log "holding: no listener, no dind, no volumes. Resume with: ci-pause resume"
    local waited=0
    while [ -e "$PAUSE_FLAG" ]; do
        sleep "$PAUSE_POLL"
        waited=$((waited + PAUSE_POLL))
        # One line an hour. Enough to prove in the journal that the silence is deliberate
        # and not a wedged listener, without burning the log down.
        [ $((waited % 3600)) -lt "$PAUSE_POLL" ] && log "still paused (${waited}s)"
    done
    log "resumed after ${waited}s — starting a listener"
}

# --- teardown ---------------------------------------------------------------
# The spike flagged that appfour's §4.1 sketch removes containers and the network but
# NOT volumes — and AC-4 asks specifically about volumes. The box was carrying 70
# orphaned volumes / 12.79GB from exactly that omission before it was cleaned up on
# 2026-09-05. Volumes are in the trap.
# Remove this slot's leftover docker objects from an unclean previous run. Runs BEFORE anything
# is created. A running container is NOT debris — that means a second instance of this slot is
# live, which is a real conflict and must stay fatal rather than being force-killed underneath.
reclaim_stale() {
    local c st attached
    for c in "$RUNNER_C" "$DIND_C"; do
        docker inspect "$c" >/dev/null 2>&1 || continue
        st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo unknown)"
        if [ "$st" = "running" ]; then
            die "container $c is already RUNNING — another slot instance is live; refusing to remove it"
        fi
        log "reclaiming stale container $c (status=$st) from a previous run that did not clean up"
        docker rm -f -v "$c" >/dev/null 2>&1 || die "could not remove stale container $c"
    done
    # THE NETWORK IS NOW PERSISTENT and is deliberately NOT removed here. An existing network
    # with the right subnet is the normal, healthy case - reusing it is the whole point of
    # pinning. Only two things still justify removing one:
    #   * it carries the WRONG subnet, which means it predates the pin and has to be migrated;
    #   * nothing else. A network with containers attached still means a live sibling.
    if docker network inspect "$NET" >/dev/null 2>&1; then
        attached="$(docker network inspect "$NET" --format '{{len .Containers}}' 2>/dev/null || echo 0)"
        if [ "${attached:-0}" -gt 0 ]; then
            die "network $NET exists and has $attached container(s) attached — refusing to touch it"
        fi
        have_subnet="$(docker network inspect "$NET" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)"
        if [ "$have_subnet" != "$SLOT_SUBNET" ]; then
            log "network $NET has subnet ${have_subnet:-none}, want $SLOT_SUBNET — recreating it once to migrate"
            docker network rm "$NET" >/dev/null 2>&1 || die "could not remove mis-subnetted network $NET"
        fi
    fi
}

cleanup() {
    local rc=$?
    log "teardown"
    # -v IS LOAD-BEARING. docker:dind declares `VOLUME /var/lib/docker` in its image, so every
    # dind container gets an ANONYMOUS volume holding the slot's entire image store. `docker rm`
    # without -v leaves it behind, and nothing else ever references it again.
    #
    # This is the same leak that was "fixed" on 2026-09-05 after 70 volumes / 12.79GB had
    # accumulated: that fix added the two NAMED volumes below and missed the anonymous one,
    # which is the big one. Measured 2026-09-08, three days later: 189 orphans / 34GB, one per
    # job. `docker rm -v` removes anonymous volumes only and leaves named volumes alone, so the
    # explicit removal below is still required — the two are not redundant.
    docker rm -f -v "$RUNNER_C" "$DIND_C" >/dev/null 2>&1 || true
    # THE NETWORK SURVIVES THE JOB, deliberately. Removing it here is what produced the fault on
    # board C-c72/C-c73: bridges churned on every job and a job starting mid-cycle was handed one
    # whose route was still linkdown. A bridge holds no job state - isolation comes from the
    # fresh image store and the fresh _work volume, both still destroyed below - so keeping it
    # costs nothing and removes the race. It is reclaimed at the next start if its subnet is
    # ever wrong, and `ci-pause` users can still remove it by hand.
    # NB: DIAG_DIR is host-side and deliberately NOT removed — see its declaration.
    docker volume  rm "$WORK_VOL" "$ROOT_VOL" >/dev/null 2>&1 || true
    # Legacy: _diag used to be a per-slot VOLUME before it moved to a host bind on 2026-09-05.
    # The rename left joggo-slot-N-diag behind with nothing referencing it, and no code path that
    # would ever remove it. Sweep it once here; it is a no-op on every box that never had one.
    docker volume  rm "joggo-slot-${SLOT}-diag" >/dev/null 2>&1 || true
    exit "$rc"
}

preflight() {
    command -v docker >/dev/null 2>&1 || die "docker not on PATH"
    docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon"
    [ -d "$RUNNER_ROOT" ] || die "runner root $RUNNER_ROOT does not exist"
    for f in .runner .credentials .credentials_rsaparams; do
        [ -r "$RUNNER_ROOT/$f" ] || die "missing $RUNNER_ROOT/$f — this slot reuses the EXISTING registration"
    done
    # bin/ and externals/ are SYMLINKS to version-stamped directories (bin.2.337.0,
    # externals.2.337.0). Resolve them rather than hardcoding, so a runner self-update
    # doesn't silently break the mounts. Both are bind-mounted read-only at their own
    # absolute paths, because the copied symlinks in the root volume point there.
    BIN_DIR="$(readlink -f "$RUNNER_ROOT/bin" 2>/dev/null)"
    EXT_DIR="$(readlink -f "$RUNNER_ROOT/externals" 2>/dev/null)"
    [ -d "$BIN_DIR" ] || die "cannot resolve $RUNNER_ROOT/bin"
    [ -d "$EXT_DIR" ] || die "cannot resolve $RUNNER_ROOT/externals"
    # One registration, one session. Refuse to fight the host service.
    # DRY_RUN / PULL_ONLY never connect to GitHub, so they are safe to run while the
    # persistent runner is live — that is the whole point of being able to rehearse
    # this before the cutover.
    if [ "$DRY_RUN" != "1" ] && [ "$PULL_ONLY" != "1" ] \
       && systemctl is-active --quiet actions.runner.example-org.joggo.service 2>/dev/null; then
        die "actions.runner.example-org.joggo.service is ACTIVE — it holds the session. Stop it first (this is the cutover)."
    fi
    # Layer 1 still matters: a skewed clock breaks the runner's OAuth, and here it
    # would break it once per job instead of once.
    if command -v chronyc >/dev/null 2>&1; then
        local off
        off="$(chronyc tracking 2>/dev/null | awk -F': *' '/System time/{print $2+0}')"
        # NAME THE HOST. On WSL2 the guest clock is slaved to Windows: chrony steps it and the
        # hypervisor puts it straight back, so a persistent offset here is almost always the
        # WINDOWS clock, and layer 1 (makestep) cannot win however it is tuned. Measured
        # 2026-09-19 after a hard reset: w32time had never synced (Source: Local CMOS Clock) and
        # ran 14.4s slow, while chrony was healthy with sources at microsecond offsets. The old
        # message said only "would fail auth", which sent the operator hunting inside WSL.
        awk -v o="${off:-0}" 'BEGIN{exit (o<0?-o:o) > 5 ? 0 : 1}' \
            && die "clock is ${off}s off NTP - refusing to start (would fail auth and hot-loop).
       On WSL2 the guest clock follows the WINDOWS clock, so check the host FIRST:
         w32tm /query /status     (Source: Local CMOS Clock, or 'not synchronized' == this fault)
       Fix it in an ELEVATED PowerShell:
         w32tm /config /update; Restart-Service W32Time; w32tm /resync /force
       WSL follows within a poll and this slot starts itself on the next restart."
    fi
}

plan() {
    cat <<EOF
  runner image : $RUNNER_IMAGE
  dind image   : $DIND_IMAGE   (privileged: rootless dind fails on this box, spike check F)
  network      : $NET on $SLOT_SUBNET   (pinned, persistent; outer: runner -> dind. The runner creates a
                                          SECOND network on the slot daemon for the job
                                          and its services — spike finding 2.)
  root volume  : $ROOT_VOL  -> $RUNNER_ROOT  (WRITABLE, throwaway: run.sh writes
                                          run-helper.sh here every loop iteration)
  bin  (ro)    : ${BIN_DIR:-<unresolved>}
  externals(ro): ${EXT_DIR:-<unresolved>}   (678M total, bind-mounted, never copied)
  work volume  : $WORK_VOL  -> $RUNNER_ROOT/_work in BOTH containers (identical path)
  diag (HOST)  : $DIAG_DIR -> $RUNNER_ROOT/_diag  (persists: deploy-monitor +
                                          watchdog read these logs from outside)
  mode         : run.sh --once  (one job, clean exit, session released)
EOF
}

main() {
    # Before ANYTHING. A paused slot must not create a network, a volume or a container,
    # and must not care whether preflight would have passed. DRY_RUN and PULL_ONLY skip the
    # hold on purpose: they never connect to GitHub, so rehearsing them while paused is safe
    # and is exactly when you would want to.
    [ "$DRY_RUN" = "1" ] || [ "$PULL_ONLY" = "1" ] || hold_while_paused
    preflight
    log "plan:"; plan
    [ "$DRY_RUN" = "1" ] && { log "DRY_RUN — nothing done"; exit 0; }

    log "ensuring images (first run is slow; ~83s of cold start per job is expected)"
    # BOTH images are built LOCALLY and are in no registry, so a pull will always
    # fail for them. Present-locally is the success condition; the pull is only an
    # opportunistic refresh for images that do come from a registry.
    #
    # Name the right builder per image. Saying "build the runner image" when it is
    # the dind image that is missing sends whoever is holding the outage down the
    # wrong path, and this fires exactly when nothing is running.
    for img in "$RUNNER_IMAGE" "$DIND_IMAGE"; do
        docker pull -q "$img" >/dev/null 2>&1 || true
        docker image inspect "$img" >/dev/null 2>&1 && continue
        case "$img" in
            "$RUNNER_IMAGE") how="docker build -t $RUNNER_IMAGE tools/runner-image" ;;
            "$DIND_IMAGE")   how="slots/dind-image/build.sh   (or fall back: DIND_IMAGE=docker:28-dind)" ;;
            *)               how="unknown image — check RUNNER_IMAGE/DIND_IMAGE" ;;
        esac
        die "image $img is neither pullable nor present locally — build it: $how"
    done
    if [ "$PULL_ONLY" = "1" ]; then
        log "PULL_ONLY — images present, exiting without registering"
        docker image inspect "$RUNNER_IMAGE" "$DIND_IMAGE" --format '  ok {{.RepoTags}} {{.Id}}' 2>/dev/null
        exit 0
    fi

    trap cleanup EXIT INT TERM

    # RECLAIM WHATEVER THE LAST RUN LEFT BEHIND, BEFORE CREATING ANYTHING.
    #
    # Every resource this slot owns is named deterministically, and cleanup() removes all of them
    # on a normal exit. So anything still here at startup is debris from a run whose trap never
    # fired: SIGKILL, a docker daemon restart, or — the case that taught us this — the machine
    # being reset with the power button. The scripted assumption "my names are free" only holds
    # after a CLEAN exit, and an unclean one is precisely when self-heal has to work.
    #
    # Measured 2026-09-19. A hard reset at 15:44 left the network AND a stopped joggo-dind-1 behind.
    # `docker network create` failed with "already exists" and was fatal, so the slot could not
    # start for 80 minutes with six jobs queued. Removing the network by hand would only have
    # exposed the next landmine: `docker run --name joggo-dind-1` fails the same way, and there was
    # no pre-run removal anywhere — line 160's `docker rm` lives in the EXIT trap, which is
    # exactly the thing that does not run in this scenario.
    #
    # SAFETY: only ever touch the slot's OWN names. This box also runs the operator's dev
    # databases, and a broad prune here would eat them.
    reclaim_stale
    log "creating network + volumes"
    # Create only if absent: reclaim_stale has already removed one carrying the wrong subnet, so
    # anything surviving to here is correct and reusable.
    if ! docker network inspect "$NET" >/dev/null 2>&1; then
        docker network create --subnet "$SLOT_SUBNET" --gateway "$SLOT_GATEWAY" "$NET" >/dev/null 2>&1 \
            || die "network create failed ($NET $SLOT_SUBNET)"
        log "created $NET on $SLOT_SUBNET"
    fi
    docker volume create "$WORK_VOL" >/dev/null || die "work volume create failed"
    mkdir -p "$DIAG_DIR" || die "cannot create $DIAG_DIR"

    # Docker creates a fresh named volume owned by root:root, but the runner in the
    # official image is uid 1001 — so _work comes up READ-ONLY to the process that has
    # to write every checkout into it. Verified 2026-09-05: without this the runner
    # container starts fine and then fails on its first job. Hand both volumes to the
    # runner uid before anything mounts them.
    #
    # 1001 is not a guess: `id -u ghrunner` on this host and `id` in
    # ghcr.io/actions/actions-runner both report 1001, which is why the read-only
    # bind of the runner root is readable by the container at all.
    local ruid rgid
    ruid="$(id -u ghrunner 2>/dev/null || echo 1001)"
    rgid="$(id -u ghrunner 2>/dev/null || echo 1001)"   # image gid is 1001, not the host's 1002
    # Uses the dind image we already pulled rather than introducing an alpine
    # dependency the host daemon may not have.
    chown "${ruid}:${rgid}" "$DIAG_DIR" 2>/dev/null || true
    docker run --rm --user 0 --entrypoint sh \
        -v "$WORK_VOL":/v -v "$ROOT_VOL":/r "$DIND_IMAGE" \
        -c "chown ${ruid}:${rgid} /v /r" >/dev/null 2>&1 \
        || die "could not initialise volume ownership (uid ${ruid})"

    # POPULATE THE WRITABLE ROOT.
    #
    # The first cut bind-mounted the whole runner root read-only, which looked right
    # and failed immediately (2026-09-05):
    #   cp: cannot create '/home/ghrunner/actions-runner/run-helper.sh': Read-only file system
    # run.sh copies run-helper.sh.template -> run-helper.sh on EVERY iteration of its
    # supervision loop, so the root has to be writable. It cannot simply be a copy of
    # everything either: bin/ and externals/ are 81M and 597M, and copying 678M per job
    # would dwarf the cold start.
    #
    # So: the root is a throwaway volume holding only the ~68K of top-level files (and
    # the bin/externals SYMLINKS), while the two heavy versioned directories those
    # symlinks point at are bind-mounted READ-ONLY underneath it. The runner gets a
    # writable root, the job still cannot touch the binaries, and nothing is copied.
    log "populating writable runner root (~68K; bin/externals stay read-only binds)"
    docker run --rm --user "$ruid" --entrypoint sh \
        -v "$RUNNER_ROOT":/src:ro -v "$ROOT_VOL":/dst "$DIND_IMAGE" -c '
            tar -C /src --exclude=./_work --exclude=./_diag --exclude=./_update \
                        --exclude="./bin.*" --exclude="./externals.*" -cf - . \
            | tar -C /dst -xf -' \
        || die "could not populate the runner root volume"

    log "starting per-slot docker daemon (dind)"
    # dind must resolve the same absolute paths the runner hands it: the root (for the
    # externals SYMLINK), the externals target it points at, and _work.
    # --sysctl disable_ipv6: make the slot daemon match the HOST's network reality.
    # This box has IPv6 switched off at the host (net.ipv6.conf.all.disable_ipv6=1), but a
    # container does NOT inherit that — verified 2026-09-06, the host read 1 while inside
    # joggo-dind-1 the same sysctl read 0. So the dind daemon and everything it pulls (buildkit,
    # base images) sees AAAA records, tries the v6 route first, and waits out a connect
    # timeout on a network that has no v6 path at all before falling back to v4. That is the
    # shape of the one buildkit pull failure recorded against this slot.
    # Nothing on this box wants v6, so the honest fix is to stop advertising it as available.
    #
    # 2026-10-14: that --sysctl covers DIND ITSELF and nothing it creates. The sysctl is
    # per-netns, so a container dind starts gets the kernel defaults instead of dind's.
    # Measured in a child: disable_ipv6=0, one link-local v6 address, no v6 default route,
    # and `getent hosts mirror.gcr.io` answering 2a00:1450:400c:c07::52 FIRST. Because the
    # child HAS a v6 address, glibc's AI_ADDRCONFIG does not filter AAAA, so every client is
    # handed an unreachable address. Setting default.disable_ipv6=1 inside dind does NOT
    # propagate either — tested. That is the root cause behind board C-c13 (trivy could not
    # fetch its DB from mirror.gcr.io) and C-c91 (next/font got a null from fonts.googleapis).
    #
    # --dns-opt=no-aaaa below is handed to dockerd, which writes `options no-aaaa` into every
    # child's resolv.conf, and glibc then stops querying AAAA at all. Verified in a child:
    # with it, mirror.gcr.io -> 74.125.133.82; without it, -> 2a00:1450:400c:c07::52.
    #
    # CAVEAT, so nobody reads this as closing C-c95: no-aaaa is a GLIBC option. musl ignores
    # it, and aquasec/trivy is Alpine — the exact client in one of the two confirmed failures.
    # Covering every client needs the filter at the RESOLVER instead; the config for that is
    # network/filter-aaaa.conf, and installing it is the operator's call because it
    # adds a service to the box.
    docker run -d --name "$DIND_C" --network "$NET" --network-alias dind --privileged \
        --sysctl net.ipv6.conf.all.disable_ipv6=1 \
        -e DOCKER_TLS_CERTDIR= \
        -v "$ROOT_VOL":"$RUNNER_ROOT" \
        -v "$EXT_DIR":"$EXT_DIR":ro \
        -v "$WORK_VOL":"$RUNNER_ROOT/_work" \
        "$DIND_IMAGE" --host=tcp://0.0.0.0:2375 \
        --dns-opt=no-aaaa >/dev/null || die "dind failed to start"

    log "waiting for the slot daemon"
    for i in $(seq 1 30); do
        docker exec "$DIND_C" docker -H tcp://127.0.0.1:2375 info >/dev/null 2>&1 && break
        [ "$i" = "30" ] && die "dind never became ready"
        sleep 2
    done

    # Seed the brand-new image store from the immutable layer baked into the dind
    # image. This is NOT persistence between builds: the store itself is created
    # empty for every job and destroyed with the container, and what goes into it
    # is a digest-pinned tarball we built, identical for every job, that no job can
    # write back to. It replaces a per-job anonymous pull of a MUTABLE tag from
    # Docker Hub — which is what failed on 2026-09-11 and took a deploy with it.
    # Measured 2026-09-12: 7.2s to load locally against 19.6s for the Hub pull that
    # then failed, and a builder boots with the container disconnected from every
    # network.
    if docker exec "$DIND_C" test -f /opt/preload/buildkit.tar 2>/dev/null; then
        log "seeding the job's image store from the baked buildkit (no network)"
        docker exec "$DIND_C" docker -H tcp://127.0.0.1:2375 load -i /opt/preload/buildkit.tar >/dev/null \
            || log "WARNING: preload failed — buildx will fall back to pulling from Docker Hub"
    else
        # Stock docker:*-dind, or an image built before this existed. Not fatal:
        # the job still runs, it just pays the Hub pull and its failure modes.
        log "WARNING: no baked buildkit in $DIND_IMAGE — every job will pull it from Docker Hub."
        log "         build it with: slots/dind-image/build.sh"
    fi

    # Everything that can fail at startup has now succeeded (images, network, volumes, dind).
    # Clear the failure counter here rather than at exit: the runner below blocks until a job
    # completes, which can be an hour, and a slot that got this far is healthy by any useful
    # definition.
    clear_failures
    log "starting runner container (install read-only; one job then exit)"
    # --sysctl disable_ipv6: the runner container must match the host's IPv6-off reality,
    # exactly as the dind daemon does above. A container does NOT inherit the host's
    # net.ipv6.conf.all.disable_ipv6=1, so tools that run IN the job (cosign sign-by-digest
    # fetching manifests from pkg-containers.githubusercontent.com, curl, git) see AAAA
    # records, try the v6 route first, and hit "network is unreachable" on a box with no v6
    # path. Buildx pushed fine over IPv4; cosign's blob fetch died on v6 — reported 2026-09-13
    # as C-c01, the same egress class as the dind buildkit case, a different host.
    docker run --rm --name "$RUNNER_C" --network "$NET" \
        --sysctl net.ipv6.conf.all.disable_ipv6=1 \
        -e DOCKER_HOST=tcp://dind:2375 \
        -e RUNNER_ALLOW_RUNASROOT=0 \
        -v "$ROOT_VOL":"$RUNNER_ROOT" \
        -v "$BIN_DIR":"$BIN_DIR":ro \
        -v "$EXT_DIR":"$EXT_DIR":ro \
        -v "$WORK_VOL":"$RUNNER_ROOT/_work" \
        -v "$DIAG_DIR":"$RUNNER_ROOT/_diag" \
        -w "$RUNNER_ROOT" \
        "$RUNNER_IMAGE" ./run.sh --once
    rc=$?
    # A pause stops the runner container with SIGTERM, so `docker run` returns 143 and systemd
    # logs "Failed with result 'exit-code'". Restart=always still restarts us straight into the
    # hold, so nothing breaks — but a DELIBERATE hold must not read as a failure in the journal,
    # which is the first place anyone looks when CI has gone quiet. Report it as the clean exit
    # it is. Only when the flag is actually set: an unexplained 143 is still a failure.
    if { [ "$rc" = "143" ] || [ "$rc" = "130" ]; } && [ -e "$PAUSE_FLAG" ]; then
        log "runner stopped by a pause (rc=$rc) — treating as a clean exit"
        rc=0
    fi
    log "runner exited rc=$rc — container and volumes are being destroyed"
    exit "$rc"
}

main "$@"
