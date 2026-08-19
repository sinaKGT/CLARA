<#
.SYNOPSIS
    The menu. Start, stop, check, repair - everything in one place.
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\env.ps1"

function Run($script, $arguments = @()) {
    $path = Join-Path $ScriptDir $script
    if (-not (Test-Path $path)) { Write-Bad "missing utilities\$script"; return }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @arguments
}
function Pause2 { Write-Host ''; Write-Host '  enter to go back ' -ForegroundColor DarkGray -NoNewline; [void](Read-Host) }

function N8nPort { Get-ContainerPort -Container 'clara-n8n' -InternalPort 5678 -Fallback 5679 }

function Row($label, $port, $url) {
    $up = Test-PortAnswers -Port $port
    Write-Host ('   {0} ' -f $(if ($up) {'*'} else {'.'})) -NoNewline -ForegroundColor $(if ($up) {'Green'} else {'DarkGray'})
    Write-Host ('{0,-11}' -f $label) -NoNewline -ForegroundColor Gray
    Write-Host $url -ForegroundColor $(if ($up) {'Cyan'} else {'DarkGray'})
    return $up
}

while ($true) {
    Clear-Host
    $n8n = N8nPort
    Write-Host ''
    Write-Host '   clara' -ForegroundColor White
    Write-Host '   -----' -ForegroundColor DarkGray
    Write-Host ''
    $vUp = Row 'voice'    8770  'http://127.0.0.1:8770'
    $null = Row 'pipeline' 8765  ''
    $null = Row 'router'   8090  ''
    $nUp = Row 'n8n'      $n8n  "http://127.0.0.1:$n8n"
    $null = Row 'ollama'   11434 '(desktop app)'
    $null = Row 'postgres' (Get-ContainerPort -Container 'clara-postgres' -InternalPort 5432  -Fallback 5433)  ''
    Write-Host ''
    Write-Host '   1 start    2 stop    3 check    4 open n8n    5 repair    6 logs    q quit' -ForegroundColor Gray
    Write-Host ''
    switch (Read-Host '  ') {
        '1' { Run 'start-ui.ps1' @('-Force','-Detach'); Pause2 }
        '2' {
            Write-Host ''
            Write-Host '   1 everything    2 voice only    3 containers only' -ForegroundColor Gray
            switch (Read-Host '  ') {
                '1' { Run 'stop-all.ps1' }
                '2' { Run 'stop-all.ps1' @('-NoDocker') }
                '3' { Run 'stop-all.ps1' @('-Ports','0') }
            }
            Pause2
        }
        '3' { Run 'check.ps1'; Pause2 }
        '4' {
            if (-not (Test-PortAnswers -Port $n8n)) { Write-Warn2 'n8n is not running - use 1 first'; Pause2 }
            else { Start-Process "http://127.0.0.1:$n8n" }
        }
        '5' {
            Write-Host ''
            Write-Host '   1 everything    2 voice system    3 agent stack    4 gpu pytorch' -ForegroundColor Gray
            switch (Read-Host '  ') {
                '1' { Run 'install-all.ps1' }
                '2' { Run 'install-all.ps1' @('-Voice') }
                '3' { Run 'install-all.ps1' @('-Agents') }
                '4' { Run 'install.ps1' @('-CudaOnly') }
            }
            Pause2
        }
        '6' {
            Write-Host ''
            if (Test-Path $LogsDir) {
                Get-ChildItem $LogsDir -Filter *.log | Sort-Object LastWriteTime -Descending | Select-Object -First 8 |
                    ForEach-Object { Write-Host ('   {0,-24} {1,7:N0} KB  {2}' -f $_.Name, ($_.Length/1KB), $_.LastWriteTime.ToString('HH:mm')) -ForegroundColor Gray }
                Start-Process explorer $LogsDir
            } else { Write-Info 'no logs yet' }
            Pause2
        }
        'q' { break }
        'Q' { break }
    }
}
