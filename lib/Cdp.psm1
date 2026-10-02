# Minimal Chrome DevTools Protocol client for Windows PowerShell 5.1.
# Launches Edge with a debug port and talks to a page target over a WebSocket.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

function Get-EdgePath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    $edge = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $edge) { throw 'msedge.exe not found' }
    $edge
}

function Test-CdpEndpoint([int]$Port) {
    try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 2; $true } catch { $false }
}

function Start-CdpEdge {
    <# Starts Edge with a debug port, or reuses one already listening on that port. #>
    param(
        [int]$Port = 9333,
        [string]$ProfileDir = (Join-Path $env:LOCALAPPDATA 'CCBridge\edge-profile'),
        [string]$Url = 'about:blank',
        [switch]$Headless
    )
    if (Test-CdpEndpoint $Port) { Write-CCBLog verbose cdp "Reusing Edge on debug port $Port"; return $null }
    $null = New-Item -ItemType Directory -Force -Path $ProfileDir
    $edgeArgs = @("--remote-debugging-port=$Port", "--user-data-dir=`"$ProfileDir`"",
                  '--no-first-run', '--no-default-browser-check',
                  # Copilot's tab usually sits in the background; throttling it stalls reply streams.
                  '--disable-background-timer-throttling', '--disable-backgrounding-occluded-windows', '--disable-renderer-backgrounding')
    if ($Headless) { $edgeArgs += '--headless=new' }
    $edgeArgs += $Url
    $proc = Start-Process -FilePath (Get-EdgePath) -ArgumentList $edgeArgs -PassThru
    Write-CCBLog info cdp "Started Edge (pid $($proc.Id)) with debug port $Port" @{ profile = $ProfileDir; headless = [bool]$Headless }
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-CdpEndpoint $Port) { return $proc }
        Start-Sleep -Milliseconds 250
    }
    throw "Edge did not open a CDP endpoint on port $Port within 15s"
}

function Get-CdpPageTarget {
    <# Returns the first page target, preferring one whose URL matches $UrlLike. #>
    param([int]$Port = 9333, [string]$UrlLike = '*')
    # Parentheses matter: PS 5.1 emits a JSON array from Invoke-RestMethod as a single object.
    $pages = @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list") | Where-Object { $_.type -eq 'page' })
    if (-not $pages) { throw "no page targets on port $Port" }
    $match = $pages | Where-Object { $_.url -like $UrlLike } | Select-Object -First 1
    if ($match) { $match } else { $pages[0] }
}

function Connect-Cdp {
    param([Parameter(Mandatory)][string]$WebSocketUrl)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
    if (-not $ws.ConnectAsync([uri]$WebSocketUrl, [Threading.CancellationToken]::None).Wait(10000)) {
        throw "could not connect to $WebSocketUrl"
    }
    $buffer = New-Object byte[] 65536
    [pscustomobject]@{
        Ws      = $ws
        NextId  = 0
        Buffer  = $buffer
        Segment = New-Object ArraySegment[byte] -ArgumentList @(, $buffer)
        Stream  = New-Object System.IO.MemoryStream
        Pending = $null
        Lost    = $false
        Events  = New-Object System.Collections.Generic.Queue[object]
    }
}

function Receive-CdpMessage {
    <# Returns the next parsed message, or $null on timeout. A receive that times
       out stays pending on the session and is resumed by the next call. #>
    param([Parameter(Mandatory)]$Session, [int]$TimeoutMs = 1000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        if (-not $Session.Pending) {
            $Session.Pending = $Session.Ws.ReceiveAsync($Session.Segment, [Threading.CancellationToken]::None)
        }
        $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        try {
            if (-not $Session.Pending.Wait($remaining)) { return $null }
            $r = $Session.Pending.Result
        } catch {
            # The tab went away (closed, replaced during sign-in, Edge closed): report the real reason.
            $Session.Pending = $null
            $Session.Lost = $true
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            throw "Lost the connection to the Copilot tab in Edge ($($inner.Message))"
        }
        $Session.Pending = $null
        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { $Session.Lost = $true; throw 'Lost the connection to the Copilot tab in Edge (the tab closed the connection)' }
        $Session.Stream.Write($Session.Buffer, 0, $r.Count)
        if ($r.EndOfMessage) {
            $text = [Text.Encoding]::UTF8.GetString($Session.Stream.ToArray())
            $Session.Stream.SetLength(0)
            return ($text | ConvertFrom-Json)
        }
    }
}

function Receive-CdpEvent {
    <# Next event: queued ones first (set aside by Invoke-Cdp), then the socket. #>
    param([Parameter(Mandatory)]$Session, [int]$TimeoutMs = 1000)
    if ($Session.Events.Count) { return $Session.Events.Dequeue() }
    Receive-CdpMessage -Session $Session -TimeoutMs $TimeoutMs
}

function Invoke-Cdp {
    <# Sends a command and waits for its result. Events received meanwhile are queued. #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutMs = 30000
    )
    $Session.NextId++
    $id = $Session.NextId
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $json = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object ArraySegment[byte] -ArgumentList @(, $bytes)
    if (-not $Session.Ws.SendAsync($seg, 'Text', $true, [Threading.CancellationToken]::None).Wait(10000)) {
        throw "timed out sending $Method"
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $msg = Receive-CdpMessage -Session $Session -TimeoutMs $remaining
        if ($null -eq $msg) { break }
        if ($msg.id -eq $id) {
            if ($msg.error) { Write-CCBLog info cdp "$Method failed: $($msg.error.message)"; throw "$Method failed: $($msg.error.message)" }
            if ($sw.ElapsedMilliseconds -gt 5000) { Write-CCBLog verbose cdp "$Method was slow ($($sw.ElapsedMilliseconds) ms)" }
            return $msg.result
        }
        if ($msg.method) { $Session.Events.Enqueue($msg) }
    }
    Write-CCBLog info cdp "Timed out waiting for $Method after $TimeoutMs ms"
    throw "timed out waiting for $Method"
}

function Invoke-CdpEval {
    <# Evaluates a JS expression in the page and returns its value (awaits promises). #>
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Expression, [int]$TimeoutMs = 30000)
    $r = Invoke-Cdp -Session $Session -Method 'Runtime.evaluate' -TimeoutMs $TimeoutMs -Params @{
        expression = $Expression; returnByValue = $true; awaitPromise = $true
    }
    if ($r.exceptionDetails) {
        $desc = if ($r.exceptionDetails.exception) { $r.exceptionDetails.exception.description } else { $r.exceptionDetails.text }
        throw "JS error: $desc"
    }
    $r.result.value
}

function Disconnect-Cdp {
    param([Parameter(Mandatory)]$Session)
    try {
        $Session.Ws.CloseAsync('NormalClosure', 'bye', [Threading.CancellationToken]::None).Wait(2000) | Out-Null
    } catch { }
    $Session.Ws.Dispose()
}

Export-ModuleMember -Function Get-EdgePath, Test-CdpEndpoint, Start-CdpEdge, Get-CdpPageTarget,
    Connect-Cdp, Receive-CdpMessage, Receive-CdpEvent, Invoke-Cdp, Invoke-CdpEval, Disconnect-Cdp
