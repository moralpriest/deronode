# node.ps1 — deronode runner (PowerShell 7 / 5.1). Mirrors node.sh's CLI.

$script:DeronodeVersion = '1.4.3'
$script:InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LibDir = Join-Path $script:InstallDir 'lib'
$script:BinDir = Join-Path $script:InstallDir 'bin'
$script:ConfigFile = Join-Path $script:InstallDir 'config.json'
$script:CatalogFile = Join-Path $script:InstallDir 'catalog.json'

. (Join-Path $script:LibDir 'platform.ps1')
$script:Platform = Get-PwshPlatform
# Windows cannot execute an extensionless file — CreateProcess/ShellExecute
# fail or pop the "How do you want to open this file?" dialog — so the managed
# binary is derod.exe there. Defined after platform.ps1 (needs $script:IsWindows).
$script:BinaryName = if ($script:IsWindows) { 'derod.exe' } else { 'derod' }
$script:BinaryPath = Join-Path $script:BinDir "derod/$($script:BinaryName)"

. (Join-Path $script:LibDir 'ui.ps1')
. (Join-Path $script:LibDir 'config.ps1')
. (Join-Path $script:LibDir 'download.ps1')
. (Join-Path $script:LibDir 'build.ps1')
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
$script:MenuMode = $false   # true while driving the interactive menu (loop back after each action)
$script:SnapshotOut = ''
$script:SnapshotFrom = ''
$script:SnapshotMaxRatio = $false
$script:SnapshotKeepRunning = $false
$script:SnapshotYes = $false
$script:UpdateSource = 'release'   # update source: release (download) | dev (community-dev compile)
$script:SendArchive = ''           # archive to share with thruflux (default: newest snapshot)
$script:ReceiveCode = ''           # thruflux join code to receive

function Show-Help {
    @'
Usage: deronode [command] [options]
  cross-platform DERO node installer & manager (derod only)

  Flag values accept both --flag=value and --flag value.

  Commands:
    start                Run derod (--service to install/start a background service)
    stop                 Stop derod
    status               Show sync status, binary tag, paths
    update               Update derod; restart if running. --source=release (default,
                         download) or --source=dev (compile latest community-dev)
    build                Compile the latest community-dev source branch (Go required)
    snapshot             Create a privacy-hardened tar.zst of the chain state
    restore              Restore chain state from a snapshot (stops the node)
    resync               Wipe the chain and re-bootstrap via --fastsync
    logs                 Tail the node log (derod.log; follows live)
    uninstall            Remove derod + all node data (binary, chain, logs,
                         snapshots, config); keeps deronode itself
    send [<archive>]     Share a snapshot (or any file) with a friend via
                         thruflux: thru host, prints a join code (fast, encrypted
                         QUIC P2P). Defaults to the newest snapshot.
    receive <code>       Receive a thruflux transfer: thru join <code>
    --reconfigure        Re-run the first-run prompts (incl. data-dir / log-dir)

  Options:
    --dry-run            Resolve/download nothing; print the derod argv and exit
    --config=<path>      Config file (default ./config.json)
    --source=release|dev Update source (release download or community-dev compile)
    --integrator-address=<addr>  10% rewards address
    --sync-profile=<p>   pruned (Recommended, ~50 GB) | full (Archival) | none (shortcut for fastsync/prune)
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
    --out=<dir>          Snapshot output dir; receive output dir (default .)
    --keep-running       Allow snapshot while derod runs on this data dir
    --from=<archive>     Archive to restore (restore)
    --yes                Skip snapshot/restore/resync/uninstall confirmations
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
        '--clog-level', '--flog-level', '--config', '--extra-arg', '--level', '--out', '--from', '--source')
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $a = $Tokens[$i]
        if ($valFlags -contains $a) {
            if ($i + 1 -ge $Tokens.Count) { Write-Host "[x] Missing value for $a" -ForegroundColor Red; exit 1 }
            $norm.Add("$a=$($Tokens[$i+1])"); $i++
        } elseif ($a -eq 'send' -and $i + 1 -lt $Tokens.Count -and $Tokens[$i+1] -notlike '--*') {
            # `send <archive>` — positional archive after the command.
            $norm.Add('send'); $script:SendArchive = $Tokens[$i+1]; $i++
        } elseif ($a -eq 'receive' -and $i + 1 -lt $Tokens.Count -and $Tokens[$i+1] -notlike '--*') {
            # `receive <code>` — positional join code after the command.
            $norm.Add('receive'); $script:ReceiveCode = $Tokens[$i+1]; $i++
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
            '--source' { $script:UpdateSource = $val }
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
            'build' { $script:Action = 'build' }
            'snapshot' { $script:Action = 'snapshot' }
            'restore' { $script:Action = 'restore' }
            'resync' { $script:Action = 'resync' }
            'logs' { $script:Action = 'logs' }
            'uninstall' { $script:Action = 'uninstall' }
            'send' { $script:Action = 'send' }
            'receive' { $script:Action = 'receive' }
            default { Write-Host "[x] Unknown: $a" -ForegroundColor Red; exit 1 }
        }
    }
}

function Confirm-Disk {
    $need = 0
    switch ($script:CFG.sync_profile) {
        'minimal'  { $need = 1 }
        'compact'  { $need = 2 }
        'standard' { $need = 10 }
        'balanced' { $need = 50 }
        'pruned'   { $need = 50 } # alias
        'custom'   { $need = 50 } # conservative fallback; custom could be smaller
        'full'     { $need = 230 }
    }
    if ($need -eq 0) { return }
    if ($script:IsWindows) { return }
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
    Write-Host '    1) Minimal (testing)        --prune-history=5000   (~200 MB, 5k blocks)'
    Write-Host '    2) Compact                  --prune-history=10000  (~2 GB, 10k blocks)'
    Write-Host '    3) Standard                 --prune-history=20000  (~10 GB, 20k blocks)'
    Write-Host '    4) Balanced (Recommended)   --prune-history=100000 (~50 GB, 100k blocks)'
    Write-Host '    5) Full History (Archival)  no prune, full history from genesis (230 GB+, plan 500 GB)'
    Write-Host '    6) Custom                   enter prune-history blocks (>=50)'
    Write-Host '      --fastsync = fast bootstrap (snapshot); --prune-history = rolling window that caps disk' -ForegroundColor DarkGray
    $pick = Read-Ask 'Choose' '4'
    switch ($pick) {
        '1' { Set-SyncProfile 'minimal' }
        '2' { Set-SyncProfile 'compact' }
        '3' { Set-SyncProfile 'standard' }
        '4' { Set-SyncProfile 'balanced' }
        '5' { Set-SyncProfile 'full' }
        '6' {
            $custom = Read-Ask 'Prune history blocks (>=50, empty=no prune)' ''
            if ([string]::IsNullOrWhiteSpace($custom)) { Set-SyncProfile 'none' }
            elseif ($custom -match '^\d+$' -and [int]$custom -ge 50) {
                $script:CFG.sync_profile = 'custom'; $script:CFG.fastsync = $true; $script:CFG.prune_history = [int]$custom
            } else { Write-Host '[x] Enter a number >=50' -ForegroundColor Red; Set-SyncProfile 'balanced' }
        }
        default { Set-SyncProfile 'balanced' }
    }

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

    Write-Host ''
    Write-Host '  Run mode:'
    Write-Host '    1) Background system service   auto-start on boot (systemd / LaunchAgent / background)'
    Write-Host '    2) Foreground               run in this terminal'
    $pick = Read-Ask 'Choose' '2'
    if ($pick -eq '1') { $script:AsService = $true } else { $script:AsService = $false }

    Apply-TestnetDefaults
    Export-Config
    Confirm-Disk
    Write-Host "[*] Saved $($script:ConfigFile)" -ForegroundColor Green
}

# Invoke-FirstRunPostInstall — shared by the download and build paths on
# first run: offers a bootstrap choice (fast sync, restore from file, receive
# via thruflux), then confirms whether to start the node.
function Invoke-FirstRunPostInstall {
    if (Test-StdinInteractive) {
        Write-Host '  Bootstrap the chain:'
        Write-Host '    1) Fast sync (fastsync — recent state snapshots, not genesis)'
        Write-Host '    2) Restore from a snapshot (.tar.zst)'
        Write-Host '    3) Receive a snapshot via thruflux (join code)'
        $pick = Read-Ask 'Choose' '1'
        switch ($pick) {
            '2' {
                $file = Read-Ask 'Snapshot file path' ''
                if ($file) {
                    $script:SnapshotFrom = $file
                    $script:Action = 'restore'
                    return
                }
                Write-Host '[!] no file — falling back to fresh sync' -ForegroundColor Yellow
            }
            '3' {
                $code = Read-Ask 'Join code' ''
                if ($code) {
                    $script:ReceiveCode = $code
                    $script:Action = 'receive'
                    return
                }
                Write-Host '[!] no code — falling back to fresh sync' -ForegroundColor Yellow
            }
        }
    }
    if ((Test-StdinInteractive) -and -not (Read-YesNo 'derod installed. Start the node now?' 'y')) {
        return   # back to the menu — the binary now exists, full menu shows
    }
    $script:Action = 'start'
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
        Write-Host '  [1] Configure & install derod (download latest release)'
        Write-Host '  [2] Configure & build derod (compile community-dev, Go required)'
        Write-Host '  [q] Quit'
        $a = Read-Ask 'Choose' '1'
        if ($a -eq '1' -or $a -eq '') {
            if (-not (Test-Path $script:ConfigFile)) { Configure }
            if (-not (Ensure-Binary)) { exit 1 }
            Invoke-FirstRunPostInstall
            return
        } elseif ($a -eq '2') {
            if (-not (Test-Path $script:ConfigFile)) { Configure }
            if (-not (Test-GoAvailable)) {
                Write-Host '[x] Go toolchain not found - install Go 1.17+ (https://go.dev/dl/) to build derod from source.' -ForegroundColor Red
                exit 1
            }
            if (-not (Invoke-BuildDerodFromSource)) { exit 1 }
            Invoke-FirstRunPostInstall
            return
        } else { exit 0 }
    }
    while ($true) {
        Write-NodeStatus (Join-Path $script:BinDir 'derod')
        Write-Host ''
        Write-Host '  1) Start (foreground)'
        Write-Host '  2) Start as background service'
        Write-Host '  3) Stop'
        Write-Host '  4) Status'
        Write-Host '  5) View node logs (tail -f)'
        Write-Host '  6) Update derod (release or community-dev)'
        Write-Host '  7) Build derod from community-dev source'
        Write-Host '  8) Reconfigure'
        Write-Host '  9) Show command line (dry-run)'
        Write-Host '  10) Snapshot chain state (tar.zst)'
        Write-Host '  11) Restore chain state from snapshot'
        Write-Host '  12) Resync: wipe chain + re-bootstrap (fastsync)'
        Write-Host '  13) Share snapshot (thruflux)'
        Write-Host '  14) Receive snapshot (thruflux)'
        Write-Host '  15) Uninstall: remove derod + all node data (keep deronode)'
        Write-Host '  q) Quit'
        $a = Read-Ask 'Choose' ''
        switch ($a) {
            '1' { $script:Action = 'start'; $script:AsService = $false; return }
            '2' { $script:Action = 'start'; $script:AsService = $true; return }
            '3' { $script:Action = 'stop'; return }
            '4' { $script:Action = 'status'; return }
            '5' { $script:Action = 'logs'; return }
            '6' {
                Write-Host '    Update source:'
                Write-Host '      1) Latest release (download)'
                Write-Host '      2) community-dev source (compile)'
                $pick = Read-Ask 'Choose' '1'
                if ($pick -eq '2') { $script:UpdateSource = 'dev' } else { $script:UpdateSource = 'release' }
                $script:Action = 'update'
                return
            }
            '7' { $script:Action = 'build'; return }
            '8' { $script:Action = 'reconfigure'; return }
            '9' { $script:Action = 'start'; $script:DryRun = $true; return }
            '10' { $script:Action = 'snapshot'; return }
            '11' { $script:Action = 'restore'; return }
            '12' { $script:Action = 'resync'; return }
            '13' { $script:Action = 'send'; return }
            '14' {
                Write-Host '    Enter the join code:'
                $code = Read-Ask 'Join code' ''
                if ($code) {
                    $script:ReceiveCode = $code
                    $script:Action = 'receive'
                    return
                }
                Write-Host '[x] No join code entered' -ForegroundColor Red
            }
            '15' { $script:Action = 'uninstall'; return }
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
        # Menu option 7: show the argv and fall back to the menu; a plain CLI
        # --dry-run exits after printing (scripted callers need the exit code).
        if ($script:MenuMode) { return }
        exit 0
    }
    if (Test-ExternalInstalled) {
        Start-ExternalNode
        return
    }
    if (-not (Test-Path $script:ConfigFile)) { Configure }
    if (-not (Ensure-Binary)) { exit 1 }
    Apply-TestnetDefaults
    New-Item -ItemType Directory -Path $script:DataDirReal, $script:LogDirReal -Force | Out-Null
    if ($script:AsService) {
        # Install-Service builds the argv itself (and short-circuits with
        # "already configured and running" before that), so the fastsync/prune
        # warnings don't print for a no-op.
        Install-Service
        return
    }
    $argv = Build-DerodArgv
    # From the menu, run derod as a child so the menu is shown again once
    # the node exits. Plain CLI start keeps the exit code.
    & $script:BinaryPath @argv
    if ($script:MenuMode) { return }
    exit $LASTEXITCODE
}

function Stop-Node {
    if (Test-ExternalInstalled) {
        Stop-ExternalNode
        return
    }
    Stop-Service
}

# Show-Logs — tail the node's log file live. derod writes its own structured
# log (--log-dir) as derod.log; launchd / background backends also capture
# stdout/stderr to derod.out.log + derod.err.log, which we fall back to.
function Show-Logs {
    Resolve-Paths
    $log = Join-Path $script:LogDirReal 'derod.log'
    if (Test-Path $log) {
        Write-Host "[*] tailing $log (Ctrl-C to stop)" -ForegroundColor DarkCyan
        Get-Content -Path $log -Tail 100 -Wait
        return
    }
    # No derod.log yet - service stdout/stderr captures (launchd / background).
    # Get-Content -Wait only shows existing content for the first of several
    # files, so tail the most recently written capture (the active stream).
    $files = @(
        (Join-Path $script:LogDirReal 'derod.out.log'),
        (Join-Path $script:LogDirReal 'derod.err.log')
    ) | Where-Object { Test-Path $_ } | ForEach-Object { Get-Item $_ } | Sort-Object LastWriteTime -Descending
    if (@($files).Count -gt 0) {
        Write-Host "[*] tailing $($files[0].FullName) (Ctrl-C to stop)" -ForegroundColor DarkCyan
        Get-Content -Path $files[0].FullName -Tail 100 -Wait
        return
    }
    Write-Host "[!] no log files in $($script:LogDirReal) - derod hasn't written logs yet (foreground start prints to the terminal)." -ForegroundColor Yellow
    if (Test-ExternalInstalled) {
        $unit = Get-ExternalUnit
        if (-not $unit) { $unit = 'derod.service' }
        Write-Host "    externally-managed node - its logs live with its service manager (e.g. journalctl --user -u $unit -f)"
    } elseif ((Get-ServiceBackend) -eq 'systemd') {
        Write-Host '    systemd console stream: journalctl --user -u deronode.service -f'
    }
    if ($script:MenuMode) { return }
    exit 1
}

# Start-ExternalNode — start a system-installed (external) derod: its launchd
# agent on macOS (sudo for LaunchDaemons), its systemd unit on Linux (sudo when
# system-level). No-op when already running.
function Start-ExternalNode {
    if (Test-NodeRunning) {
        $unit = Get-ExternalUnit
        if (-not $unit) { $unit = 'derod.service' }
        Write-Host "[*] external derod already running ($unit)" -ForegroundColor DarkCyan
        return
    }
    if ($script:IsMacOS) { Start-ExternalLaunchd; return }
    $unit = Get-ExternalUnit
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

# Stop-ExternalNode — stop a system-installed (external) derod: resolve its
# unit/agent and stop via launchd on macOS or systemd on Linux (sudo when
# system-level), else kill the bare process directly. Works whether the node is
# running or already stopped.
function Stop-ExternalNode {
    if ($script:IsMacOS) { Stop-ExternalLaunchd; return }
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

# Start-ExternalLaunchd — start a launchd-managed external derod on macOS:
# kickstart a loaded agent, else load its plist (sudo for LaunchDaemons).
function Start-ExternalLaunchd {
    $unit = Get-ExternalUnit
    if (-not $unit) { Write-Host '[x] No external derod agent found' -ForegroundColor Red; exit 1 }
    Write-Host "[*] starting $unit..." -ForegroundColor DarkCyan
    $loaded = & launchctl list 2>$null | Where-Object { ($_ -split '\s+')[-1] -eq $unit } | Select-Object -First 1
    if ($loaded) {
        & launchctl kickstart "gui/$(id -u)/$unit" 2>$null
        if ($LASTEXITCODE -ne 0) { & launchctl start $unit 2>$null }
        Write-Host "[*] $unit started" -ForegroundColor Green
        return
    }
    foreach ($plist in @((Join-Path $HOME "Library/LaunchAgents/$unit.plist"), "/Library/LaunchAgents/$unit.plist", "/Library/LaunchDaemons/$unit.plist")) {
        if (-not (Test-Path $plist)) { continue }
        & launchctl load $plist 2>$null
        if ($LASTEXITCODE -ne 0) { & sudo -n launchctl load $plist 2>$null }
        if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit loaded + started" -ForegroundColor Green; return }
        if (-not [Console]::IsInputRedirected) {
            & sudo launchctl load $plist
            if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit loaded + started" -ForegroundColor Green; return }
        }
        Write-Host "[!] could not start $unit - run: sudo launchctl load $plist" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "[!] no plist found for $unit" -ForegroundColor Yellow
    exit 1
}

# Stop-ExternalLaunchd — stop a launchd-managed external derod on macOS:
# kickstart -k + stop a loaded agent, else unload its plist (sudo for
# LaunchDaemons).
function Stop-ExternalLaunchd {
    $unit = Get-ExternalUnit
    if (-not $unit) { Write-Host '[x] No external derod agent found' -ForegroundColor Red; exit 1 }
    Write-Host "[*] stopping $unit..." -ForegroundColor DarkCyan
    $loaded = & launchctl list 2>$null | Where-Object { ($_ -split '\s+')[-1] -eq $unit } | Select-Object -First 1
    if ($loaded) {
        & launchctl kickstart -k "gui/$(id -u)/$unit" 2>$null | Out-Null
        & launchctl stop $unit 2>$null | Out-Null
    }
    foreach ($plist in @((Join-Path $HOME "Library/LaunchAgents/$unit.plist"), "/Library/LaunchAgents/$unit.plist", "/Library/LaunchDaemons/$unit.plist")) {
        if (-not (Test-Path $plist)) { continue }
        & launchctl unload $plist 2>$null
        if ($LASTEXITCODE -ne 0) { & sudo -n launchctl unload $plist 2>$null }
        if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit stopped" -ForegroundColor Green; return }
        if (-not [Console]::IsInputRedirected) {
            & sudo launchctl unload $plist
            if ($LASTEXITCODE -eq 0) { Write-Host "[*] $unit stopped" -ForegroundColor Green; return }
        }
        Write-Host "[!] could not stop $unit - run: sudo launchctl unload $plist" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "[*] $unit stopped" -ForegroundColor Green
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
    # --source=dev routes the update through the community-dev compile path.
    if ($script:UpdateSource -eq 'dev') {
        Build-Node
        return
    }
    if (-not (Resolve-Release $script:Platform)) { exit 1 }
    $old = 'none'
    $tagfile = Join-Path $script:BinDir 'derod/.tag'
    if (Test-Path $tagfile) { $old = (Get-Content $tagfile -Raw).Trim() }
    # An explicit `update` always fetches the latest release — including over a
    # community-dev source build, which is otherwise kept as fresh. Skip both
    # "already at latest" short-circuits when the installed binary is a source
    # build so the user can switch back to the release.
    if (-not (Test-SourceBuild) -and (Test-CacheFresh)) { Write-Host "[*] Already at latest ($($script:LastTag))." -ForegroundColor Green; return }
    $runRel = Get-DaemonReleaseNumber
    $latestRel = if ($script:LastTag -match '(\d+)$') { $matches[1] } else { '' }
    if (-not (Test-SourceBuild) -and $runRel -and $latestRel -and $runRel -eq $latestRel) {
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
    try {
        $bin = Get-ProcessExe $proc.Pid
        if (-not $bin -and $proc.ExecutablePath) { $bin = $proc.ExecutablePath }
    } catch { $bin = '' }
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
    if ($script:IsWindows) { } else { & chmod +x $bin }
    Write-Host "[*] replaced $bin with $($script:LastTag)" -ForegroundColor Green

    if ($script:IsMacOS) {
        $unit = Get-ExternalUnit
        if ($unit) {
            Write-Host "[*] restarting $unit..." -ForegroundColor DarkCyan
            & launchctl kickstart -k "gui/$(id -u)/$unit" 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[*] $unit restarted with $($script:LastTag)" -ForegroundColor Green
            } else {
                Write-Host "[!] restart $unit manually: launchctl kickstart -k gui/$(id -u)/$unit" -ForegroundColor Yellow
            }
        } else {
            Write-Host '[!] external node has no launchd agent - restart it manually' -ForegroundColor Yellow
        }
        return
    }
    $unit = ''
    if ($script:IsLinux) {
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
# Build-Node — compile the latest DEROFDN/derohe community-dev source branch
# with the local Go toolchain and install it as bin/derod/derod (an
# alternative to downloading a release). Restarts a running node like update.
# Refuses on externally-managed nodes (we never replace binaries we don't own).
function Build-Node {
    if ($script:DryRun) {
        Write-Host "[*] dry-run: would clone $($script:DevRepo) ($($script:DevBranch)) and 'go build ./cmd/derod' into $($script:BinaryPath)" -ForegroundColor DarkCyan
        return
    }
    if (Test-ExternalInstalled) {
        Write-Host '[x] build only works on a deronode-managed node (an external derod is installed).' -ForegroundColor Red
        exit 1
    }
    if (-not (Test-GoAvailable)) {
        Write-Host '[x] Go toolchain not found - install Go 1.17+ (https://go.dev/dl/) to build derod from source.' -ForegroundColor Red
        exit 1
    }
    $old = 'none'
    $tagfile = Join-Path $script:BinDir 'derod/.tag'
    if (Test-Path $tagfile) { $old = (Get-Content $tagfile -Raw).Trim() }
    Write-Host "[*] Building derod $old -> $($script:DevBranch)" -ForegroundColor DarkCyan
    $wasRunning = Test-NodeRunning
    if ($wasRunning) { Stop-Service }
    if (-not (Invoke-BuildDerodFromSource)) { exit 1 }
    if ($wasRunning) {
        Write-Host '[*] restarting with the freshly-built binary...' -ForegroundColor DarkCyan
        Install-Service
    }
}

function Reconfigure-Node {
    Configure
    # Continue straight into `start` after asking questions, same as the
    # first-run install flow. Only when nothing is running — a live node
    # must be stopped/restarted by the user instead.
    if (Test-NodeRunning) {
        Write-Host '[!] derod is running - stop it first (deronode stop) to apply the new config.' -ForegroundColor Yellow
        return
    }
    Start-Node
}

# Invoke-Resync — wipe the chain data and re-bootstrap via --fastsync. This is
# the "start over" path: a fresh chain (or one broken by a bad prune) gets a
# clean fastsync bootstrap. Refuses on externally-managed nodes (we never touch
# data we don't own). Stops a running node first, deletes the chain dir, forces
# fastsync on and prune off (a fresh chain can't prune), then starts.
function Invoke-Resync {
    Resolve-Paths
    if (Test-ExternalInstalled) {
        Write-Host '[x] resync only works on a deronode-managed node (an external derod is installed).' -ForegroundColor Red
        exit 1
    }
    if ($script:DryRun) {
        Write-Host "[*] dry-run: would wipe $(Get-SnapshotChainDir) and re-bootstrap via --fastsync" -ForegroundColor DarkCyan
        return
    }
    $chainDir = Get-SnapshotChainDir
    if (Test-Path $chainDir) {
        Write-Host "[!] This deletes the chain data at $chainDir" -ForegroundColor Yellow
        Write-Host "    and re-bootstraps via --fastsync." -ForegroundColor Yellow
        if (-not $script:SnapshotYes -and -not (Read-YesNo 'Continue?' 'n')) {
            Write-Host '[x] Aborted.' -ForegroundColor Red
            exit 1
        }
        if (Test-NodeRunning) {
            Write-Host '[*] stopping derod...' -ForegroundColor DarkCyan
            Stop-Node
        }
        Write-Host '[*] wiping chain data...' -ForegroundColor DarkCyan
        Remove-Item $chainDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Fresh bootstrap: fastsync on, no prune (derod can't prune an empty chain).
    $script:CFG.fastsync = $true
    $script:CFG.prune_history = $null
    Export-Config
    Write-Host '[*] chain reset - bootstrapping via fastsync.' -ForegroundColor Green
    Start-Node
}

# Uninstall-Node — remove the managed node completely: stop it, remove the
# service unit, and delete the binary, chain data, logs, snapshots, and
# config.json. Keeps the deronode tool itself so the menu returns to the
# fresh "No derod installed yet" first-run state. Refuses on
# externally-managed nodes (we never touch data we don't own).
function Uninstall-Node {
    Resolve-Paths
    if (Test-ExternalInstalled) {
        Write-Host '[x] uninstall only works on a deronode-managed node (an external derod is installed).' -ForegroundColor Red
        exit 1
    }
    if ($script:DryRun) {
        Write-Host "[*] dry-run: would stop derod, remove the service unit, and delete $($script:DataDirReal), $($script:BinDir), $($script:LogDirReal), $($script:SnapshotDirReal), $($script:ConfigFile)" -ForegroundColor DarkCyan
        return
    }
    Write-Host '[!] This removes the derod binary, chain data, logs, snapshots, and config.json.' -ForegroundColor Yellow
    if (-not $script:SnapshotYes -and -not (Read-YesNo 'Continue?' 'n')) {
        Write-Host '[x] Aborted.' -ForegroundColor Red
        exit 1
    }
    # Safety guard: never wipe / or an empty path even if config.json was
    # pointed at something pathological.
    foreach ($dir in @($script:DataDirReal, $script:BinDir, $script:LogDirReal, $script:SnapshotDirReal)) {
        if ([string]::IsNullOrEmpty($dir) -or $dir -eq '/') {
            Write-Host "[x] Refusing to uninstall: $dir is not a removable path." -ForegroundColor Red
            exit 1
        }
    }
    Write-Host '[*] stopping derod...' -ForegroundColor DarkCyan
    Remove-Service
    Write-Host '[*] removing node data...' -ForegroundColor DarkCyan
    Remove-Item $script:DataDirReal, $script:BinDir, $script:LogDirReal, $script:SnapshotDirReal -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $script:ConfigFile, "$($script:ConfigFile).bak", (Join-Path $script:InstallDir 'derod.pid'), (Join-Path $script:InstallDir 'run-derod.sh'), (Join-Path $script:InstallDir 'run-derod.ps1') -Force -ErrorAction SilentlyContinue
    Write-Host '[*] derod removed - deronode stays installed. Re-run the menu to configure a fresh node.' -ForegroundColor Green
}

# thruflux is a peer-to-peer QUIC file-transfer CLI (thru host / thru join).
# We shell out to it for `send`/`receive`; it must be installed separately.
#
# NOTE: the upstream one-line installers (install_linux.sh / install_macos.sh
# / install_windows.ps1) are currently BROKEN — they download `thru` from a
# github.com/.../raw/refs/heads/main/... URL that returns 404 (GitHub serves
# large blobs differently on that route). The binaries exist at the
# raw.githubusercontent.com/.../main/... equivalent, so we fetch them
# directly instead of piping the installer.
function Get-ThrufluxBinaryUrl {
    if ($script:IsWindows) {
        return 'https://raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries/windows/thru_windows.exe'
    } elseif ($script:IsMacOS) {
        return 'https://raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries/macos/thru_mac'
    }
    return 'https://raw.githubusercontent.com/samsungplay/Thruflux/main/frontend/binaries/linux/thru_linux'
}

function Get-ThrufluxInstallHint {
    $binDir = Join-Path $HOME '.local/bin'
    $url = Get-ThrufluxBinaryUrl
    if ($script:IsWindows) {
        return "  mkdir -p '$binDir'; curl -fsSL '$url' -o '$binDir/thru.exe'"
    }
    return "  mkdir -p '$binDir'; curl -fsSL '$url' -o '$binDir/thru' && chmod +x '$binDir/thru'"
}

# Install the thruflux CLI: download the static binary into ~/.local/bin
# (deronode already puts its launcher there). Prints progress; returns $true
# on success.
function Install-Thruflux {
    $binDir = Join-Path $HOME '.local/bin'
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    $url = Get-ThrufluxBinaryUrl
    $target = if ($script:IsWindows) { Join-Path $binDir 'thru.exe' } else { Join-Path $binDir 'thru' }
    Write-Host '[*] downloading thruflux...' -ForegroundColor DarkCyan
    Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing -ErrorAction Stop
    if (-not $script:IsWindows) {
        & chmod +x $target 2>$null | Out-Null
    }
    return $true
}

# Ensure the thruflux CLI is available. Interactive runs are asked to install
# it on the spot (default yes); piped/scripted runs and non-tty invocations
# only get the manual install hint, so nothing is ever installed unattended.
# Returns $true when `thru` is usable, $false otherwise.
function Ensure-Thruflux {
    if (Get-Command thru -ErrorAction SilentlyContinue) { return $true }
    Write-Host '[x] thruflux CLI (thru) not found.' -ForegroundColor Red
    if ((Test-StdinInteractive) -and (Read-YesNo 'Install thruflux now?' 'y')) {
        Write-Host '[*] installing thruflux...' -ForegroundColor DarkCyan
        # Install-Thruflux must run through Out-Host: its output has to be
        # shown, but must NOT join this function's pipeline, or the return
        # value below becomes a non-empty array (truthy) and the `exit 1`
        # guard in the callers is skipped — exactly the bug where send
        # continued to `thru host` after a failed install. Success/failure is
        # decided by try/catch, not by the piped output.
        try {
            Install-Thruflux 2>&1 | Out-Host
            # Make it usable for the rest of this session even when
            # ~/.local/bin is not on PATH yet (deronode's installer adds it
            # to the shell rc, but that only applies to new shells). PATH
            # separator is ';' on Windows but ':' on Linux/macOS.
            if (-not (Get-Command thru -ErrorAction SilentlyContinue)) {
                $sep = if ($script:IsWindows) { ';' } else { ':' }
                $env:PATH = "$(Join-Path $HOME '.local/bin')$sep$env:PATH"
            }
            if (Get-Command thru -ErrorAction SilentlyContinue) {
                Write-Host "[*] thruflux installed: $((Get-Command thru).Source)" -ForegroundColor Green
            } else {
                Write-Host "[*] thruflux installed at $(Join-Path $HOME '.local/bin/thru') - add ~/.local/bin to your PATH." -ForegroundColor Green
            }
            return $true
        } catch {
            Write-Host "[x] thruflux install failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host (Get-ThrufluxInstallHint)
    return $false
}

# Send-Snapshot — share a snapshot (or any file) with a friend over the
# internet, fast + encrypted, via thruflux: `thru host <archive>` prints a join
# code the friend uses with `thru join <code>` (or `deronode receive <code>`).
# Defaults to the newest snapshot in the snapshot dir; pass an explicit path
# to send any file. Needs the thruflux CLI (see Get-ThrufluxInstallHint).
function Send-Snapshot {
    Resolve-Paths
    $archive = $script:SendArchive
    if (-not $archive) {
        $archive = Get-LatestSnapshotArchive
        if (-not $archive) {
            Write-Host "[x] no snapshot found in $($script:SnapshotDirReal) - pass a file: deronode send <path>" -ForegroundColor Red
            exit 1
        }
        Write-Host "[*] using latest snapshot: $(Split-Path -Leaf $archive)" -ForegroundColor DarkCyan
    }
    if (-not (Test-Path $archive)) {
        Write-Host "[x] file not found: $archive" -ForegroundColor Red
        exit 1
    }
    # Host the archive together with its .sha256 / .manifest.json siblings
    # (when present) so the receiver can verify the restore automatically —
    # thruflux supports any number of files in one host session.
    $hostArgs = @($archive)
    if (Test-Path "$archive.sha256") { $hostArgs += "$archive.sha256" }
    if (Test-Path "$archive.manifest.json") { $hostArgs += "$archive.manifest.json" }
    if ($script:DryRun) {
        Write-Host "[*] dry-run: would run: thru host $($hostArgs -join ' ')" -ForegroundColor DarkCyan
        Write-Host '[*] your friend then runs: thru join <code> --out <dir>  (or: deronode receive <code>)' -ForegroundColor DarkCyan
        return
    }
    if (-not (Ensure-Thruflux)) { exit 1 }
    Write-Host "[*] hosting $($hostArgs -join ' ') - share the join code with your friend" -ForegroundColor DarkCyan
    & thru host @hostArgs
}

# Receive-Snapshot — receive a thruflux transfer from a friend: `thru join
# <code>` writes the files into --out (default .). Needs the thruflux CLI.
function Receive-Snapshot {
    if (-not $script:ReceiveCode) {
        Write-Host '[x] usage: deronode receive <code> [--out <dir>]' -ForegroundColor Red
        exit 1
    }
    $out = if ($script:SnapshotOut) { $script:SnapshotOut } else { '.' }
    if ($script:DryRun) {
        Write-Host "[*] dry-run: would run: thru join $($script:ReceiveCode) --out $out" -ForegroundColor DarkCyan
        return
    }
    if (-not (Ensure-Thruflux)) { exit 1 }
    & thru join $script:ReceiveCode --out $out
    if ($LASTEXITCODE -ne 0) { exit 1 }

    # Integrated restore: if the transfer carried a deronode snapshot
    # (dero-mainnet-*.tar.zst, with its .sha256/.manifest siblings when the
    # sender used `deronode send`), propose restoring it right away —
    # mirroring Invoke-Snapshot's stop/restore/restart flow. Interactive only,
    # so piped/scripted runs never touch the node.
    $received = Get-ChildItem -Path $out -Filter 'dero-mainnet-*.tar.zst' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $received) {
        Write-Host "[*] transfer complete - saved to $out (not a deronode snapshot, nothing to restore)." -ForegroundColor DarkGray
        return
    }
    if (-not (Test-StdinInteractive)) {
        Write-Host "[*] received snapshot: $(Split-Path -Leaf $received.FullName) - restore it with: deronode restore --from $($received.FullName)" -ForegroundColor DarkCyan
        return
    }
    Resolve-Paths
    $script:SnapshotFrom = $received.FullName
    if (-not (Test-SnapshotRunningOnDataDir)) {
        # Node is stopped: reuse the normal restore flow (confirm, restore,
        # then offer to start the node).
        Invoke-Restore
        return
    }
    if (-not (Read-YesNo "derod is running on $($script:DataDirReal) - stop it, restore the received snapshot, then restart?" 'y')) {
        Write-Host "[*] received snapshot saved to $($received.FullName) - restore it later with: deronode restore --from $($received.FullName)" -ForegroundColor DarkCyan
        return
    }
    Write-Host '[*] stopping derod...' -ForegroundColor DarkCyan
    Stop-Node
    # The user just confirmed the stop+restore, so skip restore's second
    # confirm and the no-.sha256 wall; sha256 verification failures still abort.
    $script:SnapshotYes = $true
    if (-not (Restore-Snapshot)) {
        Write-Host '[*] restarting derod...' -ForegroundColor DarkCyan
        if (Test-ExternalInstalled) { Start-ExternalNode } else { Install-Service }
        exit 1
    }
    Write-Host '[*] restarting derod...' -ForegroundColor DarkCyan
    if (Test-ExternalInstalled) { Start-ExternalNode } else { Install-Service }
}

function Invoke-Snapshot {
    Resolve-Paths
    $script:SnapshotDir = if ($script:SnapshotOut) { $script:SnapshotOut } else { $script:SnapshotDirReal }
    # If a snapshot already exists, present the latest one (name + timestamp)
    # and confirm a new one. Names are timestamped, so a new archive never
    # overwrites; this guards the menu against accidental re-snapshots.
    # Interactive-only (piped/scripted runs and --dry-run proceed straight to
    # New-Snapshot). Declining keeps the existing snapshot and exits 0.
    if (-not $script:DryRun -and (Test-StdinInteractive)) {
        $latest = Get-LatestSnapshotArchive
        if ($latest) {
            $stamp = Get-SnapshotArchiveStamp $latest
            if (-not (Read-YesNo "Latest snapshot: $(Split-Path -Leaf $latest) ($stamp) - create a new one?" 'y')) {
                Write-Host '[*] keeping existing snapshot - nothing created.' -ForegroundColor DarkGray
                return
            }
        }
    }
    # Snapshot needs the chain quiet. If derod is running against our data dir
    # (and --keep-running wasn't passed), offer to stop it, snapshot, then
    # restart. Only prompts on an interactive terminal so piped/scripted calls
    # never auto-stop the node; declining falls through to the library guard.
    if (-not $script:DryRun -and (Test-SnapshotRunningOnDataDir) -and -not $script:SnapshotKeepRunning -and (Test-StdinInteractive) -and
        (Read-YesNo "derod is running on $($script:DataDirReal) - stop it, snapshot, then restart?" 'y')) {
        Write-Host '[*] stopping derod...' -ForegroundColor DarkCyan
        Stop-Node
        if (-not (New-Snapshot)) { exit 1 }
        Write-Host '[*] restarting derod...' -ForegroundColor DarkCyan
        if (Test-ExternalInstalled) { Start-ExternalNode } else { Install-Service }
        return
    }
    if (-not (New-Snapshot)) { exit 1 }
}
function Invoke-Restore {
    Resolve-Paths
    if (-not (Restore-Snapshot)) { exit 1 }
    # Restore replaces the chain state and refuses while any derod runs, so the
    # node is guaranteed stopped here. Offer to bring it back up — interactive
    # only, and never with --yes, so piped/scripted restores keep their old
    # behavior (restore but leave the node stopped).
    if (-not $script:SnapshotYes -and (Test-StdinInteractive) -and (Read-YesNo 'Restore complete. Start the node now?' 'y')) {
        Write-Host '[*] starting derod...' -ForegroundColor DarkCyan
        Start-Node
    }
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
    'build' { Build-Node }
    'snapshot' { Invoke-Snapshot }
    'restore' { Invoke-Restore }
    'resync' { Invoke-Resync }
    'logs' { Show-Logs }
    'uninstall' { Uninstall-Node }
    'send' { Send-Snapshot }
    'receive' { Receive-Snapshot }
    default {
        # Menu-driven: dispatch the chosen action, then come back to the menu
        # instead of exiting (q in the menu quits).
        $script:MenuMode = $true
        while ($true) {
            Show-Menu
            switch ($script:Action) {
                'start' { Start-Node }
                'stop' { Stop-Node }
                'status' { Show-Status }
                'update' { Update-Node }
                'build' { Build-Node }
                'snapshot' { Invoke-Snapshot }
                'restore' { Invoke-Restore }
                'resync' { Invoke-Resync }
                'logs' { Show-Logs }
                'uninstall' { Uninstall-Node }
                'send' { Send-Snapshot }
                'receive' { Receive-Snapshot }
                'reconfigure' { Reconfigure-Node }
            }
        }
    }
}