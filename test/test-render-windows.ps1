<#
test/test-render-windows.ps1 -- manual visual-rendering verification.

The automated test (test/test-install.ps1) source-greps the hook scripts
to verify they target CONOUT$ instead of the Claude-Code-captured
stderr stream. That catches the obvious regression but does NOT prove
that Windows Terminal actually renders the resulting OSC bytes -- and
this whole plugin's reason for existing is that its terminal recoloring
is _visible_. So we ship a manual test that an engineer runs by hand
and confirms with their own eyes.

Run from a fresh Windows Terminal pane (not from inside Claude Code):

    pwsh -NoProfile -File test/test-render-windows.ps1

Expected sequence:
    1. ~ 2 seconds: Terminal background turns the configured "waiting"
       green (default #1f5d3a). Foreground turns light cream
       (default #e8f5e9). This is what `on_stop.ps1` produces.
    2. ~ 2 seconds: Terminal returns to your normal default colors
       (whatever theme you have set in WT). This is what
       `on_resume.ps1` produces.
    3. The script exits and you keep your default colors.

If step 1 doesn't happen, the OSC bytes are not reaching Windows
Terminal -- typically because they're being captured by a parent
process. Verify you are running this in WT directly, not inside a
Claude Code chat or another wrapper that captures stdout/stderr.

If step 1 happens but step 2 doesn't, your terminal does not implement
OSC 110 / 111 (reset). All modern terminals tested do; report this as
a bug if you see it.

Note: this script writes directly to CONOUT$, exactly the same way the
real hook scripts do, so a green flash here is strong evidence the
hooks themselves will work once Claude Code fires them.
#>

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot  = Split-Path -Parent $ScriptDir
$OnStop    = Join-Path $RepoRoot 'hooks\on_stop.ps1'
$OnResume  = Join-Path $RepoRoot 'hooks\on_resume.ps1'

if (-not (Test-Path -LiteralPath $OnStop) -or -not (Test-Path -LiteralPath $OnResume)) {
    Write-Error "Hook scripts not found at $OnStop / $OnResume. Run from inside the cloned repo."
}

Write-Host ""
Write-Host "About to apply the 'waiting' (green) tint by running on_stop.ps1."
Write-Host "Watch your Windows Terminal background; it should flip to green."
Write-Host "Press Enter to start..." -NoNewline
$null = Read-Host

& $OnStop

Write-Host ""
Write-Host "Tint applied. If the background did NOT change, the OSC bytes"
Write-Host "did not reach the terminal. Pausing 3 seconds, then resetting."
Start-Sleep -Seconds 3

& $OnResume

Write-Host ""
Write-Host "Reset applied. If the background did NOT return to default, your"
Write-Host "terminal does not implement OSC 110 / 111 (terminal-default reset)."
Write-Host ""
Write-Host "Done. If both transitions were visible, the rendering pipeline is good."
