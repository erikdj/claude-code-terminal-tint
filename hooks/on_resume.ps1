# claude-code-terminal-tint: UserPromptSubmit / PreToolUse hook -- reset
# the terminal to its default colors so the user sees their normal palette
# whenever Claude is actively working.
#
# Emits OSC 110 (reset foreground) and OSC 111 (reset background) to the
# Windows console output device (`CONOUT$`). See on_stop.ps1 for why we
# write to CONOUT$ rather than [Console]::Error.Write or stdout: Claude
# Code captures both stdout and stderr from hook processes, so neither
# would reach the terminal emulator.

$ErrorActionPreference = 'SilentlyContinue'

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
        $writer.Write("$ESC]111$ESC\")
        $writer.Write("$ESC]110$ESC\")
        $writer.Flush()
    } finally {
        $stream.Dispose()
    }
} catch {
    # No conhost available -- silently skip.
}

exit 0
