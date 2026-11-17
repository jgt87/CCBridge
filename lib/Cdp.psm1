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
    # Settings > Privacy > Clear Edge's cache: the folders Edge locked are removed now, before it opens.
    if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'CCBridge\edge-cache-clear.flag')) {
        try { Import-Module (Join-Path $PSScriptRoot 'EdgeCache.psm1'); $null = Clear-EdgeCacheFolders $ProfileDir } catch { Write-CCBLog info cdp "Edge cache not cleared: $($_.Exception.Message)" }
    }
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

# --- Edge policy BrowserSignin = 2 (forced browser sign-in) --------------------------------------
# Ported from the sister project ObsidiNote (its lib/Cdp.psm1 and lib/CopilotBridge.psm1, verified
# on a business tenant). With that policy, Edge closes the window of a profile that is not signed
# in to Edge itself when it is started with --no-first-run and a debug port, so StreamHub's tab
# vanishes. Registry, file and process reads all go through parameters, so tests inject stand-ins.

function Get-EdgePolicyValue([string]$Name) {
    <# An Edge policy value as a number (machine first, then user); $null when not set. Read only. #>
    foreach ($k in 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKCU:\SOFTWARE\Policies\Microsoft\Edge') {
        try { $v = (Get-ItemProperty -Path $k -Name $Name -ErrorAction Stop).$Name; if ($null -ne $v) { return [int]$v } } catch { }
    }
    $null
}

function Test-EdgeForcedSignIn {
    <# Edge policy BrowserSignin = 2: every Edge profile must be signed in to the browser before it
       can be used. -GetPolicy replaces the registry read in tests. #>
    param([scriptblock]$GetPolicy = { param($n) Get-EdgePolicyValue $n })
    "$(& $GetPolicy 'BrowserSignin')" -eq '2'
}

function Get-EdgeProfileAccount {
    <# Which account an Edge profile (a --user-data-dir folder) is signed in with: 'work' (work or
       school account), 'personal' (Microsoft account), 'none' or 'unknown' (also: no profile yet).
       Only the account TYPE is read from 'Local State', never names, e-mail addresses or ids. #>
    param([Parameter(Mandatory)][string]$ProfileDir)
    $msaTenant = '9188040d-6c67-4c5b-b112-36a304b66dad'   # the tenant of personal Microsoft accounts
    try { $j = [IO.File]::ReadAllText((Join-Path $ProfileDir 'Local State')) | ConvertFrom-Json } catch { return 'unknown' }
    $d = $j.profile.info_cache.Default
    if (-not $d) { return 'unknown' }
    $type = "$($d.edge_account_type)"
    $tenant = "$($d.edge_account_tenant_id)"
    if ($type -eq '2' -or ($tenant -and $tenant -ne $msaTenant -and $type -ne '1' -and $type -ne '0')) { return 'work' }
    if ($type -eq '1') { return 'personal' }
    if ($type -eq '' -or $type -eq '0') { return 'none' }
    'unknown'
}

function Get-EdgeBrowserProcesses {
    <# msedge.exe processes with their command lines (ProcessId, CommandLine). Replaced in tests. #>
    @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ ProcessId = [int]$_.ProcessId; CommandLine = "$($_.CommandLine)" } })
}

function Get-EdgeProfileUse {
    <# Is an Edge browser process running with this profile (--user-data-dir), and with the debug
       port? state: 'none' (no Edge with this profile), 'debug' (with --remote-debugging-port=$Port)
       or 'no-debug' (without it, or with another port: starting Edge again would only hand its
       window to that Edge, and no debug port would appear). Helper processes (--type=renderer...)
       are left out: only the browser process carries the port. -Processes for tests. #>
    param([Parameter(Mandatory)][string]$ProfileDir, [Parameter(Mandatory)][int]$Port, $Processes)
    if (-not $PSBoundParameters.ContainsKey('Processes')) { $Processes = Get-EdgeBrowserProcesses }
    $dir = [regex]::Escape($ProfileDir.TrimEnd('\'))
    $mine = @(@($Processes) | Where-Object {
        $_ -and "$($_.CommandLine)" -notmatch '\s--type=' -and "$($_.CommandLine)" -match ('(?i)--user-data-dir=("?)' + $dir + '\\?\1(\s|$)')
    })
    $withPort = @($mine | Where-Object { "$($_.CommandLine)" -match ('--remote-debugging-port=' + $Port + '(\s|$)') })
    $state = if (-not $mine.Count) { 'none' } elseif ($withPort.Count) { 'debug' } else { 'no-debug' }
    [pscustomobject]@{ state = $state; pids = @($mine | ForEach-Object { $_.ProcessId }) }
}

function Get-ProfileInUseMessage([int]$Port) {
    "StreamHub's Edge profile is already open in an Edge window that was started without its debug port (port $Port), so StreamHub cannot reach Copilot in it and starting Edge again would only open another window. Close every window of that Edge (the one that shows Copilot for StreamHub; also check the taskbar), then start StreamHub again."
}

function Get-ForcedSignInMessage {
    "Edge on this PC must be signed in to before it can be used (Edge policy BrowserSignin = 2), and StreamHub's Edge profile is not signed in yet, so Edge closed the Copilot window to ask for that first. In StreamHub's Edge window, sign in to Edge itself with your work account (Edge's own sign-in prompt, or the profile picture at the top left), then start StreamHub again. Copilot then signs in with that account by itself."
}

function Get-WebPageCount([int]$Port) {
    <# How many tabs in StreamHub's Edge show a web page (http or https); 0 when Edge does not answer. #>
    try { @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 3) | Where-Object { $_.type -eq 'page' -and "$($_.url)" -match '^(?i)https?://' }).Count } catch { 0 }
}

function Test-ForcedSignInBlock {
    <# The Copilot window went away because Edge wants the profile signed in to Edge first: policy
       BrowserSignin = 2, the profile has no work account yet, and no web page is left in that Edge.
       -GetForced, -GetAccount and -GetPageCount replace the real reads in tests. #>
    param(
        [int]$Port = 9333,
        [string]$ProfileDir = (Join-Path $env:LOCALAPPDATA 'CCBridge\edge-profile'),
        [scriptblock]$GetForced = { Test-EdgeForcedSignIn },
        [scriptblock]$GetAccount = { param($d) Get-EdgeProfileAccount -ProfileDir $d },
        [scriptblock]$GetPageCount = { param($p) Get-WebPageCount $p }
    )
    if (-not (& $GetForced)) { return $false }
    if ((& $GetAccount $ProfileDir) -eq 'work') { return $false }
    [int](& $GetPageCount $Port) -eq 0
}

function Test-CopilotNavigateAllowed {
    <# Whether Connect-Copilot may send a tab to Copilot's address: an empty one (about:blank, edge://
       pages, no address) always; another web page only on the first attempt; never a tab already on
       Copilot (-IsCopilot) and never Microsoft's sign-in. After the first attempt a web page that is
       not Copilot is a sign-in on its way (Microsoft's or the organisation's own): sending it back to
       Copilot restarted the sign-in and closed the tab's connection again (ObsidiNote, business tenant). #>
    param([string]$Url, [switch]$IsCopilot, [switch]$FirstAttempt)
    if ($IsCopilot) { return $false }
    if ("$Url" -notmatch '^(?i)https?://') { return $true }
    if ("$Url" -match '^(?i)https://(login\.microsoftonline\.com|login\.live\.com|login\.microsoft\.com|login\.windows\.net)(/|$)') { return $false }
    [bool]$FirstAttempt
}

function Invoke-EdgeProfileSignIn {
    <# One-time Edge sign-in for StreamHub's own profile when Edge policy requires signing in to the
       browser (BrowserSignin = 2). Started with --no-first-run and a debug port, Edge closes the window
       of a profile that is not signed in, and nobody gets a chance to sign in. So: start Edge for the
       profile the plain way (only --user-data-dir: Edge runs its own sign-in), wait until the profile
       reports a work account (account type from 'Local State', nothing else), then close that Edge, so
       Start-CdpEdge can start it with the debug port. Returns @{ ok; started; detail }.
       -GetAccount, -GetUse, -StartEdge, -StopEdge and -OnWait replace the real calls in tests. #>
    param(
        [string]$ProfileDir = (Join-Path $env:LOCALAPPDATA 'CCBridge\edge-profile'),
        [int]$Port = 9333,
        [int]$TimeoutSec = 600,
        [int]$PollMs = 2000,
        [scriptblock]$GetAccount = { param($d) Get-EdgeProfileAccount -ProfileDir $d },
        [scriptblock]$GetUse = { param($d, $p) Get-EdgeProfileUse -ProfileDir $d -Port $p },
        [scriptblock]$StartEdge = { param($d) Start-Process -FilePath (Get-EdgePath) -ArgumentList @("--user-data-dir=`"$d`"") },
        [scriptblock]$StopEdge = {
            param($ids)
            foreach ($i in @($ids)) { try { [void](Get-Process -Id $i -ErrorAction Stop).CloseMainWindow() } catch { } }
            Start-Sleep -Seconds 3
            foreach ($i in @($ids)) { try { Stop-Process -Id $i -Force -ErrorAction Stop } catch { } }
        },
        [scriptblock]$OnWait = $null
    )
    $result = [pscustomobject]@{ ok = $false; started = $false; detail = '' }
    if ((& $GetAccount $ProfileDir) -eq 'work') { $result.ok = $true; $result.detail = 'Edge profile already signed in with a work account'; return $result }
    # An Edge that already holds this profile (StreamHub's own, from an earlier start) would take
    # the new window and skip Edge's sign-in: close it first.
    $use = & $GetUse $ProfileDir $Port
    if ($use -and $use.state -ne 'none') { $null = & $StopEdge $use.pids }
    $null = New-Item -ItemType Directory -Force -Path $ProfileDir
    $null = & $StartEdge $ProfileDir
    $result.started = $true
    Write-CCBLog info cdp 'Started Edge without the debug port for its own browser sign-in (BrowserSignin = 2)'
    if ($OnWait) { $null = & $OnWait }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ((& $GetAccount $ProfileDir) -eq 'work') {
            $use = & $GetUse $ProfileDir $Port
            if ($use -and $use.state -ne 'none') { $null = & $StopEdge $use.pids }
            Write-CCBLog info cdp "Edge profile signed in with a work account after $([int]$sw.Elapsed.TotalSeconds) s"
            $result.ok = $true
            $result.detail = 'Edge profile signed in with your work account'
            return $result
        }
        Start-Sleep -Milliseconds $PollMs
    }
    Write-CCBLog info cdp "Edge profile not signed in within $TimeoutSec s"
    $result.detail = "Edge was not signed in within $TimeoutSec s. In StreamHub's Edge window, sign in with your work account (Edge's own sign-in, or the profile picture at the top left), then start StreamHub again."
    $result
}

function Get-CdpPageTarget {
    <# Returns the first page target, preferring one whose URL matches $UrlLike. #>
    param([int]$Port = 9333, [string]$UrlLike = '*')
    # Parentheses matter: PS 5.1 emits a JSON array from Invoke-RestMethod as a single object.
    $pages = @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list") | Where-Object { $_.type -eq 'page' })
    if (-not $pages) { throw "no page targets on port $Port" }
    $match = $pages | Where-Object { $_.url -like $UrlLike } | Select-Object -First 1
    if ($match) { return $match }
    # Never a local page (the StreamHub app can be a tab in this window).
    $other = @($pages | Where-Object { "$($_.url)" -notmatch '^(?i)https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(/|$)' })
    if ($other.Count) { $other[0] } else { $pages[0] }
}

function Connect-Cdp {
    param([Parameter(Mandatory)][string]$WebSocketUrl)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
    try {
        if (-not $ws.ConnectAsync([uri]$WebSocketUrl, [Threading.CancellationToken]::None).Wait(10000)) {
            throw "could not connect to $WebSocketUrl"
        }
    } catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        throw "Could not connect to the Copilot tab in Edge ($($inner.Message))"
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
    if ($Session.Ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        $Session.Lost = $true
        throw "Lost the connection to the Copilot tab in Edge (connection $($Session.Ws.State))"
    }
    try {
        if (-not $Session.Ws.SendAsync($seg, 'Text', $true, [Threading.CancellationToken]::None).Wait(10000)) {
            throw "timed out sending $Method"
        }
    } catch {
        if ("$($_.Exception.Message)" -like 'timed out sending*') { throw }
        # The tab went away (closed, crashed, replaced during sign-in, Edge closed).
        $Session.Lost = $true
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        throw "Lost the connection to the Copilot tab in Edge ($($inner.Message))"
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
    Connect-Cdp, Receive-CdpMessage, Receive-CdpEvent, Invoke-Cdp, Invoke-CdpEval, Disconnect-Cdp,
    Get-EdgePolicyValue, Test-EdgeForcedSignIn, Get-EdgeProfileAccount, Get-EdgeBrowserProcesses, Get-EdgeProfileUse,
    Get-ProfileInUseMessage, Get-ForcedSignInMessage, Get-WebPageCount, Test-ForcedSignInBlock, Test-CopilotNavigateAllowed,
    Invoke-EdgeProfileSignIn
