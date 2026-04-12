# TarkovMetora - Update Script
# Silently checks for a newer version and downloads if available.
# If the server is unreachable or the check fails for any reason, continues normally.

$SCRIPT_DIR    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$VERSION_FILE  = Join-Path $SCRIPT_DIR "version.txt"
$MAIN_SCRIPT   = Join-Path $SCRIPT_DIR "tarkovmetora.ps1"
$BACKUP_SCRIPT = Join-Path $SCRIPT_DIR "tarkovmetora.bak.ps1"
$UPDATE_BRANCH = "claude/build-tarkov-metora-Qy3IA"
$REPO          = "Jimily412/TarkovMetora"
$BASE_URL      = "https://raw.githubusercontent.com/$REPO/$UPDATE_BRANCH"

function Write-UpdateLog($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [UPDATE] $msg" -ForegroundColor DarkGray
}

# If anything fails at any point, silently continue - never block startup
try {
    if (-not (Test-Path $VERSION_FILE)) { exit 0 }

    $localVersion = (Get-Content $VERSION_FILE -ErrorAction Stop).Trim()

    $wr = $null
    try {
        $wr = Invoke-WebRequest -Uri "$BASE_URL/version.txt" `
            -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    } catch {
        # Server unreachable, repo private, or no network - silent exit
        exit 0
    }

    if ($wr.StatusCode -ne 200) { exit 0 }

    $remoteVersion = $wr.Content.Trim()
    if ([string]::IsNullOrWhiteSpace($remoteVersion)) { exit 0 }
    if ($remoteVersion -eq $localVersion) { exit 0 }

    Write-UpdateLog "Updating $localVersion -> $remoteVersion ..."

    if (Test-Path $MAIN_SCRIPT) {
        Copy-Item $MAIN_SCRIPT $BACKUP_SCRIPT -Force -ErrorAction SilentlyContinue
    }

    try {
        Invoke-WebRequest -Uri "$BASE_URL/tarkovmetora.ps1" `
            -OutFile $MAIN_SCRIPT -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        Set-Content $VERSION_FILE $remoteVersion -Encoding UTF8
        Write-UpdateLog "Updated to $remoteVersion."
    } catch {
        # Download failed - restore backup and continue with old version
        if (Test-Path $BACKUP_SCRIPT) {
            Copy-Item $BACKUP_SCRIPT $MAIN_SCRIPT -Force -ErrorAction SilentlyContinue
        }
    }

} catch {
    # Catch-all - never let the updater crash the launcher
}
