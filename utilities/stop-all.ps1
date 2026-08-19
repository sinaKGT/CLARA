<#
.SYNOPSIS
    Stop everything this system runs - processes and containers.

.DESCRIPTION
    Frees every port the voice stack can hold and removes the Docker containers
    the memory layer created, so nothing here collides with your other projects.

    Ports it will free:
      8090  router             8765  speech pipeline
      8080  llama.cpp (manual)
      8770  web interface      8081  memory proxy   (only if it was installed)
      8082  embedding server   (only if it was installed)
      5679  n8n                11435 Ollama
      5433  Postgres

    Containers it will stop, BY NAME ONLY:
      memos-api  memos-neo4j  memos-qdrant
      clara-n8n  clara-postgres
    Nothing else on your Docker host is touched.

.PARAMETER Ports    Extra ports to free, e.g. -Ports 9000,9001
.PARAMETER NoDocker Skip the container step entirely.
.PARAMETER Remove   Also remove the containers (your data in n8n\ is kept either way).
#>
[CmdletBinding()]
param(
    [int[]]$Ports = @(),
    [switch]$NoDocker,
    [switch]$Remove
)

. "$PSScriptRoot\env.ps1"

$state = Get-KitState

# Every port this system can bind. The optional ones only exist if the memory
# layer was installed, but freeing an already-free port costs nothing.
$known = @(8090, 8765, 8770, 8080, 8081, 8082, 5679, 5433, 5678)
if ($state) {
    foreach ($k in 'llamaPort','voicePort','proxyPort','embedPort','n8nPort','ollamaPort','pgPort') {
        if (($state.PSObject.Properties.Name -contains $k) -and $state.$k) { $known += [int]$state.$k }
    }
}
$known = ($known + $Ports) | Sort-Object -Unique

Write-Host ''
Write-Host '  Stopping the voice system' -ForegroundColor White
Write-Host '  -------------------------' -ForegroundColor DarkGray

Write-Step 'Ports'
$stopped = 0
foreach ($port in $known) {
    if (Test-PortFree -Port $port) { Write-Info ("port {0,-5} free" -f $port); continue }
    $owner = Get-PortOwner -Port $port
    if (-not $owner) {
        Write-Warn2 ("port {0,-5} busy, owner unknown (another user, or elevated)" -f $port)
        continue
    }
    try {
        # Ask first, then insist. llama.cpp and the pipeline flush logs on a
        # clean exit; a straight -Force loses the tail of whatever went wrong.
        $null = $owner.CloseMainWindow()
        Start-Sleep -Milliseconds 400
        if (-not $owner.HasExited) { Stop-Process -Id $owner.Id -Force -ErrorAction Stop }
        Write-Ok ("port {0,-5} stopped {1} (PID {2})" -f $port, $owner.ProcessName, $owner.Id)
        $stopped++
    } catch {
        Write-Bad ("port {0,-5} could not stop PID {1}" -f $port, $owner.Id)
    }
}

# --- containers ---------------------------------------------------------------
if (-not $NoDocker) {
    Write-Step 'Containers'
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        Write-Info 'docker not on PATH - skipping'
    } else {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'

        # Preferred path: bring the whole project down through compose, which
        # sends SIGTERM and waits, in reverse dependency order. Killing Postgres
        # instead of stopping it risks an unclean shutdown of the agent memory.
        $compose = Join-Path $Kit 'n8n\docker-compose.yml'
        if (Test-Path $compose) {
            if ($Remove) {
                Write-Info 'docker compose down (containers removed, data kept)'
                & docker compose -f $compose down 2>&1 | ForEach-Object { Write-Info $_ }
            } else {
                Write-Info 'docker compose stop (graceful, in order)'
                & docker compose -f $compose stop 2>&1 | ForEach-Object { Write-Info $_ }
            }
            if ($LASTEXITCODE -eq 0) { Write-Ok 'agent stack stopped cleanly'; $script:stopped++ }
            else { Write-Warn2 'compose reported a problem - falling back to per-container stop' }
        }

        # Anything still running that belongs to us, including the retired
        # MemOS containers, gets stopped by name. Never by wildcard.
        $ours = @('clara-n8n','clara-postgres','memos-api','memos-neo4j','memos-qdrant')
        $running = & docker ps --format '{{.Names}}' 2>$null
        $stragglers = @($ours | Where-Object { $running -contains $_ })
        foreach ($c in $stragglers) {
            & docker stop -t 20 $c 2>&1 | Out-Null      # 20s grace, then SIGKILL
            Write-Ok "stopped $c"
            if ($Remove) { & docker rm -v $c 2>&1 | Out-Null; Write-Ok "removed $c" }
            $stopped++
        }
        if (-not $stragglers -and -not (Test-Path $compose)) {
            Write-Info 'none of this system''s containers are running'
        }
        $ErrorActionPreference = $prev
    }
}

# --- what is still holding those ports ---------------------------------------
Write-Step 'Result'
$busy = @()
foreach ($port in $known) { if (-not (Test-PortFree -Port $port)) { $busy += $port } }
if ($busy.Count -eq 0) {
    Write-Ok 'every port is free'
} else {
    foreach ($port in $busy) {
        $owner = Get-PortOwner -Port $port
        Write-Warn2 ("port {0} still held by {1}" -f $port, $(if ($owner) { "$($owner.ProcessName) (PID $($owner.Id))" } else { 'an unidentified process' }))
    }
    Write-Info 'If that is your own project rather than this one, it was never ours to stop.'
}

Write-Host ''
Write-Host "  Stopped $stopped thing(s)." -ForegroundColor Green
Write-Host ''
