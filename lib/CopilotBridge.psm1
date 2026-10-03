# Drives M365 Copilot Chat in Edge: types a prompt into the page and reads the
# reply from the Chathub SignalR WebSocket, which carries the raw markdown.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Cdp.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:RecordSeparator = [char]0x1e
$script:ModuleDir = $PSScriptRoot

function ConvertTo-JsString([string]$s) { $s | ConvertTo-Json -Compress }

function Get-CopilotHosts($Selectors) {
    <# Hosts on which the Copilot tab can be: chatHosts from selectors.json plus the host of chatUrl
       (microsoft365.com/chat may redirect to m365.cloud.microsoft/chat). #>
    $hosts = @()
    if ($Selectors.PSObject.Properties['chatHosts'] -and $Selectors.chatHosts) { $hosts += @($Selectors.chatHosts) }
    $hosts += ([uri]$Selectors.chatUrl).Host -replace '^www\.', ''
    @($hosts | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() } | Select-Object -Unique)
}

function Test-CopilotUrl([string]$Url, $Selectors) {
    try { $h = ([uri]$Url).Host.ToLowerInvariant() } catch { return $false }
    foreach ($x in Get-CopilotHosts $Selectors) { if ($h -eq $x -or $h.EndsWith(".$x")) { return $true } }
    $false
}

function Get-CopilotTarget {
    <# The Edge tab with Copilot (on any of its hosts), else the first tab that is not a local page
       (sign-in pages lead back to Copilot). The StreamHub app may be a tab in the same window: it
       is never taken; without another tab a new Copilot tab is opened. #>
    param([int]$Port = 9333, [Parameter(Mandatory)]$Selectors)
    $pages = @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list") | Where-Object { $_.type -eq 'page' })
    if (-not $pages) { throw "no page targets on port $Port" }
    $match = $pages | Where-Object { Test-CopilotUrl $_.url $Selectors } | Select-Object -First 1
    if ($match) { return $match }
    $other = @($pages | Where-Object { "$($_.url)" -notmatch '^(?i)https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(/|$)' })
    if ($other.Count) { return $other[0] }
    Invoke-RestMethod -Method Put "http://127.0.0.1:$Port/json/new?$($Selectors.chatUrl)"
}

function Connect-Copilot {
    <# Starts (or reuses) Edge on the Copilot page and returns a bridge object. #>
    param(
        [int]$Port = 9333,
        [string]$SelectorsPath,
        [int]$SignInTimeoutSec = 300,
        [bool]$SaveReplyFrames = $true
    )
    $sel = if ($SelectorsPath) { Get-Content $SelectorsPath -Raw | ConvertFrom-Json } else { Get-CCBridgeConfig selectors (Split-Path -Parent $script:ModuleDir) }
    # The Copilot tab is recognised by its host (chatUrl and chatHosts in selectors.json).
    $deadline = (Get-Date).AddSeconds($SignInTimeoutSec + 30)
    $signInAnnounced = $false
    for ($attempt = 1; ; $attempt++) {
        $session = $null
        try {
            # Edge may still be starting, or may replace the tab (first start, sign-in redirects):
            # every attempt looks for the current Copilot tab again.
            $null = Start-CdpEdge -Port $Port -Url $sel.chatUrl
            $target = Get-CopilotTarget -Port $Port -Selectors $sel
            $session = Connect-Cdp $target.webSocketDebuggerUrl
            $bridge = [pscustomobject]@{ Session = $session; Selectors = $sel; Port = $Port; HubSockets = @{}; SaveFrames = $SaveReplyFrames
        Pacing = (Get-CopilotPacing); LastReplyAt = $null }
            if (-not (Test-CopilotUrl $target.url $sel)) { $null = Invoke-Cdp $session 'Page.navigate' @{ url = $sel.chatUrl } }
            $null = Invoke-Cdp $session 'Network.enable'
            # Edge throttles a page in a background or minimised window so hard that Copilot's reply
            # stream stalls halfway. Keep the Copilot tab "visible, focused and active" while attached.
            Set-CopilotTabActive $session
            Write-CCBLog verbose bridge "Attached to page target (attempt $attempt)" @{ url = ($target.url -replace '\?.*', ''); port = $Port }
            $wait = if ($signInAnnounced) { [int][Math]::Max(1, ($deadline - (Get-Date)).TotalSeconds) } else { 20 }
            if (Wait-CopilotEditor $bridge -TimeoutSec $wait) {
                Write-CCBLog info bridge "Connected to Copilot Chat$(if ($attempt -gt 1) { " (after $attempt attempts)" })"
                return $bridge
            }
            if ($signInAnnounced) { throw 'Copilot message box never appeared; not signed in?' }
            $signInAnnounced = $true
            Write-Host "Sign in to Copilot in the Edge window that just opened (waiting up to $SignInTimeoutSec s)..."
            Write-CCBLog info bridge "Message box not found; waiting for sign-in (up to $SignInTimeoutSec s)"
            if (Wait-CopilotEditor $bridge -TimeoutSec ([int][Math]::Max(1, ($deadline - (Get-Date)).TotalSeconds))) {
                Write-CCBLog info bridge 'Connected to Copilot Chat after sign-in'
                return $bridge
            }
            throw 'Copilot message box never appeared; not signed in?'
        } catch {
            if ($session) { try { Disconnect-Cdp $session } catch { } }
            $why = $_.Exception.Message
            if ($why -like '*never appeared*') {
                Write-CCBLog info bridge 'Message box never appeared (not signed in, or the page changed: check selectors.editor)'
                throw
            }
            if ((Get-Date) -gt $deadline -or $attempt -ge 15) { Write-CCBLog info bridge "Giving up connecting to Copilot after $attempt attempts: $why"; throw }
            Write-CCBLog info bridge "Copilot tab changed while connecting; reconnecting (attempt $attempt): $why"
            Start-Sleep -Seconds 2
        }
    }
}

function Get-CopilotPacing {
    <# Pauses from harness.json "pacing" (defaults when missing). #>
    $p = @{ newChatSettleSec = 3.0; beforeSendSec = 1.0; betweenPromptsSec = 5.0 }
    try {
        $cfg = Get-CCBridgeConfig harness (Split-Path -Parent $script:ModuleDir)
        if ($cfg.pacing) { foreach ($k in @($p.Keys)) { if ($null -ne $cfg.pacing.$k) { $p[$k] = [double]$cfg.pacing.$k } } }
    } catch { }
    $p
}

function Wait-Pacing($Bridge, [string]$Name, [string]$Why) {
    $sec = if ($Bridge.PSObject.Properties['Pacing'] -and $Bridge.Pacing) { [double]$Bridge.Pacing[$Name] } else { 0 }
    if ($sec -le 0) { return }
    Write-CCBLog verbose bridge "Pause $sec s ($Why)"
    # Keep reading the page's events meanwhile, so nothing backs up.
    $until = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $until) { $null = Receive-CdpEvent $Bridge.Session 200 }
}

function Set-CopilotTabActive($Session) {
    try { $null = Invoke-Cdp $Session 'Emulation.setFocusEmulationEnabled' @{ enabled = $true } } catch { Write-CCBLog verbose bridge "focus emulation failed: $($_.Exception.Message)" }
    try { $null = Invoke-Cdp $Session 'Page.enable'; $null = Invoke-Cdp $Session 'Page.setWebLifecycleState' @{ state = 'active' } } catch { Write-CCBLog verbose bridge "lifecycle state failed: $($_.Exception.Message)" }
    try { Write-CCBLog verbose bridge "Copilot tab state: $(Invoke-CdpEval $Session 'document.visibilityState')" } catch { }
}

function Wait-CopilotEditor {
    param([Parameter(Mandatory)]$Bridge, [int]$TimeoutSec = 20)
    # After a load the message box is re-mounted a few times (about 1.3 s); text typed into a
    # replaced one is shown but never sent. Ready = a live Lexical editor (__lexicalEditor) that
    # has stayed the same element for 1.5 s.
    $js = @"
(() => {
  const e = document.querySelector($(ConvertTo-JsString $Bridge.Selectors.editor));
  if (!e || !e.__lexicalEditor) return false;
  if (!e.__ccbSince) e.__ccbSince = Date.now();
  return Date.now() - e.__ccbSince >= 1500;
})()
"@
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if (Invoke-CdpEval $Bridge.Session $js) { return $true } } catch { if ($Bridge.Session.Lost) { throw } }
        # Keep draining events so the socket buffer does not back up.
        $null = Receive-CdpEvent $Bridge.Session 500
    }
    $false
}

function Get-CopilotPageSnapshot {
    <# What the Copilot tab shows when the message box is missing: address, title, a short excerpt of
       the visible text, whether a human-verification check or sign-in page is showing, and a
       screenshot in %LOCALAPPDATA%\CCBridge\screens (newest 20 kept). For diagnosis only. #>
    param([Parameter(Mandatory)]$Bridge)
    $snap = $null
    $editorSel = ConvertTo-JsString $Bridge.Selectors.editor
    try {
        $snap = Invoke-CdpEval $Bridge.Session @"
(() => JSON.stringify({
  host: location.host, path: location.pathname.replace(/[0-9a-f-]{16,}/gi, '*'), title: document.title,
  text: ((document.body && document.body.innerText) || '').replace(/\s+/g, ' ').trim().slice(0, 300),
  challenge: !!document.querySelector('iframe[src*="challenges.cloudflare.com"]'),
  editor: !!document.querySelector($editorSel)
}))()
"@ | ConvertFrom-Json
    } catch { $snap = [pscustomobject]@{ host = '?'; path = ''; title = ''; text = "page not readable: $($_.Exception.Message)"; challenge = $false; editor = $false } }
    $file = $null
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'CCBridge\screens'
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir }
        $shot = Invoke-Cdp $Bridge.Session 'Page.captureScreenshot' @{ format = 'png' } -TimeoutMs 15000
        $file = Join-Path $dir ((Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.png')
        [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($shot.data))
        foreach ($old in @(Get-ChildItem $dir -Filter *.png | Sort-Object Name -Descending | Select-Object -Skip 20)) { [IO.File]::Delete($old.FullName) }
    } catch { }
    $snap | Add-Member -NotePropertyName screenshot -NotePropertyValue $file -Force
    $off = "$($snap.host)" -and "$($snap.host)" -ne '?' -and -not (Test-CopilotUrl "https://$($snap.host)/" $Bridge.Selectors)
    $snap | Add-Member -NotePropertyName signIn -NotePropertyValue ($off -or "$($snap.host)" -match 'login\.microsoftonline|login\.live|account\.microsoft') -Force
    $snap
}

function Test-CopilotPage {
    <# Checks that the parts of Copilot's page CCBridge relies on are where selectors.json says:
       the message box, the Send button, the New chat button, and (when the chat has replies) the
       reply container and its Copy button. Returns one entry per part: @{ part; ok; setting; note }.
       When Microsoft changes the page, this names the setting to fix instead of failing later. #>
    param([Parameter(Mandatory)]$Bridge)
    $sel = $Bridge.Selectors
    $parts = [ordered]@{
        'message box' = @{ setting = 'editor'; css = $sel.editor; needed = $true }
        'Send button' = @{ setting = 'sendButton'; css = $sel.sendButton; needed = $false }
        'New chat button' = @{ setting = 'newChatButton'; css = (Get-SelectorOrDefault $Bridge 'newChatButton' "a[aria-label='New chat' i]"); needed = $false }
        'reply' = @{ setting = 'replyContainer'; css = (Get-SelectorOrDefault $Bridge 'replyContainer' "[data-testid='copilot-message-reply-div']"); needed = $false }
        'Copy button of a reply' = @{ setting = 'copyReplyButton'; css = (Get-SelectorOrDefault $Bridge 'copyReplyButton' "button[aria-label='Copy Response' i]"); needed = $false }
    }
    $list = ($parts.Values | ForEach-Object { ConvertTo-JsString $_.css }) -join ','
    $counts = try { @(Invoke-CdpEval $Bridge.Session "JSON.stringify([$list].map(s => { try { return document.querySelectorAll(s).length; } catch (e) { return -1; } }).concat([document.querySelectorAll('[data-testid=""chatQuestion""], [data-testid=""copilot-message-div""]').length]))" | ConvertFrom-Json) } catch { @() }
    $hasConversation = $counts.Count -and $counts[-1] -gt 0
    $i = 0
    foreach ($name in $parts.Keys) {
        $p = $parts[$name]; $n = if ($counts.Count) { [int]$counts[$i] } else { -1 }; $i++
        $ok = $n -gt 0
        $note = if ($n -lt 0) { 'the selector is not valid CSS' } elseif ($ok) { '' } elseif (-not $p.needed -and $name -in 'reply', 'Copy button of a reply' -and -not $hasConversation) { 'not checked: no replies on the page yet' } elseif ($name -eq 'Send button') { 'not checked: Copilot shows it once there is text in the message box' } else { 'not found on the page' }
        if (-not $ok -and $note -like 'not checked*') { $ok = $null }
        [pscustomobject]@{ part = $name; ok = $ok; setting = $p.setting; note = $note; needed = $p.needed }
    }
}

function Wait-CopilotSignIn {
    <# After a sign-in page appeared: waits until the person has signed in and Copilot's message box
       is back (up to $TimeoutSec). #>
    param([Parameter(Mandatory)]$Bridge, [int]$TimeoutSec = 300)
    Write-CCBLog info bridge "Waiting for sign-in in the Copilot window (up to $TimeoutSec s)"
    $ok = Wait-CopilotEditor $Bridge -TimeoutSec $TimeoutSec
    if ($ok) { $null = Wait-CopilotReady $Bridge; Write-CCBLog info bridge 'Signed in again; Copilot is back' }
    $ok
}

function Format-PageSnapshot($Snap) {
    $what = if ($Snap.challenge) { 'a human-verification check' } elseif ($Snap.signIn) { 'a sign-in page' } else { "'$($Snap.title)'" }
    $text = "$($Snap.text)"
    Protect-LogText ("the page shows $what at $($Snap.host)$($Snap.path): $($text.Substring(0, [Math]::Min(160, $text.Length)))" + $(if ($Snap.screenshot) { " (screenshot: $($Snap.screenshot))" } else { '' }))
}

# The web app and the MCP server may run at the same time and drive the same Copilot tab;
# this machine-wide lock lets only one of them type and wait for a reply at a time.
function Use-CopilotLock([scriptblock]$Body) {
    $mutex = New-Object Threading.Mutex($false, 'Local\CCBridgeCopilot')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne([TimeSpan]::FromMinutes(15)) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Copilot is busy with another StreamHub task (waited 15 minutes).' }
        & $Body
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function New-CopilotChat {
    <# Starts a fresh conversation by reloading the chat URL. #>
    param([Parameter(Mandatory)]$Bridge)
    Use-CopilotLock { New-CopilotChatUnlocked $Bridge }
}

function New-CopilotChatUnlocked {
    <# Starts a new conversation the way a person does, with Copilot's own New chat button, so the
       page and its connections stay alive; reloads the page only when that does not work. Then waits
       until the page is ready to take a prompt (a prompt sent while the page is still connecting can
       hang with a spinner forever on some tenants). #>
    param([Parameter(Mandatory)]$Bridge)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $how = 'reload'
    $btnSel = Get-SelectorOrDefault $Bridge 'newChatButton' "a[aria-label='New chat' i]"
    $reply = ConvertTo-JsString (Get-SelectorOrDefault $Bridge 'replyContainer' "[data-testid='copilot-message-reply-div']")
    $clicked = $false
    try {
        $clicked = Invoke-CdpEval $Bridge.Session "(() => { const b = [...document.querySelectorAll($(ConvertTo-JsString $btnSel))].find(e => e.offsetParent !== null); if (!b) return false; b.click(); return true; })()"
    } catch { if ($Bridge.Session.Lost) { throw } }
    if ($clicked) {
        # The conversation is cleared once no reply is left on the page.
        $until = (Get-Date).AddSeconds(8)
        do {
            Start-Sleep -Milliseconds 200
            $left = try { Invoke-CdpEval $Bridge.Session "document.querySelectorAll($reply).length" } catch { -1 }
        } while ($left -ne 0 -and (Get-Date) -lt $until)
        if ($left -eq 0) { $how = 'button' }
    }
    if ($how -ne 'button') {
        $null = Invoke-Cdp $Bridge.Session 'Page.navigate' @{ url = $Bridge.Selectors.chatUrl }
        Start-Sleep -Milliseconds 500
    }
    $ok = Wait-CopilotEditor $Bridge -TimeoutSec $(if ($how -eq 'button') { 15 } else { 30 })
    if (-not $ok -and $how -eq 'button') {
        Write-CCBLog info bridge 'Message box missing after New chat; reloading the page'
        $how = 'button, then reload'
        $null = Invoke-Cdp $Bridge.Session 'Page.navigate' @{ url = $Bridge.Selectors.chatUrl }
        Start-Sleep -Milliseconds 500
        $ok = Wait-CopilotEditor $Bridge -TimeoutSec 30
    }
    if (-not $ok) {
        $snap = Get-CopilotPageSnapshot $Bridge
        $why = Format-PageSnapshot $snap
        Write-CCBLog info bridge "Copilot message box did not appear; $why" @{ challenge = $snap.challenge; signIn = $snap.signIn; title = $snap.title }
        throw "Copilot message box did not appear after starting a new chat; $why"
    }
    $ready = Wait-CopilotReady $Bridge
    Wait-Pacing $Bridge 'newChatSettleSec' 'new chat settles'
    Write-CCBLog verbose bridge "New chat ($how); page ready after $($sw.ElapsedMilliseconds) ms" $ready
}

function Wait-CopilotReady {
    <# Waits until the page has finished its own start-up work: no requests in flight (telemetry
       excluded) for a moment and every newly opened StreamHub/Chathub connection has answered.
       Gives up after $MaxSec and sends anyway. Returns what it saw, for the log. #>
    param([Parameter(Mandatory)]$Bridge, [double]$MinSec = 1.0, [double]$QuietSec = 0.7, [double]$MaxSec = 10)
    $s = $Bridge.Session
    $hubPattern = [regex]::Escape($Bridge.Selectors.chatHubUrlPattern)
    $streamPattern = [regex]::Escape((Get-SelectorOrDefault $Bridge 'streamHubUrlPattern' '/StreamHub/'))
    $noise = '(?i)browser\.events\.data\.microsoft|/OneCollector/|/events(\?|$)|/instrument/|/logclient|telemetry|/healthz'
    $inflight = @{}; $waitingSockets = @{}; $requests = 0
    $start = Get-Date; $lastChange = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $MaxSec) {
        $m = Receive-CdpEvent $s 150
        if ($m) {
            $id = "$($m.params.requestId)"
            switch ($m.method) {
                'Network.requestWillBeSent' {
                    if ($m.params.type -notmatch '^(WebSocket|EventSource|Ping|Other)$' -and "$($m.params.request.url)" -notmatch $noise) { $inflight[$id] = $true; $requests++; $lastChange = Get-Date }
                }
                'Network.loadingFinished' { if ($inflight.Remove($id)) { $lastChange = Get-Date } }
                'Network.loadingFailed' { if ($inflight.Remove($id)) { $lastChange = Get-Date } }
                'Network.webSocketCreated' {
                    $kind = if ($m.params.url -match $streamPattern) { 'stream' } elseif ($m.params.url -match $hubPattern) { 'chat' } else { $null }
                    if ($kind) { $Bridge.HubSockets[$id] = $kind; $waitingSockets[$id] = $kind; $lastChange = Get-Date }
                }
                'Network.webSocketFrameReceived' { if ($waitingSockets.Remove($id)) { $lastChange = Get-Date } }
                'Network.webSocketClosed' { $null = $waitingSockets.Remove($id) }
            }
        }
        $elapsed = ((Get-Date) - $start).TotalSeconds
        if ($elapsed -ge $MinSec -and -not $inflight.Count -and -not $waitingSockets.Count -and ((Get-Date) - $lastChange).TotalSeconds -ge $QuietSec) {
            return @{ ms = [int](((Get-Date) - $start).TotalMilliseconds); requests = $requests; timedOut = $false }
        }
    }
    @{ ms = [int]($MaxSec * 1000); requests = $requests; timedOut = $true; stillLoading = $inflight.Count; socketsWaiting = @($waitingSockets.Values) }
}

function Set-CopilotWorkIq {
    <# Sets the Work IQ toggle (Microsoft 365 data grounding). Returns 'on', 'off' or 'unavailable'
       when selectors.json has no toggle selector or the control is not on the page. #>
    param([Parameter(Mandatory)]$Bridge, [Parameter(Mandatory)][bool]$On)
    $w = $Bridge.Selectors.workIq
    if (-not $w -or -not $w.toggle) { Write-CCBLog verbose bridge 'Work IQ: no toggle selector configured'; return 'unavailable' }
    $js = @"
(async () => {
  const el = document.querySelector($(ConvertTo-JsString $w.toggle));
  if (!el) return 'unavailable';
  const isOn = () => (el.getAttribute($(ConvertTo-JsString $w.stateAttribute)) || '') === $(ConvertTo-JsString $w.onValue);
  if (isOn() !== $(if ($On) { 'true' } else { 'false' })) { el.click(); await new Promise(r => setTimeout(r, 400)); }
  return isOn() ? 'on' : 'off';
})()
"@
    $state = Use-CopilotLock { Invoke-CdpEval $Bridge.Session $js }
    Write-CCBLog verbose bridge "Work IQ requested $(if ($On) { 'on' } else { 'off' }), page reports $state"
    $state
}

function Set-CopilotResponseMode {
    <# Picks Copilot's response mode: auto, quick (Quick response) or deep (Think deeper). Opens the
       picker only when the mode shown differs. Items are matched by their text, else by position.
       Returns the mode shown afterwards, or 'unavailable'. #>
    param([Parameter(Mandatory)]$Bridge, [Parameter(Mandatory)][ValidateSet('auto', 'quick', 'deep')][string]$Mode)
    $btn = if ($Bridge.Selectors.responseMode -and $Bridge.Selectors.responseMode.button) { $Bridge.Selectors.responseMode.button } else { '#gptModeSwitcher' }
    $idx = @{ auto = 0; quick = 1; deep = 2 }[$Mode]
    $re = @{ auto = '^auto'; quick = '^quick'; deep = '^think' }[$Mode]
    $js = @"
(async () => {
  const b = document.querySelector($(ConvertTo-JsString $btn));
  if (!b) return 'unavailable';
  const re = new RegExp($(ConvertTo-JsString $re), 'i');
  if (re.test((b.innerText || '').trim())) return (b.innerText || '').trim();
  b.click();
  await new Promise(r => setTimeout(r, 700));
  const items = [...document.querySelectorAll('[role=menuitem],[role=menuitemradio]')];
  const it = items.find(e => re.test((e.innerText || '').trim())) || (items.length === 3 ? items[$idx] : null);
  if (!it) { b.click(); return 'unavailable'; }
  it.click();
  await new Promise(r => setTimeout(r, 400));
  return (b.innerText || '').trim();
})()
"@
    $shown = Use-CopilotLock { Invoke-CdpEval $Bridge.Session $js }
    Write-CCBLog verbose bridge "Response mode requested $Mode, page shows $shown"
    $shown
}

function Get-CopilotInputLength {
    <# Length of the message box text, ignoring the zero-width placeholder characters Lexical adds. #>
    param([Parameter(Mandatory)]$Bridge)
    $editorSel = ConvertTo-JsString $Bridge.Selectors.editor
    Invoke-CdpEval $Bridge.Session "(() => { const e = document.querySelector($editorSel); if (!e) return -1; const t = typeof e.__lexicalTextContent === 'string' ? e.__lexicalTextContent : e.innerText; return t.replace(/[\u200b\u200c\r\n]/g, '').length; })()"
}

function Send-CdpKey {
    param($Session, [string]$Key, [string]$Code, [int]$KeyCode, [int]$Modifiers = 0, [string[]]$Commands = @())
    $down = @{ type = 'rawKeyDown'; key = $Key; code = $Code; windowsVirtualKeyCode = $KeyCode; modifiers = $Modifiers }
    if ($Commands) { $down.commands = $Commands }
    $null = Invoke-Cdp $Session 'Input.dispatchKeyEvent' $down
    $null = Invoke-Cdp $Session 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = $Key; code = $Code; windowsVirtualKeyCode = $KeyCode; modifiers = $Modifiers }
}

function Set-CopilotInput {
    <# Replaces the message box contents with $Text. The box is a Lexical editor, which ignores
       execCommand, so it is cleared with real key presses and the result is verified. #>
    param([Parameter(Mandatory)]$Bridge, [Parameter(Mandatory)][string]$Text)
    $Text = $Text.Replace("`r`n", "`n")   # a CR would land in the editor as an extra character
    $s = $Bridge.Session
    $editorSel = ConvertTo-JsString $Bridge.Selectors.editor
    $found = Invoke-CdpEval $s "(() => { const e = document.querySelector($editorSel); if (!e) return false; e.focus(); return true; })()"
    if (-not $found) {
        if (-not (Wait-CopilotEditor $Bridge -TimeoutSec 15)) { throw "Copilot message box not found; $(Format-PageSnapshot (Get-CopilotPageSnapshot $Bridge))" }
        $null = Invoke-CdpEval $s "(() => { const e = document.querySelector($editorSel); if (e) e.focus(); return !!e; })()"
    }
    for ($try = 0; $try -lt 3 -and (Get-CopilotInputLength $Bridge) -gt 0; $try++) {
        Send-CdpKey $s 'a' 'KeyA' 65 2 @('selectAll')   # modifiers 2 = Ctrl
        Send-CdpKey $s 'Backspace' 'Backspace' 8
        Start-Sleep -Milliseconds 150
    }
    if ((Get-CopilotInputLength $Bridge) -gt 0) { Write-CCBLog info bridge 'Could not clear the message box' @{ chars = (Get-CopilotInputLength $Bridge) }; throw 'could not clear the Copilot message box' }

    $expected = $Text.Replace("`r", '').Replace("`n", '').Length
    # The page can rebuild the message box just after it appeared (first prompt after connecting);
    # text typed into the old box is then lost. An empty box after typing is retried.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $null = Invoke-Cdp $s 'Input.insertText' @{ text = $Text }
        $deadline = (Get-Date).AddSeconds($(if ($attempt -lt 3) { 3 } else { 10 }))
        do {
            Start-Sleep -Milliseconds 200
            $actual = Get-CopilotInputLength $Bridge
        } while ($actual -lt $expected -and (Get-Date) -lt $deadline)
        if ($actual -gt 0) { break }
        Write-CCBLog info bridge "Message box was empty after typing; typing again (attempt $attempt)"
        $null = Wait-CopilotEditor $Bridge -TimeoutSec 10
        $null = Invoke-CdpEval $s "(() => { const e = document.querySelector($editorSel); if (!e) return false; e.focus(); return true; })()"
    }
    if ($actual -ne $expected) {
        # An empty box is often Copilot refusing input: its daily limit is reached (it shows a banner).
        $st = try { Get-PageReplyState $Bridge } catch { $null }
        if ($st -and $st.bar -and $st.bar -match $script:LimitPattern) { Write-CCBLog info bridge 'Copilot shows a usage limit; it does not accept a prompt' @{ message = $st.bar }; throw "Copilot does not accept prompts: $($st.bar)" }
        Write-CCBLog info bridge 'Message box content does not match the prompt' @{ expected = $expected; actual = $actual }; throw "message box holds $actual characters, expected $expected"
    }
    Write-CCBLog verbose bridge 'Prompt typed into the message box' @{ chars = $expected }
}

function Invoke-CopilotSend {
    param([Parameter(Mandatory)]$Bridge, [int]$TimeoutSec = 10)
    $sendSel = ConvertTo-JsString $Bridge.Selectors.sendButton
    $js = @"
(() => {
  const b = document.querySelector($sendSel);
  if (!b || b.disabled || b.getAttribute('aria-disabled') === 'true') return false;
  b.click(); return true;
})()
"@
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Invoke-CdpEval $Bridge.Session $js) { return }
        Start-Sleep -Milliseconds 250
    }
    Write-CCBLog info bridge 'Send button never became clickable (check selectors.sendButton)'
    throw 'Send button never became clickable'
}

function Read-HubRecords {
    <# Splits a SignalR frame into parsed JSON records. #>
    param([string]$Payload)
    foreach ($part in $Payload.Split($script:RecordSeparator)) {
        if ($part.Trim()) { try { $part | ConvertFrom-Json } catch { } }
    }
}

function Get-BotReplyText {
    <# The reply is the bot message without a messageType (others are hints, progress, references). #>
    param($Messages)
    $reply = @($Messages | Where-Object { $_.author -eq 'bot' -and -not $_.messageType -and $_.text }) | Select-Object -Last 1
    if ($reply) { $reply.text }
}

# --- Reply reconstruction -------------------------------------------------------------
# Copilot streams a reply as a mix of raw chunks (writeAtCursor) and full-text snapshots
# (messages[].text). Snapshots, and the final message, pass through a link/citation filter
# that deletes code such as "[name]:" or "[0] ... [x](" - fatal for source code. So the reply
# is rebuilt from the raw chunks, taking from each snapshot only the tokens that never arrived
# as chunks. Uncertain counts the merges that needed a heuristic.

function New-ReplyMerger { [pscustomobject]@{ Text = ''; LastSnap = $null; Pending = ''; Uncertain = 0 } }

function Add-ReplyChunk($M, [string]$Chunk) { $M.Text += $Chunk; $M.Pending += $Chunk }

function Add-ReplySnapshot($M, [string]$Snap) {
    if (-not $Snap -or $Snap -eq $M.LastSnap) { return }
    $pending = $M.Pending
    if ($Snap.StartsWith($M.Text)) {
        $M.Text = $Snap                                         # clean snapshot, nothing filtered
    } elseif ($M.LastSnap -and $Snap.StartsWith($M.LastSnap) -and
              $Snap.Substring($M.LastSnap.Length).StartsWith($pending)) {
        $M.Text += $Snap.Substring($M.LastSnap.Length + $pending.Length)
    } elseif ($pending -and ($i = $Snap.LastIndexOf($pending)) -ge 0 -and
              $i + $pending.Length -ge $Snap.Length - 80) {
        $M.Text += $Snap.Substring($i + $pending.Length)       # chunk text survived at the end
    } else {
        Write-CCBLog verbose bridge 'Reply repair: heuristic merge' @{ pending = $pending.Length; snapshot = $Snap.Length }
        # Filtered text near the end: anchor on the longest tail of the pending chunks
        # that still appears close to the end of the snapshot.
        $window = $Snap.Substring([Math]::Max(0, $Snap.Length - $pending.Length - 80))
        for ($n = $pending.Length; $n -ge 2; $n--) {
            $j = $window.LastIndexOf($pending.Substring($pending.Length - $n))
            if ($j -ge 0) { $M.Text += $window.Substring($j + $n); break }
        }
        $M.Uncertain++
    }
    $M.LastSnap = $Snap
    $M.Pending = ''
}

function Add-HubRecord {
    <# Feeds one SignalR record into the merger. Returns the completion item for a type-2 record. #>
    param($M, $Rec)
    switch ($Rec.type) {
        1 {
            if ($Rec.target -ne 'update' -or -not $Rec.arguments) { return }
            $a = $Rec.arguments[0]
            if ($null -ne $a.writeAtCursor) { Add-ReplyChunk $M $a.writeAtCursor }
            elseif ($a.messages) { Add-ReplySnapshot $M (Get-BotReplyText $a.messages) }
        }
        2 { return $Rec.item }
        3 { if ($Rec.error) { throw "Copilot hub error: $($Rec.error)" } }
    }
}

# --- StreamHub ---------------------------------------------------------------------------
# Some tenants deliver the reply over substrate.svc.cloud.microsoft/m365Copilot/StreamHub: a SignalR
# stream whose type-2 records each carry an item. The item layout is looked up by field name (chunks
# in writeAtCursor, snapshots in messages[], the end in result / a final flag / a type-3 completion),
# so small layout differences do not matter. The field names seen are logged (names only).

function New-StreamState {
    [pscustomobject]@{ Merger = (New-ReplyMerger); Items = 0; Done = $false; Why = ''; Result = $null; Throttling = $null
        Messages = $null; Keys = (New-Object 'System.Collections.Generic.HashSet[string]'); LastAt = $null }
}

# Banners that mean Copilot will not answer today, and progress texts that are not an answer.
$script:LimitPattern = '(?i)daily limit|usage limit|reached (your|the) .{0,30}limit|out of credits|dagelijkse limiet|limiet bereikt'
$script:PlaceholderPattern = '(?i)^(working on it|taking a look|thinking|searching|generating|one moment|bezig|even kijken)[^\n]{0,40}(\u2026|\.\.\.)\s*$'

$script:StreamFinalFlags = '^(isFinal|isLast|final|isComplete|isCompleted|completed|done|isDone|endOfStream|isEnd|isLastChunk)$'
$script:StreamStateFields = '^(state|status|messageState|streamState|phase|eventType|kind)$'
$script:StreamFinalValues = '(?i)^(complete|completed|final|done|end|ended|finished|endofstream|streamend)$'

function Find-StreamSignals($Node, $Sig, [int]$Depth = 0, [string]$Path = '') {
    if ($null -eq $Node -or $Depth -gt 6) { return }
    if ($Node -is [array]) { foreach ($el in ($Node | Select-Object -First 50)) { Find-StreamSignals $el $Sig ($Depth + 1) "$Path[]" }; return }
    if ($Node -isnot [pscustomobject]) { return }
    foreach ($p in $Node.PSObject.Properties) {
        $name = $p.Name; $v = $p.Value
        if ($Sig.keys.Count -lt 120) { [void]$Sig.keys.Add($(if ($Path) { "$Path.$name" } else { $name })) }
        if ($name -eq 'writeAtCursor' -and $v -is [string]) { $Sig.chunks.Add($v); continue }
        if ($name -eq 'messages' -and $v -is [array] -and $null -eq $Sig.messages) { $Sig.messages = $v }
        if ($name -eq 'result' -and $v -is [pscustomobject] -and $v.PSObject.Properties['value'] -and $null -eq $Sig.result) { $Sig.result = $v }
        if ($name -eq 'throttling' -and $v -is [pscustomobject]) { $Sig.throttling = $v }
        if ($v -is [bool] -and $v -and $name -match $script:StreamFinalFlags) { $Sig.final = "$name=true" }
        if ($v -is [string] -and $name -match $script:StreamStateFields -and $v -match $script:StreamFinalValues) { $Sig.final = "$name=$v" }
        if ($v -is [pscustomobject] -or $v -is [array]) {
            if ($name -ne 'messages') { Find-StreamSignals $v $Sig ($Depth + 1) $(if ($Path) { "$Path.$name" } else { $name }) }
            else { foreach ($msg in ($v | Select-Object -First 20)) { if ($msg -is [pscustomobject]) { foreach ($q in $msg.PSObject.Properties) { if ($Sig.keys.Count -lt 120) { [void]$Sig.keys.Add("$Path.messages[].$($q.Name)") } } } } }
        }
    }
}

function Add-StreamRecord {
    <# Feeds one StreamHub record into the stream state; sets Done when the reply has ended. #>
    param($S, $Rec)
    if ($Rec.type -eq 3) {
        if ($Rec.error) { throw "Copilot stream error: $($Rec.error)" }
        if ($S.Items) { $S.Done = $true; $S.Why = 'completion record' }
        return
    }
    if ($Rec.type -ne 2 -or $null -eq $Rec.item) { return }
    $S.Items++
    $S.LastAt = Get-Date
    $sig = @{ chunks = (New-Object System.Collections.Generic.List[string]); messages = $null; result = $null; throttling = $null; final = $null; keys = $S.Keys }
    Find-StreamSignals $Rec.item $sig
    foreach ($c in $sig.chunks) { Add-ReplyChunk $S.Merger $c }
    if ($sig.messages) { $S.Messages = $sig.messages; Add-ReplySnapshot $S.Merger (Get-BotReplyText $sig.messages) }
    if ($sig.throttling) { $S.Throttling = $sig.throttling }
    if ($sig.result) {
        $S.Result = $sig.result
        if ($sig.result.value -and $sig.result.value -ne 'Success') { $S.Done = $true; $S.Why = "result $($sig.result.value)" }
        elseif ($S.Merger.Text) { $S.Done = $true; $S.Why = 'result' }
    }
    if ($sig.final -and -not $S.Done) { $S.Done = $true; $S.Why = $sig.final }
}

function Get-SocketKind($Bridge, [string]$Id, [string]$Payload) {
    <# chat (Chathub), stream (StreamHub) or $null, by the socket's address or, for a socket opened
       before CCBridge connected, by the shape of its traffic. #>
    if ($Bridge.HubSockets.ContainsKey($Id)) { return $Bridge.HubSockets[$Id] }
    $kind = $null
    if ($Payload -match '"target":"update"') { $kind = 'chat' }
    elseif ($Payload -match '"type":2' -and $Payload -match '"item"') { $kind = 'stream' }
    if ($kind) { $Bridge.HubSockets[$Id] = $kind }
    $kind
}

function Get-ReplyReferences($BotMessage) {
    <# Sources Copilot cited (Work IQ: emails, files, Teams; or web pages). Copilot's link filter removes the
       citation markers from the text, so the list is taken from the message metadata. #>
    if (-not $BotMessage) { return }
    $seen = @{}
    foreach ($src in @($BotMessage.sourceAttributions) + @($BotMessage.references)) {
        if (-not $src) { continue }
        $title = $null; $url = $null; $kind = $null
        foreach ($n in 'providerDisplayName', 'title', 'displayName', 'name', 'subject', 'fileName') { if (-not $title -and $src.PSObject.Properties[$n] -and $src.$n) { $title = [string]$src.$n } }
        foreach ($n in 'seeMoreUrl', 'url', 'webUrl', 'link') { if (-not $url -and $src.PSObject.Properties[$n] -and $src.$n) { $url = [string]$src.$n } }
        foreach ($n in 'sourceType', 'referenceType', 'type', 'providerType', 'entityType') { if (-not $kind -and $src.PSObject.Properties[$n] -and $src.$n -is [string]) { $kind = [string]$src.$n } }
        if (-not $title -and -not $url) { continue }
        $key = "$title|$url"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [pscustomobject]@{ title = $title; url = $url; kind = $kind }
    }
}

# --- Human in the loop: Microsoft 365 actions -------------------------------------------
# With Work IQ, Copilot can offer to act in Microsoft 365 (send mail, change meetings, ...),
# normally as a card with buttons that the user must click. CCBridge never clicks anything in a
# reply; these functions only detect such proposals and claims so the agent can stop and hand
# them to a person.

$script:BenignMessageTypes = @('Progress', 'EarlyProgress', 'HintInvocation', 'ReferencesListComplete', 'InternalSearchQuery',
    'InternalSearchResult', 'InternalLoaderMessage', 'GenerateContentQuery', 'SemanticSerp', 'Disengaged', 'RenderCardRequest')

function Find-CardActions($Node, [int]$Depth = 0) {
    if ($null -eq $Node -or $Depth -gt 12 -or $Node -is [string] -or $Node -is [ValueType]) { return }
    if ($Node -is [array]) { foreach ($x in $Node) { Find-CardActions $x ($Depth + 1) }; return }
    $type = $Node.PSObject.Properties['type']
    if ($type -and "$($type.Value)" -match '^Action\.(Submit|Execute)$') {
        $title = if ($Node.PSObject.Properties['title']) { [string]$Node.title } else { [string]$type.Value }
        $title
    }
    foreach ($p in $Node.PSObject.Properties) { if ($p.Name -ne 'type') { Find-CardActions $p.Value ($Depth + 1) } }
}

function Get-ProposedActions($Item) {
    <# Microsoft 365 actions Copilot proposes in this reply (buttons to confirm, action messages). #>
    foreach ($m in @($Item.messages | Where-Object { $_.author -eq 'bot' })) {
        $mt = [string]$m.messageType
        if ($mt -and $script:BenignMessageTypes -notcontains $mt -and $mt -match '(?i)action|confirm|invoke|plugin|task|draft|send|schedul') {
            [pscustomobject]@{ kind = $mt; title = ([string]$m.text).Substring(0, [Math]::Min(120, ([string]$m.text).Length)) }
        }
        foreach ($t in @(Find-CardActions $m.adaptiveCards)) { [pscustomobject]@{ kind = 'button'; title = $t } }
    }
}

function Get-ActionClaims([string]$Text) {
    <# Sentences in which Copilot says it did something in Microsoft 365 (sent, cancelled, deleted ...). #>
    if (-not $Text) { return }
    $verbs = '(sent|forwarded|replied|scheduled|rescheduled|cancel+ed|declined|accepted|deleted|removed|archived|posted|shared|booked|moved)'
    $nouns = '(e-?mails?|mails?|messages?|meetings?|invit(e|ation)s?|appointments?|calendar|events?|Teams|chats?|channels?|replies)'
    foreach ($s in [regex]::Split($Text, '(?<=[.!?])\s+|\n')) {
        if ($s -match "(?i)\b(I('ve| have)|I|has been|have been|was|were|is now)\s+(\w+\s+)?$verbs\b" -and $s -match "(?i)\b$nouns\b") { $s.Trim() }
    }
}

function Complete-Reply {
    param($M, $Item, [string]$SentPrompt)
    $final = Get-BotReplyText $Item.messages
    $text = if ($M.Text) { $M.Text } else { $final }
    $userMsg = @($Item.messages | Where-Object { $_.author -eq 'user' }) | Select-Object -Last 1
    $botMsg = @($Item.messages | Where-Object { $_.author -eq 'bot' -and -not $_.messageType -and $_.text }) | Select-Object -Last 1
    [pscustomobject]@{
        Text           = $text
        ServerText     = $final        # as filtered by Copilot; differs from Text when code was damaged
        Uncertain      = $M.Uncertain  # merges that needed a heuristic; 0 = exact
        SentText       = $userMsg.text
        # Copilot's page sends < and > as &lt; and &gt;; that is not a difference.
        SentMatches    = (([string]$userMsg.text -replace '&lt;', '<' -replace '&gt;', '>' -replace '\s', '') -eq ($SentPrompt -replace '\s', ''))
        Result         = $Item.result.value
        ResultMessage  = $Item.result.message
        ConversationId = $Item.conversationId
        Throttling     = $Item.throttling
        Metering       = @($Item.result.meteringInformation)[0]   # daily credits (remainingAllowance, totalAllowance, resetAt)
        References     = @(Get-ReplyReferences $botMsg)          # emails, files, chats or web pages Copilot cited
        ProposedActions = @(Get-ProposedActions $Item)           # Microsoft 365 actions waiting for a person
        ActionClaims   = @(Get-ActionClaims $text)
    }
}

function Get-ReplyFromFrames {
    <# Rebuilds a reply from recorded Chathub frame payloads (for tests and debugging). #>
    param([string[]]$Payloads, [string]$SentPrompt = '')
    $m = New-ReplyMerger
    foreach ($p in $Payloads) {
        foreach ($rec in Read-HubRecords $p) {
            $item = Add-HubRecord $m $rec
            if ($item) { return Complete-Reply $m $item $SentPrompt }
        }
    }
}

function Write-ReplyLog($Reply, $Item, $Frames, [long]$Ms) {
    <# One verbose line per reply: timings, repair, limits, and anything unusual in the traffic. #>
    $types = @($Item.messages | ForEach-Object { "$($_.author):$($_.messageType)" } | Select-Object -Unique)
    if (-not "$($Reply.Text)".Trim() -or ($Reply.Result -and $Reply.Result -ne 'Success')) {
        # Always worth knowing, also at the default level.
        Write-CCBLog info bridge 'Reply without text or not successful' @{ result = $Reply.Result; message = $Reply.ResultMessage; messageTypes = $types; frames = $Frames.Count; ms = $Ms }
    }
    if (-not (Test-CCBLog verbose)) { return }
    $unknown = @($Item.messages | Where-Object { $_.author -eq 'bot' -and $_.messageType -and $script:BenignMessageTypes -notcontains $_.messageType } | ForEach-Object { $_.messageType } | Select-Object -Unique)
    Write-CCBLog verbose bridge 'Reply received' @{
        ms = $Ms; frames = $Frames.Count; chars = "$($Reply.Text)".Length; serverChars = "$($Reply.ServerText)".Length
        repairedDiffers = ($Reply.Text -ne $Reply.ServerText); uncertain = $Reply.Uncertain; sentMatches = $Reply.SentMatches
        result = $Reply.Result; chat = "$($Reply.Throttling.numUserMessagesInConversation)/$($Reply.Throttling.maxNumUserMessagesInConversation)"
        credits = $(if ($Reply.Metering) { "$($Reply.Metering.remainingAllowance)/$($Reply.Metering.totalAllowance)" } else { $null })
        references = @($Reply.References).Count; proposedActions = @($Reply.ProposedActions).Count; claims = @($Reply.ActionClaims).Count
        messageTypes = $types; unknownMessageTypes = $unknown
    }
    if (-not $Reply.SentMatches) { Write-CCBLog info bridge 'Copilot received different text than was typed' @{ sentChars = "$($Reply.SentText)".Length } }
    Write-CCBLog trace bridge 'Reply text' @{ text = $Reply.Text }
}

function Save-ReplyFrames($Frames) {
    <# Writes the raw Chathub frames of each reply to %LOCALAPPDATA%\CCBridge\replies\ (newest 30 kept),
       so a damaged reply can be replayed with Get-ReplyFromFrames. #>
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'CCBridge\replies'
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir }
        $file = Join-Path $dir ((Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.jsonl')
        [IO.File]::WriteAllLines($file, [string[]]$Frames, (New-Object Text.UTF8Encoding($false)))
        Get-ChildItem $dir -Filter *.jsonl | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item -Force
    } catch { }
}

function Get-UrlShape([string]$Url) {
    <# Host and path of a URL without query, fragment or id-like segments, for the log. #>
    try { $u = [Uri]$Url } catch { return '?' }
    $path = ($u.AbsolutePath -split '/' | ForEach-Object { if ($_ -match '^[0-9a-fA-F-]{16,}$|^\d{5,}$|[^\w.-]|^.{41,}$') { '*' } else { $_ } }) -join '/'
    "$($u.Scheme)://$($u.Host)$path"
}

function New-NetTrace { @{ Requests = (New-Object System.Collections.Generic.List[string]); Sockets = @{}; EventSource = 0 } }

function Add-NetTrace($Trace, $Bridge, $M) {
    <# Records what the page does on the network after a prompt is sent (method and address only). #>
    switch ($M.method) {
        'Network.requestWillBeSent' {
            $u = "$($M.params.request.url)"
            # Static files and telemetry say nothing about how the reply travels.
            $noise = $M.params.type -match '^(Script|Stylesheet|Image|Font|Media|Manifest)$' -or
                $u -match '(?i)\.(js|css|woff2?|png|svg|ico|jpe?g|gif|webp)(\?|$)|browser\.events\.data\.microsoft|/OneCollector/|/events(\?|$)|challenges\.cloudflare'
            if (-not $noise -and $Trace.Requests.Count -lt 80 -and $u -match '^https?:') { $Trace.Requests.Add("$($M.params.request.method) $(Get-UrlShape $M.params.request.url)") }
        }
        'Network.webSocketCreated' { $Trace.Sockets[$M.params.requestId] = @{ url = (Get-UrlShape $M.params.url); text = 0; binary = 0; bytes = 0 } }
        'Network.webSocketFrameReceived' {
            $k = $M.params.requestId
            if (-not $Trace.Sockets.ContainsKey($k)) { $Trace.Sockets[$k] = @{ url = $(if ($Bridge.HubSockets.ContainsKey($k)) { '(hub, opened earlier)' } else { '(opened earlier)' }); text = 0; binary = 0; bytes = 0 } }
            $s = $Trace.Sockets[$k]
            if ($M.params.response.opcode -eq 2) { $s.binary++ } else { $s.text++ }
            $s.bytes += "$($M.params.response.payloadData)".Length
        }
        'Network.eventSourceMessageReceived' { $Trace.EventSource++ }
    }
}

function Write-NetTrace($Trace, [string]$Why) {
    if (-not (Test-CCBLog verbose)) { return }
    $sockets = @($Trace.Sockets.Values | ForEach-Object { "$($_.url) text=$($_.text) binary=$($_.binary) bytes=$($_.bytes)" })
    $requests = @($Trace.Requests | Group-Object | ForEach-Object { if ($_.Count -gt 1) { "$($_.Name) x$($_.Count)" } else { $_.Name } })
    Write-CCBLog verbose bridge "Network after sending ($Why)" @{ requests = $requests; sockets = $sockets; eventSourceMessages = $Trace.EventSource }
}

function New-ReplyTimeline {
    <# For the timing test: exact time of each step of one reply. Network events use the browser's own
       timestamps (when the data arrived in Edge), page checks the page clock, the rest this computer's clock. #>
    @{ Events = (New-Object System.Collections.Generic.List[object]); Sockets = @{}; Requests = @{}; LastPage = $null; ClockOffset = $null }
}

function Test-Timeline($Bridge) { [bool]($Bridge.PSObject.Properties['Timeline'] -and $Bridge.Timeline) }

function Add-TimelineEvent($Bridge, [string]$What, $Data, $At) {
    if (-not (Test-Timeline $Bridge)) { return }
    if (-not $At) { $At = Get-Date }
    $Bridge.Timeline.Events.Add([pscustomobject]@{ at = $At; what = $What; data = $Data })
}

function Get-RecordShape([string]$Payload) {
    <# Names only: SignalR record types/targets, or the top-level keys of a JSON frame. #>
    $shapes = @()
    foreach ($part in ($Payload -split [char]0x1e)) {
        if (-not $part.Trim()) { continue }
        try { $o = $part | ConvertFrom-Json } catch { $shapes += 'non-json'; continue }
        if ($null -ne $o.type) {
            $shape = "type$($o.type)"
            if ($o.target) { $shape += ":$($o.target)" }
            if ($o.type -eq 2 -or $o.type -eq 3) { $shape += ' (end)' }
            $shapes += $shape
        } else { $shapes += '{' + ((@($o.PSObject.Properties.Name) | Select-Object -First 6) -join ',') + '}' }
    }
    $shapes
}

function Get-BrowserTime($Timeline, $M) {
    <# Wall-clock time of a Network event from Edge's monotonic timestamp (offset learnt from
       requestWillBeSent, which carries both); this computer's clock until the offset is known. #>
    if ($M.params.wallTime -and $M.params.timestamp) { $Timeline.ClockOffset = [double]$M.params.wallTime - [double]$M.params.timestamp }
    if ($null -ne $Timeline.ClockOffset -and $M.params.timestamp) {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([long](([double]$M.params.timestamp + $Timeline.ClockOffset) * 1000)).LocalDateTime
    }
    Get-Date
}

function Add-TimelineNet($Bridge, $M) {
    if (-not (Test-Timeline $Bridge)) { return }
    $tl = $Bridge.Timeline
    if ($M.method -notlike 'Network.*') { return }
    $at = Get-BrowserTime $tl $M
    $id = "$($M.params.requestId)"
    switch ($M.method) {
        'Network.webSocketCreated' { $tl.Sockets[$id] = @{ url = (Get-UrlShape $M.params.url); created = $at; first = $null; last = $null; frames = 0; binary = 0; shapes = @{} } }
        'Network.webSocketFrameReceived' {
            if (-not $tl.Sockets.ContainsKey($id)) { $tl.Sockets[$id] = @{ url = $(if ($Bridge.HubSockets.ContainsKey($id)) { '(Chathub, opened earlier)' } else { '(opened earlier)' }); created = $null; first = $null; last = $null; frames = 0; binary = 0; shapes = @{} } }
            $s = $tl.Sockets[$id]
            if ($null -eq $s.first) { $s.first = $at }
            $s.last = $at; $s.frames++
            if ($M.params.response.opcode -eq 2) { $s.binary++ }
            else {
                foreach ($sh in Get-RecordShape "$($M.params.response.payloadData)") {
                    if (-not $s.shapes.ContainsKey($sh)) { $s.shapes[$sh] = @{ n = 0; first = $at; last = $at } }
                    $s.shapes[$sh].n++; $s.shapes[$sh].last = $at
                }
            }
        }
        'Network.requestWillBeSent' {
            $u = "$($M.params.request.url)"
            # Telemetry, configuration and static files say nothing about how the reply travels.
            $noise = $u -match '(?i)\.(js|css|woff2?|png|svg|ico|jpe?g|gif|webp)(\?|$)|browser\.events\.data\.microsoft|/OneCollector/|/events(\?|$)|challenges\.cloudflare|ecs\.office\.com/config|/manifest[^/]*\.json|/uxversion'
            if ($M.params.type -notmatch '^(Script|Stylesheet|Image|Font|Media|Manifest)$' -and $u -match '^https?:' -and -not $noise) {
                $tl.Requests[$id] = @{ req = "$($M.params.request.method) $(Get-UrlShape $u)"; type = "$($M.params.type)"; sent = $at; mime = $null; response = $null; firstData = $null; lastData = $null; chunks = 0; bytes = 0; done = $null }
            }
        }
        'Network.responseReceived' { if ($tl.Requests.ContainsKey($id)) { $r = $tl.Requests[$id]; $r.response = $at; $r.mime = "$($M.params.response.mimeType)" } }
        'Network.dataReceived' {
            if ($tl.Requests.ContainsKey($id)) { $r = $tl.Requests[$id]; if ($null -eq $r.firstData) { $r.firstData = $at }; $r.lastData = $at; $r.chunks++; $r.bytes += [int]$M.params.dataLength }
        }
        'Network.eventSourceMessageReceived' {
            if ($tl.Requests.ContainsKey($id)) { $r = $tl.Requests[$id]; if ($null -eq $r.firstData) { $r.firstData = $at }; $r.lastData = $at; $r.chunks++ }
        }
        'Network.loadingFinished' { if ($tl.Requests.ContainsKey($id)) { $tl.Requests[$id].done = $at } }
    }
}

function Complete-StreamReply {
    <# The reply once StreamHub has signalled its end: the text from the stream, or, when the stream
       carries no text CCBridge recognises, the exact reply text from the page (read straight away,
       after the page confirms Copilot finished). $null when the page does not confirm the end. #>
    param($Bridge, $S, $PageBefore, [string]$SentPrompt, [long]$Ms)
    $text = $S.Merger.Text; $how = 'stream text'
    if (-not "$text".Trim()) {
        $text = $null
        $until = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $until) {
            $st = Get-PageReplyState $Bridge
            if ($st -and -not $st.stop -and (-not $PageBefore -or $st.fresh -gt 0)) {
                $pt = if ($PageBefore) { Get-PageReplyText $Bridge -Fresh } else { Get-PageReplyText $Bridge }
                $isPlaceholder = $pt.how -ne 'state' -and ("$($pt.text)" -replace '(?i)^\s*copilot said:\s*', '').Trim() -match $script:PlaceholderPattern
                if (-not $isPlaceholder -and "$($pt.text)".Trim() -and ("$($pt.text)" -replace '\s', '') -ne ($SentPrompt -replace '\s', '')) { $text = "$($pt.text)"; $how = "page $($pt.how)"; break }
            }
            Start-Sleep -Milliseconds 150
        }
        if ($null -eq $text) { return $null }
    }
    $bot = @($S.Messages | Where-Object { $_.author -eq 'bot' -and -not $_.messageType -and $_.text }) | Select-Object -Last 1
    $item = [pscustomobject]@{ messages = $S.Messages; result = $S.Result }
    $reply = [pscustomobject]@{
        Text = $text; ServerText = $(if ($bot) { $bot.text } else { $text }); Uncertain = $(if ($how -eq 'page page') { 1 } else { $S.Merger.Uncertain })
        SentText = $SentPrompt; SentMatches = $true
        Result = $(if ($S.Result -and $S.Result.value) { "$($S.Result.value)" } else { 'Success' })
        ResultMessage = $(if ($S.Result -and $S.Result.message) { "$($S.Result.message)" } else { "stream connection, $how" })
        ConversationId = $null; Throttling = $S.Throttling
        Metering = $(if ($S.Result) { @($S.Result.meteringInformation)[0] } else { $null })
        References = @(if ($bot) { Get-ReplyReferences $bot })
        ProposedActions = @(try { Get-ProposedActions $item } catch { })
        ActionClaims = @(Get-ActionClaims $text); Source = 'streamhub'
    }
    Write-CCBLog verbose bridge 'Reply received over the Copilot stream connection' @{ ms = $Ms; end = $S.Why; text = $how; items = $S.Items; chars = $text.Length; result = $reply.Result
        chat = "$($S.Throttling.numUserMessagesInConversation)/$($S.Throttling.maxNumUserMessagesInConversation)"; fields = @($S.Keys | Sort-Object) }
    $reply
}

function Get-ReplyTimelineSummary {
    <# Milestones (ms after Send) and a chronological list (HH:mm:ss.fff +ms event) of one reply
       timeline, for the timing and complexity tests. Names, sizes and times only. #>
    param([Parameter(Mandatory)]$Timeline)
    $tl = $Timeline
    $sent = @($tl.Events | Where-Object what -eq 'sent' | Select-Object -First 1)
    $t0 = if ($sent) { [datetime]$sent[0].at } else { Get-Date }
    $rows = New-Object System.Collections.Generic.List[object]
    $add = { param($At, [string]$What) if ($At) { $rows.Add([pscustomobject]@{ at = [datetime]$At; text = $What }) } }
    foreach ($e in $tl.Events) { & $add $e.at ($(if ($e.data) { "$($e.what): $($e.data)" } else { $e.what })) }
    foreach ($s in $tl.Sockets.Values) {
        if (-not $s.frames) { continue }
        $u = Protect-LogText $s.url
        & $add $s.created "socket opened $u"
        & $add $s.first "socket first frame $u"
        & $add $s.last "socket last frame $u ($($s.frames) frames, $($s.binary) binary)"
        foreach ($k in $s.shapes.Keys) {
            $x = $s.shapes[$k]
            & $add $x.first "  record $k first (x$($x.n)) on $u"
            if ($x.n -gt 1) { & $add $x.last "  record $k last on $u" }
        }
    }
    foreach ($q in $tl.Requests.Values) {
        $n = Protect-LogText $q.req
        & $add $q.sent "request $n [$($q.type)]"
        & $add $q.response "  response $n ($($q.mime))"
        & $add $q.firstData "  first data $n"
        if ($q.chunks -gt 1) { & $add $q.lastData "  last data $n ($($q.chunks) chunks, $($q.bytes) B)" }
        & $add $q.done "  finished $n"
    }
    $ms = { param($At) if ($At) { [long](([datetime]$At) - $t0).TotalMilliseconds } else { $null } }
    $pages = @($tl.Events | Where-Object what -eq 'page')
    $stopOn = @($pages | Where-Object { "$($_.data)" -match 'stop=True' } | Select-Object -First 1)
    $stopOff = if ($stopOn) { @($pages | Where-Object { $_.at -gt $stopOn[0].at -and "$($_.data)" -match 'stop=False' } | Select-Object -First 1) } else { @() }
    $text1 = @($pages | Where-Object { "$($_.data)" -match 'len=[1-9]' } | Select-Object -First 1)
    $ret = @($tl.Events | Where-Object what -eq 'returned' | Select-Object -First 1)
    $hub = @($tl.Events | Where-Object { $_.what -match '^first (Chathub|stream connection) frame$' } | Sort-Object at | Select-Object -First 1)
    $lastHub = @($tl.Sockets.Values | Where-Object { $_.url -match '(?i)chathub|streamhub' -and $_.last } | ForEach-Object { $_.last } | Sort-Object | Select-Object -Last 1)
    $o = [ordered]@{
        sentAt = $t0.ToString('HH:mm:ss.fff')
        route = $(if ($ret) { "$($ret[0].data)" } else { $null })
        firstTextOnPageMs = & $ms $(if ($text1) { $text1[0].at })
        stopShownMs = & $ms $(if ($stopOn) { $stopOn[0].at })
        stopGoneMs = & $ms $(if ($stopOff) { $stopOff[0].at })
        firstHubFrameMs = & $ms $(if ($hub) { $hub[0].at })
        lastHubFrameMs = & $ms $(if ($lastHub) { $lastHub[0] })
        returnedMs = & $ms $(if ($ret) { $ret[0].at })
        waitAfterStopGoneMs = $null; waitAfterLastHubFrameMs = $null
        timeline = @($rows | Sort-Object at | ForEach-Object { '{0}  {1,7}  {2}' -f $_.at.ToString('HH:mm:ss.fff'), ('+' + [long]($_.at - $t0).TotalMilliseconds), $_.text })
    }
    if ($null -ne $o.returnedMs -and $null -ne $o.stopGoneMs) { $o.waitAfterStopGoneMs = $o.returnedMs - $o.stopGoneMs }
    if ($null -ne $o.returnedMs -and $null -ne $o.lastHubFrameMs) { $o.waitAfterLastHubFrameMs = $o.returnedMs - $o.lastHubFrameMs }
    [pscustomobject]$o
}

function Send-CopilotPrompt {
    <#
    .SYNOPSIS Sends a prompt and returns the complete markdown reply.
    .OUTPUTS  [pscustomobject] Text, ServerText, Uncertain, SentText, SentMatches, Result, ConversationId, Throttling, Metering
    #>
    param(
        [Parameter(Mandatory)]$Bridge,
        [Parameter(Mandatory)][string]$Text,
        [int]$TimeoutSec = 300,
        [scriptblock]$OnProgress,
        [scriptblock]$CancelCheck,   # returns $true to stop now: Copilot's Stop is pressed and Cancelled = $true is returned
        [int]$StallSec = 90          # no data from Copilot this long: it hangs; press Stop and report NoAnswer
    )
    Use-CopilotLock {
        $r = Send-CopilotPromptUnlocked -Bridge $Bridge -Text $Text -TimeoutSec $TimeoutSec -OnProgress $OnProgress -CancelCheck $CancelCheck -StallSec $StallSec
        if ($Bridge.PSObject.Properties['LastReplyAt']) { $Bridge.LastReplyAt = Get-Date }
        if ($r.Result -eq 'Lost') {
            # The request never reached Copilot's answer stream (seen when the page opens that
            # connection only at the first send). The connection exists now: send it once more.
            Write-CCBLog info bridge 'No part of the reply arrived; sending the prompt again'
            Add-TimelineEvent $Bridge 'resent' $null
            $r = Send-CopilotPromptUnlocked -Bridge $Bridge -Text $Text -TimeoutSec $TimeoutSec -OnProgress $OnProgress -CancelCheck $CancelCheck -StallSec $StallSec -LostSec 0
            if ($r.Result -eq 'Lost') { $r.Result = 'NoAnswer' }
        }
        if ($Bridge.PSObject.Properties['LastReplyAt']) { $Bridge.LastReplyAt = Get-Date }
        $r
    }
}

function Send-CopilotPromptUnlocked {
    param(
        [Parameter(Mandatory)]$Bridge,
        [Parameter(Mandatory)][string]$Text,
        [int]$TimeoutSec = 300,
        [scriptblock]$OnProgress,
        [scriptblock]$CancelCheck,
        [int]$StallSec = 90,
        [int]$LostSec = 25     # no part of the reply this long after sending: the request was lost (0 = off)
    )
    $s = $Bridge.Session
    $replyRecords = 0      # records that belong to a reply (not handshakes or keep-alive pings)
    while ($s.Events.Count) { $null = $s.Events.Dequeue() }   # drop stale events
    $sendWatch = [Diagnostics.Stopwatch]::StartNew()
    Write-CCBLog trace bridge 'Prompt text' @{ text = $Text }

    # The page itself is watched too: if the reply does not arrive over the Chathub socket (other
    # tenants may deliver it differently), it is read from the page once Copilot has finished.
    Set-PageReplyBaseline $Bridge
    $pageBefore = Get-PageReplyState $Bridge
    if ($Bridge.PSObject.Properties['LastReplyAt'] -and $Bridge.LastReplyAt -and $Bridge.Pacing) {
        $left = [double]$Bridge.Pacing.betweenPromptsSec - ((Get-Date) - $Bridge.LastReplyAt).TotalSeconds
        if ($left -gt 0) { Write-CCBLog verbose bridge "Pause $([Math]::Round($left, 1)) s (gap after the previous reply)"; $until = (Get-Date).AddSeconds($left); while ((Get-Date) -lt $until) { $null = Receive-CdpEvent $s 200 } }
    }
    Add-TimelineEvent $Bridge 'typing' $null
    Set-CopilotInput $Bridge $Text
    Wait-Pacing $Bridge 'beforeSendSec' 'prompt typed, before Send'
    Invoke-CopilotSend $Bridge
    $sendWatch.Restart()   # timings and the lost-request check count from Send
    Add-TimelineEvent $Bridge 'sent' $null
    $net = New-NetTrace
    # How often the page is checked, and how long it must look finished before it counts.
    $pageEveryMs = if ($Bridge.PSObject.Properties['PageCheckMs'] -and $Bridge.PageCheckMs) { [int]$Bridge.PageCheckMs } else { 500 }
    $pageStableSec = if ($Bridge.PSObject.Properties['PageStableSec'] -and $null -ne $Bridge.PageStableSec) { [double]$Bridge.PageStableSec } else { 1.0 }
    $nextPageCheck = (Get-Date).AddSeconds(2)
    $pageDoneSince = $null; $pageLastLen = -1; $sawStop = $false; $pageQuietSince = $null

    $hubPattern = [regex]::Escape($Bridge.Selectors.chatHubUrlPattern)
    $streamPattern = [regex]::Escape($(if ($Bridge.Selectors.PSObject.Properties['streamHubUrlPattern'] -and $Bridge.Selectors.streamHubUrlPattern) { $Bridge.Selectors.streamHubUrlPattern } else { '/StreamHub/' }))
    $stream = New-StreamState
    $merger = New-ReplyMerger
    $frames = New-Object System.Collections.Generic.List[string]   # kept for diagnosis
    $reported = 0
    # The page may run several requests over the same connection (titles, suggestions, ...).
    # The id of the request carrying our prompt is taken from the outgoing frames, and only its
    # completion ends the wait; completions of other requests are ignored.
    $myInvocation = $null
    $sentTargets = New-Object System.Collections.Generic.List[string]
    # Copilot sometimes gives up silently (for example a source it cannot reach): the page shows
    # "Regenerate" and nothing more arrives. Checked after a quiet spell instead of waiting the full timeout.
    $lastActivity = Get-Date
    $nextStallCheck = (Get-Date).AddSeconds(30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($CancelCheck -and (& $CancelCheck)) {
            $was = Stop-CopilotReply $Bridge
            $keep = $merger.Text; $finished = $false
            if ($was -eq 'idle' -and $pageBefore) {
                # Copilot had already finished; only CCBridge was still waiting. Keep its reply.
                try {
                    $pt = Get-PageReplyText $Bridge -Fresh
                    $ptext = "$($pt.text)"
                    $placeholder = $pt.how -ne 'state' -and ($ptext -replace '(?i)^\s*copilot said:\s*', '').Trim() -match $script:PlaceholderPattern
                    if ($ptext.Trim() -and -not $placeholder -and ($ptext -replace '\s', '') -ne ($Text -replace '\s', '')) { $keep = $ptext; $finished = $true }
                } catch { }
            }
            Write-CCBLog info bridge "Reply cancelled by the user ($(if ($finished) { 'Copilot had already finished' } else { $was }))" @{ chars = "$keep".Length; ms = $sendWatch.ElapsedMilliseconds }
            return [pscustomobject]@{ Cancelled = $true; Text = $keep; ServerText = $null; Uncertain = $merger.Uncertain; Result = 'Cancelled'
                ResultMessage = $(if ($finished) { 'Copilot had already finished' } else { 'Stopped by the user' }); CopilotFinished = $finished
                SentMatches = $true; References = @(); ProposedActions = @(); ActionClaims = @() }
        }
        $m = Receive-CdpEvent $s 400
        if ($m) { Add-NetTrace $net $Bridge $m; Add-TimelineNet $Bridge $m }
        if ($pageBefore -and (Get-Date) -gt $nextPageCheck) {
            $nextPageCheck = (Get-Date).AddMilliseconds($pageEveryMs)
            $st = Get-PageReplyState $Bridge
            if ($st -and (Test-Timeline $Bridge)) {
                # Record each change of what the page shows.
                $sig = "stop=$($st.stop) replies=$($st.replies) new=$($st.fresh) copies=$($st.copies) len=$($st.lastLen) stateLen=$($st.stateLen) flags=$(($st.flags | ConvertTo-Json -Compress))"
                if ($sig -ne $Bridge.Timeline.LastPage) { $Bridge.Timeline.LastPage = $sig; Add-TimelineEvent $Bridge 'page' $sig $(if ($st.now) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$st.now).LocalDateTime } else { $null }) }
            }
            if ($st) {
                if ($st.stop) { $sawStop = $true }   # a spinner that never ends must still count as a stall
                if ($st.bar -and $st.bar -ne $pageBefore.bar -and $st.bar -match $script:LimitPattern) {
                    Write-CCBLog info bridge 'Copilot shows a usage limit' @{ message = $st.bar; ms = $sendWatch.ElapsedMilliseconds }
                    Add-TimelineEvent $Bridge 'returned' 'usage limit on the page'
                    $null = Stop-CopilotReply $Bridge -DrainSec 2
                    return [pscustomobject]@{ Cancelled = $false; Text = ''; ServerText = $null; Uncertain = 0; SentText = $Text; SentMatches = $true
                        Result = 'OutOfCredits'; ResultMessage = $st.bar; ConversationId = $null; Throttling = $null; Metering = $null
                        References = @(); ProposedActions = @(); ActionClaims = @(); Source = 'page' }
                }
                if ($st.lastLen -ne $pageLastLen) { if ($pageLastLen -ge 0) { $lastActivity = Get-Date }; $pageLastLen = $st.lastLen; $pageDoneSince = $null; $pageQuietSince = $null }
                # No Stop button and nothing changing: finished, even when the reply shows no Copy button.
                if (-not $st.stop -and $st.lastFresh -and $st.lastLen -gt 0) { if (-not $pageQuietSince) { $pageQuietSince = Get-Date } } else { $pageQuietSince = $null }
                $quietDone = $pageQuietSince -and ((Get-Date) - $pageQuietSince).TotalSeconds -ge 8
                $finished = -not $st.stop -and $st.lastFresh -and ($st.lastHasCopy -or $st.copies -gt $pageBefore.copies -or $quietDone) -and $st.lastLen -gt 0 -and
                    ($sawStop -or $sendWatch.Elapsed.TotalSeconds -ge 6)
                # When StreamHub carried this reply and has been quiet for a moment, the page need not settle.
                $stableNeeded = if ($stream.Items -and $stream.LastAt -and ((Get-Date) - $stream.LastAt).TotalMilliseconds -ge 300) { 0 } else { $pageStableSec }
                if (-not $finished) { $pageDoneSince = $null }
                elseif (-not $pageDoneSince) { $pageDoneSince = Get-Date }
                if ($finished -and ((Get-Date) - $pageDoneSince).TotalSeconds -ge $stableNeeded) {
                    # Finished on the page and stable, and no completion came over the socket.
                    $pt = Get-PageReplyText $Bridge -Fresh
                    $ptext = "$($pt.text)"
                    # Copilot's own progress placeholders are not an answer.
                    $placeholder = $pt.how -ne 'state' -and ($ptext -replace '(?i)^\s*copilot said:\s*', '').Trim() -match $script:PlaceholderPattern
                    if ($placeholder) { Write-CCBLog verbose bridge 'Page shows only a progress placeholder; still waiting' @{ chars = $ptext.Length } }
                    if (-not $placeholder -and $ptext.Trim() -and ($ptext -replace '\s', '') -ne ($Text -replace '\s', '')) {
                        Write-CCBLog info bridge "Reply read from the page ($($pt.how)); no completion arrived over the Chathub socket" @{ chars = $ptext.Length; hubChars = $merger.Text.Length; frames = $frames.Count; invocation = $myInvocation; ms = $sendWatch.ElapsedMilliseconds }
                        Write-NetTrace $net 'reply read from the page'
                        if ($stream.Items) { Write-CCBLog info bridge 'The Copilot stream connection carried the reply but its end was not recognised' @{ items = $stream.Items; fields = @($stream.Keys | Sort-Object) } }
                        Add-TimelineEvent $Bridge 'returned' "page ($($pt.how))"
                        if ($Bridge.SaveFrames -and $frames.Count) { Save-ReplyFrames $frames }
                        return [pscustomobject]@{ Cancelled = $false; Text = $ptext; ServerText = $ptext; Uncertain = $(if ($pt.how -eq 'state') { 0 } else { 1 })
                            SentText = $Text; SentMatches = $true; Result = 'Success'; ResultMessage = "read from the page ($($pt.how))"
                            ConversationId = $null; Throttling = $null; Metering = $null; References = @(); ProposedActions = @()
                            ActionClaims = @(Get-ActionClaims $ptext); Source = 'page' }
                    }
                    $pageDoneSince = $null
                }
            }
        }
        if ($LostSec -gt 0 -and $replyRecords -eq 0 -and $sendWatch.Elapsed.TotalSeconds -ge $LostSec -and $pageLastLen -le 40) {
            # Nothing of a reply arrived (at most a placeholder on the page): the request was lost.
            Write-CCBLog info bridge "No part of the reply arrived within $LostSec s" @{ frames = $frames.Count; pageChars = $pageLastLen; sent = @($sentTargets | Select-Object -Unique) }
            $null = Stop-CopilotReply $Bridge -DrainSec 3
            Write-NetTrace $net 'request lost'
            Add-TimelineEvent $Bridge 'lost' "no reply records within $LostSec s"
            return [pscustomobject]@{ Cancelled = $false; Text = ''; ServerText = $null; Uncertain = 0; SentText = $Text; SentMatches = $true
                Result = 'Lost'; ResultMessage = "No part of the reply arrived within $LostSec seconds"; ConversationId = $null; Throttling = $null
                Metering = $null; References = @(); ProposedActions = @(); ActionClaims = @() }
        }
        $quiet = ((Get-Date) - $lastActivity).TotalSeconds
        if ((Get-Date) -gt $nextStallCheck -and $quiet -ge 30) {
            $nextStallCheck = (Get-Date).AddSeconds(10)
            $gaveUp = Test-CopilotGaveUp $Bridge
            if ($gaveUp -and $pageBefore) {
                # Copilot also shows Regenerate under a finished reply. If this turn has a real reply on
                # the page, it finished without CCBridge noticing: read it rather than give up.
                $st = Get-PageReplyState $Bridge
                if ($st -and -not $st.stop -and $st.fresh -gt 0) {
                    $pt = Get-PageReplyText $Bridge -Fresh
                    $ptext = "$($pt.text)"
                    $placeholder = $pt.how -ne 'state' -and ($ptext -replace '(?i)^\s*copilot said:\s*', '').Trim() -match $script:PlaceholderPattern
                    if ($ptext.Trim().Length -gt 40 -and -not $placeholder) {
                        Write-CCBLog info bridge "Reply read from the page after a quiet spell ($($pt.how), $($pt.parts) block(s))" @{ chars = $ptext.Length; lastHasCopy = $st.lastHasCopy; copies = $st.copies; copiesBefore = $pageBefore.copies; ms = $sendWatch.ElapsedMilliseconds }
                        Write-NetTrace $net 'reply read from the page after a quiet spell'
                        Add-TimelineEvent $Bridge 'returned' "page ($($pt.how), after a quiet spell)"
                        if ($Bridge.SaveFrames -and $frames.Count) { Save-ReplyFrames $frames }
                        return [pscustomobject]@{ Cancelled = $false; Text = $ptext; ServerText = $ptext; Uncertain = $(if ($pt.how -eq 'state') { 0 } else { 1 })
                            SentText = $Text; SentMatches = $true; Result = 'Success'; ResultMessage = "read from the page ($($pt.how))"
                            ConversationId = $null; Throttling = $null; Metering = $null; References = @(); ProposedActions = @()
                            ActionClaims = @(Get-ActionClaims $ptext); Source = 'page' }
                    }
                }
            }
            $hangs = -not $gaveUp -and $StallSec -gt 0 -and $quiet -ge $StallSec
            if ($hangs) { $null = Stop-CopilotReply $Bridge -DrainSec 5 }
            if ($gaveUp -or $hangs) {
                Write-CCBLog info bridge "Copilot stopped without answering ($(if ($hangs) { "no data for $([int]$quiet) s" } else { 'page shows Regenerate' }))" @{ partialChars = $merger.Text.Length; frames = $frames.Count; invocation = $myInvocation; sent = @($sentTargets | Select-Object -Unique) }
                Write-NetTrace $net 'no answer'
                if ($Bridge.SaveFrames -and $frames.Count) { Save-ReplyFrames $frames }
                return [pscustomobject]@{ Cancelled = $false; Text = $merger.Text; ServerText = $null; Uncertain = $merger.Uncertain; Result = 'NoAnswer'
                    ResultMessage = "Copilot stopped without answering$(if ($hangs) { " (no data for $([int]$quiet) seconds)" }). Usually it could not reach a source it needed (for example email or calendar), or the request was blocked."
                    SentMatches = $true; References = @(); ProposedActions = @(); ActionClaims = @() }
            }
        }
        if (-not $m) { continue }
        if ($m.method -eq 'Network.webSocketCreated') {
            if ($m.params.url -match $streamPattern) { $Bridge.HubSockets[$m.params.requestId] = 'stream' }
            elseif ($m.params.url -match $hubPattern) { $Bridge.HubSockets[$m.params.requestId] = 'chat' }
            continue
        }
        if ($m.method -eq 'Network.webSocketFrameSent') {
            $sent = $m.params.response.payloadData
            if (-not $Bridge.HubSockets.ContainsKey($m.params.requestId) -and $sent -notmatch '"invocationId"') { continue }
            foreach ($rec in Read-HubRecords $sent) {
                if ($rec.target) { $sentTargets.Add("$($rec.type):$($rec.target)") }
                $isPrompt = $null -ne $rec.invocationId -and ($rec.type -eq 1 -or $rec.type -eq 4) -and
                    ("$($rec.target)" -match '(?i)chat' -or ($rec.arguments -and $rec.arguments[0].PSObject.Properties['message']))
                if (-not $myInvocation -and $isPrompt) {
                    $myInvocation = [string]$rec.invocationId
                    Write-CCBLog verbose bridge 'Request sent' @{ invocation = $myInvocation; target = "$($rec.target)"; type = $rec.type }
                }
            }
            continue
        }
        if ($m.method -ne 'Network.webSocketFrameReceived') { continue }
        if ($env:CCBRIDGE_TEST_IGNORE_HUB -eq '1') { continue }   # test switch: rely on the page only
        # Frames from a socket opened before Network.enable have no webSocketCreated; they are
        # classified by the shape of their traffic.
        $payload = $m.params.response.payloadData
        $kind = Get-SocketKind $Bridge $m.params.requestId $payload
        if (-not $kind) { continue }
        $frames.Add($payload)
        if ($kind -eq 'stream') {
            # StreamHub (primary where the tenant uses it): its end-of-reply ends the wait at once.
            if ($frames.Count -eq 1 -or $stream.Items -eq 0) { Add-TimelineEvent $Bridge 'first stream connection frame' $null $(if (Test-Timeline $Bridge) { Get-BrowserTime $Bridge.Timeline $m }) }
            foreach ($rec in Read-HubRecords $payload) {
                if ($myInvocation -and $null -ne $rec.invocationId -and [string]$rec.invocationId -ne $myInvocation) { continue }
                # Handshakes ({}) and keep-alive pings (type 6) are not part of a reply.
                if ($rec.type -ge 1 -and $rec.type -le 3) { $replyRecords++; $lastActivity = Get-Date }
                Add-StreamRecord $stream $rec
            }
            if ($stream.Done) {
                $reply = Complete-StreamReply $Bridge $stream $pageBefore $Text $sendWatch.ElapsedMilliseconds
                if ($reply) {
                    if ($Bridge.SaveFrames) { Save-ReplyFrames $frames }
                    Write-NetTrace $net 'reply over the Copilot stream connection'
                    Add-TimelineEvent $Bridge 'returned' "stream connection ($($reply.ResultMessage))"
                    return $reply
                }
                Write-CCBLog verbose bridge 'The Copilot stream connection signalled an end that the page does not confirm; waiting' @{ why = $stream.Why; items = $stream.Items }
                $stream.Done = $false
            }
            continue
        }
        if ($frames.Count -eq 1) { Add-TimelineEvent $Bridge 'first Chathub frame' $null $(if (Test-Timeline $Bridge) { Get-BrowserTime $Bridge.Timeline $m }) }
        foreach ($rec in Read-HubRecords $payload) {
            if ($rec.type -ge 1 -and $rec.type -le 3) { $replyRecords++; $lastActivity = Get-Date }
            $isEnd = $rec.type -eq 2 -or $rec.type -eq 3
            if ($isEnd -and $myInvocation -and $null -ne $rec.invocationId -and [string]$rec.invocationId -ne $myInvocation) {
                Write-CCBLog verbose bridge "Ignored the completion of another request (invocation $($rec.invocationId))"
                continue
            }
            $item = Add-HubRecord $merger $rec
            if ($item) {
                if (-not $myInvocation -and -not $merger.Text -and -not (Get-BotReplyText $item.messages) -and
                    (-not $item.result -or $item.result.value -eq 'Success')) {
                    # Without a known request id: an empty "success" is not our reply; keep waiting.
                    Write-CCBLog verbose bridge 'Ignored an empty completion' @{ invocation = "$($rec.invocationId)"; fields = @($item.PSObject.Properties.Name) }
                    continue
                }
                if ($Bridge.SaveFrames) { Save-ReplyFrames $frames }
                $reply = Complete-Reply $merger $item $Text
                Write-ReplyLog $reply $item $frames $sendWatch.ElapsedMilliseconds
                Write-NetTrace $net 'reply over the Chathub socket'
                Add-TimelineEvent $Bridge 'returned' 'Chathub socket'
                return $reply
            }
        }
        if ($OnProgress -and $merger.Text.Length -ne $reported) {
            $reported = $merger.Text.Length
            & $OnProgress $merger.Text
        }
    }
    Write-CCBLog info bridge "No complete reply within $TimeoutSec s" @{ partialChars = $merger.Text.Length; frames = $frames.Count; invocation = $myInvocation; sent = @($sentTargets | Select-Object -Unique) }
    Write-NetTrace $net 'timeout'
    if ($Bridge.SaveFrames -and $frames.Count) { Save-ReplyFrames $frames }
    $null = Stop-CopilotReply $Bridge
    throw "No complete reply within $TimeoutSec s (partial: $($merger.Text.Length) chars)"
}

function Get-SelectorOrDefault($Bridge, [string]$Name, [string]$Default) {
    if ($Bridge.Selectors.PSObject.Properties[$Name] -and $Bridge.Selectors.$Name) { $Bridge.Selectors.$Name } else { $Default }
}

function Get-PageReplyState {
    <# What the page shows: number of finished replies (with a copy button), whether Copilot is still
       answering (Stop visible), and the length of the last reply text. Used when the answer does not
       arrive over the Chathub socket (other tenants may deliver replies differently). #>
    param([Parameter(Mandatory)]$Bridge)
    $reply = ConvertTo-JsString (Get-SelectorOrDefault $Bridge 'replyContainer' "[data-testid='copilot-message-reply-div']")
    $copy = ConvertTo-JsString (Get-SelectorOrDefault $Bridge 'copyReplyButton' "button[aria-label='Copy Response' i]")
    $stop = ConvertTo-JsString $Bridge.Selectors.stopButton
    $withFlags = if ($Bridge.PSObject.Properties['Timeline'] -and $Bridge.Timeline) { 'true' } else { 'false' }
    $bars = ConvertTo-JsString (Get-SelectorOrDefault $Bridge 'messageBar' "[data-testid^='message-bar'], [role='alert']")
    $js = @"
(() => {
  const vis = e => e && e.offsetParent !== null;
  const replies = [...document.querySelectorAll($reply)];
  const last = replies[replies.length - 1];
  // Copilot keeps only recent messages on the page in a long chat, so the number of replies says
  // nothing: a reply is new when its message id was not on the page when the prompt was sent.
  const seen = window.__ccbSeen;
  const isSeen = (r) => { const h = r.closest('[data-testid="copilot-message-div"]') || r; return r.dataset.ccbSeen === '1' || !!(seen && h.id && seen.has(h.id)); };
  const out = {
    fresh: replies.filter(r => !isSeen(r)).length,
    lastFresh: !!last && !isSeen(last),
    replies: replies.length,
    copies: [...document.querySelectorAll($copy)].filter(vis).length,
    stop: [...document.querySelectorAll($stop)].some(vis),
    lastLen: last ? (last.innerText || '').length : 0,
    lastHasCopy: !!last && [...((last.closest('[data-testid="copilot-message-div"]') || last.parentElement || last).querySelectorAll($copy))].some(vis),
    bar: [...document.querySelectorAll($bars)].filter(vis).map(e => (e.innerText || '').trim()).filter(Boolean).join(' | ').slice(0, 300),
    now: Date.now()
  };
  if ($withFlags && last) {
    // Timing test only: state flags of the last reply (names and short values, never text).
    const flags = {}; let stateLen = -1;
    let e = last;
    for (let i = 0; i < 6 && e; i++, e = e.parentElement) {
      const fk = Object.keys(e).find(k => k.startsWith('__reactFiber$'));
      if (!fk) continue;
      let f = e[fk];
      for (let j = 0; j < 30 && f; j++, f = f.return) {
        const p = f.memoizedProps;
        if (!p || typeof p !== 'object') continue;
        for (const k of Object.keys(p)) {
          if (!/stream|final|complete|done|state|status|loading|progress|typing|pending|finish|busy|end/i.test(k)) continue;
          const v = p[k];
          if (typeof v === 'boolean' || typeof v === 'number' || (typeof v === 'string' && v.length <= 24 && !/\s/.test(v))) flags[k] = v;
        }
        if (stateLen < 0 && p.response && typeof p.response.text === 'string') stateLen = p.response.text.length;
      }
      break;
    }
    out.flags = flags; out.stateLen = stateLen;
  }
  return JSON.stringify(out);
})()
"@
    try { Invoke-CdpEval $Bridge.Session $js | ConvertFrom-Json } catch { if ($Bridge.Session.Lost) { throw }; $null }
}

function Set-PageReplyBaseline {
    <# Records the replies on the page just before a prompt is sent; replies not recorded are new. #>
    param([Parameter(Mandatory)]$Bridge)
    $reply = ConvertTo-JsString (Get-SelectorOrDefault $Bridge 'replyContainer' "[data-testid='copilot-message-reply-div']")
    try {
        $null = Invoke-CdpEval $Bridge.Session @"
(() => {
  const rs = [...document.querySelectorAll($reply)];
  window.__ccbSeen = new Set(rs.map(r => (r.closest('[data-testid="copilot-message-div"]') || r).id).filter(Boolean));
  rs.forEach(r => { r.dataset.ccbSeen = '1'; });
  return rs.length;
})()
"@
    } catch { if ($Bridge.Session.Lost) { throw } }
}

function Get-PageReplyText {
    <# Text of this turn's reply from the page: every reply block from index $FromIndex on (Copilot can
       split one answer over several blocks), each from the raw markdown the page keeps in its React
       state (exact, code intact), else from its visible text (formatting lost, marked uncertain). #>
    param([Parameter(Mandatory)]$Bridge, [int]$FromIndex = -1, [switch]$Fresh)
    $freshJs = if ($Fresh) { 'true' } else { 'false' }
    $reply = ConvertTo-JsString (Get-SelectorOrDefault $Bridge 'replyContainer' "[data-testid='copilot-message-reply-div']")
    $js = @"
(() => {
  const replies = [...document.querySelectorAll($reply)];
  if (!replies.length) return JSON.stringify({ how: 'none', text: '', parts: 0 });
  const from = $FromIndex < 0 ? replies.length - 1 : Math.min($FromIndex, replies.length - 1);
  const seen = window.__ccbSeen;
  const isSeen = (r) => { const h = r.closest('[data-testid="copilot-message-div"]') || r; return r.dataset.ccbSeen === '1' || !!(seen && h.id && seen.has(h.id)); };
  const pick_list = $freshJs ? replies.filter(r => !isSeen(r)) : replies.slice(from);
  const pick = (p) => {
    if (!p || typeof p !== 'object') return null;
    const r = p.response;
    if (r && typeof r === 'object' && typeof r.text === 'string' && r.text) return r.text;
    if (typeof p.legacyReplyMessage === 'string' && p.legacyReplyMessage) return p.legacyReplyMessage;
    if (Array.isArray(p.responses) && p.responses.length) {
      const t = p.responses[p.responses.length - 1];
      if (t && typeof t.text === 'string' && t.text) return t.text;
    }
    return null;
  };
  // Letters and digits only, lowercase: compares raw markdown with rendered text.
  const alnum = (s) => (s || '').toLowerCase().replace(/[^a-z0-9]+/g, '');
  // Copilot's code viewer adds labels to the visible text; they are never part of the answer.
  const chrome = /^(copilot said:|copy code|copy|go to line.*|.*isn.t fully supported\. syntax highlighting is based on .*|.*wordt niet volledig ondersteund.*)$/i;
  const visibleText = (el) => {
    const md = el.querySelector('[data-testid="markdown-reply"]') || el;
    return (md.innerText || '').split('\n').filter(l => !chrome.test(l.trim())).join('\n');
  };
  // Any string in the component state that holds this reply: it starts with the reply's visible
  // beginning. Independent of field names, which differ between Copilot versions and tenants.
  const search = (props, head, tail, minLen) => {
    const found = [];
    const seen = new Set();
    const walk = (o, d) => {
      if (!o || typeof o !== 'object' || d > 3 || seen.has(o) || o instanceof Node) return;
      seen.add(o);
      for (const k of Object.keys(o)) {
        if (k === 'children' || k === '_owner') continue;
        let v; try { v = o[k]; } catch (x) { continue; }
        if (typeof v === 'string') {
          if (v.length >= 20) { const a = alnum(v); if (a.length >= minLen && a.slice(0, 600).includes(head)) found.push({ v, end: !tail || a.includes(tail) }); }
        } else if (v && typeof v === 'object') walk(v, d + 1);
      }
    };
    walk(props, 0);
    if (!found.length) return null;
    const withEnd = found.filter(x => x.end);
    const pool = withEnd.length ? withEnd : found;
    // The shortest match is this reply alone (longer ones can span the whole conversation).
    return pool.sort((x, y) => x.v.length - y.v.length)[0].v;
  };
  const textOf = (el) => {
    let e = el.querySelector('[data-testid="markdown-reply"]') || el;
    const vis = visibleText(el);
    const va = alnum(vis);
    // A short start (the visible text skips code-block info strings and edit markers), and a plausible
    // length (visible text can miss lines of long code blocks, so the stored text may be longer).
    const head = va.slice(0, 16), tail = va.length > 80 ? va.slice(-30) : '', minLen = Math.floor(va.length * 0.5);
    for (let i = 0; i < 8 && e; i++, e = e.parentElement) {
      const fk = Object.keys(e).find(k => k.startsWith('__reactFiber$'));
      if (!fk) continue;
      let f = e[fk];
      for (let j = 0; j < 30 && f; j++, f = f.return) {
        let t = null; try { t = pick(f.memoizedProps); } catch (x) { }
        if (t) return { how: 'state', text: t };
        if (head.length >= 10) { try { t = search(f.memoizedProps, head, tail, minLen); } catch (x) { } }
        if (t) return { how: 'state', text: t };
      }
    }
    return { how: 'page', text: vis };
  };
  const parts = [];
  for (const el of pick_list) {
    const p = textOf(el);
    // Progress placeholders are not part of the answer; blocks of one answer can share the same
    // state text: keep each text once.
    const flat = (p.text || '').replace(/^\s*copilot said:\s*/i, '').trim();
    if (p.how !== 'state' && flat.length < 60 && /^(working on it|taking a look|thinking|searching|generating|one moment)[^\n]{0,40}(\u2026|\.\.\.)\s*$/i.test(flat)) continue;
    if (p.text && !parts.some(q => q.text === p.text)) parts.push(p);
  }
  return JSON.stringify({
    how: parts.length && parts.every(p => p.how === 'state') ? 'state' : 'page',
    text: parts.map(p => p.text).join('\n\n'),
    parts: parts.length
  });
})()
"@
    Invoke-CdpEval $Bridge.Session $js | ConvertFrom-Json
}

function Test-CopilotGaveUp {
    <# True when the page shows Copilot's Regenerate button and no Stop button: the turn is over without an answer. #>
    param([Parameter(Mandatory)]$Bridge)
    $regen = if ($Bridge.Selectors.PSObject.Properties['regenerateButton']) { $Bridge.Selectors.regenerateButton } else { "button[aria-label*='Regenerate' i]" }
    $js = @"
(() => {
  const visible = (e) => e && e.offsetParent !== null;
  const regen = [...document.querySelectorAll($(ConvertTo-JsString $regen))].some(visible)
    || [...document.querySelectorAll('button')].some(b => visible(b) && /^\s*regenerate\s*$/i.test(b.innerText || ''));
  const stop = [...document.querySelectorAll($(ConvertTo-JsString $Bridge.Selectors.stopButton))].some(visible);
  return regen && !stop;
})()
"@
    try { [bool](Invoke-CdpEval $Bridge.Session $js) } catch { if ($Bridge.Session.Lost) { throw }; $false }
}

function Stop-CopilotReply {
    <# Stops Copilot's current reply. Returns 'idle' when Copilot had already finished (its Stop button
       is not shown: nothing is pressed), else 'stopped'. After pressing Stop it waits until the reply
       has ended, by the hub's end record or by the page no longer showing Stop, whichever comes first,
       so a late completion cannot be taken for the answer to the next prompt. #>
    param([Parameter(Mandatory)]$Bridge, [int]$DrainSec = 15)
    $before = Get-PageReplyState $Bridge
    if ($before -and -not $before.stop) {
        Write-CCBLog verbose bridge 'Copilot had already finished; nothing to stop'
        return 'idle'
    }
    $stopSel = ConvertTo-JsString $Bridge.Selectors.stopButton
    $clicked = $false
    try {
        $clicked = Invoke-CdpEval $Bridge.Session @"
(() => {
  const b = [...document.querySelectorAll($stopSel)].find(e => e.offsetParent !== null && !e.disabled);
  if (!b) return false;
  b.click(); return true;
})()
"@
    } catch { }
    Write-CCBLog verbose bridge "Stop pressed in Copilot: $clicked"
    $deadline = (Get-Date).AddSeconds($DrainSec)
    $nextPage = (Get-Date).AddMilliseconds(500)
    while ((Get-Date) -lt $deadline) {
        $m = Receive-CdpEvent $Bridge.Session 250
        if ($m -and $m.method -eq 'Network.webSocketFrameReceived') {
            foreach ($rec in Read-HubRecords $m.params.response.payloadData) {
                if ($rec.type -eq 2 -or $rec.type -eq 3 -or $rec.type -eq 7) { Write-CCBLog verbose bridge 'Cancelled reply drained'; return 'stopped' }
            }
        }
        if ((Get-Date) -gt $nextPage) {
            $nextPage = (Get-Date).AddMilliseconds(500)
            $st = Get-PageReplyState $Bridge
            if ($st -and -not $st.stop) {
                # Give a last end record a moment to arrive, then stop waiting.
                $until = (Get-Date).AddMilliseconds(700)
                while ((Get-Date) -lt $until) { $null = Receive-CdpEvent $Bridge.Session 100 }
                Write-CCBLog verbose bridge 'Copilot shows it has stopped'
                return 'stopped'
            }
        }
    }
    Write-CCBLog verbose bridge 'Cancelled reply did not end within the drain time'
    'stopped'
}

function Disconnect-Copilot {
    param([Parameter(Mandatory)]$Bridge)
    Disconnect-Cdp $Bridge.Session
}

Export-ModuleMember -Function Set-CopilotResponseMode, Test-CopilotPage, Wait-CopilotSignIn, Get-CopilotTarget, Test-CopilotUrl, Get-ReplyTimelineSummary, New-StreamState, Add-StreamRecord, New-ReplyTimeline, Connect-Copilot, New-CopilotChat, Send-CopilotPrompt, Set-CopilotWorkIq, Disconnect-Copilot, Read-HubRecords, Get-BotReplyText, Get-ReplyFromFrames
