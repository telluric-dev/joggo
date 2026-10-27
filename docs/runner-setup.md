# Self-Hosted CI Runner — Home PC Setup Runbook

**Audience:** an AI agent (Claude) running **on the home PC** that will become the CI/CD build
machine, plus the human operator. Execute top to bottom. Stop and ask the operator at every
**🧑 OPERATOR** marker (these need a human: secrets, a browser login, or a physical decision).

**Goal:** turn an always-on home PC into a free, org-wide GitHub Actions self-hosted runner that
builds Docker images for all of the org's projects and pushes them to the container registry —
with **no public inbound exposure**, reachable for management **only from specific computers**.

---

## 0. Mental model (read first — it drives every choice below)

- **The runner is outbound-only.** It polls `api.github.com` over HTTPS and pulls jobs. It needs
  **no open ports, no port-forwarding, no public IP.** Do **not** expose it to the internet.
- **The runner is part of the production supply chain.** Whatever image it pushes to the registry
  gets auto-deployed by the production box's pull loop. So a compromise of this PC ≈ a path to
  production. That's why the hardening below (private-repos-only, network isolation, firewall,
  least-privilege) is **mandatory, not optional**, for a healthcare/PHI app.
- **Management access uses Tailscale, not port-forwarding.** The PC joins a private mesh VPN; only
  ACL-approved devices can reach it. No SSH is ever exposed to the public internet.
- **Least privilege:** the runner does **not** store production, AWS, or SSH credentials. It only
  needs to push images, and that's done with the workflow's built-in `GITHUB_TOKEN`
  (`permissions: packages: write`) — no long-lived registry PAT on this box.

---

## 1. Assumptions & prerequisites

- **OS:** Ubuntu 22.04 or 24.04 LTS, **x86-64** (must match production's x86 images).
  - 🧑 OPERATOR: If the PC runs **Windows**, do one of: (a) dedicate it with a clean Ubuntu install
    (best for a build box), or (b) run Ubuntu in an always-on **Hyper-V/VirtualBox VM** or **WSL2**.
    A native or VM Ubuntu is cleaner than WSL2 for an unattended service. Confirm which before continuing.
- **Hardware:** ≥4 GB RAM (Docker image builds are memory-hungry), ≥40 GB free disk, wired
  ethernet preferred (stable, and the box should never sleep).
- **Power/uptime:** the PC must stay on. Disable sleep/hibernate (Step 2.4). A small UPS is ideal.
- **Accounts the operator must have:** GitHub org owner access (`example-org`), a Tailscale account
  (free tier is fine), `sudo` on this PC.

Fill these in before starting:

| Variable | Value |
|----------|-------|
| `GH_ORG` | `example-org` |
| `RUNNER_USER` | `ghrunner` (dedicated unprivileged user we create) |
| `RUNNER_LABELS` | `self-hosted,linux,x64,marathon` |
| `ADMIN_TAILNET_DEVICE` | the operator's laptop/desktop hostname in Tailscale (for ACLs) |

---

## 2. OS preparation

### 2.1 Update + base tools
```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl jq git ca-certificates ufw unattended-upgrades
sudo systemctl enable --now unattended-upgrades   # auto security patches
```

### 2.2 Dedicated unprivileged runner user (never run the runner as root)
```bash
sudo useradd -m -s /bin/bash ghrunner
sudo usermod -aG sudo ghrunner   # only for setup; we remove this at Step 6.4
```

### 2.3 Install Docker Engine (native, not Docker Desktop)
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ghrunner          # lets the runner build images without sudo
sudo systemctl enable --now docker
```
> ⚠️ Being in the `docker` group is **root-equivalent** on this host. That is acceptable **only**
> because this box is dedicated to CI, network-isolated, and runs trusted (private-repo) code.

### 2.4 Never sleep (an asleep runner = CI outage for every project)
```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```
🧑 OPERATOR: also disable sleep in the BIOS/UEFI and the desktop power settings if present.

---

## 3. Remote management via Tailscale (the "only specific computers" requirement)

This is how you reach the PC from your work machine **without exposing anything publicly**.

### 3.1 Install + bring up Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --hostname marathon --advertise-tags=tag:ci
```
🧑 OPERATOR: a browser auth URL prints — open it, log into Tailscale, approve the device.
`--ssh` enables **Tailscale SSH** (no separate sshd needed; access is governed by tailnet ACLs).
`--advertise-tags=tag:ci` labels this machine so ACLs can target it.

### 3.2 Make it a stable server node
🧑 OPERATOR: in the Tailscale admin console → Machines → `marathon` → **disable key expiry**
(so it doesn't drop off the tailnet every ~6 months).

### 3.3 Lock down with ACLs — only approved devices may reach this box
🧑 OPERATOR: in the Tailscale admin console → **Access Controls**, set (adapt emails/tags):
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
Then tag the operator's work machine `tag:admin` (Machines → that device → Edit ACL tags).
Result: **only `tag:admin` devices can even see/SSH the runner** — exactly "specific computers only."

---

## 4. Host firewall — default-deny inbound, management only over the tailnet

The runner needs **no** inbound from anywhere. Allow inbound **only** on the Tailscale interface.
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0          # management/SSH only over the private mesh
sudo ufw --force enable
sudo ufw status verbose
```
> This blocks **all** public inbound (including LAN SSH). Tailscale itself works fine — it's
> outbound + NAT-traversal, so it needs no inbound `ufw` rule. If you ever lock yourself out,
> the operator can use the physical console.

---

## 5. Install the GitHub Actions runner (org-level → serves every repo)

### 5.1 Get a registration token
🧑 OPERATOR: GitHub → `example-org` org → **Settings → Actions → Runners → New runner →
New self-hosted runner** (Linux x64). Copy the **registration token** shown (it's short-lived,
~1 hour). Paste it to the agent as `REG_TOKEN` when prompted — **do not commit it anywhere.**

### 5.2 Download + configure as the `ghrunner` user
```bash
sudo -iu ghrunner bash <<'EOF'
set -euo pipefail
mkdir -p ~/actions-runner && cd ~/actions-runner
# Pin to the current runner release (check https://github.com/actions/runner/releases for latest):
RUNNER_VERSION="2.319.1"
curl -fsSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf runner.tar.gz && rm runner.tar.gz
EOF
```
🧑 OPERATOR: provide `REG_TOKEN`, then the agent runs (replace `<REG_TOKEN>`):
```bash
sudo -iu ghrunner bash -c '
  cd ~/actions-runner &&
  ./config.sh \
    --url https://github.com/example-org \
    --token <REG_TOKEN> \
    --name marathon \
    --labels self-hosted,linux,x64,marathon \
    --unattended --replace'
```

### 5.3 Install as a service (survives reboots, starts on boot)
```bash
cd /home/ghrunner/actions-runner
sudo ./svc.sh install ghrunner
sudo ./svc.sh start
sudo ./svc.sh status
```
The runner should now show **Idle / online** in the org Runners page.

---

## 6. Hardening (do not skip — this box can reach production)

### 6.1 Private repositories ONLY — never public/fork PRs
🧑 OPERATOR: GitHub org → Settings → Actions → Runners → runner groups: restrict the runner group
to selected **private** repos. **Never** allow public repos or runs from outside-contributor PRs —
a malicious PR would execute on this machine/your home LAN. (GitHub explicitly warns against
self-hosted + public.)

### 6.2 Workflow uses least-privilege registry auth (no stored PAT here)
On the **repo side** (not this PC), the build workflow should push with the built-in token:
```yaml
permissions:
  contents: read
  packages: write          # lets GITHUB_TOKEN push to GHCR — no long-lived PAT on the runner
```
So this box stores **no** registry/AWS/SSH/production secrets. Verify none exist:
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

### 6.4 Drop setup privileges
```bash
sudo deluser ghrunner sudo   # runner user no longer needs sudo after install
```

### 6.5 (Phase-2 hardening, recommended before launch) Ephemeral, isolated jobs
The persistent runner above reuses one environment across jobs. Before you go live, upgrade to
**ephemeral** runners (`./config.sh ... --ephemeral`, re-registered per job by a small loop or
the Actions Runner Controller) and/or run each job in a throwaway container, so a poisoned build
can't persist. Track this as a launch-blocker task; persistent is fine for pre-launch testing.

---

## 7. Route the build jobs to this runner (repo side)

In each project's build workflow, change the build job's `runs-on` from `ubuntu-latest` to the
self-hosted label, and keep a path filter so no-op commits don't build:
```yaml
on:
  push:
    branches: [main]
    paths: ['apps/**', 'packages/**', 'docker/**', 'pnpm-lock.yaml', 'package.json']
jobs:
  build-and-push:
    runs-on: [self-hosted, linux, x64, marathon]
    # ...
```
> Optional resilience: if you also keep `ubuntu-latest` as a fallback label, CI still runs (on paid
> GitHub minutes) when this PC is down. For pure cost-min pre-launch, omit the fallback and accept
> "PC down = CI paused."

---

## 8. Verification

**On the PC (this agent):**
```bash
sudo /home/ghrunner/actions-runner/svc.sh status   # active (running)
sudo ufw status verbose                              # deny incoming; allow in on tailscale0
tailscale status                                     # marathon up, tag:ci
docker run --rm hello-world                          # docker works for the build user context
```
🧑 OPERATOR: confirm the runner shows **online/idle** in GitHub org → Runners.

**From the operator's machine (we'll do this together):**
- `tailscale ping marathon` → succeeds (you're an allowed `tag:admin` device).
- `ssh ghrunner@marathon` over Tailscale → connects (Tailscale SSH).
- From a **non-allowed** device → cannot see or reach `marathon` (ACL default-deny). ✅
- Trigger a tiny test workflow (`runs-on: [self-hosted, marathon]`, `run: echo ok`) → it executes on
  the PC and goes green, **with zero GitHub-hosted minutes consumed**.

---

## 9. Ongoing ops checklist
- [ ] Runner shows online after a PC reboot (service auto-starts).
- [ ] Weekly `docker system prune` keeps disk healthy (`/var/log/docker-prune.log`).
- [ ] `unattended-upgrades` applying security patches.
- [ ] Tailscale key expiry disabled; ACLs still restrict to `tag:admin`.
- [ ] Runner group still restricted to private repos only.
- [ ] No production/AWS/SSH secrets present on the box.
- [ ] (Pre-launch exit) Migrate to ephemeral/isolated jobs, or to managed CodeBuild, before going live.

---

## 10. Security summary (why this is safe enough for pre-launch)
- **No public attack surface:** outbound-only runner + default-deny firewall + Tailscale-only mgmt.
- **Reachable only by specific computers:** Tailscale ACLs (`tag:admin` → `tag:ci`).
- **Least privilege:** dedicated unprivileged user, no prod/AWS/SSH creds, registry push via
  short-lived `GITHUB_TOKEN`.
- **Trusted code only:** private repos, no public/fork PRs.
- **Bounded blast radius:** worst case is "can push an image" — and the production box still
  independently health-gates + auto-rolls-back a bad image. Tighten to ephemeral builds before launch.

---

## 11. WSL2 addendum (REQUIRED when the runner runs inside WSL2 on Windows)

If, instead of a native/VM Ubuntu, you run the runner inside **WSL2 Ubuntu** on a Windows PC,
the Linux steps above (§5 runner, §6 hardening, §3 Tailscale, §4 ufw) are **unchanged** — but
WSL2 adds four host-level concerns the runbook would otherwise miss. Do all four, or the runner
will silently stop. Run the `wsl.conf`/`/etc/wsl.conf` edits **inside the distro** and the
PowerShell/Settings steps **on the Windows host**.

### 11.1 Enable systemd in WSL2 (prerequisite for every `systemctl` / `svc.sh` / docker / tailscale step)
Without systemd, none of the runbook's service commands work. Inside the distro:
```bash
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
```
Then **from Windows PowerShell** apply it:
```powershell
wsl --shutdown
```
Reopen the distro and confirm: `systemctl is-system-running` returns `running` (or `degraded`).

### 11.2 Keep the distro alive across logout/idle (THE big one)
WSL2 shuts the VM down shortly after its last process exits or when you log off — which kills the
runner even though systemd is configured. systemd alone does **not** keep the VM up. Fix: a Windows
Task Scheduler task that holds the distro open 24/7.

🧑 OPERATOR (on the Windows host, elevated PowerShell — adjust `-d Ubuntu` to the distro name):
```powershell
$action  = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument '-d Ubuntu --exec sleep infinity'
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'WSL2-keepalive' -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```
This runs **whether or not a user is logged on**, at startup, so WSL2 + systemd (docker, tailscale,
the runner service) stay up with nobody logged in. Verify after a reboot: from a logged-off state,
`tailscale ping marathon` from an admin device should still succeed.

### 11.3 Disable **Windows** sleep, not just Linux (§2.4 is insufficient here)
The runbook's `systemctl mask sleep.target` only covers the Linux side. If **Windows** sleeps, the
WSL2 VM suspends and CI stops regardless.
🧑 OPERATOR (Windows host): **Settings → System → Power → Sleep = Never** (both battery & plugged-in).
If it's a laptop: **Control Panel → Power Options → Choose what closing the lid does → "Do nothing."**

### 11.4 Tailscale: run it **inside the distro** if TUN is available; otherwise fall back to the host
Recent WSL2 ships `/dev/net/tun`, so `tailscale up` (runbook §3) works **inside the distro**, started
by systemd — §3 applies as-is. Check first:
```bash
test -e /dev/net/tun && echo "TUN available — run Tailscale inside WSL (use §3 as-is)" \
  || echo "No TUN — install Tailscale on the WINDOWS HOST instead and reach the distro via host → wsl"
```
If TUN is missing: install **Tailscale for Windows** on the host, advertise `tag:ci` from there, and
manage the runner via `wsl -d Ubuntu ...` from a host-level SSH session.

### 11.5 Firewall layering (don't accidentally open WSL2 to the LAN)
WSL2 is already **NAT-isolated** from your LAN by Windows — nothing in the distro is reachable from
outside the PC **unless you add a Windows `netsh portproxy`**. So **don't add one.** Keep `ufw` inside
the distro (§4) as defense-in-depth, but understand the real outer boundary is **Windows Firewall +
the Tailscale ACLs**, not `ufw`.

> **Net:** the Linux runner/hardening steps are unchanged. The WSL2-specific work is exactly:
> systemd-on (§11.1) + keep-alive task (§11.2) + Windows-sleep-off (§11.3) + Tailscale-with-TUN (§11.4).
