# The slot's runner container.
#
# Why this image exists instead of the upstream one
# -------------------------------------------------
# `ghcr.io/actions/actions-runner` is deliberately minimal, and three things it
# omits are things the persistent host runner had for free — so moving to
# containerised slots silently broke jobs that had worked for months:
#
#   libatomic1   every pnpm repository fails without it, at install time, with
#                an error that names neither pnpm nor libatomic
#   zstd         actions/cache uses it; without it caching degrades quietly
#                rather than failing, which is worse
#   git-lfs      a checkout of an LFS repo succeeds and gives you pointer files
#
# None of those announce themselves as a missing-package problem. That is the
# argument for baking them in rather than letting each repo discover them.
#
# Built by install/steps/50-dind-image.ps1, or by hand:
#
#   docker build -t joggo/actions-runner:local slots/runner-image
#
# Keep it thin. Everything a *job* needs belongs in the job's own container or
# its workflow, not here — this image is the runner, not the build environment.
# Anything added here is inherited by every repository on the box, and the next
# person to wonder why a build behaves differently will not look in this file.

ARG RUNNER_BASE=ghcr.io/actions/actions-runner:latest
FROM ${RUNNER_BASE}

LABEL org.joggo.purpose="actions-runner plus the three packages the stock image omits" \
      org.joggo.adds="libatomic1,zstd,git-lfs"

USER root

# One layer, no recommends, lists cleaned — this image is rebuilt on every runner
# release and the size is paid on every slot start.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libatomic1 \
      zstd \
      git-lfs \
 && git lfs install --system \
 && rm -rf /var/lib/apt/lists/*

# Back to the unprivileged account the base image runs as. A slot that runs the
# listener as root would hand every job root inside the container, which is the
# opposite of what the per-slot container exists for.
USER runner
