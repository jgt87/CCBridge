# The agent loop. Runs in a background runspace and talks to the web server only through
# the synchronized $State hashtable (events out, tasks and approval decisions in).

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Cdp', 'CopilotBridge', 'Workspace', 'Protocol', 'Executor', 'Prompts', 'Fetch', 'Runbook', 'Schedule', 'Review', 'PlanFile', 'Lint', 'Issues', 'Imports') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

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
        Queue = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))   # every task, whatever started it (Submit-AgentTask)
        CurrentQueueId = $null; MessagesSent = 0; NoCommands = $false
        QueueFile = $null   # set by the web app: the queue survives restarts (Save-AgentQueue / Restore-AgentQueue)
        Schedules = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); ScheduleFile = $null; NextScheduleCheck = $null
        # Schedules live in each project (<project>\.streamhub\schedules.json); per project root the
        # file time last read or written, so edits from outside (by hand, OneDrive) are picked up.
        ScheduleRoots = [hashtable]::Synchronized(@{}); NextScheduleSync = $null
        Held = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))   # tasks put back after the daily limit: they run first
        PausedUntil = $null; PauseReason = $null; LastLimitAt = $null; PauseFile = $null   # the web app saves the pause (Save-QueuePause)
        ResponseMode = $(if ($Config.responseMode) { [string]$Config.responseMode } else { 'leave' }); ResponseModeActual = $null   # Auto / Quick / Think deeper
        ReviewByCaller = $false   # MCP tasks: the calling model checks the result, so no Copilot review round
        NextConnectAttempt = $null
        # Work IQ (Microsoft 365 data in Copilot): 'on', 'off' or 'leave' (do not touch the toggle).
        WorkIq = $(if ($Config.workIq) { [string]$Config.workIq } else { 'leave' }); WorkIqActual = $null; WorkIqWarned = $false
        # Issue cycle: what the worker is doing besides Copilot (shown like "waiting for Copilot"),
        # the background indexer's progress, and the fix task being worked on.
        Activity = [hashtable]::Synchronized(@{ label = ''; done = 0; total = 0; current = '' })
        Indexing = [hashtable]::Synchronized(@{ running = $false; label = ''; done = 0; total = 0; current = ''; project = $null; last = $null; error = $null })
        IssueFix = $null; IssueFixHandled = $false
        SaveHistory = $false   # set by the web app: the chat is kept per project (Save-ChatEvent / Restore-ChatHistory)
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
        $Data.seq = $State.Seq; $Data.type = $Type
        # A restored event keeps its own time (with the date when it was not today).
        if (-not $Data.restored) { $Data.time = (Get-Date).ToString('HH:mm:ss'); $Data.at = (Get-Date).ToString('s') }
        if ($Type -eq 'error' -and -not $Data.restored) {
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
        # A restored event was logged when it happened.
        if (-not $Data.restored) { switch ($Type) {
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
            'runbook'        { Write-CCBLog info agent "runbook $($Data.name) -> $($Data.path)" }
        } }
        # Keep memory bounded; the UI only needs recent history after a reload.
        if ($State.Events.Count -gt 2000) { $State.Events.RemoveRange(0, 500) }
        if ($State.SaveHistory -and $State.ProjectRoot -and $Type -notin 'project', 'history-cleared' -and -not $Data.restored) {
            try { Save-ChatEvent $State.ProjectRoot $Data } catch { Write-CCBLogError agent 'chat history' $_ }
        }
    } finally { [Threading.Monitor]::Exit($State.Events.SyncRoot) }
}

# --- Chat history: kept per project, back after a restart ------------------------------------
# One JSON line per event in the project's state folder (%LOCALAPPDATA%\CCBridge\projects\...,
# not OneDrive: replies can hold Microsoft 365 data, and every event would make OneDrive sync).

$script:HistoryMaxEvents = 1500     # the most a project's history holds: older events are removed past this
$script:HistoryMaxEventChars = 200000
$script:HistoryCounts = @{}         # history file -> events in it (counted once, then kept up to date)

function Get-ChatHistoryPath([string]$ProjectRoot) { Join-Path (Get-ProjectStateDir $ProjectRoot) 'chat-history.jsonl' }

function Save-ChatEvent {
    <# Appends one event to the project's chat history. A very large event (a big file in a change
       preview) is kept without the file contents, so the card still shows what happened. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][hashtable]$Event)
    $json = ConvertTo-Json -InputObject $Event -Depth 6 -Compress
    if ($json.Length -gt $script:HistoryMaxEventChars) {
        $copy = @{}; foreach ($k in $Event.Keys) { $copy[$k] = $Event[$k] }
        if ($copy.preview) { $copy.preview = @{ path = $copy.preview.path; exists = $copy.preview.exists; old = $null; new = '(too large to keep in the chat history)' } }
        foreach ($k in 'output', 'text', 'detail') { if ("$($copy[$k])".Length -gt 50000) { $copy[$k] = "$($copy[$k])".Substring(0, 50000) + "`n... (shortened in the chat history)" } }
        $json = ConvertTo-Json -InputObject $copy -Depth 6 -Compress
    }
    $file = Get-ChatHistoryPath $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $file)
    [IO.File]::AppendAllText($file, $json + "`n", (New-Object Text.UTF8Encoding($false)))
    # Never more than HistoryMaxEvents: past that, the oldest events are removed.
    $n = if ($script:HistoryCounts.ContainsKey($file)) { $script:HistoryCounts[$file] + 1 } else { @([IO.File]::ReadAllLines($file) | Where-Object { $_.Trim() }).Count }
    if ($n -gt $script:HistoryMaxEvents) { $n = Limit-ChatHistory $file }
    $script:HistoryCounts[$file] = $n
}

function Limit-ChatHistory([string]$File) {
    # Keeps the newest HistoryMaxEvents events of a history file; returns how many it holds now.
    $lines = @([IO.File]::ReadAllLines($File) | Where-Object { $_.Trim() } | Select-Object -Last $script:HistoryMaxEvents)
    [IO.File]::WriteAllText($File, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    $lines.Count
}

function Reset-ChatHistoryCount([string]$File) { $script:HistoryCounts.Remove($File) }

function Read-ChatHistory {
    <# The project's saved events, oldest first (at most -Max). Unreadable lines are skipped; a file
       holding more than HistoryMaxEvents (from before this limit) is trimmed to it. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [int]$Max = $script:HistoryMaxEvents)
    $file = Get-ChatHistoryPath $ProjectRoot
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $lines = @([IO.File]::ReadAllLines($file) | Where-Object { $_.Trim() })
    if ($lines.Count -gt $script:HistoryMaxEvents) { $null = Limit-ChatHistory $file; $lines = @($lines | Select-Object -Last $script:HistoryMaxEvents) }
    $script:HistoryCounts[$file] = $lines.Count
    foreach ($l in @($lines | Select-Object -Last $Max)) {
        try { $o = $l | ConvertFrom-Json } catch { continue }
        if ($o -and $o.type) { $o }
    }
}

function ConvertTo-EventHash($Object) {
    # A saved event (JSON object, also nested) as hashtables, the shape Add-AgentEvent works with.
    if ($null -eq $Object) { return $null }
    if ($Object -is [string] -or $Object -is [ValueType]) { return $Object }
    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [System.Management.Automation.PSCustomObject]) { return , @($Object | ForEach-Object { ConvertTo-EventHash $_ }) }
    $h = @{}; foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-EventHash $p.Value }
    $h
}

function Get-ChangeCountStart {
    <# Where the Files tab's line counts and "new" marks start for a project just opened: at the
       oldest event of its restored chat (a minute before, so a step's change set falls inside),
       when that is earlier than $Now. So after a restart the counts match the change sets still
       in the chat. Returns a checkpoint-style id (yyyyMMdd-HHmmss-fff). #>
    param($State, [int]$AfterSeq, [string]$Now)
    $first = $null
    foreach ($e in @($State.Events)) {
        if ($e.seq -le $AfterSeq -or -not $e.restored -or -not $e.at) { continue }
        $t = [datetime]::MinValue
        if ([datetime]::TryParse("$($e.at)", [ref]$t) -and (-not $first -or $t -lt $first)) { $first = $t }
    }
    if (-not $first) { return $Now }
    $since = $first.AddMinutes(-1).ToString('yyyyMMdd-HHmmss-fff')
    if ($since -lt $Now) { $since } else { $Now }
}

function Restore-ChatHistory {
    <# Puts the project's earlier conversation back in the chat, after a restart or when the project
       is opened again. An action that was still waiting for approval or running is marked
       "interrupted": its task ended with the restart, so it cannot be approved any more. Copilot
       starts a new chat, so a note says it does not remember the earlier one. Returns the count. #>
    param($State, [Parameter(Mandatory)][string]$ProjectRoot)
    $saved = @(Read-ChatHistory $ProjectRoot)
    if (-not $saved.Count) { return 0 }
    $final = @{}   # action id -> last status seen
    foreach ($e in $saved) { if ($e.type -in 'action', 'action-result' -and $e.id -and $e.status) { $final["$($e.id)"] = "$($e.status)" } }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    foreach ($e in $saved) {
        $h = ConvertTo-EventHash $e
        $type = "$($h.type)"; [void]$h.Remove('type'); [void]$h.Remove('seq')
        $h.restored = $true
        if ($h.at -and "$($h.at)".Substring(0, 10) -ne $today) { $h.time = ([datetime]"$($h.at)").ToString('yyyy-MM-dd HH:mm') }
        Add-AgentEvent $State $type $h
    }
    foreach ($id in @($final.Keys | Where-Object { $final[$_] -in 'awaiting', 'running' })) {
        Add-AgentEvent $State 'action-result' @{ id = $id; status = 'interrupted'; restored = $true; time = (Get-Date).ToString('HH:mm:ss') }
    }
    Add-AgentEvent $State 'status' @{ text = 'Above: the earlier conversation in this project. Copilot starts a new chat for your next message and does not remember it; mention what it should build on.'; restored = $true; time = (Get-Date).ToString('HH:mm:ss') }
    Write-CCBLog info agent 'Chat history restored' @{ project = $ProjectRoot; events = $saved.Count }
    $saved.Count
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
    if ($State.ResponseMode -in 'auto', 'quick', 'deep') {
        try { $State.ResponseModeActual = Set-CopilotResponseMode $bridge $State.ResponseMode } catch { Write-CCBLogError agent 'Response mode' $_ }
    }
    $State.MessagesSent = [int]$State.MessagesSent + 1
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

function Submit-AgentTask {
    <# Puts a task in the worker's queue and records it in $State.Queue (shown in the Queue tab):
       what was asked, where it came from (user, mcp, api), status, timing, Copilot messages used,
       result or error. Returns the queue entry. #>
    param($State, [hashtable]$Task, [string]$Source = 'user', [string]$Title = '')
    $id = 'q-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    if (-not $Title) {
        $Title = switch ($Task.kind) {
            'chat' { "$($Task.text)" } 'ask' { "$($Task.text)" } 'fetch' { "Fetch: $($Task.name)" } 'runbook' { "Runbook: $($Task.name)" } 'review' { 'Code review' }
            'newchat' { 'New Copilot chat' } 'undo' { 'Undo last change set' } default { "$($Task.kind)" }
        }
    }
    $Title = ($Title -replace '\s+', ' ').Trim(); if ($Title.Length -gt 160) { $Title = $Title.Substring(0, 157) + '...' }
    $entry = [hashtable]::Synchronized(@{ id = $id; kind = $Task.kind; title = $Title; source = $Source; status = 'queued'; created = (Get-Date).ToString('s')
        project = $(if ($Task.projectRoot) { Split-Path $Task.projectRoot -Leaf } elseif ($State.ProjectRoot) { Split-Path $State.ProjectRoot -Leaf } else { $null })
        jobId = $Task.jobId; started = $null; finished = $null; messages = 0; summary = $null; error = $null; resultPath = $null
        projectRoot = $(if ($Task.projectRoot) { $Task.projectRoot } else { $State.ProjectRoot }) })
    $Task.queueId = $id
    $entry.task = @{}
    foreach ($k in $Task.Keys) { if ($k -ne 'queueId') { $entry.task[$k] = $Task[$k] } }
    [void]$State.Queue.Add($entry)
    while ($State.Queue.Count -gt 100) { $State.Queue.RemoveAt(0) }
    $State.Tasks.Enqueue($Task)
    Save-AgentQueue $State
    Write-CCBLog info agent "Queued $id ($($Task.kind), from $Source)" @{ title = $Title }
    $entry
}

function Save-AgentQueue {
    <# Writes the queue to $State.QueueFile (the web app sets it) so it survives a restart or an
       update. Finished entries are kept without their task; waiting ones with it. #>
    param($State)
    if (-not $State.QueueFile) { return }
    [Threading.Monitor]::Enter($State.Queue.SyncRoot)
    try {
        $list = foreach ($e in @($State.Queue)) {
            $copy = @{}
            foreach ($k in @($e.Keys)) { if ($k -ne 'task' -or $e.status -eq 'queued') { $copy[$k] = $e[$k] } }
            $copy
        }
        $json = ConvertTo-Json -InputObject @($list) -Depth 6 -Compress
        $tmp = "$($State.QueueFile).tmp"
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $State.QueueFile)
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $State.QueueFile) { [IO.File]::Replace($tmp, $State.QueueFile, [NullString]::Value) } else { [IO.File]::Move($tmp, $State.QueueFile) }
    } catch {
        Write-CCBLogError agent 'Could not save the queue' $_
    } finally { [Threading.Monitor]::Exit($State.Queue.SyncRoot) }
}

function ConvertTo-PlainHash($Object) {
    <# A JSON object (PSCustomObject) as a hashtable, one level deep. #>
    $h = @{}
    if ($Object) { foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    $h
}

function Restore-AgentQueue {
    <# Loads the queue saved before the last stop. Waiting tasks are queued again (MCP jobs keep their
       id, so a client polling them carries on); a task that was running when StreamHub stopped is
       marked failed, as Copilot's work on it was cut off. Returns the number of tasks queued again. #>
    param($State)
    if (-not $State.QueueFile -or -not (Test-Path -LiteralPath $State.QueueFile)) { return 0 }
    $saved = try { @(([IO.File]::ReadAllText($State.QueueFile)) | ConvertFrom-Json) } catch { Write-CCBLogError agent 'Could not read the saved queue' $_; @() }
    $requeued = 0
    foreach ($s in $saved) {
        if (-not $s -or -not $s.id) { continue }
        $e = [hashtable]::Synchronized((ConvertTo-PlainHash $s))
        $e.changed = @($s.changed | Where-Object { $_ })
        if ($e.status -in 'running', 'awaiting') {
            $e.status = 'failed'; $e.finished = (Get-Date).ToString('s')
            $e.error = 'StreamHub stopped while this task was running. Files it changed so far can be undone; send it again to finish it.'
        }
        if ($e.status -eq 'queued') {
            $task = ConvertTo-PlainHash $s.task
            if (-not $task.kind) { $e.status = 'failed'; $e.error = 'Could not be restored after the restart.'; $e.Remove('task') }
            else {
                if ($task.kind -eq 'chat' -and -not $task.projectRoot -and $e.projectRoot) { $task.projectRoot = $e.projectRoot }
                $task.queueId = $e.id
                if ($task.jobId) {
                    $State.Jobs[$task.jobId] = [hashtable]::Synchronized(@{ id = $task.jobId; kind = $(if ($task.kind -eq 'chat') { 'task' } else { $task.kind }); status = 'queued'; created = $e.created; queuedSeq = $State.Seq; project = $task.projectRoot })
                }
                $e.task = $task
                $State.Tasks.Enqueue($task)
                $requeued++
            }
        }
        [void]$State.Queue.Add($e)
    }
    while ($State.Queue.Count -gt 100) { $State.Queue.RemoveAt(0) }
    Write-CCBLog info agent "Queue restored" @{ entries = $State.Queue.Count; requeued = $requeued }
    if ($requeued) { Add-AgentEvent $State 'status' @{ text = "Picked up $requeued waiting task(s) from before the restart; they run in order (remove one in the Queue with its x)." } }
    $requeued
}

function Save-QueuePause {
    <# Keeps the daily-limit pause across a restart, so a restart does not spend another attempt. #>
    param($State)
    if (-not $State.PauseFile) { return }
    try {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $State.PauseFile)
        [IO.File]::WriteAllText($State.PauseFile, (@{ pausedUntil = $State.PausedUntil; reason = $State.PauseReason; lastLimitAt = $State.LastLimitAt } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    } catch { Write-CCBLogError agent 'Could not save the pause' $_ }
}

function Restore-QueuePause {
    param($State)
    if (-not $State.PauseFile -or -not (Test-Path -LiteralPath $State.PauseFile)) { return }
    try {
        $p = [IO.File]::ReadAllText($State.PauseFile) | ConvertFrom-Json
        $State.LastLimitAt = $p.lastLimitAt
        $until = ConvertTo-LocalTime "$($p.pausedUntil)"
        if ($until -and $until -gt (Get-Date)) {
            $State.PausedUntil = $until.ToString('s'); $State.PauseReason = $p.reason
            Write-CCBLog info agent 'Queue still paused after the restart' @{ until = $State.PausedUntil }
        }
    } catch { Write-CCBLogError agent 'Could not read the pause' $_ }
}

function Set-QueuePause {
    <# Copilot's daily limit was reached: the queue waits until it resets, then continues. #>
    param($State, [datetime]$Until, [string]$Reason)
    $State.PausedUntil = $Until.ToString('s'); $State.PauseReason = $Reason; $State.LastLimitAt = (Get-Date).ToString('s')
    Save-QueuePause $State
    Write-CCBLog info agent 'Queue paused: Copilot daily limit' @{ until = $State.PausedUntil; reason = $Reason }
    Add-AgentEvent $State 'status' @{ text = "Copilot's daily limit is reached. The queue waits until $($Until.ToString('HH:mm')) and then continues; nothing is lost." }
}

function Resume-AgentQueue {
    param($State, [string]$Why = 'the limit has reset')
    if (-not $State.PausedUntil) { return }
    $State.PausedUntil = $null; $State.PauseReason = $null
    Save-QueuePause $State
    Write-CCBLog info agent "Queue continues ($Why)"
    Add-AgentEvent $State 'status' @{ text = "The queue continues ($Why)." }
}

function Get-ProjectScheduleFile([string]$ProjectRoot) { Join-Path $ProjectRoot '.streamhub\schedules.json' }

function Get-ScheduleKey([string]$ProjectRoot) { $ProjectRoot.TrimEnd('\').ToLowerInvariant() }

function ConvertTo-ScheduleItem($Object, [string]$ProjectRoot) {
    # A saved schedule as the synchronized hashtable the worker uses. The project is where the file
    # was found (on another machine the same project may sit at another path).
    $h = [hashtable]::Synchronized((ConvertTo-PlainHash $Object))
    $h.days = @($Object.days | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    $h.times = @(Get-ScheduleTimes $h)
    if ($ProjectRoot) { $h.projectRoot = $ProjectRoot.TrimEnd('\') }
    if ($h.enabled -and -not $h.nextRun) { $n = Get-NextRun $h (Get-Date); $h.nextRun = if ($n) { $n.ToString('s') } else { $null } }
    $h
}

function Save-Schedules {
    <# Writes each project's schedules to <project>\.streamhub\schedules.json (only projects whose
       folder exists; a project whose last schedule was removed gets an empty list). Nothing is
       saved when $State.ScheduleFile is not set (the MCP server's own engine). #>
    param($State, [string[]]$Roots)
    if (-not $State.ScheduleFile) { return }
    [Threading.Monitor]::Enter($State.Schedules.SyncRoot)
    try {
        $byRoot = @{}
        foreach ($s in @($State.Schedules)) {
            if (-not $s.projectRoot) { continue }
            $k = Get-ScheduleKey $s.projectRoot
            if (-not $byRoot[$k]) { $byRoot[$k] = @{ root = "$($s.projectRoot)".TrimEnd('\'); list = New-Object System.Collections.ArrayList } }
            $copy = @{}; foreach ($key in @($s.Keys)) { $copy[$key] = $s[$key] }; $copy.Remove('projectRoot')
            [void]$byRoot[$k].list.Add($copy)
        }
        foreach ($k in @($State.ScheduleRoots.Keys)) { if (-not $byRoot[$k]) { $byRoot[$k] = @{ root = $State.ScheduleRoots[$k].root; list = @() } } }
        $only = @{}; foreach ($r in @($Roots | Where-Object { $_ })) { $only[(Get-ScheduleKey $r)] = $true }
        foreach ($k in $byRoot.Keys) {
            if ($only.Count -and -not $only.ContainsKey($k)) { continue }
            $root = $byRoot[$k].root
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            $file = Get-ProjectScheduleFile $root
            if (-not @($byRoot[$k].list).Count -and -not (Test-Path -LiteralPath $file)) { continue }
            try {
                $null = New-Item -ItemType Directory -Force -Path (Split-Path $file)
                $tmp = "$file.tmp"
                [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject @($byRoot[$k].list) -Depth 5), (New-Object Text.UTF8Encoding($false)))
                if (Test-Path -LiteralPath $file) { [IO.File]::Replace($tmp, $file, [NullString]::Value) } else { [IO.File]::Move($tmp, $file) }
                # Our own write is not an outside change.
                $State.ScheduleRoots[$k] = @{ root = $root; ticks = (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks }
            } catch { Write-CCBLogError agent "Could not save the schedules of $root" $_ }
        }
    } finally { [Threading.Monitor]::Exit($State.Schedules.SyncRoot) }
}

function Import-ProjectSchedules {
    <# Reads one project's schedules file and replaces that project's schedules with it. A project
       folder that exists without the file has no schedules (the file was removed). #>
    param($State, [Parameter(Mandatory)][string]$ProjectRoot)
    $root = $ProjectRoot.TrimEnd('\'); $k = Get-ScheduleKey $root
    $file = Get-ProjectScheduleFile $root
    $items = @()
    $ticks = 0
    if (Test-Path -LiteralPath $file) {
        $ticks = (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks
        # Assigned first: in PowerShell 5.1 ConvertFrom-Json hands a JSON array on as one object.
        $parsed = try { [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { Write-CCBLogError agent "Could not read $file" $_; return }
        $items = @(foreach ($o in $parsed) { if ($o -and $o.id) { ConvertTo-ScheduleItem $o $root } })
    }
    [Threading.Monitor]::Enter($State.Schedules.SyncRoot)
    try {
        foreach ($old in @($State.Schedules | Where-Object { $_.projectRoot -and (Get-ScheduleKey $_.projectRoot) -eq $k })) { $State.Schedules.Remove($old) }
        foreach ($i in $items) { [void]$State.Schedules.Add($i) }
        if ($ticks) { $State.ScheduleRoots[$k] = @{ root = $root; ticks = $ticks } } else { $State.ScheduleRoots.Remove($k) }
    } finally { [Threading.Monitor]::Exit($State.Schedules.SyncRoot) }
    Write-CCBLog verbose agent 'Project schedules imported' @{ project = $root; count = $items.Count }
    $items.Count
}

function Sync-ProjectSchedules {
    <# Imports the schedules of every known project whose file is new or changed (at most once a
       minute unless -Force): the projects in the OneDrive projects folder, the open project, and
       projects that had schedules. Returns how many projects were imported. #>
    param($State, [string[]]$Roots, [switch]$Force)
    if (-not $State.ScheduleFile) { return 0 }
    if (-not $Force -and $State.NextScheduleSync -and (Get-Date) -lt [datetime]$State.NextScheduleSync) { return 0 }
    $State.NextScheduleSync = (Get-Date).AddSeconds(60).ToString('s')
    $candidates = @($Roots | Where-Object { $_ })
    if (-not $candidates.Count) {
        $candidates = @($State.ScheduleRoots.Values | ForEach-Object { $_.root }) + @($State.ProjectRoot) + @($State.Schedules | ForEach-Object { $_.projectRoot })
        try { $candidates += @(Get-CCBridgeProjects | ForEach-Object { $_.path }) } catch { }
    }
    $done = 0; $seen = @{}
    foreach ($r in @($candidates | Where-Object { $_ })) {
        $k = Get-ScheduleKey $r
        if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }   # offline or moved: keep what we have
        $file = Get-ProjectScheduleFile $r
        $known = $State.ScheduleRoots[$k]
        $ticks = if (Test-Path -LiteralPath $file) { (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks } else { 0 }
        $hasItems = @($State.Schedules | Where-Object { $_.projectRoot -and (Get-ScheduleKey $_.projectRoot) -eq $k }).Count
        $changed = if ($ticks) { -not $known -or $known.ticks -ne $ticks } else { [bool]$hasItems }
        if ($changed) { $null = Import-ProjectSchedules $State $r; $done++ }
    }
    $done
}

function Restore-Schedules {
    <# At start: moves schedules from the old app-wide file (%LOCALAPPDATA%\CCBridge\schedules.json,
       before v0.1.44) into their projects once, then imports every project's schedules. #>
    param($State)
    if (-not $State.ScheduleFile) { return 0 }
    if (Test-Path -LiteralPath $State.ScheduleFile) {
        $saved = try { @(([IO.File]::ReadAllText($State.ScheduleFile)) | ConvertFrom-Json) } catch { Write-CCBLogError agent 'Could not read the schedules' $_; @() }
        $roots = @()
        foreach ($s in $saved) {
            if (-not $s -or -not $s.id -or -not $s.projectRoot) { continue }
            if (-not (Test-Path -LiteralPath "$($s.projectRoot)" -PathType Container)) { continue }
            $h = ConvertTo-ScheduleItem $s "$($s.projectRoot)"
            # Keep a schedule the project file already has (moved before); add the others.
            $existing = @()
            $pf = Get-ProjectScheduleFile $h.projectRoot
            if (Test-Path -LiteralPath $pf) { $j = try { [IO.File]::ReadAllText($pf) | ConvertFrom-Json } catch { $null }; $existing = @(foreach ($o in $j) { $o.id }) }
            if ($existing -contains $h.id) { continue }
            $null = Import-ProjectSchedules $State $h.projectRoot
            [void]$State.Schedules.Add($h)
            $roots += $h.projectRoot
        }
        if ($roots.Count) { Save-Schedules $State -Roots $roots }
        try { [IO.File]::Move($State.ScheduleFile, "$($State.ScheduleFile).moved-to-projects") } catch { Write-CCBLogError agent 'Could not rename the old schedules file' $_ }
        Write-CCBLog info agent 'Schedules moved into their projects' @{ count = $roots.Count }
    }
    $null = Sync-ProjectSchedules $State -Force
    Write-CCBLog info agent 'Schedules restored' @{ count = $State.Schedules.Count; projects = $State.ScheduleRoots.Count }
    $State.Schedules.Count
}

function Update-AgentSchedule {
    <# Changes an existing schedule from the app (what it runs, when, its title); keeps its id,
       project and history. A finished one-time schedule given a new time runs again. #>
    param($State, [Parameter(Mandatory)][string]$Id, [hashtable]$Spec)
    Test-ScheduleSpec $Spec
    $s = @($State.Schedules) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $s) { throw "Unknown schedule '$Id'" }
    $title = if ("$($Spec.title)".Trim()) { "$($Spec.title)".Trim() } elseif ($Spec.kind -eq 'chat') { ("$($Spec.text)" -replace '\s+', ' ').Trim() } else { "$($Spec.kind): $($Spec.name)" }
    if ($title.Length -gt 120) { $title = $title.Substring(0, 117) + '...' }
    $s.title = $title; $s.kind = $Spec.kind; $s.text = "$($Spec.text)"; $s.name = "$($Spec.name)"
    $s.repeat = $Spec.repeat; $s.times = @(Get-ScheduleTimes $Spec); $s.at = "$($Spec.at)"; $s.days = @($Spec.days | ForEach-Object { [int]$_ })
    $next = Get-NextRun $s (Get-Date)
    $s.nextRun = if ($next) { $next.ToString('s') } else { $null }
    if ($s.repeat -eq 'once') { $s.enabled = [bool]$next }
    $s.updated = (Get-Date).ToString('s')
    Save-Schedules $State -Roots @($s.projectRoot)
    Write-CCBLog info agent "Schedule $Id changed" @{ title = $title; repeat = $s.repeat }
    $s
}

function New-AgentSchedule {
    <# Adds a schedule from the app: a message, fetch or runbook, once or repeating. #>
    param($State, [hashtable]$Spec)
    Test-ScheduleSpec $Spec
    if (-not $State.ProjectRoot) { throw 'Open a project first' }
    $title = if ("$($Spec.title)".Trim()) { "$($Spec.title)".Trim() } elseif ($Spec.kind -eq 'chat') { ("$($Spec.text)" -replace '\s+', ' ').Trim() } else { "$($Spec.kind): $($Spec.name)" }
    if ($title.Length -gt 120) { $title = $title.Substring(0, 117) + '...' }
    $s = [hashtable]::Synchronized(@{
        id = 's-' + [guid]::NewGuid().ToString('N').Substring(0, 8); title = $title; kind = $Spec.kind
        text = "$($Spec.text)"; name = "$($Spec.name)"; projectRoot = $State.ProjectRoot
        repeat = $Spec.repeat; times = @(Get-ScheduleTimes $Spec); at = "$($Spec.at)"; days = @($Spec.days | ForEach-Object { [int]$_ })
        enabled = $true; created = (Get-Date).ToString('s'); lastRun = $null; lastQueueId = $null; nextRun = $null })
    $next = Get-NextRun $s (Get-Date)
    $s.nextRun = if ($next) { $next.ToString('s') } else { $null }
    [void]$State.Schedules.Add($s)
    Save-Schedules $State
    Write-CCBLog info agent "Schedule $($s.id) added" @{ kind = $s.kind; repeat = $s.repeat; next = $s.nextRun }
    $s
}

function Start-ScheduledItem {
    <# Puts a schedule's task in the queue now. #>
    param($State, $Schedule, [string]$Note = '')
    $task = switch ($Schedule.kind) {
        'chat' { @{ kind = 'chat'; text = $Schedule.text; projectRoot = $Schedule.projectRoot; source = 'schedule' } }
        default { @{ kind = $Schedule.kind; name = $Schedule.name; projectRoot = $Schedule.projectRoot; source = 'schedule' } }
    }
    $entry = Submit-AgentTask $State $task 'schedule' $Schedule.title
    if ($Note) { $entry.note = $Note }
    $entry
}

function Invoke-DueSchedules {
    <# Puts due schedules in the queue (checked at most every 15 seconds). A run that was missed while
       StreamHub was closed runs once, with a note; repeats then continue from now. #>
    param($State, [datetime]$Now = (Get-Date), [switch]$Force)
    try { $null = Sync-ProjectSchedules $State } catch { Write-CCBLogError agent 'schedule import' $_ }
    if (-not $State.Schedules.Count) { return 0 }
    if (-not $Force -and $State.NextScheduleCheck -and $Now -lt [datetime]$State.NextScheduleCheck) { return 0 }
    $State.NextScheduleCheck = $Now.AddSeconds(15).ToString('s')
    $fired = 0
    foreach ($s in @($State.Schedules)) {
        if (-not $s.enabled -or -not $s.nextRun) { continue }
        $due = ConvertTo-LocalTime "$($s.nextRun)"
        if (-not $due -or $due -gt $Now) { continue }
        $note = if (($Now - $due).TotalMinutes -gt 5) { "Was due at $($due.ToString('yyyy-MM-dd HH:mm')) while StreamHub was closed; runs now." } else { '' }
        try {
            $entry = Start-ScheduledItem $State $s $note
            $s.lastQueueId = $entry.id
            if ($note) { Add-AgentEvent $State 'status' @{ text = "Scheduled '$($s.title)': $note" } }
        } catch { Write-CCBLogError agent "Schedule $($s.id) could not start" $_ }
        $s.lastRun = $Now.ToString('s')
        $next = Get-NextRun $s $Now
        $s.nextRun = if ($next) { $next.ToString('s') } else { $null }
        if ($s.repeat -eq 'once') { $s.enabled = $false }
        $fired++
    }
    if ($fired) { Save-Schedules $State }
    $fired
}

function Get-QueueEntry($State, [string]$Id) {
    foreach ($e in @($State.Queue)) { if ($e.id -eq $Id -or ($e.jobId -and $e.jobId -eq $Id)) { return $e } }
    $null
}

function Complete-QueueEntry($State, $Entry, [int]$FromSeq, [int]$MessagesBefore, [bool]$Cancelled) {
    <# Status and result of a finished task, from the events it produced. #>
    $events = @(Get-AgentEvents $State $FromSeq)
    $err = @($events | Where-Object { $_.type -eq 'error' } | Select-Object -Last 1)
    $done = @($events | Where-Object { $_.type -in 'done', 'fetch', 'runbook', 'review', 'undo', 'newchat' } | Select-Object -Last 1)
    $last = @($events | Where-Object { $_.type -eq 'assistant' } | Select-Object -Last 1)
    $Entry.messages = [int]$State.MessagesSent - $MessagesBefore
    $Entry.finished = (Get-Date).ToString('s')
    $Entry.status = if ($Cancelled) { 'cancelled' } elseif ($err.Count) { 'failed' } else { 'done' }
    if ($err.Count) { $Entry.error = "$($err[0].text)"; $Entry.errId = $err[0].errId }
    $summary = if ($done.Count) { "$($done[0].text)" } elseif ($last.Count) { (("$($last[0].text)" -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)) } else { $null }
    if ($summary -and $summary.Length -gt 300) { $summary = $summary.Substring(0, 297) + '...' }
    $Entry.summary = $summary
    if ($done.Count -and $done[0].path) { $Entry.resultPath = "$($done[0].path)" }
    $changed = @($events | Where-Object { $_.type -eq 'checkpoint' } | ForEach-Object { $_.files }) | Select-Object -Unique
    if ($changed) { $Entry.changed = @($changed) }
}

function Write-PlanResult {
    <# The result of an approved build in PLAN.md: Copilot's summary, the files changed and the
       evidence file. #>
    param($State, [string]$PlanId, [int]$FromSeq)
    try {
        $events = @(Get-AgentEvents $State $FromSeq)
        $done = @($events | Where-Object { $_.type -eq 'done' } | Select-Object -Last 1)
        $files = @($events | Where-Object { $_.type -eq 'checkpoint' } | ForEach-Object { $_.files } | Where-Object { $_ } | Select-Object -Unique)
        $evidence = @($events | Where-Object { $_.type -eq 'status' -and "$($_.text)" -like 'Evidence saved: *' } | Select-Object -Last 1)
        $failed = @($events | Where-Object { $_.type -eq 'error' } | Select-Object -Last 1)
        $body = New-Object System.Collections.Generic.List[string]
        $body.Add($(if ($done.Count) { "$($done[0].text)".Trim() } elseif ($failed.Count) { "Not finished: $($failed[0].text)" } else { 'Copilot did not report the task as done.' }))
        if ($files.Count) { $body.Add(''); $body.Add('Files changed: ' + (($files | ForEach-Object { "``$_``" }) -join ', ')) }
        if ($evidence.Count) { $body.Add(''); $body.Add('Evidence: ' + ("$($evidence[0].text)" -replace '^Evidence saved: ', '')) }
        Add-PlanSection $State.ProjectRoot $PlanId "Result ($((Get-Date).ToString('yyyy-MM-dd HH:mm')))" ($body -join "`n") $(if ($done.Count) { 'done' } else { 'not finished' })
    } catch { Write-CCBLogError agent 'PLAN.md result' $_ }
}

function Publish-PlanReady {
    <# After a plan-first turn: the plan (Copilot's todo list and done summary) for the user to
       approve or change in the app. #>
    param($State, $Task, [int]$FromSeq)
    $events = @(Get-AgentEvents $State $FromSeq)
    $done = @($events | Where-Object { $_.type -eq 'done' } | Select-Object -Last 1)
    $last = @($events | Where-Object { $_.type -eq 'assistant' } | Select-Object -Last 1)
    $todos = @($State.Todos | Where-Object { $_ })
    $steps = if ($todos.Count) { (($todos | ForEach-Object -Begin { $i = 0 } -Process { $i++; "$i. $($_.text)" }) -join "`n") } else { '' }
    $summary = if ($done.Count) { "$($done[0].text)" } elseif ($last.Count) { ("$($last[0].text)" -replace '(?s)```+.*?```+', '').Trim() } else { '' }
    $plan = (@($steps, $summary) | Where-Object { $_ }) -join "`n`n"
    if (-not $plan) { Add-AgentEvent $State 'status' @{ text = 'Copilot did not write a plan. Send the request again, or build without a plan.' }; return }
    $planId = "$($Task.planId)"
    if ($planId) {
        try { Add-PlanSection $State.ProjectRoot $planId "Plan (version $((Get-PlanVersionCount $State.ProjectRoot $planId) + 1))" $plan 'waiting for approval' }
        catch { Write-CCBLogError agent 'PLAN.md' $_ }
    }
    Add-AgentEvent $State 'plan-ready' @{ request = "$($Task.request)"; plan = $plan; planId = $planId }
}

function Invoke-ClarifyStep {
    <# Clarify first: Copilot asks at most 5 questions (as JSON, with likely answers) before any
       work. The app shows them as a form; the answers come back as a plan-first task. With no
       questions it plans right away. #>
    param($State, $Task)
    $request = "$($Task.request)"
    Add-AgentEvent $State 'user' @{ text = $request }
    Add-AgentEvent $State 'kind' @{ taskKind = 'clarify' }
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; return }
    $State.Busy = $true
    try {
        if (Test-OtherSender) { $State.NeedNewChat = $true }
        if ($State.NeedNewChat) { Start-NewChat $State }
        $ctx = Get-ProjectContext $State
        $msg = (Get-PromptPart $State.AppRoot 'role:coding') + "`n`n" + $ctx.Full + "`n`n" + (Get-PromptPart $State.AppRoot 'clarify') + "`n`nRequest: $request"
        $r = Send-ToCopilot $State $msg
        if ($r.Cancelled) { return }
        if ($r.Result -and $r.Result -ne 'Success') { Add-AgentEvent $State 'error' @{ text = "Copilot answered with '$($r.Result)': $($r.ResultMessage)" }; return }
        $questions = @(); $summary = ''
        try {
            $data = (Get-JsonFromReply $r.Text) | ConvertFrom-Json
            $summary = "$($data.summary)".Trim()
            $questions = @($data.questions | Where-Object { $_ -and "$($_.question)".Trim() } | Select-Object -First 5 | ForEach-Object {
                @{ question = "$($_.question)".Trim(); options = @($_.options | Where-Object { "$_".Trim() } | Select-Object -First 4 | ForEach-Object { "$_".Trim() }) } })
        } catch { Write-CCBLog info agent 'Clarify: no readable questions in the reply' }
        # PLAN.md: one section per request, with every decision.
        $planId = "$($Task.planId)"
        try {
            if (-not $planId) { $planId = New-PlanEntry $State.ProjectRoot $request }
            if ($questions.Count) { Add-PlanSection $State.ProjectRoot $planId "Copilot's questions" (Format-PlanQuestions $questions $summary) 'waiting for your answers' }
            else { Add-PlanSection $State.ProjectRoot $planId "Copilot's questions" ("None: the request was clear." + $(if ($summary) { "`n`nCopilot understood: $summary" } else { '' })) 'planning' }
        } catch { Write-CCBLogError agent 'PLAN.md' $_ }
        if ($questions.Count) {
            Add-AgentEvent $State 'clarify' @{ request = $request; questions = $questions; summary = $summary; planId = $planId }
            return
        }
        Add-AgentEvent $State 'status' @{ text = "Copilot has no questions$(if ($summary) { " ($summary)" }); making a plan." }
    } finally { $State.Busy = $false }
    $fromSeq = [int]$State.Seq
    $State.Mode = 'plan'
    Invoke-AgentTurn $State ((Get-PromptPart $State.AppRoot 'plan-first') + "`n`n" + $request) 'coding'
    Publish-PlanReady $State @{ request = $request; planId = $planId } $fromSeq
}

function Get-ProjectVerify([string]$ProjectRoot) {
    <# The project's own check, from a "verify: COMMAND" line in AGENTS.md, or $null. #>
    $f = Join-Path $ProjectRoot 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($f), '(?im)^\s*[-*]?\s*verify\s*:\s*`?([^`\r\n]+?)`?\s*$')
    if ($m.Success -and $m.Groups[1].Value.Trim()) { return $m.Groups[1].Value.Trim() }
    $null
}

function Save-TaskEvidence {
    <# evidence/task-<stamp>.md in the project: what was asked, what changed, which checks ran and
       their results, Copilot's summary. Returns the relative path. #>
    param($State, [string]$Request, $Changes, $Ev, [string]$Done, [int]$Messages)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $rel = "evidence/task-$stamp.md"
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("# Task evidence $((Get-Date).ToString('yyyy-MM-dd HH:mm'))").AppendLine()
    [void]$sb.AppendLine('## Request').AppendLine().AppendLine($Request.Trim()).AppendLine()
    [void]$sb.AppendLine('## Result').AppendLine().AppendLine($(if ($Done) { $Done.Trim() } else { '(Copilot did not report the task as done)' })).AppendLine()
    [void]$sb.AppendLine('## Files changed').AppendLine()
    foreach ($c in @($Changes)) { [void]$sb.AppendLine("- ``$($c.path)`` +$($c.added) -$($c.removed)$(if ($c.created) { ' (new)' } elseif ($c.deleted) { ' (deleted)' })") }
    [void]$sb.AppendLine().AppendLine('## Checks').AppendLine()
    $syn = if ($null -eq $Ev.syntaxLast) { 'not run' } elseif (@($Ev.syntaxLast).Count) { "$(@($Ev.syntaxLast).Count) problem(s) left: " + (@($Ev.syntaxLast) -join '; ') } else { 'passed' }
    [void]$sb.AppendLine("- File checks (syntax and structure per file type): $syn")
    $pg = if ($null -eq $Ev.page) { 'not run' } elseif (@($Ev.page).Count) { "$(@($Ev.page).Count) problem(s): " + (@($Ev.page) -join '; ') } else { 'passed' }
    [void]$sb.AppendLine("- Page check: $pg")
    [void]$sb.AppendLine("- Copilot consistency review: $(if ($Ev.reviewed) { 'done' } else { 'not needed' })")
    $vf = if (-not $Ev.verify) { 'not configured (add a "verify: COMMAND" line to AGENTS.md)' } elseif ($Ev.verify.skipped) { "not run: $($Ev.verify.skipped)" } elseif ($Ev.verify.passed) { "passed (``$($Ev.verify.command)``)" } else { "FAILED (``$($Ev.verify.command)``, exit $($Ev.verify.exit))" }
    [void]$sb.AppendLine("- Verify: $vf")
    if ($Ev.verify -and $Ev.verify.tail) { [void]$sb.AppendLine().AppendLine('Verify output (end):').AppendLine('```').AppendLine($Ev.verify.tail).AppendLine('```') }
    [void]$sb.AppendLine().AppendLine("Copilot messages: $Messages")
    $full = Join-Path $State.ProjectRoot ($rel.Replace('/', '\'))
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
    [IO.File]::WriteAllText($full, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    $rel
}

function Get-ReviewScope {
    <# The files a review covers: the whole project, the changes since the project was opened, or
       chosen files and folders. Returns @{ files; skipped; text }. #>
    param($State, [string]$Scope, [string[]]$Paths)
    switch ($Scope) {
        'changes' {
            $changed = @((Get-SessionChangeStats $State.ProjectRoot ([string]$State.SessionSince)).Keys)
            if (-not $changed.Count) { return @{ files = @(); skipped = @(); text = 'changes since the project was opened' } }
            $sel = Get-ReviewFiles $State.ProjectRoot -Paths $changed
            return @{ files = @($sel.files); skipped = @($sel.skipped); text = 'changes since the project was opened' }
        }
        'paths' {
            $p = @($Paths | Where-Object { "$_".Trim() })
            if (-not $p.Count) { throw 'Name the files or folders to review' }
            $sel = Get-ReviewFiles $State.ProjectRoot -Paths $p
            return @{ files = @($sel.files); skipped = @($sel.skipped); text = ($p -join ', ') }
        }
        default {
            $sel = Get-ReviewFiles $State.ProjectRoot
            return @{ files = @($sel.files); skipped = @($sel.skipped); text = 'whole project' }
        }
    }
}

function Get-ReviewPlan {
    <# What a review would take: files, message batches and Copilot messages (one per batch plus the
       whole-project pass when there is more than one batch). #>
    param($State, [string]$Scope, [string[]]$Paths)
    if (-not $State.ProjectRoot) { throw 'Open or create a project first.' }
    $sc = Get-ReviewScope $State $Scope $Paths
    $budget = if ($State.Config.reviewBatchChars) { [int]$State.Config.reviewBatchChars } else { 40000 }
    $batches = @(if ($sc.files.Count) { New-ReviewBatches $State.ProjectRoot $sc.files $budget })
    @{ files = @($sc.files); skipped = @($sc.skipped); scopeText = $sc.text; batches = $batches.Count; messages = $batches.Count + $(if ($batches.Count -gt 1) { 1 } else { 0 }) }
}

function Invoke-ReviewJob {
    <# A code review in Copilot, read-only: the files go in batches with line numbers, Copilot answers
       each with findings as JSON (one correction round), every finding is checked against the file
       (Test-ReviewQuote), then one whole-project pass. Progress is kept after every batch, so a
       review stopped by Copilot's daily limit (the queue pauses and runs it again) or a restart
       continues where it was. Saves reviews/review-<stamp>.md and .json. #>
    param($State, $Task)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; return }
    $State.Busy = $true; $State.Cancel = $false
    $id = if ($Task.reviewId) { $Task.reviewId } else { 'review-' + (Get-Date).ToString('yyyyMMdd-HHmm') }
    $partial = Join-Path (Get-ProjectStateDir $State.ProjectRoot) "$id.partial.json"
    $enc = New-Object Text.UTF8Encoding($false)
    $focusList = @($Task.focus | Where-Object { $_ })
    $focus = if ($focusList.Count) { $focusList -join ', ' } else { 'bugs, security, performance, structure' }
    try {
        $rv = $null
        if (Test-Path -LiteralPath $partial) {
            $p = [IO.File]::ReadAllText($partial) | ConvertFrom-Json
            $rv = @{ id = $p.id; created = $p.created; scope = $p.scope; scopeText = $p.scopeText; focus = @($p.focus); files = @($p.files); skipped = @($p.skipped)
                messages = [int]$p.messages; done = @($p.done | ForEach-Object { [int]$_ }); summaries = @($p.summaries | ForEach-Object { ConvertTo-PlainHash $_ })
                findings = @($p.findings | ForEach-Object { ConvertTo-PlainHash $_ }); overall = $p.overall }
            Add-AgentEvent $State 'status' @{ text = "Continuing the code review where it stopped ($($rv.done.Count) part(s) done)." }
        } else {
            $sc = Get-ReviewScope $State ([string]$Task.scope) @($Task.paths)
            if (-not $sc.files.Count) { Add-AgentEvent $State 'error' @{ text = "Nothing to review in $($sc.text): no code files found."; code = 'REVIEW'; hint = 'Pick another scope; build output, lock files, data and source/ are never reviewed.' }; return }
            $rv = @{ id = $id; created = (Get-Date).ToString('s'); scope = "$($Task.scope)"; scopeText = $sc.text; focus = @($focus.Split(',') | ForEach-Object { $_.Trim() }); files = @($sc.files); skipped = @($sc.skipped)
                messages = 0; done = @(); summaries = @(); findings = @(); overall = $null }
        }
        $budget = if ($State.Config.reviewBatchChars) { [int]$State.Config.reviewBatchChars } else { 40000 }
        $batches = @(New-ReviewBatches $State.ProjectRoot $rv.files $budget)
        $total = $batches.Count
        $save = { [IO.File]::WriteAllText($partial, (ConvertTo-Json -InputObject $rv -Depth 6 -Compress), $enc) }
        Write-CCBLog info agent "Code review $id" @{ files = $rv.files.Count; batches = $total; done = $rv.done.Count }
        Start-NewChat $State
        $instructions = (Get-PromptPart $State.AppRoot 'review-code').Replace('FOCUS', $focus).Replace('TOTAL', "$total")
        $send = {
            param([string]$Message)
            $r = Send-ToCopilot $State $Message
            $rv.messages = [int]$rv.messages + 1
            if ($r.Cancelled) { return @{ stop = 'cancelled' } }
            if ($r.Result -and $r.Result -ne 'Success') { Add-AgentEvent $State 'error' @{ text = "Copilot answered with '$($r.Result)': $($r.ResultMessage)" }; return @{ stop = 'error' } }
            if (-not "$($r.Text)".Trim()) { Add-AgentEvent $State 'error' @{ text = 'Copilot finished without a reply during the code review.' }; return @{ stop = 'error' } }
            @{ text = $r.Text }
        }
        $ask = {
            # One batch or the whole-project pass: the JSON, with one correction round.
            param([string]$Message)
            $res = & $send $Message
            if ($res.stop) { return $res }
            $out = Test-ReviewOutput (Get-JsonFromReply $res.text)
            if (-not $out.ok) {
                Write-CCBLog info agent 'Review answer is not valid JSON; asking again' @{ errors = $out.errors }
                $res = & $send ("Your reply was not the review JSON: " + ($out.errors -join '; ') + ". Send the findings again as one ``````json code block in the shape described, and nothing else.")
                if ($res.stop) { return $res }
                $out = Test-ReviewOutput (Get-JsonFromReply $res.text)
            }
            @{ out = $out }
        }
        foreach ($b in $batches) {
            if ($rv.done -contains $b.index) { continue }
            if ($State.Cancel) { & $save; Add-AgentEvent $State 'status' @{ text = 'Code review stopped; run it again to continue where it stopped.' }; return }
            if ($State.Throttle.max -and $State.Throttle.used -ge ($State.Throttle.max - 2)) { Start-NewChat $State }
            $names = ($b.files | Select-Object -First 4) -join ', '
            Add-AgentEvent $State 'status' @{ text = "Code review: part $($b.index) of $total ($names$(if (@($b.files).Count -gt 4) { ', ...' }))." }
            $res = & $ask ($instructions.Replace('BATCH', "$($b.index)") + "`n" + $b.text)
            if ($res.stop) { & $save; return }
            if (-not $res.out.ok) {
                $rv.summaries += @{ index = $b.index; files = @($b.files); summary = "(no valid answer from Copilot for this part: $($res.out.errors -join '; '))" }
            } else {
                foreach ($f in $res.out.findings) { $f.part = $b.index; $rv.findings += (Test-ReviewQuote $State.ProjectRoot $f) }
                $rv.summaries += @{ index = $b.index; files = @($b.files); summary = $res.out.summary }
                if ($res.out.dropped) { Write-CCBLog info agent "Review part $($b.index): $($res.out.dropped) finding(s) without a title dropped" }
            }
            $rv.done += $b.index
            & $save
        }
        if ($total -gt 1 -and -not $rv.overall) {
            Add-AgentEvent $State 'status' @{ text = 'Code review: looking across the whole project.' }
            $list = ($rv.summaries | Sort-Object { [int]$_.index } | ForEach-Object { "- Part $($_.index) ($((@($_.files) | Select-Object -First 6) -join ', ')): $($_.summary)" }) -join "`n"
            $res = & $ask ((Get-PromptPart $State.AppRoot 'review-cross') + "Files:`n" + ((@($rv.files) | ForEach-Object { "- $_" }) -join "`n") + "`n`nSummaries:`n$list")
            if ($res.stop) { & $save; return }
            if ($res.out.ok) {
                foreach ($f in $res.out.findings) { $f.part = 0; $rv.findings += (Test-ReviewQuote $State.ProjectRoot $f -AllowGeneral) }
                $rv.overall = $res.out.summary
            }
        } elseif (-not $rv.overall) { $rv.overall = (@($rv.summaries) | Select-Object -First 1).summary }
        # The same finding reported twice (same file, line and title) counts once.
        $seen = @{}
        $unique = foreach ($f in $rv.findings) { $k = "$($f.file)|$($f.line)|$("$($f.title)".ToLowerInvariant())"; if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $f } }
        $rv.findings = @(Get-SortedFindings @($unique))
        $rv.Remove('done')
        $paths = Save-Review $State.ProjectRoot $rv
        [IO.File]::Delete($partial)
        $ok = @($rv.findings | Where-Object { $_.status -ne 'unverified' })
        $counts = "$(@($ok | Where-Object severity -eq 'high').Count) high, $(@($ok | Where-Object severity -eq 'medium').Count) medium, $(@($ok | Where-Object severity -eq 'low').Count) low"
        $unv = @($rv.findings).Count - $ok.Count
        Add-AgentEvent $State 'review' @{ id = $rv.id; path = $paths.md; json = $paths.json; text = "Code review done: $($ok.Count) finding(s) ($counts)$(if ($unv) { "; $unv unverified" }) in $(@($rv.files).Count) file(s), $($rv.messages) Copilot message(s). Report: $($paths.md). Pick findings to fix in the Changes tab." }
        if ($Task.jobId -and $State.Jobs[$Task.jobId]) { $State.Jobs[$Task.jobId].reviewPath = (Resolve-ProjectPath $State.ProjectRoot $paths.json); $State.Jobs[$Task.jobId].reviewReport = $paths.md }
    } catch {
        Write-CCBLogError agent "Code review $id failed" $_
        Add-AgentEvent $State 'error' @{ text = "Code review failed: $($_.Exception.Message)"; record = $_ }
    } finally {
        $State.NeedNewChat = $true
        $State.Busy = $false; $State.Cancel = $false
    }
}

function Invoke-RunbookJob {
    <# Runs a project runbook in a fresh Copilot chat (read-only), takes the JSON from the reply,
       checks it against the runbook header, asks Copilot once to correct it when it does not match,
       and saves a valid result to the runbook's output file (plus a dated copy in History/).
       An existing output file is kept when the run fails. #>
    param($State, [string]$Name)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; return }
    $item = Get-Runbooks $State.ProjectRoot | Where-Object name -eq $Name | Select-Object -First 1
    if (-not $item) { Add-AgentEvent $State 'error' @{ text = "There is no runbook named '$Name'." }; return }
    $State.Busy = $true; $State.Cancel = $false
    try {
        $rb = Read-Runbook ([IO.File]::ReadAllText((Resolve-ProjectPath $State.ProjectRoot $item.path)))
        $body = Resolve-RunbookText $rb.body $rb.meta
        Add-AgentEvent $State 'status' @{ text = "Running runbook '$($item.title)' (read-only) ..." }
        Write-CCBLog info agent "Runbook $Name" @{ chars = $body.Length; output = $item.output }
        Start-NewChat $State   # a runbook never mixes with the conversation
        $message = New-PromptMessage -AppRoot $State.AppRoot -Kind 'runbook' -Text $body -Sent (New-Object 'System.Collections.Generic.HashSet[string]')
        $check = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $r = Send-ToCopilot $State $message
            if ($r.Cancelled) { Add-AgentEvent $State 'status' @{ text = "Runbook '$($item.title)' stopped; $($item.output) was left unchanged." }; return }
            if (($r.Result -and $r.Result -ne 'Success') -or -not "$($r.Text)".Trim()) {
                Add-AgentEvent $State 'error' @{ text = "Runbook '$($item.title)' got no usable answer ($($r.Result): $($r.ResultMessage)); $($item.output) was left unchanged." }
                return
            }
            $json = Get-JsonFromReply $r.Text
            $check = Test-RunbookOutput $json $rb.meta
            if ($check.ok) { break }
            Write-CCBLog info agent "Runbook $Name output does not match (attempt $attempt)" @{ errors = $check.errors }
            if ($attempt -eq 1) {
                Add-AgentEvent $State 'status' @{ text = "The JSON did not match the runbook ($(@($check.errors).Count) problem(s)); asking Copilot to correct it." }
                $message = "The JSON does not match the runbook:`n- " + (@($check.errors) -join "`n- ") + "`nSend the complete corrected JSON again, in exactly the shape the runbook describes, as one ```json code block and nothing else."
            }
        }
        if (-not $check.ok) {
            Add-AgentEvent $State 'error' @{ text = "Runbook '$($item.title)': Copilot's JSON still does not match the runbook ($(@($check.errors) -join '; ')). $($item.output) was left unchanged."; code = 'RUNBOOK'; hint = 'Make the runbook''s output section and example clearer, or loosen required / requiredItemFields in its header, then run it again.' }
            return
        }
        $saved = Save-RunbookOutput $State.ProjectRoot $Name $item.output $json
        $note = if ($check.truncated) { ' Copilot marked it as truncated: not every item fitted. Narrow the period or the sources.' } else { '' }
        Add-AgentEvent $State 'runbook' @{ name = $Name; path = $saved.output; text = "Runbook '$($item.title)': saved $($check.count) item(s) to $($saved.output) (copy in $($saved.history)).$note Attach it with @$($saved.output)." }
    } catch {
        Write-CCBLogError agent "Runbook $Name failed" $_
        Add-AgentEvent $State 'error' @{ text = "Runbook '$Name' failed: $($_.Exception.Message)"; record = $_ }
    } finally {
        $State.NeedNewChat = $true
        $State.Busy = $false; $State.Cancel = $false
    }
}

function Invoke-FetchJob {
    <# Runs a saved fetch prompt in a fresh Copilot chat and writes the answer to Runbooks/Exports/<name>.md.
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
    param($State, [string]$Text, $Context = @{ Traits = @(); Paths = @() }, [string]$Force = '')
    $kind = Get-TaskKind $Text -Traits @($Context.Traits) -Paths @($Context.Paths)
    # Forced: "Send again as a coding task" (coding), or a task from another program (work: never plain chat).
    if ($Force -eq 'coding') { $kind = $(if ($kind -eq 'mixed' -or $kind -eq 'assistant') { 'mixed' } else { 'coding' }) }
    elseif ($Force -eq 'work' -and $kind -in 'chat', 'project') { $kind = 'coding' }
    if ($kind -eq 'chat' -and $State.ChatKind) { $kind = $State.ChatKind }
    if ($kind -in 'coding', 'project', 'mixed' -and $State.SentParts.Contains('actions')) {
        $State.FollowUps = [int]$State.FollowUps + 1
        $why = if ($State.LastTurnActed -eq $false) { 'the previous turn had no actions' } elseif ($State.FollowUps -ge 5) { "$($State.FollowUps) follow-ups since the instructions" } else { $null }
        if ($why) {
            Write-CCBLog info agent "Sending the full instructions again ($why)"
            foreach ($p in @($State.SentParts)) { if ($p -in 'actions', 'rules', 'role:coding', 'role:project' -or $p -like 'rules:*' -or $p -like 'actions:*') { [void]$State.SentParts.Remove($p) } }
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
    $ctx = if ($State.ProjectRoot) { try { Get-ProjectContext $State } catch { @{ Traits = @() } } } else { @{ Traits = @() } }
    $modules = @(Get-PromptModules $Task $ctx)
    $ids = @('actions') + @($modules | Where-Object { $_ -like 'actions:*' }) + @('rules') + @($modules | Where-Object { $_ -like 'rules:*' })
    $parts = @($ids | ForEach-Object { Get-PromptPart $State.AppRoot $_ }) + @(Get-PromptPart $State.AppRoot 'retry')
    foreach ($p in $ids) { [void]$State.SentParts.Add($p) }
    ($parts -join "`n`n") + "`n`nTask: $Task"
}

function Register-StepFailure {
    <# Counts how often the same step failed the same way in one message (same action, path and
       error, line numbers ignored). Returns the count. #>
    param([hashtable]$Seen, $Action, [string]$Output)
    $first = ("$Output".Split("`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    $key = "$($Action.type)|$($Action.arg)|" + ("$first" -replace '\d+', '#')
    $Seen[$key] = 1 + [int]$Seen[$key]
    $Seen[$key]
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

function Test-ScriptSyntax {
    <# Compiles changed JavaScript files in a spare Edge tab (compile only: nothing runs) and returns
       one line per syntax error. Module syntax is turned into classic script first
       (ConvertTo-CheckableScript); errors about import/export are left out, as the check cannot
       tell those apart from what it changed. #>
    param($State, [string[]]$Paths)
    $files = @($Paths | Where-Object { $_ -match '(?i)\.(m?js|cjs)$' } | Select-Object -First 10)
    if (-not $files.Count -or -not $State.Config.cdpPort) { return }
    $cdpPort = $State.Config.cdpPort
    $target = $null; $s = $null
    try {
        $target = Invoke-RestMethod -Method Put "http://127.0.0.1:$cdpPort/json/new?about:blank"
        $s = Connect-Cdp $target.webSocketDebuggerUrl
        $null = Invoke-Cdp $s 'Runtime.enable'
        foreach ($rel in $files) {
            $full = try { Resolve-ProjectPath $State.ProjectRoot $rel } catch { $null }
            if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $src = (Read-TextFile $full).Text
            if ($src.Length -gt 1000000) { continue }
            $r = Invoke-Cdp $s 'Runtime.compileScript' @{ expression = (ConvertTo-CheckableScript $src); sourceURL = $rel; persistScript = $false }
            $d = $r.exceptionDetails
            if (-not $d) { continue }
            $msg = if ($d.exception.description) { ($d.exception.description -split "`n")[0] } else { "$($d.text)" }
            if ($msg -match '\b(import|export)\b') { continue }
            "${rel}:$([int]$d.lineNumber + 1): JavaScript syntax error: $msg"
        }
        Write-CCBLog info agent 'Script syntax check' @{ files = $files.Count }
    } catch {
        Write-CCBLogError agent 'Script syntax check failed' $_
    } finally {
        if ($s) { try { Disconnect-Cdp $s } catch { } }
        if ($target) { try { $null = Invoke-RestMethod "http://127.0.0.1:$cdpPort/json/close/$($target.id)" } catch { } }
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
    $paths = @(Get-ProjectFiles $root | ForEach-Object { $_.path })
    $files = if ($paths.Count) { "Files:`n" + (Format-ProjectTree $root -MaxChars $budget) } else { 'The folder is empty.' }
    $notes = Get-ProjectNotes $root
    $full = "$location`n$files" + $(if ($notes) { "`n`nProject notes (AGENTS.md):`n$notes" } else { '' })
    $traits = @(Get-ProjectTraits $paths)
    if ($State.NoCommands -or ($State.Headless -and -not $State.AllowCommands)) { $traits += 'nocommands' }
    @{ Location = $location; Full = $full; Traits = $traits; Paths = $paths }
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
    param($State, [string]$Id, [bool]$PersonOnly = $false)
    $entry = if ($State.CurrentQueueId) { Get-QueueEntry $State $State.CurrentQueueId } else { $null }
    if ($entry) { $entry.status = 'awaiting'; Save-AgentQueue $State }
    try {
        while (-not $State.Cancel -and -not $State.Stop) {
            if ($State.Approvals.ContainsKey($Id)) {
                $d = $State.Approvals[$Id]; $State.Approvals.Remove($Id)
                # Microsoft 365 actions and deleting data: only a person in the app may approve them.
                if ($PersonOnly -and $d.decision -eq 'approve' -and $d.by -ne 'user') {
                    Write-CCBLog info agent "Approval of $Id by $($d.by) refused: needs a person in the app"
                    return @{ decision = 'reject'; note = 'This needs a person: approve it in the StreamHub window, not from another program.'; by = $d.by }
                }
                return $d
            }
            Start-Sleep -Milliseconds 150
        }
        @{ decision = 'reject'; note = 'cancelled' }
    } finally { if ($entry -and $entry.status -eq 'awaiting') { $entry.status = 'running'; Save-AgentQueue $State } }
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
            $out = (Invoke-ReadAction $root $paths -MaxCharsPerFile 200000) -join "`n`n"
            $usedBy = try { Format-ImportUsers $root $paths } catch { '' }   # who imports it or uses its ids, functions, hooks
            if ($usedBy) { $out += "`n`n$usedBy" }
            return @{ ok = $true; summary = "read $($paths.Count) file(s)"; output = $out; readPaths = @($paths) }
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
        'find' {
            $name = if ($Action.arg) { $Action.arg } else { "$($Action.body)".Split("`n")[0].Trim() }
            $evt.target = $name; Add-AgentEvent $State 'action' $evt
            return @{ ok = $true; summary = "found $name"; output = (Find-SymbolDefinition $root $name) }
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
    $personOnly = $false   # Microsoft 365 commands and deletions: only a person in the app may approve
    if ($Action.type -eq 'remember') {
        # A lasting project note: added to AGENTS.md (## Learned) only after approval, also in auto mode.
        $body = if ("$($Action.body)".Trim()) { $Action.body } else { $Action.arg }
        if (-not "$body".Trim()) { return @{ ok = $false; summary = 'remember without text'; output = 'error: put the fact to remember inside the block' } }
        $notesPath = Join-Path $root 'AGENTS.md'
        $oldNotes = if (Test-Path -LiteralPath $notesPath) { (Read-TextFile $notesPath).Text } else { '' }
        $Action | Add-Member -NotePropertyName newNotes -NotePropertyValue (Get-LearnedNotes $oldNotes $body) -Force
        $evt.target = 'AGENTS.md'
        $preview = @{ path = 'AGENTS.md'; exists = [bool]$oldNotes; old = (Get-PreviewText $oldNotes); new = (Get-PreviewText $Action.newNotes) }
        $needsApproval = $true
        $riskWarning = 'Copilot wants to add this to the project notes (AGENTS.md), which go with every new chat. Approve only if it is right and lasting.'
    }
    elseif ($Action.type -eq 'write' -or $Action.type -eq 'edit') {
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
        $newText = if ($Action.type -eq 'write') { $content } else { $er.new }
        $oldText = if ($Action.type -eq 'write') { "$($p.old)" } else { "$($er.old)" }
        # The file's encoding must be able to hold the new text (batch files ASCII, ANSI files their
        # code page, no garbled replacement characters).
        $targetFull = Resolve-ProjectPath $root $Action.arg
        $encName = if (Test-Path -LiteralPath $targetFull -PathType Leaf) { (Read-TextFile $targetFull).Encoding } else { 'utf8' }
        $misfit = Test-EncodingFit $Action.arg $oldText $newText $encName
        if ($misfit) {
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = "encoding: $misfit" })
            return @{ ok = $false; summary = "$($Action.type) $($Action.arg) refused (encoding)"; output = "error: not written: $misfit." }
        }
        # What Copilot's text brought along: invisible characters are removed on writing (reported),
        # curly quotes and long dashes in code are pointed out for Copilot to check.
        $art = Find-CodeArtifacts $Action.arg $(if ($Action.type -eq 'write') { $content } else { (@($Action.edits) | ForEach-Object { $_.replace }) -join "`n" })
        $artNote = @()
        if ($art.removed) { $artNote += "removed $($art.removed) invisible or non-breaking space character(s) that came with the text" }
        if (@($art.curlyLines).Count) { $artNote += "note: curly quotes or long dashes in the new text ($(if ($Action.type -eq 'write') { 'lines ' + ((@($art.curlyLines) | Select-Object -First 8) -join ', ') } else { 'in the REPLACE text' })); in code use straight quotes ' "" and -" }
        # Leftover edit or merge markers are always damage (a malformed edit): refuse.
        if ($Action.arg -notmatch '(?i)\.(md|markdown|txt)$') {
            $mk = [regex]::Match("$newText", '(?m)^(<{7}( SEARCH|\s.*)?|>{7}( REPLACE|\s.*)?|={7})\s*$')
            if ($mk.Success -and "$oldText" -notmatch "(?m)^$([regex]::Escape($mk.Value.TrimEnd()))\s*$") {
                $mline = ([regex]::Matches($newText.Substring(0, $mk.Index), "`n")).Count + 1
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = "leftover marker at line $mline" })
                return @{ ok = $false; summary = "$($Action.type) $($Action.arg) refused (leftover marker)"; output = "error: not written: line $mline of the new text is '$($mk.Value.Trim())', an edit or merge marker that must not end up in the file. Send the change again with only the real lines." }
            }
        }
        # Secrets (keys, tokens, passwords) the change adds: a person approves them, also in auto mode.
        $oldSecrets = @{}; foreach ($s in @(Find-Secrets $oldText)) { $k = $s -replace '^line \d+: ', ''; $oldSecrets[$k] = 1 + [int]$oldSecrets[$k] }
        $newSecrets = @(foreach ($s in @(Find-Secrets $newText)) { $k = $s -replace '^line \d+: ', ''; if ($oldSecrets[$k]) { $oldSecrets[$k]-- } else { $s } })
        if ($newSecrets.Count) {
            $riskWarning = "This change adds what looks like a secret ($(($newSecrets | Select-Object -First 3) -join '; ')). Secrets in project files end up in OneDrive and in any copy of the project; prefer a setting or environment variable. Approve only if it is meant."
        }
        # Code left out with a placeholder ("// rest of the code unchanged") would be lost: refuse.
        $ph = Find-PlaceholderLine $oldText $newText
        if ($ph) {
            $how = if ($Action.type -eq 'write') { 'A write block replaces the whole file, so the code that line stands for would be lost. Send the complete file, or use edit blocks for only the parts that change.' } else { 'The REPLACE text replaces the SEARCH lines completely, so the code that line stands for would be lost. Put the real lines in REPLACE, or make the SEARCH smaller so it covers only what changes.' }
            Write-CCBLog info agent "Placeholder line refused in $($Action.arg)" @{ line = $ph.line }
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = "left-out code: line $($ph.line) '$($ph.text)'" })
            return @{ ok = $false; summary = "$($Action.type) $($Action.arg) refused (left-out code)"; output = "error: not written: line $($ph.line) of the new text, '$($ph.text)', stands for code that was left out. $how" }
        }
        # A write that makes an existing file much shorter needs a person, also in auto mode.
        if (-not $riskWarning -and $Action.type -eq 'write' -and $oldText.Length -gt 3000 -and $newText.Length -lt $oldText.Length * 0.4) {
            $oldLines = $oldText.Split("`n").Length; $newLines = "$newText".Split("`n").Length
            $riskWarning = "This write makes $($Action.arg) much shorter ($oldLines -> $newLines lines). If Copilot left code out, it would be lost. Approve only if that is what you want."
        }
        # Runbooks have a fixed place, name and header: refuse a file that breaks them.
        $rbProblems = @(Test-RunbookFile $Action.arg $newText ("$($State.TurnText)" -match '(?i)\b(runbooks?|draaiboek(en)?)\b'))
        if ($rbProblems.Count) {
            $why = $rbProblems -join '; '
            Write-CCBLog info agent "Runbook file refused: $($Action.arg)" @{ problems = $rbProblems }
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = "runbook: $why" })
            return @{ ok = $false; summary = "$($Action.type) $($Action.arg) refused (runbook rules)"; output = "error: not written: $why. A runbook is one file Runbooks/NAME.runbook.md that starts with the template's header block; send the complete file again with a write block." }
        }
        $needsApproval = ($mode -ne 'auto') -or ($Uncertain -gt 0) -or [bool]$riskWarning
    } elseif ($Action.type -eq 'run') {
        $evt.target = $Action.body.Trim()
        # Hard boundary: deleting or moving files only inside the project. Not even a person can
        # approve past it.
        $outside = Test-DeleteScope $State.ProjectRoot $evt.target
        if ($outside) {
            Write-CCBLog info agent 'Command refused: deletes or moves outside the project' @{ reason = $outside }
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = "refused: $outside" })
            return @{ ok = $false; summary = 'run refused (outside the project)'; output = "not executed: $outside. Files may only be deleted or moved inside the project folder. Name each file or folder as a plain path inside the project (relative to it), without .., variables, or changing folders first." }
        }
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
            $personOnly = $true
        }
    }

    if ($Action.type -eq 'run' -and $State.NoCommands -and $mode -ne 'plan') {
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped' })
        return @{ ok = $false; summary = 'run skipped (commands not allowed)'; output = 'not executed: commands are not allowed for this task. Finish without running commands, and state which command the user should run to verify.' }
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
        $d = Wait-Approval $State $Id $personOnly
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
            'write' {
                $out = Invoke-WriteAction $root $Action.arg $Action.body $Checkpoint
                if (@($artNote).Count) { $out += '; ' + ($artNote -join '; ') }
                return @{ ok = $true; summary = $out; output = $out; changed = $true; path = $Action.arg }
            }
            'remember' { $null = Invoke-WriteAction $root 'AGENTS.md' $Action.newNotes $Checkpoint; return @{ ok = $true; summary = 'added to the project notes (AGENTS.md)'; output = 'saved to the project notes (AGENTS.md, ## Learned)'; changed = $true; path = 'AGENTS.md' } }
            'edit'  {
                $before = try { (Read-TextFile (Resolve-ProjectPath $root $Action.arg)).Text } catch { '' }
                $out = Invoke-EditAction $root $Action.arg $Action.edits $Checkpoint
                if (@($artNote).Count) { $out += '; ' + ($artNote -join '; ') }
                # The changed lines as they are now, so the next edit starts from the current text.
                $view = try { $now = (Read-TextFile (Resolve-ProjectPath $root $Action.arg)).Text; Get-ChangedView $before $now (Resolve-ProjectPath $root $Action.arg) $Action.arg } catch { '' }
                return @{ ok = $true; summary = $out; output = $(if ($view) { "$out`n$view" } else { $out }); changed = $true; path = $Action.arg }
            }
            'run'   {
                # What the command changes joins this step's change set, so Undo restores it.
                $snap = if ($Checkpoint) { try { Start-RunSnapshot $Checkpoint $root } catch { Write-CCBLogError agent 'run snapshot' $_; $null } }
                $r = Invoke-RunAction $root $evt.target -TimeoutSec $State.Config.commandTimeoutSec -CancelCheck ({ [bool]$State.Cancel }.GetNewClosure())
                $status = if ($r.cancelled) { 'stopped by the user' } elseif ($r.timedOut) { "timed out after $($State.Config.commandTimeoutSec)s" } else { "exit code $($r.exitCode)" }
                $out = "$status`n~~~~`n$($r.output)`n~~~~"
                $runChanged = @()
                if ($snap) {
                    try {
                        $done = Complete-RunSnapshot $Checkpoint $root $snap
                        $runChanged = @($done.changed)
                        if (@($done.notBackedUp).Count) { Add-AgentEvent $State 'status' @{ text = "This command changed files too large to back up, so Undo cannot restore them: $(@($done.notBackedUp) -join ', ')" } }
                    } catch { Write-CCBLogError agent 'run snapshot' $_ }
                }
                $fixed = @(Restore-SourceData $root)
                if ($fixed.Count) {
                    Add-AgentEvent $State 'status' @{ text = "Source data is read-only; StreamHub undid what the command did to it: " + ($fixed -join '; ') }
                    $out += "`nNote: source/ is the user's read-only source data. This command changed it, so it was put back: " + ($fixed -join '; ') + '. Work on copies outside source/.'
                }
                if ($runChanged.Count) { $out += "`nFiles this command changed: " + ($runChanged -join ', ') }
                return @{ ok = (-not $r.timedOut -and -not $r.cancelled -and $r.exitCode -eq 0); summary = "ran: $status"; output = $out; changed = [bool]$runChanged.Count }
            }
        }
    } catch {
        return @{ ok = $false; summary = "$($Action.type) failed"; output = "error: $($_.Exception.Message)" }
    }
}

# --- One user turn -------------------------------------------------------------------

# --- Issue cycle: index, change, scan the changed files, fix in cycles, scan again -------------

function Get-IssueSettings($State) {
    <# harness.json "issues": enabled (on/off), autoFix (categories fixed without asking: error,
       secret, health), maxAttempts (fix tasks per file before 'gave up'). #>
    $c = $State.Config.issues
    @{ enabled = "$($c.enabled)" -ne 'off'
       autoFix = @(if ($c -and $null -ne $c.autoFix) { @("$(@($c.autoFix) -join ',')".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'none' }) } else { 'error' })
       maxAttempts = $(if ($c -and [int]$c.maxAttempts -gt 0) { [int]$c.maxAttempts } else { 2 }) }
}

function Get-IssueBaseline($State) {
    <# Step 1: the index is current before a change; returns the ids of the issues already there
       (only issues a change adds are fixed automatically). $null when issues are off or failed. #>
    if (-not (Get-IssueSettings $State).enabled -or -not $State.ProjectRoot) { return $null }
    $State.Activity.label = 'Indexing the project for issues before the change'
    try {
        $null = Update-IssueIndex $State.ProjectRoot -Progress $State.Activity
        $ids = @{}
        foreach ($i in @(Get-IssueReport $State.ProjectRoot)) { $ids[$i.id] = $true }
        $ids
    } catch { Write-CCBLogError agent 'issue baseline' $_; $null } finally { $State.Activity.label = '' }
}

function Get-QueuedIssueFix($State, [string]$ProjectRoot, [string]$Path) {
    # A fix task for this file that is still waiting in the queue (not the one running now).
    @($State.Queue) | Where-Object { $_.source -eq 'issues' -and $_.status -eq 'queued' -and $_.task -and $_.task.issueFix -and
        "$($_.task.issueFix.path)" -eq $Path -and "$($_.projectRoot)".TrimEnd('\') -eq $ProjectRoot.TrimEnd('\') } | Select-Object -First 1
}

function Submit-IssueFix {
    <# Queues one fix task for one file's issues (a coding turn in the current chat). Returns $null
       when it may not: past issues.maxAttempts, or a fix for that file is already waiting (that
       task scans the whole file afterwards, so it covers these issues too). #>
    param($State, [string]$Path, $Issues, [int]$Attempt, $Categories, [string]$ProjectRoot)
    $root = if ($ProjectRoot) { $ProjectRoot } else { $State.ProjectRoot }
    if ($Attempt -lt 1 -or $Attempt -gt (Get-IssueSettings $State).maxAttempts) { return $null }
    if (Get-QueuedIssueFix $State $root $Path) { return $null }
    $ids = @($Issues | ForEach-Object { $_.id })
    Set-IssueState $root $ids 'fixing' -Attempts $Attempt
    $task = @{ kind = 'chat'; text = (New-FixMessage $Path @($Issues) $Attempt); forceKind = 'coding'; projectRoot = $root
        issueFix = @{ path = $Path; ids = $ids; attempt = $Attempt; categories = @($Categories) } }
    Submit-AgentTask $State $task 'issues' "Fix $(@($ids).Count) issue(s) in $Path$(if ($Attempt -gt 1) { " (attempt $Attempt)" })"
}

function Invoke-IssueCycle {
    <# Steps 3 to 6: scans the files a turn changed; queues a fix task per file for issues the
       change added (categories in issues.autoFix); after a fix task checks that file again:
       gone = fixed, still there = another attempt (up to issues.maxAttempts), then 'gave up'.
       Returns the notes it showed. #>
    param($State, [string[]]$Paths, $Baseline, $Fix)
    $cfg = Get-IssueSettings $State
    if (-not $cfg.enabled -or $null -eq $Baseline) { return }
    $root = $State.ProjectRoot
    $list = @($Paths | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') } | Select-Object -Unique)
    $State.Activity.label = "Scanning $($list.Count) changed file(s) for issues"
    try { $null = Update-IssueIndex $root -Paths $list -Progress $State.Activity } finally { $State.Activity.label = '' }
    $changed = @{}; foreach ($p in $list) { $changed[$p] = $true }
    $report = @(Get-IssueReport $root | Where-Object { $changed.ContainsKey($_.path) -and $_.status -ne 'ignored' })
    $notes = New-Object System.Collections.Generic.List[string]
    if ($Fix) {
        $State.IssueFixHandled = $true
        $cats = @($Fix.categories)
        $left = @($report | Where-Object { $_.path -eq $Fix.path -and $_.category -in $cats -and $_.status -ne 'gave up' })
        $leftIds = @($left | ForEach-Object { $_.id })
        $gone = @(@($Fix.ids) | Where-Object { $_ -notin $leftIds }).Count
        if (-not $left.Count) { $notes.Add("Issue fix: $($Fix.path) is clean again ($gone problem(s) fixed).") }
        elseif ([int]$Fix.attempt -lt $cfg.maxAttempts) {
            $next = Submit-IssueFix $State $Fix.path $left ([int]$Fix.attempt + 1) $cats $root
            if ($next) { $notes.Add("Issue fix: $($left.Count) problem(s) left in $($Fix.path); trying again (attempt $([int]$Fix.attempt + 1) of $($cfg.maxAttempts)).") }
            else { $notes.Add("Issue fix: $($left.Count) problem(s) left in $($Fix.path); a fix for that file is already waiting in the queue.") }
        } else {
            Set-IssueState $root $leftIds 'gave up' -Attempts ([int]$Fix.attempt) -Note "still there after $($Fix.attempt) attempt(s)"
            $notes.Add("Issue fix: $($left.Count) problem(s) in $($Fix.path) are still there after $($Fix.attempt) attempt(s); marked 'gave up'. They are listed under Issues in the Changes tab.")
        }
    }
    $new = @($report | Where-Object { -not $Baseline.ContainsKey($_.id) -and $_.status -eq 'open' -and (-not $Fix -or $_.path -ne $Fix.path) })
    # No chains: problems a fix task causes in other files are only reported. Otherwise fixing A
    # could break B, fixing B break A, and so on, each starting again at attempt 1.
    $auto = if ($Fix) { @() } else { @($new | Where-Object { $_.category -in $cfg.autoFix }) }
    $groups = @($auto | Group-Object path | Where-Object { Submit-IssueFix $State $_.Name @($_.Group) 1 $cfg.autoFix $root })
    if ($new.Count) {
        $files = @($new | Group-Object path).Count
        $reported = $new.Count - @($groups | ForEach-Object { $_.Group }).Count
        $notes.Add("Issue scan: $($new.Count) new problem(s) in $files $(if ($Fix) { 'other ' })changed file(s)$(if ($groups.Count) { "; queued a fix for $($groups.Count) file(s)" })$(if ($reported) { "; $reported only reported (Issues in the Changes tab)" }).")
    } elseif (-not $Fix) { $notes.Add("Issue scan: no new problems in the $($list.Count) changed file(s).") }
    foreach ($n in $notes) { Add-AgentEvent $State 'status' @{ text = $n; issues = $true } }
    @($notes)
}

function Reset-StaleIssueFixes {
    <# Issues marked 'fixing' without a fix task waiting or running for their file go back to
       'open' (the task was stopped, failed, or lost in a restart). Nothing is retried by this.
       Returns how many were reset. #>
    param($State, [string]$ProjectRoot)
    if (-not $ProjectRoot -or -not (Test-Path -LiteralPath (Get-IssueIndexPath $ProjectRoot))) { return 0 }
    $active = @{}
    foreach ($e in @($State.Queue)) {
        if ($e.source -eq 'issues' -and $e.status -in 'queued', 'running' -and $e.task -and $e.task.issueFix) { $active["$($e.task.issueFix.path)"] = $true }
    }
    if ($State.IssueFix) { $active["$($State.IssueFix.path)"] = $true }
    $stale = @(Get-IssueReport $ProjectRoot | Where-Object { $_.status -eq 'fixing' -and -not $active.ContainsKey($_.path) } | ForEach-Object { $_.id })
    if ($stale.Count) { Set-IssueState $ProjectRoot $stale 'open' -Note 'the fix task did not finish' }
    $stale.Count
}

$script:Indexer = $null
function Start-IssueIndexer {
    <# A full index run in the background (project opened, app started, Re-index), so the app
       stays usable. One at a time; $State.Indexing has the progress. Returns $true if started. #>
    param($State, [string]$ProjectRoot, [switch]$Force)
    if (-not (Get-IssueSettings $State).enabled -or -not $ProjectRoot -or $State.Indexing.running) { return $false }
    if ($script:Indexer) { try { $script:Indexer.Dispose() } catch { } }
    $ix = $State.Indexing
    $ix.running = $true; $ix.label = "Indexing $(Split-Path $ProjectRoot -Leaf) for issues"; $ix.done = 0; $ix.total = 0; $ix.current = ''; $ix.project = $ProjectRoot; $ix.error = $null
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($Lib, $Root, $Progress, $Force)
        try {
            Import-Module (Join-Path $Lib 'Issues.psm1')
            $r = Update-IssueIndex $Root -Progress $Progress -Force:$Force
            $Progress.last = @{ project = $Root; files = $r.files; scanned = $r.scanned; ms = $r.ms; at = (Get-Date).ToString('s') }
        } catch { $Progress.error = $_.Exception.Message } finally { $Progress.label = ''; $Progress.running = $false }
    }).AddArgument($PSScriptRoot).AddArgument($ProjectRoot).AddArgument($ix).AddArgument([bool]$Force)
    $null = $ps.BeginInvoke()
    $script:Indexer = $ps
    Write-CCBLog info agent 'Issue index started' @{ project = $ProjectRoot; force = [bool]$Force }
    $true
}

function Invoke-AgentTurn {
    param($State, [string]$Text, [string]$ForceKind = '')
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; $State.Busy = $false; return }
    $State.Busy = $true; $State.Cancel = $false
    $turnWatch = [Diagnostics.Stopwatch]::StartNew()
    Write-CCBLog info agent "Turn started" @{ chars = $Text.Length; mode = $State.Mode; headless = [bool]$State.Headless; allowCommands = [bool]$State.AllowCommands; workIq = $State.WorkIq; chatStarted = [bool]$State.ChatStarted }
    Write-CCBLog trace agent 'User message' @{ text = $Text }
    Add-AgentEvent $State 'user' @{ text = $Text }
    $State.TurnText = $Text
    $checkpoint = New-Checkpoint $State.ProjectRoot $Text
    $baseline = $null
    try { Sync-SourceVault $State.ProjectRoot } catch { Add-AgentEvent $State 'error' @{ text = "Could not back up source data: $($_.Exception.Message)" } }
    try {
        if (Test-OtherSender) { $State.NeedNewChat = $true }
        if ($State.NeedNewChat) { Start-NewChat $State }
        # As little as the request needs: plain chat goes as it is; other kinds add only the parts
        # (role, actions, rules, project context) this chat has not had yet.
        $ctx = Get-ProjectContext $State
        $kind = Get-TurnKind $State $Text $ctx $ForceKind
        # Issue cycle step 1: index before the change (not for plain chat or plan mode).
        if ($kind -ne 'chat' -and $State.Mode -ne 'plan') { $baseline = Get-IssueBaseline $State }
        if ($kind -ne 'chat' -and $State.ProjectRoot) {
            $State.Activity.label = 'Updating the import index'
            try { $null = Update-ImportIndex $State.ProjectRoot } catch { Write-CCBLogError agent 'import index' $_ } finally { $State.Activity.label = '' }
        }
        # The app shows how a message was sent, with "Send again as a coding task" for plain chat.
        Add-AgentEvent $State 'kind' @{ taskKind = $kind }
        $summary = $State.Summary; $State.Summary = $null
        $partsBefore = $State.SentParts.Count
        $message = New-PromptMessage -AppRoot $State.AppRoot -Kind $kind -Text $Text -Sent $State.SentParts -Context $ctx -Summary $summary
        if ($State.SentParts.Count -gt $partsBefore -and $State.SentParts.Contains('actions')) { $State.FollowUps = 0 }
        if ($kind -ne 'chat') { $State.ChatKind = $kind }
        Write-CCBLog info agent "Task kind: $kind" @{ partsAdded = $State.SentParts.Count - $partsBefore; chars = $message.Length }
        $State.LastTurnActed = $null
        $message += Get-PinnedFiles $State.ProjectRoot $Text

        $nudges = 0   # times this message was sent again because Copilot explained instead of acting
        $failSeen = @{}; $stopLoop = $false   # the same step failing the same way: warn at 2, stop at 3
        $syntaxNudges = 0   # times "done" was refused because a changed file has a syntax error
        $verifyNudges = 0   # times "done" was refused because the project's verify command failed
        $ev = @{ syntaxLast = $null; page = $null; reviewed = $false; verify = $null }   # for the evidence file
        $msgStart = [int]$State.MessagesSent
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
                if ($a.type -in 'write', 'edit', 'run' -and -not $a.closed -and $k -eq $actions.Count - 1) {
                    # The reply ended inside this block (no closing fence): it may be cut off. Applying
                    # half a file or half a command could do damage, so it waits for the full block.
                    Write-CCBLog info agent "Unclosed last block not applied: $($a.type) $($a.arg)"
                    Add-AgentEvent $State 'action' @{ id = $id; action = $a.type; target = $(if ($a.arg) { $a.arg } else { $a.body.Split("`n")[0] }); status = 'skipped'; error = 'the reply ended inside this block (it may be cut off)' }
                    $results.Add(@{ head = "### $($k + 1). $($a.type) $($a.arg)".TrimEnd(); output = "not applied: your reply ended inside this $($a.type) block (no closing fence), so it may be cut off. Send this block again, complete, with its closing fence." })
                    continue
                }
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
                $out = "$($res.output)"
                if (-not $res.ok -and $a.type -in 'edit', 'write', 'run') {
                    $times = Register-StepFailure $failSeen $a $out
                    if ($times -eq 2) {
                        $out += "`nThis is the second time this exact step failed in the same way. Do not send it again unchanged: read the lines it is about first and send a corrected step$(if ($a.type -eq 'edit') { ', or replace the whole file with a write block' })."
                    } elseif ($times -ge 3) {
                        $stopLoop = $true
                        Add-AgentEvent $State 'error' @{ text = "The same $($a.type) of $($a.arg) failed $times times in a row with: $(("$($res.output)" -split "`n")[0] -replace '^error:\s*', ''). Stopped this message so it does not loop."; code = 'STEP-LOOP'; hint = 'Ask Copilot to rewrite the whole file with a write block, or make this change by hand; then continue.' }
                    }
                }
                $results.Add(@{ head = "### $($k + 1). $($a.type) $($a.arg)".TrimEnd(); output = $out; readPaths = $res.readPaths; changedPath = $(if ($res.ok -and $res.changed) { $res.path } else { $null }) })
                if ($stopLoop) { break }
            }
            # File checks of what this round changed (per type: syntax, unclosed brackets, tags and
            # strings, duplicate keys or code, missing local files...), so a broken file is fixed in
            # the next round, before more edits build on it. Only problems the task added count.
            $roundChanged = @($results | ForEach-Object { $_.changedPath } | Where-Object { $_ } | Select-Object -Unique)
            if ($roundChanged.Count -and -not $State.Cancel -and -not $stopLoop) {
                $syntax = @(@(foreach ($p in $roundChanged) {
                    try {
                        $full = Resolve-ProjectPath $State.ProjectRoot $p
                        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-BinaryFile $full)) { continue }
                        $now = Read-TextFile $full
                        $rel = $p.Replace('\', '/')
                        $before = ''
                        if ($checkpoint.Files[$rel] -eq 'existed') { $bk = Join-Path $checkpoint.Dir ($rel.Replace('/', '\')); if (Test-Path -LiteralPath $bk) { $before = (Read-TextFile $bk).Text } }
                        foreach ($issue in @(Get-NewFileIssues $rel $before $now.Text $now.Crlf $State.ProjectRoot)) { "${rel}: $issue" }
                    } catch { Write-CCBLogError agent "File check $p" $_ }
                }) + @(if ("$($State.Config.pageCheck)" -ne 'off') { Test-ScriptSyntax $State $roundChanged }))
                # Import index: the changed files again, and what the round broke elsewhere (an import
                # of a moved file, an id, function or hook others still use).
                try { $syntax = @($syntax) + @(Update-ImportsAfterRound $State.ProjectRoot $roundChanged) } catch { Write-CCBLogError agent 'import index' $_ }
                $ev.syntaxLast = @($syntax)
                if ($syntax.Count) {
                    Write-CCBLog info agent 'File check problems after this round' @{ count = $syntax.Count }
                    Add-AgentEvent $State 'status' @{ text = "File check: $($syntax.Count) problem(s) in the changed files; Copilot is asked to fix them." }
                    $results.Add(@{ head = '### File check of the files changed in this reply'; output = (($syntax | Select-Object -First 15 | ForEach-Object { "- $_" }) -join "`n") + "`nFix these first: each one breaks the file or is a likely mistake." })
                    if ($isDone -and $syntaxNudges -lt 2) { $isDone = $false; $syntaxNudges++ }
                }
            }
            if ($State.Cancel) { Add-AgentEvent $State 'status' @{ text = 'Stopped. Changes made so far in this message can be undone.' }; break }
            if ($stopLoop) { break }
            if ($isDone) {
                # The project's own check (verify: in AGENTS.md) after a task that changed files.
                $verifyCmd = Get-ProjectVerify $State.ProjectRoot
                if ($verifyCmd -and $checkpoint.Files.Count -and $State.Mode -ne 'plan') {
                    $risk = Get-CommandRisk $verifyCmd
                    $why = Test-DeleteScope $State.ProjectRoot $verifyCmd
                    if ($State.NoCommands -or ($State.Headless -and -not $State.AllowCommands)) { $ev.verify = @{ command = $verifyCmd; skipped = 'commands are not allowed for this task' } }
                    elseif ($why -or $risk.m365 -or $risk.destructive) { $ev.verify = @{ command = $verifyCmd; skipped = 'the command deletes files or works with Microsoft 365, so it only runs by hand' } }
                    else {
                        Add-AgentEvent $State 'status' @{ text = "Verify: running ``$verifyCmd``..." }
                        $vr = Invoke-RunAction $State.ProjectRoot $verifyCmd ([int]$State.Config.commandTimeoutSec) 6000 { $State.Cancel }
                        $passed = ($vr.exitCode -eq 0)
                        $tail = ("$($vr.output)".Split("`n") | Select-Object -Last 25) -join "`n"
                        $ev.verify = @{ command = $verifyCmd; passed = $passed; exit = $vr.exitCode; tail = $tail }
                        Add-AgentEvent $State 'status' @{ text = "Verify: ``$verifyCmd`` $(if ($passed) { 'passed' } elseif ($vr.timedOut) { 'timed out' } else { "failed (exit $($vr.exitCode))" })." }
                        if (-not $passed -and $verifyNudges -lt 2 -and -not $State.Cancel) {
                            $verifyNudges++
                            $fence = '```'
                            $message = "The project's check failed, so the task is not finished. Command: $verifyCmd (exit $($vr.exitCode)). Output (end):`n$fence`n$tail`n$fence`nFix the cause, then send done again."
                            continue
                        }
                    }
                }
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
                            $ev.page = @($pageIssues)
                            if (-not $pageIssues.Count) { Add-AgentEvent $State 'status' @{ text = "Page check: $($pages -join ', ') loaded without errors." } }
                        }
                    }
                    # Changed JavaScript files: a syntax check in Edge (also files no page loads).
                    $jsChanged = @($changes | Where-Object { ($_.added -or $_.removed) -and -not $_.deleted -and $_.path -match '(?i)\.(m?js|cjs)$' } | ForEach-Object { $_.path })
                    if ($jsChanged.Count -and "$($State.Config.pageCheck)" -ne 'off' -and $State.Mode -ne 'plan') {
                        $syntax = @(Test-ScriptSyntax $State $jsChanged)
                        if ($syntax.Count) { $pageIssues = @($pageIssues) + $syntax }
                    }
                    if ($State.ReviewByCaller) {
                        # The calling model reviews the result itself; give it the local check results.
                        $reviewed = $true
                        $paths = @($changes | Where-Object { $_.added -or $_.removed } | ForEach-Object { $_.path })
                        if ($paths.Count) {
                            $issues = @(@(Test-ProjectConsistency $State.ProjectRoot $paths) + @($pageIssues | ForEach-Object { "page check: $_" }))
                            $text = if ($issues.Count) { "Local checks found $($issues.Count) problem(s):`n" + (($issues | ForEach-Object { "- $_" }) -join "`n") } else { 'Local checks (JSON, PowerShell syntax, local file references, page load) found no problems.' }
                            Add-AgentEvent $State 'status' @{ text = $text; checks = @($issues); review = 'caller' }
                        }
                        break
                    }
                    if ($pageIssues.Count -or (Test-NeedsReview $State $changes)) {
                        $reviewed = $true
                        $ev.reviewed = $true
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
        try { Clear-RunSnapshot $checkpoint } catch { Write-CCBLogError agent 'run snapshot' $_ }
        if (-not $checkpoint.Files.Count) { Remove-Item $checkpoint.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        if ($checkpoint.Files.Count -and "$($State.Config.evidence)" -ne 'off' -and $State.Mode -ne 'plan') {
            try {
                $chg = @(Get-CheckpointChanges $State.ProjectRoot $checkpoint | Where-Object { $_.added -or $_.removed -or $_.created -or $_.deleted })
                if ($chg.Count) {
                    $evPath = Save-TaskEvidence $State $Text $chg $ev $doneText ([int]$State.MessagesSent - $msgStart)
                    Add-AgentEvent $State 'status' @{ text = "Evidence saved: $evPath" }
                }
            } catch { Write-CCBLogError agent 'evidence' $_ }
        }
        if ($checkpoint.Files.Count -and $State.ReviewByCaller) {
            $contents = @(try { Get-ChangeSetContents $State.ProjectRoot $checkpoint } catch { Write-CCBLogError agent 'change set contents' $_ })
            Add-AgentEvent $State 'checkpoint' @{ files = @($checkpoint.Files.Keys); contents = $contents }
        }
        elseif ($checkpoint.Files.Count) { Add-AgentEvent $State 'checkpoint' @{ files = @($checkpoint.Files.Keys) } }
        # Issue cycle steps 3-6: scan what changed, queue fixes, check a fix task's file again.
        if (($checkpoint.Files.Count -or $State.IssueFix) -and $null -ne $baseline -and -not $State.Cancel) {
            $scan = @($checkpoint.Files.Keys) + @(if ($State.IssueFix) { "$($State.IssueFix.path)" })
            try { $null = Invoke-IssueCycle $State $scan $baseline $State.IssueFix } catch { Write-CCBLogError agent 'issue cycle' $_ }
        }
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
        try { $null = Invoke-DueSchedules $State } catch { Write-CCBLogError agent 'schedules' $_ }
        if ($State.PausedUntil) {
            if ((Get-Date) -lt [datetime]$State.PausedUntil) {
                # Paused at Copilot's daily limit: only undo (no Copilot needed) goes ahead.
                $peek = $null
                if ($State.Tasks.TryPeek([ref]$peek) -and $peek.kind -eq 'undo') { $null = $State.Tasks.TryDequeue([ref]$peek); $State.Held.Insert(0, $peek) }
                elseif (-not ($State.Held.Count -and $State.Held[0].kind -eq 'undo')) { Start-Sleep -Milliseconds 500; continue }
            } else { Resume-AgentQueue $State 'Copilot''s daily limit has reset' }
        }
        $task = $null
        $got = $false
        if ($State.Held.Count) { $task = $State.Held[0]; $State.Held.RemoveAt(0); $got = $true } else { $got = $State.Tasks.TryDequeue([ref]$task) }
        if (-not $got) {
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
        $entry = if ($task.queueId) { Get-QueueEntry $State $task.queueId } else { $null }
        if ($entry -and $entry.status -eq 'cancelled') {
            if ($job) { $job.status = 'cancelled'; $job.endSeq = $State.Seq }
            continue
        }
        if ($job) { $job.status = 'running'; $job.startSeq = $State.Seq; $job.started = (Get-Date).ToString('s') }
        $fromSeq = [int]$State.Seq; $msgsBefore = [int]$State.MessagesSent
        if ($entry) { $entry.status = 'running'; $entry.started = (Get-Date).ToString('s'); $State.CurrentQueueId = $entry.id; Save-AgentQueue $State }
        # A task from another program can bring its own mode, project and command rule; the app's
        # own settings come back afterwards.
        $saved = @{ Mode = $State.Mode; ProjectRoot = $State.ProjectRoot; NoCommands = $State.NoCommands; ReviewByCaller = $State.ReviewByCaller; ResponseMode = $State.ResponseMode }
        if ($task.responseMode) { $State.ResponseMode = $task.responseMode }
        $State.ReviewByCaller = [bool]$task.reviewByCaller
        $foreign = $task.source -and $task.source -ne 'user'
        if ($task.mode) { $State.Mode = $task.mode }
        if ($task.projectRoot -and $task.kind -in 'fetch', 'runbook', 'review' -and $task.projectRoot -ne $State.ProjectRoot) {
            if (-not (Test-Path -LiteralPath $task.projectRoot -PathType Container)) { $task.missingProject = $true }
            else { $State.ProjectRoot = $task.projectRoot }
        }
        $State.NoCommands = [bool]$task.noCommands
        try {
            switch ($task.kind) {
                'connect' { $null = Get-Bridge $State }
                'chat'    {
                    if ($task.projectRoot -and $task.projectRoot -ne $State.ProjectRoot) {
                        if ($foreign) { Add-AgentEvent $State 'status' @{ text = "Task from $($task.source): working in $($task.projectRoot)." } }
                        $State.ProjectRoot = $task.projectRoot; $State.Todos = @(); $State.NeedNewChat = $true
                    }
                    if ($task.newChat) { $State.NeedNewChat = $true }
                    $force = if ($task.forceKind) { "$($task.forceKind)" } elseif ($task.source -eq 'mcp' -or $task.source -eq 'api') { 'work' } else { '' }
                    # "Run the meetings runbook": the runbook job sends the runbook's instructions and
                    # contents to Copilot, as the Run button does. Not for "send again as a coding task".
                    $runReq = if ($force -ne 'coding' -and $State.ProjectRoot) { Get-RunbookRunRequest $task.text @(Get-Runbooks $State.ProjectRoot) } else { $null }
                    if ($runReq -and $runReq.name) {
                        Add-AgentEvent $State 'user' @{ text = $task.text }
                        Add-AgentEvent $State 'kind' @{ taskKind = 'runbook' }
                        Invoke-RunbookJob $State $runReq.name
                    } elseif ($runReq) {
                        Add-AgentEvent $State 'user' @{ text = $task.text }
                        $which = if (@($runReq.names).Count) { 'Which runbook should run? Name one of: ' + (@($runReq.names) -join ', ') + '. Or press Run on it in the Fetch tab.' } else { 'This project has no runbooks yet. Create one with "New runbook from a template" in the Fetch tab (or ask Copilot to create one), then run it.' }
                        Add-AgentEvent $State 'status' @{ text = $which }
                    } elseif ($task.clarify) {
                        Invoke-ClarifyStep $State $task
                    } else {
                        $State.IssueFix = $task.issueFix; $State.IssueFixHandled = $false
                        try { Invoke-AgentTurn $State $task.text $force }
                        finally {
                            $State.IssueFix = $null
                            # Stopped or failed before the rescan: its issues go back to open (no retry).
                            if ($task.issueFix -and -not $State.IssueFixHandled) { try { $null = Reset-StaleIssueFixes $State $State.ProjectRoot } catch { Write-CCBLogError agent 'issue fix reset' $_ } }
                        }
                        if ($task.planFirst) { Publish-PlanReady $State $task $fromSeq }
                        if ($task.planBuild -and $task.planId) { Write-PlanResult $State "$($task.planId)" $fromSeq }
                    }
                }
                'fetch' { if ($task.missingProject) { throw "The project folder $($task.projectRoot) no longer exists" }; Invoke-FetchJob $State $task.name }
                'runbook' { if ($task.missingProject) { throw "The project folder $($task.projectRoot) no longer exists" }; Invoke-RunbookJob $State $task.name }
                'review' { if ($task.missingProject) { throw "The project folder $($task.projectRoot) no longer exists" }; Invoke-ReviewJob $State $task }
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
                    $details = @(Undo-LastCheckpoint $State.ProjectRoot -Detailed)
                    $files = @($details | ForEach-Object { $_.path })
                    $text = if ($files.Count) { 'Undid the last change set: ' + ($files -join ', ') } else { 'Nothing to undo.' }
                    # Per file: the lines the undo brought back and took away, with a preview.
                    $changes = @($details | ForEach-Object { @{ path = $_.path; deleted = [bool]$_.deleted; added = [int]$_.added; removed = [int]$_.removed; binary = [bool]$_.binary; preview = $_.preview } })
                    Add-AgentEvent $State 'undo' @{ files = $files; text = $text; changes = $changes }
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
            if ($entry) {
                try { Complete-QueueEntry $State $entry $fromSeq $msgsBefore ([bool]($job.cancelled -or $entry.cancelRequested)) } catch { Write-CCBLogError agent 'queue entry' $_ }
                if ($job -and $job.status -eq 'error' -and $entry.status -ne 'failed') { $entry.status = 'failed'; $entry.error = $job.error }
                if ($entry.status -eq 'failed' -and (Test-LimitText $entry.error $State.LastLimitAt)) {
                    $until = Get-LimitResetTime $entry.error (Get-Date) "$($State.Credits.resetAt)"
                    Set-QueuePause $State $until 'daily limit'
                    $worked = @(Get-AgentEvents $State $fromSeq | Where-Object { $_.type -eq 'checkpoint' -or ($_.type -eq 'action' -and $_.status -eq 'done') }).Count
                    if (-not $worked) {
                        # Nothing was done yet: the task waits and runs first after the reset.
                        $entry.status = 'queued'; $entry.error = $null; $entry.summary = $null; $entry.started = $null; $entry.finished = $null
                        $entry.note = "Waits for Copilot's daily limit to reset ($($until.ToString('HH:mm')))."
                        if ($job) { $job.status = 'queued'; $job.error = $null; $job.endSeq = $null; $job.finished = $null }
                        $task.Remove('missingProject')
                        [void]$State.Held.Add($task)
                    } else {
                        $entry.error = "Stopped at Copilot's daily limit (it resets at $($until.ToString('HH:mm'))). Changes made so far stay; send a follow-up after the reset to finish."
                    }
                } elseif ($entry.status -in 'done', 'failed' -and $entry.note -like 'Waits for*') { $entry.note = $null }
                Write-CCBLog info agent "Queue $($entry.id) $($entry.status)" @{ messages = $entry.messages }
                Save-AgentQueue $State
            }
            $State.CurrentQueueId = $null
            $State.Mode = $saved.Mode; $State.NoCommands = $saved.NoCommands; $State.ReviewByCaller = $saved.ReviewByCaller; $State.ResponseMode = $saved.ResponseMode
            if ($foreign -and $saved.ProjectRoot -and $State.ProjectRoot -ne $saved.ProjectRoot) {
                $State.ProjectRoot = $saved.ProjectRoot; $State.NeedNewChat = $true
                Add-AgentEvent $State 'status' @{ text = "Back to $($saved.ProjectRoot)." }
            }
        }
    }
    Reset-Bridge $State
}

Export-ModuleMember -Function Get-ChangeCountStart, Reset-ChatHistoryCount, Get-ChatHistoryPath, Save-ChatEvent, Read-ChatHistory, Restore-ChatHistory, Update-AgentSchedule, Get-ProjectScheduleFile, Import-ProjectSchedules, Sync-ProjectSchedules, Get-IssueSettings, Get-IssueBaseline, Submit-IssueFix, Reset-StaleIssueFixes, Get-QueuedIssueFix, Invoke-IssueCycle, Start-IssueIndexer, Get-ProjectVerify, Save-TaskEvidence, Publish-PlanReady, Invoke-ClarifyStep, Get-ReviewScope, Get-ReviewPlan, Invoke-ReviewJob, Submit-AgentTask, Get-QueueEntry, Save-AgentQueue, Restore-AgentQueue, Set-QueuePause, Resume-AgentQueue, Save-QueuePause, Restore-QueuePause, Save-Schedules, Restore-Schedules, New-AgentSchedule, Start-ScheduledItem, Invoke-DueSchedules, New-AgentState, Add-AgentEvent, Get-AgentEvents, Start-AgentWorker, Invoke-AgentTurn
