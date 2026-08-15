# lib/platform.ps1 — OS / arch / Termux detection.

function Get-PwshPlatform {
    $os = 'linux'
    $arch = 'amd64'
    if ($IsLinux) { $os = 'linux' }
    elseif ($IsMacOS) { $os = 'darwin' }
    elseif ($IsWindows) { $os = 'windows' }
    elseif ($env:OS -eq 'Windows_NT') { $os = 'windows' }
    else {
        $dotNet = [System.Environment]::OSVersion.Platform
        if ($dotNet -eq [System.PlatformID]::Win32NT) { $os = 'windows' }
        elseif ($dotNet -eq [System.PlatformID]::MacOSX) { $os = 'darwin' }
        elseif ($dotNet -eq [System.PlatformID]::Unix) { $os = 'linux' }
    }

    $procArch = $env:PROCESSOR_ARCHITECTURE
    if ($procArch -eq 'x86' -and $env:PROCESSOR_ARCHITEW6432) { $procArch = $env:PROCESSOR_ARCHITEW6432 }
    if (-not $procArch) { $procArch = $env:PROCESSOR_ARCHITEW6432 }
    if ($procArch -match 'ARM64|arm64|aarch64') { $arch = 'aarch64' }
    elseif ($procArch -match 'AMD64|amd64|x86_64|x64') { $arch = 'amd64' }
    elseif ($procArch -match 'ARM|arm') { $arch = 'arm' }
    elseif ($os -ne 'windows' -and (Get-Command uname -ErrorAction SilentlyContinue)) {
        $unameArch = (& uname -m 2>$null) -as [string]
        if ($unameArch -match 'aarch64|arm64') { $arch = 'aarch64' }
        elseif ($unameArch -match '^armv7') { $arch = 'arm' }
        elseif ($unameArch -match '^armv8') { $arch = 'aarch64' }
    }
    return [PSCustomObject]@{ os = $os; arch = $arch }
}

function Test-IsTermux {
    return [bool]($env:PREFIX -and ($env:PREFIX -match 'com\.termux') -and (Test-Path (Join-Path $env:PREFIX 'bin')))
}

function Get-CatalogKey {
    param([object]$Platform)
    $os = if ($Platform.os -eq 'darwin') { 'darwin' } else { $Platform.os }
    $arch = if ($Platform.os -eq 'darwin') { '*' } else { $Platform.arch }
    return [PSCustomObject]@{ os = $os; arch = $arch }
}