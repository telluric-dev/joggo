<#
  preflight.ps1 -- check everything the whole install needs, before anything changes.

  WHY THIS FILE IS LONG. The install touches the BIOS-level (virtualization), the
  Windows feature set, the WSL2 VM, Docker inside it, GitHub, and two disks. Each of
  those can be wrong in a way that only surfaces four steps in. Preflight contract,
  rule 2: a user must never get halfway and discover virtualization is off in the
  firmware. So every later step's precondition is asked about here instead.

  THE RULE THAT SHAPES EVERY CHECK BELOW
  --------------------------------------
  A check that cannot run must never report `pass`. This repo's docs are mostly about
  reads that return a plausible answer when their basis is missing (README, "A read
  that cannot fail loudly returns a number, not an error"; docs/memory-pressure.md
  SS9). So:

      "I asked, the answer is no"      -> fail / warn, with the measurement
      "I could not ask"                -> fail / warn, saying "could not determine"
      "the subject does not exist yet" -> warn, saying which step creates it

  Never `pass` for the last two. The distro probe carries a POSITIVE CONTROL in the
  same call -- a sentinel line at the end -- so a probe that half-ran is detected
  rather than read as a set of empty answers meaning "nothing wrong".

  OUTPUT
      human (default)   one line per check, then a summary
      -Json             a single object: { ok, checks[], blocking, warnings }
      -Quiet            human mode, FAIL/WARN lines and the summary only

  EXIT     0 nothing blocks   2 bad usage   3 something blocks
           Never 0 on a blocking failure. Design rule 6.

  THE TOKEN IS NEVER PRINTED. Not in human mode, not in -Json, not under -Verbose.
  Every detail and action string goes through Scrub() on the way out. SECURITY.md.

  Usage:
      install\preflight.ps1
      install\preflight.ps1 -Scope repo -Repo me/my-app -Slots 2
      install\preflight.ps1 -Json -Scope org -Org my-org
      install\preflight.ps1 -ConfigFile C:\ProgramData\joggo\joggo.config.json
#>
[CmdletBinding()]
param(
  [ValidateSet('', 'org', 'repo')]
  [string]$Scope = '',
  [string]$Org = '',
  [string]$Repo = '',
  [string]$Distro = 'Ubuntu-24.04',
  [int]$Slots = 0,
  # Accepted so preflight can confirm one was supplied. Held in memory, never printed,
  # never written. CONTRACT.md: "The registration token must never be persisted."
  [string]$Token = '',
  # Only check for gh if the caller actually wants the CLI path.
  [switch]$UseGhCli,
  [string]$ConfigFile = '',
  [switch]$Json,
  [switch]$Quiet
)

# Not 'Stop': one unexpected error must not abort the remaining checks, because a
# partial report is what sends someone into an install half-prepared. Each check
# carries its own try/catch and turns a surprise into a stated "could not determine".
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# wsl.exe writes UTF-16LE to a redirected pipe unless this is set, which turns every
# parse below into garbage with NULs in it. Older builds ignore the variable, so the
# parser strips NULs as well -- belt and braces, because a mis-parsed distro list
# reads as "no distro installed" and that is a wrong answer, not an error.
$env:WSL_UTF8 = '1'

$MinRamMB            = 8 * 1024
$WarnRamMB           = 12 * 1024
$MinSysDriveGB       = 40
$MinDistroGB         = 20
$ProbeSentinel       = '__JOGGO_PROBE_OK__'

# ---------------------------------------------------------------- report plumbing

$script:Checks = New-Object System.Collections.ArrayList

function Scrub([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return $s }
  if ($Token) { $s = $s.Replace($Token, '[redacted]') }
  # gh's own tokens are not registration tokens, but nothing is gained by echoing one.
  $s = [regex]::Replace($s, 'gh[pousr]_[A-Za-z0-9]{8,}', '[redacted]')
  $s
}

function Add-Check {
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][ValidateSet('pass', 'warn', 'fail')][string]$Status,
    [Parameter(Mandatory)][string]$Detail,
    [string]$Action = ''
  )
  $d = Scrub $Detail
  $a = Scrub $Action
  if ($Status -ne 'pass' -and -not $a) {
    # A bare "failed" is forbidden by design rule 1. If a check reaches here without
    # an action it is a bug in this file, and saying so beats hiding it.
    $a = "No action recorded for check '$Id' -- this is a bug in preflight.ps1; report it."
  }
  [void]$script:Checks.Add([pscustomobject]@{
    id     = $Id
    status = $Status
    detail = $d
    action = if ($a) { $a } else { $null }
  })
  if (-not $Json) {
    if ($Status -eq 'pass' -and $Quiet) { return }
    $tag = switch ($Status) { 'pass' { '[PASS]' } 'warn' { '[WARN]' } 'fail' { '[FAIL]' } }
    Write-Host "$tag $d"
    if ($a) { Write-Host "       -> $a" }
  }
}

function Die-Usage([string]$msg) {
  if ($Json) {
    [pscustomobject]@{ ok = $false; checks = @(); blocking = 0; warnings = 0; usage = (Scrub $msg) } |
      ConvertTo-Json -Depth 5
  } else {
    Write-Host "[USAGE] $(Scrub $msg)"
  }
  exit 2
}

# ---------------------------------------------------------------- config

if ($ConfigFile) {
  if (-not (Test-Path -LiteralPath $ConfigFile)) { Die-Usage "-ConfigFile not found: $ConfigFile" }
  try { $cfg = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json }
  catch { Die-Usage "-ConfigFile is not valid JSON: $ConfigFile" }
  # Explicit flags win over the file. CONTRACT.md: "flags override it."
  if (-not $PSBoundParameters.ContainsKey('Scope')  -and $cfg.scope)      { $Scope  = [string]$cfg.scope }
  if (-not $PSBoundParameters.ContainsKey('Org')    -and $cfg.org)        { $Org    = [string]$cfg.org }
  if (-not $PSBoundParameters.ContainsKey('Repo')   -and $cfg.repo)       { $Repo   = [string]$cfg.repo }
  if (-not $PSBoundParameters.ContainsKey('Distro') -and $cfg.distro)     { $Distro = [string]$cfg.distro }
  if (-not $PSBoundParameters.ContainsKey('Slots')  -and $cfg.slots)      { $Slots  = [int]$cfg.slots }
}

if ($Scope -eq 'org'  -and -not $Org)  { Die-Usage "-Scope org requires -Org <organisation>." }
if ($Scope -eq 'repo' -and -not $Repo) { Die-Usage "-Scope repo requires -Repo <owner/name>." }
if ($Repo -and $Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
  Die-Usage "-Repo must be owner/name, got '$Repo'."
}

# ---------------------------------------------------------------- helpers

function Clean-WslText([string]$s) {
  if ($null -eq $s) { return '' }
  # NULs: a UTF-16 pipe that WSL_UTF8 did not take. Control chars: the spinner
  # wsl.exe writes while installing.
  ($s -replace "`0", '') -replace "`r", ''
}

# Every wsl.exe call is bounded and the command travels as base64. Both of those are
# scar tissue from guard/wsl-mem-guard.ps1: an unbounded call hangs preflight exactly
# when the VM is the sick thing, and quoting a shell command through PowerShell's
# native argument packing AND wsl.exe has silently eaten a glob in this repo before.
# Base64 is [A-Za-z0-9+/=] only, so neither layer has anything left to chew.
# ONE capture path for every child process below, bounded by a timeout. The three
# obvious alternatives all lose output, and silent truncation is the worst failure
# this file can have: a probe whose tail went missing looks exactly like a probe that
# found nothing wrong.
#   * Register-ObjectEvent + BeginOutputReadLine (what guard/wsl-mem-guard.ps1 uses):
#     the -Action handlers go through PowerShell's event queue, and here it delivered
#     the first TWO lines of a 25-line probe and dropped the rest. Fine for the guard,
#     which reads one number. Useless for this. Measured 2026-10-28.
#   * Start-Process -PassThru -Redirect*: on PS 5.1 leaves ExitCode empty and can hand
#     back empty redirect files after WaitForExit says the process finished.
#   * Sequential ReadToEnd() on both streams: deadlocks when one fills its pipe buffer
#     while we are blocked on the other.
# ReadToEndAsync on both streams, started before the wait, has none of those.
function Start-Capture {
  param([string]$File, [string]$Arguments = '', [int]$TimeoutSec = 30, [switch]$Utf8)
  $r = [pscustomobject]@{ ran = $false; code = -1; out = ''; err = '' }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = $File
  $psi.Arguments = $Arguments
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow  = $true
  if ($Utf8) {
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
  }
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try {
    [void]$p.Start()
    $tO = $p.StandardOutput.ReadToEndAsync()
    $tE = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill() } catch {}
      $r.err = "did not answer within ${TimeoutSec}s"
      return $r
    }
    # The process is gone, so draining what the pipes still hold cannot block long.
    [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tO, $tE), 5000)
    $r.ran  = $true
    $r.code = $p.ExitCode
    if ($tO.IsCompleted) { $r.out = [string]$tO.Result }
    if ($tE.IsCompleted) { $r.err = [string]$tE.Result }
    return $r
  } catch {
    $r.err = $_.Exception.Message
    return $r
  } finally { try { $p.Dispose() } catch {} }
}

function Invoke-Wsl {
  param([string]$Command, [string]$InDistro = '', [int]$TimeoutSec = 90, [string]$User = 'root')
  $result = [pscustomobject]@{ reachable = $false; ok = $false; out = ''; err = '' }
  try { $null = Get-Command wsl.exe -ErrorAction Stop } catch { $result.err = 'wsl.exe not found'; return $result }

  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
  # NO QUOTES around the distro name. wsl.exe parses its own command line rather than
  # going through CommandLineToArgvW, so `-d "Ubuntu"` arrives with the quotes still
  # attached and fails with WSL_E_DISTRO_NOT_FOUND -- which reads as "the distro is
  # gone" instead of "preflight quoted it wrong". Measured here, 2026-10-28.
  $d = if ($InDistro) { "-d $InDistro " } else { '' }
  $argline = "$d-u $User bash -c `"echo $b64 | base64 -d | bash`""
  $c = Start-Capture -File 'wsl.exe' -Arguments $argline -TimeoutSec $TimeoutSec -Utf8
  if (-not $c.ran) { $result.err = "wsl.exe $($c.err)"; return $result }
  $result.reachable = $true
  $result.ok  = ($c.code -eq 0)
  $result.out = (Clean-WslText $c.out).Trim()
  $result.err = (Clean-WslText $c.err).Trim()
  $result
}

function Invoke-WslRaw {
  param([string[]]$WslArgs, [int]$TimeoutSec = 60)
  $result = [pscustomobject]@{ reachable = $false; ok = $false; out = ''; err = '' }
  try { $null = Get-Command wsl.exe -ErrorAction Stop } catch { $result.err = 'wsl.exe not found'; return $result }
  # Not -Utf8 here: `wsl --status` and `--list` predate WSL_UTF8 on some builds and
  # still answer in UTF-16LE. Clean-WslText strips the NULs either way, which matters
  # because a mis-decoded distro list parses as "no distro installed" -- a wrong
  # answer, not an error.
  $c = Start-Capture -File 'wsl.exe' -Arguments ($WslArgs -join ' ') -TimeoutSec $TimeoutSec
  if (-not $c.ran) { $result.err = "wsl.exe $($c.err)"; return $result }
  $result.reachable = $true
  $result.ok  = ($c.code -eq 0)
  $result.out = (Clean-WslText $c.out).Trim()
  $result.err = (Clean-WslText $c.err).Trim()
  $result
}

# An HTTP error status is a REACHABLE endpoint. ghcr.io/v2/ answers 401 to an
# anonymous request; treating that as unreachable would fail every clean box.
function Test-Https {
  param([string]$Url, [int]$TimeoutSec = 15)
  try {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.UserAgent = 'joggo-preflight'
    $req.AllowAutoRedirect = $false
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return [pscustomobject]@{ reachable = $true; code = $code; error = $null }
  } catch [System.Net.WebException] {
    $we = $_.Exception
    try {
      if ($we.Response) {
        $code = [int]$we.Response.StatusCode
        $we.Response.Close()
        return [pscustomobject]@{ reachable = $true; code = $code; error = $null }
      }
    } catch {}
    return [pscustomobject]@{ reachable = $false; code = 0; error = "$($we.Status)" }
  } catch {
    return [pscustomobject]@{ reachable = $false; code = 0; error = $_.Exception.Message }
  }
}

function Invoke-Exe {
  param([string]$File, [string]$Arguments = '', [int]$TimeoutSec = 30)
  $result = [pscustomobject]@{ ran = $false; code = -1; out = ''; err = '' }
  try { $cmd = Get-Command $File -ErrorAction Stop } catch { $result.err = "$File not found"; return $result }
  $c = Start-Capture -File $cmd.Source -Arguments $Arguments -TimeoutSec $TimeoutSec -Utf8
  $result.ran  = $c.ran
  $result.code = $c.code
  $result.out  = ($c.out -replace "`r", '').Trim()
  $result.err  = ($c.err -replace "`r", '').Trim()
  $result
}

# ================================================================ HOST

$isAdmin = $null
try {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $null }

# -- os-version
try {
  $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $ver = [Environment]::OSVersion.Version
  $build = $ver.Build
  $caption = ($os.Caption -replace '\s+', ' ').Trim()
  if ($os.ProductType -ne 1) {
    Add-Check os-version warn "$caption build $build -- server SKU, untested here" `
      'Supported target is Windows 10 2004+ or Windows 11 desktop. Proceed knowing the WSL2 path is unverified on Server.'
  } elseif ($build -ge 22000) {
    Add-Check os-version pass "$caption build $build -- WSL2 supported"
  } elseif ($build -ge 19041) {
    Add-Check os-version pass "$caption build $build (Windows 10 2004+) -- WSL2 supported"
  } else {
    Add-Check os-version fail "$caption build $build is below the WSL2 minimum (19041 / Windows 10 2004)" `
      'Run Windows Update to at least Windows 10 version 2004 (build 19041), then re-run.'
  }
} catch {
  Add-Check os-version fail "could not determine the Windows version: $($_.Exception.Message)" `
    'Run this from a normal PowerShell session on the target host; preflight cannot verify the OS from here.'
}

# -- arch
$arch = $env:PROCESSOR_ARCHITECTURE
if (-not $arch) { $arch = $env:PROCESSOR_ARCHITEW6432 }
if (-not $arch) {
  Add-Check arch fail 'could not determine the processor architecture' `
    'PROCESSOR_ARCHITECTURE is unset in this environment. Re-run from a normal PowerShell session.'
} elseif ($arch -eq 'AMD64') {
  Add-Check arch pass "x86-64 ($arch)"
} else {
  Add-Check arch fail "architecture is $arch, not x86-64" `
    'The runner tarball and the dind image this installs are linux/amd64 only. An arm64 host needs a different runner build; not supported here.'
}

# -- admin
if ($null -eq $isAdmin) {
  Add-Check admin fail 'could not determine whether this session is elevated' `
    'Re-run from an elevated PowerShell: Start-Process powershell -Verb RunAs'
} elseif ($isAdmin) {
  Add-Check admin pass 'running elevated'
} else {
  # Steps 10 (optional features), 80 (scheduled tasks) and 95 (keepalive task) all
  # need it, and 10 is the first thing that runs.
  Add-Check admin fail 'not elevated -- the WSL features, the scheduled tasks and the keepalive task all need admin' `
    'Re-run from an elevated PowerShell: Start-Process powershell -Verb RunAs -ArgumentList "-File <path to install.ps1>"'
}

# -- virtualization
# HypervisorPresent true means a hypervisor is already running, which cannot happen
# with firmware virtualization off -- so it is the strongest available signal.
# VirtualizationFirmwareEnabled is the firmware bit itself, but it reports $null on
# some OEM firmware, and $null is NOT "disabled".
try {
  $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
  $fw = $null
  try { $fw = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).VirtualizationFirmwareEnabled } catch {}
  if ($cs.HypervisorPresent) {
    Add-Check virtualization pass 'a hypervisor is running -- firmware virtualization is enabled'
  } elseif ($fw -eq $true) {
    Add-Check virtualization pass 'firmware virtualization enabled (no hypervisor running yet; step 10 starts one)'
  } elseif ($fw -eq $false) {
    Add-Check virtualization fail 'virtualization is disabled in firmware' `
      'Reboot into UEFI/BIOS and enable Intel VT-x or AMD-V (often under CPU / Advanced), then re-run. Nothing in this install works without it.'
  } else {
    Add-Check virtualization warn 'could not determine the firmware virtualization state (no hypervisor running, and the CPU did not report the bit)' `
      'Check it in UEFI/BIOS (Intel VT-x / AMD-V) before running the install, or confirm from an elevated prompt with: systeminfo | findstr /i "Virtualization Hyper-V"'
  }
} catch {
  Add-Check virtualization fail "could not determine the virtualization state: $($_.Exception.Message)" `
    'Confirm Intel VT-x / AMD-V is enabled in UEFI/BIOS before running the install.'
}

# -- ram
$ramMB = 0
try {
  $ramMB = [int]((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1MB)
} catch { $ramMB = 0 }
$recSlots = 0
if ($ramMB -le 0) {
  Add-Check ram fail 'could not determine installed RAM' `
    'The guard thresholds and the slot count are both scaled from RAM. Re-run where Win32_ComputerSystem is readable, or pass -Slots and the guard thresholds explicitly.'
} else {
  $ramGB = [math]::Round($ramMB / 1024, 1)
  $recSlots = if ($ramMB -lt (12 * 1024)) { 1 } elseif ($ramMB -le (32 * 1024)) { 2 } else { 3 }
  if ($ramMB -lt $MinRamMB) {
    Add-Check ram fail "$ramGB GB RAM -- below the 8 GB minimum" `
      'A runner slot plus its Docker-in-Docker daemon does not fit under 8 GB. Add RAM, or run the runner on another box.'
  } elseif ($ramMB -lt $WarnRamMB) {
    Add-Check ram warn "$ramGB GB RAM detected -- guard thresholds will scale, $recSlots slot recommended" `
      'Nothing to do, but expect the memory guard to hold slots under load. docs/memory-pressure.md is the measurement.'
  } else {
    Add-Check ram pass "$ramGB GB RAM -- $recSlots slots recommended, guard warn/critical will scale to $([int][math]::Round($ramMB*0.15))/$([int][math]::Round($ramMB*0.075)) MB"
  }
}

# -- slots (asked for vs what the RAM supports)
if ($Slots -gt 0) {
  if ($recSlots -le 0) {
    Add-Check slots warn "-Slots $Slots requested, but RAM is unknown so it cannot be judged" `
      'Resolve the ram check first; the slot count is scaled from RAM.'
  } elseif ($Slots -gt $recSlots) {
    Add-Check slots warn "-Slots $Slots exceeds the $recSlots recommended for $([math]::Round($ramMB/1024,1)) GB" `
      "Each slot is a runner container plus its own dockerd. Use -Slots $recSlots unless you have measured otherwise."
  } else {
    Add-Check slots pass "-Slots $Slots within the $recSlots recommended for this RAM"
  }
}

# -- disk-system
# NOTE the vhdx check below. The system drive is what the contract names, but it is
# not necessarily where the bytes land.
$sysDrive = $env:SystemDrive
try {
  $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'" -ErrorAction Stop
  if (-not $ld) { throw "no logical disk for $sysDrive" }
  $freeGB = [math]::Round($ld.FreeSpace / 1GB, 1)
  if ($freeGB -ge $MinSysDriveGB) {
    Add-Check disk-system pass "$freeGB GB free on $sysDrive (need $MinSysDriveGB GB)"
  } else {
    Add-Check disk-system fail "$freeGB GB free on $sysDrive -- below the $MinSysDriveGB GB the install wants" `
      "Free space on $sysDrive (cleanmgr, or move the WSL distro's VHDX to another drive and re-check). The runner tarball, the dind image and the slot work volumes all grow here unless the distro lives elsewhere -- see the vhdx check."
  }
} catch {
  Add-Check disk-system fail "could not determine free space on $sysDrive -- $($_.Exception.Message)" `
    "Check it by hand (Get-PSDrive $($sysDrive.TrimEnd(':'))) and ensure at least $MinSysDriveGB GB free before installing."
}

# -- power-sleep
# An asleep runner is a CI outage for every repo pointed at it, and WSL2 suspends with
# the host, so docs/runner-setup.md SS11.3 exists because SS2.4 (the Linux side) is not
# enough. The exact command is in the action on purpose.
$powercfgFix = 'powercfg /change standby-timeout-ac 0; powercfg /change standby-timeout-dc 0; powercfg /change hibernate-timeout-ac 0'
try {
  $pc = Invoke-Exe -File 'powercfg.exe' -Arguments '/q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE' -TimeoutSec 20
  if (-not $pc.ran) { throw "powercfg did not run: $($pc.err)" }
  $ac = $null; $dc = $null
  foreach ($line in ($pc.out -split "`n")) {
    if ($line -match 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)') { $ac = [Convert]::ToInt64($Matches[1], 16) }
    if ($line -match 'Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)') { $dc = [Convert]::ToInt64($Matches[1], 16) }
  }
  $hasBattery = $false
  try { $hasBattery = [bool](Get-CimInstance Win32_Battery -ErrorAction Stop) } catch { $hasBattery = $false }
  if ($null -eq $ac) {
    Add-Check power-sleep warn 'could not read the sleep timeout from the active power scheme' `
      "Set it anyway, elevated: $powercfgFix  -- then confirm with: powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE"
  } elseif ($ac -ne 0 -or ($hasBattery -and $dc -ne 0)) {
    $bits = @()
    if ($ac -ne 0) { $bits += "AC sleeps after $ac s" }
    if ($hasBattery -and $dc -ne 0) { $bits += "battery sleeps after $dc s" }
    Add-Check power-sleep fail "the active power plan will sleep this box ($($bits -join ', ')) -- that is a CI outage for every repo pointed at it" `
      "Run elevated: $powercfgFix  -- and on a laptop also set Control Panel > Power Options > closing the lid = Do nothing."
  } else {
    $note = if ($hasBattery) { 'AC and battery' } else { 'AC (no battery present)' }
    Add-Check power-sleep pass "sleep is disabled on $note in the active power plan"
  }
} catch {
  Add-Check power-sleep warn "could not determine the sleep settings -- $($_.Exception.Message)" `
    "Set them regardless, elevated: $powercfgFix"
}

# ================================================================ WSL

$wslPresent = $false
try { $null = Get-Command wsl.exe -ErrorAction Stop; $wslPresent = $true } catch { $wslPresent = $false }

if ($wslPresent) {
  $st = Invoke-WslRaw -WslArgs @('--status') -TimeoutSec 30
  if ($st.reachable) {
    Add-Check wsl-present pass 'wsl.exe present and answering'
  } else {
    # The interop wedge: the distro can be Running while every wsl.exe call fails.
    # That is not "no WSL", and it is not a pass either.
    Add-Check wsl-present fail "wsl.exe is installed but did not answer -- $($st.err)" `
      'Likely the WSL interop/control-plane wedge. From an elevated prompt: wsl --shutdown, then re-run. If that fails, restart the host.'
  }
} else {
  Add-Check wsl-present fail 'wsl.exe not found' `
    'Install WSL from an elevated prompt: wsl --install --no-distribution  (a reboot may be required), then re-run.'
}

# -- distro inventory
$distroList   = @()
$distroKnown  = $null     # $null = could not ask
if ($wslPresent) {
  $lv = Invoke-WslRaw -WslArgs @('--list', '--verbose') -TimeoutSec 30
  if ($lv.reachable -and $lv.out) {
    $distroKnown = @()
    foreach ($line in ($lv.out -split "`n")) {
      $t = $line.Trim()
      if (-not $t) { continue }
      if ($t -match '^\*?\s*(NAME)\s') { continue }
      if ($t -match '^\*?\s*(\S+)\s+(\S+)\s+(\d+)\s*$') {
        $distroKnown += [pscustomobject]@{ name = $Matches[1]; state = $Matches[2]; version = [int]$Matches[3] }
      }
    }
    $distroList = $distroKnown
  }
}

$target = $null
if ($null -ne $distroKnown) { $target = $distroList | Where-Object { $_.name -eq $Distro } | Select-Object -First 1 }
$distroInstalled = [bool]$target

# -- wsl-version
if (-not $wslPresent) {
  Add-Check wsl-version fail 'could not determine the WSL version -- wsl.exe is absent' `
    'Install WSL first (see the wsl-present action), then re-run.'
} elseif ($target) {
  if ($target.version -eq 2) {
    Add-Check wsl-version pass "$Distro is WSL 2 (state $($target.state))"
  } else {
    Add-Check wsl-version fail "$Distro is WSL $($target.version); WSL2 is the only supported target" `
      "Convert it: wsl --set-version $Distro 2  (this takes a while and needs the disk space), then re-run."
  }
} elseif ($null -ne $distroKnown) {
  # No target distro yet -- the only thing we can judge is what a new install becomes.
  $def = Invoke-WslRaw -WslArgs @('--status') -TimeoutSec 30
  if ($def.reachable -and $def.out -match 'Default Version:\s*(\d+)') {
    if ([int]$Matches[1] -eq 2) {
      Add-Check wsl-version pass "default WSL version is 2, so step 20 will create $Distro as WSL 2"
    } else {
      Add-Check wsl-version fail "default WSL version is $($Matches[1]); a new distro would be WSL 1" `
        'Run: wsl --set-default-version 2  then re-run.'
    }
  } else {
    Add-Check wsl-version warn 'could not determine the default WSL version from wsl --status' `
      'Set it explicitly before installing: wsl --set-default-version 2'
  }
} else {
  Add-Check wsl-version fail 'could not determine the WSL version -- wsl --list --verbose did not return a parseable list' `
    'Run `wsl --list --verbose` by hand and confirm VERSION is 2 for the target distro.'
}

# -- wsl-distro
if ($null -eq $distroKnown) {
  Add-Check wsl-distro fail "could not determine whether $Distro is installed -- wsl --list --verbose did not answer" `
    'Run `wsl --list --verbose` by hand. Preflight will not guess at this.'
} elseif ($target) {
  Add-Check wsl-distro pass "$Distro installed (state $($target.state))"
} else {
  $have = if ($distroList) { ($distroList | ForEach-Object { $_.name }) -join ', ' } else { 'none' }
  $online = Invoke-WslRaw -WslArgs @('--list', '--online') -TimeoutSec 60
  if ($online.reachable -and $online.out -match [regex]::Escape($Distro)) {
    Add-Check wsl-distro warn "$Distro is not installed (installed: $have), but it is available to install" `
      "Step 20 will run: wsl --install -d $Distro --no-launch  -- or do it now and re-run. Everything inside the distro is unverified until then."
  } elseif ($online.reachable) {
    Add-Check wsl-distro fail "$Distro is not installed and not offered by `wsl --list --online` (installed: $have)" `
      "Pick a distro from `wsl --list --online` and pass it as -Distro, e.g. -Distro Ubuntu-24.04."
  } else {
    Add-Check wsl-distro warn "$Distro is not installed (installed: $have) and the online catalogue could not be read -- $($online.err)" `
      "Confirm by hand: wsl --list --online  -- then install with: wsl --install -d $Distro --no-launch"
  }
}

# -- wsl-distro-name: docker-desktop is Docker Desktop's own utility VM, not a target.
if ($Distro -match '^docker-desktop') {
  Add-Check wsl-distro-name fail "-Distro is '$Distro' -- that is Docker Desktop's utility VM, not a usable distro" `
    'Pass a real distro, e.g. -Distro Ubuntu-24.04. Installing into docker-desktop would be destroyed by the next Desktop update.'
} else {
  Add-Check wsl-distro-name pass "-Distro '$Distro' is not a Docker Desktop utility VM"
}

# ---------------------------------------------------------------- the distro probe
# ONE round trip, every fact as key=value, and a SENTINEL at the end. The sentinel is
# the positive control: without it the probe half-ran, and a set of missing keys must
# read as "could not ask", never as a set of empty answers meaning "nothing wrong".
# README: "with a positive control in the same call".

$probeScript = @'
p(){ printf '%s=%s\n' "$1" "$2"; }
p init "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')"
p sysrunning "$(systemctl is-system-running 2>&1 | head -1)"
p wslconf_systemd "$(sed -n 's/^[[:space:]]*systemd[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' /etc/wsl.conf 2>/dev/null | head -1)"
p systemctl_bin "$(command -v systemctl 2>/dev/null)"
p curl_bin "$(command -v curl 2>/dev/null)"
p tar_bin "$(command -v tar 2>/dev/null)"
p gh_bin "$(command -v gh 2>/dev/null)"
p docker_bin "$(command -v docker 2>/dev/null)"
p sock_exists "$([ -S /var/run/docker.sock ] && echo yes || echo no)"
p sock_target "$(readlink -f /var/run/docker.sock 2>/dev/null)"
p dd_mount "$([ -d /mnt/wsl/docker-desktop ] || [ -d /mnt/wsl/docker-desktop-data ] && echo yes || echo no)"
if command -v docker >/dev/null 2>&1; then
  p docker_os "$(timeout 25 docker info --format '{{.OperatingSystem}}' 2>/dev/null | head -1)"
  p docker_ver "$(timeout 25 docker version --format '{{.Server.Version}}' 2>/dev/null | head -1)"
fi
p df_bytes_free "$(df -P -B1 / 2>/dev/null | awk 'NR==2{print $4}')"
p df_fstype "$(stat -f -c %T / 2>/dev/null)"
p ino_total "$(df -P -i / 2>/dev/null | awk 'NR==2{print $2}')"
p ino_free "$(df -P -i / 2>/dev/null | awk 'NR==2{print $4}')"
p v6default "$(ip -6 route show default 2>/dev/null | head -1 | tr -d '\n')"
for h in github.com ghcr.io mirror.gcr.io; do
  a=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u | grep -c '\.')
  q=$(getent ahostsv6 "$h" 2>/dev/null | awk '{print $1}' | sort -u | grep -c ':')
  p "a_$h" "${a:-0}"
  p "aaaa_$h" "${q:-0}"
done
echo __JOGGO_PROBE_OK__
'@

$probe        = @{}
$probeRan     = $false
$probeReason  = 'not attempted'
if ($wslPresent -and $distroInstalled) {
  $pr = Invoke-Wsl -Command $probeScript -InDistro $Distro -TimeoutSec 120
  if (-not $pr.reachable) {
    $probeReason = "wsl.exe did not answer: $($pr.err)"
  } elseif ($pr.out -notmatch [regex]::Escape($ProbeSentinel)) {
    # Half a probe. Every key below is now untrustworthy, and that is the point of
    # the sentinel: a truncated probe must not read as a clean one.
    $probeReason = "the probe did not complete inside $Distro (sentinel missing)"
    if ($pr.err) { $probeReason += "; stderr: $(($pr.err -split "`n")[0])" }
  } else {
    $probeRan = $true
    foreach ($line in ($pr.out -split "`n")) {
      $i = $line.IndexOf('=')
      if ($i -lt 1) { continue }
      $probe[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
  }
} elseif (-not $wslPresent) {
  $probeReason = 'wsl.exe is absent'
} else {
  $probeReason = "$Distro is not installed yet"
}

function Probe([string]$k) { if ($probe.ContainsKey($k)) { return $probe[$k] } else { return $null } }

# A distro that does not exist yet is "the subject is not there", which is a warn with
# the step that creates it. A distro that exists but will not answer is a fail.
$insideSeverity = if ($distroInstalled) { 'fail' } else { 'warn' }
function Inside-Unknown([string]$id, [string]$what, [string]$action) {
  $sev = $insideSeverity
  $why = if ($distroInstalled) { $probeReason } else { "$Distro is not installed yet; step 20 creates it, so this stays unverified until then" }
  Add-Check $id $sev "could not determine $what -- $why" $action
}

# -- wsl-systemd. HARD requirement: svc.sh, systemctl, docker and the slot units all
# depend on it. Asked of the RUNNING distro (PID 1 and is-system-running), not read
# out of /etc/wsl.conf -- the file can say systemd=true while the VM in memory was
# started before the edit and still has /init as PID 1.
if (-not $probeRan) {
  Inside-Unknown 'wsl-systemd' "whether systemd is running in $Distro" `
    "Inside the distro: printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf  then from Windows: wsl --shutdown  then confirm: wsl -d $Distro -u root systemctl is-system-running"
} else {
  $init    = Probe 'init'
  $sysrun  = Probe 'sysrunning'
  $confVal = Probe 'wslconf_systemd'
  $fixSystemd = "Inside the distro: printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf  -- then from Windows: wsl --shutdown  -- then re-run. Without systemd, svc.sh, docker and joggo-slot@ cannot start at all."
  if ([string]::IsNullOrEmpty($init)) {
    Add-Check wsl-systemd fail "could not read PID 1 in $Distro, so systemd cannot be confirmed" $fixSystemd
  } elseif ($init -ne 'systemd') {
    $cn = if ($confVal) { "/etc/wsl.conf says systemd=$confVal" } else { '/etc/wsl.conf sets no systemd key' }
    Add-Check wsl-systemd fail "PID 1 in $Distro is '$init', not systemd ($cn)" $fixSystemd
  } elseif ($sysrun -match '^(running|degraded|starting|maintenance)') {
    $extra = if ($sysrun -eq 'degraded') { ' (degraded: some unit has failed, which is normal here but worth a look)' } else { '' }
    Add-Check wsl-systemd pass "systemd is PID 1 in $Distro and is-system-running reports '$sysrun'$extra"
  } else {
    Add-Check wsl-systemd fail "systemd is PID 1 in $Distro but is-system-running reports '$sysrun'" `
      "Inside the distro: systemctl list-units --state=failed  -- fix or mask the failed units, then re-run. The slot units will not start reliably in this state."
  }
}

# ================================================================ CONFLICTS
# Docker Desktop vs the Docker Engine this installs NATIVE inside the distro. They
# fight: Desktop hijacks the docker socket inside every integrated distro, so the
# slots' dind ends up talking to Desktop's daemon on the host, and Desktop's own
# restarts then take the runner's builds with them. runner-setup.md SS2.3.

# -- docker-desktop-host
try {
  $ddProc = @(Get-Process -Name 'Docker Desktop', 'com.docker.backend', 'com.docker.build' -ErrorAction SilentlyContinue)
  $ddSvc  = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
  $ddVm   = $distroList | Where-Object { $_.name -match '^docker-desktop' }
  $ddVmRunning = @($ddVm | Where-Object { $_.state -eq 'Running' })
  if ($ddProc.Count -gt 0 -or ($ddSvc -and $ddSvc.Status -eq 'Running') -or $ddVmRunning.Count -gt 0) {
    $why = @()
    if ($ddProc.Count -gt 0) { $why += "$($ddProc.Count) Desktop process(es)" }
    if ($ddSvc -and $ddSvc.Status -eq 'Running') { $why += 'com.docker.service running' }
    if ($ddVmRunning.Count -gt 0) { $why += "the $(($ddVmRunning | ForEach-Object { $_.name }) -join '/') VM running" }
    Add-Check docker-desktop-host fail "Docker Desktop is running ($($why -join '; ')) -- it conflicts with the native Docker Engine this installs inside $Distro" `
      'Quit Docker Desktop and stop it starting with Windows (Desktop > Settings > General > uncheck "Start Docker Desktop when you sign in"), then: wsl --shutdown  and re-run. If you intend to keep Desktop, at minimum turn OFF its WSL integration for this distro.'
  } elseif ($ddSvc -or $ddVm) {
    Add-Check docker-desktop-host warn 'Docker Desktop is installed but not running -- it will conflict if it starts' `
      'Disable its autostart (Desktop > Settings > General) and turn off WSL integration for this distro, or uninstall it. A Desktop that wakes up later takes the docker socket with it.'
  } else {
    Add-Check docker-desktop-host pass 'Docker Desktop is not running and not installed'
  }
} catch {
  Add-Check docker-desktop-host warn "could not determine whether Docker Desktop is running -- $($_.Exception.Message)" `
    'Confirm by hand that Docker Desktop is quit and not set to start with Windows before installing.'
}

# -- docker-socket. The host check above is not enough: Desktop can be stopped on the
# host while the distro still has its integration shim on PATH and a socket bound to
# /mnt/wsl. Ask the distro what it is actually talking to.
if (-not $probeRan) {
  Inside-Unknown 'docker-socket' "what provides the docker socket inside $Distro" `
    "Check by hand: wsl -d $Distro -u root bash -c 'readlink -f /var/run/docker.sock; docker info --format {{.OperatingSystem}}'  -- it must NOT say Docker Desktop and must not resolve under /mnt/wsl."
} else {
  $dockerBin = Probe 'docker_bin'
  $sockT     = Probe 'sock_target'
  $ddMount   = Probe 'dd_mount'
  $dockerOs  = Probe 'docker_os'
  $desktopSigns = @()
  if ($dockerOs -and $dockerOs -match 'Docker Desktop') { $desktopSigns += "docker info reports '$dockerOs'" }
  if ($sockT -and $sockT -match '^/mnt/(wsl|host)/') { $desktopSigns += "/var/run/docker.sock resolves to $sockT" }
  if ($ddMount -eq 'yes') { $desktopSigns += '/mnt/wsl/docker-desktop is mounted' }
  if ($desktopSigns.Count -gt 0) {
    Add-Check docker-socket fail "Docker Desktop is providing docker inside $Distro ($($desktopSigns -join '; ')) -- this install needs Docker Engine native in the distro" `
      'Turn off Docker Desktop WSL integration for this distro (Desktop > Settings > Resources > WSL integration), then: wsl --shutdown  and re-run. Step 40 installs the native engine; it cannot while Desktop owns the socket.'
  } elseif (-not $dockerBin) {
    Add-Check docker-socket pass "no docker client inside $Distro and no Desktop integration -- step 40 installs the native engine"
  } elseif ($dockerOs) {
    Add-Check docker-socket pass "docker inside $Distro is native ($dockerOs, server $(Probe 'docker_ver')), socket $sockT"
  } elseif ($sockT) {
    Add-Check docker-socket pass "docker socket inside $Distro is $sockT, no Docker Desktop markers (daemon not answering yet; step 40 starts it)"
  } else {
    Add-Check docker-socket warn "a docker client exists inside $Distro but neither the daemon nor the socket answered, so its provider is undetermined" `
      "Start it and look: wsl -d $Distro -u root bash -c 'systemctl start docker; docker info --format {{.OperatingSystem}}'  -- it must not say Docker Desktop."
  }
}

# ================================================================ NETWORK

$endpoints = @(
  @{ id = 'net-api-github'; url = 'https://api.github.com/zen';   label = 'api.github.com'; why = 'runner registration and the job API' }
  @{ id = 'net-github';     url = 'https://github.com/';          label = 'github.com';    why = 'the runner tarball download in step 60' }
  @{ id = 'net-ghcr';       url = 'https://ghcr.io/v2/';          label = 'ghcr.io';       why = 'the image pushes every build does' }
)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
foreach ($e in $endpoints) {
  $r = Test-Https -Url $e.url -TimeoutSec 15
  if ($r.reachable) {
    # An HTTP status is the point: 401 from ghcr.io/v2/ anonymously IS reachable.
    Add-Check $e.id pass "$($e.label) reachable over HTTPS (HTTP $($r.code))"
  } else {
    Add-Check $e.id fail "$($e.label) is not reachable over HTTPS from the host -- $($r.error)" `
      "Fix outbound HTTPS to $($e.label) (needed for $($e.why)): check DNS, the proxy, and the Windows firewall, then re-run. Test with: Invoke-WebRequest $($e.url) -UseBasicParsing"
  }
}

# -- dns-aaaa
# THE FAULT, confirmed 2026-10-14 (network/filter-aaaa.conf has the measurement): a
# container gets an IPv6 link-local address but the box has no IPv6 route, so glibc's
# AI_ADDRCONFIG stops filtering AAAA and DNS hands every client an address it cannot
# reach. Clients that fall back cleanly survive; trivy (Alpine/musl) and next/font did
# not -- they HANG rather than fail, which is why this is checked before install and
# not debugged after.
if (-not $probeRan) {
  Add-Check dns-aaaa warn "could not determine the AAAA/IPv6-route situation inside $Distro -- $probeReason" `
    "Check after step 20: wsl -d $Distro -u root bash -c 'ip -6 route show default; getent ahostsv6 mirror.gcr.io'  -- AAAA answers with no default route means installing network/filter-aaaa.conf."
} else {
  $v6def   = Probe 'v6default'
  $aNames  = @('github.com', 'ghcr.io', 'mirror.gcr.io')
  $aTotal  = 0; $qTotal = 0; $qHosts = @(); $missing = $false
  foreach ($h in $aNames) {
    $a = Probe "a_$h"; $q = Probe "aaaa_$h"
    if ($null -eq $a -or $null -eq $q) { $missing = $true; continue }
    $ai = 0; [void][int]::TryParse($a, [ref]$ai)
    $qi = 0; [void][int]::TryParse($q, [ref]$qi)
    $aTotal += $ai; $qTotal += $qi
    if ($qi -gt 0) { $qHosts += $h }
  }
  if ($missing) {
    Add-Check dns-aaaa warn "the resolver probe inside $Distro returned incomplete counts, so AAAA behaviour is undetermined" `
      "Re-check by hand: wsl -d $Distro -u root bash -c 'getent ahostsv6 mirror.gcr.io; ip -6 route show default'"
  } elseif ($aTotal -eq 0) {
    # The positive control: no A records either means DNS is broken, not that there
    # happen to be no AAAA records. Reporting "no AAAA problem" here would be exactly
    # the defect this file is written against.
    Add-Check dns-aaaa fail "DNS inside $Distro returned no A records for any of $($aNames -join ', ') -- the resolver is not working, so the AAAA question cannot be answered" `
      "Fix resolution inside the distro first: wsl -d $Distro -u root bash -c 'cat /etc/resolv.conf; getent hosts github.com'. If /etc/resolv.conf is being rewritten, see docs/runner-setup.md."
  } elseif ($qTotal -gt 0 -and -not $v6def) {
    Add-Check dns-aaaa warn "the resolver returns AAAA records ($($qHosts -join ', ')) but $Distro has no IPv6 default route -- build-time fetches and 'docker login ghcr.io' HANG rather than fail" `
      'Install the dnsmasq drop-in: copy network/filter-aaaa.conf to /etc/dnsmasq.d/joggo-filter-aaaa.conf inside the distro, then `dnsmasq --test && systemctl enable --now dnsmasq`, and point the slots at the slot gateway with --dns. Read its header first: it makes dnsmasq a hard dependency for container DNS.'
  } elseif ($qTotal -gt 0) {
    Add-Check dns-aaaa pass "the resolver returns AAAA records and $Distro has an IPv6 default route ($v6def) -- they route"
  } else {
    Add-Check dns-aaaa pass "no AAAA records returned for $($aNames -join ', ') (A records resolve, so the resolver works) -- the hang this guards against cannot occur"
  }
}

# ================================================================ GITHUB

$ghPresent = $false
try { $null = Get-Command gh -ErrorAction Stop; $ghPresent = $true } catch { $ghPresent = $false }
$ghAuthed = $null   # $null = could not ask
if ($ghPresent) {
  # Exit code only. gh auth status prints a masked token and the account name; none of
  # it is echoed, because nothing is gained by putting credentials in a report.
  $ga = Invoke-Exe -File 'gh' -Arguments 'auth status' -TimeoutSec 30
  if ($ga.ran) { $ghAuthed = ($ga.code -eq 0) }
}

# -- github-auth
if ($Token) {
  Add-Check github-auth pass 'a registration token was supplied (held in memory, never printed or persisted)'
} elseif ($ghAuthed -eq $true) {
  Add-Check github-auth pass 'gh CLI is authenticated -- the installer can mint a registration token through it'
} elseif ($ghAuthed -eq $false) {
  Add-Check github-auth fail 'gh CLI is installed but not authenticated, and no -Token was supplied' `
    'Either run: gh auth login  -- or mint a registration token by hand and pass it: -Token $env:JOGGO_TOKEN (org: https://github.com/organizations/<org>/settings/actions/runners/new). The token is short-lived (~1h) and must never be committed or stored.'
} elseif ($ghPresent) {
  Add-Check github-auth fail 'could not determine the gh CLI auth state (gh did not run), and no -Token was supplied' `
    'Run `gh auth status` by hand, or pass -Token with a freshly minted registration token.'
} else {
  Add-Check github-auth fail 'no registration token supplied and no gh CLI to mint one' `
    'Mint a registration token (org: https://github.com/organizations/<org>/settings/actions/runners/new, repo: Settings > Actions > Runners > New) and pass it as -Token. It expires in ~1 hour and must never be committed or stored.'
}

# -- github-scope. Runner groups -- the actual security boundary in README Phase 2 --
# are an ORGANISATION feature. A personal account has no group page at all, so an
# org-scoped install against a user account registers a runner nothing can constrain.
if (-not $Scope) {
  Add-Check github-scope warn 'no -Scope given, so the registration target was not checked' `
    'Pass -Scope org -Org <organisation>, or -Scope repo -Repo owner/name (-Scope repo is the personal-account path), and re-run preflight.'
} elseif ($Scope -eq 'repo') {
  Add-Check github-scope pass "-Scope repo -Repo $Repo -- repo-level registration, which is also the personal-account path"
} else {
  $acctType = $null
  if ($ghAuthed -eq $true) {
    $q = Invoke-Exe -File 'gh' -Arguments "api /users/$Org --jq .type" -TimeoutSec 30
    if ($q.ran -and $q.code -eq 0 -and $q.out) { $acctType = $q.out.Trim() }
  }
  if ($acctType -eq 'Organization') {
    Add-Check github-scope pass "$Org is an organisation -- runner groups are available, and that group page is the whole threat model (README Phase 2)"
  } elseif ($acctType -eq 'User') {
    Add-Check github-scope warn "-Scope org was asked for, but '$Org' is a personal account -- runner groups are an organisation feature and do not exist there" `
      "Use the personal-account path instead: -Scope repo -Repo $Org/<repo>. An org-scoped runner on a user account has no runner group, so nothing constrains which repositories reach it."
  } else {
    $why = if ($ghAuthed -eq $true) { 'the API query failed' } elseif ($ghPresent) { 'gh is not authenticated' } else { 'gh is not installed' }
    Add-Check github-scope warn "could not determine whether '$Org' is an organisation or a personal account ($why) -- runner groups are an organisation feature" `
      "Confirm with: gh api /users/$Org --jq .type  -- if it says User, use -Scope repo -Repo $Org/<repo> instead. Then create the runner group (Settings > Actions > Runner groups): 'Allow public repositories' MUST stay unchecked."
  }
}

# ================================================================ TOOLS

# -- tools-powershell: the guard, the sampler and the keepalive all run as scheduled
# tasks, and something has to execute them.
$psHost = $null
foreach ($c in @('pwsh', 'powershell')) {
  try { $psHost = (Get-Command $c -ErrorAction Stop).Source; break } catch {}
}
if ($psHost) {
  Add-Check tools-powershell pass "scheduled tasks can run: $psHost"
} else {
  Add-Check tools-powershell fail 'neither pwsh nor powershell was found on PATH' `
    'Scheduled tasks for the guard, the sampler and the keepalive need one. Confirm %SystemRoot%\System32\WindowsPowerShell\v1.0 is on PATH, or install PowerShell 7.'
}

# -- tools-distro: curl and tar are what step 60 downloads and unpacks the runner with.
if (-not $probeRan) {
  Inside-Unknown 'tools-distro' "whether curl and tar exist inside $Distro" `
    "After step 20: wsl -d $Distro -u root bash -c 'apt-get update && apt-get install -y curl tar'"
} else {
  $missingT = @()
  if (-not (Probe 'curl_bin')) { $missingT += 'curl' }
  if (-not (Probe 'tar_bin'))  { $missingT += 'tar' }
  if ($missingT.Count -eq 0) {
    Add-Check tools-distro pass "curl and tar present inside $Distro"
  } else {
    Add-Check tools-distro fail "missing inside $Distro`: $($missingT -join ', ') -- step 60 downloads and unpacks the runner with them" `
      "Run: wsl -d $Distro -u root bash -c 'apt-get update && apt-get install -y $($missingT -join ' ')'"
  }
}

# -- tools-gh: only when the caller asked for the CLI path. Checking it otherwise
# would fail boxes that are perfectly fine with -Token.
if ($UseGhCli) {
  if (-not $probeRan) {
    Inside-Unknown 'tools-gh' "whether gh exists inside $Distro (-UseGhCli was requested)" `
      'See https://github.com/cli/cli/blob/trunk/docs/install_linux.md for the apt repository, then re-run.'
  } elseif (Probe 'gh_bin') {
    Add-Check tools-gh pass "gh present inside $Distro ($(Probe 'gh_bin'))"
  } elseif ($ghPresent) {
    Add-Check tools-gh warn "-UseGhCli was requested; gh is on the Windows host but not inside $Distro" `
      "Install it in the distro if a step needs it there, or drop -UseGhCli and pass -Token. Host gh is reachable from the distro only with interop enabled, and this repo's wsl.conf sets appendWindowsPath=false."
  } else {
    Add-Check tools-gh fail "-UseGhCli was requested but gh is on neither the host nor inside $Distro" `
      'Install gh (https://cli.github.com), run `gh auth login`, or drop -UseGhCli and pass -Token instead.'
  }
}

# ================================================================ DISK INSIDE THE DISTRO

# -- distro-disk
$requiredGB = if ($Slots -gt 1) { $MinDistroGB + 10 * ($Slots - 1) } else { $MinDistroGB }
if (-not $probeRan) {
  Inside-Unknown 'distro-disk' "free space inside $Distro" `
    "After step 20: wsl -d $Distro -u root df -h /  -- need at least $MinDistroGB GB for the runner, the dind image and the slot work volumes."
} else {
  $bytesRaw = Probe 'df_bytes_free'
  $bytes = 0L
  if (-not [string]::IsNullOrEmpty($bytesRaw)) { [void][long]::TryParse($bytesRaw, [ref]$bytes) }
  if ($bytes -le 0) {
    Add-Check distro-disk fail "could not read free space inside $Distro (df returned '$bytesRaw')" `
      "Check by hand: wsl -d $Distro -u root df -P -B1 /  -- at least $MinDistroGB GB must be free."
  } else {
    $gb = [math]::Round($bytes / 1GB, 1)
    $fs = Probe 'df_fstype'
    if ($gb -lt $MinDistroGB) {
      Add-Check distro-disk fail "$gb GB free on / inside $Distro -- below the $MinDistroGB GB minimum" `
        "Reclaim it: wsl -d $Distro -u root docker system prune -af  -- and note the VHDX does not shrink on its own (see the vhdx check). The dind image plus the slot work volumes do not fit under $MinDistroGB GB."
    } elseif ($gb -lt $requiredGB) {
      Add-Check distro-disk warn "$gb GB free on / inside $Distro -- above the $MinDistroGB GB minimum but below the $requiredGB GB $Slots slots want" `
        "Reclaim with: wsl -d $Distro -u root docker system prune -af  -- or install fewer slots."
    } else {
      Add-Check distro-disk pass "$gb GB free on / inside $Distro (fs $fs, need $requiredGB GB for $(if($Slots -gt 0){"$Slots slots"}else{'the default slot count'}))"
    }
  }
}

# -- distro-inodes. Inodes exhaust INDEPENDENTLY of bytes and the symptom reads as
# "disk full" -- ENOSPC with plenty of gigabytes free. Docker layers are millions of
# small files, so this is the end a build cache hits first. It only shows up if you
# look, which is why it is its own check and not a line in the one above.
if (-not $probeRan) {
  Inside-Unknown 'distro-inodes' "inode headroom inside $Distro" `
    "After step 20: wsl -d $Distro -u root df -i /  -- bytes and inodes exhaust separately and both read as 'disk full'."
} else {
  $itRaw = Probe 'ino_total'; $ifRaw = Probe 'ino_free'
  $it = 0L; $if_ = 0L
  if (-not [string]::IsNullOrEmpty($itRaw)) { [void][long]::TryParse($itRaw, [ref]$it) }
  if (-not [string]::IsNullOrEmpty($ifRaw)) { [void][long]::TryParse($ifRaw, [ref]$if_) }
  $fs = Probe 'df_fstype'
  if ($it -le 0) {
    # btrfs, xfs with dynamic inodes and overlay report 0 or '-'. That is "no inode
    # limit to measure", not "no inodes free" -- and it is not a pass either, because
    # nothing was measured.
    Add-Check distro-inodes warn "inode count is not reportable on / inside $Distro (fs $fs, df -i returned total='$itRaw') -- headroom undetermined" `
      "If the filesystem allocates inodes dynamically (btrfs, xfs) there is nothing to exhaust; confirm with: wsl -d $Distro -u root bash -c 'stat -f /; df -i /'"
  } else {
    $usedPct = [math]::Round((($it - $if_) / [double]$it) * 100, 1)
    $prune = "Reclaim with: wsl -d $Distro -u root docker system prune -af --volumes  -- docker layers are millions of small files and are almost always the cause."
    if ($usedPct -ge 95 -or $if_ -lt 100000) {
      Add-Check distro-inodes fail "inodes on / inside $Distro are $usedPct% used, $if_ free of $it -- builds will fail with ENOSPC while df -h still looks fine" $prune
    } elseif ($usedPct -ge 85 -or $if_ -lt 500000) {
      Add-Check distro-inodes warn "inodes on / inside $Distro are $usedPct% used, $if_ free of $it -- tight" $prune
    } else {
      Add-Check distro-inodes pass "inodes on / inside $Distro are $usedPct% used, $if_ free of $it"
    }
  }
}

# -- vhdx-drive. The contract names the system drive, but on this box the distro's
# VHDX lives on another one -- and the VHDX is where every byte of the install
# actually lands. A 40 GB check on C: says nothing about it, in either direction.
try {
  $basePath = $null
  foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss')) {
    if (-not (Test-Path $root)) { continue }
    foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
      $pp = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
      if ($pp -and $pp.DistributionName -eq $Distro) { $basePath = [string]$pp.BasePath; break }
    }
    if ($basePath) { break }
  }
  if (-not $basePath) {
    if ($distroInstalled) {
      Add-Check vhdx-drive warn "$Distro is installed but its VHDX location could not be read from the registry, so the drive that actually holds the install is unchecked" `
        'Find it with: (Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss | ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object DistributionName -eq ' + "'$Distro'" + ').BasePath  -- then confirm that drive has headroom.'
    } else {
      Add-Check vhdx-drive warn "$Distro is not installed, so its VHDX will be created on $sysDrive unless step 20 is told otherwise" `
        "Ensure $sysDrive has room, or import the distro onto a roomier drive with: wsl --import <name> <dir on that drive> <rootfs.tar>"
    }
  } else {
    $clean = $basePath -replace '^\\\\\?\\', ''
    $dl = $null
    if ($clean -match '^([A-Za-z]):') { $dl = $Matches[1].ToUpper() + ':' }
    if (-not $dl) { throw "could not read a drive letter from BasePath '$clean'" }
    $vd = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$dl'" -ErrorAction Stop
    if (-not $vd) { throw "no logical disk for $dl" }
    $vfree = [math]::Round($vd.FreeSpace / 1GB, 1)
    if ($vfree -ge $requiredGB) {
      Add-Check vhdx-drive pass "$Distro's VHDX is on $dl ($clean) with $vfree GB free -- that is the drive the install actually consumes"
    } else {
      Add-Check vhdx-drive fail "$Distro's VHDX is on $dl ($clean) with only $vfree GB free -- below the $requiredGB GB the install needs" `
        "Free space on $dl, or move the distro: wsl --export $Distro <tar> then wsl --unregister $Distro then wsl --import $Distro <dir on a roomier drive> <tar>. Note a VHDX never shrinks on its own; pruning inside the distro frees distro space, not $dl."
    }
  }
} catch {
  Add-Check vhdx-drive warn "could not determine which drive holds $Distro's VHDX -- $($_.Exception.Message)" `
    'Locate it under HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss (BasePath) and confirm that drive has headroom. Pruning inside the distro does not shrink the VHDX.'
}

# -- win-features. Get-WindowsOptionalFeature needs admin, so when it cannot be asked
# the fallback is a PROOF rather than an assumption: if the distro answered a command,
# both features are enabled by construction. If neither path is available this says so
# instead of passing.
$featureNames = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
$featState = $null
if ($isAdmin -eq $true) {
  try {
    $featState = @{}
    foreach ($f in $featureNames) {
      $r = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
      $featState[$f] = [string]$r.State
    }
  } catch { $featState = $null }
}
if ($featState) {
  $off = @($featureNames | Where-Object { $featState[$_] -ne 'Enabled' })
  if ($off.Count -eq 0) {
    Add-Check win-features pass "WSL and VirtualMachinePlatform optional features are Enabled"
  } else {
    $desc = ($off | ForEach-Object { "$_=$($featState[$_])" }) -join ', '
    Add-Check win-features fail "required Windows optional features are not enabled: $desc" `
      "Run elevated: dism.exe /online /enable-feature /featurename:$($off -join ' /featurename:') /all /norestart  -- then REBOOT and re-run. Step 10 will do this too, but it costs you a reboot mid-install."
  }
} elseif ($probeRan) {
  Add-Check win-features pass "$Distro executed a command, which both optional features are required for -- proven by use rather than by query (not elevated enough to read the feature list)"
} elseif ($isAdmin -eq $true) {
  Add-Check win-features fail 'could not read the Windows optional feature states even though this session is elevated' `
    "Check by hand: dism.exe /online /get-featureinfo /featurename:VirtualMachinePlatform  -- both WSL and VirtualMachinePlatform must be Enabled."
} else {
  Add-Check win-features fail "could not determine whether the WSL and VirtualMachinePlatform features are enabled -- not elevated, and no distro answered to prove it by use" `
    'Re-run elevated so the feature list can be read, or enable them now: dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /featurename:VirtualMachinePlatform /all /norestart  then reboot.'
}

# ================================================================ REPORT

$blocking = @($script:Checks | Where-Object { $_.status -eq 'fail' }).Count
$warnings = @($script:Checks | Where-Object { $_.status -eq 'warn' }).Count
$passes   = @($script:Checks | Where-Object { $_.status -eq 'pass' }).Count
$ok       = ($blocking -eq 0)

if ($Json) {
  $report = [ordered]@{
    ok       = $ok
    checks   = @($script:Checks)
    blocking = $blocking
    warnings = $warnings
  }
  ([pscustomobject]$report) | ConvertTo-Json -Depth 5
} else {
  Write-Host ''
  $verdict = if ($ok) { 'READY' } else { 'BLOCKED' }
  Write-Host ("{0} checks: {1} pass, {2} warn, {3} fail -- {4}" -f $script:Checks.Count, $passes, $warnings, $blocking, $verdict)
  if (-not $ok) {
    Write-Host "Nothing has been changed. Fix the FAIL items above and re-run; exit 3."
  } elseif ($warnings -gt 0) {
    Write-Host "Nothing blocks the install. Read the $warnings warning(s) first -- each one is something that has bitten before."
  }
}

exit $(if ($ok) { 0 } else { 3 })
