# lib/build.ps1 — compile derod from the DEROFDN/derohe community-dev branch
# with the local Go toolchain and lift the binary into bin/derod/derod, as an
# alternative to the release download.

$script:DevRepo = 'https://github.com/DEROFDN/derohe.git'
$script:DevBranch = 'community-dev'
# The source checkout lives under bin/ (gitignored); the built binary goes
# through the same bin/derod/derod path the release download uses.
$script:SrcDir = Join-Path $script:BinDir 'src/derohe'
$script:DevSha = ''

# True when the Go toolchain is on PATH.
function Test-GoAvailable {
    return [bool](Get-Command go -ErrorAction SilentlyContinue)
}

# Resolve the latest community-dev commit sha (network). Sets $script:DevSha.
# Returns $false when the branch cannot be resolved (offline / repo moved).
function Resolve-DevSha {
    $script:DevSha = ''
    $sha = (& git ls-remote $script:DevRepo "refs/heads/$($script:DevBranch)" 2>$null | Select-Object -First 1)
    if ($sha) { $script:DevSha = ($sha -split '\s+')[0].Trim() }
    if (-not $script:DevSha) {
        Write-Host "[x] Could not resolve the latest $($script:DevBranch) commit for $($script:DevRepo)" -ForegroundColor Red
        return $false
    }
    return $true
}

# True when the installed binary came from a source build (community-dev),
# not a release download. start/status keep such a build until the user
# explicitly runs `update` (back to a release) or `build` again.
function Test-SourceBuild {
    $asset = Join-Path $script:BinDir 'derod/.asset'
    if (Test-Path $asset) {
        return ((Get-Content $asset -Raw).Trim() -eq 'community-dev')
    }
    return $false
}

# Clone (shallow, branch) or fast-forward the community-dev checkout in
# $script:SrcDir. Sets $script:DevSha to the checked-out short sha.
function Sync-DevSource {
    $gitDir = Join-Path $script:SrcDir '.git'
    if (Test-Path $gitDir) {
        Write-Host "[*] updating $($script:DevBranch) checkout at $($script:SrcDir)" -ForegroundColor DarkCyan
        & git -C $script:SrcDir fetch origin $script:DevBranch *> $null
        if ($LASTEXITCODE -ne 0) { Write-Host '[x] git fetch failed - offline?' -ForegroundColor Red; return $false }
        & git -C $script:SrcDir reset --hard "origin/$($script:DevBranch)" *> $null
        if ($LASTEXITCODE -ne 0) { Write-Host '[x] git reset failed' -ForegroundColor Red; return $false }
    } else {
        Write-Host "[*] cloning $($script:DevRepo) ($($script:DevBranch), shallow)..." -ForegroundColor DarkCyan
        New-Item -ItemType Directory -Path (Split-Path $script:SrcDir) -Force | Out-Null
        & git clone --depth 1 --branch $script:DevBranch $script:DevRepo $script:SrcDir *> $null
        if ($LASTEXITCODE -ne 0) { Write-Host '[x] git clone failed - offline?' -ForegroundColor Red; return $false }
    }
    $script:DevSha = (& git -C $script:SrcDir rev-parse --short HEAD 2>$null).Trim()
    if (-not $script:DevSha) {
        Write-Host "[x] could not read the $($script:DevBranch) revision" -ForegroundColor Red
        return $false
    }
    return $true
}

# Compile derod from the checkout and lift it into bin/derod/derod, marking
# the install as a source build (Test-SourceBuild) so it is kept until an
# explicit `update`.
function Invoke-BuildDerodFromSource {
    if (-not (Test-GoAvailable)) {
        Write-Host '[x] Go toolchain not found - install Go 1.17+ (https://go.dev/dl/) to build derod from source' -ForegroundColor Red
        return $false
    }
    if (-not (Sync-DevSource)) { return $false }
    Write-Host "[*] building derod from $($script:DevBranch)@$($script:DevSha) (go build ./cmd/derod)..." -ForegroundColor DarkCyan
    Push-Location $script:SrcDir
    try {
        & go build -o derod ./cmd/derod
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) { Write-Host '[x] go build failed - see the output above' -ForegroundColor Red; return $false }
    $found = Find-DerodBinary $script:SrcDir
    if (-not $found) { Write-Host '[x] derod binary not found after build' -ForegroundColor Red; return $false }

    # Same executable-magic sanity check the release download uses.
    $magic = ''
    try {
        $bytes = [System.IO.File]::ReadAllBytes($found.FullName)
        if ($bytes.Length -ge 4) { $magic = '{0:x2}{1:x2}{2:x2}{3:x2}' -f $bytes[0], $bytes[1], $bytes[2], $bytes[3] }
    } catch { }
    if ($magic -notin @('7f454c46', 'cffaedfe', 'cafebabe', 'feedface', 'feedfacf', '4d5a')) {
        Write-Host '[x] Built derod failed the executable magic check' -ForegroundColor Red
        return $false
    }

    $derodDir = Join-Path $script:BinDir 'derod'
    New-Item -ItemType Directory -Path $derodDir -Force | Out-Null
    $old = Join-Path $derodDir 'derod'
    # Back up the previous binary (timestamped) before replacing it, so a
    # source build never destroys the previous (e.g. release) binary.
    if (Test-Path $old) {
        $bak = "$old.bak-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item $old $bak -Force
        Write-Host "[*] backed up previous binary -> $bak" -ForegroundColor DarkCyan
    }
    Prune-DerodBackups $derodDir
    Copy-Item $found.FullName $old -Force
    if (-not $script:IsWindows) { & chmod +x $old }
    Set-Content (Join-Path $derodDir '.tag') "community-dev@$($script:DevSha)" -NoNewline
    Set-Content (Join-Path $derodDir '.asset') 'community-dev' -NoNewline
    Set-Content (Join-Path $derodDir '.tagtime') ([int][double]::Parse((Get-Date -UFormat %s))) -NoNewline
    Write-Host "[*] derod built from community-dev@$($script:DevSha): $(Join-Path $derodDir 'derod')" -ForegroundColor Green
    return $true
}
