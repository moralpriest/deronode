# lib/snapshot.ps1 — privacy-hardened snapshot & restore of the chain state.
# Archive: standard .tar.zst via GNU tar (explicit include list + excludes)
# compressed with zstd. Restore extracts with rargz when present, else tar.

$script:SnapshotInclude = @('balances', 'bltx_store', 'topo.map')
$script:SnapshotExclude = @('peers.json', 'trusted_peers.json', 'ban_list.json', 'config.json', 'config_pool.json')

function Get-SnapshotChainDir {
    $base = $script:DataDirReal
    if (Test-ExternalInstalled) {
        $ext = Get-ExternalDataDir
        if ($ext) { $base = $ext }
    }
    $mn = Join-Path $base 'mainnet'
    if (Test-Path (Join-Path $mn 'topo.map')) { return $mn }
    return $base
}

function Get-SnapshotHeight {
    if (Test-NodeRunning) {
        $info = Invoke-RpcCall 'DERO.GetInfo'
        if ($info -and $info.height) { return [string][int]$info.height }
    }
    return ''
}

# Portable process table: pid / name / commandline / executable path. Windows
# uses CIM (ExecutablePath powers external-node detection + update); other
# platforms parse `ps -eo pid=,comm=,args=` (comm = executable name, so a
# "deronode" path never matches a derod executable).
function Get-ProcessTable {
    if ($script:IsWindows) {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ Pid = $_.ProcessId; Name = $_.Name; CommandLine = $_.CommandLine; ExecutablePath = $_.ExecutablePath } }
    } else {
        $rows = & ps -eo pid=,comm=,args= 2>$null
        foreach ($row in $rows) {
            $t = [regex]::Match([string]$row, '^\s*(\d+)\s+(\S+)\s+(.*)$')
            if ($t.Success) {
                [pscustomobject]@{ Pid = [int]$t.Groups[1].Value; Name = $t.Groups[2].Value; CommandLine = $t.Groups[3].Value; ExecutablePath = $null }
            }
        }
    }
}

# PIDs of actual derod daemon processes (matched by executable name, not the
# full cmdline, so unrelated processes in a "deronode" path never match).
function Get-DerodPids {
    Get-ProcessTable | Where-Object { $_.Name -like 'derod*' } |
        Select-Object -ExpandProperty Pid
}

function Test-SnapshotRunningOnDataDir {
    if (Test-NodeRunning) { return $true }
    if (Test-Path (Join-Path $script:InstallDir 'derod.pid')) { return $true }
    foreach ($proc in (Get-ProcessTable | Where-Object { $_.Name -like 'derod*' })) {
        if ($proc.CommandLine -like "*--data-dir=$($script:DataDirReal)*") { return $true }
    }
    return $false
}

function Test-AnyDerodRunning {
    if (Test-NodeRunning) { return $true }
    if (Test-Path (Join-Path $script:InstallDir 'derod.pid')) { return $true }
    return [bool](Get-DerodPids)
}

function Get-SnapshotRawBytes {
    $dir = Get-SnapshotChainDir
    if (-not $script:IsWindows) {
        $total = 0L
        foreach ($item in $script:SnapshotInclude) {
            $p = Join-Path $dir $item
            if (Test-Path $p) {
                $line = (& du -sk $p 2>$null | Select-Object -First 1)
                if ($LASTEXITCODE -eq 0 -and $line) {
                    $total += [long](([string]$line) -split "`t")[0] * 1024
                }
            }
        }
        return $total
    }
    $total = 0L
    foreach ($item in $script:SnapshotInclude) {
        $p = Join-Path $dir $item
        if (Test-Path $p) {
            $sz = (Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if ($sz) { $total += [long]$sz }
        }
    }
    return $total
}

function Get-Sha256Hex {
    param([string]$File)
    if (Get-Command sha256sum -ErrorAction SilentlyContinue) {
        return ((& sha256sum $File | Select-Object -First 1) -split '\s+')[0]
    }
    return (Get-FileHash $File -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-Sha256Verify {
    param([string]$Name, [string]$Dir)
    Push-Location $Dir
    try {
        if (Get-Command sha256sum -ErrorAction SilentlyContinue) {
            & sha256sum -c "$Name.sha256" 2>$null | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        $expected = ((Get-Content "$Name.sha256" -Raw) -split '\s+')[0]
        $actual = (Get-FileHash $Name -Algorithm SHA256).Hash.ToLowerInvariant()
        return ($expected.ToLowerInvariant() -eq $actual)
    } finally { Pop-Location }
}

# True when stdin is an interactive terminal (prompts allowed). Separated so
# the smoke suite can force the interactive branch.
function Test-StdinInteractive { return -not [Console]::IsInputRedirected }

function New-Snapshot {
    $chainDir = Get-SnapshotChainDir
    $outDir = if ($script:SnapshotDir) { $script:SnapshotDir } else { $script:SnapshotDirReal }
    $level = [int]$script:CFG.snapshot_level
    if ($level -lt 1) { $level = 1 }
    if ($script:SnapshotMaxRatio) { $level = 19 }

    if (-not (Test-Path $chainDir)) {
        Write-Host "[x] chain data not found at $chainDir (nothing to snapshot)" -ForegroundColor Red
        return $false
    }
    $missing = @($script:SnapshotInclude | Where-Object { -not (Test-Path (Join-Path $chainDir $_)) })
    if ($missing.Count -gt 0) {
        Write-Host "[x] chain dir incomplete at $chainDir - missing: $($missing -join ' ')" -ForegroundColor Red
        return $false
    }
    if ((Test-SnapshotRunningOnDataDir) -and -not $script:SnapshotKeepRunning) {
        Write-Host "[x] derod is running on $($script:DataDirReal) - stop it (deronode stop) or pass --keep-running for a live snapshot." -ForegroundColor Red
        return $false
    }

    $ts = Get-Date -Format 'yyyyMMdd-HHmm'
    $height = Get-SnapshotHeight
    $name = "dero-mainnet-$ts"
    if ($height) { $name += "-h$height" }
    $name += '.tar.zst'
    $rawSize = Get-SnapshotRawBytes

    if ($script:DryRun) {
        Write-Host "[*] dry-run: would snapshot $chainDir" -ForegroundColor DarkCyan
        Write-Host "    archive : $(Join-Path $outDir $name)"
        Write-Host "    includes: $($script:SnapshotInclude -join ' ')"
        Write-Host "    excludes: $($script:SnapshotExclude -join ' ')"
        Write-Host "    bytes_raw: $rawSize   zstd level: $level"
        return $true
    }

    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Write-Host '[x] snapshot needs tar' -ForegroundColor Red
        return $false
    }
    # zstd CLI (brew install zstd / winget install zstandard) is preferred;
    # GNU tar --zstd and modern bsdtar (macOS, Win10+) work without it.
    $haveZstd = [bool](Get-Command zstd -ErrorAction SilentlyContinue)
    $haveTarZstd = $false
    try {
        $haveTarZstd = [bool]((& tar --help 2>&1 | Select-String -Pattern '--zstd' -Quiet))
    } catch { $haveTarZstd = $false }
    if (-not $haveZstd -and -not $haveTarZstd) {
        Write-Host '[x] snapshot needs the zstd CLI (brew install zstd / winget install zstandard) or a tar with --zstd support' -ForegroundColor Red
        return $false
    }

    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $out = Join-Path $outDir $name
    $tmpOut = "$out.tmp"
    Write-Host "[*] snapshotting $chainDir -> $out" -ForegroundColor DarkCyan
    Write-Host "    includes: $($script:SnapshotInclude -join ' ')   excludes: $($script:SnapshotExclude -join ' ')"

    $excArgs = @()
    foreach ($e in $script:SnapshotExclude) { $excArgs += "--exclude=$e" }
    $errFile = Join-Path $outDir '.snap-tar.err'
    try {
        if ($haveZstd) {
            if ($script:IsWindows) {
                $incStr = ($script:SnapshotInclude | ForEach-Object { '"{0}"' -f $_ }) -join ' '
                $excStr = ($excArgs | ForEach-Object { '"{0}"' -f $_ }) -join ' '
                $c = "cd /d ""$chainDir"" && tar $excStr -cf - $incStr | zstd -T0 -q -$level --long=27 -o ""$tmpOut"""
                & cmd.exe /d /c $c
                if ($LASTEXITCODE -ne 0) { throw 'tar/zstd failed' }
            } else {
                & tar @excArgs -C $chainDir -cf - @($script:SnapshotInclude) 2>$errFile |
                    & zstd -T0 -q -$level --long=27 -o "$tmpOut"
            }
        } else {
            # No zstd CLI — GNU tar --zstd / bsdtar handles compression itself.
            if ($script:IsWindows) {
                $incStr = ($script:SnapshotInclude | ForEach-Object { '"{0}"' -f $_ }) -join ' '
                $excStr = ($excArgs | ForEach-Object { '"{0}"' -f $_ }) -join ' '
                $c = "cd /d ""$chainDir"" && tar --zstd $excStr -cf ""$tmpOut"" $incStr"
                & cmd.exe /d /c $c
                if ($LASTEXITCODE -ne 0) { throw 'tar --zstd failed' }
            } else {
                & tar --zstd @excArgs -C $chainDir -cf "$tmpOut" @($script:SnapshotInclude) 2>$errFile
                if ($LASTEXITCODE -ne 0) { throw 'tar --zstd failed' }
            }
        }
        $terr = ''
        if (Test-Path $errFile) {
            $raw = Get-Content $errFile -Raw
            if ($raw) { $terr = $raw.Trim() }
        }
        if ($LASTEXITCODE -ne 0 -or $terr) {
            throw ($terr | Select-Object -First 1)
        }
    } catch {
        $emsg = $_.Exception.Message
        if (-not $emsg) { $emsg = 'snapshot failed' }
        Remove-Item $tmpOut, $errFile -Force -ErrorAction SilentlyContinue
        Write-Host "[x] $emsg" -ForegroundColor Red
        return $false
    }
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    Move-Item $tmpOut $out -Force

    $sha = Get-Sha256Hex $out
    Set-Content "$out.sha256" "$sha  $name" -NoNewline

    $h = $null; $th = $null
    if ($height -and (Test-NodeRunning)) {
        $info = Invoke-RpcCall 'DERO.GetInfo'
        if ($info) { $h = [int]$info.height; $th = [int]$info.topoheight }
    }
    $manifest = [ordered]@{
        artifact   = $name
        created    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        height     = $h
        topoheight = $th
        sha256     = $sha
        bytes_raw  = [long]$rawSize
        bytes_zst  = (Get-Item $out).Length
        zstd_level = $level
        includes   = @($script:SnapshotInclude)
        excludes   = @($script:SnapshotExclude)
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content "$out.manifest.json" -Encoding UTF8

    Write-Host "[*] done: $name" -ForegroundColor Green
    Write-Host "    sha256: $sha"
    Write-Host "    archive: $out"
    return $true
}

# Newest dero-mainnet-*.tar.zst in the snapshot dir, by last-write time (newest
# name as a tie-break/fallback). Returns the path or $null when none exists.
function Get-LatestSnapshotArchive {
    $dir = if ($script:SnapshotDir) { $script:SnapshotDir } else { $script:SnapshotDirReal }
    if (-not (Test-Path $dir)) { return $null }
    $archives = Get-ChildItem (Join-Path $dir 'dero-mainnet-*.tar.zst') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if (-not $archives) { return $null }
    return $archives[0].FullName
}

function Restore-Snapshot {
    $archive = $script:SnapshotFrom
    if (-not $archive) {
        $archive = Get-LatestSnapshotArchive
        if (-not $archive) {
            $dir = if ($script:SnapshotDir) { $script:SnapshotDir } else { $script:SnapshotDirReal }
            Write-Host "[x] no snapshot found in $dir - pass --from=<archive>" -ForegroundColor Red
            return $false
        }
        Write-Host "[*] using latest snapshot: $(Split-Path -Leaf $archive)" -ForegroundColor DarkCyan
    }
    if (-not (Test-Path $archive)) { Write-Host "[x] archive not found: $archive" -ForegroundColor Red; return $false }
    $chainDir = Get-SnapshotChainDir

    if (Test-AnyDerodRunning) {
        Write-Host '[x] derod is running - restore replaces chain state. Stop it first (deronode stop).' -ForegroundColor Red
        return $false
    }

    $name = Split-Path -Leaf $archive
    $dir = Split-Path -Parent $archive
    if (Test-Path "$archive.sha256") {
        if (Test-Sha256Verify $name $dir) {
            Write-Host '[*] sha256 verified' -ForegroundColor Green
        } else {
            Write-Host "[x] sha256 verification failed for $archive" -ForegroundColor Red
            return $false
        }
    } else {
        Write-Host '[!] no .sha256 next to archive - skipping verification' -ForegroundColor Yellow
        if (-not $script:SnapshotYes) {
            if (-not (Read-YesNo 'Continue without verification?' 'n')) { return $false }
        }
    }

    $maniH = ''
    if (Test-Path "$archive.manifest.json") {
        $maniH = (Get-Content "$archive.manifest.json" -Raw | ConvertFrom-Json).height
    }

    if (-not $script:SnapshotYes) {
        Write-Host "    target : $chainDir"
        Write-Host "    archive: $archive"
        if (-not (Read-YesNo "Restore $archive into $chainDir? (current chain moved to .bak)" 'n')) {
            Write-Host '[*] aborted' -ForegroundColor DarkGray
            return $false
        }
    }

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = ''
    if (Test-Path $chainDir) {
        $bak = "$chainDir.bak-$ts"
        Move-Item $chainDir $bak
        Write-Host "[*] moved $chainDir -> $bak" -ForegroundColor DarkGray
    }
    New-Item -ItemType Directory -Path $chainDir -Force | Out-Null

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('deronode-restore-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $ok = $false
    if (Get-Command rargz -ErrorAction SilentlyContinue) {
        Write-Host '[*] extracting with rargz...' -ForegroundColor DarkGray
        & rargz --extract -o $tmp $archive 2>$null
        if ($LASTEXITCODE -eq 0) { $ok = $true }
    } else {
        Write-Host '[*] extracting with tar --zstd...' -ForegroundColor DarkGray
        & tar --zstd -xf $archive -C $tmp 2>$null
        if ($LASTEXITCODE -eq 0) { $ok = $true }
    }
    if (-not $ok) {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '[x] extraction failed; restoring previous chain' -ForegroundColor Red
        if ($bak) { Move-Item $bak $chainDir }
        return $false
    }
    foreach ($item in $script:SnapshotInclude) {
        if (-not (Test-Path (Join-Path $tmp $item))) {
            Write-Host "[x] archive missing $item; restoring previous chain" -ForegroundColor Red
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
            if ($bak) { Move-Item $bak $chainDir }
            return $false
        }
    }
    Get-ChildItem $tmp -Force | Move-Item -Destination $chainDir -Force
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "[*] restored into $chainDir" -ForegroundColor Green
    if ($bak) { Write-Host "    keep $bak until the node reaches height >= $maniH, then delete it manually." -ForegroundColor DarkGray }
    return $true
}