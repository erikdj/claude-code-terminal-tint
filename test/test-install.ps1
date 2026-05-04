#Requires -Version 7.0
<#
test/test-install.ps1 -- regression test for the PowerShell side of the
plugin. Mirrors test/test-install.sh.

Run:
    pwsh -NoProfile -File test/test-install.ps1

Requires PowerShell 7.0 or later (matching install.ps1's minimum, which
uses ConvertFrom-Json -AsHashtable -- a 7+-only feature).

Coverage (mirrors test-install.sh):
  - Hook scripts emit the right escape sequences:
      on_stop.ps1   -- OSC 11 / 10 with the green "waiting" palette
      on_resume.ps1 -- OSC 110 / 111 (reset to default), and NO
                       hardcoded OSC 11 color set
  - config.json defines the green "waiting" palette and no longer
    defines a "working" block.
  - install.ps1 registers exactly three hook entries (Stop,
    UserPromptSubmit, PreToolUse) and explicitly does NOT register
    anything on Notification.
  - Path-independent marker: idempotent re-installs and clean uninstall
    work even when the plugin lives at a path that does not contain
    "claude-code-terminal-tint".
  - Migration: a settings.json pre-seeded with the v0.1.0 layout (four
    plugin hooks including Notification) is collapsed to the new
    three-hook layout on re-install, and the Notification key is gone.
  - Pre-existing user hooks survive both install and uninstall.
  - settings.json round-trips through a JSON parser at every step.

Note on stderr: unlike the bash hooks (which write OSC sequences to
/dev/tty), the PowerShell hooks intentionally write OSC bytes to the
process's stderr stream via [Console]::Error.Write -- the conhost
interprets them as terminal-recolor commands. There is therefore no
"empty stderr" assertion equivalent to the bash test's tty-leak check.
#>

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot  = Split-Path -Parent $ScriptDir

$Work      = Join-Path ([System.IO.Path]::GetTempPath()) ("cctt-test-" + [System.Guid]::NewGuid())
$Plugin    = Join-Path $Work     'tint'
$FakeHome  = Join-Path $Work     'home'
$ClaudeDir = Join-Path $FakeHome '.claude'
$Settings  = Join-Path $ClaudeDir 'settings.json'

New-Item -ItemType Directory -Force -Path (Join-Path $Plugin 'hooks') | Out-Null
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null

Copy-Item -LiteralPath (Join-Path $RepoRoot 'install.ps1')         -Destination $Plugin
Copy-Item -LiteralPath (Join-Path $RepoRoot 'uninstall.ps1')       -Destination $Plugin
Copy-Item -LiteralPath (Join-Path $RepoRoot 'config.json')         -Destination $Plugin
Copy-Item -LiteralPath (Join-Path $RepoRoot 'hooks\on_stop.ps1')   -Destination (Join-Path $Plugin 'hooks')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'hooks\on_resume.ps1') -Destination (Join-Path $Plugin 'hooks')

$Mark            = '# claude-code-terminal-tint-marker'
$InstallScript   = Join-Path $Plugin 'install.ps1'
$UninstallScript = Join-Path $Plugin 'uninstall.ps1'
$ConfigPath      = Join-Path $Plugin 'config.json'
$OnStopPath      = Join-Path $Plugin 'hooks\on_stop.ps1'
$OnResumePath    = Join-Path $Plugin 'hooks\on_resume.ps1'

$script:Pass = 0
$script:Fail = 0

function Assert-Eq {
    param($got, $want, $desc)
    if ($got -eq $want) {
        Write-Host "ok  -- $desc"
        $script:Pass++
    } else {
        Write-Host "FAIL -- $desc (expected '$want', got '$got')" -ForegroundColor Red
        $script:Fail++
    }
}

function Get-OursCount {
    if (-not (Test-Path -LiteralPath $Settings)) { return 0 }
    try {
        $data = Get-Content -Raw -LiteralPath $Settings | ConvertFrom-Json -AsHashtable
    } catch {
        return 0
    }
    if ($null -eq $data -or -not $data.ContainsKey('hooks')) { return 0 }
    $hooks = $data['hooks']
    if ($hooks -isnot [hashtable]) { return 0 }
    $n = 0
    foreach ($arr in $hooks.Values) {
        if ($arr -is [System.Collections.IList]) {
            foreach ($g in $arr) {
                if ($g -is [hashtable] -and $g.ContainsKey('hooks')) {
                    foreach ($h in $g['hooks']) {
                        if ($h -is [hashtable] -and $h.ContainsKey('command')) {
                            $cmd = ([string]$h['command']).TrimEnd()
                            if ($cmd.EndsWith($Mark)) { $n++ }
                        }
                    }
                }
            }
        }
    }
    return $n
}

function Test-EventKey {
    param($name)
    if (-not (Test-Path -LiteralPath $Settings)) { return 'no' }
    try {
        $data = Get-Content -Raw -LiteralPath $Settings | ConvertFrom-Json -AsHashtable
    } catch {
        return 'no'
    }
    if ($null -eq $data -or -not $data.ContainsKey('hooks')) { return 'no' }
    if ($data['hooks'] -isnot [hashtable]) { return 'no' }
    if ($data['hooks'].ContainsKey($name)) { return 'yes' } else { return 'no' }
}

function Get-HasUserHook {
    if (-not (Test-Path -LiteralPath $Settings)) { return 'no' }
    try {
        $data = Get-Content -Raw -LiteralPath $Settings | ConvertFrom-Json -AsHashtable
    } catch {
        return 'no'
    }
    if ($null -eq $data -or -not $data.ContainsKey('hooks')) { return 'no' }
    $hooks = $data['hooks']
    if ($hooks -isnot [hashtable] -or -not $hooks.ContainsKey('Stop')) { return 'no' }
    foreach ($g in $hooks['Stop']) {
        if ($g -is [hashtable] -and $g.ContainsKey('hooks')) {
            foreach ($h in $g['hooks']) {
                if ($h -is [hashtable] -and ([string]$h['command']).Contains('user-existing-hook')) {
                    return 'yes'
                }
            }
        }
    }
    return 'no'
}

function Assert-JsonValid {
    $null = Get-Content -Raw -LiteralPath $Settings | ConvertFrom-Json
}

function Invoke-WithFakeHome {
    param([string]$ScriptPath)
    $prevHome    = $env:HOME
    $prevProfile = $env:USERPROFILE
    try {
        $env:HOME        = $FakeHome
        $env:USERPROFILE = $FakeHome
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath *> $null
    } finally {
        if ($null -eq $prevHome)    { Remove-Item Env:HOME        -ErrorAction SilentlyContinue }
        else                        { $env:HOME        = $prevHome }
        if ($null -eq $prevProfile) { Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue }
        else                        { $env:USERPROFILE = $prevProfile }
    }
}

# ---------- 0. Sanity guard --------------------------------------------------

if ($Plugin -like '*claude-code-terminal-tint*') {
    Write-Host "FAIL -- plugin path '$Plugin' contains plugin name; cannot exercise marker fix" -ForegroundColor Red
    exit 1
}
Write-Host "ok  -- plugin path '$Plugin' does not contain plugin name"
$script:Pass++

# ---------- 1. Static asset checks ------------------------------------------

$cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json -AsHashtable
Assert-Eq $cfg['waiting']['background'] '#1f5d3a' "config.json: waiting.background is the green hex"
Assert-Eq ($cfg.ContainsKey('working') ? 'yes' : 'no') 'no' "config.json: 'working' block is gone (single-color config)"

$onStopSrc   = Get-Content -Raw -LiteralPath $OnStopPath
$onResumeSrc = Get-Content -Raw -LiteralPath $OnResumePath

# Hook source uses  $ESC]11;  /  $ESC]10;  /  $ESC]110  /  $ESC]111  literals
# (the $ESC variable is bound to [char]27 at runtime). Match those tokens.
Assert-Eq ($onStopSrc.Contains('$ESC]11;')   ? 'yes' : 'no') 'yes' "on_stop.ps1 emits OSC 11 (set background)"
Assert-Eq ($onResumeSrc.Contains('$ESC]110') ? 'yes' : 'no') 'yes' "on_resume.ps1 emits OSC 110 (reset foreground)"
Assert-Eq ($onResumeSrc.Contains('$ESC]111') ? 'yes' : 'no') 'yes' "on_resume.ps1 emits OSC 111 (reset background)"
Assert-Eq ($onResumeSrc.Contains('$ESC]11;') ? 'yes' : 'no') 'no'  "on_resume.ps1 does NOT emit a hardcoded OSC 11 color set"

# ---------- 2. Fresh install + idempotency ----------------------------------

$preseed = @'
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "echo user-existing-hook"}]}
    ]
  },
  "model": "claude-sonnet-4-6"
}
'@
Set-Content -LiteralPath $Settings -Value $preseed -Encoding utf8

try {
    Invoke-WithFakeHome $InstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount)                3     'first install registers exactly 3 plugin hook entries'
    Assert-Eq (Test-EventKey 'Notification') 'no'  'first install does NOT register a Notification hook'
    Assert-Eq (Test-EventKey 'Stop')             'yes' 'first install registers Stop'
    Assert-Eq (Test-EventKey 'UserPromptSubmit') 'yes' 'first install registers UserPromptSubmit'
    Assert-Eq (Test-EventKey 'PreToolUse')       'yes' 'first install registers PreToolUse'
    Assert-Eq (Get-HasUserHook)              'yes' 'pre-existing user hook survives first install'

    Invoke-WithFakeHome $InstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount) 3 'second install is idempotent (still 3 entries)'

    Invoke-WithFakeHome $InstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount) 3 'third install is idempotent (still 3 entries)'

    # ---------- 3. Migration from v0.1.0 layout -----------------------------

    $seedHash = @{
        hooks = @{
            Stop = @(
                @{ hooks = @(@{ type = 'command'; command = 'echo user-existing-hook' }) }
                @{ hooks = @(@{ type = 'command'; command = "pwsh -File /old/hooks/on_stop.ps1 $Mark" }) }
            )
            Notification = @(
                @{ hooks = @(@{ type = 'command'; command = "pwsh -File /old/hooks/on_stop.ps1 $Mark" }) }
            )
            UserPromptSubmit = @(
                @{ hooks = @(@{ type = 'command'; command = "pwsh -File /old/hooks/on_resume.ps1 $Mark" }) }
            )
            PreToolUse = @(
                @{ matcher = '*'; hooks = @(@{ type = 'command'; command = "pwsh -File /old/hooks/on_resume.ps1 $Mark" }) }
            )
        }
        model = 'claude-sonnet-4-6'
    }
    $seedJson = $seedHash | ConvertTo-Json -Depth 32
    Set-Content -LiteralPath $Settings -Value $seedJson -Encoding utf8

    Invoke-WithFakeHome $InstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount)                3   'v0.1.0->current upgrade collapses 4 plugin entries to 3'
    Assert-Eq (Test-EventKey 'Notification') 'no' 'v0.1.0 Notification entry is removed on upgrade'
    Assert-Eq (Get-HasUserHook)              'yes' 'user hook on Stop survives v0.1.0->current upgrade'

    # ---------- 4. Uninstall + idempotent uninstall -------------------------

    Invoke-WithFakeHome $UninstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount)   0     'uninstall removes all plugin hook entries'
    Assert-Eq (Get-HasUserHook) 'yes' 'user hook survives uninstall'

    Invoke-WithFakeHome $UninstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount)   0     'second uninstall is a no-op'
    Assert-Eq (Get-HasUserHook) 'yes' 'user hook still present after second uninstall'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $Work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Summary: $($script:Pass) passed, $($script:Fail) failed."
if ($script:Fail -gt 0) { exit 1 }
exit 0
