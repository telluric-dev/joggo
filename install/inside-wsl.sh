#!/usr/bin/env bash
#
# inside-wsl.sh — the Linux half of the joggo installer.
#
# Called as:  bash /opt/joggo/inside-wsl.sh <phase> [args]
# with the config object as JSON on STDIN (install/CONTRACT.md "Config schema").
#
# WHY STDIN. The registration token is in that object, and stdin is the only
# channel into this script that does not end up in a process listing, a shell
# history, or a log. Nothing here ever writes the token anywhere, and the only
# place it is passed as an argument is config.sh's own --token, which has no
# alternative — a ~2 second window visible to root on this box, documented
# rather than hidden. See SECURITY.md.
#
# WHY THE SCRIPT IS STAGED HERE rather than run from /mnt/c: a script on a DrvFs
# mount carries CRLF and no exec bit, and both failures surface as nonsense
# errors from bash several layers from the cause.
#
# HOUSE RULE, and it is the reason this file is longer than it looks: a command
# exiting 0 is not evidence that it did anything. Every phase that changes
# something reads the effect back — the unit is active, the file is on disk with
# the content we wrote, the runner answered. Where a check cannot be made, the
# phase says "could not determine" and FAILS. slots/slot-pause.sh's job_in_flight
# is the local cautionary tale: it read a failed `docker top` as "idle" and
# destroyed a running build.
#
# Exit codes: 0 ok, 1 blocking failure, 2 bad usage.

set -uo pipefail

PHASE="${1:-}"
shift || true

STAGE=/opt/joggo
say()  { printf '%s\n' "$*"; }
ok()   { printf 'ok: %s\n' "$*"; }
skip() { printf 'already done: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# Every failure names the problem AND the action. There is no bare-die path.
die() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -n "${2:-}" ]; then printf '  -> %s\n' "$2" >&2; fi
  exit 1
}
# A probe that cannot answer is a failure, never a pass.
undetermined() {
  printf 'FAIL: could not determine %s\n' "$1" >&2
  if [ -n "${2:-}" ]; then printf '  -> %s\n' "$2" >&2; fi
  exit 1
}

[ "$(id -u)" = "0" ] || die "the Linux half must run as root (got uid $(id -u))" \
  "the installer calls it with 'wsl -u root'; do not run it by hand as a user"

# ---------------------------------------------------------------- config
#
# The schema is FLAT by contract (one object, no nesting), so a flat reader is
# sufficient and avoids depending on jq, which is not installed on a fresh
# distro and would have to be installed before the config could be read — a
# bootstrap order nobody enjoys debugging.
#
# Values are restricted to what the schema actually carries: strings without
# quotes or backslashes, integers, and booleans. A value containing a single
# quote is REJECTED rather than quietly mangled, because mangling it would turn
# a bad input into a shell injection.

read_cfg() {
  CFG_JSON="$(cat)"
  [ -n "$CFG_JSON" ] || die "no config on stdin" "this script is driven by install.ps1; it is not a standalone tool"
  local assigns
  assigns="$(printf '%s' "$CFG_JSON" | awk '
    { s = s $0 " " }
    END {
      n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c != "\"") { i++; continue }
        j = i + 1; key = ""
        while (j <= n) {
          ch = substr(s, j, 1)
          if (ch == "\\") { key = key substr(s, j+1, 1); j += 2; continue }
          if (ch == "\"") break
          key = key ch; j++
        }
        i = j + 1
        while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
        if (substr(s, i, 1) != ":") continue
        i++
        while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
        ch = substr(s, i, 1)
        if (ch == "\"") {
          j = i + 1; val = ""
          while (j <= n) {
            c2 = substr(s, j, 1)
            if (c2 == "\\") { val = val substr(s, j+1, 1); j += 2; continue }
            if (c2 == "\"") break
            val = val c2; j++
          }
          i = j + 1
        } else {
          val = ""
          while (i <= n && substr(s, i, 1) !~ /[,}]/) { val = val substr(s, i, 1); i++ }
          gsub(/[ \t]/, "", val)
        }
        if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
        q = sprintf("%c", 39)
        if (index(val, q) > 0) { printf "BADVALUE_%s=1\n", key; continue }
        printf "CFG_%s=%s%s%s\n", key, q, val, q
      }
    }')"
  case "$assigns" in
    *BADVALUE_*) die "a config value contains a single quote" "remove it; the schema has no field that needs one" ;;
  esac
  eval "$assigns"

  # Defaults for anything the caller omitted, so a phase can reference a field
  # without every phase re-checking that it was sent.
  : "${CFG_scope:=}" "${CFG_org:=}" "${CFG_repo:=}" "${CFG_runnerUrl:=}"
  : "${CFG_runnerName:=joggo}" "${CFG_labels:=self-hosted,linux,x64,joggo}"
  : "${CFG_slots:=1}" "${CFG_runnerUser:=ghrunner}" "${CFG_distro:=}"
  : "${CFG_registrationToken:=}" "${CFG_watchdog:=true}" "${CFG_startOnBoot:=true}"
  : "${CFG_tailscale:=false}" "${CFG_guard:=true}" "${CFG_filterAaaa:=false}"

  RUNNER_USER="$CFG_runnerUser"
  RUNNER_ROOT="/home/${RUNNER_USER}/actions-runner"
}

truthy() { case "${1:-}" in true|True|TRUE|1|yes|y) return 0 ;; *) return 1 ;; esac }

# The systemd unit svc.sh generates is named from the registration URL, so it
# differs between scopes: actions.runner.<org>.<name> for an organisation,
# actions.runner.<owner>-<repo>.<name> for a repository. Both shapes exist in
# the wild and the slot unit has to Conflicts= against whichever one this box
# has, or two runners fight for one GitHub session.
#
# PREFER THE VALUE svc.sh WROTE. config.sh leaves the real unit name in
# $RUNNER_ROOT/.service; deriving it is only the fallback for the window before
# registration has happened.
legacy_service_name() {
  if [ -r "$RUNNER_ROOT/.service" ]; then
    local s
    s="$(tr -d ' \r\n' < "$RUNNER_ROOT/.service")"
    if [ -n "$s" ]; then printf '%s\n' "$s"; return 0; fi
  fi
  local slug
  if [ "$CFG_scope" = "org" ]; then
    slug="$CFG_org"
  else
    slug="$(printf '%s' "$CFG_repo" | tr '/' '-')"
  fi
  printf 'actions.runner.%s.%s.service\n' "$slug" "$CFG_runnerName"
}

# Install a staged repo file, substituting the one thing the shipped copies
# hardcode: actions.runner.example-org.joggo.service, the scrubbed original's
# own unit name. Left alone, Conflicts= would point at a unit that does not
# exist on this box and the mutual exclusion the slot model depends on would be
# silently absent.
install_templated() {
  local src="$1" dst="$2" mode="$3" svc
  [ -r "$src" ] || die "staged file missing: $src" "re-run the installer; the payload stage did not complete"
  svc="$(legacy_service_name)"
  mkdir -p "$(dirname "$dst")"
  sed -e "s|actions\.runner\.example-org\.joggo\.service|${svc}|g" \
      -e "s|https://github.com/example-org/joggo|https://github.com/joggo-runner/joggo|g" \
      "$src" > "$dst.tmp" || die "could not write $dst.tmp" "check free space in the distro: df -h /"
  chmod "$mode" "$dst.tmp"
  mv -f "$dst.tmp" "$dst"
  # READ IT BACK. A sed that matched nothing and a write that half-landed both
  # exit 0. If the source carried the scrubbed placeholder, the installed copy
  # must carry THIS box's unit name instead — a Conflicts= pointing at a unit
  # that does not exist here is silently no mutual exclusion at all, and two
  # runners then fight over one GitHub session.
  [ -s "$dst" ] || die "installed $dst is empty" "check free space (df -h /) and re-run"
  if grep -q 'actions\.runner\.example-org\.joggo\.service' "$src"; then
    grep -q "$svc" "$dst" \
      || undetermined "whether the service name was substituted into $dst" \
                      "check it by hand: grep actions.runner $dst — it must name $svc"
  fi
  ok "installed $dst"
}

# ---------------------------------------------------------------- phases

phase_stage_payload() {
  # stdin: one "relative/path<TAB>base64" line per file. base64 so no file body
  # can be mistaken for the protocol and so binary content survives.
  mkdir -p "$STAGE"
  local n=0 line path b64
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line%%	*}"
    b64="${line#*	}"
    case "$path" in
      *..*|/*) die "refusing a payload path outside the stage: $path" "this is a bug in install/config.ps1" ;;
    esac
    mkdir -p "$STAGE/$(dirname "$path")"
    printf '%s' "$b64" | base64 -d > "$STAGE/$path" \
      || die "could not decode payload for $path" "re-run the installer"
    case "$path" in *.sh) chmod 0755 "$STAGE/$path" ;; *) chmod 0644 "$STAGE/$path" ;; esac
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || die "empty payload" "this is a bug in install/config.ps1"
  ok "staged $n file(s) under $STAGE"
}

# Read-only. Everything the Windows side needs in order to decide whether a step
# is already done, in one round trip.
phase_probe() {
  read_cfg
  printf 'distro_id=%s\n'   "$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-unknown}-${VERSION_ID:-}")"
  printf 'systemd=%s\n'     "$(if [ -d /run/systemd/system ]; then echo yes; else echo no; fi)"
  printf 'systemd_conf=%s\n' "$(if grep -qs '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf; then echo yes; else echo no; fi)"
  printf 'system_state=%s\n' "$(systemctl is-system-running 2>/dev/null || echo unknown)"
  printf 'user=%s\n'        "$(if id "$RUNNER_USER" >/dev/null 2>&1; then echo yes; else echo no; fi)"
  printf 'dockerd=%s\n'     "$(if command -v dockerd >/dev/null 2>&1; then echo yes; else echo no; fi)"
  printf 'docker_active=%s\n' "$(systemctl is-active docker 2>/dev/null || echo inactive)"
  printf 'docker_sock=%s\n' "$(readlink -f /var/run/docker.sock 2>/dev/null || echo none)"
  printf 'registered=%s\n'  "$(if [ -r "$RUNNER_ROOT/.credentials" ] && [ -r "$RUNNER_ROOT/.runner" ]; then echo yes; else echo no; fi)"
  printf 'dind_image=%s\n'  "$(if docker image inspect joggo/dind:local >/dev/null 2>&1; then echo yes; else echo no; fi)"
  printf 'runner_image=%s\n' "$(if docker image inspect joggo/actions-runner:local >/dev/null 2>&1; then echo yes; else echo no; fi)"
  printf 'free_disk_gb=%s\n' "$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
  printf 'legacy_service=%s\n' "$(legacy_service_name)"
}

# systemd=true is a hard prerequisite, not a nicety: svc.sh, systemctl, docker
# and every slot unit depend on it. Setting it requires restarting the distro,
# which the WINDOWS side does (only it can) — this phase just reports whether
# the file changed.
phase_wsl_conf() {
  read_cfg
  if grep -qs '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf; then
    skip "/etc/wsl.conf already has systemd=true"
    printf 'changed=0\n'
    return 0
  fi
  if [ -f /etc/wsl.conf ]; then
    cp -a /etc/wsl.conf "/etc/wsl.conf.joggo-backup.$(date -u +%Y%m%d%H%M%S)"
    if grep -qs '^\[boot\]' /etc/wsl.conf; then
      # Append under the existing [boot] section rather than adding a second
      # one: WSL reads the first occurrence and a duplicate section is how a
      # setting ends up present in the file and absent in the VM.
      awk '{ print } /^\[boot\]/ && !done { print "systemd=true"; done=1 }' /etc/wsl.conf > /etc/wsl.conf.new
      mv -f /etc/wsl.conf.new /etc/wsl.conf
    else
      printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
    fi
  else
    printf '[boot]\nsystemd=true\n' > /etc/wsl.conf
  fi
  grep -qs '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf \
    || die "wrote /etc/wsl.conf but systemd=true is not in it" "edit /etc/wsl.conf by hand: [boot] / systemd=true"
  ok "/etc/wsl.conf now sets systemd=true (read back from the file)"
  printf 'changed=1\n'
}

phase_runner_user() {
  read_cfg
  if id "$RUNNER_USER" >/dev/null 2>&1; then
    skip "user $RUNNER_USER exists (uid $(id -u "$RUNNER_USER"))"
  else
    useradd -m -s /bin/bash "$RUNNER_USER" \
      || die "could not create user $RUNNER_USER" "create it by hand: useradd -m -s /bin/bash $RUNNER_USER"
    id "$RUNNER_USER" >/dev/null 2>&1 \
      || undetermined "whether user $RUNNER_USER was created (useradd exited 0 but id does not find it)" \
                      "check /etc/passwd and NSS configuration in this distro"
    ok "created $RUNNER_USER (uid $(id -u "$RUNNER_USER")) — never root, by design"
  fi
  # The runner must own its install root; the launcher chowns the throwaway
  # volumes to this uid and the read-only bind of the root has to be readable
  # from inside the container.
  mkdir -p "$RUNNER_ROOT"
  chown "$RUNNER_USER:$RUNNER_USER" "/home/$RUNNER_USER" "$RUNNER_ROOT"
  ok "$RUNNER_ROOT owned by $RUNNER_USER"
}

phase_docker() {
  read_cfg

  # DOCKER DESKTOP IS THE WRONG ENGINE HERE, and it does not merely
  # underperform: Desktop projects its own socket into the distro from
  # /mnt/wsl, so `docker info` succeeds while there is no local daemon at all.
  # Every slot then shares one image store and build cache across repositories,
  # which is the isolation property the slot model exists to provide.
  local sock
  sock="$(readlink -f /var/run/docker.sock 2>/dev/null || true)"
  case "$sock" in
    /mnt/wsl/*|/mnt/host/*)
      die "the docker socket in this distro comes from Docker Desktop ($sock)" \
          "turn off Docker Desktop's WSL integration for this distro (Settings -> Resources -> WSL integration), then re-run. joggo needs Docker Engine NATIVE in the distro." ;;
  esac
  # A WINDOWS docker.exe ON PATH IS NOT DOCKER DESKTOP INTEGRATION, and on its own
  # it is harmless. WSL's appendWindowsPath=true projects the host PATH into every
  # distro, so whenever Docker Desktop is installed on the box -- which is common --
  # /mnt/c/Program Files/Docker/Docker/resources/bin/docker is on PATH even in a
  # distro with no integration enabled at all. The SOCKET check above is what
  # detects real integration, and it is the one that has to be fatal.
  #
  # This used to die right here, which made the rest of the phase unreachable on
  # exactly the machines that need it. A fresh distro has no native docker, so the
  # only docker on PATH is the Windows one, so the installer refused to install the
  # native engine -- the single thing that would have fixed it -- and told the
  # operator to switch off an integration that was already off. Measured on a fresh
  # Ubuntu-24.04 whose socket check had just passed, proving integration was off.
  #
  # So note it and carry on. PATH ORDER is checked at the end of this phase, once
  # /usr/bin/docker exists and the question can actually be answered.
  if command -v docker >/dev/null 2>&1; then
    case "$(readlink -f "$(command -v docker)" 2>/dev/null || true)" in
      /mnt/*) say "docker on PATH is currently the host's ($(command -v docker)); the native engine will take precedence once installed" ;;
    esac
  fi

  if command -v dockerd >/dev/null 2>&1; then
    skip "Docker Engine is installed ($(dockerd --version 2>/dev/null | head -1))"
  else
    say "installing Docker Engine (native, from get.docker.com)"
    command -v curl >/dev/null 2>&1 || die "curl is not installed in the distro" "apt-get update && apt-get install -y curl, then re-run"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh \
      || die "could not download the Docker install script" "check network from inside the distro: curl -I https://get.docker.com"
    sh /tmp/get-docker.sh >/tmp/joggo-docker-install.log 2>&1 \
      || die "the Docker install script failed (see /tmp/joggo-docker-install.log)" "read that log; the usual cause is apt being held by another process"
    rm -f /tmp/get-docker.sh
    command -v dockerd >/dev/null 2>&1 \
      || undetermined "whether Docker Engine installed (the script exited 0 but dockerd is not on PATH)" \
                      "read /tmp/joggo-docker-install.log"
    ok "Docker Engine installed"
  fi

  # Being in the docker group is root-equivalent on this host. Acceptable only
  # because the box is dedicated to CI and runs private-repo code — the same
  # trade docs/runner-setup.md §2.3 spells out.
  if id -nG "$RUNNER_USER" | tr ' ' '\n' | grep -qx docker; then
    skip "$RUNNER_USER is already in the docker group"
  else
    usermod -aG docker "$RUNNER_USER" || die "could not add $RUNNER_USER to the docker group" "usermod -aG docker $RUNNER_USER"
    id -nG "$RUNNER_USER" | tr ' ' '\n' | grep -qx docker \
      || undetermined "whether $RUNNER_USER joined the docker group" "check: id -nG $RUNNER_USER"
    ok "$RUNNER_USER added to the docker group"
  fi

  [ -d /run/systemd/system ] || die "systemd is not running in this distro" \
    "set systemd=true in /etc/wsl.conf and restart the distro (wsl --terminate), then re-run"

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker  >/dev/null 2>&1 || true

  # VERIFY THE EFFECT, not the exit code. `systemctl start` returns 0 for a unit
  # that then dies, and `docker info` can succeed against a foreign socket. The
  # pair of checks below is what distinguishes "running native daemon" from
  # both of those.
  [ "$(systemctl is-active docker 2>/dev/null)" = "active" ] \
    || die "docker.service is not active ($(systemctl is-active docker 2>/dev/null || echo 'no answer'))" \
           "journalctl -u docker --no-pager -n 50"
  local sv
  sv="$(docker info --format '{{.ServerVersion}}' 2>/dev/null || true)"
  [ -n "$sv" ] || undetermined "the Docker server version (the daemon did not answer)" \
                               "docker info ; journalctl -u docker --no-pager -n 50"
  ok "docker.service active, server $sv (asked the daemon, not the unit)"

  # PATH ORDER, checked HERE and not at the top of the phase. Before the install
  # there is legitimately no native docker to find, so the question is meaningless
  # then; now that /usr/bin/docker exists, it is the question that matters. If the
  # Windows binary still wins at this point, every `docker` call in the slot
  # scripts would talk to the host daemon instead of this distro's.
  local cli
  cli="$(readlink -f "$(command -v docker)" 2>/dev/null || true)"
  case "$cli" in
    /mnt/*) die "the native engine is active but '$cli' still wins on PATH" \
                "put /usr/bin ahead of the Windows entries, or set appendWindowsPath=false in /etc/wsl.conf and restart the distro (wsl --terminate), then re-run" ;;
    '')     undetermined "which docker CLI is on PATH" "check inside the distro: command -v docker" ;;
    *)      ok "docker CLI resolves to $cli, not the host's" ;;
  esac

  # Disk hygiene. A full disk presents as random build failures, and this box
  # fills it with build cache rather than with anything a human put there.
  if [ ! -x /etc/cron.weekly/docker-prune ]; then
    printf '#!/bin/sh\n/usr/bin/docker system prune -af --filter "until=168h" >/var/log/docker-prune.log 2>&1\n' \
      > /etc/cron.weekly/docker-prune
    chmod +x /etc/cron.weekly/docker-prune
    ok "weekly docker prune installed (/etc/cron.weekly/docker-prune)"
  else
    skip "weekly docker prune already installed"
  fi
}

# OPT-IN. Strips AAAA for the slot networks only.
#
# THE FAULT. Some hosts advertise AAAA records they cannot route. A container
# created by a slot's dind comes up WITH a link-local v6 address and no v6
# route, so glibc's AI_ADDRCONFIG does not filter AAAA and every client is
# handed an address it cannot reach. Clients that fall back cleanly (curl, pnpm)
# survive; clients that do not HANG rather than fail — which is how it cost the
# origin box a stalled production pin. dockerd's --dns-opt=no-aaaa, already in
# the launcher, covers glibc and is ignored by musl, and aquasec/trivy is
# Alpine. The resolver is the only layer that covers every client.
#
# SCOPE IS NARROW BY DESIGN: it listens only on the two slot gateways and
# forwards to the VM's own resolver. Nothing else on the box changes resolver.
# Even so this is opt-in, because it changes name resolution inside someone's
# distro.
#
# The BEHAVIOURAL proof is deliberately NOT here. The conf listens on the slot
# gateway addresses, which exist only once the slot networks do (step 70), so a
# resolution test at this point would have nothing to query. What is provable
# here is proved here; the differential test lives in phase_verify.
phase_dns_aaaa() {
  read_cfg
  if ! truthy "$CFG_filterAaaa"; then
    skip "filterAaaa is false — DNS inside the distro is left exactly as it is"
    return 0
  fi
  [ -r "$STAGE/network/filter-aaaa.conf" ] || die "staged network/filter-aaaa.conf missing" "re-run the installer"

  if ! command -v dnsmasq >/dev/null 2>&1; then
    say "installing dnsmasq (the drop-in needs it) and dig (so the effect can be measured)"
    DEBIAN_FRONTEND=noninteractive apt-get update >/tmp/joggo-dns-apt.log 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq dnsutils >>/tmp/joggo-dns-apt.log 2>&1 \
      || die "could not install dnsmasq (see /tmp/joggo-dns-apt.log)" "apt-get install -y dnsmasq dnsutils, then re-run"
    command -v dnsmasq >/dev/null 2>&1 \
      || undetermined "whether dnsmasq installed (apt exited 0 but dnsmasq is not on PATH)" "read /tmp/joggo-dns-apt.log"
  else
    skip "dnsmasq already installed"
    command -v dig >/dev/null 2>&1 \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils >>/tmp/joggo-dns-apt.log 2>&1 || true
  fi
  # dig is the instrument the verify step measures with. Without it the effect
  # cannot be checked, and an unmeasurable change is not one to make.
  command -v dig >/dev/null 2>&1 \
    || die "dig is not available, so the effect of this change could not be measured" \
           "apt-get install -y dnsutils, then re-run. The AAAA filter is not installed without a way to verify it."

  mkdir -p /etc/dnsmasq.d
  install -m 0644 "$STAGE/network/filter-aaaa.conf" /etc/dnsmasq.d/joggo-filter-aaaa.conf \
    || die "could not write /etc/dnsmasq.d/joggo-filter-aaaa.conf" "check free space: df -h /"
  cmp -s "$STAGE/network/filter-aaaa.conf" /etc/dnsmasq.d/joggo-filter-aaaa.conf \
    || undetermined "whether the drop-in was written intact (it differs from the source)" \
                    "diff $STAGE/network/filter-aaaa.conf /etc/dnsmasq.d/joggo-filter-aaaa.conf"
  ok "/etc/dnsmasq.d/joggo-filter-aaaa.conf installed (byte-identical to the source)"

  # --test checks syntax AND that this build actually supports filter-AAAA. A
  # dnsmasq without it parses the file and silently does nothing, which is the
  # worst of the three outcomes.
  dnsmasq --test >/tmp/joggo-dnsmasq-test.log 2>&1 \
    || { sed -n '1,20p' /tmp/joggo-dnsmasq-test.log >&2
         die "dnsmasq --test rejected the configuration" "read the output above; if it names filter-AAAA, this dnsmasq build does not support it and the drop-in cannot work here"; }
  ok "dnsmasq --test passes, and this build accepts filter-AAAA"

  systemctl enable --now dnsmasq >/dev/null 2>&1 || true
  [ "$(systemctl is-active dnsmasq 2>/dev/null)" = "active" ] \
    || { journalctl -u dnsmasq --no-pager -n 20 2>/dev/null | sed 's/^/    /' >&2
         die "dnsmasq is not active after being started" "the journal above names the cause; port 53 already in use is the usual one"; }
  ok "dnsmasq active (asked systemd after starting it, not assumed from the exit code)"
  say "the resolution test itself runs in step 99 — the slot gateways it listens on do not exist until step 70"
}

# Both images are built LOCALLY and live in no registry, so "present locally" is
# the only success condition the launcher accepts.
phase_images() {
  read_cfg
  [ "$(systemctl is-active docker 2>/dev/null)" = "active" ] \
    || die "docker is not active, so no image can be built" "re-run the installer; step 40-docker should have started it"

  if docker image inspect joggo/dind:local >/dev/null 2>&1; then
    skip "joggo/dind:local present ($(docker image inspect joggo/dind:local --format '{{.Id}}' | cut -c1-19))"
  else
    [ -x "$STAGE/slots/dind-image/build.sh" ] || die "staged slots/dind-image/build.sh missing" "re-run the installer"
    say "building joggo/dind:local (digest-pinned buildkit baked in; see the Dockerfile for why)"
    ( cd "$STAGE/slots/dind-image" && ./build.sh ) >/tmp/joggo-dind-build.log 2>&1 \
      || die "the dind image build failed (see /tmp/joggo-dind-build.log)" "read that log; a Docker Hub timeout is the common cause — re-run"
    docker image inspect joggo/dind:local >/dev/null 2>&1 \
      || undetermined "whether joggo/dind:local was built (build.sh exited 0 but the image is absent)" \
                      "read /tmp/joggo-dind-build.log and build by hand: $STAGE/slots/dind-image/build.sh"
    ok "built joggo/dind:local"
  fi

  # THE RUNNER IMAGE.
  #
  # run-containerized-slot.sh defaults RUNNER_IMAGE to joggo/actions-runner:local
  # and tells you to build it from tools/runner-image — a directory that does
  # not exist in this repository (it was dropped by the scrub). Without it no
  # slot can start, so the installer generates the context here.
  #
  # The three packages are not arbitrary: the launcher's own comment names them.
  # The stock ghcr.io/actions/actions-runner lacks libatomic1 (every pnpm repo
  # fails), zstd (actions/cache) and git-lfs, all of which the persistent host
  # runner had for free from the distro.
  #
  # The runner BINARIES are not baked in. The slot bind-mounts the host
  # registration's bin/ and externals/ read-only at their own absolute paths and
  # runs run.sh out of the throwaway root volume, so this image supplies the OS
  # and nothing else — which is also why it does not need rebuilding when the
  # runner self-updates.
  if docker image inspect joggo/actions-runner:local >/dev/null 2>&1; then
    skip "joggo/actions-runner:local present"
  else
    mkdir -p "$STAGE/runner-image"
    cat > "$STAGE/runner-image/Dockerfile" <<'DOCKERFILE'
# Generated by install/inside-wsl.sh. The slot's runner container: the upstream
# image plus the three packages the launcher's header says the stock one lacks.
#
# No runner binaries are added. The slot bind-mounts the host registration's
# bin/ and externals/ read-only and runs run.sh from a throwaway root volume, so
# a runner self-update does not invalidate this image.
FROM ghcr.io/actions/actions-runner:latest
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends libatomic1 zstd git-lfs curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# uid 1001 is not a guess: `id` in the upstream image and `id -u ghrunner` on
# the original host both report 1001, which is why the read-only bind of the
# runner root is readable from inside the container at all.
USER 1001
DOCKERFILE
    say "building joggo/actions-runner:local (tools/runner-image is absent from this repo; generating it)"
    docker build -t joggo/actions-runner:local "$STAGE/runner-image" >/tmp/joggo-runner-image-build.log 2>&1 \
      || die "the runner image build failed (see /tmp/joggo-runner-image-build.log)" "read that log; then: docker build -t joggo/actions-runner:local $STAGE/runner-image"
    docker image inspect joggo/actions-runner:local >/dev/null 2>&1 \
      || undetermined "whether joggo/actions-runner:local was built (docker build exited 0 but the image is absent)" \
                      "read /tmp/joggo-runner-image-build.log"
    ok "built joggo/actions-runner:local"
    docker image inspect ghcr.io/actions/actions-runner:latest --format '  base digest: {{index .RepoDigests 0}}' 2>/dev/null || true
  fi
}

# Download, register, and install the service unit for slot 1's registration.
phase_runner() {
  read_cfg
  [ -n "$CFG_runnerUrl" ] || die "no runner URL in the config" "this is a bug in install/config.ps1"

  # Already registered? Converge rather than duplicate. Re-registering with the
  # same name would work (--replace), but it would also invalidate the live
  # credentials for no reason and drop any in-flight job.
  if [ -r "$RUNNER_ROOT/.runner" ] && [ -r "$RUNNER_ROOT/.credentials" ]; then
    local have_url have_name
    have_url="$(sed -n 's/.*"gitHubUrl"[^"]*"\([^"]*\)".*/\1/p' "$RUNNER_ROOT/.runner" | head -1)"
    have_name="$(sed -n 's/.*"agentName"[^"]*"\([^"]*\)".*/\1/p' "$RUNNER_ROOT/.runner" | head -1)"
    if [ "$have_name" = "$CFG_runnerName" ]; then
      skip "registered as '$have_name' against ${have_url:-<url not readable>}"
      install_service_unit
      return 0
    fi
    warn "registered as '$have_name' but the config asks for '$CFG_runnerName' — re-registering with --replace"
  fi

  command -v curl >/dev/null 2>&1 || die "curl is not installed in the distro" "apt-get install -y curl and re-run"
  command -v tar  >/dev/null 2>&1 || die "tar is not installed in the distro"  "apt-get install -y tar and re-run"

  if [ ! -x "$RUNNER_ROOT/config.sh" ]; then
    local ver
    ver="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest 2>/dev/null \
            | sed -n 's/.*"tag_name"[^"]*"v\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$ver" ] || undetermined "the current runner version (api.github.com did not answer)" \
      "check network from the distro: curl -I https://api.github.com ; or place the tarball at $RUNNER_ROOT yourself"
    say "downloading actions-runner $ver"
    mkdir -p "$RUNNER_ROOT"
    curl -fsSL -o /tmp/joggo-runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${ver}/actions-runner-linux-x64-${ver}.tar.gz" \
      || die "could not download actions-runner $ver" "check network and retry; the URL is in the error above"
    tar -C "$RUNNER_ROOT" -xzf /tmp/joggo-runner.tar.gz \
      || die "could not unpack the runner tarball" "check free space: df -h /"
    rm -f /tmp/joggo-runner.tar.gz
    chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_ROOT"
    [ -x "$RUNNER_ROOT/config.sh" ] \
      || undetermined "whether the runner unpacked (tar exited 0 but config.sh is absent)" "ls -la $RUNNER_ROOT"
    ok "runner $ver unpacked at $RUNNER_ROOT"
    if [ -x "$RUNNER_ROOT/bin/installdependencies.sh" ]; then
      "$RUNNER_ROOT/bin/installdependencies.sh" >/tmp/joggo-runner-deps.log 2>&1 \
        || warn "installdependencies.sh failed (see /tmp/joggo-runner-deps.log). The containerised slot supplies its own OS, so this is not fatal here."
    fi
  else
    skip "runner already unpacked at $RUNNER_ROOT"
  fi

  [ -n "$CFG_registrationToken" ] || die "no registration token" \
    "mint one and pass -Token, or set \$env:JOGGO_TOKEN. It expires in about an hour and is never stored."

  say "registering '$CFG_runnerName' against $CFG_runnerUrl"
  # --replace: a ghost entry with the same name usually survives server-side and
  # blocks a fresh registration without it.
  # The token reaches config.sh as an argument because config.sh takes no other
  # form. That is the one exposure window in this installer; it is local, root
  # only, and seconds long.
  sudo -u "$RUNNER_USER" -H bash -c 'cd "$1" && ./config.sh --url "$2" --token "$3" --name "$4" --labels "$5" --unattended --replace' \
    _ "$RUNNER_ROOT" "$CFG_runnerUrl" "$CFG_registrationToken" "$CFG_runnerName" "$CFG_labels" \
    || die "config.sh failed to register the runner" \
           "the usual cause is an EXPIRED token (they last ~1h) — mint a fresh one and re-run. For scope=repo check the repo exists and you have admin on it."

  # PROVE IT. config.sh prints a success banner on paths that leave no
  # credentials behind, and the launcher refuses to start without all three of
  # these files.
  for f in .runner .credentials .credentials_rsaparams; do
    [ -r "$RUNNER_ROOT/$f" ] || undetermined "whether registration completed ($RUNNER_ROOT/$f is missing)" \
      "re-run with a fresh token; if it persists, remove $RUNNER_ROOT and let the installer re-download"
  done
  local nm
  nm="$(sed -n 's/.*"agentName"[^"]*"\([^"]*\)".*/\1/p' "$RUNNER_ROOT/.runner" | head -1)"
  [ "$nm" = "$CFG_runnerName" ] || undetermined "the registered runner name (.runner says '${nm:-empty}')" \
    "inspect $RUNNER_ROOT/.runner"
  ok "registered: .runner says agentName='$nm' (read back from disk, not from config.sh's banner)"

  install_service_unit
}

# svc.sh's unit is installed but left DISABLED and STOPPED on purpose.
#
# One registration holds exactly one GitHub session, so this unit and the slot
# units cannot both run — joggo-slot@.service carries Conflicts= against it.
# Keeping it installed-but-off makes the documented rollback a single command
# instead of a re-registration:
#
#   systemctl disable --now joggo-slot@1 && systemctl start <this unit>
install_service_unit() {
  local svc
  if [ -r "$RUNNER_ROOT/.service" ]; then
    svc="$(tr -d ' \r\n' < "$RUNNER_ROOT/.service")"
    skip "runner service unit already installed ($svc)"
  else
    ( cd "$RUNNER_ROOT" && ./svc.sh install "$RUNNER_USER" ) >/tmp/joggo-svc-install.log 2>&1 \
      || die "svc.sh install failed (see /tmp/joggo-svc-install.log)" "read that log; systemd must be running in the distro"
    [ -r "$RUNNER_ROOT/.service" ] \
      || undetermined "the runner service unit name (svc.sh exited 0 but wrote no .service file)" \
                      "read /tmp/joggo-svc-install.log"
    svc="$(tr -d ' \r\n' < "$RUNNER_ROOT/.service")"
    ok "runner service unit installed: $svc"
  fi
  # svc.sh enables and may start it. The slot model replaces it, so turn it off
  # and say so rather than leaving two runners to discover each other at boot.
  systemctl disable --now "$svc" >/dev/null 2>&1 || true
  if [ "$(systemctl is-active "$svc" 2>/dev/null)" = "active" ]; then
    die "$svc is still active and would fight the slots for the one GitHub session" \
        "systemctl disable --now $svc, then re-run"
  fi
  ok "$svc left installed but disabled — it is the one-command rollback from the slot model, not a second runner"
}

phase_slots() {
  read_cfg
  [ -r "$RUNNER_ROOT/.credentials" ] || die "slot 1 is not registered" "re-run; step 60-runner must succeed first"

  install_templated "$STAGE/slots/run-containerized-slot.sh" /usr/local/sbin/run-containerized-slot.sh 0755
  install_templated "$STAGE/slots/slot-pause.sh"             /usr/local/sbin/joggo-pause                  0755
  if [ -r "$STAGE/slots/slots-status.sh" ]; then
    install_templated "$STAGE/slots/slots-status.sh"         /usr/local/sbin/joggo-slots-status            0755
  fi
  install_templated "$STAGE/slots/systemd/joggo-slot@.service" /etc/systemd/system/joggo-slot@.service 0644

  # POINT THE SLOT DAEMONS AT THE FILTER, if it was installed.
  #
  # Installing the drop-in alone changes nothing for builds: dind hands its
  # children the VM's resolver unless it is told otherwise, so the filter would
  # sit there listening and never be asked. network/filter-aaaa.conf's own
  # INSTALL section says to add --dns="$SLOT_GATEWAY" next to --dns-opt, and
  # this is that edit — applied to the INSTALLED copy under /usr/local/sbin, not
  # to the repo.
  if truthy "$CFG_filterAaaa"; then
    local launcher=/usr/local/sbin/run-containerized-slot.sh
    if grep -q -- '--dns="\$SLOT_GATEWAY"' "$launcher"; then
      skip "the installed launcher already points dind at the slot gateway"
    else
      sed -i 's|^\( *\)--dns-opt=no-aaaa |\1--dns="$SLOT_GATEWAY" \\\n\1--dns-opt=no-aaaa |' "$launcher"
      grep -q -- '--dns="\$SLOT_GATEWAY"' "$launcher" \
        || undetermined "whether the launcher was pointed at the AAAA filter (the --dns-opt line was not found to anchor on)" \
                        "add --dns=\"\$SLOT_GATEWAY\" to the dind 'docker run' in $launcher by hand; see network/filter-aaaa.conf"
      bash -n "$launcher" \
        || die "the launcher does not parse after adding --dns" "restore it: re-run the installer without -FilterAaaa"
      ok "installed launcher now starts dind with --dns=\$SLOT_GATEWAY (and it still passes bash -n)"
    fi
  fi

  # The pause flag directory is the CONTRACT between slot-pause, the launcher
  # and the memory guard: /var/lib/joggo-slot/<N>.paused. (README quotes
  # /var/lib/joggo-slot; the scripts have always used joggo-slot, and the scripts
  # are what runs.)
  mkdir -p /var/lib/joggo-slot /var/log/joggo-slots /var/lib/runner-watchdog
  systemctl daemon-reload

  [ -f /etc/systemd/system/joggo-slot@.service ] \
    || undetermined "whether the slot template unit installed" "ls -l /etc/systemd/system/joggo-slot@.service"
  systemctl cat joggo-slot@1.service >/dev/null 2>&1 \
    || undetermined "whether systemd can read the slot template (systemctl cat joggo-slot@1 failed)" \
                    "systemctl cat joggo-slot@1.service"
  ok "slot template unit readable by systemd (systemctl cat joggo-slot@1 succeeded)"

  # ---- additional slots ----
  #
  # A SLOT IS A REGISTRATION, not a unit instance. Two instances pointed at one
  # .credentials do not run two jobs: the second loses the session and retries
  # about every 95 seconds forever. slots/add-slot.sh prepares the second root
  # and strips the copied credentials; registering it is still a separate
  # config.sh call.
  local n
  n=2
  while [ "$n" -le "${CFG_slots:-1}" ]; do
    local dst="/home/${RUNNER_USER}/actions-runner-${n}"
    if [ -r "$dst/.credentials" ]; then
      skip "slot $n already has its own registration at $dst"
    else
      if [ "$RUNNER_USER" != "ghrunner" ]; then
        die "slots/add-slot.sh hardcodes /home/ghrunner/actions-runner but runnerUser is '$RUNNER_USER'" \
            "either install with -RunnerUser ghrunner, or run with -Slots 1 and add slots by hand"
      fi
      [ -x "$STAGE/slots/add-slot.sh" ] || die "staged slots/add-slot.sh missing" "re-run the installer"
      say "preparing slot $n (copies the runner root, strips the copied credentials)"
      RUNNER_USER="$RUNNER_USER" "$STAGE/slots/add-slot.sh" "$n" >/tmp/joggo-add-slot-$n.log 2>&1
      local rc=$?
      if [ "$rc" != "0" ] && [ "$rc" != "3" ]; then
        sed -n '1,40p' /tmp/joggo-add-slot-$n.log >&2
        die "add-slot.sh $n failed (rc=$rc, see /tmp/joggo-add-slot-$n.log)" "read that log; a job in flight is the common refusal — wait for 'joggo-pause status' to read 'job in flight: none'"
      fi
      [ -d "$dst" ] || undetermined "whether slot $n's runner root was created" "read /tmp/joggo-add-slot-$n.log"

      [ -n "$CFG_registrationToken" ] || die "no token left to register slot $n" "re-run with a fresh -Token"
      # SAME labels so GitHub dispatches the same jobs. DIFFERENT name. NO
      # --replace: that would take over slot 1's identity and leave one runner
      # looking like two.
      sudo -u "$RUNNER_USER" -H bash -c 'cd "$1" && ./config.sh --url "$2" --token "$3" --name "$4" --labels "$5" --unattended' \
        _ "$dst" "$CFG_runnerUrl" "$CFG_registrationToken" "${CFG_runnerName}-${n}" "$CFG_labels" \
        || die "registering slot $n failed" \
               "a registration token can be reused while it is valid, so the usual cause is EXPIRY. Mint a fresh one and re-run, or register by hand: sudo -u $RUNNER_USER bash -c 'cd $dst && ./config.sh --url $CFG_runnerUrl --token <TOKEN> --name ${CFG_runnerName}-${n} --labels $CFG_labels --unattended'"
      for f in .runner .credentials .credentials_rsaparams; do
        [ -r "$dst/$f" ] || undetermined "whether slot $n registered ($dst/$f missing)" "register it by hand; the command is in the error above"
      done
      ok "slot $n registered as ${CFG_runnerName}-${n} with its own credentials"
    fi
    n=$((n+1))
  done

  n=1
  while [ "$n" -le "${CFG_slots:-1}" ]; do
    systemctl enable "joggo-slot@${n}.service" >/dev/null 2>&1 \
      || die "could not enable joggo-slot@${n}" "systemctl enable joggo-slot@${n}; then journalctl -xe"
    [ "$(systemctl is-enabled "joggo-slot@${n}.service" 2>/dev/null)" = "enabled" ] \
      || undetermined "whether joggo-slot@${n} is enabled" "systemctl is-enabled joggo-slot@${n}"
    ok "joggo-slot@${n} enabled (read back from systemd; started in step 95)"
    n=$((n+1))
  done
}

phase_watchdog() {
  read_cfg
  install_templated "$STAGE/watchdog/runner-watchdog.sh" /usr/local/sbin/runner-watchdog.sh 0755
  install_templated "$STAGE/watchdog/systemd/runner-watchdog.service" /etc/systemd/system/runner-watchdog.service 0644
  install_templated "$STAGE/watchdog/systemd/runner-watchdog.timer"   /etc/systemd/system/runner-watchdog.timer   0644

  # Self-heal layer 2 for the persistent unit: svc.sh ships no Restart=, so a
  # listener that EXITS leaves CI dead until a human notices. Harmless with the
  # slot model (that unit is disabled), and exactly right if anyone rolls back.
  local svc
  svc="$(legacy_service_name)"
  if [ -r "$STAGE/watchdog/systemd/actions-runner-restart-override.conf" ]; then
    mkdir -p "/etc/systemd/system/${svc}.d"
    install_templated "$STAGE/watchdog/systemd/actions-runner-restart-override.conf" \
                      "/etc/systemd/system/${svc}.d/override.conf" 0644
  fi

  mkdir -p /var/lib/runner-watchdog
  systemctl daemon-reload
  systemctl enable --now runner-watchdog.timer >/dev/null 2>&1 \
    || die "could not enable runner-watchdog.timer" "systemctl enable --now runner-watchdog.timer; journalctl -xe"

  # VERIFY the timer is armed, not merely that systemctl exited 0. A timer can be
  # enabled and have no next elapse (a bad OnCalendar, a missing unit).
  [ "$(systemctl is-enabled runner-watchdog.timer 2>/dev/null)" = "enabled" ] \
    || undetermined "whether runner-watchdog.timer is enabled" "systemctl is-enabled runner-watchdog.timer"
  [ "$(systemctl is-active runner-watchdog.timer 2>/dev/null)" = "active" ] \
    || die "runner-watchdog.timer is enabled but not active" "systemctl start runner-watchdog.timer; journalctl -u runner-watchdog.timer"
  local nxt
  nxt="$(systemctl show runner-watchdog.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
  if [ -z "$nxt" ] || [ "$nxt" = "0" ]; then
    # Monotonic timers (OnBootSec/OnUnitActiveSec, which is what this one uses)
    # report their next elapse in the monotonic field instead.
    nxt="$(systemctl show runner-watchdog.timer -p NextElapseUSecMonotonic --value 2>/dev/null)"
  fi
  [ -n "$nxt" ] && [ "$nxt" != "0" ] \
    || undetermined "when runner-watchdog.timer next fires (systemd reports no next elapse)" \
                    "systemctl list-timers runner-watchdog.timer"
  ok "runner-watchdog.timer enabled and active, next elapse reported by systemd"

  # Run the watchdog in --check mode. It never acts in that mode, and it proves
  # the thing a timer cannot: that the script resolves a live target and runs.
  if /usr/local/sbin/runner-watchdog.sh --check >/tmp/joggo-watchdog-check.log 2>&1; then
    sed -n '1,12p' /tmp/joggo-watchdog-check.log | sed 's/^/    /'
    ok "runner-watchdog.sh --check ran clean (it never acts in --check)"
  else
    sed -n '1,20p' /tmp/joggo-watchdog-check.log | sed 's/^/    /' >&2
    warn "runner-watchdog.sh --check exited non-zero. The timer is armed, but the watchdog cannot assess the runner yet — this is expected before any slot has written a Runner_*.log, and must be re-checked after the first job."
  fi

  # The reboot re-runner. Installed, but only enabled when its auth actually
  # exists: it reaches GitHub through the WINDOWS gh.exe over interop so no
  # token lives on this box, and without that it would run every boot and do
  # nothing.
  if [ -r "$STAGE/watchdog/rerun-after-reboot.sh" ]; then
    install_templated "$STAGE/watchdog/rerun-after-reboot.sh" /usr/local/sbin/joggo-rerun-after-reboot.sh 0755
    install_templated "$STAGE/watchdog/systemd/rerun-after-reboot.service" /etc/systemd/system/rerun-after-reboot.service 0644
    mkdir -p /etc/joggo-rerun
    if [ ! -f /etc/joggo-rerun/repos ]; then
      if [ "$CFG_scope" = "repo" ]; then
        printf '%s\n' "$CFG_repo" > /etc/joggo-rerun/repos
        ok "/etc/joggo-rerun/repos seeded with $CFG_repo"
      else
        printf '# One owner/repo per line. The reboot re-runner only retries runs in these repos.\n' > /etc/joggo-rerun/repos
        warn "/etc/joggo-rerun/repos is empty: with scope=org there is no single repo to seed. Add the repos you want retried after a reboot, one owner/repo per line."
      fi
    fi
    systemctl daemon-reload
    if [ -x "/mnt/c/Program Files/GitHub CLI/gh.exe" ]; then
      systemctl enable rerun-after-reboot.service >/dev/null 2>&1 || true
      [ "$(systemctl is-enabled rerun-after-reboot.service 2>/dev/null)" = "enabled" ] \
        && ok "rerun-after-reboot.service enabled (uses the Windows gh.exe over interop; no token on this box)" \
        || warn "rerun-after-reboot.service could not be enabled; check: systemctl enable rerun-after-reboot.service"
    else
      warn "rerun-after-reboot.service installed but NOT enabled: the Windows gh.exe is not at /mnt/c/Program Files/GitHub CLI/gh.exe, which is how it authenticates without storing a token. Install GitHub CLI on Windows, 'gh auth login', then: systemctl enable rerun-after-reboot.service"
    fi
  fi
}

phase_boot() {
  read_cfg
  systemctl enable docker >/dev/null 2>&1 || true
  local n=1
  while [ "$n" -le "${CFG_slots:-1}" ]; do
    local unit="joggo-slot@${n}.service"
    if truthy "$CFG_startOnBoot"; then
      systemctl enable "$unit" >/dev/null 2>&1 || true
    fi
    systemctl start "$unit" >/dev/null 2>&1 || true

    # A SLOT IS LEGITIMATELY 'inactive' FOR A MOMENT between every job: it runs
    # run.sh --once, exits cleanly, and systemd restarts it. So "active" is not
    # the right test on its own, and neither is "inactive" evidence of failure.
    # What must hold is: enabled, and either active or restarting — and NOT
    # failed.
    local st sub
    st="$(systemctl is-active "$unit" 2>/dev/null || true)"
    sub="$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)"
    if [ "$st" = "failed" ]; then
      journalctl -u "$unit" --no-pager -n 25 2>/dev/null | sed 's/^/    /' >&2
      die "$unit is FAILED" "the journal above names the cause. Common ones: a missing image (step 50), or a clock skew the launcher refuses to start on."
    fi
    case "$st" in
      active|activating|deactivating) ok "$unit is $st (SubState=$sub)" ;;
      '')  undetermined "the state of $unit (systemctl gave no answer)" "systemctl status $unit" ;;
      *)   # inactive right after `start` means it exited immediately.
           journalctl -u "$unit" --no-pager -n 25 2>/dev/null | sed 's/^/    /' >&2
           die "$unit is '$st' immediately after being started" "the journal above names the cause" ;;
    esac
    if truthy "$CFG_startOnBoot"; then
      [ "$(systemctl is-enabled "$unit" 2>/dev/null)" = "enabled" ] \
        || undetermined "whether $unit is enabled for boot" "systemctl enable $unit"
      ok "$unit enabled for boot"
    fi
    n=$((n+1))
  done
}

# ---------------------------------------------------------------- verify
#
# PROVE, do not assert. Every line below is a reading taken after the fact, and
# anything that cannot be read is a FAILURE with a named follow-up.
phase_verify() {
  read_cfg
  local fails=0
  v_ok()   { printf '  PASS  %s\n' "$*"; }
  v_fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails+1)); }
  v_unk()  { printf '  FAIL  could not determine %s\n' "$*"; fails=$((fails+1)); }
  v_warn() { printf '  WARN  %s\n' "$*"; }

  # systemd
  local ss
  ss="$(systemctl is-system-running 2>/dev/null || true)"
  case "$ss" in
    running|degraded) v_ok "systemd is '$ss' (degraded is normal in WSL2: some host units never apply)" ;;
    '')               v_unk "systemd state (systemctl gave no answer)" ;;
    *)                v_fail "systemd is '$ss' — svc.sh, docker and the slot units all need it" ;;
  esac

  # docker, native
  local sv sock
  sv="$(docker info --format '{{.ServerVersion}}' 2>/dev/null || true)"
  sock="$(readlink -f /var/run/docker.sock 2>/dev/null || true)"
  if [ -z "$sv" ]; then v_unk "the Docker server version (the daemon did not answer)"
  else
    case "$sock" in
      /mnt/wsl/*|/mnt/host/*) v_fail "docker answers, but through Docker DESKTOP's socket ($sock). joggo needs the native engine." ;;
      *) v_ok "docker $sv, native in the distro (socket $sock)" ;;
    esac
  fi

  # images
  for img in joggo/dind:local joggo/actions-runner:local; do
    if docker image inspect "$img" >/dev/null 2>&1
      then v_ok "image $img present locally (it is in no registry; present-locally is the only success condition)"
      else v_fail "image $img is absent — no slot can start without it"
    fi
  done

  # registration(s)
  local n=1 root
  while [ "$n" -le "${CFG_slots:-1}" ]; do
    if [ "$n" = "1" ]; then root="$RUNNER_ROOT"; else root="/home/${RUNNER_USER}/actions-runner-${n}"; fi
    if [ -r "$root/.credentials" ] && [ -r "$root/.runner" ]; then
      v_ok "slot $n has its OWN registration at $root ($(sed -n 's/.*"agentName"[^"]*"\([^"]*\)".*/\1/p' "$root/.runner" | head -1))"
    else
      v_fail "slot $n has no registration at $root — a slot is a registration, not a unit instance"
    fi
    n=$((n+1))
  done

  # units
  n=1
  while [ "$n" -le "${CFG_slots:-1}" ]; do
    local unit="joggo-slot@${n}.service"
    local en st
    en="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    st="$(systemctl is-active  "$unit" 2>/dev/null || true)"
    if [ -z "$en" ]; then v_unk "whether $unit is enabled"
    elif [ "$en" != "enabled" ]; then v_fail "$unit is '$en' — it will not come back after a reboot"
    else v_ok "$unit enabled"
    fi
    case "$st" in
      active|activating) v_ok "$unit $st" ;;
      inactive) v_warn "$unit is inactive. With run.sh --once that is NORMAL between jobs — judged below on the listener log, not on this." ;;
      failed)   v_fail "$unit is FAILED (journalctl -u $unit)" ;;
      '')       v_unk "the state of $unit" ;;
      *)        v_warn "$unit is '$st'" ;;
    esac
    n=$((n+1))
  done

  # THE ONE THAT MATTERS: is the runner actually online and able to take a job?
  #
  # 'enabled' and 'active' both say nothing about whether GitHub has it. The
  # local proof is the listener's own log line, which it writes only after it
  # has authenticated and connected. Waiting for it also covers the first cold
  # start (p50 44s, p90 69s, max 139s measured over 75 starts).
  n=1
  while [ "$n" -le "${CFG_slots:-1}" ]; do
    local diag="/var/log/joggo-slots/${n}/_diag" waited=0 found=''
    while [ "$waited" -lt 180 ]; do
      if [ -d "$diag" ]; then
        found="$(grep -l 'Listening for Jobs' "$diag"/Runner_*.log 2>/dev/null | tail -1)"
        [ -n "$found" ] && break
      fi
      sleep 5
      waited=$((waited+5))
    done
    if [ -n "$found" ]; then
      v_ok "slot $n listener reported 'Listening for Jobs' in $(basename "$found") after ${waited}s — it authenticated and connected"
    else
      printf '    last 15 journal lines for joggo-slot@%s:\n' "$n"
      journalctl -u "joggo-slot@${n}.service" --no-pager -n 15 2>/dev/null | sed 's/^/      /'
      v_unk "whether slot $n is online (no 'Listening for Jobs' in $diag within 180s). 'enabled' and 'active' do not answer this."
    fi
    n=$((n+1))
  done

  # Second instrument, at a different layer, when one is available. The local
  # log says the listener connected; only GitHub says GitHub agrees.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    local api out
    if [ "$CFG_scope" = "org" ]; then api="orgs/$CFG_org/actions/runners"; else api="repos/$CFG_repo/actions/runners"; fi
    out="$(gh api "$api" --jq '.runners[] | "\(.name) \(.status) \(.busy)"' 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/    github: /'
      if printf '%s' "$out" | grep -q "^${CFG_runnerName} online"; then
        v_ok "GitHub reports '$CFG_runnerName' ONLINE (second instrument, different layer)"
      else
        v_fail "GitHub does not report '$CFG_runnerName' as online — see the list above"
      fi
    else
      v_warn "gh is authenticated but $api returned nothing; falling back to the listener log above"
    fi
  else
    v_warn "gh is absent or not authenticated, so GitHub's own view could not be read. The listener-log check above is the local proof; confirm 'Idle / online' on the Runners page yourself."
  fi

  # watchdog
  if truthy "$CFG_watchdog"; then
    local en st
    en="$(systemctl is-enabled runner-watchdog.timer 2>/dev/null || true)"
    st="$(systemctl is-active  runner-watchdog.timer 2>/dev/null || true)"
    if [ "$en" = "enabled" ] && [ "$st" = "active" ]; then
      v_ok "runner-watchdog.timer enabled and active ($(systemctl list-timers runner-watchdog.timer --no-pager --no-legend 2>/dev/null | head -1 | sed 's/  */ /g'))"
    elif [ -z "$en" ] || [ -z "$st" ]; then v_unk "the state of runner-watchdog.timer"
    else v_fail "runner-watchdog.timer is enabled=$en active=$st"
    fi
  fi

  # THE AAAA FILTER, measured rather than asserted.
  #
  # A DIFFERENTIAL TEST WITH A POSITIVE CONTROL IN THE SAME PASS. Asking the
  # filter for a AAAA record and getting nothing back proves nothing on its own:
  # an empty answer is exactly what a broken resolver, a host with no AAAA
  # record, or a dropped packet also produce. So the upstream is asked the same
  # question first. Only "upstream HAS AAAA and the filter does NOT" is
  # evidence; if the control comes back empty the test is void and says so.
  if truthy "$CFG_filterAaaa"; then
    if ! command -v dig >/dev/null 2>&1; then
      v_unk "whether the AAAA filter works (dig is not installed, so there is no instrument)"
    elif [ "$(systemctl is-active dnsmasq 2>/dev/null)" != "active" ]; then
      v_fail "dnsmasq is not active, so the AAAA filter is not in effect"
    else
      local probe_host=www.google.com up_aaaa fl_aaaa gw=10.201.1.1
      up_aaaa="$(dig +short +time=3 +tries=1 @10.255.255.254 AAAA "$probe_host" 2>/dev/null | grep -c ':' || true)"
      if [ "${up_aaaa:-0}" = "0" ]; then
        v_unk "whether the AAAA filter works: the POSITIVE CONTROL failed — the upstream resolver returned no AAAA for $probe_host, so an empty answer from the filter would mean nothing"
      elif ! ip -o addr show 2>/dev/null | grep -q "$gw"; then
        v_unk "whether the AAAA filter works: $gw does not exist yet, so the filter cannot be queried. It is created with the slot network on the slot's first start — re-check after the first job"
      else
        fl_aaaa="$(dig +short +time=3 +tries=1 "@$gw" AAAA "$probe_host" 2>/dev/null | grep -c ':' || true)"
        if [ "${fl_aaaa:-0}" = "0" ]
          then v_ok "AAAA filter works: upstream returns $up_aaaa AAAA for $probe_host, the filter on $gw returns 0 (differential test, positive control passed)"
          else v_fail "AAAA filter is NOT filtering: $gw still returned $fl_aaaa AAAA record(s) for $probe_host"
        fi
      fi
    fi
  fi

  # the pause lever, which is the contract the guard drives the slots through
  if [ -x /usr/local/sbin/joggo-pause ] && [ -d /var/lib/joggo-slot ]; then
    v_ok "pause lever installed: /usr/local/sbin/joggo-pause, flags in /var/lib/joggo-slot (the guard holds slots through this)"
  else
    v_fail "the pause lever is missing — the memory guard has no way to hold a slot, so it would go straight to restarting the VM"
  fi

  printf 'verify_failures=%s\n' "$fails"
  [ "$fails" = "0" ] || exit 1
}

# ---------------------------------------------------------------- uninstall
#
# Reverse order, and it never guesses. Deregistration needs a FRESH token
# (config.sh remove will not accept the old one, and the one used at install is
# long expired) — without one it says exactly what to run rather than failing
# obscurely or leaving the caller thinking it succeeded.
phase_remove() {
  read_cfg
  local deep=0
  for a in "$@"; do [ "$a" = "--deep" ] && deep=1; done

  local n="${CFG_slots:-1}"
  while [ "$n" -ge 1 ]; do
    local unit="joggo-slot@${n}.service"
    if systemctl cat "$unit" >/dev/null 2>&1; then
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      say "disabled $unit"
    fi
    n=$((n-1))
  done

  for u in runner-watchdog.timer runner-watchdog.service rerun-after-reboot.service; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u"
  done
  rm -f /etc/systemd/system/joggo-slot@.service
  systemctl daemon-reload
  say "units removed"

  # Deregister every slot that has its own registration.
  n=1
  while [ "$n" -le "${CFG_slots:-1}" ]; do
    local root
    if [ "$n" = "1" ]; then root="$RUNNER_ROOT"; else root="/home/${RUNNER_USER}/actions-runner-${n}"; fi
    if [ ! -r "$root/.credentials" ]; then
      skip "slot $n is not registered"
    elif [ -n "$CFG_registrationToken" ]; then
      ( cd "$root" && sudo -u "$RUNNER_USER" -H ./config.sh remove --token "$CFG_registrationToken" ) >/tmp/joggo-remove-$n.log 2>&1 \
        && ok "slot $n deregistered" \
        || warn "slot $n deregistration failed (see /tmp/joggo-remove-$n.log). It will linger as an OFFLINE entry; remove it on the Runners page by hand."
    else
      warn "slot $n NOT deregistered: no fresh token was given."
      warn "  Deregistration needs a NEW registration token — the one used at install has expired."
      warn "  Mint one, then: sudo -u $RUNNER_USER bash -c 'cd $root && ./config.sh remove --token <TOKEN>'"
      warn "  Or delete the runner on the Runners page. Skipping it leaves an offline entry that blocks the same name later."
    fi
    n=$((n+1))
  done

  # The runner service unit, if svc.sh installed one.
  if [ -r "$RUNNER_ROOT/.service" ]; then
    ( cd "$RUNNER_ROOT" && ./svc.sh uninstall ) >/dev/null 2>&1 || true
    say "runner service unit uninstalled"
  fi

  # Docker objects the slots own. ONLY by their deterministic names: this box
  # also runs the operator's dev databases and a broad prune would eat them.
  if docker info >/dev/null 2>&1; then
    n=1
    while [ "$n" -le 8 ]; do
      docker rm -f -v "joggo-runner-$n" "joggo-dind-$n" >/dev/null 2>&1 || true
      docker volume rm "joggo-slot-${n}-work" "joggo-slot-${n}-root" "joggo-slot-${n}-diag" >/dev/null 2>&1 || true
      docker network rm "joggo-slot-$n" >/dev/null 2>&1 || true
      n=$((n+1))
    done
    docker image rm -f joggo/dind:local joggo/actions-runner:local >/dev/null 2>&1 || true
    say "slot containers, volumes, networks and the two local images removed (by exact name only)"
  else
    warn "docker did not answer, so slot containers/volumes/networks were NOT removed. Remove them when it is back: docker ps -a --filter name=joggo-"
  fi

  rm -f /usr/local/sbin/run-containerized-slot.sh /usr/local/sbin/joggo-pause \
        /usr/local/sbin/joggo-slots-status /usr/local/sbin/runner-watchdog.sh \
        /usr/local/sbin/joggo-rerun-after-reboot.sh
  # The AAAA drop-in, if it was installed. dnsmasq itself is left alone: this
  # installer may not have been what put it on the box.
  if [ -f /etc/dnsmasq.d/joggo-filter-aaaa.conf ]; then
    rm -f /etc/dnsmasq.d/joggo-filter-aaaa.conf
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
      systemctl restart dnsmasq >/dev/null 2>&1 \
        && ok "AAAA drop-in removed and dnsmasq restarted — it no longer filters" \
        || warn "AAAA drop-in removed but dnsmasq would not restart, so it is STILL running the old config. Fix: systemctl restart dnsmasq"
    else
      ok "AAAA drop-in removed (dnsmasq was not running)"
    fi
  fi

  rm -rf /var/lib/joggo-slot /var/lib/runner-watchdog "$STAGE"
  say "scripts and state removed (/var/log/joggo-slots kept: it holds the job logs)"

  if [ "$deep" = "1" ]; then
    warn "--deep: removing the runner roots and the docker package"
    n=1
    while [ "$n" -le "${CFG_slots:-1}" ]; do
      if [ "$n" = "1" ]; then rm -rf "$RUNNER_ROOT"; else rm -rf "/home/${RUNNER_USER}/actions-runner-${n}"; fi
      n=$((n+1))
    done
    systemctl disable --now docker >/dev/null 2>&1 || true
    say "docker disabled. The package and the distro are left in place: removing them is a Windows-side decision."
  else
    say "the distro, Docker and the runner roots are left alone (pass -Deep to remove the roots too)"
  fi
}

# ---------------------------------------------------------------- dispatch

case "$PHASE" in
  stage-payload) phase_stage_payload ;;
  probe)         phase_probe ;;
  wsl-conf)      phase_wsl_conf ;;
  runner-user)   phase_runner_user ;;
  docker)        phase_docker ;;
  dns-aaaa)      phase_dns_aaaa ;;
  images)        phase_images ;;
  runner)        phase_runner ;;
  slots)         phase_slots ;;
  watchdog)      phase_watchdog ;;
  boot)          phase_boot ;;
  verify)        phase_verify ;;
  remove)        phase_remove "$@" ;;
  ''|-h|--help)
    say "usage: inside-wsl.sh <phase>   with the config JSON on stdin"
    say "phases: stage-payload probe wsl-conf runner-user docker dns-aaaa images runner slots watchdog boot verify remove"
    exit 2 ;;
  *) die "unknown phase: $PHASE" "one of: stage-payload probe wsl-conf runner-user docker dns-aaaa images runner slots watchdog boot verify remove" ; exit 2 ;;
esac
