# scripts/restore.ps1 — standalone restore wrapper: `deronode restore`.
$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $ProjectDir
& (Join-Path $ProjectDir 'node.ps1') restore @args
exit $LASTEXITCODE