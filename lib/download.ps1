# lib/download.ps1 — resolve latest DEROFDN release, download derod, verify
# checksum.txt, extract only the daemon into bin/derod.

$script:GH_API = 'https://api.github.com/repos/DEROFDN/derohe/releases/latest'
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
    try {
        $h = @{ 'Accept' = 'application/vnd.github.v3+json'; 'User-Agent' = "deronode/$script:DeronodeVersion" }
        $r = Invoke-RestMethod -Uri $script:GH_API -Headers $h -TimeoutSec 30
        $script:LastTag = [string]$r.tag_name
    } catch {
        Write-Host "[x] Could not reach GitHub releases API for $($script:Repo)" -ForegroundColor Red
        return $false
    }
    return $true
}

function Test-CacheFresh {
    $derod = Join-Path $BinDir 'derod/derod'
    $tagfile = Join-Path $BinDir 'derod/.tag'
    if (-not (Test-Path $derod) -or -not (Test-Path $tagfile)) { return $false }
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

function Invoke-FetchDerod {
    param([object]$Platform)
    $derodDir = Join-Path $BinDir 'derod'
    New-Item -ItemType Directory -Path $derodDir -Force | Out-Null
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('deronode-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $url = "$($script:GH_DL)/$($script:LastTag)/$($script:LastAsset)"
        Write-Host "[*] Downloading $($script:LastAsset) (tag $($script:LastTag))" -ForegroundColor DarkCyan
        Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp $script:LastAsset) -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop

        $cs = Join-Path $tmp 'checksum.txt'
        try {
            Invoke-WebRequest -Uri "$($script:GH_DL)/$($script:LastTag)/checksum.txt" -OutFile $cs -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            if (Test-Checksum (Join-Path $tmp $script:LastAsset) $cs $script:LastAsset) {
                Write-Host "[*] checksum verified against checksum.txt" -ForegroundColor Green
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
            Expand-Archive (Join-Path $tmp $script:LastAsset) -DestinationPath $x -Force
        } else {
            & tar -xzf (Join-Path $tmp $script:LastAsset) -C $x 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'tar extraction failed' }
        }

        $found = Find-DerodBinary $x
        if (-not $found) { throw "derod binary not found in $($script:LastAsset)" }

        Copy-Item $found.FullName (Join-Path $derodDir 'derod') -Force
        if ($Platform.os -ne 'windows') { & chmod +x (Join-Path $derodDir 'derod') }
        Set-Content (Join-Path $derodDir '.tag') $script:LastTag -NoNewline
        Set-Content (Join-Path $derodDir '.tagtime') ([int][double]::Parse((Get-Date -UFormat %s))) -NoNewline
        Set-Content (Join-Path $derodDir '.asset') $script:LastAsset -NoNewline
        Write-Host "[*] derod $($script:LastTag) ready: $(Join-Path $derodDir 'derod')" -ForegroundColor Green
    } catch {
        Write-Host "[x] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}