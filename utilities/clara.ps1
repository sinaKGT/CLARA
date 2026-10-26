<#
.SYNOPSIS
    The menu. Start, stop, check, set up, update - everything in one place.
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\env.ps1"

function Run($script, $arguments = @()) {
    $path = Join-Path $ScriptDir $script
    if (-not (Test-Path -LiteralPath $path)) { Write-Bad "missing utilities\$script"; return }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @arguments
}
function Stop-Clara {
    # Quitting the menu leaves the services running otherwise - they are
    # background processes, not children of this window. stop-all.ps1 frees
    # 8770/8765/8090/8080 and stops clara-n8n + clara-postgres by name.
    Write-Host ''
    Write-Host '  stopping services and freeing ports' -ForegroundColor White
    Run 'stop-all.ps1'
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

# Labelled: in PowerShell a bare `break` inside a switch exits the SWITCH,
# not the loop around it - so 'q' redrew the menu forever instead of quitting.
:mainmenu while ($true) {
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
    Write-Host '   1 start   2 stop   3 check   4 open n8n   5 setup   6 logs   7 version   8 update n8n   q quit + stop' -ForegroundColor Gray
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
            if (Test-Path -LiteralPath $LogsDir) {
                Get-ChildItem -LiteralPath $LogsDir -Filter *.log | Sort-Object LastWriteTime -Descending | Select-Object -First 8 |
                    ForEach-Object { Write-Host ('   {0,-24} {1,7:N0} KB  {2}' -f $_.Name, ($_.Length/1KB), $_.LastWriteTime.ToString('HH:mm')) -ForegroundColor Gray }
                # Quoted: the positional arg is -ArgumentList, one raw command
                # line, so a kit path like "D:\2. CLARA" would split at the space.
                Start-Process explorer -ArgumentList ('"{0}"' -f $LogsDir)
            } else { Write-Info 'no logs yet' }
            Pause2
        }
        '7' {
            Write-Host ''
            Write-Host '   1 show version    2 update to a release    3 undo last update' -ForegroundColor Gray
            switch (Read-Host '  ') {
                '1' { Run 'update-upstream.ps1' @('-List') }
                '2' { Run 'update-upstream.ps1' }
                '3' { Run 'update-upstream.ps1' @('-Rollback') }
            }
            Pause2
        }
        '8' { Run 'update-n8n.ps1'; Pause2 }
        'q' { Stop-Clara; break mainmenu }
        'Q' { Stop-Clara; break mainmenu }
    }
}
