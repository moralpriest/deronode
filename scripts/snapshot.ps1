# scripts/snapshot.ps1 — standalone snapshot wrapper: `deronode snapshot`.
$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $ProjectDir
& (Join-Path $ProjectDir 'node.ps1') snapshot @args
exit $LASTEXITCODE