# lib/rpc.ps1 — talk to the local daemon's JSON-RPC.

function Invoke-RpcCall {
    param([string]$Method, [string]$Params = '')
    $bind = $script:CFG.rpc_bind
    $hostPort = $bind.Split('/')[0]
    $path = ''
    if ($bind -like '*/*') { $path = '/' + ($bind.Split('/')[1]) }
    $body = if ($Params) {
        @{ jsonrpc = '2.0'; id = '1'; method = $Method; params = ($Params | ConvertFrom-Json) } | ConvertTo-Json -Compress -Depth 6
    } else {
        @{ jsonrpc = '2.0'; id = '1'; method = $Method } | ConvertTo-Json -Compress
    }
    try {
        $r = Invoke-RestMethod -Uri "http://$hostPort$path/json_rpc" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 8
        return $r.result
    } catch { return $null }
}

function Test-NodeRunning {
    return $null -ne (Invoke-RpcCall 'DERO.GetInfo')
}

# Get-DaemonReleaseNumber — release number of the running daemon, derived from
# its DERO.GetInfo version string ("3.6.0-152.DEROHE.STARGATE+..." -> "152").
# Empty when the node is not running or the version carries no release component.
function Get-DaemonReleaseNumber {
    if (-not (Test-NodeRunning)) { return '' }
    $info = Invoke-RpcCall 'DERO.GetInfo'
    if (-not $info -or -not $info.version) { return '' }
    $m = [regex]::Match([string]$info.version, '-(\d+)\.')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Get-ProcessExe <pid> — absolute path of a running process's executable.
# Linux: /proc/$pid/exe. Windows: Win32_Process.ExecutablePath. macOS/other:
# lsof reports the mapped executable (ps truncates). $null when unresolvable.
function Get-ProcessExe {
    param([int]$Pid)
    try {
        if ($script:IsLinux -and (Test-Path "/proc/$Pid/exe")) {
            return ((Get-Item "/proc/$Pid/exe").Target -replace ' \(deleted\)$', '')
        }
        if ($script:IsWindows) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$Pid" -ErrorAction SilentlyContinue
            if ($p -and $p.ExecutablePath) { return $p.ExecutablePath }
            return $null
        }
        $l = & lsof -a -p $Pid -Fn 2>$null | Where-Object { $_ -match '^n/' } | Select-Object -First 1
        if ($l) { return $l.Substring(1) }
    } catch {}
    return $null
}

# Get-ProcessCwd <pid> — a running process's working directory. Linux:
# /proc/$pid/cwd. macOS/other: lsof -d cwd. Windows has no portable cwd probe,
# so it returns $null there (callers fall back to unit/plist data dirs).
function Get-ProcessCwd {
    param([int]$Pid)
    try {
        if ($script:IsLinux -and (Test-Path "/proc/$Pid/cwd")) {
            return ((Get-Item "/proc/$Pid/cwd").Target -replace ' \(deleted\)$', '')
        }
        if (-not $script:IsWindows) {
            $l = & lsof -a -p $Pid -d cwd -Fn 2>$null | Where-Object { $_ -match '^n/' } | Select-Object -First 1
            if ($l) { return $l.Substring(1) }
        }
    } catch {}
    return $null
}

# Test-ExternalNode — true when a derod is running whose binary is NOT the one
# deronode manages (system-installed via systemd/launchd etc.). Robust to
# deronode having a previously-downloaded copy in bin/ — compares the running
# process image, not the existence of our own binary.
function Test-ExternalNode {
    if (-not (Test-NodeRunning)) { return $false }
    $proc = Get-ProcessTable | Where-Object { $_.Name -like 'derod*' } | Select-Object -First 1
    if (-not $proc) { return $false }
    $image = $null
    try {
        $image = Get-ProcessExe $proc.Pid
        if (-not $image -and $proc.ExecutablePath) { $image = $proc.ExecutablePath }
    } catch { $image = $null }
    if (-not $image) { return $false }
    $ours = (Get-Item $script:BinaryPath -ErrorAction SilentlyContinue).FullName
    return ($image -ne $ours)
}

# Get-ExternalUnit — the unit/agent name for an externally-installed derod
# (e.g. derod.service on Linux, a derod launchd agent on macOS), or $null when
# none is installed. Works even when the node is stopped — detects the
# *installation*, not a running process. Our own deronode-managed unit/agent
# (deronode.service / org.deronode.derod) is never treated as external.
function Get-ExternalUnit {
    $unit = $null
    if ($script:IsMacOS) {
        $u = & launchctl list 2>$null | Where-Object { $_ -match '^\S+\s+\S+\s+\S*derod\S*$' } | Select-Object -First 1
        if ($u) {
            $parts = ($u -split '\s+')
            $unit = $parts[$parts.Count - 1]
            if ($unit -eq 'org.deronode.derod') { $unit = $null }
        }
        if (-not $unit) {
            foreach ($d in @((Join-Path $HOME 'Library/LaunchAgents'), '/Library/LaunchAgents', '/Library/LaunchDaemons')) {
                $plist = Get-ChildItem $d -Filter '*derod*.plist' -ErrorAction SilentlyContinue |
                    Where-Object { $_.BaseName -ne 'org.deronode.derod' } |
                    Select-Object -First 1
                if ($plist) { $unit = $plist.BaseName; break }
            }
        }
    }
    if (-not $unit -and $script:IsLinux -and (Get-Command systemctl -ErrorAction SilentlyContinue)) {
        $unit = (& systemctl list-unit-files --no-legend --type=service 2>$null |
            Where-Object { $_ -match '^derod[^@]*\.service\s' -and $_ -notmatch '^deronode\.service' } |
            ForEach-Object { ($_ -split '\s+')[0] } |
            Select-Object -First 1)
    }
    if (-not $unit) {
        if ($script:IsLinux -and (Test-Path '/etc/systemd/system/derod.service')) { $unit = 'derod.service' }
        elseif ($script:IsLinux -and (Test-Path '/usr/lib/systemd/system/derod.service')) { $unit = 'derod.service' }
    }
    return $unit
}

# Test-ExternalInstalled — true when an external derod installation exists: a
# derod systemd unit / launchd agent is present, OR a derod is running whose
# binary is not ours.
function Test-ExternalInstalled {
    if (Get-ExternalUnit) { return $true }
    return (Test-ExternalNode)
}

# Get-DataDirFromUnitFile — the data dir root encoded in a systemd unit file:
# WorkingDirectory=, fallback --data-dir= from ExecStart. $null when absent.
function Get-DataDirFromUnitFile {
    param([string]$UnitFile)
    if (-not (Test-Path $UnitFile)) { return $null }
    $m = Select-String -Path $UnitFile -Pattern '^WorkingDirectory=(.+)$' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    $m = Select-String -Path $UnitFile -Pattern -- '--data-dir=(\S+)' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    return $null
}

# Get-DataDirFromPlist <plist> — the data dir root encoded in a macOS launchd
# plist: WorkingDirectory, fallback --data-dir= from ProgramArguments. $null
# when absent.
function Get-DataDirFromPlist {
    param([string]$Plist)
    if (-not (Test-Path $Plist)) { return $null }
    $xml = Get-Content $Plist -Raw -ErrorAction SilentlyContinue
    if (-not $xml) { return $null }
    if ($xml -match '<key>WorkingDirectory</key>\s*<string>([^<]+)</string>') {
        return $matches[1]
    }
    $m = [regex]::Match($xml, '--data-dir=([^\s<>"'']+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Get-ExternalDataDir — the data dir root for an externally-installed derod
# (systemd unit / launchd agent). derod's data dir defaults to its working
# directory, so we take the running process's cwd when the node is up, else the
# unit/agent's WorkingDirectory (fallback --data-dir= from ExecStart/
# ProgramArguments). Returns $script:DataDirReal when no external install is
# present.
function Get-ExternalDataDir {
    $proc = Get-ProcessTable | Where-Object { $_.Name -like 'derod*' } | Select-Object -First 1
    if ($proc) {
        $cwd = $null
        try { $cwd = Get-ProcessCwd $proc.Pid } catch { $cwd = $null }
        if ($cwd) { return $cwd }
    }
    $unit = Get-ExternalUnit
    if ($unit) {
        if ($script:IsMacOS) {
            foreach ($f in @((Join-Path $HOME "Library/LaunchAgents/$unit.plist"), "/Library/LaunchAgents/$unit.plist", "/Library/LaunchDaemons/$unit.plist")) {
                $d = Get-DataDirFromPlist $f
                if ($d) { return $d }
            }
        } else {
            foreach ($f in @("/etc/systemd/system/$unit", "/usr/lib/systemd/system/$unit")) {
                $d = Get-DataDirFromUnitFile $f
                if ($d) { return $d }
            }
        }
    }
    return $script:DataDirReal
}

# Test-ExternalSystemUnit — true when the unit/agent lives in the system
# manager (needs sudo) vs the user manager. Linux: systemd system vs user
# unit. macOS: LaunchDaemon (/Library/LaunchDaemons) vs user LaunchAgent
# (~/Library/LaunchAgents).
function Test-ExternalSystemUnit {
    $unit = Get-ExternalUnit
    if (-not $unit) { return $true }
    if ($script:IsMacOS) {
        return (Test-Path "/Library/LaunchDaemons/$unit.plist")
    }
    $userUnits = & systemctl --user list-unit-files --no-legend 2>$null | Where-Object { $_ -match "^$unit " }
    return -not $userUnits
}

function Write-NodeStatus {
    param([string]$DerodDir)
    $bin = Join-Path $DerodDir 'derod'
    if (Test-NodeRunning) {
        $info = Invoke-RpcCall 'DERO.GetInfo'
        $h = [int]$info.height
        $th = [int]$info.topoheight
        $st = [int]$info.stableheight
        $peers = if ($info.incoming_connections_count -ne $null) { $info.incoming_connections_count } else { '?' }
        $ver = if ($info.version) { ("  derohe " + ([string]$info.version -replace '\+.*$', '')) } else { '' }
        if ($h -ge $th -and $th -gt 0) {
            Write-Host "  running  height $h/$th  peers $peers$ver" -ForegroundColor Green
        } else {
            Write-Host "  syncing  height $h/$th  stable $st  peers $peers$ver" -ForegroundColor Yellow
        }
        $tag = '?'
        if (Test-Path (Join-Path $DerodDir '.tag')) { $tag = (Get-Content (Join-Path $DerodDir '.tag') -Raw).Trim() }
        if (Test-ExternalInstalled) {
            $unit = Get-ExternalUnit
            if ($unit) { Write-Host "  external derod: $unit  (not managed by deronode)" }
            else { Write-Host '  external derod  (not managed by deronode)' }
        } elseif (Test-Path $bin) {
            Write-Host "  derod $tag  data: $($script:DataDirReal)  log: $($script:LogDirReal)"
        } else {
            Write-Host "  derod running - managed binary missing (run 'deronode update')"
        }
    } else {
        Write-Host "  stopped" -ForegroundColor DarkGray
        if (Test-ExternalInstalled) {
            $unit = Get-ExternalUnit
            if ($unit) { Write-Host "  external derod: $unit - stopped" }
            else { Write-Host '  external derod - stopped' }
        } elseif (Test-Path $bin) {
            $tag = (Get-Content (Join-Path $DerodDir '.tag') -Raw).Trim()
            Write-Host "  derod $tag installed - run 'deronode start'"
        }
    }
}