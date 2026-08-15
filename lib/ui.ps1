# lib/ui.ps1 — colors, banner, prompts.

function Get-TerminalWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -and $w -ge 80) { return $w }
    } catch {}
    return 80
}

function Write-Banner {
    param([string]$Version)
    Write-Host ""
    Write-Host "  deronode v$Version - DERO node installer & manager" -ForegroundColor Cyan
    Write-Host "  derod only, from DEROFDN/derohe latest release. Explorer/wallet/miner excluded." -ForegroundColor DarkGray
    Write-Host ""
}

function Read-Ask {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) { Write-Host "${Prompt} [$Default]: " -NoNewline }
    else { Write-Host "${Prompt}: " -NoNewline }
    $ans = Read-Host
    if (-not $ans) { $ans = $Default }
    return $ans
}

function Read-YesNo {
    param([string]$Prompt, [string]$Default = 'n')
    $hint = if ($Default -eq 'y') { 'Y/n' } else { 'y/N' }
    Write-Host "$Prompt [$hint]: " -NoNewline
    $ans = (Read-Host).Trim().ToLowerInvariant()
    if (-not $ans) { $ans = $Default }
    return ($ans -in @('y', 'yes'))
}