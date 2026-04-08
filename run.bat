@echo off
title TarkovMetora
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tarkovmetora.ps1"
pause
