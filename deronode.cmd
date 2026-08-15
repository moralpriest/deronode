@echo off
rem deronode.cmd - unified launcher (Windows cmd)
rem Prefers pwsh, falls back to Windows PowerShell 5.1.
setlocal EnableDelayedExpansion
set "DIR=%~dp0"
if not exist "%DIR%node.ps1" set "DIR=%USERPROFILE%\.local\share\deronode\"
where pwsh >nul 2>nul
if not errorlevel 1 (
    pwsh -NoProfile -File "%DIR%node.ps1" %*
    exit /b !errorlevel!
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%node.ps1" %*
exit /b %errorlevel%