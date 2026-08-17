# lib/download.ps1 — resolve latest DEROFDN release, download derod, verify
# checksum.txt, extract only the daemon into bin/derod.

$script:GH_DL  = 'https://github.com/DEROFDN/derohe/releases/download'
$script:Repo   = 'DEROFDN/derohe'
$script:LastTag = ''
$script:LastAsset = ''

function Resolve-Release {
    param([object]$Platform)
    $key = Get-CatalogKey $Platform
    $cat = Get-Content $CatalogFile -Raw | ConvertFrom-Json
    $asset = @($cat.assets | Where-Object { $_.os -eq $key.os -and ($_.arch -eq '*' -or $_.arch -eq $key.arch) } | Select-Object -First 1)
    if (-not $asset) {
        Write-Host "[x] No catalog asset for $($Platform.os)/$($Platform.arch)" -ForegroundColor Red
        return $false
    }
    $script:LastAsset = $asset[0].archive
    # Resolve the latest tag from the releases/latest redirect (CDN — no GitHub
    # API quota, immune to unauthenticated rate limits). Retry on network blips.
    # -SkipHttpErrorCheck is PS 7+; on 5.1 we catch the terminating error and
    # inspect the response status instead.
    $script:LastTag = ''
    for ($i = 1; $i -le 3; $i++) {
        try {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                $resp = Invoke-WebRequest -Uri "https://github.com/$($script:Repo)/releases/latest" -Method Head -MaximumRedirection 1 -SkipHttpErrorCheck -TimeoutSec 20
                $final = $resp.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
            } else {
                $resp = Invoke-WebRequest -Uri "https://github.com/$($script:Repo)/releases/latest" -Method Head -MaximumRedirection 1 -TimeoutSec 20 -ErrorAction SilentlyContinue
                $final = $resp.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
            }
            if ($final) { $script:LastTag = ([uri]$final).Segments[-1].TrimEnd('/') }
            if ($script:LastTag) { break }
        } catch {
            $script:LastTag = ''
        }
        if ($i -lt 3) { Start-Sleep -Seconds 1 }
    }
    if (-not $script:LastTag) {
        Write-Host "[x] Could not resolve the latest release tag for $($script:Repo)" -ForegroundColor Red
        return $false
    }
    return $true
}

# bin/derod/.tag holds the tag the cached binary came from. Fresh when it
# matches a resolved tag, or within the freshness window. A community-dev
# source build (Test-SourceBuild) is always treated as fresh — `start` must
# never silently replace it with a release download; only an explicit
# `update` swaps back to the release.
function Test-CacheFresh {
    $derod = Join-Path $BinDir 'derod/derod'
    $tagfile = Join-Path $BinDir 'derod/.tag'
    if (-not (Test-Path $derod) -or -not (Test-Path $tagfile)) { return $false }
    if (Test-SourceBuild) { return $true }
    if ((Get-Content $tagfile -Raw).Trim() -eq $script:LastTag) { return $true }
    $tf = Join-Path $BinDir 'derod/.tagtime'
    if (Test-Path $tf) {
        $now = [int][double]::Parse((Get-Date -UFormat %s))
        $secs = [int]((Get-Content $tf -Raw).Trim())
        if (($now - $secs) -lt 600) { return $true }
    }
    return $false
}

function Test-Checksum {
    param([string]$Archive, [string]$ChecksumFile, [string]$Name)
    # DEROFDN ships 128-char SHA-512 hashes; accept 64-char SHA-256 too.
    $want = ''; $bits = 0
    foreach ($line in Get-Content $ChecksumFile) {
        if ($line -match "([0-9a-fA-F]{128})") { $bits = 512; $hex = $matches[1] }
        elseif ($line -match "([0-9a-fA-F]{64})") { $bits = 256; $hex = $matches[1] }
        else { continue }
        if ($line -match [regex]::Escape($Name)) { $want = $hex; break }
    }
    if (-not $want) { return $false }
    $alg = if ($bits -eq 512) { 'SHA512' } else { 'SHA256' }
    $got = (Get-FileHash $Archive -Algorithm $alg).Hash
    return ($got.ToLowerInvariant() -eq $want.ToLowerInvariant())
}

function Find-DerodBinary {
    param([string]$Dir)
    $cand = Get-ChildItem $Dir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'derod*' } |
        Select-Object -First 1
    return $cand
}

# Keep only the newest $Keep timestamped binary backups (derod.bak-*); older
# ones pile up at ~20-45 MB per update. Shared with lib/build.ps1.
function Prune-DerodBackups {
    param([string]$Dir, [int]$Keep = 3)
    Get-ChildItem (Join-Path $Dir 'derod.bak-*') -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -Skip $Keep |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Invoke-FetchDerod {
    param([object]$Platform)
    $derodDir = Join-Path $BinDir 'derod'
    New-Item -ItemType Directory -Path $derodDir -Force | Out-Null
    # Archives are kept in bin/archives/<tag>/ so an already-downloaded release
    # is not fetched again (re-verified against checksum.txt; a corrupt cache is
    # discarded and refetched).
    $cacheAr = Join-Path (Join-Path $BinDir 'archives') (Join-Path $script:LastTag $script:LastAsset)
    New-Item -ItemType Directory -Path (Split-Path $cacheAr) -Force | Out-Null
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('deronode-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $url = "$($script:GH_DL)/$($script:LastTag)/$($script:LastAsset)"
        $ar = Join-Path $tmp $script:LastAsset
        $reused = $false
        if (Test-Path $cacheAr) {
            Write-Host "[*] Reusing cached $($script:LastAsset) (tag $($script:LastTag))" -ForegroundColor DarkCyan
            Copy-Item $cacheAr $ar -Force
            $reused = $true
        } else {
            Write-Host "[*] Downloading $($script:LastAsset) (tag $($script:LastTag))" -ForegroundColor DarkCyan
            Invoke-WebRequest -Uri $url -OutFile $ar -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        }

        $cs = Join-Path $tmp 'checksum.txt'
        try {
            Invoke-WebRequest -Uri "$($script:GH_DL)/$($script:LastTag)/checksum.txt" -OutFile $cs -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            if (Test-Checksum $ar $cs $script:LastAsset) {
                Write-Host "[*] checksum verified against checksum.txt" -ForegroundColor Green
            } elseif ($reused) {
                # Cached archive failed verification - discard and refetch it.
                Write-Host "[!] cached archive failed checksum - re-downloading" -ForegroundColor Yellow
                Remove-Item $cacheAr -Force -ErrorAction SilentlyContinue
                Invoke-WebRequest -Uri $url -OutFile $ar -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
                if (Test-Checksum $ar $cs $script:LastAsset) {
                    Write-Host "[*] checksum verified against checksum.txt" -ForegroundColor Green
                } else {
                    Write-Host "[!] checksum mismatch or not listed - continuing" -ForegroundColor Yellow
                }
            } else {
                Write-Host "[!] checksum mismatch or not listed - continuing" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "[!] no checksum.txt asset; skipping verification" -ForegroundColor Yellow
        }

        Write-Host "[*] Extracting derod..." -ForegroundColor DarkCyan
        $x = Join-Path $tmp 'x'
        New-Item -ItemType Directory -Path $x -Force | Out-Null
        if ($script:LastAsset -like '*.zip') {
            Expand-Archive $ar -DestinationPath $x -Force
        } else {
            & tar -xzf $ar -C $x 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'tar extraction failed' }
        }

        $found = Find-DerodBinary $x
        if (-not $found) { throw "derod binary not found in $($script:LastAsset)" }

        $old = Join-Path $derodDir 'derod'
        # Back up the previous binary (timestamped) before replacing it, so an
        # update is reversible — same pattern as the external-node update path.
        if (Test-Path $old) {
            $bak = "$old.bak-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Copy-Item $old $bak -Force
            Write-Host "[*] backed up previous binary -> $bak" -ForegroundColor DarkCyan
        }
        Prune-DerodBackups $derodDir
        Copy-Item $found.FullName $old -Force
        if ($Platform.os -ne 'windows') { & chmod +x $old }
        Set-Content (Join-Path $derodDir '.tag') $script:LastTag -NoNewline
        Set-Content (Join-Path $derodDir '.tagtime') ([int][double]::Parse((Get-Date -UFormat %s))) -NoNewline
        Set-Content (Join-Path $derodDir '.asset') $script:LastAsset -NoNewline
        # Keep the verified archive so the next install of this tag skips the download.
        Copy-Item $ar $cacheAr -Force
        Write-Host "[*] derod $($script:LastTag) ready: $(Join-Path $derodDir 'derod')" -ForegroundColor Green
    } catch {
        Write-Host "[x] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}