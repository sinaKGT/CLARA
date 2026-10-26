<#
.SYNOPSIS
    Update n8n to the newest release of the tag in n8n\docker-compose.yml.

.DESCRIPTION
    Pulls the n8n image and recreates only the clara-n8n container. Postgres
    and everything else in the stack is left alone.

    n8n migrates its database on the first start of a new version, and an
    older n8n cannot open a migrated database. So before switching, n8n is
    stopped and n8n\data\.n8n is copied to n8n\backups\n8n-<old version>-<date>.
    Workflows, credentials and files live in n8n\ on the host and carry over.

    To go back: stop n8n, copy the backup over n8n\data\.n8n, and pin the old
    version in docker-compose.yml, e.g.  image: docker.n8n.io/n8nio/n8n:2.34.4

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\utilities\update-n8n.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\env.ps1"

$N8nDir    = Join-Path $Kit 'n8n'
$Compose   = Join-Path $N8nDir 'docker-compose.yml'
$DataDir   = Join-Path $N8nDir 'data\.n8n'
$BackupDir = Join-Path $N8nDir 'backups'
$Container = 'clara-n8n'

# Run docker and return its stdout. Docker writes progress and warnings to
# stderr, which 'Stop' would otherwise turn into a terminating error.
function Get-Docker {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & docker @args 2>$null } finally { $ErrorActionPreference = $prev }
}

# The version baked into an image, read by running its CLI once.
function Get-ImageVersion([string]$Image) {
    $v = Get-Docker run --rm --entrypoint n8n $Image --version | Select-Object -Last 1
    if ($v) { "$v".Trim() } else { 'unknown' }
}

Write-Host ''
Write-Host '  Update n8n' -ForegroundColor White
Write-Host '  ----------' -ForegroundColor DarkGray

Write-Step 'Checking Docker'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Bad 'Docker Desktop is not installed or not on PATH.'
    exit 1
}
$null = Get-Docker info
if ($LASTEXITCODE -ne 0) { Write-Bad 'Docker is not running. Start Docker Desktop and try again.'; exit 1 }
if (-not (Test-Path -LiteralPath $Compose)) { Write-Bad "missing $Compose"; exit 1 }

Push-Location -LiteralPath $N8nDir
try {
    # Image and port come from the compose file, so pinning a version there is
    # all it takes to hold n8n back.
    $cfg   = Get-Docker compose -f $Compose config --format json | Out-String | ConvertFrom-Json
    $image = $cfg.services.n8n.image
    $port  = 5679
    if ($cfg.services.n8n.ports) { $port = [int]$cfg.services.n8n.ports[0].published }

    $oldId  = Get-Docker inspect $Container --format '{{.Image}}'
    $oldVer = $null
    if ($oldId) { $oldVer = Get-ImageVersion $oldId; Write-Ok "installed: n8n $oldVer" }
    else        { Write-Info 'n8n is not installed yet - this will install it' }

    Write-Step "Downloading $image"
    Invoke-Native -FilePath 'docker' -Arguments @('compose', '-f', $Compose, 'pull', 'n8n')
    if ($LASTEXITCODE -ne 0) { Write-Bad 'download failed - check the internet connection'; exit 1 }

    $newId  = Get-Docker image inspect $image --format '{{.Id}}'
    $newVer = Get-ImageVersion $image
    if ($oldId -and $newId -eq $oldId) {
        Write-Ok "already up to date: n8n $newVer"
        exit 0
    }
    if ($oldVer) { Write-Ok "n8n $oldVer  ->  $newVer" } else { Write-Ok "n8n $newVer" }

    # The backup has to happen BEFORE the new version opens the database, and
    # with n8n stopped: SQLite keeps recent writes in database.sqlite-wal while
    # it runs, so a copy of a live database can miss them.
    if ($oldId -and (Test-Path -LiteralPath $DataDir)) {
        Write-Step 'Backing up workflows and credentials'
        Invoke-Native -FilePath 'docker' -Arguments @('compose', '-f', $Compose, 'stop', 'n8n')
        $dest = Join-Path $BackupDir ('n8n-{0}-{1}' -f $oldVer, (Get-Date -Format 'yyyyMMdd-HHmm'))
        # robocopy rather than Copy-Item: community nodes under nodes\ nest
        # deeper than the 260-character path limit Copy-Item stops at.
        & robocopy $DataDir $dest /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-Bad 'backup failed - n8n was NOT updated, starting the old version again'
            # start, not up: up would recreate the container from the new image.
            Invoke-Native -FilePath 'docker' -Arguments @('compose', '-f', $Compose, 'start', 'n8n')
            exit 1
        }
        Write-Ok "n8n\backups\$(Split-Path -Leaf $dest)"
    }

    Write-Step "Starting n8n $newVer"
    Write-Info 'the first start upgrades the database - give it a minute'
    Invoke-Native -FilePath 'docker' -Arguments @('compose', '-f', $Compose, 'up', '-d', 'n8n')
    if ($LASTEXITCODE -ne 0) { Write-Bad "could not start n8n - see: docker logs $Container"; exit 1 }

    # Not Wait-ForPortShown: Docker Desktop accepts connections on a published
    # port before n8n listens, so a port check passes instantly even if the
    # database upgrade then fails. /healthz only answers once n8n is serving.
    Write-Host '    waiting for n8n ' -NoNewline -ForegroundColor DarkGray
    $t0 = Get-Date; $ready = $false
    while (((Get-Date) - $t0).TotalSeconds -lt 300) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "http://127.0.0.1:$port/healthz"
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }
    Write-Host ''
    if ($ready) {
        Write-Ok "n8n $newVer is running on http://127.0.0.1:$port"
    } else {
        Write-Warn2 "n8n has not answered after 5 minutes - see: docker logs $Container"
        Write-Info  "the old version's data is in n8n\backups\ if you need to go back"
    }

    # The old image is around 2 GB and nothing uses it any more. Docker refuses
    # if another tag or container still needs it, which is fine.
    if ($oldId) {
        $null = Get-Docker image rm $oldId
        if ($LASTEXITCODE -eq 0) { Write-Ok "old image removed (n8n $oldVer)" }
    }
} finally {
    Pop-Location
}

Write-Host ''
