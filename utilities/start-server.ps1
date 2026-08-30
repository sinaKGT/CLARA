<#
.SYNOPSIS
    Run the pipeline as an OpenAI Realtime-compatible server (no local audio).

.DESCRIPTION
    Exposes ws://<host>:8765/v1/realtime. Connect with the browser
    demo in repo\demo, or any OpenAI Realtime client - point the OpenAI SDK at
    base_url http://<host>:8765/v1 with any api_key.

.PARAMETER Config  Config file in configs\. Default serve-gpu.json.
.PARAMETER Lan     Bind 0.0.0.0 so other machines on your network can connect.
.PARAMETER NoWait  Do not wait for the LLM port before starting.
#>
[CmdletBinding()]
param(
    [string]$Config = 'serve-gpu.json',
    [switch]$Lan,
    [switch]$NoWait,
    [switch]$LogFile,
    [switch]$Force
)

. "$PSScriptRoot\env.ps1"
Assert-Installed

$state = Get-KitState
if ($state) {
    if (-not (Assert-PortAvailable -Port ([int]$state.voicePort) -Label 'Realtime server' `
              -Force:$Force -ScriptHint '.\start-server.ps1')) { exit 1 }
}
$cfgPath = if (Test-Path -LiteralPath $Config) { (Resolve-Path -LiteralPath $Config).Path } else { Join-Path $ConfigDir $Config }
if (-not (Test-Path -LiteralPath $cfgPath)) { Write-Bad "Config not found: $cfgPath"; exit 1 }

if ($Lan) {
    $tmp = Join-Path $TempDir ("s2s-" + [guid]::NewGuid().ToString('N') + '.json')
    $obj = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    $obj | Add-Member -NotePropertyName host -NotePropertyValue '0.0.0.0' -Force
    Write-Utf8NoBom -Path $tmp -Content ($obj | ConvertTo-Json -Depth 6)
    $cfgPath = $tmp
    Write-Warn2 'Binding 0.0.0.0. The server has no authentication - only do this on a trusted network.'
}

if (-not $NoWait) {
    # The pipeline's LLM endpoint is the router now. It starts in about a
    # second, so a short wait is enough; warn rather than block if it is absent.
    if (-not (Wait-ForPort -Port 8090 -TimeoutSec 30)) {
        Write-Warn2 'router (8090) not answering - replies will fail until it is up'
    }
}

Write-Step "Starting the Realtime server  ($(Split-Path $cfgPath -Leaf))"
[System.IO.Directory]::CreateDirectory($LogsDir) | Out-Null
if ($LogFile) {
    Invoke-Native -FilePath $S2SExe -Arguments @('serve', $cfgPath) -LogFile (Join-Path $LogsDir 'server.log')
} else {
    Invoke-Native -FilePath $S2SExe -Arguments @('serve', $cfgPath)
}
