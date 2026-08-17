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
    --reconfigure        Re-run the first-run prompts (incl. data-dir / log-dir)

  Options:
    --dry-run            Resolve/download nothing; print the derod argv and exit
    --config=<path>      Config file (default ./config.json)
    --source=release|dev Update source (release download or community-dev compile)
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
    --yes                Skip snapshot/restore/resync confirmations
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
            # Continue straight into `start` after installing — no second menu
            # prompt. The run-mode answer from Configure (service vs
            # foreground) is honored, so don't reset AsService here.
            if (-not (Ensure-Binary)) { exit 1 }
            $script:Action = 'start'
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
        Write-Host '  5) Update derod (release or community-dev)'
        Write-Host '  6) Build derod from community-dev source'
        Write-Host '  7) Reconfigure'
        Write-Host '  8) Show command line (dry-run)'
        Write-Host '  9) Snapshot chain state (tar.zst)'
        Write-Host '  10) Restore chain state from snapshot'
        Write-Host '  11) Resync: wipe chain + re-bootstrap (fastsync)'
        Write-Host '  12) View node logs (tail -f)'
        Write-Host '  q) Quit'
        $a = Read-Ask 'Choose' ''
        switch ($a) {
            '1' { $script:Action = 'start'; $script:AsService = $false; return }
            '2' { $script:Action = 'start'; $script:AsService = $true; return }
            '3' { $script:Action = 'stop'; return }
            '4' { $script:Action = 'status'; return }
            '5' {
                Write-Host '    Update source:'
                Write-Host '      1) Latest release (download)'
                Write-Host '      2) community-dev source (compile)'
                $pick = Read-Ask 'Choose' '1'
                if ($pick -eq '2') { $script:UpdateSource = 'dev' } else { $script:UpdateSource = 'release' }
                $script:Action = 'update'
                return
            }
            '6' { $script:Action = 'build'; return }
            '7' { $script:Action = 'reconfigure'; return }
            '8' { $script:Action = 'start'; $script:DryRun = $true; return }
            '9' { $script:Action = 'snapshot'; return }
            '10' { $script:Action = 'restore'; return }
            '11' { $script:Action = 'resync'; return }
            '12' { $script:Action = 'logs'; return }
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
    $argv = Build-DerodArgv
    New-Item -ItemType Directory -Path $script:DataDirReal, $script:LogDirReal -Force | Out-Null
    if ($script:AsService) {
        Install-Service
    } else {
        # From the menu, run derod as a child so the menu is shown again once
        # the node exits. Plain CLI start keeps the exit code.
        & $script:BinaryPath @argv
        if ($script:MenuMode) { return }
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

function Invoke-Snapshot {
    Resolve-Paths
    $script:SnapshotDir = if ($script:SnapshotOut) { $script:SnapshotOut } else { $script:SnapshotDirReal }
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
                'reconfigure' { Reconfigure-Node }
            }
        }
    }
}