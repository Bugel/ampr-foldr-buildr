@echo off
setlocal
set "SCRIPT=%~dp0ampr-foldr-buildr.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
