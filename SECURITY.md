# Security

## Reporting

Open a GitHub security advisory on this repository, or a normal issue if the
problem is not exploitable. There is no private email address for this project.

## The one rule this project is built around

**No privileged secrets live on the runner box.**

A self-hosted runner executes code from every repository allowed to use it. On a
machine that also holds your own files, in your own home, on your own network,
that is the whole threat model in one sentence. So:

- The runner authenticates with a *registration token*, which is short-lived and
  is never stored. `docs/recovery.md` explains how to mint one when a
  registration is lost, and why that step is deliberately left manual.
- Nothing here needs an org-admin PAT. The one place that would have been
  convenient — automating re-registration — is left undone on purpose, and
  `docs/recovery.md` §5 says so.
- Jobs run in a container, against a per-slot Docker daemon, on a throwaway
  volume. `--once` means one job per runner process, so a job cannot see the
  next job's workspace.
- `tailscale/acl.hujson` is default-deny. Only admin devices reach the box, and
  only for SSH.

## What this project does not protect you from

A self-hosted runner is only as trustworthy as the repositories allowed to
target it. **Do not point a public repository's pull-request workflows at a
runner on a machine you care about.** A PR from a stranger is arbitrary code on
your hardware. GitHub's own documentation says the same thing more politely.
