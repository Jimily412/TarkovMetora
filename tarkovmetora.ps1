# TarkovMetora v1.0.0
# Real-time Tarkov companion: screenshot key sender + live browser map
# ASCII only. No Clear-Host. No non-ASCII characters anywhere.

param()

$VERSION    = "1.0.0"
$APP_NAME   = "TarkovMetora"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition
$CONFIG_FILE= Join-Path $SCRIPT_DIR "config.json"
$LOG_FILE   = Join-Path $SCRIPT_DIR "tarkovmetora.log"
$CACHE_DIR  = Join-Path $SCRIPT_DIR "cache"
$WEB_DIR    = Join-Path $SCRIPT_DIR "web"
$MAP_CACHE  = Join-Path $CACHE_DIR "mapdata.json"

# ---------------------------------------------------------------------------
# Win32 PostMessage (send key directly to EFT window handle)
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32PostMsg {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@ -ErrorAction Stop

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log($msg, $color = "Gray") {
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
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
            }
        }
    } catch {}
}

# ---------------------------------------------------------------------------
# Key send - PostMessage to EFT window, never system-wide
# ---------------------------------------------------------------------------
$VK_MAP = @{
    "home"     = 0x24
    "insert"   = 0x2D; "delete" = 0x2E; "end" = 0x23
    "pageup"   = 0x21; "pagedown" = 0x22
    "f1"=0x70; "f2"=0x71; "f3"=0x72;  "f4"=0x73
    "f5"=0x74; "f6"=0x75; "f7"=0x76;  "f8"=0x77
    "f9"=0x78; "f10"=0x79;"f11"=0x7A; "f12"=0x7B
}

function Send-KeyToEFT($vk) {
    try {
        $eft = Get-Process -Name "EscapeFromTarkov" -ErrorAction SilentlyContinue |
               Select-Object -First 1
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

# ---------------------------------------------------------------------------
# Purge - runs unconditionally every loop, no extension filter
# ---------------------------------------------------------------------------
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
            Write-Log "Purge: deleted $count file(s). Remaining: $($files.Count - $count)" "DarkGray"
        }
    } catch { Write-LogError "Purge-Old failed" $_ }
    return $count
}

# ---------------------------------------------------------------------------
# Map bounds - used in FSW action via MessageData
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
function Get-DefaultScreenshotDir {
    return Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Escape from Tarkov\Screenshots"
}

function New-Config {
    Write-Host ""
    Write-Host "=== $APP_NAME v$VERSION - First Run Setup ===" -ForegroundColor Cyan
    Write-Host ""

    $defaultDir = Get-DefaultScreenshotDir
    Write-Host "Screenshot folder (default: $defaultDir):"
    $dir = Read-Host "  Press Enter to accept, or type a custom path"
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $defaultDir }

    Write-Host ""
    Write-Host "Your in-game name:"
    $playerName = Read-Host "  Player name"

    Write-Host ""
    Write-Host "Are you the host, or connecting to another player?"
    Write-Host "  [1] Host (default)"
    Write-Host "  [2] Client"
    $modeInput = Read-Host "  Choice"
    $mode    = if ($modeInput -eq "2") { "client" } else { "host" }
    $hostUrl = ""
    if ($mode -eq "client") {
        Write-Host ""
        Write-Host "Host URL (e.g. http://192.168.1.50:7472):"
        $hostUrl = Read-Host "  URL"
    }

    Write-Host ""
    Write-Host "Port (default 7472):"
    $portInput = Read-Host "  Port"
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
    Write-Log "Config saved." "Green"
    return $cfg
}

function Load-Config {
    if (-not (Test-Path $CONFIG_FILE)) { return New-Config }
    try {
        $cfg = (Get-Content $CONFIG_FILE -Raw -ErrorAction Stop) | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($cfg.screenshot_dir)) { $cfg.screenshot_dir = Get-DefaultScreenshotDir }
        if (-not $cfg.interval_seconds -or $cfg.interval_seconds -lt 1) { $cfg.interval_seconds = 5 }
        if ([string]::IsNullOrWhiteSpace($cfg.screenshot_key))           { $cfg.screenshot_key = "home" }
        if (-not $cfg.port -or $cfg.port -lt 1)                          { $cfg.port = 7472 }
        if ([string]::IsNullOrWhiteSpace($cfg.mode))                     { $cfg.mode = "host" }
        return $cfg
    } catch {
        Write-LogError "Config load failed" $_
        return New-Config
    }
}

# ---------------------------------------------------------------------------
# tarkov.dev map data cache
# ---------------------------------------------------------------------------
function Get-MapData {
    $fresh = $false
    if (Test-Path $MAP_CACHE) {
        $age = ((Get-Date) - (Get-Item $MAP_CACHE).LastWriteTime).TotalSeconds
        if ($age -lt 86400) { $fresh = $true }
    }
    if ($fresh) {
        Write-Log "Map cache is fresh." "DarkGray"
        return
    }

    Write-Log "Fetching map data from tarkov.dev..." "Cyan"
    $q = '{"query":"{ maps { id name normalizedName bosses { boss { name } spawnChance spawnLocations { name chance } } extracts { id name faction position { x y z } } spawns { position { x y z } sides categories } } }"}'
    try {
        $resp = Invoke-RestMethod -Uri "https://api.tarkov.dev/graphql" `
            -Method Post -Body $q -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop
        if (-not (Test-Path $CACHE_DIR)) { New-Item -ItemType Directory -Path $CACHE_DIR | Out-Null }
        $resp | ConvertTo-Json -Depth 20 | Set-Content $MAP_CACHE -Encoding UTF8
        Write-Log "Map data cached." "Green"
    } catch {
        Write-LogError "tarkov.dev fetch failed" $_
        if (Test-Path $MAP_CACHE) { Write-Log "Using stale cache." "Yellow" }
    }
}

# ---------------------------------------------------------------------------
# Shared state - thread-safe .NET objects passed between runspaces
# The broadcast queue carries JSON strings to SSE clients.
# The state dict carries the last known values for API polling.
# ---------------------------------------------------------------------------
$broadcastQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$stateDict      = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()

foreach ($kv in @{
    eftRunning   = "false"
    inRaid       = "false"
    map          = "unknown"
    sessionCount = "0"
    posJson      = ""
    playerName   = ""
    version      = $VERSION
}.GetEnumerator()) {
    $stateDict.TryAdd($kv.Key, $kv.Value) | Out-Null
}

# ---------------------------------------------------------------------------
# HTTP server script - runs in background runspace
# Uses BeginGetContext (non-blocking) so it can also drain the broadcast queue
# and push SSE messages without blocking on new connections.
# ---------------------------------------------------------------------------
$httpScript = {
    param($listener, $webDir, $cacheDir, $queue, $state)

    $sseClients = [System.Collections.Generic.List[System.Net.HttpListenerResponse]]::new()

    function Get-Mime($ext) {
        switch ($ext.ToLower()) {
            ".html" { "text/html; charset=utf-8" }
            ".js"   { "application/javascript; charset=utf-8" }
            ".css"  { "text/css; charset=utf-8" }
            ".json" { "application/json; charset=utf-8" }
            ".png"  { "image/png" }
            ".svg"  { "image/svg+xml" }
            default { "application/octet-stream" }
        }
    }

    function Send-Bytes($resp, $bytes, $mime) {
        try {
            $resp.ContentType     = $mime
            $resp.ContentLength64 = $bytes.Length
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            $resp.OutputStream.Close()
        } catch {}
    }

    function Send-Text($resp, $text, $mime) {
        Send-Bytes $resp ([System.Text.Encoding]::UTF8.GetBytes($text)) $mime
    }

    function Send-File($resp, $path) {
        if (-not (Test-Path $path)) {
            Send-Text $resp "Not Found" "text/plain"
            $resp.StatusCode = 404
            return
        }
        $ext  = [System.IO.Path]::GetExtension($path)
        $data = [System.IO.File]::ReadAllBytes($path)
        Send-Bytes $resp $data (Get-Mime $ext)
    }

    function Build-StatusJson($s) {
        return "{`"type`":`"status`",`"eftRunning`":$($s['eftRunning']),`"inRaid`":$($s['inRaid']),`"map`":`"$($s['map'])`",`"version`":`"$($s['version'])`",`"sessionCount`":$($s['sessionCount']),`"playerName`":`"$($s['playerName'])`"}"
    }

    function Handle-SSE($resp) {
        $resp.ContentType = "text/event-stream"
        $resp.Headers.Add("Cache-Control", "no-cache")
        $resp.Headers.Add("X-Accel-Buffering", "no")
        $resp.SendChunked = $true

        # Flush initial connection frame
        $init = [System.Text.Encoding]::UTF8.GetBytes("data: {`"type`":`"connected`"}`n`n")
        try {
            $resp.OutputStream.Write($init, 0, $init.Length)
            $resp.OutputStream.Flush()
        } catch { return }

        $sseClients.Add($resp)

        # Push current state immediately to new subscriber
        $statusBytes = [System.Text.Encoding]::UTF8.GetBytes("data: $(Build-StatusJson $state)`n`n")
        try {
            $resp.OutputStream.Write($statusBytes, 0, $statusBytes.Length)
            $resp.OutputStream.Flush()
        } catch {}

        $posJson = $state["posJson"]
        if ($posJson -and $posJson.Length -gt 0) {
            $posBytes = [System.Text.Encoding]::UTF8.GetBytes("data: $posJson`n`n")
            try {
                $resp.OutputStream.Write($posBytes, 0, $posBytes.Length)
                $resp.OutputStream.Flush()
            } catch {}
        }
    }

    function Handle-Request($ctx) {
        $req  = $ctx.Request
        $resp = $ctx.Response
        $url  = $req.Url.AbsolutePath

        $resp.Headers.Add("Access-Control-Allow-Origin", "*")
        $resp.Headers.Add("Access-Control-Allow-Methods", "GET, OPTIONS")
        $resp.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

        if ($req.HttpMethod -eq "OPTIONS") { $resp.StatusCode = 204; $resp.OutputStream.Close(); return }

        switch -Regex ($url) {
            '^/events$' {
                Handle-SSE $resp
                # Do NOT close - kept alive for SSE push
            }
            '^/$|^$' {
                Send-File $resp (Join-Path $webDir "index.html")
            }
            '^/web/(.+)$' {
                Send-File $resp (Join-Path $webDir $Matches[1])
            }
            '^/cache/(.+)$' {
                Send-File $resp (Join-Path $cacheDir $Matches[1])
            }
            '^/api/status$' {
                $j = "{`"eftRunning`":$($state['eftRunning']),`"inRaid`":$($state['inRaid']),`"map`":`"$($state['map'])`",`"version`":`"$($state['version'])`",`"sessionCount`":$($state['sessionCount']),`"playerName`":`"$($state['playerName'])`"}"
                Send-Text $resp $j "application/json; charset=utf-8"
            }
            '^/api/position$' {
                $p = $state["posJson"]
                Send-Text $resp (if ($p -and $p.Length -gt 0) { $p } else { '{"error":"no position yet"}' }) "application/json; charset=utf-8"
            }
            '^/api/mapdata$' {
                $mp = Join-Path $cacheDir "mapdata.json"
                if (Test-Path $mp) { Send-File $resp $mp }
                else { Send-Text $resp '{"error":"no map data"}' "application/json; charset=utf-8" }
            }
            default {
                $resp.StatusCode = 404
                Send-Text $resp "Not Found" "text/plain"
            }
        }
    }

    # Main HTTP loop - BeginGetContext allows non-blocking accept
    # so we can also drain the broadcast queue between connections.
    $ar = $listener.BeginGetContext($null, $null)

    while ($listener.IsListening) {
        # Wait up to 50ms for a new connection
        if ($ar.AsyncWaitHandle.WaitOne(50)) {
            try {
                $ctx = $listener.EndGetContext($ar)
                Handle-Request $ctx
            } catch {}
            try { $ar = $listener.BeginGetContext($null, $null) } catch { break }
        }

        # Drain broadcast queue - send to all live SSE clients
        $msg  = $null
        $dead = $null
        while ($queue.TryDequeue([ref]$msg)) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("data: $msg`n`n")
            foreach ($client in $sseClients) {
                try {
                    $client.OutputStream.Write($bytes, 0, $bytes.Length)
                    $client.OutputStream.Flush()
                } catch {
                    if ($null -eq $dead) { $dead = [System.Collections.Generic.List[object]]::new() }
                    $dead.Add($client)
                }
            }
        }
        if ($null -ne $dead) {
            foreach ($d in $dead) { $sseClients.Remove($d) | Out-Null }
        }
    }
}

# ---------------------------------------------------------------------------
# Start HTTP listener - tries localhost (no admin needed)
# If host mode, also tries all-interfaces binding (needs admin or netsh reservation)
# ---------------------------------------------------------------------------
function Start-HttpServer($port, $mode) {
    $prefixes = @("http://localhost:$port/")
    if ($mode -eq "host") {
        # All-interface bind for squad sharing; falls back to localhost if no rights
        $prefixes = @("http://+:$port/", "http://localhost:$port/")
    }

    foreach ($prefix in $prefixes) {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add($prefix)
        try {
            $l.Start()
            Write-Log "HTTP server: $prefix" "Green"
            return $l
        } catch {
            Write-Log "Cannot bind $prefix (need admin for + binding) - trying localhost." "Yellow"
        }
    }
    return $null
}

function Start-HttpLoop($listener) {
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($httpScript)     | Out-Null
    $ps.AddArgument($listener)     | Out-Null
    $ps.AddArgument($WEB_DIR)      | Out-Null
    $ps.AddArgument($CACHE_DIR)    | Out-Null
    $ps.AddArgument($broadcastQueue) | Out-Null
    $ps.AddArgument($stateDict)    | Out-Null
    $handle = $ps.BeginInvoke()
    return @{ ps = $ps; rs = $rs; handle = $handle }
}

# ---------------------------------------------------------------------------
# FileSystemWatcher action
# IMPORTANT: runs in a separate thread - cannot call main-scope functions.
# All shared data passed via -MessageData. Map bounds lookup done inline.
# ---------------------------------------------------------------------------
$watcherAction = {
    $md   = $Event.MessageData
    $path = $Event.SourceEventArgs.FullPath
    $name = [System.IO.Path]::GetFileName($path)

    $coordRx = '_(-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+)_(-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+), (-?[\d]+\.[\d]+)_'

    if ($name -match $coordRx) {
        $x  = [float]$Matches[1]; $y  = [float]$Matches[2]; $z  = [float]$Matches[3]
        $qw = [float]$Matches[4]; $qx = [float]$Matches[5]; $qy = [float]$Matches[6]; $qz = [float]$Matches[7]

        # Map detection - inline, no external function call
        $detectedMap = "unknown"
        foreach ($mapName in $md.MapBounds.Keys) {
            $b = $md.MapBounds[$mapName]
            if ($x -ge $b.xMin -and $x -le $b.xMax -and
                $y -ge $b.yMin -and $y -le $b.yMax -and
                $z -ge $b.zMin -and $z -le $b.zMax) {
                $detectedMap = $mapName
                break
            }
        }

        $ts         = [datetime]::UtcNow.ToString("o")
        $playerName = $md.State["playerName"]
        $count      = [int]$md.State["sessionCount"] + 1

        $posJson = "{`"type`":`"position`",`"player`":`"$playerName`",`"x`":$x,`"y`":$y,`"z`":$z,`"qw`":$qw,`"qx`":$qx,`"qy`":$qy,`"qz`":$qz,`"map`":`"$detectedMap`",`"ts`":`"$ts`"}"

        $md.State["inRaid"]       = "true"
        $md.State["map"]          = $detectedMap
        $md.State["sessionCount"] = "$count"
        $md.State["posJson"]      = $posJson

        $md.Queue.Enqueue($posJson)

        try { Remove-Item $path -Force -ErrorAction Stop } catch {}
    } else {
        $md.State["inRaid"] = "false"
        # Non-coordinate file - will be deleted by Purge-Old after 30s
    }
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
Rotate-Log
Write-Log "=== $APP_NAME v$VERSION starting ===" "Cyan"

$cfg = Load-Config
$stateDict["playerName"] = $cfg.player_name

if (-not (Test-Path $CACHE_DIR)) { New-Item -ItemType Directory -Path $CACHE_DIR -Force | Out-Null }
if (-not (Test-Path $WEB_DIR))   { New-Item -ItemType Directory -Path $WEB_DIR   -Force | Out-Null }

$vk = $VK_MAP[$cfg.screenshot_key.ToLower()]
if (-not $vk) {
    Write-Log "Unknown key '$($cfg.screenshot_key)' - defaulting to Home (0x24)." "Yellow"
    $vk = 0x24
}

Write-Log "Key:      $($cfg.screenshot_key) (VK 0x$($vk.ToString('X2')))" "Gray"
Write-Log "Shots at: $($cfg.screenshot_dir)" "Gray"
Write-Log "Interval: $($cfg.interval_seconds)s" "Gray"
Write-Log "Mode:     $($cfg.mode)" "Gray"
Write-Log "Player:   $($cfg.player_name)" "Gray"

# Fetch map overlay data
Get-MapData

# Ensure screenshot directory exists (EFT creates it on first screenshot, but watch it now)
if (-not (Test-Path $cfg.screenshot_dir)) {
    try { New-Item -ItemType Directory -Path $cfg.screenshot_dir -Force | Out-Null }
    catch { Write-Log "Could not create screenshot dir - EFT will create it on first shot." "Yellow" }
}

# FileSystemWatcher
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path              = $cfg.screenshot_dir
$watcher.Filter            = "*.*"
$watcher.NotifyFilter      = [System.IO.NotifyFilters]::FileName
$watcher.EnableRaisingEvents = $true

Register-ObjectEvent -InputObject $watcher -EventName "Created" `
    -SourceIdentifier "EFTScreenshot" -Action $watcherAction `
    -MessageData @{
        Queue     = $broadcastQueue
        State     = $stateDict
        MapBounds = $MAP_BOUNDS
    } | Out-Null

Write-Log "FileSystemWatcher active on: $($cfg.screenshot_dir)" "Green"

# HTTP server
$listener = Start-HttpServer $cfg.port $cfg.mode
if ($listener) {
    $httpJob = Start-HttpLoop $listener
    Write-Log "Open browser: http://localhost:$($cfg.port)" "Cyan"
} else {
    Write-Log "HTTP server failed to start. Browser map will not work." "Red"
}

Write-Log "Press SPACE to pause/resume. Ctrl+C to exit." "Yellow"
Write-Log "" "Gray"

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$loopCount    = 0
$lastEftState = ""
$paused       = $false

try {
    while ($true) {
        $loopStart = Get-Date
        $loopCount++

        if ($loopCount % 10 -eq 0) { Rotate-Log }

        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Spacebar) {
                $paused = -not $paused
                Write-Log (if ($paused) { "PAUSED." } else { "RESUMED." }) "Yellow"
            }
        }

        if (-not $paused) {
            # Purge always first, always unconditional
            Purge-Old $cfg.screenshot_dir

            $keyResult = Send-KeyToEFT $vk

            # Update shared state for HTTP polling
            $stateDict["eftRunning"] = if ($keyResult -ne "NoProcess") { "true" } else { "false" }
            $stateDict["inRaid"]     = if ($keyResult -eq "Sent" -and $stateDict["inRaid"] -eq "true") { "true" } else { $stateDict["inRaid"] }

            # Log and broadcast only when EFT state changes
            if ($keyResult -ne $lastEftState) {
                switch ($keyResult) {
                    "NoProcess" { Write-Log "EFT not running." "DarkGray" }
                    "NoHandle"  { Write-Log "EFT loading screen (no window handle)." "DarkGray" }
                    "Sent"      { Write-Log "Key sent to EFT." "DarkGray" }
                    "Error"     { Write-Log "Key send error." "Red" }
                }
                $lastEftState = $keyResult

                $sj = "{`"type`":`"status`",`"eftRunning`":$($stateDict['eftRunning']),`"inRaid`":$($stateDict['inRaid']),`"map`":`"$($stateDict['map'])`",`"version`":`"$VERSION`",`"sessionCount`":$($stateDict['sessionCount'])}"
                $broadcastQueue.Enqueue($sj)
            }
        }

        $elapsed = ((Get-Date) - $loopStart).TotalSeconds
        $wait    = $cfg.interval_seconds - $elapsed
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
    }
} finally {
    Write-Log "$APP_NAME shutting down." "Yellow"
    try { Unregister-Event -SourceIdentifier "EFTScreenshot" -ErrorAction SilentlyContinue } catch {}
    try { $watcher.EnableRaisingEvents = $false; $watcher.Dispose() } catch {}
    try { $listener.Stop(); $listener.Close() } catch {}
    try { $httpJob.ps.Stop(); $httpJob.rs.Close() } catch {}
}
