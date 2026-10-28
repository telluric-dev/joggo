# Client-Side CI Runbook — Use the Self-Hosted Runner From a Project Repo

**Audience:** a developer (or an AI agent) on **any computer**, working in a repo that should build
its Docker images on the self-hosted runner (`joggo`) instead of paid GitHub-hosted minutes. The
runner itself is already set up — see [`quickstart.md`](quickstart.md) for the install and
[`runner-setup.md`](runner-setup.md) for the long form. This document is the **consumer** side:
what you add **inside a project repo**.

**Goal:** push to a repo → a build runs on `joggo` → an x86-64 image lands in GHCR → production
pulls it. **No secrets, no PAT, no runner software** live in the project repo — only a workflow file.

---

## 0. Mental model (read first)

```
your repo  ──push──►  GitHub Actions  ──dispatches job──►  joggo (home PC, outbound-only)
                                                              │ builds x86-64 image
                                                              │ pushes with per-job GITHUB_TOKEN
                                                              ▼
                                                         ghcr.io/example-org/<image>
                                                              │
                                                              ▼
                                                production box pulls + auto-deploys
```

- The project repo contributes **one workflow file**. That's the entire client footprint.
- On an organisation the runner is **org-level**, so any approved repo can use it — you install
  nothing. On a **personal account** there are no runner groups, so the runner is registered to
  each repository individually (`-Scope repo`); the client-side workflow below is identical either
  way.
- Auth to push the image uses the **per-job `GITHUB_TOKEN`** (minted fresh, expires when the job
  ends). The repo stores **no** long-lived registry credential.
- The reusable build logic lives once in this repo:
  [.github/workflows/build-and-push.yml](../.github/workflows/build-and-push.yml). Project repos
  **call** it; they don't copy it.

---

## 1. Prerequisites (one-time, per repo — needs whoever owns the runner)

Before a repo's jobs will run on `joggo`, someone must allow that repo. This is the security gate
from [`runner-setup.md`](runner-setup.md) §6.1 — self-hosted runners must never be exposed to public or fork code.

🧑 **Organisation owner:** **Settings → Actions → Runner groups → `joggo-runners`** — add the repo
to the group's repository access, and confirm **"Allow public repositories"** stays **unchecked**.
If the group is set to *All repositories*, nothing stands between any public repo in the org and
the runner; prefer selected repositories.

🧑 **Personal account:** there are no runner groups. Register the runner to this repository
(`install.ps1 -Scope repo -Repo <owner>/<name>`, or `config.sh --url
https://github.com/<owner>/<name>`), which is the same decision in a different place — that
registered list *is* the boundary.

Either way, the repo being onboarded must be **private**.

Hard rules:
- ✅ The repo must be **private**. Never route a public repo onto `joggo`.
- ✅ **Settings → Actions → General → Fork PR workflows**: keep "Require approval for all outside
  collaborators" (or stricter). A self-hosted runner must not execute untrusted fork code.

---

## 2. The fast path — call the reusable workflow (recommended)

Add **`.github/workflows/ci.yml`** to your project repo. This delegates all build logic to the
shared reusable workflow, so every repo stays a few lines:

```yaml
name: CI
on:
  push:
    branches: [main]
    # Only rebuild when something that affects the image changes:
    paths: ['apps/**', 'packages/**', 'docker/**', 'Dockerfile', 'pnpm-lock.yaml', 'package.json']
  workflow_dispatch:        # allows manual "Run workflow" from the Actions tab

jobs:
  build:
    uses: example-org/joggo/.github/workflows/build-and-push.yml@main
    with:
      image-name: my-service        # optional; defaults to the repo name
      context: .
      dockerfile: ./Dockerfile
      # platforms: linux/amd64       # default; must match production
      # push: true                   # default; set false for build-only PR checks
    permissions:
      contents: read
      packages: write                # REQUIRED so the job's GITHUB_TOKEN can push to GHCR
```

That's it. The reusable workflow already:
- runs on `runs-on: [self-hosted, linux, x64, joggo]`,
- logs into GHCR with the job's `GITHUB_TOKEN`,
- tags the image (`sha-<commit>`, branch name, and `latest` on the default branch;
  pass `publish-latest: false` to suppress `latest` when this repo publishes SEVERAL
  images and something downstream keys off it — see the IMAGE ORDERING note in
  `.github/workflows/build-and-push.yml`),
- builds `linux/amd64` and pushes to `ghcr.io/example-org/<image-name>`.

> **Pin for safety:** `@main` always tracks the latest reusable workflow. For reproducibility you
> can pin to a tag or commit SHA instead, e.g. `...build-and-push.yml@v1` — bump it deliberately.

### Multi-image repos + custom tags
If your repo builds **more than one image** (e.g. an `api` and a `web`), or needs **bare `<sha>`**
tags instead of the default `sha-<sha>`, use the `images` and `tag-format` inputs:

```yaml
  build:
    uses: example-org/joggo/.github/workflows/build-and-push.yml@main
    with:
      tag-format: sha                 # bare <sha> + latest on default branch (also: prefixed-sha [default], sha-short)
      build-args: |                   # applied to EVERY image
        GIT_SHA=${{ github.sha }}
      images: |
        [
          { "name": "myapp-api", "dockerfile": "./api/Dockerfile", "context": "." },
          { "name": "myapp-web", "dockerfile": "./web/Dockerfile", "context": ".",
            "build-args": "NEXT_PUBLIC_API_URL=https://api.example.com" }
        ]
    permissions: { contents: read, packages: write }
```
Each image builds as its own matrix leg (parallel, isolated build cache). Per-image `build-args` are
merged with the global ones. Omit `images` for the single-image fast path above.

### Isolated tests (containerized, no port collisions)
For a **test** job that needs Postgres, use the reusable `node-test.yml` instead of running services
directly. It runs the job **inside a container** and attaches a Postgres **service with no host-port
mapping**, reachable at `postgres:5432` over the private job network — so it can never collide with a
dev database on the shared runner. This is the recommended pattern on `joggo` (which doubles as a
dev box).

```yaml
  test:
    uses: example-org/joggo/.github/workflows/node-test.yml@main
    with:
      postgres-user: myapp
      postgres-password: myapp
      postgres-db: myapp_test
      # database-url-env defaults to DATABASE_URL → postgresql://myapp:myapp@postgres:5432/myapp_test
      pre-command: bash .github/scripts/some-setup.sh        # optional
      db-setup-command: |                                    # optional
        pnpm run db:generate
        pnpm --filter @x/api run db:migrate:deploy
        pnpm run db:seed
      test-command: |
        pnpm run lint
        pnpm run test
    permissions: { contents: read }
```
Notes:
- Use a **Debian** `container-image` (the default `node:22`) if you use Prisma — Alpine's musl/openssl
  trips its query engine. Add system packages via `apt-packages: "..."` if a step needs them.
- The DB connection URL is injected as `DATABASE_URL` (rename via `database-url-env`); pass anything
  else with `extra-env` (newline-separated `KEY=VALUE`).
- It builds nothing/pushes nothing — pair it with `build-and-push.yml` for the image stage.

### PR validation without pushing
Add a second job (or a separate `pull_request` workflow) that builds but doesn't push, to catch
broken Dockerfiles before merge:
```yaml
  validate:
    if: github.event_name == 'pull_request'
    uses: example-org/joggo/.github/workflows/build-and-push.yml@main
    with: { push: false }
    permissions: { contents: read, packages: write }
```

---

## 3. The manual path — inline `runs-on` (only if you can't use the reusable workflow)

If a repo needs bespoke build steps, route just the build job to the runner yourself:

```yaml
on:
  push: { branches: [main], paths: ['apps/**', 'docker/**', 'Dockerfile'] }
jobs:
  build-and-push:
    runs-on: [self-hosted, linux, x64, joggo]    # <- the runner's labels
    permissions: { contents: read, packages: write }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: true
          tags: ghcr.io/example-org/${{ github.event.repository.name }}:sha-${{ github.sha }}
```
Prefer §2 — keep build logic in one place.

---

## 4. Verify a build worked

1. **Actions tab** of the repo → your run → the `build` job shows it ran on `joggo`
   (annotation: *"This job ran on a self-hosted runner"*), and **no GitHub-hosted minutes** were billed.
2. **Package appears:** repo (or org) → **Packages** → `ghcr.io/example-org/<image-name>` with the new
   `sha-…` / `latest` tags.
3. Pull it anywhere authenticated: `docker pull ghcr.io/example-org/<image-name>:latest`.

---

## 5. Make the image deployable by production

GHCR packages are **private by default**, so production must authenticate to pull:
- Link the package to the repo (Package → **Package settings → Connect repository**) so repo-scoped
  access applies, **or** grant the production box a **read-only** `read:packages` token / a GitHub
  App installation token. (Least privilege: production gets **pull-only**, never push.)
- Keep the package **private** unless there's a reason otherwise.
- Production's existing pull-loop + health-gate + auto-rollback ([`runner-setup.md`](runner-setup.md) §10) handles the rest.

---

## 6. Onboard a new repo — checklist

- [ ] Repo is **private**.
- [ ] Repo allowed on the runner: added to the **`joggo-runners`** group, or (personal account) the
      runner registered to this repo (§1).
- [ ] Added `.github/workflows/ci.yml` calling the reusable workflow (§2).
- [ ] Job has `permissions: { contents: read, packages: write }`.
- [ ] A `Dockerfile` exists at the path you referenced.
- [ ] First run is green and the image shows up in GHCR (§4).
- [ ] Production can pull the image (§5).

---

## 7. Fallback when the PC is down

`joggo` is a single home PC. If it's off, jobs pinned to it **queue** until it returns.
- **Pure cost-min (default):** accept "PC down = builds pause." Jobs resume when it's back.
- **Resilience:** also allow GitHub-hosted as a fallback, e.g. `runs-on: [self-hosted, joggo]`
  with a matrix or a conditional second job on `ubuntu-latest`. This costs paid minutes but keeps CI
  flowing. Choose per repo.

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Job stuck **Queued** forever | Runner offline (PC asleep/off/WSL down), or the repo is not allowed on the runner. Check org → Runners shows `joggo` **Idle/green**; confirm group membership, or the per-repo registration on a personal account (§1). |
| `denied: permission_granted... packages` on push | Missing `permissions: packages: write` in the job, or pushing to a different org/owner than `github.repository`. |
| `permission denied ... /var/run/docker.sock` | Runner user not in `docker` group on the host — a server-side fix ([`runner-setup.md`](runner-setup.md) §2.3), not a repo change. |
| Image is `arm64` / won't run in prod | `platforms` not `linux/amd64`. The reusable workflow defaults correctly; check any inline override. |
| Build fails: **no space left on device** | Host disk full. Server-side weekly `docker system prune` handles this ([`runner-setup.md`](runner-setup.md) §6.3); prune sooner if needed. |
| Public repo / fork PR tried to run | Blocked by design. Never add public repos to the runner group (§1). |

---

## 9. Security do's & don'ts (client side)

- ✅ Keep the repo **private**; rely on the per-job `GITHUB_TOKEN`; request **least** permissions
  (`contents: read`, `packages: write`, nothing more).
- ✅ Pin the reusable workflow to a tag/SHA for production repos.
- ❌ Never store AWS/SSH/production secrets in a build that runs on `joggo` — the box is
  deliberately credential-free ([`runner-setup.md`](runner-setup.md) §6.2). If a deploy step needs prod secrets, run that
  step on a **separate, GitHub-hosted** job, not on the self-hosted runner.
- ❌ Never `runs-on: ubuntu-latest`-style a job that depends on `joggo`-local state; treat the
  runner as shared and (eventually) ephemeral.
