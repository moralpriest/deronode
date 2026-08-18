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
if ($svc -match 'degraded' -and $svc -match 'is-system-running') { Pass 'systemd backend keeps degraded sessions (no pid fallback)' } else { Fail 'systemd backend keeps degraded sessions (no pid fallback)' }
if ($svc -match 'usr/bin/env pwsh' -and $svc -match 'chmod') { Pass 'run wrapper is executable with pwsh shebang on non-Windows' } else { Fail 'run wrapper is executable with pwsh shebang on non-Windows' }
if ($svc -match '@derodArgs') { Pass 'run wrapper splats argv (comma list would be one arg)' } else { Fail 'run wrapper splats argv (comma list would be one arg)' }
if ($svc -match 'WindowStyle' -and $svc -match 'IsWindows') { Pass 'Start-Background only passes -WindowStyle on Windows' } else { Fail 'Start-Background only passes -WindowStyle on Windows' }
if ($svc -match 'journalctl --user -u deronode.service') { Pass 'systemd start failure is surfaced' } else { Fail 'systemd start failure is surfaced' }
if ($svc -match 'already configured and running' -and $svc -match 'is-active' -and $svc -match 'return') { Pass 'Install-Service short-circuits before building wrapper' } else { Fail 'Install-Service short-circuits before building wrapper' }
if ($svc -match 'org\.deronode\.derod is already configured' -and $svc -match 'launchctl list') { Pass 'launchd install is idempotent (PS)' } else { Fail 'launchd install is idempotent (PS)' }
if ($svc -match 'Get-ProcessTable') { Pass 'pid stop uses portable process table' } else { Fail 'pid stop uses portable process table' }

# 5. Version + help
Write-Host ''
Write-Host '5. CLI basics:'
$ver = (& ./node.ps1 --version 6>&1 2>&1 | Select-Object -First 1)
if ($ver -match '^deronode \d+\.\d+\.\d+$') { Pass "--version prints '$ver'" } else { Fail "--version prints '$ver'" }
$help = (& ./node.ps1 --help 2>&1 | Out-String)
foreach ($token in @('--integrator-address','--sync-profile','--getwork-bind','--data-dir','--log-dir','--rpc-bind','--p2p-bind','--prune-history','--add-priority-node','--socks-proxy','--testnet','--extra-arg','--config=','--source=','snapshot','restore','build','community-dev','--level','--max-ratio','--out','--keep-running','--from','--yes')) {
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
# Chain that already has blocks (topo.map exists): --prune-history applies but
# --fastsync is bootstrap-only, so it is dropped with a warning.
$argvFix = Join-Path $ProjectDir '.argv-fixture'
Remove-Item -Path $argvFix -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $argvFix 'mainnet') -Force | Out-Null
Set-Content (Join-Path $argvFix 'mainnet/topo.map') 'x' -NoNewline
Set-SyncProfile 'pruned'
$script:CFG.data_dir = $argvFix
Resolve-Paths
$av = Build-DerodArgv
$s = $av -join ' '
if ($s -notmatch '--fastsync' -and $s -match '--prune-history=100000' -and $s -match '--rpc-bind=127\.0\.0\.1:10102') { Pass 'established chain skips --fastsync but keeps --prune-history/rpc' } else { Fail "established chain skips --fastsync ($s)" }
# Chain already pruned (bltx_store's oldest NON-genesis block is at/above the
# prune point): --prune-history is dropped too — re-running it would redo the
# multi-hour prune rewrite on every start. derod names blocks
# <hash>.block_<diff>_<ver>_<height>, keeps the genesis block (height 0) after
# pruning, and leaves a rolling window of recent blocks near the tip.
$argvPruned = Join-Path $ProjectDir '.argv-pruned'
Remove-Item -Path $argvPruned -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $argvPruned 'mainnet/bltx_store/f0/27') -Force | Out-Null
Set-Content (Join-Path $argvPruned 'mainnet/topo.map') 'x' -NoNewline
# Genesis block (height 0) + a prune-point block (99980): only genesis sits below
# the 100000 prune point, so the chain is treated as already pruned.
Set-Content (Join-Path $argvPruned 'mainnet/bltx_store/f0/27/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.block_1_1_0') 'x' -NoNewline
Set-Content (Join-Path $argvPruned 'mainnet/bltx_store/f0/27/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.block_100000_1_99980') 'x' -NoNewline
$script:CFG.data_dir = $argvPruned
Resolve-Paths
$s = (Build-DerodArgv) -join ' '
if ($s -notmatch '--prune-history') { Pass 'pruned chain skips --prune-history' } else { Fail "pruned chain skips --prune-history ($s)" }
# Chain with old blocks still in bltx_store (never pruned): --prune-history
# still applies. Genesis (0) plus a real early block (1) below the prune point.
$argvUnpruned = Join-Path $ProjectDir '.argv-unpruned'
Remove-Item -Path $argvUnpruned -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $argvUnpruned 'mainnet/bltx_store/f0/27') -Force | Out-Null
Set-Content (Join-Path $argvUnpruned 'mainnet/topo.map') 'x' -NoNewline
Set-Content (Join-Path $argvUnpruned 'mainnet/bltx_store/f0/27/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.block_1_1_0') 'x' -NoNewline
Set-Content (Join-Path $argvUnpruned 'mainnet/bltx_store/f0/27/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd.block_1_1_1') 'x' -NoNewline
$script:CFG.data_dir = $argvUnpruned
Resolve-Paths
$s = (Build-DerodArgv) -join ' '
if ($s -match '--prune-history=100000') { Pass 'unpruned chain keeps --prune-history' } else { Fail "unpruned chain keeps --prune-history ($s)" }
Remove-Item -Path $argvPruned, $argvUnpruned -Recurse -Force -ErrorAction SilentlyContinue
# Fresh chain (no topo.map): derod can't prune <50 blocks, so --prune-history
# is deferred — the flag is dropped and a warning is printed.
$argvFresh = Join-Path $ProjectDir '.argv-fresh'
Remove-Item -Path $argvFresh -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $argvFresh 'mainnet') -Force | Out-Null
$script:CFG.data_dir = $argvFresh
Resolve-Paths
$s = (Build-DerodArgv) -join ' '
if ($s -match '--fastsync' -and $s -notmatch '--prune-history') { Pass 'fresh chain defers --prune-history' } else { Fail "fresh chain defers --prune-history ($s)" }
Remove-Item -Path $argvFix, $argvFresh -Recurse -Force -ErrorAction SilentlyContinue
Set-SyncProfile 'full'
Resolve-Paths
$s = (Build-DerodArgv) -join ' '
if ($s -notmatch '--fastsync' -and $s -notmatch '--prune-history') { Pass 'full argv omits fastsync/prune' } else { Fail "full argv omits fastsync/prune ($s)" }
Set-SyncProfile 'pruned'
# Reset binds to the mainnet defaults so the swap test is independent of the
# user's real config.json (e.g. an off-host getwork bind must not block it).
$script:CFG.rpc_bind = '127.0.0.1:10102'
$script:CFG.p2p_bind = '0.0.0.0:10101'
$script:CFG.getwork_bind = '127.0.0.1:10100'
$script:CFG.testnet = $true
Resolve-Paths
Apply-TestnetDefaults
$s = (Build-DerodArgv) -join ' '
if ($s -match '--testnet' -and $s -match '--rpc-bind=127\.0\.0\.1:40402' -and $s -match '--getwork-bind=127\.0\.0\.1:40400') { Pass 'testnet argv swaps default ports' } else { Fail "testnet argv ($s)" }
$script:CFG.testnet = $false
$script:CFG.extra_args = @('--rpc-public')
$s = (Build-DerodArgv) -join ' '
if ($s -match '--rpc-public') { Pass 'extra_args passthrough' } else { Fail 'extra_args passthrough' }
# null prune_history round-trips to "no prune" (absent keeps the 100000 default)
$nullCfg = Join-Path $ProjectDir '.null-prune.json'
Set-Content $nullCfg '{"fastsync":true,"prune_history":null}' -NoNewline
$script:ConfigFile = $nullCfg
Import-Config
if ($null -eq $script:CFG.prune_history -and $script:CFG.fastsync) { Pass 'null prune_history means no prune flag' } else { Fail "null prune_history means no prune flag (got '$($script:CFG.prune_history)')" }
# Absent key keeps the in-memory default (fresh state = 100000).
$script:CFG.prune_history = 100000
Set-Content $nullCfg '{"fastsync":true}' -NoNewline
Import-Config
if ($script:CFG.prune_history -eq 100000) { Pass 'absent prune_history keeps the default' } else { Fail "absent prune_history keeps the default (got '$($script:CFG.prune_history)')" }
Remove-Item $nullCfg -Force -ErrorAction SilentlyContinue
$script:ConfigFile = Join-Path $ProjectDir 'config.json'
Import-Config
# snapshot dir defaults next to the install (same tree as the derod binary),
# not to the old ~/Crypto/dero external-node path.
$script:CFG.snapshot_dir = ''
Resolve-Paths
if ($script:SnapshotDirReal -eq (Join-Path $ProjectDir 'snapshots')) { Pass 'snapshot dir defaults to <install>/snapshots' } else { Fail "snapshot dir defaults to <install>/snapshots (got '$($script:SnapshotDirReal)')" }
$script:CFG.snapshot_dir = '/custom/out'
Resolve-Paths
if ($script:SnapshotDirReal -eq '/custom/out') { Pass 'explicit snapshot_dir wins' } else { Fail "explicit snapshot_dir wins (got '$($script:SnapshotDirReal)')" }
$script:CFG.snapshot_dir = ''
Resolve-Paths

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
# Isolate the offline fixture from any real external install on this machine.
function Test-ExternalInstalled { return $false }
$script:InstallDir = $ProjectDir
$snapFix = Join-Path $ProjectDir '.snap-fixture'
Remove-Item -Path $snapFix -Recurse -Force -ErrorAction SilentlyContinue
$snapChain = Join-Path $snapFix 'chain'
New-Item -ItemType Directory -Path (Join-Path $snapChain 'mainnet/balances/ab'), (Join-Path $snapChain 'mainnet/bltx_store/b1') -Force | Out-Null
Set-Content (Join-Path $snapChain 'mainnet/balances/ab/x1') 'blob' -NoNewline
Set-Content (Join-Path $snapChain 'mainnet/bltx_store/b1/y1') 'blob2' -NoNewline
Set-Content (Join-Path $snapChain 'mainnet/topo.map') 'topomapdata' -NoNewline
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
# snapshot_chain_dir resolves to $base/mainnet (derod's actual data dir), so the
# fixture must pre-create mainnet/ for the .bak branch to fire.
function Test-AnyDerodRunning { return $false }
$snapRest = Join-Path $snapFix 'restore'
$restMainnet = Join-Path $snapRest 'mainnet'
New-Item -ItemType Directory -Path $restMainnet -Force | Out-Null
Set-Content (Join-Path $restMainnet 'topo.map') 'stale' -NoNewline
$script:DataDirReal = $snapRest
$script:SnapshotYes = $true
$script:SnapshotFrom = $snapArch.FullName
if (Restore-Snapshot) { Pass 'restore runs offline' } else { Fail 'restore runs offline' }
if ((Test-Path (Join-Path $restMainnet 'balances/ab/x1')) -and (Test-Path (Join-Path $restMainnet 'bltx_store/b1/y1')) -and (Test-Path (Join-Path $restMainnet 'topo.map'))) { Pass 'restore reproduces includes' } else { Fail 'restore reproduces includes' }
if (-not (Test-Path (Join-Path $restMainnet 'peers.json')) -and -not (Test-Path (Join-Path $restMainnet 'config.json'))) { Pass 'restore omits decoys' } else { Fail 'restore omits decoys' }
if (Get-ChildItem "$restMainnet.bak-*" -ErrorAction SilentlyContinue) { Pass 'restore keeps .bak' } else { Fail 'restore keeps .bak' }
# restore without --from auto-picks the latest snapshot
$snapLat = Join-Path $snapFix 'lat'
New-Item -ItemType Directory -Path (Join-Path $snapLat 'mainnet/balances/ab'), (Join-Path $snapLat 'mainnet/bltx_store/b1') -Force | Out-Null
Set-Content (Join-Path $snapLat 'mainnet/balances/ab/x1') 'oldblob' -NoNewline
Set-Content (Join-Path $snapLat 'mainnet/topo.map') 'oldtopo' -NoNewline
$script:DataDirReal = $snapLat
$script:SnapshotYes = $true
$script:SnapshotFrom = ''
function Test-AnyDerodRunning { return $false }
$restOut = ''
try {
    $okRest = Restore-Snapshot
    if ($okRest) { Pass 'restore without --from auto-picks latest' } else { Fail 'restore without --from auto-picks latest' }
} catch { Fail "restore without --from auto-picks latest (threw: $($_.Exception.Message))" }
$script:DataDirReal = $snapLat
$latBlob = (Get-Content (Join-Path $snapLat 'mainnet/balances/ab/x1') -Raw)
if ($latBlob -eq 'blob') { Pass 'auto-picked archive restores newer content' } else { Fail "auto-picked archive restores newer content (got '$latBlob')" }
# restore with an empty snapshot dir errors clearly
$emptyFix = Join-Path $snapFix 'empty'
New-Item -ItemType Directory -Path (Join-Path $emptyFix 'out') -Force | Out-Null
$script:SnapshotDir = (Join-Path $emptyFix 'out')
$script:SnapshotFrom = ''
try {
    $okEmpty = Restore-Snapshot
    if ($okEmpty) { Fail 'restore with empty snapshot dir refuses' } else { Pass 'restore with empty snapshot dir refuses' }
} catch { Fail "restore with empty snapshot dir refuses (threw: $($_.Exception.Message))" }
$script:SnapshotDir = $null
$snapPs = Get-Content (Join-Path $ProjectDir 'lib/snapshot.ps1') -Raw
if ($snapPs -match 'tar --zstd' -and $snapPs -match 'rargz --extract') { Pass 'restore falls back to tar, rargz optional' } else { Fail 'restore falls back to tar, rargz optional' }
# external data-dir resolution (stub unit files)
$unitFile = Join-Path $snapFix 'derod.service'
Set-Content $unitFile "[Service]`nWorkingDirectory=/home/priest/Crypto/dero/node" -NoNewline
$dd = Get-DataDirFromUnitFile $unitFile
if ($dd -eq '/home/priest/Crypto/dero/node') { Pass 'Get-DataDirFromUnitFile reads WorkingDirectory' } else { Fail "Get-DataDirFromUnitFile reads WorkingDirectory (got '$dd')" }
Set-Content $unitFile "[Service]`nExecStart=/usr/bin/derod --data-dir=/srv/dero/node" -NoNewline
$dd = Get-DataDirFromUnitFile $unitFile
if ($dd -eq '/srv/dero/node') { Pass 'Get-DataDirFromUnitFile falls back to --data-dir' } else { Fail "Get-DataDirFromUnitFile falls back to --data-dir (got '$dd')" }
# macOS launchd plist data-dir resolution
$plistFile = Join-Path $snapFix 'derod.plist'
Set-Content $plistFile '<?xml version="1.0"?><plist><dict><key>WorkingDirectory</key><string>/Users/priest/Crypto/dero/node</string></dict></plist>' -NoNewline
$dd = Get-DataDirFromPlist $plistFile
if ($dd -eq '/Users/priest/Crypto/dero/node') { Pass 'Get-DataDirFromPlist reads WorkingDirectory' } else { Fail "Get-DataDirFromPlist reads WorkingDirectory (got '$dd')" }
Set-Content $plistFile '<?xml version="1.0"?><plist><dict><key>ProgramArguments</key><array><string>/usr/bin/derod</string><string>--data-dir=/srv/dero/node</string></array></dict></plist>' -NoNewline
$dd = Get-DataDirFromPlist $plistFile
if ($dd -eq '/srv/dero/node') { Pass 'Get-DataDirFromPlist falls back to --data-dir' } else { Fail "Get-DataDirFromPlist falls back to --data-dir (got '$dd')" }
# Cross-platform external-node plumbing (source-grep: macOS launchd + Windows paths)
$platPs = Get-Content (Join-Path $ProjectDir 'lib/platform.ps1') -Raw
if ($platPs -match 'Set-Variable -Name IsWindows' -and $platPs -notmatch '\$script:IsWindows = if') { Pass 'platform.ps1 installs OS vars via Set-Variable (PS 5.1 + 6+ safe)' } else { Fail 'platform.ps1 installs OS vars via Set-Variable (PS 5.1 + 6+ safe)' }
$rpcPs = Get-Content (Join-Path $ProjectDir 'lib/rpc.ps1') -Raw
if ($rpcPs -match 'launchctl list' -and $rpcPs -match 'org\.deronode\.derod' -and $rpcPs -match 'Get-ProcessExe' -and $rpcPs -match 'Get-ProcessCwd' -and $rpcPs -match 'Get-DataDirFromPlist' -and $rpcPs -match 'Library/LaunchDaemons') { Pass 'rpc.ps1 detects external derod on macOS (launchd) + Windows (ExecutablePath)' } else { Fail 'rpc.ps1 detects external derod on macOS (launchd) + Windows (ExecutablePath)' }
$snapPs2 = Get-Content (Join-Path $ProjectDir 'lib/snapshot.ps1') -Raw
if ($snapPs2 -match 'ExecutablePath = \$_\.ExecutablePath') { Pass 'snapshot.ps1 process table captures ExecutablePath on Windows' } else { Fail 'snapshot.ps1 process table captures ExecutablePath on Windows' }
$nodePs = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($nodePs -match 'Start-ExternalLaunchd' -and $nodePs -match 'Stop-ExternalLaunchd' -and $nodePs -match '\$script:IsMacOS\) \{ Start-ExternalLaunchd; return \}') { Pass 'node.ps1 start/stop route to launchd on macOS' } else { Fail 'node.ps1 start/stop route to launchd on macOS' }
if ($nodePs -match 'Get-ProcessExe \$proc\.Pid' -and $nodePs -match 'launchctl kickstart -k') { Pass 'Update-ExternalNode resolves binary portably + restarts launchd' } else { Fail 'Update-ExternalNode resolves binary portably + restarts launchd' }
# Get-SnapshotChainDir resolves the external node's real data dir
function Test-ExternalInstalled { return $true }
function Get-ExternalDataDir { return (Join-Path $snapFix 'extnode') }
New-Item -ItemType Directory -Path (Join-Path $snapFix 'extnode/mainnet') -Force | Out-Null
Set-Content (Join-Path $snapFix 'extnode/mainnet/topo.map') 'x' -NoNewline
$script:DataDirReal = (Join-Path $snapFix 'decoy')
$c = Get-SnapshotChainDir
if ($c -eq (Join-Path $snapFix 'extnode/mainnet')) { Pass 'Get-SnapshotChainDir resolves external data dir' } else { Fail "Get-SnapshotChainDir resolves external data dir (got '$c')" }
function Test-ExternalInstalled { return $false }
$c = Get-SnapshotChainDir
$expected = Join-Path $script:DataDirReal 'mainnet'
if ($c -eq $expected) { Pass 'Get-SnapshotChainDir falls back to DataDirReal/mainnet' } else { Fail "Get-SnapshotChainDir falls back to DataDirReal/mainnet (got '$c')" }
# leftover flat topo.map on a non-external install resolves to mainnet (not flat)
$flatFix = Join-Path $snapFix 'flat'
New-Item -ItemType Directory -Path (Join-Path $flatFix 'chain') -Force | Out-Null
Set-Content (Join-Path $flatFix 'chain/topo.map') 'flatdata' -NoNewline
$script:DataDirReal = Join-Path $flatFix 'chain'
$c = Get-SnapshotChainDir
if ($c -eq (Join-Path $flatFix 'chain/mainnet')) { Pass 'flat topo.map without external resolves to mainnet' } else { Fail "flat topo.map without external resolves to mainnet (got '$c')" }
# missing-member pre-check fails clearly (external stub stays off)
$incFix = Join-Path $snapFix 'incomplete'
New-Item -ItemType Directory -Path (Join-Path $incFix 'mainnet/balances/ab') -Force | Out-Null
Set-Content (Join-Path $incFix 'mainnet/balances/ab/x1') 'blob' -NoNewline
Set-Content (Join-Path $incFix 'mainnet/topo.map') 'topomapdata' -NoNewline
$script:DataDirReal = $incFix
$script:SnapshotYes = $false
$script:DryRun = $false
$errOut = ''
try {
    $ok = New-Snapshot
    if ($ok) { Fail 'New-Snapshot rejects incomplete chain dir' } else { Pass 'New-Snapshot rejects incomplete chain dir' }
} catch {
    Fail "New-Snapshot rejects incomplete chain dir (threw: $($_.Exception.Message))"
}
Remove-Item -Path $snapFix -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$snapFix.bak-*" -Force -ErrorAction SilentlyContinue

# 7. Dry-run is offline (no download, no config, no dirs created). Run from an
# isolated temp copy of the runner so the test can assert 'no bin/ created'
# without touching (or deleting!) the real project bin/ — a previous version
# Remove-Item'd $ProjectDir/bin, nuking a user's installed derod on every smoke run.
Write-Host ''
Write-Host '7. Dry-run is offline:'
$dryTmp = Join-Path $ProjectDir '.dry-run-test'
Remove-Item -Path $dryTmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dryTmp -Force | Out-Null
Copy-Item (Join-Path $ProjectDir 'node.ps1'), (Join-Path $ProjectDir 'catalog.json') $dryTmp -Force
Copy-Item (Join-Path $ProjectDir 'lib') (Join-Path $dryTmp 'lib') -Recurse -Force
$dryCfg = Join-Path $dryTmp '.dry-test.json'
$out = (& (Join-Path $dryTmp 'node.ps1') --config=$dryCfg --dry-run --sync-profile=pruned --data-dir="$dryTmp/drydata" --log-dir="$dryTmp/drylogs" 6>&1 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) { Pass '--dry-run exits 0' } else { Fail "--dry-run exits 0 (rc=$LASTEXITCODE)" }
# The drydata dir is fresh (no topo.map) so prune is deferred in the argv too.
if ($out -notmatch '--prune-history=100000') { Pass 'pruned profile in argv deferred on fresh chain' } else { Fail 'pruned profile in argv deferred on fresh chain' }
if ($out -match [regex]::Escape("--data-dir=$dryTmp/drydata")) { Pass 'data-dir override in argv' } else { Fail 'data-dir override in argv' }
if (-not (Test-Path (Join-Path $dryTmp 'bin'))) { Pass 'no bin/ created' } else { Fail 'no bin/ created' }
if (-not (Test-Path (Join-Path $dryTmp 'drydata'))) { Pass 'no data dir created' } else { Fail 'no data dir created' }
if (-not (Test-Path $dryCfg)) { Pass 'no config file written' } else { Fail 'no config file written' }
Remove-Item -Path $dryTmp -Recurse -Force -ErrorAction SilentlyContinue

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
$dlPs = Get-Content (Join-Path $ProjectDir 'lib/download.ps1') -Raw
if ($dlPs -match 'Reusing cached' -and $dlPs -match 'archives' -and $dlPs -match 'cached archive failed checksum') { Pass 'Invoke-FetchDerod caches + reuses the downloaded archive' } else { Fail 'Invoke-FetchDerod caches + reuses the downloaded archive' }
if ($dlPs -match '\$old\.bak-' -and $dlPs -match 'backed up previous binary') { Pass 'Invoke-FetchDerod backs up previous binary with timestamp' } else { Fail 'Invoke-FetchDerod backs up previous binary with timestamp' }
if ($dlPs -match 'function Prune-DerodBackups' -and $dlPs -match 'Prune-DerodBackups \$derodDir' -and (Get-Content (Join-Path $ProjectDir 'lib/build.ps1') -Raw) -match 'Prune-DerodBackups \$derodDir') { Pass 'binary backups pruned to newest 3 (download + build)' } else { Fail 'binary backups pruned to newest 3 (download + build)' }

# 9. Menu option 8 (reconfigure) is dispatched after the menu
Write-Host ''
Write-Host '9. Menu reconfigure dispatch:'
$menuSrc = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($menuSrc -match '''8'' \{ \$script:Action = ''reconfigure''; return \}') { Pass "menu option 8 sets Action=reconfigure" } else { Fail "menu option 8 sets Action=reconfigure" }
if ($menuSrc -match "'reconfigure' \{ Reconfigure-Node \}") { Pass "post-menu switch dispatches reconfigure" } else { Fail "post-menu switch dispatches reconfigure" }
if ($menuSrc -match 'No derod installed yet' -and $menuSrc -match 'Configure & install derod \(download latest release\)' -and $menuSrc -match 'Configure & build derod \(compile community-dev' -and $menuSrc -match 'Ensure-Binary' -and $menuSrc -match 'Invoke-BuildDerodFromSource' -and $menuSrc -match 'Invoke-FirstRunPostInstall') { Pass 'first-run install offers download and compile paths, both route to post-install prompt' } else { Fail 'first-run install offers download and compile paths, both route to post-install prompt' }
# first-run install offers bootstrap choice: fast sync / restore file / thruflux receive
if ($menuSrc -match 'Fast sync' -and $menuSrc -match 'Restore from a snapshot' -and $menuSrc -match 'Receive a snapshot via thruflux' -and $menuSrc -match "\$script:Action = 'restore'" -and $menuSrc -match "\$script:Action = 'receive'") { Pass 'first-run bootstrap choice offers fast sync / restore / receive' } else { Fail 'first-run bootstrap choice offers fast sync / restore / receive' }
# first-run build path checks for Go toolchain before building
if ($menuSrc -match 'Test-GoAvailable') { Pass 'first-run build option checks for Go toolchain' } else { Fail 'first-run build option checks for Go toolchain' }
# first-run install honors the configure run-mode answer (service vs foreground)
$cfgSrc = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($cfgSrc -match 'function Configure' -and $cfgSrc -match 'Background system service' -and $cfgSrc -match '\$script:AsService = \$true' -and $cfgSrc -match "Read-Ask 'Choose' '2'") { Pass 'Configure offers system-service install (run mode question)' } else { Fail 'Configure offers system-service install (run mode question)' }
if ($cfgSrc -match '\$script:AsService = \$false' -and $cfgSrc -match "\$script:Action = 'start'" -and $menuSrc -notmatch 'AsService = \$false\s*\r?\n\s*return') { Pass "first-run install keeps configure's service/foreground choice" } else { Fail "first-run install keeps configure's service/foreground choice" }
# reconfigure also continues straight into start (only when nothing is running)
if ($menuSrc -match 'function Reconfigure-Node' -and $menuSrc -match 'Test-NodeRunning' -and $menuSrc -match 'Start-Node') { Pass 'reconfigure continues into start when stopped' } else { Fail 'reconfigure continues into start when stopped' }
# resync command: parse, menu, dispatch, wipe+fastsync+start
if ($menuSrc -match '''resync'' \{ \$script:Action = ''resync'' \}' -and $menuSrc -match '''12'' \{ \$script:Action = ''resync''; return \}' -and $menuSrc -match '''resync'' \{ Invoke-Resync \}') { Pass 'resync wired into parse/menu/dispatch' } else { Fail 'resync wired into parse/menu/dispatch' }
# build command (compile community-dev source): parse, menu, dispatch
if ($menuSrc -match '''build'' \{ \$script:Action = ''build'' \}' -and $menuSrc -match '''7'' \{ \$script:Action = ''build''; return \}' -and $menuSrc -match '''build'' \{ Build-Node \}') { Pass 'build wired into parse/menu/dispatch' } else { Fail 'build wired into parse/menu/dispatch' }
$bldSrc = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($bldSrc -match 'function Build-Node' -and $bldSrc -match 'Invoke-BuildDerodFromSource' -and $bldSrc -match 'Stop-Service' -and $bldSrc -match 'Install-Service' -and $bldSrc -match 'Test-ExternalInstalled') { Pass 'Build-Node stops+builds+restarts, refuses external' } else { Fail 'Build-Node stops+builds+restarts, refuses external' }
if ($bldSrc -match 'Test-GoAvailable' -and $bldSrc -match 'Go toolchain not found') { Pass 'Build-Node guards on the Go toolchain' } else { Fail 'Build-Node guards on the Go toolchain' }
$bldLib = Get-Content (Join-Path $ProjectDir 'lib/build.ps1') -Raw
if ($bldLib -match 'git clone --depth 1 --branch \$script:DevBranch' -and $bldLib -match 'go build -o derod ./cmd/derod' -and $bldLib -match 'community-dev@' -and $bldLib -match 'Test-SourceBuild') { Pass 'lib/build.ps1 clones community-dev + go builds derod + marks source' } else { Fail 'lib/build.ps1 clones community-dev + go builds derod + marks source' }
if ($bldLib -match 'Find-DerodBinary' -and $bldLib -match 'magic') { Pass 'lib/build.ps1 reuses Find-DerodBinary + magic check' } else { Fail 'lib/build.ps1 reuses Find-DerodBinary + magic check' }
# Windows binary naming + PE magic check fixes (community-dev build path)
$nodeSrc = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($nodeSrc -match '\$script:BinaryName = if \(\$script:IsWindows\)' -and $nodeSrc -match 'derod\.exe') { Pass 'node.ps1 names the Windows binary derod.exe' } else { Fail 'node.ps1 names the Windows binary derod.exe' }
if ($bldLib -match '\$script:BinaryName' -and $dlPs -match '\$script:BinaryName') { Pass 'download/build install sites use the platform binary name' } else { Fail 'download/build install sites use the platform binary name' }
if ($bldLib -match '\^\(' -and $bldLib -match '4d5a\)') { Pass 'lib/build.ps1 magic check accepts PE MZ (4d5a prefix)' } else { Fail 'lib/build.ps1 magic check accepts PE MZ (4d5a prefix)' }
if ($bldLib -match '\$old\.bak-') { Pass 'lib/build.ps1 backs up previous binary before replacing' } else { Fail 'lib/build.ps1 backs up previous binary before replacing' }
# source builds are kept by start (Test-CacheFresh) but replaced by update
if ($dlPs -match 'Test-SourceBuild\) \{ return \$true' -and $bldSrc -match '-not \(Test-SourceBuild\) -and \(Test-CacheFresh\)') { Pass 'start keeps source build; update swaps back to release' } else { Fail 'start keeps source build; update swaps back to release' }
# update --source=dev routes through the community-dev compile path; menu
# option 5 offers the release-vs-community-dev choice.
if ($menuSrc -match 'UpdateSource -eq ''dev''' -and $menuSrc -match 'Build-Node' -and $menuSrc -match 'Update source:' -and $menuSrc -match 'community-dev source \(compile\)') { Pass 'update --source=dev routes to Build-Node (menu option 5 offers the choice)' } else { Fail 'update --source=dev routes to Build-Node (menu option 5 offers the choice)' }
if ($menuSrc -match '''--source'' \{ \$script:UpdateSource = \$val \}') { Pass "Parse-Args accepts --source" } else { Fail "Parse-Args accepts --source" }
if ($menuSrc -match 'function Invoke-Resync' -and $menuSrc -match 'Get-SnapshotChainDir' -and $menuSrc -match 'Remove-Item \$chainDir -Recurse -Force' -and $menuSrc -match 'fastsync = \$true' -and $menuSrc -match 'prune_history = \$null' -and $menuSrc -match 'Start-Node') { Pass 'resync wipes chain then fastsync-bootstraps and starts' } else { Fail 'resync wipes chain then fastsync-bootstraps and starts' }
# menu-driven entry loops back to the menu after each action (no exit)
if ($menuSrc -match 'while \(\$true\)' -and $menuSrc -match '\$script:MenuMode = \$true') { Pass 'menu-driven entry loops back to the menu' } else { Fail 'menu-driven entry loops back to the menu' }
# Start-Node runs derod as a child and returns to the menu in menu mode
if ($menuSrc -match 'function Start-Node' -and $menuSrc -match '\$script:MenuMode') { Pass 'Start-Node returns to the menu in menu mode' } else { Fail 'Start-Node returns to the menu in menu mode' }
if ($menuSrc -notmatch 'Install-Service -Argv') { Pass 'Start-Node lets Install-Service build argv (no pre-build warnings)' } else { Fail 'Start-Node lets Install-Service build argv (no pre-build warnings)' }
# logs command: parse, menu, dispatch, tail selection
if ($menuSrc -match '''logs'' \{ \$script:Action = ''logs'' \}' -and $menuSrc -match '''5'' \{ \$script:Action = ''logs''; return \}' -and $menuSrc -match '''logs'' \{ Show-Logs \}') { Pass 'logs wired into parse/menu/dispatch' } else { Fail 'logs wired into parse/menu/dispatch' }
if ($menuSrc -match 'function Show-Logs' -and $menuSrc -match 'Get-Content.*-Wait' -and $menuSrc -match 'derod.out.log') { Pass 'Show-Logs tails derod.log and falls back to out/err captures' } else { Fail 'Show-Logs tails derod.log and falls back to out/err captures' }
# uninstall command: parse, menu, dispatch, stop+wipe, keep deronode
if ($menuSrc -match '''uninstall'' \{ \$script:Action = ''uninstall'' \}' -and $menuSrc -match '''15'' \{ \$script:Action = ''uninstall''; return \}' -and $menuSrc -match '''uninstall'' \{ Uninstall-Node \}') { Pass 'uninstall wired into parse/menu/dispatch' } else { Fail 'uninstall wired into parse/menu/dispatch' }
$uninstSrc = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($uninstSrc -match 'function Uninstall-Node' -and $uninstSrc -match 'Remove-Service' -and $uninstSrc -match 'Remove-Item' -and $uninstSrc -match 'DataDirReal' -and $uninstSrc -match 'ConfigFile') { Pass 'Uninstall-Node removes service + binary/chain/logs/snapshots/config' } else { Fail 'Uninstall-Node removes service + binary/chain/logs/snapshots/config' }
if ($uninstSrc -match 'Test-ExternalInstalled' -and $uninstSrc -match 'Read-YesNo') { Pass 'Uninstall-Node refuses external + confirms before wiping' } else { Fail 'Uninstall-Node refuses external + confirms before wiping' }
if ($uninstSrc -match 'Refusing to uninstall' -and $uninstSrc -match 'not a removable path') { Pass 'Uninstall-Node guards against wiping / or empty paths' } else { Fail 'Uninstall-Node guards against wiping / or empty paths' }
if ($uninstSrc -match 'stays installed' -and $uninstSrc -match 'DryRun') { Pass 'Uninstall-Node keeps deronode itself + supports dry-run' } else { Fail 'Uninstall-Node keeps deronode itself + supports dry-run' }
$svcPs = Get-Content (Join-Path $ProjectDir 'lib/service.ps1') -Raw
if ($svcPs -match 'function Remove-Service' -and $svcPs -match 'systemctl --user disable' -and $svcPs -match 'LaunchAgents/org.deronode.derod.plist') { Pass 'Remove-Service disables systemd + removes launchd plist' } else { Fail 'Remove-Service disables systemd + removes launchd plist' }
# send/receive (thruflux): parse, menu, dispatch, host/join wrappers
if ($menuSrc -match '''send'' \{ \$script:Action = ''send'' \}' -and $menuSrc -match '''13'' \{ \$script:Action = ''send''; return \}' -and $menuSrc -match '''send'' \{ Send-Snapshot \}' -and $menuSrc -match '''receive'' \{ Receive-Snapshot \}') { Pass 'send/receive wired into parse/menu/dispatch' } else { Fail 'send/receive wired into parse/menu/dispatch' }
if ($menuSrc -match '14\) Receive snapshot' -and $menuSrc -match 'Join code' -and $menuSrc -match '''receive''') { Pass 'menu option 14 prompts for the join code and dispatches receive' } else { Fail 'menu option 14 prompts for the join code and dispatches receive' }
$sendSrc = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($sendSrc -match 'function Send-Snapshot' -and $sendSrc -match 'thru host' -and $sendSrc -match 'Get-LatestSnapshotArchive' -and $sendSrc -match 'Ensure-Thruflux') { Pass 'Send-Snapshot hosts the newest snapshot via thruflux' } else { Fail 'Send-Snapshot hosts the newest snapshot via thruflux' }
if ($sendSrc -match 'function Receive-Snapshot' -and $sendSrc -match 'thru join' -and $sendSrc -match 'ReceiveCode' -and $sendSrc -match 'Ensure-Thruflux') { Pass 'Receive-Snapshot joins a thruflux code' } else { Fail 'Receive-Snapshot joins a thruflux code' }
if ($sendSrc -match 'Test-Path "\$archive\.sha256"' -and $sendSrc -match 'Test-Path "\$archive\.manifest\.json"' -and $sendSrc -match '@hostArgs') { Pass 'Send-Snapshot hosts the archive with its .sha256/.manifest siblings' } else { Fail 'Send-Snapshot hosts the archive with its .sha256/.manifest siblings' }
if ($sendSrc -match 'dero-mainnet-\*\.tar\.zst' -and $sendSrc -match 'SnapshotFrom = ' -and $sendSrc -match 'Test-SnapshotRunningOnDataDir') { Pass 'Receive-Snapshot detects a received snapshot and proposes restoring it' } else { Fail 'Receive-Snapshot detects a received snapshot and proposes restoring it' }
if ($sendSrc -match 'Test-StdinInteractive' -and $sendSrc -match 'restore --from' -and $sendSrc -match 'stop it, restore the received snapshot, then restart') { Pass 'Receive-Snapshot restore offer is interactive-only + stops/restarts the node' } else { Fail 'Receive-Snapshot restore offer is interactive-only + stops/restarts the node' }
if ($sendSrc -match 'Get-ThrufluxInstallHint' -and $sendSrc -match 'samsungplay/Thruflux') { Pass 'send/receive hint at installing thruflux per-OS' } else { Fail 'send/receive hint at installing thruflux per-OS' }
if ($sendSrc -match 'function Ensure-Thruflux' -and $sendSrc -match "Read-YesNo 'Install thruflux now\?'" -and $sendSrc -match 'Install-Thruflux') { Pass 'Ensure-Thruflux proposes installing thruflux on a tty' } else { Fail 'Ensure-Thruflux proposes installing thruflux on a tty' }
if ($sendSrc -match '2>&1 \| Out-Host' -and $sendSrc -match 'must NOT join this function.s pipeline' -and $sendSrc -match 'try \{' -and $sendSrc -match 'catch \{') { Pass 'Ensure-Thruflux installer stdout can not pollute the return value (exit-1 guard stays intact)' } else { Fail 'Ensure-Thruflux installer stdout can not pollute the return value (exit-1 guard stays intact)' }
if ($sendSrc -match 'Test-StdinInteractive' -and $sendSrc -match 'thru_windows.exe') { Pass 'Ensure-Thruflux gates the prompt on stdin + handles Windows' } else { Fail 'Ensure-Thruflux gates the prompt on stdin + handles Windows' }
if ($sendSrc -match 'function Install-Thruflux' -and $sendSrc -match 'raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries' -and $sendSrc -match 'thru_linux' -and $sendSrc -match 'thru_mac' -and $sendSrc -match 'thru_windows.exe' -and $sendSrc -match 'Invoke-WebRequest') { Pass 'Install-Thruflux fetches the per-OS binary directly (upstream 404 workaround)' } else { Fail 'Install-Thruflux fetches the per-OS binary directly (upstream 404 workaround)' }
if ($sendSrc -match 'function Install-Thruflux' -and $sendSrc -match '.local/bin' -and $sendSrc -match 'thru.exe') { Pass 'Install-Thruflux drops the binary into ~/.local/bin (thru.exe on Windows)' } else { Fail 'Install-Thruflux drops the binary into ~/.local/bin (thru.exe on Windows)' }
if ($sendSrc -match 'install_linux.sh' -and $sendSrc -match '404') { Pass 'code comments document the broken upstream installer URL (404)' } else { Fail 'code comments document the broken upstream installer URL (404)' }
if ($sendSrc -match '\$script:SendArchive = \$Tokens\[\$i\+1\]' -and $sendSrc -match '\$script:ReceiveCode = \$Tokens\[\$i\+1\]') { Pass 'Parse-Args captures send/receive positionals' } else { Fail 'Parse-Args captures send/receive positionals' }

# 10. Snapshot prompts to stop a running node (source-grep on node.ps1)
Write-Host ''
Write-Host '10. Snapshot prompt-to-stop wiring:'
$invokeSnap = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($invokeSnap -match 'Test-StdinInteractive' -and $invokeSnap -match 'Read-YesNo "derod is running on' -and $invokeSnap -match 'Stop-Node') { Pass 'Invoke-Snapshot prompts to stop a running node' } else { Fail 'Invoke-Snapshot prompts to stop a running node' }
if ($invokeSnap -match 'Start-ExternalNode' -and $invokeSnap -match 'Install-Service') { Pass 'Invoke-Snapshot restarts after snapshot (external + managed)' } else { Fail 'Invoke-Snapshot restarts after snapshot (external + managed)' }
if ($invokeSnap -match 'Test-SnapshotRunningOnDataDir' -and $invokeSnap -match 'SnapshotKeepRunning') { Pass 'Invoke-Snapshot keeps library guard condition' } else { Fail 'Invoke-Snapshot keeps library guard condition' }
if ($invokeSnap -match 'Get-LatestSnapshotArchive' -and $invokeSnap -match 'Read-YesNo "Latest snapshot:' -and $invokeSnap -match 'keeping existing snapshot') { Pass 'Invoke-Snapshot confirms new snapshot when one exists' } else { Fail 'Invoke-Snapshot confirms new snapshot when one exists' }
$invokeRest = Get-Content (Join-Path $ProjectDir 'node.ps1') -Raw
if ($invokeRest -match 'Restore-Snapshot' -and $invokeRest -match 'Read-YesNo ''Restore complete\. Start the node now\?''' -and $invokeRest -match 'Start-Node') { Pass 'Invoke-Restore offers to start the node after restore' } else { Fail 'Invoke-Restore offers to start the node after restore' }
if ($invokeRest -match 'SnapshotYes' -and $invokeRest -match 'Test-StdinInteractive') { Pass 'Invoke-Restore start prompt is interactive + no --yes only' } else { Fail 'Invoke-Restore start prompt is interactive + no --yes only' }
$snapLib = Get-Content (Join-Path $ProjectDir 'lib/snapshot.ps1') -Raw
if ($snapLib -match 'function Test-StdinInteractive') { Pass 'lib/snapshot.ps1 defines Test-StdinInteractive' } else { Fail 'lib/snapshot.ps1 defines Test-StdinInteractive' }
if ($snapLib -match 'function Get-SnapshotArchiveStamp') { Pass 'lib/snapshot.ps1 defines Get-SnapshotArchiveStamp' } else { Fail 'lib/snapshot.ps1 defines Get-SnapshotArchiveStamp' }

Write-Host ''
Write-Host "=== results: $PASS passed, $FAIL failed ==="
exit $(if ($FAIL -eq 0) { 0 } else { 1 })