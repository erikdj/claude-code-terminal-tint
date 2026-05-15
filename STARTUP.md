# STARTUP

> **If you are a Claude Code session opening this repo for the first time
> in a new conversation, READ THIS FILE FIRST -- before `README.md`, before
> running any tests, before reading any code.** Erik parked work
> mid-investigation; this file restores the in-flight context.

---

## 1. Status as of 2026-05-15

- **Repo:** `erikdj/claude-code-terminal-tint`
  (https://github.com/erikdj/claude-code-terminal-tint)
- **Branch:** `master`
- **Test status:** 28/28 install + 5/5 tty-recovery, all green locally.
- **Bash / Ubuntu (WSL):** **WORKS end-to-end** on Claude Code 2.1.142.
  Verified live by Erik on 2026-05-15: green tint at end-of-turn, reset
  on the next prompt or tool. The fix is the `/proc`-walk fallback in
  `hooks/on_*.sh` (`resolve_user_tty()`). See section 2 for why bash
  was actually broken too -- the prior STARTUP was wrong about that.
- **Windows native (CC launched as `claude` CLI from PowerShell in
  Windows Terminal):** **CODE FIX IS LANDED, NOT YET VISUALLY
  VERIFIED.** `hooks/on_*.ps1` now always do `FreeConsole` +
  `AttachConsole(-1)` before opening `CONOUT$`. This is the production
  form of the cheap-fix branch from the gated `CCTT_PROBE` experiment
  (commit 3d8d708, now stripped). Manual visual pass on a real WT
  pane is still required before claiming the Windows platform is
  shipped -- see section 4.

## 2. What changed since the prior parking (2026-05-04)

The prior STARTUP.md was written believing bash worked and Windows
didn't. **Both were actually broken, by the same root cause:**

> Newer Claude Code (2.1.x) spawns hook child processes with their
> own session on POSIX (`setsid`) and detached from the parent
> ConPTY on Windows. This is what makes the "just write to
> `/dev/tty` / `CONOUT$`" pattern fail on both platforms:
>
> - On POSIX the kernel returns `ENXIO` when the process has no
>   controlling terminal. The hooks had a `[ -e /dev/tty ]` guard
>   that passed (the device node always exists), but the actual
>   open then failed silently because `2>/dev/null || true`
>   swallowed the error -- the hook exited 0 with no OSC bytes
>   emitted.
> - On Windows `CONOUT$` still opens, but resolves to a fresh
>   invisible console instead of WT's ConPTY -- so the OSC bytes
>   were written into a void.

The reason bash *appeared* to work in the prior STARTUP is that
earlier CC versions did inherit the controlling terminal into hook
children. The upstream behavior changed underneath us; the visible
failure landed on Windows first because the failure mode there was
louder (stderr leak), while on POSIX it just silently no-op'd.

The fix on both platforms recovers before writing:

| Platform | Recovery |
| --- | --- |
| POSIX | walk `/proc/<ppid>/...` up the process tree until an ancestor's stdio resolves to `/dev/pts/N`; write OSC bytes there. Lives in `resolve_user_tty()` in `hooks/on_*.sh`. |
| Windows | `FreeConsole()` then `AttachConsole(-1)` (a.k.a. `ATTACH_PARENT_PROCESS`) to bind to the parent process's console, then open `CONOUT$` as before. Lives at the top of `hooks/on_*.ps1`. |

Both fall back to silent no-op (exit 0) if recovery fails, so a
misbehaving hook never surfaces as a CC error.

The diagnostic probe (`CCTT_PROBE=1`) added in commit 3d8d708 is
gone. Its successful "cheap fix" branch (`AttachConsole(-1)`) is now
the production code path.

## 3. What still needs doing

**Manual Windows visual verification.** The code path is in but
nobody has run a real CC session in Windows Terminal under it.
Section 4 has the verification recipe.

If Windows verification fails (no green flash, hook errors, etc.),
the next decision is whether to pivot to the sidecar shape
documented in section 6 (preserved verbatim from the prior STARTUP,
in case the cheap fix turns out not to be enough).

## 4. Verification recipe for Windows

> Run from a fresh Windows Terminal pane. Close any existing CC
> sessions first -- `settings.json` is read at session start, so a
> session already running won't pick up the new hooks.

1. Sync the local clone:
   ```powershell
   cd C:\Users\erikdj\projects\claude-code-terminal-tint
   git pull
   ```
   Confirm `git log -1 --oneline` shows a `docs: explain the
   /proc-walk and AttachConsole fallbacks` commit (or later).

2. Sanity-check that the OSC + `CONOUT$` pipeline itself still works
   in WT, independent of CC:
   ```powershell
   pwsh -File test\test-render-windows.ps1
   ```
   Expect: background flips green for ~3s, then resets. If this
   fails, the issue is environmental (WT settings, conhost mode)
   rather than in our code.

3. Start a real CC session and trigger a Stop:
   ```powershell
   claude
   ```
   Send any short prompt (e.g. `say hi`). Watch the background at
   the moment Claude finishes talking and waits for the next prompt.

4. **Expected outcome:** background flashes green at end-of-turn,
   returns to your default on the next prompt or tool use. Repeat
   a few times so you can tell the cycle is reliable.

5. **If it works:** reply "ok on Windows" and we mark Windows shipped
   (delete the README banner + this STARTUP.md, or shrink them to a
   release-readiness checklist).
   **If it doesn't:** capture
   - which step failed,
   - any error text in the CC chat,
   - `Get-Process | Where-Object { $_.Name -in 'claude','pwsh','powershell' } | Format-Table Id,Parent,Name`
     run from the same pane (helps debug the `AttachConsole` target).
   That is enough to decide between (a) tuning the AttachConsole
   target (walk to a specific pwsh PID instead of -1) or (b) pivoting
   to the sidecar in section 6.

## 5. Locked-in design decisions -- DO NOT UNDO

- **Color semantic.** Green (`#1f5d3a` background, `#e8f5e9` foreground)
  when waiting for human input. **Nothing** (OSC 110 / OSC 111 reset)
  otherwise. The default state must restore the user's terminal
  default, not a hardcoded color. Erik specifically pushed back on the
  earlier "tint in both states" design.
- **Hooks registered.** Exactly three: `Stop` (apply green),
  `UserPromptSubmit` (reset), `PreToolUse` with `matcher: '*'` (reset).
  **NEVER hook `Notification`** -- it fires multiple times per turn
  for `permission_prompt`, `idle_prompt`, `auth_success`,
  `elicitation_dialog`, etc., and produced spurious mid-loop tints
  before. The bash and pwsh installers must agree on this list.
- **Cross-platform parity.** Every code, test, and doc change must
  cover bash AND pwsh sides at parity. `test/test-install.sh` alone is
  not sufficient -- `test/test-install.ps1` must mirror it. If a
  platform-specific concept (e.g. the `/proc`-walk fallback, which has
  no Windows analogue) genuinely cannot be tested on the other side,
  document why in the test file and the README.
- **Idempotency marker.** Literal `# claude-code-terminal-tint-marker`
  comment appended to each hook command in `settings.json`. Detection
  is by trailing-suffix match on the marker. **NEVER fall back to
  substring-of-path matching** -- that was the v0.1.0 bug Erik hit
  when his clone path didn't contain the plugin name.
- **Output channel.** Hooks write directly to the user's terminal
  device. POSIX: `/dev/tty` with the `/proc`-walk fallback when
  `/dev/tty` is unavailable. Windows: `CONOUT$` after
  `FreeConsole + AttachConsole(-1)` to recover from CC's hook-child
  isolation. **DO NOT** reintroduce `[Console]::Error.Write(...)`
  or `[Console]::Out.Write(...)` in any hook script -- CC captures
  both streams and the bytes are silently lost. The automated
  regression tests in `test/test-install.{sh,ps1}` enforce this; do
  not weaken them.

## 6. Sidecar fallback shape (only if section 4 verification fails)

(Preserved from the prior STARTUP, in case the cheap-fix
`AttachConsole(-1)` approach turns out not to reach WT's ConPTY in
Erik's actual setup. If section 4 passes, this entire plan can be
deleted.)

- Module ships at `daemon/TerminalTint.psm1` in the repo.
- User adds **one line** to `$PROFILE`:
  `Import-Module C:\Users\erikdj\projects\claude-code-terminal-tint\daemon\TerminalTint.psm1`.
- `install.ps1` should **detect** pwsh and **offer** to add it --
  print the line to be added, ask for explicit `y/n` confirmation,
  only then modify `$PROFILE`. **Never silent.** If the user
  declines, fall back to the current `CONOUT$` behavior and print
  a warning that real-time tinting in CC-in-WT will not work without
  the profile entry.
- The module exports `Start-ClaudeTintDaemon` (or auto-runs on
  import) which:
  1. Creates a per-PID named pipe `\\.\pipe\cctt-$PID` (or watches a
     status file at `$env:TEMP\cctt-$PID.status`).
  2. Spawns a `Start-ThreadJob` (NOT `Start-Job` -- ThreadJobs run
     in the same process, so writes to `[Console]::Out` reach the
     WT pty).
  3. Job loops: read pipe / file -> match `green` / `reset` ->
     emit the corresponding OSC bytes via
     `[Console]::Out.Write(...)`.
  - **Verify before declaring victory:** ThreadJob writes to
    `[Console]::Out` while `claude.exe` is the foreground process --
    does WT actually render those bytes? May need to test. If
    ThreadJob output does not reach WT either, fall back to a
    wrapper-function approach (`function claude { ... }` in the
    module, which intercepts and proxies, doing OSC writes in-process
    while shelling out to the real `claude.exe`).
- Hooks (`on_stop.ps1`, `on_resume.ps1`) become tiny: write `green`
  or `reset` to the named pipe / status file. To find which pwsh
  PID's pipe to address: when `Import-Module` runs, the module
  appends `$PID` to `$env:TEMP\cctt-pwsh-pids` (one PID per line);
  the hook reads that file, walks its own parent chain to find a
  matching pwsh PID, and writes to that pipe.
- Bash side stays as-is -- the `/proc`-walk fallback already covers
  the equivalent POSIX scenario. Sidecar is Windows-only.
- README needs a "Windows: profile setup" section explaining why and
  what to add. Setup requires one shell restart.
- Add a regression test for the named-pipe protocol: start the
  daemon, send `green`, assert the OSC sequence comes out the
  daemon's stdout.

## 7. File pointers

| Path | What it is |
| --- | --- |
| `README.md` | User-facing install / config / troubleshooting docs. |
| `CHANGELOG.md` | `[Unreleased]` block tracks the most recent changes. |
| `config.json` | Single configurable color block (`waiting`). |
| `hooks/on_stop.{sh,ps1}` | "Green tint" hook (writes OSC 11 + OSC 10). POSIX uses `resolve_user_tty()` for the `/proc`-walk fallback; pwsh does `FreeConsole` + `AttachConsole(-1)` before opening `CONOUT$`. |
| `hooks/on_resume.{sh,ps1}` | "Reset to default" hook (writes OSC 110 + OSC 111). Same isolation-recovery on both platforms. |
| `install.{sh,ps1}` | Installer. Merges the three plugin hook entries into `~/.claude/settings.json`. Idempotent via the marker comment; performs a global sweep on every event before re-adding so v0.1.0 -> current upgrades clean out the stale `Notification` entry. |
| `uninstall.{sh,ps1}` | Removes the plugin's entries by marker; resets the terminal via OSC 110 / OSC 111. |
| `test/test-install.{sh,ps1}` | Automated regression suites (path-independence, marker, count, migration, output-channel guard). |
| `test/test-tty-recovery.sh` | Regression guard for the POSIX `/proc`-walk fallback. Uses `script(1)` + `setsid` to recreate the isolated-hook-child scenario so /dev/tty really is unwritable, then asserts the OSC bytes still appear in the captured PTY. Linux/WSL only. |
| `test/test-render-windows.ps1` | Manual visual-rendering helper. Run from a fresh WT pane (not via CC); flashes green for ~3s then resets. The test that bypasses CC entirely and confirms the OSC + `CONOUT$` pipeline itself works in WT. |
