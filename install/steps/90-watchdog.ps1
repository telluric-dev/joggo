param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 90-watchdog — the wedge detector and its systemd timer.
#
# THE GAP IT FILLS, because it is not the same as a crash: on 2026-09-01 the
# listener did not exit, it HUNG — alive at 0% CPU in futex_wait, holding an
# ESTABLISHED socket, after its OAuth refresh died mid-read. systemd saw a
# perfectly healthy unit while seven jobs piled up. Restart=always cannot fire
# for a process that never exits, so this is a separate layer.
#
# The threshold is 65 min and must not be lowered: an idle-but-healthy listener
# is routinely silent for up to 50 minutes between OAuth refreshes (measured at
# 3021 s over 2 days / 5422 log lines).

Step-Header $Ctx '90-watchdog'

if(-not $Cfg.watchdog){
  Skip $Ctx 'watchdog disabled (-NoWatchdog)'
  Warn $Ctx 'a hung listener will now stay hung until a human notices. Restart=always does not cover it: the process never exits.'
  Add-Result $Ctx 'watchdog' 'warn' 'watchdog disabled' 're-run without -NoWatchdog'
  return
}

if($Ctx.DryRun){
  Plan $Ctx 'would install watchdog/runner-watchdog.sh -> /usr/local/sbin/ and its .service + .timer'
  Plan $Ctx 'would install the Restart=always drop-in for the persistent runner unit (self-heal layer 2, and right if anyone rolls back)'
  Plan $Ctx 'would enable + start runner-watchdog.timer, then confirm enabled, active, AND that systemd reports a next elapse'
  Plan $Ctx 'would run runner-watchdog.sh --check, which never acts, to prove it resolves a live target'
  Plan $Ctx 'would install the reboot re-runner but enable it only if the Windows gh.exe exists — it authenticates through interop so no token lives in the distro'
  Add-Result $Ctx 'watchdog' 'pass' 'dry run' ''
  return
}

$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'watchdog' -TimeoutSec 600
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem 'the watchdog is not armed' `
    -Action 'the output above names the cause. Check: systemctl status runner-watchdog.timer inside the distro.' -Code 1
}
Add-Result $Ctx 'watchdog' 'pass' 'runner-watchdog.timer enabled and active with a next elapse; --check ran' ''
