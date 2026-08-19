<#
.SYNOPSIS
    One-shot installer for the Hugging Face speech-to-speech voice pipeline on Windows.

.DESCRIPTION
    Installs everything into THIS folder. Nothing is written to Program Files,
    nothing is added to PATH, no system Python is touched, no admin rights needed.

    What it sets up:
      1. uv                       -> tools\uv\uv.exe
      2. CPython 3.12 (managed)   -> tools\python\
      3. speech-to-speech source  -> repo\        (git clone, or source zip fallback)
      4. Isolated venv            -> repo\.venv\
      5. CUDA PyTorch (if a GPU is present) from the matching pytorch.org index
      6. llama.cpp server         -> tools\llama.cpp\
      7. Model weights            -> models\      (Gemma 4, Qwen3-TTS, Parakeet, VAD)

.PARAMETER Quant
    GGUF quantisation of Gemma 4 E4B to download. Q4_0 (~4.6 GB, default),
    Q8_0 (~8.0 GB, better quality), or BF16 (~15 GB).

.PARAMETER ForceCpu
    Skip GPU detection and install the CPU build even if an NVIDIA GPU is found.

.PARAMETER SkipModels
    Install software only. Models download on first run instead (slower first launch).

.PARAMETER SkipLlama
    Do not download llama.cpp. Use this if you already run an OpenAI-compatible
    LLM server elsewhere.

.PARAMETER CudaOnly
    Redo only the CUDA PyTorch step against an existing install. Use this when
    check.ps1 reports torch.cuda.is_available() = False. Takes a few minutes
    rather than an hour - nothing else is touched.

.PARAMETER LlamaOnly
    Re-download llama.cpp only, forcing the build that matches your GPU. Use this
    when the LLM is running on the CPU because the wrong flavour was installed.

.PARAMETER TorchIndex
    Force a specific PyTorch wheel index (cu126, cu128, cu130, cpu) instead of
    letting the installer choose from your driver.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Quant Q8_0
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -CudaOnly
#>
[CmdletBinding()]
param(
    [ValidateSet('Q4_0','Q8_0','BF16')]
    [string]$Quant = 'Q4_0',
    [switch]$ForceCpu,
    [switch]$SkipModels,
    [switch]$SkipLlama,
    [switch]$CudaOnly,
    [switch]$LlamaOnly,
    [ValidateSet('','cpu','cu126','cu128','cu130')]
    [string]$TorchIndex = ''
)

. "$PSScriptRoot\env.ps1"

$TorchPin      = '2.9.1'   # torch + torchaudio matched pair, available on cu126/cu128/cu130
$PythonVersion = '3.12'
$GemmaRepo     = 'ggml-org/gemma-4-E4B-it-GGUF'

Write-Host ''
Write-Host '  speech-to-speech - Windows setup' -ForegroundColor White
Write-Host '  ---------------------------------' -ForegroundColor DarkGray
Write-Host "  target folder : $Kit"
Write-Host ''

# ---------------------------------------------------------------- preflight
Write-Step 'Checking the machine'

if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Write-Bad 'This installer is for Windows.'; exit 1 }
if ([Environment]::Is64BitOperatingSystem -ne $true) { Write-Bad '64-bit Windows is required.'; exit 1 }
Write-Ok "Windows $([Environment]::OSVersion.Version)  |  PowerShell $($PSVersionTable.PSVersion)"

$drive     = (Get-Item $Kit).PSDrive.Name
$freeBytes = (Get-PSDrive $drive).Free
$freeGB    = [math]::Round($freeBytes / 1GB, 1)
$needGB    = if ($SkipModels) { 12 } elseif ($Quant -eq 'BF16') { 32 } elseif ($Quant -eq 'Q8_0') { 25 } else { 22 }
if ($freeGB -lt $needGB) {
    Write-Bad "Only $freeGB GB free on ${drive}: - about $needGB GB is needed."
    Write-Info 'Free some space, move this folder to a bigger drive, or re-run with -SkipModels.'
    exit 1
}
Write-Ok "$freeGB GB free on ${drive}: (need ~$needGB GB)"

# Long paths: HF cache filenames nest deeply. Warn rather than fail.
try {
    $lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled
    if ($lp -ne 1) { Write-Warn2 'Win32 long paths are disabled. See README.md if downloads fail with path-too-long.' }
} catch { }

$gpu = Get-GpuInfo
if ($ForceCpu)   { $gpu.TorchIndex = 'cpu'; $gpu.LlamaFlavor = 'cpu' }
if ($TorchIndex) { $gpu.TorchIndex = $TorchIndex; Write-Info "PyTorch index forced to '$TorchIndex'" }
if ($gpu.HasNvidia -and -not $ForceCpu) {
    Write-Ok "GPU: $($gpu.GpuName)  |  $([math]::Round($gpu.VramMB/1024,1)) GB VRAM"
    Write-Ok "driver $($gpu.DriverVersion)  |  CUDA $($gpu.DriverCuda)"
    if ($gpu.IsBlackwell) { Write-Info 'Blackwell (RTX 50-series, sm_120) - cu128 is the minimum usable wheel index.' }
    Write-Info "-> PyTorch index '$($gpu.TorchIndex)', llama.cpp build '$($gpu.LlamaFlavor)'"
    if ($gpu.TorchIndex -eq 'cpu') {
        Write-Warn2 "Driver CUDA $($gpu.DriverCuda) is older than 12.6 - falling back to CPU wheels. Update the NVIDIA driver for GPU speed."
    }
} elseif ($ForceCpu) {
    Write-Ok 'CPU mode forced (-ForceCpu).'
} else {
    Write-Warn2 'No NVIDIA GPU detected - installing CPU builds. Expect several seconds of latency per reply.'
}

foreach ($d in @($ToolsDir, $ModelsDir, $LogsDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# --- the CUDA PyTorch swap, shared by the full install and -CudaOnly ---------
# PyPI ships CPU-only torch wheels for Windows (~120 MB). The CUDA builds live on
# download.pytorch.org, so swap them in when the driver supports it.
function Install-TorchForGpu {
    param($GpuInfo)

    if ($GpuInfo.TorchIndex -eq 'cpu') {
        Write-Step 'Using CPU PyTorch'
        Write-Ok 'CPU wheels from PyPI'
        return $true
    }

    Write-Step "Installing CUDA PyTorch ($($GpuInfo.TorchIndex))"
    Write-Info 'About 3 GB. This is what makes the GPU actually get used.'
    $idx = "https://download.pytorch.org/whl/$($GpuInfo.TorchIndex)"
    & $UvExe pip install --python $VenvPython --index-url $idx --reinstall `
        "torch==$TorchPin" "torchaudio==$TorchPin"
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 'CUDA PyTorch install failed - the CPU build stays in place. Everything still works, just slower.'
        return $false
    }

    $cudaOk = & $VenvPython -c "import torch;print(torch.cuda.is_available())" 2>$null
    if ("$cudaOk".Trim() -eq 'True') {
        $devName = & $VenvPython -c "import torch;print(torch.cuda.get_device_name(0))" 2>$null
        Write-Ok "torch.cuda.is_available() = True  ->  $devName"
        return $true
    }

    Write-Warn2 'torch installed but CUDA is not visible.'
    Write-Info  'Try another index, e.g.  .\install.ps1 -CudaOnly -TorchIndex cu128'
    return $false
}

# --- llama.cpp, shared by the full install and -LlamaOnly --------------------
# The GPU build ships ggml-cuda.dll; the CPU build does not. Checking for that
# rather than for llama-server.exe means a wrong-flavour install is detected and
# replaced instead of silently kept - which is how a CPU llama.cpp survived on a
# machine with a 5080.
function Test-LlamaIsCuda {
    return (Test-Path (Join-Path $LlamaDir 'ggml-cuda.dll'))
}

function Install-LlamaCpp {
    param(
        [Parameter(Mandatory)][string]$Flavor,
        [switch]$Force
    )

    Write-Step "llama.cpp server ($Flavor build)"

    $haveExe  = Test-Path $LlamaExe
    $haveCuda = Test-LlamaIsCuda
    $wantCuda = $Flavor -ne 'cpu'

    if ($haveExe -and -not $Force) {
        if ($wantCuda -eq $haveCuda) {
            Write-Ok "already the right build ($(if($haveCuda){'CUDA'}else{'CPU'})) in tools\llama.cpp"
            return $true
        }
        Write-Warn2 "installed build is $(if($haveCuda){'CUDA'}else{'CPU'}) but $(if($wantCuda){'CUDA'}else{'CPU'}) is wanted - replacing it"
    }

    New-Item -ItemType Directory -Force -Path $LlamaDir | Out-Null
    $headers  = @{ 'User-Agent' = 'speech-to-speech-setup' }
    try {
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=12' `
                                      -Headers $headers -UseBasicParsing
    } catch {
        Write-Warn2 "Could not reach the llama.cpp release list: $_"
        return $false
    }

    # The newest release is sometimes still uploading, so walk back until one has
    # both the binaries and (for CUDA) the matching runtime DLLs.
    $picked = $null
    foreach ($rel in $releases) {
        $main = $rel.assets | Where-Object { $_.name -eq "llama-$($rel.tag_name)-bin-win-$Flavor-x64.zip" }
        if (-not $main) { continue }
        $rt = $null
        if ($wantCuda) {
            $rt = $rel.assets | Where-Object { $_.name -eq "cudart-llama-bin-win-$Flavor-x64.zip" }
            if (-not $rt) { continue }
        }
        $picked = [pscustomobject]@{ Tag = $rel.tag_name; Main = $main; Runtime = $rt }
        break
    }

    if (-not $picked) {
        Write-Warn2 "No llama.cpp '$Flavor' build in the last 12 releases. Use -SkipLlama, or point at your own LLM server."
        return $false
    }

    Write-Info "release $($picked.Tag)  |  $($picked.Main.name)"
    $z1 = Join-Path $TempDir $picked.Main.name
    Invoke-WebRequest -Uri $picked.Main.browser_download_url -OutFile $z1 -UseBasicParsing
    Expand-Archive -Path $z1 -DestinationPath $LlamaDir -Force
    Remove-Item $z1 -Force

    if ($picked.Runtime) {
        Write-Info "CUDA runtime: $($picked.Runtime.name)"
        $z2 = Join-Path $TempDir $picked.Runtime.name
        Invoke-WebRequest -Uri $picked.Runtime.browser_download_url -OutFile $z2 -UseBasicParsing
        Expand-Archive -Path $z2 -DestinationPath $LlamaDir -Force
        Remove-Item $z2 -Force
    }

    # Some archives nest a level deep; flatten so llama-server.exe sits at the root.
    if (-not (Test-Path $LlamaExe)) {
        $found = Get-ChildItem $LlamaDir -Recurse -Filter 'llama-server.exe' | Select-Object -First 1
        if ($found) { Get-ChildItem $found.DirectoryName | Move-Item -Destination $LlamaDir -Force -ErrorAction SilentlyContinue }
    }

    if (-not (Test-Path $LlamaExe)) {
        Write-Warn2 'llama-server.exe not found after extraction - check tools\llama.cpp'
        return $false
    }
    if ($wantCuda -and -not (Test-LlamaIsCuda)) {
        Write-Warn2 'Extracted, but ggml-cuda.dll is missing - the LLM will still run on the CPU.'
        return $false
    }
    Write-Ok "llama-server.exe ready ($($picked.Tag), $(if(Test-LlamaIsCuda){'CUDA'}else{'CPU'}))"
    return $true
}

# --- -LlamaOnly: swap the llama.cpp build without redoing everything ---------
if ($LlamaOnly) {
    $ok = Install-LlamaCpp -Flavor $gpu.LlamaFlavor -Force
    $state = Get-KitState
    if ($state) {
        $state.llamaFlavor = if ($ok) { $gpu.LlamaFlavor } else { 'cpu' }
        Write-Utf8NoBom -Path $StateFile -Content ($state | ConvertTo-Json -Depth 5)
        Write-Ok "system.json updated -> llamaFlavor $($state.llamaFlavor)"
    }
    Write-Host ''
    Write-Host '  Done. Run .\stop-all.ps1 then CLARA.cmd' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# --- -CudaOnly: repair an existing install without redoing everything --------
if ($CudaOnly) {
    if (-not (Test-Path $VenvPython)) {
        Write-Bad 'No virtual environment yet - run install.ps1 without -CudaOnly first.'
        exit 1
    }
    $ok = Install-TorchForGpu -GpuInfo $gpu
    if (-not $ok -and $gpu.TorchIndex -ne 'cpu') { $gpu.TorchIndex = 'cpu' }

    $state = Get-KitState
    if ($state) {
        $state.torchIndex = $gpu.TorchIndex
        $state.device     = if ($gpu.TorchIndex -eq 'cpu') { 'cpu' } else { 'cuda' }
        $state.config     = 'serve-gpu.json'
        Write-Utf8NoBom -Path $StateFile -Content ($state | ConvertTo-Json -Depth 5)
        Write-Ok "system.json updated -> device $($state.device), config $($state.config)"
    }
    Write-Host ''
    Write-Host '  Done. Verify with  .\check.ps1  then run  CLARA.cmd' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------------- uv
Write-Step 'Installing uv (into this folder only)'
if (Test-Path $UvExe) {
    Write-Ok "already present: $(& $UvExe --version)"
} else {
    $uvZip = Join-Path $TempDir 'uv-win.zip'
    $uvUrl = 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip'
    Write-Info "downloading $uvUrl"
    Invoke-WebRequest -Uri $uvUrl -OutFile $uvZip -UseBasicParsing
    New-Item -ItemType Directory -Force -Path $UvDir | Out-Null
    Expand-Archive -Path $uvZip -DestinationPath $UvDir -Force
    Remove-Item $uvZip -Force
    if (-not (Test-Path $UvExe)) { Write-Bad 'uv.exe not found after extraction.'; exit 1 }
    Write-Ok "installed: $(& $UvExe --version)"
}

# ------------------------------------------------------------------ python
Write-Step "Installing an isolated CPython $PythonVersion"
& $UvExe python install $PythonVersion
if ($LASTEXITCODE -ne 0) { Write-Bad 'uv python install failed.'; exit 1 }
Write-Ok "CPython $PythonVersion under tools\python (your system Python is untouched)"

# ------------------------------------------------------------------ source
$pin          = Get-UpstreamPin
$UpstreamRef  = $pin.ref
$UpstreamRepo = $pin.repo
Write-Step "Fetching the speech-to-speech source ($UpstreamRef)"
if (Test-Path (Join-Path $RepoDir 'pyproject.toml')) {
    Write-Ok 'source already present in repo\'
} else {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        & git clone --depth 1 --branch $UpstreamRef $UpstreamRepo $RepoDir
        if ($LASTEXITCODE -ne 0) { Write-Bad "git clone of $UpstreamRef failed."; exit 1 }
        Write-Ok "cloned at $UpstreamRef  (change it with .\utilities\update-upstream.ps1)"
    } else {
        Write-Info 'git not found - downloading the source archive instead'
        $srcZip = Join-Path $TempDir 's2s-src.zip'
        Invoke-WebRequest -Uri "https://codeload.github.com/huggingface/speech-to-speech/zip/refs/tags/$UpstreamRef" -OutFile $srcZip -UseBasicParsing
        $tmpDir = Join-Path $TempDir 's2s-src'
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
        Expand-Archive -Path $srcZip -DestinationPath $tmpDir -Force
        # GitHub names the folder after the tag without its leading v
        $extracted = Get-ChildItem $tmpDir -Directory | Select-Object -First 1
        Move-Item $extracted.FullName $RepoDir
        Remove-Item $srcZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok 'source archive extracted to repo\'
    }
}

# -------------------------------------------------------------------- venv
Write-Step 'Creating the isolated virtual environment and installing dependencies'
Write-Info 'This is the long step (~2 GB of wheels). Grab a coffee.'
Push-Location $RepoDir
try {
    # --allow-existing reuses a venv that is already there instead of stopping to
    # ask. Without it a re-run prompts, and declining makes uv exit non-zero,
    # which aborts the whole install for no good reason.
    & $UvExe venv --python $PythonVersion --allow-existing .venv
    if ($LASTEXITCODE -ne 0) { throw 'uv venv failed' }

    # -e . installs the checkout in editable mode. --prerelease allow mirrors the
    # repo's own [tool.uv] setting; some pinned deps publish pre-release wheels.
    & $UvExe pip install --python $VenvPython --prerelease allow -e .
    if ($LASTEXITCODE -ne 0) { throw 'dependency install failed' }

    # onnxruntime is required by Smart Turn (VAD end-of-turn model), which is ON by
    # default, but it is not declared in pyproject.toml. Without it the server
    # crashes at start-up with "Smart Turn requires the `onnxruntime` package".
    & $UvExe pip install --python $VenvPython onnxruntime
    if ($LASTEXITCODE -ne 0) { throw 'onnxruntime install failed' }
    Write-Ok 'speech-to-speech installed in repo\.venv (editable)'
} catch {
    Pop-Location; Write-Bad $_; exit 1
}
Pop-Location

# ------------------------------------------------------------- cuda pytorch
$torchOk = Install-TorchForGpu -GpuInfo $gpu
if (-not $torchOk -and $gpu.TorchIndex -ne 'cpu') { $gpu.TorchIndex = 'cpu' }

# --------------------------------------------------------------- llama.cpp
if (-not $SkipLlama) {
    Install-LlamaCpp -Flavor $gpu.LlamaFlavor | Out-Null
} else {
    Write-Info 'Skipping llama.cpp (-SkipLlama)'
}

# ------------------------------------------------------------------ models
if (-not $SkipModels) {
    Write-Step 'Downloading model weights into models\'
    Write-Info 'Gemma 4 E4B + Qwen3-TTS + Parakeet TDT + Silero VAD + Smart Turn'
    & $VenvPython "$ScriptDir\prefetch.py" --gemma-repo $GemmaRepo --quant $Quant
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 'Some model downloads failed. They will retry on first run - check the messages above.'
    } else {
        Write-Ok 'all models cached in models\'
    }
} else {
    Write-Info 'Skipping model download (-SkipModels). They download on first run.'
}

# ------------------------------------------------------------------- state
Write-Step 'Writing system.json'
$state = [ordered]@{
    installedAt = (Get-Date).ToString('s')
    kit         = $Kit
    gpu         = [ordered]@{
        hasNvidia  = $gpu.HasNvidia
        name       = $gpu.GpuName
        driverCuda = $gpu.DriverCuda
        vramMB     = $gpu.VramMB
    }
    torchIndex  = $gpu.TorchIndex
    llamaFlavor = $gpu.LlamaFlavor
    device      = if ($gpu.TorchIndex -eq 'cpu') { 'cpu' } else { 'cuda' }
    gemmaRepo   = $GemmaRepo
    quant       = $Quant
    config      = 'serve-gpu.json'
    llamaPort   = 8080
    voicePort   = 8765
}
Write-Utf8NoBom -Path $StateFile -Content ($state | ConvertTo-Json -Depth 5)
Write-Ok "saved -> $StateFile"

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
Write-Host '  Talk to it:' -ForegroundColor White
Write-Host "      powershell -ExecutionPolicy Bypass -File `"$ScriptDir\start-ui.ps1`"" -ForegroundColor Cyan
Write-Host ''
Write-Host '  Verify the install first:' -ForegroundColor White
Write-Host "      powershell -ExecutionPolicy Bypass -File `"$ScriptDir\check.ps1`"" -ForegroundColor Cyan
Write-Host ''
