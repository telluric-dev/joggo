param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 50-dind-image — the two images a slot needs, both built locally.
#
# joggo/dind:local        the per-slot Docker daemon, with a digest-pinned
#                         buildkit baked in. slots/dind-image/build.sh and its
#                         Dockerfile explain why the pin matters; the short
#                         version is that a floating moby/buildkit tag pulled
#                         from Hub at build time took a production deploy down.
#
# joggo/actions-runner:local   the slot's runner container. THE REPO DOES NOT
#                         SHIP A CONTEXT FOR THIS. run-containerized-slot.sh
#                         defaults RUNNER_IMAGE to this name and says to build
#                         it from tools/runner-image, a directory the scrub
#                         removed. Without it no slot can start, so the Linux
#                         half generates the context: the upstream image plus
#                         the three packages the launcher's own header names as
#                         missing from it (libatomic1, zstd, git-lfs).
#
# Neither image is in any registry, so "present locally" is the only success
# condition — which is also why a `docker pull` failure for them is not an
# error.

Step-Header $Ctx '50-dind-image'

if($Ctx.DryRun){
  Plan $Ctx 'would build joggo/dind:local via slots/dind-image/build.sh, unless the image is already present'
  Plan $Ctx 'would generate /opt/joggo/runner-image/Dockerfile and build joggo/actions-runner:local, unless present'
  Plan $Ctx 'would confirm each image with docker image inspect afterwards — build.sh exiting 0 is not evidence of an image'
  Add-Result $Ctx 'images' 'pass' 'dry run' ''
  return
}

Say $Ctx 'building the slot images. First build is slow: the dind image ships a ~106 MB buildkit layer.'
$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'images' -TimeoutSec 2400
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem 'a slot image could not be built' `
    -Action 'the build log named in the output above has the reason. A Docker Hub timeout is the common one and re-running is usually enough.' -Code 1
}
Add-Result $Ctx 'images' 'pass' 'joggo/dind:local and joggo/actions-runner:local present (inspected, not assumed)' ''
