# claude-code-terminal-tint uninstaller (PowerShell).
#
# Removes our entries from %USERPROFILE%\.claude\settings.json and resets
# the terminal colors via OSC 110 / OSC 111 so users aren't left with a
# tinted terminal.

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "PowerShell 7+ (pwsh) is required. Install from https://aka.ms/powershell, or run uninstall.sh under WSL."
    exit 1
}

$Settings = Join-Path $HOME '.claude\settings.json'

if (Test-Path -LiteralPath $Settings) {
    $raw = (Get-Content -Raw -LiteralPath $Settings).Trim()
    if ($raw) {
        try {
            $data = $raw | ConvertFrom-Json -AsHashtable
        } catch {
            $data = $null
        }
        if ($data -is [hashtable] -and $data.ContainsKey('hooks') -and $data['hooks'] -is [hashtable]) {
            $hooks = $data['hooks']
            $Mark  = '# claude-code-terminal-tint-marker'
            $removed = 0

            function Test-IsOurs {
                param($group)
                if ($null -eq $group -or $null -eq $group.hooks) { return $false }
                foreach ($h in $group.hooks) {
                    if ($null -ne $h -and $h.command) {
                        $cmd = ([string]$h.command).TrimEnd()
                        if ($cmd.EndsWith($Mark)) { return $true }
                    }
                }
                return $false
            }

            foreach ($event in @($hooks.Keys)) {
                $arr = $hooks[$event]
                if ($arr -isnot [System.Collections.IList]) { continue }
                $kept = @()
                foreach ($g in $arr) {
                    if (Test-IsOurs $g) { $removed++ }
                    else { $kept += ,$g }
                }
                if ($kept.Count -eq 0) {
                    $hooks.Remove($event)
                } else {
                    $hooks[$event] = @($kept)
                }
            }
            if ($hooks.Count -eq 0) { $data.Remove('hooks') }

            $out = $data | ConvertTo-Json -Depth 32
            $null = $out | ConvertFrom-Json   # validate
            Set-Content -LiteralPath $Settings -Value $out -Encoding UTF8
            Write-Host ("Removed {0} claude-code-terminal-tint hook entr{1}." -f $removed, $(if ($removed -eq 1) { 'y' } else { 'ies' }))
        }
    }
}

# Reset terminal colors to defaults via the conhost device. We write to
# CONOUT$ rather than [Console]::Error because Claude Code-spawned hook
# child processes have their stderr captured -- and although uninstall is
# typically run by hand, we use the same approach the hooks do for
# consistency, and so a script-driven uninstall (e.g. from CI or
# automation) still resets the running terminal.
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

Write-Host "Uninstalled. Restart Claude Code for the settings change to take effect."
