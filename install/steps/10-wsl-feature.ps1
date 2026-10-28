param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 10-wsl-feature — the two Windows optional features WSL2 needs.
#
# THE THING THIS STEP EXISTS TO HANDLE HONESTLY: enabling either feature can
# require a reboot, and after that reboot nothing has been installed yet.
# Pretending to continue past it produces a cascade of nonsense errors from
# every later step, because wsl.exe is present and non-functional. So this step
# detects the requirement, says so unmistakably, and stops with the command to
# resume.

Step-Header $Ctx '10-wsl-feature'

$features = @(
  @{ Name='Microsoft-Windows-Subsystem-Linux'; Label='Windows Subsystem for Linux' },
  @{ Name='VirtualMachinePlatform';            Label='Virtual Machine Platform' }
)

$needReboot = $false
$changed    = $false

foreach($f in $features){
  $state = $null
  $probeErr = ''
  try {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $f.Name -ErrorAction Stop).State
  } catch {
    $probeErr = ($_.Exception.Message -replace '\s+',' ').Trim()
  }

  if($probeErr){
    # Not "probably fine". On a box where DISM cannot answer, every later step
    # is guesswork — so a real run stops. A dry run says so and carries on,
    # because reading DISM needs elevation and previewing the plan should not.
    if($Ctx.DryRun){
      Warn $Ctx "cannot read the '$($f.Label)' feature state: $probeErr"
      Plan $Ctx "  a real run would stop here. Dry run continues; it changes nothing either way."
      $changed = $true
      continue
    }
    Undetermined -Ctx $Ctx -What "whether the '$($f.Label)' feature is enabled ($probeErr)" `
      -Action "run elevated, then check by hand: Get-WindowsOptionalFeature -Online -FeatureName $($f.Name)"
  }

  if($state -eq 'Enabled'){
    Skip $Ctx "$($f.Label) already enabled"
    Add-Result $Ctx $f.Name 'pass' 'already enabled' ''
    continue
  }

  if($Ctx.DryRun){
    Plan $Ctx "would enable $($f.Label) ($($f.Name)) — state is currently '$state'"
    Plan $Ctx '  this is the step that can demand a reboot'
    $changed = $true
    continue
  }

  Say $Ctx "enabling $($f.Label) (currently '$state')"
  $r = $null
  try {
    $r = Enable-WindowsOptionalFeature -Online -FeatureName $f.Name -All -NoRestart -ErrorAction Stop
  } catch {
    Fail -Ctx $Ctx -Problem "enabling $($f.Label) failed: $($_.Exception.Message)" `
      -Action "run in an ELEVATED PowerShell. If it still fails, enable it in 'Turn Windows features on or off' and re-run." -Code 1
  }
  $changed = $true
  if($r.RestartNeeded){ $needReboot = $true }

  # Read the state back. DISM reports success for a feature that is only staged.
  $after = (Get-WindowsOptionalFeature -Online -FeatureName $f.Name -ErrorAction SilentlyContinue).State
  if($after -eq 'Enabled'){
    Ok $Ctx "$($f.Label) enabled (read back from DISM)"
    Add-Result $Ctx $f.Name 'pass' 'enabled' ''
  } elseif($after -match 'Pending'){
    Say $Ctx "$($f.Label) is '$after' — it takes effect on reboot"
    $needReboot = $true
    Add-Result $Ctx $f.Name 'warn' "state '$after' — reboot required" 'reboot and re-run install.ps1'
  } else {
    Undetermined -Ctx $Ctx -What "whether $($f.Label) was enabled (DISM now reports '$after')" `
      -Action "check 'Turn Windows features on or off', enable it there, reboot, and re-run"
  }
}

if($needReboot){
  $resume = './install.ps1'
  if($Ctx.NonInteractive){ $resume = './install.ps1 -NonInteractive -Scope ' + $Cfg.scope }
  Write-JLine $Ctx ''
  Write-JLine $Ctx '*******************************************************************************'
  Write-JLine $Ctx '*  A REBOOT IS REQUIRED. THE INSTALL IS NOT FINISHED AND IS STOPPING HERE.    *'
  Write-JLine $Ctx '*******************************************************************************'
  Write-JLine $Ctx ''
  Write-JLine $Ctx '  Windows enabled the WSL / Virtual Machine Platform features but they do not'
  Write-JLine $Ctx '  take effect until the machine restarts. Nothing has been registered with'
  Write-JLine $Ctx '  GitHub, no runner exists yet, and no scheduled task has been created.'
  Write-JLine $Ctx ''
  Write-JLine $Ctx '  RESUME, in this order:'
  Write-JLine $Ctx '    1. Restart-Computer'
  Write-JLine $Ctx ("    2. re-run, elevated:  " + $resume)
  Write-JLine $Ctx ''
  Write-JLine $Ctx '  Re-running is safe: every step detects what is already done and converges.'
  Write-JLine $Ctx '  Your registration token has almost certainly expired by then (~1h) — mint a'
  Write-JLine $Ctx '  fresh one for the resumed run.'
  Write-JLine $Ctx ''
  Add-Result $Ctx 'reboot' 'fail' 'a reboot is required before the install can continue' 'Restart-Computer, then re-run install.ps1'
  Fail -Ctx $Ctx -Problem 'reboot required to finish enabling the WSL features' `
    -Action 'Restart-Computer, then re-run install.ps1 (it resumes; nothing is half-registered)' -Code 1
}

if(-not $changed){ Ok $Ctx 'both Windows features were already enabled — nothing to do' }
