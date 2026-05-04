# claude-code-terminal-tint: Stop hook -- apply "waiting" tint.
#
# Fires when the main agent finishes its turn and is genuinely waiting on
# the user. Writes OSC 11 (background) and OSC 10 (foreground) sequences
# to the Windows console output device (`CONOUT$`), which is the analogue
# of POSIX `/dev/tty`.
#
# Why CONOUT$ and not [Console]::Error.Write or [Console]::Out.Write?
# Claude Code captures both stdout and stderr from hook child processes
# (per the hooks docs: stdout is parsed for JSON output, stderr is
# surfaced as an error message on non-zero exit). Bytes written to either
# stream therefore never reach the terminal emulator. CONOUT$ opens a
# direct handle to the inherited conhost / pseudoconsole, which IS still
# connected to Windows Terminal even when stdout/stderr have been pipe-
# redirected by the parent process. The terminator used is ST (ESC + \\),
# accepted by Windows Terminal and every other modern emulator.

$ErrorActionPreference = 'SilentlyContinue'

$Dir        = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ConfigPath = Join-Path $Dir 'config.json'

# Defaults -- kept in sync with config.json.
$bg = '#1f5d3a'
$fg = '#e8f5e9'

if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
        if ($cfg.waiting.background) { $bg = [string]$cfg.waiting.background }
        if ($cfg.waiting.foreground) { $fg = [string]$cfg.waiting.foreground }
    } catch { }
}

$ESC = [char]27

try {
    $stream = [System.IO.File]::Open(
        'CONOUT$',
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::ASCII)
        $writer.Write("$ESC]11;$bg$ESC\")
        $writer.Write("$ESC]10;$fg$ESC\")
        $writer.Flush()
    } finally {
        $stream.Dispose()
    }
} catch {
    # No conhost available (e.g. running under a service or detached
    # session) -- silently skip rather than surface a hook error.
}

exit 0
