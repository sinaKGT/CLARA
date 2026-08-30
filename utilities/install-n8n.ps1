<#
.SYNOPSIS
    Install n8n, Ollama and Postgres for the agent workflows.

.DESCRIPTION
    Everything lands inside D:\local_agent\n8n\ as relative bind mounts, so the
    whole thing is portable: move the folder and workflows, credentials, agent
    memory and models all move with it. No named Docker volumes are used.

    Container names are prefixed "clara-" and cannot collide with other projects.

        clara-n8n        5679    workflow editor
        clara-postgres   5433    agent memory

    Every host port is deliberately off the upstream default, so an n8n, Ollama
    or Postgres already installed on the machine keeps working untouched.
    Override with -Port / -PgPort.

.PARAMETER Port        Host port for n8n. Default 5679.
.PARAMETER PgPort      Host port for Postgres. Default 5433.
#>
[CmdletBinding()]
param(
        [int]$Port       = 5679,    # n8n      (upstream default 5678)
    [int]$PgPort     = 5433     # Postgres (upstream default 5432)
)

. "$PSScriptRoot\env.ps1"

$N8nDir  = Join-Path $Kit 'n8n'
$Compose = Join-Path $N8nDir 'docker-compose.yml'

Write-Host ''
Write-Host '  Agent stack: n8n + Ollama + Postgres' -ForegroundColor White
Write-Host '  ------------------------------------' -ForegroundColor DarkGray

Write-Step 'Checking Docker'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Bad 'Docker Desktop is not installed or not on PATH.'
    Write-Info 'https://www.docker.com/products/docker-desktop/'
    exit 1
}
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& docker info 2>&1 | Out-Null
$engineUp = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prev
if (-not $engineUp) { Write-Bad 'Docker is installed but the engine is not running. Start Docker Desktop.'; exit 1 }
Write-Ok "docker ready: $(& docker --version)"
if (-not (Test-Path -LiteralPath $Compose)) { Write-Bad "missing $Compose"; exit 1 }

foreach ($d in 'data','ollama','postgres','files','backups') {
    [System.IO.Directory]::CreateDirectory((Join-Path $N8nDir $d)) | Out-Null
}
Write-Ok 'n8n\{data, ollama, postgres, files, backups} ready'

Write-Step 'Checking ports'
foreach ($p in @($Port, $PgPort)) {
    if (Test-PortFree -Port $p) { Write-Info ("port {0,-6} free" -f $p) }
    else {
        $o = Get-PortOwner -Port $p
        Write-Warn2 ("port {0} already in use{1}" -f $p, $(if($o){" by $($o.ProcessName)"}))
    }
}

# n8n encrypts saved credentials with this key. If it changes, every stored
# credential becomes unreadable - so it is generated once and kept.
# .env carries both the encryption key and the host ports. The key must survive
# across restarts or every saved credential becomes unreadable, so it is
# generated once and never regenerated.
$envFile = Join-Path $N8nDir '.env'
$key = $null
if (Test-Path -LiteralPath $envFile) {
    $m = Select-String -Path $envFile -Pattern '^N8N_ENCRYPTION_KEY=(.+)$'
    if ($m) { $key = $m.Matches[0].Groups[1].Value }
}
if (-not $key) {
    $key = -join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    Write-Ok 'generated a new encryption key'
} else {
    Write-Ok 'kept the existing encryption key'
}
Write-Utf8NoBom -Path $envFile -Content @"
N8N_ENCRYPTION_KEY=$key
N8N_PORT=$Port
PG_PORT=$PgPort
"@
Write-Ok "ports written to n8n\.env  (n8n $Port, postgres $PgPort)"

$args = @('compose','-f',$Compose)

Write-Step 'Pulling images'
Write-Info 'n8n ~360 MB, ollama ~600 MB, postgres ~80 MB'
Push-Location -LiteralPath $N8nDir
try {
    Invoke-Native -FilePath 'docker' -Arguments ($args + @('pull'))
    Write-Step 'Starting the stack'
    Invoke-Native -FilePath 'docker' -Arguments ($args + @('up','-d'))
} finally { Pop-Location }

# --- Postgres on a Windows bind mount is the fragile part, so verify it -------
Write-Step 'Verifying Postgres wrote into the folder'
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & docker exec clara-postgres pg_isready -U clara -d agents 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($rc -eq 0) { $ok = $true; break }
}
$pgdata = Join-Path $N8nDir 'postgres\pgdata'
if ($ok -and (Test-Path -LiteralPath (Join-Path $pgdata 'PG_VERSION'))) {
    Write-Ok "Postgres is live and its data is in n8n\postgres\pgdata (portable)"
} elseif ($ok) {
    Write-Warn2 'Postgres answers but n8n\postgres\pgdata looks empty - data may not be on the host.'
    Write-Info 'Check:  docker logs clara-postgres'
} else {
    Write-Bad 'Postgres did not become ready.'
    Write-Info 'Windows bind mounts can reject the Postgres data directory.'
    Write-Info 'Check:  docker logs clara-postgres'
}

foreach ($svc in @(@{n='n8n';p=$Port})) {
    if (Wait-ForPort -Port $svc.p -TimeoutSec 180) { Write-Ok "$($svc.n) is up on $($svc.p)" }
    else { Write-Warn2 "$($svc.n) has not answered - docker logs clara-$($svc.n)" }
}

$state = Get-KitState
if ($state) {
    $state | Add-Member -NotePropertyName n8nEnabled  -NotePropertyValue $true  -Force
    $state | Add-Member -NotePropertyName n8nPort     -NotePropertyValue $Port  -Force
    $state | Add-Member -NotePropertyName pgPort      -NotePropertyValue $PgPort -Force
    Write-Utf8NoBom -Path $StateFile -Content ($state | ConvertTo-Json -Depth 5)
    Write-Ok 'system.json updated'
}

Write-Host ''
Write-Host "  n8n:      http://127.0.0.1:$Port    (create your owner account)" -ForegroundColor Green
Write-Host ''
Write-Host '  Inside a workflow, use these host names - not localhost:' -ForegroundColor DarkGray
Write-Host '    Ollama    http://host.docker.internal:11434   (your desktop app)' -ForegroundColor DarkGray
Write-Host '    Postgres  host clara-postgres  port 5432  db agents  user clara  password clara' -ForegroundColor DarkGray
Write-Host '  (those are the INSIDE-the-network ports and never change,' -ForegroundColor DarkGray
Write-Host "   whatever host ports you picked)" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Ollama must allow container access. In Windows env vars set:' -ForegroundColor DarkGray
Write-Host '    OLLAMA_HOST = 0.0.0.0     then restart Ollama' -ForegroundColor DarkGray
Write-Host ''
