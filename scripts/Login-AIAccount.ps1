[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('codex-6t', 'codex-wna', 'claude-jsy', 'claude-6t')]
    [string]$Profile
)

$ErrorActionPreference = 'Stop'
$profileRoot = Join-Path $env:USERPROFILE '.ai-usage-accounts'
$environmentNames = @(
    'CODEX_HOME',
    'CLAUDE_CONFIG_DIR',
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_AUTH_TOKEN'
)
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    switch ($Profile) {
        'codex-6t' {
            $env:CODEX_HOME = Join-Path $profileRoot 'codex\6t'
            & codex login
        }
        'codex-wna' {
            $env:CODEX_HOME = Join-Path $profileRoot 'codex\wna'
            & codex login
        }
        'claude-jsy' {
            $env:CLAUDE_CONFIG_DIR = Join-Path $profileRoot 'claude\jsy'
            [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $null, 'Process')
            [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $null, 'Process')
            & claude auth login
        }
        'claude-6t' {
            $env:CLAUDE_CONFIG_DIR = Join-Path $profileRoot 'claude\6t'
            [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $null, 'Process')
            [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $null, 'Process')
            & claude auth login
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Login command failed with exit code $LASTEXITCODE"
    }
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}

Write-Output "Profile login completed: $Profile"
