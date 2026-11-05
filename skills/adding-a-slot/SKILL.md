---
name: adding-a-slot
description: >
  Use when the joggo box needs MORE CONCURRENCY — jobs queuing behind each other, or
  GitHub dropping them with "The job was not acquired by Runner of type self-hosted even
  after multiple attempts". Covers why a second slot needs a second REGISTRATION (not just
  a second systemd instance), the one-command preparation, the human-only token step, how
  to prove real parallelism rather than two runners trading one session, and what to
  re-check afterwards. Operator skill for the joggo platform repo. Trigger on
  "add a slot", "second slot", "more capacity", "jobs are queuing", "jobs being dropped",
  "not acquired by runner", "run two jobs at once", "parallel runners".
---

This skill's full procedure lives in the joggo docs, so the repository has one source of truth.
Read `${CLAUDE_PLUGIN_ROOT}/docs/adding-a-slot.md` in full before acting, and follow it. Paths inside it
(`slots/`, `watchdog/`, `docs/`) are relative to `${CLAUDE_PLUGIN_ROOT}`; the commands run on
the joggo box itself.

Before anything that restarts a runner, a slot or the VM, or that touches a registration token,
read the invariants in `${CLAUDE_PLUGIN_ROOT}/agent/SUPERVISOR.md` and ask the operator first.
