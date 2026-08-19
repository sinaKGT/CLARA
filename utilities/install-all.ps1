<#
.SYNOPSIS
    Install everything. One command, on a clean machine.

.DESCRIPTION
    This is only an orchestrator. Each part still has its own script, so you can
    run, re-run or debug any of them on their own:

        install.ps1        the voice system   (uv, Python, llama.cpp, models)
        install-n8n.ps1    the agent stack    (n8n, Ollama, Postgres in Docker)

    Running this is the same as running those in order, with a preflight first
    and a summary at the end. Every step is skippable and safe to repeat.

.PARAMETER Voice     Install only the voice system.
.PARAMETER Agents    Install only the agent stack.
.PARAMETER Quant     GGUF quantisation for the voice LLM. Default Q4_0.
.PARAMETER Port      n8n host port.      Default 5679.
.PARAMETER PgPort    Postgres host port. Default 5433.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\utilities\install-all.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\utilities\install-all.ps1 -Agents
#>
[CmdletBinding()]
param(
    [switch]$Voice,
    [switch]$Agents,
    [ValidateSet('Q4_0','Q8_0','BF16')][string]$Quant = 'Q4_0',
    [int]$Port = 5679,
    [int]$PgPort = 5433
)

. "$PSScriptRoot\env.ps1"

# No switch given means "everything".
$doVoice  = $Voice -or -not ($Voice -or $Agents)
$doAgents = $Agents -or -not ($Voice -or $Agents)

Write-Host ''
Write-Host '  FULL INSTALL' -ForegroundColor White
Write-Host '  ------------' -ForegroundColor DarkGray
Write-Host "  target: $Kit"
Write-Host ''
Write-Host ("  voice system   {0}" -f $(if($doVoice){'yes'}else{'skipped'}))
Write-Host ("  agent stack    {0}" -f $(if($doAgents){'yes'}else{'skipped'}))
Write-Host ''

# ------------------------------------------------------------------ preflight
Write-Step 'Preflight'
$fail = $false

if ([Environment]::Is64BitOperatingSystem -ne $true) { Write-Bad '64-bit Windows required'; $fail = $true }
else { Write-Ok "Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion)" }

$drive  = (Get-Item $Kit).PSDrive.Name
$freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB, 1)
$needGB = 0; if ($doVoice) { $needGB += 22 }; if ($doAgents) { $needGB += 12 }
if ($freeGB -lt $needGB) { Write-Bad "$freeGB GB free on ${drive}: - about $needGB GB needed"; $fail = $true }
else { Write-Ok "$freeGB GB free on ${drive}: (need ~$needGB GB)" }

$gpu = Get-GpuInfo
if ($gpu.HasNvidia) { Write-Ok "GPU: $($gpu.GpuName), $([math]::Round($gpu.VramMB/1024,1)) GB" }
else { Write-Warn2 'No NVIDIA GPU - everything still works, just slower' }

if ($doAgents) {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & docker info 2>&1 | Out-Null
        $up = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prev
        if ($up) { Write-Ok 'Docker engine running' }
        else { Write-Bad 'Docker is installed but not running - start Docker Desktop'; $fail = $true }
    } else {
        Write-Bad 'Docker Desktop is required for the agent stack'
        Write-Info 'https://www.docker.com/products/docker-desktop/  (or run with -Voice to skip it)'
        $fail = $true
    }
    foreach ($p in @($Port, $PgPort)) {
        if (Test-PortFree -Port $p) { Write-Ok ("port {0,-6} free" -f $p) }
        else {
            $o = Get-PortOwner -Port $p
            Write-Bad ("port {0} already in use{1}" -f $p, $(if($o){" by $($o.ProcessName)"}))
            Write-Info 'Pass a different -Port / -PgPort'
            $fail = $true
        }
    }
}
if ($fail) { Write-Host ''; Write-Bad 'Preflight failed - nothing was installed.'; exit 1 }

# --------------------------------------------------------------------- steps
$steps = @()
if ($doVoice)  { $steps += @{ Name='Voice system'; Script='install.ps1'
                              Args=@('-Quant',$Quant) } }
if ($doAgents) { $steps += @{ Name='Agent stack';  Script='install-n8n.ps1'
                              Args=@('-Port',"$Port",'-PgPort',"$PgPort") } }

$results = @()
$n = 0
foreach ($step in $steps) {
    $n++
    Write-Host ''
    Write-Host ("  ===== [{0}/{1}] {2} =====" -f $n, $steps.Count, $step.Name) -ForegroundColor Cyan
    Write-Host ''
    $path = Join-Path $ScriptDir $step.Script
    if (-not (Test-Path $path)) {
        Write-Bad "missing $($step.Script)"
        $results += @{ Name=$step.Name; Ok=$false }
        continue
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @($step.Args)
    $ok = ($LASTEXITCODE -eq 0)
    $results += @{ Name=$step.Name; Ok=$ok }
    if (-not $ok) { Write-Warn2 "$($step.Name) reported a problem - continuing" }
}

# ------------------------------------------------------------------- summary
Write-Host ''
Write-Host '  ===== SUMMARY =====' -ForegroundColor White
foreach ($r in $results) {
    if ($r.Ok) { Write-Ok $r.Name } else { Write-Bad "$($r.Name) - re-run utilities\$($steps[$results.IndexOf($r)].Script)" }
}
Write-Host ''
if ($doVoice)  { Write-Host '  Voice agent   CLARA.cmd, then 1' -ForegroundColor Green }
if ($doAgents) { Write-Host "  Workflows     http://127.0.0.1:$Port" -ForegroundColor Green }
Write-Host '  Health check  CLARA.cmd, then 5' -ForegroundColor DarkGray
Write-Host ''
