@echo off
setlocal
set "PS1=%~dp0agpool.ps1"
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
if "%~1"=="" pause
