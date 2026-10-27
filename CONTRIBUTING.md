# Contributing

This started as one person's runner and became a set of findings. Both kinds of
contribution are welcome, and the second kind is more valuable.

## If you are fixing something

Shell scripts must pass `bash -n`. PowerShell should pass
`[System.Management.Automation.PSParser]::Tokenize`. Neither is enforced by CI
here yet, because this repository has no runner of its own.

Keep the comments. A lot of the files carry long explanations of why something
is the way it is — which failure it came from, what was measured, what was tried
and did not work. That is deliberate, it is most of the value, and a tidy-up
that strips it is a net loss.

## If you are reporting behaviour

What makes a report useful here is a number and a method. "The guard restarts too
often" is hard to act on; "the guard restarted 4 times in 6 hours, here is the
log, free never went below 1.2GB" is a bug report. The documentation in `docs/`
is written the same way and should stay that way.

**State what you measured and what you inferred, separately.** Several of the
findings in `docs/memory-pressure.md` were wrong the first time because a
plausible-looking number came from a query that could not fail — a grep matching
a threshold label instead of an event, a filter that structurally could not see
the failure mode it was meant to catch. If a read would return a plausible
number when its basis was missing, the basis needs checking separately.
