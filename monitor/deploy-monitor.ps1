<#
  deploy-monitor.ps1 — WPF deploy monitor for the marathon self-hosted runner.

  Two window types (design-bucket/Deploy Monitor.dc.html):
    * Control plane (single, always one): runner badge, running/queued/failed
      chips, INCOMING/QUEUED, RECENT last-3. Minimized = compact counts pill
      (running/queued/failed + updated note).
    * Deploy status (one per ACTIVE deployment): 3-stage stepped progress with
      sweep, active line, elapsed, RUNNER line, error. Minimized = small pill.

  Each window is a taskbar button (the "pin"): red dot minimizes to taskbar,
  yellow toggles compact/expanded.

  Data source: the LOCAL runner journal (journalctl over WSL) — NO GitHub auth
  needed. Deploys are reconstructed from the runner's own job start/complete
  lines. If gh is authenticated (env token OR its own keyring/hosts login), it is
  used only to ENRICH the INCOMING·QUEUED view (GitHub-side runs that haven't
  reached the runner yet — the one thing the journal can't see); gh being
  missing / unauthed / offline just leaves that section empty, never an error.

  Usage: powershell -ExecutionPolicy Bypass -File tools\deploy-monitor.ps1 [-Repo example-org/appone]
#>
param(
  [string]$Repo = "example-org/appone",
  [int]$IntervalSec = 15,
  [string]$WslDistro = "Ubuntu",
  [string]$RunnerService = "actions.runner.example-org.marathon.service",
  # The containerized slot logs to its OWN unit, so after the 2026-09-05 cutover the
  # monitor went blind — it was still grepping the (now inactive) persistent unit and
  # showed no card at all for a job that ran fine. Read BOTH units so the monitor works
  # on either model, and during a cutover, without a flag.
  # A GLOB, not one unit. This was "marathon-slot@1.service" and went blind the day a
  # second slot was added (2026-09-29): a job on slot 2 produced no runner line
  # and no busy badge, so the card showed an idle box while a job was running.
  # systemd accepts the pattern directly in journalctl -u.
  [string]$SlotService = "marathon-slot@*",
  # The pause lever is a FLAG FILE, not a systemd state: run-containerized-slot.sh reads it
  # before it builds anything and holds without a listener (slots/slot-pause.sh). That path is
  # the whole contract, which is why the monitor can drive the pause even on a box where
  # ci-pause was never installed.
  [string]$PauseFlag = "/var/lib/ci-slot/1.paused",
  [string]$PauseCmd = "/usr/local/sbin/ci-pause",
  # Journal read window. See the comment at $since in Get-JournalDeploys for why this is 24h
  # and not 14 days, with the timings that decided it.
  [string]$JournalWindow = "24 hours ago",
  # Repos to ask GitHub about for the QUEUE. Defaults to the box's ci-fail-watch list, which is
  # the same set the failure watcher polls. Empty string disables the file and falls back to the
  # journal-derived set alone.
  [string]$QueueRepoFile = ""
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class Flasher {
  [StructLayout(LayoutKind.Sequential)] public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
  [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO p);
  public static void Flash(IntPtr h){ var f=new FLASHWINFO(); f.cbSize=(uint)Marshal.SizeOf(f); f.hwnd=h; f.dwFlags=3u|12u; f.uCount=4; f.dwTimeout=0; FlashWindowEx(ref f); }
}
"@

# ---- tokens ----
$Cgreen='#3FB950'; $CgreenDeep='#2EA043'; $Corange='#E3A008'; $Cred='#F85149'; $CredDeep='#DA3633'
$Cpause='#58A6FF'   # a deliberate hold is a FOURTH state — deliberately not green/orange/red
$Ccancel='#58A6FF'  # cancelled is neither pass nor fail — blue, so it never reads as a defect
$Cpending='#24242B'; $Ctext='#F5F5F7'; $Csub='#AEB2BD'; $Cmute='#6E7280'; $Cdim='#5F636D'
# One hue per SLOT NUMBER -- identity, not status. Green/amber/blue/red are spoken for by idle,
# busy, paused and down, so a slot hue that read as a state would make the strip say two things
# at once. Beyond the palette, slate: a fifth slot is not a thing this box will have, and an
# invented colour is worse than an obviously neutral one.
$SlotHues=@('#2DD4BF','#A78BFA','#F472B6','#38BDF8')
function SlotHue($n){ if($null -eq $n){ return '#94A3B8' }
  $i=[int]$n - 1; if($i -lt 0 -or $i -ge $SlotHues.Count){ return '#94A3B8' }; $SlotHues[$i] }
$bc = New-Object System.Windows.Media.BrushConverter
function B([string]$hex){ if([string]::IsNullOrEmpty($hex)){ $hex='#00000000' }; $bc.ConvertFromString($hex) }
function StageHex([string]$st){ switch($st){ 'done'{$script:CgreenDeep} 'canceled'{$script:Ccancel} 'active'{$script:Corange} 'failed'{$script:CredDeep} 'skipped'{$script:Cdim} default{$script:Cpending} } }
$script:repoShort=($Repo -split '/')[-1]
# The owner, resolved ONCE at script scope and deliberately NOT called $org. PowerShell
# variable names are case-insensitive, so a function taking a [string]$repo parameter
# shadows the script's $Repo — `($Repo -split '/')[0]` inside such a function returns the
# SHORT repo name, and the cancel button built "appone/appone". It failed with
# "can't find workflow run id", which reads like a bad id rather than a bad repo. Measured
# 2026-09-14. A distinct name is what stops it recurring.
$script:ghOrg=($Repo -split '/')[0]

# Which repos the QUEUE is polled for.
#
# It used to be derived purely from the journal -- the repos that had actually RUN a job in the
# last 24h -- plus this repo. That silently hid every queued run belonging to a repo the box had
# not touched recently, which is the opposite of what a queue view is for: a repo is most
# interesting precisely when it is waiting and has not run. Measured 2026-09-15, nine repos were
# pushed at once and the journal knew only five of them, so SEVEN of the nine queued runs were
# invisible while the tenth job held the slot.
#
# The watch file is the right source because it is already the answer to "which repos land on
# this box" and the failure watcher polls exactly it. Re-read every tick so editing the list
# takes effect without a restart; it is a few hundred bytes off local disk, not a wsl call.
function Get-QueueRepos {
  $f=$QueueRepoFile
  if(-not $f){
    # Same fallback chain New-IoRunspace uses: $PSScriptRoot is empty when the script is run
    # through -Command or dot-sourced, and Join-Path THROWS on an empty Path rather than
    # returning nothing, which would take the whole gather down with it.
    $root=$PSScriptRoot
    if(-not $root -and $PSCommandPath){ $root=Split-Path -Parent $PSCommandPath }
    if(-not $root -and $MyInvocation.MyCommand.Path){ $root=Split-Path -Parent $MyInvocation.MyCommand.Path }
    if(-not $root){ return @() }
    $f=Join-Path $root 'ci-fail-watch-repos'
  }
  if(-not (Test-Path $f)){ return @() }
  try {
    return @(Get-Content $f -ErrorAction Stop |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -and -not $_.StartsWith('#') } |
      ForEach-Object { ($_ -split '/')[-1] } |
      Where-Object { $_ })
  } catch { return @() }
}

# ---- single instance ----
# Two monitors on one box is not a harmless duplicate: every poll goes through wsl.exe, and
# wsl.exe invocations SERIALIZE. One tick costs ~8s of journalctl (468 job lines over 24h)
# plus one wsl.exe per watched repo for the commit subjects. Two instances on a 15s tick
# therefore starve each other, the journal poll comes back empty, and Get-JournalDeploys
# returns $null. On an instance that has never had a good poll there is no previous model to
# hold, so the control plane falls back to the empty placeholder -- dashes and NO history --
# which reads exactly like "the last 24h are gone". Measured 2026-09-15, after a reboot the
# box was launched twice within three minutes.
#
# A named mutex, not a pidfile: it is released by the kernel when the process dies, so a
# crash or a hard kill cannot leave a stale lock that blocks every future launch.
$script:singleton=New-Object System.Threading.Mutex($false,'Local\platform-deploy-monitor')
# AbandonedMutexException is NOT a failure to acquire -- it means the previous holder died
# without releasing (a force-kill, a crash, a closed console) and the wait SUCCEEDED. Letting
# it escape killed the NEXT launch outright, which is the opposite of what a guard is for.
$script:haveLock=$false
try { $script:haveLock=$script:singleton.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:haveLock=$true }
if(-not $script:haveLock){
  # NOT a MessageBox. The monitor is normally launched with -WindowStyle Hidden, and a modal
  # dialog on a hidden console blocks forever with nothing on screen to dismiss -- the refused
  # instance becomes an invisible zombie, which is worse than the duplicate it prevented.
  Write-Host 'deploy-monitor is already running - switch to the open window. Two instances contend for wsl.exe and blank each other''s history.'
  exit 0
}

# ---- data ----
function Get-RunnerLine {
  # Both units, and strip either process prefix. The slot logs as
  # run-containerized-slot.sh[pid]; the persistent runner as runsvc.sh[pid].
  try { $cmd="journalctl -u $RunnerService -u '$SlotService' --no-pager -n 120 | grep -E 'Running job:|completed with result:|Listening for Jobs' | grep -v 'WRITE LINE:' | tail -1 | sed -E 's/.*(runsvc\.sh|run-containerized-slot\.sh)\[[0-9]*\]: //'"
    $o=& wsl.exe -d $WslDistro -u root bash -c $cmd 2>$null; if($o){ return ($o|Select-Object -Last 1).Trim() } } catch {}
  return ""
}

# ---- per-slot state ----
# The badge answers "is this box busy"; these answer "which slot, and with what".
# Reuses slots/slots-status.sh rather than re-deriving here, so the monitor and
# the command line can never disagree about a slot -- they were already disagreeing
# once, when this file knew only about slot 1.
#
# Returns $null on any failure, and the caller keeps the last known value: the same
# rule Get-PauseState follows, for the same reason. A busy distro that cannot answer
# must not be rendered as "no slots".
function Get-SlotStates {
  try {
    if(-not $SlotScriptWsl){ return $null }
    # sed strips CRLF: the script lives on an NTFS checkout and bash will not run it otherwise.
    $cmd = "sed 's/\r$//' '$SlotScriptWsl' > /tmp/dm-slots.sh 2>/dev/null && bash /tmp/dm-slots.sh --json"
    $o = & wsl.exe -d $WslDistro -u root bash -c $cmd 2>$null
    if($o){
      $j = ($o -join '') | ConvertFrom-Json
      if($j -and $j.slots){ return @($j.slots) }
    }
  } catch {}
  return $null
}

# ---- pause lever ----
# Read: does the flag exist, and what reason was recorded on its first line.
# Returns $null (not "live") when WSL does not answer, so a busy distro can never flip the
# badge back to LIVE and make the operator think the hold was dropped. The caller keeps the
# last known state on $null — same rule the journal poll already follows.
function Get-PauseState {
  try {
    # PAUSED means the BOX is held, i.e. EVERY slot is. One held slot out of two still takes
    # jobs, and reporting that as paused would promise a hold the box is not honouring.
    # $PauseFlag supplies the directory and the <n>.paused naming; systemd supplies the slots.
    #
    # Emits three tagged line kinds and counts them HERE rather than looping in bash: a shell
    # loop needs $( ) and $var through two levels of quoting into wsl.exe, which is precisely
    # the escaping that has bitten this box repeatedly.
    $dir=[System.IO.Path]::GetDirectoryName($PauseFlag) -replace '\\','/'
    $cmd="systemctl list-units 'marathon-slot@*' --all --no-legend --no-pager 2>/dev/null | sed -E 's/^[^a-z]*marathon-slot@([0-9]+)\.service.*/U \1/'; ls $dir/ 2>/dev/null | grep -E '^[0-9]+\.paused' | sed 's/^/F /'; head -qn1 $dir/*.paused 2>/dev/null | head -1 | sed 's/^/S /'"
    $o=& wsl.exe -d $WslDistro -u root bash -c $cmd 2>$null
    if($o){
      $l=@($o | Where-Object { $_ -ne $null } | ForEach-Object { ([string]$_).Trim() })
      $n=@($l | Where-Object { $_ -like 'U *' }).Count
      $pn=@($l | Where-Object { $_ -like 'F *' }).Count
      # No units at all is not "live" -- it is an unanswered question, and $null is how this
      # function has always said so (the caller keeps the last known state).
      if($n -eq 0){ return $null }
      if($pn -ge $n){
        $since=''
        $sl=@($l | Where-Object { $_ -like 'S *' })
        if($sl.Count -gt 0){ $since=$sl[0].Substring(2).Trim() }
        return @{ paused=$true; since=$since }
      }
      return @{ paused=$false; since='' }
    }
  } catch {}
  return $null
}
# Write. Prefers slots/slot-pause.sh, which is the one that also DRAINS (it leaves a running job
# alone and holds at the next boundary), reclaims page cache and reports. Falls back to the flag
# file itself so the button still works on a box where the script was never installed — the
# fallback sets the same flag, so the slot still holds, just without the niceties.
#
# RUNS OFF THE UI THREAD. A pause is not instant: ci-pause stops the listener with a 30s docker
# stop grace and then waits up to 20s for the launcher's trap to tear down dind, the network and
# the volumes. Called inline that froze WPF for the whole time — no repaint, no spinner, and a
# window Windows would offer to kill. So it runs in its own runspace and a 200ms DispatcherTimer
# polls the handle; the UI keeps rendering, which is the only reason the loader can animate.
function Start-RunnerPause([bool]$on){
  # One transition at a time across BOTH levers. The box lever and a per-slot pill write the
  # same flag files, so letting them overlap would race over what paused means.
  if($global:pauseOp -or $global:slotOp){ return }
  $dir=[System.IO.Path]::GetDirectoryName($PauseFlag) -replace '\','/'
  # Over EVERY registered slot, so the lever means the same thing the badge does. ci-pause
  # takes --slot N; the fallback writes the same flag the launcher reads, so an uninstalled
  # ci-pause still holds the box -- just without the drain report and the page-cache reclaim.
  #
  # The slot numbers are resolved HERE and the command is a flat `;`-joined list. A `for`
  # loop over $(systemctl ...) reads better and does not survive: PS 5.1's native-argument
  # quoting resolved the substitution before bash parsed the string, inlining its newline
  # ("syntax error near unexpected token `2'") and emptying the loop variable.
  #
  # The strip is the slot list; without it, slot 1 alone -- exactly what this did before, so
  # a failed probe degrades to the old behaviour rather than to no lever at all.
  $snums=@()
  try { $snums=@($global:wins['control'].model.slots | Where-Object { $_ } | ForEach-Object { [int]$_.slot } | Sort-Object) } catch {}
  if($snums.Count -eq 0){ $snums=@(1) }
  $parts=foreach($n in $snums){
    if($on){ "if [ -x $PauseCmd ]; then $PauseCmd pause --slot $n 'paused from deploy-monitor' || true; else mkdir -p $dir && date -u '+%Y-%m-%dT%H:%M:%SZ  paused from deploy-monitor' > $dir/$n.paused; fi" }
    else   { "if [ -x $PauseCmd ]; then $PauseCmd resume --slot $n || true; else rm -f $dir/$n.paused; fi" }
  }
  $sh=($parts -join '; ')
  $rs=[runspacefactory]::CreateRunspace(); $rs.Open()
  $ps=[powershell]::Create(); $ps.Runspace=$rs
  [void]$ps.AddScript({ param($d,$c) $o=& wsl.exe -d $d -u root bash -c $c 2>&1; [pscustomobject]@{ code=$LASTEXITCODE; out=@($o) } }).AddArgument($WslDistro).AddArgument($sh)
  $global:pauseOp=@{ ps=$ps; rs=$rs; handle=$ps.BeginInvoke(); target=$on; started=(Get-Date) }
  # Paint the loader NOW, not on the next 15s tick: Render-Win draws from the model, so the
  # model has to know about the transition before the redraw, or the click looks ignored.
  $m=$global:wins['control'].model; if($m){ $m.pending=$on }
  Render-Win 'control'
  # Cap the wait. ci-pause's own worst case is ~50s; 90s means a wedged wsl.exe surfaces as an
  # error the operator can see instead of a control that spins for ever.
  $t=New-Object System.Windows.Threading.DispatcherTimer; $t.Interval=[TimeSpan]::FromMilliseconds(200)
  $t.Add_Tick({
    $op=$global:pauseOp; if(-not $op){ $t.Stop(); return }
    $timedOut=(((Get-Date)-$op.started).TotalSeconds -gt 90)
    if(-not $op.handle.IsCompleted -and -not $timedOut){ return }
    $t.Stop()
    $err=''
    if($timedOut){ $err='timed out after 90s' }
    else { try { $r=$op.ps.EndInvoke($op.handle); $r=@($r)[0]
             if($r -and $r.code -ne 0){ $err=(@($r.out) | Select-Object -Last 2) -join ' ' } } catch { $err=$_.Exception.Message } }
    try { $op.ps.Dispose(); $op.rs.Close(); $op.rs.Dispose() } catch {}
    # Believe the flag, not the intent: on failure the next Get-PauseState corrects this anyway,
    # but leaving the optimistic value in place would show a hold that never happened.
    if(-not $err){ $global:pauseState=@{ paused=$op.target; since='just now' } }
    $global:pauseOp=$null
    $m=$global:wins['control'].model
    if($m){ if($err){ $m.error="pause: $err" } elseif($m.error -like 'pause:*'){ $m.error=$null } }
    & $refresh
  }.GetNewClosure())
  $t.Start()
}

# ---- per-slot hold ----
# Same shape as Start-RunnerPause and the same reasoning -- confirm first, run off the UI thread,
# believe the flag rather than the intent -- but for ONE slot.
#
# There is no optimistic state here. Start-RunnerPause can set $global:pauseState because it owns
# the box-wide answer; a slot's truth is the flag file, which ci-slots-status.sh reads on the next
# gather. So the pill shows the transition while it runs and then shows whatever the box says,
# which cannot drift from reality even if ci-pause fails halfway.
function Start-SlotPause([int]$slot,[bool]$on){
  if($global:pauseOp -or $global:slotOp){ return }
  $what = if($on){'Hold'}else{'Resume'}
  $body = if($on){
    "Hold slot $slot only.`n`nThe other slot keeps taking jobs. A job already running on slot $slot is LEFT ALONE and the hold takes effect when it finishes.`n`nGitHub keeps queueing; nothing is lost."
  } else {
    "Resume slot $slot.`n`nIt starts listening again and takes the oldest queued job that fits."
  }
  $ans=[System.Windows.MessageBox]::Show($body,"$what slot $slot",
    [System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Question)
  if($ans -ne [System.Windows.MessageBoxResult]::Yes){ return }
  $dir=[System.IO.Path]::GetDirectoryName($PauseFlag) -replace '\','/'
  # Flat command, no shell loop and no $( ) -- see Start-RunnerPause for the PS 5.1 argument
  # packing that makes those unsurvivable.
  $sh = if($on){ "if [ -x $PauseCmd ]; then $PauseCmd pause --slot $slot 'paused from deploy-monitor' || true; else mkdir -p $dir && date -u '+%Y-%m-%dT%H:%M:%SZ  paused from deploy-monitor' > $dir/$slot.paused; fi" }
        else    { "if [ -x $PauseCmd ]; then $PauseCmd resume --slot $slot || true; else rm -f $dir/$slot.paused; fi" }
  $rs=[runspacefactory]::CreateRunspace(); $rs.Open()
  $ps=[powershell]::Create(); $ps.Runspace=$rs
  [void]$ps.AddScript({ param($d,$c) $o=& wsl.exe -d $d -u root bash -c $c 2>&1; [pscustomobject]@{ code=$LASTEXITCODE; out=@($o) } }).AddArgument($WslDistro).AddArgument($sh)
  $global:slotOp=@{ ps=$ps; rs=$rs; handle=$ps.BeginInvoke(); slot=$slot; target=$on; started=(Get-Date) }
  Render-Win 'control'
  $t=New-Object System.Windows.Threading.DispatcherTimer; $t.Interval=[TimeSpan]::FromMilliseconds(200)
  $t.Add_Tick({
    $op=$global:slotOp; if(-not $op){ $t.Stop(); return }
    $timedOut=(((Get-Date)-$op.started).TotalSeconds -gt 90)
    if(-not $op.handle.IsCompleted -and -not $timedOut){ return }
    $t.Stop(); $err=''
    if($timedOut){ $err='timed out after 90s' }
    else { try { $r=@($op.ps.EndInvoke($op.handle))[0]
             if($r -and $r.code -ne 0){ $err=(@($r.out) | Select-Object -Last 2) -join ' ' } } catch { $err=$_.Exception.Message } }
    try { $op.ps.Dispose(); $op.rs.Close(); $op.rs.Dispose() } catch {}
    $sl=$op.slot
    $global:slotOp=$null
    $m=$global:wins['control'].model
    if($m){ if($err){ $m.error="slot ${sl}: $err" } elseif($m.error -like 'slot *'){ $m.error=$null } }
    & $refresh
  }.GetNewClosure())
  $t.Start()
}

# Tidy a runner job display name into a stage label: drop the matrix-args parenthetical, keep the
# rest (full names stay distinct, e.g. "build / prepare" vs "build / build-and-push").
function CleanStage([string]$job){ ($job -replace '\s*\(.*$','').Trim() }
# The journal's "Running job" lines carry no repo or ids. Recover them from the runner's Worker
# logs: repo from the _work/<repo> path; the per-RUN planId GUID (shared by every job of a workflow
# run) which groups interleaved jobs/repos into deploys; the GitHub run_id (databaseId) used to
# check a run's live status against gh; and the workflow name (title/file) shown on the cards.
# Keyed by the job's UTC start second (== journal job-start
# second). Worker logs are immutable, so results are cached by filename; entries still missing a
# planId (job just initializing) are retried on the next tick.
$script:wmCache=@{}
$script:wmRetry=@{}   # per-log re-read count, bounding the retry above
function Get-WorkerMeta {
  # Two locations: the persistent runner's own _diag, and the containerized slots', which
  # are bind-mounted to the host at /var/log/marathon-slots/<n>/_diag precisely so this lookup
  # keeps working (a slot's _diag used to be a throwaway volume, which is why the control
  # plane showed no card for a job that ran fine on 2026-09-05).
  # Now with MTIME, which is the only honest liveness signal available out here: the runner
  # writes to this log continuously while the job runs. `stat` prints in argument order, so
  # `ls -t`'s newest-first ordering survives the pipe.
  $ls=$null; try { $ls=& wsl.exe -d $WslDistro -u root bash -c 'ls -t /home/ghrunner/actions-runner/_diag/Worker_*.log /var/log/marathon-slots/*/_diag/Worker_*.log 2>/dev/null | head -150 | xargs -r stat -c %Y:%n' 2>$null } catch {}
  $files=@(); $mtOf=@{}
  foreach($ln in @($ls)){
    if($ln -match '^(\d+):(.+Worker_\d{8}-\d{6}-utc\.log)$'){
      $fp=$matches[2]; $files+=$fp
      # Epoch seconds -> UTC. Kept OUT of the cache on purpose: the cache is keyed by filename
      # and holds immutable facts, and mtime is the one thing here that changes every second.
      $mtOf[$fp]=([DateTimeOffset]::FromUnixTimeSeconds([int64]$matches[1])).UtcDateTime
    }
  }
  if($files.Count -eq 0){ return ,@() }
  # Which slot wrote it, straight out of the path. /var/log/marathon-slots/<n>/_diag is a bind mount
  # created per slot, so the number is authoritative; the persistent runner's own _diag has no
  # slot and reports $null rather than pretending to be slot 1.
  $slotOf=@{}
  foreach($fp in $files){ $slotOf[$fp]=$(if($fp -match '/ci-slots/(\d+)/_diag/'){ [int]$matches[1] }else{ $null }) }
  # Stamp liveness and slot onto whatever the cache hands back, on EVERY call.
  $stamp={ param($e,$fp) if($e){ $e.mtime=$mtOf[$fp]; $e.slot=$slotOf[$fp] }; $e }
  # Re-read a log until BOTH planId and repo are known, not just planId.
  #
  # A Worker log is written progressively: the planId lands in the job message almost
  # immediately, but "_work/<repo>" only appears once the job actually touches the workspace.
  # Committing to the cache on planId alone froze repo=$null for the life of the process, so a
  # deploy card could show its workflow and never its repo — visible on the live appeight deploy,
  # 2026-09-05. Retry is bounded: a job that fails before it ever touches the workspace has no
  # repo to find, and must not be re-grepped forever.
  $need=@($files | Where-Object {
    (-not $script:wmCache.ContainsKey($_)) -or
    ((-not $script:wmCache[$_].repo) -and ([int]$script:wmRetry[$_] -lt 12)) })
  if($need.Count -gt 0){
    $argstr=($need -join ' '); $repoOut=$null; $planOut=$null; $runOut=$null; $wfOut=$null
    # PRIMARY: the job message's own "repository" variable ("example-org/appeight"). This is
    # DECLARATIVE — GitHub sends it when the job is dispatched, so it is present from the first
    # write of the log, for every job, including ones that never touch the workspace.
    #
    # The old method inferred the repo from a "_work/<repo>" path, which only appears once a job
    # actually uses the workspace. That is why a repo could be missing or arrive late: it was a
    # side effect being read as an identifier.
    #
    # Pattern uses '.' for the quote chars (the file's existing idiom) to avoid escaping double
    # quotes through PowerShell -> bash -c. Matching '.k.: .repository.,' rather than a looser
    # 'repository' keeps it off "type": "repository" (the actions list) and workflow_repository.
    try { $repoOut=& wsl.exe -d $WslDistro -u root bash -c "grep -aHA1 '.k.: .repository.,' $argstr 2>/dev/null" 2>$null } catch {}
    # FALLBACK for logs written before that key was read (or if the format ever changes).
    try { $repoAlt=& wsl.exe -d $WslDistro -u root bash -c "grep -aoHE -m1 '_work/[^_/][^/]*' $argstr 2>/dev/null" 2>$null } catch {}
    try { $planOut=& wsl.exe -d $WslDistro -u root bash -c "grep -aoHE -m1 'planId.{0,6}[0-9a-f-]{36}' $argstr 2>/dev/null" 2>$null } catch {}
    # run_id and workflow are pretty-printed as a key line ("k": "run_id"/"workflow",) then a value
    # line ("v": "..."), so grab the key ([^_] excludes check_run_id / workflow_ref) with 1 line of
    # trailing context and read the value.
    try { $runOut=& wsl.exe -d $WslDistro -u root bash -c "grep -aHA1 '[^_]run_id.,' $argstr 2>/dev/null" 2>$null } catch {}
    try { $wfOut=& wsl.exe -d $WslDistro -u root bash -c "grep -aHA1 '[^_]workflow.,' $argstr 2>/dev/null" 2>$null } catch {}
    # The job's commit. The pattern is anchored so it cannot also match "workflow_sha": there is
    # exactly one character (the quote) between the colon-space and `sha`.
    try { $shaOut=& wsl.exe -d $WslDistro -u root bash -c "grep -aHA1 -m1 '.k.: .sha.,' $argstr 2>/dev/null" 2>$null } catch {}
    $repoOf=@{}; $planOf=@{}; $runOf=@{}; $wfOf=@{}; $shaOf=@{}
    # "<file>-          "v": "example-org/appeight""  -> keep the bare repo name, since everything
    # downstream (gh calls, the commit-subject path) expects it without the owner.
    foreach($ln in $repoOut){ if($ln -match '^(.+\.log)-\s*"v":\s*"[^"/]+/([^"]+)"' -and -not $repoOf.ContainsKey($matches[1])){ $repoOf[$matches[1]]=$matches[2] } }
    foreach($ln in $repoAlt){ if($ln -match '^(.+\.log):.*_work/(\S+)$' -and -not $repoOf.ContainsKey($matches[1])){ $repoOf[$matches[1]]=$matches[2] } }
    foreach($ln in $planOut){ if($ln -match '^(.+\.log):.*?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'){ $planOf[$matches[1]]=$matches[2] } }
    foreach($ln in $runOut){ if($ln -match '^(.+\.log)-\s*"v":\s*"(\d{7,})"' -and -not $runOf.ContainsKey($matches[1])){ $runOf[$matches[1]]=$matches[2] } }
    foreach($ln in $wfOut){ if($ln -match '^(.+\.log)-\s*"v":\s*"([^"]*)"' -and -not $wfOf.ContainsKey($matches[1])){ $wfOf[$matches[1]]=$matches[2] } }
    # 40 hex exactly -- a shorter match would accept a truncated or unrelated value and print a
    # hash that looks real.
    foreach($ln in $shaOut){ if($ln -match '^(.+\.log)-\s*"v":\s*"([0-9a-f]{40})"' -and -not $shaOf.ContainsKey($matches[1])){ $shaOf[$matches[1]]=$matches[2] } }
    # A FAILED CALL IS NOT EVIDENCE OF ABSENCE.
    #
    # The retry budget above exists to stop re-grepping a job that never touched the workspace
    # and so has no repo to find. It cannot tell that apart from a grep that DID NOT RUN, and
    # under load these do not run: wsl.exe invocations serialize, so a build holding the box
    # starves them and they come back empty. Every empty result still burned a retry, so after
    # 12 ticks EVERY log was frozen at repo=$null and the whole history rendered as 'repo?'.
    # Measured 2026-09-15, while nine queued repos drained behind a 42-minute appone job.
    #
    # planId is the signal, not repo: it is written to the job message almost immediately and is
    # present in every Worker log ever produced, so a batch that yields NO planId at all did not
    # read the files -- there is no honest way for 150 real logs to have none. Bail without
    # touching the cache or the retry counters and try again next tick.
    if($planOf.Count -eq 0){
      return ,@($files | ForEach-Object { & $stamp $script:wmCache[$_] $_ } | Where-Object { $_ })
    }
    # The greps are FIVE SEPARATE wsl.exe calls and they fail INDEPENDENTLY. The case that bit
    # us is the partial one: planId came back, both repo lookups came back empty. That writes a
    # cache entry with repo=$null, and because the entry now EXISTS the only thing keeping it
    # alive is the retry budget -- which the same failure is busy spending. Reproduced 2026-09-15:
    # 13 such ticks left all 150 logs cached with repo=$null at maxRetry=12, and once the box
    # recovered NOT ONE came back. Every history row rendered 'repo?' until the process restarted.
    #
    # A whole batch yielding zero repos is the tell. The primary lookup reads the declarative
    # "repository" key, which GitHub writes into every job message before the job starts, so 150
    # real logs cannot honestly contain none. Treat it as a failed lookup: still cache the planId
    # (grouping needs it), but do NOT spend the budget, so the entry stays eligible and repairs
    # itself on the next healthy tick instead of needing a restart.
    $repoLookupRan=($repoOf.Count -gt 0)
    foreach($fp in $need){ if($repoLookupRan){ $script:wmRetry[$fp]=[int]$script:wmRetry[$fp]+1 }
      if($planOf[$fp] -and $fp -match 'Worker_(\d{8})-(\d{6})-utc\.log$'){
      try { $t=[DateTime]::ParseExact(($matches[1]+$matches[2]),'yyyyMMddHHmmss',[System.Globalization.CultureInfo]::InvariantCulture,([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)); $script:wmCache[$fp]=@{ t=$t; repo=$repoOf[$fp]; planId=$planOf[$fp]; runId=$runOf[$fp]; workflow=$wfOf[$fp]; sha=$shaOf[$fp] } } catch {} } }
  }
  return ,@($files | ForEach-Object { & $stamp $script:wmCache[$_] $_ } | Where-Object { $_ })
}
# HEAD commit subject per repo (the "last deploy" comment), read from the checked-out tree.
# Runs as ghrunner (who owns the tree) to avoid git's dubious-ownership guard. No auth.
function Get-RepoCommits($repos){
  $map=@{}
  foreach($r in $repos){ if(-not $r){ continue }
    $p="/home/ghrunner/actions-runner/_work/$r/$r"
    $s=$null; try { $s=& wsl.exe -d $WslDistro -u ghrunner bash -c "git -C $p log -1 --pretty=%s 2>/dev/null" } catch {}
    if($s){ $map[$r]=(($s|Select-Object -Last 1).Trim()) } }
  return $map
}
# Reconstruct deploys from the runner journal (no auth). Jobs are grouped into deploys by their
# workflow-run planId (from the Worker log), so interleaved repos/runs never merge; each deploy's
# stages are derived generically from whatever jobs actually ran, in start order. Returns an array
# (newest-first) of @{ id;planId;repo;start;last;end;stages;running;conclusion } where stages is an
# ordered @( @{ name; status } ), or $null when the journal/WSL can't be read.
function Get-JournalDeploys {
  # How far back to read the journal. NOT 14 days any more — measured 2026-09-15 on this box,
  # whose journal has grown to 2.6GB because the runner logs a WORKER debug line per process:
  #
  #   since 14 days ago  -> 188s   3220 matching lines
  #   since 48 hours ago ->  40s    952 matching lines
  #   since 24 hours ago ->  20s    586 matching lines
  #
  # The refresh tick is 15s. At 188s the gather could never finish between ticks, so the view
  # updated roughly every three minutes: a job that ran for 2m10s could start and finish inside
  # one poll and never appear at all. That is exactly what it looked like — "no running jobs and
  # no job card" while a job was demonstrably in flight. The cost is journalctl SCANNING the
  # journal, not the lines it returns, so the window is the lever.
  #
  # 24h is ample for what the view needs: running deploys now, the 24h success/failed counts,
  # and a RECENT pool that caps at 60 completed (24h holds ~145 jobs here). Widen it with
  # -JournalWindow if you want more history and can pay the poll.
  # A blank window is not a legal journalctl argument and must never reach it: `--since ''`
  # returns zero lines while still looking like a clean poll. Fall back rather than lie.
  $since=$(if([string]::IsNullOrWhiteSpace($JournalWindow)){'24 hours ago'}else{$JournalWindow})
  # Read BOTH the persistent runner's unit and the containerized slot's, so the view is
  # continuous across a cutover. The slot double-logs every line (once bare, once wrapped
  # as "[RUNNER ...] WRITE LINE: ...") because the runner writes to stdout AND its own
  # terminal logger and docker captures both — dropping the WRITE LINE copies here is what
  # stops every slot job being counted twice.
  $cmd="(journalctl -u $RunnerService -u '$SlotService' --no-pager --since '$since' -o short-iso 2>/dev/null | grep -E 'Running job:|completed with result:' | grep -v 'WRITE LINE:'); echo __JOK__"
  # A wsl.exe call can come back empty just because the distro is BUSY — wsl.exe invocations
  # serialize, so a long chown/find in another shell starves this poll. That is contention, not
  # the runner being down. Retry once before giving up; the caller escalates only after a streak.
  $out=$null
  foreach($attempt in 1..2){
    $try=$null; try { $try=& wsl.exe -d $WslDistro -u root bash -c $cmd 2>$null } catch {}
    if(($try -join "`n") -match '__JOK__'){ $out=$try; break }
    if($attempt -lt 2){ Start-Sleep -Milliseconds 1500 }
  }
  if($null -eq $out){ return $null }   # journal/WSL unreadable after a retry
  $events=@()
  # Line: "<iso-ts> <host> runsvc.sh[pid]: <runner-ts>Z: Running job: <name>". The runner
  # prints its OWN timestamp after the pid, so the message patterns are NOT anchored to ^.
  foreach($ln in $out){ if(-not $ln -or $ln -eq '__JOK__'){ continue }
    if($ln -match '^(\S+)\s.*(?:runsvc\.sh|run-containerized-slot\.sh)\[\d+\]:\s*(.+)$'){
      $tsRaw=$matches[1]; $msg=$matches[2].Trim()
      try { $t=[DateTimeOffset]::Parse($tsRaw).UtcDateTime } catch { continue }
      if($msg -match 'Running job:\s*(.+)$'){ $events+=@{ t=$t; kind='start'; job=$matches[1].Trim() } }
      elseif($msg -match 'Job\s+(.+?)\s+completed with result:\s*(\w+)'){ $events+=@{ t=$t; kind='done'; job=$matches[1].Trim(); result=$matches[2] } }
    }
  }
  $wm=Get-WorkerMeta
  $deploys=@{}; $order=@(); $cur=$null   # single-concurrency runner: a 'done' pairs with the open job
  foreach($ev in ($events | Sort-Object { $_.t })){
    $name=CleanStage $ev.job
    if($ev.kind -eq 'start'){
      # only START events have a Worker log (named by start-second) -> planId (grouping) + repo
      # Match the journal's job-start to its Worker log. The window is ASYMMETRIC on purpose:
      # the listener logs "Running job" first, then the worker process starts and names its log
      # after ITSELF, so the log is always at or AFTER the journal line, never meaningfully
      # before. A symmetric +/-6.5s therefore spent half its budget on time that cannot happen
      # and ran out on the side that does.
      #
      # Measured 2026-09-14, and it was a real miss, not a theoretical one:
      #   journal 20:27:35Z  Running job: build / build-and-push (appthree, ...)
      #   log     20:27:45Z  Worker_20260914-202745-utc.log   (repository=example-org/appthree)
      # 10s apart, so no match, so no repo, so the row read "repo? · build / build-and-push"
      # with the answer sitting in a file on disk. Short jobs (sync-store-claims, build/prepare)
      # matched at 0s, which is why this only ever bit the heavy build-and-push rows.
      #
      # Forward 30s, back 2s (clock skew only). Safe against stealing the NEXT job's log because
      # --once turnover pays teardown plus a cold start between jobs — the gaps in the journal
      # are 45s+ and never close to 30.
      $best=$null; $bestDiff=[double]::MaxValue
      foreach($w in $wm){
        $d=($w.t-$ev.t).TotalSeconds
        if($d -ge -2 -and $d -le 30 -and $d -lt $bestDiff){ $bestDiff=$d; $best=$w }
      }
      $plan=$(if($best -and $best.planId){$best.planId}else{"solo-$($ev.t.Ticks)"})
      $repo=$(if($best){$best.repo}else{$null})
      $rid=$(if($best){$best.runId}else{$null})
      $wf=$(if($best){$best.workflow}else{$null})
      $csha=$(if($best){$best.sha}else{$null})
      if(-not $deploys.ContainsKey($plan)){ $d=@{ id=$ev.t.ToString('yyyyMMddHHmmss'); planId=$plan; repo=$repo; runId=$rid; workflow=$wf; start=$ev.t; last=$ev.t; end=$null; sIdx=@{}; sList=@() }; $deploys[$plan]=$d; $order+=$plan }
      $d=$deploys[$plan]; if(-not $d.repo -and $repo){ $d.repo=$repo }; if(-not $d.runId -and $rid){ $d.runId=$rid }; if(-not $d.workflow -and $wf){ $d.workflow=$wf }
      # Deploy-level, not stage-level: every job of one workflow run is the same commit.
      if(-not $d.sha -and $csha){ $d.sha=$csha }
      if(-not $d.sIdx.ContainsKey($name)){ $st=@{ name=$name; status='active' }; $d.sList+=$st; $d.sIdx[$name]=$st } else { $d.sIdx[$name].status='active' }
      # Which slot ran this job, and when its worker last wrote. Both come from the Worker log
      # that was just matched to this start event, so they cost nothing extra.
      if($best){ $d.sIdx[$name].slotN=$best.slot; $d.sIdx[$name].aliveAt=$best.mtime }
      if($ev.t -lt $d.start){ $d.start=$ev.t }
      $d.last=$ev.t; $cur=@{ stage=$d.sIdx[$name]; deploy=$d }
    } else {
      # 'done' closes the currently-open job; fall back to newest still-active stage of this name
      $s=$null; $dp=$null
      if($cur -and $cur.stage.name -eq $name){ $s=$cur.stage; $dp=$cur.deploy }
      else { for($k=$order.Count-1;$k -ge 0;$k--){ $cand=$deploys[$order[$k]]; if($cand.sIdx.ContainsKey($name) -and $cand.sIdx[$name].status -eq 'active'){ $s=$cand.sIdx[$name]; $dp=$cand; break } } }
      # Three results, not two. The runner emits Succeeded / Failed / Canceled; mapping Canceled onto
      # 'failed' painted a red row for something nobody needs to fix, which is how a cancelled run
      # ends up investigated twice.
      if($s){ $s.status=$(switch($ev.result){ 'Succeeded' {'done'} 'Canceled' {'canceled'} 'Cancelled' {'canceled'} default {'failed'} }); $dp.last=$ev.t; $dp.end=$ev.t }
      $cur=$null
    }
  }
  $res=@()
  # A deploy whose repo couldn't be resolved from a Worker log must NOT impersonate the primary
  # repo — that mislabels e.g. a appthree job as appone. It used to be stamped with a bare
  # '…', which is worse than useless on a card: several rows reading "… · main" carry no
  # information and cannot be told apart from each other.
  #
  # So leave .repo NULL (the git/gh lookups below already skip null, and MUST keep skipping it) and
  # give the card a label built from what the journal ALWAYS provides — the stage names. A row then
  # reads "test" or "build / prepare +2" instead of "…".
  #
  # This is permanent for jobs that ran before _diag was bound to the host (2026-09-05): their
  # Worker logs died with the throwaway volume, so no later tick can recover the repo.
  foreach($plan in $order){ $d=$deploys[$plan]
    $d.stages=@($d.sList)
    if(-not $d.repo){
      $nm=@($d.stages | ForEach-Object { $_.name } | Where-Object { $_ } | Select-Object -Unique)
      $d.label=$(if($nm.Count -eq 0){'unidentified job'}
                 elseif($nm.Count -le 2){ $nm -join ' + ' }
                 else { "$($nm[0]) +$($nm.Count-1)" })
    } else { $d.label=$d.repo }
    $anyFailed=(@($d.stages | Where-Object { $_.status -eq 'failed' }).Count -gt 0)
    $anyActive=(@($d.stages | Where-Object { $_.status -eq 'active' }).Count -gt 0)
    # A stranded 'active' stage -- no completion line because the runner disconnected -- has to
    # be closed eventually, or its card sits on the screen for ever. The question is how to tell
    # it apart from a job that is simply taking a long time.
    #
    # This used to answer with elapsed time: active for over an hour meant failed. That was safe
    # when jobs were minutes long, and it is now WRONG. appone's suite takes about 1h40m, so
    # at the 60-minute mark the monitor declared a perfectly healthy job dead, dropped its deploy
    # card and wrote a red row into RECENT. Observed 2026-09-30 with both slots busy and only one
    # card on screen; the journal was right (no completion line yet) and the heuristic overrode it.
    #
    # Liveness is the honest test: the runner writes to its Worker log continuously while the job
    # runs, so a log touched seconds ago is a job that is running, however long it has been going.
    # 150s of slack over the ci-slots-status threshold (90s), because that file is also read
    # through a starved wsl.exe.
    #
    # With no Worker log matched we are blind and fall back to elapsed time -- but at 6h, not 1h.
    # A blind bound exists to stop a card living for ever, not to adjudicate a running job.
    if($anyActive){
      $ageSec=([DateTime]::UtcNow-$d.last).TotalSeconds
      $alive=@($d.stages | Where-Object { $_.status -eq 'active' -and $_.aliveAt } | ForEach-Object { $_.aliveAt } | Sort-Object -Descending | Select-Object -First 1)
      $live = if($alive.Count -gt 0){ (([DateTime]::UtcNow-$alive[0]).TotalSeconds -lt 150) } else { ($ageSec -lt 21600) }
      if($live){ $d.running=$true; $d.conclusion=$null }
      else { foreach($s in $d.stages){ if($s.status -eq 'active'){ $s.status='failed' } }; $d.running=$false; $d.conclusion='failure' } }
    elseif($anyFailed){ $d.running=$false; $d.conclusion='failure' }
    # Cancelled only counts once nothing failed: a run where one job failed and the rest were
    # cancelled as a consequence is a FAILURE, and calling it "canceled" would bury the cause.
    elseif(@($d.stages | Where-Object { $_.status -eq 'canceled' }).Count -gt 0){ $d.running=$false; $d.conclusion='cancelled' }
    # all stages done, none active: still 'running' briefly in case the run's next job hasn't started.
    else { $ageSec=([DateTime]::UtcNow-$d.last).TotalSeconds
      if($ageSec -lt 150){ $d.running=$true; $d.conclusion=$null } else { $d.running=$false; $d.conclusion='success' } }
    $res+=$d }
  return ,(@($res | Sort-Object { $_.start } -Descending))
}
function Ago([string]$iso){ try { $m=[int](([DateTime]::UtcNow-[DateTime]::Parse($iso).ToUniversalTime()).TotalMinutes); if($m -lt 60){"$m" + "m ago"}else{"$([int]($m/60))h ago"} } catch { '—' } }
function Dur([string]$a,[string]$b){ try { if(-not $a -or -not $b){return ''}; $sec=([DateTime]::Parse($b)-[DateTime]::Parse($a)).TotalSeconds; if($sec -lt 0){return ''}; $mm=[int]($sec/60); $ss=[int]($sec%60); if($mm -ge 60){"$([int]($mm/60))h" + "$($mm%60)m"}elseif($mm -gt 0){"${mm}m" + "${ss}s"}else{"${ss}s"} } catch { '' } }

# ---- element builders ----
function Track([double]$h,[string]$st,[bool]$sweep){
  $b=New-Object System.Windows.Controls.Border; $b.Height=$h; $b.CornerRadius=($h/2); $b.Background=(B (StageHex $st)); $b.ClipToBounds=$true
  if($st -eq 'active'){
    $pa=New-Object System.Windows.Media.Animation.DoubleAnimation; $pa.From=0.8; $pa.To=1.0; $pa.Duration=(New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.8))); $pa.AutoReverse=$true; $pa.RepeatBehavior=[System.Windows.Media.Animation.RepeatBehavior]::Forever
    $b.BeginAnimation([System.Windows.UIElement]::OpacityProperty,$pa)
    if($sweep){
      $r=New-Object System.Windows.Shapes.Rectangle; $r.HorizontalAlignment='Left'; $r.Width=44; $r.RadiusX=$h/2; $r.RadiusY=$h/2
      $g=New-Object System.Windows.Media.LinearGradientBrush; $g.StartPoint='0,0'; $g.EndPoint='1,0'
      $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop(((B '#00FFD680').Color),0))); $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop(((B '#A6FFD680').Color),0.5))); $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop(((B '#00FFD680').Color),1)))
      $r.Fill=$g; $tt=New-Object System.Windows.Media.TranslateTransform; $r.RenderTransform=$tt
      $r.Add_Loaded({ param($s,$e) $w=[double]$s.Parent.ActualWidth; if($w -le 0){$w=120}
        $sa=New-Object System.Windows.Media.Animation.DoubleAnimation; $sa.From=-50; $sa.To=$w+20; $sa.Duration=(New-Object System.Windows.Duration([TimeSpan]::FromSeconds(1.5))); $sa.RepeatBehavior=[System.Windows.Media.Animation.RepeatBehavior]::Forever
        $s.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty,$sa) })
      $b.Child=$r
    }
  }
  return $b
}
function MiniBars($stages,[double]$w){
  $g=New-Object System.Windows.Controls.StackPanel; $g.Orientation='Horizontal'; if($w){$g.Width=$w}
  $n=@($stages).Count; if($n -lt 1){$n=1}
  for($i=0;$i -lt $n;$i++){ $c=New-Object System.Windows.Controls.Border; $c.Height=4; $c.Width= if($w){($w-4*($n-1))/$n}else{0}; $c.CornerRadius=2; $c.Background=(B (StageHex $stages[$i].status)); $c.Margin= if($i -lt ($n-1)){'0,0,4,0'}else{'0'}; [void]$g.Children.Add($c) }
  return $g
}
function Dot([string]$hex,[double]$d){ $e=New-Object System.Windows.Shapes.Ellipse; $e.Width=$d; $e.Height=$d; $e.Fill=(B $hex); $e.VerticalAlignment='Center'; return $e }
# ---- attention animations ----
function Pop-In($el){ $st=New-Object System.Windows.Media.ScaleTransform(1,1); $el.RenderTransformOrigin='0.5,0.5'; $el.RenderTransform=$st
  $sa=New-Object System.Windows.Media.Animation.DoubleAnimation; $sa.From=1.16; $sa.To=1.0; $sa.Duration=(New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.5)))
  $ee=New-Object System.Windows.Media.Animation.BackEase; $ee.EasingMode='EaseOut'; $ee.Amplitude=0.7; $sa.EasingFunction=$ee
  $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty,$sa); $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty,$sa) }
function Flash-Bg($border,[string]$hex,[int]$alpha){ $col=(B $hex).Color
  $brush=New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb([byte]$alpha,$col.R,$col.G,$col.B)); $border.Background=$brush
  $ca=New-Object System.Windows.Media.Animation.ColorAnimation; $ca.To=[System.Windows.Media.Color]::FromArgb(0,$col.R,$col.G,$col.B); $ca.Duration=(New-Object System.Windows.Duration([TimeSpan]::FromSeconds(1.7))); $ca.BeginTime=(New-Object TimeSpan(0,0,0,0,250))
  $brush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty,$ca) }
function Flash-Taskbar($win){ try { $h=(New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle; if($h -ne [IntPtr]::Zero){ [Flasher]::Flash($h) } } catch {} }
function Pulse($el){ $st=New-Object System.Windows.Media.ScaleTransform(1,1); $el.RenderTransformOrigin='0.5,0.5'; $el.RenderTransform=$st
  $sa=New-Object System.Windows.Media.Animation.DoubleAnimation; $sa.From=1; $sa.To=1.4; $sa.Duration=(New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.85))); $sa.AutoReverse=$true; $sa.RepeatBehavior=[System.Windows.Media.Animation.RepeatBehavior]::Forever
  $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty,$sa); $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty,$sa)
  $oa=New-Object System.Windows.Media.Animation.DoubleAnimation; $oa.From=1; $oa.To=0.45; $oa.Duration=(New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.85))); $oa.AutoReverse=$true; $oa.RepeatBehavior=[System.Windows.Media.Animation.RepeatBehavior]::Forever
  $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty,$oa) }
function Textb([string]$t,[string]$hex,[double]$fs,[string]$weight,[string]$fam){ $x=New-Object System.Windows.Controls.TextBlock; $x.Text=$t; $x.Foreground=(B $hex); $x.FontSize=$fs; if($weight){$x.FontWeight=$weight}; if($fam){$x.FontFamily=$fam}; $x.VerticalAlignment='Center'; return $x }
function TLights([string]$key){
  $sp=New-Object System.Windows.Controls.StackPanel; $sp.Orientation='Horizontal'; $sp.Margin='0,0,4,0'
  $red=Dot '#FF5F57' 12; $red.Margin='0,0,7,0'; $red.Cursor='Hand'; $red.ToolTip='Minimize to taskbar'
  $red.Add_MouseLeftButtonDown({ param($s,$e) $e.Handled=$true })
  $red.Add_MouseLeftButtonUp({ param($s,$e) $e.Handled=$true; $global:wins[$key].win.WindowState='Minimized' }.GetNewClosure())
  [void]$sp.Children.Add($red)
  $yel=Dot '#FEBC2E' 12; $yel.Margin='0,0,7,0'; $yel.Cursor='Hand'; $yel.ToolTip='Compact / expand'
  $yel.Add_MouseLeftButtonDown({ param($s,$e) $e.Handled=$true })
  $yel.Add_MouseLeftButtonUp({ param($s,$e) $e.Handled=$true; Toggle-View $key }.GetNewClosure())
  [void]$sp.Children.Add($yel)
  return $sp
}
function Pill([string]$txt,[string]$hex,[string]$bg,[string]$bd){ $b=New-Object System.Windows.Controls.Border; $b.CornerRadius=6; $b.Padding='8,3,8,3'; $b.Background=(B $bg); $b.BorderBrush=(B $bd); $b.BorderThickness=1; $b.Child=(Textb $txt $hex 9.5 'Bold' $null); $b.VerticalAlignment='Center'; return $b }
function Chip([string]$count,[string]$label,[string]$dotHex,[bool]$pulse){ $b=New-Object System.Windows.Controls.Border; $b.CornerRadius=7; $b.Background=(B '#16161A'); $b.BorderBrush=(B '#12FFFFFF'); $b.BorderThickness=1; $b.Padding='9,5,9,5'; $b.Margin='0,0,7,0'
  $s=New-Object System.Windows.Controls.StackPanel; $s.Orientation='Horizontal'; $d=Dot $dotHex 7; $d.Margin='0,0,6,0'; if($pulse){ Pulse $d }; [void]$s.Children.Add($d); [void]$s.Children.Add((Textb "$count $label" $Csub 11 $null $null)); $b.Child=$s; return $b }

# ---- transport (the pause lever) ----
# A 1990s deck transport, not a text button. Two latching keys in a recessed housing: the key
# matching the current state is lit and held DOWN, the other stands proud and is the one you can
# press. That is the shape the hardware had, and it settles the ambiguity a single toggle always
# carries — you press the key for the state you want, instead of guessing whether the icon shows
# what is happening or what will happen if you click it.
#
# The glyphs are drawn as geometry (a Polygon and two Rectangles), not ⏸/▶ characters: those render
# as whatever the fallback font decides, at whatever weight, and come out hairline-thin at this
# size. Solid shapes are the chunky VCR look, and they scale exactly.
$CkeyFace='#2E2E37'; $CkeyDown='#131317'; $CkeyLip='#6E6E7E'; $CkeyShadow='#000000'; $CkeyHousing='#0B0B0E'; $CkeyOff='#565663'

# Hard two-tone bevel. One Border carries one brush, so the lip and the shadow are two nested
# Borders: light top-left over dark bottom-right reads as raised; swapped reads as pressed in.
# Returns both so a click can invert them.
function FilterChip([string]$txt,[bool]$on,[scriptblock]$onClick){
  $b=New-Object System.Windows.Controls.Border; $b.CornerRadius=6; $b.Padding='7,2,7,2'; $b.Margin='0,0,5,5'; $b.Cursor='Hand'
  $b.Background=(B $(if($on){'#1F3A5F'}else{'#16161A'}))
  $b.BorderBrush=(B $(if($on){'#4C8EDA'}else{'#16FFFFFF'})); $b.BorderThickness=1
  $b.Child=(Textb $txt $(if($on){'#CFE3FF'}else{$Cmute}) 10 'SemiBold' $null)
  # Swallow the DOWN as well. The card is drag-to-move, so without this a click on a chip
  # starts a window drag and the chip never sees a clean up-click.
  $b.Add_MouseLeftButtonDown({ param($s,$e) $e.Handled=$true })
  $b.Add_MouseLeftButtonUp($onClick)
  return $b
}
function MenuRow([string]$txt,[int]$count,[bool]$on,[scriptblock]$onClick){
  $b=New-Object System.Windows.Controls.Border; $b.CornerRadius=5; $b.Padding='8,5,8,5'; $b.Cursor='Hand'
  $b.Background=(B $(if($on){'#1F3A5F'}else{'#00000000'}))
  if($on){ $b.Tag='sel' }   # read by the hover handlers so selection outranks hover
  $d=New-Object System.Windows.Controls.DockPanel; $d.LastChildFill=$true
  $c=Textb "$count" $Cmute 10 'SemiBold' 'Consolas'; [System.Windows.Controls.DockPanel]::SetDock($c,'Right'); [void]$d.Children.Add($c)
  [void]$d.Children.Add((Textb $txt $(if($on){'#CFE3FF'}else{$Csub}) 11 'SemiBold' $null | %{ $_.TextTrimming='CharacterEllipsis'; $_ }))
  $b.Child=$d
  # Same drag-swallow as FilterChip: the card is drag-to-move, so a bare Up handler would
  # lose the click to a window drag.
  $b.Add_MouseLeftButtonDown({ param($s,$e) $e.Handled=$true })
  $b.Add_MouseLeftButtonUp($onClick)
  $b.Add_MouseEnter({ param($s,$e) if(-not $s.Tag){ $s.Background=(B '#1C1C22') } })
  $b.Add_MouseLeave({ param($s,$e) if(-not $s.Tag){ $s.Background=(B '#00000000') } })
  return $b
}
function Bevel($child,[bool]$down){
  $outer=New-Object System.Windows.Controls.Border; $outer.BorderThickness='2,2,0,0'
  $inner=New-Object System.Windows.Controls.Border; $inner.BorderThickness='0,0,2,2'
  $outer.BorderBrush=(B $(if($down){$CkeyShadow}else{$CkeyLip})); $inner.BorderBrush=(B $(if($down){$CkeyLip}else{$CkeyShadow}))
  $inner.Child=$child; $outer.Child=$inner
  return @{ outer=$outer; inner=$inner }
}
function SetBevel($bv,[bool]$down){
  $bv.outer.BorderBrush=(B $(if($down){$CkeyShadow}else{$CkeyLip})); $bv.inner.BorderBrush=(B $(if($down){$CkeyLip}else{$CkeyShadow}))
}
function PlayGlyph([string]$hex){
  $p=New-Object System.Windows.Shapes.Polygon; $p.Fill=(B $hex); $p.Points=New-Object System.Windows.Media.PointCollection
  # 13x15, not 14x14: a triangle reads smaller than two bars of the same height, so it gets
  # the usual optical correction rather than matching numbers.
  foreach($pt in @(@(0,0),@(0,15),@(13,7.5))){ [void]$p.Points.Add((New-Object System.Windows.Point($pt[0],$pt[1]))) }
  $p.HorizontalAlignment='Center'; $p.VerticalAlignment='Center'; return $p
}
function PauseGlyph([string]$hex){
  $s=New-Object System.Windows.Controls.StackPanel; $s.Orientation='Horizontal'; $s.HorizontalAlignment='Center'; $s.VerticalAlignment='Center'
  foreach($i in 0,1){ $r=New-Object System.Windows.Shapes.Rectangle; $r.Width=4.5; $r.Height=14; $r.Fill=(B $hex); if($i -eq 0){ $r.Margin='0,0,4,0' }; [void]$s.Children.Add($r) }
  return $s
}
# One key. $lit = this key matches the current state, so it sits held down and coloured while the
# other key is the live control.
#
# Cursor is set on the key AND ForceCursor is turned on, because WPF's Cursor is NOT an inherited
# property: without ForceCursor the pointer snaps back to an arrow the moment it crosses the glyph
# inside, which is most of the key's area. That is why the old text button never showed a hand.
# One key, in one of four states:
#
#   lit   the state you are already in — latched down, coloured, inert (Arrow cursor says so
#         without a greyed-out look that would fight the "lit" reading)
#   live  the state you can switch to — raised, dim glyph, Hand cursor, handlers attached
#   busy  the state being switched TO right now — latched down and BLINKING, which is what a
#         deck did while the transport engaged, and inert so the click cannot be repeated
#   off   the other key during a transition — raised but dead, so nothing invites a second press
#
# Cursor is set on the key AND ForceCursor is turned on, because WPF's Cursor is NOT an inherited
# property: without ForceCursor the pointer snaps back to an arrow the moment it crosses the glyph
# inside, which is most of the key's area. That is why the old text button never showed a hand.
# A slot's own transport key, at pill scale. $paused is the slot's CURRENT state, so the glyph
# shows the ACTION: bars to hold a live slot, a triangle to resume a held one.
#
# $pending blinks it and detaches the handler, so a transition cannot be clicked twice -- the same
# rule TransportKey's "busy" state follows, for the same reason.
#
# Cursor AND ForceCursor, because WPF's Cursor is not inherited and the glyph covers most of the
# key: without ForceCursor the pointer reverts to an arrow exactly where you aim.
function SlotKey([bool]$paused,[string]$hex,[bool]$pending,[string]$tip,[scriptblock]$onPress){
  $b=New-Object System.Windows.Controls.Border; $b.Width=22; $b.Height=18; $b.CornerRadius=4
  $b.BorderThickness=1; $b.BorderBrush=(B ('#4D'+$hex.Substring(1))); $b.Background=(B ('#14'+$hex.Substring(1)))
  $b.VerticalAlignment='Center'; $b.Margin='8,0,0,0'
  if($paused){
    $g=New-Object System.Windows.Shapes.Polygon; $g.Fill=(B $hex); $g.Points=New-Object System.Windows.Media.PointCollection
    # 7x9 with the same optical correction the big triangle gets: narrower than the bars are tall.
    foreach($pt in @(@(0,0),@(0,9),@(7,4.5))){ [void]$g.Points.Add((New-Object System.Windows.Point($pt[0],$pt[1]))) }
    $g.HorizontalAlignment='Center'; $g.VerticalAlignment='Center'; $g.Margin='1,0,0,0'
  } else {
    $g=New-Object System.Windows.Controls.StackPanel; $g.Orientation='Horizontal'
    $g.HorizontalAlignment='Center'; $g.VerticalAlignment='Center'
    foreach($i in 0,1){ $r=New-Object System.Windows.Shapes.Rectangle; $r.Width=2.5; $r.Height=9; $r.Fill=(B $hex); if($i -eq 0){ $r.Margin='0,0,2.5,0' }; [void]$g.Children.Add($r) }
  }
  $b.Child=$g; $b.ToolTip=$tip
  if($pending){ Blink $b 0.6 }
  else {
    $b.Cursor='Hand'; $b.ForceCursor=$true
    $b.Add_MouseLeftButtonDown({ param($src,$ev) $ev.Handled=$true })
    $b.Add_MouseLeftButtonUp($onPress)
  }
  return $b
}
function TransportKey([string]$kind,[string]$state,[string]$litHex,[string]$tip,[scriptblock]$onPress){
  $down=($state -eq 'lit' -or $state -eq 'busy')
  $hex= if($down){$litHex}else{$CkeyOff}
  $face=New-Object System.Windows.Controls.Border; $face.Width=34; $face.Height=26
  $face.Background=(B $(if($down){$CkeyDown}else{$CkeyFace}))
  $face.Child=$(if($kind -eq 'play'){ PlayGlyph $hex }else{ PauseGlyph $hex })
  if($down){ $face.Child.Margin='1,1,0,0' }   # a pressed key sits low and right — the cheapest convincing depth cue there is
  $bv=Bevel $face $down
  $k=$bv.outer; $k.ToolTip=$tip
  if($state -eq 'busy'){ Blink $face.Child 0.42 }
  if($state -ne 'live'){ $k.Cursor='Arrow'; return $k }
  $k.Cursor='Hand'; $k.ForceCursor=$true
  $k.Add_MouseLeftButtonDown({ param($s,$e) $e.Handled=$true; SetBevel $bv $true; $face.Background=(B $CkeyDown) }.GetNewClosure())
  $k.Add_MouseLeave({ SetBevel $bv $false; $face.Background=(B $CkeyFace) }.GetNewClosure())
  $k.Add_MouseLeftButtonUp({ param($s,$e) $e.Handled=$true; SetBevel $bv $false; $face.Background=(B $CkeyFace); & $onPress }.GetNewClosure())
  return $k
}
# Blink — the engaging light. Steady opacity ramp rather than a hard on/off, which at this size
# reads as a rendering glitch rather than an indicator.
function Blink($el,[double]$sec){
  $a=New-Object System.Windows.Media.Animation.DoubleAnimation; $a.From=1; $a.To=0.18
  $a.Duration=(New-Object System.Windows.Duration([TimeSpan]::FromSeconds($sec))); $a.AutoReverse=$true
  $a.RepeatBehavior=[System.Windows.Media.Animation.RepeatBehavior]::Forever
  $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty,$a)
}
# The loader: three LED segments chasing, in the colour of the state being switched to. They are
# ALWAYS in the layout and merely unlit at rest — appearing on demand would resize the control
# mid-click and shift the key out from under the pointer.
function ChaseLeds([string]$hex,[bool]$running){
  $col=New-Object System.Windows.Controls.StackPanel; $col.Margin='5,0,0,0'; $col.VerticalAlignment='Center'
  for($i=0;$i -lt 3;$i++){
    $r=New-Object System.Windows.Shapes.Rectangle; $r.Width=5; $r.Height=5; $r.RadiusX=1; $r.RadiusY=1
    $r.Fill=(B $(if($running){$hex}else{'#1B1B21'})); if($i -lt 2){ $r.Margin='0,0,0,3' }
    if($running){
      $a=New-Object System.Windows.Media.Animation.DoubleAnimation; $a.From=1; $a.To=0.12
      $a.Duration=(New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.3))); $a.AutoReverse=$true
      $a.RepeatBehavior=[System.Windows.Media.Animation.RepeatBehavior]::Forever
      $a.BeginTime=[TimeSpan]::FromSeconds(0.2*$i)   # the stagger IS the chase
      $r.BeginAnimation([System.Windows.UIElement]::OpacityProperty,$a)
    }
    [void]$col.Children.Add($r)
  }
  return $col
}
# The housing the keys sit in: bevelled the other way round, so the cluster reads as recessed into
# the panel and the raised key stands out of it.
#
# $pending is $null when nothing is in flight, or the target state ($true = pausing) while a
# transition runs. During a transition NEITHER key is clickable and the loader runs, because the
# work behind it takes tens of seconds and a second press would be a request the box cannot honour.
function PauseBtn($paused,$busy,$pending){
  $moving=($null -ne $pending)
  $playState  = if($moving){ if($pending -eq $false){'busy'}else{'off'} } elseif(-not $paused){'lit'}else{'live'}
  $pauseState = if($moving){ if($pending -eq $true ){'busy'}else{'off'} } elseif($paused){'lit'}else{'live'}
  $playTip = if($moving){'Resuming — starting a listener.'}
             elseif($paused){'Resume — the slot takes the queue again, oldest first (~10s, then the usual cold start).'}
             else{'Running — the slot is taking jobs normally.'}
  $pauseTip = if($moving){'Pausing — draining, then stopping the listener. This takes a few seconds.'}
              elseif($paused){'Paused — held. No runner, no dind, no job. Queued runs keep queueing on GitHub and land when you resume.'}
              elseif($busy){'Pause — hold the runner AFTER the job now running finishes. That job is not touched. Queued runs keep queueing on GitHub and land when you resume.'}
              else{'Pause — stop the listener and free its memory. The runner stays registered, so queued runs keep queueing on GitHub and land when you resume.'}
  $row=New-Object System.Windows.Controls.StackPanel; $row.Orientation='Horizontal'
  $play=TransportKey 'play' $playState $Cgreen $playTip { Start-RunnerPause $false }
  $pause=TransportKey 'pause' $pauseState $Cpause $pauseTip { Start-RunnerPause $true }
  $pause.Margin='3,0,0,0'
  [void]$row.Children.Add($play); [void]$row.Children.Add($pause)
  [void]$row.Children.Add((ChaseLeds $(if($pending -eq $true){$Cpause}else{$Cgreen}) $moving))
  $housing=New-Object System.Windows.Controls.Border; $housing.Background=(B $CkeyHousing); $housing.Padding='4,4,4,4'; $housing.Child=$row
  $hb=Bevel $housing $true
  # The housing is furniture, not a control: same bevel geometry, quieter brushes, so the well
  # never competes with the key standing proud inside it.
  $hb.outer.BorderBrush=(B '#000000'); $hb.inner.BorderBrush=(B '#3A3A44')
  $hb.outer.VerticalAlignment='Center'
  if($moving){ $hb.outer.ToolTip=$(if($pending -eq $true){'Pausing…'}else{'Resuming…'}) }
  return $hb.outer
}


# Runs whose cancel GitHub has ACKNOWLEDGED but has not applied yet. A queued run has no runner
# to deliver the cancel to, so GitHub expires the assignment server-side instead and the run can
# sit in `queued` for MINUTES after the click (measured 2026-09-23: 7m02s, a appone Build &
# Deploy). With nothing on screen the honest reading of that wait is "my click did nothing", and
# the next thing anyone does is click again. Keyed by run id as a string; the renderer prunes an
# entry once the run leaves the queue.
$script:cancelReq=@{}

# ---- cancelling a queued run ----
# The one destructive action this window offers, so it confirms first. A queued run belongs to
# whoever pushed it; cancelling costs them a round trip, and the monitor is a glanceable window
# people click at speed.
#
# Runs off the UI thread for the same reason the pause lever does: `gh run cancel` is a network
# call, and a frozen window cannot show that anything happened. GitHub also acknowledges the
# request before the run flips to `cancelled`, so the refresh after it may still show the old
# state for a tick — that is GitHub being asynchronous, not the click failing.
function Cancel-QueuedRun([string]$repoName,[string]$rid,[string]$wf){
  if(-not $rid){ return }
  # $script:ghOrg, not a local $org from $Repo — see its definition for why that broke.
  $ans=[System.Windows.MessageBox]::Show(
    "Cancel queued run $rid?`n`n$script:ghOrg/$repoName · $wf`n`nIt has not started, so nothing is lost but the push will need re-running.",
    'Cancel queued run', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
  if($ans -ne [System.Windows.MessageBoxResult]::Yes){ return }
  $rs=[runspacefactory]::CreateRunspace(); $rs.Open()
  $ps=[powershell]::Create(); $ps.Runspace=$rs
  [void]$ps.AddScript({ param($r,$i) $o=& gh run cancel $i --repo $r 2>&1; [pscustomobject]@{ code=$LASTEXITCODE; out=@($o) } }).AddArgument("$script:ghOrg/$repoName").AddArgument($rid)
  $h=$ps.BeginInvoke()
  $t=New-Object System.Windows.Threading.DispatcherTimer; $t.Interval=[TimeSpan]::FromMilliseconds(250)
  $t.Add_Tick({
    if(-not $h.IsCompleted){ return }
    $t.Stop(); $err=''
    try { $r=@($ps.EndInvoke($h))[0]; if($r -and $r.code -ne 0){ $err=(@($r.out) | Select-Object -Last 2) -join ' ' } } catch { $err=$_.Exception.Message }
    try { $ps.Dispose(); $rs.Close(); $rs.Dispose() } catch {}
    $m=$global:wins['control'].model
    if($m){ if($err){ $m.error="cancel $rid : $err" } elseif($m.error -like "cancel *"){ $m.error=$null } }
    # gh returned 0: GitHub has the request. The run itself flips later, so remember the moment
    # and let the queue row say so until it does.
    if(-not $err){ $script:cancelReq["$rid"]=(Get-Date) }
    & $refresh
  }.GetNewClosure())
  $t.Start()
}


# ---- re-running a failed run ----
# Same shape as Cancel-QueuedRun, and same reasoning: confirm first, run off the UI thread.
# `--failed` rather than a whole-run re-run, because that is what an operator looking at a red
# row wants — retry what broke, keep what passed, and do not pay for green jobs again.
#
# Only offered where BOTH the run id and the repo resolved. The run id comes from the Worker
# log, so a deploy the monitor never matched to a log has no id and gets no button: an
# re-run control that might address the wrong run is worse than none.
function Rerun-FailedRun([string]$repoName,[string]$rid,[string]$label){
  if(-not $rid -or -not $repoName){ return }
  # $script:ghOrg, not a local $org from $Repo — see its definition for why that broke.
  $ans=[System.Windows.MessageBox]::Show(
    "Re-run the failed jobs of run $rid?`n`n$script:ghOrg/$repoName`n$label`n`nPassing jobs are not re-run.",
    'Re-run failed jobs', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
  if($ans -ne [System.Windows.MessageBoxResult]::Yes){ return }
  $rs=[runspacefactory]::CreateRunspace(); $rs.Open()
  $ps=[powershell]::Create(); $ps.Runspace=$rs
  [void]$ps.AddScript({ param($r,$i) $o=& gh run rerun $i --failed --repo $r 2>&1; [pscustomobject]@{ code=$LASTEXITCODE; out=@($o) } }).AddArgument("$script:ghOrg/$repoName").AddArgument($rid)
  $h=$ps.BeginInvoke()
  $t=New-Object System.Windows.Threading.DispatcherTimer; $t.Interval=[TimeSpan]::FromMilliseconds(250)
  $t.Add_Tick({
    if(-not $h.IsCompleted){ return }
    $t.Stop(); $err=''
    try { $x=@($ps.EndInvoke($h))[0]; if($x -and $x.code -ne 0){ $err=(@($x.out) | Select-Object -Last 2) -join ' ' } } catch { $err=$_.Exception.Message }
    try { $ps.Dispose(); $rs.Close(); $rs.Dispose() } catch {}
    $m=$global:wins['control'].model
    if($m){ if($err){ $m.error="re-run $rid : $err" } elseif($m.error -like 're-run *'){ $m.error=$null } }
    & $refresh
  }.GetNewClosure())
  $t.Start()
}

# ---- view builders ----
function Build-ControlPanel($m){
  $root=New-Object System.Windows.Controls.StackPanel; $root.Width=468
  $h=New-Object System.Windows.Controls.DockPanel; $h.Margin='16,14,16,10'; $h.LastChildFill=$false
  $tl=TLights 'control'; [System.Windows.Controls.DockPanel]::SetDock($tl,'Left'); [void]$h.Children.Add($tl)
  $t=Textb 'Deploy control plane' $Ctext 13 'Bold' $null; [System.Windows.Controls.DockPanel]::SetDock($t,'Left'); [void]$h.Children.Add($t)
  # Runner badge — four states, not two. A paused runner is neither busy nor idle, and showing
  # it as "idle" would be an outright lie: idle means "ready for the next job", paused means
  # "will not take one". DRAINING is the honest label for the overlap (held, but the job that
  # was already running is still finishing).
  # Slots are the local truth and outrank both inputs when present. $m.busy is derived
  # from GitHub's in_progress list, which counts HOSTED runs too -- on 2026-09-30 it said
  # "busy" for a appone job that was deliberately not on this box. $m.paused was the
  # slot-1 flag alone. Fall back to both only when the distro could not answer.
  $sl=@(@($m.slots) | Where-Object { $_ })
  if($sl.Count -gt 0){
    $bBusy   = [bool](@($sl | Where-Object { $_.state -eq 'busy' }).Count)
    # ALL, not any: one held slot out of two is not a held box, and calling it "paused"
    # would say no work can land when half the capacity is still taking jobs.
    $bPaused = (@($sl | Where-Object { $_.paused -eq 'yes' }).Count -eq $sl.Count)
  } else {
    $bPaused=[bool]$m.paused; $bBusy=[bool]$m.busy
  }
  $bDown = [bool](@($sl | Where-Object { $_.state -eq 'down' }).Count)
  $bTxt = if($bPaused -and $bBusy){'this PC · draining'} elseif($bPaused){'this PC · paused'} elseif($bBusy){'this PC · busy'} elseif($bDown){'this PC · slot down'} else {'this PC · idle'}
  $bHex = if($bPaused){$Cpause} elseif($bBusy){$Corange} elseif($bDown){$Cred} else {$Cgreen}
  $bBg  = if($bPaused){'#1A58A6FF'} elseif($bBusy){'#1AE3A008'} elseif($bDown){'#1AF85149'} else {'#1A3FB950'}
  $bBd  = if($bPaused){'#4058A6FF'} elseif($bBusy){'#40E3A008'} elseif($bDown){'#40F85149'} else {'#403FB950'}
  $rb=New-Object System.Windows.Controls.Border; $rb.CornerRadius=7; $rb.Padding='9,4,9,4'; $rb.Background=(B $bBg); $rb.BorderBrush=(B $bBd); $rb.BorderThickness=1
  $rs=New-Object System.Windows.Controls.StackPanel; $rs.Orientation='Horizontal'; $rd=Dot $bHex 7; $rd.Margin='0,0,6,0'; if($bBusy){ Pulse $rd }; [void]$rs.Children.Add($rd); [void]$rs.Children.Add((Textb $bTxt $bHex 10.5 'SemiBold' $null)); $rb.Child=$rs
  # Docked Right in add order, so the badge takes the edge and the lever sits just inside it.
  if($m.animBadge){ Pop-In $rb }; [System.Windows.Controls.DockPanel]::SetDock($rb,'Right'); [void]$h.Children.Add($rb)
  $pb=PauseBtn $bPaused $bBusy $m.pending; $pb.Margin='0,0,8,0'; [System.Windows.Controls.DockPanel]::SetDock($pb,'Right'); [void]$h.Children.Add($pb)
  [void]$root.Children.Add($h)
  # ---- slots ----
  # The badge says whether the box is busy; this says WHICH slot and with WHAT. Added
  # 2026-09-30, after a job ran on slot 2 and the card showed an idle machine: with one
  # slot the badge was the whole truth, with two it is a summary of two different answers.
  #
  # ONE row, one PILL per slot, in a star-sized Grid -- so it stays one row at three slots
  # too, and the chips and the queue keep their place on the card. Separate pills rather
  # than one bordered row split by a divider: a seam carries no information, and two
  # distinct shapes let the eye count busy slots without reading a word.
  #
  # Rendered only when the distro answered. An empty strip is better than a made-up one --
  # "no slots" and "could not ask" look identical to a reader and mean opposite things.
  #
  # The OUTER @() is load-bearing: a pipeline yielding one object returns that object, not a
  # one-element array, and on a single-slot box (any rollback) $sl.Count then read as a
  # property of the slot rather than a length -- the strip disappeared entirely.
  if($sl.Count -gt 0){
    [void]$root.Children.Add((Textb "RUNNER SLOTS ($($sl.Count))" $Cdim 9.5 'Bold' $null | %{ $_.Margin='16,12,16,7'; $_ }))
    # The 12 at the bottom separates the slots from the chips below. It lives HERE rather than
    # on the chips row, because that row also renders on a box that reports no slots — putting
    # the gap there would leave a hole under the badge whenever the strip is absent.
    $sg=New-Object System.Windows.Controls.Grid; $sg.Margin='16,0,16,12'
    $si=0; $sn=$sl.Count
    foreach($sx in ($sl | Sort-Object { [int]$_.slot })){
      $cd=New-Object System.Windows.Controls.ColumnDefinition
      $cd.Width=(New-Object System.Windows.GridLength(1,[System.Windows.GridUnitType]::Star))
      $sg.ColumnDefinitions.Add($cd)
      $st=[string]$sx.state
      # Same alpha convention as the runner badge above, so the two never disagree about what
      # a state looks like. Idle alone keeps the neutral card surface: tinting all four would
      # light every pill on a quiet box and leave a busy or dead slot nothing to stand out
      # against.
      $sHex = switch($st){ 'busy' {$Corange}     'paused' {$Cpause}     'down' {$Cred}       default {$Cgreen} }
      $sBg  = switch($st){ 'busy' {'#1AE3A008'}  'paused' {'#1A58A6FF'} 'down' {'#1AF85149'} default {'#141418'} }
      $sBd  = switch($st){ 'busy' {'#40E3A008'}  'paused' {'#4058A6FF'} 'down' {'#40F85149'} default {'#2C3FB950'} }
      $sAcc=SlotHue $sx.slot
      # A pill in transition shows that, and shows it INSTEAD of a state that is about to stop
      # being true. $global:slotOp is the only thing the UI thread knows about an in-flight hold;
      # the flag file is the answer, and it arrives on the next gather.
      $sOp=$global:slotOp
      $sBusyOp=($sOp -and [int]$sOp.slot -eq [int]$sx.slot)
      if($sBusyOp){ $st=$(if($sOp.target){'holding'}else{'resuming'}); $sHex=$Cpause; $sBg='#1A58A6FF'; $sBd='#4058A6FF' }
      $cell=New-Object System.Windows.Controls.Border
      $cell.Background=(B $sBg); $cell.BorderBrush=(B $sBd); $cell.BorderThickness=1
      $cell.CornerRadius=9; $cell.Padding='9,7,11,7'
      # The pill itself is NOT a click target. The key below is, so the control is visible and
      # a glance at the card cannot hold a slot by accident.
      $sN=[int]$sx.slot; $sWasPaused=($sx.paused -eq 'yes')
      $sTip=$(if($sBusyOp){ 'working...' }
              elseif($sWasPaused){ "Resume slot $sN. The other slot is unaffected." }
              else { "Hold slot $sN only - the other slot keeps taking jobs, and a job already running here is left to finish." })
      # Gap between pills, carried on every cell but the last so the row still ends flush
      # with the chips and the queue below it.
      if($si -lt $sn-1){ $cell.Margin='0,0,8,0' }
      $sd=New-Object System.Windows.Controls.DockPanel; $sd.LastChildFill=$true
      # The key is docked before the elapsed, so it lands at the pill's right edge and sits at the
      # same x on every row whatever the job name does. Inert while EITHER lever is transitioning.
      $sKey=SlotKey $sWasPaused $(if($sBusyOp){$Cpause}else{$sAcc}) ($sBusyOp -or [bool]$global:pauseOp) $sTip `
        ({ param($src,$ev) $ev.Handled=$true; Start-SlotPause $sN (-not $sWasPaused) }.GetNewClosure())
      [System.Windows.Controls.DockPanel]::SetDock($sKey,'Right'); [void]$sd.Children.Add($sKey)
      # Elapsed docked right, tabular, so two slots' timers line up as a column rather than
      # reading as two sentences. Docked FIRST so it keeps its width and the job name is what
      # gives way when the pill is narrow.
      if($st -eq 'busy' -and [int]$sx.seconds -gt 0){
        $ss=[int]$sx.seconds
        $sage = if($ss -lt 60){ "${ss}s" } else { '{0}m {1:00}s' -f [int]($ss/60),($ss%60) }
        $se=Textb $sage $Cdim 9.5 'Bold' 'Consolas'; $se.VerticalAlignment='Center'; $se.Margin='8,0,0,0'
        [System.Windows.Controls.DockPanel]::SetDock($se,'Right'); [void]$sd.Children.Add($se)
      }
      # The slot's own colour, as a 3px edge. Left of the state dot on purpose: identity first,
      # then what it is doing. Stretch rather than a fixed height so it tracks the row.
      $sbar=New-Object System.Windows.Shapes.Rectangle; $sbar.Width=3; $sbar.RadiusX=1.5; $sbar.RadiusY=1.5
      $sbar.Fill=(B $sAcc); $sbar.VerticalAlignment='Stretch'; $sbar.Margin='0,0,9,0'
      [System.Windows.Controls.DockPanel]::SetDock($sbar,'Left'); [void]$sd.Children.Add($sbar)
      $sp=New-Object System.Windows.Controls.StackPanel; $sp.Orientation='Horizontal'
      $sdot=Dot $sHex 7; $sdot.Margin='0,0,7,0'; $sdot.VerticalAlignment='Center'
      if($st -eq 'busy'){ Pulse $sdot }
      [void]$sp.Children.Add($sdot)
      [void]$sp.Children.Add((Textb "slot $($sx.slot)" $sAcc 11 'SemiBold' $null | %{ $_.VerticalAlignment='Center'; $_.Margin='0,0,7,0'; $_ }))
      [void]$sp.Children.Add((Textb $st $sHex 10.5 'SemiBold' $null | %{ $_.VerticalAlignment='Center'; $_ }))
      # The job name only when there is one. "busy" with nothing after it is still useful;
      # "idle - " trailing a separator is just noise.
      if($sx.job){
        [void]$sp.Children.Add((Textb "·" $Cmute 10.5 $null $null | %{ $_.VerticalAlignment='Center'; $_.Margin='5,0,5,0'; $_ }))
        [void]$sp.Children.Add((Textb ([string]$sx.job) $Cdim 10.5 $null $null | %{ $_.VerticalAlignment='Center'; $_.TextTrimming='CharacterEllipsis'; $_.MaxWidth=112; $_ }))
      }
      elseif($st -eq 'down'){
        [void]$sp.Children.Add((Textb "· unit $($sx.unit)" $Cmute 10.5 $null $null | %{ $_.VerticalAlignment='Center'; $_.Margin='5,0,0,0'; $_ }))
      }
      [void]$sd.Children.Add($sp); $cell.Child=$sd
      [System.Windows.Controls.Grid]::SetColumn($cell,$si); [void]$sg.Children.Add($cell); $si++
    }
    [void]$root.Children.Add($sg)
  }
  if($m.error){ $eb=New-Object System.Windows.Controls.Border; $eb.CornerRadius=8; $eb.Margin='16,2,16,8'; $eb.Padding='11,9,11,9'; $eb.Background=(B '#1AF85149'); $eb.BorderBrush=(B '#45F85149'); $eb.BorderThickness=1
    $es=New-Object System.Windows.Controls.StackPanel; $es.Orientation='Horizontal'; [void]$es.Children.Add((Textb '⚠' '#F85149' 13 $null $null | %{ $_.Margin='0,0,9,0'; $_.VerticalAlignment='Top'; $_ })); [void]$es.Children.Add((Textb $m.error '#FF9D96' 11 'SemiBold' $null | %{ $_.TextWrapping='Wrap'; $_.MaxWidth=402; $_ })); $eb.Child=$es; Pop-In $eb; [void]$root.Children.Add($eb) }
  $ch=New-Object System.Windows.Controls.StackPanel; $ch.Orientation='Horizontal'; $ch.Margin='16,0,16,4'
  $crun=Chip $m.runningCount 'running' '#E3A008' ($m.runningCount -gt 0); if($m.animChips.running){ Pop-In $crun }; [void]$ch.Children.Add($crun)
  $cque=Chip $m.queuedCount 'queued' '#3A3A44'; if($m.animChips.queued){ Pop-In $cque }; [void]$ch.Children.Add($cque)
  $csucc=Chip $m.success24 'success · 24h' '#3FB950' $false; if($m.animChips.success){ Pop-In $csucc }; [void]$ch.Children.Add($csucc)
  $cfail=Chip $m.failed24 'failed · 24h' '#DA3633'; if($m.animChips.failed){ Pop-In $cfail }; [void]$ch.Children.Add($cfail)
  [void]$root.Children.Add($ch)
  [void]$root.Children.Add((Textb "INCOMING · QUEUED ($($m.queuedCount))$(if($m.paused){' · HELD'})" $Cdim 9.5 'Bold' $null | %{ $_.Margin='16,16,16,9'; $_ }))
  # While paused the queue is not ours and is not lost: these are GitHub-side runs waiting on a
  # runner that is still registered, just held. Saying so here is the whole difference between
  # "the queue is building, as designed" and "CI is broken".
  if($m.paused){ [void]$root.Children.Add((Textb 'held — these land oldest-first when you resume' $Cpause 10 'SemiBold' $null | %{ $_.Margin='16,0,16,8'; $_ })) }
  $qrow=New-Object System.Windows.Controls.StackPanel; $qrow.Margin='16,0,16,0'
  if($m.queued.Count -eq 0){ [void]$qrow.Children.Add((Textb 'nothing queued' $Cmute 11 $null $null)) }
  else {
    # one full-width row per queued task, stacked top-to-bottom (soonest to run first).
    foreach($q in $m.queued){ $qc=New-Object System.Windows.Controls.Border; $qc.Background=(B '#141418'); $qc.BorderThickness=1; $qc.BorderBrush=(B '#21FFFFFF'); $qc.CornerRadius=10; $qc.Padding='12,9,12,9'; $qc.Margin='0,0,0,7'
      # single line: <repo> · <workflow> · <sha6> · <commit subject>, with the #pos badge at the
      # end (docked right).
      $qt=New-Object System.Windows.Controls.DockPanel; $qt.LastChildFill=$true
      $pos=New-Object System.Windows.Controls.Border; $pos.CornerRadius=4; $pos.BorderBrush=(B '#1AFFFFFF'); $pos.BorderThickness=1; $pos.Padding='5,1,5,1'; $pos.Margin='8,0,0,0'; $pos.VerticalAlignment='Center'; $pos.Child=(Textb "#$($q.pos)" $Cdim 9.5 'Bold' 'Consolas'); [System.Windows.Controls.DockPanel]::SetDock($pos,'Right'); [void]$qt.Children.Add($pos)
      # A cancel control per queued run. It is the only destructive thing in this window, so it
      # sits quiet until hovered, asks once, and names what it will cancel — a queued run is
      # somebody's push, and an accidental click costs them a round trip.
      # A cancel already acknowledged for this run replaces the button with a live counter. The
      # counter is the point: a number that moves is proof the click landed, where a row that
      # looks untouched reads as a failed click and invites a second one. Amber, not red — this
      # is in-flight, not broken.
      $creq=$script:cancelReq["$($q.rid)"]
      if($creq){
        $csec=[int]((Get-Date)-$creq).TotalSeconds
        $cage= if($csec -lt 60){ "${csec}s" } else { '{0}m {1:00}s' -f [int]($csec/60),($csec%60) }
        $cx=New-Object System.Windows.Controls.Border; $cx.CornerRadius=4; $cx.BorderBrush=(B '#33E3B341'); $cx.BorderThickness=1
        $cx.Padding='6,1,6,1'; $cx.Margin='8,0,0,0'; $cx.VerticalAlignment='Center'; $cx.Background=(B '#12E3B341')
        $cx.Child=(Textb "cancelling... $cage" '#E3B341' 9.5 'Bold' $null)
        $cx.ToolTip="GitHub has ACCEPTED the cancel for run $($q.rid) and is applying it. A queued run has no runner to deliver a cancel to, so it can take minutes to flip — the click worked, nothing more to do."
      } else {
        $cx=New-Object System.Windows.Controls.Border; $cx.CornerRadius=4; $cx.BorderBrush=(B '#33F85149'); $cx.BorderThickness=1
        $cx.Padding='6,1,6,1'; $cx.Margin='8,0,0,0'; $cx.VerticalAlignment='Center'; $cx.Background=(B '#12F85149')
        $cx.Cursor='Hand'; $cx.ForceCursor=$true
        $cx.Child=(Textb 'cancel' '#F0857A' 9.5 'Bold' $null)
        $cx.ToolTip="Cancel run $($q.rid) — $($q.repo) · $($q.wf). It is queued, so nothing has run yet."
        $cx.Add_MouseLeftButtonDown({ param($s,$e) $e.Handled=$true })
        $cx.Add_MouseLeftButtonUp({ param($s,$e) $e.Handled=$true; Cancel-QueuedRun $q.repo $q.rid $q.wf }.GetNewClosure())
      }
      [System.Windows.Controls.DockPanel]::SetDock($cx,'Right'); [void]$qt.Children.Add($cx)
      $tb=New-Object System.Windows.Controls.TextBlock; $tb.TextTrimming='CharacterEllipsis'; $tb.VerticalAlignment='Center'
      $rr=New-Object System.Windows.Documents.Run($q.repo); $rr.Foreground=(B '#D4D7DE'); $rr.FontWeight=[System.Windows.FontWeights]::SemiBold; [void]$tb.Inlines.Add($rr)
      $rb=New-Object System.Windows.Documents.Run(" · $($q.wf)"); $rb.Foreground=(B $Csub); [void]$tb.Inlines.Add($rb)
      if($q.sha){ $rs=New-Object System.Windows.Documents.Run(" · $($q.sha)"); $rs.Foreground=(B $Corange); $rs.FontFamily=(New-Object System.Windows.Media.FontFamily('Consolas')); [void]$tb.Inlines.Add($rs) }
      if($q.msg){ $rmsg=New-Object System.Windows.Documents.Run("  $($q.msg)"); $rmsg.Foreground=(B $Csub); [void]$tb.Inlines.Add($rmsg) }
      [void]$qt.Children.Add($tb)
      $qc.Child=$qt; if($m.changed -and $m.changed.ContainsKey($q.id)){ Pop-In $qc }; [void]$qrow.Children.Add($qc) } }
  # Prune. A run leaves the queue either because the cancel landed or because it started anyway;
  # both mean the pill has said all it can, and an entry left behind would resurrect it the next
  # time GitHub reused that id.
  if($script:cancelReq.Count -gt 0){
    $qlive=@{}; foreach($q in $m.queued){ $qlive["$($q.rid)"]=$true }
    foreach($k in @($script:cancelReq.Keys)){ if(-not $qlive.ContainsKey($k)){ $script:cancelReq.Remove($k) } } }
  [void]$root.Children.Add($qrow)
  $pool=@($m.recent)
  # --- filter state -----------------------------------------------------------------
  # 'all' | 'failed' | '<repo>'. Kept on the window, not the model, so a refresh never
  # resets what the operator is looking at.
  $fil=[string]$global:wins['control'].recentFilter; if(-not $fil){ $fil='all' }
  $repos=@($pool | ForEach-Object { $_.repo } | Where-Object { $_ } | Sort-Object -Unique)
  # A cancelled run is not a failure. `-not $_.ok` swept it into both the count and the
  # filter, so cancelling a queued run made the failed chip tick up — the opposite of the
  # reassurance cancelling is supposed to give.
  $nFail=@($pool | Where-Object { $_.state -eq 'failure' -or (-not $_.state -and -not $_.ok) }).Count
  # A repo filter outlives the repo: pick "appeight", come back tomorrow, and appeight has aged out
  # of the pool. Without this the card would render an empty list pinned to a chip that is
  # no longer drawn — no visible way back. Fall back to 'all' instead.
  if($fil -ne 'all' -and $fil -ne 'failed' -and ($repos -notcontains $fil)){ $fil='all'; $global:wins['control'].recentFilter='all' }

  $rh=New-Object System.Windows.Controls.DockPanel; $rh.Margin='16,14,16,4'; $rh.LastChildFill=$false
  [void]$rh.Children.Add((Textb 'RECENT' $Cdim 9.5 'Bold' $null))
  if($fil -ne 'all'){ $cl=Textb '✕  clear' $Csub 9.5 'SemiBold' $null; $cl.Cursor='Hand'
    $cl.Add_MouseLeftButtonDown({ param($s,$e) $e.Handled=$true })
    $cl.Add_MouseLeftButtonUp({ param($s,$e) $e.Handled=$true; $global:wins['control'].recentFilter='all'; $global:wins['control'].recentExpanded=$false; $global:wins['control'].repoMenuOpen=$false; Render-Win 'control' })
    [System.Windows.Controls.DockPanel]::SetDock($cl,'Right'); [void]$rh.Children.Add($cl) }
  [void]$root.Children.Add($rh)

  # Two fixed modes as chips, repos behind a dropdown. One chip per repo does not scale — the
  # list grows with whatever has used the box lately and would wrap into several rows above a
  # three-row list.
  $onRepo=($fil -ne 'all' -and $fil -ne 'failed')
  # A repo with nothing in the pool cannot be chosen, so don't draw a control that opens an
  # empty menu.
  $menuOpen=([bool]$global:wins['control'].repoMenuOpen -and $repos.Count -gt 0)
  $fp=New-Object System.Windows.Controls.StackPanel; $fp.Orientation='Horizontal'; $fp.Margin='16,0,16,5'
  [void]$fp.Children.Add((FilterChip "all ($($pool.Count))" ($fil -eq 'all') { param($s,$e) $e.Handled=$true; $global:wins['control'].recentFilter='all'; $global:wins['control'].recentExpanded=$false; $global:wins['control'].repoMenuOpen=$false; Render-Win 'control' }))
  [void]$fp.Children.Add((FilterChip "failed ($nFail)" ($fil -eq 'failed') { param($s,$e) $e.Handled=$true; $global:wins['control'].recentFilter='failed'; $global:wins['control'].recentExpanded=$false; $global:wins['control'].repoMenuOpen=$false; Render-Win 'control' }))
  if($repos.Count -gt 0){
    $selLbl= if($onRepo){ $fil } else { 'repo' }
    if($selLbl.Length -gt 18){ $selLbl=$selLbl.Substring(0,17)+'…' }
    [void]$fp.Children.Add((FilterChip "$selLbl  $(if($menuOpen){'▴'}else{'▾'})" $onRepo { param($s,$e) $e.Handled=$true; $global:wins['control'].repoMenuOpen = -not [bool]$global:wins['control'].repoMenuOpen; Render-Win 'control' }))
  }
  [void]$root.Children.Add($fp)

  # The menu opens INLINE and pushes the list down, rather than in a WPF Popup. A Popup is a
  # separate HWND: on this window (WindowStyle=None + AllowsTransparency + Topmost) placement
  # and z-order are unreliable, and the card is rebuilt wholesale every refresh — 15s by
  # default — which would tear the Popup down mid-choice. Inline state is just layout, so it
  # survives the rebuild exactly the way recentExpanded already does.
  if($menuOpen){
    $mn=New-Object System.Windows.Controls.Border; $mn.Margin='16,0,16,6'; $mn.CornerRadius=8
    $mn.Background=(B '#141418'); $mn.BorderBrush=(B '#20FFFFFF'); $mn.BorderThickness=1; $mn.Padding='4,4,4,4'
    $ms=New-Object System.Windows.Controls.StackPanel
    [void]$ms.Children.Add((MenuRow 'all repos' $pool.Count ($fil -eq 'all') { param($s,$e) $e.Handled=$true; $global:wins['control'].recentFilter='all'; $global:wins['control'].repoMenuOpen=$false; $global:wins['control'].recentExpanded=$false; Render-Win 'control' }))
    foreach($rp in $repos){
      $cnt=@($pool | Where-Object { $_.repo -eq $rp }).Count
      # GetNewClosure() is REQUIRED here. PowerShell scriptblocks capture the variable, not its
      # value, so without it every row would share the loop's final $rp and they would all
      # select the last repo in the list.
      $h=({ param($s,$e) $e.Handled=$true; $global:wins['control'].recentFilter=$rp; $global:wins['control'].repoMenuOpen=$false; $global:wins['control'].recentExpanded=$false; Render-Win 'control' }).GetNewClosure()
      [void]$ms.Children.Add((MenuRow $rp $cnt ($fil -eq $rp) $h))
    }
    $mn.Child=$ms; [void]$root.Children.Add($mn)
  }

  $rw=New-Object System.Windows.Controls.StackPanel; $rw.Margin='16,0,16,2'
  # Filter first, THEN cap: 3 collapsed, 10 expanded.
  $filtered= switch($fil){
    'all'    { $pool }
    'failed' { @($pool | Where-Object { $_.state -eq 'failure' -or (-not $_.state -and -not $_.ok) }) }
    default  { @($pool | Where-Object { $_.repo -eq $fil }) }
  }
  $filtered=@($filtered)
  $exp=[bool]$global:wins['control'].recentExpanded
  $recShow=@($filtered | Select-Object -First $(if($exp){10}else{3}))
  if($recShow.Count -eq 0){ [void]$rw.Children.Add((Textb $(if($fil -eq 'failed'){'no failures in the last 60 runs'}else{'nothing for this filter'}) $Cmute 11 $null $null | %{ $_.Margin='0,6,0,6'; $_ })) }
  foreach($r in $recShow){ $bd=New-Object System.Windows.Controls.Border; $bd.BorderBrush=(B '#0DFFFFFF'); $bd.BorderThickness='0,1,0,0'; $bd.Padding='0,9,0,9'
    $rg=New-Object System.Windows.Controls.DockPanel; $rg.LastChildFill=$true
    $gl=Textb $r.glyph $r.glyphColor 12 $null $null; $gl.Width=16; $gl.TextAlignment='Center'; $gl.Margin='0,0,10,0'; [System.Windows.Controls.DockPanel]::SetDock($gl,'Left'); [void]$rg.Children.Add($gl)
    $ag=Textb $r.ago $Cmute 10.5 $null 'Consolas'; $ag.Width=58; $ag.TextAlignment='Right'; [System.Windows.Controls.DockPanel]::SetDock($ag,'Right'); [void]$rg.Children.Add($ag)
    $du=Textb $r.dur $Cdim 10.5 $null 'Consolas'; $du.Width=52; $du.TextAlignment='Right'; $du.Margin='0,0,4,0'; [System.Windows.Controls.DockPanel]::SetDock($du,'Right'); [void]$rg.Children.Add($du)
    $mb=MiniBars $r.stages 84; $mb.Margin='10,0,10,0'; [System.Windows.Controls.DockPanel]::SetDock($mb,'Right'); [void]$rg.Children.Add($mb)
    # Re-run control, only on a FAILED row that carries both a run id and a repo. Docked Right
    # before the timings so it sits at a consistent x whatever the label does, and kept narrow
    # because RECENT is 468px and the label is the part that identifies the row.
    if($r.state -eq 'failure' -and $r.rid -and $r.repo){
      $rr=New-Object System.Windows.Controls.Border; $rr.CornerRadius=4; $rr.BorderBrush=(B '#33E3A008'); $rr.BorderThickness=1
      $rr.Background=(B '#12E3A008'); $rr.Padding='6,1,6,1'; $rr.Margin='8,0,0,0'; $rr.VerticalAlignment='Center'
      $rr.Cursor='Hand'; $rr.ForceCursor=$true
      $rr.Child=(Textb 're-run' $Corange 9.5 'Bold' $null)
      $rr.ToolTip="Re-run the failed jobs of run $($r.rid) — $($r.repo). Passing jobs are not re-run."
      $rr.Add_MouseLeftButtonDown({ param($s,$e) $e.Handled=$true })
      $rr.Add_MouseLeftButtonUp({ param($s,$e) $e.Handled=$true; Rerun-FailedRun $r.repo $r.rid $r.label }.GetNewClosure())
      [System.Windows.Controls.DockPanel]::SetDock($rr,'Right'); [void]$rg.Children.Add($rr)
    }
    # Label and commit in ONE TextBlock, as inline runs. Two TextBlocks would let the label
    # ellipsize while the sha kept its width somewhere else on the row; this way the commit sits
    # against the name it belongs to and the pair truncates together.
    $rlab=New-Object System.Windows.Controls.TextBlock; $rlab.TextTrimming='CharacterEllipsis'; $rlab.VerticalAlignment='Center'
    $rl1=New-Object System.Windows.Documents.Run($r.label); $rl1.Foreground=(B $Csub); $rl1.FontWeight=[System.Windows.FontWeights]::SemiBold; [void]$rlab.Inlines.Add($rl1)
    # Dim rather than the amber the queue uses: there, amber means "not run yet". Here it is
    # history, and a second amber token would compete with the re-run control beside it.
    if($r.sha){ $rl2=New-Object System.Windows.Documents.Run(" · $($r.sha)"); $rl2.Foreground=(B $Cdim); $rl2.FontFamily=(New-Object System.Windows.Media.FontFamily('Consolas')); [void]$rlab.Inlines.Add($rl2) }
    [void]$rg.Children.Add($rlab); $bd.Child=$rg; if($m.changed -and $m.changed.ContainsKey($r.id)){ Pop-In $bd; Flash-Bg $bd $(switch($r.state){ 'success'{$Cgreen} 'cancelled'{$Ccancel} default{$Cred} }) 48 }; [void]$rw.Children.Add($bd) }
  [void]$root.Children.Add($rw)
  # Count the FILTERED list, and cap the "more" figure at what expanding can actually show.
  # Offering "show 47 more" and then rendering 10 would be a lie the operator notices once.
  $recTotal=$filtered.Count
  if($recTotal -gt 3){
    # Inside this branch recTotal >= 4, so min(recTotal,10)-3 is always >= 1.
    $more=[Math]::Min($recTotal,10)-3
    $tgTxt= if(-not $exp){ "▾  show $more more" }
            elseif($recTotal -gt 10){ "▴  show less  ·  $recTotal match, showing 10" }
            else { '▴  show less' }
    $tg=Textb $tgTxt $Csub 10.5 'SemiBold' $null; $tg.Cursor='Hand'; $tg.Margin='16,7,16,2'
    $tg.Add_MouseLeftButtonDown({ param($s,$e) $e.Handled=$true })
    $tg.Add_MouseLeftButtonUp({ param($s,$e) $e.Handled=$true; $global:wins['control'].recentExpanded = -not [bool]$global:wins['control'].recentExpanded; Render-Win 'control' })
    [void]$root.Children.Add($tg)
  }
  $sep=New-Object System.Windows.Controls.Border; $sep.BorderBrush=(B '#10FFFFFF'); $sep.BorderThickness='0,1,0,0'; $sep.Margin='16,8,16,0'; [void]$root.Children.Add($sep)
  [void]$root.Children.Add((Textb $m.footerStamp $Cdim 11 $null 'Consolas' | %{ $_.Margin='16,13,16,13'; $_ }))
  return $root
}
function Build-ControlMini($m){
  $b=New-Object System.Windows.Controls.Border; $b.Cursor='Hand'; $b.Padding='14,0,14,0'; $b.Height=52; $b.Background=(B '#01000000')
  $col=New-Object System.Windows.Controls.StackPanel; $col.VerticalAlignment='Center'
  $row=New-Object System.Windows.Controls.StackPanel; $row.Orientation='Horizontal'; $row.Margin='0,0,0,6'
  # The compact pill is what sits on the taskbar all day, so a hold has to be legible from it —
  # otherwise the operator minimises the monitor, forgets, and wonders why nothing is deploying.
  if($m.paused){ $pd=Dot $Cpause 7; $pd.Margin='0,0,5,0'; [void]$row.Children.Add($pd); [void]$row.Children.Add((Textb 'PAUSED' $Cpause 11.5 'Bold' $null | %{ $_.Margin='0,0,12,0'; $_ })) }
  foreach($c in @(@{n=$m.runningCount;l='running';d=$Corange},@{n=$m.queuedCount;l='queued';d='#3A3A44'},@{n=$m.success24;l='success';d=$Cgreen},@{n=$m.failed24;l='failed';d=$CredDeep})){
    $dd=Dot $c.d 7; $dd.Margin='0,0,5,0'; if($c.l -eq 'running' -and $m.runningCount -gt 0){ Pulse $dd }; [void]$row.Children.Add($dd); [void]$row.Children.Add((Textb "$($c.n) $($c.l)" $Csub 11.5 'SemiBold' $null | %{ $_.Margin='0,0,12,0'; $_ })) }
  [void]$col.Children.Add($row)
  [void]$col.Children.Add((Textb $m.footerStamp $Cmute 10 $null 'Consolas'))
  $b.Child=$col; return $b
}
function Build-DeployExpanded($d){
  $root=New-Object System.Windows.Controls.StackPanel; $root.Width=344
  $h=New-Object System.Windows.Controls.DockPanel; $h.Margin='15,13,15,11'; $h.LastChildFill=$false
  $tl=TLights $d.key; [System.Windows.Controls.DockPanel]::SetDock($tl,'Left'); [void]$h.Children.Add($tl)
  # ORDER MATTERS. A DockPanel hands out space in CHILD ORDER, so the badges are docked
  # BEFORE the title: they are short and fixed, the title is long and knows how to ellipsize.
  # With the title added first it took what it wanted and clipped the slot chip to "slo" --
  # an address made unreadable by the very title it was there to disambiguate.
  $pill=Pill $d.statusWord $d.dotColor $d.pillBg $d.pillBd; [System.Windows.Controls.DockPanel]::SetDock($pill,'Right'); [void]$h.Children.Add($pill)
  # Which slot, sitting just inside the status pill. Deliberately quiet -- neutral rather than
  # the status colour, because it is an address, not a verdict, and two coloured badges side by
  # side would read as two things needing attention.
  if($d.slotLabel){
    # Rim and text in the slot's hue, at a low alpha on the rim so it stays quieter than the
    # status pill beside it. Still an address, not a verdict -- just one you can now match to a
    # pill on the control plane without reading either.
    $sHexD=$(if($d.slotColor){$d.slotColor}else{'#94A3B8'})
    $sc2=New-Object System.Windows.Controls.Border; $sc2.CornerRadius=5; $sc2.BorderThickness=1
    $sc2.BorderBrush=(B ('#59' + $sHexD.Substring(1))); $sc2.Background=(B ('#14' + $sHexD.Substring(1)))
    $sc2.Padding='6,2,6,2'; $sc2.Margin='0,0,7,0'; $sc2.VerticalAlignment='Center'
    $sc2.Child=(Textb $d.slotLabel $sHexD 9.5 'Bold' 'Consolas')
    [System.Windows.Controls.DockPanel]::SetDock($sc2,'Right'); [void]$h.Children.Add($sc2)
  }
  [void]$h.Children.Add((Textb $d.runTitle $Ctext 13 'SemiBold' $null | %{ $_.TextTrimming='CharacterEllipsis'; $_ }))
  [void]$root.Children.Add($h)
  $n=@($d.stages).Count; if($n -lt 1){$n=1}
  $sg=New-Object System.Windows.Controls.Grid; $sg.Margin='15,4,15,0'; for($i=0;$i -lt $n;$i++){ $sg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) }
  for($i=0;$i -lt $n;$i++){ $stt=$d.stages[$i].status; $col=New-Object System.Windows.Controls.StackPanel; $col.Margin= if($i -lt ($n-1)){'0,0,6,0'}else{'0'}; [void]$col.Children.Add((Track 6 $stt $true))
    $lb=Textb $d.stages[$i].name (@{done=$Csub;active=$Ctext;failed='#FF9D96';pending='#555A64';skipped=$Cdim}[$stt]) 10.5 'SemiBold' $null; $lb.Margin='0,8,0,0'; $lb.TextTrimming='CharacterEllipsis'; $lb.TextAlignment= if($i -eq 0){'Left'}elseif($i -eq ($n-1)){'Right'}else{'Center'}; [void]$col.Children.Add($lb); [System.Windows.Controls.Grid]::SetColumn($col,$i); [void]$sg.Children.Add($col) }
  [void]$root.Children.Add($sg)
  $al=New-Object System.Windows.Controls.DockPanel; $al.Margin='15,15,15,0'; $al.LastChildFill=$false
  [void]$al.Children.Add((Textb $d.activeLine $d.activeColor 13 'SemiBold' $null | %{ $_.TextTrimming='CharacterEllipsis'; $_ })); $el=Textb $d.elapsed '#9AA0AA' 12 $null 'Consolas'; [System.Windows.Controls.DockPanel]::SetDock($el,'Right'); [void]$al.Children.Add($el); [void]$root.Children.Add($al)
  $rl=New-Object System.Windows.Controls.StackPanel; $rl.Orientation='Horizontal'; $rl.Margin='15,11,15,0'
  # The tag already said COMMIT and then printed the commit's SUBJECT, which is the one thing
  # that does not identify it. The sha goes in the tag itself, so the line reads
  # "<sha6>  <subject>" and the row can be matched to a run.
  $tag=New-Object System.Windows.Controls.Border; $tag.CornerRadius=5; $tag.BorderBrush=(B '#1FFFFFFF'); $tag.BorderThickness=1; $tag.Padding='6,2,6,2'; $tag.Margin='0,0,8,0'
  $tag.Child=(Textb $(if($d.sha){$d.sha}else{'COMMIT'}) $(if($d.sha){$Csub}else{$Cmute}) 9.5 'Bold' 'Consolas'); [void]$rl.Children.Add($tag)
  [void]$rl.Children.Add((Textb $d.runnerLine $Csub 11.5 $null 'Consolas' | %{ $_.TextTrimming='CharacterEllipsis'; $_.MaxWidth=255; $_ })); [void]$root.Children.Add($rl)
  if($d.hasError){ $eb=New-Object System.Windows.Controls.Border; $eb.Margin='15,11,15,0'; $eb.Padding='11,9,11,9'; $eb.CornerRadius=8; $eb.Background=(B '#14F85149'); $eb.BorderBrush=(B '#38F85149'); $eb.BorderThickness=1
    $es=New-Object System.Windows.Controls.StackPanel; $es.Orientation='Horizontal'; [void]$es.Children.Add((Textb '▲' $Cred 12 $null $null | %{ $_.Margin='0,0,7,0'; $_.VerticalAlignment='Top'; $_ })); [void]$es.Children.Add((Textb $d.errorLine '#FF9D96' 11 $null 'Consolas' | %{ $_.TextWrapping='Wrap'; $_.MaxWidth=285; $_ })); $eb.Child=$es; [void]$root.Children.Add($eb) }
  $sep=New-Object System.Windows.Controls.Border; $sep.BorderBrush=(B '#10FFFFFF'); $sep.BorderThickness='0,1,0,0'; $sep.Margin='15,13,15,0'; [void]$root.Children.Add($sep)
  [void]$root.Children.Add((Textb $d.footerStamp $Cdim 11 $null 'Consolas' | %{ $_.Margin='15,12,15,14'; $_ }))
  return $root
}
function Build-DeployMini($d){
  $b=New-Object System.Windows.Controls.Border; $b.Width=280; $b.Height=56; $b.Cursor='Hand'; $b.Background=(B '#01000000')
  $sp=New-Object System.Windows.Controls.StackPanel; $sp.Orientation='Horizontal'; $sp.Margin='15,0,15,0'; $sp.VerticalAlignment='Center'
  $dot=Dot $d.dotColor 9; $dot.Margin='0,0,11,0'
  if($d.busy){ $pa=New-Object System.Windows.Media.Animation.DoubleAnimation; $pa.From=0.5; $pa.To=1; $pa.Duration=(New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.9))); $pa.AutoReverse=$true; $pa.RepeatBehavior=[System.Windows.Media.Animation.RepeatBehavior]::Forever; $dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty,$pa) }
  [void]$sp.Children.Add($dot)
  $col=New-Object System.Windows.Controls.StackPanel; $col.Width=215; $col.VerticalAlignment='Center'
  $row=New-Object System.Windows.Controls.DockPanel; $row.LastChildFill=$false; $row.Margin='0,0,0,7'
  # repo (bold) + workflow first so they stay visible when collapsed even if the stage gets trimmed
  $nm=New-Object System.Windows.Controls.TextBlock; $nm.FontSize=12.5; $nm.VerticalAlignment='Center'; $nm.TextTrimming='CharacterEllipsis'
  $rr=New-Object System.Windows.Documents.Run($d.repoName); $rr.Foreground=(B $Ctext); $rr.FontWeight=[System.Windows.FontWeights]::SemiBold; [void]$nm.Inlines.Add($rr)
  $rwf=New-Object System.Windows.Documents.Run(" · $($d.workflowName)"); $rwf.Foreground=(B $Csub); [void]$nm.Inlines.Add($rwf)
  $rst=New-Object System.Windows.Documents.Run(" · $($d.activeName)"); $rst.Foreground=(B $Cmute); [void]$nm.Inlines.Add($rst)
  [System.Windows.Controls.DockPanel]::SetDock($nm,'Left'); [void]$row.Children.Add($nm)
  $mt=Textb $d.miniMeta '#7D818C' 11 $null 'Consolas'; [System.Windows.Controls.DockPanel]::SetDock($mt,'Right'); [void]$row.Children.Add($mt); [void]$col.Children.Add($row); [void]$col.Children.Add((MiniBars $d.stages 215)); [void]$sp.Children.Add($col)
  $b.Child=$sp; return $b
}

# ---- window management ----
$global:wins=@{}    # key -> @{ win; host; kind; runId; view; userMoved; dragged; slot; model; shownFinal }
# distinct taskbar/window icon (green dot) so the button stands out next to other apps
$script:appIcon=$null
try { $bmp=New-Object System.Drawing.Bitmap(32,32); $gfx=[System.Drawing.Graphics]::FromImage($bmp); $gfx.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias; $gfx.Clear([System.Drawing.Color]::Transparent); $gfx.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,63,185,80))),5,5,22,22); $gfx.Dispose(); $hi=$bmp.GetHicon(); $script:appIcon=[System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($hi,[System.Windows.Int32Rect]::Empty,[System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()) } catch {}
function New-Shell([string]$title){
  # The title is interpolated into XAML and then parsed as XML, so it MUST be escaped.
  # A bare & makes the document invalid, [xml]$xaml throws, Make-Window never returns, and the
  # job card is simply never created -- silently, because the throw happens inside the timer
  # tick. Measured 2026-09-17 on appone job "Lint & Test / test": the control plane counted
  # the deploy as running while no card for it could ever open. It is the longest job on the
  # box, which is precisely the one an operator wants a card for.
  $title=[System.Security.SecurityElement]::Escape([string]$title)
  $xaml=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" WindowStartupLocation="Manual"
  WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ResizeMode="NoResize"
  ShowInTaskbar="True" Title="$title" SizeToContent="WidthAndHeight" FontFamily="Segoe UI">
  <Border x:Name="Root" CornerRadius="14" BorderThickness="1.2" Margin="26">
    <!-- white edge, brighter at the top, so the card reads clearly against dark windows -->
    <Border.BorderBrush><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#F2FFFFFF" Offset="0"/><GradientStop Color="#99FFFFFF" Offset="0.5"/><GradientStop Color="#5CFFFFFF" Offset="1"/></LinearGradientBrush></Border.BorderBrush>
    <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#121216" Offset="0"/><GradientStop Color="#0D0D11" Offset="1"/></LinearGradientBrush></Border.Background>
    <!-- soft light halo instead of a black drop shadow, which disappears over dark backgrounds -->
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="0" Color="#FFFFFF" Opacity="0.22"/></Border.Effect>
    <Grid x:Name="Host"/>
  </Border>
</Window>
"@
  return [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
}
function Make-Window([string]$key,[string]$kind,[string]$runId,[int]$slot,[string]$title,[string]$startView){
  $win=New-Shell $title
  if($script:appIcon){ try{ $win.Icon=$script:appIcon }catch{} }
  $root=$win.FindName('Root'); $host_=$win.FindName('Host')
  $e=@{ win=$win; host=$host_; root=$root; kind=$kind; runId=$runId; view=$startView; userMoved=$false; dragged=$false; slot=$slot; model=$null; shownFinal=$false }
  $global:wins[$key]=$e
  # drag only in non-mini views; record dragged to suppress the click-to-expand on minis
  # panel/expanded: drag immediately on press. mini: press+move = drag, press+release in place = expand.
  $root.Add_MouseLeftButtonDown({ param($s,$ev) $w=$global:wins[$key]
    if($w.view -like '*mini*'){ $w.pressing=$true; $w.moved=$false; $w.downPt=$ev.GetPosition($null) }
    else { $w.userMoved=$true; try{ $w.win.DragMove() }catch{} } }.GetNewClosure())
  $root.Add_MouseMove({ param($s,$ev) $w=$global:wins[$key]
    if($w.pressing -and -not $w.moved -and $ev.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed){ $c=$ev.GetPosition($null)
      if(([Math]::Abs($c.X-$w.downPt.X)+[Math]::Abs($c.Y-$w.downPt.Y)) -gt 4){ $w.moved=$true; $w.userMoved=$true; try{ $w.win.DragMove() }catch{} } } }.GetNewClosure())
  $root.Add_MouseLeftButtonUp({ param($s,$ev) $w=$global:wins[$key]; if($w.pressing -and -not $w.moved){ Toggle-View $key }; $w.pressing=$false }.GetNewClosure())
  $win.Add_SizeChanged({ Position-Win $key }.GetNewClosure())
  $win.Add_KeyDown({ param($s,$ev) if($ev.Key -eq 'Escape'){ if($key -eq 'control'){ Stop-All } else { $global:wins[$key].win.Close() } } }.GetNewClosure())
  $win.Add_StateChanged({ if($global:wins[$key].win.WindowState -eq [System.Windows.WindowState]::Normal){ $global:wins[$key].win.Topmost=$false; $global:wins[$key].win.Topmost=$true } }.GetNewClosure())
  return $e
}
function Toggle-View([string]$key){ $e=$global:wins[$key]; if(-not $e){return}
  if($e.kind -eq 'control'){ $e.view= if($e.view -eq 'panel'){'mini'}else{'panel'} } else { $e.view= if($e.view -eq 'expanded'){'mini'}else{'expanded'} }
  Render-Win $key }
function Render-Win([string]$key){ $e=$global:wins[$key]; if(-not $e -or -not $e.model){return}
  $e.host.Children.Clear(); $m=$e.model
  $el= if($e.kind -eq 'control'){ if($e.view -eq 'mini'){ Build-ControlMini $m }else{ Build-ControlPanel $m } } else { if($e.view -eq 'mini'){ Build-DeployMini $m }else{ Build-DeployExpanded $m } }
  [void]$e.host.Children.Add($el); Position-Win $key }
# The shell carries a 26px transparent margin for its halo, so the VISIBLE card edge sits
# 26px inside the window box — every adjacency below is measured on the visible edges.
$script:ShellPad=26
$script:CardGap=14
function Position-Win([string]$key){ $e=$global:wins[$key]; if(-not $e -or $e.userMoved){return}
  $wa=[System.Windows.SystemParameters]::WorkArea; $w=$e.win.ActualWidth; $h=$e.win.ActualHeight; if($w -le 0){return}
  $p=$script:ShellPad; $gap=$script:CardGap
  if($e.kind -eq 'control'){ $e.win.Left=[Math]::Max($wa.Left,$wa.Right-$w+4); $e.win.Top=[Math]::Max($wa.Top,$wa.Bottom-$h+4)
    # deploy cards hang off the control plane's top corner, so re-anchor them whenever the
    # panel grows or shrinks (queue rows, RECENT expand, mini toggle) and its top edge moves.
    foreach($k in @($global:wins.Keys)){ if($k -ne $key){ Position-Win $k } } }
  else {
    # top edge flush with the control plane's top, card sitting just outside its side edge;
    # further slots stack away with the same gap.
    $c=$global:wins['control']
    $cl= if($c -and $c.win.ActualWidth -gt 0){ $c.win.Left } else { $wa.Right-468-2*$p+4 }
    $ct= if($c -and $c.win.ActualHeight -gt 0){ $c.win.Top } else { $wa.Bottom-$h+4 }
    $step=($w-2*$p)+$gap
    $left=$cl+2*$p-$gap-$w-($e.slot)*$step
    $e.win.Left=[Math]::Max($wa.Left,$left)
    $e.win.Top=[Math]::Max($wa.Top,[Math]::Min($ct,$wa.Bottom-$h+4)) } }

# ---- models ----
# Card title: ALWAYS the repo AND the job. Showing one without the other was the standing
# complaint — "sync-store-claims" alone does not say whose, and "<repo> · CI" does not say which
# job. Both halves, every row.
#
# An unresolved repo prints "repo?" rather than being silently dropped. The old title fell back to
# the bare stage name, which is indistinguishable from a job that legitimately has no repo — so a
# resolution failure looked like normal output and went unnoticed for days. Make it ask a question.
#
# The workflow moves OFF the title. The expanded card already prints it on its own name line
# (repo bold + workflow), and most repos here run exactly one workflow, so the job name identifies
# far more per character — which matters because RECENT trims on width.
function DeployTitle($d){
  $repo=$(if($d.repo){[string]$d.repo}else{'repo?'})
  $st=@($d.stages | Where-Object { $_ -and $_.name })
  if($st.Count -eq 0){ return $(if($d.label -and -not $d.repo){"$repo · $($d.label)"}else{$repo}) }
  # The job that matters: what failed, else what is running, else the last to have run. On a
  # multi-job deploy that is the one the operator is actually looking for; the card lists the rest.
  $pick=@($st | Where-Object { $_.status -eq 'failed' })[0]
  if(-not $pick){ $pick=@($st | Where-Object { $_.status -eq 'active' })[0] }
  if(-not $pick){ $pick=$st[$st.Count-1] }
  $more=$st.Count-1
  "$repo · $($pick.name)" + $(if($more -gt 0){" +$more"}else{''})
}

function Build-DeployModelJ($d,[string]$key){
  $st=$d.stages
  $busy=[bool]$d.running; $failed=($d.conclusion -eq 'failure'); $done=($d.conclusion -eq 'success')
  if($done){ $dot=$Cgreen; $word='PASSED'; $pb='#1F3FB950'; $pd='#4D3FB950' } elseif($failed){ $dot=$Cred; $word='FAILED'; $pb='#1FF85149'; $pd='#4DF85149' } else { $dot=$Corange; $word='RUNNING'; $pb='#1FE3A008'; $pd='#4DE3A008' }
  $sc=@($st).Count
  $aidx=-1; for($i=0;$i -lt $sc;$i++){ if($st[$i].status -eq 'active'){ $aidx=$i; break } }
  if($aidx -lt 0){ for($i=0;$i -lt $sc;$i++){ if($st[$i].status -eq 'failed'){ $aidx=$i } } }
  if($aidx -lt 0){ $aidx=$(if($done -and $sc -gt 0){$sc-1}else{0}) }
  $curName=$(if($sc -gt 0 -and $aidx -lt $sc){$st[$aidx].name}else{'—'})
  if($done){ $al='✓  All stages passed'; $ac=$Cgreen } elseif($failed){ $al="✕  Failed at $curName"; $ac=$Cred } else { $al="›  $curName"; $ac=$Ctext }
  $elapsed='—'; try { if($busy){ $sp=[DateTime]::UtcNow-$d.start; $elapsed=('{0:00}:{1:00}' -f [int]$sp.TotalMinutes,$sp.Seconds) } elseif($d.end){ $elapsed=(Dur ($d.start.ToString('o')) ($d.end.ToString('o'))) } } catch {}
  # Read the LAST GATHERED line rather than calling Get-RunnerLine here. This runs on the UI
  # thread, once per running deploy, every tick — so an inline wsl.exe made the deploy cards a
  # second way to freeze the app even after the main poll moved off-thread. The gather fills
  # $script:runnerLine; before the first one completes it is empty, which reads as idle.
  $rl=$script:runnerLine; if(-not $rl){ $rl='(runner idle)' }
  # WHICH SLOT. Read from the running stages while the deploy is live, because that is the
  # question being asked -- "what is slot 2 doing" -- and from every stage once it is not, so a
  # finished card still says where it ran. A deploy CAN span both slots: two jobs of one
  # workflow run can be dispatched separately, hence a set rather than a number.
  $slotSrc=@($d.stages | Where-Object { $_.status -eq 'active' -and $null -ne $_.slotN })
  if($slotSrc.Count -eq 0){ $slotSrc=@($d.stages | Where-Object { $null -ne $_.slotN }) }
  $slotNs=@($slotSrc | ForEach-Object { [int]$_.slotN } | Sort-Object -Unique)
  # $null, not 'slot ?', when no Worker log was matched: a card that names no slot is read as
  # "unknown", whereas a question mark in the badge position reads as a slot that went wrong.
  $slotLab=$(if($slotNs.Count -eq 1){ "slot $($slotNs[0])" } elseif($slotNs.Count -gt 1){ "slots $($slotNs -join '·')" } else { $null })
  # The control plane's hue for that slot, so the chip and the pill match by eye. A deploy
  # spanning two slots gets the neutral: no single hue would be true.
  $slotHex=$(if($slotNs.Count -eq 1){ SlotHue $slotNs[0] } else { '#94A3B8' })
  $repo=$d.repo                                          # may be $null — see DeployTitle
  $wfLabel=$d.workflow                                   # may be $null; NOT defaulted to 'main',
                                                         # which read like a fact but was a guess
  # info line = the deploy's HEAD commit subject; fall back to the runner line if unknown.
  # $repo may legitimately be $null now, and Hashtable.ContainsKey($null) THROWS — guard it.
  $subj=$null; if($repo -and $script:commitMap -and $script:commitMap.ContainsKey($repo)){ $subj=$script:commitMap[$repo] }
  $infoLine=$(if($subj){$subj}else{$rl})
  return @{ key=$key; stages=$st; busy=$busy; dotColor=$dot; statusWord=$word; pillBg=$pb; pillBd=$pd
    runTitle=(DeployTitle $d); workflowName=$(if($wfLabel){$wfLabel}else{$curName}); activeLine=$al; activeColor=$ac; elapsed=$elapsed; runnerLine=$infoLine
    hasError=$failed; errorLine=$rl; footerStamp=("updated {0} · runner journal" -f $script:now)
    slotLabel=$slotLab; slotColor=$slotHex; sha=$(if($d.sha){([string]$d.sha).Substring(0,6)}else{''})
    miniMeta=$(if($done){"$sc/$sc ✓"}elseif($failed){"$($aidx+1)/$sc ✕"}else{"$($aidx+1)/$sc · $elapsed"}); activeName=$(if($done){'All stages passed'}else{$curName}); repoName=$(if($repo){$repo}else{'repo?'}) }
}

# Why the journal poll came back empty. The old message blamed WSL/the service unconditionally,
# which cried wolf on what is almost always transient contention. One cheap probe tells them apart
# so the operator is pointed at the real thing (or told to just wait).
function Get-JournalFailReason {
  $probe=$null
  # Also probe /mnt/c. WSL2's drvfs/9p transport can die while the distro stays perfectly up:
  # the mount entry survives but every access returns EIO, so any wsl.exe call made from a
  # WINDOWS working directory fails its chdir. Measured 2026-09-17 -- the box had 2d9h uptime,
  # no OOM, and jobs were still building happily on ext4 inside the VM, but the card read
  # "isn't responding to commands. Is the distro up?", which sent the operator hunting a crash
  # that had not happened. The distro being up and /mnt/c being usable are separate facts, and
  # the card has to say which one broke.
  try { $probe=& wsl.exe -d $WslDistro -u root bash -c "systemctl is-active '$SlotService' 2>/dev/null; systemctl is-active $RunnerService 2>/dev/null; ls /mnt/c >/dev/null 2>&1 && echo __MNTOK__ || echo __MNTBAD__; journalctl -u '$SlotService' --no-pager --since '-15 min' 2>/dev/null | grep -a -m1 'off NTP' && echo __CLOCKBAD__; echo __POK__" 2>$null } catch {}
  $j=($probe -join "`n")
  if(-not ($j -match '__POK__')){ return "WSL '$WslDistro' isn't responding to commands. Is the distro up? (wsl -l -v)" }
  if($j -match '__MNTBAD__'){ return "WSL is UP but /mnt/c is dead (drvfs 9p transport lost) - jobs on ext4 still run, but interop and every wsl call from a Windows cwd fail. Fix without restarting: umount -l /mnt/c then mount -t drvfs C: /mnt/c -o metadata,uid=1000,gid=1000" }
  # THE SLOT REFUSING TO START IS NOT THE SAME AS THE BOX BEING DOWN.
  #
  # run-containerized-slot.sh has a preflight guard that dies when the clock is more than 5s off
  # NTP, because a skewed clock breaks the runner's OAuth. It dies BEFORE creating containers, so
  # from out here the box looks idle: units cycling, no containers, jobs queueing, and nothing
  # saying why. Measured 2026-09-19 after a hard reset -- the operator watched six jobs queue for
  # 80 minutes reading it as a hung job. On WSL2 the cause is nearly always the WINDOWS clock,
  # which chrony cannot fix, so the card names the host and the command.
  if($j -match '__CLOCKBAD__'){
    $off=''
    if($j -match 'clock is ([0-9.]+)s off NTP'){ $off=" by $($matches[1])s" }
    return "Runner is REFUSING to start: its clock guard says the clock is off NTP$off. On WSL2 the guest follows the WINDOWS clock - check 'w32tm /query /status' (Source: Local CMOS Clock, or 'not synchronized', is the fault) and fix it in an ELEVATED PowerShell: w32tm /config /update; Restart-Service W32Time; w32tm /resync /force. The slot starts itself on the next restart."
  }
  # BOTH units are probed and the verdict is OR, because since the 2026-09-05 cutover jobs run
  # on $SlotService and $RunnerService is disabled BY DESIGN -- finding that one inactive is
  # not a fault. Asking only about it meant a starved poll reported 'the service is not running'
  # for a box that was running jobs perfectly well.
  # Anchored per line: 'inactive' CONTAINS 'active', so an unanchored match can never fire.
  if($j -notmatch '(?m)^active?$'){ return "WSL is up, but neither '$SlotService' nor '$RunnerService' is running on it." }
  # Distro answers and the service is active: the journal read itself is being starved.
  return "Runner is UP (service active) — the journal poll keeps timing out, usually a busy WSL distro. Showing the last known state."
}

# ---- I/O worker -------------------------------------------------------------------------
# WHY THIS EXISTS. Every poll used to run wsl.exe and gh synchronously on the WPF UI thread:
# Get-PauseState, Get-JournalDeploys, Get-RepoCommits (one call PER REPO), two gh calls per
# repo, and Get-RunnerLine per running deploy. On an idle box that is a few hundred ms and
# nobody notices. On a loaded one it is fatal — 2026-09-07, during appone's build, the box
# ran out of memory, WSL stopped servicing new interop sessions, and those calls stopped
# returning. Twelve wsl.exe launchers piled up, the card froze with a busy cursor, and no job
# card would open. Windows still reported Responding=True, because the message pump was alive
# and the thread was simply never given back.
#
# THE FIX IS NOT A TIMEOUT. A hung wsl.exe cannot be reliably killed, so the guarantee here is
# different and weaker on purpose: the UI thread NEVER makes a blocking call, and at most ONE
# gather is ever in flight. A busy box therefore produces a STALE card that still drags,
# clicks, filters and animates — not a frozen one. Staleness is shown, not hidden.
#
# The worker runspace is PERSISTENT, which also fixes something the old design got for free
# and a naive port would have lost: Get-WorkerMeta's $script:wmCache/$script:wmRetry live in
# it, so the per-log parse cache survives across ticks instead of being rebuilt every 15s.
$script:runnerLine=''
# Where ci-slots-status.sh lives, as WSL sees it. Resolved once, because it is fixed for the
# life of the process and the worker runspace needs it handed across as a plain string.
#
# Same fallback chain as Get-QueueRepos, for the same reason: $PSScriptRoot is empty under
# -Command and when dot-sourced. Failing soft here is worse than failing loudly -- it costs
# the slots strip and says nothing, leaving a card that looks exactly like the old one.
$script:SlotScriptWsl = $null
try {
  $root=$PSScriptRoot
  if(-not $root -and $PSCommandPath){ $root=Split-Path -Parent $PSCommandPath }
  if(-not $root -and $MyInvocation.MyCommand.Path){ $root=Split-Path -Parent $MyInvocation.MyCommand.Path }
  if($root){
    $sp = Join-Path $root 'ci-slots-status.sh'
    # A drive letter, not a UNC path: /mnt/<letter> has no meaning for \\server\share, and a
    # checkout there would need a mount this box does not have. Leave it $null and skip the strip.
    if((Test-Path $sp) -and $sp -match '^[A-Za-z]:'){
      $script:SlotScriptWsl = '/mnt/' + $sp.Substring(0,1).ToLower() + ($sp.Substring(2) -replace '\\','/')
    }
  }
} catch {}
$script:slotStates=@()
$script:gatherOp=$null
$script:lastGoodStamp=''

# The worker needs the I/O functions. Rather than keep a second copy in a here-string — which
# would drift from the originals the first time one is edited — pull their definitions out of
# THIS file by AST. Same trick the render tests use, and it means there is exactly one source.
# $SrcPath is a parameter only so the test harness can point this at the script it is checking;
# in the app it always resolves to this file.
function New-IoRunspace([string]$SrcPath){
  $ioNames=@('Get-RunnerLine','Get-PauseState','Get-SlotStates','Get-WorkerMeta','CleanStage','Get-RepoCommits','Get-JournalDeploys','Get-JournalFailReason')
  $src=$SrcPath; if(-not $src){ $src=$PSCommandPath }; if(-not $src){ $src=$MyInvocation.MyCommand.Path }
  $ast=[System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$null,[ref]$null)
  $defs=($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ioNames -contains $n.Name},$true) |
          ForEach-Object { $_.Extent.Text }) -join "`n"
  $rs=[runspacefactory]::CreateRunspace(); $rs.Open()
  $init=[powershell]::Create(); $init.Runspace=$rs
  [void]$init.AddScript(@'
param($defs,$distro,$runnerSvc,$slotSvc,$pauseFlag,$journalWindow,$slotScript)
$WslDistro=$distro; $RunnerService=$runnerSvc; $SlotService=$slotSvc; $PauseFlag=$pauseFlag
$SlotScriptWsl=$slotScript
# EVERY parameter Get-JournalDeploys reads has to be handed across explicitly -- the runspace
# shares no scope with the script. $JournalWindow was added on 2026-09-14 and NOT added here,
# so inside the worker it was $null: the poll ran `journalctl --since ''`, which errors to a
# stderr that is already discarded, prints zero lines, and still echoes __JOK__. The gather
# therefore looked SUCCESSFUL and returned an empty deploy list -- no red banner, no retry
# counter, just a control plane with no history at all. Measured 2026-09-15.
$JournalWindow=$journalWindow
$script:wmCache=@{}; $script:wmRetry=@{}
Invoke-Expression $defs
'@).AddArgument($defs).AddArgument($WslDistro).AddArgument($RunnerService).AddArgument($SlotService).AddArgument($PauseFlag).AddArgument($JournalWindow).AddArgument($script:SlotScriptWsl)
  [void]$init.Invoke(); $init.Dispose()
  return $rs
}
$script:ioRs=$null
try { $script:ioRs=New-IoRunspace } catch { if($env:DM_DEBUG){ try { "IO RUNSPACE INIT FAILED: $($_.Exception.Message)" | Out-File -Append -FilePath $env:DM_DEBUG } catch {} } }

# Everything that blocks, in one round trip. Returns a plain payload; builds no UI and touches
# no $global:wins — the whole point is that this half can be slow without consequence.
$gather = {
  param($org,$repoShort,$watchRepos)
  $out=@{ pause=$null; deploys=$null; commitMap=@{}; queued=@(); cancelled=@(); ghOk=$false; liveRunIds=@{}; runnerLine=''; failReason=''; slots=$null }
  try { $out.pause=Get-PauseState } catch {}
  try { $out.deploys=Get-JournalDeploys } catch { $out.deploys=$null }
  if($null -eq $out.deploys){
    try { $out.failReason=Get-JournalFailReason } catch {}
    return $out
  }
  try { $out.runnerLine=Get-RunnerLine } catch {}
  # One extra wsl.exe per tick. They SERIALIZE (see the two-instances note above), so
  # this is deliberately a single call returning every slot rather than one per slot.
  try { $out.slots=Get-SlotStates } catch {}
  $repos=@($out.deploys | ForEach-Object { $_.repo } | Where-Object { $_ -and $_ -ne '…' } | Select-Object -Unique)
  try { $out.commitMap=Get-RepoCommits $repos } catch {}
  # Journal repos ∪ this repo ∪ the watch list. The union matters: the journal still contributes
  # anything running right now that the watch file has not been told about yet.
  $qrepos=@(@($repos) + $repoShort + @($watchRepos) | Where-Object { $_ -and $_ -ne '…' } | Select-Object -Unique)
  foreach($qr in $qrepos){
    try { $qj=& gh run list --repo "$org/$qr" --status queued --limit 5 --json databaseId,workflowName,headBranch,headSha,displayTitle 2>$null
      # NOTE: PS 5.1 emits '[]' as a single empty object; filter to real runs (must have databaseId).
      if($LASTEXITCODE -eq 0){ $out.ghOk=$true; if($qj){ foreach($it in @(($qj | ConvertFrom-Json) | Where-Object { $_ -and $_.databaseId })){ $it | Add-Member -NotePropertyName _repo -NotePropertyValue $qr -Force; $out.queued+=$it; $out.liveRunIds["$($it.databaseId)"]=$true } } } } catch {}
    # Cancelled runs come from gh, NOT the journal, and that is the whole point. A run cancelled
    # while QUEUED never reached this box — there is no "completed with result: Canceled" line to
    # find, because no job ever started. The journal path added alongside this only catches a
    # cancel that lands mid-flight. Without this query the common case (cancel from the queue,
    # including from this window's own cancel control) leaves no trace in the history at all.
    try { $cj=& gh run list --repo "$org/$qr" --status cancelled --limit 8 --json databaseId,workflowName,headSha,displayTitle,createdAt,updatedAt 2>$null
      if($LASTEXITCODE -eq 0){ $out.ghOk=$true; if($cj){ foreach($it in @(($cj | ConvertFrom-Json) | Where-Object { $_ -and $_.databaseId })){ $it | Add-Member -NotePropertyName _repo -NotePropertyValue $qr -Force; $out.cancelled+=$it } } } } catch {}
    try { $pj=& gh run list --repo "$org/$qr" --status in_progress --limit 15 --json databaseId 2>$null
      if($LASTEXITCODE -eq 0){ $out.ghOk=$true; if($pj){ foreach($it in @(($pj | ConvertFrom-Json) | Where-Object { $_ -and $_.databaseId })){ $out.liveRunIds["$($it.databaseId)"]=$true } } } } catch {}
  }
  return $out
}

# ---- refresh ----
# Two halves now. $refresh only STARTS a gather (and repaints staleness); $applyPayload does the
# model building and rendering when one comes back. Nothing between them blocks.
$refresh = {
  # One at a time. This is the actual fix for the pile-up: a tick that arrives while the box is
  # still answering the previous one is dropped, not queued behind it. Twelve stacked calls is
  # what turned a slow poll into a dead window.
  if($script:gatherOp){
    $age=[int]((Get-Date)-$script:gatherOp.started).TotalSeconds
    # Only say so once it is genuinely late; below that it is just a poll in flight and
    # announcing it would make a healthy box look sick.
    if($age -gt [Math]::Max(20,$IntervalSec+5)){
      $m=$global:wins['control'].model
      if($m){ $m.footerStamp=("stale {0}s · box busy, still polling{1}" -f $age,$(if($script:lastGoodStamp){" · last good $($script:lastGoodStamp)"}else{''})); Render-Win 'control' }
    }
    return
  }
  if(-not $script:ioRs){ return }
  $script:now=(Get-Date).ToUniversalTime().ToString('HH:mmZ')
  $ps=[powershell]::Create(); $ps.Runspace=$script:ioRs
  [void]$ps.AddScript($gather).AddArgument((($Repo -split '/')[0])).AddArgument($script:repoShort).AddArgument((Get-QueueRepos))
  $script:gatherOp=@{ ps=$ps; handle=$ps.BeginInvoke(); started=(Get-Date) }
}

# Polls the in-flight gather at 200ms — the same shape Start-RunnerPause uses — so completion is
# picked up promptly without the UI thread ever waiting on it.
$gatherPoll=New-Object System.Windows.Threading.DispatcherTimer
$gatherPoll.Interval=[TimeSpan]::FromMilliseconds(200)
$gatherPoll.Add_Tick({
  $op=$script:gatherOp; if(-not $op){ return }
  if(-not $op.handle.IsCompleted){ return }
  $payload=$null
  try { $payload=@($op.ps.EndInvoke($op.handle))[0] } catch { if($env:DM_DEBUG){ try { "$(Get-Date -f HH:mm:ss) GATHER ERR: $($_.Exception.Message)" | Out-File -Append -FilePath $env:DM_DEBUG } catch {} } }
  try { $op.ps.Dispose() } catch {}
  $script:gatherOp=$null
  if($payload){ & $applyPayload $payload }
})

$applyPayload = {
  param($p)
  try {
    # Timestamp the ARRIVAL, not the request. $script:now is what the footer shows, and stamping
    # it when the gather was started would date the card by however long the box took to answer.
    $script:now=(Get-Date).ToUniversalTime().ToString('HH:mmZ')
    # Keep the last known hold when WSL didn't reply. This has to survive the journal poll
    # failing below: a paused runner produces no journal activity at all, so the two must not be
    # coupled or the badge would go unreachable-red on every hold.
    if($p.pause){ $global:pauseState=$p.pause }
    # The in-flight target, or $null. Read from the op rather than from a model field so a
    # transition survives a re-render triggered from anywhere, including its own completion.
    $pendingNow=$(if($global:pauseOp){ $global:pauseOp.target }else{ $null })
    $pausedNow=[bool]($global:pauseState -and $global:pauseState.paused)
    $deploys=$p.deploys
    if($null -eq $deploys){
      $script:journalFails=[int]$script:journalFails+1
      $m=$global:wins['control'].model; if(-not $m){ $m=@{ runningCount='—'; queuedCount='—'; success24='—'; failed24='—'; queued=@(); recent=@(); busy=$false; paused=$pausedNow; pending=$pendingNow; changed=@{}; animBadge=$false; animChips=@{running=$false;queued=$false;failed=$false;success=$false} } }
      # Keep the hold visible even when the journal poll is degrading — a hold and an outage
      # must never look the same, and the hold is the one the operator caused.
      $m.paused=$pausedNow; $m.pending=$pendingNow
      # A single bad poll is contention, not an outage. Hold the last good view (no red banner)
      # and only escalate after 3 consecutive failures — ~45s at the default 15s interval.
      if($script:journalFails -lt 3){
        $m.footerStamp=("poll retrying {0}/3 · {1}" -f $script:journalFails,$script:now)
        $global:wins['control'].model=$m; Render-Win 'control'; return }
      # The reason was probed by the worker in the same round trip — asking for it here would
      # put a wsl.exe back on the UI thread at exactly the moment WSL is known to be unwell.
      $m.paused=$pausedNow; $m.pending=$pendingNow; $m.error=$p.failReason; $m.footerStamp="runner unreachable · $($script:now)"
      $global:wins['control'].model=$m; Render-Win 'control'; return }
    $script:journalFails=0
    $script:runnerLine=$p.runnerLine
    if($p.slots -ne $null){ $script:slotStates=@($p.slots) }
    $script:commitMap=$p.commitMap
    $queued=@($p.queued); $ghOk=[bool]$p.ghOk; $liveRunIds=$p.liveRunIds
    # gh-backed 'running' gate. A deploy shown 'running' only via the between-jobs grace window
    # (no stage currently active) whose GitHub run is NOT in-progress/queued has actually finished —
    # conclude it now instead of lingering up to 150s. Deploys with an active stage (a job really is
    # executing), or when gh is unavailable, keep the offline journal/time heuristic untouched.
    if($ghOk){
      foreach($d in $deploys){
        $hasActive=(@($d.stages | Where-Object { $_.status -eq 'active' }).Count -gt 0)
        if($d.running -and -not $hasActive -and $d.runId -and -not $liveRunIds.ContainsKey([string]$d.runId)){
          $d.running=$false
          $d.conclusion=$(if(@($d.stages | Where-Object { $_.status -eq 'failed' }).Count -gt 0){'failure'}else{'success'})
        }
      }
    }
    if($env:DM_DEBUG){ try { "$(Get-Date -f HH:mm:ss) QUEUE ghOk=$ghOk qn=$($queued.Count) live=$($liveRunIds.Count)" | Out-File -Append -FilePath $env:DM_DEBUG } catch {} }
    $running=@($deploys | Where-Object { $_.running })
    $completed=@($deploys | Where-Object { -not $_.running })
    # The model carries a POOL, not the visible list. RECENT shows 3 collapsed / 10 expanded,
    # but the FILTER runs over this pool — so capping it at 10 here would make "failed" mean
    # "failures among the last 10 runs" rather than "the last 10 failures", and on a good day
    # the filter would read as "no failures" while the box had plenty. 60 is far more than the
    # view can ever show and costs nothing: these are small hashtables built from data already
    # in memory.
    $recentD=@($completed | Select-Object -First 60)
    $cut=[DateTime]::UtcNow.AddHours(-24)
    $failed24n=@($completed | Where-Object { $_.conclusion -eq 'failure' -and $_.start -gt $cut }).Count
    $success24n=@($completed | Where-Object { $_.conclusion -eq 'success' -and $_.start -gt $cut }).Count
    # detect changes since last refresh (drives attention animations)
    $curMap=@{}; foreach($d in $deploys){ $curMap[[string]$d.id]=$(if($d.running){'running'}else{"done/$($d.conclusion)"}) }
    foreach($q in $queued){ $curMap["q$($q.databaseId)"]='queued' }
    $changed=@{}; $completedNow=$false; $newQueued=$false
    if($global:seenRuns){ foreach($id in $curMap.Keys){ if(-not $global:seenRuns.ContainsKey($id) -or $global:seenRuns[$id] -ne $curMap[$id]){ $changed[$id]=$true; if($curMap[$id] -like 'done/*'){ $completedNow=$true }; if($curMap[$id] -eq 'queued'){ $newQueued=$true } } } }
    $busyNow=($running.Count -gt 0)
    # "running" means JOBS EXECUTING ON THIS BOX, which stopped being the same as the number of
    # running DEPLOYS the day a second slot arrived: a matrix run holding both slots is one
    # deploy and two jobs, and the chip read "1 running" with two workers going. Counting active
    # stages fixes that and sums across slots for free, since the journal now reads both units.
    #
    # Floored at the busy-slot count, which comes from live Worker-log freshness rather than from
    # pairing journal lines. The two disagree in opposite directions and neither is reliable
    # alone: a job whose Worker log is not written yet is busy in the journal and idle in the
    # strip, and a job whose completion line was missed is the reverse. The floor is the cheap
    # half of that -- it never reports fewer jobs than are demonstrably executing.
    $activeJobs=@($running | ForEach-Object { $_.stages } | Where-Object { $_ -and $_.status -eq 'active' }).Count
    $busySlots=@($script:slotStates | Where-Object { $_ -and $_.state -eq 'busy' }).Count
    $runningN=[Math]::Max($activeJobs,$busySlots)
    $animBadge=([bool]$global:seenRuns -and $global:prevBusy -ne $busyNow)
    $animChips=@{ running=([bool]$global:seenRuns -and $global:prevRunning -ne $runningN); queued=([bool]$global:seenRuns -and $global:prevQueued -ne $queued.Count); failed=([bool]$global:seenRuns -and $global:prevFailed -ne $failed24n); success=([bool]$global:seenRuns -and $global:prevSuccess -ne $success24n) }
    $global:seenRuns=$curMap; $global:prevBusy=$busyNow; $global:prevRunning=$runningN; $global:prevQueued=$queued.Count; $global:prevFailed=$failed24n; $global:prevSuccess=$success24n
    # control model
    $qm=@(); $i=0
    # queue is FIFO, so #1 must be the NEXT run to be picked up. gh returns newest-first, and run
    # ids are globally monotonic with creation, so sort oldest-first by databaseId to number them.
    foreach($q in @($queued | Sort-Object { [long]$_.databaseId })){ $i++
      $br= if($q.headBranch){$q.headBranch}else{'main'}
      $sha= if($q.headSha){ $q.headSha.Substring(0,[Math]::Min(6,$q.headSha.Length)) }else{''}
      # commit subject (truncated) shown inline — displayTitle is the head commit's message for
      # a push; fall back to the workflow name when gh has no title.
      $msg= if($q.displayTitle){[string]$q.displayTitle}elseif($q.workflowName){[string]$q.workflowName}else{''}
      if($msg.Length -gt 38){ $msg=$msg.Substring(0,37)+'…' }
      $wfq= if($q.workflowName){[string]$q.workflowName}else{'main'}
      $qm+=@{ id="q$($q.databaseId)"; rid=[string]$q.databaseId; pos=$i; repo=$(if($q._repo){$q._repo}else{'…'}); wf=$wfq; branch=$br; sha=$sha; msg=$msg } }
    $rm=@(); foreach($d in $recentD){ $ok=($d.conclusion -eq 'success'); $endIso=$(if($d.end){$d.end.ToString('o')}else{$d.last.ToString('o')})
      # same rule as the deploy card: real repo, else the stage-derived label, never '…'
      # `repo` is carried separately from `label` because the repo filter has to match on the
      # bare repo name. label is "<repo> · <workflow>", and a job whose repo never resolved
      # falls back to a stage-derived label — which must NOT become a filter chip.
      # Three outcomes now, so `ok` alone no longer describes a row. `state` carries which one, and
      # the glyph/colour/pill are derived from it — cancelled gets a blue ⊘ and a "canceled" pill so
      # it is legible at a glance as "somebody stopped this", not "this broke".
      $state=$(if($d.conclusion -eq 'cancelled'){'cancelled'}elseif($ok){'success'}else{'failure'})
      $rm+=@{ id=[string]$d.id; ok=$ok; state=$state; start=$d.start; rid=$(if($d.runId){[string]$d.runId}else{''}); repo=$(if($d.repo){[string]$d.repo}else{''}); label=(DeployTitle $d); sha=$(if($d.sha){([string]$d.sha).Substring(0,6)}else{''}); ago=(Ago ($d.start.ToString('o'))); dur=(Dur ($d.start.ToString('o')) $endIso); stages=$d.stages; glyph=$(switch($state){ 'success'{'✓'} 'cancelled'{'⊘'} default{'✕'} }); glyphColor=$(switch($state){ 'success'{$Cgreen} 'cancelled'{$Ccancel} default{$Cred} }) } }
    # Fold in runs cancelled on GitHub's side. These have no journal entry — see the gh query —
    # so they are synthesised here rather than derived from stages, and carry no mini-bars because
    # no stage ever ran. Deduped on run id: a cancel that landed MID-flight is already in $rm from
    # the journal, with real stages, and that row is the better one.
    $haveRun=@{}; foreach($d in $recentD){ if($d.runId){ $haveRun["$($d.runId)"]=$true } }
    $cut24=[DateTime]::UtcNow.AddHours(-24)
    foreach($c in @($p.cancelled)){
      if(-not $c.databaseId -or $haveRun.ContainsKey("$($c.databaseId)")){ continue }
      $st=$null; $en=$null
      try { $st=[DateTime]::Parse($c.createdAt).ToUniversalTime() } catch { continue }
      if($st -lt $cut24){ continue }
      try { $en=[DateTime]::Parse($c.updatedAt).ToUniversalTime() } catch { $en=$st }
      $cwf=$(if($c.workflowName){[string]$c.workflowName}else{'?'})
      $crepo=$(if($c._repo){[string]$c._repo}else{'repo?'})
      $rm+=@{ id="c$($c.databaseId)"; ok=$false; state='cancelled'; repo=$crepo
              sha=$(if($c.headSha){ ([string]$c.headSha).Substring(0,6) }else{''})
              label="$crepo · $cwf"; ago=(Ago ($st.ToString('o'))); dur=(Dur ($st.ToString('o')) ($en.ToString('o')))
              stages=@(@{ name='cancelled'; status='canceled' })   # one segment, so the row carries a single
              # blue bar exactly where a passing row carries green and a failing one red. MiniBars already
              # forces n=1 on an empty list, but the status has to exist or StageHex paints it dead grey.
              glyph='⊘'; glyphColor=$Ccancel; start=$st }
    }
    # One list, newest first, however each row got here.
    $rm=@($rm | Sort-Object { if($_.start){ $_.start } else { [DateTime]::MinValue } } -Descending)
    $srcTag=$(if($ghOk){'journal + gh'}else{'runner journal'})
    # Remember the last GOOD stamp so a later stale footer can say when the card was last true,
    # rather than just admitting it is out of date.
    $script:lastGoodStamp=$script:now
    $global:wins['control'].model=@{ busy=$busyNow; paused=$pausedNow; pending=$pendingNow; runningCount=$runningN; queuedCount=$queued.Count; success24=$success24n; failed24=$failed24n; queued=$qm; recent=$rm; footerStamp=("updated {0} · {1}" -f $script:now,$srcTag); changed=$changed; animBadge=$animBadge; animChips=$animChips; slots=$script:slotStates }
    Render-Win 'control'
    if($completedNow -or $newQueued){ Flash-Taskbar $global:wins['control'].win }
    # deploy windows: one per running deploy
    $activeKeys=@{}; $slot=0
    foreach($d in $running){ $key="deploy:$($d.id)"; $activeKeys[$key]=$true
      if(-not $global:wins.ContainsKey($key)){ $e=Make-Window $key 'deploy' $d.id $slot ("deploy · " + (DeployTitle $d)) 'expanded'; $e.model=(Build-DeployModelJ $d $key); Render-Win $key; $e.win.Show(); Position-Win $key }
      else { $global:wins[$key].slot=$slot; $global:wins[$key].model=(Build-DeployModelJ $d $key); Render-Win $key
        # The window/taskbar title is set once at creation, when the repo is often still unknown
        # (the Worker log has not written _work/<repo> yet). Refresh it every tick so it picks the
        # repo up as soon as it resolves, instead of showing the job name for the whole deploy.
        try { $t="deploy · " + (DeployTitle $d); if($global:wins[$key].win.Title -ne $t){ $global:wins[$key].win.Title=$t } } catch {} }
      $slot++
    }
    # close deploy windows whose deploy finished (show final state once, then close next cycle)
    foreach($k in @($global:wins.Keys | Where-Object { $_ -like 'deploy:*' })){
      if(-not $activeKeys.ContainsKey($k)){
        $e=$global:wins[$k]
        if($e.shownFinal){ $e.win.Close(); $global:wins.Remove($k) }
        else { $d=$deploys | Where-Object { "deploy:$($_.id)" -eq $k } | Select-Object -First 1
          if($d){ $e.model=(Build-DeployModelJ $d $k); Render-Win $k; $e.shownFinal=$true } else { $e.win.Close(); $global:wins.Remove($k) } }
      }
    }
  } catch { if($env:DM_DEBUG){ try { "$(Get-Date -f HH:mm:ss) ERR: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" | Out-File -Append -FilePath $env:DM_DEBUG } catch {} } }
}

# ---- app ----
function Stop-All { try { foreach($k in @($global:wins.Keys)){ $global:wins[$k].win.Close() } } catch {}; [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }

$ctl=Make-Window 'control' 'control' '' 0 'Deploy control plane' 'panel'
$timer=New-Object System.Windows.Threading.DispatcherTimer; $timer.Interval=[TimeSpan]::FromSeconds([Math]::Max(5,$IntervalSec)); $timer.Add_Tick($refresh)
# gatherPoll runs for the life of the app: $refresh only STARTS work, so something has to be
# watching for it to finish. Start it before the first $refresh so the very first gather is
# collected too.
$ctl.win.Add_ContentRendered({ $gatherPoll.Start(); & $refresh; Position-Win 'control'; $timer.Start() })
# A gather may still be running in the worker when the window closes. Don't block shutdown
# waiting for it — a wedged wsl.exe is exactly the case that would hang the exit. Dispose what
# we can, ignore what we can't, and let the process go.
$ctl.win.Add_Closed({ $timer.Stop(); $gatherPoll.Stop()
  try { if($script:gatherOp){ $script:gatherOp.ps.Dispose() } } catch {}
  try { if($script:ioRs){ $script:ioRs.Dispose() } } catch {}
  foreach($k in @($global:wins.Keys | Where-Object { $_ -ne 'control' })){ try{ $global:wins[$k].win.Close() }catch{} }; [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({ param($s,$e) if($env:DM_DEBUG){ try { "$(Get-Date -f HH:mm:ss) DISP ERR: $($e.Exception.Message)" | Out-File -Append -FilePath $env:DM_DEBUG } catch {} }; $e.Handled=$true })
$ctl.win.Show()
[System.Windows.Threading.Dispatcher]::Run()
