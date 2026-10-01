<#
.SYNOPSIS
  Hammurapi installer for Windows (docker compose).

.EXAMPLE
  .\install\install.ps1 -Demo           # fake GitLab + scripted agent
.EXAMPLE
  .\install\install.ps1                 # interactive: your GitHub or GitLab
#>
param(
  [switch]$Demo,
  [switch]$Voice,
  [switch]$Yes,
  [ValidateSet('github', 'gitlab', '')][string]$Provider = ''
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Parent = Split-Path -Parent $Root
$RepoBase = if ($env:REPO_BASE) { $env:REPO_BASE } else { 'https://github.com/GreenOnGrey' }

function Say($m) { Write-Host "> $m" -ForegroundColor Magenta }
function Die($m) { Write-Host "x $m" -ForegroundColor Red; exit 1 }
function Ask($q, $def) {
  if ($Yes) { return $def }
  $a = Read-Host "$q$(if ($def) { " [$def]" })"
  if ([string]::IsNullOrWhiteSpace($a)) { return $def } else { return $a }
}
function New-Secret { $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b) }

Say 'Checking prerequisites'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Die 'Docker Desktop is required: https://docs.docker.com/desktop/' }
docker compose version *> $null; if ($LASTEXITCODE -ne 0) { Die 'Docker Compose v2 is required' }
docker info *> $null; if ($LASTEXITCODE -ne 0) { Die 'Docker Desktop is not running' }

foreach ($repo in 'hammurapi-core', 'hammurapi-web') {
  if (-not (Test-Path (Join-Path $Parent $repo))) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "$repo is missing next to hammurapi and git is not installed" }
    Say "Cloning $repo"
    git clone --depth 1 "$RepoBase/$repo.git" (Join-Path $Parent $repo)
  }
}

$EnvFile = Join-Path $Root '.env'
$keep = $false
if (Test-Path $EnvFile) { $keep = $Yes -or ((Ask '.env exists. Keep it? (y/n)' 'y') -notmatch '^[Nn]') }

if (-not $keep) {
  $values = [ordered]@{
    TOKEN_ENCRYPTION_KEY = New-Secret
    WEBHOOK_SECRET       = ((New-Secret) -replace '[^A-Za-z0-9]', '').Substring(0, 32)
    CI_RESULTS_SECRET    = ((New-Secret) -replace '[^A-Za-z0-9]', '').Substring(0, 32)
  }
  if ($Demo) {
    Say 'Demo mode: in-memory fake GitLab and a scripted agent (no real LLM)'
    $values += [ordered]@{
      PUBLIC_URL = 'http://localhost:8080'; GIT_PROVIDER = 'gitlab'; GIT_BASE_URL = 'http://fakegitlab:8929'
      GIT_OAUTH_URL = 'http://localhost:8929'; GIT_REPO = 'demo/specs'; GITLAB_CLIENT_ID = 'demo'
      GITLAB_CLIENT_SECRET = 'demo'; BOOTSTRAP_ADMINS = 'admin'
      GITLAB_BOT_TOKEN = 'demo-bot-' + ((New-Secret) -replace '[^A-Za-z0-9]', '').Substring(0, 12); HOOKS_URL = 'http://api:8080'
    }
  } else {
    $publicUrl = (Ask 'Public URL of Hammurapi' 'http://localhost:8080').TrimEnd('/')
    if (-not $Provider) { $Provider = Ask 'Git provider (github/gitlab)' 'gitlab' }
    $baseDefault = if ($Provider -eq 'github') { 'https://github.com' } else { 'https://gitlab.com' }
    $values.PUBLIC_URL = $publicUrl
    $values.GIT_PROVIDER = $Provider
    $values.GIT_BASE_URL = (Ask 'Provider URL' $baseDefault).TrimEnd('/')
    $values.GIT_REPO = Ask 'Specifications repository (owner/name)' ''
    $values.GIT_DEFAULT_BRANCH = Ask 'Default branch' 'main'
    if ($Provider -eq 'gitlab') {
      $values.GITLAB_CLIENT_ID = Ask 'GitLab OAuth application ID' ''
      $values.GITLAB_CLIENT_SECRET = Ask 'GitLab OAuth application secret' ''
      $values.GITLAB_BOT_TOKEN = Ask 'Token of the bot user (agent branches and MRs in service repositories)' ''
    } else {
      $values.GITHUB_APP_ID = Ask 'GitHub App ID' ''
      $values.GITHUB_CLIENT_ID = Ask 'GitHub App client ID' ''
      $values.GITHUB_CLIENT_SECRET = Ask 'GitHub App client secret' ''
    }
    $values.BOOTSTRAP_ADMINS = Ask 'Logins of the first administrators (comma-separated)' ''
    $values.AGENT_TARGET = Ask 'Agent: fake or claude' 'fake'
    if ($values.AGENT_TARGET -eq 'claude') {
      $values.ACP_AGENT_COMMAND = 'claude-agent-acp'
      $values.ACP_AGENT_ENV = 'ANTHROPIC_API_KEY=' + (Ask 'Anthropic API key' '')
    }
    if (-not $values.GIT_REPO) { Die 'the repository is required' }
  }
  $lines = Get-Content (Join-Path $Root '.env.example')
  $lines = $lines | ForEach-Object {
    $line = $_
    foreach ($k in $values.Keys) { if ($line -match "^$k=") { $line = "$k=$($values[$k])" } }
    $line
  }
  [IO.File]::WriteAllLines($EnvFile, $lines)
  Say "Wrote $EnvFile"
}

$profiles = @()
if ($Demo) { $profiles += '--profile', 'demo' }
if ($Voice) { $profiles += '--profile', 'voice' }
Say 'Building and starting containers (first run takes a few minutes)'
Push-Location $Root
try { docker compose @profiles up -d --build; if ($LASTEXITCODE -ne 0) { Die 'docker compose failed' } } finally { Pop-Location }

Say 'Waiting for the api to become ready'
$ready = $false
for ($i = 0; $i -lt 90; $i++) {
  try { Invoke-WebRequest -UseBasicParsing http://localhost:9100/readyz -TimeoutSec 2 | Out-Null; $ready = $true; break } catch { Start-Sleep 2 }
}
if (-not $ready) { Die 'the api is not ready; see: docker compose logs api' }

$envMap = @{}
Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $envMap[$k] = $v }
Write-Host ''
Write-Host 'Hammurapi is running.' -ForegroundColor Green
Write-Host "  Open:            $($envMap.PUBLIC_URL)"
if ($Demo) {
  Write-Host '  Sign in as:      admin (global administrator), anna or oleg - any login works'
  Write-Host '  Fake GitLab:     http://localhost:8929  (development only)'
} else {
  Write-Host "  OAuth callback:  $($envMap.PUBLIC_URL)/api/v1/auth/callback"
  Write-Host "  Webhook URL:     $($envMap.PUBLIC_URL)/hooks/v1/git   (push events)"
  Write-Host "  Webhook secret:  $($envMap.WEBHOOK_SECRET)"
  Write-Host "  Copy $Root\rules into the repository (rules/<area>/template.md, fix-template.md)."
}
Write-Host ''
Write-Host '  Logs:     docker compose logs -f api worker'
Write-Host '  Cleaner:  docker compose run --rm api cleaner'
Write-Host '  Stop:     docker compose down'
