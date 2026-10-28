# slots.ps1 -- how many runner slots this box should run, and why.
#
# ONE implementation, dot-sourced by both install/config.ps1 (the default and the wizard)
# and install/preflight.ps1 (the check). There used to be two, and they disagreed: the
# installer recommended 1 slot under 12 GB and 2 otherwise, while preflight said 1 / 2 / 3
# with a third slot above 32 GB -- a tier the installer's own comment called "inventing
# evidence for a configuration nothing here has run".
#
# THE LIMIT IS THE WSL VM, NOT THE MACHINE. Every slot runs inside the one WSL2 VM, and that
# VM is capped by .wslconfig's [wsl2] memory=, which defaults to half of physical RAM. A
# 32 GB box with memory=8GB has the room of a 16 GB one. So this reads the cap, and only
# falls back to half of RAM when .wslconfig does not set it.
#
# THE NUMBERS, measured on a 16 GB box (WSL cap 8 GB, two slots), 2026-10-28:
#
#   VM baseline, both slots held, nothing running   592 MB used
#   runner container, during a job                  1.25 GB   (docker stats)
#   dind, idle                                      330 MB
#   an image build through dind                     ~3.8 GB of Windows-side memory at peak
#
# So a slot is budgeted at 3 GB -- the job plus its daemon under a build, which is the
# common workload here -- on top of a 1 GB VM baseline. That gives 1 slot at a 4 GB cap
# (8 GB machines), 2 at 8 GB (16 GB machines), and more above.
#
# AND THEN IT STOPS AT TWO, deliberately. Memory is not what runs out next. With a SINGLE job
# running, 30-40% of tasks on that 16 GB box were stalled on disk IO (docs/adding-a-slot.md),
# so a third slot on the same disk adds contention before it adds throughput -- and nothing
# here has measured three. Where memory would fit more, the advice says so and says why it
# still recommends two, and -Slots takes whatever the operator decides.

$script:JoggoVmBaseMB  = 1024
$script:JoggoSlotPeakMB = 3072
$script:JoggoMeasuredMaxSlots = 2

# The WSL VM's memory cap in MB, and where the number came from.
function Get-JoggoWslMemMB {
  param([int]$RamMB, [string]$WslConfigPath = (Join-Path $env:USERPROFILE '.wslconfig'))
  $half = [int][math]::Floor($RamMB / 2)
  if(-not (Test-Path $WslConfigPath)){ return @{ mb = $half; source = 'WSL default: half of RAM (no .wslconfig)' } }
  $section = ''
  foreach($line in [IO.File]::ReadAllLines($WslConfigPath)){
    $t = ($line -replace '[#;].*$','').Trim()
    if($t -match '^\[(.+)\]$'){ $section = $matches[1].Trim().ToLower(); continue }
    if($section -eq 'wsl2' -and $t -match '^memory\s*=\s*(\d+(?:\.\d+)?)\s*([KMGT]?B?)$'){
      $n = [double]$matches[1]; $u = $matches[2].ToUpper().TrimEnd('B')
      $mb = switch($u){ 'K' { $n/1024 } 'M' { $n } 'G' { $n*1024 } 'T' { $n*1024*1024 } default { $n/1MB } }
      return @{ mb = [int][math]::Floor($mb); source = ".wslconfig memory=$($matches[1])$($matches[2])" }
    }
  }
  @{ mb = $half; source = 'WSL default: half of RAM (.wslconfig sets no memory=)' }
}

# The recommendation: slots, how many would fit by memory alone, and a sentence saying why.
function Get-JoggoSlotAdvice {
  param([int]$RamMB, [string]$WslConfigPath = (Join-Path $env:USERPROFILE '.wslconfig'))
  $w = Get-JoggoWslMemMB -RamMB $RamMB -WslConfigPath $WslConfigPath
  $fit = [int][math]::Floor(($w.mb - $script:JoggoVmBaseMB) / $script:JoggoSlotPeakMB)
  if($fit -lt 1){ $fit = 1 }
  $rec = [math]::Min($fit, $script:JoggoMeasuredMaxSlots)
  $gb = [math]::Round($w.mb / 1024, 1)
  $why = if($fit -gt $script:JoggoMeasuredMaxSlots){
    "$rec recommended. The $gb GB WSL cap ($($w.source)) would fit $fit by memory, but the disk saturates first and nothing above $($script:JoggoMeasuredMaxSlots) has been measured; add slots one at a time and watch the guard log and job times."
  } elseif($rec -eq 1){
    "1 recommended. The $gb GB WSL cap ($($w.source)) holds one job and its Docker daemon through an image build (~3 GB) on a 1 GB base; a second slot would push the guard into holding under load."
  } else {
    "$rec recommended. The $gb GB WSL cap ($($w.source)) holds $rec jobs at ~3 GB each through an image build, on a 1 GB base. This is the measured configuration."
  }
  @{ slots = $rec; fit = $fit; wslMB = $w.mb; source = $w.source; why = $why }
}
