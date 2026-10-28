#!/usr/bin/env bash
# Build joggo/dind:local — the slot daemon with buildkit already inside.
#
#   slots/dind-image/build.sh              # build with the pinned digest below
#   slots/dind-image/build.sh --refresh    # re-resolve the tag, print the new digest, build
#
# Run it in WSL, where the runner's Docker lives.
#
# The pin is the point. `buildx-stable-1` is a moving tag on a third party's
# registry; resolving it at build time here, once, deliberately, is what turns
# "whatever Hub serves during your deploy" into "the bytes we chose". --refresh
# is how you move the pin, and moving it is an operator decision with a commit
# attached, not something a build does behind your back.

set -euo pipefail

# Pinned 2026-09-12. Resolved from moby/buildkit:buildx-stable-1.
BUILDKIT_REF=moby/buildkit:buildx-stable-1
BUILDKIT_DIGEST=sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8

DIND_BASE=${DIND_BASE:-docker:28-dind}
IMAGE=${IMAGE:-joggo/dind:local}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REFRESH=0

[ "${1:-}" = "--refresh" ] && REFRESH=1

die() { printf '%s\n' "dind-image: $*" >&2; exit 1; }

if [ "$REFRESH" = "1" ]; then
  echo "== re-resolving $BUILDKIT_REF =="
  docker pull -q "$BUILDKIT_REF" >/dev/null || die "could not pull $BUILDKIT_REF"
  new=$(docker image inspect "$BUILDKIT_REF" --format '{{index .RepoDigests 0}}' | cut -d@ -f2)
  echo "  was: $BUILDKIT_DIGEST"
  echo "  now: $new"
  if [ "$new" != "$BUILDKIT_DIGEST" ]; then
    echo
    echo "  The tag has moved. Update BUILDKIT_DIGEST in this script and commit it,"
    echo "  so the change to what every build runs is reviewable. Not doing it for you."
  fi
  BUILDKIT_DIGEST=$new
fi

echo "== fetching buildkit by digest =="
# By digest, so this is the same content regardless of where the tag points now.
docker pull -q "${BUILDKIT_REF%%:*}@${BUILDKIT_DIGEST}" >/dev/null \
  || die "could not pull ${BUILDKIT_REF%%:*}@${BUILDKIT_DIGEST}"

# Tag it locally as the name buildx will look for. buildx asks for
# moby/buildkit:buildx-stable-1 and pulls only when it is absent, so presenting
# the pinned bytes under that name is what stops the network call — verified
# 2026-09-12 with the dind container disconnected from every network.
docker tag "${BUILDKIT_REF%%:*}@${BUILDKIT_DIGEST}" "$BUILDKIT_REF"

echo "== exporting to the build context =="
docker save "$BUILDKIT_REF" -o "$HERE/buildkit.tar"
ls -lh "$HERE/buildkit.tar" | awk '{print "  buildkit.tar: " $5}'

echo "== building $IMAGE =="
docker build \
  --build-arg "DIND_BASE=$DIND_BASE" \
  --build-arg "BUILDKIT_DIGEST=$BUILDKIT_DIGEST" \
  --build-arg "BUILDKIT_REF=$BUILDKIT_REF" \
  -t "$IMAGE" "$HERE"

# The tarball is a build artefact, not source. Left on disk it is 106 MB of
# duplicate bytes that go stale the moment the pin moves.
rm -f "$HERE/buildkit.tar"

echo
echo "built: $IMAGE"
docker image inspect "$IMAGE" \
  --format '  buildkit: {{index .Config.Labels "org.joggo.buildkit-ref"}}@{{index .Config.Labels "org.joggo.buildkit-digest"}}'
echo
echo "The slot picks this up by default. To use stock dind instead:"
echo "  DIND_IMAGE=docker:28-dind systemctl restart joggo-slot@1"
