<#
.SYNOPSIS
    Serve ui\ over HTTP. Started in the background by start-ui.ps1 -Detach.

.DESCRIPTION
    Nothing but a static file server. It exists as its own script because
    Start-BackgroundService launches a PowerShell file, and this needs to be the
    thing that keeps running after the launcher exits.
#>
[CmdletBinding()]
param([int]$Port = 8770)

. "$PSScriptRoot\env.ps1"

$uiDir = Join-Path $Kit 'ui'
if (-not (Test-Path -LiteralPath (Join-Path $uiDir 'index.html'))) { Write-Bad "ui\index.html missing"; exit 1 }

Invoke-Native -FilePath $VenvPython -Arguments @(
    '-m','http.server',"$Port",'--bind','127.0.0.1','--directory',$uiDir
)
