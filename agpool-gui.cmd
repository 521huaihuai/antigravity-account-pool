@echo off
setlocal
set "PS1=%~dp0AgPool.Gui.ps1"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"
