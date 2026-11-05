---
name: restore-runner-after-clock-mismatch
description: >-
  Use when the joggo runner is not taking jobs and it is NOT a GitHub outage — either the
  clock-drift incident (OAuth "token expired" with a large local-vs-server time gap, "runner
  registration has been deleted from the server") or a WEDGED listener (service active, process
  alive at 0% CPU, log silent, jobs queued forever). Covers telling the two apart, the log
  signatures, re-registering with --replace, restarting a wedge, and the three self-heal layers.
  Operator skill for the joggo platform repo. Trigger on "token expired", "clock drift",
  "clock mismatch", "registration deleted", "runner dead after power outage", "re-register the
  runner", "jobs stuck but runner looks fine", "runner idle but not picking up jobs", "wedged
  listener", "hanging jobs".
---

This skill's full procedure lives in the joggo docs, so the repository has one source of truth.
Read `${CLAUDE_PLUGIN_ROOT}/docs/recovery.md` in full before acting, and follow it. Paths inside it
(`slots/`, `watchdog/`, `docs/`) are relative to `${CLAUDE_PLUGIN_ROOT}`; the commands run on
the joggo box itself.

Before anything that restarts a runner, a slot or the VM, or that touches a registration token,
read the invariants in `${CLAUDE_PLUGIN_ROOT}/agent/SUPERVISOR.md` and ask the operator first.
