param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 30-runner-user — the unprivileged account the runner runs as.
#
# NEVER ROOT. On the persistent runner, jobs execute as this uid and it owns the
# runner install, which is the exposure the containerised slot closes; running
# as root would hand a job the box outright.

Step-Header $Ctx '30-runner-user'

if($Ctx.DryRun){
  Plan $Ctx "would create user '$($Cfg.runnerUser)' in $($Cfg.distro) if absent (useradd -m -s /bin/bash)"
  Plan $Ctx "would ensure /home/$($Cfg.runnerUser)/actions-runner exists and is owned by them"
  Add-Result $Ctx 'runner-user' 'pass' 'dry run' ''
  return
}

$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'runner-user' -TimeoutSec 120
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem "could not prepare the runner user '$($Cfg.runnerUser)'" `
    -Action "create it by hand in the distro: sudo useradd -m -s /bin/bash $($Cfg.runnerUser)" -Code 1
}
Add-Result $Ctx 'runner-user' 'pass' "$($Cfg.runnerUser) present and owns its runner root" ''
