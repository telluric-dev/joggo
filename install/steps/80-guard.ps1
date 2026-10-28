param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 80-guard — the memory guard and the 5-minute sampler, AS SCHEDULED TASKS.
#
# THIS IS THE GAP THE REPO HAD. guard/wsl-mem-guard.ps1's own usage line says
# "what the task runs", and nothing in this repository ever created that task.
# So a user got the guard's code, its thresholds, its measurements and its log
# format — and never a running guard. Same for guard/mem-watch.ps1: the sampler
# that produces the 5-minute trail every post-mortem in docs/memory-pressure.md
# depends on.
#
# Both tasks run as the INSTALLING USER, every N minutes and at logon -- the shape of the
# guard this was extracted from, which has paused slots and restarted WSL in production. Not
# SYSTEM: WSL distros are per Windows user, so a SYSTEM guard's `wsl -d <distro>` -- every
# call it makes to pause a slot or read the job count -- finds no distro. The first elevated
# install registered them as SYSTEM, and its keepalive (same principal) exited -1 at once.
# -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries because the scheduler's DEFAULT is to
# stop a task on battery, which would silently remove the guard from a laptop at the exact
# moment power got interesting.
#
# And both are READ BACK afterwards: registered, enabled, the right user, repeating at the
# right interval, and actually executed with result 0. Register-ScheduledTask returning
# without throwing proves none of that.

Step-Header $Ctx '80-guard'

if(-not $Cfg.guard -and -not $Cfg.sampler){
  Skip $Ctx 'guard and sampler both disabled — nothing scheduled'
  Warn $Ctx 'nothing now watches memory on this box. The guard is what stops the WSL2 VM starving Windows; see docs/memory-pressure.md.'
  Add-Result $Ctx 'guard' 'warn' 'guard and sampler both disabled' 're-run without -NoGuard'
  return
}

$ps = Get-JoggoPowerShellExe
if(-not $ps -and -not $Ctx.DryRun){
  Undetermined -Ctx $Ctx -What 'a powershell.exe to point the scheduled tasks at' `
    -Action 'the tasks cannot be created without one. Repair Windows PowerShell, or install PowerShell and re-run.'
}

$bin = $Ctx.BinDir

# CAN THE TASKS WRITE THEIR OWN FILES? They run as you, and the data directory may hold files
# created by someone else: an earlier version of joggo ran these tasks as SYSTEM, and anything
# an ELEVATED process creates is owned by Administrators. A Limited user may create new files
# in C:\ProgramData\joggo but may not modify ones it does not own -- so the sampler ran, could
# not append, and the trail silently stopped. Checked before registering anything: elevated,
# fix it (grant this user Modify on the directory tree); not elevated, stop and name the fix.
if(-not $Ctx.DryRun -and (Test-Path $Ctx.DataDir)){
  $who = Get-JoggoTaskUser
  $locked = @(Get-ChildItem $Ctx.DataDir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
    $ok = $true
    try { $fs = [IO.File]::Open($_.FullName, 'Open', 'ReadWrite', 'ReadWrite'); $fs.Close() } catch { $ok = $false }
    -not $ok
  })
  if($locked.Count -gt 0){
    $names = ($locked | ForEach-Object { $_.FullName.Substring($Ctx.DataDir.Length).TrimStart('\') }) -join ', '
    $fix = 'icacls "{0}" /grant "{1}:(OI)(CI)M" /T' -f $Ctx.DataDir, $who
    if(Test-Admin){
      Say $Ctx "granting $who write access to $($Ctx.DataDir): $($locked.Count) file(s) there are owned by another account ($names)"
      & icacls.exe $Ctx.DataDir /grant ("{0}:(OI)(CI)M" -f $who) /T /Q | Out-Null
      $still = @($locked | Where-Object { try { $f=[IO.File]::Open($_.FullName,'Open','ReadWrite','ReadWrite'); $f.Close(); $false } catch { $true } })
      if($still.Count -gt 0){ Fail -Ctx $Ctx -Problem "still cannot write $($still.Count) file(s) in $($Ctx.DataDir) after granting access" -Action "run by hand, elevated: $fix" -Code 1 }
      Ok $Ctx "$who can write every file in $($Ctx.DataDir)"
    } else {
      Fail -Ctx $Ctx -Problem "$($locked.Count) file(s) in $($Ctx.DataDir) belong to another account, and the guard/sampler (running as $who) could not write them: $names" `
        -Action "run once in an ELEVATED PowerShell, then re-run this installer:  $fix   (they are the old memory trail; deleting them works too)" -Code 1
    }
  }
}

# The task must not depend on where the repo was cloned. A task pointed at
# C:\Users\someone\Downloads\joggo is a task that breaks the day that directory
# is tidied up, and it breaks silently.
function Install-GuardScript {
  param([string]$Rel)
  $src = Join-Path $Ctx.RepoRoot $Rel
  $dst = Join-Path $bin (Split-Path $Rel -Leaf)
  if(-not (Test-Path $src)){
    Fail -Ctx $Ctx -Problem "missing from the checkout: $Rel" -Action 'run install.ps1 from a complete checkout' -Code 1
  }
  if($Ctx.DryRun){ Plan $Ctx "would copy $Rel -> $dst"; return $dst }
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  Copy-Item -Path $src -Destination $dst -Force
  # Compare hashes, not timestamps. A half-written copy and a successful one both
  # leave a file behind.
  $a = (Get-FileHash -Path $src -Algorithm SHA256).Hash
  $b = (Get-FileHash -Path $dst -Algorithm SHA256).Hash
  if($a -ne $b){
    Undetermined -Ctx $Ctx -What "whether $Rel copied intact (the hashes differ)" -Action "copy it by hand: Copy-Item '$src' '$dst'"
  }
  Ok $Ctx "installed $dst (SHA256 matches the source)"
  return $dst
}

# ---------------------------------------------------------------- the guard
if($Cfg.guard){
  $guardPath = Install-GuardScript -Rel 'guard\wsl-mem-guard.ps1'
  $gArgs = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -WarnMB {1} -CriticalMB {2} -Distro "{3}"' -f `
            $guardPath, [int]$Cfg.guardWarnMB, [int]$Cfg.guardCriticalMB, $Cfg.distro)

  Say $Ctx ("thresholds: warn {0} MB, critical {1} MB — 15% and 7.5% of this box's {2} MB." -f $Cfg.guardWarnMB, $Cfg.guardCriticalMB, $Cfg.ramMB)
  Say $Ctx '  those ratios reproduce 2500/1200, which is where they were measured. They are not knobs to turn to make a symptom go away.'

  [void](Register-JoggoTask -Ctx $Ctx -Name 'joggo-mem-guard' -Exe $ps -Arguments $gArgs `
    -EveryMinutes ([int]$Cfg.guardIntervalMin) `
    -Description 'joggo: hold the runner slots, then restart the WSL2 VM, before it starves Windows of memory.')
  [void](Assert-JoggoTask -Ctx $Ctx -Name 'joggo-mem-guard' -EveryMinutes ([int]$Cfg.guardIntervalMin))

  if($Ctx.DryRun){
    Plan $Ctx 'would run joggo-mem-guard once and read LastRunTime/LastTaskResult back from the scheduler'
  } else {
    # PROVING IT RAN MEANS RUNNING IT, and the guard ACTS. Above the warn line it
    # is a no-op by its own logic, so kicking it there is free. Below the warn
    # line it would hold the slots — and possibly restart the VM — so it is not
    # kicked, and that is said out loud rather than quietly skipped.
    $free = 0
    try { $free = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) } catch { $free = -1 }
    if($free -lt 0){
      Undetermined -Ctx $Ctx -What 'available memory, so whether running the guard now would be a no-op' `
        -Action "check by hand, then run it once: Start-ScheduledTask -TaskName joggo-mem-guard ; Get-ScheduledTaskInfo -TaskName joggo-mem-guard"
    } elseif($free -ge [int]$Cfg.guardWarnMB){
      Say $Ctx "available memory is $free MB, above the $($Cfg.guardWarnMB) MB warn line — a guard pass here is a no-op, so it is safe to prove it runs."
      [void](Assert-JoggoTaskHasRun -Ctx $Ctx -Name 'joggo-mem-guard' -WaitSec 180)
    } else {
      # The script is still proved to be executable, just not through the
      # scheduler: -Status reads state and changes nothing.
      Warn $Ctx "available memory is $free MB, BELOW the $($Cfg.guardWarnMB) MB warn line."
      Say  $Ctx 'Running the guard right now would hold the slots and possibly restart the VM, so this install will not do that behind your back.'
      & $ps -NoProfile -ExecutionPolicy Bypass -File $guardPath -Status -WarnMB ([int]$Cfg.guardWarnMB) -CriticalMB ([int]$Cfg.guardCriticalMB) -Distro $Cfg.distro 2>&1 |
        ForEach-Object { Say $Ctx $_ }
      if($LASTEXITCODE -ne 0){
        Fail -Ctx $Ctx -Problem 'the guard script itself failed to run (-Status, which only reads state)' `
          -Action "run it by hand and read the error: & '$ps' -File '$guardPath' -Status" -Code 1
      }
      Ok $Ctx 'the guard script runs (proved with -Status, which changes nothing).'
      Say $Ctx "Its first scheduled pass lands within $($Cfg.guardIntervalMin) min. Confirm it then:"
      Say $Ctx '  Get-ScheduledTaskInfo -TaskName joggo-mem-guard   # LastTaskResult 0'
      Add-Result $Ctx 'guard.run' 'warn' "task scheduled; its proving run was deferred because free memory ($free MB) is below the warn line" 'Get-ScheduledTaskInfo -TaskName joggo-mem-guard after the next interval'
    }
  }
  Add-Result $Ctx 'guard' 'pass' "joggo-mem-guard every $($Cfg.guardIntervalMin) min as the installing user, warn $($Cfg.guardWarnMB) / critical $($Cfg.guardCriticalMB)" ''
} else {
  Skip $Ctx 'guard disabled (-NoGuard)'
  Add-Result $Ctx 'guard' 'warn' 'guard disabled' ''
}

# ---------------------------------------------------------------- the sampler
if($Cfg.sampler){
  $watchPath = Install-GuardScript -Rel 'guard\mem-watch.ps1'
  # -Distro, in step with the guard above. mem-watch.ps1 used to hardcode 'Ubuntu' at
  # its one probe site, so there was no parameter to pass and nothing to notice: a box
  # whose distro is named anything else got a sampler that wrote Windows-side numbers
  # and left every VM column empty — a trail that reads like a working sampler on a
  # machine with no WSL memory in it. Both halves are fixed; keep them in step.
  $wArgs = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Quiet -Distro "{1}"' -f $watchPath, $Cfg.distro)

  # FIVE MINUTES, fixed, not guardIntervalMin. The trail's value is its
  # resolution: every finding in docs/memory-pressure.md — the terminal emulator
  # leaking 24.2 MB/hour, the chrome spike that drove a pointless WSL restart —
  # came out of 5-minute samples. A coarser trail would not have shown them.
  [void](Register-JoggoTask -Ctx $Ctx -Name 'joggo-mem-watch' -Exe $ps -Arguments $wArgs -EveryMinutes 5 `
    -Description 'joggo: sample memory every 5 minutes and snapshot full state when it turns.')
  [void](Assert-JoggoTask -Ctx $Ctx -Name 'joggo-mem-watch' -EveryMinutes 5)

  if($Ctx.DryRun){
    Plan $Ctx 'would run joggo-mem-watch once and confirm a new row appeared in mem-watch.csv'
  } else {
    # The sampler is read-only on the Windows side and cannot hang (that is a
    # documented design decision in its header), so it is always safe to kick.
    $csv = Join-Path $Ctx.DataDir 'mem-watch.csv'
    $before = 0
    if(Test-Path $csv){ $before = @(Get-Content $csv).Count }
    [void](Assert-JoggoTaskHasRun -Ctx $Ctx -Name 'joggo-mem-watch' -WaitSec 180)
    # The scheduler saying "ran, result 0" is one instrument. The CSV growing is
    # a second one, at a different layer, and it is the thing the sampler is
    # FOR — a task that runs and writes nothing is not a working sampler.
    $after = 0
    if(Test-Path $csv){ $after = @(Get-Content $csv).Count }
    if($after -le $before){
      Undetermined -Ctx $Ctx -What "whether the sampler actually sampled (mem-watch.csv went from $before to $after rows)" `
        -Action "run it by hand and read the error: & '$ps' -File '$watchPath'"
    }
    Ok $Ctx "mem-watch.csv grew from $before to $after rows — the sampler wrote a real sample, not just exited 0"
    Say $Ctx "trail: $csv ; snapshots: $(Join-Path $Ctx.DataDir 'snapshots')"
  }
  Add-Result $Ctx 'sampler' 'pass' 'joggo-mem-watch every 5 min as the installing user, verified by a new CSV row' ''
} else {
  Skip $Ctx 'sampler disabled (-NoSampler)'
  Add-Result $Ctx 'sampler' 'warn' 'sampler disabled' ''
}
