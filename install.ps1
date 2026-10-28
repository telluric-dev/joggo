<#
.SYNOPSIS
  Install a joggo self-hosted GitHub Actions runner on Windows + WSL2.

.DESCRIPTION
  Registers the runner, brings up N containerised slots, and schedules the
  memory guard, the 5-minute sampler and the wedge watchdog. Two front doors,
  one engine: a wizard for humans, flags for agents. Both produce the same
  config object and run the same steps.

  WSL2 on Windows is the only supported target.

  The registration token is never written to disk. Pass -Token, set
  $env:JOGGO_TOKEN, or let the wizard prompt for it without echo.

  Exit codes: 0 ok, 1 blocking failure, 2 bad usage, 3 preflight failed.

.PARAMETER Scope
  'org' or 'repo'. 'repo' is the personal-account path: runner groups are an
  organisation-only feature, so a personal account registers per repository.

.PARAMETER Token
  Registration token. Short-lived (~1h), never stored. Alternatives:
  $env:JOGGO_TOKEN, or the no-echo wizard prompt.

.PARAMETER PreflightOnly
  Run install/preflight.ps1, report, exit. Changes nothing.

.PARAMETER DryRun
  Print every step's intent and change nothing. Makes no wsl.exe call that
  could start or alter the distro.

.EXAMPLE
  ./install.ps1
  The wizard.

.EXAMPLE
  ./install.ps1 -NonInteractive -Json -Yes -Scope repo -Repo me/my-app -Token $env:JOGGO_TOKEN -Slots 2
  The agent path: one line, machine-readable on stdout.

.EXAMPLE
  ./install.ps1 -PreflightOnly
  Check the box without touching it.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
  # PositionalBinding=$false, and it is load-bearing. Left positional, a typo
  # like `--slots 2` binds as a VALUE to the first positional parameter: it died
  # inside PowerShell's binder complaining about -Scope's ValidateSet, which
  # names the wrong parameter and never reaches this script's own usage text or
  # exit 2. (A bare [Parameter()] attribute does NOT remove positionality —
  # tested.) With it off, anything unrecognised lands in $Rest below.
  #
  # --- config keys (every key in the schema is a flag) ---
  [Parameter()][ValidateSet('org','repo')][string]$Scope,
  [Parameter()][string]$Org,
  [Parameter()][string]$Repo,
  [Parameter()][string]$RunnerName,
  [Parameter()][string]$Labels,
  [Parameter()][int]$Slots,
  [Parameter()][string]$Distro,
  [Parameter()][string]$RunnerUser,
  [switch]$Guard,
  [switch]$NoGuard,
  [Parameter()][int]$GuardWarnMB,
  [Parameter()][int]$GuardCriticalMB,
  [Parameter()][int]$GuardIntervalMin,
  [switch]$Sampler,
  [switch]$NoSampler,
  [switch]$Watchdog,
  [switch]$NoWatchdog,
  [switch]$Monitor,
  [switch]$NoMonitor,
  [switch]$StartOnBoot,
  [switch]$NoStartOnBoot,
  [switch]$Tailscale,
  [switch]$NoTailscale,
  [switch]$FilterAaaa,
  [switch]$NoFilterAaaa,
  [Parameter()][string]$Token,

  # --- behaviour ---
  [switch]$Wizard,
  [switch]$NonInteractive,
  [switch]$PreflightOnly,
  [switch]$SkipPreflight,
  [switch]$Json,
  [switch]$DryRun,
  [switch]$Yes,
  [Parameter()][string]$ConfigFile,

  [switch]$h,
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $RepoRoot 'install\config.ps1')

function Show-Usage {
  @'
joggo install — a self-hosted GitHub Actions runner on Windows + WSL2.

  ./install.ps1                                    wizard (the human front door)
  ./install.ps1 -NonInteractive -Scope repo -Repo me/app -Token $env:JOGGO_TOKEN
  ./install.ps1 -PreflightOnly                     check the box, change nothing
  ./install.ps1 -DryRun -NonInteractive -Scope repo -Repo me/app -Token x

CONFIG (defaults scale with RAM; see install/CONTRACT.md for the schema)
  -Scope org|repo        repo is the PERSONAL-ACCOUNT path. Runner groups are an
                         organisation-only feature, so a personal account must
                         register per repository. Both work end to end.
  -Org <name>            required with -Scope org
  -Repo <owner/name>     required with -Scope repo
  -RunnerName <s>        default joggo
  -Labels <csv>          default self-hosted,linux,x64,joggo
  -Slots <n>             default 1 under 12 GB RAM, 2 otherwise. Never more by
                         default: RAM decides whether a second slot fits, and
                         nothing past that — this workload is IO-bound. 3+ works
                         but is untested here.
  -Distro <s>            default Ubuntu-24.04
  -RunnerUser <s>        default ghrunner. Never root.
  -Guard | -NoGuard      the memory guard. On by default.
  -GuardWarnMB <n>       default 15% of RAM   (2500 on the 16 GB box it was measured on)
  -GuardCriticalMB <n>   default 7.5% of RAM  (1200 on 16 GB)
  -GuardIntervalMin <n>  default 5
  -Sampler | -NoSampler  guard/mem-watch.ps1, the 5-minute trail. On by default.
  -Watchdog | -NoWatchdog        the wedge detector. On by default.
  -Monitor | -NoMonitor          the WPF monitor. OFF by default (desktop app).
  -StartOnBoot | -NoStartOnBoot  keepalive task + enabled units. On by default.
  -Tailscale | -NoTailscale      optional, remote management only. Off by default.
  -FilterAaaa            install network/filter-aaaa.conf: strips AAAA for the
                         slot networks, so hosts advertising unroutable AAAA
                         records fail fast instead of hanging a build. OPT-IN —
                         it changes DNS inside the distro. The wizard offers it
                         only when preflight raised that warning.
  -Token <s>             registration token. NEVER stored. Also read from
                         $env:JOGGO_TOKEN, or prompted for without echo.

BEHAVIOUR
  -Wizard                interactive. The default when no scope flag is given.
  -NonInteractive        never prompt; exit 2 if something required is missing.
  -PreflightOnly         run preflight, report, exit. Changes nothing.
  -SkipPreflight         run the steps without preflight. You are on your own.
  -Json                  machine-readable on stdout, human text on stderr.
  -DryRun                print every step's intent, change nothing.
  -Yes                   assume yes for confirmations.
  -ConfigFile <path>     load config from JSON; flags override it.
  -h, -?                 this text / the full help.

EXIT  0 ok   1 blocking failure   2 bad usage   3 preflight failed
'@
}

if($h -or $Help){ Show-Usage; exit 0 }

$ctx = New-JoggoContext @{
  Json = [bool]$Json; DryRun = [bool]$DryRun; Yes = [bool]$Yes
  NonInteractive = [bool]$NonInteractive; RepoRoot = $RepoRoot
}

if($Rest -and $Rest.Count -gt 0){
  Write-JLine $ctx ("[FAIL] unrecognised argument(s): " + ($Rest -join ' '))
  Write-JLine $ctx ''
  Show-Usage
  Add-Result $ctx 'usage' 'fail' ("unrecognised: " + ($Rest -join ' ')) 'see ./install.ps1 -h'
  Exit-Joggo -Ctx $ctx -Code 2
}

# ---------------------------------------------------------------- preflight
#
# FIRST, and before anything is changed. install/preflight.ps1 is a separate
# concern and a separate file: it checks everything the WHOLE run needs, so a
# user cannot get halfway and discover virtualization is off in the BIOS.

$preflight = Join-Path $RepoRoot 'install\preflight.ps1'

function Invoke-JoggoPreflight {
  param([hashtable]$Ctx,[hashtable]$Cfg,[string]$PfToken,[switch]$ReportOnly)
  if(-not (Test-Path $preflight)){
    # Missing preflight is NOT "preflight passed". In a real run that is fatal:
    # nothing has checked virtualization, systemd, Docker Desktop or the disk,
    # and proceeding would be guessing on the user's behalf.
    if($Ctx.DryRun -and -not $ReportOnly){
      Warn $Ctx 'install/preflight.ps1 is missing. A real run would abort here with exit 3.'
      Say  $Ctx 'Continuing ONLY because -DryRun changes nothing.'
      Add-Result $Ctx 'preflight' 'warn' 'preflight.ps1 missing; dry run continued' 'restore install/preflight.ps1 before a real install'
      return 0
    }
    Write-JLine $Ctx '[FAIL] install/preflight.ps1 is missing — nothing has checked this box.'
    Write-JLine $Ctx '       -> restore it from the repo, or pass -SkipPreflight and accept that'
    Write-JLine $Ctx '          virtualization, systemd, Docker Desktop and disk space are unverified.'
    Add-Result $Ctx 'preflight' 'fail' 'install/preflight.ps1 missing' 'restore it, or pass -SkipPreflight'
    Exit-Joggo -Ctx $Ctx -Code 3
  }

  # Forward what preflight needs in order to check the right things: it cannot
  # tell an org install from a repo one, or know which distro was resolved,
  # unless it is told.
  # A HASHTABLE SPLAT, not an array one. `& $script @arrayOfStrings` binds the
  # elements POSITIONALLY here: '-Distro' arrives as preflight's $Scope and dies
  # on its ValidateSet. Named splatting is unambiguous.
  $pfArgs = @{}
  if($Cfg){
    if($Cfg.scope) { $pfArgs['Scope']  = $Cfg.scope }
    if($Cfg.org)   { $pfArgs['Org']    = $Cfg.org }
    if($Cfg.repo)  { $pfArgs['Repo']   = $Cfg.repo }
    if($Cfg.distro){ $pfArgs['Distro'] = $Cfg.distro }
    if($Cfg.slots) { $pfArgs['Slots']  = [int]$Cfg.slots }
  }
  if($PfToken){ $pfArgs['Token'] = $PfToken }

  if($ReportOnly){
    # -PreflightOnly belongs to the user, not to me. Run it in whichever form
    # they asked for and get out of the way: preflight emits EITHER JSON on
    # stdout OR human text via Write-Host, never both, so there is nothing to
    # tee and no value in reformatting it.
    if($Ctx.Json){ $pfArgs['Json'] = $true }
    & $preflight @pfArgs
    return $LASTEXITCODE
  }

  # For a real run, always ask for JSON and render it here.
  #
  # Two reasons, both mechanical. The human form goes out through Write-Host,
  # which does not travel down the pipeline, so it cannot be captured at all.
  # And the wizard's AAAA question has to be gated on preflight ACTUALLY having
  # raised that warning, which means reading its findings rather than its
  # exit code.
  $pfArgs['Json'] = $true
  $raw = (& $preflight @pfArgs) -join "`n"
  $code = $LASTEXITCODE
  $rep = $null
  if($raw.Trim()){
    try { $rep = $raw | ConvertFrom-Json } catch { $rep = $null }
  }
  if($null -eq $rep){
    # Preflight ran but said nothing parseable. That is not a pass.
    Write-JLine $Ctx '[FAIL] preflight produced no parseable JSON report.'
    Write-JLine $Ctx '       -> run it on its own to see what it says: ./install.ps1 -PreflightOnly'
    Add-Result $Ctx 'preflight' 'fail' 'preflight emitted no parseable report' 'run ./install.ps1 -PreflightOnly'
    Exit-Joggo -Ctx $Ctx -Code 3
  }
  foreach($c in @($rep.checks)){
    $tag = '[WARN]'
    if($c.status -eq 'pass'){ $tag = '[PASS]' }
    if($c.status -eq 'fail'){ $tag = '[FAIL]' }
    Write-JLine $Ctx ("{0} {1}: {2}" -f $tag, $c.id, $c.detail)
    if($c.status -ne 'pass' -and $c.action){ Write-JLine $Ctx ("       -> " + $c.action) }
    Add-Result $Ctx ("preflight." + $c.id) $c.status $c.detail $c.action
    if(($c.id + ' ' + $c.detail + ' ' + $c.action) -match '(?i)aaaa' -and $c.status -ne 'pass'){
      $Ctx.AaaaWarned = $true
    }
  }
  Write-JLine $Ctx ("       preflight: {0} blocking, {1} warning(s)" -f $rep.blocking, $rep.warnings)
  if($Ctx.AaaaWarned){
    Say $Ctx 'the AAAA finding above has a fix in this repo: pass -FilterAaaa to install network/filter-aaaa.conf.'
  }
  if($code -ne 0){
    Write-JLine $Ctx ''
    Write-JLine $Ctx "[FAIL] preflight reported $code — blocking problems above."
    Add-Result $Ctx 'preflight' 'fail' "preflight exited $code" 'fix the blocking checks and re-run'
    if($Ctx.DryRun){
      # A dry run is most useful on a box that is NOT yet ready, so it carries
      # on and prints the whole plan — but it still exits 3 at the end, and says
      # so here, because a plan is not a pass.
      Write-JLine $Ctx '       -DryRun continues so you can read the plan, and will still exit 3.'
      Write-JLine $Ctx '       A real run would have stopped right here, with nothing changed.'
      $Ctx.PreflightFailed = $true
      return $code
    }
    Write-JLine $Ctx '       -> fix each [FAIL] line and re-run. Nothing has been changed.'
    Exit-Joggo -Ctx $Ctx -Code 3
  }
  Add-Result $Ctx 'preflight' 'pass' 'preflight exited 0' ''
}

# ---------------------------------------------------------------- config
#
# Defaults -> config file -> flags -> wizard. The wizard is the default front
# door when nothing on the command line determines the scope.

$ramMB = 0
try { $ramMB = Get-JoggoRamMB } catch {
  Fail -Ctx $ctx -Problem "could not read the installed RAM: $($_.Exception.Message)" -Action 'the guard thresholds and the slot count are both scaled from it; fix WMI/CIM before installing' -Code 1
}
$cfg = Get-JoggoDefaults -RamMB $ramMB

if($ConfigFile){
  $fromFile = Read-JoggoConfigFile -Ctx $ctx -Path $ConfigFile
  foreach($k in $fromFile.Keys){ $cfg[$k] = $fromFile[$k] }
  Say $ctx "config loaded from $ConfigFile (flags override it)"
}
$cfg = Merge-JoggoFlags -Cfg $cfg -Bound $PSBoundParameters

# Resolve the distro NAME before preflight, so preflight checks the distro that
# will actually be used rather than the schema's default spelling. Read-only:
# `wsl -l -v` lists and starts nothing.
$cfg = Resolve-JoggoDistro -Ctx $ctx -Cfg $cfg -Explicit ($PSBoundParameters.ContainsKey('Distro'))
$ctx.Distro = $cfg.distro

# The token, from the flag or the environment ONLY at this point. Prompting
# before preflight would ask for a short-lived secret and then possibly abort —
# the wizard prompt comes later, once the box is known to be viable.
#
# DELIBERATELY NOT NAMED $token. PowerShell variable names are case-INSENSITIVE,
# so `$token` and the `$Token` parameter are the SAME variable: assigning '' to
# the lower-case one erased the flag the user had just passed, and the install
# then announced "no token given" while holding one.
$regToken = ''
if($Token){ $regToken = $Token }
else {
  foreach($n in @('JOGGO_TOKEN','RUNNER_TOKEN','GITHUB_RUNNER_TOKEN')){
    $v = [Environment]::GetEnvironmentVariable($n)
    if($v){ $regToken = $v; Say $ctx "token taken from `$env:$n (not stored)"; break }
  }
}

if($PreflightOnly){
  $pfCode = Invoke-JoggoPreflight -Ctx $ctx -Cfg $cfg -PfToken $regToken -ReportOnly
  if($null -eq $pfCode){ $pfCode = 0 }
  Write-JLine $ctx ''
  if($pfCode -eq 0){
    Write-JLine $ctx 'Preflight only: nothing blocking, and nothing was changed.'
    Write-JLine $ctx 'Next: ./install.ps1    (or ./install.ps1 -h for the flag form)'
  } else {
    Write-JLine $ctx "Preflight only: exit $pfCode. Nothing was changed."
    Write-JLine $ctx 'Fix each blocking check above and run it again.'
  }
  exit $pfCode
}

$scopeGiven = ($PSBoundParameters.ContainsKey('Scope') -or $PSBoundParameters.ContainsKey('Org') -or $PSBoundParameters.ContainsKey('Repo') -or ($ConfigFile -and $cfg.scope))
$useWizard = $false
if($Wizard){ $useWizard = $true }
elseif(-not $scopeGiven -and -not $NonInteractive){ $useWizard = $true }

if($useWizard -and $NonInteractive){
  Fail -Ctx $ctx -Problem '-Wizard and -NonInteractive are mutually exclusive' -Action 'drop one; the agent form is -NonInteractive with -Scope/-Repo or -Org' -Code 2
}
if(-not $useWizard -and -not $scopeGiven){
  Fail -Ctx $ctx -Problem '-NonInteractive without a scope' -Action 'pass -Scope repo -Repo owner/name, or -Scope org -Org yourorg' -Code 2
}

# PREFLIGHT BEFORE THE WIZARD, not after.
#
# Two reasons. It checks everything the whole run needs, so nobody should answer
# fifteen questions and then be told virtualization is off in the BIOS. And the
# wizard's AAAA question is gated on preflight having actually raised that
# warning — which means preflight has to have run first.
if(-not $SkipPreflight){
  [void](Invoke-JoggoPreflight -Ctx $ctx -Cfg $cfg -PfToken $regToken)
} else {
  Warn $ctx '-SkipPreflight: nothing has checked this box. Failures below may be anything.'
  Add-Result $ctx 'preflight' 'warn' 'skipped by -SkipPreflight' ''
}

if($useWizard){
  $cfg = Invoke-JoggoWizard -Ctx $ctx -Cfg $cfg
}

$cfg = Test-JoggoConfig -Ctx $ctx -Cfg $cfg
$ctx.Distro   = $cfg.distro
$ctx.TokenUrl = Get-JoggoTokenUrl -Cfg $cfg

# ---------------------------------------------------------------- the token
#
# Already taken from -Token or the environment above. This is the no-echo prompt
# for the interactive path, asked only now that the box is known to be viable
# and the scope is known — so the URL printed with it is the right one.

if(-not $regToken){ $regToken = Resolve-JoggoToken -Ctx $ctx -Flag '' }
if(-not $regToken -and -not $ctx.DryRun){
  Fail -Ctx $ctx -Problem 'no registration token' -Action ("mint one at " + $ctx.TokenUrl + " and pass -Token <t>, or set `$env:JOGGO_TOKEN. It is short-lived and never stored.") -Code 2
}
if(-not $regToken -and $ctx.DryRun){
  Say $ctx 'no token given; -DryRun does not need one'
}

# ---------------------------------------------------------------- run

$steps = @(
  '10-wsl-feature','20-distro','30-runner-user','40-docker','45-dns-aaaa',
  '50-dind-image','60-runner','70-slots','80-guard','90-watchdog','95-boot','99-verify'
)
$ctx.StepTotal = $steps.Count

Write-JLine $ctx ''
Write-JLine $ctx '================================ joggo install ================================'
Write-JLine $ctx ("  scope      : {0}  ->  {1}" -f $cfg.scope, (Get-JoggoRunnerUrl -Cfg $cfg))
Write-JLine $ctx ("  runner     : {0}   labels: {1}" -f $cfg.runnerName, $cfg.labels)
Write-JLine $ctx ("  distro     : {0}   user: {1}   slots: {2}" -f $cfg.distro, $cfg.runnerUser, $cfg.slots)
Write-JLine $ctx ("  guard      : {0}  warn {1} MB / critical {2} MB every {3} min  ({4} MB RAM)" -f $cfg.guard, $cfg.guardWarnMB, $cfg.guardCriticalMB, $cfg.guardIntervalMin, $cfg.ramMB)
Write-JLine $ctx ("  sampler    : {0}   watchdog: {1}   startOnBoot: {2}   monitor: {3}" -f $cfg.sampler, $cfg.watchdog, $cfg.startOnBoot, $cfg.monitor)
Write-JLine $ctx ("  filterAaaa : {0}   tailscale: {1}" -f $cfg.filterAaaa, $cfg.tailscale)
Write-JLine $ctx ("  token      : {0}" -f (& { if($regToken){'held in memory, never written'} else {'none (dry run)'} }))
if($ctx.DryRun){ Write-JLine $ctx '  DRY RUN    : nothing will be changed, and no wsl.exe call will be made.' }
Write-JLine $ctx '=============================================================================='

if(-not (Test-Admin) -and -not $ctx.DryRun){
  Fail -Ctx $ctx -Problem 'not running as Administrator' -Action 'the Windows features, the SYSTEM scheduled tasks and the keepalive all need elevation. Re-run in an elevated PowerShell.' -Code 1
}

Save-JoggoConfig -Ctx $ctx -Cfg $cfg

foreach($s in $steps){
  $f = Join-Path $RepoRoot ("install\steps\{0}.ps1" -f $s)
  if(-not (Test-Path $f)){
    Fail -Ctx $ctx -Problem "step file missing: install/steps/$s.ps1" -Action 'run install.ps1 from a complete checkout' -Code 1
  }
  & $f -Ctx $ctx -Cfg $cfg -Token $regToken
  # A step fails only through Fail/Undetermined, which set Failed on the shared
  # context and have already printed the problem and the action item. Checking
  # the flag rather than $LASTEXITCODE: that variable keeps its previous value
  # when a script exits without setting one, which would read as success.
  if($ctx.Failed){
    $code = 1
    if($ctx.ExitCode){ $code = [int]$ctx.ExitCode }
    Exit-Joggo -Ctx $ctx -Code $code
  }
}

if($ctx.PreflightFailed){
  Write-JLine $ctx ''
  Write-JLine $ctx 'DRY RUN COMPLETE, AND PREFLIGHT FAILED. Nothing was changed.'
  Write-JLine $ctx 'The plan above is what a real run would attempt; it would not have got past'
  Write-JLine $ctx 'preflight. Fix the [FAIL] lines near the top, then run it for real.'
  Exit-Joggo -Ctx $ctx -Code 3
}

if($ctx.DryRun){
  Write-JLine $ctx ''
  Write-JLine $ctx 'DRY RUN COMPLETE. Nothing was changed, and no wsl.exe call was made.'
}
Exit-Joggo -Ctx $ctx -Code 0
