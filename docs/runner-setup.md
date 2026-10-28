# Self-Hosted CI Runner — WSL2 Setup Runbook (long form)

**If you only want it working, use [`quickstart.md`](quickstart.md) and `install.ps1`.** This page
is the reference: what each step does, why it is there, and what it costs. Read it when the
installer fails a check you do not understand, or when you want to deviate from it.

**Target:** **Windows 10 2004+ or Windows 11, x86-64, with Ubuntu in WSL2.** That is the only
supported configuration. There is no native-Ubuntu and no Hyper-V/VirtualBox path: every
Windows-side tool in this repo (the memory guard, the sampler, the monitor, the day report, the
keepalive task) talks to the WSL VM from the Windows host, so a Linux-only install leaves half the
repo unusable.

**Audience:** the human operator, or an agent working on the box with them. Execute top to bottom.
Stop at every **🧑 OPERATOR** marker — those need a human: a secret, a browser login, or a physical
decision. Run the `bash` blocks **inside the distro** and the `powershell` blocks **on the Windows
host**, elevated where it says so.

---

## 0. Mental model (read first — it drives every choice below)

- **The runner is outbound-only.** It polls `api.github.com` over HTTPS and pulls jobs. It needs
  **no open ports, no port-forwarding, no public IP.** Do **not** expose it to the internet.
- **The runner executes other people's code on your hardware, inside your network.** Whatever it
  builds and pushes to the registry is downstream of everything the allowed repositories can say,
  so a compromise of this PC is a path into anything that pulls those images. That is why the
  hardening below — private repos only, no stored credentials, default-deny firewall — is part of
  the install and not an optional extra.
- **The runner group is the security boundary.** On an organisation that is
  `Settings → Actions → Runner groups`. On a **personal account** there are no runner groups, so
  the boundary is the set of repositories you register the runner to, one at a time. Either way it
  is a list of repositories you chose deliberately, and it is the whole threat model.
- **Least privilege:** the runner stores no production, cloud, or SSH credentials. It needs to push
  images, and that is done with the workflow's own `GITHUB_TOKEN` (`permissions: packages: write`)
  — no long-lived registry PAT on this box.
- **Management access, if you need it at all, is Tailscale — never port-forwarding.** See §3, which
  is optional.

---

## 1. Prerequisites

### 1.1 Host

- **Windows 10 2004+ or Windows 11**, x86-64. The images this box builds are `linux/amd64`.
- **WSL2** (not WSL1), with an Ubuntu 22.04 or 24.04 distro, and **`systemd=true`** in that distro
  (§2.1). systemd is not negotiable: `svc.sh`, docker, the slot units and the watchdog timer all
  depend on it.
- **Virtualization enabled in firmware.** Discovering this halfway through an install is the most
  annoying way to fail; `install.ps1 -PreflightOnly` checks it before changing anything.
- **No Docker Desktop.** This repo uses Docker Engine native inside the distro. Docker Desktop
  providing the socket in the distro fights it; stop and disable it.
- **≥40 GB free on the system drive**, and ≥20 GB free inside the distro.
- **Wired ethernet preferred**, and the box must never sleep — Windows side *and* Linux side
  (§2.1, §2.4). An asleep runner is a CI outage for every repository pointed at it. A small UPS is
  ideal.

### 1.2 Memory, and what it buys you

**Floor: 8 GB. Under 12 GB, expect to feel it** — Docker image builds are memory-hungry, and this
box's worst measured moment was 445 MB available. The installer does not fight your hardware; it
scales to it:

| RAM | Slots | Guard warn | Guard critical |
|---|---|---|---|
| under 12 GB | 1 | 15% of RAM | 7.5% of RAM |
| 12–32 GB | 2 | 15% of RAM | 7.5% of RAM |
| above 32 GB | 3 | 15% of RAM | 7.5% of RAM |

The guard's published thresholds — **warn 2500 MB, critical 1200 MB** — are those same 15% and
7.5% figures on the 16 GB box they were measured on. They are percentages of *your* RAM, not
constants. Do not move them to make a symptom go away;
[`memory-pressure.md`](memory-pressure.md) is what they cost to find.

### 1.3 Accounts and access

- A GitHub **organisation owner** (for `-Scope org`) **or** admin on a single repository (for
  `-Scope repo`, the personal-account path). Runner groups are an organisation feature; a personal
  account registers the runner per repository instead.
- Local **administrator** on the Windows box, and `sudo` inside the distro.
- **Tailscale is optional.** It is only for reaching a headless box from somewhere else. If the
  machine is on your desk, skip §3 entirely — you do not need a Tailscale account, and nothing
  else in this repo requires one.

Fill these in before starting:

| Variable | Value |
|----------|-------|
| `GH_SCOPE` | `org` or `repo` |
| `GH_TARGET` | `example-org`, or `owner/name` for a single repo |
| `WSL_DISTRO` | `Ubuntu-24.04` |
| `RUNNER_USER` | `ghrunner` (dedicated unprivileged user we create) |
| `RUNNER_LABELS` | `self-hosted,linux,x64,joggo` |
| `ADMIN_TAILNET_DEVICE` | only if you are doing §3 |

---

## 2. Preparing the box

### 2.1 Windows host — WSL2, systemd, and staying awake

These are the WSL2-specific concerns, and skipping any one of them makes the runner stop silently
rather than loudly.

**Install WSL2 and the distro** (elevated PowerShell; a reboot may be needed after the optional
features go on):

```powershell
wsl --install --no-distribution       # enables the WSL + VM Platform features
wsl --install -d Ubuntu-24.04
wsl --set-default-version 2
wsl -l -v                             # confirm VERSION is 2, not 1
```

**Enable systemd**, inside the distro — nothing else in this runbook works without it:

```bash
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
```

Then, from Windows, `wsl --shutdown` to apply it. Reopen the distro and confirm
`systemctl is-system-running` returns `running` (or `degraded`).

**Keep the distro alive.** This is the one people miss. WSL powers a distro off about 30 seconds
after the last session into it closes — measured: right after the installer exits — which kills
the runner even with systemd configured. **systemd alone does not keep it up.** A Windows
scheduled task holds a session open. The installer registers it (`joggo-wsl-keepalive`); by hand:

🧑 OPERATOR, ordinary PowerShell — no elevation needed (adjust `-d` to your distro name):

```powershell
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action    = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" `
               -Argument '--headless "C:\Windows\System32\wsl.exe" -d Ubuntu-24.04 --exec sleep infinity'
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $me
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'joggo-wsl-keepalive' -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

**It runs as you, at logon — not as SYSTEM, and not "with nobody logged on".** WSL distros are
registered per Windows user, so a SYSTEM task cannot see yours: it starts and exits -1 within
seconds. (An earlier version of this page showed exactly that task and promised it would work
logged off; it never did.) The consequence is real: **the box must stay logged in** — lock the
screen, don't log off. To get CI back after a reboot without someone signing in, turn on Windows
auto-logon for that account; that is a security trade-off for you to make, not something the
installer does. `conhost --headless` keeps the session from holding a console window open on the
desktop. Verify after a reboot and logon: the runner shows online in GitHub.

**Disable Windows sleep — a different thing from disabling Linux sleep.** Masking `sleep.target`
in the distro (§2.4) does nothing if *Windows* sleeps: the VM suspends and CI stops regardless.

🧑 OPERATOR (Windows host): **Settings → System → Power → Sleep = Never**, on battery and plugged
in. On a laptop also **Control Panel → Power Options → Choose what closing the lid does → "Do
nothing."** Disable sleep in the BIOS/UEFI while you are there.

### 2.2 Base tools and a dedicated runner user

Inside the distro:

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl jq git ca-certificates ufw unattended-upgrades
sudo systemctl enable --now unattended-upgrades   # auto security patches

sudo useradd -m -s /bin/bash ghrunner            # never run the runner as root
sudo usermod -aG sudo ghrunner                   # setup only; removed at §6.4
```

### 2.3 Docker Engine (native, not Docker Desktop)

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ghrunner          # lets the runner build images without sudo
sudo systemctl enable --now docker
```

> ⚠️ Being in the `docker` group is **root-equivalent** on this host. That is acceptable **only**
> because the box runs trusted (private-repo) code, is network-isolated, and stores no credentials.

### 2.4 Never sleep, Linux side

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

This covers the Linux half only. The Windows half is in §2.1 and matters more.

---

## 3. Remote management via Tailscale — OPTIONAL

**Skip this section if the box is on your desk.** Nothing in this repo requires Tailscale or a
Tailscale account. It exists for one case: a headless box you need to reach from another machine
without exposing anything publicly.

### 3.1 Install and bring it up

Recent WSL2 ships `/dev/net/tun`, so Tailscale runs **inside the distro** under systemd. Check
first:

```bash
test -e /dev/net/tun && echo "TUN available — run Tailscale inside the distro" \
  || echo "No TUN — install Tailscale for Windows on the host instead, and manage the distro via wsl"
```

With TUN:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --hostname joggo --advertise-tags=tag:ci
```

🧑 OPERATOR: a browser auth URL prints — open it, log in, approve the device. `--ssh` enables
Tailscale SSH (no separate sshd; access is governed by tailnet ACLs). `--advertise-tags=tag:ci`
labels the machine so ACLs can target it.

Without TUN: install **Tailscale for Windows** on the host, advertise `tag:ci` from there, and
manage the runner with `wsl -d Ubuntu-24.04 ...` over a host-level session.

### 3.2 Make it a stable server node

🧑 OPERATOR: Tailscale admin console → Machines → `joggo` → **disable key expiry**, so it does not
drop off the tailnet every few months.

### 3.3 Lock it down with ACLs

🧑 OPERATOR: admin console → **Access Controls**. [`tailscale/acl.hujson`](../tailscale/acl.hujson)
in this repo is the default-deny policy; adapt the emails and tags:

```json
{
  "tagOwners": { "tag:ci": ["autogroup:owner"], "tag:admin": ["autogroup:owner"] },
  "acls": [
    // Only admin devices may reach the CI box, and only for SSH management.
    { "action": "accept", "src": ["tag:admin"], "dst": ["tag:ci:22"] }
    // (No rule grants anyone else access to tag:ci → default-deny applies.)
  ],
  "ssh": [
    { "action": "accept", "src": ["tag:admin"], "dst": ["tag:ci"], "users": ["ghrunner", "root"] }
  ]
}
```

Then tag your work machine `tag:admin` (Machines → that device → Edit ACL tags). Result: only
`tag:admin` devices can see or SSH the runner.

---

## 4. Firewall — default-deny inbound, and where the real boundary is

The runner needs **no** inbound from anywhere.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0          # only if you did §3; drop this line otherwise
sudo ufw --force enable
sudo ufw status verbose
```

**Know which layer is actually protecting you.** WSL2 is already NAT-isolated from your LAN by
Windows: nothing in the distro is reachable from off the PC **unless you add a Windows `netsh
portproxy`**. So do not add one. Keep `ufw` inside the distro as defence in depth, but the outer
boundary is **Windows Firewall** — plus the tailnet ACLs if you did §3 — not `ufw`.

If you ever lock yourself out, the physical console still works.

---

## 5. Install and register the runner

### 5.1 Get a registration token

🧑 OPERATOR, depending on scope:

- **Organisation:** `https://github.com/organizations/<org>/settings/actions/runners/new` → Linux x64.
- **Personal account / single repo:** `https://github.com/<owner>/<repo>/settings/actions/runners/new`
  → Linux x64.

Copy the **registration token**. It is short-lived (~1 hour) and must never be committed, logged,
or written to a config file — see [`../SECURITY.md`](../SECURITY.md). Minting it is deliberately a
human step; [`recovery.md`](recovery.md) §5 explains why automating it is left undone.

### 5.2 Download the runner

**Take the current release.** Do not pin a version out of this document — it will be stale by the
time you read it. Check `https://github.com/actions/runner/releases` and use what is there:

```bash
sudo -iu ghrunner bash <<'EOF'
set -euo pipefail
mkdir -p ~/actions-runner && cd ~/actions-runner
RUNNER_VERSION="<the current release tag, without the leading v>"
curl -fsSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf runner.tar.gz && rm runner.tar.gz
EOF
```

The version is not baked in anywhere afterwards. The runner unpacks `bin` and `externals` as
symlinks to version-stamped directories (`bin.<version>`, `externals.<version>`), and
[`slots/run-containerized-slot.sh`](../slots/run-containerized-slot.sh) **resolves those symlinks at
slot start** rather than hardcoding a path, so a runner self-update does not break the slots. If you
find a runner version written down in this repo's docs, that is a bug in the docs.

### 5.3 Configure

🧑 OPERATOR provides `REG_TOKEN`, then:

```bash
# organisation scope — one registration serves every repo you allow
sudo -iu ghrunner bash -c '
  cd ~/actions-runner &&
  ./config.sh \
    --url https://github.com/example-org \
    --token <REG_TOKEN> \
    --name joggo \
    --labels self-hosted,linux,x64,joggo \
    --unattended --replace'
```

For a **personal account** the only change is the URL — `https://github.com/<owner>/<repo>` — and
that you repeat the registration for each repository that needs the runner, because there is no
runner group to put it in.

`--replace` matters: a ghost entry with the same name usually survives server-side and blocks a
fresh registration without it.

### 5.4 Install as a service

```bash
cd /home/ghrunner/actions-runner
sudo ./svc.sh install ghrunner
sudo ./svc.sh start
sudo ./svc.sh status
```

The runner should now show **Idle / online** on the Runners page.

For the containerised multi-slot setup rather than one plain persistent runner, carry on into
[`adding-a-slot.md`](adding-a-slot.md). That is what the installer builds by default, and §6.5 is
why — including what it costs.

---

## 6. Hardening (do not skip — this box can reach whatever pulls its images)

### 6.1 Private repositories ONLY — never public, never fork PRs

🧑 OPERATOR:

- **Organisation:** Settings → Actions → Runner groups. Create a group (these docs call it
  `joggo-runners`), restrict it to selected **private** repositories, and leave **"Allow public
  repositories" unchecked**.
- **Personal account:** there are no runner groups. The boundary is the set of repositories you
  registered the runner to (§5.3). Register it only to private repositories you control, and treat
  adding a registration as the same decision an org owner makes on the group page.

Either way: **Settings → Actions → General → Fork PR workflows** → keep "Require approval for all
outside collaborators", or stricter. A malicious PR would otherwise execute on this machine, inside
your network. GitHub warns against self-hosted plus public for exactly this reason.

### 6.2 Least-privilege registry auth (no stored PAT here)

On the **repo side**, the build workflow pushes with the built-in token:

```yaml
permissions:
  contents: read
  packages: write          # lets GITHUB_TOKEN push to GHCR — no long-lived PAT on the runner
```

So this box stores **no** registry, cloud, SSH, or production secrets. Verify none exist:

```bash
sudo -iu ghrunner bash -c 'cat ~/.docker/config.json 2>/dev/null; ls -la ~/.aws ~/.ssh 2>/dev/null' || true
```

### 6.3 Disk hygiene (Docker build cache fills disks → builds start failing)

```bash
sudo tee /etc/cron.weekly/docker-prune >/dev/null <<'EOF'
#!/bin/sh
/usr/bin/docker system prune -af --filter "until=168h" >/var/log/docker-prune.log 2>&1
EOF
sudo chmod +x /etc/cron.weekly/docker-prune
```

Watch inodes as well as bytes. They exhaust separately, and the symptom reads as "disk full" only
if you look.

### 6.4 Drop setup privileges

```bash
sudo deluser ghrunner sudo   # the runner user no longer needs sudo after install
```

### 6.5 Ephemeral, isolated jobs — and what they cost

A persistent runner reuses one environment across jobs, so a poisoned build persists. The
containerised slots in [`adding-a-slot.md`](adding-a-slot.md) fix that: each job runs in a fresh
container with its own Docker daemon and a throwaway work volume, via `run.sh --once`.

That is not free, and the price is specific. **`--once` costs 83–108 seconds of container rebuild
per job, measured**, and GitHub's runner-acquisition timeout races that rebuild at **every** job
boundary. An 11-job workflow therefore gets eleven chances to die with *"not acquired by Runner of
type self-hosted"*, not one. On one repository that killed **~11% of jobs**. Persisting the Docker
daemon and network while recreating only the runner container would recover most of it; that is not
done here. Decide with that number in front of you.

---

## 7. Route the build jobs to this runner (repo side)

Full client-side runbook: [`onboarding-a-repo.md`](onboarding-a-repo.md). The short version — in
each project's build workflow, change `runs-on` from `ubuntu-latest` to the runner's labels, and
keep a path filter so no-op commits do not build:

```yaml
on:
  push:
    branches: [main]
    paths: ['apps/**', 'packages/**', 'docker/**', 'pnpm-lock.yaml', 'package.json']
jobs:
  build-and-push:
    runs-on: [self-hosted, linux, x64, joggo]
    # ...
```

> Optional resilience: keeping `ubuntu-latest` as a fallback label means CI still runs (on paid
> minutes) when this PC is down. Omit it and accept "PC down = CI paused."

---

## 8. Verification

On the box:

```bash
sudo /home/ghrunner/actions-runner/svc.sh status   # active (running)
sudo ufw status verbose                            # deny incoming
docker run --rm hello-world                        # docker works for the build user context
systemctl is-system-running                        # running or degraded — never "offline"
```

```powershell
Get-ScheduledTask -TaskName 'WSL2-keepalive'       # Ready or Running
```

🧑 OPERATOR: confirm the runner shows **online / idle** in GitHub, then trigger a tiny workflow
(`runs-on: [self-hosted, linux, x64, joggo]`, `run: echo ok`) and watch it go green with zero
GitHub-hosted minutes consumed. **An install that has not produced a green build is not finished.**

If you did §3: `tailscale ping joggo` succeeds from an allowed `tag:admin` device,
`ssh ghrunner@joggo` connects over Tailscale, and a non-allowed device cannot see the box at all.

---

## 9. Ongoing ops checklist

- [ ] Runner shows online after a Windows reboot (keepalive task + enabled units).
- [ ] `WSL2-keepalive` still registered, and the distro still comes up with nobody logged on.
- [ ] Weekly `docker system prune` keeps disk healthy (`/var/log/docker-prune.log`).
- [ ] `unattended-upgrades` applying security patches.
- [ ] Runner group — or, on a personal account, the registered repository list — still private-only.
- [ ] No production, cloud, or SSH secrets present on the box.
- [ ] Guard thresholds still match the box's RAM if the hardware changed (§1.2).
- [ ] If you did §3: key expiry still disabled, ACLs still restricted to `tag:admin`.

---

## 10. Security summary

- **No public attack surface:** outbound-only runner, default-deny firewall, WSL2 NAT isolation, no
  `portproxy`.
- **Reachable only by machines you chose**, if remotely reachable at all — §3 is optional.
- **Least privilege:** dedicated unprivileged user, no production/cloud/SSH credentials, registry
  push via the short-lived per-job `GITHUB_TOKEN`.
- **Trusted code only:** private repositories, no public repos, no fork PRs from outside
  collaborators.
- **Bounded blast radius:** worst case is "can push an image" — which is only bounded if whatever
  consumes those images health-gates and can roll back. Check that it does before believing this
  bullet.
