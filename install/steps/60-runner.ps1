param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 60-runner — download, register, and install the service unit.
#
# THE TOKEN NEVER TOUCHES DISK. It reaches the Linux half on stdin and is handed
# to config.sh as an argument because config.sh accepts no other form. Nothing
# writes it anywhere, and it is not in the config file this installer saved.
#
# BOTH SCOPES WORK HERE, and the difference is only the URL:
#   org   -> https://github.com/<org>          one registration, every allowed repo
#   repo  -> https://github.com/<owner>/<repo> the personal-account path, because
#            runner groups are an organisation-only feature
# The generated service unit's NAME differs between them too, which is why the
# slot unit's Conflicts= is templated from the registration rather than assumed.

Step-Header $Ctx '60-runner'

$url = Get-JoggoRunnerUrl -Cfg $Cfg

if($Ctx.DryRun){
  Plan $Ctx "would register runner '$($Cfg.runnerName)' at $url with labels: $($Cfg.labels)"
  Plan $Ctx "  scope=$($Cfg.scope)$(if($Cfg.scope -eq 'repo'){' — the personal-account path; runner groups do not exist outside an organisation'})"
  Plan $Ctx 'would download the current actions-runner release into the runner root if it is not already there'
  Plan $Ctx 'would use --replace: a server-side ghost with the same name survives and blocks a fresh registration without it'
  Plan $Ctx 'would then read .runner/.credentials/.credentials_rsaparams back off disk rather than trusting config.sh output'
  Plan $Ctx 'would install the svc.sh service unit and leave it DISABLED — the slot units Conflicts= it, and it is the one-command rollback'
  Add-Result $Ctx 'runner' 'pass' 'dry run' ''
  return
}

if(-not $Token){
  Fail -Ctx $Ctx -Problem 'no registration token, so the runner cannot be registered' `
    -Action ("mint one at " + (Get-JoggoTokenUrl -Cfg $Cfg) + " and pass -Token, or set `$env:JOGGO_TOKEN") -Code 2
}

$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'runner' -Token $Token -TimeoutSec 1200
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem 'the runner is not registered' `
    -Action 'the output above names the cause. An EXPIRED token is the usual one — they last about an hour. Mint a fresh one and re-run; re-running is safe.' -Code 1
}
Add-Result $Ctx 'runner' 'pass' "registered as $($Cfg.runnerName) at $url (verified from .runner on disk)" ''
