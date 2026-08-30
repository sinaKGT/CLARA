<#
.SYNOPSIS
    Health check. Run this when something misbehaves, before reading logs.

.DESCRIPTION
    Verifies every layer of the install: tools, virtual environment, PyTorch/CUDA,
    the pipeline import, cached model weights, audio devices and ports. Prints a
    pass/fail line per item and a summary of what to do about failures.
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\env.ps1"

$fail = 0
$warn = 0
function Chk  { param([bool]$ok, [string]$m) if ($ok) { Write-Ok $m } else { Write-Bad $m; $script:fail++ } }
function Soft { param([bool]$ok, [string]$m) if ($ok) { Write-Ok $m } else { Write-Warn2 $m; $script:warn++ } }

Write-Host ''
Write-Host '  speech-to-speech - health check' -ForegroundColor White
Write-Host "  $Kit" -ForegroundColor DarkGray

# ------------------------------------------------------------------- layout
Write-Step 'Files'
Chk  (Test-Path -LiteralPath $UvExe)                              "uv                 tools\uv\uv.exe"
Chk  (Test-Path -LiteralPath (Join-Path $RepoDir 'pyproject.toml')) "source             repo\"
Chk  (Test-Path -LiteralPath $VenvPython)                         "python             repo\.venv\Scripts\python.exe"
Chk  (Test-Path -LiteralPath $S2SExe)                             "cli                repo\.venv\Scripts\speech-to-speech.exe"
Soft (Test-Path -LiteralPath $LlamaExe)                           "llama-server       tools\llama.cpp\llama-server.exe"
Chk  (Test-Path -LiteralPath $StateFile)                          "state              system.json"

$state = Get-KitState
if ($state) {
    Write-Info "installed $($state.installedAt)  |  device $($state.device)  |  torch $($state.torchIndex)  |  quant $($state.quant)"
}

if (-not (Test-Path -LiteralPath $VenvPython)) {
    Write-Host ''
    Write-Bad 'The virtual environment is missing. Run install.ps1.'
    exit 1
}

# ---------------------------------------------------------------- gpu state
Write-Step 'Hardware'
$gpu = Get-GpuInfo
if ($gpu.HasNvidia) {
    Write-Ok "$($gpu.GpuName)  |  $([math]::Round($gpu.VramMB/1024,1)) GB VRAM"
    Write-Ok "driver $($gpu.DriverVersion)  |  CUDA $($gpu.DriverCuda)  ->  wheel index $($gpu.TorchIndex)$(if($gpu.IsBlackwell){'  (Blackwell: cu128 minimum)'})"
    if (-not $gpu.DriverCuda) {
        Write-Warn2 'Could not read the CUDA version from nvidia-smi. Run  nvidia-smi  yourself and check the top-right corner.'
        $warn++
    }
} else {
    Write-Warn2 'No NVIDIA GPU visible (CPU mode).'
}
$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Soft ($ram -ge 16) "system RAM $ram GB (16 GB+ recommended)"

# --------------------------------------------------------------- python env
Write-Step 'Python environment'
$relocated = Get-RelocatedVenvRoot
if ($relocated) {
    Write-Bad 'the environment was built for a different folder and cannot run'
    Write-Info "   built for : $relocated"
    Write-Info "   now at    : $Kit"
    Write-Info '   a venv stores absolute paths, so moving or renaming the folder breaks it'
    Write-Info '   fix: delete repo\.venv, then CLARA.cmd -> 5 -> 2'
    $fail++
} else {
    $pyver = (& $VenvPython -c "import sys;print('.'.join(map(str,sys.version_info[:3])))" 2>$null)
    Chk ($LASTEXITCODE -eq 0) "interpreter runs: Python $pyver"
}

$probe = @'
import json, importlib
out = {}
try:
    import torch
    out["torch"] = torch.__version__
    out["cuda_available"] = bool(torch.cuda.is_available())
    out["cuda_build"] = torch.version.cuda
    out["gpu"] = torch.cuda.get_device_name(0) if torch.cuda.is_available() else None
except Exception as e:
    out["torch_error"] = repr(e)
for mod in ("transformers", "onnxruntime", "sounddevice", "nano_parakeet",
            "faster_qwen3_tts", "openai", "speech_to_speech"):
    try:
        importlib.import_module(mod)
        out[mod] = True
    except Exception as e:
        out[mod] = repr(e)[:120]
print(json.dumps(out))
'@
$probeFile = Join-Path $TempDir 's2s-probe.py'
Write-Utf8NoBom -Path $probeFile -Content $probe
$raw = & $VenvPython $probeFile 2>$null | Select-Object -Last 1
Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue

if (-not $raw) {
    Write-Bad 'Could not import anything in the venv - the install is broken. Re-run install.ps1.'
    exit 1
}
$p = $raw | ConvertFrom-Json

Chk ($null -ne $p.torch) "torch $($p.torch)  (CUDA build: $($p.cuda_build))"
if ($gpu.HasNvidia) {
    Chk ($p.cuda_available -eq $true) "torch.cuda.is_available() = $($p.cuda_available)  $(if($p.gpu){"-> $($p.gpu)"})"
    if ($p.cuda_available -ne $true) {
        Write-Info "CPU-only torch is installed. Fix it without redoing the whole install:"
        Write-Host  '           .\install.ps1 -CudaOnly' -ForegroundColor White
    }
} else {
    Write-Info 'CPU torch is correct for this machine.'
}
foreach ($m in 'transformers','onnxruntime','sounddevice','nano_parakeet','faster_qwen3_tts','openai','speech_to_speech') {
    Chk ($p.$m -eq $true) "import $m$(if($p.$m -ne $true){" -> $($p.$m)"})"
}
if ($p.onnxruntime -ne $true) { Write-Info 'onnxruntime missing: Smart Turn will refuse to start. Fix: tools\uv\uv.exe pip install --python repo\.venv\Scripts\python.exe onnxruntime' }

# ------------------------------------------------------------------- models
Write-Step 'Model cache'
$hub = Join-Path $ModelsDir 'hub'
function HasModel { param([string]$pattern) (Test-Path -LiteralPath $hub) -and ((Get-ChildItem -LiteralPath $hub -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $pattern }).Count -gt 0) }
Soft (HasModel 'models--ggml-org--gemma-4*')  'Gemma 4 E4B GGUF   (LLM)'
Soft (HasModel 'models--Qwen--Qwen3-TTS*')    'Qwen3-TTS          (speech output)'
Soft (HasModel 'models--nvidia--parakeet*')   'Parakeet TDT       (speech recognition)'
Soft (HasModel 'models--pipecat-ai--smart*')  'Smart Turn v3.2    (turn detection)'
Soft (Test-Path -LiteralPath (Join-Path $ModelsDir 'torch\hub')) 'Silero VAD         (voice activity)'
if (Test-Path -LiteralPath $ModelsDir) {
    $sz = [math]::Round((Get-ChildItem -LiteralPath $ModelsDir -Recurse -File -ErrorAction SilentlyContinue |
          Measure-Object Length -Sum).Sum / 1GB, 2)
    Write-Info "models\ is $sz GB"
}

# -------------------------------------------------------------------- audio
Write-Step 'Audio'
# Run the probe from a file. Passing this inline via -c means nesting quotes
# inside a PowerShell string, which mangles the Python source before it is parsed.
$audioProbe = @'
import sounddevice as sd
devs = sd.query_devices()
idx = sd.default.device
def name(i):
    try:
        return devs[i]["name"]
    except Exception:
        return "none"
print("in=" + name(idx[0]))
print("out=" + name(idx[1]))
print("count=%d" % len(devs))
'@
$audioFile = Join-Path $TempDir 's2s-audio-probe.py'
Write-Utf8NoBom -Path $audioFile -Content $audioProbe

$dev = $null
try {
    $ErrorActionPreference = 'Continue'      # a failing probe is a warning, not a crash
    $dev = & $VenvPython $audioFile 2>&1
} catch {
    $dev = $null
} finally {
    $ErrorActionPreference = 'Stop'
    Remove-Item -LiteralPath $audioFile -Force -ErrorAction SilentlyContinue
}

$inLine  = $dev | Where-Object { $_ -is [string] -and $_ -like 'in=*' }  | Select-Object -First 1
$outLine = $dev | Where-Object { $_ -is [string] -and $_ -like 'out=*' } | Select-Object -First 1
if ($inLine -and $outLine) {
    Write-Ok "default input : $($inLine  -replace '^in=','')"
    Write-Ok "default output: $($outLine -replace '^out=','')"
    Write-Info 'Wrong device? Change the default in Windows sound settings.'
} else {
    Write-Warn2 'Could not query audio devices - check that a microphone is connected and Windows mic permission is granted.'
    Write-Info  "probe said: $($dev | Out-String -Width 200)".Trim()
    $warn++
}

# -------------------------------------------------------------------- ports
Write-Step 'Ports'
if ($state) {
    $lp = [int]$state.llamaPort; $vp = [int]$state.voicePort
    if (Test-PortFree -Port $lp) { Write-Info "port $lp free  - LLM not running" }      else { Write-Ok "port $lp in use - LLM is running" }
    if (Test-PortFree -Port $vp) { Write-Info "port $vp free  - pipeline not running" } else { Write-Ok "port $vp in use - pipeline is running" }
}

# --------------------------------------------------------------- path safety
# CLARA once failed to start only because its folder was named "2. CLARA".
# This proves the launch path survives spaces, brackets and non-ASCII names.
Write-Step 'Path handling'
$selftest = Join-Path $ScriptDir 'selftest.ps1'
if (Test-Path -LiteralPath $selftest) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $selftest | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'runs correctly from awkward folder names (.\utilities\selftest.ps1 for detail)'
    } else {
        Write-Bad 'this kit does NOT run reliably from its current path - .\utilities\selftest.ps1'
        $fail++
    }
} else {
    Write-Info 'selftest.ps1 not present - skipped'
}

# ------------------------------------------------------------------ summary
Write-Host ''
if ($fail -eq 0 -and $warn -eq 0) {
    Write-Host '  Everything checks out. Run CLARA.cmd.' -ForegroundColor Green
} elseif ($fail -eq 0) {
    Write-Host "  Usable, with $warn warning(s) above." -ForegroundColor Yellow
    Write-Host '  Warnings about missing models just mean a slower first run.' -ForegroundColor DarkGray
} else {
    Write-Host "  $fail problem(s) and $warn warning(s)." -ForegroundColor Red
    Write-Host '  See README.md, or re-run install.ps1 - it is safe to run again.' -ForegroundColor DarkGray
}
Write-Host ''
