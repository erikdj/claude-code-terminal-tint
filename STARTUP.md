# STARTUP

> **If you are a Claude Code session opening this repo for the first time
> in a new conversation, READ THIS FILE FIRST -- before `README.md`, before
> running any tests, before reading any code.** Erik parked work mid-debug;
> this file restores the in-flight context without you having to re-derive
> it.

---

## 1. Status as of 2026-05-04

- **Repo:** `erikdj/claude-code-terminal-tint`
  (https://github.com/erikdj/claude-code-terminal-tint)
- **Branch:** `master`
- **Last commit on master:** `3d8d708` --
  `diag: gated probe in on_stop.ps1 to capture hook-child console state`
- **Test status:** 28/28 bash, 29/29 pwsh, all green locally as of the
  last run before parking.
- **Bash / Ubuntu (WSL):** **WORKS end-to-end.** Confirmed by Erik on
  2026-05-04. Green tint at end-of-turn, terminal default during work.
- **Windows native (CC launched as `claude` CLI from PowerShell in
  Windows Terminal):** **DOES NOT WORK.** Hooks fire (settings.json is
  correct, no errors), but the OSC sequences do not reach the visible WT
  pane. End-to-end tinting is broken on this platform only.

## 2. Diagnosis so far

- Per the
  [Claude Code hooks docs](https://code.claude.com/docs/en/hooks), CC
  captures hook child stdout (parsed for JSON output) and stderr
  (surfaced as an error message on non-zero exit). **Bytes written to
  either stream from a hook never reach the terminal emulator.**
- POSIX side bypasses this by writing the OSC sequences directly to
  `/dev/tty`, which is the controlling tty of the hook process and
  remains connected to the user's terminal regardless of pipe
  redirection by CC. This is why bash works.
- Windows side writes to `CONOUT$` (the documented Windows analogue of
  `/dev/tty`). On CC-in-pwsh-in-WT, the hook child appears to land in a
  detached / private console -- `CONOUT$` opens that hidden conhost
  instead of WT's ConPTY, so the OSC bytes go nowhere visible.
- **Confirmed independently:** `pwsh -File test/test-render-windows.ps1`
  run *directly* from a fresh WT pane (not as a CC hook child) flips
  the bg green and resets correctly. So the OSC + CONOUT$ pipeline
  itself works when the writer inherits WT's ConPTY. The bug is
  specifically that CC's hook-child spawn does not forward the ConPTY
  down to the hook on Windows.

## 3. Where we left off

- A diagnostic probe is live on master at commit `3d8d708`. It
  instruments `hooks/on_stop.ps1` only. **It is gated behind
  `$env:CCTT_PROBE = '1'`** -- production usage is not affected.
- When the env var is set, the Stop hook dumps a JSON report to
  `$env:TEMP\cctt-probe-<timestamp>.json` containing:
  parent process chain (8 levels), first `pwsh.exe` /
  `powershell.exe` ancestor, stdio handle types
  (`GetFileType` on stdin/stdout/stderr), `[Console]::Is*Redirected`
  flags, initial console state (`GetConsoleWindow`,
  `GetConsoleProcessList`, can-open-`CONOUT$`), the result of
  `FreeConsole` + `AttachConsole(-1)` plus a fresh post-attach
  snapshot, the result of `AttachConsole($pwshPid)` plus its own
  post-attach snapshot, and filtered env vars (`CLAUDE*`, `WT_*`,
  `TERM*`, `CONHOST*`, `CONEMU*`, `MSYSTEM`, `SESSIONNAME`,
  `COLORTERM`).
- The latest dump path is also written to
  `$env:TEMP\cctt-probe-latest.txt` so a follow-up command can find it
  without a directory listing.
- The probe doubles as a **cheap-fix experiment**: at the end of the
  probe block, the console is left attached to whichever
  `AttachConsole` call last succeeded. If that landed in WT's ConPTY,
  the regular `CONOUT$` write further down the same script tints the
  terminal green. So a green flash with `CCTT_PROBE=1` alone tells us
  the cheap fix is sufficient -- without needing to read the JSON.
- **The probe has NOT been run on real CC-in-WT yet.** Erik was asked
  to run it and parked the project before doing so.
- **First action when Erik resumes: ask him to run the probe.**
  Instructions are in section 4 below, ready to paste verbatim.

## 4. Exact instructions to give Erik when he resumes

Paste this block verbatim. Do not paraphrase.

---

> One-time probe to capture what the CC-in-WT hook child actually sees.
> Should take ~30 seconds.
>
> 1. Sync your local clone so `on_stop.ps1` includes the probe:
>    ```powershell
>    cd C:\Users\erikdj\projects\claude-code-terminal-tint
>    git pull
>    ```
>    Confirm `git log -1 --oneline` shows `3d8d708 diag: gated probe in on_stop.ps1`.
>
> 2. **Open a fresh Windows Terminal pane** (close any existing CC sessions
>    first -- `settings.json` is read at session start). In the fresh pwsh
>    prompt:
>    ```powershell
>    $env:CCTT_PROBE = '1'
>    claude
>    ```
>
> 3. Send Claude any single short prompt that triggers a response
>    (e.g. `say hi`). Wait for the response to fully complete -- the Stop
>    hook fires at end-of-turn, which is what we are probing.
>
> 4. **Watch for two things during step 3:**
>    - **(a) Did the terminal background flash green** specifically at the
>      moment Claude finished talking and was waiting for the next prompt?
>    - **(b) Did anything weird happen** -- flicker, no flash, screen
>      artifacts, error messages in the chat?
>
> 5. Find the dump path and grab the JSON:
>    ```powershell
>    Get-Content $env:TEMP\cctt-probe-latest.txt
>    Get-Content (Get-Content $env:TEMP\cctt-probe-latest.txt) | clip
>    ```
>    First line prints the path. Second line copies the JSON contents to
>    the clipboard.
>
> 6. Reply with **(a)** yes/no on the green flash, **(b)** any weirdness,
>    and **paste the JSON contents** (or attach the file).
>
> If you trigger a couple of Stop events back-to-back (e.g. two quick
> prompts), there will be two probe files. Send the latest. The marker
> file `cctt-probe-latest.txt` always points to the most recent dump.

---

## 5. Decision tree once the probe data is in

| Observed outcome | Conclusion | Fix |
| --- | --- | --- |
| **(a) flashed green** | `AttachConsole(-1)` reaches WT's ConPTY in the real hook context. | **Cheap fix.** Bake `FreeConsole` + `AttachConsole(-1)` into all three PS hooks unconditionally, strip the probe scaffolding, ship. One commit, no sidecar. |
| **(a) no flash, JSON shows pwsh in chain and `AttachConsole($pwshPid)` succeeded** | Parent of the hook is something else (likely `cmd.exe` wrapping); attaching directly to pwsh works. | **Walk-then-attach.** Bake the parent-chain walk + `AttachConsole(<pwshPid>)` into the hooks. |
| **(a) no flash, pwsh in chain but pwsh-attach failed** | Windows access checks block cross-process attach in this configuration. | **Pivot to pwsh-side sidecar.** See section 5b below for the agreed shape. |
| **(a) no flash, no pwsh in chain at all** | CC is wrapping the hook in `cmd /c ...` or similar; the cmd.exe owns its own console and hides the user's pwsh. Inspect the depth-1/2 ancestor `cmdline` field in the JSON to confirm. | **Pivot to pwsh-side sidecar.** |

### 5b. Sidecar shape (only if section 5 forces this path)

- Module ships at `daemon/TerminalTint.psm1` in the repo.
- User adds **one line** to `$PROFILE`:
  `Import-Module C:\Users\erikdj\projects\claude-code-terminal-tint\daemon\TerminalTint.psm1`.
- `install.ps1` should **detect** pwsh and **offer** to add it -- print
  the line to be added, ask for explicit `y/n` confirmation, only then
  modify `$PROFILE`. **Never silent.** If the user declines, fall back
  to the current `CONOUT$` behavior and print a warning that real-time
  tinting in CC-in-WT will not work without the profile entry.
- The module exports `Start-ClaudeTintDaemon` (or auto-runs on import)
  which:
  1. Creates a per-PID named pipe
     `\\.\pipe\cctt-$PID` (or watches a status file at
     `$env:TEMP\cctt-$PID.status`).
  2. Spawns a `Start-ThreadJob` (NOT `Start-Job` -- ThreadJobs run in
     the same process, so writes to `[Console]::Out` reach the WT pty).
  3. Job loops: read pipe / file -> match `green` / `reset` -> emit
     the corresponding OSC bytes via `[Console]::Out.Write(...)`.
  - **Verify before declaring victory:** ThreadJob writes to
    `[Console]::Out` while `claude.exe` is the foreground process --
    does WT actually render those bytes? May need to test. If
    ThreadJob output does not reach WT either, fall back to a
    wrapper-function approach (`function claude { ... }` in the
    module, which intercepts and proxies, doing OSC writes in-process
    while shelling out to the real `claude.exe`).
- Hooks (`on_stop.ps1`, `on_resume.ps1`) become tiny: write `green` or
  `reset` to the named pipe / status file. To find which pwsh PID's
  pipe to address: when `Import-Module` runs, the module appends `$PID`
  to `$env:TEMP\cctt-pwsh-pids` (one PID per line); the hook reads
  that file, walks its own parent chain to find a matching pwsh PID,
  and writes to that pipe.
- Bash side stays as-is. The sidecar is Windows-only.
- README needs a "Windows: profile setup" section explaining why and
  what to add. Setup requires one shell restart.
- Add a regression test for the named-pipe protocol: start the daemon,
  send `green`, assert the OSC sequence comes out the daemon's stdout.

## 6. Locked-in design decisions -- DO NOT UNDO

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
  before. The Claude Code hooks docs confirm Stop is the only
  once-per-turn end-of-turn event. The bash and pwsh installers must
  agree on this list.
- **Cross-platform parity.** Every code, test, and doc change must
  cover bash AND pwsh sides at parity. `test/test-install.sh` alone is
  not sufficient -- `test/test-install.ps1` must mirror it. The bash
  side has its own counterpart for every assertion (current count: 28
  bash, 29 pwsh). If a Windows-specific concept (e.g. `CONOUT$`
  regression guard) genuinely has no POSIX analogue, document why in
  the test file and the README.
- **Idempotency marker.** Literal `# claude-code-terminal-tint-marker`
  comment appended to each hook command in `settings.json`. Detection
  is by trailing-suffix match on the marker. **NEVER fall back to
  substring-of-path matching** -- that was the v0.1.0 bug Erik hit
  when his clone path didn't contain the plugin name. The path-
  independent marker is non-negotiable.
- **Output channel.** Bash hooks write to `/dev/tty`. PowerShell hooks
  write to `CONOUT$` (currently -- this may change to one of the
  fixes from section 5). **DO NOT** reintroduce
  `[Console]::Error.Write(...)` or `[Console]::Out.Write(...)` in any
  hook script -- CC captures both streams and the bytes are silently
  lost. The automated regression tests in
  `test/test-install.{sh,ps1}` enforce this; do not weaken them.

## 7. File pointers

| Path | What it is |
| --- | --- |
| `README.md` | User-facing install / config / troubleshooting docs. |
| `CHANGELOG.md` | `[Unreleased]` block tracks the most recent changes. |
| `config.json` | Single configurable color block (`waiting`). |
| `hooks/on_stop.sh` / `hooks/on_stop.ps1` | "Green tint" hook (writes OSC 11 + OSC 10). The pwsh version contains the gated diagnostic probe (section 3). |
| `hooks/on_resume.sh` / `hooks/on_resume.ps1` | "Reset to default" hook (writes OSC 110 + OSC 111). |
| `install.sh` / `install.ps1` | Installer. Merges the three plugin hook entries into `~/.claude/settings.json`. Idempotent via the marker comment; performs a global sweep on every event before re-adding so v0.1.0 -> current upgrades clean out the stale `Notification` entry. |
| `uninstall.sh` / `uninstall.ps1` | Removes the plugin's entries by marker; resets the terminal via OSC 110 / OSC 111. |
| `test/test-install.sh` / `test/test-install.ps1` | Automated regression suites (path-independence, marker, count, migration, output-channel guard). |
| `test/test-render-windows.ps1` | Manual visual-rendering helper. Run from a fresh WT pane (not via CC); flashes green for ~3s then resets. This is the test that bypasses CC entirely and confirms the OSC/`CONOUT$` pipeline itself works in WT. |
