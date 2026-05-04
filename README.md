# claude-code-terminal-tint

Tint your terminal background green when Claude Code is genuinely waiting
on you, and leave it alone the rest of the time. While Claude is working,
the terminal stays at whatever colors you've configured it to use; the
moment the agent finishes a turn and is ready for your next prompt, the
background flips to a calm green that's hard to miss out of the corner of
your eye. As soon as you start the next turn -- typing a prompt or letting
Claude pick up the next tool -- the green is removed and the terminal
goes right back to its default look.

It's a thin Claude Code plugin: a couple of hook scripts plus a small
installer that merges them into your `~/.claude/settings.json`. Recoloring
works by emitting [OSC 11](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Operating-System-Commands)
(background) and [OSC 10](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Operating-System-Commands)
(foreground) escape sequences to set the green tint, and OSC 110 / OSC 111
to reset back to the terminal's defaults.

## Supported terminals

Tested or expected to work:

- Windows Terminal -- both PowerShell 7+ and WSL bash
- gnome-terminal (Ubuntu)
- iTerm2, kitty, Alacritty, WezTerm, foot
- xterm

Caveats:

- Apple Terminal accepts OSC 11 but its handling of dynamic changes can be
  flaky -- your mileage may vary.
- Inside `tmux` or `screen` you need a passthrough; see Troubleshooting.
- Windows PowerShell 5.1 (the default `powershell.exe`) is **not** supported
  for the installer. Use PowerShell 7+ (`pwsh`) or run `install.sh` under WSL.

## Install

### Linux / macOS / WSL

```sh
git clone https://github.com/erikdj/claude-code-terminal-tint.git ~/.claude-code-terminal-tint
sh ~/.claude-code-terminal-tint/install.sh
```

### Windows (PowerShell 7+)

```powershell
git clone https://github.com/erikdj/claude-code-terminal-tint.git $env:USERPROFILE\.claude-code-terminal-tint
& $env:USERPROFILE\.claude-code-terminal-tint\install.ps1
```

Then **restart Claude Code** (or start a new session). Claude Code reads
`settings.json` at session start, so existing sessions won't pick up the
new hooks.

> If you move or rename the plugin folder later, re-run the installer.
> Hook entries store absolute paths.

## How it works

The installer merges three hook entries into `~/.claude/settings.json`:

| Event              | What we do                            | When it fires                                          |
| ------------------ | ------------------------------------- | ------------------------------------------------------ |
| `Stop`             | apply green tint (OSC 11 / OSC 10)    | Claude finished its turn and is waiting on you         |
| `UserPromptSubmit` | reset to terminal default (OSC 110/111) | You sent a new prompt                                  |
| `PreToolUse`       | reset to terminal default (OSC 110/111) | Claude is about to run a tool                          |

`Stop` is the once-per-turn event documented in the
[Claude Code hooks reference](https://docs.claude.com/en/docs/claude-code/hooks);
it only fires after the agentic loop has fully completed and the agent is
genuinely ready for human input. We deliberately do **not** also hook
`Notification`: that event fires multiple times per turn (for permission
prompts, idle prompts, `auth_success`, `elicitation_dialog`, etc.), and
hooking it produced spurious tints in the middle of tool-use loops.

Each hook fires a tiny script (`hooks/on_stop.*` for the green tint,
`hooks/on_resume.*` for the reset) that writes the OSC sequences directly
to the controlling terminal device. POSIX scripts write to `/dev/tty`;
PowerShell scripts open `CONOUT$` (the Windows analogue) as a `FileStream`
and write through that. **Both deliberately bypass stdout/stderr**, because
[the Claude Code hooks docs](https://code.claude.com/docs/en/hooks) confirm
that Claude Code captures both streams from hook child processes -- stdout
is parsed for JSON output and stderr is fed back to Claude as an error
message on non-zero exit, so any escape sequences written there would
never reach the terminal emulator. `/dev/tty` and `CONOUT$` are the
escape hatches that go straight to the inherited conhost / pty regardless
of how the parent process redirects standard handles.

> If you're contributing a port to another shell or platform: do not
> "simplify" the hooks to write to stdout or stderr. Write directly to
> the controlling terminal device. The automated tests
> (`test/test-install.{sh,ps1}`) enforce this.

The merge is idempotent. Running `install.sh` again (e.g. after editing
this plugin) replaces only the entries this plugin owns, identified by a
literal sentinel comment (`# claude-code-terminal-tint-marker`) appended
to each hook command. The sentinel is path-independent, so the installer
behaves the same whether you cloned the plugin into `~/.claude-code-terminal-tint`,
`~/dotfiles/`, or anywhere else. `#` is a comment in both POSIX `sh` and
PowerShell, so the marker has no effect at runtime. Anything else in your
`settings.json` is left alone, and the merged JSON is round-tripped through
a parser before being written so a corrupt file is never produced.

## Configure the color

There is exactly one configurable color: the tint applied while Claude is
waiting on you. Everything else uses your terminal's default theme.

Edit `config.json` in the plugin folder:

```json
{
  "waiting": {
    "background": "#1f5d3a",
    "foreground": "#e8f5e9"
  }
}
```

Hex format only (`#rrggbb`). The hook script reads `config.json` every
time it fires, so no reinstall is needed -- save the file and the next
`Stop` event picks it up.

A few alternate palettes if green isn't your thing:

| Vibe                | waiting bg / fg          |
| ------------------- | ------------------------ |
| **Default (green)** | `#1f5d3a` / `#e8f5e9`    |
| Amber               | `#7a4a00` / `#fff7e0`    |
| Cool (slate)        | `#1e3a5f` / `#e3f0ff`    |
| Coral               | `#7a1f3a` / `#ffe0eb`    |
| High-contrast green | `#0d3b1f` / `#ffffff`    |
| High-contrast amber | `#8a3500` / `#ffffff`    |

## Troubleshooting

**Nothing happens after install.** Confirm the hooks are registered:

```sh
grep claude-code-terminal-tint ~/.claude/settings.json
```

If you see three matches, you're good -- start a fresh Claude Code session.
`settings.json` is only read at session start.

**The green tint flashes on, then immediately snaps back to default.** Some
terminals reset OSC 11 on each new shell process. The sequences are meant
to persist for the life of the terminal session, so the next `Stop` event
will reapply the tint and the next `UserPromptSubmit` / `PreToolUse` will
reset it.

**Inside tmux or screen.** OSC 11 needs a passthrough. For tmux, in
`~/.tmux.conf`:

```
set -g allow-passthrough on
set -ga terminal-overrides ',*:Tc'
```

Then wrap the OSC sequences in a tmux DCS passthrough by editing
`hooks/on_stop.sh` and `hooks/on_resume.sh` to emit
`\033Ptmux;\033\033]11;<color>\033\033\\\033\\` instead of
`\033]11;<color>\033\\`. (PRs welcome to ship this as a config flag.)

**`pwsh: command not found` or `ConvertFrom-Json -AsHashtable not recognized`.**
The installer needs PowerShell 7+. Install from
<https://aka.ms/powershell>, or use the bash installer under WSL.

**`python3: command not found`.** The bash installer uses python3 to merge
JSON. On Ubuntu: `sudo apt install python3`. On macOS, python3 ships with
the Xcode command line tools.

**Want a different event to trigger the tint?** Edit
`~/.claude/settings.json` directly. The three events the installer wires
up are listed in the table above; the
[Claude Code hooks reference](https://docs.claude.com/en/docs/claude-code/hooks)
documents every available event. (Note: hooking `Notification` is
tempting but produces spurious mid-loop tints, because Notification fires
for many things that aren't "agent waiting on the human" -- see the
"How it works" section above.)

## Uninstall

### Linux / macOS / WSL

```sh
sh ~/.claude-code-terminal-tint/uninstall.sh
rm -rf ~/.claude-code-terminal-tint
```

### Windows

```powershell
& $env:USERPROFILE\.claude-code-terminal-tint\uninstall.ps1
Remove-Item -Recurse -Force $env:USERPROFILE\.claude-code-terminal-tint
```

Both uninstallers reset the terminal background and foreground via OSC
110 / OSC 111 so you aren't left staring at green after the plugin is
gone, and they remove only this plugin's entries from `settings.json` --
unrelated hooks stay put.

## Tests

Two regression tests cover the install / uninstall flow on each platform.
Both deliberately install the plugin at a path that does **not** contain
the string `claude-code-terminal-tint`, so the path-independent marker
that detects this plugin's own hook entries is actually exercised. They
also assert that pre-existing user hooks in `settings.json` are preserved
across install and uninstall, and that `settings.json` remains valid JSON
at every step.

```sh
# Linux / macOS / WSL -- requires bash + python3
bash test/test-install.sh
```

```powershell
# Windows -- requires PowerShell 7+ (same minimum as install.ps1)
pwsh -NoProfile -File test/test-install.ps1
```

The bash test additionally asserts that the POSIX hook scripts produce
no stderr when invoked without a controlling tty. The PowerShell hooks
intentionally write OSC bytes to stderr (the conhost interprets them as
recolor commands), so that assertion does not have a PowerShell analogue.

## License

MIT -- see [LICENSE](LICENSE).
