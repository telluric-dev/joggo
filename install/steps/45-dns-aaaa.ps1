param([hashtable]$Ctx,[hashtable]$Cfg,[string]$Token)

# 45-dns-aaaa — OPT-IN. Strip AAAA for the slot networks.
#
# Preflight warns when DNS returns AAAA records that do not route from here,
# because that makes build-time fetches and `docker login ghcr.io` HANG rather
# than fail — it cost the origin box a stalled production image pin. Until now
# the warning had no remedy attached: network/filter-aaaa.conf sat in the repo
# marked NOT INSTALLED.
#
# It stays opt-in because it changes name resolution inside someone's distro,
# which is not a thing to do silently. Default false; the wizard offers it only
# when preflight actually raised the warning; with -NonInteractive it is purely
# flag-driven.

Step-Header $Ctx '45-dns-aaaa'

if(-not $Cfg.filterAaaa){
  Skip $Ctx 'filterAaaa is false — DNS inside the distro is left exactly as it is'
  if($Ctx.AaaaWarned){
    Say $Ctx 'preflight DID raise the AAAA warning for this box. The fix is -FilterAaaa; it is not applied because it was not asked for.'
    Add-Result $Ctx 'dns-aaaa' 'warn' 'preflight warned about unroutable AAAA; the filter was not requested' 're-run with -FilterAaaa'
  } else {
    Add-Result $Ctx 'dns-aaaa' 'pass' 'not requested' ''
  }
  return
}

if($Ctx.DryRun){
  Plan $Ctx 'would install dnsmasq and dnsutils in the distro (dnsutils is the instrument the effect is measured with)'
  Plan $Ctx 'would install network/filter-aaaa.conf to /etc/dnsmasq.d/joggo-filter-aaaa.conf and compare it byte-for-byte'
  Plan $Ctx 'would run dnsmasq --test (syntax, AND that this build supports filter-AAAA at all)'
  Plan $Ctx 'would enable + start dnsmasq, then ask systemd whether it is active'
  Plan $Ctx 'would add --dns=$SLOT_GATEWAY to the installed launcher in step 70 — without it the filter listens and is never asked'
  Plan $Ctx 'the behavioural proof runs in 99-verify: upstream-has-AAAA vs filter-has-none, with the upstream as positive control'
  Add-Result $Ctx 'dns-aaaa' 'pass' 'dry run' ''
  return
}

if(-not (Confirm-Joggo -Ctx $Ctx -Question 'Install the AAAA filter? It changes DNS resolution for the slot networks inside the distro.')){
  Skip $Ctx 'declined — DNS left unchanged'
  Add-Result $Ctx 'dns-aaaa' 'warn' 'declined by the operator' ''
  $Cfg.filterAaaa = $false
  return
}

$r = Invoke-Phase -Ctx $Ctx -Cfg $Cfg -Phase 'dns-aaaa' -TimeoutSec 900
if(-not $r.ok){
  Fail -Ctx $Ctx -Problem 'the AAAA filter could not be installed' `
    -Action 'the output above names the cause. If dnsmasq --test rejected filter-AAAA, this dnsmasq build cannot do it and the fix does not apply here — re-run without -FilterAaaa.' -Code 1
}
Add-Result $Ctx 'dns-aaaa' 'pass' 'dnsmasq active with the filter drop-in; resolution tested in 99-verify' ''
