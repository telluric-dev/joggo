# joggo-setup.exe

A one-file Windows entry point for people who would rather double-click than clone.

**What it does:** downloads `joggo-<version>.zip` from the GitHub release, checks its SHA-256
against the value compiled into the exe, extracts it to `%LOCALAPPDATA%\joggo\<version>`, and
runs `install.ps1 -Wizard` in the same window. It has no installer logic of its own: everything
after the download is the same wizard you get from a clone. The wizard opens GitHub's runner
registration page for you and reads the token without echoing it; the token is never stored.

**Why the hash matters:** each exe is pinned to one release zip. If the download is swapped,
truncated or tampered with, the exe refuses and installs nothing. Put the zip next to the exe
to install offline; it is held to the same hash.

## Making a release

1. Tag the commit: `git tag v0.1.0 && git push origin v0.1.0`.
2. Build: `./setup/build.ps1 -Version 0.1.0`. This writes `dist/joggo-0.1.0.zip`,
   `dist/joggo-setup.exe` (unsigned) and `dist/SHA256SUMS` (the zip's hash). It needs only
   `git` and the `csc.exe` that ships with .NET Framework 4.8 in Windows 10/11.
3. **Sign `dist/joggo-setup.exe`** (Authenticode). Do not rebuild after signing.
4. Append the signed exe's SHA-256 to `SHA256SUMS`.
5. Upload the zip, the signed exe and `SHA256SUMS` to the GitHub release `v0.1.0`. The zip must
   be the exact file built in step 2: the exe accepts no other bytes.

An unsigned exe works, but Windows SmartScreen warns about it, so unsigned builds are for testing.
