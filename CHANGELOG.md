# Changelog

All notable changes to this project will be documented in this file. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Idempotency now works regardless of where the plugin is cloned. The
  installer previously identified its own hook entries by searching for
  the substring `claude-code-terminal-tint` in the command path, which
  silently failed when the plugin lived at a path that did not include
  that string -- re-runs accumulated duplicate entries and `uninstall.sh`
  reported "Removed 0 entries". Detection now uses a literal sentinel
  comment (`# claude-code-terminal-tint-marker`) appended to each command.
- Hook scripts (`on_stop.sh`, `on_resume.sh`) and `uninstall.sh` no longer
  leak the shell's "cannot open /dev/tty" message when invoked outside of
  an interactive terminal. The `> /dev/tty` redirect is now wrapped in a
  subshell so the failure is captured by `2>/dev/null`.

### Added
- `test/test-install.sh` -- bash regression test that exercises install
  idempotency, the path-independent marker, uninstall, JSON validity, and
  the no-tty stderr-leak fix. No dependencies beyond `bash` + `python3`.
- `test/test-install.ps1` -- PowerShell counterpart that mirrors the bash
  test on the Windows side. Requires PowerShell 7+ (same minimum as
  `install.ps1`).

## [0.1.0] - 2026-05-03

### Added
- Initial release.
- Bash hook scripts (`hooks/on_stop.sh`, `hooks/on_resume.sh`) that emit
  OSC 11 (background) and OSC 10 (foreground) escape sequences to `/dev/tty`,
  so Claude Code's stdout/stderr pipes are never touched.
- PowerShell hook scripts (`hooks/on_stop.ps1`, `hooks/on_resume.ps1`) that
  emit the same sequences to the conhost via `[Console]::Error.Write`.
- `config.json` with two states:
  - `working` -- default `#1f5d3a` background, `#e8f5e9` foreground (calm green).
  - `waiting` -- default `#7a4a00` background, `#fff7e0` foreground (warm amber).
- `install.sh` / `install.ps1` -- merge hook entries for `Stop`, `Notification`,
  `UserPromptSubmit`, and `PreToolUse` into `~/.claude/settings.json` without
  clobbering existing hooks. Idempotent: re-running replaces the plugin's
  own entries while leaving any unrelated hooks alone.
- `uninstall.sh` / `uninstall.ps1` -- remove the plugin's entries and reset
  the terminal colors via OSC 110 / OSC 111.
- `.gitattributes` enforcing LF for `.sh` and CRLF for `.ps1` so cloned
  copies work on the right platform out of the box.
