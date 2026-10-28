param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 70-slots — the launcher, the pause lever, the joggo-slot@ template, and N slots.
#
# A SLOT IS A REGISTRATION, NOT A UNIT INSTANCE. `systemctl enable joggo-slot@2`
# on its own buys zero extra concurrency: one registration holds exactly one
# GitHub session, so the second instance loses it and retries about every 95
# seconds, forever. Everything else in the launcher is already keyed on the slot
# number — network, both containers, both volumes, _diag, the pause flag, the
# fail stamp — and RUNNER_ROOT is the single thing that is not. slots/add-slot.sh
# fixes exactly that, and this step then registers the copy under its own name.

Step-Header $Ctx '70-slots'

if($Ctx.DryRun){
  Plan $Ctx 'would install, with the legacy service name substituted in so Conflicts= names a unit that exists here:'
  Plan $Ctx '  slots/run-containerized-slot.sh  -> /usr/local/sbin/run-containerized-slot.sh'
  Plan $Ctx '  slots/slot-pause.sh              -> /usr/local/sbin/joggo-pause'
  Plan $Ctx '  slots/slots-status.sh            -> /usr/local/sbin/joggo-slots-status'
  Plan $Ctx '  slots/systemd/joggo-slot@.service -> /etc/systemd/system/'
  Plan $Ctx '  and create /var/lib/joggo-slot + /var/log/joggo-slots (the pause flag path is the contract)'
  if($Cfg.filterAaaa){
    Plan $Ctx 'would add --dns=$SLOT_GATEWAY to the installed launcher, so the AAAA filter is actually consulted'
  }
  for($n=2; $n -le [int]$Cfg.slots; $n++){
    Plan $Ctx "would prepare slot $n with add-slot.sh (copies the root, STRIPS the copied credentials) and register it as $($Cfg.runnerName)-$n with the same labels, a different name, and NO --replace"
  }
  Plan $Ctx "would enable joggo-slot@1..$($Cfg.slots) and read is-enabled back (started in step 95)"
  Plan $Ctx "would retire any existing slot above $($Cfg.slots): disable + deregister + remove its root if idle; if it is running a job, only pause it (never kill the job)"
  Add-Result $Ctx 'slots' 'pass' 'dry run' ''
  return
}

if([int]$Cfg.slots -gt 1 -and -not $Token){
  Fail -Ctx $Ctx -Problem "slots=$($Cfg.slots) but there is no token left to register the additional slot(s)" `
    -Action 'each slot needs its OWN registration. Re-run with a fresh -Token, or install with -Slots 1.' -Code 2
}

$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'slots' -Token $Token -TimeoutSec 2400
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem 'the slots are not installed' `
    -Action 'the output above names the cause and the hand-run command where one exists.' -Code 1
}
Add-Result $Ctx 'slots' 'pass' "$($Cfg.slots) slot(s) installed and enabled, each with its own registration" ''
