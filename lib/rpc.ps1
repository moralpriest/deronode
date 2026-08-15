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

# Test-ExternalNode — true when a derod is running whose binary is NOT the one
# deronode manages (system-installed via systemd etc.). Robust to deronode
# having a previously-downloaded copy in bin/ — compares the running process
# image, not the existence of our own binary.
function Test-ExternalNode {
    if (-not (Test-NodeRunning)) { return $false }
    $proc = Get-ProcessTable | Where-Object { $_.Name -like 'derod*' } | Select-Object -First 1
    if (-not $proc) { return $false }
    $image = $null
    try {
        if ($IsLinux -and (Test-Path "/proc/$($proc.Pid)/exe")) {
            $image = (Get-Item "/proc/$($proc.Pid)/exe").Target
            $image = $image -replace ' \(deleted\)$', ''
        } elseif ($proc.Path) {
            $image = $proc.Path
        }
    } catch { $image = $null }
    if (-not $image) { return $false }
    $ours = (Get-Item $script:BinaryPath -ErrorAction SilentlyContinue).FullName
    return ($image -ne $ours)
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
        if ($h -ge $th -and $th -gt 0) {
            Write-Host "  running  height $h/$th  peers $peers" -ForegroundColor Green
        } else {
            Write-Host "  syncing  height $h/$th  stable $st  peers $peers" -ForegroundColor Yellow
        }
        $tag = '?'
        if (Test-Path (Join-Path $DerodDir '.tag')) { $tag = (Get-Content (Join-Path $DerodDir '.tag') -Raw).Trim() }
        if (Test-Path $bin) {
            Write-Host "  derod $tag  data: $($script:DataDirReal)  log: $($script:LogDirReal)"
        } else {
            Write-Host "  derod system-installed (external, not managed by deronode)"
        }
    } else {
        Write-Host "  stopped" -ForegroundColor DarkGray
        if (Test-Path $bin) {
            $tag = (Get-Content (Join-Path $DerodDir '.tag') -Raw).Trim()
            Write-Host "  derod $tag installed - run 'deronode start'"
        }
    }
}