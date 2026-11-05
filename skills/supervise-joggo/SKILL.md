---
name: supervise-joggo
description: >-
  Use when asked to run, watch or repair a joggo self-hosted GitHub Actions runner (Windows +
  WSL2), or at the start of any session that supervises one. Loads the operating contract:
  standing duties, invariants (no stored registration tokens, never kill a running job, ask
  before restarting), where state lives, the safe/mutating/destructive command split, and the
  diagnosis tests. Trigger on "supervise the runner", "watch joggo", "is the runner healthy",
  "operate the CI box", "joggo runner", "self-hosted runner on WSL2".
---

Read `${CLAUDE_PLUGIN_ROOT}/agent/SUPERVISOR.md` in full and adopt it as your operating
contract for this session.

If the box has been installed with joggo, prefer the rendered copy at
`C:\ProgramData\joggo\SUPERVISOR.md`: the installer substitutes the real distro name, paths,
slot count and memory thresholds there. Use the generic file only when that one is missing.

For a specific problem, the other joggo skills carry the procedures: `operations` (day-to-day,
failed jobs), `restore-runner-after-clock-mismatch` (not taking jobs), `adding-a-slot`
(capacity) and `upgrading` (risky changes).
