# node.ps1 — deronode runner (PowerShell 7 / 5.1). Mirrors node.sh's CLI.

$script:DeronodeVersion = '1.0.0'
$script:InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LibDir = Join-Path $script:InstallDir 'lib'
$script:BinDir = Join-Path $script:InstallDir 'bin'
$script:ConfigFile = Join-Path $script:InstallDir 'config.json'
$script:CatalogFile = Join-Path $script:InstallDir 'catalog.json'
$script:BinaryPath = Join-Path $script:BinDir 'derod/derod'

. (Join-Path $script:LibDir 'platform.ps1')
$script:Platform = Get-PwshPlatform

. (Join-Path $script:LibDir 'ui.ps1')
. (Join-Path $script:LibDir 'config.ps1')
. (Join-Path $script:LibDir 'download.ps1')
. (Join-Path $script:LibDir 'rpc.ps1')
. (Join-Path $script:LibDir 'service.ps1')
. (Join-Path $script:LibDir 'snapshot.ps1')

if (Test-IsTermux) {
    Write-Host "[x] derod's glibc binaries do not run on Termux/Android." -ForegroundColor Red
    Write-Host "    Use deromine (bash fallback) for mining instead." -ForegroundColor DarkGray
    exit 1
}

$Action = 'menu'
$AsService = $false
$DryRun = $false
$Reconfigure = $false
$script:SnapshotOut = ''
$script:SnapshotFrom = ''
$script:SnapshotMaxRatio = $false
$script:SnapshotKeepRunning = $false
$script:SnapshotYes = $false

function Show-Help {
    @'
Usage: deronode [command] [options]
  cross-platform DERO node installer & manager (derod only)

  Flag values accept both --flag=value and --flag value.

  Commands:
    start                Run derod (--service to install/start a background service)
    stop                 Stop derod
    status               Show sync status, binary tag, paths
    update               Fetch the latest DEROFDN release; restart if running
    snapshot             Create a privacy-hardened tar.zst of the chain state
    restore              Restore chain state from a snapshot (stops the node)
    --reconfigure        Re-run the first-run prompts (incl. data-dir / log-dir)

  Options:
    --dry-run            Resolve/download nothing; print the derod argv and exit
    --config=<path>      Config file (default ./config.json)
    --integrator-address=<addr>  10% rewards address
    --sync-profile=<p>   pruned | full | none (shortcut for fastsync/prune)
    --fastsync           Enable fast sync (bootstrap only)
    --no-fastsync        Disable fast sync
    --prune-history=<n>  Prune history to this topo height
    --node-tag=<name>    Public node identifier
    --getwork-bind=<ip:port>      Miner endpoint (default 127.0.0.1:10100)
    --data-dir=<dir>     Blockchain data location (configurable)
    --log-dir=<dir>      Log location (configurable)
    --rpc-bind=<ip:port> Daemon JSON-RPC (default 127.0.0.1:10102)
    --p2p-bind=<ip:port> P2P listen (default 0.0.0.0:10101)
    --min-peers=<n>      Target minimum peers
    --max-peers=<n>      Maximum peers
    --socks-proxy=<socks_ip:port> Route P2P through a proxy
    --add-priority-node=<ip:port>   Maintain a persistent connection (repeatable)
    --add-exclusive-node=<ip:port>  Connect to this peer only (repeatable)
    --clog-level=<0-127> Console log level
    --flog-level=<0-127> File log level
    --testnet            Run on testnet (swaps default ports)
    --debug              Verbose logging
    --time-is-in-sync    Tell the daemon the clock is correct
    --sync-node          Force sync from seed nodes
    --extra-arg=<raw>    Append a raw derod argument (repeatable)
    --level=<n>          Snapshot zstd level (default 10; --max-ratio forces 19)
    --max-ratio          Snapshot at maximum compression (zstd level 19)
    --out=<dir>          Snapshot output dir (overrides snapshot_dir)
    --keep-running       Allow snapshot while derod runs on this data dir
    --from=<archive>     Archive to restore (restore)
    --yes                Skip snapshot/restore confirmations
    --version | -h       Version / help
'@
}

function Set-CliValue {
    param([string]$Key, [string]$Val)
    $script:CFG[$Key] = $Val
}

function Parse-Args {
    param([string[]]$Tokens)
    $norm = New-Object System.Collections.Generic.List[string]
    $valFlags = @('--integrator-address', '--sync-profile', '--prune-history', '--node-tag',
        '--getwork-bind', '--data-dir', '--log-dir', '--rpc-bind', '--p2p-bind', '--min-peers',
        '--max-peers', '--socks-proxy', '--add-priority-node', '--add-exclusive-node',
        '--clog-level', '--flog-level', '--config', '--extra-arg', '--level', '--out', '--from')
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $a = $Tokens[$i]
        if ($valFlags -contains $a) {
            if ($i + 1 -ge $Tokens.Count) { Write-Host "[x] Missing value for $a" -ForegroundColor Red; exit 1 }
            $norm.Add("$a=$($Tokens[$i+1])"); $i++
        } else { $norm.Add($a) }
    }
    foreach ($a in $norm) {
        $key = $a; $val = ''
        if ($a -like '--*=*') { $key = $a.Substring(0, $a.IndexOf('=')); $val = $a.Substring($a.IndexOf('=') + 1) }
        switch ($key) {
            '--integrator-address' { Set-CliValue 'integrator_address' $val }
            '--sync-profile' { Set-SyncProfile $val }
            '--fastsync' { $script:CFG.fastsync = $true }
            '--no-fastsync' { $script:CFG.fastsync = $false }
            '--prune-history' { if ($val) { $script:CFG.prune_history = [int]$val } }
            '--node-tag' { Set-CliValue 'node_tag' $val }
            '--getwork-bind' { Set-CliValue 'getwork_bind' $val }
            '--data-dir' { Set-CliValue 'data_dir' $val; Resolve-Paths }
            '--log-dir' { Set-CliValue 'log_dir' $val; Resolve-Paths }
            '--rpc-bind' { Set-CliValue 'rpc_bind' $val }
            '--p2p-bind' { Set-CliValue 'p2p_bind' $val }
            '--min-peers' { if ($val) { $script:CFG.min_peers = [int]$val } }
            '--max-peers' { if ($val) { $script:CFG.max_peers = [int]$val } }
            '--socks-proxy' { Set-CliValue 'socks_proxy' $val }
            '--add-priority-node' { $script:CFG.add_priority_node += $val }
            '--add-exclusive-node' { $script:CFG.add_exclusive_node += $val }
            '--clog-level' { if ($val) { $script:CFG.clog_level = [int]$val } }
            '--flog-level' { if ($val) { $script:CFG.flog_level = [int]$val } }
            '--testnet' { $script:CFG.testnet = $true }
            '--debug' { $script:CFG.debug = $true }
            '--time-is-in-sync' { $script:CFG.time_is_in_sync = $true }
            '--sync-node' { $script:CFG.sync_node = $true }
            '--extra-arg' { if ($val) { $script:CFG.extra_args += $val } }
            '--level' { if ($val) { $script:CFG.snapshot_level = [int]$val } }
            '--max-ratio' { $script:SnapshotMaxRatio = $true }
            '--out' { if ($val) { $script:SnapshotOut = $val } }
            '--keep-running' { $script:SnapshotKeepRunning = $true }
            '--from' { if ($val) { $script:SnapshotFrom = $val } }
            '--yes' { $script:SnapshotYes = $true }
            '--config' { $script:ConfigFile = $val }
            '--dry-run' { $script:DryRun = $true; if ($script:Action -eq 'menu') { $script:Action = 'start' } }
            '--service' { $script:AsService = $true }
            '--reconfigure' { $script:Reconfigure = $true; $script:Action = 'reconfigure' }
            '--version' { Write-Host "deronode $($script:DeronodeVersion)"; exit 0 }
            '-h' { Show-Help; exit 0 }
            '--help' { Show-Help; exit 0 }
            'help' { Show-Help; exit 0 }
            'start' { $script:Action = 'start' }
            'stop' { $script:Action = 'stop' }
            'status' { $script:Action = 'status' }
            'update' { $script:Action = 'update' }
            'snapshot' { $script:Action = 'snapshot' }
            'restore' { $script:Action = 'restore' }
            default { Write-Host "[x] Unknown: $a" -ForegroundColor Red; exit 1 }
        }
    }
}

function Confirm-Disk {
    $need = 0
    switch ($script:CFG.sync_profile) {
        'pruned' { $need = 50 }
        'full' { $need = 230 }
    }
    if ($need -eq 0) { return }
    if ($IsWindows) { return }
    $free = [int]((& df -Pk $script:DataDirReal 2>$null | Select-Object -Skip 1).ToString().Split(@(' '), [StringSplitOptions]::RemoveEmptyEntries)[3])
    if ($free -and $free -lt ($need * 1024 * 1024)) {
        Write-Host "[!] ~$need GB recommended for '$($script:CFG.sync_profile)' but $script:DataDirReal shows ~$([int]($free/1024/1024)) GB free." -ForegroundColor Yellow
        if (-not (Read-YesNo 'Continue anyway?' 'n')) { Write-Host '[x] Aborted.' -ForegroundColor Red; exit 1 }
    }
}

function Configure {
    Write-Host '[*] derod configuration' -ForegroundColor DarkCyan
    Write-Host ''
    $ia = Read-Ask 'Integrator address (dero1.../deto1..., empty = dev address)' $script:CFG.integrator_address
    $script:CFG.integrator_address = $ia
    if (-not $ia) { Write-Host '[!] No integrator address: integrator-block rewards go to the upstream dev address.' -ForegroundColor Yellow }

    Write-Host ''
    Write-Host '  Sync profile:'
    Write-Host '    1) Pruned VPS   --fastsync --prune-history=100000  (~50 GB) [recommended]'
    Write-Host '    2) Full archival  no prune, full history from genesis (230 GB+, plan 500 GB)'
    Write-Host '    3) Custom       keep whatever --fastsync/--prune-history are set to'
    $pick = Read-Ask 'Choose' '1'
    if ($pick -eq '2') { Set-SyncProfile 'full' }
    elseif ($pick -ne '3') { Set-SyncProfile 'pruned' }

    Write-Host ''
    $script:CFG.node_tag = Read-Ask 'Node tag (public name, optional)' $script:CFG.node_tag

    Write-Host ''
    Write-Host '  GETWORK (miner endpoint, port 10100):'
    Write-Host '    1) This machine only  127.0.0.1:10100  (default)'
    Write-Host '    2) Off-host miners    0.0.0.0:10100   (open 10100/tcp on the firewall)'
    Write-Host '    3) Custom'
    $pick = Read-Ask 'Choose' '1'
    if ($pick -eq '2') { $script:CFG.getwork_bind = '0.0.0.0:10100' }
    elseif ($pick -eq '3') { $script:CFG.getwork_bind = Read-Ask 'GETWORK bind' $script:CFG.getwork_bind }
    else { $script:CFG.getwork_bind = '127.0.0.1:10100' }

    Write-Host ''
    if (Test-Path $script:ConfigFile) {
        Write-Host '  Paths (Enter keeps current):'
        $script:CFG.data_dir = Read-Ask 'Data dir' $script:DataDirReal
        $script:CFG.log_dir = Read-Ask 'Log dir' $script:LogDirReal
        Resolve-Paths
    } elseif (Read-YesNo 'Configure data-dir / log-dir now? (advanced)' 'n') {
        $script:CFG.data_dir = Read-Ask 'Data dir' (Join-Path $script:InstallDir 'chain')
        $script:CFG.log_dir = Read-Ask 'Log dir' (Join-Path $script:InstallDir 'logs')
        Resolve-Paths
    } else {
        Resolve-Paths
    }

    Apply-TestnetDefaults
    Export-Config
    Confirm-Disk
    Write-Host "[*] Saved $($script:ConfigFile)" -ForegroundColor Green
}

function Ensure-Binary {
    if (-not (Resolve-Release $script:Platform)) { return $false }
    if (Test-CacheFresh) { return $true }
    return (Invoke-FetchDerod $script:Platform)
}

function Show-Menu {
    Write-Banner $script:DeronodeVersion
    if (-not (Test-Path $script:BinaryPath) -and -not (Test-NodeRunning) -and -not (Test-ExternalInstalled)) {
        Write-Host '  No derod installed yet.'
        Write-Host ''
        Write-Host '  [1] Configure & install derod'
        Write-Host '  [q] Quit'
        $a = Read-Ask 'Choose' '1'
        if ($a -eq '1' -or $a -eq '') {
            if (-not (Test-Path $script:ConfigFile)) { Configure }
            if (-not (Ensure-Binary)) { exit 1 }
        } else { exit 0 }
    }
    while ($true) {
        Write-NodeStatus (Join-Path $script:BinDir 'derod')
        Write-Host ''
        Write-Host '  1) Start (foreground)'
        Write-Host '  2) Start as background service'
        Write-Host '  3) Stop'
        Write-Host '  4) Status'
        Write-Host '  5) Update derod'
        Write-Host '  6) Reconfigure'
        Write-Host '  7) Show command line (dry-run)'
        Write-Host '  8) Snapshot chain state (tar.zst)'
        Write-Host '  9) Restore chain state from snapshot'
        Write-Host '  q) Quit'
        $a = Read-Ask 'Choose' ''
        switch ($a) {
            '1' { $script:Action = 'start'; $script:AsService = $false; return }
            '2' { $script:Action = 'start'; $script:AsService = $true; return }
            '3' { $script:Action = 'stop'; return }
            '4' { $script:Action = 'status'; return }
            '5' { $script:Action = 'update'; return }
            '6' { $script:Action = 'reconfigure'; return }
            '7' { $script:Action = 'start'; $script:DryRun = $true; return }
            '8' { $script:Action = 'snapshot'; return }
            '9' { $script:Action = 'restore'; return }
            'q' { exit 0 }
            default { Write-Host '[x] Unknown choice' -ForegroundColor Red }
        }
    }
}

function Start-Node {
    if ($script:DryRun) {
        Resolve-Paths
        Apply-TestnetDefaults
        $argv = Build-DerodArgv
        Write-Host 'derod command line:' -ForegroundColor DarkGray
        Write-Host "  $($script:BinaryPath) $($argv -join ' ')"
        exit 0
    }
    if (Test-ExternalInstalled) {
        Start-ExternalNode
        return
    }
    if (-not (Test-Path $script:ConfigFile)) { Configure }
    if (-not (Ensure-Binary)) { exit 1 }
    Apply-TestnetDefaults
    $argv = Build-DerodArgv
    New-Item -ItemType Directory -Path $script:DataDirReal, $script:LogDirReal -Force | Out-Null
    if ($script:AsService) {
        Install-Service
    } else {
        & $script:BinaryPath @argv
        exit $LASTEXITCODE
    }
}

function Stop-Node {
    if (Test-ExternalInstalled) {
        Stop-ExternalNode
        return
    }
    Stop-Service
}

# Start-ExternalNode — start a system-installed (external) derod via its systemd
# unit (sudo when system-level). No-op when already running.
function Start-ExternalNode {
    $unit = Get-ExternalUnit
    if (Test-NodeRunning) {
        if (-not $unit) { $unit = 'derod.service' }
        Write-Host "[*] external derod already running ($unit)" -ForegroundColor DarkCyan
        return
    }
    if (-not $unit) { Write-Host '[x] No external derod unit found' -ForegroundColor Red; exit 1 }
    Write-Host "[*] starting $unit..." -ForegroundColor DarkCyan
    if (Test-ExternalSystemUnit) {
        & sudo -n systemctl start $unit 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit started" -ForegroundColor Green; return }
        if (-not [Console]::IsInputRedirected) {
            & sudo systemctl start $unit
            if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit started" -ForegroundColor Green; return }
        }
        Write-Host "[!] could not start $unit (needs sudo) - run: sudo systemctl start $unit" -ForegroundColor Yellow
        exit 1
    }
    & systemctl --user start $unit 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit started" -ForegroundColor Green; return }
    Write-Host "[!] could not start $unit - run: systemctl --user start $unit" -ForegroundColor Yellow
    exit 1
}

# Stop-ExternalNode — stop a system-installed (external) derod: resolve its unit
# and stop via systemd (sudo when system-level), else kill the bare process
# directly. Works whether the node is running or already stopped.
function Stop-ExternalNode {
    $unit = Get-ExternalUnit
    if ($unit) {
        Write-Host "[*] stopping $unit..." -ForegroundColor DarkCyan
        if (Test-ExternalSystemUnit) {
            & sudo -n systemctl stop $unit 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit stopped" -ForegroundColor Green; return }
            if (-not [Console]::IsInputRedirected) {
                & sudo systemctl stop $unit
                if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit stopped" -ForegroundColor Green; return }
            }
            Write-Host "[!] could not stop $unit (needs sudo) - run: sudo systemctl stop $unit" -ForegroundColor Yellow
            exit 1
        }
        & systemctl --user stop $unit 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit stopped" -ForegroundColor Green; return }
        Write-Host "[!] could not stop $unit - run: systemctl --user stop $unit" -ForegroundColor Yellow
        exit 1
    }
    $proc = Get-ProcessTable | Where-Object { $_.Name -like 'derod*' } | Select-Object -First 1
    if (-not $proc) { Write-Host '[*] no external derod running' -ForegroundColor DarkGray; return }
    Stop-Process -Id $proc.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    if (Get-Process -Id $proc.Pid -ErrorAction SilentlyContinue) {
        Write-Host "[!] could not stop external derod (pid $($proc.Pid)) - no permission? stop it manually." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "[*] stopped external derod (pid $($proc.Pid))" -ForegroundColor Green
}
function Show-Status {
    Write-Banner $script:DeronodeVersion
    if ((Test-NodeRunning) -or (Test-Path $script:BinaryPath) -or (Test-ExternalInstalled)) {
        Write-NodeStatus (Join-Path $script:BinDir 'derod')
    } else {
        Write-Host "  derod is not installed. Run 'deronode' or 'deronode start'." -ForegroundColor DarkGray
        exit 0
    }
}
function Update-Node {
    if (-not (Resolve-Release $script:Platform)) { exit 1 }
    $old = 'none'
    $tagfile = Join-Path $script:BinDir 'derod/.tag'
    if (Test-Path $tagfile) { $old = (Get-Content $tagfile -Raw).Trim() }
    if (Test-CacheFresh) { Write-Host "[*] Already at latest ($($script:LastTag))." -ForegroundColor Green; return }
    $runRel = Get-DaemonReleaseNumber
    $latestRel = if ($script:LastTag -match '(\d+)$') { $matches[1] } else { '' }
    if ($runRel -and $latestRel -and $runRel -eq $latestRel) {
        Write-Host "[*] Already at latest ($($script:LastTag))." -ForegroundColor Green
        return
    }
    Write-Host "[*] Updating derod $old -> $($script:LastTag)" -ForegroundColor DarkCyan
    if (Test-ExternalNode) {
        Update-ExternalNode
        return
    }
    $wasRunning = Test-NodeRunning
    if ($wasRunning) { Stop-Service }
    if (-not (Invoke-FetchDerod $script:Platform)) { exit 1 }
    if ($wasRunning) { Write-Host '[*] restarting with the new binary...' -ForegroundColor DarkCyan; Install-Service }
}

function Update-ExternalNode {
    $proc = Get-ProcessTable | Where-Object { $_.Name -like 'derod*' } | Select-Object -First 1
    if (-not $proc) { Write-Host '[x] Could not find the running derod process' -ForegroundColor Red; exit 1 }
    $bin = ''
    if ($IsLinux -and (Test-Path "/proc/$($proc.Pid)/exe")) {
        $bin = (Get-Item "/proc/$($proc.Pid)/exe").Target
        $bin = $bin -replace ' \(deleted\)$', ''
    }
    if (-not $bin -or -not (Test-Path $bin)) { Write-Host '[x] Could not resolve the running derod binary path' -ForegroundColor Red; exit 1 }

    if (-not (Invoke-FetchDerod $script:Platform)) { exit 1 }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item $bin "$bin.bak-$ts" -Force -ErrorAction Stop
    Write-Host "[*] backed up $bin -> $bin.bak-$ts" -ForegroundColor DarkCyan
    $tmp = "$bin.new-$ts"
    try {
        Copy-Item $script:BinaryPath $tmp -Force -ErrorAction Stop
        Move-Item -Force $tmp $bin
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Host "[x] Replace failed: $bin ($($_.Exception.Message))" -ForegroundColor Red
        exit 1
    }
    if ($IsWindows) { } else { & chmod +x $bin }
    Write-Host "[*] replaced $bin with $($script:LastTag)" -ForegroundColor Green

    $unit = ''
    if ($IsLinux) {
        $unit = (Get-Content "/proc/$($proc.Pid)/cgroup" -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '\.service$' } | Select-Object -First 1)
        if ($unit) { $unit = ($unit -split '/')[-1] }
    }
    if ($unit) {
        Write-Host "[*] restarting $unit..." -ForegroundColor DarkCyan
        & sudo -n systemctl restart $unit 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[*] $unit restarted with $($script:LastTag)" -ForegroundColor Green
        } else {
            Write-Host "[!] $unit is a system unit - restart it manually: sudo systemctl restart $unit" -ForegroundColor Yellow
        }
    } else {
        Write-Host '[!] external node has no systemd unit - restart it manually' -ForegroundColor Yellow
    }
}
function Reconfigure-Node { Configure; Write-Host '[*] Done. Run deronode start to launch.' -ForegroundColor Green }

function Invoke-Snapshot {
    Resolve-Paths
    $script:SnapshotDir = if ($script:SnapshotOut) { $script:SnapshotOut } else { $script:SnapshotDirReal }
    if (-not (New-Snapshot)) { exit 1 }
}
function Invoke-Restore {
    Resolve-Paths
    if (-not (Restore-Snapshot)) { exit 1 }
}

for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--config') { if ($i + 1 -lt $args.Count) { $script:ConfigFile = $args[$i+1] }; break }
    elseif ($args[$i] -like '--config=*') { $script:ConfigFile = $args[$i].Substring(9); break }
}
Import-Config
Parse-Args $args

switch ($script:Action) {
    'reconfigure' { Reconfigure-Node }
    'start' { Start-Node }
    'stop' { Stop-Node }
    'status' { Show-Status }
    'update' { Update-Node }
    'snapshot' { Invoke-Snapshot }
    'restore' { Invoke-Restore }
    default {
        Show-Menu
        switch ($script:Action) {
            'start' { Start-Node }
            'stop' { Stop-Node }
            'status' { Show-Status }
            'update' { Update-Node }
            'snapshot' { Invoke-Snapshot }
            'restore' { Invoke-Restore }
            'reconfigure' { Reconfigure-Node }
        }
    }
}