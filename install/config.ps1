# config.ps1 — schema, RAM-scaled defaults, flag parse, wizard, and the shared
# plumbing every step uses. Dot-sourced by install.ps1 and uninstall.ps1; it
# defines functions and nothing else, so sourcing it changes nothing.
#
# Windows PowerShell 5.1 is the floor. No ternaries, no ?? , no -AsHashtable:
# the scheduled tasks this installer registers run under powershell.exe, and a
# file that only parses in pwsh would fail there and nowhere else.

Set-StrictMode -Version 1.0

# ---------------------------------------------------------------- output
#
# -Json puts machine-readable output on stdout and ALL human text on stderr, so
# an agent can parse stdout without a filter. Every Say/Warn/Fail therefore
# writes to the host stream only when -Json is off, and to stderr when it is on.

function New-JoggoContext {
  param(
    [hashtable]$Opt = @{}
  )
  $ctx = @{
    Json        = $false
    DryRun      = $false
    Yes         = $false
    NonInteractive = $false
    StepNo      = 0
    StepTotal   = 0
    Results     = (New-Object System.Collections.ArrayList)
    RepoRoot    = $null
    DataDir     = (Join-Path $env:ProgramData 'joggo')
    BinDir      = (Join-Path $env:ProgramData 'joggo\bin')
    ConfigPath  = (Join-Path $env:ProgramData 'joggo\joggo.config.json')
    Failed      = $false
  }
  foreach($k in $Opt.Keys){ $ctx[$k] = $Opt[$k] }
  $ctx
}

function Write-JLine {
  param([hashtable]$Ctx, [string]$Text)
  if($Ctx.Json){ [Console]::Error.WriteLine($Text) } else { Write-Host $Text }
}
function Say  { param([hashtable]$Ctx,[string]$m) Write-JLine $Ctx "       $m" }
function Ok   { param([hashtable]$Ctx,[string]$m) Write-JLine $Ctx "[ OK ] $m" }
function Skip { param([hashtable]$Ctx,[string]$m) Write-JLine $Ctx "[SKIP] $m" }
function Warn { param([hashtable]$Ctx,[string]$m) Write-JLine $Ctx "[WARN] $m" }
function Plan { param([hashtable]$Ctx,[string]$m) Write-JLine $Ctx "[PLAN] $m" }

# A failure always names the action item. There is no bare-"failed" path here on
# purpose: every call site passes -Action, and the parameter is mandatory so one
# cannot be added that forgets.
function Fail {
  param(
    [hashtable]$Ctx,
    [Parameter(Mandatory=$true)][string]$Problem,
    [Parameter(Mandatory=$true)][string]$Action,
    [int]$Code = 1
  )
  Write-JLine $Ctx "[FAIL] $Problem"
  Write-JLine $Ctx "       -> $Action"
  $Ctx.Failed = $true
  $Ctx.ExitCode = $Code
  [void]$Ctx.Results.Add([pscustomobject]@{ id='fail'; status='fail'; detail=$Problem; action=$Action })
  Exit-Joggo -Ctx $Ctx -Code $Code
}

# "could not determine" is a FAILURE, never a pass. This exists so that reading
# the code makes that unmistakable: there is no third outcome to reach for.
# slots/slot-pause.sh's job_in_flight is the cautionary tale — it treated a
# failed `docker top` as "idle" and stopped a running build.
function Undetermined {
  param(
    [hashtable]$Ctx,
    [Parameter(Mandatory=$true)][string]$What,
    [Parameter(Mandatory=$true)][string]$Action
  )
  Fail -Ctx $Ctx -Problem "could not determine $What" -Action $Action -Code 1
}

function Step-Header {
  param([hashtable]$Ctx,[string]$Name)
  $Ctx.StepNo = $Ctx.StepNo + 1
  Write-JLine $Ctx ''
  Write-JLine $Ctx ("== {0}/{1} {2} ==" -f $Ctx.StepNo, $Ctx.StepTotal, $Name)
}

function Add-Result {
  param([hashtable]$Ctx,[string]$Id,[string]$Status,[string]$Detail='',[string]$Action='')
  [void]$Ctx.Results.Add([pscustomobject]@{ id=$Id; status=$Status; detail=$Detail; action=$Action })
}

function Exit-Joggo {
  param([hashtable]$Ctx,[int]$Code)
  # A step that fails exits the step script; install.ps1 then exits too. The
  # -Json object must be printed exactly once across those two exits, so the
  # flag lives on the shared context rather than in either scope.
  if($Ctx.Json -and -not $Ctx.JsonPrinted){
    $Ctx.JsonPrinted = $true
    $blocking = @($Ctx.Results | Where-Object { $_.status -eq 'fail' }).Count
    $warnings = @($Ctx.Results | Where-Object { $_.status -eq 'warn' }).Count
    $obj = [pscustomobject]@{
      ok       = ($Code -eq 0)
      exit     = $Code
      dryRun   = [bool]$Ctx.DryRun
      checks   = @($Ctx.Results)
      blocking = $blocking
      warnings = $warnings
    }
    $obj | ConvertTo-Json -Depth 6
  }
  exit $Code
}

function Confirm-Joggo {
  param([hashtable]$Ctx,[string]$Question)
  if($Ctx.Yes){ return $true }
  if($Ctx.NonInteractive){
    Say $Ctx "-NonInteractive without -Yes: refusing '$Question'"
    return $false
  }
  # A host can be non-interactive without -NonInteractive having been passed
  # (powershell.exe -NonInteractive, a scheduled task, a CI runner). Read-Host
  # throws there, and an unhandled throw on a confirmation prompt would look
  # like a crash rather than a question nobody could answer.
  $a = ''
  try { $a = Read-Host "$Question [y/N]" }
  catch {
    Say $Ctx "this host cannot prompt ($($_.Exception.Message.Trim())), so '$Question' is answered NO."
    Say $Ctx 'pass -Yes if you meant yes.'
    return $false
  }
  return ($a -match '^(y|yes)$')
}

# ---------------------------------------------------------------- schema

function Get-JoggoRamMB {
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  [int]($os.TotalVisibleMemorySize / 1KB)
}

# The guard thresholds scale with RAM, and the scaling is not a guess: 15% /
# 7.5% of total RAM reproduce 2500 MB / 1200 MB on the 16 GB box where those two
# numbers were actually measured (guard/wsl-mem-guard.ps1, and
# docs/memory-pressure.md for the measurements behind them). Scaling the ratio
# rather than shipping the absolute numbers is what makes them mean the same
# thing on an 8 GB or a 64 GB box.
#
# THE SLOT COUNT DOES NOT SCALE PAST TWO, and that is deliberate. RAM decides
# whether a second slot fits at all, and nothing beyond that: this workload is
# IO-bound, not RAM-bound (docs/adding-a-slot.md measures 30-40% of tasks
# stalled on IO with a SINGLE job running, and calls the second slot only
# "mostly free"). A tier table keyed on RAM above 32 GB would be inventing
# evidence for a configuration nothing here has run.
function Get-JoggoDefaults {
  param([int]$RamMB)
  if($RamMB -le 0){ throw 'RAM size unknown' }
  $slots = 2
  if($RamMB -lt 12288){ $slots = 1 }
  @{
    scope             = ''
    org               = ''
    repo              = ''
    runnerName        = 'joggo'
    labels            = 'self-hosted,linux,x64,joggo'
    slots             = $slots
    distro            = 'Ubuntu-24.04'
    runnerUser        = 'ghrunner'
    guard             = $true
    guardWarnMB       = [int][math]::Round($RamMB * 0.15)
    guardCriticalMB   = [int][math]::Round($RamMB * 0.075)
    guardIntervalMin  = 5
    sampler           = $true
    watchdog          = $true
    monitor           = $false
    # The supervisor brief for an agent session. Defaults ON because it costs one
    # rendered markdown file and nothing else — and the point of rendering it rather
    # than shipping it is that it carries THIS box's distro name, paths and
    # thresholds. A generic brief makes an agent guess, which is the thing the brief
    # exists to prevent.
    agentSupervisor   = $true
    startOnBoot       = $true
    tailscale         = $false
    filterAaaa        = $false
    ramMB             = $RamMB
  }
}

$script:JoggoKeys = @(
  'scope','org','repo','runnerName','labels','slots','distro','runnerUser',
  'guard','guardWarnMB','guardCriticalMB','guardIntervalMin','sampler',
  'watchdog','monitor','agentSupervisor','startOnBoot','tailscale','filterAaaa','ramMB'
)
function Get-JoggoKeys { $script:JoggoKeys }

# ---------------------------------------------------------------- the token
#
# NEVER PERSISTED. Not in the config file, not in a log line, not in an echo.
# It is read here, kept in one variable, handed to the Linux half on STDIN (not
# on a command line, where it would be visible in /proc and in any process
# listing), and dropped when the process exits. SECURITY.md is the reason.
#
# A registration token is also short-lived (~1h) and single-purpose, so storing
# it buys nothing even ignoring the risk.
function Resolve-JoggoToken {
  param([hashtable]$Ctx,[string]$Flag)
  if($Flag){ return $Flag }
  foreach($n in @('JOGGO_TOKEN','RUNNER_TOKEN','GITHUB_RUNNER_TOKEN')){
    $v = [Environment]::GetEnvironmentVariable($n)
    if($v){ Say $Ctx "token taken from `$env:$n (not stored)"; return $v }
  }
  if($Ctx.NonInteractive){ return '' }
  Write-JLine $Ctx ''
  Write-JLine $Ctx 'Registration token. Mint it at:'
  if($Ctx.TokenUrl){ Write-JLine $Ctx ("  " + $Ctx.TokenUrl) }
  Write-JLine $Ctx 'It is short-lived (~1h) and is never written to disk by this installer.'
  $sec = Read-Host -AsSecureString 'Token (not echoed)'
  if(-not $sec){ return '' }
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-JoggoTokenUrl {
  param([hashtable]$Cfg)
  if($Cfg.scope -eq 'org'){
    return ("https://github.com/organizations/{0}/settings/actions/runners/new" -f $Cfg.org)
  }
  return ("https://github.com/{0}/settings/actions/runners/new" -f $Cfg.repo)
}

function Get-JoggoRunnerUrl {
  param([hashtable]$Cfg)
  if($Cfg.scope -eq 'org'){ return ("https://github.com/{0}" -f $Cfg.org) }
  return ("https://github.com/{0}" -f $Cfg.repo)
}

# ---------------------------------------------------------------- config build

function Read-JoggoConfigFile {
  param([hashtable]$Ctx,[string]$Path)
  if(-not (Test-Path $Path)){
    Fail -Ctx $Ctx -Problem "config file not found: $Path" -Action "check the path, or drop -ConfigFile to use flags/wizard" -Code 2
  }
  $raw = Get-Content -Path $Path -Raw
  try { $o = $raw | ConvertFrom-Json }
  catch {
    Fail -Ctx $Ctx -Problem "config file is not valid JSON: $Path" -Action "fix the JSON; install/joggo.config.example.json is a working example" -Code 2
  }
  $h = @{}
  foreach($p in $o.PSObject.Properties){ $h[$p.Name] = $p.Value }
  if($h.ContainsKey('registrationToken')){
    Warn $Ctx "$Path contains a registrationToken key. It is IGNORED and should be deleted — tokens are never stored."
    $h.Remove('registrationToken')
  }
  $h
}

function Merge-JoggoFlags {
  param([hashtable]$Cfg,[hashtable]$Bound)
  # Flags override the file, which overrides the RAM-scaled defaults. Only keys
  # actually PRESENT on the command line count: $PSBoundParameters, not the
  # variables, or every unspecified switch would read as an explicit $false.
  $map = @{
    Scope='scope'; Org='org'; Repo='repo'; RunnerName='runnerName'; Labels='labels';
    Slots='slots'; Distro='distro'; RunnerUser='runnerUser'; GuardWarnMB='guardWarnMB';
    GuardCriticalMB='guardCriticalMB'; GuardIntervalMin='guardIntervalMin'
  }
  foreach($f in $map.Keys){
    if($Bound.ContainsKey($f)){ $Cfg[$map[$f]] = $Bound[$f] }
  }
  $pairs = @(
    @('Guard','NoGuard','guard'), @('Sampler','NoSampler','sampler'),
    @('Watchdog','NoWatchdog','watchdog'), @('Monitor','NoMonitor','monitor'), @('AgentSupervisor','NoAgentSupervisor','agentSupervisor'),
    @('StartOnBoot','NoStartOnBoot','startOnBoot'), @('Tailscale','NoTailscale','tailscale'),
    @('FilterAaaa','NoFilterAaaa','filterAaaa')
  )
  foreach($p in $pairs){
    if($Bound.ContainsKey($p[0])){ $Cfg[$p[2]] = $true }
    if($Bound.ContainsKey($p[1])){ $Cfg[$p[2]] = $false }
  }
  $Cfg
}

function Invoke-JoggoWizard {
  param([hashtable]$Ctx,[hashtable]$Cfg)
  Write-JLine $Ctx ''
  Write-JLine $Ctx 'joggo install — wizard. Enter accepts the default in [brackets].'
  Write-JLine $Ctx ("RAM detected: {0} MB. Defaults below are scaled from it." -f $Cfg.ramMB)
  Write-JLine $Ctx ''

  function Ask([string]$q,[string]$def){
    $a = Read-Host ("{0} [{1}]" -f $q,$def)
    if([string]::IsNullOrWhiteSpace($a)){ return $def }
    return $a.Trim()
  }
  function AskBool([string]$q,[bool]$def){
    $d = 'n'; if($def){ $d = 'y' }
    $a = Read-Host ("{0} (y/n) [{1}]" -f $q,$d)
    if([string]::IsNullOrWhiteSpace($a)){ return $def }
    return ($a -match '^(y|yes)$')
  }

  # Scope first: it decides which identifier is asked for, and it is the one
  # choice people get wrong. Runner GROUPS are an organisation-only feature, so
  # a personal account has to register per repository — scope=repo is not a
  # lesser path, it is the only path there.
  Write-JLine $Ctx 'Scope:'
  Write-JLine $Ctx '  org   — one registration serves every repo you allow. Needs an organisation'
  Write-JLine $Ctx '          and org-admin rights. Runner groups (the real security boundary)'
  Write-JLine $Ctx '          only exist here.'
  Write-JLine $Ctx '  repo  — one repository. THIS IS THE PERSONAL-ACCOUNT PATH: a personal'
  Write-JLine $Ctx '          account has no runner groups, so per-repository is how it works.'
  $scope = ''
  while($scope -ne 'org' -and $scope -ne 'repo'){
    $scope = (Ask 'scope (org|repo)' 'repo').ToLower()
  }
  $Cfg.scope = $scope
  if($scope -eq 'org'){
    while(-not $Cfg.org){ $Cfg.org = Ask 'organisation name' '' }
  } else {
    while($Cfg.repo -notmatch '^[^/\s]+/[^/\s]+$'){ $Cfg.repo = Ask 'repository (owner/name)' '' }
  }

  $Cfg.runnerName = Ask 'runner name'        $Cfg.runnerName
  $Cfg.labels     = Ask 'labels'             $Cfg.labels
  $Cfg.distro     = Ask 'WSL distro'         $Cfg.distro
  $Cfg.runnerUser = Ask 'runner user (unprivileged, never root)' $Cfg.runnerUser
  # RAM decides whether a second slot fits; it does not justify a third. The
  # prompt says so rather than implying a ladder.
  $Cfg.slots      = [int](Ask ("slots (1 under 12 GB, 2 otherwise; this box has {0} MB)" -f $Cfg.ramMB) ([string]$Cfg.slots))

  $Cfg.guard = AskBool 'install the memory guard (recommended)' $Cfg.guard
  if($Cfg.guard){
    $Cfg.guardWarnMB      = [int](Ask 'guard warn MB (hold slots below this)'    ([string]$Cfg.guardWarnMB))
    $Cfg.guardCriticalMB  = [int](Ask 'guard critical MB (restart below this)'   ([string]$Cfg.guardCriticalMB))
    $Cfg.guardIntervalMin = [int](Ask 'guard interval, minutes'                  ([string]$Cfg.guardIntervalMin))
  }
  $Cfg.sampler     = AskBool 'install the 5-minute memory sampler' $Cfg.sampler
  $Cfg.watchdog    = AskBool 'install the wedge watchdog'          $Cfg.watchdog
  $Cfg.startOnBoot = AskBool 'start on boot (keepalive task + enabled units)' $Cfg.startOnBoot
  $Cfg.monitor     = AskBool 'install the WPF monitor (desktop app, optional)' $Cfg.monitor
  $Cfg.agentSupervisor = AskBool 'render a supervisor brief for an agent session' $Cfg.agentSupervisor
  $Cfg.tailscale   = AskBool 'configure Tailscale for remote management (optional)' $Cfg.tailscale

  # OFFERED ONLY WHEN PREFLIGHT ACTUALLY RAISED THE WARNING. It changes name
  # resolution inside the distro, which is not something to do to someone
  # because a checklist had a line for it. $Ctx.AaaaWarned is set from
  # preflight's own output; absent that, the question is not asked and the
  # default stays false.
  if($Ctx.AaaaWarned){
    Write-JLine $Ctx ''
    Write-JLine $Ctx 'Preflight saw DNS return AAAA records that do not route from here.'
    Write-JLine $Ctx 'Build-time fetches and `docker login ghcr.io` then HANG rather than fail —'
    Write-JLine $Ctx 'on the box this came from that stalled a production image pin for hours.'
    Write-JLine $Ctx 'The fix is a dnsmasq drop-in that strips AAAA for the slot networks only.'
    $Cfg.filterAaaa = AskBool 'install the AAAA filter (changes DNS inside the distro)' $Cfg.filterAaaa
  }
  $Cfg
}

function Test-JoggoConfig {
  param([hashtable]$Ctx,[hashtable]$Cfg)
  if($Cfg.scope -ne 'org' -and $Cfg.scope -ne 'repo'){
    Fail -Ctx $Ctx -Problem "scope must be 'org' or 'repo' (got '$($Cfg.scope)')" -Action "pass -Scope repo -Repo owner/name, or -Scope org -Org yourorg" -Code 2
  }
  if($Cfg.scope -eq 'org' -and -not $Cfg.org){
    Fail -Ctx $Ctx -Problem 'scope=org needs an organisation' -Action 'pass -Org <name>. A personal account has no organisation: use -Scope repo -Repo owner/name' -Code 2
  }
  if($Cfg.scope -eq 'repo' -and $Cfg.repo -notmatch '^[^/\s]+/[^/\s]+$'){
    Fail -Ctx $Ctx -Problem "scope=repo needs -Repo owner/name (got '$($Cfg.repo)')" -Action 'pass -Repo me/my-app' -Code 2
  }
  if([int]$Cfg.slots -lt 1 -or [int]$Cfg.slots -gt 8){
    Fail -Ctx $Ctx -Problem "slots must be 1..8 (got $($Cfg.slots))" -Action 'pass -Slots 1, or -Slots 2 on a box with 12 GB or more' -Code 2
  }
  # Stated as a fact, because it is one: two is the most this has ever run.
  if([int]$Cfg.slots -gt 2){
    Say $Ctx "$($Cfg.slots) slots is untested here — two is the most this setup has run, and the limit past that is likely disk throughput rather than memory."
    Add-Result $Ctx 'slots' 'warn' "$($Cfg.slots) slots is untested; the constraint is IO, not RAM" ''
  }
  if([int]$Cfg.guardCriticalMB -ge [int]$Cfg.guardWarnMB){
    Fail -Ctx $Ctx -Problem "guardCriticalMB ($($Cfg.guardCriticalMB)) must be below guardWarnMB ($($Cfg.guardWarnMB))" -Action 'the guard holds at warn and restarts at critical; critical has to be the lower line' -Code 2
  }
  if([int]$Cfg.guardIntervalMin -lt 1){
    Fail -Ctx $Ctx -Problem 'guardIntervalMin must be >= 1' -Action 'pass -GuardIntervalMin 5' -Code 2
  }
  if($Cfg.distro -eq 'docker-desktop' -or $Cfg.distro -eq 'docker-desktop-data'){
    Fail -Ctx $Ctx -Problem "distro '$($Cfg.distro)' is Docker Desktop's own utility VM" -Action 'pick a real distro, e.g. -Distro Ubuntu-24.04' -Code 2
  }
  # Not fatal, but the single most common wasted hour: runner groups do not
  # exist outside an organisation.
  if($Cfg.scope -eq 'org'){
    Warn $Ctx 'scope=org: set the runner GROUP after install (Settings -> Actions -> Runner groups).'
    Say  $Ctx 'That group page is the security boundary: private repos only, never public, never fork PRs.'
    Add-Result $Ctx 'org-group' 'warn' 'runner group must be restricted after install' 'Settings -> Actions -> Runner groups'
  }
  $Cfg
}

# The config file on disk is the sanitized object: every schema key, and no
# token. Written with the token key absent rather than empty, so nothing
# downstream can be tempted to read it.
function Save-JoggoConfig {
  param([hashtable]$Ctx,[hashtable]$Cfg)
  $out = [ordered]@{}
  foreach($k in (Get-JoggoKeys)){ if($Cfg.ContainsKey($k)){ $out[$k] = $Cfg[$k] } }
  if($Ctx.DryRun){
    Plan $Ctx ("would write " + $Ctx.ConfigPath)
    return
  }
  New-Item -ItemType Directory -Force -Path (Split-Path $Ctx.ConfigPath) | Out-Null
  ([pscustomobject]$out | ConvertTo-Json -Depth 4) | Set-Content -Path $Ctx.ConfigPath -Encoding utf8
  $txt = Get-Content -Path $Ctx.ConfigPath -Raw
  if($txt -match 'registrationToken'){
    Fail -Ctx $Ctx -Problem 'the written config contains a token key' -Action 'this is a bug in Save-JoggoConfig; delete the file and report it' -Code 1
  }
  Ok $Ctx ("config written: " + $Ctx.ConfigPath + " (no token in it — verified by reading it back)")
}

# ---------------------------------------------------------------- WSL plumbing
#
# Two of these three lessons come from guard/wsl-mem-guard.ps1. The third is a
# correction TO it.
#
#  * the command travels as BASE64, because quoting a shell command through
#    PowerShell's native argument packing and then through wsl.exe has silently
#    eaten a single-quoted glob in this repo before;
#  * ProcessStartInfo, not Start-Process -PassThru, because on PS 5.1 the latter
#    leaves ExitCode empty and can hand back empty redirect files;
#  * every call is BOUNDED. An unbounded wsl.exe call hangs the installer
#    exactly when the VM is the thing that is wrong.
#
# THE CAPTURE IS *NOT* THE GUARD'S. Do not reintroduce its
# Register-ObjectEvent + BeginOutputReadLine + "let the async handlers drain the
# last lines" sleep. That pattern races PowerShell's event loop and silently
# discards most of the output while reporting exit code 0 — measured:
#
#     seq 1 3    -> 3 lines captured
#     seq 1 25   -> 2 lines captured   (23 lost)
#     seq 1 80   -> 3 lines captured   (77 lost)
#
# Every verification in this installer parses multi-line output from inside the
# distro (systemctl state, image inspection, the verify report), so that defect
# would make a step "succeed" against output that was thrown away — the exact
# failure class this installer exists to avoid.
#
# ReadToEndAsync on BOTH streams, started BEFORE the bounded WaitForExit:
# nothing buffers up and deadlocks, nothing is dropped, and there is no sleep to
# tune.
#
# -Stdin is how the config (and the registration token in it) reaches the Linux
# half: on stdin, never in an argument, so it is not in any process listing.

function Invoke-Wsl {
  param(
    [hashtable]$Ctx,
    [Parameter(Mandatory=$true)][string]$Command,
    [string]$Distro,
    [string]$User = 'root',
    [int]$TimeoutSec = 60,
    [string]$Stdin
  )
  if(-not $Distro){ $Distro = $Ctx.Distro }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'wsl.exe'
  # eval, not a pipe into bash: a pipe would make the decoded script bash's
  # stdin and there would be nowhere left to hand the config in. eval runs it in
  # this shell, whose stdin is still ours.
  $psi.Arguments = '-d ' + $Distro + ' -u ' + $User + ' bash -c "eval \"$(echo ' + $b64 + ' | base64 --decode)\""'
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.RedirectStandardInput   = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow  = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try {
    [void]$p.Start()
    # Both readers started before anything can block, so neither stream can fill
    # its pipe buffer and wedge the other.
    $tOut = $p.StandardOutput.ReadToEndAsync()
    $tErr = $p.StandardError.ReadToEndAsync()
    if($PSBoundParameters.ContainsKey('Stdin') -and $null -ne $Stdin){
      # WRITE THE BYTES, NOT THE STRING. StandardInput is a StreamWriter whose
      # encoding comes from the console code page -- on this box 437/1252, not
      # UTF-8 -- so .Write($string) re-encodes every non-ASCII character on its
      # way into the pipe. inside-wsl.sh carries em-dashes and middle dots in
      # its comments, so each one arrived inside the distro as two or three
      # mojibake bytes. That is what broke it: enough of them land inside quoted
      # strings to desynchronise bash's parser, and the error surfaced 150 lines
      # later as "line 205: syntax error near unexpected token `('" -- a line
      # containing file(s), which is only a syntax error once the quoting around
      # it has already been destroyed.
      #
      # ProcessStartInfo.StandardInputEncoding would be the tidy fix and does not
      # exist on .NET Framework, which is what Windows PowerShell 5.1 runs on. So
      # encode explicitly and write to the BaseStream, which takes bytes and
      # re-encodes nothing.
      $inBytes = [Text.Encoding]::UTF8.GetBytes($Stdin)
      $p.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length)
      $p.StandardInput.BaseStream.Flush()
    }
    $p.StandardInput.Close()
    if(-not $p.WaitForExit($TimeoutSec * 1000)){
      try { $p.Kill() } catch {}
      # Whatever arrived before the kill is still worth returning: it usually
      # names which part was slow.
      $partial = ''
      try { $partial = $tOut.Result } catch {}
      return [pscustomobject]@{ ok=$false; code=-1; out=$partial; err=("timed out after ${TimeoutSec}s"); timedOut=$true }
    }
    # The process has exited and both pipes are closed, so these complete
    # immediately and completely.
    $so = ''; $se = ''
    try { $so = $tOut.Result } catch { $so = '' }
    try { $se = $tErr.Result } catch { $se = '' }
    return [pscustomobject]@{ ok=($p.ExitCode -eq 0); code=$p.ExitCode; out=$so.Trim(); err=$se.Trim(); timedOut=$false }
  } finally {
    $p.Dispose()
  }
}

# Resolve the distro NAME before anything uses it.
#
# The schema default is Ubuntu-24.04; a store-installed Ubuntu is very often
# registered as plain 'Ubuntu'. Reporting "Ubuntu-24.04 is not installed" on a
# box with a perfectly good Ubuntu is literally true and practically useless, so
# this accepts any usable Ubuntu: exact name first, then a single Ubuntu* if
# there is exactly one, and it ASKS when there are several rather than picking.
# Only when none is found is installing offered.
function Resolve-JoggoDistro {
  param([hashtable]$Ctx,[hashtable]$Cfg,[bool]$Explicit)
  $distros = Get-WslDistros -Ctx $Ctx
  if($null -eq $distros){
    # No answer is not "none installed". Leave the configured name alone and let
    # 20-distro fail with a real diagnosis.
    Warn $Ctx 'wsl -l -v did not answer, so the installed distros could not be listed. Keeping the configured name.'
    return $Cfg
  }
  $names = @($distros | ForEach-Object { $_.name })
  if($names -contains $Cfg.distro){
    Ok $Ctx "distro '$($Cfg.distro)' found"
    return $Cfg
  }
  if($Explicit){
    Fail -Ctx $Ctx -Problem "distro '$($Cfg.distro)' was named explicitly but is not installed" `
      -Action ("installed: " + ($names -join ', ') + ". Pass one of those, or 'wsl --install -d $($Cfg.distro)' first.") -Code 2
  }

  $ubuntu = @($names | Where-Object { $_ -match '^(?i)ubuntu' })
  if($ubuntu.Count -eq 1){
    Say $Ctx "'$($Cfg.distro)' is not installed, but '$($ubuntu[0])' is — using it. (Pass -Distro to override.)"
    $Cfg.distro = $ubuntu[0]
    return $Cfg
  }
  if($ubuntu.Count -gt 1){
    # Several candidates is exactly when guessing is worst: the wrong one may be
    # somebody's working environment.
    Write-JLine $Ctx "'$($Cfg.distro)' is not installed, and there is more than one Ubuntu:"
    foreach($u in $ubuntu){ Write-JLine $Ctx ("  " + $u) }
    if($Ctx.NonInteractive){
      Fail -Ctx $Ctx -Problem 'several Ubuntu distros are installed and none matches the configured name' `
        -Action ("pass -Distro with one of: " + ($ubuntu -join ', ')) -Code 2
    }
    $pick = ''
    while($ubuntu -notcontains $pick){ $pick = (Read-Host ("which distro? [" + $ubuntu[0] + "]")).Trim(); if(-not $pick){ $pick = $ubuntu[0] } }
    $Cfg.distro = $pick
    return $Cfg
  }
  Say $Ctx "no Ubuntu distro is installed (found: $(if($names.Count){$names -join ', '}else{'none'})). 20-distro will offer to install '$($Cfg.distro)'."
  return $Cfg
}

# The Linux half is staged INTO the distro rather than executed from /mnt/c:
# a script on a DrvFs mount carries CRLF and no exec bit, and both failures
# present as nonsense errors from bash. Staging also means /opt/joggo holds
# exactly what ran, which is what uninstall and any later debugging read.
function Push-InsideWsl {
  param([hashtable]$Ctx)
  $src = Join-Path $Ctx.RepoRoot 'install\inside-wsl.sh'
  if(-not (Test-Path $src)){
    Fail -Ctx $Ctx -Problem "install/inside-wsl.sh is missing from $($Ctx.RepoRoot)" -Action 'run install.ps1 from a complete checkout' -Code 1
  }
  # READ IT AS UTF-8 EXPLICITLY. Get-Content -Raw under Windows PowerShell 5.1
  # reads a BOM-less file as ANSI, and this file is BOM-less UTF-8 -- as a shell
  # script must be, since a BOM is bytes before the shebang. Measured on the box
  # this was written on: Get-Content -Raw returned 59026 characters where the
  # file holds 58953, because each em-dash came back as three.
  #
  # Same root cause as the supervisor-brief renderer in 97-agent.ps1. That one
  # was found by rendering the file and looking at it; this one could only be
  # found by running the installer, because the corruption happened in a string
  # that was never printed -- it went straight into a pipe.
  #
  # The -replace stays: a CRLF checkout would still need flattening.
  $text = ([System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)) -replace "`r",''
  $r = Invoke-Wsl -Ctx $Ctx -Command 'mkdir -p /opt/joggo && cat > /opt/joggo/inside-wsl.sh && chmod 0755 /opt/joggo/inside-wsl.sh && bash -n /opt/joggo/inside-wsl.sh && echo staged' -Stdin $text -TimeoutSec 60
  if(-not $r.ok -or $r.out -notmatch 'staged'){
    Fail -Ctx $Ctx -Problem "could not stage the Linux half into $($Ctx.Distro): $($r.err)$($r.out)" -Action "check: wsl -d $($Ctx.Distro) -u root -- echo ok" -Code 1
  }
  $Ctx.Staged = $true
}

# The repo files the Linux half installs (launcher, units, pause lever,
# watchdog, dind build context) are pushed as a path<TAB>base64 manifest on
# stdin. base64 so nothing in a file body can be mistaken for the protocol, and
# so binary content (buildkit contexts, future assets) survives unchanged.
function Push-RepoPayload {
  param([hashtable]$Ctx,[string[]]$RelPaths)
  $lines = New-Object System.Collections.ArrayList
  foreach($rel in $RelPaths){
    $full = Join-Path $Ctx.RepoRoot $rel
    if(-not (Test-Path $full)){
      Fail -Ctx $Ctx -Problem "repo file missing: $rel" -Action 'run install.ps1 from a complete checkout' -Code 1
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    [void]$lines.Add(($rel -replace '\\','/') + "`t" + [Convert]::ToBase64String($bytes))
  }
  $manifest = ($lines -join "`n") + "`n"
  $r = Invoke-Wsl -Ctx $Ctx -Command 'bash /opt/joggo/inside-wsl.sh stage-payload' -Stdin $manifest -TimeoutSec 120
  if(-not $r.ok){
    Fail -Ctx $Ctx -Problem "staging the repo payload failed: $($r.err)$($r.out)" -Action 'see the output above; /opt/joggo must be writable by root in the distro' -Code 1
  }
  if($r.out){ foreach($l in ($r.out -split "`n")){ if($l.Trim()){ Say $Ctx $l.Trim() } } }
}

# Run one phase of the Linux half with the config (and the token) on stdin.
function Invoke-Phase {
  param(
    [hashtable]$Ctx,
    [hashtable]$Cfg,
    [Parameter(Mandatory=$true)][string]$Phase,
    [string]$Token = '',
    [int]$TimeoutSec = 600,
    [string[]]$Extra = @()
  )
  if(-not $Ctx.Staged){ Push-InsideWsl -Ctx $Ctx }
  $o = [ordered]@{}
  foreach($k in (Get-JoggoKeys)){ if($Cfg.ContainsKey($k)){ $o[$k] = $Cfg[$k] } }
  $o['runnerUrl'] = Get-JoggoRunnerUrl -Cfg $Cfg
  # The ONLY place the token is ever serialised, and it goes to a pipe, not a
  # file. Nothing on the Linux side writes it anywhere either.
  if($Token){ $o['registrationToken'] = $Token }
  $json = ([pscustomobject]$o | ConvertTo-Json -Depth 4 -Compress)
  $argline = (@($Phase) + $Extra) -join ' '
  $r = Invoke-Wsl -Ctx $Ctx -Command ("bash /opt/joggo/inside-wsl.sh " + $argline) -Stdin $json -TimeoutSec $TimeoutSec
  if($r.out){
    foreach($l in ($r.out -split "`n")){ if($l.TrimEnd()){ Write-JLine $Ctx ("       " + $l.TrimEnd()) } }
  }
  if($r.err -and -not $r.ok){
    foreach($l in ($r.err -split "`n")){ if($l.TrimEnd()){ Write-JLine $Ctx ("       " + $l.TrimEnd()) } }
  }
  $r
}

# ---------------------------------------------------------------- distro probe

function Get-WslDistros {
  param([hashtable]$Ctx)
  # `wsl -l -v` lists; it does NOT start anything. That matters: every other wsl
  # call in here boots the VM as a side effect, and a probe must not.
  $raw = & wsl.exe -l -v 2>&1
  if($LASTEXITCODE -ne 0){
    return $null   # caller decides; "no answer" is never "no distros"
  }
  $out = New-Object System.Collections.ArrayList
  foreach($line in @($raw)){
    $s = ($line -replace "`0",'').Trim()
    if(-not $s){ continue }
    if($s -match '^\*?\s*NAME\s'){ continue }
    if($s -match '^\*?\s*(\S+)\s+(\S+)\s+(\d+)\s*$'){
      [void]$out.Add([pscustomobject]@{ name=$Matches[1]; state=$Matches[2]; version=[int]$Matches[3] })
    }
  }
  # Exit 0 with nothing parsed means the OUTPUT changed shape, not that the box
  # has no distros — wsl.exe exits non-zero when there are genuinely none.
  # Returning an empty list here would read as "none installed" and send
  # 20-distro off to install over a working setup.
  if($out.Count -eq 0){ return $null }
  $out
}

# ---------------------------------------------------------------- scheduled tasks
#
# This is the gap the repo had: guard/wsl-mem-guard.ps1's own usage says "what
# the task runs", and nothing in the repo ever created that task. So the guard
# shipped as code that never ran.
#
# Every task registered here is: SYSTEM (so it works with nobody logged on),
# AtStartup (so it survives a reboot), -AllowStartIfOnBatteries
# -DontStopIfGoingOnBatteries (the default settings STOP a task on battery, and
# a laptop CI box would silently lose its guard on a power blip).

function Register-JoggoTask {
  param(
    [hashtable]$Ctx,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(Mandatory=$true)][string]$Arguments,
    [int]$EveryMinutes = 0,
    [switch]$AtStartupOnly,
    [string]$Description = ''
  )
  if($Ctx.DryRun){
    $iv = 'at startup only'
    if($EveryMinutes -gt 0){ $iv = "every $EveryMinutes min, indefinitely, from startup" }
    Plan $Ctx "would register scheduled task '$Name' as SYSTEM, $iv"
    Plan $Ctx "  action: $Exe $Arguments"
    return $true
  }

  $action    = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -StartWhenAvailable -MultipleInstances IgnoreNew `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
  if($EveryMinutes -gt 0){
    # A repetition on an AtStartup trigger, not a daily one: the box reboots for
    # Windows Update and a daily trigger would leave a gap until the next day.
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) `
        -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition
  } else {
    $trigger = New-ScheduledTaskTrigger -AtStartup
  }

  $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if($existing){
    Say $Ctx "task '$Name' exists — updating it in place (idempotent; not a second task)"
  }
  try {
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger `
      -Principal $principal -Settings $settings -Description $Description -Force -ErrorAction Stop | Out-Null
  } catch {
    Fail -Ctx $Ctx -Problem "registering scheduled task '$Name' failed: $($_.Exception.Message)" -Action 'run install.ps1 in an ELEVATED PowerShell (task registration as SYSTEM needs admin)' -Code 1
  }
  return $true
}

# READ IT BACK. Register-ScheduledTask exiting without throwing is not evidence
# that a task exists, is enabled, runs as SYSTEM, or repeats. Each of those is
# checked against the registered object here, and a missing answer fails.
function Assert-JoggoTask {
  param(
    [hashtable]$Ctx,
    [Parameter(Mandatory=$true)][string]$Name,
    [int]$EveryMinutes = 0
  )
  if($Ctx.DryRun){ Plan $Ctx "would read back task '$Name' and assert SYSTEM / enabled / interval"; return $true }

  $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if(-not $t){
    Fail -Ctx $Ctx -Problem "scheduled task '$Name' is not registered after registering it" -Action "check Task Scheduler, then re-run; 'Get-ScheduledTask -TaskName $Name' should return it" -Code 1
  }
  $problems = New-Object System.Collections.ArrayList
  if($t.State -eq 'Disabled'){ [void]$problems.Add('the task is DISABLED') }
  if($t.Principal.UserId -notmatch '(?i)^(SYSTEM|NT AUTHORITY\\SYSTEM|S-1-5-18)$'){
    [void]$problems.Add("it runs as '$($t.Principal.UserId)', not SYSTEM — it would not run with nobody logged on")
  }
  $set = $t.Settings
  if($set.DisallowStartIfOnBatteries){
    [void]$problems.Add('DisallowStartIfOnBatteries is set — a power blip would stop it')
  }
  if($set.StopIfGoingOnBatteries){ [void]$problems.Add('StopIfGoingOnBatteries is set') }
  $hasStartup = $false
  $interval = $null
  foreach($trg in @($t.Triggers)){
    if($trg.CimClass.CimClassName -match 'BootTrigger'){ $hasStartup = $true }
    if($trg.Repetition -and $trg.Repetition.Interval){ $interval = $trg.Repetition.Interval }
  }
  if(-not $hasStartup){ [void]$problems.Add('no at-startup trigger — it would not survive a reboot') }
  if($EveryMinutes -gt 0){
    if(-not $interval){
      [void]$problems.Add("no repetition interval — it would run once at boot and never again (wanted every $EveryMinutes min)")
    } elseif($interval -notmatch ("PT{0}M" -f $EveryMinutes) -and $interval -notmatch ("PT{0}H" -f ($EveryMinutes/60))){
      [void]$problems.Add("repetition interval is '$interval', wanted every $EveryMinutes min")
    }
  }
  if($problems.Count -gt 0){
    Fail -Ctx $Ctx -Problem ("scheduled task '$Name' is registered but wrong: " + ($problems -join '; ')) -Action "unregister it and re-run: Unregister-ScheduledTask -TaskName $Name -Confirm:`$false" -Code 1
  }
  $iv = 'at startup'
  if($interval){ $iv = "at startup, repeating $interval" }
  Ok $Ctx "task '$Name': registered, enabled, SYSTEM, $iv — read back from the scheduler"
  return $true
}

# "Scheduled" is not "working". This runs the task once and waits for the
# scheduler's OWN record of the run — LastRunTime advancing past the moment we
# started it, plus LastTaskResult 0. A task can be perfectly registered and fail
# every execution (a wrong path, no interpreter), and only this catches that.
function Assert-JoggoTaskHasRun {
  param(
    [hashtable]$Ctx,
    [Parameter(Mandatory=$true)][string]$Name,
    [int]$WaitSec = 120,
    [switch]$NoKick
  )
  if($Ctx.DryRun){ Plan $Ctx "would run task '$Name' once and read LastRunTime/LastTaskResult back"; return $true }

  $t0 = Get-Date
  if(-not $NoKick){
    try { Start-ScheduledTask -TaskName $Name -ErrorAction Stop }
    catch {
      Fail -Ctx $Ctx -Problem "could not start task '$Name': $($_.Exception.Message)" -Action "start it by hand: Start-ScheduledTask -TaskName $Name" -Code 1
    }
  }
  $deadline = $t0.AddSeconds($WaitSec)
  $info = $null
  while((Get-Date) -lt $deadline){
    $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
    if($null -eq $info){ Start-Sleep -Seconds 2; continue }
    # 267009 = currently running. Keep waiting rather than reading the previous
    # run's result and calling it this one's.
    if($info.LastTaskResult -ne 267009 -and $info.LastRunTime -and $info.LastRunTime -ge $t0.AddSeconds(-5)){ break }
    Start-Sleep -Seconds 3
  }
  if($null -eq $info){
    Undetermined -Ctx $Ctx -What "whether task '$Name' ran (the scheduler returned no run info)" -Action "check Task Scheduler history for '$Name'; it may be disabled at the service level"
  }
  if(-not $info.LastRunTime -or $info.LastRunTime -lt $t0.AddSeconds(-5)){
    Undetermined -Ctx $Ctx -What "whether task '$Name' ran (LastRunTime did not advance within ${WaitSec}s)" -Action "run it by hand and watch: Start-ScheduledTask -TaskName $Name ; Get-ScheduledTaskInfo -TaskName $Name"
  }
  if($info.LastTaskResult -ne 0){
    Fail -Ctx $Ctx -Problem ("task '$Name' ran and FAILED with result {0} (0x{0:X})" -f $info.LastTaskResult) -Action "run the task's action by hand to see the error; check the script path exists and powershell.exe can reach it" -Code 1
  }
  Ok $Ctx ("task '$Name': ran at {0} and exited 0 — read back from the scheduler, not assumed" -f $info.LastRunTime)
  return $true
}

function Get-JoggoPowerShellExe {
  # powershell.exe, not pwsh: it is present on every Windows box and the guard
  # is written against 5.1. A task pointed at a pwsh that was installed by hand
  # is a task that breaks the day someone uninstalls it.
  $p = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if(Test-Path $p){ return $p }
  $c = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if($c){ return $c.Source }
  return $null
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
