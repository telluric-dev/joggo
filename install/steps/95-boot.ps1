param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 95-boot — survive logout and reboot, then start the slots.
#
# THE BIG WSL2-SPECIFIC ONE. WSL2 shuts the VM down shortly after its last
# process exits, or when the user logs off. systemd inside the distro does NOT
# prevent that — it cannot, it is inside the thing being shut down. So docker,
# the runner and every slot unit are correctly configured and simply gone the
# moment nobody is logged in. The fix is a Windows task that holds the distro
# open: `wsl --exec sleep infinity`, as SYSTEM, at startup.
#
# This is docs/runner-setup.md §11.2, and it is the step whose absence makes a
# runner that works while you watch it and stops when you go home.

Step-Header $Ctx '95-boot'

$taskName = 'joggo-wsl-keepalive'
$keepArgs = ('-d {0} --exec sleep infinity' -f $Cfg.distro)

if(-not $Cfg.startOnBoot){
  Warn $Ctx '-NoStartOnBoot: no keepalive task. WSL powers the distro off about 30 seconds after the last session into it closes,'
  Say  $Ctx '  and CI stops with it -- measured: right after this installer exits. Units are still enabled, but nothing holds the distro up.'
  Add-Result $Ctx 'keepalive' 'warn' 'startOnBoot disabled; nothing holds the WSL2 VM open' 're-run without -NoStartOnBoot'
} else {
  if($Ctx.DryRun){
    Plan $Ctx "would register scheduled task '$taskName' as SYSTEM at startup: wsl.exe $keepArgs"
    Plan $Ctx '  with -RestartCount 999 -RestartInterval 1min, so a VM restart (including one the guard performs) is re-held'
    Plan $Ctx "would then read the task back and confirm distro '$($Cfg.distro)' is Running"
  } else {
    $exe = (Get-Command wsl.exe -ErrorAction SilentlyContinue)
    if(-not $exe){
      Undetermined -Ctx $Ctx -What 'the path to wsl.exe for the keepalive task' -Action 'repair WSL (step 10), reboot, and re-run'
    }
    # TWO VARIANTS, chosen by elevation, because the alternative was no keepalive at all.
    #
    # Elevated: SYSTEM, at startup -- holds the distro with nobody logged on. The right one.
    #
    # Not elevated: the installing user, at THEIR logon. Any user may register a task that runs
    # as themselves, so this needs no admin. It holds the distro while that user is logged in
    # and comes back at their next logon after a reboot. Without it, an unelevated install
    # passed verify and then went offline: WSL powered the distro off 32 seconds after the
    # installer's last session closed (journal: "systemd-logind: The system will power off
    # now!"), measured on the first real unelevated run.
    #
    # Launched through `conhost --headless` in the user variant: a wsl.exe started in an
    # interactive session would otherwise hold a console window open on the desktop forever.
    $admin = Test-Admin
    if($admin){
      $action    = New-ScheduledTaskAction -Execute $exe.Source -Argument $keepArgs
      $trigger   = New-ScheduledTaskTrigger -AtStartup
      $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
      $who = $null
    } else {
      $who       = [Security.Principal.WindowsIdentity]::GetCurrent().Name
      $conhost   = Join-Path $env:WINDIR 'System32\conhost.exe'
      $action    = New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "{0}" {1}' -f $exe.Source, $keepArgs)
      $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $who
      $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited
      Warn $Ctx "not elevated: the keepalive runs as $who at logon, so CI is up while you are logged in and returns at your next logon after a reboot."
      Say  $Ctx '  for a runner that works with nobody logged on, re-run elevated: the keepalive is then SYSTEM at startup.'
    }
    # RestartCount/RestartInterval matter here and nowhere else: this task is
    # SUPPOSED to run forever, so if it ever exits — because the VM went down,
    # including a restart the memory guard performed on purpose — something has
    # to put it back. ExecutionTimeLimit 0 so the scheduler never kills it.
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                   -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
                   -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    try {
      Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'joggo: hold the WSL2 distro open so CI survives logout and reboot.' -Force -ErrorAction Stop | Out-Null
    } catch {
      Fail -Ctx $Ctx -Problem "registering '$taskName' failed: $($_.Exception.Message)" -Action 'run install.ps1 in an ELEVATED PowerShell' -Code 1
    }
    if($who){ [void](Assert-JoggoTask -Ctx $Ctx -Name $taskName -ExpectUser $who) }
    else    { [void](Assert-JoggoTask -Ctx $Ctx -Name $taskName) }

    # Start it and check the state that is CORRECT for this task: Running, and
    # staying that way. LastTaskResult is the wrong instrument here — a task
    # that holds a VM open has no completed run to report, and waiting for one
    # would time out on a healthy install.
    try { Start-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch {
      Fail -Ctx $Ctx -Problem "could not start '$taskName': $($_.Exception.Message)" -Action "Start-ScheduledTask -TaskName $taskName" -Code 1
    }
    $deadline = (Get-Date).AddSeconds(90); $state = ''
    while((Get-Date) -lt $deadline){
      $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
      if($state -eq 'Running'){ break }
      Start-Sleep -Seconds 3
    }
    if($state -ne 'Running'){
      Undetermined -Ctx $Ctx -What "whether the keepalive is holding the distro open (the task state is '$state', not Running)" `
        -Action "start it by hand and watch: Start-ScheduledTask -TaskName $taskName ; Get-ScheduledTask -TaskName $taskName"
    }
    Ok $Ctx "'$taskName' is Running — which is the correct steady state for it, not a completed run"

    $d = @((Get-WslDistros -Ctx $Ctx) | Where-Object { $_.name -eq $Cfg.distro })[0]
    if($null -eq $d){
      Undetermined -Ctx $Ctx -What "the state of distro '$($Cfg.distro)' after starting the keepalive" -Action 'run: wsl -l -v'
    }
    if($d.state -ne 'Running'){
      Fail -Ctx $Ctx -Problem "the keepalive task is Running but distro '$($Cfg.distro)' reports '$($d.state)'" `
        -Action "check the task's action by hand: wsl.exe $keepArgs" -Code 1
    }
    Ok $Ctx "distro '$($Cfg.distro)' is Running — the effect, read from wsl.exe rather than inferred from the task"
    if($who){ Add-Result $Ctx 'keepalive' 'warn' "$taskName Running as $who at logon (not elevated); distro Running" 're-run elevated for a SYSTEM keepalive that works with nobody logged on' }
    else    { Add-Result $Ctx 'keepalive' 'pass' "$taskName Running as SYSTEM at startup; distro Running" '' }
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
