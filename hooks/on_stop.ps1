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

# ---------------------------------------------------------------------------
# Optional diagnostic probe + cheap-attach fallback.
#
# When $env:CCTT_PROBE = '1', dump per-hook console / stdio diagnostics to
# $env:TEMP\cctt-probe-<timestamp>.json AND attempt the cheap-attach
# recovery (FreeConsole + AttachConsole(-1)) so the subsequent CONOUT$
# write is performed against the parent's console. If the parent IS
# Windows Terminal's ConPTY (the case we want to support), this should
# render visibly. The probe leaves the console attached to whatever the
# last successful AttachConsole call selected; this is intentional, so
# the visual outcome of the run tells us whether the cheap fix is
# sufficient or whether we need a sidecar.
#
# When $env:CCTT_PROBE is unset, this block is a no-op and the hook
# behaves exactly like before (open CONOUT$ directly, write OSC).
# ---------------------------------------------------------------------------
if ($env:CCTT_PROBE -eq '1') {
    try {
        $probeSig = @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AttachConsole(uint dwProcessId);
[DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint GetConsoleProcessList(uint[] lpdwProcessList, uint dwProcessCount);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint GetFileType(System.IntPtr hFile);
'@
        Add-Type -MemberDefinition $probeSig -Name CcttProbeNative -Namespace CcttProbe -ErrorAction SilentlyContinue

        function Probe-Snapshot {
            $hwnd = [CcttProbe.CcttProbeNative]::GetConsoleWindow()
            $buf = New-Object uint32[] 64
            $count = [CcttProbe.CcttProbeNative]::GetConsoleProcessList($buf, 64)
            $procs = @()
            for ($i = 0; $i -lt $count; $i++) {
                $cp = Get-CimInstance Win32_Process -Filter "ProcessId=$($buf[$i])" -ErrorAction SilentlyContinue
                if ($cp) { $procs += @{ pid = [int]$buf[$i]; name = $cp.Name } }
                else    { $procs += @{ pid = [int]$buf[$i]; name = '(unknown)' } }
            }
            $conOutOK = $false; $conOutErr = $null
            try {
                $tfs = [System.IO.File]::Open('CONOUT$', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $conOutOK = $true; $tfs.Dispose()
            } catch { $conOutErr = $_.Exception.Message }
            return @{
                consoleWindow = $hwnd.ToInt64()
                processCount = [int]$count
                processList = $procs
                conOutOpen = $conOutOK
                conOutError = $conOutErr
            }
        }

        $report = [ordered]@{
            timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ')
            pid = $PID
            ppid = $null
            ancestors = @()
            stdio = @{}
            initialConsole = @{}
            env = @{}
            attachParentResult = @{}
            attachToPwshResult = @{}
        }

        # Ancestor chain (up to 8 levels)
        $cur = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
        $report.ppid = $cur.ParentProcessId
        $depth = 0
        $pwshPid = $null
        while ($cur -and $depth -lt 8) {
            $report.ancestors += [ordered]@{
                depth = $depth
                pid = [int]$cur.ProcessId
                ppid = [int]$cur.ParentProcessId
                name = $cur.Name
                cmdline = $cur.CommandLine
            }
            if (-not $pwshPid -and $cur.ProcessId -ne $PID -and $cur.Name -match '^(pwsh|powershell)\.exe$') {
                $pwshPid = [int]$cur.ProcessId
            }
            if (-not $cur.ParentProcessId -or $cur.ParentProcessId -eq 0) { break }
            $cur = Get-CimInstance Win32_Process -Filter "ProcessId=$($cur.ParentProcessId)" -ErrorAction SilentlyContinue
            $depth++
        }
        $report.pwshAncestorPid = $pwshPid

        # Stdio handle types
        $STD_IN = -10; $STD_OUT = -11; $STD_ERR = -12
        function Probe-HandleType($which) {
            $h = [CcttProbe.CcttProbeNative]::GetStdHandle($which)
            $t = [CcttProbe.CcttProbeNative]::GetFileType($h)
            $names = @{ 0 = 'UNKNOWN'; 1 = 'DISK'; 2 = 'CHAR(console)'; 3 = 'PIPE'; 4 = 'REMOTE' }
            $name = if ($names.ContainsKey([int]$t)) { $names[[int]$t] } else { "type=$t" }
            return @{ handle = $h.ToInt64(); type = $name }
        }
        $report.stdio = @{
            stdin  = (Probe-HandleType $STD_IN)
            stdout = (Probe-HandleType $STD_OUT)
            stderr = (Probe-HandleType $STD_ERR)
            isInputRedirected  = [System.Console]::IsInputRedirected
            isOutputRedirected = [System.Console]::IsOutputRedirected
            isErrorRedirected  = [System.Console]::IsErrorRedirected
        }

        # Initial console state (before any attach attempts)
        $report.initialConsole = Probe-Snapshot

        # Env vars
        $report.env = @{}
        Get-ChildItem Env: |
            Where-Object { $_.Name -match '^(CLAUDE|WT_|TERM|CONHOST|CONEMU|MSYSTEM|SESSIONNAME|COLORTERM)' } |
            Sort-Object Name |
            ForEach-Object { $report.env[$_.Name] = $_.Value }

        # Attempt #1: AttachConsole(-1) (ATTACH_PARENT_PROCESS)
        $attachParentUint = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int]-1), 0)
        $freeRet = [CcttProbe.CcttProbeNative]::FreeConsole()
        $attachRet = [CcttProbe.CcttProbeNative]::AttachConsole($attachParentUint)
        $attachLE = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $report.attachParentResult = @{
            freeReturn   = [bool]$freeRet
            attachReturn = [bool]$attachRet
            lastError    = [int]$attachLE
            postAttach   = (Probe-Snapshot)
        }

        # Attempt #2: AttachConsole($pwshPid) if found in chain
        if ($pwshPid) {
            $null = [CcttProbe.CcttProbeNative]::FreeConsole()
            $attachRet2 = [CcttProbe.CcttProbeNative]::AttachConsole([uint32]$pwshPid)
            $attachLE2 = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $report.attachToPwshResult = @{
                pwshPid      = $pwshPid
                attachReturn = [bool]$attachRet2
                lastError    = [int]$attachLE2
                postAttach   = (Probe-Snapshot)
            }
            # If pwsh-attach failed, fall back to parent-attach so the
            # subsequent CONOUT$ write at least has the parent's console.
            if (-not $attachRet2) {
                $null = [CcttProbe.CcttProbeNative]::FreeConsole()
                $null = [CcttProbe.CcttProbeNative]::AttachConsole($attachParentUint)
            }
        } else {
            $report.attachToPwshResult = @{ skipped = 'no pwsh.exe / powershell.exe in ancestor chain' }
        }

        # Write the report to TEMP. Use a stable timestamp filename so
        # multiple Stop hooks in one session don't collide.
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $outPath = Join-Path $env:TEMP "cctt-probe-$stamp.json"
        $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outPath -Encoding utf8

        # Write the same path back to a well-known marker so the user
        # (or a reporting script) can find the latest dump easily.
        Set-Content -LiteralPath (Join-Path $env:TEMP 'cctt-probe-latest.txt') -Value $outPath -Encoding utf8
    } catch {
        # Probe is best-effort. Do not let any probe failure break the
        # hook -- fall through to the normal CONOUT$ write below.
    }
}

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
