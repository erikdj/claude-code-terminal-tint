# claude-code-terminal-tint: UserPromptSubmit / PreToolUse hook -- reset
# the terminal to its default colors so the user sees their normal palette
# whenever Claude is actively working.
#
# Emits OSC 110 (reset foreground) and OSC 111 (reset background) to the
# Windows console output device (`CONOUT$`). See on_stop.ps1 for why we
# write to CONOUT$ rather than [Console]::Error.Write or stdout: Claude
# Code captures both stdout and stderr from hook processes, so neither
# would reach the terminal emulator.
#
# Newer Claude Code spawns hook children that are NOT attached to the
# parent's ConPTY, so we FreeConsole + AttachConsole(-1) to bind to the
# parent process's console before writing -- same recovery pattern as
# on_stop.ps1, and the Windows analogue of the /proc-walk fallback in
# the POSIX hooks.

$ErrorActionPreference = 'SilentlyContinue'

try {
    Add-Type -ErrorAction SilentlyContinue -Namespace CcttHook -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeConsole();
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AttachConsole(uint dwProcessId);
'@
    $ATTACH_PARENT = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int]-1), 0)
    [CcttHook.Native]::FreeConsole() | Out-Null
    [CcttHook.Native]::AttachConsole($ATTACH_PARENT) | Out-Null
} catch { }

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
