[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$NoStartup,
    [switch]$SkipCodexSnapshot
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseExe = Join-Path $repoRoot 'target\release\claude-code-usage-monitor.exe'
# Codex Desktop is an MSIX-packaged process.  When this installer is invoked
# from Codex, LOCALAPPDATA/APPDATA can be package-redirected into Codex's
# LocalCache.  A desktop companion must live outside that package so Codex
# updates and shutdowns cannot remove or own it.
$realLocalAppData = Join-Path $env:USERPROFILE 'AppData\Local'
$realRoamingAppData = Join-Path $env:USERPROFILE 'AppData\Roaming'
$installRoot = Join-Path $realLocalAppData 'AIUsageMonitor'
$installedExe = Join-Path $installRoot 'AIUsageMonitor.exe'
$appDataRoot = Join-Path $realRoamingAppData 'ClaudeCodeUsageMonitor'
$themeRoot = Join-Path $appDataRoot 'themes'
$themeSource = Join-Path $repoRoot 'src\themes\four-account-weekly-monitor.json'
$themeTarget = Join-Path $themeRoot 'four-account-weekly-monitor-user.json'
$themeAssetSource = Join-Path $repoRoot 'src\themes\assets'
$themeAssetRoot = Join-Path $themeRoot 'assets'
$profileRoot = Join-Path $env:USERPROFILE '.ai-usage-accounts'

$profiles = [ordered]@{
    Codex6t  = Join-Path $profileRoot 'codex\6t'
    CodexWna = Join-Path $profileRoot 'codex\wna'
    ClaudeJsy = Join-Path $profileRoot 'claude\jsy'
    Claude6t = Join-Path $profileRoot 'claude\6t'
}

if (-not $SkipBuild) {
    & cargo build --release --manifest-path (Join-Path $repoRoot 'Cargo.toml')
    if ($LASTEXITCODE -ne 0) {
        throw "Release build failed with exit code $LASTEXITCODE"
    }
}
if (-not (Test-Path -LiteralPath $releaseExe)) {
    throw "Release executable was not found: $releaseExe"
}

New-Item -ItemType Directory -Force -Path $installRoot, $appDataRoot, $themeRoot, $themeAssetRoot, $profileRoot | Out-Null
foreach ($directory in $profiles.Values) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

# Account files contain OAuth credentials. Keep this tree private to the
# signed-in Windows user and let new files inherit that ACL.
$windowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $profileRoot /inheritance:r /grant:r "${windowsIdentity}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to protect the account profile directory"
}

if (-not $SkipCodexSnapshot) {
    $currentCodex = Join-Path $env:USERPROFILE '.codex\auth.json'
    $savedCodex = Join-Path $profiles.Codex6t 'auth.json'
    if ((Test-Path -LiteralPath $currentCodex) -and -not (Test-Path -LiteralPath $savedCodex)) {
        Copy-Item -LiteralPath $currentCodex -Destination $savedCodex
    }
}

Copy-Item -LiteralPath $releaseExe -Destination $installedExe -Force
Copy-Item -LiteralPath $themeSource -Destination $themeTarget -Force
Copy-Item -LiteralPath (Join-Path $themeAssetSource 'openai-mark.png') -Destination (Join-Path $themeAssetRoot 'openai-mark.png') -Force
Copy-Item -LiteralPath (Join-Path $themeAssetSource 'claude-mark.png') -Destination (Join-Path $themeAssetRoot 'claude-mark.png') -Force

$settingsPath = Join-Path $appDataRoot 'settings.json'
$desktopSurfaceOffsets = [ordered]@{}
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $existingSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if ($null -ne $existingSettings.desktop_surface_offsets) {
            $desktopSurfaceOffsets = $existingSettings.desktop_surface_offsets
        }
    } catch {
        Write-Warning "Existing desktop positions could not be read; the default layout will be used."
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $appDataRoot "settings.before-four-accounts.$stamp.json")
}

$settings = [ordered]@{
    accounts = [ordered]@{
        claude = [ordered]@{
            profiles = @(
                [ordered]@{
                    id = 'account_1'
                    name = '클로드 (공용) · Claude Max 5x'
                    config_dir = $profiles.Claude6t
                    credentials_path = ''
                    desktop_org_id = '6e4be185-eca5-41c5-a733-b9c5a9afb72d'
                    enabled = $true
                },
                [ordered]@{
                    id = 'default'
                    name = '클로드 (승엽) · Claude Max 20x'
                    config_dir = $profiles.ClaudeJsy
                    credentials_path = ''
                    desktop_org_id = '62c74cc8-cc55-4c43-a853-416ec7e4b0e9'
                    enabled = $true
                }
            )
            selected = 'default'
            used_ids = @('default', 'account_1')
        }
        codex = [ordered]@{
            profiles = @(
                [ordered]@{
                    id = 'default'
                    name = '코덱스 (공용) · ChatGPT Pro 20x'
                    config_dir = $profiles.Codex6t
                    credentials_path = ''
                    desktop_org_id = ''
                    enabled = $true
                },
                [ordered]@{
                    id = 'account_1'
                    name = '코덱스 (승엽) · ChatGPT Pro 5x'
                    config_dir = $profiles.CodexWna
                    credentials_path = ''
                    desktop_org_id = ''
                    enabled = $true
                }
            )
            selected = 'default'
            used_ids = @('default', 'account_1')
        }
    }
    poll_interval_ms = 120000
    language = 'ko'
    show_claude_code = $true
    show_codex = $true
    show_antigravity = $false
    show_opencode = $false
    show_cursor = $false
    custom_theme_enabled = $true
    usage_countdown = $true
    active_theme_path = $themeTarget
    desktop_surface_offsets = $desktopSurfaceOffsets
}

$json = $settings | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupShortcut = Join-Path `
    ([Environment]::GetFolderPath('Startup')) `
    'AI Usage Monitor.lnk'
Remove-ItemProperty `
    -Path $runKey `
    -Name 'AI Usage Monitor' `
    -ErrorAction SilentlyContinue
if ($NoStartup) {
    Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue
} else {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupShortcut)
    $shortcut.TargetPath = $installedExe
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description = 'AI usage, RAM, and drive desktop monitor'
    $shortcut.Save()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
}

Write-Output "Installed: $installedExe"
Write-Output "Settings:  $settingsPath"
Write-Output "Profiles:  $profileRoot"
Write-Output "Theme:     $themeTarget"
Write-Output "Startup:   $startupShortcut"
