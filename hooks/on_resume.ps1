# claude-code-terminal-tint: UserPromptSubmit / PreToolUse hook -- reset
# the terminal to its default colors so the user sees their normal palette
# whenever Claude is actively working.
#
# Emits OSC 110 (reset foreground) and OSC 111 (reset background) via
# [Console]::Error.Write so the conhost restores whatever colors the user
# had configured before the "waiting" tint was applied. We deliberately
# do NOT set a specific "working" color, because that would override the
# user's own theme. Terminals that don't implement OSC 110/111 will pick
# up default colors on their next repaint.

$ErrorActionPreference = 'SilentlyContinue'

$ESC = [char]27

[Console]::Error.Write("$ESC]111$ESC\")
[Console]::Error.Write("$ESC]110$ESC\")

exit 0
