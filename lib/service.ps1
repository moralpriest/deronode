# lib/service.ps1 — start/stop/install for the derod process.
# Backend: systemd user unit (Linux), launchctl (macOS), nohup + pid (Windows).

function Write-RunWrapper {
    $wrapper = Join-Path $InstallDir 'run-derod.ps1'
    $argv = Build-DerodArgv
    $argLine = ($argv | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
    $content = @"
`$ErrorActionPreference = 'Stop'
& '$BinaryPath' $argLine
"@
    Set-Content $wrapper $content -Encoding UTF8
    return $wrapper
}

function Get-ServiceBackend {
    if ($IsLinux -and (Get-Command systemctl -ErrorAction SilentlyContinue)) {
        $st = & systemctl --user is-system-running 2>$null
        if ($LASTEXITCODE -eq 0) { return 'systemd' }
    }
    if ($IsMacOS) { return 'launchd' }
    return 'pid'
}

function Install-Service {
    $wrapper = Write-RunWrapper
    switch (Get-ServiceBackend) {
        'systemd' {
            $unitDir = Join-Path $HOME '.config/systemd/user'
            New-Item -ItemType Directory -Path $unitDir -Force | Out-Null
            $unit = Join-Path $unitDir 'deronode.service'
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
            Write-Host "[*] installed + started systemd user unit deronode.service" -ForegroundColor Green
        }
        'launchd' {
            $plistDir = Join-Path $HOME 'Library/LaunchAgents'
            New-Item -ItemType Directory -Path $plistDir -Force | Out-Null
            $plist = Join-Path $plistDir 'org.deronode.derod.plist'
            $logFile = Join-Path $script:LogDirReal 'derod.log'
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
    <key>StandardErrorPath</key><string>$logFile</string>
</dict>
</plist>
"@ | Set-Content $plist -Encoding ASCII
            & launchctl unload $plist 2>$null | Out-Null
            & launchctl load $plist 2>$null | Out-Null
            Write-Host "[*] installed + started LaunchAgent org.deronode.derod" -ForegroundColor Green
        }
        default {
            Start-Background
        }
    }
}

function Start-Background {
    $wrapper = Write-RunWrapper
    New-Item -ItemType Directory -Path $script:LogDirReal -Force | Out-Null
    $log = Join-Path $script:LogDirReal 'derod.log'
    $hostExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $p = Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-File', $wrapper) -RedirectStandardOutput $log -RedirectStandardError $log -WindowStyle Hidden -PassThru
    Set-Content (Join-Path $InstallDir 'derod.pid') $p.Id -NoNewline
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
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -like "$BinaryPath*" -or $_.CommandLine -like "*$BinaryPath*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    Write-Host "[*] derod stopped" -ForegroundColor Green
}