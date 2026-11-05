---
name: upgrading
description: >-
  Use before and during any risky change to the live joggo runner — cutting over to the
  containerized slot, upgrading the runner version, editing the self-heal layers, or changing WSL
  config. Covers the proven order (restore point → verify it → baseline smoke → change → smoke →
  keep or roll back), the one-command rollback, the runner-smoke workflow and how to read it, the
  fault injections that validate self-heal, and the verification traps that make a broken runner
  look healthy. Operator skill for the joggo platform repo. Trigger on "cut over to the
  containerized runner", "upgrade the runner", "roll back the runner", "smoke test the runner",
  "is it safe to change the runner", "test the self-heal", "restore point for joggo".
---

This skill's full procedure lives in the joggo docs, so the repository has one source of truth.
Read `${CLAUDE_PLUGIN_ROOT}/docs/upgrading.md` in full before acting, and follow it. Paths inside it
(`slots/`, `watchdog/`, `docs/`) are relative to `${CLAUDE_PLUGIN_ROOT}`; the commands run on
the joggo box itself.

Before anything that restarts a runner, a slot or the VM, or that touches a registration token,
read the invariants in `${CLAUDE_PLUGIN_ROOT}/agent/SUPERVISOR.md` and ask the operator first.
