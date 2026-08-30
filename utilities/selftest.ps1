<#
.SYNOPSIS
    Prove the kit survives being installed at an awkward path.

.DESCRIPTION
    CLARA once refused to start purely because its folder was named
    "2. CLARA". Start-Process -ArgumentList flattens its array into ONE raw
    command line without quoting, so powershell.exe received

        -File D:\2. CLARA\utilities\serve-ui.ps1

    and tried to run "D:\2." - which is not a .ps1 file. Every background
    service failed, and the error pointed at a log rather than the cause.

    This test recreates that class of failure on purpose, in temp folders, so
    a regression is caught here rather than by whoever clones the repo next.

    Covered:
      space         "clara selftest space"    - the original bug
      brackets      "clara selftest [1]"      - PowerShell wildcard characters,
                                                which is why paths use
                                                -LiteralPath throughout
      apostrophe    "clara's selftest"        - quoting
      non-ASCII     "clara selftest ümlaut"   - encoding

    Exits 0 if everything passes, 1 if anything fails.

.EXAMPLE
    .\utilities\selftest.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\env.ps1"

$cases = @(
    @{ Name = 'space';      Dir = 'clara selftest space'  },
    @{ Name = 'brackets';   Dir = 'clara selftest [1]'    },
    @{ Name = 'apostrophe'; Dir = "clara's selftest"      },
    @{ Name = 'non-ASCII';  Dir = 'clara selftest ümlaut' }
)

Write-Host ''
Write-Host '  path handling' -ForegroundColor White
Write-Host '  -------------' -ForegroundColor DarkGray
Write-Info 'launching a script from folders named like a bad install path'
Write-Host ''

$token  = 'CLARA_OK'
$failed = 0

foreach ($c in $cases) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) $c.Dir
    $ps1 = Join-Path $dir 'probe.ps1'
    $out = Join-Path $dir 'probe.out'
    $err = Join-Path $dir 'probe.err'
    $why = ''

    try {
        # -LiteralPath everywhere: without it, the "[1]" case is read as a
        # wildcard character class and none of these find the folder.
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        Write-Utf8NoBom -Path $ps1 -Content "Write-Output '$token'"

        # Exactly how Start-BackgroundService launches a service.
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $ps1))
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -PassThru `
                           -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'timed out' }

        if (-not (Test-Path -LiteralPath $out)) { throw 'no output file' }
        $got = (Get-Content -LiteralPath $out -Raw)
        if ($got -notmatch $token) {
            $e = if (Test-Path -LiteralPath $err) { (Get-Content -LiteralPath $err -Raw).Trim() } else { '' }
            throw $(if ($e) { $e -split "`n" | Select-Object -First 1 } else { 'no token in output' })
        }

        # The cmdlets the kit leans on most, against the same awkward path.
        if (-not (Get-ChildItem -LiteralPath $dir)) { throw 'Get-ChildItem found nothing' }
    } catch {
        $failed++
        $why = "$_"
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($why) {
        Write-Host ("   {0,-12} FAIL  {1}" -f $c.Name, $why) -ForegroundColor Red
    } else {
        Write-Host ("   {0,-12} ok" -f $c.Name) -ForegroundColor Green
    }
}

# The real install path, reported so a user can see what they actually have.
Write-Host ''
Write-Info "this kit lives at: $Kit"
if ($Kit -match '[\[\]]') {
    Write-Warn2 'that path contains [ or ] - report it if anything behaves oddly'
}

Write-Host ''
if ($failed) {
    Write-Bad "$failed of $($cases.Count) path cases failed - CLARA will not run reliably from a folder like that."
    exit 1
}
Write-Ok "all $($cases.Count) path cases passed - the kit runs from any folder name"
exit 0
