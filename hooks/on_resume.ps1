# claude-code-terminal-tint: UserPromptSubmit / PreToolUse hook -- apply
# "working" tint. Mirrors on_stop.ps1 but reads the "working" block.

$ErrorActionPreference = 'SilentlyContinue'

$Dir        = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ConfigPath = Join-Path $Dir 'config.json'

$bg = '#1f5d3a'
$fg = '#e8f5e9'

if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
        if ($cfg.working.background) { $bg = [string]$cfg.working.background }
        if ($cfg.working.foreground) { $fg = [string]$cfg.working.foreground }
    } catch { }
}

$ESC   = [char]27
$bgSeq = "$ESC]11;$bg$ESC\"
$fgSeq = "$ESC]10;$fg$ESC\"

[Console]::Error.Write($bgSeq)
[Console]::Error.Write($fgSeq)

exit 0
