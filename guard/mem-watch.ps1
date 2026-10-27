# mem-watch.ps1 — catch the box degrading, with evidence, at the moment it happens.
#
# WHY THIS EXISTS
# The box runs fine for hours or days with two CI slots and two Claude sessions, then
# becomes slow and unresponsive while the RUNNER KEEPS WORKING. Post-mortems have not
# settled it because by the time anyone looks, the evidence is gone — a reboot resets
# everything, and process working sets are trimmed by Windows under exactly the pressure
# we are trying to observe.
#
# So: sample cheaply and often, keep a flat trail for trend, and dump a full forensic
# snapshot the moment things turn. Then a human (or Claude) reads the snapshot afterwards
# and sees the state AT the event rather than after it.
#
# TWO DESIGN DECISIONS THAT MATTER, both learned the hard way on this box:
#
# 1. THE FAST PATH NEVER CROSSES THE WSL BOUNDARY. wsl.exe calls on this machine can be
#    slow or hang outright under memory pressure — the marathon memory guard counts jobs
#    through `wsl.exe ... ps` with a 15s timeout and that call has timed out 7 times in
#    131 passes, always when the VM was loaded. A watcher that hangs during the event it
#    is meant to record is worse than no watcher. vmmem is read from the WINDOWS side via
#    Get-Process, which cannot hang. The snapshot path may touch WSL, but with a timeout
#    and tolerating failure.
#
# 2. IT RECORDS COMMIT (private bytes), NOT JUST WORKING SET. Windows trims working sets
#    when memory is tight, so "working set" FALLS during the squeeze and understates the
#    culprit. Private/commit does not get trimmed the same way, so a slow leak shows up
#    there first. Recording only working set is how a leak hides.
#
# OUTPUT
#   C:\ProgramData\marathon\mem-watch.csv            one line per sample, append-only
#   C:\ProgramData\marathon\snapshots\<stamp>.txt    full state, written only on a trip
#
# PARAMETERS are thresholds for "things turned". Defaults chosen from measured behaviour:
#   FreeTripMB 3500 — above the guard's 2500 warn line, so we capture the APPROACH to
#                     trouble, not the aftermath.
#   DropTripMB 1500 — a cliff between two samples, even if still above FreeTripMB.
#   CooldownMin 20  — do not write a snapshot more than once per this many minutes.

[CmdletBinding()]
param(
  [int]$FreeTripMB  = 3500,
  [int]$DropTripMB  = 1500,
  [int]$CooldownMin = 20,
  [switch]$SnapshotNow,
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$root     = 'C:\ProgramData\marathon'
$csv      = Join-Path $root 'mem-watch.csv'
$snapDir  = Join-Path $root 'snapshots'
$stateF   = Join-Path $root 'mem-watch.state'

if(-not (Test-Path $root)){    New-Item -ItemType Directory -Path $root    -Force | Out-Null }
if(-not (Test-Path $snapDir)){ New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }

# ---------- sample (cheap, Windows-side only, cannot hang) ----------

$os   = Get-CimInstance Win32_OperatingSystem
$free = [math]::Round($os.FreePhysicalMemory / 1KB)
$tot  = [math]::Round($os.TotalVisibleMemorySize / 1KB)

# Commit charge: the number that does NOT get trimmed under pressure.
$commit = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1KB)

$procs = Get-Process -ErrorAction SilentlyContinue

function SumMB($list, $prop){
  if($null -eq $list -or @($list).Count -eq 0){ return 0 }
  return [math]::Round((($list | Measure-Object $prop -Sum).Sum) / 1MB)
}
function GroupMB($pattern){
  $g = $procs | Where-Object { $_.ProcessName -match $pattern }
  $ws = SumMB $g 'WorkingSet64'
  $pb = SumMB $g 'PrivateMemorySize64'
  $n  = 0
  if($null -ne $g){ $n = @($g).Count }
  return [pscustomobject]@{ N = $n; WS = $ws; PB = $pb }
}

$vm      = GroupMB '^vmmem'
$claude  = GroupMB '^claude$'
$dropbox = GroupMB '^Dropbox'
$svc     = GroupMB '^svchost$'
$node    = GroupMB '^node$'
$edge    = GroupMB 'msedge'
$memcomp = GroupMB 'Memory Compression'

# WindowsTerminal is tracked because it LEAKED and the trail could not see it.
# Measured 2026-10-18/20 across 22 snapshot points: commit rose monotonically from
# ~350MB to 1100MB over 44h — a steady ~25-30MB/hour, continuing through idle and
# loaded periods alike and unaffected by any of the five guard cache drops. It
# accounted for a 971MB commit drift that every other tracked group failed to
# explain, and it was only found because a snapshot happened to be taken. The five
# original groups were chosen from a single post-boot reading of the top consumers,
# which is exactly the wrong basis: the biggest process at t=0 is not the one that
# grows. If another untracked process starts drifting, the fix is the same — add it
# here rather than relying on a lucky snapshot.
$wterm   = GroupMB 'WindowsTerminal'
# chrome added 2026-10-21: it was absent from every top-20 for 44h, then started and
# held 3144MB WS, crashing host free to 1114MB and driving the guard into a WSL restart
# that could not possibly help (vmmem was 941MB, its idle floor). The trail could not
# see the cause because edgeWS tracks msedge, not chrome. Same lesson as the comment above.
$chrome  = GroupMB 'chrome'

# Handles and threads: a leak often shows here BEFORE it shows in megabytes.
$handles = 0
$threads = 0
foreach($p in $procs){
  $handles += $p.HandleCount
  if($null -ne $p.Threads){ $threads += $p.Threads.Count }
}

$pf     = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
$pfUsed = 0
if($null -ne $pf){ $pfUsed = ($pf | Measure-Object CurrentUsage -Sum).Sum }

$now = Get-Date

# ---------- trend: compare against the previous sample ----------

$prevFree = $free
if(Test-Path $stateF){
  try {
    $st = Get-Content $stateF -Raw | ConvertFrom-Json
    if($null -ne $st.free){ $prevFree = [int]$st.free }
  } catch { }
}
$delta = $prevFree - $free

# ---------- append the trail ----------

# SCHEMA SEAM, deliberate and documented. Two fields were appended after this file
# first shipped: wtermPB (2026-10-20, field 22) and chromePB (2026-10-21, field 23).
# The header is written ONLY when the csv is created, so the live mem-watch.csv still
# carries its original 21-column header while rows carry 22 or 23 depending on when
# they were written. Appending at the END means every existing positional index is
# unchanged, so prior readers keep working. Anything parsing by header name must treat
# the trailing columns as optional, and a reader wanting chromePB must tolerate rows
# that predate it. Do not insert new fields in the middle.
if(-not (Test-Path $csv)){
  'ts,freeMB,totalMB,commitMB,pagefileMB,vmmemMB,claudeN,claudeWS,claudePB,dropboxWS,dropboxPB,svchostN,svchostWS,nodeN,nodeWS,edgeWS,memcompWS,procCount,handles,threads,deltaMB,wtermPB,chromePB' |
    Out-File -FilePath $csv -Encoding utf8
}
$line = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15},{16},{17},{18},{19},{20},{21},{22}' -f `
  $now.ToString('yyyy-MM-ddTHH:mm:sszzz'), $free, $tot, $commit, $pfUsed, $vm.WS,
  $claude.N, $claude.WS, $claude.PB, $dropbox.WS, $dropbox.PB,
  $svc.N, $svc.WS, $node.N, $node.WS, $edge.WS, $memcomp.WS,
  @($procs).Count, $handles, $threads, $delta, $wterm.PB, $chrome.PB
Add-Content -Path $csv -Value $line

# ---------- decide whether this is a trip ----------

$tripReason = ''
if($SnapshotNow){ $tripReason = 'manual' }
elseif($free -lt $FreeTripMB){ $tripReason = ('free {0}MB below {1}MB' -f $free, $FreeTripMB) }
elseif($delta -ge $DropTripMB){ $tripReason = ('free dropped {0}MB since last sample' -f $delta) }

$lastSnap = [datetime]'1990-01-01'
if(Test-Path $stateF){
  try {
    $st = Get-Content $stateF -Raw | ConvertFrom-Json
    if($null -ne $st.lastSnap){ $lastSnap = [datetime]$st.lastSnap }
  } catch { }
}
$cooled = (($now - $lastSnap).TotalMinutes -ge $CooldownMin)

$wrote = ''
if($tripReason -ne '' -and ($cooled -or $SnapshotNow)){

  $stamp = $now.ToString('yyyyMMdd-HHmmss')
  $snap  = Join-Path $snapDir ("$stamp.txt")
  $out   = New-Object System.Collections.Generic.List[string]

  $out.Add('================ mem-watch snapshot ================')
  $out.Add(('when        : {0}' -f $now.ToString('yyyy-MM-dd HH:mm:sszzz')))
  $out.Add(('trip reason : {0}' -f $tripReason))
  $out.Add(('free        : {0} MB of {1} MB   (delta since last sample: {2} MB)' -f $free,$tot,$delta))
  $out.Add(('commit      : {0} MB   pagefile in use: {1} MB' -f $commit,$pfUsed))
  $out.Add(('vmmem       : {0} MB' -f $vm.WS))
  $out.Add(('processes   : {0}   handles: {1}   threads: {2}' -f @($procs).Count,$handles,$threads))
  $out.Add(('uptime      : {0:N1} h' -f ((Get-Date) - $os.LastBootUpTime).TotalHours))
  $out.Add('')

  $out.Add('---- consumers by COMMIT (private bytes: not trimmed under pressure) ----')
  $procs | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{
      Name = $_.Name
      N    = $_.Count
      PB   = [math]::Round((($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum)/1MB)
      WS   = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum)/1MB)
    }
  } | Sort-Object PB -Descending | Select-Object -First 20 | ForEach-Object {
    $out.Add(('  {0,-26} {1,3}p  commit {2,6} MB   ws {3,6} MB' -f $_.Name,$_.N,$_.PB,$_.WS))
  }
  $out.Add('')

  $out.Add('---- individual processes over 150 MB commit ----')
  $procs | Where-Object { $_.PrivateMemorySize64 -gt 150MB } |
    Sort-Object -Property PrivateMemorySize64 -Descending | ForEach-Object {
      $st2 = '?'
      try { $st2 = $_.StartTime.ToString('MM-dd HH:mm') } catch { }
      $out.Add(('  {0,-22} pid {1,-7} commit {2,6} MB  ws {3,6} MB  hnd {4,6}  thr {5,4}  started {6}' -f `
        $_.ProcessName,$_.Id,[math]::Round($_.PrivateMemorySize64/1MB),[math]::Round($_.WorkingSet64/1MB),
        $_.HandleCount,$_.Threads.Count,$st2))
    }
  $out.Add('')

  $out.Add('---- claude sessions (command line identifies which) ----')
  try {
    Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop | ForEach-Object {
      $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
      $c = $_.CommandLine
      if($null -eq $c){ $c = '' }
      $tag = 'other'
      if($c.Contains('daemon run')){ $tag = 'daemon' }
      elseif($c.Contains('bg-pty-host')){ $tag = 'pty-host' }
      elseif($c.Contains('--resume')){ $tag = 'session' }
      $sid = ''
      $ix = $c.IndexOf('pty-')
      if($ix -ge 0 -and $c.Length -ge $ix+12){ $sid = $c.Substring($ix+4,8) }
      if($sid -eq '' -and $c.Contains('.jsonl')){
        $j = $c.LastIndexOf('\')
        if($j -ge 0 -and $c.Length -ge $j+9){ $sid = $c.Substring($j+1,8) }
      }
      $mb = 0; $wsmb = 0; $hnd = 0
      if($null -ne $p){ $mb = [math]::Round($p.PrivateMemorySize64/1MB); $wsmb = [math]::Round($p.WorkingSet64/1MB); $hnd = $p.HandleCount }
      $out.Add(('  pid {0,-7} {1,-9} {2,-9} commit {3,5} MB  ws {4,5} MB  hnd {5,5}' -f $_.ProcessId,$tag,$sid,$mb,$wsmb,$hnd))
    }
  } catch { $out.Add('  (could not enumerate)') }
  $out.Add('')

  $out.Add('---- marathon memory guard, last 12 lines ----')
  $g = Join-Path $root 'wsl-mem-guard.log'
  if(Test-Path $g){ Get-Content $g -Tail 12 | ForEach-Object { $out.Add('  ' + $_.TrimEnd()) } }
  else { $out.Add('  (no guard log)') }
  $out.Add('')

  # WSL side LAST, and EACH PROBE TIMED SEPARATELY.
  #
  # A single budget over a compound command cannot tell you WHICH part was slow, so it
  # attributes every timeout to "WSL". The first version of this script did exactly that
  # and reported "WSL DID NOT ANSWER IN 20s" at a moment when `wsl -- echo ok` was
  # answering in 250ms — the slow part was `ci-pause status`, which shells out to docker.
  # That is the same defect this box's memory guard has: a probe that cannot distinguish
  # "the subject is broken" from "my query was slow" will blame the subject.
  #
  # So: one probe per fact, each with its own budget, and the DURATION is recorded for
  # every probe whether it succeeds or not. A slow probe is then visible as a number
  # instead of being laundered into a verdict about WSL.
  $out.Add('---- WSL / slots (each probe timed separately; a slow probe is data, not a verdict) ----')
  function Probe([string]$label, [string]$cmd, [int]$budgetMs){
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName  = 'wsl.exe'
      $psi.Arguments = '-d Ubuntu -u root -- sh -c "' + $cmd + '"'
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError  = $true
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow  = $true
      $pr = [System.Diagnostics.Process]::Start($psi)
      if($pr.WaitForExit($budgetMs)){
        $o = $pr.StandardOutput.ReadToEnd()
        $sw.Stop()
        $script:out.Add(('  [{0}] {1} ms' -f $label, $sw.ElapsedMilliseconds))
        foreach($l in ($o -split "`n")){ if($l.Trim() -ne ''){ $script:out.Add('      ' + $l.TrimEnd()) } }
      } else {
        try { $pr.Kill() } catch { }
        $sw.Stop()
        $script:out.Add(('  [{0}] TIMED OUT after {1} ms budget — this probe only, not a claim about WSL' -f $label, $budgetMs))
      }
    } catch {
      $sw.Stop()
      $script:out.Add(('  [{0}] failed in {1} ms: {2}' -f $label, $sw.ElapsedMilliseconds, $_.Exception.Message))
    }
  }

  # Cheapest first, so a later hang still leaves the earlier facts on the page.
  Probe 'alive'      'echo ok'                                              8000
  Probe 'uptime'     'uptime'                                               8000
  Probe 'vm-mem'     'free -m | head -2'                                    8000
  Probe 'workers'    'ps -eo cmd | grep -ac "[R]unner.Worker" || true'      8000
  Probe 'containers' 'docker ps --format ''{{.Names}} {{.Status}}''' 15000
  Probe 'slot1'      '/usr/local/sbin/ci-pause status --slot 1 | head -4' 15000
  Probe 'slot2'      '/usr/local/sbin/ci-pause status --slot 2 | head -4' 15000

  $out.Add('')
  $out.Add('---- recent system events (ids relevant to resource exhaustion) ----')
  try {
    $ev = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$now.AddMinutes(-30)} -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -in 2004,2019,2020,41,6008,1001,7031,7034,10016 } | Select-Object -First 8
    if($null -eq $ev){ $out.Add('  none in the last 30 min') }
    else { $ev | ForEach-Object {
      $m = ($_.Message -replace '\s+',' ')
      if($m.Length -gt 140){ $m = $m.Substring(0,140) }
      $out.Add(('  {0} id={1} :: {2}' -f $_.TimeCreated.ToString('HH:mm:ss'),$_.Id,$m)) } }
  } catch { $out.Add('  (event log query failed)') }

  $out | Out-File -FilePath $snap -Encoding utf8
  $wrote = $snap
  $lastSnap = $now
}

# ---------- persist state ----------

@{ free = $free; lastSnap = $lastSnap.ToString('o') } | ConvertTo-Json -Compress |
  Out-File -FilePath $stateF -Encoding utf8

if(-not $Quiet){
  $msg = 'free {0}MB vmmem {1}MB claude {2}MB/{3}p dropbox {4}MB commit {5}MB delta {6}MB' -f `
         $free,$vm.WS,$claude.WS,$claude.N,$dropbox.WS,$commit,$delta
  if($wrote -ne ''){ $msg = $msg + '  >>> SNAPSHOT: ' + $wrote }
  elseif($tripReason -ne ''){ $msg = $msg + '  (tripped: ' + $tripReason + ', suppressed by cooldown)' }
  Write-Output $msg
}
