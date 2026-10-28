# The slot's Docker daemon, with the build toolchain already in the box.
#
# Why this image exists
# ---------------------
# The slot gives every job a brand-new dind with an empty image store, which is
# the whole security property: nothing a job does can reach the next job. The
# cost was that `docker buildx` then pulled moby/buildkit from Docker Hub on
# EVERY job — anonymously, over the network, at build time, by a MUTABLE tag.
# On 2026-09-11 that pull timed out and took appone's deploy with it.
#
# This does not add persistence. The buildkit image ships as an immutable layer
# of this image, pinned by digest, and is loaded into each job's fresh store at
# slot start. Every job gets an identical, verifiable seed and still cannot
# leave anything behind for the next one — the same standing the runner binary
# and `externals/` already have, both of which are mounted read-only into jobs
# and which nobody calls persistent state.
#
# It is also strictly better supply-chain posture than what it replaces: a
# digest we chose and hold locally, instead of a floating tag re-fetched from a
# third party during every build.
#
# Rebuilding is deliberate, and that is the point of pinning — see build.sh.

ARG DIND_BASE=docker:28-dind
FROM ${DIND_BASE}

# The digest this image ships. Passed in by build.sh so the value lives in one
# place; recorded here as a label so a running slot can be asked what it holds.
ARG BUILDKIT_DIGEST
ARG BUILDKIT_REF
LABEL org.joggo.buildkit-digest="${BUILDKIT_DIGEST}" \
      org.joggo.buildkit-ref="${BUILDKIT_REF}" \
      org.joggo.purpose="dind with a digest-pinned buildkit preloaded; no cross-job persistence"

# `docker save` output of the pinned buildkit image. Read-only for the life of
# the image; the job's daemon loads FROM it, never writes back TO it.
COPY buildkit.tar /opt/preload/buildkit.tar
