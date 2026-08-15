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
    } elseif ($HOME) {
        $script:SnapshotDirReal = Join-Path $HOME 'Crypto/dero/snapshots'
    } else {
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
        'pruned' { $script:CFG.sync_profile = 'pruned'; $script:CFG.fastsync = $true; $script:CFG.prune_history = 100000 }
        'full'   { $script:CFG.sync_profile = 'full';   $script:CFG.fastsync = $false; $script:CFG.prune_history = $null }
        'none'   { $script:CFG.sync_profile = 'none';   $script:CFG.fastsync = $false; $script:CFG.prune_history = $null }
        default  { throw "sync-profile must be pruned|full|none" }
    }
}

function Export-Config {
    $dir = Split-Path -Parent $ConfigFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:CFG | ConvertTo-Json -Depth 4 | Set-Content $ConfigFile -Encoding UTF8
}

function Build-DerodArgv {
    $argv = New-Object System.Collections.Generic.List[string]
    if ($script:CFG.testnet) { $argv.Add('--testnet') }
    if ($script:CFG.debug) { $argv.Add('--debug') }
    if ($script:CFG.time_is_in_sync) { $argv.Add('--timeisinsync') }
    if ($script:CFG.sync_node) { $argv.Add('--sync-node') }
    if ($script:CFG.fastsync) { $argv.Add('--fastsync') }
    if ($script:CFG.prune_history) { $argv.Add("--prune-history=$($script:CFG.prune_history)") }
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