# lib/config.ps1 — load/save/validate config.json and build the derod argv.

$script:CFG = [ordered]@{
    integrator_address = ''
    sync_profile       = 'pruned'
    fastsync           = $true
    prune_history      = 100000
    node_tag           = ''
    getwork_bind       = '127.0.0.1:10100'
    data_dir           = ''
    log_dir            = ''
    rpc_bind           = '127.0.0.1:10102'
    p2p_bind           = '0.0.0.0:10101'
    min_peers          = $null
    max_peers          = $null
    socks_proxy        = ''
    add_priority_node  = @()
    add_exclusive_node = @()
    clog_level         = $null
    flog_level         = $null
    testnet            = $false
    debug              = $false
    time_is_in_sync    = $false
    sync_node          = $false
    extra_args         = @()
    snapshot_dir       = ''
    snapshot_level     = 10
}
$script:DataDirReal = ''
$script:LogDirReal  = ''
$script:SnapshotDirReal = ''

function Resolve-Paths {
    $script:DataDirReal = if ($script:CFG.data_dir) { $script:CFG.data_dir } else { Join-Path $InstallDir 'chain' }
    $script:LogDirReal  = if ($script:CFG.log_dir)  { $script:CFG.log_dir }  else { Join-Path $InstallDir 'logs' }
    if ($script:CFG.snapshot_dir) {
        $script:SnapshotDirReal = $script:CFG.snapshot_dir
    } else {
        # Same tree as the derod binary/install (bin/derod/derod sits under
        # InstallDir) — snapshots live next to the node, not in the old
        # ~/Crypto/dero external-node path.
        $script:SnapshotDirReal = Join-Path $InstallDir 'snapshots'
    }
}

function Import-Config {
    if (-not (Test-Path $ConfigFile)) { Resolve-Paths; return }
    try {
        $j = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    } catch { Resolve-Paths; return }
    foreach ($p in $j.PSObject.Properties) {
        if ($script:CFG.Contains($p.Name)) { $script:CFG[$p.Name] = $p.Value }
    }
    Resolve-Paths
}

function Apply-TestnetDefaults {
    if (-not $script:CFG.testnet) { return }
    if ($script:CFG.rpc_bind     -eq '127.0.0.1:10102') { $script:CFG.rpc_bind     = '127.0.0.1:40402' }
    if ($script:CFG.p2p_bind     -eq '0.0.0.0:10101')   { $script:CFG.p2p_bind     = '0.0.0.0:40401' }
    if ($script:CFG.getwork_bind -eq '127.0.0.1:10100') { $script:CFG.getwork_bind = '127.0.0.1:40400' }
}

function Set-SyncProfile {
    param([string]$Profile)
    switch ($Profile) {
        'minimal'  { $script:CFG.sync_profile = 'minimal';  $script:CFG.fastsync = $true; $script:CFG.prune_history = 5000 }
        'compact'  { $script:CFG.sync_profile = 'compact';  $script:CFG.fastsync = $true; $script:CFG.prune_history = 10000 }
        'standard' { $script:CFG.sync_profile = 'standard'; $script:CFG.fastsync = $true; $script:CFG.prune_history = 20000 }
        'balanced' { $script:CFG.sync_profile = 'balanced'; $script:CFG.fastsync = $true; $script:CFG.prune_history = 100000 }
        'pruned'   { $script:CFG.sync_profile = 'balanced'; $script:CFG.fastsync = $true; $script:CFG.prune_history = 100000 } # alias for backwards compat
        'full'   { $script:CFG.sync_profile = 'full';   $script:CFG.fastsync = $false; $script:CFG.prune_history = $null }
        'none'   { $script:CFG.sync_profile = 'none';   $script:CFG.fastsync = $false; $script:CFG.prune_history = $null }
        default  { throw "sync-profile must be minimal|compact|standard|balanced|full|none|custom (pruned is alias for balanced)" }
    }
}

function Export-Config {
    $dir = Split-Path -Parent $ConfigFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:CFG | ConvertTo-Json -Depth 4 | Set-Content $ConfigFile -Encoding UTF8
}

# Lowest block height still present in bltx_store, or $null. derod names block
# files <hash>.block_<difficulty>_<snapshot_version>_<height> (see storefs.go).
# A completed --prune-history deletes everything below the prune point, leaving
# only the genesis block (height 0) plus a rolling window of recent blocks near
# the tip — so the lowest remaining height above genesis is the prune floor.
# Height 0 must be excluded: genesis is always kept, so including it would make
# every pruned chain look unpruned.
function Get-ChainMinBlockHeight {
    $bltx = Join-Path $script:DataDirReal 'mainnet/bltx_store'
    if (-not (Test-Path $bltx)) { return $null }
    $min = $null
    Get-ChildItem -Path $bltx -Recurse -File -Filter '*.block_*' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '\.block_\d+_\d+_(\d+)$') {
            $h = [int64]$Matches[1]
            # Genesis (height 0) is always kept after a prune — exclude it, or
            # every pruned chain would look unpruned.
            if ($h -ne 0 -and ($null -eq $min -or $h -lt $min)) { $min = $h }
        }
    }
    return $min
}

function Build-DerodArgv {
    $argv = New-Object System.Collections.Generic.List[string]
    if ($script:CFG.testnet) { $argv.Add('--testnet') }
    if ($script:CFG.debug) { $argv.Add('--debug') }
    if ($script:CFG.time_is_in_sync) { $argv.Add('--timeisinsync') }
    if ($script:CFG.sync_node) { $argv.Add('--sync-node') }
    # fastsync is a bootstrap-only flag — derod only honors it while the chain
    # is fresh, and re-running it on a synced chain redoes the fastsync
    # bootstrap. Once the chain has blocks (topo.map exists) drop it; use
    # 'deronode resync' to force a fresh bootstrap.
    if ($script:CFG.fastsync) {
        $topoMap = Join-Path $script:DataDirReal 'mainnet/topo.map'
        if (Test-Path $topoMap) {
            Write-Host "[!] chain already bootstrapped at $($script:DataDirReal) - skipping --fastsync (use 'deronode resync' to re-bootstrap)" -ForegroundColor Yellow
        } else {
            $argv.Add('--fastsync')
        }
    }
    # derod refuses --prune-history on a chain with <50 blocks and exits
    # ("We need atleast 50 blocks to prune"). Defer it until the fastsync
    # bootstrap has produced blocks (topo.map exists in the chain dir).
    if ($script:CFG.prune_history) {
        $topoMap = Join-Path $script:DataDirReal 'mainnet/topo.map'
        if (Test-Path $topoMap) {
            $minH = Get-ChainMinBlockHeight
            # Prune is a one-shot rewrite: once the oldest retained (non-genesis)
            # block is already at/above the prune point, re-passing
            # --prune-history would make derod redo the whole multi-hour rewrite
            # on every start for nothing. Allow a 1000-block margin for the
            # rolling window derod keeps near the tip.
            if ($null -ne $minH -and $minH -ge ($script:CFG.prune_history - 1000)) {
                Write-Host "[!] chain at $($script:DataDirReal) already pruned to topo ~$minH - skipping --prune-history (raise --prune-history to re-prune)" -ForegroundColor Yellow
            } else {
                $argv.Add("--prune-history=$($script:CFG.prune_history)")
            }
        } else {
            Write-Host "[!] fresh chain at $($script:DataDirReal) - deferring --prune-history until the chain has blocks" -ForegroundColor Yellow
        }
    }
    if ($script:CFG.socks_proxy) { $argv.Add("--socks-proxy=$($script:CFG.socks_proxy)") }
    if ($script:DataDirReal) { $argv.Add("--data-dir=$($script:DataDirReal)") }
    if ($script:CFG.p2p_bind) { $argv.Add("--p2p-bind=$($script:CFG.p2p_bind)") }
    if ($script:CFG.rpc_bind) { $argv.Add("--rpc-bind=$($script:CFG.rpc_bind)") }
    if ($script:CFG.getwork_bind) { $argv.Add("--getwork-bind=$($script:CFG.getwork_bind)") }
    foreach ($n in $script:CFG.add_priority_node) { $argv.Add("--add-priority-node=$n") }
    foreach ($n in $script:CFG.add_exclusive_node) { $argv.Add("--add-exclusive-node=$n") }
    if ($script:CFG.min_peers) { $argv.Add("--min-peers=$($script:CFG.min_peers)") }
    if ($script:CFG.max_peers) { $argv.Add("--max-peers=$($script:CFG.max_peers)") }
    if ($script:CFG.node_tag) { $argv.Add("--node-tag=$($script:CFG.node_tag)") }
    if ($script:CFG.integrator_address) { $argv.Add("--integrator-address=$($script:CFG.integrator_address)") }
    if ($script:CFG.clog_level) { $argv.Add("--clog-level=$($script:CFG.clog_level)") }
    if ($script:CFG.flog_level) { $argv.Add("--flog-level=$($script:CFG.flog_level)") }
    if ($script:LogDirReal) { $argv.Add("--log-dir=$($script:LogDirReal)") }
    foreach ($a in $script:CFG.extra_args) { $argv.Add($a) }
    return $argv
}