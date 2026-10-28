param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 40-docker — Docker Engine, NATIVE in the distro.
#
# Not Docker Desktop, and this is not a preference. Desktop projects its own
# socket into the distro from /mnt/wsl, so `docker info` answers while there is
# no local daemon at all — and every slot then shares one image store and build
# cache across repositories, which is the isolation the slot model exists for.
# The Linux half refuses to continue if it finds Desktop's socket.

Step-Header $Ctx '40-docker'

if($Ctx.DryRun){
  Plan $Ctx 'would refuse to continue if the docker socket in the distro comes from Docker Desktop'
  Plan $Ctx 'would install Docker Engine from get.docker.com if dockerd is absent'
  Plan $Ctx "would add $($Cfg.runnerUser) to the docker group (root-equivalent on this host, and accepted: the box is dedicated to CI)"
  Plan $Ctx 'would enable + start docker.service, then confirm it is active AND that the daemon reports a server version'
  Plan $Ctx 'would install the weekly docker prune (a full disk presents as random build failures)'
  Plan $Ctx 'if WSL tunnels DNS (resolv.conf 10.255.255.254, unreachable from containers) and daemon.json sets no dns: write the Windows DNS servers that answer, + 1.1.1.1/8.8.8.8 fallback'
  Add-Result $Ctx 'docker' 'pass' 'dry run' ''
  return
}

# CONTAINER DNS CANDIDATES, gathered here because only Windows knows them. Current WSL
# tunnels DNS: the distro's resolv.conf says 10.255.255.254, which answers inside the
# distro and NOT from Docker's bridge network -- so on a fresh install every container
# build died at its first network step ("Temporary failure resolving
# 'archive.ubuntu.com'", 30s per lookup, minutes per build). The Linux half writes these
# into /etc/docker/daemon.json only when it finds that situation, and only the ones that
# actually answer a query from inside the distro.
#
# Only adapters that are UP. A disconnected adapter keeps advertising its DNS server, and
# on the box this was found on that server was the FIRST one listed -- and timed out.
# Public resolvers go last, as the fallback, not first: a company network may need its
# own DNS to resolve anything internal.
if(-not $Cfg.dockerDns){
  $cand = @()
  try {
    $up = @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty ifIndex)
    $cand = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
              Where-Object { $up -contains $_.InterfaceIndex } |
              ForEach-Object { $_.ServerAddresses } |
              Where-Object { $_ -and $_ -notmatch '^(127\.|169\.254\.|0\.)' })
  } catch { $cand = @() }
  $Cfg.dockerDns = (@($cand) + @('1.1.1.1','8.8.8.8') | Select-Object -Unique) -join ','
}

# Long: a cold apt plus the engine download.
$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'docker' -TimeoutSec 1200
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem 'Docker Engine is not running natively in the distro' `
    -Action 'the output above names the cause and the fix. The two common ones: Docker Desktop WSL integration is on for this distro, or systemd is not running.' -Code 1
}
Add-Result $Ctx 'docker' 'pass' 'docker.service active, daemon answered with a server version' ''
