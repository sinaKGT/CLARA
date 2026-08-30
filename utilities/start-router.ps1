<#
.SYNOPSIS
    Run the agent router on port 8090.

.DESCRIPTION
    Sits between the speech pipeline and n8n. Each agent's webhook travels in a
    [route:...] marker in its system prompt; the router strips it and forwards
    the turn. Runs on the pipeline's own venv - no extra installs.
#>
[CmdletBinding()]
param([int]$Port = 8090)

. "$PSScriptRoot\env.ps1"

if (-not (Test-Path -LiteralPath $VenvPython)) { Write-Bad 'venv missing - run the installer'; exit 1 }
if (Test-PortAnswers -Port $Port) { Write-Ok "router already on $Port"; exit 0 }

$env:ROUTER_PORT = "$Port"
Write-Step "Agent router on http://127.0.0.1:$Port"
Invoke-Native -FilePath $VenvPython -Arguments @("$ScriptDir\router.py")
