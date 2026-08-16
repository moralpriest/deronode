# deronode PowerShell smoke tests — non-interactive verification of the PS path.
$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $ProjectDir

$PASS = 0; $FAIL = 0
function Pass([string]$m) { Write-Host "  [PASS] $m"; $script:PASS++ }
function Fail([string]$m) { Write-Host "  [FAIL] $m"; $script:FAIL++ }

Write-Host '=== deronode PowerShell smoke tests ==='
Write-Host ''

# 1. Prerequisites
Write-Host '1. Prerequisites:'
if (Get-Command jq -ErrorAction SilentlyContinue) { Pass 'jq available' } else { Fail 'jq available' }

# 2. Catalog validation
Write-Host ''
Write-Host '2. Catalog validation:'
try { Get-Content catalog.json -Raw | ConvertFrom-Json | Out-Null; Pass 'catalog.json parses as valid JSON' } catch { Fail 'catalog.json parses as valid JSON' }
$cat = Get-Content catalog.json -Raw | ConvertFrom-Json
if ($cat.repo -eq 'DEROFDN/derohe') { Pass 'catalog points at DEROFDN/derohe' } else { Fail 'catalog points at DEROFDN/derohe' }
$os = if ($IsWindows) { 'windows' } else { 'linux' }
$ok = [bool]@($cat.assets | Where-Object { $_.os -eq $os })
if ($ok) { Pass "catalog covers current OS ($os)" } else { Fail "catalog covers current OS ($os)" }

# 3. Config schema
Write-Host ''
Write-Host '3. Config schema:'
try { $cfgEx = Get-Content config.example.json -Raw | ConvertFrom-Json; Pass 'config.example.json parses' } catch { Fail 'config.example.json parses' }
$need = @('integrator_address','sync_profile','fastsync','prune_history','node_tag','getwork_bind','data_dir','log_dir','rpc_bind','p2p_bind','min_peers','max_peers','socks_proxy','add_priority_node','add_exclusive_node','clog_level','flog_level','testnet','debug','time_is_in_sync','sync_node','extra_args','snapshot_dir','snapshot_level')
$missing = @($need | Where-Object { $null -eq $cfgEx.PSObject.Properties[$_] })
if ($missing.Count -eq 0) { Pass 'config.example.json has all 24 keys' } else { Fail "config.example.json missing: $($missing -join ',')" }

# 4. Installer safety
Write-Host ''
Write-Host '4. Installer safety:'
$sh = Get-Content install.sh -Raw
if ($sh -match 'install_pwsh_if_missing' -and $sh -match 'DERONODE_SKIP_PWSH' -and $sh -match 'DERONODE_AUTO_INSTALL_PWSH' -and $sh -match '/dev/tty' -and $sh -match 'brew install --cask powershell') { Pass 'bash installer handles missing pwsh safely' } else { Fail 'bash installer handles missing pwsh safely' }
if ($sh -match 'not packaged for Termux' -and $sh -match 'com\.termux' -and $sh -notmatch 'pkg install.*powershell') { Pass 'bash installer never attempts pwsh install on Termux' } else { Fail 'bash installer never attempts pwsh install on Termux' }
if ($sh -match 'reset --hard' -and $sh -match 'pull --ff-only') { Pass 'installer recovers from diverged clone on update' } else { Fail 'installer recovers from diverged clone on update' }
$ps = Get-Content install.ps1 -Raw
if ($ps -match 'Install-PwshIfMissing' -and $ps -match 'Microsoft.PowerShell') { Pass 'PowerShell installer handles missing pwsh' } else { Fail 'PowerShell installer handles missing pwsh' }
$svc = Get-Content (Join-Path $ProjectDir 'lib/service.ps1') -Raw
if ($svc -match 'PSEdition') { Pass 'service picks pwsh vs powershell by edition' } else { Fail 'service picks pwsh vs powershell by edition' }
if ($svc -match 'is-system-running') { Pass 'systemd backend requires live user session' } else { Fail 'systemd backend requires live user session' }
if ($svc -match 'Get-ProcessTable') { Pass 'pid stop uses portable process table' } else { Fail 'pid stop uses portable process table' }

# 5. Version + help
Write-Host ''
Write-Host '5. CLI basics:'
$ver = (& ./node.ps1 --version 6>&1 2>&1 | Select-Object -First 1)
if ($ver -match '^deronode \d+\.\d+\.\d+$') { Pass "--version prints '$ver'" } else { Fail "--version prints '$ver'" }
$help = (& ./node.ps1 --help 2>&1 | Out-String)
foreach ($token in @('--integrator-address','--sync-profile','--getwork-bind','--data-dir','--log-dir','--rpc-bind','--p2p-bind','--prune-history','--add-priority-node','--socks-proxy','--testnet','--extra-arg','--config=','snapshot','restore','--level','--max-ratio','--out','--keep-running','--from','--yes')) {
    if ($help -match [regex]::Escape($token)) { Pass "help documents '$token'" } else { Fail "help documents '$token'" }
}

# 6. Argv builder
Write-Host ''
Write-Host '6. derod argv builder:'
. (Join-Path $ProjectDir 'lib/config.ps1')
. (Join-Path $ProjectDir 'lib/platform.ps1')
$script:InstallDir = $ProjectDir
$script:ConfigFile = Join-Path $ProjectDir 'config.json'
$script:Platform = Get-PwshPlatform
Import-Config
Set-SyncProfile 'pruned'
Resolve-Paths
$av = Build-DerodArgv
$s = $av -join ' '
if ($s -match '--fastsync' -and $s -match '--prune-history=100000' -and $s -match '--rpc-bind=127\.0\.0\.1:10102') { Pass 'pruned argv has fastsync/prune/rpc' } else { Fail "pruned argv ($s)" }
Set-SyncProfile 'full'
Resolve-Paths
$s = (Build-DerodArgv) -join ' '
if ($s -notmatch '--fastsync' -and $s -notmatch '--prune-history') { Pass 'full argv omits fastsync/prune' } else { Fail "full argv omits fastsync/prune ($s)" }
Set-SyncProfile 'pruned'
$script:CFG.testnet = $true
Resolve-Paths
Apply-TestnetDefaults
$s = (Build-DerodArgv) -join ' '
if ($s -match '--testnet' -and $s -match '--rpc-bind=127\.0\.0\.1:40402' -and $s -match '--getwork-bind=127\.0\.0\.1:40400') { Pass 'testnet argv swaps default ports' } else { Fail "testnet argv ($s)" }
$script:CFG.testnet = $false
$script:CFG.extra_args = @('--rpc-public')
$s = (Build-DerodArgv) -join ' '
if ($s -match '--rpc-public') { Pass 'extra_args passthrough' } else { Fail 'extra_args passthrough' }

# 7. Dry-run is offline (no download, no config, no dirs created)
Write-Host ''
Write-Host '6b. Checksum verification (real DEROFDN 128-char sha512):'
. (Join-Path $ProjectDir 'lib/download.ps1')
$tmpCs = Join-Path $ProjectDir '.cs-test'
Remove-Item -Path $tmpCs -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $tmpCs -Force | Out-Null
$fake = Join-Path $tmpCs 'archive'
Set-Content $fake 'x' -NoNewline
$h512 = (Get-FileHash $fake -Algorithm SHA512).Hash.ToLowerInvariant()
Set-Content (Join-Path $tmpCs 'cs4') "$h512  dero_linux_amd64.tar.gz"
if (Test-Checksum $fake (Join-Path $tmpCs 'cs4') 'dero_linux_amd64.tar.gz') { Pass 'Test-Checksum accepts 128-char sha512' } else { Fail 'Test-Checksum accepts 128-char sha512' }
$h256 = (Get-FileHash $fake -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content (Join-Path $tmpCs 'cs1') "$h256  dero_linux_amd64.tar.gz"
if (Test-Checksum $fake (Join-Path $tmpCs 'cs1') 'dero_linux_amd64.tar.gz') { Pass 'Test-Checksum accepts 64-char sha256' } else { Fail 'Test-Checksum accepts 64-char sha256' }
Remove-Item -Path $tmpCs -Recurse -Force -ErrorAction SilentlyContinue

# 6c. Snapshot/restore offline fixture (no network, no real derod)
Write-Host ''
Write-Host '6c. Snapshot/restore offline fixture:'
. (Join-Path $ProjectDir 'lib/rpc.ps1')
. (Join-Path $ProjectDir 'lib/snapshot.ps1')
$script:InstallDir = $ProjectDir
$snapFix = Join-Path $ProjectDir '.snap-fixture'
Remove-Item -Path $snapFix -Recurse -Force -ErrorAction SilentlyContinue
$snapChain = Join-Path $snapFix 'chain'
New-Item -ItemType Directory -Path (Join-Path $snapChain 'balances/ab'), (Join-Path $snapChain 'bltx_store/b1') -Force | Out-Null
Set-Content (Join-Path $snapChain 'balances/ab/x1') 'blob' -NoNewline
Set-Content (Join-Path $snapChain 'bltx_store/b1/y1') 'blob2' -NoNewline
Set-Content (Join-Path $snapChain 'topo.map') 'topomapdata' -NoNewline
foreach ($d in @('peers.json','trusted_peers.json','ban_list.json','config.json','config_pool.json')) { Set-Content (Join-Path $snapChain $d) '{}' -NoNewline }
$script:DataDirReal = $snapChain
$script:CFG.rpc_bind = '127.0.0.1:39998'
$script:CFG.snapshot_level = 1
$script:SnapshotDir = (Join-Path $snapFix 'out')
$script:SnapshotMaxRatio = $false
$script:SnapshotKeepRunning = $false
$script:SnapshotYes = $false
$script:DryRun = $false
New-Item -ItemType Directory -Path $script:SnapshotDir -Force | Out-Null
if (New-Snapshot) { Pass 'New-Snapshot runs offline' } else { Fail 'New-Snapshot runs offline' }
$snapArch = Get-ChildItem (Join-Path $script:SnapshotDir 'dero-mainnet-*.tar.zst') -ErrorAction SilentlyContinue | Select-Object -First 1
if ($snapArch) { Pass 'archive created' } else { Fail 'archive created' }
if (Test-Path "$($snapArch.FullName).sha256") { Pass '.sha256 written' } else { Fail '.sha256 written' }
if (Test-Path "$($snapArch.FullName).manifest.json") { Pass '.manifest.json written' } else { Fail '.manifest.json written' }
$listing = (& tar -tf $snapArch.FullName 2>$null | Out-String)
$decoyBad = $false
foreach ($d in @('peers.json','trusted_peers.json','ban_list.json','config.json','config_pool.json')) {
    if ($listing -match [regex]::Escape($d)) { $decoyBad = $true; Fail "archive excludes $d" } else { Pass "archive excludes $d" }
}
if (-not $decoyBad) { Pass 'no identity files in archive' }
foreach ($item in @('balances','bltx_store','topo.map')) {
    if ($listing -match [regex]::Escape($item) + '(?:/|\s|$)') { Pass "archive includes $item" } else { Fail "archive includes $item" }
}
if (Test-Sha256Verify $snapArch.Name $script:SnapshotDir) { Pass 'archive sha256 verifies' } else { Fail 'archive sha256 verifies' }
$mani = Get-Content "$($snapArch.FullName).manifest.json" -Raw | ConvertFrom-Json
if ($null -eq $mani.height -and ($mani.includes -join ',') -eq 'balances,bltx_store,topo.map') { Pass 'manifest is chain-facts-only' } else { Fail 'manifest is chain-facts-only' }
if (($mani | ConvertTo-Json -Compress) -match '"hostname"|"node_tag"|"integrator"|"ip"|"user"|"host"') { Fail 'manifest has no identity fields' } else { Pass 'manifest has no identity fields' }
# dry-run writes nothing
Remove-Item -Path $script:SnapshotDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $script:SnapshotDir -Force | Out-Null
$script:DryRun = $true
if (New-Snapshot) { Pass 'snapshot dry-run exits 0' } else { Fail 'snapshot dry-run exits 0' }
$script:DryRun = $false
if (-not (Get-ChildItem $script:SnapshotDir -ErrorAction SilentlyContinue)) { Pass 'snapshot dry-run writes nothing' } else { Fail 'snapshot dry-run writes nothing' }
# running guard refuses; --keep-running overrides
Set-Content (Join-Path $script:InstallDir 'derod.pid') '1' -NoNewline
if (New-Snapshot) { Fail 'snapshot refuses while pidfile present' } else { Pass 'snapshot refuses while pidfile present' }
$script:SnapshotKeepRunning = $true
if (New-Snapshot) { Pass 'snapshot --keep-running overrides guard' } else { Fail 'snapshot --keep-running overrides guard' }
$script:SnapshotKeepRunning = $false
Remove-Item (Join-Path $script:InstallDir 'derod.pid') -Force -ErrorAction SilentlyContinue
# restore into a fresh dir (stub the broad "any derod" guard: the live node is up)
function Test-AnyDerodRunning { return $false }
$snapRest = Join-Path $snapFix 'restore'
New-Item -ItemType Directory -Path $snapRest -Force | Out-Null
$script:DataDirReal = $snapRest
$script:SnapshotYes = $true
$script:SnapshotFrom = $snapArch.FullName
if (Restore-Snapshot) { Pass 'restore runs offline' } else { Fail 'restore runs offline' }
if ((Test-Path (Join-Path $snapRest 'balances/ab/x1')) -and (Test-Path (Join-Path $snapRest 'bltx_store/b1/y1')) -and (Test-Path (Join-Path $snapRest 'topo.map'))) { Pass 'restore reproduces includes' } else { Fail 'restore reproduces includes' }
if (-not (Test-Path (Join-Path $snapRest 'peers.json')) -and -not (Test-Path (Join-Path $snapRest 'config.json'))) { Pass 'restore omits decoys' } else { Fail 'restore omits decoys' }
if (Get-ChildItem "$snapRest.bak-*" -ErrorAction SilentlyContinue) { Pass 'restore keeps .bak' } else { Fail 'restore keeps .bak' }
$snapPs = Get-Content (Join-Path $ProjectDir 'lib/snapshot.ps1') -Raw
if ($snapPs -match 'tar --zstd' -and $snapPs -match 'rargz --extract') { Pass 'restore falls back to tar, rargz optional' } else { Fail 'restore falls back to tar, rargz optional' }
Remove-Item -Path $snapFix -Recurse -Force -ErrorAction SilentlyContinue

# 7. Dry-run is offline (no download, no config, no dirs created)
Write-Host ''
Write-Host '7. Dry-run is offline:'
$dryCfg = Join-Path $ProjectDir '.dry-test.json'
Remove-Item -Path $dryCfg, (Join-Path $ProjectDir 'bin'), (Join-Path $ProjectDir 'drydata'), (Join-Path $ProjectDir 'drylogs') -Recurse -Force -ErrorAction SilentlyContinue
$out = (& ./node.ps1 --config=$dryCfg --dry-run --sync-profile=pruned --data-dir="$ProjectDir/drydata" --log-dir="$ProjectDir/drylogs" 6>&1 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) { Pass '--dry-run exits 0' } else { Fail "--dry-run exits 0 (rc=$LASTEXITCODE)" }
if ($out -match '--prune-history=100000') { Pass 'pruned profile in argv' } else { Fail 'pruned profile in argv' }
if ($out -match [regex]::Escape("--data-dir=$ProjectDir/drydata")) { Pass 'data-dir override in argv' } else { Fail 'data-dir override in argv' }
if (-not (Test-Path (Join-Path $ProjectDir 'bin'))) { Pass 'no bin/ created' } else { Fail 'no bin/ created' }
if (-not (Test-Path (Join-Path $ProjectDir 'drydata'))) { Pass 'no data dir created' } else { Fail 'no data dir created' }
if (-not (Test-Path $dryCfg)) { Pass 'no config file written' } else { Fail 'no config file written' }
Remove-Item -Path $dryCfg, (Join-Path $ProjectDir 'bin'), (Join-Path $ProjectDir 'drydata'), (Join-Path $ProjectDir 'drylogs') -Recurse -Force -ErrorAction SilentlyContinue

# 8. Running daemon at latest skips download
Write-Host ''
Write-Host '8. Update skips when running daemon is at latest:'
. (Join-Path $ProjectDir 'lib/rpc.ps1')
function Test-NodeRunning { return $true }
function Invoke-RpcCall { return @{ version = '3.6.0-152.DEROHE.STARGATE+14082026' } }
$rel = Get-DaemonReleaseNumber
if ($rel -eq '152') { Pass 'Get-DaemonReleaseNumber extracts 152 from version' } else { Fail "Get-DaemonReleaseNumber extracts 152 (got '$rel')" }
$tag = 'Release152'
$tagRel = if ($tag -match '(\d+)$') { $matches[1] } else { '' }
if ($rel -and $tagRel -and $rel -eq $tagRel) { Pass 'running release matches tag -> skip' } else { Fail 'running release matches tag -> skip' }
$upd = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($upd -match 'Get-DaemonReleaseNumber' -and $upd -match 'runRel -eq \$latestRel') { Pass 'Update-Node guards on running version' } else { Fail 'Update-Node guards on running version' }
if ($upd -match 'Copy-Item \$script:BinaryPath \$tmp' -and $upd -match 'Move-Item -Force \$tmp \$bin') { Pass 'Update-ExternalNode replaces via temp+rename (no ETXTBSY)' } else { Fail 'Update-ExternalNode replaces via temp+rename (no ETXTBSY)' }

# 9. Menu option 6 (reconfigure) is dispatched after the menu
Write-Host ''
Write-Host '9. Menu reconfigure dispatch:'
$menuSrc = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($menuSrc -match '''6'' \{ \$script:Action = ''reconfigure''; return \}') { Pass "menu option 6 sets Action=reconfigure" } else { Fail "menu option 6 sets Action=reconfigure" }
if ($menuSrc -match "'reconfigure' \{ Reconfigure-Node \}") { Pass "post-menu switch dispatches reconfigure" } else { Fail "post-menu switch dispatches reconfigure" }

Write-Host ''
Write-Host "=== results: $PASS passed, $FAIL failed ==="
exit $(if ($FAIL -eq 0) { 0 } else { 1 })