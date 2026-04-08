# TarkovMetora v1.0.0
# Real-time Tarkov companion: auto-screenshot key sender + live map in browser
# All string literals ASCII only. No Clear-Host. No non-ASCII characters.

param()

$VERSION    = "1.0.0"
$APP_NAME   = "TarkovMetora"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition
$CONFIG_FILE= Join-Path $SCRIPT_DIR "config.json"
$LOG_FILE   = Join-Path $SCRIPT_DIR "tarkovmetora.log"
$CACHE_DIR  = Join-Path $SCRIPT_DIR "cache"
$WEB_DIR    = Join-Path $SCRIPT_DIR "web"
$MAP_CACHE  = Join-Path $CACHE_DIR "mapdata.json"

# ─── P/Invoke type for PostMessage ────────────────────────────────────────────
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32PostMsg {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@ -ErrorAction Stop

# ─── Logging ──────────────────────────────────────────────────────────────────
function Write-Log($msg, $color = "Gray") {
    $ts  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    try { Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8 -ErrorAction Stop } catch {}
    Write-Host $line -ForegroundColor $color
}

function Write-LogError($msg, $err) {
    Write-Log "ERROR: $msg - $($err.Exception.Message)" "Red"
}

function Rotate-Log {
    try {
        if (Test-Path $LOG_FILE) {
            $lines = Get-Content $LOG_FILE -ErrorAction Stop
            if ($lines.Count -gt 1000) {
                $lines | Select-Object -Last 800 | Set-Content $LOG_FILE -Encoding UTF8
                Write-Log "Log rotated to 800 lines." "DarkGray"
            }
        }
    } catch {}
}

# ─── Key send ─────────────────────────────────────────────────────────────────
$VK_MAP = @{
    "home"   = 0x24
    "f1"     = 0x70; "f2" = 0x71; "f3" = 0x72; "f4" = 0x73
    "f5"     = 0x74; "f6" = 0x75; "f7" = 0x76; "f8" = 0x77
    "f9"     = 0x78; "f10"= 0x79; "f11"= 0x7A; "f12"= 0x7B
    "insert" = 0x2D; "delete"= 0x2E; "end"= 0x23; "pageup"= 0x21; "pagedown"= 0x22
}

function Send-KeyToEFT($vk) {
    try {
        $eft = Get-Process -Name "EscapeFromTarkov" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $eft)                                { return "NoProcess" }
        if ($eft.MainWindowHandle -eq [IntPtr]::Zero) { return "NoHandle"  }
        [Win32PostMsg]::PostMessage($eft.MainWindowHandle, 0x0100, [IntPtr]$vk, [IntPtr]1)          | Out-Null
        Start-Sleep -Milliseconds 50
        [Win32PostMsg]::PostMessage($eft.MainWindowHandle, 0x0101, [IntPtr]$vk, [IntPtr]0xC0000001) | Out-Null
        return "Sent"
    } catch {
        Write-LogError "Send-KeyToEFT failed" $_
        return "Error"
    }
}

# ─── Purge ────────────────────────────────────────────────────────────────────
function Purge-Old($dir) {
    $count = 0
    try {
        if (-not (Test-Path $dir)) { Write-Log "Purge: folder not found - $dir" "Red"; return 0 }
        $cutoff = (Get-Date).AddSeconds(-30)
        $files  = @(Get-ChildItem -Path $dir -File -ErrorAction Stop)
        foreach ($f in $files) {
            if ($f.LastWriteTime -lt $cutoff) {
                try { Remove-Item $f.FullName -Force -ErrorAction Stop; $count++ } catch {}
            }
        }
        if ($count -gt 0) {
            $remaining = $files.Count - $count
            Write-Log "Purge: deleted $count file(s). Remaining: $remaining" "DarkGray"
        }
    } catch { Write-LogError "Purge-Old failed" $_ }
    return $count
}

# ─── Map bounds ───────────────────────────────────────────────────────────────
$MAP_BOUNDS = @{
    "customs"     = @{ xMin=-500;  xMax=500;  yMin=-50;  yMax=100;  zMin=-500; zMax=500  }
    "woods"       = @{ xMin=-900;  xMax=900;  yMin=-50;  yMax=400;  zMin=-900; zMax=900  }
    "factory"     = @{ xMin=-200;  xMax=200;  yMin=-50;  yMax=50;   zMin=-200; zMax=200  }
    "shoreline"   = @{ xMin=-600;  xMax=800;  yMin=-50;  yMax=300;  zMin=-600; zMax=800  }
    "reserve"     = @{ xMin=-600;  xMax=600;  yMin=-150; yMax=100;  zMin=-600; zMax=600  }
    "interchange" = @{ xMin=-600;  xMax=600;  yMin=-50;  yMax=100;  zMin=-600; zMax=600  }
    "lighthouse"  = @{ xMin=-600;  xMax=800;  yMin=-50;  yMax=400;  zMin=-800; zMax=800  }
    "streets"     = @{ xMin=-600;  xMax=600;  yMin=-50;  yMax=200;  zMin=-600; zMax=600  }
    "labs"        = @{ xMin=-300;  xMax=300;  yMin=-100; yMax=-10;  zMin=-300; zMax=300  }
    "groundzero"  = @{ xMin=-400;  xMax=400;  yMin=-50;  yMax=150;  zMin=-400; zMax=400  }
}

function Get-MapFromCoords($x, $y, $z) {
    foreach ($map in $MAP_BOUNDS.Keys) {
        $b = $MAP_BOUNDS[$map]
        if ($x -ge $b.xMin -and $x -le $b.xMax -and
            $y -ge $b.yMin -and $y -le $b.yMax -and
            $z -ge $b.zMin -and $z -le $b.zMax) {
            return $map
        }
    }
    return "unknown"
}

# ─── Config ───────────────────────────────────────────────────────────────────
function Get-DefaultScreenshotDir {
    $userProfile = [Environment]::GetFolderPath("MyDocuments")
    return Join-Path $userProfile "Escape from Tarkov\Screenshots"
}

function New-Config {
    Write-Host ""
    Write-Host "=== $APP_NAME v$VERSION - First Run Setup ===" -ForegroundColor Cyan
    Write-Host ""

    $defaultDir = Get-DefaultScreenshotDir
    Write-Host "Screenshot folder (default: $defaultDir):"
    $dir = Read-Host "  Press Enter to use default, or type path"
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $defaultDir }

    Write-Host ""
    Write-Host "Your in-game name (used to label your marker on squad maps):"
    $playerName = Read-Host "  Player name"

    Write-Host ""
    Write-Host "Mode - are you hosting the session or joining another player's?"
    Write-Host "  [1] Host (default)"
    Write-Host "  [2] Client (connect to another player's TarkovMetora)"
    $modeInput = Read-Host "  Choice"
    $mode = if ($modeInput -eq "2") { "client" } else { "host" }

    $hostUrl = ""
    if ($mode -eq "client") {
        Write-Host ""
        Write-Host "Enter host URL (e.g. http://192.168.1.50:7472):"
        $hostUrl = Read-Host "  Host URL"
    }

    Write-Host ""
    Write-Host "HTTP port (default: 7472):"
    $portInput = Read-Host "  Port (Enter for 7472)"
    $port = if ([string]::IsNullOrWhiteSpace($portInput)) { 7472 } else { [int]$portInput }

    $cfg = [ordered]@{
        screenshot_dir   = $dir
        interval_seconds = 5
        screenshot_key   = "home"
        port             = $port
        player_name      = $playerName
        mode             = $mode
        host_url         = $hostUrl
        squad            = @()
    }

    $cfg | ConvertTo-Json -Depth 5 | Set-Content $CONFIG_FILE -Encoding UTF8
    Write-Log "Config saved to $CONFIG_FILE" "Green"
    return $cfg
}

function Load-Config {
    if (-not (Test-Path $CONFIG_FILE)) {
        return New-Config
    }
    try {
        $raw = Get-Content $CONFIG_FILE -Raw -ErrorAction Stop
        $cfg = $raw | ConvertFrom-Json
        # Normalize
        if ([string]::IsNullOrWhiteSpace($cfg.screenshot_dir)) {
            $cfg.screenshot_dir = Get-DefaultScreenshotDir
        }
        if (-not $cfg.interval_seconds -or $cfg.interval_seconds -lt 1) { $cfg.interval_seconds = 5 }
        if ([string]::IsNullOrWhiteSpace($cfg.screenshot_key))           { $cfg.screenshot_key = "home" }
        if (-not $cfg.port -or $cfg.port -lt 1)                          { $cfg.port = 7472 }
        if ([string]::IsNullOrWhiteSpace($cfg.mode))                     { $cfg.mode = "host" }
        return $cfg
    } catch {
        Write-LogError "Failed to load config" $_
        return New-Config
    }
}

# ─── tarkov.dev API cache ─────────────────────────────────────────────────────
function Get-MapData {
    $cacheMaxAge = 24 * 3600  # 24 hours in seconds
    $fresh = $false

    if (Test-Path $MAP_CACHE) {
        $age = ((Get-Date) - (Get-Item $MAP_CACHE).LastWriteTime).TotalSeconds
        if ($age -lt $cacheMaxAge) { $fresh = $true }
    }

    if ($fresh) {
        Write-Log "Map data cache is fresh - using cached data." "DarkGray"
        try {
            return (Get-Content $MAP_CACHE -Raw) | ConvertFrom-Json
        } catch {
            Write-LogError "Failed to read map cache" $_
        }
    }

    Write-Log "Fetching map data from tarkov.dev..." "Cyan"
    $query = '{"query":"{ maps { id name normalizedName bosses { boss { name } spawnChance spawnLocations { name chance } } extracts { id name faction position { x y z } } spawns { position { x y z } sides categories } } }"}'

    try {
        $resp = Invoke-RestMethod -Uri "https://api.tarkov.dev/graphql" `
            -Method Post `
            -Body $query `
            -ContentType "application/json" `
            -TimeoutSec 30 `
            -ErrorAction Stop

        if (-not (Test-Path $CACHE_DIR)) { New-Item -ItemType Directory -Path $CACHE_DIR | Out-Null }
        $resp | ConvertTo-Json -Depth 20 | Set-Content $MAP_CACHE -Encoding UTF8
        Write-Log "Map data cached to $MAP_CACHE" "Green"
        return $resp
    } catch {
        Write-LogError "Failed to fetch map data from tarkov.dev" $_
        if (Test-Path $MAP_CACHE) {
            Write-Log "Using stale cache as fallback." "Yellow"
            try { return (Get-Content $MAP_CACHE -Raw) | ConvertFrom-Json } catch {}
        }
        return $null
    }
}

# ─── State shared between watcher, loop, and HTTP server ─────────────────────
$script:currentPosition = $null   # { x, y, z, qw, qx, qy, qz, map, ts }
$script:currentMap      = "unknown"
$script:inRaid          = $false
$script:sessionCount    = 0
$script:squadData       = @{}     # keyed by player name
$script:sseClients      = [System.Collections.Generic.List[System.Net.HttpListenerResponse]]::new()
$script:sseClientsLock  = [System.Object]::new()
$script:mapData         = $null

# ─── SSE helpers ──────────────────────────────────────────────────────────────
function Send-SSE($data) {
    $json = $data | ConvertTo-Json -Depth 5 -Compress
    $msg  = "data: $json`n`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)

    $dead = [System.Collections.Generic.List[System.Net.HttpListenerResponse]]::new()
    [System.Threading.Monitor]::Enter($script:sseClientsLock)
    try {
        foreach ($client in $script:sseClients) {
            try {
                $client.OutputStream.Write($bytes, 0, $bytes.Length)
                $client.OutputStream.Flush()
            } catch {
                $dead.Add($client)
            }
        }
        foreach ($d in $dead) { $script:sseClients.Remove($d) | Out-Null }
    } finally {
        [System.Threading.Monitor]::Exit($script:sseClientsLock)
    }
}

function Broadcast-Position($pos) {
    $payload = @{
        type       = "position"
        player     = $script:cfg.player_name
        x          = $pos.x
        y          = $pos.y
        z          = $pos.z
        qw         = $pos.qw
        qx         = $pos.qx
        qy         = $pos.qy
        qz         = $pos.qz
        map        = $pos.map
        ts         = $pos.ts
    }
    Send-SSE $payload
}

function Broadcast-Status {
    $payload = @{
        type        = "status"
        eftRunning  = ($script:lastEftState -ne "NoProcess")
        inRaid      = $script:inRaid
        map         = $script:currentMap
        version     = $VERSION
        sessionCount= $script:sessionCount
    }
    Send-SSE $payload
}

# ─── FileSystemWatcher ────────────────────────────────────────────────────────
function Start-Watcher($dir) {
    if (-not (Test-Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {}
    }

    $watcher                   = New-Object System.IO.FileSystemWatcher
    $watcher.Path              = $dir
    $watcher.Filter            = "*.*"
    $watcher.NotifyFilter      = [System.IO.NotifyFilters]::FileName
    $watcher.EnableRaisingEvents = $true

    $action = {
        $path = $Event.SourceEventArgs.FullPath
        $name = [System.IO.Path]::GetFileName($path)

        if ($name -match '_(-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+)_(-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+)_') {
            $x  = [float]$Matches[1]; $y  = [float]$Matches[2]; $z  = [float]$Matches[3]
            $qw = [float]$Matches[4]; $qx = [float]$Matches[5]; $qy = [float]$Matches[6]; $qz = [float]$Matches[7]
            $map = Get-MapFromCoords $x $y $z

            $pos = @{ x=$x; y=$y; z=$z; qw=$qw; qx=$qx; qy=$qy; qz=$qz; map=$map; ts=(Get-Date -Format "o") }
            $script:currentPosition = $pos
            $script:currentMap      = $map
            $script:inRaid          = $true
            $script:sessionCount++

            Broadcast-Position $pos

            try { Remove-Item $path -Force -ErrorAction Stop } catch {}
        } else {
            # Non-coordinate file - will be cleaned up by Purge-Old
            $script:inRaid = $false
        }
    }

    Register-ObjectEvent -InputObject $watcher -EventName "Created" -SourceIdentifier "EFTScreenshot" -Action $action | Out-Null
    Write-Log "FileSystemWatcher active on: $dir" "Green"
    return $watcher
}

# ─── HTTP Server ──────────────────────────────────────────────────────────────
function Get-MimeType($ext) {
    switch ($ext.ToLower()) {
        ".html" { return "text/html; charset=utf-8" }
        ".js"   { return "application/javascript; charset=utf-8" }
        ".css"  { return "text/css; charset=utf-8" }
        ".json" { return "application/json; charset=utf-8" }
        ".png"  { return "image/png" }
        ".jpg"  { return "image/jpeg" }
        ".svg"  { return "image/svg+xml" }
        default { return "application/octet-stream" }
    }
}

function Serve-File($resp, $path) {
    if (-not (Test-Path $path)) {
        $resp.StatusCode = 404
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
        $resp.ContentLength64 = $bytes.Length
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
        $resp.OutputStream.Close()
        return
    }
    $ext   = [System.IO.Path]::GetExtension($path)
    $mime  = Get-MimeType $ext
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $resp.ContentType     = $mime
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Serve-JSON($resp, $obj) {
    $json  = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $resp.ContentType     = "application/json; charset=utf-8"
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Start-HttpServer($port) {
    $prefix = if ($script:cfg.mode -eq "host") { "http://+:$port/" } else { "http://localhost:$port/" }
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
        Write-Log "HTTP server listening on $prefix" "Green"
        Write-Log "Open browser: http://localhost:$port" "Cyan"
    } catch {
        Write-LogError "Failed to start HTTP server on port $port" $_
        Write-Log "Try running as Administrator if port binding fails." "Yellow"
        return $null
    }
    return $listener
}

function Handle-Request($ctx) {
    $req  = $ctx.Request
    $resp = $ctx.Response
    $url  = $req.Url.AbsolutePath.TrimEnd('/')

    try {
        # SSE endpoint
        if ($url -eq "/events") {
            $resp.ContentType = "text/event-stream"
            $resp.Headers.Add("Cache-Control", "no-cache")
            $resp.Headers.Add("Access-Control-Allow-Origin", "*")
            $resp.SendChunked = $true

            # Send initial state
            $initBytes = [System.Text.Encoding]::UTF8.GetBytes("data: {`"type`":`"connected`"}`n`n")
            $resp.OutputStream.Write($initBytes, 0, $initBytes.Length)
            $resp.OutputStream.Flush()

            [System.Threading.Monitor]::Enter($script:sseClientsLock)
            try { $script:sseClients.Add($resp) } finally { [System.Threading.Monitor]::Exit($script:sseClientsLock) }

            # Immediately push current state
            Broadcast-Status
            if ($script:currentPosition) { Broadcast-Position $script:currentPosition }

            # Do NOT close — keep alive for SSE
            return
        }

        # CORS preflight
        if ($req.HttpMethod -eq "OPTIONS") {
            $resp.Headers.Add("Access-Control-Allow-Origin", "*")
            $resp.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $resp.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
            $resp.StatusCode = 204
            $resp.OutputStream.Close()
            return
        }

        $resp.Headers.Add("Access-Control-Allow-Origin", "*")

        if ($url -eq "" -or $url -eq "/") {
            Serve-File $resp (Join-Path $WEB_DIR "index.html")
            return
        }

        if ($url -match '^/web/(.+)$') {
            Serve-File $resp (Join-Path $WEB_DIR $Matches[1])
            return
        }

        if ($url -match '^/cache/(.+)$') {
            Serve-File $resp (Join-Path $CACHE_DIR $Matches[1])
            return
        }

        if ($url -eq "/api/status") {
            Serve-JSON $resp @{
                eftRunning   = ($script:lastEftState -ne "NoProcess" -and $script:lastEftState -ne "")
                inRaid       = $script:inRaid
                map          = $script:currentMap
                version      = $VERSION
                sessionCount = $script:sessionCount
            }
            return
        }

        if ($url -eq "/api/position") {
            if ($script:currentPosition) {
                Serve-JSON $resp $script:currentPosition
            } else {
                Serve-JSON $resp @{ error = "no position data" }
            }
            return
        }

        if ($url -eq "/api/squad") {
            $results = @()
            foreach ($member in $script:cfg.squad) {
                if ([string]::IsNullOrWhiteSpace($member)) { continue }
                try {
                    $memberData = Invoke-RestMethod -Uri "$($script:cfg.host_url)/api/position" -TimeoutSec 3 -ErrorAction Stop
                    $results += $memberData
                } catch {}
            }
            Serve-JSON $resp $results
            return
        }

        if ($url -eq "/api/mapdata") {
            if (Test-Path $MAP_CACHE) {
                Serve-File $resp $MAP_CACHE
            } else {
                Serve-JSON $resp @{ error = "no map data cached" }
            }
            return
        }

        # 404
        $resp.StatusCode = 404
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("Not Found: $url")
        $resp.ContentLength64 = $bytes.Length
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
        $resp.OutputStream.Close()

    } catch {
        try {
            $resp.StatusCode = 500
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("Server Error")
            $resp.ContentLength64 = $bytes.Length
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            $resp.OutputStream.Close()
        } catch {}
    }
}

# ─── HTTP listener loop (runs in runspace) ────────────────────────────────────
function Start-HttpLoop($listener) {
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()

    # Share state variables with the runspace
    $rs.SessionStateProxy.SetVariable("script_sseClients",    $script:sseClients)
    $rs.SessionStateProxy.SetVariable("script_sseClientsLock",$script:sseClientsLock)
    $rs.SessionStateProxy.SetVariable("WEB_DIR",  $WEB_DIR)
    $rs.SessionStateProxy.SetVariable("CACHE_DIR",$CACHE_DIR)
    $rs.SessionStateProxy.SetVariable("VERSION",  $VERSION)
    $rs.SessionStateProxy.SetVariable("listener", $listener)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    # Pass functions and shared refs via a script block that references $using:
    # Because we can't easily share all state, we use a simpler design:
    # The HTTP loop in the runspace handles static files and calls back via thread-safe queues.
    # For simplicity and reliability, we use the main thread's listener via BeginGetContext.

    $ps.AddScript({
        param($listener, $webDir, $cacheDir, $version, $sseClients, $sseClientsLock)

        function Get-MimeType2($ext) {
            switch ($ext.ToLower()) {
                ".html" { return "text/html; charset=utf-8" }
                ".js"   { return "application/javascript; charset=utf-8" }
                ".css"  { return "text/css; charset=utf-8" }
                ".json" { return "application/json; charset=utf-8" }
                ".png"  { return "image/png" }
                ".svg"  { return "image/svg+xml" }
                default { return "application/octet-stream" }
            }
        }

        while ($listener.IsListening) {
            try {
                $ctx  = $listener.GetContext()
                $req  = $ctx.Request
                $resp = $ctx.Response
                $url  = $req.Url.AbsolutePath.TrimEnd('/')

                $resp.Headers.Add("Access-Control-Allow-Origin", "*")

                if ($url -eq "/events") {
                    $resp.ContentType = "text/event-stream"
                    $resp.Headers.Add("Cache-Control", "no-cache")
                    $resp.SendChunked = $true
                    $initBytes = [System.Text.Encoding]::UTF8.GetBytes("data: {`"type`":`"connected`"}`n`n")
                    $resp.OutputStream.Write($initBytes, 0, $initBytes.Length)
                    $resp.OutputStream.Flush()
                    [System.Threading.Monitor]::Enter($sseClientsLock)
                    try { $sseClients.Add($resp) } finally { [System.Threading.Monitor]::Exit($sseClientsLock) }
                    continue
                }

                $sendFile = {
                    param($r, $p)
                    if (-not (Test-Path $p)) {
                        $r.StatusCode = 404
                        $b = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
                        $r.ContentLength64 = $b.Length
                        $r.OutputStream.Write($b, 0, $b.Length)
                        $r.OutputStream.Close(); return
                    }
                    $ext  = [System.IO.Path]::GetExtension($p)
                    $mime = Get-MimeType2 $ext
                    $b = [System.IO.File]::ReadAllBytes($p)
                    $r.ContentType     = $mime
                    $r.ContentLength64 = $b.Length
                    $r.OutputStream.Write($b, 0, $b.Length)
                    $r.OutputStream.Close()
                }

                $sendJson = {
                    param($r, $obj)
                    $j = $obj | ConvertTo-Json -Depth 10 -Compress
                    $b = [System.Text.Encoding]::UTF8.GetBytes($j)
                    $r.ContentType     = "application/json; charset=utf-8"
                    $r.ContentLength64 = $b.Length
                    $r.OutputStream.Write($b, 0, $b.Length)
                    $r.OutputStream.Close()
                }

                switch -Regex ($url) {
                    '^/?$' {
                        & $sendFile $resp (Join-Path $webDir "index.html")
                    }
                    '^/web/(.+)$' {
                        & $sendFile $resp (Join-Path $webDir $Matches[1])
                    }
                    '^/cache/(.+)$' {
                        & $sendFile $resp (Join-Path $cacheDir $Matches[1])
                    }
                    '^/api/status$' {
                        # Status is pushed via SSE; polling fallback returns last known
                        & $sendJson $resp @{ version=$version; note="use SSE /events for live data" }
                    }
                    '^/api/mapdata$' {
                        $mp = Join-Path $cacheDir "mapdata.json"
                        if (Test-Path $mp) { & $sendFile $resp $mp }
                        else { & $sendJson $resp @{ error="no map data" } }
                    }
                    default {
                        $resp.StatusCode = 404
                        $b = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
                        $resp.ContentLength64 = $b.Length
                        $resp.OutputStream.Write($b, 0, $b.Length)
                        $resp.OutputStream.Close()
                    }
                }
            } catch [System.Net.HttpListenerException] {
                break
            } catch {
                try { $ctx.Response.OutputStream.Close() } catch {}
            }
        }
    }) | Out-Null

    $ps.AddArgument($listener) | Out-Null
    $ps.AddArgument($WEB_DIR)  | Out-Null
    $ps.AddArgument($CACHE_DIR)| Out-Null
    $ps.AddArgument($VERSION)  | Out-Null
    $ps.AddArgument($script:sseClients) | Out-Null
    $ps.AddArgument($script:sseClientsLock) | Out-Null

    $handle = $ps.BeginInvoke()
    return @{ ps=$ps; rs=$rs; handle=$handle }
}

# ─── Client mode: forward own position to host ────────────────────────────────
function Push-PositionToHost($pos) {
    if ($script:cfg.mode -ne "client") { return }
    if ([string]::IsNullOrWhiteSpace($script:cfg.host_url)) { return }
    try {
        $body = @{
            player = $script:cfg.player_name
            x=$pos.x; y=$pos.y; z=$pos.z
            qw=$pos.qw; qx=$pos.qx; qy=$pos.qy; qz=$pos.qz
            map=$pos.map; ts=$pos.ts
        } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$($script:cfg.host_url)/api/squad/update" `
            -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

# ─── Startup ──────────────────────────────────────────────────────────────────
Rotate-Log
Write-Log "=== $APP_NAME v$VERSION starting ===" "Cyan"

$script:cfg = Load-Config

if (-not (Test-Path $CACHE_DIR)) { New-Item -ItemType Directory -Path $CACHE_DIR -Force | Out-Null }
if (-not (Test-Path $WEB_DIR))   { New-Item -ItemType Directory -Path $WEB_DIR   -Force | Out-Null }

# Resolve VK code
$vk = $VK_MAP[$script:cfg.screenshot_key.ToLower()]
if (-not $vk) {
    Write-Log "Unknown screenshot_key '$($script:cfg.screenshot_key)' - defaulting to home (0x24)" "Yellow"
    $vk = 0x24
}
Write-Log "Screenshot key: $($script:cfg.screenshot_key) (VK 0x$($vk.ToString('X2')))" "Gray"
Write-Log "Screenshot dir: $($script:cfg.screenshot_dir)" "Gray"
Write-Log "Interval: $($script:cfg.interval_seconds)s" "Gray"
Write-Log "Mode: $($script:cfg.mode)" "Gray"

# Fetch map data in background
$script:mapData = Get-MapData

# Start FileSystemWatcher
$watcher = Start-Watcher $script:cfg.screenshot_dir

# Start HTTP server
$listener = Start-HttpServer $script:cfg.port
if ($listener) {
    $httpJob = Start-HttpLoop $listener
}

Write-Log "Press SPACE to pause/resume. Press CTRL+C to exit." "Yellow"
Write-Log "" "Gray"

# ─── Main loop ────────────────────────────────────────────────────────────────
$loopCount     = 0
$lastEftState  = ""
$script:lastEftState = ""
$paused        = $false

try {
    while ($true) {
        $loopStart = Get-Date
        $loopCount++

        if ($loopCount % 10 -eq 0) { Rotate-Log }

        # Check for spacebar pause
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Spacebar) {
                $paused = -not $paused
                Write-Log $(if ($paused) { "PAUSED." } else { "RESUMED." }) "Yellow"
                Broadcast-Status
            }
        }

        if (-not $paused) {
            # Purge always first, always unconditional
            Purge-Old $script:cfg.screenshot_dir

            $keyResult = Send-KeyToEFT $vk
            $script:lastEftState = $keyResult

            if ($keyResult -ne $lastEftState) {
                switch ($keyResult) {
                    "NoProcess" { Write-Log "EFT not running." "DarkGray" }
                    "NoHandle"  { Write-Log "EFT found but no window handle - loading screen?" "DarkGray" }
                    "Sent"      { Write-Log "Key sent to EFT." "DarkGray" }
                    "Error"     { Write-Log "Key send error." "Red" }
                }
                $lastEftState = $keyResult
                Broadcast-Status
            }

            # Process any pending PowerShell events from the watcher
            Get-Event -SourceIdentifier "EFTScreenshot" -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue
            }
        }

        $elapsed = ((Get-Date) - $loopStart).TotalSeconds
        $wait    = $script:cfg.interval_seconds - $elapsed
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
    }
} finally {
    Write-Log "$APP_NAME shutting down." "Yellow"
    try { Unregister-Event -SourceIdentifier "EFTScreenshot" -ErrorAction SilentlyContinue } catch {}
    try { $watcher.EnableRaisingEvents = $false; $watcher.Dispose() } catch {}
    try { $listener.Stop(); $listener.Close() } catch {}
    try { $httpJob.ps.Stop(); $httpJob.rs.Close() } catch {}
}
