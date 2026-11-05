# "The token expired" and a deleted runner: WSL2's clock after sleep

**Symptom.** A self-hosted runner in WSL2 stops taking jobs after the PC slept, lost
power or was hard-reset. Jobs queue forever. The runner log says:

```
ERR ...] VssOAuthTokenRequestException: The token expired on 08/29 04:10:59.
         Current server time is 08/29 06:31:18.        <-- hours of skew
ERR ...] Failed to create a session. The runner registration has been deleted
         from the server, please re-configure.
```

Restarting the runner does nothing. Restarting it in a loop makes no difference either.

## What happened

**The WSL2 VM's clock stopped while Windows slept, and came back hours behind.** Every
token the runner holds is checked against GitHub's clock, so to the runner every token
looks expired. It cannot refresh its session. If that lasts long enough, GitHub concludes
the runner is gone and **deletes its registration**. From then on no amount of clock
fixing helps: the runner has to be registered again.

Seen on the box joggo was extracted from on 2026-08-29, and once before after a power
outage.

### Why the time sync does not save you

You might expect NTP to correct the clock. On Ubuntu with chrony, the default rule is
`makestep 1 3`: **step** (jump) the clock only during the first 3 updates after boot. After
that, any offset is **slewed**, corrected gradually at minutes per day. A multi-hour offset
that appears after the VM has been up for a while (because it slept rather than rebooted)
is therefore effectively never corrected in time.

And there is a second case where tuning NTP cannot help at all: **on WSL2 the guest clock
follows the Windows clock.** If Windows itself is wrong, the guest is wrong with it.
Measured on 2026-09-19 after a hard reset: Windows Time had never synchronised
(`w32tm /query /status` showed `Source: Local CMOS Clock`) and ran 14.4 s slow, while
chrony inside WSL was healthy. chrony stepped the guest clock and the hypervisor put it
straight back. No Linux-side setting can fix that.

## The fix

**1. Let chrony step any offset, at any time.** In `/etc/chrony/chrony.conf`, replace the
`makestep` line with:

```
makestep 1 -1
```

(step whenever the offset is over 1 second, with no limit on how many updates that
applies to), then `systemctl restart chrony`. A future freeze is then corrected within one
poll, before the registration is lost. Running on the original box since 2026-08-30.

**2. Make sure Windows itself keeps time.** From an elevated PowerShell:

```powershell
w32tm /query /status        # want a stratum of 2-3 and a real "Last Successful Sync Time"
w32tm /config /update; Restart-Service W32Time; w32tm /resync /force
```

`Source: Local CMOS Clock`, or "not synchronized", means Windows has never synced and the
next reset will cause this again.

**3. If the registration is already deleted, register again.** Mint a new registration
token (it expires in about an hour; never store it), clear the old local config, and
re-register with `--replace`, because a ghost runner with the same name usually still exists
on GitHub. The exact commands are in [recovery.md §2](recovery.md#2-failure-a--clock-drift-killed-the-registration).

## How to check you have this problem

- `chronyc tracking` inside WSL: the `System time` line is the offset. Anything over a
  second or two on an idle box deserves a look.
- `date -u` inside WSL against `Get-Date -AsUTC` (or any clock) in Windows.
- The runner log, for the two lines above. The first appears long before the second, so
  catching it early saves a re-registration.

joggo's slot launcher refuses to start a slot while chrony reports the clock more than
5 seconds off, and names the Windows-side fix, rather than letting the runner hot-loop
on expired tokens.

## Limits in joggo today

- **The installer does not apply `makestep 1 -1`.** It is a manual step for now (fix 1
  above). It also does not install chrony. Without chrony, the launcher's clock check is
  skipped too, because it reads `chronyc tracking`.
- Nothing fixes a wrong Windows clock automatically: setting Windows time needs elevation,
  and joggo deliberately runs with none (see [SECURITY.md](../SECURITY.md)). Detection is
  automated; the fix is a human step.
