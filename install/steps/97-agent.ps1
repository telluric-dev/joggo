param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 97-agent — the monitor, and the supervisor brief for an agent session.
#
# Two small things that were previously dishonest or missing.
#
# THE MONITOR used to be a flag that stored a value and installed nothing:
# -Monitor was accepted, written into the config, and then no step ever looked
# at it. That is worse than not offering it, because the config says it is on.
# It is a WPF desktop app with no service story, so "installing" it means
# staging it somewhere stable and telling the operator the command. It is NOT
# registered to run at logon unless asked: a window that opens itself on every
# login is a thing people uninstall.
#
# THE SUPERVISOR BRIEF is rendered, not copied. agent/SUPERVISOR.md is a
# template; the value is in it being specific to THIS box — the distro name
# every wsl call needs, the real thresholds, the real paths. A generic brief
# makes an agent guess, and the guesses are what the brief exists to prevent.

Step-Header $Ctx '97-agent'

# ----------------------------------------------------------------- the monitor
if($Cfg.monitor){
  $src = Join-Path $Ctx.RepoRoot 'monitor\deploy-monitor.ps1'
  $dst = Join-Path $Ctx.BinDir   'deploy-monitor.ps1'
  if($Ctx.DryRun){
    Plan $Ctx "would stage monitor\deploy-monitor.ps1 -> $dst and print how to run it"
  } else {
    if(-not (Test-Path $src)){
      Fail -Ctx $Ctx -Problem 'monitor\deploy-monitor.ps1 is missing from the repo' `
        -Action 'run without -Monitor, or restore the file.' -Code 1
    }
    # Create the bin directory here, not rely on step 80 having done it. 80 makes it only
    # when it installs the guard or the sampler, so under -NoGuard -NoSampler this copy hit
    # a missing directory and died as a raw DirectoryNotFoundException -- found on the first
    # real run of that combination.
    New-Item -ItemType Directory -Force -Path $Ctx.BinDir | Out-Null
    Copy-Item $src $dst -Force -ErrorAction SilentlyContinue
    if(-not (Test-Path $dst)){
      Fail -Ctx $Ctx -Problem "the monitor did not land at $dst" -Action 'check permissions on the bin directory.' -Code 1
    }
    Say $Ctx "monitor staged: $dst"
    # Parenthesised: `Say $Ctx 'a' + $x + 'b'` parses as Say with THREE positional
    # arguments and a stray '+', not as one concatenated string.
    Say $Ctx ('  run it with:  powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $dst)
    Say $Ctx '  it reads the runner journal over wsl and needs no GitHub token.'
    # Deliberately NOT registered to run at logon, even under -StartOnBoot. A window
    # that opens itself on every login is a thing people uninstall, and the guard and
    # watchdog — which do need to survive a reboot — are tasks already. This is a tool
    # you open when you want to look.
  }
  Add-Result $Ctx 'monitor' 'pass' 'staged, with the command to run it' ''
} else {
  Skip $Ctx 'monitor not requested (-Monitor to stage it)'
  Add-Result $Ctx 'monitor' 'pass' 'not requested' ''
}

# -------------------------------------------------------- the supervisor brief
if($Cfg.agentSupervisor){
  $tpl = Join-Path $Ctx.RepoRoot 'agent\SUPERVISOR.md'
  $out = Join-Path $Ctx.DataDir  'SUPERVISOR.md'

  if($Ctx.DryRun){
    Plan $Ctx "would render agent\SUPERVISOR.md -> $out with this box's distro, paths, slots and thresholds substituted"
    Add-Result $Ctx 'agent-brief' 'pass' 'dry run' ''
    return
  }

  if(-not (Test-Path $tpl)){
    Fail -Ctx $Ctx -Problem 'agent\SUPERVISOR.md is missing from the repo' `
      -Action 'run with -NoAgentSupervisor, or restore the file.' -Code 1
  }

  $scopeDesc = if($Cfg.scope -eq 'org'){ "org $($Cfg.org) (runner group is the boundary)" }
               else { "repo $($Cfg.repo) (the registered repo list is the boundary)" }

  $map = @{
    '{{RUNNER_NAME}}' = [string]$Cfg.runnerName
    '{{LABELS}}'      = [string]$Cfg.labels
    '{{DISTRO}}'      = [string]$Cfg.distro
    '{{SLOTS}}'       = [string]$Cfg.slots
    '{{SCOPE_DESC}}'  = $scopeDesc
    '{{RAM_MB}}'      = [string]$Cfg.ramMB
    '{{WARN_MB}}'     = [string]$Cfg.guardWarnMB
    '{{CRITICAL_MB}}' = [string]$Cfg.guardCriticalMB
    '{{GUARD_MIN}}'   = [string]$Cfg.guardIntervalMin
    '{{DATA_DIR}}'    = [string]$Ctx.DataDir
    '{{SLOT_UNIT}}'   = 'joggo-slot'
  }

  # EXPLICIT ENCODING ON BOTH SIDES, and not Get-Content/Set-Content.
  #
  # SUPERVISOR.md is UTF-8 without a BOM, as a markdown file should be, and
  # `Get-Content -Raw` under Windows PowerShell 5.1 reads a BOM-less file as ANSI.
  # The template's middle dots and em-dashes came out as mojibake -- the rendered
  # brief read "warn 2450 MB A? critical 1225 MB", which is the first thing an agent
  # would see and the last thing that inspires confidence in the rest of it.
  #
  # Reading with an explicit UTF8Encoding fixes it without requiring the template to
  # carry a BOM, and writing with UTF8Encoding($false) keeps the output BOM-less so
  # the rendered file is as clean as the source. Caught by rendering it and looking,
  # which is the only way this class of bug ever gets caught.
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $text = [System.IO.File]::ReadAllText($tpl, [System.Text.Encoding]::UTF8)
  foreach($k in $map.Keys){ $text = $text.Replace($k, $map[$k]) }

  # The template calls itself a template in its first sentence. The rendered copy is
  # not one, and leaving that sentence in invites somebody to go looking for the "real"
  # file. Matched on an ASCII-only literal: an earlier version anchored on the heading,
  # which contained an em-dash, and this file is read as ANSI by Windows PowerShell 5.1
  # unless it carries a BOM -- at which point the em-dash's last byte becomes a curly
  # quote and PS accepts curly quotes as string delimiters. The file now has a BOM AND
  # this match does not depend on a non-ASCII character. Belt and braces, cheaply.
  $notice = 'Rendered for this box by install.ps1 on ' + (Get-Date -Format 'yyyy-MM-dd') + '.'
  $text = $text.Replace('This is a **template**.', $notice)

  [System.IO.File]::WriteAllText($out, $text, $utf8NoBom)

  # Read it back and prove no placeholder survived — a brief that still says
  # {{DISTRO}} is worse than none, because an agent will use it literally.
  if(-not (Test-Path $out)){
    Fail -Ctx $Ctx -Problem "the supervisor brief did not land at $out" -Action 'check permissions on the data directory.' -Code 1
  }
  $left = Select-String -Path $out -Pattern '\{\{[A-Z_]+\}\}' -AllMatches
  if($left){
    $names = ($left.Matches.Value | Sort-Object -Unique) -join ', '
    Fail -Ctx $Ctx -Problem "the rendered brief still contains placeholders: $names" `
      -Action 'a template token has no value in the config. Report this as a bug; the brief is unusable as written.' -Code 1
  }

  Say $Ctx "supervisor brief: $out"
  Say $Ctx "  paste it to start a session that watches this runner. It carries this box's distro,"
  Say $Ctx '  paths and thresholds, the invariants, and the diagnosis tests.'
  Add-Result $Ctx 'agent-brief' 'pass' "rendered to $out, no placeholders left" ''
} else {
  Skip $Ctx 'supervisor brief not requested (-AgentSupervisor to render it)'
  Add-Result $Ctx 'agent-brief' 'pass' 'not requested' ''
}
