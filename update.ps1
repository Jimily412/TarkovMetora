# TarkovMetora - Update Script
# Checks GitHub for a newer version and downloads if available

$SCRIPT_DIR   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$VERSION_FILE = Join-Path $SCRIPT_DIR "version.txt"
$MAIN_SCRIPT  = Join-Path $SCRIPT_DIR "tarkovmetora.ps1"
$BACKUP_SCRIPT= Join-Path $SCRIPT_DIR "tarkovmetora.bak.ps1"
$REMOTE_VERSION_URL = "https://raw.githubusercontent.com/jimily412/tarkovmetora/main/version.txt"
$REMOTE_SCRIPT_URL  = "https://raw.githubusercontent.com/jimily412/tarkovmetora/main/tarkovmetora.ps1"

function Write-UpdateLog($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [UPDATE] $msg"
}

try {
    if (-not (Test-Path $VERSION_FILE)) {
        Write-UpdateLog "version.txt not found - skipping update check."
        exit 0
    }

    $localVersion = (Get-Content $VERSION_FILE -ErrorAction Stop).Trim()
    Write-UpdateLog "Local version: $localVersion"

    try {
        $remoteVersion = (Invoke-WebRequest -Uri $REMOTE_VERSION_URL -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content.Trim()
    } catch {
        Write-UpdateLog "Could not reach update server - continuing with local version."
        exit 0
    }

    Write-UpdateLog "Remote version: $remoteVersion"

    if ($remoteVersion -eq $localVersion) {
        Write-UpdateLog "Already up to date."
        exit 0
    }

    Write-UpdateLog "New version available: $remoteVersion - downloading..."

    if (Test-Path $MAIN_SCRIPT) {
        Copy-Item $MAIN_SCRIPT $BACKUP_SCRIPT -Force
        Write-UpdateLog "Backed up current script to tarkovmetora.bak.ps1"
    }

    try {
        Invoke-WebRequest -Uri $REMOTE_SCRIPT_URL -OutFile $MAIN_SCRIPT -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        Set-Content $VERSION_FILE $remoteVersion -Encoding UTF8
        Write-UpdateLog "Update complete. Now at version $remoteVersion"
    } catch {
        Write-UpdateLog "Download failed - restoring backup."
        if (Test-Path $BACKUP_SCRIPT) {
            Copy-Item $BACKUP_SCRIPT $MAIN_SCRIPT -Force
        }
    }
} catch {
    Write-UpdateLog "Update check failed: $($_.Exception.Message)"
}
