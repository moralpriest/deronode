# lib/service.ps1 — start/stop/install for the derod process.
# Backend: systemd user unit (Linux), launchctl (macOS), nohup + pid (Windows).

function Write-RunWrapper {
    $wrapper = Join-Path $InstallDir 'run-derod.ps1'
    $argv = Build-DerodArgv
    # One quoted arg per line, splatted (@derodArgs) into the binary — a comma
    # list ('a', 'b') collapses into a single argument, which derod rejects with
    # its usage screen.
    $argLines = ($argv | ForEach-Object { "  '" + ($_ -replace "'", "''") + "'" }) -join ",`n"
    $content = @"
`$ErrorActionPreference = 'Stop'
`$derodArgs = @(
$argLines
)
& '$BinaryPath' @derodArgs
"@
    # systemd ExecStart points straight at this file, so on Linux/macOS it must
    # be executable and carry a pwsh shebang (mirrors run-derod.sh on the bash
    # side) or the unit dies with status=203/EXEC. Windows only ever runs it
    # via 'pwsh -File', so both are skipped there.
    if (-not $script:IsWindows) {
        $content = "#!/usr/bin/env pwsh`n$content"
    }
    Set-Content $wrapper $content -Encoding UTF8
    if (-not $script:IsWindows) {
        try { & chmod +x $wrapper 2>$null } catch { }
    }
    return $wrapper
}

function Get-ServiceBackend {
    if ($script:IsLinux -and (Get-Command systemctl -ErrorAction SilentlyContinue)) {
        $st = & systemctl --user is-system-running 2>$null
        # "running" (exit 0) and "degraded" (exit 1) both mean the user manager
        # is up and can start units — a failed *unrelated* unit must not demote
        # us to the pid fallback (that is what made a failing unit crash-loop
        # into the background backend). Only an unreachable/offline bus does.
        if ($st -in @('running', 'degraded', 'starting', 'maintenance')) { return 'systemd' }
    }
    if ($script:IsMacOS) { return 'launchd' }
    return 'pid'
}

function Install-Service {
    # Already configured and running: nothing to do — report it without even
    # building the wrapper, so the fastsync/prune warnings don't print for a
    # no-op. (Get-ServiceBackend is cheap; the switch below calls it again.)
    switch (Get-ServiceBackend) {
        'systemd' {
            $unit = Join-Path $HOME '.config/systemd/user/deronode.service'
            if ((Test-Path $unit) -and ((& systemctl --user is-active deronode.service 2>$null) -eq 'active')) {
                Write-Host '[*] deronode.service is already configured and running' -ForegroundColor Green
                return
            }
        }
        'launchd' {
            $plist = Join-Path $HOME 'Library/LaunchAgents/org.deronode.derod.plist'
            if ((Test-Path $plist) -and [bool](& launchctl list 2>$null | Select-String 'org\.deronode\.derod' -Quiet)) {
                Write-Host '[*] org.deronode.derod is already configured and running' -ForegroundColor Green
                return
            }
        }
    }
    Apply-TestnetDefaults
    $wrapper = Write-RunWrapper
    switch (Get-ServiceBackend) {
        'systemd' {
            $unitDir = Join-Path $HOME '.config/systemd/user'
            $unit = Join-Path $unitDir 'deronode.service'
            if (Test-Path $unit) {
                # Idempotent: the unit is already configured but not running —
                # just start it (the wrapper above already embeds the argv).
                Write-Host '[*] deronode.service is already configured - starting it' -ForegroundColor DarkCyan
                & systemctl --user start deronode.service 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[!] systemctl --user start returned $($LASTEXITCODE) - check 'journalctl --user -u deronode.service'" -ForegroundColor Yellow
                } else {
                    Write-Host '[*] started deronode.service' -ForegroundColor Green
                }
                return
            }
            New-Item -ItemType Directory -Path $unitDir -Force | Out-Null
            @"
[Unit]
Description=DERO node (deronode)
After=network.target

[Service]
Type=simple
ExecStart=$wrapper
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
"@ | Set-Content $unit -Encoding ASCII
            & systemctl --user daemon-reload
            & systemctl --user enable deronode.service 2>$null | Out-Null
            & systemctl --user start deronode.service 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[!] systemctl --user start returned $($LASTEXITCODE) — check 'journalctl --user -u deronode.service'" -ForegroundColor Yellow
            } else {
                Write-Host "[*] installed + started systemd user unit deronode.service" -ForegroundColor Green
            }
        }
        'launchd' {
            $plistDir = Join-Path $HOME 'Library/LaunchAgents'
            $plist = Join-Path $plistDir 'org.deronode.derod.plist'
            $existed = Test-Path $plist
            New-Item -ItemType Directory -Path $plistDir -Force | Out-Null
            $logFile = Join-Path $script:LogDirReal 'derod.out.log'
            $errLogFile = Join-Path $script:LogDirReal 'derod.err.log'
            @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>org.deronode.derod</string>
    <key>ProgramArguments</key>
    <array><string>$wrapper</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$logFile</string>
    <key>StandardErrorPath</key><string>$errLogFile</string>
</dict>
</plist>
"@ | Set-Content $plist -Encoding ASCII
            & launchctl unload $plist 2>$null | Out-Null
            & launchctl load $plist 2>$null | Out-Null
            if ($existed) {
                Write-Host "[*] org.deronode.derod is already configured - starting it" -ForegroundColor DarkCyan
            } else {
                Write-Host "[*] installed + started LaunchAgent org.deronode.derod" -ForegroundColor Green
            }
        }
        default {
            Start-Background
        }
    }
}

function Start-Background {
    $wrapper = Write-RunWrapper
    New-Item -ItemType Directory -Path $script:LogDirReal -Force | Out-Null
    $log = Join-Path $script:LogDirReal 'derod.out.log'
    $errLog = Join-Path $script:LogDirReal 'derod.err.log'
    $hostExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $psi = @{
        FilePath               = $hostExe
        ArgumentList           = @('-NoProfile', '-File', $wrapper)
        RedirectStandardOutput = $log
        RedirectStandardError  = $errLog
        PassThru               = $true
    }
    # -WindowStyle only exists on Windows; PowerShell on Linux/macOS rejects the
    # parameter outright ("not supported for the cmdlet 'Start-Process'...").
    if ($script:IsWindows) { $psi.WindowStyle = 'Hidden' }
    $p = Start-Process @psi
    # Only record the pid when we actually have one — a failed Start-Process
    # must not leave an empty derod.pid, which the running-guards treat as
    # "derod is running".
    if ($p.Id) {
        Set-Content (Join-Path $InstallDir 'derod.pid') $p.Id -NoNewline
    }
    Write-Host "[*] derod started in background (pid $($p.Id))" -ForegroundColor Green
    Write-Host "    log: $log"
}

function Stop-Service {
    switch (Get-ServiceBackend) {
        'systemd' {
            & systemctl --user stop deronode.service 2>$null | Out-Null
        }
        'launchd' {
            $plist = Join-Path $HOME 'Library/LaunchAgents/org.deronode.derod.plist'
            & launchctl unload $plist 2>$null | Out-Null
        }
    }
    # Safety net: regardless of backend, never leave OUR binary running.
    $pidFile = Join-Path $InstallDir 'derod.pid'
    if (Test-Path $pidFile) {
        $pid = [int](Get-Content $pidFile -Raw).Trim()
        Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    }
    Get-ProcessTable |
        Where-Object { $_.Name -like 'derod*' -and $_.CommandLine -like "*$BinaryPath*" } |
        ForEach-Object { Stop-Process -Id $_.Pid -Force -ErrorAction SilentlyContinue }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    Write-Host "[*] derod stopped" -ForegroundColor Green
}