# ---------------------------------------------------------------------------
# Shared environment for the speech-to-speech kit.
# Every other script in utilities\ dot-sources this:  . "$PSScriptRoot\env.ps1"
#
# Everything lives INSIDE this kit folder. Nothing is installed system-wide:
#   tools\uv        - uv binary
#   tools\python    - uv-managed CPython (isolated from any system Python)
#   tools\llama.cpp - llama-server binaries
#   repo\.venv      - the isolated virtual environment
#   models          - Hugging Face / torch.hub / nltk caches
# Delete this folder and the machine is exactly as it was before.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is ~10x faster without it

# The scripts live in utilities\; the kit itself is the folder above them.
# $ScriptDir is where the .ps1 files are, $Kit is where tools/models/configs live.
$ScriptDir   = $PSScriptRoot
$Kit         = Split-Path -Parent $PSScriptRoot
$ToolsDir    = Join-Path $Kit 'tools'
$UvDir       = Join-Path $ToolsDir 'uv'
$UvExe       = Join-Path $UvDir 'uv.exe'
$RepoDir     = Join-Path $Kit 'repo'
$VenvDir     = Join-Path $RepoDir '.venv'
$VenvScripts = Join-Path $VenvDir 'Scripts'
$VenvPython  = Join-Path $VenvScripts 'python.exe'
$S2SExe      = Join-Path $VenvScripts 'speech-to-speech.exe'
$LlamaDir    = Join-Path $ToolsDir 'llama.cpp'
$LlamaExe    = Join-Path $LlamaDir 'llama-server.exe'
$ModelsDir   = Join-Path $Kit 'models'
$LogsDir     = Join-Path $Kit 'logs'
$ConfigDir   = Join-Path $Kit 'configs'
$StateFile   = Join-Path $Kit 'system.json'

# Scratch space for downloads and generated configs. %TEMP% is normally set, but
# it is empty under some service and scheduled-task contexts, so fall back rather
# than dying on a null Join-Path.
$TempDir = if ($env:TEMP) { $env:TEMP }
           elseif ($env:TMP) { $env:TMP }
           else { [System.IO.Path]::GetTempPath() }
if ([string]::IsNullOrWhiteSpace($TempDir)) { $TempDir = Join-Path $Kit 'tmp' }
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Force -Path $TempDir | Out-Null }

# --- keep every cache inside the kit ---------------------------------------
$env:UV_PYTHON_INSTALL_DIR = Join-Path $ToolsDir 'python'
$env:UV_CACHE_DIR          = Join-Path $ToolsDir 'uv-cache'
$env:HF_HOME               = $ModelsDir                    # HF hub cache -> models\hub
$env:TORCH_HOME            = Join-Path $ModelsDir 'torch'  # silero VAD via torch.hub
$env:NLTK_DATA             = Join-Path $ModelsDir 'nltk'
$env:PYTHONUTF8            = '1'
$env:PYTHONIOENCODING      = 'utf-8'

# Cut the Hugging Face start-up stall without going fully offline.
#
# huggingface_hub checks each model against the hub on every start. When
# huggingface.co is slow that costs a minute of retries for models already on
# disk. HF_HUB_OFFLINE=1 looks like the fix but breaks Qwen3-TTS: it calls
# model_info(), which is an API call rather than a file fetch, and offline mode
# raises OfflineModeIsEnabled instead of falling back to the cache.
#
# So: stay online, but fail fast. ETAG_TIMEOUT is the per-request budget for
# those HEAD checks (default 10 s); at 2 s the whole retry chain is over in
# seconds rather than a minute, and the cached model still loads either way.
$env:HF_HUB_ETAG_TIMEOUT      = '2'
$env:HF_HUB_DOWNLOAD_TIMEOUT  = '10'
$env:HF_HUB_DISABLE_TELEMETRY = '1'
$env:HF_HUB_OFFLINE           = '0'

# Write a text file as UTF-8 WITHOUT a byte-order mark.
#
# Windows PowerShell 5.1's `Set-Content -Encoding UTF8` emits a BOM, and Python's
# json.load rejects it outright:
#   json.decoder.JSONDecodeError: Unexpected UTF-8 BOM (decode using utf-8-sig)
# Any file handed to Python - configs, probe scripts - must go through here.
# The .NET call behaves identically on PowerShell 5.1 and 7.x.
function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Write-Step  { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "    [ok]   $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "    [warn] $m" -ForegroundColor Yellow }
function Write-Bad   { param([string]$m) Write-Host "    [fail] $m" -ForegroundColor Red }
function Write-Info  { param([string]$m) Write-Host "    $m" -ForegroundColor DarkGray }

# --- GPU / CUDA detection ---------------------------------------------------
# nvidia-smi prints the highest CUDA runtime the installed driver supports.
# That number maps to a PyTorch wheel index and a llama.cpp build flavour.
function Get-GpuInfo {
    $info = [ordered]@{
        HasNvidia     = $false
        GpuName       = $null
        DriverVersion = $null  # e.g. "581.42"
        DriverCuda    = $null  # e.g. "13.0"
        VramMB        = 0
        IsBlackwell   = $false
        TorchIndex    = 'cpu'  # cpu | cu126 | cu128 | cu130
        LlamaFlavor   = 'cpu'  # cpu | cuda-12.4 | cuda-13.3
    }

    $exe = $null
    $cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($cmd) {
        $exe = $cmd.Source
    } elseif ($env:SystemRoot) {
        # Driver installs drop nvidia-smi.exe here even when it is not on PATH.
        $fallback = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
        if (Test-Path $fallback) { $exe = $fallback }
    }
    if (-not $exe) { return $info }

    # Structured query first - far more reliable than scraping the banner.
    try {
        $q = & $exe --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null |
             Select-Object -First 1
        if ($q) {
            $info.HasNvidia = $true
            $parts = $q -split ','
            $info.GpuName       = $parts[0].Trim()
            $info.VramMB        = [int]($parts[1].Trim())
            $info.DriverVersion = $parts[2].Trim()
        }
    } catch { }

    # The banner carries the max CUDA runtime the driver supports. -Width 4096 is
    # essential: Out-String otherwise wraps to the console width and slices
    # "CUDA Version: 13.0" off the end of the header line, which silently
    # downgraded the whole install to CPU wheels.
    try {
        $banner = & $exe 2>$null | Out-String -Width 4096
        if (-not [string]::IsNullOrWhiteSpace($banner)) {
            $info.HasNvidia = $true
            if ($banner -match 'CUDA Version:\s*([0-9]+(?:\.[0-9]+)?)') {
                $v = $Matches[1]
                if ($v -notmatch '\.') { $v = "$v.0" }
                $info.DriverCuda = $v
            }
        }
    } catch { }

    if (-not $info.HasNvidia) { return $info }

    # Fall back to the driver number when the banner could not be read at all.
    # Windows driver branch -> highest CUDA runtime it ships.
    if (-not $info.DriverCuda -and $info.DriverVersion) {
        $major = [int](($info.DriverVersion -split '\.')[0])
        $info.DriverCuda = if     ($major -ge 580) { '13.0' }
                           elseif ($major -ge 570) { '12.8' }
                           elseif ($major -ge 560) { '12.6' }
                           else                    { '12.0' }
    }

    # RTX 50-series is Blackwell (compute capability sm_120). The cu126 wheels
    # contain no sm_120 kernels, so those cards need cu128 as an absolute floor
    # or every CUDA op dies with "no kernel image is available for execution".
    if ($info.GpuName -match 'RTX\s*(50\d\d|PRO\s*\d+\s*Blackwell)' -or $info.GpuName -match 'Blackwell') {
        $info.IsBlackwell = $true
    }

    if ($info.DriverCuda) {
        $cuda = [version]$info.DriverCuda
        if     ($cuda -ge [version]'13.0') { $info.TorchIndex = 'cu130'; $info.LlamaFlavor = 'cuda-13.3' }
        elseif ($cuda -ge [version]'12.8') { $info.TorchIndex = 'cu128'; $info.LlamaFlavor = 'cuda-12.4' }
        elseif ($cuda -ge [version]'12.6') { $info.TorchIndex = 'cu126'; $info.LlamaFlavor = 'cuda-12.4' }
        else                               { $info.TorchIndex = 'cpu';   $info.LlamaFlavor = 'cpu' }
    }

    if ($info.IsBlackwell -and $info.TorchIndex -in @('cpu', 'cu126')) {
        $info.TorchIndex  = 'cu128'
        $info.LlamaFlavor = 'cuda-12.4'
    }

    return $info
}

function Get-KitState {
    # Tolerates a missing, empty or half-written system.json (interrupted install)
    # rather than throwing an opaque JSON error at the caller.
    if (-not (Test-Path $StateFile)) { return $null }
    try {
        $raw = Get-Content $StateFile -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Warn2 'system.json is unreadable - re-run install.ps1 to regenerate it.'
        return $null
    }
}

function Assert-Installed {
    if (-not (Test-Path $S2SExe)) {
        Write-Bad 'Not installed yet. Run this first:'
        Write-Host "        powershell -ExecutionPolicy Bypass -File `"$ScriptDir\install.ps1`"" -ForegroundColor White
        exit 1
    }
}

# Wait until a TCP port answers, so the voice pipeline does not start talking
# to an LLM server that is still loading its weights.
function Wait-ForPort {
    param([string]$TargetHost = '127.0.0.1', [int]$Port = 8080, [int]$TimeoutSec = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $c.Connect($TargetHost, $Port)
            $c.Close()
            return $true
        } catch {
            Start-Sleep -Milliseconds 1000
        }
    }
    return $false
}

# Run a long-lived native program (llama-server, the voice pipeline) attached to
# this console.
#
# llama.cpp and Python's logging both write progress to STDERR, not stdout. With
# $ErrorActionPreference = 'Stop', PowerShell wraps the first stderr line in a
# NativeCommandError and treats it as terminating - so the process is killed by
# its own start-up banner. Relaxing the preference for the duration of the call
# is the fix; piping the output would also break the live console rendering the
# voice pipeline relies on, so the program is left owning the terminal.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$LogFile                       # optional: also capture a copy
    )

    $prevPref   = $ErrorActionPreference
    $prevNative = $null
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
        # PowerShell 7.4+ escalates non-zero native exit codes as well.
        $prevNative = $global:PSNativeCommandUseErrorActionPreference
        $global:PSNativeCommandUseErrorActionPreference = $false
    }
    $ErrorActionPreference = 'Continue'

    try {
        if ($LogFile) {
            # "$_" flattens the ErrorRecords that 2>&1 produces back into plain text,
            # so the log file and the console stay readable instead of all-red.
            & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $LogFile
        } else {
            & $FilePath @Arguments
        }
    } finally {
        $ErrorActionPreference = $prevPref
        if ($null -ne $prevNative) { $global:PSNativeCommandUseErrorActionPreference = $prevNative }
    }
}


# A filled/empty bar for the console, e.g. [########..........]
function Get-ProgressBar {
    param([int]$Done, [int]$Total, [int]$Width = 18)
    if ($Total -le 0) { $Total = 1 }
    $fill = [math]::Round($Width * ([math]::Min($Done, $Total) / $Total))
    return ('[' + ('#' * $fill) + ('.' * ($Width - $fill)) + ']')
}

# Launch one of the start-*.ps1 scripts as a hidden background process and wait
# for its port to answer. Keeps everything in a single console: one line per
# service instead of four popup windows fighting for the taskbar. Output goes to
# logs\<name>.log so a failure is still diagnosable.
function Start-BackgroundService {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][int]$Port,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 600,
        [int]$Index = 0,
        [int]$Total = 0,
        [string]$Shell = 'powershell.exe'
    )

    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
    # llama.cpp and Python logging both write to stderr, so stderr is the log that
    # matters. Give it the obvious name and park stdout in the secondary file,
    # otherwise the interesting output hides in something called ".err.log".
    $err = Join-Path $LogsDir "$Name.log"
    $out = Join-Path $LogsDir "$Name.stdout.log"

    # The bar reflects services finished BEFORE this one, so it fills down the list.
    $bar = if ($Total -gt 0) { Get-ProgressBar -Done ($Index - 1) -Total $Total } else { '' }
    Write-Host ("  {0} {1,2}/{2}  {3,-15}" -f $bar, $Index, $Total, $Name) -NoNewline -ForegroundColor Gray

    if (-not (Test-PortFree -Port $Port)) {
        Write-Host 'already running' -ForegroundColor DarkGreen
        return $true
    }

    # -WindowStyle is a Windows-only switch on the PowerShell host itself; passing it
    # elsewhere makes the child exit immediately with 'not implemented on this platform'.
    $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass')
    if ($IsWindows -ne $false) { $psArgs += @('-WindowStyle','Hidden') }
    $psArgs += @('-File', $Script) + $Arguments
    $sp = @{
        FilePath               = $Shell
        ArgumentList           = $psArgs
        PassThru               = $true
        RedirectStandardOutput = $out
        RedirectStandardError  = $err
    }
    # -WindowStyle only exists on Windows. $IsWindows is $null on PowerShell 5.1
    # (which is Windows by definition) and $false on PowerShell 7 for Linux.
    if ($IsWindows -ne $false) { $sp.WindowStyle = 'Hidden' }
    try {
        Start-Process @sp | Out-Null
    } catch {
        Write-Host 'failed to launch' -ForegroundColor Red
        Write-Info $_
        return $false
    }

    $t0 = Get-Date
    $deadline = $t0.AddSeconds($TimeoutSec)
    $spin = '|/-\'; $i = 0
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-PortFree -Port $Port)) {
            Write-Host ("`b ok  {0,4}s" -f [math]::Round(((Get-Date) - $t0).TotalSeconds)) -ForegroundColor Green
            return $true
        }
        Write-Host ("`b" + $spin[$i++ % 4]) -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 400
    }
    Write-Host "`b FAILED    " -ForegroundColor Red
    Write-Info "port $Port never opened - see $err"
    return $false
}

# What host port is a container ACTUALLY published on?
#
# system.json, .env and the compose defaults can all disagree - they did: the
# installer recorded 5678 while compose had moved to 5679, so the readiness
# check polled a port nothing was listening on and waited forever on a service
# that was up. Docker is the only authority here, so ask it.
function Get-ContainerPort {
    param([string]$Container, [int]$InternalPort, [int]$Fallback)
    try {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $out = & docker port $Container $InternalPort 2>$null | Select-Object -First 1
        $ErrorActionPreference = $prev
        if ($out -and $out -match ':(\d+)\s*$') { return [int]$Matches[1] }
    } catch { }
    return $Fallback
}

# Is something ANSWERING on this port?
#
# Not the same question as Test-PortFree, which asks whether the port can be
# bound. Docker publishes with 0.0.0.0, and Windows will often still allow a
# separate bind to 127.0.0.1 - so a container's port looks "free" while the
# service behind it is perfectly reachable. For anything in Docker this is the
# only reliable check.
function Test-PortAnswers {
    param([int]$Port, [string]$TargetHost = '127.0.0.1', [int]$TimeoutMs = 700)
    try {
        $c = [System.Net.Sockets.TcpClient]::new()
        $iar = $c.BeginConnect($TargetHost, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $c.Connected) { $c.EndConnect($iar); $c.Close(); return $true }
        $c.Close(); return $false
    } catch { return $false }
}

# Wait for a port, but SHOW that you are waiting.
#
# Wait-ForPort polls silently, which after "docker compose up -d" returns looks
# exactly like a hang: the containers report Started, then the screen sits there
# for up to three minutes while n8n actually boots. Same logic, with a spinner
# and an elapsed time so it is obviously alive.
function Wait-ForPortShown {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Label,
        [int]$TimeoutSec = 180,
        [string]$SlowHint = ''      # shown once if it takes longer than usual
    )
    Write-Host ("   {0,-12} " -f $Label) -NoNewline -ForegroundColor Gray
    $spin = '|/-\'; $i = 0
    $t0 = Get-Date
    $deadline = $t0.AddSeconds($TimeoutSec)
    $hinted = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-PortAnswers -Port $Port) {
            Write-Host ("`b ready {0,4}s" -f [math]::Round(((Get-Date) - $t0).TotalSeconds)) -ForegroundColor Green
            return $true
        }
        # After 45 s, say what is taking the time and how to watch it, rather
        # than leaving a spinner that gives no way to tell slow from stuck.
        if (-not $hinted -and $SlowHint -and ((Get-Date) - $t0).TotalSeconds -gt 45) {
            $hinted = $true
            Write-Host "`b " -NoNewline
            Write-Host ''
            Write-Info $SlowHint
            Write-Host ("   {0,-12} " -f $Label) -NoNewline -ForegroundColor Gray
        }
        Write-Host ("`b" + $spin[$i++ % 4]) -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 400
    }
    Write-Host "`b timed out " -ForegroundColor Yellow
    return $false
}

function Test-PortFree {
    param([int]$Port)
    try {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}

# Which process is holding a port. Get-NetTCPConnection is missing on some
# Windows SKUs, so fall back to parsing netstat.
function Get-PortOwner {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($conn) { return Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue }
    } catch {
        try {
            $line = netstat -ano -p TCP 2>$null | Select-String ":$Port\s.*LISTENING" | Select-Object -First 1
            if ($line) {
                $ownerPid = ($line.ToString().Trim() -split '\s+')[-1]
                return Get-Process -Id ([int]$ownerPid) -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    return $null
}

# Refuse to start on an occupied port, or reclaim it when -Force was passed.
# A leftover process from an earlier run is by far the most common cause: the
# server binds, fails, and tears the whole pipeline down again.
function Assert-PortAvailable {
    param(
        [int]$Port,
        [string]$Label = 'server',
        [switch]$Force,
        [string]$ScriptHint = '.\CLARA.cmd'
    )

    if (Test-PortFree -Port $Port) { return $true }

    $owner = Get-PortOwner -Port $Port
    $who   = if ($owner) { "$($owner.ProcessName) (PID $($owner.Id))" } else { 'an unknown process' }

    if ($Force) {
        if (-not $owner) {
            # Happens when the port belongs to another user, an elevated process,
            # or a stale TIME_WAIT entry. Say so instead of repeating the generic advice.
            Write-Bad "Port $Port is in use but the owning process could not be identified, so -Force cannot release it."
            Write-Info "Investigate with:  Get-NetTCPConnection -LocalPort $Port -State Listen"
            Write-Info 'If it belongs to another user, an elevated PowerShell can stop it.'
            return $false
        }
        Write-Warn2 "Port $Port held by $who - stopping it (-Force)."
        try {
            Stop-Process -Id $owner.Id -Force -ErrorAction Stop
        } catch {
            Write-Bad "Could not stop PID $($owner.Id): $_"
            Write-Info 'If it belongs to another user, try an elevated PowerShell.'
            return $false
        }
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Milliseconds 400
            if (Test-PortFree -Port $Port) { Write-Ok "port $Port released"; return $true }
        }
        Write-Bad "Port $Port is still busy after stopping $who."
        return $false
    }

    Write-Bad "Port $Port ($Label) is already in use by $who."
    Write-Info 'A previous run is probably still alive in another window. Close it, or reclaim the port:'
    Write-Host  "        $ScriptHint -Force" -ForegroundColor White
    Write-Info  'Or stop everything at once:   .\stop-all.ps1'
    return $false
}
