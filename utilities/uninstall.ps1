<#
.SYNOPSIS
    Remove everything this kit installed.

.DESCRIPTION
    Because the install is entirely self-contained, uninstalling is just deleting
    folders inside the kit. Nothing was written to Program Files, the registry or
    PATH, so there is nothing else to undo.

.PARAMETER KeepModels  Delete the software but keep models\ (the ~12 GB of weights).
#>
[CmdletBinding()]
param([switch]$KeepModels)

. "$PSScriptRoot\env.ps1"

$targets = @($ToolsDir, $RepoDir, $LogsDir, $StateFile)
if (-not $KeepModels) { $targets += $ModelsDir }

Write-Step 'About to delete'
foreach ($t in $targets) { if (Test-Path $t) { Write-Info $t } }
if ($KeepModels) { Write-Info "(keeping $ModelsDir)" }

$answer = Read-Host "`nType 'yes' to continue"
if ($answer -ne 'yes') { Write-Info 'Cancelled.'; exit 0 }

foreach ($t in $targets) {
    if (Test-Path $t) {
        Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $t) { Write-Warn2 "could not fully remove $t (a process may still have it open)" }
        else { Write-Ok "removed $t" }
    }
}
Write-Host ''
Write-Host '  Done. The scripts and configs are still here - re-run install.ps1 to rebuild.' -ForegroundColor Green
Write-Host ''
