---
name: operations
description: >-
  Use for day-2 operations and debugging of the live self-hosted runner on this Windows+WSL2 box:
  watching jobs land, diagnosing failed runs from the slot's worker logs, jobs killed by Windows
  Update reboots and the automatic retry that covers them, the WSL2 command-quirks that bite shell
  automation, restarting WSL after config changes, and handling the dev-box/CI collisions. Operator
  skill for the joggo platform repo. Trigger on "watch the runner", "why did the job fail",
  "tail the runner log", "restart WSL", "job failed on joggo", "service container port collision",
  "runner lost communication with the server", "job died after a reboot", "could not resolve host
  github.com in CI", "is this an OOM".
---

This skill's full procedure lives in the joggo docs, so the repository has one source of truth.
Read `${CLAUDE_PLUGIN_ROOT}/docs/operations.md` in full before acting, and follow it. Paths inside it
(`slots/`, `watchdog/`, `docs/`) are relative to `${CLAUDE_PLUGIN_ROOT}`; the commands run on
the joggo box itself.

Before anything that restarts a runner, a slot or the VM, or that touches a registration token,
read the invariants in `${CLAUDE_PLUGIN_ROOT}/agent/SUPERVISOR.md` and ask the operator first.
