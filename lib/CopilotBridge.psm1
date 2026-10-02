# Drives M365 Copilot Chat in Edge: types a prompt into the page and reads the
# reply from the Chathub SignalR WebSocket, which carries the raw markdown.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Cdp.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:RecordSeparator = [char]0x1e
$script:ModuleDir = $PSScriptRoot

function ConvertTo-JsString([string]$s) { $s | ConvertTo-Json -Compress }

function Connect-Copilot {
    <# Starts (or reuses) Edge on the Copilot page and returns a bridge object. #>
    param(
        [int]$Port = 9333,
        [string]$SelectorsPath,
        [int]$SignInTimeoutSec = 300,
        [bool]$SaveReplyFrames = $true
    )
    $sel = if ($SelectorsPath) { Get-Content $SelectorsPath -Raw | ConvertFrom-Json } else { Get-CCBridgeConfig selectors (Split-Path -Parent $script:ModuleDir) }
    # The Copilot tab is recognised by the host of chatUrl (selectors.json), the one place to change the address.
    $hostLike = '*' + ([uri]$sel.chatUrl).Host + '*'
    $deadline = (Get-Date).AddSeconds($SignInTimeoutSec + 30)
    $signInAnnounced = $false
    for ($attempt = 1; ; $attempt++) {
        $session = $null
        try {
            # Edge may still be starting, or may replace the tab (first start, sign-in redirects):
            # every attempt looks for the current Copilot tab again.
            $null = Start-CdpEdge -Port $Port -Url $sel.chatUrl
            $target = Get-CdpPageTarget -Port $Port -UrlLike $hostLike
            $session = Connect-Cdp $target.webSocketDebuggerUrl
            $bridge = [pscustomobject]@{ Session = $session; Selectors = $sel; Port = $Port; HubSockets = @{}; SaveFrames = $SaveReplyFrames }
            if ($target.url -notlike $hostLike) { $null = Invoke-Cdp $session 'Page.navigate' @{ url = $sel.chatUrl } }
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

# The web app and the MCP server may run at the same time and drive the same Copilot tab;
# this machine-wide lock lets only one of them type and wait for a reply at a time.
function Use-CopilotLock([scriptblock]$Body) {
    $mutex = New-Object Threading.Mutex($false, 'Local\CCBridgeCopilot')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne([TimeSpan]::FromMinutes(15)) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Copilot is busy with another CCBridge task (waited 15 minutes).' }
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
    param([Parameter(Mandatory)]$Bridge)
    $null = Invoke-Cdp $Bridge.Session 'Page.navigate' @{ url = $Bridge.Selectors.chatUrl }
    Start-Sleep -Milliseconds 500
    if (-not (Wait-CopilotEditor $Bridge -TimeoutSec 30)) { throw 'Copilot message box did not appear after starting a new chat' }
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
    $null = Invoke-CdpEval $s "(() => { const e = document.querySelector($editorSel); if (!e) throw new Error('message box not found'); e.focus(); return true; })()"
    for ($try = 0; $try -lt 3 -and (Get-CopilotInputLength $Bridge) -gt 0; $try++) {
        Send-CdpKey $s 'a' 'KeyA' 65 2 @('selectAll')   # modifiers 2 = Ctrl
        Send-CdpKey $s 'Backspace' 'Backspace' 8
        Start-Sleep -Milliseconds 150
    }
    if ((Get-CopilotInputLength $Bridge) -gt 0) { Write-CCBLog info bridge 'Could not clear the message box' @{ chars = (Get-CopilotInputLength $Bridge) }; throw 'could not clear the Copilot message box' }

    $null = Invoke-Cdp $s 'Input.insertText' @{ text = $Text }
    $expected = $Text.Replace("`r", '').Replace("`n", '').Length
    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 200
        $actual = Get-CopilotInputLength $Bridge
    } while ($actual -lt $expected -and (Get-Date) -lt $deadline)
    if ($actual -ne $expected) { Write-CCBLog info bridge 'Message box content does not match the prompt' @{ expected = $expected; actual = $actual }; throw "message box holds $actual characters, expected $expected" }
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
    Use-CopilotLock { Send-CopilotPromptUnlocked -Bridge $Bridge -Text $Text -TimeoutSec $TimeoutSec -OnProgress $OnProgress -CancelCheck $CancelCheck -StallSec $StallSec }
}

function Send-CopilotPromptUnlocked {
    param(
        [Parameter(Mandatory)]$Bridge,
        [Parameter(Mandatory)][string]$Text,
        [int]$TimeoutSec = 300,
        [scriptblock]$OnProgress,
        [scriptblock]$CancelCheck,
        [int]$StallSec = 90
    )
    $s = $Bridge.Session
    while ($s.Events.Count) { $null = $s.Events.Dequeue() }   # drop stale events
    $sendWatch = [Diagnostics.Stopwatch]::StartNew()
    Write-CCBLog trace bridge 'Prompt text' @{ text = $Text }

    # The page itself is watched too: if the reply does not arrive over the Chathub socket (other
    # tenants may deliver it differently), it is read from the page once Copilot has finished.
    $pageBefore = Get-PageReplyState $Bridge
    Add-TimelineEvent $Bridge 'typing' $null
    Set-CopilotInput $Bridge $Text
    Invoke-CopilotSend $Bridge
    Add-TimelineEvent $Bridge 'sent' $null
    $net = New-NetTrace
    # How often the page is checked, and how long it must look finished before it counts.
    $pageEveryMs = if ($Bridge.PSObject.Properties['PageCheckMs'] -and $Bridge.PageCheckMs) { [int]$Bridge.PageCheckMs } else { 500 }
    $pageStableSec = if ($Bridge.PSObject.Properties['PageStableSec'] -and $null -ne $Bridge.PageStableSec) { [double]$Bridge.PageStableSec } else { 1.0 }
    $nextPageCheck = (Get-Date).AddSeconds(2)
    $pageDoneSince = $null; $pageLastLen = -1; $sawStop = $false

    $hubPattern = [regex]::Escape($Bridge.Selectors.chatHubUrlPattern)
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
            Stop-CopilotReply $Bridge
            Write-CCBLog info bridge 'Reply cancelled by the user' @{ partialChars = $merger.Text.Length; ms = $sendWatch.ElapsedMilliseconds }
            return [pscustomobject]@{ Cancelled = $true; Text = $merger.Text; ServerText = $null; Uncertain = $merger.Uncertain; Result = 'Cancelled'
                ResultMessage = 'Stopped by the user'; SentMatches = $true; References = @(); ProposedActions = @(); ActionClaims = @() }
        }
        $m = Receive-CdpEvent $s 400
        if ($m) { Add-NetTrace $net $Bridge $m; Add-TimelineNet $Bridge $m }
        if ($pageBefore -and (Get-Date) -gt $nextPageCheck) {
            $nextPageCheck = (Get-Date).AddMilliseconds($pageEveryMs)
            $st = Get-PageReplyState $Bridge
            if ($st -and (Test-Timeline $Bridge)) {
                # Record each change of what the page shows.
                $sig = "stop=$($st.stop) replies=$($st.replies) copies=$($st.copies) len=$($st.lastLen) stateLen=$($st.stateLen) flags=$(($st.flags | ConvertTo-Json -Compress))"
                if ($sig -ne $Bridge.Timeline.LastPage) { $Bridge.Timeline.LastPage = $sig; Add-TimelineEvent $Bridge 'page' $sig $(if ($st.now) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$st.now).LocalDateTime } else { $null }) }
            }
            if ($st) {
                if ($st.stop) { $sawStop = $true; $lastActivity = Get-Date }
                if ($st.lastLen -ne $pageLastLen) { if ($pageLastLen -ge 0) { $lastActivity = Get-Date }; $pageLastLen = $st.lastLen; $pageDoneSince = $null }
                $finished = -not $st.stop -and $st.replies -gt $pageBefore.replies -and $st.copies -gt $pageBefore.copies -and $st.lastLen -gt 0 -and
                    ($sawStop -or $sendWatch.Elapsed.TotalSeconds -ge 6)
                if (-not $finished) { $pageDoneSince = $null }
                elseif (-not $pageDoneSince) { $pageDoneSince = Get-Date }
                elseif (((Get-Date) - $pageDoneSince).TotalSeconds -ge $pageStableSec) {
                    # Finished on the page and stable, and no completion came over the socket.
                    $pt = Get-PageReplyText $Bridge
                    $ptext = "$($pt.text)"
                    if ($ptext.Trim() -and ($ptext -replace '\s', '') -ne ($Text -replace '\s', '')) {
                        Write-CCBLog info bridge "Reply read from the page ($($pt.how)); no completion arrived over the Chathub socket" @{ chars = $ptext.Length; hubChars = $merger.Text.Length; frames = $frames.Count; invocation = $myInvocation; ms = $sendWatch.ElapsedMilliseconds }
                        Write-NetTrace $net 'reply read from the page'
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
        $quiet = ((Get-Date) - $lastActivity).TotalSeconds
        if ((Get-Date) -gt $nextStallCheck -and $quiet -ge 30) {
            $nextStallCheck = (Get-Date).AddSeconds(10)
            $gaveUp = Test-CopilotGaveUp $Bridge
            $hangs = -not $gaveUp -and $StallSec -gt 0 -and $quiet -ge $StallSec
            if ($hangs) { Stop-CopilotReply $Bridge -DrainSec 5 }
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
            if ($m.params.url -match $hubPattern) { $Bridge.HubSockets[$m.params.requestId] = $true }
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
        # Frames from a socket opened before Network.enable have no webSocketCreated; accept them
        # when they look like Chathub traffic.
        $payload = $m.params.response.payloadData
        if (-not $Bridge.HubSockets.ContainsKey($m.params.requestId)) {
            if ($payload -notmatch '"target":"update"|"invocationId"') { continue }
            $Bridge.HubSockets[$m.params.requestId] = $true
        }
        $frames.Add($payload)
        if ($frames.Count -eq 1) { Add-TimelineEvent $Bridge 'first Chathub frame' $null $(if (Test-Timeline $Bridge) { Get-BrowserTime $Bridge.Timeline $m }) }
        $lastActivity = Get-Date
        foreach ($rec in Read-HubRecords $payload) {
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
    Stop-CopilotReply $Bridge
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
    $js = @"
(() => {
  const vis = e => e && e.offsetParent !== null;
  const replies = [...document.querySelectorAll($reply)];
  const last = replies[replies.length - 1];
  const out = {
    replies: replies.length,
    copies: [...document.querySelectorAll($copy)].filter(vis).length,
    stop: [...document.querySelectorAll($stop)].some(vis),
    lastLen: last ? (last.innerText || '').length : 0,
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

function Get-PageReplyText {
    <# Text of the last reply from the page. First the raw markdown the page keeps in its React state
       (exact, code intact); otherwise the reply's visible text (formatting lost, marked uncertain). #>
    param([Parameter(Mandatory)]$Bridge)
    $reply = ConvertTo-JsString (Get-SelectorOrDefault $Bridge 'replyContainer' "[data-testid='copilot-message-reply-div']")
    $js = @"
(() => {
  const replies = [...document.querySelectorAll($reply)];
  const last = replies[replies.length - 1];
  if (!last) return JSON.stringify({ how: 'none', text: '' });
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
  let e = last.querySelector('[data-testid="markdown-reply"]') || last;
  for (let i = 0; i < 8 && e; i++, e = e.parentElement) {
    const fk = Object.keys(e).find(k => k.startsWith('__reactFiber$'));
    if (!fk) continue;
    let f = e[fk];
    for (let j = 0; j < 30 && f; j++, f = f.return) {
      let t = null; try { t = pick(f.memoizedProps); } catch (x) { }
      if (t) return JSON.stringify({ how: 'state', text: t });
    }
  }
  const md = last.querySelector('[data-testid="markdown-reply"]') || last;
  return JSON.stringify({ how: 'page', text: md.innerText || '' });
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
    <# Presses Copilot's Stop button, then reads the socket until the cancelled reply has ended,
       so its late completion record cannot be taken for the answer to the next prompt. #>
    param([Parameter(Mandatory)]$Bridge, [int]$DrainSec = 15)
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
    while ((Get-Date) -lt $deadline) {
        $m = Receive-CdpEvent $Bridge.Session 400
        if (-not $m -or $m.method -ne 'Network.webSocketFrameReceived') { continue }
        foreach ($rec in Read-HubRecords $m.params.response.payloadData) {
            if ($rec.type -eq 2 -or $rec.type -eq 3 -or $rec.type -eq 7) { Write-CCBLog verbose bridge 'Cancelled reply drained'; return }
        }
    }
    Write-CCBLog verbose bridge 'Cancelled reply did not end within the drain time'
}

function Disconnect-Copilot {
    param([Parameter(Mandatory)]$Bridge)
    Disconnect-Cdp $Bridge.Session
}

Export-ModuleMember -Function New-ReplyTimeline, Connect-Copilot, New-CopilotChat, Send-CopilotPrompt, Set-CopilotWorkIq, Disconnect-Copilot, Read-HubRecords, Get-BotReplyText, Get-ReplyFromFrames