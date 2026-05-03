# claude-code-terminal-tint: Stop / Notification hook -- apply "waiting" tint.
#
# Writes OSC 11 (background) and OSC 10 (foreground) sequences to stderr via
# [Console]::Error.Write, so the conhost recolors itself without polluting
# Claude Code's stdout. ST terminator = ESC + backslash.

$ErrorActionPreference = 'SilentlyContinue'

$Dir        = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ConfigPath = Join-Path $Dir 'config.json'

# Defaults -- kept in sync with config.json.
$bg = '#7a4a00'
$fg = '#fff7e0'

if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
        if ($cfg.waiting.background) { $bg = [string]$cfg.waiting.background }
        if ($cfg.waiting.foreground) { $fg = [string]$cfg.waiting.foreground }
    } catch { }
}

$ESC   = [char]27
$bgSeq = "$ESC]11;$bg$ESC\"
$fgSeq = "$ESC]10;$fg$ESC\"

[Console]::Error.Write($bgSeq)
[Console]::Error.Write($fgSeq)

exit 0
