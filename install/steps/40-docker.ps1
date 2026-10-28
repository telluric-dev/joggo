param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 40-docker — Docker Engine, NATIVE in the distro.
#
# Not Docker Desktop, and this is not a preference. Desktop projects its own
# socket into the distro from /mnt/wsl, so `docker info` answers while there is
# no local daemon at all — and every slot then shares one image store and build
# cache across repositories, which is the isolation the slot model exists for.
# The Linux half refuses to continue if it finds Desktop's socket.

Step-Header $Ctx '40-docker'

if($Ctx.DryRun){
  Plan $Ctx 'would refuse to continue if the docker socket in the distro comes from Docker Desktop'
  Plan $Ctx 'would install Docker Engine from get.docker.com if dockerd is absent'
  Plan $Ctx "would add $($Cfg.runnerUser) to the docker group (root-equivalent on this host, and accepted: the box is dedicated to CI)"
  Plan $Ctx 'would enable + start docker.service, then confirm it is active AND that the daemon reports a server version'
  Plan $Ctx 'would install the weekly docker prune (a full disk presents as random build failures)'
  Add-Result $Ctx 'docker' 'pass' 'dry run' ''
  return
}

# Long: a cold apt plus the engine download.
$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'docker' -TimeoutSec 1200
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem 'Docker Engine is not running natively in the distro' `
    -Action 'the output above names the cause and the fix. The two common ones: Docker Desktop WSL integration is on for this distro, or systemd is not running.' -Code 1
}
Add-Result $Ctx 'docker' 'pass' 'docker.service active, daemon answered with a server version' ''
