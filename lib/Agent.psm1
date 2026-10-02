# The agent loop. Runs in a background runspace and talks to the web server only through
# the synchronized $State hashtable (events out, tasks and approval decisions in).

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Cdp', 'CopilotBridge', 'Workspace', 'Protocol', 'Executor', 'Prompts', 'Fetch') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

function New-AgentState {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$AppRoot)
    [hashtable]::Synchronized(@{
        Config = $Config; AppRoot = $AppRoot
        Events = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Seq = 0
        Tasks = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Approvals = [hashtable]::Synchronized(@{})
        Mode = 'ask'; ProjectRoot = $null; Busy = $false; Cancel = $false; Stop = $false
        Progress = ''; Copilot = 'idle'; CopilotMessage = ''
        Throttle = @{ used = 0; max = 0 }; Credits = $null; Todos = @(); ChatStarted = $false; NeedNewChat = $true; Summary = $null
        # Headless (MCP): no person approves; 'auto' mode applies changes, commands only when AllowCommands.
        Headless = $false; AllowCommands = $false; Jobs = [hashtable]::Synchronized(@{})
        LogLevel = $null   # set by the front end; the worker applies changes on the fly
        ChatKind = $null   # kind of task the current chat is about (chat, assistant, project, coding, mixed)
        SentParts = (New-Object 'System.Collections.Generic.HashSet[string]')   # prompt parts this chat already has
        PreviewToken = [guid]::NewGuid().ToString('N'); PreviewPort = 0   # page check: project served read-only at /preview/<token>/
        NextConnectAttempt = $null
        # Work IQ (Microsoft 365 data in Copilot): 'on', 'off' or 'leave' (do not touch the toggle).
        WorkIq = $(if ($Config.workIq) { [string]$Config.workIq } else { 'leave' }); WorkIqActual = $null; WorkIqWarned = $false
    })
}

# The web app and the MCP server can both drive the same Copilot tab. Whoever sent last is
# recorded here; a process that finds another sender starts a fresh chat instead of
# continuing someone else's conversation.
$script:LastSenderFile = Join-Path $env:LOCALAPPDATA 'CCBridge\last-sender.txt'

function Test-OtherSender {
    try { $p = [IO.File]::ReadAllText($script:LastSenderFile).Trim(); [bool]($p -and $p -ne "$PID") } catch { $false }
}

function Set-LastSender {
    try { [IO.File]::WriteAllText($script:LastSenderFile, "$PID") } catch { }
}

function Add-AgentEvent {
    param($State, [string]$Type, [hashtable]$Data = @{})
    [Threading.Monitor]::Enter($State.Events.SyncRoot)
    try {
        $State.Seq++
        $Data.seq = $State.Seq; $Data.type = $Type; $Data.time = (Get-Date).ToString('HH:mm:ss')
        if ($Type -eq 'error') {
            # For investigation: an id that is also in the log, a category, a hint and the technical detail.
            $rec = $Data.record; [void]$Data.Remove('record')
            if (-not $Data.text -and $rec) { $Data.text = "$($rec.Exception.Message)" }
            $help = Get-CCBErrorHelp "$($Data.text)"
            if (-not $Data.code) { $Data.code = $help.code }
            if (-not $Data.hint) { $Data.hint = $help.hint }
            $Data.errId = New-CCBErrorId
            if ($rec) { $Data.detail = Get-CCBErrorDetail $rec }
            $Data.version = "$($State.Version)"
        }
        # The UI renders these as text; whatever Copilot returned, send strings (or nothing).
        foreach ($k in 'text', 'target', 'summary', 'output', 'error', 'warning', 'status', 'action', 'id') {
            if ($Data.ContainsKey($k) -and $null -ne $Data[$k] -and $Data[$k] -isnot [string]) {
                $Data[$k] = if ($Data[$k] -is [ValueType]) { [string]$Data[$k] } else { ConvertTo-Json -InputObject $Data[$k] -Depth 5 -Compress }
            }
        }
        if ($Data.ContainsKey('references')) {
            $Data.references = @(@($Data.references) | Where-Object { $_ } | ForEach-Object {
                @{ title = $(if ($null -ne $_.title) { [string]$_.title }); url = $(if ($null -ne $_.url) { [string]$_.url }); kind = $(if ($null -ne $_.kind) { [string]$_.kind }) }
            })
        }
        [void]$State.Events.Add($Data)
        switch ($Type) {
            'error'          { Write-CCBLog info agent "ERROR $($Data.errId) [$($Data.code)] $($Data.text)" @{ hint = $Data.hint; detail = $Data.detail } }
            'human-required' { Write-CCBLog info agent "HUMAN REQUIRED: $($Data.text)" }
            'status'         { Write-CCBLog verbose agent "status: $($Data.text)" }
            'action'         {
                $lvl = if ($Data.status -eq 'failed') { 'info' } else { 'verbose' }
                Write-CCBLog $lvl agent "action $($Data.id) $($Data.action) -> $($Data.status)" @{ target = $Data.target; error = $Data.error }
            }
            'action-result'  {
                if ($Data.ok -eq $false -and $Data.status -ne 'rejected') {
                    # Failed actions are always logged, with the reason Copilot was given.
                    Write-CCBLog info agent "action failed $($Data.id) [$($Data.code)]: $($Data.summary)" @{ reasons = $Data.reasons; output = $(if ($Data.output) { "$($Data.output)".Substring(0, [Math]::Min(1200, "$($Data.output)".Length)) }) }
                } else { Write-CCBLog verbose agent "result $($Data.id) $($Data.status)" @{ summary = $Data.summary } }
            }
            'checkpoint'     { Write-CCBLog verbose agent "change set saved" @{ files = $Data.files } }
            'undo'           { Write-CCBLog info agent "undo: $($Data.text)" }
            'fetch'          { Write-CCBLog info agent "fetched $($Data.name) -> $($Data.path)" }
        }
        # Keep memory bounded; the UI only needs recent history after a reload.
        if ($State.Events.Count -gt 2000) { $State.Events.RemoveRange(0, 500) }
    } finally { [Threading.Monitor]::Exit($State.Events.SyncRoot) }
}

function Get-AgentEvents {
    param($State, [int]$After)
    [Threading.Monitor]::Enter($State.Events.SyncRoot)
    try { @($State.Events | Where-Object { $_.seq -gt $After }) }
    finally { [Threading.Monitor]::Exit($State.Events.SyncRoot) }
}

# --- Copilot connection --------------------------------------------------------------

$script:Bridge = $null

function Get-Bridge($State) {
    if ($script:Bridge) {
        $ws = $script:Bridge.Session.Ws
        if (-not $script:Bridge.Session.Lost -and $ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            # Pacing changed in the settings applies to the next prompt.
            if ($State.Config.pacing -and $script:Bridge.PSObject.Properties['Pacing']) {
                foreach ($k in 'newChatSettleSec', 'beforeSendSec', 'betweenPromptsSec') { if ($null -ne $State.Config.pacing.$k) { $script:Bridge.Pacing[$k] = [double]$State.Config.pacing.$k } }
            }
            return $script:Bridge
        }
        Write-CCBLog info agent 'The connection to the Copilot tab was lost; reconnecting'
        Reset-Bridge $State
    }
    $State.Copilot = 'connecting'
    $State.CopilotMessage = 'Opening Copilot in Edge. Sign in there if asked.'
    try {
        $save = if ($null -ne $State.Config.saveReplyFrames) { [bool]$State.Config.saveReplyFrames } else { $true }
        $script:Bridge = Connect-Copilot -Port $State.Config.cdpPort -SaveReplyFrames $save
        $State.Copilot = 'ready'; $State.CopilotMessage = ''
        # Page health check: the parts CCBridge relies on are where selectors.json says.
        try {
            $health = @(Test-CopilotPage $script:Bridge)
            $bad = @($health | Where-Object { $_.ok -eq $false })
            Write-CCBLog $(if ($bad.Count) { 'info' } else { 'verbose' }) agent "Copilot page check: $(if ($bad.Count) { "$($bad.Count) problem(s)" } else { 'all parts found' })" @{ parts = @($health | ForEach-Object { "$($_.part)=$(if ($null -eq $_.ok) { 'unchecked' } elseif ($_.ok) { 'ok' } else { 'missing' })" }) }
            if ($bad.Count) {
                $what = ($bad | ForEach-Object { "$($_.part) (selectors.$($_.setting): $($_.note))" }) -join '; '
                $State.CopilotMessage = "Page check: $what"
                Add-AgentEvent $State 'status' @{ text = "Copilot page check: $what. Copilot's page may have changed; StreamHub may not be able to $(if (@($bad | Where-Object needed).Count) { 'type or send prompts' } else { 'start new chats or read replies reliably' }). Run capture.cmd and send the report to update the selectors." }
            }
        } catch { Write-CCBLogError agent 'Copilot page check failed' $_ }
        $script:Bridge
    } catch {
        $State.Copilot = 'error'; $State.CopilotMessage = $_.Exception.Message
        $State.NextConnectAttempt = (Get-Date).AddSeconds(30)   # the idle worker retries, so Copilot is ready before the first prompt
        throw
    }
}

function Reset-Bridge($State) {
    if ($script:Bridge) { try { Disconnect-Copilot $script:Bridge } catch { } }
    $script:Bridge = $null
    $State.Copilot = 'idle'
}

function Send-ToCopilot {
    param($State, [string]$Message)
    $bridge = Get-Bridge $State
    if ($State.WorkIq -eq 'on' -or $State.WorkIq -eq 'off') {
        $State.WorkIqActual = Set-CopilotWorkIq $bridge ($State.WorkIq -eq 'on')
        if ($State.WorkIqActual -eq 'unavailable' -and -not $State.WorkIqWarned) {
            $State.WorkIqWarned = $true
            Add-AgentEvent $State 'status' @{ text = "Work IQ could not be switched $($State.WorkIq): the toggle is not configured or not on the page (run capture.cmd on a Microsoft 365 Copilot licence). Copilot uses its current setting." }
        }
    }
    $progress = { param($t) $State.Progress = $t }.GetNewClosure()
    $cancel = { [bool]$State.Cancel }.GetNewClosure()
    try {
        $stall = if ($State.Config.PSObject.Properties['stallSec']) { [int]$State.Config.stallSec } else { 90 }
        $r = $null
        try {
            $r = Send-CopilotPrompt $bridge $Message -TimeoutSec $State.Config.replyTimeoutSec -OnProgress $progress -CancelCheck $cancel -StallSec $stall
        } catch {
            if (-not (Test-ConnectionLost $_) -or $State.ChatStarted) { throw }
            # First message of a chat: reconnect, start a fresh chat and send it once more.
            Write-CCBLog info agent 'Connection lost while sending the first message of a chat; reconnecting and sending again' @{ error = $_.Exception.Message }
            Add-AgentEvent $State 'status' @{ text = 'The connection to Copilot was lost; reconnecting and sending again.' }
            Reset-Bridge $State
            Start-NewChat $State
            $bridge = Get-Bridge $State
            $r = Send-CopilotPrompt $bridge $Message -TimeoutSec $State.Config.replyTimeoutSec -OnProgress $progress -CancelCheck $cancel -StallSec $stall
        }
    } catch {
        if (Test-ConnectionLost $_) {
            # Later in a chat the conversation cannot be resumed: the next message starts a new chat.
            $State.NeedNewChat = $true
            Reset-Bridge $State
            throw "The connection to the Copilot tab was lost ($($_.Exception.Message)). StreamHub reconnects; send your message again (it starts a new Copilot chat)."
        }
        Reset-Bridge $State   # the next send reconnects
        throw
    } finally { $State.Progress = '' }
    if ($r.Throttling -and $r.Throttling.maxNumUserMessagesInConversation) {
        $State.Throttle = @{ used = [int]$r.Throttling.numUserMessagesInConversation; max = [int]$r.Throttling.maxNumUserMessagesInConversation }
    } elseif (-not $r.Cancelled) {
        # The reply came without Copilot's own count (read from the page): count locally, against
        # messagesPerChat, so the chat is still continued in a new one before Copilot's limit.
        $max = if ($State.Throttle.max) { [int]$State.Throttle.max } elseif ($State.Config.messagesPerChat) { [int]$State.Config.messagesPerChat } else { 30 }
        $State.Throttle = @{ used = [int]$State.Throttle.used + 1; max = $max }
    }
    if ($r.Metering -and $null -ne $r.Metering.remainingAllowance) {
        $State.Credits = @{ remaining = [int]$r.Metering.remainingAllowance; total = [int]$r.Metering.totalAllowance; resetAt = [string]$r.Metering.resetAt }
    }
    $State.ChatStarted = $true
    Set-LastSender
    $r
}

function Test-ConnectionLost($ErrorRecord) {
    "$($ErrorRecord.Exception.Message)" -match 'Lost the connection to the Copilot tab|Could not connect to the Copilot tab'
}

function Invoke-FetchJob {
    <# Runs a saved fetch prompt in a fresh Copilot chat and writes the answer to fetch/<name>.md.
       Copilot only answers: action blocks in the answer are not carried out. An existing answer
       file is kept when the fetch fails. #>
    param($State, [string]$Name)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; return }
    $item = Get-FetchPrompts $State.ProjectRoot | Where-Object name -eq $Name | Select-Object -First 1
    if (-not $item) { Add-AgentEvent $State 'error' @{ text = "There is no fetch prompt named '$Name'." }; return }
    $State.Busy = $true; $State.Cancel = $false
    try {
        Add-AgentEvent $State 'status' @{ text = "Fetching '$Name' from Copilot..." }
        Write-CCBLog info agent "Fetch $Name" @{ promptChars = $item.prompt.Length }
        Start-NewChat $State   # a fetch never mixes with the conversation
        $tk = Get-TaskKind $item.prompt
        $kind = if ($tk -eq 'assistant' -or $tk -eq 'mixed') { 'fetch-m365' } else { 'fetch' }
        $sent = New-Object 'System.Collections.Generic.HashSet[string]'
        $message = New-PromptMessage -AppRoot $State.AppRoot -Kind $kind -Text $item.prompt -Sent $sent
        $r = Send-ToCopilot $State $message
        if ($r.Cancelled) { Add-AgentEvent $State 'status' @{ text = "Fetch '$Name' stopped; $($item.output) was left unchanged." }; return }
        if (($r.Result -and $r.Result -ne 'Success') -or -not "$($r.Text)".Trim()) {
            Add-AgentEvent $State 'error' @{ text = "Fetch '$Name' got no usable answer ($($r.Result): $($r.ResultMessage)); $($item.output) was left unchanged." }
            return
        }
        $content = Format-FetchResult -Name $Name -Reply $r.Text -References @($r.References)
        $path = Save-FetchResult $State.ProjectRoot $Name $content
        Add-AgentEvent $State 'fetch' @{ name = $Name; path = $path; text = "Saved the answer to $path. Attach it with @$path." }
    } catch {
        Write-CCBLogError agent "Fetch $Name failed" $_
        Add-AgentEvent $State 'error' @{ text = "Fetch '$Name' failed: $($_.Exception.Message)"; record = $_ }
    } finally {
        $State.NeedNewChat = $true   # the next message starts its own chat
        $State.Busy = $false; $State.Cancel = $false
    }
}

function Get-TurnKind {
    <# The kind of task for this message, with the follow-up rules of a work chat. CCBridge has no
       language model of its own, so these are fixed rules, not an understanding of the request:
       - a follow-up that reads like plain chat ("do it", "and the other page too") continues the
         chat's task and gets its instructions instead of a bare pass-through;
       - the full instructions are sent again when the previous turn ended without any action
         (Copilot drifted into explaining) or after every 5 follow-ups;
       - other follow-ups get the short recap (prompts/reminder.md, added by New-PromptMessage). #>
    param($State, [string]$Text)
    $kind = Get-TaskKind $Text
    if ($kind -eq 'chat' -and $State.ChatKind) { $kind = $State.ChatKind }
    if ($kind -in 'coding', 'project', 'mixed' -and $State.SentParts.Contains('actions')) {
        $State.FollowUps = [int]$State.FollowUps + 1
        $why = if ($State.LastTurnActed -eq $false) { 'the previous turn had no actions' } elseif ($State.FollowUps -ge 5) { "$($State.FollowUps) follow-ups since the instructions" } else { $null }
        if ($why) {
            Write-CCBLog info agent "Sending the full instructions again ($why)"
            foreach ($p in 'actions', 'rules', 'role:coding', 'role:project') { [void]$State.SentParts.Remove($p) }
        }
    }
    $kind
}

# Phrases of a reply that tells the user how to do the task by hand, or asks for the files
# (English and Dutch). CCBridge has no language model: this is a fixed list, kept in tests.
$script:ManualPhrases = '(?i)\b(open (the|your) file|in your (editor|file)|replace (it|this|the following|that) with|add the following|copy (this|the)|paste (this|it|the)|you (can|could|should|need to|will need to)|you''ll need|save the file|upload (the|your)|provide (the|me|your)|share (the|your) (file|code)|i (can''t|cannot|can not|don''t have) (access|see|read|open|make)|i do not have access|once you (provide|share|upload|paste)|open het bestand|vervang|plak|kopieer|je kunt|upload)\b'

function Test-NeedsActionNudge {
    <# True when a work task (coding / project / mixed) got instructions for doing it by hand instead
       of action blocks: code, a list of steps, or phrases such as "open the file", "replace ... with",
       "you can", "upload the files" or "I can't access". Not in plan mode, and at most $Max times per
       message. #>
    param($State, [string]$Kind, [string]$Text, [int]$Attempts = 0, [int]$Max = 2)
    if ($Attempts -ge $Max -or $State.Mode -eq 'plan') { return $false }
    if ($Kind -notin 'coding', 'project', 'mixed') { return $false }
    $hasCode = $Text -match '(?m)^\s{0,3}(`{3,}|~{3,})'
    $hasSteps = ([regex]::Matches($Text, '(?m)^\s{0,3}(\d+[.)]|[-*])\s+\S')).Count -ge 2
    $hasManual = $Text -match $script:ManualPhrases
    $hasCode -or $hasSteps -or $hasManual
}

function New-ActionRetryMessage {
    <# The task again with the instructions enforced: the full action instructions and rules, a note
       that nothing was changed and the task must be carried out, then the original request. #>
    param($State, [string]$Task)
    $parts = @(
        (Get-PromptPart $State.AppRoot 'actions'),
        (Get-PromptPart $State.AppRoot 'rules'),
        (Get-PromptPart $State.AppRoot 'retry')
    )
    foreach ($p in 'actions', 'rules') { [void]$State.SentParts.Add($p) }
    ($parts -join "`n`n") + "`n`nTask: $Task"
}

function Get-StepFailureInfo {
    <# Why a step (read / grep / edit / write / run) may have failed and what happens next, from the
       action type and the reason it reported. Fixed rules: the usual causes, not a diagnosis. #>
    param([string]$Type, [string]$Reason)
    $copilotRetries = 'Copilot gets this reason in the next message and usually corrects it itself. Nothing else is needed from you; if it keeps failing, use Copy details on the card or start a New chat.'
    $r = "$Reason"
    $info = switch -Regex ($r) {
        'already contains these changes|already applied' { @{ code = 'EDIT-ALREADY-APPLIED'; reasons = @('Copilot sent a change that had already been made earlier in this task.'); next = 'Nothing to do; Copilot is asked to confirm.' }; break }
        'does not contain them yet' { @{ code = 'EDIT-MOVE-ORDER'; reasons = @('Copilot removes code from this file and links another file, but that file does not hold the code yet (missing, or only a placeholder).', 'Copilot sent the edit before (or instead of) writing the new file.'); next = "Nothing was changed, so no code is lost. $copilotRetries" }; break }
        'half open|half closed' { @{ code = 'EDIT-HALF-BLOCK'; reasons = @('Copilot''s SEARCH covered only part of a block (for example the first lines of a <style> or <script> block, or a function without its closing brace).', 'Copilot shortened a long block without a line containing only ... between its first and last lines.'); next = "Nothing was changed. $copilotRetries" }; break }
        'matches \d+ places|matches more than once' { @{ code = 'EDIT-AMBIGUOUS'; reasons = @('The SEARCH text occurs more than once in the file (for example a repeated closing tag or line).', 'Copilot copied too few lines to point at one place.'); next = "Nothing was changed. $copilotRetries" }; break }
        'no SEARCH/REPLACE pairs' { @{ code = 'EDIT-FORMAT'; reasons = @('Copilot''s edit block had no <<<<<<< SEARCH / ======= / >>>>>>> REPLACE markers (or they were not at the start of a line).', 'Copilot meant to replace the whole file; that needs a write block.'); next = "Nothing was changed. $copilotRetries" }; break }
        'SEARCH text not found' { @{ code = 'EDIT-NOT-FOUND'; reasons = @('The file changed since Copilot read it: an earlier edit in this task, or you edited it.', 'Copilot''s SEARCH lines differ slightly from the file: spaces, quotes, or a line it remembered differently.', 'The change was already made earlier, but with different text.', 'Copilot shortened SEARCH without a line containing only ... (only its first lines were given).'); next = "Nothing was changed. Copilot gets the reason plus the file's closest current lines. $copilotRetries" }; break }
        'is in source/|read-only' { @{ code = 'SOURCE-DATA'; reasons = @('The step tried to change a file in source/, which holds your source data and is read-only.'); next = 'Nothing was changed. Copilot is told to write its result elsewhere (for example work/ or output/).' }; break }
        'file not found|\(file not found\)' { @{ code = 'FILE-NOT-FOUND'; reasons = @('The path does not exist in the project: a typo, another folder, or a file that was never created.', 'For a new file Copilot should use a write block, not an edit.'); next = $copilotRetries }; break }
        'without a path' { @{ code = 'STEP-FORMAT'; reasons = @('The block had no file name after the action name (for example ````edit with nothing after it).'); next = $copilotRetries }; break }
        'plan mode' { @{ code = 'PLAN-MODE'; reasons = @('"Plan only" mode is on, so changes and commands are not carried out.'); next = 'Switch the mode to "Ask before changes" or "Auto-accept edits" and ask again to carry out the plan.' }; break }
        'commands are not allowed' { @{ code = 'RUN-NOT-ALLOWED'; reasons = @('Commands are not allowed for this task (MCP task started without permission to run commands).'); next = 'Copilot is told to finish without running commands.' }; break }
        'needs a person|refused' { @{ code = 'RUN-NEEDS-PERSON'; reasons = @('The command would act on Microsoft 365 or delete data; that always needs a person.'); next = 'Run it yourself if you really want it; Copilot is told not to work around it.' }; break }
        'stopped by the user' { @{ code = 'STOPPED'; reasons = @('You pressed Stop.'); next = 'Changes made so far in this message can be undone (Changes > Undo last change set).' }; break }
        'timed out after' { @{ code = 'RUN-TIMEOUT'; reasons = @('The command ran longer than commandTimeoutSec (it may wait for input, or just be slow).'); next = 'Copilot sees the output so far. Raise commandTimeoutSec in config\harness.local.json for slow builds.' }; break }
        'exit code [1-9]|exit code -' { @{ code = 'RUN-FAILED'; reasons = @('The command reported an error (see its output on this card).', 'A tool or module the command needs is not installed on this computer.', 'The command ran in the project folder with cmd.exe; it may have expected another folder or shell.'); next = $copilotRetries }; break }
        'is not valid|invalid' { @{ code = 'STEP-INVALID'; reasons = @('The step''s input was not valid (see the reason above).'); next = $copilotRetries }; break }
        default { @{ code = "$($Type.ToUpperInvariant())-FAILED"; reasons = @('See the reason above; this case has no specific explanation yet.'); next = 'Copilot gets the reason in the next message. If it keeps failing, use Copy details and send them.' }; break }
    }
    $info
}

function Test-WebPage {
    <# Opens project pages in a spare Edge tab (served read-only by the web app at /preview/<token>/)
       and collects what goes wrong while they load: JavaScript errors, console errors, and files
       that fail to load (missing styles.css, a fetch() of a JSON file that is not there). The tab
       is closed afterwards. Returns one line per problem. #>
    param($State, [string[]]$Pages, [int]$WaitSec = 6)
    if (-not $State.PreviewPort) { return }
    $cdpPort = $State.Config.cdpPort
    foreach ($page in @($Pages | Select-Object -First 3)) {
        $base = "http://localhost:$($State.PreviewPort)/preview/$($State.PreviewToken)/"
        $url = $base + (($page.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
        $target = $null; $s = $null
        try {
            $target = Invoke-RestMethod -Method Put "http://127.0.0.1:$cdpPort/json/new?about:blank"
            $s = Connect-Cdp $target.webSocketDebuggerUrl
            foreach ($m in 'Runtime.enable', 'Log.enable', 'Network.enable', 'Page.enable') { $null = Invoke-Cdp $s $m }
            $null = Invoke-Cdp $s 'Page.navigate' @{ url = $url }
            $problems = New-Object System.Collections.Generic.List[string]
            $urls = @{}
            $rel = { param([string]$u) if ($u.StartsWith($base)) { [Uri]::UnescapeDataString($u.Substring($base.Length)) } else { ($u -replace '\?.*$', '') } }
            $loaded = $null
            $until = (Get-Date).AddSeconds($WaitSec)
            while ((Get-Date) -lt $until) {
                $m = Receive-CdpEvent $s 200
                if (-not $m) { if ($loaded -and ((Get-Date) - $loaded).TotalMilliseconds -gt 1500) { break }; continue }
                switch ($m.method) {
                    'Page.loadEventFired' { $loaded = Get-Date }
                    'Network.requestWillBeSent' { $urls["$($m.params.requestId)"] = "$($m.params.request.url)" }
                    'Network.responseReceived' {
                        # The browser asks for /favicon.ico by itself: not a problem of the page.
                        if ([int]$m.params.response.status -ge 400 -and "$($m.params.response.url)" -notmatch '/favicon\.ico(\?|$)') { $problems.Add("$page loads $(& $rel $m.params.response.url): HTTP $($m.params.response.status)$(if ($m.params.response.status -eq 404) { ' (file not found)' })") }
                    }
                    'Network.loadingFailed' {
                        if (-not $m.params.canceled) { $problems.Add("$page could not load $(& $rel $urls["$($m.params.requestId)"]): $($m.params.errorText)") }
                    }
                    'Runtime.exceptionThrown' {
                        $d = $m.params.exceptionDetails
                        $msg = if ($d.exception.description) { ($d.exception.description -split "`n")[0] } else { $d.text }
                        $where = if ($d.url) { " ($(& $rel $d.url):$([int]$d.lineNumber + 1))" } else { '' }
                        $problems.Add("$page JavaScript error$where`: $msg")
                    }
                    'Runtime.consoleAPICalled' {
                        if ($m.params.type -in 'error', 'assert') {
                            $text = (@($m.params.args) | ForEach-Object { if ($null -ne $_.value) { "$($_.value)" } elseif ($_.description) { $_.description } } ) -join ' '
                            $problems.Add("$page console error: $($text.Substring(0, [Math]::Min(300, $text.Length)))")
                        }
                    }
                    'Log.entryAdded' {
                        $en = $m.params.entry
                        if ($en.level -eq 'error' -and $en.source -ne 'network') { $problems.Add("$page browser error: $($en.text)") }
                    }
                }
            }
            if (-not $loaded) { $problems.Add("$page did not finish loading within $WaitSec seconds") }
            foreach ($p in ($problems | Select-Object -Unique -First 20)) { $p }
            Write-CCBLog info agent "Page check $page" @{ problems = $problems.Count }
        } catch {
            Write-CCBLogError agent "Page check $page failed" $_
        } finally {
            if ($s) { try { Disconnect-Cdp $s } catch { } }
            if ($target) { try { $null = Invoke-RestMethod "http://127.0.0.1:$cdpPort/json/close/$($target.id)" } catch { } }
        }
    }
}

function Test-NeedsReview {
    <# Whether a finished task changed enough to ask Copilot for a consistency review: at least
       reviewMinLines changed lines in total, or a file created while another lost 20+ lines (code
       moved out). harness.json reviewAfterChanges: "big" (default), "always" or "off". #>
    param($State, $Changes)
    $setting = if ($State.Config.reviewAfterChanges) { "$($State.Config.reviewAfterChanges)" } else { 'big' }
    $changes = @($Changes | Where-Object { $_.added -or $_.removed })
    if ($setting -eq 'off' -or -not $changes.Count -or $State.Mode -eq 'plan') { return $false }
    if ($setting -eq 'always') { return $true }
    $min = if ($State.Config.reviewMinLines) { [int]$State.Config.reviewMinLines } else { 40 }
    $total = ($changes | ForEach-Object { $_.added + $_.removed } | Measure-Object -Sum).Sum
    $movedOut = @($changes | Where-Object { $_.created -and $_.added -ge 10 }).Count -and @($changes | Where-Object { -not $_.created -and $_.removed -ge 20 }).Count
    ($total -ge $min) -or $movedOut
}

function New-ReviewMessage {
    <# The review request: what changed, the local check results and the current contents. #>
    param($State, $Changes, [string[]]$Issues)
    $list = ($Changes | Where-Object { $_.added -or $_.removed } | ForEach-Object {
        $what = if ($_.deleted) { 'deleted' } elseif ($_.created) { 'new' } else { 'changed' }
        "- $($_.path) ($what, +$($_.added) -$($_.removed) lines)"
    }) -join "`n"
    $checks = if (@($Issues).Count) { "Local checks found:`n" + ((@($Issues) | ForEach-Object { "- $_" }) -join "`n") } else { 'Local checks (JSON and PowerShell syntax, referenced local files exist): no problems found.' }
    $paths = @($Changes | Where-Object { -not $_.deleted -and ($_.added -or $_.removed) } | ForEach-Object { $_.path })
    $perFile = [Math]::Max(4000, [int]($State.Config.resultCharBudget / [Math]::Max(1, $paths.Count)))
    $contents = if ($paths.Count) { (Invoke-ReadAction $State.ProjectRoot $paths -MaxCharsPerFile $perFile) -join "`n`n" } else { '' }
    (Get-PromptPart $State.AppRoot 'review') + "`n`nChanged files:`n$list`n`n$checks`n`n$contents"
}

function Start-NewChat($State) {
    try { New-CopilotChat (Get-Bridge $State) }
    catch {
        if ("$($_.Exception.Message)" -match 'the page shows a sign-in page') {
            # The organisation asks to sign in again (for example multi-factor authentication).
            Add-AgentEvent $State 'status' @{ text = 'Copilot asks you to sign in again. Complete the sign-in in the Copilot window in Edge; StreamHub waits up to 5 minutes.' }
            $State.Copilot = 'connecting'; $State.CopilotMessage = 'Waiting for you to sign in to Copilot in Edge'
            $ok = Wait-CopilotSignIn (Get-Bridge $State) 300
            $State.Copilot = $(if ($ok) { 'ready' } else { 'error' }); $State.CopilotMessage = $(if ($ok) { '' } else { 'Sign-in was not completed' })
            if (-not $ok) { throw 'Copilot sign-in was not completed within 5 minutes. Sign in in the Copilot window in Edge and send your message again.' }
            Add-AgentEvent $State 'status' @{ text = 'Signed in again; continuing.' }
            New-CopilotChat (Get-Bridge $State)
            $State.ChatStarted = $false; $State.ChatKind = $null
            $State.SentParts = New-Object 'System.Collections.Generic.HashSet[string]'
            $State.FollowUps = 0; $State.LastTurnActed = $null; $State.NeedNewChat = $false
            $State.Throttle = @{ used = 0; max = $State.Throttle.max }
            return
        }
        if (-not (Test-ConnectionLost $_)) { throw }
        # Nothing was sent yet: reconnect and try once more.
        Write-CCBLog info agent 'Connection lost while starting a new chat; reconnecting' @{ error = $_.Exception.Message }
        Reset-Bridge $State
        New-CopilotChat (Get-Bridge $State)
    }
    $State.ChatStarted = $false
    $State.ChatKind = $null
    $State.SentParts = New-Object 'System.Collections.Generic.HashSet[string]'
    $State.FollowUps = 0; $State.LastTurnActed = $null
    $State.NeedNewChat = $false
    $State.Throttle = @{ used = 0; max = $State.Throttle.max }
}

# --- Prompt building -----------------------------------------------------------------

function Get-PinnedFiles {
    param([string]$ProjectRoot, [string]$Text)
    # @path or @path:START-END (only those lines)
    $paths = @([regex]::Matches($Text, '(?<![\w@])@([\w.][\w./\\-]*\w)(:\d+(?:-\d*)?)?') |
        Where-Object { try { Test-Path -LiteralPath (Resolve-ProjectPath $ProjectRoot $_.Groups[1].Value) -PathType Leaf } catch { $false } } |
        ForEach-Object { $_.Groups[1].Value + $_.Groups[2].Value } | Select-Object -Unique)
    if (-not $paths.Count) { return '' }
    "`n`n# Attached files`n" + ((Invoke-ReadAction $ProjectRoot $paths) -join "`n`n")
}

function Get-ProjectNotes([string]$ProjectRoot) {
    <# AGENTS.md without its template lines; empty when the user has not filled it in. #>
    $memo = Join-Path $ProjectRoot 'AGENTS.md'
    if (-not (Test-Path $memo)) { return '' }
    $lines = @([IO.File]::ReadAllText($memo).Replace("`r`n", "`n").Split("`n") | Where-Object {
        $_ -notmatch '^(Instructions for coding (agents|assistants)|Project notes for CCBridge|Describe the goal, tech stack)' })
    $meaningful = @($lines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })
    if (-not $meaningful.Count) { return '' }
    ($lines -join "`n").Trim()
}

function Get-ProjectContext($State) {
    <# Location (in OneDrive when possible, so Copilot can open the files there), files and notes. #>
    $root = $State.ProjectRoot
    $loc = Get-OneDriveLocation $root
    $location = if ($loc) {
        "Project folder: $($loc.Display)$(if ($loc.Url) { " ($($loc.Url))" }). It is in the user's OneDrive, so you can open its files there; the read action shows their exact current content."
    } else {
        "Project folder: $(Split-Path $root -Leaf) on the user's computer; use the read action to see its files."
    }
    $budget = [Math]::Max(2000, [int]($State.Config.promptCharBudget * 0.25))
    $files = if (@(Get-ProjectFiles $root).Count) { "Files:`n" + (Format-ProjectTree $root -MaxChars $budget) } else { 'The folder is empty.' }
    $notes = Get-ProjectNotes $root
    $full = "$location`n$files" + $(if ($notes) { "`n`nProject notes (AGENTS.md):`n$notes" } else { '' })
    @{ Location = $location; Full = $full }
}

function Format-ActionResults {
    <# The results message. File contents get the budget first: other results (command output,
       write/edit confirmations) are kept short, the rest is shared by the files read. A file that
       does not fit is read again to fit, cut at a whole line with a note on how to read the rest. #>
    param($State, $Results)
    $budget = [int]$State.Config.resultCharBudget
    $reads = @($Results | Where-Object { $_.readPaths })
    $others = @($Results | Where-Object { -not $_.readPaths })
    $otherText = @{}
    foreach ($r in $others) { $otherText[$r.head] = Limit-Text $r.output 6000 }
    $used = ($otherText.Values | Measure-Object -Property Length -Sum).Sum
    $readBudget = [Math]::Max(4000, $budget - [int]$used)
    $files = [Math]::Max(1, ($reads | ForEach-Object { @($_.readPaths).Count } | Measure-Object -Sum).Sum)
    $perFile = [Math]::Max(1500, [int]($readBudget / $files))
    $parts = foreach ($r in $Results) {
        $out = if ($r.readPaths) {
            if ($r.output.Length -le $perFile * @($r.readPaths).Count) { $r.output }
            else { (Invoke-ReadAction $State.ProjectRoot @($r.readPaths) -MaxCharsPerFile $perFile) -join "`n`n" }
        } else { $otherText[$r.head] }
        "$($r.head)`n$out".TrimEnd()
    }
    $parts -join "`n`n"
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max) + "`n(truncated: $($Text.Length - $Max) more characters)"
}

function Invoke-RolloverIfNeeded($State) {
    $t = $State.Throttle
    if (-not $t.max -or $t.used -lt ($t.max - $State.Config.rolloverMargin)) { return }
    Write-CCBLog info agent "Chat rollover" @{ used = $t.used; max = $t.max }
    Add-AgentEvent $State 'status' @{ text = "This Copilot chat is nearly full ($($t.used)/$($t.max) messages). Summarizing and continuing in a new chat." }
    $r = Send-ToCopilot $State 'Summarize this conversation so it can continue in a fresh chat: the task, decisions made, files created or changed, the current state and the next steps. At most 2500 characters. Do not use action blocks.'
    $State.Summary = Limit-Text $r.Text 4000
    $kind = $State.ChatKind
    Start-NewChat $State
    $State.ChatKind = $kind   # the new chat continues the same kind of task
}

# --- Actions -------------------------------------------------------------------------

function Join-Hash([hashtable]$A, [hashtable]$B) {
    $c = $A.Clone(); foreach ($k in $B.Keys) { $c[$k] = $B[$k] }; $c
}

function Wait-Approval {
    param($State, [string]$Id)
    while (-not $State.Cancel -and -not $State.Stop) {
        if ($State.Approvals.ContainsKey($Id)) { $d = $State.Approvals[$Id]; $State.Approvals.Remove($Id); return $d }
        Start-Sleep -Milliseconds 150
    }
    @{ decision = 'reject'; note = 'cancelled' }
}

function Test-AutoRun($State, [string]$Command) {
    foreach ($re in @($State.Config.autoApproveCommands)) { if ($re -and $Command -match $re) { return $true } }
    $false
}

function Get-PreviewText([string]$s) { if ($null -eq $s) { return $null } Limit-Text $s 200000 }

function Invoke-AgentAction {
    <# Executes one action. Returns @{ ok; summary; output } where output goes back to Copilot. #>
    param($State, $Action, [string]$Id, $Checkpoint, [int]$Uncertain)
    $root = $State.ProjectRoot
    $mode = $State.Mode
    $evt = @{ id = $Id; action = $Action.type; target = $Action.arg; status = 'running' }

    switch ($Action.type) {
        'read' {
            $paths = Get-ActionPaths $Action
            $evt.target = $paths -join ', '; Add-AgentEvent $State 'action' $evt
            return @{ ok = $true; summary = "read $($paths.Count) file(s)"; output = ((Invoke-ReadAction $root $paths -MaxCharsPerFile 200000) -join "`n`n"); readPaths = @($paths) }
        }
        'glob' {
            $pat = if ($Action.arg) { $Action.arg } else { $Action.body.Split("`n")[0].Trim() }
            $evt.target = $pat; Add-AgentEvent $State 'action' $evt
            return @{ ok = $true; summary = "listed $pat"; output = (Invoke-GlobAction $root $pat) }
        }
        'grep' {
            $lines = @($Action.body.Split("`n") | Where-Object { $_.Trim() })
            $pat = if ($Action.arg) { $Action.arg } else { $lines[0].Trim() }
            $glob = if ($Action.arg) { if ($lines.Count) { $lines[0].Trim() } } elseif ($lines.Count -gt 1) { $lines[1].Trim() }
            $evt.target = $pat; Add-AgentEvent $State 'action' $evt
            return @{ ok = $true; summary = "searched $pat"; output = (Invoke-GrepAction $root $pat $glob) }
        }
        'todo' {
            $State.Todos = @(Get-TodoItems $Action.body)
            Add-AgentEvent $State 'todos' @{ items = $State.Todos }
            return @{ ok = $true; summary = 'updated the task list'; output = 'task list updated' }
        }
        'done' {
            return @{ ok = $true; summary = 'done'; output = '' }
        }
    }

    # Changing actions: write, edit, run
    $needsApproval = $true
    $preview = $null
    $riskWarning = $null
    if ($Action.type -eq 'write' -or $Action.type -eq 'edit') {
        if (-not $Action.arg) { Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed' }); return @{ ok = $false; summary = "$($Action.type) without a path"; output = 'error: the block needs a path after the action name' } }
        try { $null = Assert-Writable $root $Action.arg } catch {
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = $_.Exception.Message })
            return @{ ok = $false; summary = "$($Action.type) refused (source data)"; output = "error: $($_.Exception.Message)" }
        }
        if ($Action.type -eq 'write') {
            $content = $Action.body
            $p = Get-WritePreview $root $Action.arg $content
            $preview = @{ path = $p.path; exists = $p.exists; old = (Get-PreviewText $p.old); new = (Get-PreviewText $p.new) }
        } else {
            $er = Get-EditResult $root $Action.arg $Action.edits
            if (-not $er.ok) {
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = $er.error })
                return @{ ok = $false; summary = "edit $($Action.arg) failed"; output = "error: $($er.error)" }
            }
            if ($er.unchanged) {
                $out = Format-AlreadyApplied $Action.arg $er
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'done' })
                Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $true; status = 'already applied'; summary = 'already applied (verified)'; output = $out }
                return @{ ok = $true; summary = 'already applied'; output = $out; reported = $true }
            }
            $preview = @{ path = $Action.arg; exists = $true; old = (Get-PreviewText $er.old); new = (Get-PreviewText $er.new) }
        }
        $needsApproval = ($mode -ne 'auto') -or ($Uncertain -gt 0)
    } elseif ($Action.type -eq 'run') {
        $evt.target = $Action.body.Trim()
        $needsApproval = -not (Test-AutoRun $State $evt.target)
        $risk = Get-CommandRisk $evt.target
        if ($risk.m365 -or $risk.destructive) {
            $why = $risk.reasons -join ', '
            if ($State.Headless) {
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = "refused: this command $why; that needs a person to approve it" })
                Add-AgentEvent $State 'human-required' @{ text = "Copilot wanted to run a command that $why. StreamHub does not run such commands without a person approving them. Command: $($evt.target)" }
                return @{ ok = $false; summary = 'run refused (needs a person)'; output = "not executed: this command $why. Microsoft 365 actions and deleting data always need a person. Do not try a workaround; prepare the change and tell the user what to run themselves." }
            }
            $needsApproval = $true
            $riskWarning = "Human in the loop: this command $why. Only approve it if you want exactly this to happen."
        }
    }

    if ($State.Headless -and $mode -ne 'plan') {
        if ($Action.type -eq 'run' -and -not $State.AllowCommands) {
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped' })
            return @{ ok = $false; summary = 'run skipped (commands not allowed)'; output = 'not executed: commands are not allowed for this task. Finish without running commands, and state which command the user should run to verify.' }
        }
        if ($mode -eq 'auto') { $needsApproval = $false }
    }

    if ($mode -eq 'plan') {
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; preview = $preview })
        return @{ ok = $false; summary = "$($Action.type) skipped (plan mode)"; output = 'not executed: plan mode is on (read-only). Describe the plan instead of changing files or running commands.' }
    }

    if ($needsApproval) {
        # Explicit $null: an if without else yields AutomationNull, which ConvertTo-Json writes as {}.
        $warn = $null
        if ($Uncertain -gt 0) { $warn = 'Copilot''s reply had to be repaired after its link filter removed text; check this change carefully.' }
        if ($riskWarning) { $warn = $riskWarning }
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'awaiting'; preview = $preview; warning = $warn })
        $waitWatch = [Diagnostics.Stopwatch]::StartNew()
        $d = Wait-Approval $State $Id
        Write-CCBLog verbose agent "approval ${Id}: $($d.decision) by $($d.by) after $($waitWatch.ElapsedMilliseconds) ms"
        if ($d.decision -ne 'approve') {
            Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $false; status = 'rejected'; output = $d.note; decidedBy = $d.by }
            $why = if ($d.note) { " The user said: $($d.note)" } else { '' }
            return @{ ok = $false; summary = "$($Action.type) rejected"; output = "rejected by the user.$why" ; reported = $true }
        }
        Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $true; status = 'running'; decidedBy = $d.by }
    } else {
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ preview = $preview })
    }

    try {
        switch ($Action.type) {
            'write' { $out = Invoke-WriteAction $root $Action.arg $Action.body $Checkpoint; return @{ ok = $true; summary = $out; output = $out; changed = $true } }
            'edit'  { $out = Invoke-EditAction $root $Action.arg $Action.edits $Checkpoint; return @{ ok = $true; summary = $out; output = $out; changed = $true } }
            'run'   {
                $r = Invoke-RunAction $root $evt.target -TimeoutSec $State.Config.commandTimeoutSec -CancelCheck ({ [bool]$State.Cancel }.GetNewClosure())
                $status = if ($r.cancelled) { 'stopped by the user' } elseif ($r.timedOut) { "timed out after $($State.Config.commandTimeoutSec)s" } else { "exit code $($r.exitCode)" }
                $out = "$status`n~~~~`n$($r.output)`n~~~~"
                $fixed = @(Restore-SourceData $root)
                if ($fixed.Count) {
                    Add-AgentEvent $State 'status' @{ text = "Source data is read-only; StreamHub undid what the command did to it: " + ($fixed -join '; ') }
                    $out += "`nNote: source/ is the user's read-only source data. This command changed it, so it was put back: " + ($fixed -join '; ') + '. Work on copies outside source/.'
                }
                return @{ ok = (-not $r.timedOut -and -not $r.cancelled -and $r.exitCode -eq 0); summary = "ran: $status"; output = $out }
            }
        }
    } catch {
        return @{ ok = $false; summary = "$($Action.type) failed"; output = "error: $($_.Exception.Message)" }
    }
}

# --- One user turn -------------------------------------------------------------------

function Invoke-AgentTurn {
    param($State, [string]$Text)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; $State.Busy = $false; return }
    $State.Busy = $true; $State.Cancel = $false
    $turnWatch = [Diagnostics.Stopwatch]::StartNew()
    Write-CCBLog info agent "Turn started" @{ chars = $Text.Length; mode = $State.Mode; headless = [bool]$State.Headless; allowCommands = [bool]$State.AllowCommands; workIq = $State.WorkIq; chatStarted = [bool]$State.ChatStarted }
    Write-CCBLog trace agent 'User message' @{ text = $Text }
    Add-AgentEvent $State 'user' @{ text = $Text }
    $checkpoint = New-Checkpoint $State.ProjectRoot $Text
    try { Sync-SourceVault $State.ProjectRoot } catch { Add-AgentEvent $State 'error' @{ text = "Could not back up source data: $($_.Exception.Message)" } }
    try {
        if (Test-OtherSender) { $State.NeedNewChat = $true }
        if ($State.NeedNewChat) { Start-NewChat $State }
        # As little as the request needs: plain chat goes as it is; other kinds add only the parts
        # (role, actions, rules, project context) this chat has not had yet.
        $kind = Get-TurnKind $State $Text
        $summary = $State.Summary; $State.Summary = $null
        $partsBefore = $State.SentParts.Count
        $message = New-PromptMessage -AppRoot $State.AppRoot -Kind $kind -Text $Text -Sent $State.SentParts -Context (Get-ProjectContext $State) -Summary $summary
        if ($State.SentParts.Count -gt $partsBefore -and $State.SentParts.Contains('actions')) { $State.FollowUps = 0 }
        if ($kind -ne 'chat') { $State.ChatKind = $kind }
        Write-CCBLog info agent "Task kind: $kind" @{ partsAdded = $State.SentParts.Count - $partsBefore; chars = $message.Length }
        $State.LastTurnActed = $null
        $message += Get-PinnedFiles $State.ProjectRoot $Text

        $nudges = 0   # times this message was sent again because Copilot explained instead of acting
        $lastReply = ''; $doneText = ''   # for the suggested next steps after the turn
        $reviewed = $false   # the consistency review after a big change happens once per message
        for ($round = 1; $round -le $State.Config.maxRounds; $round++) {
            if ($State.Cancel) { Add-AgentEvent $State 'status' @{ text = 'Stopped.' }; break }
            Invoke-RolloverIfNeeded $State
            if (-not $State.ChatStarted -and $round -gt 1) {
                # A rollover started a fresh chat: give it the parts again, with the summary.
                $prefix = New-PromptMessage -AppRoot $State.AppRoot -Kind $(if ($State.ChatKind) { $State.ChatKind } else { 'chat' }) -Text '' -Sent $State.SentParts -Context (Get-ProjectContext $State) -Summary $State.Summary
                $State.Summary = $null
                if ($prefix) { $message = "$prefix`n`n$message" }
            }
            $message = Limit-Text $message $State.Config.promptCharBudget

            Write-CCBLog verbose agent "Round ${round}: sending" @{ chars = $message.Length }
            $r = Send-ToCopilot $State $message
            if ($r.Cancelled) {
                if ($r.CopilotFinished -and "$($r.Text)".Trim()) {
                    Add-AgentEvent $State 'assistant' @{ text = $r.Text; uncertain = $r.Uncertain; round = $round; used = $State.Throttle.used; max = $State.Throttle.max; references = @() }
                    Add-AgentEvent $State 'status' @{ text = 'Stopped. Copilot had already finished; its reply is shown above, but its actions were not carried out.' }
                } else {
                    Add-AgentEvent $State 'status' @{ text = 'Stopped while Copilot was writing; its partial reply was discarded.' }
                }
                break
            }
            $actions = @(Get-ActionBlocks $r.Text)
            $lastReply = "$($r.Text)"
            Write-CCBLog verbose agent "Round ${round}: reply parsed" @{ actions = @($actions | ForEach-Object { "$($_.type) $($_.arg)".Trim() }) }
            Add-AgentEvent $State 'assistant' @{ text = $r.Text; uncertain = $r.Uncertain; round = $round; used = $State.Throttle.used; max = $State.Throttle.max; references = @($r.References) }
            if ($r.Result -and $r.Result -ne 'Success') { Add-AgentEvent $State 'error' @{ text = "Copilot answered with '$($r.Result)': $($r.ResultMessage)" }; break }
            if (-not "$($r.Text)".Trim()) {
                Add-AgentEvent $State 'error' @{ text = 'Copilot finished without a reply. Check the Copilot window in Edge; if it shows an answer there, turn on verbose logging, try again and export diagnostics.' }
                break
            }
            if (@($r.ProposedActions).Count) {
                $what = (@($r.ProposedActions) | ForEach-Object { $_.title } | Where-Object { $_ } | Select-Object -Unique) -join '; '
                Add-AgentEvent $State 'human-required' @{ text = "Copilot proposed an action in Microsoft 365 ($what). StreamHub never confirms Microsoft 365 actions. Look at it in the Copilot window in Edge and confirm or cancel it yourself; the task has stopped here." }
                break
            }
            foreach ($claim in @($r.ActionClaims)) {
                Add-AgentEvent $State 'human-required' @{ text = "Copilot's reply says: ""$claim"" StreamHub did not confirm any Microsoft 365 action. Check Outlook / Teams if this is unexpected." }
            }
            if (-not $actions.Count) {
                if ($State.LastTurnActed -ne $true) { $State.LastTurnActed = $false }
                $effectiveKind = if ($kind -eq 'chat' -and $State.ChatKind) { $State.ChatKind } else { $kind }
                $maxRetries = if ($null -ne $State.Config.actionRetries) { [int]$State.Config.actionRetries } else { 2 }
                if (Test-NeedsActionNudge $State $effectiveKind $r.Text $nudges $maxRetries) {
                    # Copilot told how to do the task instead of doing it: send the same task again,
                    # with the action instructions in full and a note that it must carry it out.
                    $nudges++
                    Write-CCBLog info agent "Reply gave instructions instead of actions; sending the task again with the instructions enforced (attempt $nudges of $maxRetries)"
                    Add-AgentEvent $State 'status' @{ text = "Copilot explained how to do it instead of doing it. Sending the task again with the instructions for changing files (attempt $nudges of $maxRetries)." }
                    $message = New-ActionRetryMessage $State $Text
                    continue
                }
                if ($nudges -ge $maxRetries -and $effectiveKind -in 'coding', 'project', 'mixed' -and $State.Mode -ne 'plan') {
                    Add-AgentEvent $State 'status' @{ text = "Copilot still explained instead of changing the files after $nudges attempts, so StreamHub stopped asking. Try a New chat, or phrase the request as a direct instruction (for example: ""Edit index.html so that ..."")." }
                }
                break
            }

            $State.LastTurnActed = $true
            $results = New-Object Collections.Generic.List[object]
            $isDone = $false
            for ($k = 0; $k -lt $actions.Count; $k++) {
                if ($State.Cancel) { break }
                $a = $actions[$k]
                if ($a.type -eq 'done') { $isDone = $true; $doneText = $a.body.Trim(); Add-AgentEvent $State 'done' @{ text = $doneText }; continue }
                $id = "$($State.Seq)-$k"
                $res = Invoke-AgentAction $State $a $id $checkpoint $r.Uncertain
                if (-not $res.reported) {
                    $result = @{ id = $id; ok = $res.ok; status = $(if ($res.ok) { 'ok' } else { 'failed' }); summary = $res.summary; output = (Limit-Text $res.output 4000); changed = [bool]$res.changed }
                    if (-not $res.ok) {
                        # Why it may have failed, and what happens next (shown on the step's card and logged).
                        $why = Get-StepFailureInfo $a.type "$($res.summary) $($res.output)"
                        $result.code = $why.code; $result.reasons = @($why.reasons); $result.next = $why.next
                    }
                    Add-AgentEvent $State 'action-result' $result
                }
                $results.Add(@{ head = "### $($k + 1). $($a.type) $($a.arg)".TrimEnd(); output = "$($res.output)"; readPaths = $res.readPaths })
            }
            if ($State.Cancel) { Add-AgentEvent $State 'status' @{ text = 'Stopped. Changes made so far in this message can be undone.' }; break }
            if ($isDone) {
                # After a big change: one consistency review by Copilot (dead code, broken references).
                if (-not $reviewed) {
                    $changes = @(Get-CheckpointChanges $State.ProjectRoot $checkpoint)
                    # Page check: when web files changed, open the changed pages (or index.html) and
                    # collect JavaScript errors and files that fail to load.
                    $pageIssues = @()
                    $webChanged = @($changes | Where-Object { ($_.added -or $_.removed) -and $_.path -match '(?i)\.(html?|css|m?js|json)$' })
                    if ($webChanged.Count -and "$($State.Config.pageCheck)" -ne 'off' -and $State.PreviewPort -and $State.Mode -ne 'plan') {
                        $pages = @($webChanged | Where-Object { -not $_.deleted -and $_.path -match '(?i)\.html?$' } | ForEach-Object { $_.path })
                        if (-not $pages.Count -and (Test-Path -LiteralPath (Join-Path $State.ProjectRoot 'index.html'))) { $pages = @('index.html') }
                        if ($pages.Count) {
                            Add-AgentEvent $State 'status' @{ text = "Checking $($pages -join ', ') in a browser tab for JavaScript errors and files that fail to load..." }
                            $pageIssues = @(Test-WebPage $State $pages)
                            if (-not $pageIssues.Count) { Add-AgentEvent $State 'status' @{ text = "Page check: $($pages -join ', ') loaded without errors." } }
                        }
                    }
                    if ($pageIssues.Count -or (Test-NeedsReview $State $changes)) {
                        $reviewed = $true
                        $issues = @(@(Test-ProjectConsistency $State.ProjectRoot @($changes | ForEach-Object { $_.path })) + @($pageIssues | ForEach-Object { "page check: $_" }))
                        Write-CCBLog info agent 'Asking Copilot for a consistency review' @{ files = $changes.Count; issues = $issues.Count }
                        Add-AgentEvent $State 'status' @{ text = "Big change: asking Copilot to review $(@($changes).Count) changed file(s) for leftovers, dead code and broken references$(if ($issues.Count) { " ($($issues.Count) problem(s) found by the local checks)" })." }
                        $message = New-ReviewMessage $State $changes $issues
                        continue
                    }
                }
                break
            }
            if ($round -eq $State.Config.maxRounds) { Add-AgentEvent $State 'status' @{ text = "Stopped after $($State.Config.maxRounds) rounds. Send a message to continue." }; break }

            $message = "Results:`n`n" + (Format-ActionResults $State $results) + "`n`nContinue. Use done when the task is finished."
        }
        # "Next steps" in Copilot's last reply become one-click prompts (sent only when the user picks one).
        if (-not $State.Cancel) {
            $next = @(Get-NextSteps ($lastReply + "`n`n" + $doneText))
            if ($next.Count) { Add-AgentEvent $State 'next-steps' @{ steps = $next } }
        }
    } catch {
        Write-CCBLogError agent 'turn failed' $_
        Add-AgentEvent $State 'error' @{ text = $_.Exception.Message; record = $_ }
    } finally {
        Write-CCBLog info agent "Turn finished" @{ ms = $turnWatch.ElapsedMilliseconds; chat = "$($State.Throttle.used)/$($State.Throttle.max)"; cancelled = [bool]$State.Cancel }
        try {
            $fixed = @(Restore-SourceData $State.ProjectRoot)
            if ($fixed.Count) { Add-AgentEvent $State 'status' @{ text = 'Source data is read-only; StreamHub undid changes to it: ' + ($fixed -join '; ') } }
        } catch { Add-AgentEvent $State 'error' @{ text = "Could not verify source data: $($_.Exception.Message)" } }
        if (-not $checkpoint.Files.Count) { Remove-Item $checkpoint.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        else { Add-AgentEvent $State 'checkpoint' @{ files = @($checkpoint.Files.Keys) } }
        $State.Busy = $false; $State.Cancel = $false
    }
}

function Start-AgentWorker {
    <# Worker loop: processes queued tasks until $State.Stop. #>
    param([Parameter(Mandatory)]$State)
    Initialize-CCBLog -Level $State.LogLevel -Config $State.Config
    $appliedLevel = $State.LogLevel
    Write-CCBLog verbose agent "Worker started" @{ level = (Get-CCBLogLevel) }
    while (-not $State.Stop) {
        if ($State.LogLevel -and $State.LogLevel -ne $appliedLevel) { Set-CCBLogLevel $State.LogLevel; $appliedLevel = $State.LogLevel; Write-CCBLog info agent "Log level now $appliedLevel" }
        $task = $null
        if (-not $State.Tasks.TryDequeue([ref]$task)) {
            # Keep Copilot staged: after a failed connect, try again while nothing else is happening.
            if (-not $State.Headless -and $State.Copilot -eq 'error' -and $State.NextConnectAttempt -and (Get-Date) -gt $State.NextConnectAttempt) {
                $State.NextConnectAttempt = $null
                Write-CCBLog info agent 'Retrying the Copilot connection'
                $State.Tasks.Enqueue(@{ kind = 'connect' })
            }
            Start-Sleep -Milliseconds 150; continue
        }
        # Jobs (MCP) track a task from queue to result.
        $job = if ($task.jobId) { $State.Jobs[$task.jobId] } else { $null }
        if ($job) { $job.status = 'running'; $job.startSeq = $State.Seq; $job.started = (Get-Date).ToString('s') }
        try {
            switch ($task.kind) {
                'connect' { $null = Get-Bridge $State }
                'chat'    {
                    if ($task.projectRoot -and $task.projectRoot -ne $State.ProjectRoot) {
                        $State.ProjectRoot = $task.projectRoot; $State.Todos = @(); $State.NeedNewChat = $true
                    }
                    if ($task.newChat) { $State.NeedNewChat = $true }
                    Invoke-AgentTurn $State $task.text
                }
                'fetch' { Invoke-FetchJob $State $task.name }
                'ask' {
                    # A plain question to Copilot, without project context or actions.
                    if ($task.newChat -or (Test-OtherSender)) { Start-NewChat $State }
                    $r = Send-ToCopilot $State $task.text
                    if ($r.Cancelled) { $job.cancelled = $true }
                    $job.reply = $r.Text; $job.result = $r.Result; $job.resultMessage = $r.ResultMessage; $job.uncertain = $r.Uncertain; $job.references = @($r.References)
                    $job.proposedActions = @($r.ProposedActions); $job.actionClaims = @($r.ActionClaims)
                    if ($r.Result -and $r.Result -ne 'Success') { $job.status = 'error'; $job.error = "Copilot answered with '$($r.Result)': $($r.ResultMessage)" }
                    elseif (-not $r.Cancelled -and -not "$($r.Text)".Trim()) { $job.status = 'error'; $job.error = 'Copilot finished without a reply' }
                }
                'newchat' {
                    Start-NewChat $State
                    $State.Todos = @()
                    $State.Summary = $null
                    Add-AgentEvent $State 'newchat' @{ text = 'New Copilot chat started.' }
                }
                'undo' {
                    $files = @(Undo-LastCheckpoint $State.ProjectRoot)
                    $text = if ($files.Count) { 'Undid the last change set: ' + ($files -join ', ') } else { 'Nothing to undo.' }
                    Add-AgentEvent $State 'undo' @{ files = $files; text = $text }
                }
            }
        } catch {
            Write-CCBLogError agent "task $($task.kind) failed" $_
            Add-AgentEvent $State 'error' @{ text = $_.Exception.Message; record = $_ }
            if ($job) { $job.status = 'error'; $job.error = $_.Exception.Message }
        } finally {
            if ($job) {
                if ($job.status -eq 'running') { $job.status = if ($job.cancelled) { 'cancelled' } else { 'finished' } }
                $job.endSeq = $State.Seq; $job.finished = (Get-Date).ToString('s')
            }
        }
    }
    Reset-Bridge $State
}

Export-ModuleMember -Function New-AgentState, Add-AgentEvent, Get-AgentEvents, Start-AgentWorker, Invoke-AgentTurn
