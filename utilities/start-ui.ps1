<#
.SYNOPSIS
    Start the whole system in the background.

.DESCRIPTION
    Order matters and is handled here:

      agent stack    n8n + Postgres (docker, fired first, boots in parallel)
      interface:8770 the page you talk to - instant, so it goes up FIRST and
                     stays up even if something below it fails
      router :8090   forwards each turn to its agent's n8n webhook
      pipeline:8765  voice - VAD, speech-to-text, text-to-speech

    Order used to be the other way round, with the interface last. A pipeline
    that failed or ran long meant the web server was never reached at all and
    the browser showed nothing - the one component that could have told you
    what went wrong was the one that never started. Now the page is always
    there; a failed pipeline is reported on it instead of as a blank tab.

    The LLM lives in n8n now (Ollama), so nothing here loads one.

.PARAMETER Port       Interface port. Default 8770.
.PARAMETER Force      Reclaim busy ports from a previous run.
.PARAMETER NoBrowser  Do not open the browser.
.PARAMETER Detach     Return when everything is up (the menu uses this).
#>
[CmdletBinding()]
param(
    [int]$Port = 8770,
    [switch]$Force,
    [switch]$NoBrowser,
    [switch]$Detach
)

. "$PSScriptRoot\env.ps1"
Assert-Installed

$state = Get-KitState
if (-not $state) { Write-Bad 'system.json missing - run the installer first.'; exit 1 }

$uiDir = Join-Path $Kit 'ui'
if (-not (Test-Path -LiteralPath (Join-Path $uiDir 'index.html'))) { Write-Bad "ui\index.html missing"; exit 1 }

$voicePort = [int]$state.voicePort
$uiUrl     = "http://127.0.0.1:$Port/"
$startedAt = Get-Date

Write-Host ''
Write-Host '  starting' -ForegroundColor White

if (-not (Assert-PortAvailable -Port $Port -Label 'interface' -Force:$Force -ScriptHint '.\utilities\start-ui.ps1')) { exit 1 }
if ($Force) {
    if (-not (Assert-PortAvailable -Port $voicePort -Label 'pipeline' -Force -ScriptHint '.\utilities\start-ui.ps1')) { exit 1 }
}

# --- agent stack first: docker returns immediately, n8n boots while the voice
# --- models load, so the wall-clock cost is close to zero.
$compose = Join-Path $Kit 'n8n\docker-compose.yml'
$stack = (Test-Path -LiteralPath $compose) -and (Get-Command docker -ErrorAction SilentlyContinue)
if ($stack -and -not (Test-PortAnswers -Port (Get-ContainerPort -Container 'clara-n8n' -InternalPort 5678 -Fallback 5679))) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & docker compose -f $compose up -d 2>&1 |
        Out-File -LiteralPath (Join-Path $LogsDir 'docker-up.log') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { Write-Warn2 'agent stack did not start (is Docker Desktop running?) - voice will still work' }
    $ErrorActionPreference = $prev
}

$total = 3

# 1. the page, always, whatever else happens
if ($Detach) {
    if (-not (Start-BackgroundService -Name 'interface' -Script "$ScriptDir\serve-ui.ps1" `
              -Port $Port -Arguments @('-Port',"$Port") -TimeoutSec 60 -Index 1 -Total $total)) {
        Write-Bad 'the interface did not start - see logs\interface.log'
        exit 1
    }
} else {
    Write-Host ("  {0} {1,2}/{2}  {3,-15}" -f (Get-ProgressBar -Done 0 -Total $total), 1, $total, 'interface') -NoNewline -ForegroundColor Gray
    Write-Host 'ok' -ForegroundColor Green
}

# 2. the router
#
# Always relaunched, never reused. Start-BackgroundService skips anything whose
# port already answers, which is right for the pipeline (90 s of model loading)
# but wrong here: the router is our own code, starts in under two seconds, and a
# stale one left over from a previous run keeps serving the OLD forwarding
# contract while looking perfectly healthy. That failure is invisible from the
# outside - the symptom shows up in n8n as markers that were not stripped and a
# missing sessionId, which is a long way from the cause. Two seconds is cheap
# insurance against that.
$degraded = @()
$stale = @(Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction SilentlyContinue)
foreach ($c in $stale) {
    try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction Stop } catch {}
}
if ($stale.Count) { Start-Sleep -Milliseconds 400 }
if (-not (Start-BackgroundService -Name 'router' -Script "$ScriptDir\start-router.ps1" `
          -Port 8090 -TimeoutSec 60 -Index 2 -Total $total)) {
    $degraded += 'router (logs\router.log)'
}

# 3. the voice pipeline - slowest by far, and no longer able to take the page
#    down with it. If it fails you still get the interface, which is where the
#    error is legible.
if (-not (Start-BackgroundService -Name 'pipeline' -Script "$ScriptDir\start-server.ps1" `
          -Port $voicePort -TimeoutSec 900 -Index 3 -Total $total)) {
    $degraded += 'pipeline (logs\pipeline.log)'
}

if ($stack) { Wait-ForPortShown -Port (Get-ContainerPort -Container 'clara-n8n' -InternalPort 5678 -Fallback 5679) -Label 'n8n' -TimeoutSec 120 `
                -SlowHint 'n8n still booting - docker logs -f clara-n8n' | Out-Null }

$elapsed = [math]::Round(((Get-Date) - $startedAt).TotalSeconds)
Write-Host ''
if ($degraded.Count) {
    Write-Warn2 ("started with problems: " + ($degraded -join ', '))
    Write-Host ("  interface is up at $uiUrl - but talking will not work until the above is fixed") -ForegroundColor Yellow
} else {
    Write-Host ("  ready in ${elapsed}s   $uiUrl") -ForegroundColor Green
}
Write-Host ''

if (-not $NoBrowser) {
    Start-Job -ScriptBlock {
        param($url, $uiPort)
        function Ready([int]$p) {
            try { $c=[Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1',$p); $c.Close(); $true } catch { $false }
        }
        for ($i=0; $i -lt 120; $i++) { if (Ready $uiPort) { break }; Start-Sleep -Milliseconds 400 }
        Start-Sleep -Milliseconds 400
        Start-Process $url
    } -ArgumentList $uiUrl, $Port | Out-Null
}

if (-not $Detach) {
    Invoke-Native -FilePath $VenvPython -Arguments @('-m','http.server',"$Port",'--bind','127.0.0.1','--directory',$uiDir)
}
