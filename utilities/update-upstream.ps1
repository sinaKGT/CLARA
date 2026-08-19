<#
.SYNOPSIS
    Move the speech-to-speech pipeline to a different upstream release.

.DESCRIPTION
    Upstream takes roughly 55 commits a week on main and is not stability
    tested on Windows. CLARA therefore pins a TAG, recorded in
    configs\upstream.json, and this script is the only thing that changes it.

    What it does, in order:

      1. reads the pin and the current checkout
      2. fetches upstream tags
      3. shows you what is available and what changed
      4. records the current commit so it can go back
      5. checks out the tag you chose
      6. reinstalls dependencies - the venv holds an editable install, so new
         code lands instantly but pyproject.toml changes do not
      7. runs check.ps1
      8. offers to roll back if any of that fails

    Nothing here touches your models, workflows or agents.

.PARAMETER Ref
    Tag to move to, e.g. v0.2.13. Omit to be shown a list.

.PARAMETER List
    Show available releases and exit. Changes nothing.

.PARAMETER Rollback
    Return to the commit recorded by the last run of this script.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    .\utilities\update-upstream.ps1 -List
.EXAMPLE
    .\utilities\update-upstream.ps1 -Ref v0.2.13
.EXAMPLE
    .\utilities\update-upstream.ps1 -Rollback
#>
[CmdletBinding()]
param(
    [string]$Ref,
    [switch]$List,
    [switch]$Rollback,
    [switch]$Force
)

. "$PSScriptRoot\env.ps1"
Assert-Installed

$pin        = Get-UpstreamPin
$backupFile = Join-Path $ConfigDir '.upstream-previous.json'

$GitExe = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $GitExe) {
    Write-Bad 'git is required to change the upstream version.'
    Write-Info 'Install it from https://git-scm.com/downloads, or re-run the installer to fetch a fresh source archive.'
    exit 1
}
if (-not (Test-Path (Join-Path $RepoDir '.git'))) {
    Write-Bad 'repo\ is not a git checkout - it came from the zip fallback.'
    Write-Info 'Delete repo\ and re-run install.ps1 to get a git clone, then this script will work.'
    exit 1
}

# Named RepoGit, not Git: PowerShell is case-insensitive, so a function
# called Git would shadow git.exe and recurse into itself forever.
#
# git writes progress and "fatal:" lines to stderr, and with
# $ErrorActionPreference = 'Stop' PowerShell turns the first stderr line into a
# terminating NativeCommandError - so a harmless "No names found" from
# git describe kills the script. Same treatment as Invoke-Native in env.ps1:
# relax the preference for the duration of the call and drop stderr, so only
# real output comes back and failures are judged on $LASTEXITCODE.
function RepoGit {
    param([Parameter(ValueFromRemainingArguments)]$a)
    $prevPref   = $ErrorActionPreference
    $prevNative = $null
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
        $prevNative = $global:PSNativeCommandUseErrorActionPreference
        $global:PSNativeCommandUseErrorActionPreference = $false
    }
    $ErrorActionPreference = 'Continue'
    try { & $GitExe -C $RepoDir @a 2>$null }
    finally {
        $ErrorActionPreference = $prevPref
        if ($null -ne $prevNative) { $global:PSNativeCommandUseErrorActionPreference = $prevNative }
    }
}

function Install-Deps {
    Write-Step 'Reinstalling dependencies'
    Write-Info 'The venv holds an editable install, so code is already live - this picks up pyproject.toml changes.'
    Push-Location $RepoDir
    try {
        & $UvExe pip install --python $VenvPython --prerelease allow -e .
        if ($LASTEXITCODE -ne 0) { throw 'dependency install failed' }
        & $UvExe pip install --python $VenvPython onnxruntime
        if ($LASTEXITCODE -ne 0) { throw 'onnxruntime install failed' }
        Write-Ok 'dependencies up to date'
    } catch {
        Pop-Location
        Write-Bad $_
        Write-Info 'Roll back with:  .\utilities\update-upstream.ps1 -Rollback'
        exit 1
    }
    Pop-Location
}

# ---------------------------------------------------------------- current
$currentCommit = (RepoGit rev-parse HEAD)

# ---------------------------------------------------------------- rollback
if ($Rollback) {
    if (-not (Test-Path $backupFile)) { Write-Bad 'nothing to roll back to - this script has not changed anything yet.'; exit 1 }
    $prev = Get-Content $backupFile -Raw | ConvertFrom-Json
    Write-Step "Rolling back to $($prev.desc)"
    RepoGit fetch origin $prev.commit | Out-Null
    RepoGit checkout --force $prev.commit | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Bad 'checkout failed.'; exit 1 }
    Install-Deps
    Write-Ok "back at $($prev.desc)"
    exit 0
}

# ---------------------------------------------------------------- releases
Write-Step 'Fetching upstream releases'

# install.ps1 clones --depth 1, which arrives with no tags and no ancestry.
# Both "git describe" and the A..B commit preview need real history, so the
# first run here deepens the checkout. Upstream is ~5 MB and about a second,
# which is far cheaper than showing the wrong version.
if (Test-Path (Join-Path $RepoDir '.git\shallow')) {
    Write-Info 'deepening the checkout (one-off, ~5 MB) so version comparison works'
    RepoGit fetch --unshallow --tags --force origin | Out-Null
} else {
    RepoGit fetch --tags --force origin | Out-Null
}
$tags = @(RepoGit tag --sort=version:refname) | Where-Object { $_ -match '^v\d' }
if (-not $tags) { Write-Bad 'no release tags found upstream - check your connection.'; exit 1 }
$latest = $tags[-1]

# git describe needs tags to exist locally, and install.ps1 clones --depth 1
# with none of them - so this has to come after the fetch above, not before.
$currentDesc = (RepoGit describe --tags)
if (-not $currentDesc) {
    $currentDesc = if ($currentCommit) { $currentCommit.Substring(0, [Math]::Min(12, $currentCommit.Length)) } else { 'unknown' }
}
# "v0.2.12-23-gdef4ad4" -> "v0.2.12". Compared exactly, because a -like
# "v0.2.1*" test would also match v0.2.12.
$currentTag = ($currentDesc -split '-')[0]

Write-Host ''
Write-Host '  speech-to-speech version' -ForegroundColor White
Write-Host '  ------------------------' -ForegroundColor DarkGray
Write-Info "pinned in configs\upstream.json : $($pin.ref)"
Write-Info "actually checked out            : $currentDesc"

Write-Host ''
Write-Host '   available releases' -ForegroundColor White
foreach ($t in ($tags | Select-Object -Last 8)) {
    $date = (RepoGit log -1 --format=%ad --date=short $t)
    $mark = ''
    if ($t -eq $currentTag)       { $mark = '  <- you are here' }
    elseif ($t -eq $latest)       { $mark = '  <- newest' }
    Write-Host ("   {0,-10} {1}{2}" -f $t, $date, $mark) -ForegroundColor $(if ($mark) { 'Cyan' } else { 'Gray' })
}
Write-Host ''

if ($List) {
    Write-Info "update with:  .\utilities\update-upstream.ps1 -Ref $latest"
    exit 0
}

if (-not $Ref) {
    Write-Host "   which release? (blank = $latest, q = cancel) " -ForegroundColor Gray -NoNewline
    $Ref = Read-Host
    if ($Ref -eq 'q') { Write-Info 'cancelled'; exit 0 }
    if (-not $Ref)    { $Ref = $latest }
}
if ($tags -notcontains $Ref) { Write-Bad "$Ref is not a release tag. Use -List to see the options."; exit 1 }

# ---------------------------------------------------------------- preview
$ahead  = @(RepoGit log --oneline "$currentCommit..$Ref")   # gained by moving
$behind = @(RepoGit log --oneline "$Ref..$currentCommit")   # lost by moving
if ($ahead.Count -eq 0 -and $behind.Count -eq 0) {
    Write-Ok "already exactly at $Ref - nothing to do."
    exit 0
}
if ($ahead.Count -eq 0) {
    Write-Warn2 "$Ref is OLDER than what you have - moving there gives up $($behind.Count) commits."
    Write-Info "you are at $currentDesc"
}
Write-Step "$($ahead.Count) commits between here and $Ref"
$ahead | Select-Object -First 12 | ForEach-Object { Write-Info $_ }
if ($ahead.Count -gt 12) { Write-Info "... and $($ahead.Count - 12) more" }

$risky = @($ahead | Where-Object { $_ -match '(?i)break|remove|rename|deprecat|migrat|\brequire' })
if ($risky) {
    Write-Host ''
    Write-Warn2 "$($risky.Count) of those look like they change a contract:"
    $risky | Select-Object -First 5 | ForEach-Object { Write-Info $_ }
    Write-Info 'CLARA carries Windows-specific workarounds; these are the commits most likely to break them.'
}

if (-not $Force) {
    Write-Host ''
    Write-Host "   update to $Ref ? [y/N] " -ForegroundColor Gray -NoNewline
    if ((Read-Host) -notmatch '^[Yy]') { Write-Info 'cancelled - nothing changed'; exit 0 }
}

# ---------------------------------------------------------------- save undo
Write-Utf8NoBom -Path $backupFile -Content (@{
    commit = $currentCommit
    desc   = $currentDesc
    savedAt= (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
} | ConvertTo-Json)
Write-Ok "current version saved - .\utilities\update-upstream.ps1 -Rollback undoes this"

# ---------------------------------------------------------------- do it
Write-Step "Checking out $Ref"
RepoGit fetch --tags --force origin | Out-Null
RepoGit checkout --force $Ref | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Bad "checkout of $Ref failed."; exit 1 }
Write-Ok "repo\ is now at $Ref"

Install-Deps

# CUDA torch is reinstalled from a custom index by install.ps1; a plain
# dependency sync can quietly pull the CPU-only wheel back over it.
Write-Step 'Verifying CUDA survived the dependency install'
$cuda = & $VenvPython -c "import torch;print(torch.cuda.is_available())" 2>$null
if ($cuda -ne 'True') {
    Write-Warn2 'torch is no longer CUDA-enabled - the dependency install replaced it with the CPU wheel.'
    Write-Info 'Fix with:  .\utilities\install.ps1 -CudaOnly'
} else {
    Write-Ok 'CUDA still available'
}

# ---------------------------------------------------------------- record
$pin.ref = $Ref
if ($pin.PSObject.Properties.Name -contains 'pinnedAt') { $pin.pinnedAt = (Get-Date -Format 'yyyy-MM-dd') }
else { $pin | Add-Member -NotePropertyName pinnedAt -NotePropertyValue (Get-Date -Format 'yyyy-MM-dd') -Force }
Write-Utf8NoBom -Path $UpstreamFile -Content ($pin | ConvertTo-Json -Depth 5)
Write-Ok "configs\upstream.json now pins $Ref"

Write-Step 'Health check'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'check.ps1')

Write-Host ''
Write-Host "  Now on $Ref. Start it and talk to it before trusting it." -ForegroundColor Green
Write-Info 'If anything is wrong:  .\utilities\update-upstream.ps1 -Rollback'
Write-Host ''
