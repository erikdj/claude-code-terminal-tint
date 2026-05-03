# claude-code-terminal-tint

Tint your terminal background based on what Claude Code is doing right now.
When Claude is working, the terminal stays a calm green. When Claude is
waiting on you, it switches to a warm amber. Hard to miss out of the corner
of your eye, easy to glance past when you don't need it.

It's a thin Claude Code plugin: four hook scripts plus a small installer
that merges them into your `~/.claude/settings.json`. Recoloring works by
emitting [OSC 11](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Operating-System-Commands)
(background) and [OSC 10](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Operating-System-Commands)
(foreground) escape sequences to the parent terminal.

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

The installer merges four hook entries into `~/.claude/settings.json`:

| Event              | Tint applied | When it fires                            |
| ------------------ | ------------ | ---------------------------------------- |
| `Stop`             | waiting      | Claude finished responding               |
| `Notification`     | waiting      | Claude is asking for permission or input |
| `UserPromptSubmit` | working      | You sent a new prompt                    |
| `PreToolUse`       | working      | Claude is about to run a tool            |

Each hook fires a tiny script (`hooks/on_stop.*` or `hooks/on_resume.*`)
that writes OSC 11/10 sequences to the parent terminal. POSIX scripts write
to `/dev/tty`; PowerShell scripts write to stderr via
`[Console]::Error.Write`. Either way, Claude Code's own stdout is never
touched, so the hook can't accidentally interfere with tool output or the
agent loop.

The merge is idempotent. Running `install.sh` again (e.g. after editing
this plugin) replaces only the entries this plugin owns, identified by a
literal sentinel comment (`# claude-code-terminal-tint-marker`) appended
to each hook command. The sentinel is path-independent, so the installer
behaves the same whether you cloned the plugin into `~/.claude-code-terminal-tint`,
`~/dotfiles/`, or anywhere else. `#` is a comment in both POSIX `sh` and
PowerShell, so the marker has no effect at runtime. Anything else in your
`settings.json` is left alone, and the merged JSON is round-tripped through
a parser before being written so a corrupt file is never produced.

## Configure colors

Edit `config.json` in the plugin folder:

```json
{
  "working": {
    "background": "#1f5d3a",
    "foreground": "#e8f5e9"
  },
  "waiting": {
    "background": "#7a4a00",
    "foreground": "#fff7e0"
  }
}
```

Hex format only (`#rrggbb`). The hook scripts read `config.json` every time
they fire, so no reinstall is needed -- save the file and the next event
picks it up.

A few alternate palettes if green/amber aren't your thing:

| Vibe                     | working bg / fg          | waiting bg / fg          |
| ------------------------ | ------------------------ | ------------------------ |
| **Default**              | `#1f5d3a` / `#e8f5e9`    | `#7a4a00` / `#fff7e0`    |
| Cool (slate / coral)     | `#1e3a5f` / `#e3f0ff`    | `#7a1f3a` / `#ffe0eb`    |
| High-contrast            | `#0d3b1f` / `#ffffff`    | `#8a3500` / `#ffffff`    |
| Subtle (charcoal / dusk) | `#1a1a1a` / `#dcdcdc`    | `#3a2a1a` / `#f0e0c8`    |

## Troubleshooting

**Nothing happens after install.** Confirm the hooks are registered:

```sh
grep claude-code-terminal-tint ~/.claude/settings.json
```

If you see four matches, you're good -- start a fresh Claude Code session.
`settings.json` is only read at session start.

**The tint flashes briefly, then snaps back.** Some terminals reset OSC 11
on each new shell process. The sequences are meant to persist for the life
of the terminal session, so the next `Stop` or `UserPromptSubmit` event
will reapply.

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
`~/.claude/settings.json` directly. The four events the installer wires up
are listed in the table above; the
[Claude Code hooks reference](https://docs.claude.com/en/docs/claude-code/hooks)
documents every available event.

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
110 / OSC 111 so you aren't left staring at amber after the plugin is
gone, and they remove only this plugin's entries from `settings.json` --
unrelated hooks stay put.

## License

MIT -- see [LICENSE](LICENSE).
