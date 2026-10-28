<#
  wsl-mem-guard.ps1 — keep Windows out of memory starvation caused by the WSL2 VM.

  THE PROBLEM THIS SOLVES
  -----------------------
  WSL2 does not hand freed pages back to Windows. Measured on this box 2026-10-13:

      inside the VM   828 MB used, 7089 MB available
      Windows sees    vmmemWSL holding 3251 MB

  The VM had already released that memory internally; Windows still counted it. Every
  CI job pulls images and writes page cache, so vmmemWSL ratchets upward over days
  until Windows has nothing left and the box dies. Nothing inside the VM looks wrong
  while it happens, which is why it is hard to catch by hand.

  WHAT THIS DOES, AND THE ORDER MATTERS
  -------------------------------------
  It runs on the WINDOWS side, because it has to work when the VM is the thing that
  is sick, and only Windows can `wsl --shutdown`.

      free >= WarnMB        nothing. If it had paused slots itself, it resumes them.
      free <  WarnMB        HOLD: pause every running slot so no NEW job starts, and
                            let whatever is running finish. Re-checked each tick.
      free <  CriticalMB    RESTART NOW, even mid-job. Losing one job beats losing the
                            box, and the job is re-runnable; a hard crash is not.
      held longer than
      DrainMinutes          RESTART. A slot holding a 2h suite would otherwise keep the
                            box in the danger zone indefinitely.

  WHY IT PAUSES BEFORE IT RESTARTS. `wsl --shutdown` kills in-flight jobs outright —
  GitHub reports "The self-hosted runner lost communication with the server" and the
  work is lost. Pausing first means the common case costs nothing: the slots stop
  taking NEW jobs, the current ones finish, and the restart lands on an idle box.

  IT ONLY RESUMES WHAT IT PAUSED. A slot the operator held deliberately stays held —
  the guard records its own holds in the state file and touches nothing else.

  THIS IS A BACKSTOP, NOT THE FIX. The cheaper controls are in .wslconfig: a `memory=`
  cap bounds the VM so it cannot starve Windows in the first place, and
  `autoMemoryReclaim` makes the VM hand pages back. The config explains why reclaim is
  off here. Prefer the cap; keep this for the case the cap is still too generous.

  Usage:
      wsl-mem-guard.ps1                 one pass, act if needed  (what the task runs)
      wsl-mem-guard.ps1 -DryRun         report what it WOULD do, change nothing
      wsl-mem-guard.ps1 -Status         print current state and exit
#>
param(
  # Below this, stop taking new jobs. ~15% of 16GB.
  [int]$WarnMB = 2500,
  # Below this, restart regardless of what is running.
  [int]$CriticalMB = 1200,
  # How long to tolerate the held state before restarting anyway.
  [int]$DrainMinutes = 45,
  # Never restart twice inside this window — stops a thrash loop if a restart does
  # not actually recover the memory (e.g. the pressure is Windows-side, not WSL).
  [int]$CooldownMinutes = 90,
  [string]$Distro = "Ubuntu",
  [string]$StateFile = "$env:ProgramData\joggo\wsl-mem-guard.state.json",
  [string]$LogFile   = "$env:ProgramData\joggo\wsl-mem-guard.log",
  [switch]$DryRun,
  [switch]$Status
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $StateFile) | Out-Null

function Log([string]$m){
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $m
  Write-Host $line
  try { Add-Content -Path $LogFile -Value $line -Encoding utf8 } catch {}
}

function Get-FreeMB {
  $os = Get-CimInstance Win32_OperatingSystem
  [int]($os.FreePhysicalMemory / 1KB)
}

function Get-VmmemMB {
  $p = Get-Process -Name 'vmmemWSL','vmmem' -ErrorAction SilentlyContinue |
       Sort-Object WorkingSet64 -Descending | Select-Object -First 1
  if($p){ [int]($p.WorkingSet64 / 1MB) } else { 0 }
}

# Every wsl.exe call here is bounded. The whole point of this script is to work when
# the VM is unwell, and an unbounded call would hang the guard exactly then.
function Invoke-Wsl([string]$cmd, [int]$TimeoutSec = 25){
  # Start-Process with an ARRAY -ArgumentList, not ProcessStartInfo.ArgumentList: the latter
  # is .NET Core only and is $null on the .NET Framework that Windows PowerShell 5.1 runs on.
  # The array form also quotes each argument itself, which keeps the shell command intact —
  # hand-building one string is how `$( )` and spaces get mangled on the way to wsl.exe.
  # THE COMMAND TRAVELS AS BASE64. Quoting a shell command through PowerShell's native
  # argument packing and then through wsl.exe has failed in this repo repeatedly and
  # silently: a single-quoted glob was swallowed here, so `systemctl list-units
  # 'joggo-slot@*'` arrived with no pattern and matched EVERY unit on the box. The guard
  # read that as "no slots" and would have skipped straight past the hold to a restart.
  # Base64 is [A-Za-z0-9+/=] only, so there is nothing left for either layer to eat.
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd))

  # ProcessStartInfo.Arguments (a STRING), not Start-Process -ArgumentList: on PS 5.1
  # Start-Process -PassThru leaves ExitCode empty and can hand back empty redirect files
  # even after WaitForExit says the process finished. Building the string by hand is only
  # safe because $b64 is alphanumeric — there is nothing in it to quote.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = 'wsl.exe'
  $psi.Arguments = "-d $Distro -u root bash -c `"echo $b64 | base64 -d | bash`""
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow  = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  # Async readers with a StringBuilder: reading both streams synchronously can deadlock
  # when one fills its pipe buffer while we are blocked on the other.
  $sbO = New-Object System.Text.StringBuilder
  $sbE = New-Object System.Text.StringBuilder
  $hO = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action { if($null -ne $EventArgs.Data){ [void]$Event.MessageData.AppendLine($EventArgs.Data) } } -MessageData $sbO
  $hE = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived  -Action { if($null -ne $EventArgs.Data){ [void]$Event.MessageData.AppendLine($EventArgs.Data) } } -MessageData $sbE
  try {
    [void]$p.Start()
    $p.BeginOutputReadLine(); $p.BeginErrorReadLine()
    if(-not $p.WaitForExit($TimeoutSec * 1000)){
      try { $p.Kill() } catch {}
      return [pscustomobject]@{ ok=$false; out=''; err="timed out after ${TimeoutSec}s" }
    }
    Start-Sleep -Milliseconds 120   # let the async handlers drain the last lines
    [pscustomobject]@{ ok = ($p.ExitCode -eq 0); out = $sbO.ToString().Trim(); err = $sbE.ToString().Trim() }
  } finally {
    Unregister-Event -SourceIdentifier $hO.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $hE.Name -ErrorAction SilentlyContinue
    $p.Dispose()
  }
}

function Get-RunningJobs {
  # grep -c with the bracket trick so the grep itself is not counted.
  $r = Invoke-Wsl "ps -eo cmd | grep -ac '[R]unner.Worker' || true" 15
  if(-not $r.ok -and -not $r.out){ return -1 }   # -1 = unknown, treat as "cannot confirm idle"
  $n = 0; [void][int]::TryParse(($r.out -split "`n")[0].Trim(), [ref]$n)
  $n
}

function Get-Slots {
  # Slot numbers from systemd, so this follows the box rather than a hardcoded list.
  $r = Invoke-Wsl "systemctl list-units 'joggo-slot@*' --all --no-legend --no-pager 2>/dev/null | sed -E 's/^[^a-z]*joggo-slot@([0-9]+)\.service.*/\1/'" 15
  if(-not $r.ok){ return @() }
  @($r.out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
}

function Get-PausedSlots {
  $r = Invoke-Wsl "ls /var/lib/ci-slot/ 2>/dev/null | grep -E '^[0-9]+\.paused' | sed 's/\.paused//'" 15
  if(-not $r.ok){ return @() }
  @($r.out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
}

function Read-State {
  if(Test-Path $StateFile){ try { return (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch {} }
  [pscustomobject]@{ heldSince = $null; heldSlots = @(); lastRestart = $null }
}
function Write-State($s){ $s | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding utf8 }

# ---------------------------------------------------------------- the pass
$free   = Get-FreeMB
$vmmem  = Get-VmmemMB
$jobs   = Get-RunningJobs
$state  = Read-State

if($Status){
  "free        : $free MB   (warn $WarnMB, critical $CriticalMB)"
  "vmmemWSL    : $vmmem MB"
  "jobs in run : $(if($jobs -lt 0){'unknown — WSL did not answer'}else{$jobs})"
  "held since  : $(if($state.heldSince){$state.heldSince}else{'not held'})"
  "held slots  : $(if($state.heldSlots){($state.heldSlots -join ', ')}else{'none'})"
  "last restart: $(if($state.lastRestart){$state.lastRestart}else{'never'})"
  "log         : $LogFile"
  exit 0
}

# ---- healthy: release any hold this guard placed, and leave ----
if($free -ge $WarnMB){
  if($state.heldSince){
    Log "RECOVERED free=${free}MB vmmem=${vmmem}MB — releasing the slots this guard held: $($state.heldSlots -join ', ')"
    foreach($s in @($state.heldSlots)){
      if($DryRun){ Log "  [dry-run] would resume slot $s" ; continue }
      $r = Invoke-Wsl "if [ -x /usr/local/sbin/ci-pause ]; then /usr/local/sbin/ci-pause resume --slot $s || true; else rm -f /var/lib/ci-slot/$s.paused; fi" 60
      Log "  resumed slot $s$(if(-not $r.ok){' (reported: ' + $r.err + ')'})"
    }
    $state.heldSince = $null; $state.heldSlots = @(); Write-State $state
  }
  exit 0
}

# ---- below the warn line ----
$critical = ($free -lt $CriticalMB)
Log "LOW free=${free}MB vmmem=${vmmem}MB jobs=$jobs warn=$WarnMB critical=$CriticalMB$(if($critical){' CRITICAL'})"

# ---- STEP ZERO: give the page cache back before considering anything disruptive ----
#
# Measured on this box 2026-10-13, slots idle:
#
#     VM genuinely in use   820 MB
#     page cache           2209 MB
#     vmmemWSL  3269 MB -> 2383 MB after `echo 3 > drop_caches`   (886 MB returned)
#
# The ratchet is mostly page cache from image pulls and test IO, and WSL hands those
# pages back to Windows when the VM frees them. So the cheapest fix is also the only
# one that costs no jobs: no pause, no restart, nothing killed. It is tried FIRST and
# every time, and the pass exits here if it recovers enough.
#
# The cost is real but small and self-correcting: the next read re-faults from disk.
# That is why it is not run on a schedule — only under pressure, where paying some
# disk reads plainly beats pausing the box or killing a job.
if(-not $DryRun){
  $r = Invoke-Wsl "sync; echo 3 > /proc/sys/vm/drop_caches; echo dropped" 60
  Start-Sleep -Seconds 5
  $freeAfterDrop = Get-FreeMB; $vmAfterDrop = Get-VmmemMB
  $recovered = $freeAfterDrop - $free
  Log "  dropped page cache: free ${free}MB -> ${freeAfterDrop}MB (+${recovered}MB), vmmem ${vmmem}MB -> ${vmAfterDrop}MB$(if(-not $r.ok){' [' + $r.err + ']'})"
  if($freeAfterDrop -ge $WarnMB){
    Log "  RECOVERED by dropping cache alone — nothing paused, nothing restarted."
    if($state.heldSince){
      foreach($s in @($state.heldSlots)){
        $rr = Invoke-Wsl "if [ -x /usr/local/sbin/ci-pause ]; then /usr/local/sbin/ci-pause resume --slot $s || true; else rm -f /var/lib/ci-slot/$s.paused; fi" 60
        Log "  resumed slot $s"
      }
      $state.heldSince = $null; $state.heldSlots = @(); Write-State $state
    }
    exit 0
  }
  # Re-read, so every decision below is made against the post-drop reality.
  $free = $freeAfterDrop; $vmmem = $vmAfterDrop; $critical = ($free -lt $CriticalMB)
  Log "  still below warn after the drop — escalating"
} else {
  Log "  [dry-run] would first drop the page cache and re-check"
}

# Place the hold once, and only on slots that are not already paused — so an operator's
# deliberate hold is never adopted, and never resumed by this guard later.
if(-not $state.heldSince){
  $all    = Get-Slots
  $paused = Get-PausedSlots
  $mine   = @($all | Where-Object { $paused -notcontains $_ })
  if($mine.Count -gt 0){
    foreach($s in $mine){
      if($DryRun){ Log "  [dry-run] would hold slot $s"; continue }
      $r = Invoke-Wsl "if [ -x /usr/local/sbin/ci-pause ]; then /usr/local/sbin/ci-pause pause --slot $s 'held by wsl-mem-guard: low memory' || true; else mkdir -p /var/lib/ci-slot && date -u '+%Y-%m-%dT%H:%M:%SZ  held by wsl-mem-guard' > /var/lib/ci-slot/$s.paused; fi" 90
      Log "  held slot $s$(if(-not $r.ok){' (reported: ' + $r.err + ')'})"
    }
  } else {
    Log "  nothing to hold — every slot is already paused"
  }
  if(-not $DryRun){
    $state.heldSince = (Get-Date).ToString('o'); $state.heldSlots = $mine; Write-State $state
  }
}

# ---- decide whether to restart ----
$heldFor = 0
if($state.heldSince){ $heldFor = [int]((Get-Date) - [DateTime]::Parse($state.heldSince)).TotalMinutes }

# jobs -lt 0 means WSL would not answer. That is itself a reason to act rather than to
# wait politely for a drain that may never be reported.
$idle    = ($jobs -eq 0)
$drained = $idle -or ($jobs -lt 0)
$overdue = ($heldFor -ge $DrainMinutes)

if(-not ($critical -or $drained -or $overdue)){
  Log "  holding: $jobs job(s) still running, held ${heldFor}m of ${DrainMinutes}m — waiting for them to finish"
  exit 0
}

if($state.lastRestart){
  $since = [int]((Get-Date) - [DateTime]::Parse($state.lastRestart)).TotalMinutes
  if($since -lt $CooldownMinutes){
    Log "  WOULD RESTART but last restart was ${since}m ago (cooldown ${CooldownMinutes}m). Not thrashing; if memory is still low after a restart the cause is probably not WSL."
    exit 0
  }
}

$why = if($critical){ "free below critical" } elseif($overdue){ "held ${heldFor}m without draining" } else { "slots idle" }
Log "RESTARTING WSL — $why. jobs=$jobs free=${free}MB vmmem=${vmmem}MB"
if($jobs -gt 0){ Log "  NOTE: $jobs job(s) will be killed by this. They will report 'lost communication with the server' and need re-running." }

if($DryRun){ Log "  [dry-run] would run: wsl --shutdown, then restart the distro and resume the held slots"; exit 0 }

try {
  & wsl.exe --shutdown 2>&1 | ForEach-Object { Log "  wsl --shutdown: $_" }
  Start-Sleep -Seconds 12
  # Bring the distro back. systemd starts the slot units (both are `enabled`), so the
  # runners return by themselves; this call exists to boot the VM and prove it answers.
  $r = Invoke-Wsl "systemctl is-system-running --wait >/dev/null 2>&1; uptime" 120
  Log "  distro back: $(if($r.ok){$r.out}else{'did not answer — ' + $r.err})"

  # Release the holds this guard placed. The slot units are already up; the flag is the
  # only thing still telling them not to take work.
  foreach($s in @($state.heldSlots)){
    $rr = Invoke-Wsl "if [ -x /usr/local/sbin/ci-pause ]; then /usr/local/sbin/ci-pause resume --slot $s || true; else rm -f /var/lib/ci-slot/$s.paused; fi" 60
    Log "  resumed slot $s$(if(-not $rr.ok){' (reported: ' + $rr.err + ')'})"
  }

  Start-Sleep -Seconds 5
  $after = Get-FreeMB; $vmAfter = Get-VmmemMB
  Log "DONE free ${free}MB -> ${after}MB   vmmemWSL ${vmmem}MB -> ${vmAfter}MB"
  if($after -lt $WarnMB){
    Log "  STILL LOW after a restart. That points away from WSL — check the Windows side (Dropbox, Defender, browsers) before letting this run again."
  }
  $state.lastRestart = (Get-Date).ToString('o'); $state.heldSince = $null; $state.heldSlots = @()
  Write-State $state
} catch {
  Log "RESTART FAILED: $($_.Exception.Message)"
  exit 1
}
