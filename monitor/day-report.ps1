<#
.SYNOPSIS
  Render the CI day log — every job that finished today — as a self-contained HTML page.

.DESCRIPTION
  The "CI day" runs 03:00 -> 03:00 local (Asia/Jerusalem, UTC+3), which is exactly
  00:00Z -> 00:00Z. So the day boundary is simply the UTC date, and the file resets
  itself at 3am local with no scheduled wipe: runs from a previous UTC date are
  never collected, so the page is empty again the moment the date rolls.

  Successes get one compact row. Failures get a detailed card: the failed job, the
  error lines pulled from the run log, the commit, and a root-cause note if one has
  been written for that run (see -Note).

  Root-cause prose is not something a script can invent. The renderer supplies the
  evidence; an operator (or an agent on a schedule) adds the diagnosis with -Note.

.EXAMPLE
  pwsh monitor/day-report.ps1
  pwsh monitor/day-report.ps1 -Note 31151058626 -Text "Lockfile not regenerated after adding the vendored chrome tarball."
#>
[CmdletBinding()]
param(
  # Append/replace the root-cause note for a run id, then exit without re-rendering.
  [string] $Note,
  [string] $Text,
  # Where the rendered page lands.
  [string] $OutFile = "$env:USERPROFILE\.claude\ci-day\ci-day.html",
  [string] $StateDir = "$env:USERPROFILE\.claude\ci-day",
  # How far back to look for failures that are still open (never superseded by a pass).
  [int] $LookbackDays = 14,
  # Repos to watch. Defaults to everything that has ever run on marathon.
  [string[]] $Repos = @(
    'example-org/appthree', 'example-org/appthree', 'example-org/appthree',
    'example-org/appthree', 'example-org/appthree', 'example-org/appthree',
    'example-org/appthree', 'example-org/appone', 'example-org/appfour',
    'example-org/chui-docker', 'example-org/appsix'
  )
)

$ErrorActionPreference = 'Stop'

# gh writes to stderr for the ordinary "this run kept no log" case (an outage-killed
# run has none). Under -ErrorActionPreference Stop that aborts the whole render, so
# every gh call goes through here and a failure just yields $null.
function Invoke-Gh {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]] $GhArgs)
  # No 2>$null: redirecting a native command's stderr in PS 5.1 turns each line into
  # a NativeCommandError and poisons the exit status. Let gh's stderr through and
  # judge it by its exit code instead.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & gh @GhArgs
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) { return $null }
  return $out
}

# `gh run list` hands back GitHub's own displayTitle, which is cut at ~72 chars with
# an ellipsis — exactly where a commit subject stops being informative. When we see
# that cut, fetch the commit and use its real subject line.
$titleCache = @{}
function Resolve-Title {
  param([string] $Repo, [string] $Sha, [string] $Title)
  if ($Title -notmatch '…\s*$') { return $Title }
  $key = "$Repo/$Sha"
  if ($titleCache.ContainsKey($key)) { return $titleCache[$key] }
  $full = $Title
  $raw = Invoke-Gh api "repos/example-org/$Repo/commits/$Sha"
  if ($raw) {
    $msg = ($raw | ConvertFrom-Json).commit.message
    if ($msg) { $full = ($msg -split "`n")[0].Trim() }
  }
  $titleCache[$key] = $full
  return $full
}

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force $StateDir | Out-Null }
$notesPath = Join-Path $StateDir 'notes.json'

# ---- -Note mode: record a diagnosis and stop -------------------------------
if ($Note) {
  if (-not $Text) { throw "-Note requires -Text" }
  $notes = @{}
  if (Test-Path $notesPath) {
    (Get-Content $notesPath -Raw | ConvertFrom-Json).PSObject.Properties |
      ForEach-Object { $notes[$_.Name] = $_.Value }
  }
  $notes[$Note] = $Text
  $notes | ConvertTo-Json -Depth 3 | Out-File $notesPath -Encoding utf8
  Write-Host "noted $Note"
  return
}

$notes = @{}
if (Test-Path $notesPath) {
  (Get-Content $notesPath -Raw | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $notes[$_.Name] = $_.Value }
}

# ---- collect runs ----------------------------------------------------------
# Today's finished runs are the day log. On top of that, a failure from an earlier
# day STAYS on the page until a later run of the same repo+workflow passes — a red
# pipeline shouldn't disappear at 3am just because the clock rolled.
$dayStart = [datetime]::UtcNow.Date                     # 00:00Z == 03:00 local
$since = $dayStart.AddDays(-$LookbackDays)
$all = @()

foreach ($repo in $Repos) {
  # The --json list MUST stay quoted: unquoted, PowerShell parses the commas as an
  # array literal and splatting rejoins them with spaces, which gh rejects.
  $raw = Invoke-Gh run list -R $repo --limit 60 --json 'databaseId,workflowName,displayTitle,status,conclusion,createdAt,updatedAt,headSha,event,url'
  if (-not $raw) { continue }
  foreach ($r in ($raw | ConvertFrom-Json)) {
    $created = [datetime]::Parse($r.createdAt).ToUniversalTime()
    if ($created -lt $since) { continue }
    # Unfinished runs are kept: a job sitting in the queue behind a busy runner is
    # exactly what you want to see, and it never shows up as a completed run.
    $all += [pscustomobject]@{
      Status   = $r.status
      Repo     = $repo.Split('/')[-1]
      Id       = $r.databaseId
      Workflow = $r.workflowName
      Title    = $r.displayTitle
      Result   = $r.conclusion
      Event    = $r.event
      Sha      = $r.headSha.Substring(0, 8)
      Start    = $created
      End      = [datetime]::Parse($r.updatedAt).ToUniversalTime()
      Url      = $r.url
    }
  }
}
$all = @($all | Sort-Object Start)
$inflight = @($all | Where-Object Status -ne 'completed')
$all = @($all | Where-Object Status -eq 'completed')
# Bucket the day by when a run FINISHED, not when it was created. Two very common
# cases on this box are created on one UTC day and finish on the next, and keying
# on createdAt files both under "still open from earlier" — or drops them entirely:
#   * long runs (appone Build & Deploy is 50m-2.5h and often starts late evening);
#   * every RE-RUN, because a re-run keeps the original run's createdAt. Since
#     ci-rerun-after-reboot retries automatically, this is now the normal path.
# "Every job that finished today" is what the synopsis promises, so honour that.
$runs = @($all | Where-Object { $_.End -ge $dayStart })

# A failure is "open" until a later run of the same repo + workflow succeeds. One card
# per broken workflow — the newest open failure, with a count if it has repeated —
# otherwise a workflow that fails on every push floods the page with identical cards.
$carried = @()
foreach ($g in ($all | Group-Object { "$($_.Repo)/$($_.Workflow)" })) {
  $lastOk = $g.Group | Where-Object Result -eq 'success' | Select-Object -Last 1
  # Order by finish time here too: a re-run carries the ORIGINAL createdAt, so a
  # failure re-run into a pass would still look newer than its own fix by Start.
  $open = @($g.Group | Where-Object {
    $_.Result -eq 'failure' -and (-not $lastOk -or $_.End -gt $lastOk.End)
  })
  if ($open.Count -eq 0) { continue }
  $latest = $open[-1]
  # Must use the SAME predicate as $runs above, or a run lands in both sections
  # or in neither.
  if ($latest.End -ge $dayStart) { continue }   # today's section already shows it
  $carried += $latest | Add-Member -NotePropertyName Repeats -NotePropertyValue $open.Count -PassThru |
    Add-Member -NotePropertyName Since -NotePropertyValue $open[0].Start -PassThru
}
$carried = @($carried | Sort-Object Start)

# ---- pull failure detail ---------------------------------------------------
$detail = @{}
foreach ($run in (@($runs | Where-Object Result -eq 'failure') + $carried)) {
  $jobs = @()
  $errors = @()
  $view = Invoke-Gh run view $run.Id -R "example-org/$($run.Repo)" --json 'jobs'
  if ($view) {
    foreach ($j in (($view | ConvertFrom-Json).jobs | Where-Object conclusion -eq 'failure')) {
      $steps = ($j.steps | Where-Object conclusion -eq 'failure' | ForEach-Object { $_.name }) -join ', '
      $jobs += if ($steps) { "$($j.name) -> $steps" } else { $j.name }
    }
  }
  $log = Invoke-Gh run view $run.Id -R "example-org/$($run.Repo)" --log-failed
  if ($log) {
    $errors = $log |
      Select-String -Pattern 'ERR_[A-Z_]+|##\[error\]|\[ERROR\]|failed to solve|Permission denied|exit code' |
      Where-Object { $_ -notmatch 'DeprecationWarning|Node\.js 20|ACTIONS_ALLOW' } |
      ForEach-Object { ($_ -replace '^.*?\dZ\s', '') } |
      Select-Object -Unique -First 5
  }
  $detail[[string]$run.Id] = [pscustomobject]@{ Jobs = $jobs; Errors = $errors }
}

# ---- render ----------------------------------------------------------------
function E([string]$s) {
  if ($null -eq $s) { return '' }
  $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
}

$fails = @($runs | Where-Object Result -eq 'failure')
$oks = @($runs | Where-Object Result -eq 'success')
$others = @($runs | Where-Object { $_.Result -ne 'failure' -and $_.Result -ne 'success' })
$dayLabel = $dayStart.ToString('d MMMM yyyy')
$stamp = [datetime]::UtcNow.ToString('HH:mm')
$flightStat = if ($inflight.Count -gt 0) {
  "<div class=""stat""><span class=""n"">$($inflight.Count)</span><span class=""k"">queued / running</span></div>"
} else { '' }
$carryStat = if ($carried.Count -gt 0) {
  "<div class=""stat bad""><span class=""n"">$($carried.Count)</span><span class=""k"">open from earlier</span></div>"
} else { '' }

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine(@"
<title>CI day — example-org, $dayLabel</title>
<style>
  :root{--ground:#F4F6F5;--surface:#FFFFFF;--surface-2:#EDF1F0;--ink:#131A1B;--ink-2:#4E5A5C;--ink-3:#78868A;
    --line:#DBE3E2;--accent:#1F5F63;--fail:#A32E28;--fail-bg:#FBEDEC;--good:#2F6B44;--good-bg:#E9F3EC;
    --warn:#8A5A16;--warn-bg:#FAF2E3;--shadow:0 1px 2px rgba(19,26,27,.05),0 8px 24px -16px rgba(19,26,27,.25);}
  @media (prefers-color-scheme:dark){:root{--ground:#0E1414;--surface:#151D1E;--surface-2:#1C2627;--ink:#E8EEED;
    --ink-2:#A5B3B3;--ink-3:#758587;--line:#263233;--accent:#63B7B1;--fail:#EC8B81;--fail-bg:#2B1A18;
    --good:#84C492;--good-bg:#16261C;--warn:#E2B268;--warn-bg:#2A2216;--shadow:0 1px 2px rgba(0,0,0,.4),0 8px 24px -16px rgba(0,0,0,.8);}}
  :root[data-theme=light]{--ground:#F4F6F5;--surface:#FFFFFF;--surface-2:#EDF1F0;--ink:#131A1B;--ink-2:#4E5A5C;
    --ink-3:#78868A;--line:#DBE3E2;--accent:#1F5F63;--fail:#A32E28;--fail-bg:#FBEDEC;--good:#2F6B44;--good-bg:#E9F3EC;
    --warn:#8A5A16;--warn-bg:#FAF2E3;--shadow:0 1px 2px rgba(19,26,27,.05),0 8px 24px -16px rgba(19,26,27,.25);}
  :root[data-theme=dark]{--ground:#0E1414;--surface:#151D1E;--surface-2:#1C2627;--ink:#E8EEED;--ink-2:#A5B3B3;
    --ink-3:#758587;--line:#263233;--accent:#63B7B1;--fail:#EC8B81;--fail-bg:#2B1A18;--good:#84C492;--good-bg:#16261C;
    --warn:#E2B268;--warn-bg:#2A2216;--shadow:0 1px 2px rgba(0,0,0,.4),0 8px 24px -16px rgba(0,0,0,.8);}
  *{box-sizing:border-box}
  body{background:var(--ground);color:var(--ink);margin:0;padding:32px 20px 72px;font-size:15px;line-height:1.55;
    font-family:ui-sans-serif,system-ui,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
  .wrap{max-width:1000px;margin:0 auto;display:flex;flex-direction:column;gap:34px}
  code,.mono,time{font-family:ui-monospace,"Cascadia Code","JetBrains Mono",Menlo,Consolas,monospace;font-variant-numeric:tabular-nums}
  .eyebrow{font-size:11px;letter-spacing:.13em;text-transform:uppercase;color:var(--ink-3);font-weight:600}
  h1{font-size:clamp(26px,4vw,36px);line-height:1.1;margin:.35em 0 0;font-weight:640;letter-spacing:-.02em}
  .standfirst{margin:.5em 0 0;color:var(--ink-2);max-width:62ch}
  .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:1px;background:var(--line);
    border:1px solid var(--line);border-radius:3px;overflow:hidden;margin-top:22px}
  .stat{background:var(--surface);padding:13px 15px;display:flex;flex-direction:column;gap:2px}
  .stat .n{font-size:26px;font-weight:600;letter-spacing:-.02em;line-height:1.1}
  .stat .k{font-size:11px;letter-spacing:.07em;text-transform:uppercase;color:var(--ink-3);font-weight:600}
  .stat.bad .n{color:var(--fail)} .stat.good .n{color:var(--good)}
  h2{font-size:13px;letter-spacing:.12em;text-transform:uppercase;color:var(--ink-3);font-weight:660;margin:0 0 14px;
    padding-bottom:10px;border-bottom:1px solid var(--line)}
  .card{background:var(--surface);border:1px solid var(--line);border-left:3px solid var(--fail);border-radius:3px;
    padding:15px 17px;box-shadow:var(--shadow);display:flex;flex-direction:column;gap:10px;margin-bottom:12px}
  .card-head{display:flex;flex-wrap:wrap;align-items:baseline;gap:9px}
  .card-head time{font-size:13px;color:var(--ink-3);font-weight:600}
  .card-head .repo{font-size:15.5px;font-weight:640}
  .card-head .wf{font-size:13px;color:var(--ink-2)}
  .card-head .wf::before{content:"› ";color:var(--ink-3)}
  .pill{margin-left:auto;font-size:11px;font-weight:660;letter-spacing:.05em;text-transform:uppercase;padding:3px 9px;
    border-radius:2px;background:var(--fail-bg);color:var(--fail)}
  .title{font-size:14px;color:var(--ink-2);margin:0}
  pre{margin:0;background:var(--surface-2);border-radius:3px;padding:10px 12px;font-size:12.5px;line-height:1.5;
    overflow-x:auto;white-space:pre-wrap;word-break:break-word}
  .note{margin:0;font-size:14.5px;border-left:2px solid var(--accent);padding-left:11px;color:var(--ink-2)}
  .note b{color:var(--ink);font-weight:620}
  .meta{display:flex;flex-wrap:wrap;gap:5px 16px;font-size:12.5px;color:var(--ink-3);border-top:1px dashed var(--line);padding-top:9px}
  .tbl-shell{overflow-x:auto;border:1px solid var(--line);border-radius:3px;background:var(--surface)}
  table{width:100%;border-collapse:collapse;font-size:13.5px}
  th{text-align:left;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3);font-weight:660;
    padding:10px 13px;border-bottom:1px solid var(--line);white-space:nowrap}
  td{padding:9px 13px;border-bottom:1px solid var(--line);vertical-align:top}
  tr:last-child td{border-bottom:0}
  td.t,td.sha{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px;color:var(--ink-3);white-space:nowrap}
  td .ok{color:var(--good);font-weight:660}
  .empty{background:var(--surface);border:1px dashed var(--line);border-radius:3px;padding:34px;text-align:center;color:var(--ink-3)}
  a{color:var(--accent);text-underline-offset:2px}
  a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
  footer{color:var(--ink-3);font-size:12.5px;border-top:1px solid var(--line);padding-top:16px;max-width:78ch}
</style>
<div class="wrap">
<header>
  <div class="eyebrow">example-org · runner <span class="mono">marathon</span> · day runs 03:00 → 03:00 local (00:00Z)</div>
  <h1>CI day — $dayLabel</h1>
  <p class="standfirst">Every job that finished today, newest last — plus any earlier failure that
    no later run has fixed yet. Updated $stamp UTC.</p>
  <div class="stats">
    <div class="stat"><span class="n">$($runs.Count)</span><span class="k">runs finished</span></div>
    <div class="stat bad"><span class="n">$($fails.Count)</span><span class="k">failed</span></div>
    <div class="stat good"><span class="n">$($oks.Count)</span><span class="k">succeeded</span></div>
    $flightStat
    $carryStat
  </div>
</header>
"@)

if ($runs.Count -eq 0 -and $carried.Count -eq 0 -and $inflight.Count -eq 0) {
  $null = $sb.AppendLine('<div class="empty">No jobs have finished yet today, and nothing is left failing. The log fills as runs complete.</div>')
} elseif ($runs.Count -eq 0 -and $inflight.Count -eq 0) {
  $null = $sb.AppendLine('<div class="empty">No jobs have finished yet today. What follows is still open from earlier.</div>')
}

# Queued / running work. Not part of the day's tally — it's here so a job waiting
# behind a busy runner is visible instead of looking like it never arrived.
if ($inflight.Count -gt 0) {
  $now = [datetime]::UtcNow
  $null = $sb.AppendLine('<section><h2>In flight</h2><div class="tbl-shell"><table>
    <thead><tr><th>Started</th><th>Repo</th><th>Workflow</th><th>State</th><th>Commit</th><th>Waiting</th></tr></thead><tbody>')
  foreach ($r in $inflight) {
    $mins = [math]::Round(($now - $r.Start).TotalMinutes, 1)
    $null = $sb.AppendLine("<tr><td class=""t"">$($r.Start.ToString('HH:mm'))</td><td>$(E $r.Repo)</td>
      <td>$(E $r.Workflow)</td><td>$(E $r.Status)</td><td class=""sha"">$($r.Sha)</td><td class=""t"">$mins m</td></tr>")
  }
  $null = $sb.AppendLine('</tbody></table></div></section>')
}

# One card renderer for both sections; -Carried stamps the date and says it is still open.
function Add-FailCard {
  param($f, [switch] $Carried)
  $d = $detail[[string]$f.Id]
  $mins = [math]::Round(($f.End - $f.Start).TotalMinutes, 1)
  # A bare HH:mm under "today" is misleading when the run STARTED on an earlier UTC
  # day (long runs and re-runs both do). Stamp the date in that case too.
  $when = if ($Carried -or $f.Start -lt $dayStart) { $f.Start.ToString('d MMM HH:mm') }
          else { $f.Start.ToString('HH:mm') }
  $pill = if ($Carried) { 'still failing' } else { 'failed' }
  $null = $sb.AppendLine("<article class=""card"">
    <div class=""card-head""><time>$when</time>
      <span class=""repo"">$(E $f.Repo)</span><span class=""wf"">$(E $f.Workflow)</span>
      <span class=""pill"">$pill</span></div>
    <p class=""title"">$(E (Resolve-Title $f.Repo $f.Sha $f.Title))</p>")
  if ($d.Jobs) { $null = $sb.AppendLine("<p class=""title""><b>Failed job:</b> $(E ($d.Jobs -join ' · '))</p>") }
  if ($d.Errors) { $null = $sb.AppendLine("<pre>$(E ($d.Errors -join "`n"))</pre>") }
  if ($notes.ContainsKey([string]$f.Id)) {
    $null = $sb.AppendLine("<p class=""note""><b>Root cause.</b> $(E $notes[[string]$f.Id])</p>")
  } else {
    $null = $sb.AppendLine("<p class=""note"">Root cause not yet diagnosed.</p>")
  }
  $rep = if ($Carried -and $f.Repeats -gt 1) {
    "<span>failed <b>$($f.Repeats)&times;</b> since $($f.Since.ToString('d MMM'))</span>"
  } else { '' }
  $null = $sb.AppendLine("<div class=""meta""><span>commit <b>$($f.Sha)</b></span><span>$($f.Event)</span>
    <span>$mins min</span>$rep<span><a href=""$($f.Url)"">run $($f.Id)</a></span></div></article>")
}

if ($fails.Count -gt 0) {
  $null = $sb.AppendLine('<section><h2>Failures today</h2>')
  foreach ($f in $fails) { Add-FailCard $f }
  $null = $sb.AppendLine('</section>')
}

if ($carried.Count -gt 0) {
  $null = $sb.AppendLine('<section><h2>Still open from earlier</h2>
    <p class="standfirst">These stay on the page until a later run of the same workflow passes.</p>')
  foreach ($f in $carried) { Add-FailCard $f -Carried }
  $null = $sb.AppendLine('</section>')
}

if ($oks.Count -gt 0 -or $others.Count -gt 0) {
  $null = $sb.AppendLine('<section><h2>Completed</h2><div class="tbl-shell"><table>
    <thead><tr><th>Time</th><th>Repo</th><th>Workflow</th><th>Result</th><th>Commit</th><th>Took</th></tr></thead><tbody>')
  # Sorted by finish time: this is the day log of what COMPLETED today, and with
  # re-runs in the mix createdAt order no longer matches the order things landed.
  foreach ($r in ($oks + $others | Sort-Object End)) {
    $mins = [math]::Round(($r.End - $r.Start).TotalMinutes, 1)
    $res = if ($r.Result -eq 'success') { '<span class="ok">passed</span>' } else { E $r.Result }
    $when = if ($r.Start -lt $dayStart) { $r.Start.ToString('d MMM HH:mm') } else { $r.Start.ToString('HH:mm') }
    $null = $sb.AppendLine("<tr><td class=""t"">$when</td><td>$(E $r.Repo)</td>
      <td>$(E $r.Workflow)</td><td>$res</td><td class=""sha"">$($r.Sha)</td><td class=""t"">$mins m</td></tr>")
  }
  $null = $sb.AppendLine('</tbody></table></div></section>')
}

$null = $sb.AppendLine("<footer>Rendered by <code>monitor/day-report.ps1</code> from <code>gh run list</code> across $($Repos.Count) repos. Successes carry one calendar day and clear at 3am local (00:00Z). Failures do not: a failed run stays on the page, with its diagnosis, until a later run of the same repo and workflow succeeds — looking back $LookbackDays days.</footer></div>")

$outDir = Split-Path $OutFile -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }
$sb.ToString() | Out-File $OutFile -Encoding utf8
Write-Host "wrote $OutFile — $($runs.Count) runs, $($fails.Count) failed"

