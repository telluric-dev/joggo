param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 99-verify — prove the install, then say what to do next.
#
# PROVE, DO NOT ASSERT. Every line below is a reading taken after the fact, from
# the instrument that would actually notice if the thing were broken: the
# scheduler's own record for the tasks, systemd for the units, the listener's own
# log for "is this runner online", GitHub's API as a second instrument where it
# is available. Anything that cannot be read fails the step rather than passing
# quietly — see slots/slot-pause.sh's job_in_flight comment for the local
# cautionary tale.
#
# AND IT ENDS WITH THE NEXT ACTION. An install that finishes without the user
# knowing what to paste into a repo is not finished.

Step-Header $Ctx '99-verify'

$labelList = @(($Cfg.labels -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$runsOn    = '[' + ($labelList -join ', ') + ']'
$owner     = $Cfg.org
if($Cfg.scope -eq 'repo'){ $owner = ($Cfg.repo -split '/')[0] }

function Show-NextAction {
  Write-JLine $Ctx ''
  Write-JLine $Ctx '=============================== WHAT TO DO NEXT ==============================='
  Write-JLine $Ctx ''
  Write-JLine $Ctx '  Paste this into a repository that may use this runner, as'
  Write-JLine $Ctx '  .github/workflows/joggo-smoke.yml, then push. It should go green in under a'
  Write-JLine $Ctx '  minute and consumes zero GitHub-hosted minutes.'
  Write-JLine $Ctx ''
  Write-JLine $Ctx '    name: joggo smoke'
  Write-JLine $Ctx '    on:'
  Write-JLine $Ctx '      workflow_dispatch:'
  Write-JLine $Ctx '      push:'
  Write-JLine $Ctx '        branches: [main]'
  Write-JLine $Ctx ''
  Write-JLine $Ctx '    jobs:'
  Write-JLine $Ctx '      smoke:'
  Write-JLine $Ctx ("        runs-on: " + $runsOn)
  Write-JLine $Ctx '        steps:'
  Write-JLine $Ctx '          - run: echo "ran on $(hostname) as $(whoami)"'
  Write-JLine $Ctx '          - run: docker run --rm hello-world'
  Write-JLine $Ctx ''
  if($Cfg.scope -eq 'repo'){
    Write-JLine $Ctx ("  This registration is scoped to ONE repository: " + $Cfg.repo)
    Write-JLine $Ctx '  Only that repo can use it. That is the personal-account path and it is'
    Write-JLine $Ctx '  correct: runner groups are an organisation-only feature, so there is no'
    Write-JLine $Ctx '  group to put a personal runner in. For a second repo, register again with'
    Write-JLine $Ctx '  -Repo other/repo and a fresh token.'
  } else {
    Write-JLine $Ctx ("  This registration is org-wide (" + $Cfg.org + "), so ANY repo you allow can use it.")
    Write-JLine $Ctx '  DO THIS BEFORE POINTING ANYTHING AT IT — the runner group page is the whole'
    Write-JLine $Ctx '  threat model, because a self-hosted runner executes whatever an allowed'
    Write-JLine $Ctx '  repository tells it to, on your hardware, inside your network:'
    Write-JLine $Ctx ("    https://github.com/organizations/" + $Cfg.org + "/settings/actions/runner-groups")
    Write-JLine $Ctx '      Allow public repositories    MUST stay unchecked'
    Write-JLine $Ctx '      Repository access            private repos only, chosen explicitly'
    Write-JLine $Ctx '      Fork PR workflows            require approval for outside collaborators'
  }
  Write-JLine $Ctx ''
  Write-JLine $Ctx '  For image builds, the reusable workflow keeps a consuming repo to a few lines'
  Write-JLine $Ctx ('  (it needs THIS repo pushed to ' + $owner + '/joggo first):')
  Write-JLine $Ctx ''
  Write-JLine $Ctx '    jobs:'
  Write-JLine $Ctx '      build:'
  Write-JLine $Ctx ("        uses: " + $owner + "/joggo/.github/workflows/build-and-push.yml@main")
  Write-JLine $Ctx '        with:'
  Write-JLine $Ctx '          image-name: my-service'
  Write-JLine $Ctx '          dockerfile: ./Dockerfile'
  Write-JLine $Ctx '        permissions:'
  Write-JLine $Ctx '          contents: read'
  Write-JLine $Ctx '          packages: write       # REQUIRED for GITHUB_TOKEN to push to GHCR'
  Write-JLine $Ctx ''
  Write-JLine $Ctx '  Day to day:'
  Write-JLine $Ctx ("    wsl -d " + $Cfg.distro + " -u root joggo-slots-status            # what every slot is doing")
  Write-JLine $Ctx ("    wsl -d " + $Cfg.distro + " -u root joggo-pause status --slot 1   # one slot, in detail")
  Write-JLine $Ctx ("    powershell -File `"" + (Join-Path $Ctx.BinDir 'wsl-mem-guard.ps1') + "`" -Status")
  Write-JLine $Ctx ("    Get-ScheduledTaskInfo -TaskName joggo-mem-guard       # LastTaskResult should be 0")
  Write-JLine $Ctx ''
  Write-JLine $Ctx '==============================================================================='
}

if($Ctx.DryRun){
  Plan $Ctx 'would verify, each against the instrument that would notice a fault:'
  Plan $Ctx '  config file present and containing NO token (read back and grepped)'
  Plan $Ctx '  systemd running/degraded; docker native (not Desktop) and answering with a server version'
  Plan $Ctx '  both slot images present locally'
  Plan $Ctx '  every slot has its OWN registration (a slot is a registration, not a unit instance)'
  Plan $Ctx '  slot units enabled; and ONLINE proved by "Listening for Jobs" in the listener log, waiting up to 180s'
  Plan $Ctx '  GitHub asked directly as a second instrument when gh is authenticated'
  if($Cfg.filterAaaa){ Plan $Ctx '  the AAAA filter, by differential test with the upstream resolver as positive control' }
  Plan $Ctx '  the scheduled tasks: registered, enabled, SYSTEM, repeating, and with a successful run on record'
  Plan $Ctx 'then print the workflow YAML to paste into a consuming repo'
  Show-NextAction
  Add-Result $Ctx 'verify' 'pass' 'dry run' ''
  return
}

$fails = 0
function V-Ok   { param([string]$m) Write-JLine $Ctx ("  PASS  " + $m) }
function V-Fail { param([string]$m) Write-JLine $Ctx ("  FAIL  " + $m); $script:fails++ }
function V-Warn { param([string]$m) Write-JLine $Ctx ("  WARN  " + $m) }

# ---- the config file, and the token that must not be in it ----
if(Test-Path $Ctx.ConfigPath){
  $raw = Get-Content -Path $Ctx.ConfigPath -Raw
  if($raw -match 'registrationToken' -or ($Token -and $raw.Contains($Token))){
    V-Fail ("the token is present in " + $Ctx.ConfigPath + " — it must never be persisted")
  } else {
    V-Ok ("config at " + $Ctx.ConfigPath + " contains no token (grepped, including for the literal token value)")
  }
} else {
  V-Fail ("no config at " + $Ctx.ConfigPath)
}

# ---- everything inside the distro ----
$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'verify' -TimeoutSec 900
if($r.timedOut){
  V-Fail 'the in-distro verification did not finish within its budget — nothing about the runner can be concluded from that'
} elseif(-not $r.ok){
  V-Fail 'the in-distro verification reported failures (see the PASS/FAIL lines above)'
}

# ---- the scheduled tasks ----
$wanted = New-Object System.Collections.ArrayList
if($Cfg.guard)      { [void]$wanted.Add(@{ n='joggo-mem-guard';    every=[int]$Cfg.guardIntervalMin; mustHaveRun=$true  }) }
if($Cfg.sampler)    { [void]$wanted.Add(@{ n='joggo-mem-watch';    every=5;                          mustHaveRun=$true  }) }
if($Cfg.startOnBoot){ [void]$wanted.Add(@{ n='joggo-wsl-keepalive'; every=0;                         mustHaveRun=$false }) }

foreach($w in $wanted){
  $t = Get-ScheduledTask -TaskName $w.n -ErrorAction SilentlyContinue
  if(-not $t){ V-Fail ("scheduled task '" + $w.n + "' does not exist"); continue }
  if($t.State -eq 'Disabled'){ V-Fail ("scheduled task '" + $w.n + "' is DISABLED"); continue }
  if($t.Principal.UserId -notmatch '(?i)(SYSTEM|S-1-5-18)'){
    V-Fail ("scheduled task '" + $w.n + "' runs as " + $t.Principal.UserId + ", not SYSTEM — it would not run with nobody logged on"); continue
  }
  $info = Get-ScheduledTaskInfo -TaskName $w.n -ErrorAction SilentlyContinue
  if($null -eq $info){ V-Fail ("could not determine whether '" + $w.n + "' has ever run"); continue }

  if(-not $w.mustHaveRun){
    # The keepalive is correct when it is RUNNING, not when it has completed.
    if($t.State -eq 'Running'){ V-Ok ("'" + $w.n + "' is Running as SYSTEM — the correct steady state for a task that holds the VM open") }
    else { V-Fail ("'" + $w.n + "' is '" + $t.State + "'; it must be Running or the WSL2 VM will shut down when you log off") }
    continue
  }
  if($info.LastTaskResult -eq 267011 -or -not $info.LastRunTime){
    V-Fail ("'" + $w.n + "' is scheduled but has NEVER run — scheduled is not running")
  } elseif($info.LastTaskResult -eq 0 -or $info.LastTaskResult -eq 267009){
    V-Ok ("'" + $w.n + "' last ran " + $info.LastRunTime + ", result " + $info.LastTaskResult + ", next " + $info.NextRunTime)
  } else {
    V-Fail ("'" + $w.n + "' last ran " + $info.LastRunTime + " and FAILED with result " + $info.LastTaskResult)
  }
}

# The sampler's output is the thing it exists for, so check the artefact too.
if($Cfg.sampler){
  $csv = Join-Path $Ctx.DataDir 'mem-watch.csv'
  if(Test-Path $csv){
    $rows = @(Get-Content $csv).Count
    if($rows -ge 2){ V-Ok ("mem-watch.csv has " + $rows + " rows — the sampler is producing the trail, not just exiting 0") }
    else { V-Fail 'mem-watch.csv exists but has no samples in it' }
  } else {
    V-Fail ("no " + $csv + " — the sampler task ran but wrote nothing")
  }
}

Write-JLine $Ctx ''
if($fails -gt 0){
  Write-JLine $Ctx ("  " + $fails + " check(s) failed or could not be determined. The install is NOT complete.")
  Add-Result $Ctx 'verify' 'fail' "$fails verification check(s) failed" 'fix each FAIL line above and re-run install.ps1'
  Fail -Ctx $Ctx -Problem "$fails verification check(s) failed or could not be determined" `
    -Action 'each FAIL line above names what to look at. Re-running the installer is safe and converges.' -Code 1
}

Ok $Ctx 'every check passed, and each was read back from the thing that would notice a fault.'
Add-Result $Ctx 'verify' 'pass' 'all verification checks passed' ''
Show-NextAction
