param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 95-boot — keep the distro up, then start the slots.
#
# THE BIG WSL2-SPECIFIC ONE. WSL powers a distro off about 30 seconds after the last session
# into it closes -- measured: right after this installer exits ("systemd-logind: The system
# will power off now!"). systemd inside the distro cannot prevent it; it is inside the thing
# being shut down. So docker, the runner and every slot are correctly configured and simply
# gone. The fix is a Windows task that holds a session open: `wsl --exec sleep infinity`.
#
# AS THE INSTALLING USER, AT LOGON -- ALWAYS, elevated or not. This used to be SYSTEM at
# startup, meant to work with nobody logged on, and it cannot: WSL distros are registered per
# Windows user, so a SYSTEM task does not see the user's distro at all. On the first elevated
# install it started, exited -1 (4294967295) within seconds, and this step still passed
# because it caught the task in "Running" for the moment it took to fail. The machine this
# was extracted from settled the same question the hard way: of its five keepalive attempts
# the one that works is the user's, Interactive, at logon; the boot-trigger one fails with 1.
#
# So the box must stay logged in -- lock the screen, do not log off. Auto-logon, if you want
# CI back after a reboot without anyone signing in, is a Windows setting this does not make.
#
# Launched through `conhost --headless`, or wsl.exe would hold a console window on the
# desktop for as long as the session lasts.

Step-Header $Ctx '95-boot'

$taskName = 'joggo-wsl-keepalive'
$keepArgs = ('-d {0} --exec sleep infinity' -f $Cfg.distro)

if(-not $Cfg.startOnBoot){
  Warn $Ctx '-NoStartOnBoot: no keepalive task. WSL powers the distro off about 30 seconds after the last session into it closes,'
  Say  $Ctx '  and CI stops with it -- measured: right after this installer exits. Units are still enabled, but nothing holds the distro up.'
  Add-Result $Ctx 'keepalive' 'warn' 'startOnBoot disabled; nothing holds the WSL2 VM open' 're-run without -NoStartOnBoot'
} else {
  $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  if($Ctx.DryRun){
    Plan $Ctx "would register scheduled task '$taskName' as $who at logon: conhost --headless wsl.exe $keepArgs"
    Plan $Ctx '  with -RestartCount 999 -RestartInterval 1min, so a VM restart (including one the guard performs) is re-held'
    Plan $Ctx "would then confirm it is STILL Running 20s later, and that distro '$($Cfg.distro)' is Running"
  } else {
    $exe = (Get-Command wsl.exe -ErrorAction SilentlyContinue)
    if(-not $exe){
      Undetermined -Ctx $Ctx -What 'the path to wsl.exe for the keepalive task' -Action 'repair WSL (step 10), reboot, and re-run'
    }
    $conhost   = Join-Path $env:WINDIR 'System32\conhost.exe'
    $action    = New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "{0}" {1}' -f $exe.Source, $keepArgs)
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $who
    $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited
    # RestartCount/RestartInterval: this task is SUPPOSED to run forever, so if it ever exits --
    # because the VM went down, including a restart the memory guard performed on purpose --
    # something has to put it back. ExecutionTimeLimit 0 so the scheduler never kills it.
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                   -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
                   -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    try {
      Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'joggo: hold the WSL2 distro open so CI keeps running while this user is logged in.' -Force -ErrorAction Stop | Out-Null
    } catch {
      Fail -Ctx $Ctx -Problem "registering '$taskName' failed: $($_.Exception.Message)" -Action 'check Task Scheduler is running, then re-run' -Code 1
    }
    [void](Assert-JoggoTask -Ctx $Ctx -Name $taskName -ExpectUser $who)

    try { Start-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch {
      Fail -Ctx $Ctx -Problem "could not start '$taskName': $($_.Exception.Message)" -Action "Start-ScheduledTask -TaskName $taskName" -Code 1
    }
    # STILL RUNNING, NOT JUST RUNNING ONCE. A keepalive that cannot reach its distro starts,
    # shows "Running" for a moment, and exits -- the SYSTEM variant did exactly that and passed
    # a single read. Require Running now AND 20 seconds later.
    $deadline = (Get-Date).AddSeconds(90); $state = ''
    while((Get-Date) -lt $deadline){
      $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
      if($state -eq 'Running'){ break }
      Start-Sleep -Seconds 3
    }
    if($state -eq 'Running'){ Start-Sleep -Seconds 20; $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State }
    if($state -ne 'Running'){
      $res = (Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue).LastTaskResult
      Fail -Ctx $Ctx -Problem "the keepalive did not stay running (state '$state', last result $res)" `
        -Action "run its action by hand as $who and read the error: wsl.exe $keepArgs" -Code 1
    }
    Ok $Ctx "'$taskName' is Running as $who, and still Running 20s later"

    $d = @((Get-WslDistros -Ctx $Ctx) | Where-Object { $_.name -eq $Cfg.distro })[0]
    if($null -eq $d){
      Undetermined -Ctx $Ctx -What "the state of distro '$($Cfg.distro)' after starting the keepalive" -Action 'run: wsl -l -v'
    }
    if($d.state -ne 'Running'){
      Fail -Ctx $Ctx -Problem "the keepalive task is Running but distro '$($Cfg.distro)' reports '$($d.state)'" `
        -Action "check the task's action by hand: wsl.exe $keepArgs" -Code 1
    }
    Ok $Ctx "distro '$($Cfg.distro)' is Running — the effect, read from wsl.exe rather than inferred from the task"
    Say $Ctx "  CI runs while $who is logged in. Lock the screen rather than logging off."
    Add-Result $Ctx 'keepalive' 'pass' "$taskName Running as $who at logon; distro Running" ''
  }
}

# Windows sleep. §2.4's systemctl mask only covers the Linux side; if WINDOWS
# sleeps, the VM suspends and CI stops regardless. Preflight checks this and can
# fail on it, so here it is only re-stated for the record.
if(-not $Ctx.DryRun){
  $plan = ''
  try { $plan = (& powercfg /getactivescheme 2>&1) -join ' ' } catch { $plan = '' }
  if($plan){ Say $Ctx ("active power plan: " + ($plan -replace '\s+',' ')) }
  Say $Ctx 'if Windows sleeps, the WSL2 VM suspends and CI stops. Settings -> System -> Power -> Sleep = Never.'
}

# ---- the Linux side: enable for boot, start now, and judge it correctly ----
if($Ctx.DryRun){
  Plan $Ctx "would enable and start joggo-slot@1..$($Cfg.slots) and docker.service"
  Plan $Ctx '  and judge each slot on enabled + (active|activating), NOT on "active" alone:'
  Plan $Ctx '  with run.sh --once a slot is genuinely inactive for a second or two between every job'
  Add-Result $Ctx 'boot' 'pass' 'dry run' ''
  return
}

$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'boot' -TimeoutSec 600
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem 'the slot units did not come up' `
    -Action 'the journal excerpt above names the cause.' -Code 1
}
Add-Result $Ctx 'boot' 'pass' "$($Cfg.slots) slot unit(s) enabled and started" ''
