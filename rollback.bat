@echo off
title TarkovMetora - Rollback
cd /d "%~dp0"
if not exist "%~dp0tarkovmetora.bak.ps1" (
    echo No backup file found. Cannot rollback.
    pause
    exit /b 1
)
copy /y "%~dp0tarkovmetora.bak.ps1" "%~dp0tarkovmetora.ps1"
echo Rollback complete. tarkovmetora.ps1 restored from backup.
pause
