#Requires -Version 7.0
<#
test/test-install.ps1 -- regression test for installer idempotency and the
path-independent marker on the Windows / PowerShell side. Mirrors
test/test-install.sh.

Run:
    pwsh -NoProfile -File test/test-install.ps1

Requires PowerShell 7.0 or later. (PowerShell 5.1 cannot run install.ps1
itself because install.ps1 uses `ConvertFrom-Json -AsHashtable`, which is
7+-only -- so the test inherits the same minimum.)

Coverage (mirrors test-install.sh):
    - Plugin path deliberately does NOT contain "claude-code-terminal-tint",
      which exercises the marker fix that this PR is built around.
    - Fresh install registers exactly 4 plugin hook entries.
    - Repeated installs are idempotent (still 4 entries; no duplicates).
    - Uninstall removes only the plugin's entries.
    - Pre-existing user hook entries survive both install and uninstall.
    - settings.json remains valid JSON after every step.

Note on stderr: unlike the bash hooks (which write OSC sequences to
/dev/tty), the PowerShell hooks intentionally write OSC bytes to the
process's stderr stream via [Console]::Error.Write -- the conhost
interprets them as terminal-recolor commands. There is therefore no
"empty stderr" assertion equivalent to the bash test's tty-leak check;
emitting bytes to stderr is the design.
#>

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot  = Split-Path -Parent $ScriptDir

# Tempdir under a GUID-named subfolder so the path is guaranteed not to
# contain the plugin name. Mirrors `mktemp -d` from the bash test, but
# uses a deterministic check for "no plugin substring" below.
$Work     = Join-Path ([System.IO.Path]::GetTempPath()) ("cctt-test-" + [System.Guid]::NewGuid())
$Plugin   = Join-Path $Work     'tint'
$FakeHome = Join-Path $Work     'home'
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

# Run install.ps1 / uninstall.ps1 in a child pwsh process. Setting
# $env:HOME (and $env:USERPROFILE for safety on Windows) on this process
# means the child inherits the env, and pwsh's automatic $HOME variable
# is initialised from $env:HOME at session start.
function Invoke-WithFakeHome {
    param([string]$ScriptPath)
    $prevHome    = $env:HOME
    $prevProfile = $env:USERPROFILE
    try {
        $env:HOME        = $FakeHome
        $env:USERPROFILE = $FakeHome
        # Discard stdout/stderr -- the OSC bytes that uninstall.ps1 emits
        # to stderr would otherwise clutter the test output.
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath *> $null
    } finally {
        if ($null -eq $prevHome)    { Remove-Item Env:HOME        -ErrorAction SilentlyContinue }
        else                        { $env:HOME        = $prevHome }
        if ($null -eq $prevProfile) { Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue }
        else                        { $env:USERPROFILE = $prevProfile }
    }
}

# Sanity guard: if the plugin path *does* contain the old substring, we'd
# be testing the wrong thing.
if ($Plugin -like '*claude-code-terminal-tint*') {
    Write-Host "FAIL -- plugin path '$Plugin' contains plugin name; cannot exercise marker fix" -ForegroundColor Red
    exit 1
}
Write-Host "ok  -- plugin path '$Plugin' does not contain plugin name"
$script:Pass++

# Pre-seed an unrelated user hook + a top-level setting we want preserved.
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
    # 1. Fresh install
    Invoke-WithFakeHome $InstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount)    4     'first install registers exactly 4 plugin hook entries'
    Assert-Eq (Get-HasUserHook)  'yes' 'pre-existing user hook survives first install'

    # 2. Repeat install -- must not duplicate
    Invoke-WithFakeHome $InstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount) 4 'second install is idempotent (still 4 entries)'

    Invoke-WithFakeHome $InstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount) 4 'third install is idempotent (still 4 entries)'

    # 3. Uninstall removes only our entries
    Invoke-WithFakeHome $UninstallScript
    Assert-JsonValid
    Assert-Eq (Get-OursCount)   0     'uninstall removes all plugin hook entries'
    Assert-Eq (Get-HasUserHook) 'yes' 'user hook survives uninstall'

    # 4. Idempotent uninstall
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
