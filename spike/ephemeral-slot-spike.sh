#!/usr/bin/env bash
# Spike: can a runner running INSIDE a container, with its Docker daemon in a
# separate per-slot dind container, still run the container jobs that
# .github/workflows/node-test.yml produces (job `container:` + Postgres
# `service:`)?
#
# Background: the runner asks its Docker daemon to bind-mount its own work tree
# into the job container. Those are absolute HOST paths, resolved by whichever
# daemon receives the request. Point DOCKER_HOST at a separate dind and the
# paths resolve inside the dind's filesystem, not the runner's.
#
# The docker flags replayed below are copied verbatim from a real appone
# node-test job on marathon (_diag/Worker_20260823-124613-utc.log), with only the
# container names changed.
#
#   sudo spike/ephemeral-slot-spike.sh          # run every scenario
#   sudo spike/ephemeral-slot-spike.sh --clean  # tear down and exit
#
# Leaves nothing behind: every object it creates is named spike-*.

set -uo pipefail

RUNNER_ROOT=/home/ghrunner/actions-runner   # same path the real runner uses
JOB_IMAGE=node:22
PG_IMAGE=postgres:16-alpine
DIND_IMAGE=docker:28-dind
DIND_ROOTLESS_IMAGE=docker:28-dind-rootless
CLI_IMAGE=docker:cli                        # stands in for the runner process
RUNNER_IMAGE=ghcr.io/actions/actions-runner:latest

pass=0; fail=0
BASE_AVAIL=$(free -m | sed -n '2p' | awk '{print $7}')
ok()    { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
no()    { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
info()  { printf '  ....  %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }

cleanup() {
  docker exec spike-runner docker rm -f spike-job spike-pg >/dev/null 2>&1
  docker rm -f spike-job spike-pg spike-runner spike-dind >/dev/null 2>&1
  docker network rm spike-net >/dev/null 2>&1
  docker volume rm spike-work >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
cleanup
if [ "${1:-}" = "--clean" ]; then echo "cleaned"; trap - EXIT; exit 0; fi

# start_slot <shared|isolated> <dind-image> <privileged|unprivileged>
# Brings up a per-slot network, a dind daemon and a runner-like container.
# `shared` puts a named volume at $RUNNER_ROOT in BOTH containers.
start_slot() {
  mode="$1"; dimg="$2"; priv="$3"
  vol=""; pflag=""
  docker network create spike-net >/dev/null 2>&1
  if [ "$mode" = shared ]; then
    docker volume create spike-work >/dev/null
    vol="-v spike-work:$RUNNER_ROOT"
  fi
  if [ "$priv" = privileged ]; then pflag="--privileged"; fi
  # shellcheck disable=SC2086
  docker run -d --name spike-dind --network spike-net --network-alias dind \
    $pflag $vol -e DOCKER_TLS_CERTDIR= \
    "$dimg" --host=tcp://0.0.0.0:2375 >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2086
  docker run -d --name spike-runner --network spike-net \
    -e DOCKER_HOST=tcp://dind:2375 $vol \
    --entrypoint sleep "$CLI_IMAGE" infinity >/dev/null || return 1
  for _ in $(seq 1 90); do
    if docker exec spike-runner docker info >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

# Populate the runner's work tree the way actions/checkout would, then replay
# the exact `docker create` the runner issues for a container job.
seed_and_create_job() {
  # The real runner creates its job network on ITS OWN daemon (github_network_<id>),
  # not on the host. Two networks exist per slot: the outer one wiring runner->dind,
  # and this inner one wiring the job container to its services.
  docker exec spike-runner docker network create github_network_spike >/dev/null 2>&1

  docker exec spike-runner sh -c "mkdir -p $RUNNER_ROOT/_work/appone/appone $RUNNER_ROOT/_work/_temp $RUNNER_ROOT/_work/_actions $RUNNER_ROOT/_work/_tool $RUNNER_ROOT/_work/_temp/_github_home $RUNNER_ROOT/_work/_temp/_github_workflow $RUNNER_ROOT/externals && echo checked-out-source > $RUNNER_ROOT/_work/appone/appone/package.json" >/dev/null || return 1

  docker exec spike-runner docker create --name spike-job \
    --workdir /__w/appone/appone --network github_network_spike \
    -e HOME=/github/home -e GITHUB_ACTIONS=true -e CI=true \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$RUNNER_ROOT/_work":/__w \
    -v "$RUNNER_ROOT/externals":/__e:ro \
    -v "$RUNNER_ROOT/_work/_temp":/__w/_temp \
    -v "$RUNNER_ROOT/_work/_actions":/__w/_actions \
    -v "$RUNNER_ROOT/_work/_tool":/__w/_tool \
    -v "$RUNNER_ROOT/_work/_temp/_github_home":/github/home \
    -v "$RUNNER_ROOT/_work/_temp/_github_workflow":/github/workflow \
    --entrypoint tail "$JOB_IMAGE" -f /dev/null 2>&1 | tail -2 | sed 's/^/        create: /'
  docker exec spike-runner docker inspect spike-job >/dev/null 2>&1 || return 1
  docker exec spike-runner docker start spike-job >/dev/null 2>&1
}

workspace_visible() {
  docker exec spike-runner docker exec spike-job \
    cat /__w/appone/appone/package.json 2>/dev/null | grep -q checked-out-source
}

###############################################################################
head_ "A. Control - separate dind, NO shared volume (the predicted failure)"
###############################################################################
if start_slot isolated "$DIND_IMAGE" privileged; then
  info "slot up: dind reachable from the runner container"
  if seed_and_create_job; then
    if workspace_visible; then
      no "job container CAN see the workspace - failure did NOT reproduce"
    else
      ok "job container sees an EMPTY workspace (failure reproduced)"
      info "what the job container actually got:"
      docker exec spike-runner docker exec spike-job \
        sh -c 'ls -a /__w/appone/appone 2>&1 | tr "\n" " "; echo' | sed 's/^/        /'
      info "the dind created the mount sources itself, empty, on ITS filesystem:"
      docker exec spike-dind sh -c "ls -ld $RUNNER_ROOT/_work 2>&1" | sed 's/^/        /'
    fi
  else
    no "could not create the job container at all"
  fi
else
  no "slot failed to start (dind may not run nested in WSL2 - see scenario F)"
  docker logs spike-dind 2>&1 | tail -5 | sed 's/^/        /'
fi
cleanup

###############################################################################
head_ "B. Fix - one named volume at the identical path in runner AND dind"
###############################################################################
if start_slot shared "$DIND_IMAGE" privileged; then
  if seed_and_create_job && workspace_visible; then
    ok "job container sees the checked-out workspace"
  else
    no "workspace still not visible with the shared volume"
  fi

  # externals/ lives OUTSIDE _work, so the volume must cover the runner ROOT.
  if docker exec spike-runner docker exec spike-job test -d /__e; then
    ok "externals (/__e) also resolves - volume must cover the runner root, not just _work"
  else
    no "externals (/__e) missing"
  fi

  head_ "C. Service container reachability (node-test.yml's Postgres)"
  docker exec spike-runner docker run -d --name spike-pg --network github_network_spike \
    --network-alias postgres --health-cmd pg_isready --health-interval 10s \
    -e POSTGRES_USER=handsfree_clinic -e POSTGRES_PASSWORD=handsfree_clinic \
    -e POSTGRES_DB=handsfree_clinic_test "$PG_IMAGE" >/dev/null 2>&1
  sleep 10
  if docker exec spike-runner docker exec spike-job getent hosts postgres >/dev/null 2>&1; then
    ok "job container resolves the 'postgres' network alias"
  else
    no "job container cannot resolve 'postgres'"
  fi
  if docker exec spike-runner docker exec spike-pg pg_isready -U handsfree_clinic >/dev/null 2>&1; then
    ok "postgres service is healthy inside the slot"
  else
    info "postgres not ready yet (timing, not necessarily a failure)"
  fi

  head_ "D. What /var/run/docker.sock becomes inside the job container"
  sock=$(docker exec spike-runner docker exec spike-job \
           sh -c 'if [ -S /var/run/docker.sock ]; then echo socket; elif [ -d /var/run/docker.sock ]; then echo empty-dir; else echo missing; fi' 2>/dev/null)
  info "job container's /var/run/docker.sock is: ${sock:-unknown}"
  if [ "$sock" = socket ]; then
    ok "resolves to the SLOT's own daemon (dind's socket), not the host's"
  else
    info "no usable socket - jobs that shell out to 'docker' need DOCKER_HOST instead"
  fi

  head_ "E. Footprint of one full slot (runner + dind + job + service)"
  info "on the host daemon (the slot's own containers):"
  docker stats --no-stream --format '        {{.Name}}: {{.MemUsage}}' \
    spike-dind spike-runner 2>/dev/null
  info "on the SLOT daemon (invisible to the host's docker stats):"
  docker exec spike-runner docker stats --no-stream \
    --format '        {{.Name}}: {{.MemUsage}}' spike-job spike-pg 2>/dev/null
  now_avail=$(free -m | sed -n '2p' | awk '{print $7}')
  printf '        whole slot costs %s MiB of available memory (%s -> %s avail)
' \
    "$((BASE_AVAIL - now_avail))" "$BASE_AVAIL" "$now_avail"
else
  no "shared-volume slot failed to start"
fi
cleanup

###############################################################################
head_ "F. Rootless dind (the safer option in the proposal's 4.4)"
###############################################################################
for p in unprivileged privileged; do
  if start_slot shared "$DIND_ROOTLESS_IMAGE" "$p"; then
    ok "rootless dind came up $p and served the API"
    cleanup
    break
  else
    no "rootless dind did NOT come up $p"
    docker logs spike-dind 2>&1 | tail -4 | sed 's/^/        /'
    cleanup
  fi
done

###############################################################################
head_ "H. Per-job cold-start cost (a fresh daemon has an empty image store)"
###############################################################################
t0=$(date +%s)
if start_slot shared "$DIND_IMAGE" privileged; then
  t1=$(date +%s)
  info "dind boot to first API response: $((t1 - t0))s"
  docker exec spike-runner docker pull -q "$JOB_IMAGE" >/dev/null 2>&1
  t2=$(date +%s)
  info "pull $JOB_IMAGE into the empty slot daemon: $((t2 - t1))s"
  docker exec spike-runner docker pull -q "$PG_IMAGE" >/dev/null 2>&1
  t3=$(date +%s)
  info "pull $PG_IMAGE: $((t3 - t2))s"
  docker exec spike-runner sh -c 'mkdir -p /tmp/b && printf "FROM alpine:latest\nRUN echo hi > /hi\n" > /tmp/b/Dockerfile && docker build -q -t spike-built /tmp/b' >/dev/null 2>&1
  t4=$(date +%s)
  if docker exec spike-runner docker image inspect spike-built >/dev/null 2>&1; then
    ok "an image builds inside the slot (cold cache): $((t4 - t3))s"
  else
    no "docker build inside the slot failed"
  fi
  info "fixed overhead before a job's first step: $((t3 - t0))s"
else
  no "slot failed to start for the timing run"
fi
cleanup

###############################################################################
head_ "G. What the official runner image is missing (proposal 4.5)"
###############################################################################
for t in git jq docker buildx zstd node curl unzip tar; do
  if docker run --rm --entrypoint sh "$RUNNER_IMAGE" -c "command -v $t" >/dev/null 2>&1; then
    info "present: $t"
  else
    printf '        MISSING: %s\n' "$t"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
