# lib/ui.ps1 — colors, banner, prompts.

function Get-TerminalWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -and $w -ge 80) { return $w }
    } catch {}
    return 80
}

function Test-IsUnicodeTerminal {
    try {
        $oem = [Console]::OutputEncoding
        if ($oem -and $oem.WebName -match 'utf-?8') { return $true }
    } catch {}
    if ($env:LANG -match '[Uu][Tt][Ff]-?8' -or $env:LC_ALL -match '[Uu][Tt][Ff]-?8') { return $true }
    return $false
}

$script:UnicodeBox = @{
    TopLeft = '╔'; TopRight = '╗'; BotLeft = '╚'; BotRight = '╝'
    Horiz = '═'; Vert = '║'; MenuDot = '·'
}
$script:AsciiBox = @{
    TopLeft = '+'; TopRight = '+'; BotLeft = '+'; BotRight = '+'
    Horiz = '='; Vert = '|'; MenuDot = '-'
}

function Get-BoxChars {
    if (Test-IsUnicodeTerminal) { return $script:UnicodeBox } else { return $script:AsciiBox }
}

function Write-Banner {
    param([string]$Version)
    $b = Get-BoxChars
    $title = "deronode v$Version"
    $subtitle = 'DERO node installer & manager'
    $menuHint = "[ MENU ]  start $($b.MenuDot) stop $($b.MenuDot) status $($b.MenuDot) update $($b.MenuDot) build $($b.MenuDot) snapshot $($b.MenuDot) restore $($b.MenuDot) resync $($b.MenuDot) logs $($b.MenuDot) quit"
    $width = [Math]::Min((Get-TerminalWidth), 100)
    $inner = [Math]::Max(30, $width - 2)
    $titlePad = [Math]::Max(0, $inner - $title.Length - 4)
    $subtitlePad = [Math]::Max(0, $inner - $subtitle.Length - 4)
    $hintPad = [Math]::Max(0, $inner - $menuHint.Length - 4)
    Write-Host ''
    Write-Host ($b.TopLeft + ($b.Horiz * $inner) + $b.TopRight) -ForegroundColor Magenta
    Write-Host ($b.Vert + '  ' + $title + (' ' * $titlePad) + '  ' + $b.Vert) -ForegroundColor White
    Write-Host ($b.Vert + '  ' + $subtitle + (' ' * $subtitlePad) + '  ' + $b.Vert) -ForegroundColor DarkGray
    Write-Host ($b.BotLeft + ($b.Horiz * $inner) + $b.BotRight) -ForegroundColor Magenta
    Write-Host ("  $menuHint") -ForegroundColor DarkGray
    Write-Host ''
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