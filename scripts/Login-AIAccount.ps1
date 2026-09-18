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
$expectedClaudeTier = $null
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
            $expectedClaudeTier = 'default_claude_max_20x'
            [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $null, 'Process')
            [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $null, 'Process')
            & claude auth login --claudeai --email 'jsy@awesomeent.kr'
        }
        'claude-6t' {
            $env:CLAUDE_CONFIG_DIR = Join-Path $profileRoot 'claude\6t'
            $expectedClaudeTier = 'default_claude_max_5x'
            [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $null, 'Process')
            [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $null, 'Process')
            & claude auth login --claudeai --email '6tawesome@gmail.com'
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Login command failed with exit code $LASTEXITCODE"
    }
    if ($expectedClaudeTier) {
        $credentialsPath = Join-Path $env:CLAUDE_CONFIG_DIR '.credentials.json'
        $credentials = Get-Content -LiteralPath $credentialsPath -Raw |
            ConvertFrom-Json
        $actualTier = [string]$credentials.claudeAiOauth.rateLimitTier
        if ($actualTier -ne $expectedClaudeTier) {
            & claude auth logout | Out-Null
            throw "Wrong Claude account: expected '$expectedClaudeTier', got '$actualTier'. The mismatched login was removed."
        }
    }
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}

Write-Output "Profile login completed: $Profile"
