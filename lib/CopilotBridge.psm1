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
    $null = Start-CdpEdge -Port $Port -Url $sel.chatUrl
    $target = Get-CdpPageTarget -Port $Port -UrlLike '*m365.cloud.microsoft*'
    $session = Connect-Cdp $target.webSocketDebuggerUrl
    $bridge = [pscustomobject]@{ Session = $session; Selectors = $sel; Port = $Port; HubSockets = @{}; SaveFrames = $SaveReplyFrames }

    if ($target.url -notlike '*m365.cloud.microsoft*') {
        $null = Invoke-Cdp $session 'Page.navigate' @{ url = $sel.chatUrl }
    }
    $null = Invoke-Cdp $session 'Network.enable'
    Write-CCBLog verbose bridge "Attached to page target" @{ url = ($target.url -replace '\?.*', ''); port = $Port }
    if (-not (Wait-CopilotEditor $bridge -TimeoutSec 20)) {
        Write-Host "Sign in to Copilot in the Edge window that just opened (waiting up to $SignInTimeoutSec s)..."
        Write-CCBLog info bridge "Message box not found; waiting for sign-in (up to $SignInTimeoutSec s)"
        if (-not (Wait-CopilotEditor $bridge -TimeoutSec $SignInTimeoutSec)) { Write-CCBLog info bridge 'Message box never appeared (not signed in, or the page changed: check selectors.editor)'; throw 'Copilot message box never appeared; not signed in?' }
    }
    Write-CCBLog info bridge 'Connected to Copilot Chat'
    $bridge
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
        try { if (Invoke-CdpEval $Bridge.Session $js) { return $true } } catch { }
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
        SentMatches    = (($userMsg.text -replace '\s', '') -eq ($SentPrompt -replace '\s', ''))
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
    if (-not (Test-CCBLog verbose)) { return }
    $types = @($Item.messages | ForEach-Object { "$($_.author):$($_.messageType)" } | Select-Object -Unique)
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
        [scriptblock]$CancelCheck   # returns $true to stop now: Copilot's Stop is pressed and Cancelled = $true is returned
    )
    Use-CopilotLock { Send-CopilotPromptUnlocked -Bridge $Bridge -Text $Text -TimeoutSec $TimeoutSec -OnProgress $OnProgress -CancelCheck $CancelCheck }
}

function Send-CopilotPromptUnlocked {
    param(
        [Parameter(Mandatory)]$Bridge,
        [Parameter(Mandatory)][string]$Text,
        [int]$TimeoutSec = 300,
        [scriptblock]$OnProgress,
        [scriptblock]$CancelCheck
    )
    $s = $Bridge.Session
    while ($s.Events.Count) { $null = $s.Events.Dequeue() }   # drop stale events
    $sendWatch = [Diagnostics.Stopwatch]::StartNew()
    Write-CCBLog trace bridge 'Prompt text' @{ text = $Text }

    Set-CopilotInput $Bridge $Text
    Invoke-CopilotSend $Bridge

    $hubPattern = [regex]::Escape($Bridge.Selectors.chatHubUrlPattern)
    $merger = New-ReplyMerger
    $frames = New-Object System.Collections.Generic.List[string]   # kept for diagnosis
    $reported = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($CancelCheck -and (& $CancelCheck)) {
            Stop-CopilotReply $Bridge
            Write-CCBLog info bridge 'Reply cancelled by the user' @{ partialChars = $merger.Text.Length; ms = $sendWatch.ElapsedMilliseconds }
            return [pscustomobject]@{ Cancelled = $true; Text = $merger.Text; ServerText = $null; Uncertain = $merger.Uncertain; Result = 'Cancelled'
                ResultMessage = 'Stopped by the user'; SentMatches = $true; References = @(); ProposedActions = @(); ActionClaims = @() }
        }
        $m = Receive-CdpEvent $s 400
        if (-not $m) { continue }
        if ($m.method -eq 'Network.webSocketCreated') {
            if ($m.params.url -match $hubPattern) { $Bridge.HubSockets[$m.params.requestId] = $true }
            continue
        }
        if ($m.method -ne 'Network.webSocketFrameReceived') { continue }
        # Frames from a socket opened before Network.enable have no webSocketCreated; accept them
        # when they look like Chathub traffic.
        $payload = $m.params.response.payloadData
        if (-not $Bridge.HubSockets.ContainsKey($m.params.requestId)) {
            if ($payload -notmatch '"target":"update"|"invocationId"') { continue }
            $Bridge.HubSockets[$m.params.requestId] = $true
        }
        $frames.Add($payload)
        foreach ($rec in Read-HubRecords $payload) {
            $item = Add-HubRecord $merger $rec
            if ($item) {
                if ($Bridge.SaveFrames) { Save-ReplyFrames $frames }
                $reply = Complete-Reply $merger $item $Text
                Write-ReplyLog $reply $item $frames $sendWatch.ElapsedMilliseconds
                return $reply
            }
        }
        if ($OnProgress -and $merger.Text.Length -ne $reported) {
            $reported = $merger.Text.Length
            & $OnProgress $merger.Text
        }
    }
    Write-CCBLog info bridge "No complete reply within $TimeoutSec s" @{ partialChars = $merger.Text.Length; frames = $frames.Count }
    if ($Bridge.SaveFrames -and $frames.Count) { Save-ReplyFrames $frames }
    Stop-CopilotReply $Bridge
    throw "No complete reply within $TimeoutSec s (partial: $($merger.Text.Length) chars)"
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

Export-ModuleMember -Function Connect-Copilot, New-CopilotChat, Send-CopilotPrompt, Set-CopilotWorkIq, Disconnect-Copilot, Read-HubRecords, Get-BotReplyText, Get-ReplyFromFrames