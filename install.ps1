# claude-code-terminal-tint installer (PowerShell).
#
# Merges hook entries into %USERPROFILE%\.claude\settings.json without
# clobbering existing hooks. Re-running the installer updates entries in
# place (idempotent).
#
# Requires PowerShell 7+ (pwsh) -- ConvertFrom-Json -AsHashtable is not
# available in Windows PowerShell 5.1. If you only have 5.1, run install.sh
# from inside WSL instead.

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "PowerShell 7+ (pwsh) is required. Install from https://aka.ms/powershell, or run install.sh under WSL."
    exit 1
}

$Dir         = Split-Path -Parent $PSCommandPath
$SettingsDir = Join-Path $HOME '.claude'
$Settings    = Join-Path $SettingsDir 'settings.json'

if (-not (Test-Path -LiteralPath $SettingsDir)) {
    New-Item -ItemType Directory -Path $SettingsDir | Out-Null
}
if (-not (Test-Path -LiteralPath $Settings)) {
    Set-Content -LiteralPath $Settings -Value '{}' -Encoding UTF8
}

# Load existing settings; recover from empty / malformed files by backing up.
$raw = (Get-Content -Raw -LiteralPath $Settings).Trim()
if (-not $raw) { $raw = '{}' }
try {
    $data = $raw | ConvertFrom-Json -AsHashtable
    if ($null -eq $data -or $data -isnot [hashtable]) { throw "settings.json is not a JSON object" }
} catch {
    Write-Warning "Could not parse settings.json ($_); backing up existing file to settings.json.bak."
    Copy-Item -LiteralPath $Settings -Destination "$Settings.bak" -Force
    $data = @{}
}

if (-not $data.ContainsKey('hooks') -or $data['hooks'] -isnot [hashtable]) {
    $data['hooks'] = @{}
}
$hooks = $data['hooks']

# We invoke pwsh explicitly so the hooks work regardless of execution policy.
$StopPath   = Join-Path $Dir 'hooks\on_stop.ps1'
$ResumePath = Join-Path $Dir 'hooks\on_resume.ps1'
$StopCmd   = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$StopPath`""
$ResumeCmd = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$ResumePath`""

$Mark = 'claude-code-terminal-tint'

function Test-IsOurs {
    param($group)
    if ($null -eq $group -or $null -eq $group.hooks) { return $false }
    foreach ($h in $group.hooks) {
        if ($null -ne $h -and $h.command -and ([string]$h.command).Contains($Mark)) {
            return $true
        }
    }
    return $false
}

function Invoke-Upsert {
    param($event, $cmd, $matcher)
    if (-not $hooks.ContainsKey($event) -or $hooks[$event] -isnot [System.Collections.IList]) {
        $hooks[$event] = @()
    }
    $kept = @()
    foreach ($g in $hooks[$event]) {
        if (-not (Test-IsOurs $g)) { $kept += ,$g }
    }
    $entry = @{ hooks = @(@{ type = 'command'; command = $cmd }) }
    if ($matcher) { $entry['matcher'] = $matcher }
    $kept += ,$entry
    # Force array shape so ConvertTo-Json never collapses a single-element
    # list into a bare object.
    $hooks[$event] = @($kept)
}

Invoke-Upsert 'Stop'             $StopCmd   $null
Invoke-Upsert 'Notification'     $StopCmd   $null
Invoke-Upsert 'UserPromptSubmit' $ResumeCmd $null
Invoke-Upsert 'PreToolUse'       $ResumeCmd '*'

$out = $data | ConvertTo-Json -Depth 32
# Validate by re-parsing -- throws if the output is malformed.
$null = $out | ConvertFrom-Json
Set-Content -LiteralPath $Settings -Value $out -Encoding UTF8

Write-Host "Installed claude-code-terminal-tint hooks -> $Settings"
Write-Host "Done. Restart Claude Code (or start a new session) for hooks to take effect."
