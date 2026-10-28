<#
.SYNOPSIS
  Remove a joggo install, in reverse order.

.DESCRIPTION
  Lists what it will do and asks, unless -Yes. Reverses the installer: the
  scheduled tasks, the keepalive, the watchdog, the slot units, the slot
  containers/volumes/networks, the registration, the local images.

  DEREGISTRATION NEEDS A FRESH TOKEN. The one used at install expired about an
  hour after it was minted, and `config.sh remove` will not accept it. Pass
  -Token with a new one, or the runner is left as an OFFLINE entry on the
  Runners page — which also blocks re-using the same name later. This script
  says so plainly rather than failing somewhere obscure.

  The distro and Docker are left alone unless -Deep, which additionally removes
  the runner roots and disables docker.service.

  Exit codes: 0 ok, 1 blocking failure, 2 bad usage.

.EXAMPLE
  ./uninstall.ps1
  Lists the plan and asks.

.EXAMPLE
  ./uninstall.ps1 -Yes -Token $env:JOGGO_TOKEN
  Unattended, including deregistration.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
  # Named-only, for the same reason as install.ps1 — and here it was worse: with
  # positional binding on, `./uninstall.ps1 --nope` bound "--nope" to -Token and
  # the script cheerfully announced it would deregister every runner "using the
  # token you passed".
  [Parameter()][string]$Token,
  [switch]$Deep,
  [switch]$Yes,
  [switch]$DryRun,
  [switch]$Json,
  [switch]$NonInteractive,
  [Parameter()][string]$ConfigFile,
  [Parameter()][string]$Distro,
  [switch]$h,
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $RepoRoot 'install\config.ps1')

function Show-Usage {
  @'
joggo uninstall — reverses the installer, in reverse order.

  ./uninstall.ps1                       list the plan and ask
  ./uninstall.ps1 -Yes -Token <t>       unattended, including deregistration
  ./uninstall.ps1 -DryRun               print the plan, change nothing
  ./uninstall.ps1 -Deep -Yes -Token <t> also remove the runner roots, disable docker

  -Token <s>      a FRESH registration token. Deregistration needs one: the
                  install-time token expired within the hour. Without it the
                  runner is left as an offline entry you must delete by hand.
  -Deep           also remove the runner roots and disable docker.service.
  -Yes            do not ask.
  -DryRun         change nothing.
  -Json           machine-readable on stdout, human text on stderr.
  -ConfigFile <p> read the install config from here instead of %ProgramData%.
  -Distro <s>     override the distro name.
  -h, -?          this text.
'@
}
if($h -or $Help){ Show-Usage; exit 0 }

$ctx = New-JoggoContext @{
  Json = [bool]$Json; DryRun = [bool]$DryRun; Yes = [bool]$Yes
  NonInteractive = [bool]$NonInteractive; RepoRoot = $RepoRoot
}

if($Rest -and $Rest.Count -gt 0){
  Write-JLine $ctx ("[FAIL] unrecognised argument(s): " + ($Rest -join ' '))
  Show-Usage
  Add-Result $ctx 'usage' 'fail' 'unrecognised arguments' 'see ./uninstall.ps1 -h'
  Exit-Joggo -Ctx $ctx -Code 2
}

# What was installed is read from the config the installer wrote. Guessing the
# slot count would leave registrations behind.
$path = $ConfigFile
if(-not $path){ $path = $ctx.ConfigPath }
$cfg = $null
if(Test-Path $path){
  $cfg = Read-JoggoConfigFile -Ctx $ctx -Path $path
  Say $ctx "read the install config from $path"
} else {
  Warn $ctx "no config at $path — falling back to defaults, which may not match what was installed."
  Say  $ctx 'If you installed with -Slots 2, pass -ConfigFile or expect slot 2 to be left behind.'
  $ram = 8192
  try { $ram = Get-JoggoRamMB } catch {}
  $cfg = Get-JoggoDefaults -RamMB $ram
  $cfg.scope = 'repo'
}
if($Distro){ $cfg.distro = $Distro }
if(-not $cfg.ContainsKey('distro') -or -not $cfg.distro){ $cfg.distro = 'Ubuntu' }
if(-not $cfg.ContainsKey('slots') -or -not $cfg.slots){ $cfg.slots = 1 }
$ctx.Distro = $cfg.distro

$tasks = @('joggo-mem-guard','joggo-mem-watch','joggo-wsl-keepalive')

# ---------------------------------------------------------------- the plan
Write-JLine $ctx ''
Write-JLine $ctx '=============================== joggo uninstall ==============================='
Write-JLine $ctx 'This will, in this order:'
Write-JLine $ctx ''
Write-JLine $ctx ("  1. unregister the scheduled tasks: " + ($tasks -join ', '))
Write-JLine $ctx ("  2. disable and remove the slot units joggo-slot@1.." + $cfg.slots + ", the watchdog timer")
Write-JLine $ctx '     and service, and the reboot re-runner'
if($Token){
  Write-JLine $ctx '  3. DEREGISTER every slot from GitHub, using the token you passed'
} else {
  Write-JLine $ctx '  3. NOT deregister anything: no -Token was passed. Deregistration needs a FRESH'
  Write-JLine $ctx '     token (the install-time one expired within the hour), so each runner will be'
  Write-JLine $ctx '     left as an OFFLINE entry that you must delete on the Runners page. An offline'
  Write-JLine $ctx '     entry with the same name also blocks a later re-registration without --replace.'
}
Write-JLine $ctx '  4. remove the slot containers, volumes and networks, by exact name only'
Write-JLine $ctx '     (this box may also run your dev databases; nothing else is touched)'
Write-JLine $ctx '  5. remove the local images joggo/dind:local and joggo/actions-runner:local'
Write-JLine $ctx '  6. remove /usr/local/sbin scripts, /var/lib/joggo-slot, /opt/joggo, and the AAAA'
Write-JLine $ctx '     dnsmasq drop-in if this installer wrote one'
Write-JLine $ctx ("  7. remove " + $ctx.ConfigPath)
if($Deep){
  Write-JLine $ctx '  8. -Deep: remove the runner roots and disable docker.service'
} else {
  Write-JLine $ctx '  The distro, Docker, the runner roots, /var/log/joggo-slots (job logs) and the'
  Write-JLine $ctx '  memory trail under ProgramData are LEFT IN PLACE. Pass -Deep for the roots.'
}
Write-JLine $ctx ''
Write-JLine $ctx '==============================================================================='

if($ctx.DryRun){
  Write-JLine $ctx ''
  Write-JLine $ctx 'DRY RUN: nothing above was done.'
  Add-Result $ctx 'uninstall' 'pass' 'dry run' ''
  Exit-Joggo -Ctx $ctx -Code 0
}

if(-not (Confirm-Joggo -Ctx $ctx -Question 'Proceed?')){
  Write-JLine $ctx 'Nothing was changed.'
  Add-Result $ctx 'uninstall' 'warn' 'declined' ''
  Exit-Joggo -Ctx $ctx -Code 0
}

# Elevation only if there is something that needs it: joggo's SYSTEM scheduled tasks. This
# used to be unconditional, the same mistake the installer's gate had -- so an install that
# needed no elevation (slots only: no guard, sampler or keepalive task) could not be REMOVED
# without it. Found on the first real uninstall. Everything else here -- the distro side and
# C:\ProgramData\joggo, which an unelevated install created -- needs no admin.
$joggoTasks = @(Get-ScheduledTask -TaskName 'joggo*' -ErrorAction SilentlyContinue)
if($joggoTasks.Count -gt 0 -and -not (Test-Admin)){
  Fail -Ctx $ctx -Problem ("not running as Administrator, and {0} joggo scheduled task(s) exist: {1}" -f $joggoTasks.Count, (($joggoTasks | ForEach-Object TaskName) -join ', ')) `
    -Action 'unregistering SYSTEM scheduled tasks needs elevation. Re-run in an elevated PowerShell.' -Code 1
}

# ---------------------------------------------------------------- 1. tasks
Write-JLine $ctx ''
Write-JLine $ctx '== scheduled tasks =='
foreach($t in $tasks){
  $existing = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
  if(-not $existing){ Skip $ctx "task '$t' is not registered"; continue }
  try {
    # Stop first: the keepalive is a long-running task and unregistering it
    # while it runs leaves the wsl.exe process behind holding the VM.
    Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop
  } catch {
    Warn $ctx "could not remove task '$t': $($_.Exception.Message)"
    continue
  }
  if(Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue){
    Warn $ctx "task '$t' still exists after Unregister-ScheduledTask — remove it in Task Scheduler"
  } else {
    Ok $ctx "task '$t' removed (confirmed by reading the scheduler back)"
  }
}

# ---------------------------------------------------------------- 2..6 distro
Write-JLine $ctx ''
Write-JLine $ctx '== inside the distro =='
$d = $null
$all = Get-WslDistros -Ctx $ctx
if($null -ne $all){ $d = @($all | Where-Object { $_.name -eq $cfg.distro })[0] }
if($null -eq $d){
  Warn $ctx "distro '$($cfg.distro)' is not present, so nothing inside it was removed."
  Say  $ctx 'The units, registrations and containers are wherever that distro is. Pass -Distro <name>.'
} else {
  $extra = @()
  if($Deep){ $extra = @('--deep') }
  $r = Invoke-Phase -Ctx $ctx -Cfg $cfg -Phase 'remove' -Token $Token -TimeoutSec 900 -Extra $extra
  if(-not $r.ok){
    Warn $ctx 'the in-distro removal reported problems (above). Re-run, or finish by hand.'
    Add-Result $ctx 'remove-linux' 'warn' 'in-distro removal reported problems' 'see the output above'
  } else {
    Ok $ctx 'in-distro removal completed'
  }
}

# ---------------------------------------------------------------- 7. config
Write-JLine $ctx ''
Write-JLine $ctx '== Windows-side files =='
if(Test-Path $ctx.ConfigPath){
  Remove-Item -Path $ctx.ConfigPath -Force
  if(Test-Path $ctx.ConfigPath){ Warn $ctx "could not remove $($ctx.ConfigPath)" }
  else { Ok $ctx "removed $($ctx.ConfigPath)" }
} else {
  Skip $ctx 'no config file to remove'
}
if(Test-Path $ctx.BinDir){
  Remove-Item -Path $ctx.BinDir -Recurse -Force -ErrorAction SilentlyContinue
  if(Test-Path $ctx.BinDir){ Warn $ctx "could not remove $($ctx.BinDir)" } else { Ok $ctx "removed $($ctx.BinDir)" }
}
# The supervisor brief that step 97 rendered. It is STATE (this box's paths and thresholds),
# not evidence, and a brief describing a runner that no longer exists would send an agent
# looking for one. Left behind by every uninstall until the first real one showed it.
$brief = Join-Path $ctx.DataDir 'SUPERVISOR.md'
if(Test-Path $brief){
  Remove-Item -Path $brief -Force -ErrorAction SilentlyContinue
  if(Test-Path $brief){ Warn $ctx "could not remove $brief" } else { Ok $ctx "removed $brief" }
}
# The directory itself, when nothing is left in it. With the trail present it stays.
if((Test-Path $ctx.DataDir) -and -not (Get-ChildItem $ctx.DataDir -Force -ErrorAction SilentlyContinue)){
  Remove-Item -Path $ctx.DataDir -Force -ErrorAction SilentlyContinue
}
Say $ctx "kept: the memory trail and snapshots under $($ctx.DataDir). They are evidence, not state — delete them yourself if you want them gone."

if(-not $Token){
  Write-JLine $ctx ''
  Write-JLine $ctx '*** ONE THING IS LEFT, AND ONLY YOU CAN DO IT ***'
  Write-JLine $ctx '  Nothing was deregistered, because that needs a fresh registration token.'
  Write-JLine $ctx '  Delete the runner entries on the Runners page, or re-run with -Token <fresh>:'
  if($cfg.scope -eq 'org'){
    Write-JLine $ctx ("    https://github.com/organizations/" + $cfg.org + "/settings/actions/runners")
  } else {
    Write-JLine $ctx ("    https://github.com/" + $cfg.repo + "/settings/actions/runners")
  }
  Add-Result $ctx 'deregister' 'warn' 'not deregistered: no fresh token was given' 'delete the runner on the Runners page, or re-run with -Token'
}

Write-JLine $ctx ''
Ok $ctx 'uninstall finished.'
Add-Result $ctx 'uninstall' 'pass' 'completed' ''
Exit-Joggo -Ctx $ctx -Code 0
