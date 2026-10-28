param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 20-distro — the distro exists, is WSL 2, and has systemd=true.
#
# systemd=true IS A PREREQUISITE, not a preference: svc.sh, systemctl, docker and
# every slot unit depend on it. Setting it requires restarting the distro, which
# only the Windows side can do — so that restart happens here, once, before
# anything is installed inside, rather than being discovered three steps later
# when `systemctl` is not a thing.

Step-Header $Ctx '20-distro'

$payload = @(
  'slots\run-containerized-slot.sh','slots\slot-pause.sh','slots\slots-status.sh',
  'slots\add-slot.sh','slots\systemd\joggo-slot@.service',
  'slots\dind-image\build.sh','slots\dind-image\Dockerfile','slots\runner-image\Dockerfile',
  'watchdog\runner-watchdog.sh','watchdog\rerun-after-reboot.sh',
  'watchdog\systemd\runner-watchdog.service','watchdog\systemd\runner-watchdog.timer',
  'watchdog\systemd\actions-runner-restart-override.conf','watchdog\systemd\rerun-after-reboot.service',
  'network\filter-aaaa.conf'
)

if($Ctx.DryRun){
  Plan $Ctx "would confirm distro '$($Cfg.distro)' exists and is WSL version 2"
  Plan $Ctx "would install it with: wsl --install -d $($Cfg.distro)   (only if absent)"
  Plan $Ctx "would stage install/inside-wsl.sh and $($payload.Count) repo files into /opt/joggo"
  Plan $Ctx 'would set systemd=true in /etc/wsl.conf and restart the distro with: wsl --terminate'
  Plan $Ctx '  (--terminate, not --shutdown: only this distro, so nothing else on the box is dropped)'
  Add-Result $Ctx 'distro' 'pass' 'dry run' ''
  return
}

$distros = Get-WslDistros -Ctx $Ctx
if($null -eq $distros){
  Undetermined -Ctx $Ctx -What 'the installed WSL distros (wsl -l -v did not answer)' `
    -Action 'run: wsl -l -v   — if WSL itself is broken, reboot after step 10 and re-run'
}

$d = @($distros | Where-Object { $_.name -eq $Cfg.distro })[0]
if($null -eq $d){
  # Resolve-JoggoDistro has already looked for a usable Ubuntu under any name,
  # so reaching here means there genuinely is not one. Installing a distro is a
  # several-hundred-megabyte download and a new VM on someone's machine: ask.
  if(-not (Confirm-Joggo -Ctx $Ctx -Question "No usable distro found. Install '$($Cfg.distro)' now (several hundred MB)?")){
    Fail -Ctx $Ctx -Problem "distro '$($Cfg.distro)' is not installed and installing it was declined" `
      -Action "install one yourself ('wsl --install -d $($Cfg.distro)'), or pass -Distro <an installed distro>" -Code 1
  }
  Say $Ctx "installing '$($Cfg.distro)'"
  & wsl.exe --install -d $Cfg.distro --no-launch 2>&1 | ForEach-Object { Say $Ctx $_ }
  if($LASTEXITCODE -ne 0){
    $names = (@($distros | ForEach-Object { $_.name }) -join ', ')
    Fail -Ctx $Ctx -Problem "could not install distro '$($Cfg.distro)'" `
      -Action "list what is available with 'wsl --list --online' and pass -Distro <name>. Installed right now: $names" -Code 1
  }
  $distros = Get-WslDistros -Ctx $Ctx
  $d = @($distros | Where-Object { $_.name -eq $Cfg.distro })[0]
  if($null -eq $d){
    Undetermined -Ctx $Ctx -What "whether distro '$($Cfg.distro)' installed (wsl --install exited 0 but it is not listed)" `
      -Action 'run: wsl -l -v ; wsl --list --online'
  }
  Ok $Ctx "distro '$($Cfg.distro)' installed"
} else {
  Skip $Ctx "distro '$($Cfg.distro)' is present (state $($d.state), WSL version $($d.version))"
}

if($d.version -ne 2){
  Fail -Ctx $Ctx -Problem "distro '$($Cfg.distro)' is WSL version $($d.version), not 2" `
    -Action "convert it: wsl --set-version $($Cfg.distro) 2   (WSL1 has no systemd, no real kernel, and no working Docker)" -Code 1
}
Ok $Ctx "WSL version 2 confirmed for '$($Cfg.distro)'"

# Stage the Linux half and the repo files it installs from.
Push-InsideWsl   -Ctx $Ctx
Push-RepoPayload -Ctx $Ctx -RelPaths $payload
Ok $Ctx "staged the Linux half and $($payload.Count) repo files into /opt/joggo"

# systemd
$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'wsl-conf' -TimeoutSec 90
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem 'could not set systemd=true in /etc/wsl.conf' `
    -Action "set it by hand inside the distro: printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf, then: wsl --terminate $($Cfg.distro)" -Code 1
}

if($r.out -match 'changed=1'){
  if(-not (Confirm-Joggo -Ctx $Ctx -Question "Restart distro '$($Cfg.distro)' now to apply systemd=true?")){
    Fail -Ctx $Ctx -Problem 'systemd=true is written but not applied, and nothing further can work without it' `
      -Action "restart the distro yourself: wsl --terminate $($Cfg.distro)   then re-run install.ps1" -Code 1
  }
  Say $Ctx "restarting distro '$($Cfg.distro)' (--terminate, so only this distro is affected)"
  & wsl.exe --terminate $Cfg.distro 2>&1 | ForEach-Object { Say $Ctx $_ }
  Start-Sleep -Seconds 3
}

# VERIFY systemd IS ACTUALLY PID 1'S INIT, not that the config file says so. The
# file saying systemd=true and the VM running without it is exactly the state a
# missed restart leaves behind, and it is the state every later step would
# misdiagnose.
$deadline = (Get-Date).AddSeconds(120)
$state = ''
while((Get-Date) -lt $deadline){
  $p = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'probe' -TimeoutSec 60
  foreach($line in ($p.out -split "`n")){
    if($line -match '^\s*system_state=(.+)$'){ $state = $Matches[1].Trim() }
  }
  if($state -eq 'running' -or $state -eq 'degraded'){ break }
  Start-Sleep -Seconds 5
}
switch($state){
  'running'  { Ok $Ctx "systemd is running in '$($Cfg.distro)'" }
  'degraded' { Ok $Ctx "systemd is running (degraded) in '$($Cfg.distro)' — normal in WSL2: some host-oriented units never apply" }
  ''         { Undetermined -Ctx $Ctx -What 'whether systemd is running in the distro (it did not answer)' `
                 -Action "run: wsl -d $($Cfg.distro) -u root -- systemctl is-system-running" }
  default    { Fail -Ctx $Ctx -Problem "systemd in '$($Cfg.distro)' reports '$state'" `
                 -Action "wsl --terminate $($Cfg.distro), then re-run. svc.sh, docker and the slot units all need systemd." -Code 1 }
}
Add-Result $Ctx 'distro' 'pass' "$($Cfg.distro) WSL2, systemd $state" ''
