# The agent loop. Runs in a background runspace and talks to the web server only through
# the synchronized $State hashtable (events out, tasks and approval decisions in).

$ErrorActionPreference = 'Stop'
$script:ProjectTaskKinds = @('chat', 'agent', 'fetch', 'runbook', 'chain', 'script', 'review', 'packages', 'undo', 'export', 'testrun-report')
foreach ($m in 'Log', 'Cdp', 'CopilotBridge', 'WorkStatus', 'Workspace', 'Protocol', 'Executor', 'Prompts', 'Fetch', 'Runbook', 'Schedule', 'Review', 'PlanFile', 'Lint', 'Issues', 'Imports', 'Guardrails', 'WebFetch', 'Retention', 'Chain', 'Layout', 'DataMirror', 'Config', 'ChatScope', 'TestRunner', 'Hooks', 'RepoMap', 'CheckPolicy', 'AutoFix', 'Office', 'SecretFiles', 'ShotDiff', 'UiKit', 'Contrast', 'DataImport', 'Download', 'Packages', 'FixCases', 'OneFile', 'ProjectSetup', 'ToolChecks', 'WebBuild', 'GuiTest', 'TaskNotes', 'SharePointPage', 'SessionReport', 'TestRuns', 'SharePointLink', 'FileIntake', 'DataQuery', 'PageExport', 'SqlServer', 'Handoff', 'LoopGuard', 'TaskGuidance', 'Progress') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

function New-AgentState {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$AppRoot)
    [hashtable]::Synchronized(@{
        Config = $Config; AppRoot = $AppRoot
        Events = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Seq = 0
        Tasks = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Approvals = [hashtable]::Synchronized(@{})
        Mode = 'ask'; ProjectRoot = $null; Busy = $false; Cancel = $false; Stop = $false
        ProjectGate = New-Object object   # worker/project-open exclusion; never lock the shared state itself
        SwitchWanted = $false   # a project open waits for the worker: it stops getting the current project ready
        Progress = ''; Copilot = 'idle'; CopilotMessage = ''
        Throttle = @{ used = 0; max = 0 }; Credits = $null; Todos = @(); ChatStarted = $false; NeedNewChat = $true; Summary = $null
        # This run of the app: event numbers start over with it, so an open tab knows to start over too.
        Instance = [guid]::NewGuid().ToString('N').Substring(0, 12)
        # Headless (MCP): no person approves; 'auto' mode applies changes, commands only when AllowCommands.
        Headless = $false; AllowCommands = $false; Jobs = [hashtable]::Synchronized(@{})
        LogLevel = $null   # set by the front end; the worker applies changes on the fly
        ChatKind = $null   # kind of task the current chat is about (chat, assistant, project, coding, mixed)
        ChatFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)   # what this chat read, changed or named (ChatScope)
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
        ResponseOptions = @((Read-ResponseOptionsFile).options); ResponseOptionsRead = (Read-ResponseOptionsFile).read   # what Copilot's picker offers (read weekly)
        ReviewByCaller = $false   # MCP tasks: the calling model checks the result, so no Copilot review round
        NextConnectAttempt = $null
        ConnectFailures = 0   # failed connects in a row: the idle worker's retries wait longer, then stop (Get-ConnectRetryDelay)
        OpenSync = $null   # a project just opened: its data files are converted at the next idle moment
        TurnAnswers = @{}   # request-scope setup answers (ProjectSetup) for the turn at hand
        ReadStamps = @{}   # per file: the fingerprint at Copilot's last read (line-range edits) and the last it saw (the stale note)
        # Work IQ (Microsoft 365 data in Copilot): 'on', 'off' or 'leave' (do not touch the toggle).
        WorkIq = $(if ($Config.workIq) { [string]$Config.workIq } else { 'leave' }); WorkIqActual = $null; WorkIqWarned = $false
        # Issue cycle: what the worker is doing besides Copilot (shown like "waiting for Copilot"),
        # the background indexer's progress, and the fix task being worked on.
        Activity = [hashtable]::Synchronized(@{ label = ''; kind = ''; done = 0; total = 0; current = '' })
        Indexing = [hashtable]::Synchronized(@{ running = $false; label = ''; done = 0; total = 0; current = ''; project = $null; last = $null; error = $null })
        IssueFix = $null; IssueFixHandled = $false
        AgentChat = $null   # the agent (Researcher) whose plan waits for the person's answer in the current chat
        InChain = $false   # a chain is running: its runbook/fetch steps leave Busy and Stop to it
        SaveHistory = $false   # set by the web app: the chat is kept per project (Save-ChatEvent / Restore-ChatHistory)
        HookRunning = $false; HookTrace = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
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
        # The waiting card's activity log and counts (WorkStatus); never in the way of the event itself.
        try { Update-WorkFromEvent $State $Type $Data } catch { }
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
        $keep = 0; if ($State.Config -and $State.Config.retention) { $keep = [int]$State.Config.retention.chatEvents }
        if ($keep -ge 100) { $script:HistoryMaxEvents = $keep }   # Settings > Retention > Chat history
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
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][Alias('Event')][hashtable]$ChatEvent
    )
    $json = ConvertTo-Json -InputObject $ChatEvent -Depth 6 -Compress
    if ($json.Length -gt $script:HistoryMaxEventChars) {
        $copy = @{}; foreach ($k in $ChatEvent.Keys) { $copy[$k] = $ChatEvent[$k] }
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
        $signIn = if ("$($State.Config.signIn)" -eq 'private') { 'private' } else { 'single-sign-on' }
            $script:Bridge = Connect-Copilot -Port $State.Config.cdpPort -SaveReplyFrames $save -SignIn $signIn
        $State.Copilot = 'ready'; $State.CopilotMessage = ''; $State.ConnectFailures = 0
        $State.CopilotThemeApplied = $null; Update-CopilotTheme $State   # a new connection: the tab gets StreamHub's theme again
        # What the response picker offers on this tenant (Advanced reasoning, models...), for the app's picker.
        if (Test-ResponseOptionsDue $State) { Update-ResponseOptions $State $script:Bridge }
        # Page health check: the parts CCBridge relies on are where selectors.json says.
        try {
            $health = @(Test-CopilotPage $script:Bridge)
            $bad = @($health | Where-Object { $_.ok -eq $false })
            Write-CCBLog $(if ($bad.Count) { 'info' } else { 'verbose' }) agent "Copilot page check: $(if ($bad.Count) { "$($bad.Count) problem(s)" } else { 'all parts found' })" @{ parts = @($health | ForEach-Object { "$($_.part)=$(if ($null -eq $_.ok) { 'unchecked' } elseif ($_.ok) { 'ok' } else { 'missing' })" }) }
            if ($bad.Count) {
                $what = ($bad | ForEach-Object { "$($_.part) (selectors.$($_.setting): $($_.note))" }) -join '; '
                $State.CopilotMessage = "Page check: $what"
                Add-AgentEvent $State 'status' @{ text = "Copilot page check: $what. Copilot's page may have changed; StreamHub may not be able to $(if (@($bad | Where-Object needed).Count) { 'type or send prompts' } else { 'start new chats or read replies reliably' }). Run test-tools\capture.cmd and send the report to update the selectors." }
            }
        } catch { Write-CCBLogError agent 'Copilot page check failed' $_ }
        $script:Bridge
    } catch {
        $State.Copilot = 'error'; $State.CopilotMessage = $_.Exception.Message
        # The idle worker retries, so Copilot is ready before the first prompt: waiting longer each
        # time, and stopping by itself after a while (Edge closed, signed out, no network).
        $State.ConnectFailures = [int]$State.ConnectFailures + 1
        $wait = Get-ConnectRetryDelay $State.ConnectFailures
        if ($null -ne $wait) { $State.NextConnectAttempt = (Get-Date).AddSeconds($wait) }
        else {
            $State.NextConnectAttempt = $null
            $State.CopilotMessage = "$($_.Exception.Message) StreamHub stopped trying by itself after $($State.ConnectFailures) attempts: press Check connection, or send a message to try again."
            Write-CCBLog info agent "Copilot connection: no more automatic retries after $($State.ConnectFailures) attempts"
        }
        throw
    }
}

function Get-ConnectRetryDelay([int]$Failures) {
    <# Seconds before the idle worker tries to connect to Copilot again after this many failures in a
       row, or $null to stop trying by itself: 30 s, 1 min, 2 min, 5 min, then every 10 min, about an
       hour in all. A Retry or a message the person sends starts the count over. #>
    $waits = @(30, 60, 120, 300, 600, 600, 600)
    if ($Failures -lt 1) { return $waits[0] }
    if ($Failures -gt $waits.Count) { return $null }
    $waits[$Failures - 1]
}

function Get-CopilotThemeWanted($State) {
    <# The theme the Copilot tab should get: StreamHub's theme (light, dark, or system = follow
       Windows), or 'system' when the setting copilotTheme is off. $null before the app said which. #>
    if (-not $State.CopilotTheme) { return $null }
    $on = $State.Config.copilotTheme
    if ($null -ne $on -and (-not [bool]$on -or "$on" -eq 'off')) { return 'system' }
    "$($State.CopilotTheme)"
}

function Update-CopilotTheme($State) {
    <# Applies the wanted theme to the Copilot tab when it differs from what was applied on this
       connection. Only on the worker's thread (one connection, one user at a time), and only when
       connected: a new connection starts without the override and gets it right after connecting. #>
    $want = Get-CopilotThemeWanted $State
    if (-not $want -or $want -eq $State.CopilotThemeApplied) { return }
    if (-not $script:Bridge -or $script:Bridge.Session.Lost) { return }
    try { Set-CopilotTheme $script:Bridge $want; $State.CopilotThemeApplied = $want }
    catch { Write-CCBLogError agent 'Copilot theme' $_; $State.CopilotThemeApplied = $want }   # not retried in a loop
}

function Reset-Bridge($State) {
    if ($script:Bridge) { try { Disconnect-Copilot $script:Bridge } catch { } }
    $script:Bridge = $null
    $State.Copilot = 'idle'
    $State.CopilotThemeApplied = $null   # the override ends with the connection
}

function Send-ToCopilot {
    param($State, [string]$Message, [string]$Agent = '', [switch]$Long, [string[]]$Files = @(), [switch]$OptionalFiles)   # -Agent mentions Researcher/Analyst; -Long: agent runs take minutes; -Files are attached (-OptionalFiles: left out when they cannot be)
    $bridge = Get-Bridge $State
    Update-CopilotTheme $State   # a theme chosen while a task ran
    if ($State.ResponseMode -in 'auto', 'quick', 'deep' -or "$($State.ResponseMode)" -like 'pick:*') {
        try { $State.ResponseModeActual = Set-CopilotResponseMode $bridge $State.ResponseMode } catch { Write-CCBLogError agent 'Response mode' $_ }
    }
    $State.MessagesSent = [int]$State.MessagesSent + 1
    if ($State.WorkIq -eq 'on' -or $State.WorkIq -eq 'off') {
        $State.WorkIqActual = Set-CopilotWorkIq $bridge ($State.WorkIq -eq 'on')
        if ($State.WorkIqActual -eq 'unavailable' -and -not $State.WorkIqWarned) {
            $State.WorkIqWarned = $true
            Add-AgentEvent $State 'status' @{ text = "Work IQ could not be switched $($State.WorkIq): the toggle is not configured or not on the page (run test-tools\capture.cmd on a Microsoft 365 Copilot licence). Copilot uses its current setting." }
        }
    }
    $who = if ($Agent) { $Agent } elseif ($State.AgentChat) { [string]$State.AgentChat } else { 'Copilot' }
    # The waiting card: reply data and the page's own signs of work count as signs of life (WorkStatus).
    $progress = { param($t) $State.Progress = $t; Set-WorkSign $State -Data; if ($State.Work -and $State.Work.phase -like 'Waiting for*reply*') { Set-WorkPhase $State "$who is writing the reply" -Step } }.GetNewClosure()
    $cancel = { [bool]$State.Cancel }.GetNewClosure()
    # An agent's progress lines ("Searching for release details") show in the waiting indicator.
    # $null clears the line again (the wait for the send lock is over).
    $status = { param($t) if (-not $t) { $State.Activity.label = ''; return }; Set-WorkSign $State; Add-WorkStep $State "${who}: $t"; $State.Activity.kind = $(if ($who -eq 'Copilot') { 'busy' } else { 'agent' }); $State.Activity.label = "${who}: $t" }.GetNewClosure()
    Set-WorkPhase $State "Waiting for ${who}'s reply" -Step
    Add-WorkStep $State "Sent a message to ${who} ($($Message.Length) characters)"
    try {
        $stall = if ($State.Config.PSObject.Properties['stallSec']) { [int]$State.Config.stallSec } else { 90 }
        $timeout = [int]$State.Config.replyTimeoutSec
        if ($Long) {
            # Agents work for minutes and can be quiet for half a minute or more in between.
            $timeout = if ([int]$State.Config.agentTimeoutSec -gt 0) { [int]$State.Config.agentTimeoutSec } else { 1800 }
            $stall = [Math]::Max($stall, 300)
        }
        Set-WorkWait $State $(if ([int]$State.Config.agentTimeoutSec -gt 0) { [int]$State.Config.agentTimeoutSec } else { 1800 }) $stall
        $r = $null
        try {
            $r = Send-CopilotPrompt $bridge $Message -TimeoutSec $timeout -MaxTimeoutSec $(if ([int]$State.Config.agentTimeoutSec -gt 0) { [int]$State.Config.agentTimeoutSec } else { 1800 }) -OnProgress $progress -CancelCheck $cancel -StallSec $stall -Agent $Agent -Files $Files -OptionalFiles:$OptionalFiles -OnStatus $status
        } catch {
            if (-not (Test-ConnectionLost $_) -or $State.ChatStarted) { throw }
            # First message of a chat: reconnect, start a fresh chat and send it once more.
            Write-CCBLog info agent 'Connection lost while sending the first message of a chat; reconnecting and sending again' @{ error = $_.Exception.Message }
            Add-AgentEvent $State 'status' @{ text = 'The connection to Copilot was lost; reconnecting and sending again.' }
            Reset-Bridge $State
            Start-NewChat $State
            $bridge = Get-Bridge $State
            $r = Send-CopilotPrompt $bridge $Message -TimeoutSec $timeout -MaxTimeoutSec $(if ([int]$State.Config.agentTimeoutSec -gt 0) { [int]$State.Config.agentTimeoutSec } else { 1800 }) -OnProgress $progress -CancelCheck $cancel -StallSec $stall -Agent $Agent -Files $Files -OptionalFiles:$OptionalFiles -OnStatus $status
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
    } finally { $State.Progress = ''; if ("$($State.Activity.label)" -like "${who}: *") { $State.Activity.label = ''; $State.Activity.kind = '' }; Set-WorkPhase $State "Working on ${who}'s reply"; Set-WorkWait $State 0 0 }
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
    <# Puts a task in the worker's queue and records it in $State.Queue (shown under Actions > Runs):
       what was asked, where it came from (user, mcp, api), status, timing, Copilot messages used,
       result or error. Returns the queue entry. #>
    param($State, [hashtable]$Task, [string]$Source = 'user', [string]$Title = '')
    # The queue's display entry and the executable task must name the same project, even when
    # the person opens another project before this task runs. Copy the caller's task as well.
    $Task = $Task.Clone()
    if ($Task.kind -in $script:ProjectTaskKinds -and -not $Task.ContainsKey('projectRoot')) { $Task.projectRoot = $State.ProjectRoot }
    $taskProjectRoot = if ($Task.ContainsKey('projectRoot')) { $Task.projectRoot } else { $State.ProjectRoot }
    $id = 'q-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    if (-not $Title) {
        $Title = switch ($Task.kind) {
            'chat' { "$($Task.text)" } 'ask' { "$($Task.text)" } 'fetch' { "Runbook: $($Task.name)" } 'runbook' { "Runbook: $($Task.name)" } 'chain' { "Chain: $($Task.name)" } 'script' { "Script: $($Task.name)" } 'agent' { "$(Get-AgentDisplayName $Task.agent): $($Task.text)" } 'review' { 'Code review' }
            'newchat' { 'New Copilot chat' } 'undo' { 'Undo last change set' } 'response-options' { 'Read Copilot''s response options' } default { "$($Task.kind)" }
        }
    }
    $Title = ($Title -replace '\s+', ' ').Trim(); if ($Title.Length -gt 160) { $Title = $Title.Substring(0, 157) + '...' }
    $entry = [hashtable]::Synchronized(@{ id = $id; kind = $Task.kind; title = $Title; source = $Source; status = 'queued'; created = (Get-Date).ToString('s')
        project = $(if ($taskProjectRoot) { Split-Path $taskProjectRoot -Leaf } else { $null })
        jobId = $Task.jobId; started = $null; finished = $null; messages = 0; summary = $null; error = $null; resultPath = $null
        projectRoot = $taskProjectRoot })
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
                if ($task.kind -in $script:ProjectTaskKinds -and -not $task.ContainsKey('projectRoot') -and $e.projectRoot) { $task.projectRoot = $e.projectRoot }
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
    if ($requeued) { Add-AgentEvent $State 'status' @{ text = "Picked up $requeued waiting task(s) from before the restart; they run in order (remove one under Actions > Runs with its x)." } }
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
    $done = @($events | Where-Object { $_.type -in 'done', 'fetch', 'runbook', 'chain', 'script', 'review', 'undo', 'newchat' } | Select-Object -Last 1)
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
    $sets = @($events | Where-Object { $_.type -eq 'checkpoint' })
    if ($sets.Count) { $Entry.changeSeq = [int]$sets[-1].seq }   # the History tab's card of this task
}

function Invoke-ExportJob {
    <# A project page as a PDF or a PowerPoint deck (PageExport.psm1), in Runbooks/Exports/: the page
       opens from the page check's address in StreamHub's Edge (a headless Edge of its own when that
       is not running). The first PDF also writes Scripts/Export-Page.ps1 for schedules and chains. #>
    param($State, $Task)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open a project first.' }; return }
    $page = "$($Task.page)".Replace('\', '/').TrimStart('/')
    if (-not $page -or -not (Test-Path -LiteralPath (Join-Path $State.ProjectRoot $page.Replace('/', '\')) -PathType Leaf)) { Add-AgentEvent $State 'error' @{ text = "The project has no page $page to export." }; return }
    $fmt = if ("$($Task.format)" -eq 'pptx') { 'pptx' } else { 'pdf' }
    $url = if ($State.PreviewPort) { "http://localhost:$($State.PreviewPort)/preview/$($State.PreviewToken)/$page" } else { 'file:///' + (Join-Path $State.ProjectRoot $page.Replace('/', '\')).Replace('\', '/') }
    $port = [int]$State.Config.cdpPort; $own = $null
    $prof = Join-Path $env:LOCALAPPDATA 'CCBridge\export-edge'
    $prev = Enter-Activity $State 'page' "Exporting $page as $(if ($fmt -eq 'pptx') { 'a PowerPoint deck' } else { 'a PDF' })"
    try {
        if (-not $port -or -not (Test-CdpEndpoint $port)) {
            $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
            $own = Start-CdpEdge -Port $port -ProfileDir $prof -Headless
        }
        $rel = Get-ExportName $page $fmt
        $full = Join-Path $State.ProjectRoot $rel.Replace('/', '\')
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
        if ($fmt -eq 'pdf') {
            [IO.File]::WriteAllBytes($full, (Export-PagePdf $port $url))
            $what = 'a PDF'
        } else {
            $parts = @(Get-PageParts $port $url)
            if (-not $parts.Count) { Add-AgentEvent $State 'status' @{ text = "$page has no charts or figures to put on slides." }; return }
            $title = [IO.Path]::GetFileNameWithoutExtension($page)
            [IO.File]::WriteAllBytes($full, (ConvertTo-PptxBytes $title $parts (Get-Date).ToString('yyyy-MM-dd')))
            $what = "a PowerPoint deck of $($parts.Count) chart(s) and figures"
        }
        Add-AgentEvent $State 'status' @{ text = "$page saved as $($what): $rel"; path = $rel }
        if ($fmt -eq 'pdf' -and -not (Test-Path -LiteralPath (Join-Path $State.ProjectRoot 'Scripts\Export-Page.ps1'))) {
            $script = Write-ExportScript $State.ProjectRoot
            Add-OwnChangeEvent $State 'write' $script 'StreamHub wrote Scripts/Export-Page.ps1: it saves a page as a PDF with Edge alone, so a schedule or chain can make the report while StreamHub is closed.'
        }
    } catch {
        Add-AgentEvent $State 'error' @{ text = "Exporting $page failed: $($_.Exception.Message)" }
    } finally {
        Exit-Activity $State $prev
        if ($own) { Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)" -like "*$prof*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    }
}

function Invoke-TestRunReport {
    <# The end of a test run: the session report of the run's time span in this run of the app, its
       numbers next to the last run of the same test, written to the run's project
       (.streamhub/TestRun-report.md) and beside the test (TestRuns/NAME/report-STAMP.md). #>
    param($State, $Task)
    $tr = $Task.testRun
    $log = Join-Path (Get-CCBLogDir) ('ccbridge-' + (Get-Date).ToString('yyyyMMdd') + '.log')
    $since = [datetime]::ParseExact("$($tr.started)", 's', [Globalization.CultureInfo]::InvariantCulture)
    $entries = @(if (Test-Path -LiteralPath $log) { Read-LogEntries ([IO.File]::ReadAllLines($log)) $PID | Where-Object { $_.time -ge $since } })
    $build = Format-CCBBuild (Get-CCBridgeBuild $State.AppRoot)
    $page = Get-SessionReport $entries "StreamHub $build"
    $now = Get-SessionReport $entries "StreamHub $build" -Metrics
    $now.when = (Get-Date).ToString('yyyy-MM-dd HH:mm'); $now.project = Split-Path -Leaf "$($tr.project)"
    # A run with checks turned off ('off:') is compared with the last run that had them all on.
    $off = @(@($tr.off) | Where-Object { "$_".Trim() })
    $now.off = $off
    $before = @(Read-TestRunHistory "$($tr.projectsRoot)" "$($tr.name)" | Where-Object { -not @($_.off | Where-Object { $_ }).Count }) | Select-Object -Last 1
    $checks = New-Object System.Collections.Generic.List[string]
    foreach ($expect in @($tr.expectations | Where-Object { "$_".Trim() })) {
        $res = Test-DoneWhenCheck "$($tr.project)" "$expect" -Literal
        if (-not $res) { $checks.Add("- NOT CHECKED: $expect (use 'PATH exists', 'PATH does not exist', 'PATH contains TEXT' or 'PATH does not contain TEXT')"); continue }
        $checks.Add("- $(if ($res.met) { 'MET' } else { 'NOT MET' }): $expect$(if ($res.note) { " ($($res.note))" })")
    }
    $outcomes = if ($checks.Count) { "`n## Deterministic outcome checks`n`n$($checks -join "`n")`n" } else { '' }
    if ($off.Count) {
        $known = @(Get-CheckSwitchNames)
        $outcomes = "`n## Turned off for this run`n`n$($off -join ', ') (compared with the last run that had everything on$(if (-not $before) { '; there is none yet' })). Checks: $($known -join ', '); other names are settings that are on or off.`n" + $outcomes
    }
    $text = "# Test run: $($tr.title)`n`n- Test: $($tr.name) ($($tr.steps) step(s)), project: $($now.project)`n`n## Compared with the last run`n`n" + (Format-TestRunComparison $now $before) + $outcomes + "`n" + ($page -replace '^# Session report', '## Session report' -replace '(?m)^## (Findings|Tasks|Failed steps)', '### $1')
    $enc = New-Object Text.UTF8Encoding($false)
    $rel = '.streamhub/TestRun-report.md'
    try {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path "$($tr.project)" '.streamhub')
        [IO.File]::WriteAllText((Join-Path "$($tr.project)" $rel.Replace('/', '\')), $text, $enc)
        $dir = Join-Path (Get-TestRunsDir "$($tr.projectsRoot)") "$($tr.name)"
        $null = New-Item -ItemType Directory -Force -Path $dir
        [IO.File]::WriteAllText((Join-Path $dir "report-$((Get-Date).ToString('yyyyMMdd-HHmm')).md"), $text, $enc)
        Add-TestRunHistory "$($tr.projectsRoot)" "$($tr.name)" $now
    } catch { Write-CCBLogError agent 'test run report' $_ }
    $delta = if ($before) { " Last run: $($before.messages) messages, $($before.nudges) nudges, $($before.failedSteps) failed steps." } else { '' }
    Add-AgentEvent $State 'status' @{ text = "Test run '$($tr.title)' finished: $($now.tasks) task(s), $($now.messages) Copilot messages, $($now.nudges) nudges, $($now.failedSteps) failed steps.$delta Report: $rel"; path = $rel }
}

function Set-PlanBuildTask {
    <# A task that builds an approved plan (the plan card's Approve and build): never in Plan only mode,
    which would skip every change and leave Copilot planning again; such a task asks before changes
    instead. Copilot is told planning is over, since the chat still holds the plan-first instructions. #>
    param($State, [hashtable]$Task)
    if ($State.Mode -eq 'plan' -or $Task.mode -eq 'plan') { $Task.mode = 'ask' }
    $Task.text = "$($Task.text)`n`nTHE PLAN IS APPROVED: planning is over. From this message on you change files and run commands as needed; carry out the plan now with action blocks."
}

function Write-TurnPlan {
    <# A turn that had a plan, written to PLAN.md for later reference: the steps Copilot listed (its
       todo list, as they stood at the end) and its Done when checks with their answers for a build or
       change, or Copilot's plan in Plan only mode; then the result (Write-PlanResult). Requests that
       went through Clarify first, Plan first or a proposal are written by those already. Returns the
       plan id or ''. #>
    param($State, $Task, [int]$FromSeq)
    if (-not $State.ProjectRoot -or $Task.planFirst -or $Task.planBuild -or $Task.issueFix -or $Task.clarify) { return '' }
    $p = $State.LastTurnPlan
    $todos = @(if ($p) { $p.todos }); $checks = @(if ($p) { $p.doneWhen })
    $planMode = $State.Mode -eq 'plan'
    $events = @(Get-AgentEvents $State $FromSeq)
    if (@($events | Where-Object { $_.type -eq 'plan-ready' }).Count) { return '' }   # a proposal: written already
    $planText = ''
    if ($planMode) {
        $last = @($events | Where-Object { $_.type -eq 'assistant' -and "$($_.text)".Trim() } | Select-Object -Last 1)
        if ($last.Count) { $planText = ("$($last[0].text)" -replace '(?s)`{3,}.*?`{3,}', '').Trim() }
    }
    if (-not $todos.Count -and -not $checks.Count -and -not $planText) { return '' }
    try {
        $request = ("$($Task.request)", "$($Task.text)" | Where-Object { $_ } | Select-Object -First 1)
        $id = New-PlanEntry $State.ProjectRoot $request
        if ($planText) { Add-PlanSection $State.ProjectRoot $id "Copilot's plan (Plan only mode)" $planText 'plan only: nothing built' }
        if ($todos.Count) { Add-PlanSection $State.ProjectRoot $id "Steps" ((@($todos | ForEach-Object { "- [$(if ($_.done) { 'x' } else { ' ' })] $($_.text)" })) -join "`n") 'in progress' }
        if ($checks.Count) {
            $lines = if ($p.acceptance) { @(Format-AcceptanceReport $p.acceptance) } else { @($checks | ForEach-Object { "- $_" }) }
            Add-PlanSection $State.ProjectRoot $id "Done when (Copilot's checks)" ($lines -join "`n") 'in progress'
        }
        if (-not $planMode) { Write-PlanResult $State $id $FromSeq }
        Add-AgentEvent $State 'status' @{ text = "Plan saved for later reference: .streamhub/PLAN.md"; path = '.streamhub/PLAN.md' }
        $id
    } catch { Write-CCBLogError agent 'PLAN.md turn plan' $_; '' }
}

function Write-PlanResult {
    <# The result of an approved build in PLAN.md: Copilot's summary, the files changed and the
       evidence file. #>
    param($State, [string]$PlanId, [int]$FromSeq)
    try {
        $events = @(Get-AgentEvents $State $FromSeq)
        $done = @($events | Where-Object { $_.type -eq 'done' } | Select-Object -Last 1)
        $files = @($events | Where-Object { $_.type -eq 'checkpoint' } | ForEach-Object { $_.files } | Where-Object { $_ } | Select-Object -Unique)
        $evidence = @($events | Where-Object { $_.type -eq 'status' -and ("$($_.text)" -like 'Task report saved: *' -or "$($_.text)" -like 'Evidence saved: *') } | Select-Object -Last 1)
        $failed = @($events | Where-Object { $_.type -eq 'error' } | Select-Object -Last 1)
        $body = New-Object System.Collections.Generic.List[string]
        $body.Add($(if ($done.Count) { "$($done[0].text)".Trim() } elseif ($failed.Count) { "Not finished: $($failed[0].text)" } else { 'Copilot did not report the task as done.' }))
        if ($files.Count) { $body.Add(''); $body.Add('Files changed: ' + (($files | ForEach-Object { "``$_``" }) -join ', ')) }
        if ($evidence.Count) { $body.Add(''); $body.Add('Task report: ' + ("$($evidence[0].text)" -replace '^(Task report|Evidence) saved: ', '')) }
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
    $steps = if ($todos.Count) {
        $lines = @()
        for ($i = 0; $i -lt $todos.Count; $i++) { $lines += "$($i + 1). $($todos[$i].text)" }
        ($lines -join "`n")
    } else { '' }
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

function Publish-ProposalPlan {
    <# After an ordinary turn that changed no files: when Copilot answered with a proposal
       (Test-ProposalText on its done summary, else its last reply), offer it as a plan to approve
       and build, the same card as a plan-first plan. Written to PLAN.md like any plan. #>
    param($State, $Task, [int]$FromSeq)
    if (-not $State.ProjectRoot) { return $false }
    $events = @(Get-AgentEvents $State $FromSeq)
    if (@($events | Where-Object { $_.type -in 'checkpoint', 'plan-ready', 'clarify', 'human-required' }).Count) { return $false }
    $done = @($events | Where-Object { $_.type -eq 'done' -and "$($_.text)".Trim() } | Select-Object -Last 1)
    $last = @($events | Where-Object { $_.type -eq 'assistant' -and "$($_.text)".Trim() } | Select-Object -Last 1)
    $text = if ($done.Count) { "$($done[0].text)" } elseif ($last.Count) { "$($last[0].text)" } else { '' }
    $text = ($text -replace '(?s)`{3,}.*?`{3,}', '').Trim()
    $unfinished = -not (Test-ProposalText $text)
    if ($unfinished -and -not (Test-UnfinishedText $text)) { return $false }
    $request = "$($Task.text)"
    $planId = ''
    try {
        $planId = New-PlanEntry $State.ProjectRoot $request
        Add-PlanSection $State.ProjectRoot $planId $(if ($unfinished) { 'Copilot stopped before the change' } else { "Copilot's proposal" }) $text 'waiting for approval'
    } catch { Write-CCBLogError agent 'PLAN.md' $_ }
    Write-CCBLog info agent $(if ($unfinished) { 'Copilot stopped before the change; offered as a plan' } else { 'Copilot answered with a proposal; offered as a plan' }) @{ chars = $text.Length }
    Add-AgentEvent $State 'plan-ready' @{ request = $request; plan = $text; planId = $planId; proposal = $true; unfinished = $unfinished }
    $true
}

function Test-RoundsLeft([int]$Limit, [int]$Round, [int]$LastProgress) {
    <# Whether a message's loop goes on after this round: within the budget always; past it only
       while the work still changes files (this round or the one before), up to three times the budget
       (at most 60). @{ go; extend (past the budget, still building); idle (stopped for two rounds
       without a change); hard; reason }. #>
    $hard = [Math]::Min(60, [Math]::Max($Limit, $Limit * 3))
    if ($Round -lt $Limit) { return @{ go = $true; extend = $false; idle = $false; hard = $hard; reason = '' } }
    $building = ($Round - $LastProgress) -le 1 -and $LastProgress -gt 0
    if ($Round -lt $hard -and $building) { return @{ go = $true; extend = $true; idle = $false; hard = $hard; reason = '' } }
    $reason = if ($Round -ge $hard) { "it reached the limit of $hard rounds" } else { "it reached the limit of $Limit rounds without new evidence (changed no files) in the last two rounds" }
    @{ go = $false; extend = $false; idle = ($Round -lt $hard); hard = $hard; reason = $reason }
}

function Test-ExploreRound($Actions, $Results) {
    <# Whether a round only looked around: reads, searches, finds and folder listings (dir, ls,
       Get-ChildItem, tree, type, cat), and nothing changed. #>
    if (-not @($Actions).Count) { return $false }
    foreach ($a in @($Actions)) {
        if ($a.type -in 'read', 'glob', 'grep', 'find') { continue }
        if ($a.type -eq 'run') {
            $cmd = $(if ($a.arg) { "$($a.arg)" } else { ("$($a.body)" -split "`n")[0] }).Trim()
            if ($cmd -match '(?i)^(dir|ls|tree|Get-ChildItem|gci|type|cat|Get-Content|gc|where|findstr|Select-String|sls)\b') { continue }
        }
        return $false
    }
    @($Results | Where-Object { $_.changedPath }).Count -eq 0
}

function Get-ExploreNudge([int]$Rounds, [string[]]$Missing, [bool]$NewProject) {
    <# The note that goes back to Copilot after three rounds (and every three more) of only reading
       and searching with no change: the file list is complete, write now. '' otherwise. #>
    if ($Rounds -lt 3 -or $Rounds % 3 -ne 0) { return '' }
    $m = @($Missing | Where-Object { $_ } | Select-Object -Unique)
    $gone = if ($m.Count) { " The files you looked for do not exist: $($m -join ', ')." } else { '' }
    "You have read and searched for $Rounds rounds.$gone Check whether the next observation will resolve a specific uncertainty. Continue useful investigation, or report the findings when the request is answered. Change files only when the task asks for changes. The project listing may be shortened; use glob or grep to locate files outside the displayed portion."
}

function Publish-SetupQuestions {
    <# The setup questions (ProjectSetup.psm1 Get-SetupQuestions: fixed rules on the request and the
       project's files) before a request goes to Copilot: the build form of a new project and every
       registry question whose trigger fires (kind of app, audience, entered data, Microsoft 365 data,
       sample data, personal details, language, extras, big request, recurring work, a new page, a
       rebuild). The message and a 'setup-choice' card; the answer sends the request again with
       task.setup. Answers the request states itself are saved (or set for this turn) without asking.
       Returns whether the turn stops for the card. #>
    param($State, $Task)
    $root = $State.ProjectRoot
    $setup = Get-ProjectSetup $root
    $paths = @(Get-ProjectFiles $root | ForEach-Object { $_.path })
    if (-not $setup.build) {
        $stated = Get-StatedBuild $Task.text
        if ($stated -and -not (Test-OwnCode $paths)) { $null = Save-ProjectSetup $root @{ build = $stated; chosenBy = 'request' }; $setup = Get-ProjectSetup $root }
    }
    $q = Get-SetupQuestions $Task.text $paths $setup $root $State.AppRoot
    if (-not $q) { return $false }
    if (@($q.stated.Keys).Count) {
        $null = Save-ProjectSetup $root @{ answers = $q.stated; chosenBy = 'request' }
        Write-CCBLog info agent 'Setup answers stated by the request' @{ ids = @($q.stated.Keys) -join ',' }
    }
    if (@($q.statedTurn.Keys).Count) { foreach ($k in $q.statedTurn.Keys) { $State.TurnAnswers[$k] = $q.statedTurn[$k] } }
    if (-not @($q.questions).Count) { return $false }
    if (-not $Task.shown) { Add-AgentEvent $State 'user' @{ text = $Task.text } }
    Add-AgentEvent $State 'setup-choice' @{ request = $Task.text; choices = @($q.questions); live = [bool]$q.live; suggest = "$($q.suggest)"; clarify = [bool]$Task.clarify }
    Write-CCBLog info agent 'Setup questions asked' @{ ids = (@($q.questions | ForEach-Object { $_.id }) -join ','); live = [bool]$q.live }
    $true
}

function Save-SetupAnswer {
    <# The user's answer to the setup card (task.setup from the app page: build, liveSource, answers =
       @{ id = value }): project-scope answers are saved for the project, request-scope ones apply to
       this turn ($State.TurnAnswers); a live data file is checked, copied in and gets
       Scripts/Refresh-Data.ps1. Returns @{ textPrefix } (words a request-scope answer puts before the
       request, such as making it a runbook). #>
    param($State, $Setup)
    $root = $State.ProjectRoot
    if (-not $root -or -not $Setup) { return @{ textPrefix = '' } }
    $changes = @{ chosenBy = 'user' }
    if ("$($Setup.build)" -in 'single', 'modular', 'copilot') { $changes.build = "$($Setup.build)" }
    $live = "$($Setup.liveSource)".Trim().Trim('"')
    if ($live) {
        $why = Test-LiveSourcePath $live $root
        if ($why) { Add-AgentEvent $State 'status' @{ text = "The live data file was not set: $why. Set it later under Project setup in the Files tab." }; $live = '' }
        else { $changes.liveSource = [IO.Path]::GetFullPath($live); $changes.liveStamp = '' }
    }
    $saved = @{}; $turn = @{}; $labels = New-Object System.Collections.Generic.List[string]
    $answers = $Setup.answers
    if ($answers) {
        $keys = if ($answers -is [hashtable]) { @($answers.Keys) } else { @($answers.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($k in $keys) {
            $d = Get-SetupQuestionDef "$k"
            if (-not $d) { continue }
            $v = "$(if ($answers -is [hashtable]) { $answers[$k] } else { $answers.$k })".Trim()
            $allowed = @($d.options | ForEach-Object { $_.value })
            $v = @($v -split ',' | Where-Object { $_ -and $allowed -contains $_ }) -join ','
            if (-not $v -and -not $d.multi) { continue }
            if ($d.scope -eq 'project') { $saved["$k"] = $v } else { $turn["$k"] = $v }
            $labels.Add((Get-SetupAnswerLabel "$k" $v))
        }
    }
    if ($saved.Count) { $changes.answers = $saved }
    foreach ($k in $turn.Keys) { $State.TurnAnswers[$k] = $turn[$k] }
    $s = Save-ProjectSetup $root $changes
    $parts = New-Object System.Collections.Generic.List[string]
    if ($changes.build) { $parts.Add("build form $(switch ($s.build) { 'single' { 'one HTML file' } 'modular' { 'separate files' } 'copilot' { 'left to Copilot' } })") }
    if ($changes.liveSource) { $parts.Add("live data from $($changes.liveSource)") }
    foreach ($l in $labels) { $parts.Add($l.ToLowerInvariant().Substring(0, 1) + $l.Substring(1)) }
    if ($parts.Count) { Add-AgentEvent $State 'status' @{ text = "Project setup saved: $($parts -join '; '). Change it under Project setup in the Files tab." } }
    if ($changes.liveSource) {
        try { $w = Write-RefreshScript $root $State.AppRoot; if ($w) { Add-OwnChangeEvent $State 'write' $w 'StreamHub wrote the refresh script: it copies the live data file in and updates the pages, for when StreamHub is closed (Windows Task Scheduler can run it).' } } catch { Write-CCBLogError agent 'refresh script' $_ }
        $null = Sync-LiveData $State
    }
    @{ textPrefix = (Get-SetupTextPrefix $turn) }
}

function Use-BigTaskPreference {
    <# A project whose setup says big requests are clarified or planned first (question bigtask): a
       big request that comes in plain becomes a Clarify first or Plan first task. #>
    param($State, $Task)
    $State.ScopeAsk = ''
    $pref = "$((Get-ProjectSetup $State.ProjectRoot).answers['bigtask'])"
    if ($pref -notin 'clarify', 'plan' -or $Task.clarify -or $Task.planFirst -or $Task.planBuild -or $Task.setup -or $Task.issueFix) { return }
    # The text of a plan card's build button (Approve and build, Continue and build) is a build, not a
    # new request, also when it arrives without its flag (an older page).
    if ("$($Task.text)" -match '^(Build this now, following the approved plan|Continue and make the change now)') { return }
    if (-not $Task.bigByCopilot -and -not (Test-BigRequest "$($Task.text)")) {
        # Near the line: Copilot decides in its first reply (Read-ScopeDecision), the turn ends on 'plan'.
        if ($Task.kind -eq 'chat' -and (Test-BigUnclear "$($Task.text)")) { $State.ScopeAsk = $pref }
        return
    }
    if ($pref -eq 'clarify') { $Task.clarify = $true; $Task.request = $Task.text }
    else {
        $Task.planFirst = $true; $Task.mode = 'plan'; $State.Mode = 'plan'; $Task.forceKind = 'coding'; $Task.request = $Task.text
        # Its own PLAN.md section, so the plan card carries an id and its approval is recorded.
        if (-not $Task.planId) { try { $Task.planId = New-PlanEntry $State.ProjectRoot "$($Task.text)" } catch { Write-CCBLogError agent 'PLAN.md big request' $_ } }
        $Task.text = (Get-PromptPart $State.AppRoot 'plan-first') + "`n`n" + $Task.text
    }
    Add-AgentEvent $State 'status' @{ text = "A big request$(if ($Task.bigByCopilot) { ' (Copilot judged it so)' }): $(if ($pref -eq 'clarify') { 'Copilot asks its questions first' } else { 'Copilot plans first' }), as chosen for this project (Project setup in the Files tab changes it)." }
}

function Invoke-ClarifyStep {
    <# Clarify first: Copilot asks at most 5 questions (as JSON, with likely answers) before any
       work. The app shows them as a form; the answers come back as a plan-first task. With no
       questions it plans right away. #>
    param($State, $Task)
    $request = "$($Task.request)"
    if (-not $Task.shown) { Add-AgentEvent $State 'user' @{ text = $request } }
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

function Get-TurnTestBaseline($State) {
    <# The project's check (verify: in AGENTS.md, else all its tests: TestRunner) as it is before a
       task changes anything: @{ command; stamp; passed; failures; when }, or $null (setting
       testBaseline off, no tests, commands not allowed, or a command that only runs by hand). The
       saved run is used again while no project file changed since (Get-ProjectStamp). #>
    if ("$($State.Config.testBaseline)" -in 'False', 'off') { return $null }
    if ($State.NoCommands -or ($State.Headless -and -not $State.AllowCommands)) { return $null }
    $cmd = Get-ProjectVerify $State.ProjectRoot
    if (-not $cmd) {
        if ("$($State.Config.autoTests)" -in 'False', 'off') { return $null }
        $tc = Find-TestCommand $State.ProjectRoot @(Get-ProjectFiles $State.ProjectRoot | ForEach-Object { $_.path })
        if (-not $tc) { return $null }
        $cmd = $tc.command
    }
    $risk = Get-CommandRisk $cmd
    if ((Test-DeleteScope $State.ProjectRoot $cmd) -or $risk.m365 -or $risk.destructive) { return $null }
    $dir = Get-ProjectStateDir $State.ProjectRoot
    $saved = Read-TestBaseline $dir
    if ($saved -and $saved.command -eq $cmd -and $saved.stamp -eq (Get-ProjectStamp $State.ProjectRoot)) { return $saved }
    Add-AgentEvent $State 'status' @{ text = "Tests before the change: running ``$cmd`` once, so failures that are already there are not counted as Copilot's." }
    $prev = Enter-Activity $State 'tests' 'Running the tests before the change'
    try { $vr = Invoke-RunAction $State.ProjectRoot $cmd ([int]$State.Config.commandTimeoutSec) 20000 { $State.Cancel } } finally { Exit-Activity $State $prev }
    if ($vr.timedOut -or $State.Cancel) { Add-AgentEvent $State 'status' @{ text = 'Tests before the change: did not finish in time; failures after the change all count.' }; return $null }
    $entry = @{ command = $cmd; stamp = (Get-ProjectStamp $State.ProjectRoot); passed = ($vr.exitCode -eq 0); failures = @(Get-TestFailureLines "$($vr.output)"); when = (Get-Date).ToString('s') }
    Save-TestBaseline $dir $entry
    if (-not $entry.passed) { Add-AgentEvent $State 'status' @{ text = "Tests before the change: already failing ($(@($entry.failures).Count) failure line(s)). Those are not sent to Copilot as its own." } }
    $entry
}

function Get-AcceptanceStep($State, [string[]]$DoneWhen) {
    <# What to ask at "done" about the Done when lines: StreamHub checks the file lines itself
       (TaskNotes Test-DoneWhenCheck), Copilot is asked about the rest and to fix file lines not met.
       @{ text ('' = nothing to ask); asked (the lines Copilot answers); helper (StreamHub's results) }. #>
    $helper = @(Get-HelperChecks $State.ProjectRoot $DoneWhen)
    $own = @($helper | ForEach-Object { "$($_.check)" })
    @{ text = (New-AcceptanceAsk $DoneWhen $helper); asked = @(@($DoneWhen) | Where-Object { $own -notcontains "$_" }); helper = $helper }
}

function Invoke-FreshReview($State, $Checkpoint, [string[]]$DoneWhen, $Ev) {
    <# The change reviewed in a new Copilot chat that sees only the request, the Done when lines and
       the change (Review New-FreshReviewMessage). A finding counts only when the line it quotes is in
       the file (Test-ReviewQuote); those go to a Continue card. The next message goes on in that chat. #>
    $contents = @(Get-ChangeSetContents $State.ProjectRoot $Checkpoint)
    if (-not $contents.Count) { return }
    $budget = [Math]::Max(8000, [int]([int]$State.Config.promptCharBudget * 0.6))
    $msg = New-FreshReviewMessage "$($State.TurnText)" @($DoneWhen) $contents $budget
    Add-AgentEvent $State 'status' @{ text = "Review in a fresh chat: a new Copilot chat reviews the change ($($contents.Count) file(s)), without the chat that made it." }
    Start-NewChat $State
    $r = Send-ToCopilot $State $msg
    if ($r.Cancelled) { return }
    $found = @(Read-FreshReviewFindings "$($r.Text)")
    $verified = @(foreach ($f in $found) { $v = Test-ReviewQuote $State.ProjectRoot $f; if ($v.status -eq 'verified') { $v } })
    $Ev.freshReview = @{ found = $found.Count; verified = $verified.Count }
    Write-CCBLog info agent 'Fresh review' @{ files = $contents.Count; found = $found.Count; verified = $verified.Count }
    if (-not $verified.Count) {
        Add-AgentEvent $State 'status' @{ text = "Review in a fresh chat: no problems found$(if ($found.Count) { " ($($found.Count) reported, but the lines they quote are not in the files, so they are left out)" })." }
        return
    }
    Add-AgentEvent $State 'task-unfinished' @{ text = "A review in a fresh Copilot chat found $($verified.Count) problem(s) in the change (each quotes a line that is in the file$(if ($found.Count -gt $verified.Count) { "; $($found.Count - $verified.Count) more left out because their quote is not" })). Continue to have Copilot check and fix them."; findings = @($verified | ForEach-Object { "$($_.file):$($_.line) - $($_.text)" }); continueText = (Get-FreshReviewContinue $verified) }
}

function Set-TaskSwitchesOff($State, [string[]]$Names) {
    <# A test run's 'off:' names, for one task: check switches (Config Get-CheckSwitchNames) through
       Set-CheckSwitchOverride, other names as on/off settings ($State.Config, only a setting that is
       a true/false value). Returns what Restore-TaskSwitches puts back; nothing is saved. #>
    $list = @(@($Names) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
    $checks = @(Get-CheckSwitchNames)
    Set-CheckSwitchOverride @($list | Where-Object { $checks -contains $_.ToLowerInvariant() })
    $restore = @{ config = $State.Config; values = @{} }
    $cfg = $State.Config
    if (-not $cfg) { return $restore }
    foreach ($n in @($list | Where-Object { $checks -notcontains $_.ToLowerInvariant() })) {
        $key = if ($cfg -is [hashtable]) { @($cfg.Keys | Where-Object { $_ -eq $n })[0] } else { @($cfg.PSObject.Properties | Where-Object { $_.Name -eq $n } | ForEach-Object { $_.Name })[0] }
        if (-not $key -or $cfg.$key -isnot [bool]) { continue }
        $restore.values[$key] = $cfg.$key
        $cfg.$key = $false
    }
    if ($list.Count) { Write-CCBLog info agent 'Turned off for this task' @{ names = ($list -join ', ') } }
    $restore
}

function Restore-TaskSwitches($Restore) {
    Set-CheckSwitchOverride @()
    if (-not $Restore -or -not $Restore.config) { return }
    foreach ($k in @($Restore.values.Keys)) { $Restore.config.$k = $Restore.values[$k] }
}

function Save-TaskEvidence {
    <# .streamhub/evidence/task-<stamp>.md in the project: what was asked, what changed, which checks ran and
       their results, Copilot's summary. Returns the relative path. #>
    param($State, [string]$Request, $Changes, $Ev, [string]$Done, [int]$Messages)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $rel = Get-LayoutPath Evidence "task-$stamp.md"
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
    if ($Ev.pageLeft) { $pg += ' (still there when the task ended: Copilot said done anyway)' }
    [void]$sb.AppendLine("- Page check: $pg")
    if (@($Ev.unloaded).Count) { [void]$sb.AppendLine("- New files nothing loads: $(@($Ev.unloaded) -join ', ')") }
    if ($Ev.coverage -and @($Ev.coverage).Count) { [void]$sb.AppendLine("- Plan coverage (left when the task ended): $(@($Ev.coverage) -join '; ')") }
    if (@($Ev.kitEdits).Count) { [void]$sb.AppendLine("- UI kit files changed directly: $(@($Ev.kitEdits) -join ', ') (the kit is meant to be restyled through tokens.css and the project's own CSS)") }
    if ($Ev.unfinished) { [void]$sb.AppendLine("- Not finished: Copilot $($Ev.unfinished). StreamHub checked the changed files at the end: $(if (@($Ev.final).Count) { "$(@($Ev.final).Count) problem(s): " + (@($Ev.final) -join '; ') } else { 'no problems found' })") }
    [void]$sb.AppendLine("- Copilot consistency review: $(if ($Ev.reviewed) { 'done' } else { 'not needed' })")
    if ($Ev.freshReview) { [void]$sb.AppendLine("- Review in a fresh chat: $($Ev.freshReview.verified) problem(s) whose quoted line is in the file$(if ([int]$Ev.freshReview.found -gt [int]$Ev.freshReview.verified) { "; $([int]$Ev.freshReview.found - [int]$Ev.freshReview.verified) more reported that quote lines not in the files (left out)" })") }
    if ($Ev.acceptance -and @($Ev.acceptance).Count) {   # @($null) counts 1
        [void]$sb.AppendLine().AppendLine("## Done when (Copilot's checks, answered at the end; file checks made by StreamHub)").AppendLine()
        foreach ($l in @(Format-AcceptanceReport $Ev.acceptance)) { [void]$sb.AppendLine($l) }
    }
    if (@($Ev.hooks).Count) {
        [void]$sb.AppendLine().AppendLine('## Hooks').AppendLine()
        foreach ($h in @($Ev.hooks)) {
            [void]$sb.AppendLine("- $($h.event)$(if ($h.action) { " [$($h.action)]" })$(if ($h.name) { " '$($h.name)'" }): $($h.status), $($h.durationMs) ms$(if ($h.timedOut) { ', timed out' })$(if ($h.outputTruncated) { ', output truncated' })")
        }
    }
    $vf = if (-not $Ev.verify -and $null -ne $Ev.page -and -not @($Ev.page).Count) { 'no verify command in AGENTS.md; the page check passed' } elseif (-not $Ev.verify) { 'not configured (add a "verify: COMMAND" line to AGENTS.md)' } elseif ($Ev.verify.skipped) { "not run: $($Ev.verify.skipped)" } elseif ($Ev.verify.passed) { "passed (``$($Ev.verify.command)``)" } elseif ($Ev.verify.preexisting) { "FAILED with the same failures as before this task (``$($Ev.verify.command)``, exit $($Ev.verify.exit))" } else { "FAILED (``$($Ev.verify.command)``, exit $($Ev.verify.exit))" }
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
       continues where it was. Saves .streamhub/reviews/review-<stamp>.md and .json. #>
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
                findings = @($p.findings | ForEach-Object { ConvertTo-PlainHash $_ }); overall = $p.overall; ignored = [int]$p.ignored }
            Add-AgentEvent $State 'status' @{ text = "Continuing the code review where it stopped ($($rv.done.Count) part(s) done)." }
        } else {
            $sc = Get-ReviewScope $State ([string]$Task.scope) @($Task.paths)
            if (-not $sc.files.Count) { Add-AgentEvent $State 'error' @{ text = "Nothing to review in $($sc.text): no code files found."; code = 'REVIEW'; hint = 'Pick another scope; build output, lock files, data and Source/ are never reviewed.' }; return }
            $rv = @{ id = $id; created = (Get-Date).ToString('s'); scope = "$($Task.scope)"; scopeText = $sc.text; focus = @($focus.Split(',') | ForEach-Object { $_.Trim() }); files = @($sc.files); skipped = @($sc.skipped)
                messages = 0; done = @(); summaries = @(); findings = @(); overall = $null; ignored = 0 }
        }
        $budget = if ($State.Config.reviewBatchChars) { [int]$State.Config.reviewBatchChars } else { 40000 }
        $batches = @(New-ReviewBatches $State.ProjectRoot $rv.files $budget)
        $total = $batches.Count
        $save = { [IO.File]::WriteAllText($partial, (ConvertTo-Json -InputObject $rv -Depth 6 -Compress), $enc) }
        Write-CCBLog info agent "Code review $id" @{ files = $rv.files.Count; batches = $total; done = $rv.done.Count }
        Start-NewChat $State
        $instructions = (Get-PromptPart $State.AppRoot 'review-code').Replace('FOCUS', $focus).Replace('TOTAL', "$total")
        # What the user ignored (in Issues or an earlier review) is named per part and left out.
        $ignoredList = @(try { Get-IgnoredFindings $State.ProjectRoot } catch { Write-CCBLogError agent 'ignored findings' $_ })
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
            $res = & $ask ($instructions.Replace('BATCH', "$($b.index)") + "`n" + $b.text + (Format-IgnoredForReview $ignoredList @($b.files)))
            if ($res.stop) { & $save; return }
            if (-not $res.out.ok) {
                $rv.summaries += @{ index = $b.index; files = @($b.files); summary = "(no valid answer from Copilot for this part: $($res.out.errors -join '; '))" }
            } else {
                foreach ($f in $res.out.findings) {
                    $f.part = $b.index
                    if (Test-IgnoredFinding $ignoredList $f) { $rv.ignored = [int]$rv.ignored + 1; continue }
                    $rv.findings += (Test-ReviewQuote $State.ProjectRoot $f)
                }
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
                foreach ($f in $res.out.findings) {
                    $f.part = 0
                    if (Test-IgnoredFinding $ignoredList $f) { $rv.ignored = [int]$rv.ignored + 1; continue }
                    $rv.findings += (Test-ReviewQuote $State.ProjectRoot $f -AllowGeneral)
                }
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
        Add-AgentEvent $State 'review' @{ id = $rv.id; path = $paths.md; json = $paths.json; text = "Code review done: $($ok.Count) finding(s) ($counts)$(if ($unv) { "; $unv unverified" })$(if ([int]$rv.ignored) { "; $($rv.ignored) left out because you ignored them before" }) in $(@($rv.files).Count) file(s), $($rv.messages) Copilot message(s). Report: $($paths.md). Pick findings to fix under Code health > Code review." }
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
       An existing output file is kept when the run fails. $Inputs (a chain step's "with" files)
       go with the prompt as data. #>
    param($State, [string]$Name, [string[]]$Inputs = @())
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
        $spec = Get-WebSourceSpec $rb.meta
        $agentSpec = Get-AgentSpec $rb.meta   # agent: researcher / analyst, files: to attach
        $web = Get-WebSourcePrompt $State $spec
        $inp = New-ChainInputBlock $State.ProjectRoot $Inputs ([int]$State.Config.resultCharBudget)
        foreach ($n in @($inp.notes)) { Add-AgentEvent $State 'status' @{ text = "Runbook '$($item.title)': $n." } }
        # A runbook that reads only the web gets the research role, not the Microsoft 365 assistant.
        $rbKind = if ($spec.sources -eq 'web') { 'runbook-web' } else { 'runbook' }
        $message = New-PromptMessage -AppRoot $State.AppRoot -Kind $rbKind -Text "$body$(if ($web.text) { "`n`n$($web.text)" })$(if ($inp.text) { "`n`n$($inp.text)" })" -Sent (New-Object 'System.Collections.Generic.HashSet[string]')
        $check = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $r = if ($attempt -eq 1) { Send-AgentJobMessage $State $spec $message $agentSpec } else { Send-WithSources $State $spec $message -Long:([bool]$agentSpec.agent) }
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
        if ($agentSpec.agent) { $null = Save-AgentCharts $State "$Name-chart" }
        $note = if ($check.truncated) { ' Copilot marked it as truncated: not every item fitted. Narrow the period or the sources.' } else { '' }
        $siteNotes = @(@($web.notes) + @(Get-SourceSiteNotes $spec $r.References))
        if ($siteNotes.Count) { $note += ' Note: ' + ($siteNotes -join '; ') + '.' }
        Add-AgentEvent $State 'runbook' @{ name = $Name; path = $saved.output; text = "Runbook '$($item.title)': saved $($check.count) item(s) to $($saved.output) (copy in $($saved.history)).$note Attach it with @$($saved.output)." }
    } catch {
        Write-CCBLogError agent "Runbook $Name failed" $_
        Add-AgentEvent $State 'error' @{ text = "Runbook '$Name' failed: $($_.Exception.Message)"; record = $_ }
    } finally {
        $State.NeedNewChat = $true
        if (-not $State.InChain) { $State.Busy = $false; $State.Cancel = $false }   # a chain carries on (and keeps a Stop)
    }
}

function Start-OwnRunCard {
    <# A card for something StreamHub runs itself (the built-in build, a tool check, a window app
       test): "running" now, finished with Complete-OwnRunCard. Returns its id. #>
    param($State, [string]$Target, [string]$Command = '')
    $id = 'own-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Add-AgentEvent $State 'action' @{ id = $id; action = 'run'; target = $Target; status = 'running'; by = 'streamhub'; command = $Command }
    $id
}

function Complete-OwnRunCard {
    param($State, [string]$Id, [bool]$Ok, [string]$Summary, [string]$Output = '')
    Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $Ok; status = $(if ($Ok) { 'ok' } else { 'failed' }); summary = $Summary; output = (Limit-Text $(if ($Output) { "$Summary`n$Output" } else { $Summary }) 4000) }
}

function Invoke-ProjectBuild {
    <# The built-in build of a React or TypeScript project without npm (WebBuild): after a round that
       changed src/, with a card while it runs. Returns the problems as "FILE:LINE: text" lines. #>
    param($State, [string[]]$Changed)
    if (-not (Test-WebBuildProject $State.ProjectRoot $State.AppRoot)) { return @() }
    $src = @($Changed | ForEach-Object { "$_".Replace('\', '/') } | Where-Object { $_ -match '(?i)^src/' })
    if (-not $src.Count) { return @() }
    $script = try { Write-BuildScript $State.ProjectRoot $State.AppRoot } catch { '' }
    if ($script) { Add-OwnChangeEvent $State 'write' $script 'StreamHub wrote a script that builds this app (src/ into dist/) without Node.js, for when StreamHub is closed.' }
    $typed = [bool]@($src | Where-Object { $_ -match '(?i)\.(ts|tsx)$' }).Count
    $card = Start-OwnRunCard $State "Build the app (built-in builder in Edge$(if ($typed) { ', with a TypeScript check' }))" 'esbuild + TypeScript'
    $prevAct = Enter-Activity $State 'tests' 'Building the app'
    try {
        $r = Invoke-WebBuild -ProjectRoot $State.ProjectRoot -AppRoot $State.AppRoot -TypeCheck:$typed -CdpPort ([int]$State.Config.cdpPort) -Minify
        $problems = @(Format-WebBuildProblems $r)
        $sum = if (-not $r.ok) { "build failed ($(@($r.errors).Count) error(s))" } elseif (@($r.typeErrors).Count) { "built, $(@($r.typeErrors).Count) type error(s)" } else { "built in $([Math]::Round($r.ms / 1000, 1)) s" }
        Complete-OwnRunCard $State $card ($r.ok -and -not @($r.typeErrors).Count) $sum (@(@($problems) + @(if ($r.written.Count) { "Written: $($r.written -join ', ')" })) -join "`n")
        $problems
    } catch {
        Write-CCBLogError agent 'built-in build' $_
        Complete-OwnRunCard $State $card $false "the builder could not run: $($_.Exception.Message)"
        @()
    } finally { Exit-Activity $State $prevAct }
}

function Add-OwnChangeEvent {
    <# A change StreamHub made to the project itself (data copies, folder moves, links, source data
       put back): an action card in the chat like Copilot's reads and writes, with the diff when
       $Preview (@{ path; exists; old; new }) is given and the details as its output. #>
    param($State, [string]$Action, [string]$Target, [string]$Summary, $Preview = $null, [string]$Output = '')
    $id = 'own-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $evt = @{ id = $id; action = $Action; target = $Target; status = 'running'; by = 'streamhub' }
    if ($Preview) { $evt.preview = @{ path = $Preview.path; exists = [bool]$Preview.exists; old = (Get-PreviewText $Preview.old); new = (Get-PreviewText $Preview.new) } }
    Add-AgentEvent $State 'action' $evt
    # The card shows the summary as its own line; the output holds the details (or the summary
    # when there is nothing else, so the card can open).
    $out = $(if ($Output) { $Output } elseif ($Preview) { '' } else { $Summary })
    Add-AgentEvent $State 'action-result' @{ id = $id; ok = $true; status = 'ok'; summary = $Summary; output = (Limit-Text $out 4000); changed = $true }
}

function Sync-LiveData {
    <# The project's live data file (project setup, ProjectSetup.psm1) copied into Source/Live/ when it
       changed; said once when it cannot be found. Returns whether a new copy came in. #>
    param($State)
    if (-not $State.ProjectRoot) { return $false }
    try {
        $r = Sync-LiveSource $State.ProjectRoot
        if (-not $r) { return $false }
        if ($r.missing) {
            if ($State.LiveMissingSaid -ne $r.source) {
                $State.LiveMissingSaid = $r.source
                Add-AgentEvent $State 'status' @{ text = "The live data file was not found: $($r.source). Is its folder still synced by OneDrive on this computer? The pages keep the last copy ($($r.rel))." }
            }
            return $false
        }
        $State.LiveMissingSaid = $null
        if ($r.changed) { Add-AgentEvent $State 'status' @{ text = "Live data refreshed: $($r.rel) copied from $($r.source)." }; return $true }
    } catch { Write-CCBLogError agent 'live data' $_ }
    $false
}

function Sync-OneFilePages {
    <# One-file pages (project setup "one file"): their UI kit and data blocks brought up to date
       (Update-OneFilePages), each page an edit card and all of them one change set. Returns the
       pages written. #>
    param($State)
    if (-not $State.ProjectRoot) { return @() }
    try {
        $r = Update-OneFilePages $State.ProjectRoot $State.AppRoot
        foreach ($it in @($r.items)) { Add-OwnChangeEvent $State 'edit' "$($it.path) (UI kit and data blocks)" 'StreamHub filled the one-file page''s UI kit and data blocks with what the page uses now.' @{ path = $it.path; exists = $true; old = $it.old; new = $it.new } }
        foreach ($n in @($r.notes)) { Add-AgentEvent $State 'status' @{ text = $n } }
        if ($r.checkpoint -and $r.checkpoint.Files.Count) { Add-ChangeSetEvent $State $r.checkpoint 'One-file page brought up to date' }
        return @($r.files)
    } catch { Write-CCBLogError agent 'one-file pages' $_ }
    @()
}

function Sync-DataImports {
    <# Data files (CSV, TSV, Excel; JSON in Source/) converted to data/NAME.json + data/NAME.js for
       Copilot (setting dataImport): at task start, after each task and when a project opens. The
       live data file comes in first and one-file pages are filled after. Returns whether a file was
       written. #>
    param($State, [switch]$NoLive)
    if (-not $State.ProjectRoot) { return $false }
    if (-not $NoLive) { $null = Sync-LiveData $State }
    if (-not (Test-DataImportOn $State.AppRoot)) { return (@(Sync-OneFilePages $State).Count -gt 0) }
    $wrote = $false
    # What is happening while a data file is converted (a large Excel file takes a while): a line in
    # the chat per file and the waiting indicator saying which file; the change cards follow.
    $st = $State
    $progress = { param($rel, $n, $of) $name = Split-Path $rel -Leaf; Add-AgentEvent $st 'status' @{ text = "Converting $name for Copilot, so it can read the data (StreamHub writes it to data/)." }; $st.Activity.kind = 'convert'; $st.Activity.label = "Converting $name for Copilot" }.GetNewClosure()
    $prevActivity = Enter-Activity $State "$($State.Activity.kind)" "$($State.Activity.label)"
    try {
        $r = Update-DataImports $State.ProjectRoot -JsCopy (Test-DataCopiesOn $State.AppRoot) -AppRoot $State.AppRoot -OnProgress $progress
        $notes = @(Format-DataImportNotes $r)
        $items = @($r.items | Where-Object { $_.status -ne 'taken' })
        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items[$i]
            if ($it.status -in 'created', 'updated', 'tools') { Add-OwnChangeEvent $State 'write' $(if ($it.source) { "$($it.output) (from $($it.source))" } else { $it.output }) $notes[$i] @{ path = $it.output; exists = ($null -ne $it.old); old = $it.old; new = $it.new } }
            elseif ($notes[$i]) { Add-AgentEvent $State 'status' @{ text = $notes[$i] } }
        }
        if ($r.checkpoint -and $r.checkpoint.Files.Count) { Add-ChangeSetEvent $State $r.checkpoint 'Data files converted for Copilot'; $wrote = $true }
    } catch { Write-CCBLogError agent 'data import' $_ } finally { Exit-Activity $State $prevActivity }
    if (@(Sync-OneFilePages $State).Count) { $wrote = $true }
    $wrote
}

function Sync-DataMirrors {
    <# Data copies (JS files that wrap a JSON file) follow their JSON: after each task and when a
       project opens. What was rewritten is one change set; problems are said in the chat. With
       -Import, data files are converted first (Sync-DataImports); otherwise that happens only when
       a work request starts, never just because a project opened or a task ended. #>
    param($State, [switch]$Import)
    if (-not $State.ProjectRoot) { return }
    if ($Import) { $null = Sync-DataImports $State }
    if (-not (Test-DataCopiesOn $State.AppRoot)) { return }   # setting dataCopies off
    try {
        $r = Update-DataMirrors $State.ProjectRoot
        $notes = @(Format-DataMirrorNotes $r)
        $items = @($r.items)
        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items[$i]
            if ($it.status -eq 'updated' -or $it.status -eq 'marked') {
                # A write like any other: a card with the diff in the chat, not only a note.
                Add-OwnChangeEvent $State 'write' "$($it.js) (data copy of $($it.json))" $notes[$i] @{ path = $it.js; exists = $true; old = $it.old; new = $it.new }
            } else { Add-AgentEvent $State 'status' @{ text = $notes[$i] } }
        }
        if ($r.checkpoint -and $r.checkpoint.Files.Count) { Add-ChangeSetEvent $State $r.checkpoint 'Data copies updated from their JSON' }
    } catch { Write-CCBLogError agent 'data copies' $_ }
}

function Add-ChangeSetEvent {
    <# The 'checkpoint' event of a finished change set (History tab): its files, what asked for it
       (title) and the lines added and removed per file. $Extra adds fields (contents for MCP). #>
    param($State, $Checkpoint, [string]$Title, [hashtable]$Extra = @{})
    if (-not $Checkpoint -or -not $Checkpoint.Files.Count) { return }
    $counts = @(try { Get-CheckpointChanges $State.ProjectRoot $Checkpoint | ForEach-Object { @{ path = $_.path; added = [int]$_.added; removed = [int]$_.removed; created = [bool]$_.created; deleted = [bool]$_.deleted } } } catch { Write-CCBLogError agent 'change set counts' $_ })
    $t = ("$Title" -replace '\s+', ' ').Trim(); if ($t.Length -gt 120) { $t = $t.Substring(0, 117) + '...' }
    $data = @{ files = @($Checkpoint.Files.Keys); title = $t; counts = $counts; changeSet = $Checkpoint.Id }
    foreach ($k in $Extra.Keys) { $data[$k] = $Extra[$k] }
    Add-AgentEvent $State 'checkpoint' $data
}

function Test-NoAnswerError($Events) {
    <# Whether a step's error events are all "Copilot gave no usable answer" (it stopped, stalled or
       said it could not respond): worth another try after a pause, unlike a broken runbook. #>
    $errs = @($Events | Where-Object { $_.type -eq 'error' })
    if (-not $errs.Count) { return $false }
    foreach ($e in $errs) { if ("$($e.text)" -notmatch '(?i)NoAnswer|stopped without answering|finished without a reply|no usable answer|wasn.t able to respond') { return $false } }
    $true
}

function Get-ChainRetryWaits($Config) {
    <# Seconds to wait before each new try of a step Copilot gave no answer to (pacing chainRetrySec). #>
    $w = if ($Config -and $Config.pacing -and $null -ne $Config.pacing.chainRetrySec) { @($Config.pacing.chainRetrySec) } else { @(120, 300) }
    @($w | ForEach-Object { [double]$_ } | Where-Object { $_ -gt 0 })
}

function Enter-Activity($State, [string]$Kind, [string]$Label) {
    <# What StreamHub is busy with now, for the chat's waiting indicator: a kind (newchat, page,
       syntax, tests, index, wait, agent, busy; the app adds light lines per kind) and a plain label.
       Returns what was there before, for Exit-Activity. #>
    $prev = @{ kind = "$($State.Activity.kind)"; label = "$($State.Activity.label)" }
    $State.Activity.kind = $Kind; $State.Activity.label = $Label
    Set-WorkPhase $State $Label -Step   # the waiting card's status line and activity log
    $prev
}

function New-RunWatch($State, [string]$Id, [string]$Label, [string]$Command) {
    <# Live view of a running command for the app (Invoke-RunAction -OnProgress): the run card with
       this id shows its elapsed time, last output lines and whether it seems to wait ($State.RunLive,
       sent with the app state, never saved). Clear it with Stop-RunWatch. #>
    $State.RunLive = @{ id = $Id; label = $Label; command = $Command; elapsed = 0; lines = @(); quietSec = 0; state = 'running' }
    $st = $State
    { param($pr) if ($st.RunLive -and $st.RunLive.id -eq $Id) { $st.RunLive = @{ id = $Id; label = $Label; command = $Command; elapsed = [int]$pr.elapsed; lines = @($pr.lines); quietSec = [int]$pr.quietSec; state = "$($pr.state)" } } }.GetNewClosure()
}

function Stop-RunWatch($State, [string]$Id) {
    if ($State.RunLive -and $State.RunLive.id -eq $Id) { $State.RunLive = $null }
}

function Exit-Activity($State, $Prev) {
    $State.Activity.kind = "$($Prev.kind)"; $State.Activity.label = "$($Prev.label)"
}

function Wait-ChainPause($State, [double]$Seconds, [string]$Label = 'Pausing before the next step') {
    $prev = Enter-Activity $State 'wait' $Label
    try { Wait-ChainPauseCore $State $Seconds } finally { Exit-Activity $State $prev }
}

function Wait-ChainPauseCore($State, [double]$Seconds) {
    <# Waits, but stops early when the user stops the chain. Returns $false when stopped. #>
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        if ($State.Cancel -or $State.Stop) { return $false }
        Start-Sleep -Milliseconds 250
    }
    $true
}

function Invoke-ChainJob {
    <# Runs a chain (Runbooks/NAME.chain.md): its runbooks, fetch prompts and scripts one after
       another. With stopOnError (the default) the first failing step ends the chain. Scripts run
       through Invoke-ChainScript; what they change is one change set, so Undo restores it. #>
    param($State, [string]$Name)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; return }
    $root = $State.ProjectRoot
    $item = Get-Chains $root | Where-Object name -eq $Name | Select-Object -First 1
    if (-not $item) { Add-AgentEvent $State 'error' @{ text = "There is no chain named '$Name'." }; return }
    if (@($item.problems).Count) {
        Add-AgentEvent $State 'error' @{ text = "Chain '$($item.title)' cannot start: $(@($item.problems) -join '; ')."; code = 'CHAIN'; hint = "Fix the steps in $($item.path) and run it again." }
        return
    }
    $chain = Read-Chain ([IO.File]::ReadAllText((Resolve-ProjectPath $root $item.path)))
    $total = @($chain.steps).Count
    $lines = New-Object System.Collections.Generic.List[string]
    $failed = 0; $stopped = $false
    $cp = [pscustomobject]@{ Value = $null }   # the change set, made at the first script step
    $State.InChain = $true; $State.Busy = $true; $State.Cancel = $false
    $betweenSec = if ($State.Config -and $State.Config.pacing -and $null -ne $State.Config.pacing.chainStepSec) { [double]$State.Config.pacing.chainStepSec } else { 10 }
    try {
        Add-AgentEvent $State 'status' @{ text = "Running chain '$($item.title)' ($total step(s))..." }
        Write-CCBLog info agent "Chain $Name" @{ steps = $total }
        foreach ($step in @($chain.steps)) {
            if ($State.Cancel -or $State.Stop) { $stopped = $true; break }
            $label = "$($step.kind) $($step.target)"
            Add-AgentEvent $State 'status' @{ text = "Chain '$($item.title)', step $($step.n) of ${total}: $label" }
            # A short pause between Copilot steps: many requests in a row make Copilot stop answering.
            if ($step.kind -notin 'script', 'download' -and $step.n -gt 1 -and $betweenSec -gt 0) { if (-not (Wait-ChainPause $State $betweenSec)) { $stopped = $true; break } }
            $ok = $true; $why = ''
            $waits = @(Get-ChainRetryWaits $State.Config); $try = 0
            while ($true) {
                $from = [int]$State.Seq
                switch ($step.kind) {
                    'runbook' {
                        # A text runbook (NAME.prompt.md) runs as one; a checked-JSON runbook gets the inputs.
                        if (-not @(Get-Runbooks $root | Where-Object name -eq $step.target).Count -and @(Get-FetchPrompts $root | Where-Object name -eq $step.target).Count) { Invoke-FetchJob $State $step.target }
                        else { Invoke-RunbookJob $State $step.target -Inputs @($step.with) }
                    }
                    'fetch' { Invoke-FetchJob $State $step.target }
                    'script' { $r = Invoke-ChainScript $State $item $step $cp; $ok = $r.ok; $why = $r.why }
                    'download' { $r = Invoke-ChainDownload $State $item $step $cp; $ok = $r.ok; $why = $r.why }
                }
                if ($step.kind -in 'script', 'download') { break }
                $stepEvents = @(Get-AgentEvents $State $from)
                $errs = @($stepEvents | Where-Object { $_.type -eq 'error' })
                if (-not $errs.Count) { $ok = $true; $why = ''; break }
                $ok = $false; $why = 'see the error above'
                # Copilot gave no answer (it stops answering after many requests in a row): wait, then
                # try the step again in a new chat. Other errors (a broken runbook) fail at once.
                if ($try -ge $waits.Count -or -not (Test-NoAnswerError $stepEvents) -or $State.Cancel -or $State.Stop) { break }
                $wait = $waits[$try]; $try++
                Add-AgentEvent $State 'status' @{ text = "Copilot gave no answer to step $($step.n). Waiting $([int]$wait) s, then trying it again in a new chat (try $($try + 1) of $($waits.Count + 1))." }
                Write-CCBLog info agent "Chain $Name step $($step.n): no answer, retry after $wait s" @{ try = $try }
                if (-not (Wait-ChainPause $State $wait "Waiting $([int]$wait) s, then trying step $($step.n) again in a new chat")) { break }
                $State.NeedNewChat = $true
            }
            if ($State.Cancel -or $State.Stop) { $stopped = $true; $lines.Add("$($step.n). $label - stopped"); break }
            $lines.Add("$($step.n). $label - $(if ($ok) { 'done' } else { "failed: $why" })")
            if (-not $ok) {
                $failed++
                if ($chain.stopOnError) { break }
            }
        }
        $done = $lines.Count
        $head = if ($stopped) { "Chain '$($item.title)' stopped by the user after $done of $total step(s)." }
            elseif ($failed -and $chain.stopOnError) { "Chain '$($item.title)' stopped at a failing step ($done of $total step(s) run)." }
            elseif ($failed) { "Chain '$($item.title)' finished with $failed failed step(s)." }
            else { "Chain '$($item.title)' finished: all $total step(s) done." }
        if ($failed -and -not $stopped) {
            Add-AgentEvent $State 'error' @{ text = "$head`n" + ($lines -join "`n"); code = 'CHAIN'; hint = 'The step list says which step failed and why; fix it and run the chain again.' }
        } else {
            Add-AgentEvent $State $(if ($stopped) { 'status' } else { 'chain' }) @{ name = $Name; text = "$head`n" + ($lines -join "`n") }
        }
    } catch {
        Write-CCBLogError agent "Chain $Name failed" $_
        Add-AgentEvent $State 'error' @{ text = "Chain '$Name' failed: $($_.Exception.Message)"; record = $_ }
    } finally {
        if ($cp.Value) {
            try { Clear-RunSnapshot $cp.Value } catch { Write-CCBLogError agent 'run snapshot' $_ }
            if (-not $cp.Value.Files.Count) { Remove-Item $cp.Value.Dir -Recurse -Force -ErrorAction SilentlyContinue }
            else { Add-ChangeSetEvent $State $cp.Value "Chain: $($item.title)" }
        }
        try {
            $fixed = @(Restore-SourceData $root)
            if ($fixed.Count) { Add-OwnChangeEvent $State 'restore' "$(@($fixed).Count) read-only file(s)" 'Source/ and protected files are read-only; StreamHub undid changes to them.' -Output ($fixed -join "`n") }
        } catch { Write-CCBLogError agent 'source data' $_ }
        $State.InChain = $false; $State.NeedNewChat = $true
        $State.Busy = $false; $State.Cancel = $false
    }
}

function Publish-PackagesNeeded {
    <# A "packages needed" card when a package.json lists packages node_modules does not have: once
       per folder and set of missing packages in this session (after a task and at project open). #>
    param($State)
    if (-not $State.ProjectRoot) { return }
    try {
        if (-not $State.PackagesShown) { $State.PackagesShown = @{} }
        $npm = [bool](Get-RealCommand 'npm')
        foreach ($it in @(Get-PackageState $State.ProjectRoot | Where-Object { @($_.missing).Count })) {
            $key = "$($State.ProjectRoot)|$(Get-PackagesKey $it)"
            if ($State.PackagesShown.ContainsKey($key)) { continue }
            $State.PackagesShown[$key] = $true
            Add-AgentEvent $State 'packages-needed' @{ folder = $it.folder; text = (Format-PackageNeed $it); npm = $npm }
        }
    } catch { Write-CCBLogError agent 'packages check' $_ }
}

function Invoke-PackagesJob {
    <# npm install for one package.json folder ('' = the project root), or for every one with
       missing packages when $Folder is $null: started by a person (the card, or Settings), never by
       StreamHub itself. A run card per folder with npm's output; package-lock.json changes are a
       change set. Network failures get a hint (proxy, registry). #>
    param($State, $Folder = $null)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; return }
    $root = $State.ProjectRoot
    if (-not (Get-RealCommand 'npm')) {
        Add-AgentEvent $State 'error' @{ text = 'npm is not installed on this computer, so the packages cannot be installed.'; code = 'NPM'; hint = 'Settings > This computer > Node.js > Install for me (it brings npm), then run npm install again.' }
        return
    }
    $all = @(Get-PackageState $root)
    # One folder when given ('' is the root); $null (the API without a folder): every folder with missing packages.
    $todo = @(if ($null -ne $Folder) { $all | Where-Object { $_.folder -eq $Folder } } else { $all | Where-Object { @($_.missing).Count } })
    if (-not $todo.Count) { Add-AgentEvent $State 'status' @{ text = $(if ($all.Count) { 'All packages are installed already.' } else { 'This project has no package.json.' }) }; return }
    $State.Busy = $true; $State.Cancel = $false
    $cp = $null
    try {
        foreach ($it in $todo) {
            if ($State.Cancel -or $State.Stop) { break }
            $cmd = Get-NpmInstallCommand $it.folder
            $id = 'npm-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            Add-AgentEvent $State 'action' @{ id = $id; action = 'run'; target = $cmd; status = 'running'; by = 'streamhub' }
            $State.Activity.kind = 'install'; $State.Activity.label = "Installing packages$(if ($it.folder) { " in $($it.folder)" })"
            $lockRel = ($(if ($it.folder) { "$($it.folder)/" } else { '' }) + 'package-lock.json')
            $lockFull = Join-Path $root $lockRel.Replace('/', '\')
            $lockBefore = if (Test-Path -LiteralPath $lockFull) { [IO.File]::ReadAllText($lockFull) } else { $null }
            if (-not $cp) { $cp = New-Checkpoint $root 'npm install' }
            Save-CheckpointFile $cp $root $lockFull
            $timeout = [Math]::Max(900, [int]$State.Config.commandTimeoutSec)
            $watch = New-RunWatch $State $id 'npm install' $cmd
            try { $r = Invoke-RunAction $root $cmd -TimeoutSec $timeout -MaxChars 6000 -CancelCheck ({ [bool]$State.Cancel }.GetNewClosure()) -OnProgress $watch } finally { Stop-RunWatch $State $id }
            $ok = (-not $r.timedOut) -and (-not $r.cancelled) -and ($r.exitCode -eq 0)
            $status = if ($r.cancelled) { 'stopped by the user' } elseif ($r.timedOut) { "timed out after $timeout s" } else { "exit code $($r.exitCode)" }
            $out = "$status`n$($r.output)"
            if (-not $ok -and "$($r.output)" -match '(?i)ETIMEDOUT|ECONNREFUSED|ECONNRESET|ENOTFOUND|EAI_AGAIN|proxy|SELF_SIGNED|UNABLE_TO_GET_ISSUER|certificate|E403|E401') {
                $out += "`nnpm could not reach its package registry. On a company network this is usually a proxy or a blocked registry: ask IT for the npm registry address to use (npm config set registry ADDRESS), or build the app without npm."
            }
            $after = if (Test-Path -LiteralPath $lockFull) { [IO.File]::ReadAllText($lockFull) } else { $null }
            if ($after -eq $lockBefore) { $cp.Files.Remove($lockRel) }
            Add-AgentEvent $State 'action-result' @{ id = $id; ok = $ok; status = $(if ($ok) { 'ok' } else { 'failed' }); summary = "npm install$(if ($it.folder) { " in $($it.folder)" }): $status"; output = (Limit-Text $out 4000); changed = $true }
        }
        $left = @(Get-PackageState $root | Where-Object { @($_.missing).Count -and (@($todo | ForEach-Object { $_.folder }) -contains $_.folder) })
        if ($left.Count) { Add-AgentEvent $State 'error' @{ text = "Packages are still missing after npm install: $(@($left | ForEach-Object { Format-PackageNeed $_ }) -join '; ')."; code = 'NPM'; hint = 'The card above shows npm''s output.' } }
        else { Add-AgentEvent $State 'status' @{ text = "Packages installed: every package in $(@($todo | ForEach-Object { if ($_.folder) { "$($_.folder)/package.json" } else { 'package.json' } }) -join ', ') is there now." } }
    } catch {
        Write-CCBLogError agent 'npm install' $_
        Add-AgentEvent $State 'error' @{ text = "npm install failed: $($_.Exception.Message)"; record = $_ }
    } finally {
        $State.Activity.label = ''
        $State.Busy = $false
        if ($cp) {
            if (-not $cp.Files.Count) { Remove-Item $cp.Dir -Recurse -Force -ErrorAction SilentlyContinue }
            else { Add-ChangeSetEvent $State $cp 'npm install' }
        }
    }
}

function Invoke-ScriptJob {
    <# Runs one script from the project's Scripts/ folder on its own (Automation > Scripts, or a
       schedule), with the same rules as a script step in a chain (Invoke-ChainScript): inside the
       project, approved once and again after it changes (setting chainScripts), Microsoft 365 or
       deleting scripts by a person every time. What it changes is one change set. #>
    param($State, [string]$Path)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; return }
    $cp = [pscustomobject]@{ Value = $null }
    $State.Busy = $true; $State.Cancel = $false
    try {
        Add-AgentEvent $State 'status' @{ text = "Running script $Path..." }
        Write-CCBLog info agent "Script $Path"
        $r = Invoke-ChainScript $State ([pscustomobject]@{ title = $Path; direct = $true }) ([pscustomobject]@{ target = $Path; args = '' }) $cp
        if ($r.ok) { Add-AgentEvent $State 'script' @{ name = $Path; text = "Script $Path finished: $($r.why)." } }
        else { Add-AgentEvent $State 'error' @{ text = "Script $Path did not finish: $($r.why)."; code = 'SCRIPT'; hint = 'The card above shows its output; fix the script and run it again.' } }
    } catch {
        Write-CCBLogError agent "Script $Path failed" $_
        Add-AgentEvent $State 'error' @{ text = "Script $Path failed: $($_.Exception.Message)"; record = $_ }
    } finally {
        if ($cp.Value) {
            try { Clear-RunSnapshot $cp.Value } catch { Write-CCBLogError agent 'run snapshot' $_ }
            if (-not $cp.Value.Files.Count) { Remove-Item $cp.Value.Dir -Recurse -Force -ErrorAction SilentlyContinue }
            else { Add-ChangeSetEvent $State $cp.Value "Script: $Path" }
        }
        $State.Busy = $false; $State.Cancel = $false
    }
}

function Invoke-ChainScript {
    <# One script step of a chain. Same rules as Copilot's commands: deleting or moving outside the
       project is refused; scripts that delete data or use Microsoft 365 need a person every time
       (refused without one, as in MCP). Other scripts: setting chainScripts approve-once (a person
       approves a script the first time and after it changed), always-ask, or off. Returns @{ ok; why }. #>
    param($State, $Chain, $Step, $CheckpointBox)
    $root = $State.ProjectRoot
    $mode = "$($State.Config.chainScripts)"; if (-not $mode) { $mode = 'approve-once' }
    if ($mode -eq 'off') { return @{ ok = $false; why = 'scripts in chains are turned off (Settings > Chains)' } }
    $sc = Resolve-ChainScript $root $Step.target $Step.args
    if ($sc.error) { return @{ ok = $false; why = $sc.error } }
    $outside = Test-DeleteScope $root $sc.command
    if ($outside) { return @{ ok = $false; why = "refused: $outside" } }
    $text = (Read-TextFile $sc.full).Text
    $risk = Get-CommandRisk "$($sc.command)`n$text"
    $risky = [bool]($risk.m365 -or $risk.destructive)
    if ($risky -and $State.Headless) { return @{ ok = $false; why = "this script $($risk.reasons -join ', '); that needs a person in the StreamHub window" } }
    $id = 'chain-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $preview = if ($text.Length -gt 20000) { $text.Substring(0, 20000) + "`n..." } else { $text }
    # The script that runs, shown on the card (a preview: path and text, like a file change).
    $evt = @{ id = $id; action = 'run'; target = $sc.command; preview = @{ path = $sc.path; exists = $true; old = $null; new = $preview } }
    $who = $(if ($Chain.direct) { 'This' } else { "Chain '$($Chain.title)'" })   # direct: run from Automation > Scripts
    $hash = Get-ScriptHash $sc.full
    $ask = $risky -or $mode -eq 'always-ask' -or -not (Test-ScriptApproved $root $sc.path $hash)
    if ($ask) {
        $warn = if ($risky) { "Human in the loop: this script $($risk.reasons -join ', '). Only approve it if you want exactly this to happen; it is asked every time." }
            elseif ($mode -eq 'approve-once') { "$who runs $($sc.path) for the first time, or the script changed since it was approved. Check it: once approved, it runs without asking until it changes." }
            else { "$who runs $($sc.path)." }
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'awaiting'; warning = $warn })
        $d = Wait-Approval $State $id $true
        if ($d.decision -ne 'approve') {
            Add-AgentEvent $State 'action-result' @{ id = $id; ok = $false; status = 'rejected'; output = $d.note; decidedBy = $d.by }
            return @{ ok = $false; why = 'not approved' }
        }
        Add-AgentEvent $State 'action-result' @{ id = $id; ok = $true; status = 'running'; decidedBy = $d.by }
        if (-not $risky -and $mode -eq 'approve-once') { Add-ApprovedScript $root $sc.path $hash }
    } else {
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'running' })
    }
    if (-not $CheckpointBox.Value) { $CheckpointBox.Value = New-Checkpoint $root $(if ($Chain.direct) { "Script: $($sc.path)" } else { "Chain: $($Chain.title)" }) }
    $cp = $CheckpointBox.Value
    $snap = try { Start-RunSnapshot $cp $root } catch { Write-CCBLogError agent 'run snapshot' $_; $null }
    $watch = New-RunWatch $State $id "$($sc.path)" $sc.command
    try { $r = Invoke-RunAction $root $sc.command -TimeoutSec $State.Config.commandTimeoutSec -CancelCheck ({ [bool]$State.Cancel }.GetNewClosure()) -OnProgress $watch } finally { Stop-RunWatch $State $id }
    if ($snap) { try { $null = Complete-RunSnapshot $cp $root $snap } catch { Write-CCBLogError agent 'run snapshot' $_ } }
    # The helper program's own refresh script downloads the saved web data again into Source/Web/: kept.
    $accept = @()
    if ("$($sc.path)" -eq 'Scripts/Refresh-Web-Data.ps1') {
        $saves = try { [IO.File]::ReadAllText((Join-Path $root '.streamhub\web-saves.json')) | ConvertFrom-Json } catch { $null }
        $accept = @(foreach ($w in $saves) { "$($w.file)" })
    }
    $fixed = @(Restore-SourceData $root -Accept $accept)
    $status = if ($r.cancelled) { 'stopped by the user' } elseif ($r.timedOut) { "timed out after $($State.Config.commandTimeoutSec)s" } else { "exit code $($r.exitCode)" }
    $ok = (-not $r.timedOut) -and (-not $r.cancelled) -and ($r.exitCode -eq 0)
    $out = "$status`n$($r.output)"
    if ($fixed.Count) { $out += "`nSource/ and protected files are read-only; StreamHub put back: $($fixed -join '; ')" }
    Add-AgentEvent $State 'action-result' @{ id = $id; ok = $ok; status = $(if ($ok) { 'ok' } else { 'failed' }); summary = "ran $($sc.path): $status"; output = (Limit-Text $out 4000); changed = $true }
    @{ ok = $ok; why = $status }
}

function Invoke-ChainDownload {
    <# One download step of a chain: a SharePoint or OneDrive file into the project through
       StreamHub's Edge (signed in to Microsoft 365). A person approves each link and place once
       (refused without one, as in MCP); after that it runs on schedules too. The file replaces the
       earlier download in the chain's change set (Undo takes it back). Returns @{ ok; why }. #>
    param($State, $Chain, $Step, $CheckpointBox)
    $root = $State.ProjectRoot
    $bad = Test-DownloadAddress $Step.target
    if ($bad) { return @{ ok = $false; why = $bad } }
    $t = Get-DownloadTarget $root $Step.target $Step.args
    if ($t.error) { return @{ ok = $false; why = $t.error } }
    $id = 'chain-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $evt = @{ id = $id; action = 'web'; target = "$($Step.target) -> $($t.rel)" }
    $key = "download: $($Step.target) to $($t.rel)"
    if (-not (Test-ScriptApproved $root $key 'download')) {
        if ($State.Headless) { return @{ ok = $false; why = 'a download needs a person to approve it once in the StreamHub window' } }
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'awaiting'; warning = "Chain '$($Chain.title)' downloads this file from Microsoft 365 into $($t.rel), with your sign-in in StreamHub's Edge. Once approved, this link and place download without asking (also on a schedule)." })
        $d = Wait-Approval $State $id $true
        if ($d.decision -ne 'approve') {
            Add-AgentEvent $State 'action-result' @{ id = $id; ok = $false; status = 'rejected'; output = $d.note; decidedBy = $d.by }
            return @{ ok = $false; why = 'not approved' }
        }
        Add-AgentEvent $State 'action-result' @{ id = $id; ok = $true; status = 'running'; decidedBy = $d.by }
        Add-ApprovedScript $root $key 'download'
    } else {
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'running' })
    }
    $tmp = Join-Path $env:TEMP ('ccb-dl-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $tmp
    try {
        $null = Get-Bridge $State   # StreamHub's Edge is running (and signed in)
        $State.Activity.kind = 'download'; $State.Activity.label = "Downloading $(Split-Path $t.rel -Leaf)"
        $r = Invoke-EdgeDownload -Port $State.Config.cdpPort -Url (Add-DownloadParam $Step.target) -Folder $tmp -CancelCheck ({ [bool]$State.Cancel }.GetNewClosure())
        if (-not $r.error) { $r.error = Test-DownloadContent $r.path $t.rel }
        if ($r.error) {
            Add-AgentEvent $State 'action-result' @{ id = $id; ok = $false; status = 'failed'; summary = "download failed: $($r.error)"; output = $r.error }
            return @{ ok = $false; why = $r.error }
        }
        if (-not $CheckpointBox.Value) { $CheckpointBox.Value = New-Checkpoint $root "Chain: $($Chain.title)" }
        Save-CheckpointFile $CheckpointBox.Value $root $t.full
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $t.full)
        Copy-Item -LiteralPath $r.path -Destination $t.full -Force
        $kb = [Math]::Max(1, [int]((Get-Item -LiteralPath $t.full).Length / 1KB))
        Write-CCBLog info agent "Chain download" @{ to = $t.rel; kb = $kb }
        Add-AgentEvent $State 'action-result' @{ id = $id; ok = $true; status = 'ok'; summary = "downloaded $($t.rel) ($kb KB)"; output = "Saved $($t.rel) ($kb KB) from $($Step.target)."; changed = $true }
        @{ ok = $true; why = '' }
    } catch {
        Write-CCBLogError agent 'Chain download' $_
        Add-AgentEvent $State 'action-result' @{ id = $id; ok = $false; status = 'failed'; summary = "download failed: $($_.Exception.Message)"; output = $_.Exception.Message }
        @{ ok = $false; why = $_.Exception.Message }
    } finally {
        $State.Activity.label = ''
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$script:AgentGoAhead = 'Proceed with your plan. Where the instructions above do not decide something, use your best assumptions and list them at the start. Then give the result in exactly the form the instructions ask for.'
$script:AgentFileMaxBytes = 50MB

function Resolve-AgentFiles {
    <# Project files to attach to an agent message: full paths, checked (inside the project, not in
       .streamhub/, existing, at most 50 MB each, at most 10). Throws with what is wrong. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Paths | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim().Trim('`', '"', "'").Replace('\', '/') } | Select-Object -Unique)) {
        if ($p -match '(?i)^\.streamhub(/|$)') { throw "$p is one of StreamHub's own records; attach a project file instead." }
        $full = Resolve-ProjectPath $ProjectRoot $p
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "There is no file $p in the project." }
        if (Get-SecretFileKind $full) { throw "$p holds secrets (keys, passwords, tokens) and is never attached." }
        if ((Get-Item -LiteralPath $full).Length -gt $script:AgentFileMaxBytes) { throw "$p is larger than 50 MB; Copilot does not take files that large." }
        $out.Add($full)
    }
    if ($out.Count -gt 10) { throw 'At most 10 files can be attached to one message.' }
    $out.ToArray()
}

function Get-AgentAttachments {
    <# @path references in a message to an agent that name project files: those files are attached
       (uploaded as with Copilot's + button), and in the text each becomes the file name, because
       typing @ in Copilot's message box opens its @ list. Returns @{ text; files (full); names }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $files = New-Object System.Collections.Generic.List[string]; $names = New-Object System.Collections.Generic.List[string]
    $new = [regex]::Replace($Text, '(?<![\w@])@([^\s,;()<>"''`]+[^\s,;()<>"''`.:!?])', {
        param($m)
        $rel = $m.Groups[1].Value.Replace('\', '/')
        if ($rel -match '(?i)^\.streamhub(/|$)') { return $m.Value }
        $full = try { Resolve-ProjectPath $ProjectRoot $rel } catch { $null }
        if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { return $m.Value }
        if (-not $files.Contains($full)) { $files.Add($full); $names.Add($rel) }
        '`' + [IO.Path]::GetFileName($full) + '` (attached)'
    })
    [pscustomobject]@{ text = $new; files = $files.ToArray(); names = $names.ToArray() }
}

function Get-AgentSpec($Meta) {
    <# The agent fields of a runbook or fetch prompt header: agent (researcher / analyst) and files
       (project files to attach, comma separated). #>
    $get = { param($k) if ($null -eq $Meta) { '' } elseif ($Meta -is [System.Collections.IDictionary]) { "$($Meta[$k])" } else { "$($Meta.$k)" } }
    $a = (& $get 'agent').Trim().ToLowerInvariant()
    [pscustomobject]@{
        agent = $(if ($a -in 'researcher', 'analyst') { Get-AgentDisplayName $a } else { '' })
        files = @((& $get 'files') -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}

function Save-AgentCharts {
    <# Saves the charts in Copilot's last reply (Analyst draws them on a canvas) as PNG files in
       Runbooks/Exports/ and says so in the chat with an Open link. Returns the project paths. #>
    param($State, [string]$Prefix = 'analyst-chart')
    $saved = New-Object System.Collections.Generic.List[string]
    try {
        $charts = @(Get-CopilotCharts (Get-Bridge $State))
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $n = 0
        foreach ($bytes in $charts) {
            $n++
            $rel = Get-LayoutPath Exports "$Prefix-$stamp$(if ($charts.Count -gt 1) { "-$n" }).png"
            $full = Resolve-ProjectPath $State.ProjectRoot $rel
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
            [IO.File]::WriteAllBytes($full, [byte[]]$bytes)
            $saved.Add($rel)
            Add-AgentEvent $State 'status' @{ text = "Chart saved: $rel"; path = $rel }
        }
    } catch { Write-CCBLogError agent 'saving charts' $_ }
    $saved.ToArray()
}

function Send-AgentJobMessage {
    <# The first message of a runbook or fetch prompt, to its agent when the header names one (with
       its files attached). Researcher may answer with a plan first: a runbook runs unattended and
       its instructions are the answer, so the fixed go-ahead is sent (at most twice). #>
    param($State, $Spec, [string]$Message, $AgentSpec)
    if (-not $AgentSpec -or -not $AgentSpec.agent) { return (Send-WithSources $State $Spec $Message) }
    $files = @(Resolve-AgentFiles $State.ProjectRoot $AgentSpec.files)
    Add-AgentEvent $State 'status' @{ text = "Asking $($AgentSpec.agent)$(if ($files.Count) { " with $($files.Count) attached file(s)" }) (this can take several minutes)..." }
    $r = Send-WithSources $State $Spec $Message -Agent $AgentSpec.agent -Files $files
    for ($i = 0; $i -lt 2 -and $r -and $r.IsPlan -and -not $r.Cancelled; $i++) {
        Add-AgentEvent $State 'status' @{ text = "$($AgentSpec.agent) made a research plan; the instructions are its answer, so it goes ahead." }
        $r = Send-WithSources $State $Spec $script:AgentGoAhead -Long
    }
    if ($r -and $r.Agent -ne $AgentSpec.agent -and -not ($r.PSObject.Properties['Source'] -and $r.Source -eq 'page') -and -not $r.Cancelled) {
        Add-AgentEvent $State 'status' @{ text = "This answer came from $(if ($r.Agent) { $r.Agent } else { 'Copilot itself' }), not from $($AgentSpec.agent)." }
    }
    $r
}

function Get-AgentPromptLine([string]$AppRoot, [string]$Name) {
    $file = Join-Path $AppRoot "prompts\$Name"
    if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file).Trim() } else { '' }
}

function Add-AgentOutputFormat {
    <# A message to Researcher or Analyst with what the answer should cover and look like, so it can
       be checked and reused. Analyst always gets its scope (prompts/agent-scope-analyst.md: data
       used, rows left out, assumptions, method, no invented values). The layout (agent-output.md for
       Researcher, agent-output-analyst.md for Analyst) is left out when the message already says
       how the answer should look. #>
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Agent = '')
    $analyst = $Agent -match '(?i)^analyst$'
    $lines = New-Object System.Collections.Generic.List[string]
    if ($analyst) { $lines.Add((Get-AgentPromptLine $AppRoot 'agent-scope-analyst.md')) }
    if ($Text -notmatch '(?i)\b(format|formatted|json|csv|markdown|tables?|bullets?|bullet points|columns?|yaml|xml|spreadsheet)\b') {
        $lines.Add((Get-AgentPromptLine $AppRoot $(if ($analyst) { 'agent-output-analyst.md' } else { 'agent-output.md' })))
    }
    $add = @($lines | Where-Object { $_ })
    if (-not $add.Count) { return $Text }
    "$($Text.TrimEnd())`n`n$($add -join "`n")"
}

function Invoke-AgentRun {
    <# Sends a message to one of Copilot's agents (Researcher, Analyst) by mentioning it, as typed:
       no coding instructions or project context. A new run starts a fresh Copilot chat; -FollowUp
       continues the agent's chat (answers to Researcher's plan), without a new mention. The reply
       says which agent answered; Researcher's plan and questions end with an 'agent-plan' event,
       so the person answers them (StreamHub never answers for them). #>
    param($State, [Parameter(Mandatory)][string]$Agent, [Parameter(Mandatory)][string]$Text, [switch]$FollowUp, [string]$AutoWhy = '')
    $name = Get-AgentDisplayName $Agent
    $State.Busy = $true; $State.Cancel = $false
    try {
        Add-AgentEvent $State 'user' @{ text = $Text; agent = $name }
        Add-AgentEvent $State 'kind' @{ taskKind = 'agent'; agent = $name; auto = [bool]$AutoWhy }
        # Agent: Auto picked this agent (Get-AutoAgent): say why, so a wrong pick is easy to spot.
        if ($AutoWhy) { Add-AgentEvent $State 'status' @{ text = "Agent Auto picked $name for $AutoWhy. To send this to Copilot itself, choose Agent: none and send it again." } }
        if (-not $FollowUp -or -not $State.AgentChat) { Start-NewChat $State }
        $State.AgentChat = $name
        Add-AgentEvent $State 'status' @{ text = $(if ($FollowUp) { "Sending your answer to $name; it works on it now (this can take several minutes)." } else { "Asking $name (this can take several minutes)..." }) }
        Write-CCBLog info agent "Agent run: $name" @{ chars = $Text.Length; followUp = [bool]$FollowUp }
        # @path references to project files are attached (uploaded) to the message.
        $att = Get-AgentAttachments $State.ProjectRoot $Text
        $files = @(Resolve-AgentFiles $State.ProjectRoot $att.names)
        if ($files.Count) { Add-AgentEvent $State 'status' @{ text = "Attaching $($att.names -join ', ') (Copilot keeps a copy in your OneDrive, as with its own + button)." } }
        # A new question gets the expected output format (unless it states one); an answer to the plan goes as typed.
        $message = if ($FollowUp) { $att.text } else { Add-AgentOutputFormat $State.AppRoot $att.text $Agent }
        $r = Send-ToCopilot $State $message -Agent $(if ($FollowUp) { '' } else { $name }) -Long -Files $files
        if ($r.Cancelled) { Add-AgentEvent $State 'status' @{ text = "$name stopped." }; $State.AgentChat = $null; $State.NeedNewChat = $true; return }
        if (($r.Result -and $r.Result -ne 'Success') -or -not "$($r.Text)".Trim()) {
            Add-AgentEvent $State 'error' @{ text = "$name gave no usable answer ($($r.Result): $($r.ResultMessage))."; code = 'AGENT' }
            $State.AgentChat = $null; $State.NeedNewChat = $true
            return
        }
        $by = "$($r.Agent)"
        Add-AgentEvent $State 'assistant' @{ text = $r.Text; uncertain = $r.Uncertain; used = $State.Throttle.used; max = $State.Throttle.max; references = @($r.References); agent = $by }
        if (-not $by -and $r.PSObject.Properties['Source'] -and $r.Source -eq 'page') {
            # Read from the page: Copilot's stream did not say who answered.
        } elseif ($by -ne $name) {
            Add-AgentEvent $State 'status' @{ text = "This answer came from $(if ($by) { $by } else { 'Copilot itself' }), not from $name. The agent may not have run; check the Copilot window." }
        }
        # Human in the loop: an agent never gets a Microsoft 365 action confirmed by StreamHub.
        if (@($r.ProposedActions).Count) {
            $what = (@($r.ProposedActions) | ForEach-Object { $_.title } | Where-Object { $_ } | Select-Object -Unique) -join '; '
            Add-AgentEvent $State 'human-required' @{ text = "$name proposed an action in Microsoft 365 ($what). StreamHub never confirms Microsoft 365 actions. Look at it in the Copilot window in Edge and confirm or cancel it yourself." }
        }
        foreach ($claim in @($r.ActionClaims)) {
            Add-AgentEvent $State 'human-required' @{ text = "$name's reply says: ""$claim"" StreamHub did not confirm any Microsoft 365 action. Check Outlook / Teams if this is unexpected." }
        }
        if (-not $r.IsPlan) { $null = Save-AgentCharts $State "$($name.ToLowerInvariant())-chart" }   # Analyst draws charts on the page
        if ($r.IsPlan) {
            # Researcher waits for the person: the plan card asks for answers (or "go ahead").
            Add-AgentEvent $State 'agent-plan' @{ agent = $name }
        } else {
            $State.AgentChat = $null
            $State.NeedNewChat = $true   # the next message starts its own chat
        }
    } catch {
        Write-CCBLogError agent "Agent run $name failed" $_
        Add-AgentEvent $State 'error' @{ text = "$name could not be asked: $($_.Exception.Message)"; record = $_ }
        $State.AgentChat = $null; $State.NeedNewChat = $true
    } finally {
        $State.Busy = $false; $State.Cancel = $false
    }
}

function Get-WebSourcePrompt($State, $Spec) {
    # The text a fetch prompt or runbook adds for its web fields (pages read here, as data).
    if (-not $Spec.any) { return [pscustomobject]@{ text = ''; notes = @() } }
    if (@($Spec.pages).Count) { Add-AgentEvent $State 'status' @{ text = "Reading $(@($Spec.pages).Count) web page(s) named in the header..." } }
    $per = [Math]::Max(4000, [int]([int]$State.Config.resultCharBudget / [Math]::Max(1, @($Spec.pages).Count)))
    New-WebSourceBlock $Spec -PageChars $per
}

function Send-WithSources($State, $Spec, [string]$Message, [string]$Agent = '', [string[]]$Files = @(), [switch]$Long) {
    # Sends with the Work/Web switch set for the header's sources (web: off, work or both: on),
    # only when StreamHub manages the switch (workIq on or off); it is set back afterwards.
    # -Agent mentions Researcher/Analyst (with -Files attached); -Long for follow-ups to an agent.
    $old = $State.WorkIq
    if ($Spec.sources -and $old -in 'on', 'off') { $State.WorkIq = $(if ($Spec.sources -eq 'web') { 'off' } else { 'on' }) }
    try { Send-ToCopilot $State $Message -Agent $Agent -Files $Files -Long:([bool]($Agent -or $Long)) } finally { $State.WorkIq = $old }
}

function Get-SourceSiteNotes($Spec, $References) {
    # A note when Copilot cited pages outside the allowed sites, or cited nothing at all.
    if (-not @($Spec.sites).Count) { return }
    $refs = @($References | Where-Object { $_ -and $_.url })
    if (-not $refs.Count) { return "no sources were cited, so it is not shown that the answer comes from $(@($Spec.sites) -join ', ')" }
    $out = @(Test-SourceSites $refs $Spec.sites)
    if ($out.Count) { "$($out.Count) source(s) are outside the allowed sites: $($out -join ', ')" }
}

function Invoke-FetchJob {
    <# Runs a saved fetch prompt in a fresh Copilot chat and writes the answer to Runbooks/Exports/<name>.md.
       Copilot only answers: action blocks in the answer are not carried out. An existing answer
       file is kept when the fetch fails. #>
    param($State, [string]$Name)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; return }
    $item = Get-FetchPrompts $State.ProjectRoot | Where-Object name -eq $Name | Select-Object -First 1
    if (-not $item) { Add-AgentEvent $State 'error' @{ text = "There is no runbook named '$Name'." }; return }
    $State.Busy = $true; $State.Cancel = $false
    try {
        Add-AgentEvent $State 'status' @{ text = "Running runbook '$Name' (text answer)..." }
        Write-CCBLog info agent "Fetch $Name" @{ promptChars = $item.prompt.Length }
        Start-NewChat $State   # a fetch never mixes with the conversation
        $spec = Get-WebSourceSpec $item
        $agentSpec = Get-AgentSpec $item   # agent: researcher / analyst, files: to attach
        $tk = Get-TaskKind $item.prompt
        $kind = if ($spec.sources -eq 'web') { 'fetch' } elseif ($spec.sources -in 'work', 'both') { 'fetch-m365' } elseif ($tk -eq 'assistant' -or $tk -eq 'mixed') { 'fetch-m365' } else { 'fetch' }
        $web = Get-WebSourcePrompt $State $spec
        $sent = New-Object 'System.Collections.Generic.HashSet[string]'
        $message = New-PromptMessage -AppRoot $State.AppRoot -Kind $kind -Text "$($item.prompt)$(if ($web.text) { "`n`n$($web.text)" })" -Sent $sent
        $r = Send-AgentJobMessage $State $spec $message $agentSpec
        if ($r.Cancelled) { Add-AgentEvent $State 'status' @{ text = "Runbook '$Name' stopped; $($item.output) was left unchanged." }; return }
        if (($r.Result -and $r.Result -ne 'Success') -or -not "$($r.Text)".Trim()) {
            Add-AgentEvent $State 'error' @{ text = "Runbook '$Name' got no usable answer ($($r.Result): $($r.ResultMessage)); $($item.output) was left unchanged." }
            return
        }
        $notes = @($web.notes) + @(Get-SourceSiteNotes $spec $r.References)
        $content = Format-FetchResult -Name $Name -Reply $r.Text -References @($r.References) -Notes $notes
        $path = Save-FetchResult $State.ProjectRoot $Name $content
        if ($agentSpec.agent) { $null = Save-AgentCharts $State "$Name-chart" }
        Add-AgentEvent $State 'fetch' @{ name = $Name; path = $path; text = "Saved the answer to $path. Attach it with @$path." }
    } catch {
        Write-CCBLogError agent "Fetch $Name failed" $_
        Add-AgentEvent $State 'error' @{ text = "Runbook '$Name' failed: $($_.Exception.Message)"; record = $_ }
    } finally {
        $State.NeedNewChat = $true   # the next message starts its own chat
        if (-not $State.InChain) { $State.Busy = $false; $State.Cancel = $false }   # a chain carries on (and keeps a Stop)
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
    if ($State.ContainsKey('TaskIntent') -and $State.TaskIntent -ne 'change') { return $false }
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

function Register-ReadStamp {
    <# Remembers the file as Copilot saw it: -Seen after its own edit or write (the changed lines went
       back to it), else at a read. A line-range edit is valid only while the file is still as read;
       the stale note fires when the file changed since Copilot last saw it. #>
    param($State, [string]$ProjectRoot, [string]$Key, [switch]$Seen)
    if ($null -eq $State.ReadStamps) { $State.ReadStamps = @{} }
    $full = Resolve-ProjectPath $ProjectRoot $Key
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
    $fp = Get-FileFingerprint $full
    $old = $State.ReadStamps[$Key]
    if ($Seen) { $State.ReadStamps[$Key] = @{ read = $(if ($old) { $old.read } else { '' }); seen = $fp } }
    else { $State.ReadStamps[$Key] = @{ read = $fp; seen = $fp } }
}

function Test-RangeEditAllowed {
    <# Why a line-range edit (pairs with a range) cannot be applied, or '': the lines must have been
       read in this task (read PATH:START-END, or the whole file) and the file must be as it was read
       (the fingerprint of that read), else the numbers mean other lines. The refusal shows the
       current lines of the range. #>
    param($State, [string]$ProjectRoot, [string]$Path, $Edits)
    $ranges = @($Edits | Where-Object { $_ -is [hashtable] -and $_.range })
    if (-not $ranges.Count) { return '' }
    $key = "$Path".Replace('\', '/').TrimStart('/').ToLowerInvariant()
    $st = if ($State.ReadStamps) { $State.ReadStamps[$key] } else { $null }
    if (-not $st -or -not $st.read) { return "an edit by line numbers needs the lines read in this task first: read ${Path}:START-END (the numbers must come from that read), then send the edit again, or send a SEARCH/REPLACE edit. Nothing was changed." }
    $full = Resolve-ProjectPath $ProjectRoot $Path
    $fp = Get-FileFingerprint $full
    $lines = (Read-TextFile $full).Text.Replace("`r`n", "`n").Split("`n")
    $fence = '````'
    foreach ($r in $ranges) {
        $from = [int]$r.range.from; $to = [int]$r.range.to
        if ($fp -ne $st.read) {
            $a = [Math]::Max(1, $from); $z = [Math]::Min($lines.Length, [Math]::Max($to, $a))
            $shown = if ($z -ge $a) { "`nCurrent lines $a-$z of ${Path} (line numbers are not part of the file):`n$fence`n" + (($lines[($a - 1)..($z - 1)]) -join "`n") + "`n$fence" } else { '' }
            return "${Path} changed since your read (an edit, or a repair by the helper program), so lines $from-$to are stale.$shown`nRead the file again and send the edit with the numbers it shows, or send a SEARCH/REPLACE edit. Nothing was changed."
        }
        $covered = @($State.ReadRanges[$key] | Where-Object { $_ -and [int]$_.from -le $from -and [int]$_.to -ge $to }).Count -gt 0
        if (-not $covered) { return "lines $from-$to of ${Path} were not among the lines you read this task: read ${Path}:$from-$to first, then send the edit again. Nothing was changed." }
    }
    ''
}

function Get-StaleReadNote {
    # A line for a failed edit when the file changed since Copilot last saw it (a repair or another change by the helper program).
    param($State, [string]$ProjectRoot, [string]$Path)
    $key = "$Path".Replace('\', '/').TrimStart('/').ToLowerInvariant()
    $st = if ($State.ReadStamps) { $State.ReadStamps[$key] } else { $null }
    if (-not $st -or -not $st.seen) { return '' }
    $full = try { Resolve-ProjectPath $ProjectRoot $Path } catch { return '' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return '' }
    if ((Get-FileFingerprint $full) -eq $st.seen) { return '' }
    "Note: ${Path} changed since you last saw it (the helper program repaired or rewrote lines after your read), so lines you remember may differ: go by the current lines shown above, or read the file again."
}

function Get-WholeFileFallback {
    <# For the second failed edit of a small file: the whole file as it is now, so one write block
       ends the loop. '' for a large file; a one-file page (blocks the helper program writes) gets a
       pointer to line-range edits instead. #>
    param([string]$ProjectRoot, [string]$Path, [int]$MaxLines = 400, [int]$MaxChars = 60000)
    $full = Resolve-ProjectPath $ProjectRoot $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return '' }
    $info = Read-TextFile $full
    if ($info.Encoding -eq 'office') { return '' }
    $text = $info.Text.Replace("`r`n", "`n")
    if (Test-OneFileText $text) { return "This page holds blocks the helper program writes (data-streamhub), so it cannot be rewritten whole: read the lines you want to change (read ${Path}:START-END) and send ACTION edit ${Path}:START-END with the new lines, or a SEARCH that copies the current lines exactly." }
    $lines = $text.Split("`n")
    if ($lines.Length -gt $MaxLines -or $text.Length -gt $MaxChars) { return '' }
    $fence = '````'
    "The whole file as it is now ($($lines.Length) lines) is below. Reply with one write block (ACTION write ${Path}) holding the complete new file, the change made:`n$fence`n$text`n$fence"
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
        'no SEARCH/REPLACE pairs' { @{ code = 'EDIT-FORMAT'; reasons = @('Copilot''s edit block had no ####### SEARCH / ####### REPLACE / ####### END markers (or they were not at the start of a line).', 'Copilot meant to replace the whole file; that needs a write block.'); next = "Nothing was changed. $copilotRetries" }; break }
        'needs the lines read in this task|changed since your read|were not among the lines you read' { @{ code = 'EDIT-STALE'; reasons = @('Copilot sent an edit by line numbers (ACTION edit PATH:START-END) without reading those lines in this task, or the file changed since that read (an earlier edit, or a repair by the helper program).'); next = $copilotRetries } }
        'SEARCH text not found' { @{ code = 'EDIT-NOT-FOUND'; reasons = @('The file changed since Copilot read it: an earlier edit in this task, or you edited it.', 'Copilot''s SEARCH lines differ slightly from the file: spaces, quotes, or a line it remembered differently.', 'The change was already made earlier, but with different text.', 'Copilot shortened SEARCH without a line containing only ... (only its first lines were given).'); next = "Nothing was changed. Copilot gets the reason plus the file's closest current lines. $copilotRetries" }; break }
        'reads .* from the internet itself' { @{ code = 'RUN-WEB'; reasons = @('The command, or a project script it runs, reads a web page, script or JSON from the internet itself (curl, Invoke-WebRequest, fetch...), which would skip the rules for reading the web.'); next = 'Copilot is told to use the web action instead (ACTION web, or ACTION web source for the data as sent); sites you did not name still ask first.' }; break }
        'plan mode' { @{ code = 'PLAN-MODE'; reasons = @('"Plan only" mode is on, so changes and commands are not carried out.'); next = 'Switch the mode to "Ask before changes" or "Auto-accept edits" and ask again to carry out the plan.' }; break }
        'is in Source/|read-only' { @{ code = 'SOURCE-DATA'; reasons = @('The step tried to change a file in Source/, which holds your source data and is read-only.'); next = 'Nothing was changed. Copilot is told to write its result elsewhere (for example Work/ or output/).' }; break }
        'file not found|\(file not found\)' { @{ code = 'FILE-NOT-FOUND'; reasons = @('The path does not exist in the project: a typo, another folder, or a file that was never created.', 'For a new file Copilot should use a write block, not an edit.'); next = $copilotRetries }; break }
        'without a path' { @{ code = 'STEP-FORMAT'; reasons = @('The block had no file name after the action name (for example ACTION edit with nothing after it).'); next = $copilotRetries }; break }
        'commands are not allowed' { @{ code = 'RUN-NOT-ALLOWED'; reasons = @('Commands are not allowed for this task (MCP task started without permission to run commands).'); next = 'Copilot is told to finish without running commands.' }; break }
        'needs a person|refused' { @{ code = 'RUN-NEEDS-PERSON'; reasons = @('The command would act on Microsoft 365 or delete data; that always needs a person.'); next = 'Run it yourself if you really want it; Copilot is told not to work around it.' }; break }
        'stopped by the user' { @{ code = 'STOPPED'; reasons = @('You pressed Stop.'); next = 'Changes made so far in this message can be undone (Changes > Undo last change set).' }; break }
        'timed out after' { @{ code = 'RUN-TIMEOUT'; reasons = @('The command ran longer than commandTimeoutSec (it may wait for input, or just be slow).'); next = 'Copilot sees the output so far. Raise commandTimeoutSec in config\harness.local.json for slow builds.' }; break }
        'needs an interactive terminal to ask questions' { @{ code = 'RUN-INTERACTIVE'; reasons = @('The command wants to ask questions in a terminal (it is interactive). StreamHub runs commands without a terminal, so nobody can answer them.'); next = "Copilot is told to use the command's form for scripts (flags that answer the questions, or the tool's command for scripts and CI), or to give you the exact command to run in your own terminal. $copilotRetries" }; break }
        'exit code [1-9]|exit code -' { @{ code = 'RUN-FAILED'; reasons = @('The command reported an error (see its output on this card).', 'A tool or module the command needs is not installed on this computer.', 'The command ran in the project folder with cmd.exe; it may have expected another folder or shell.'); next = $copilotRetries }; break }
        'is not valid|invalid' { @{ code = 'STEP-INVALID'; reasons = @('The step''s input was not valid (see the reason above).'); next = $copilotRetries }; break }
        default { @{ code = "$($Type.ToUpperInvariant())-FAILED"; reasons = @('See the reason above; this case has no specific explanation yet.'); next = 'Copilot gets the reason in the next message. If it keeps failing, use Copy details and send them.' }; break }
    }
    $info
}

# With every automatic screenshot: how to see a part the page does not show when it opens.
function Get-ScreenshotHint([string]$Page) {
    <# With every automatic screenshot: how to see a part the page does not show when it opens. Names
       the page that was screenshotted (a placeholder was copied literally). #>
    if (-not $Page) { $Page = 'index.html' }
    "The screenshot shows $Page as it first opens. If the part you changed is in another view, tab or dialog, send a text block whose first line is ACTION screenshot $Page, with one line per step to get there: click CSS-SELECTOR, or click text=LABEL for a button or tab by its text, or wait MILLISECONDS. You get a new screenshot after those steps."
}

function Test-WebPage {
    <# The page check with its label for the waiting indicator (Test-WebPageCore does the work). #>
    param($State, [string[]]$Pages, [int]$WaitSec = 6, [switch]$Screenshot, $Steps = @())
    $what = (@($Pages) | Select-Object -First 3) -join ', '
    $prev = Enter-Activity $State 'page' $(if ($Screenshot) { "Taking a screenshot of $what" } else { "Checking $what in a browser tab" })
    try { Test-WebPageCore @PSBoundParameters } finally { Exit-Activity $State $prev }
}

function Split-PageWarnings {
    <# Page check results without the likely problems (CheckPolicy warnings, such as sideways scrolling
       at phone width): those are shown in the chat once (unless -Quiet) and do not hold up "done". #>
    param($State, $Issues, [switch]$Quiet)
    $warn = @($Issues | Where-Object { $_ -and (Get-CheckLevel "$_" 'script') -eq 'warning' })
    if ($warn.Count -and -not $Quiet) { Add-AgentEvent $State 'status' @{ text = "Page check, worth a look (not holding up the task):`n" + (($warn | Select-Object -First 5 | ForEach-Object { "- $_" }) -join "`n") } }
    @($Issues | Where-Object { $_ -and (Get-CheckLevel "$_" 'script') -ne 'warning' })
}

function Test-WebPageCore {
    <# Opens project pages in a spare Edge tab (served read-only by the web app at /preview/<token>/)
       and collects what goes wrong while they load: JavaScript errors, console errors, and files
       that fail to load (missing styles.css, a fetch() of a JSON file that is not there). The tab
       is closed afterwards. Returns one line per problem. #>
    param($State, [string[]]$Pages, [int]$WaitSec = 6, [switch]$Screenshot, $Steps = @())
    if (-not $State.PreviewPort) { return }
    $State.PageShots = @(); $State.PageShotMap = @{}
    $cdpPort = $State.Config.cdpPort
    foreach ($page in @($Pages | Select-Object -First 3)) {
        $base = "http://localhost:$($State.PreviewPort)/preview/$($State.PreviewToken)/"
        $url = $base + (($page.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
        $target = $null; $s = $null
        try {
            $target = Invoke-RestMethod -Method Put "http://127.0.0.1:$cdpPort/json/new?about:blank"
            $s = Connect-Cdp $target.webSocketDebuggerUrl
            foreach ($m in 'Runtime.enable', 'Log.enable', 'Network.enable', 'Page.enable') { $null = Invoke-Cdp $s $m }
            # A desktop-size page, the same every time, for the screenshot.
            if ($Screenshot) { try { $null = Invoke-Cdp $s 'Emulation.setDeviceMetricsOverride' @{ width = 1280; height = 800; deviceScaleFactor = 1; mobile = $false } } catch { } }
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
                        if (-not $m.params.canceled -and "$($urls["$($m.params.requestId)"])" -notmatch '/favicon\.ico(\?|$)') { $problems.Add("$page could not load $(& $rel $urls["$($m.params.requestId)"]): $($m.params.errorText)") }
                    }
                    'Runtime.exceptionThrown' {
                        $d = $m.params.exceptionDetails
                        $msg = if ($d.exception.description) { ($d.exception.description -split "`n")[0] } else { $d.text }
                        $where = if ($d.url) { " ($(& $rel $d.url):$([int]$d.lineNumber + 1))" } else { '' }
                        # The check serves the page in a sandbox without storage (as a private window
                        # has none): a page that needs it unguarded is told so, not held up.
                        if ($msg -match "Failed to read the '(local|session)Storage' property") { $problems.Add("$page reads $($Matches[1])Storage$where, and storage is not available where the helper program checks the page (nor in a private window): wrap it in try/catch so the page works without it") }
                        else { $problems.Add("$page JavaScript error$where`: $msg") }
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
            # Steps Copilot gave to reach the part it changed (another view, tab or dialog).
            if ($Screenshot -and $loaded) {
                foreach ($step in @($Steps)) {
                    if ($step.kind -eq 'wait') { $until = (Get-Date).AddMilliseconds([int]$step.ms); while ((Get-Date) -lt $until) { $null = Receive-CdpEvent $s 100 }; continue }
                    $clickOn = "$($step.target)"
                    $byText = $clickOn -match '^(?i)text\s*=\s*(.+)$'
                    $what = ConvertTo-Json $(if ($byText) { $Matches[1].Trim().Trim('"', "'") } else { $clickOn }) -Compress
                    $js = if ($byText) {
                        "(() => { const t = $what.toLowerCase(); const els = [...document.querySelectorAll('button, a, [role=button], [role=tab], summary, label, input[type=button], input[type=submit]')]; const el = els.find(e => (e.innerText || e.value || '').trim().toLowerCase() === t) || els.find(e => (e.innerText || e.value || '').trim().toLowerCase().includes(t)); if (!el) return 'missing'; el.scrollIntoView({ block: 'center' }); el.click(); return 'ok'; })()"
                    } else {
                        "(() => { let el; try { el = document.querySelector($what); } catch (e) { return 'bad selector'; } if (!el) return 'missing'; el.scrollIntoView({ block: 'center' }); el.click(); return 'ok'; })()"
                    }
                    $res = try { "$((Invoke-Cdp $s 'Runtime.evaluate' @{ expression = $js; returnByValue = $true }).result.value)" } catch { 'error' }
                    if ($res -ne 'ok') { $problems.Add("screenshot step 'click $clickOn': $(if ($res -eq 'missing') { 'nothing on the page matches it' } else { $res })") }
                    # Let the page react (and record any error the click caused).
                    $until = (Get-Date).AddMilliseconds(800); while ((Get-Date) -lt $until) { $m = Receive-CdpEvent $s 100; if ($m -and $m.method -eq 'Runtime.exceptionThrown') { $d = $m.params.exceptionDetails; $problems.Add("$page JavaScript error after 'click $clickOn': $(if ($d.exception.description) { ($d.exception.description -split "`n")[0] } else { $d.text })") } }
                }
            }
            if ($Screenshot -and $loaded) {
                # How the page looks now, for Copilot and the user (.streamhub/Screenshots/).
                try {
                    $shot = Invoke-Cdp $s 'Page.captureScreenshot' @{ format = 'png' } -TimeoutMs 15000
                    $dir = Join-Path $State.ProjectRoot '.streamhub\Screenshots'
                    $null = New-Item -ItemType Directory -Force -Path $dir
                    $name = 'page-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + ($(if ($page) { $page } else { 'site' }) -replace '[^\w.-]+', '-').Trim('-') + '.png'
                    [IO.File]::WriteAllBytes((Join-Path $dir $name), [Convert]::FromBase64String($shot.data))
                    $State.PageShots = @($State.PageShots) + @(".streamhub/Screenshots/$name")
                    $State.PageShotMap[$page] = ".streamhub/Screenshots/$name"
                    # Where the page's parts are in this screenshot, to name a changed area in words.
                    try {
                        $lay = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = (Get-PageLayoutScript); returnByValue = $true } -TimeoutMs 10000
                        if ("$($lay.result.value)") { [IO.File]::WriteAllText((Join-Path $dir ($name -replace '\.png$', '.layout.json')), "$($lay.result.value)", (New-Object Text.UTF8Encoding($false))) }
                    } catch { Write-CCBLog verbose agent "Page layout of $page not recorded: $($_.Exception.Message)" }
                } catch { Write-CCBLogError agent "Screenshot of $page" $_ }
            }
            # Readability: WCAG AA contrast of the visible text and field edges, in light and in dark.
            if ($loaded -and (Test-CheckSwitch 'contrast')) {
                try {
                    $js = Get-ContrastScript
                    # Colours that fade (CSS transitions) would be measured halfway: switch fading off in
                    # this throwaway tab, and let the page settle after each theme switch.
                    $null = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = "(() => { const st = document.createElement('style'); st.textContent = '*, *::before, *::after { transition: none !important; animation: none !important; }'; document.head.appendChild(st); })()" }
                    foreach ($mode in 'light', 'dark') {
                        $null = Invoke-Cdp $s 'Emulation.setEmulatedMedia' @{ features = @(@{ name = 'prefers-color-scheme'; value = $mode }) }
                        $until = (Get-Date).AddMilliseconds(250); while ((Get-Date) -lt $until) { $null = Receive-CdpEvent $s 50 }
                        $res = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = $js; returnByValue = $true } -TimeoutMs 15000
                        # ConvertFrom-Json gives a JSON list as one object in a pipeline (5.1): assign first.
                        $list = ConvertFrom-Json "$($res.result.value)"
                        foreach ($f in $list) {
                            if (-not $f) { continue }
                            $times = if ([int]$f.count -gt 1) { " ($($f.count) places)" } else { '' }
                            if ($f.kind -eq 'size') {
                                $which = "$($f.where)$(if ($f.text) { " '$($f.text)'" })"; $other = "$($f.other)$(if ($f.otherText) { " '$($f.otherText)'" })"
                                if ($mode -eq 'light' -and $f.scope -eq 'row') { $problems.Add("$page sizes: $which is $($f.h) px tall beside $other at $($f.otherH) px; controls side by side share one height (the kit's default size for all of them, or the small size for all), never a height, padding or font size of their own$times") }
                                elseif ($mode -eq 'light') { $problems.Add("$page sizes: $which is $($f.h) px tall while the same control elsewhere on the page ($other) is $($f.otherH) px; the same control has one size everywhere: remove the height, padding or font size that sets this one apart$times") }
                                continue
                            }
                            if ($f.kind -eq 'align') {
                                if ($mode -eq 'light') { $problems.Add("$page alignment: $($f.where)$(if ($f.text) { " ('$($f.text)')" }) has its $($f.side) edge at $($f.at) px, $($f.off) px from the edge most of the page uses ($($f.main) px); line it up (same page width and side padding)$times") }
                                continue
                            }
                            if ($f.kind -eq 'name') {
                                if ($mode -eq 'light') { $problems.Add("$page $($f.where)$(if ($f.text) { " ($($f.text))" }) has no name for screen readers; add visible text, aria-label or alt$times") }
                                continue
                            }
                            $what = if ($f.kind -eq 'border') { "the edge of the field $(if ($f.text) { "'$($f.text)' " })($($f.where))" } else { "text '$($f.text)' ($($f.where))" }
                            $problems.Add("$page contrast ($mode): $what is $($f.ratio):1, $($f.fg) on $($f.bg); WCAG AA needs $($f.need):1$times")
                        }
                    }
                } catch { Write-CCBLogError agent "Contrast check of $page" $_ }
            }
            # What the page shows: broken characters, bars that do not show their percentage, tables
            # that cannot be sorted (it clicks the column headers, so it runs last).
            if ($loaded) {
                try {
                    $res = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = (Get-PageContentScript); returnByValue = $true; awaitPromise = $true } -TimeoutMs 30000
                    $list = ConvertFrom-Json "$($res.result.value)"
                    foreach ($f in $list) {
                        if ($f -and $f.kind -eq 'kitcss') {
                            # Kit classes on the page with no rule: their rules go into kit.css (a StreamHub
                            # change card); a class the kit does not have goes back to Copilot. Only with the
                            # UI kit on (Settings) and in the project.
                            if (-not ((Test-UiKitOn $State.AppRoot) -and (Test-UiKitInProject $State.ProjectRoot))) { continue }
                            try {
                                $kr = Repair-KitPageClasses $State.ProjectRoot $State.AppRoot $page @($f.classes)
                                if (@($kr.added).Count) {
                                    Add-OwnChangeEvent $State 'edit' "$(Get-UiKitFolder)/kit.css" "StreamHub added the UI kit rules for $(@($kr.added).Count) class(es) $page shows but had no style for: $(@($kr.added) -join ', ')." @{ path = "$(Get-UiKitFolder)/kit.css"; exists = $true; old = $kr.kitCss.old; new = $kr.kitCss.new }
                                    Write-CCBLog info agent "Kit rules added after the page check of $page" @{ classes = @($kr.added) }
                                }
                                if (@($kr.unknown).Count) { $problems.Add("$page uses class(es) the UI kit does not have: $(@($kr.unknown) -join ', ') (a misspelling or an invented kit class, so the element has no style): use a class from the kit's examples, or style it in your own stylesheet with a name that does not start with kit-") }
                            } catch { Write-CCBLogError agent "Kit rules for $page" $_ }
                            continue
                        }
                        if ($f -and $f.text) { $problems.Add("$page $($f.text)") }
                    }
                } catch { Write-CCBLogError agent "Page content check of $page" $_ }
            }
            # At phone width (375 px): sideways scrolling and the parts that cause it (a warning).
            if ($loaded) {
                try {
                    $null = Invoke-Cdp $s 'Emulation.setDeviceMetricsOverride' @{ width = 375; height = 800; deviceScaleFactor = 1; mobile = $false }   # a narrow window: 375 px of layout, also without a viewport tag
                    $until = (Get-Date).AddMilliseconds(500); while ((Get-Date) -lt $until) { $null = Receive-CdpEvent $s 50 }
                    $res = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = (Get-NarrowScreenScript); returnByValue = $true } -TimeoutMs 15000
                    if ("$($res.result.value)") { $problems.Add("$page $($res.result.value)") }
                } catch { Write-CCBLogError agent "Phone width check of $page" $_ }
                finally { try { $null = Invoke-Cdp $s 'Emulation.clearDeviceMetricsOverride' } catch { } }
            }
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

function Save-BeforeShot {
    <# Before the first change to a web file in a task: a screenshot of the page it shows up on (the
       file itself when it is a page, else index.html), to compare with the screenshot after the
       change (Compare-Screenshots). Once per page per task; only when screenshots are on. #>
    param($State, [string]$Path)
    if ($Path -notmatch '(?i)\.(html?|css|scss|less|m?js|cjs|jsx|tsx|vue|svelte)$') { return }
    if (-not $State.PreviewPort -or -not $State.ProjectRoot -or $State.ReviewByCaller -or $State.Mode -eq 'plan') { return }
    if ("$($State.Config.pageCheck)" -eq 'off' -or "$($State.Config.pageScreenshot)" -in 'False', 'off') { return }
    if ($null -eq $State.BeforeShots) { $State.BeforeShots = @{} }
    $rel = $Path.Replace('\', '/').TrimStart('/')
    $page = if ($rel -match '(?i)\.html?$') { $rel } else { 'index.html' }
    if ($State.BeforeShots.ContainsKey($page)) { return }
    $State.BeforeShots[$page] = ''
    $full = try { Resolve-ProjectPath $State.ProjectRoot $page } catch { $null }
    if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { return }   # a new page has no before
    try {
        $null = @(Test-WebPage $State @($page) -Screenshot)
        $shot = "$($State.PageShotMap[$page])"
        $State.PageShots = @(); $State.PageShotMap = @{}
        if ($shot) { $State.BeforeShots[$page] = $shot; Write-CCBLog info agent "Screenshot before the change: $page" }
    } catch { Write-CCBLogError agent "Screenshot before the change of $page" $_ }
}

function Get-BeforeAfterNotes {
    <# For each page with a screenshot before and after this task's changes: the comparison line,
       and whether it looks exactly the same. #>
    param($State, $AfterMap)
    $notes = @(); $same = @(); $pairs = @(); $crops = @()
    foreach ($page in @($AfterMap.Keys)) {
        $before = if ($State.BeforeShots) { "$($State.BeforeShots[$page])" } else { '' }
        if (-not $before) { continue }
        try {
            $beforeFull = Join-Path $State.ProjectRoot $before.Replace('/', '\')
            $afterRel = "$($AfterMap[$page])"
            $afterFull = Join-Path $State.ProjectRoot $afterRel.Replace('/', '\')
            $r = Compare-Screenshots $beforeFull $afterFull
            # The page's parts as recorded with the after screenshot (Test-WebPageCore), to name the areas.
            $layFile = $afterFull -replace '\.png$', '.layout.json'
            $layout = if (Test-Path -LiteralPath $layFile) { try { $l = ConvertFrom-Json ([IO.File]::ReadAllText($layFile)); @($l) } catch { $null } } else { $null }
            $notes += Format-ShotComparison $page $r $layout
            if ($r.same) { $same += $page; $pairs += @{ page = $page; before = $before; after = $afterRel } }
            elseif (@($r.regions).Count -and -not $crops.Count) {
                # The changed areas close up, before and after side by side (the first page only).
                $cropRel = $afterRel -replace '\.png$', '-changes.png'
                if (New-ShotCrop $beforeFull $afterFull $r.regions (Join-Path $State.ProjectRoot $cropRel.Replace('/', '\'))) { $crops += @{ page = $page; path = $cropRel; areas = [Math]::Min(2, @($r.regions).Count) } }
            }
        } catch { Write-CCBLogError agent "Comparing screenshots of $page" $_ }
    }
    @{ notes = $notes; same = $same; pairs = $pairs; crops = $crops }
}

function Test-ScriptSyntax {
    param($State, [string[]]$Paths)
    $prev = Enter-Activity $State 'syntax' 'Checking the scripts for syntax errors'
    try { Test-ScriptSyntaxCore $State $Paths } finally { Exit-Activity $State $prev }
}

function Test-ScriptSyntaxCore {
    <# Compiles changed JavaScript files in a spare Edge tab (compile only: nothing runs) and returns
       one line per syntax error. Module syntax is turned into classic script first
       (ConvertTo-CheckableScript); errors about import/export are left out, as the check cannot
       tell those apart from what it changed. #>
    param($State, [string[]]$Paths)
    $files = @($Paths | Where-Object { $_ -match '(?i)\.(m?js|cjs|html?)$' } | Select-Object -First 10)
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
            # A page: each inline <script> block on its own, numbered by its line in the page.
            $parts = if ($rel -match '(?i)\.html?$') { @(Get-InlineScripts $src) } else { @(@{ line = 1; code = $src }) }
            foreach ($part in $parts) {
                $r = Invoke-Cdp $s 'Runtime.compileScript' @{ expression = (ConvertTo-CheckableScript $part.code); sourceURL = $rel; persistScript = $false }
                $d = $r.exceptionDetails
                if (-not $d) { continue }
                $msg = if ($d.exception.description) { ($d.exception.description -split "`n")[0] } else { "$($d.text)" }
                if ($msg -match '\b(import|export)\b') { continue }
                $where = if ($rel -match '(?i)\.html?$') { ' (in a <script> block)' } else { '' }
                "${rel}:$([int]$part.line + [int]$d.lineNumber): JavaScript syntax error${where}: $msg"
            }
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

function Invoke-ProjectHooks {
    param($State, [string]$HookEvent, [string[]]$Paths = @(), $ActionContext = $null)
    if ($State.HookRunning) {
        Write-CCBLog verbose agent "Skipping $HookEvent hooks during hook execution" @{ reason = 're-entry' }
        return @()
    }
    $prev = Enter-Activity $State 'tests' "Running the project's $HookEvent hooks"
    $State.HookRunning = $true
    try { Invoke-ProjectHooksCore $State $HookEvent $Paths $ActionContext } finally { $State.HookRunning = $false; Exit-Activity $State $prev }
}

function Invoke-ProjectHooksCore {
    <# Runs the project's hooks for one moment (Hooks.psm1): afterEdit for each changed file that
       matches, beforeDone and afterTask once. The hooks file is approved by a person once per version
       (it can run any command); commands that delete outside the project, delete data or use
       Microsoft 365 never run. Each run is a card in the chat. Returns the failures as lines. #>
    param($State, [string]$HookEvent, [string[]]$Paths = @(), $ActionContext = $null)
    $root = $State.ProjectRoot
    if (-not $root -or $State.NoCommands -or $State.Mode -eq 'plan') { return @() }
    if ("$($State.Config.hooks)" -in 'False', 'off') { return @() }   # setting: hooks paused
    $h = try { Read-Hooks $root } catch { Write-CCBLogError agent 'hooks' $_; $null }
    if (-not $h -or -not $h.exists) { return @() }
    if ($h.error) { Add-AgentEvent $State 'status' @{ text = "Hooks not run: $($h.error)." }; return @() }
    $mine = @($h.hooks | Where-Object { $_.event -eq $HookEvent })
    if (-not $mine.Count) { return @() }
    $runs = New-Object System.Collections.Generic.List[object]
    foreach ($k in $mine) {
        if ($HookEvent -eq 'afterEdit') { foreach ($p in @($Paths | Where-Object { Test-HookMatch $k $_ })) { $runs.Add(@{ hook = $k; path = $p }) } }
        elseif ($HookEvent -in 'beforeAction', 'afterAction') {
            $actionName = if ($ActionContext -and $ActionContext.action) { "$($ActionContext.action)" } else { '' }
            if (Test-HookActionMatch $k $actionName) { $runs.Add(@{ hook = $k; path = ''; action = $actionName }) }
        }
        else { $runs.Add(@{ hook = $k; path = '' }) }
    }
    if (-not $runs.Count) { return @() }
    # The hooks file as a whole is approved once per version, by a person.
    $file = Get-HooksPath $root
    $hash = Get-ScriptHash $file
    if ($State.HooksApproved -ne $hash -and -not (Test-ScriptApproved $root '.streamhub/hooks.json' $hash)) {
        if ($State.Headless) { Add-AgentEvent $State 'status' @{ text = 'Hooks not run: .streamhub/hooks.json is new or changed and needs a person to approve it in the StreamHub window.' }; return @() }
        $id = 'hooks-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $text = [IO.File]::ReadAllText($file)
        Add-AgentEvent $State 'action' @{ id = $id; action = 'run'; target = 'hooks in .streamhub/hooks.json'; status = 'awaiting'; by = 'streamhub'
            preview = @{ path = '.streamhub/hooks.json'; exists = $true; old = $null; new = (Limit-Text $text 20000) }
            warning = 'The project''s hooks run these commands at fixed moments of a task. Check them: once approved they run without asking until the file changes.' }
        $d = Wait-Approval $State $id $true
        if ($d.decision -ne 'approve') {
            Add-AgentEvent $State 'action-result' @{ id = $id; ok = $false; status = 'rejected'; output = $d.note; decidedBy = $d.by }
            return @()
        }
        Add-AgentEvent $State 'action-result' @{ id = $id; ok = $true; status = 'ok'; summary = 'hooks approved'; decidedBy = $d.by }
        Add-ApprovedScript $root '.streamhub/hooks.json' $hash
    }
    $State.HooksApproved = $hash
    $fails = New-Object System.Collections.Generic.List[string]
    foreach ($r in $runs) {
        if ($State.Cancel) { break }
        $cmd = Get-HookCommand $r.hook $r.path
        $label = "$HookEvent hook$(if ($r.hook.name) { " '$($r.hook.name)'" })$(if ($r.path) { " for $($r.path)" })$(if ($r.action) { " for $($r.action)" })"
        $id = 'hook-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        if (-not $cmd) {
            Add-AgentEvent $State 'action' @{ id = $id; action = 'run'; target = "$($r.hook.run)"; status = 'running'; by = 'streamhub' }
            Add-AgentEvent $State 'action-result' @{ id = $id; ok = $false; status = 'failed'; summary = "$label not run"; output = "Not run: the file name '$($r.path)' holds characters a command line would read as code. Hooks only take plain file names." }
            $fails.Add("$label was not run: the file name holds characters a command line would read as code (rename the file to letters, digits, dots, dashes and underscores)")
            continue
        }
        Add-AgentEvent $State 'action' @{ id = $id; action = 'run'; target = $cmd; status = 'running'; by = 'streamhub' }
        $risk = Get-CommandRisk $cmd
        $outside = Test-DeleteScope $root $cmd
        if ($outside -or $risk.m365 -or $risk.destructive) {
            $why = if ($outside) { $outside } else { "it $($risk.reasons -join ', ')" }
            Add-AgentEvent $State 'action-result' @{ id = $id; ok = $false; status = 'failed'; summary = "$label not run"; output = "Not run: $why. Hooks never delete data or use Microsoft 365." }
            continue
        }
        $hookTimeout = if ($State.Config.hookTimeoutSec) { [Math]::Max(1, [int]$State.Config.hookTimeoutSec) } else { 30 }
        $hookMaxChars = if ($State.Config.hookMaxOutputChars) { [Math]::Max(200, [int]$State.Config.hookMaxOutputChars) } else { 4000 }
        $started = Get-Date
        $watch = New-RunWatch $State $id $label $cmd
        $vr = $null; $runError = $null
        try { $vr = Invoke-RunAction $root $cmd $hookTimeout $hookMaxChars { $State.Cancel } -OnProgress $watch } catch { $runError = $_ } finally { Stop-RunWatch $State $id }
        if ($runError) { $vr = [pscustomobject]@{ timedOut = $false; exitCode = 1; output = "hook runner error: $($runError.Exception.Message)" } }
        $ok = (-not $vr.timedOut) -and $vr.exitCode -eq 0
        $status = if ($vr.timedOut) { 'timed out' } else { "exit code $($vr.exitCode)" }
        $durationMs = [int]((Get-Date) - $started).TotalMilliseconds
        $out = "$($vr.output)"
        $truncated = $out.Length -ge $hookMaxChars
        $trace = @{ event = $HookEvent; name = "$($r.hook.name)"; action = "$($r.action)"; command = $cmd; status = $(if ($ok) { 'ok' } else { 'failed' }); exitCode = $vr.exitCode; timedOut = [bool]$vr.timedOut; durationMs = $durationMs; outputTruncated = $truncated; correlation = (Get-CCBLogContext) }
        if ($null -ne $State.HookTrace) { [void]$State.HookTrace.Add($trace) }
        Write-CCBLog verbose agent "Hook $label finished" @{ status = $trace.status; exitCode = $trace.exitCode; timedOut = $trace.timedOut; durationMs = $durationMs; outputTruncated = $truncated; correlation = $trace.correlation }
        Add-AgentEvent $State 'action-result' @{ id = $id; ok = $ok; status = $(if ($ok) { 'ok' } else { 'failed' }); summary = "${label}: $status"; output = (Limit-Text "$label`n$status`n$out" $hookMaxChars); changed = $true; hookEvent = $HookEvent; durationMs = $durationMs; timedOut = [bool]$vr.timedOut; outputTruncated = $truncated }
        if (-not $ok) {
            $tail = ($out.Split("`n") | Where-Object { $_.Trim() } | Select-Object -Last 12) -join "`n"
            $fails.Add("the project's $label failed ($status): $cmd`n$tail")
        }
    }
    try { $null = Restore-SourceData $root } catch { Write-CCBLogError agent 'source data' $_ }
    @($fails)
}

function Invoke-UndoTask {
    <# Undo: the newest change set, or with $UpTo that change set and every newer one, newest first
       (History > Restore). One undo event per change set, so the History list follows. #>
    param($State, [string]$UpTo = '')
    $root = $State.ProjectRoot
    if ($UpTo) {
        $have = Test-Path -LiteralPath (Join-Path (Join-Path (Get-ProjectStateDir $root) 'backups') "$UpTo\manifest.json")
        if (-not $have) { Add-AgentEvent $State 'error' @{ text = 'That change set can no longer be undone (its backup is gone).'; code = 'UNDO'; hint = 'Undo the newer change sets one by one, or restore the files by hand.' }; return }
    }
    $count = 0
    do {
        $id = Get-LastChangeSetId $root
        if (-not $id) { break }
        $details = @(Undo-LastCheckpoint $root -Detailed)
        $files = @($details | ForEach-Object { $_.path })
        $count++
        $text = if ($files.Count) { 'Undid the last change set: ' + ($files -join ', ') } else { 'Nothing to undo.' }
        if ($UpTo -and $files.Count) { $text = "Restore, change set ${count}: undid " + ($files -join ', ') }
        # Per file: the lines the undo brought back and took away, with a preview.
        $changes = @($details | ForEach-Object { @{ path = $_.path; deleted = [bool]$_.deleted; added = [int]$_.added; removed = [int]$_.removed; binary = [bool]$_.binary; preview = $_.preview } })
        Add-AgentEvent $State 'undo' @{ files = $files; text = $text; changes = $changes }
    } while ($UpTo -and $id -ne $UpTo -and $count -lt 200)
    if ($count -eq 0) { Add-AgentEvent $State 'undo' @{ files = @(); text = 'Nothing to undo.' } }
}

function Test-ChatScopeOn($State) {
    # Setting newChatOnSwitch (on unless turned off).
    $v = $State.Config.newChatOnSwitch
    ($null -eq $v) -or ([bool]$v -and "$v" -ne 'off')
}

function Update-ChatScope {
    <# Before a message: a new Copilot chat when it is about another part of the project than the
       chat so far (ChatScope.psm1). Plain chat and the first message of a chat are left alone. #>
    param($State, [string]$Text, [string]$ForceKind)
    if ($State.NeedNewChat -or -not $State.ChatStarted -or $ForceKind -eq 'chat' -or -not (Test-ChatScopeOn $State)) { return }
    try {
        $sw = Test-ChatSwitch $State.ProjectRoot $Text @($State.ChatFiles)
        Write-CCBLog verbose agent 'Chat scope' @{ switch = $sw.switch; reason = $sw.reason }
        if ($sw.switch) {
            $State.NeedNewChat = $true
            Add-AgentEvent $State 'status' @{ text = "New Copilot chat: this message is about $(@($sw.to) -join ', '), the chat so far was about $(@($sw.from) -join ', '). A fresh chat keeps the earlier work from crowding Copilot's context (Settings > Copilot > New chat for another part of the project)." }
        }
    } catch { Write-CCBLogError agent 'chat scope' $_ }
}

function Add-ChatScopeFiles($State, [string]$Text) {
    # The files a message names belong to its chat too.
    if ($null -eq $State.ChatFiles -or -not (Test-ChatScopeOn $State) -or -not $State.ProjectRoot) { return }
    try {
        $files = @(Get-ProjectFiles $State.ProjectRoot | ForEach-Object { $_.path })
        foreach ($n in @(Get-NamedFiles $Text $files)) { [void]$State.ChatFiles.Add($n) }
    } catch { Write-CCBLogError agent 'chat scope' $_ }
}

function Start-NewChat($State) {
    $prev = Enter-Activity $State 'newchat' 'Opening a new Copilot chat'
    try { Start-NewChatCore $State } finally { Exit-Activity $State $prev }
}

function Start-NewChatCore($State) {
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
            $State.ChatFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
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
    $State.ChatFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $State.FolderNotesSent = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)   # folder AGENTS.md sent in this chat (Get-FolderNotes)
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

function Get-FolderNotes {
    <# The AGENTS.md of the folders the given files are in (and their parent folders, not the
       project root: that one is in the project context), deepest last, that were not sent in this
       chat yet ($Sent, a set of paths; added to). Never from build output, packages, Source/ or the
       helper program's folders. Text, or ''. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths, $Sent, [int]$MaxChars = 3000)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Paths | Where-Object { $_ })) {
        $parts = @("$p".Replace('\', '/').TrimStart('/').Split('/') | Where-Object { $_ })
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $dir = ($parts[0..($i - 1)] -join '/')
            if ($dir -match '(?i)(^|/)(node_modules|dist|build|out|\.git|vendor|Source|\.streamhub|shared|library|shared-library)(/|$)|^styles/kit') { break }
            $rel = "$dir/AGENTS.md"
            if (-not $found.Contains($rel) -and -not ($Sent -and $Sent.Contains($rel)) -and (Test-Path -LiteralPath (Join-Path $ProjectRoot $rel.Replace('/', '\')) -PathType Leaf)) { $found.Add($rel) }
        }
    }
    if (-not $found.Count) { return '' }
    $out = @(foreach ($rel in @($found | Sort-Object { ($_ -split '/').Count }, { $_ })) {
        if ($Sent) { [void]$Sent.Add($rel) }
        $t = Get-ProjectNotes (Join-Path $ProjectRoot (Split-Path $rel.Replace('/', '\') -Parent))
        if (-not $t) { continue }
        # Instructions are never shortened. The send budget refuses an oversized required block.
        "Folder notes ($rel; they apply to the files in $(Split-Path $rel.Replace('/', '\') -Parent | ForEach-Object { $_.Replace('\', '/') })/ and win over the project notes there):`n$t"
    })
    $out -join "`n`n"
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
    # A project without pages or scripts of its own (only converted data and the kit): said plainly,
    # so Copilot writes instead of looking for files that are not there.
    if ($paths.Count -and -not (Test-OwnCode $paths)) { $files += "`nNo pages or scripts of the project's own were found in the indexed files. The displayed list may be shortened. Use glob or grep when needed; create files only when the request asks for them." }
    $notes = Get-ProjectNotes $root
    $full = "$location`n$files" + $(if ($notes) { "`n`nProject notes (AGENTS.md):`n$notes" } else { '' })
    # The shared instructions of every project in this folder (shared/AGENTS.md beside the projects).
    $sharedNotes = try { Get-SharedNotes $root } catch { '' }
    if ($sharedNotes) { $full += "`n`nShared notes for every project in this folder ($(Get-SharedPrefix $root)/AGENTS.md, read-only here):`n$sharedNotes" }
    # What earlier tasks did (Progress, setting progressLog): a new chat knows where the work stands.
    if ("$($State.Config.progressLog)" -notin 'False', 'off') {
        $pg = try { Format-ProgressContext @(Read-ProgressEntries (Get-ProjectStateDir $root) 5) } catch { Write-CCBLogError agent 'progress' $_; '' }
        if ($pg) { $full += "`n`n$pg" }
    }
    # A code map within its budget (setting repoMapChars), for work on the project's code.
    $mapChars = $(if ($null -ne $State.Config.repoMapChars) { [int]$State.Config.repoMapChars } else { 4000 })
    if ($mapChars -gt 0 -and $paths.Count) {
        $map = try { Get-RepoMap $root "$($State.TurnText)" @($State.ChatFiles) $mapChars } catch { Write-CCBLogError agent 'repo map' $_; '' }
        if ($map) { $full += "`n`n$map" }
    }
    $guarded = @(Get-ProtectedPatterns $State.AppRoot)
    if ($guarded.Count) { $full += "`n`nRead-only (the user protected these; never write, edit, move or delete them): $($guarded -join ', ')" }
    if (Test-DataImportOn $State.AppRoot) {
        $ready = try { Format-DataImportContext $root -OneFile:((Get-ProjectSetup $root).build -eq 'single') } catch { Write-CCBLogError agent 'data context' $_; '' }
        if ($ready) { $full += "`n`n$ready" }
        $dn = try { Format-DataNotes $root } catch { Write-CCBLogError agent 'data notes' $_; '' }
        if ($dn) { $full += "`n`n$dn" }
    }
    # Pages a project script builds from a template (OneFile Get-TemplateBuilds): output, never edited.
    $built = @(try { Get-TemplateBuilds $root } catch { Write-CCBLogError agent 'built pages' $_; @() })
    if ($built.Count) { $full += "`n`nPages built by a script (output: never write or edit them; change the template, then run the script): " + (@($built | ForEach-Object { "$($_.output) from $($_.template) by $($_.script)" }) -join '; ') }
    # What the UI kit offers (where each part is), so every task can use it, not only interface requests.
    if ((Test-UiKitOn $State.AppRoot) -and (Test-UiKitInProject $root)) {
        $kitText = try { Format-UiKitContext $root $State.AppRoot } catch { Write-CCBLogError agent 'UI kit context' $_; '' }
        if ($kitText) { $full += "`n`n$kitText" }
    }
    $traits = @(Get-ProjectTraits $paths)
    if ($State.NoCommands -or ($State.Headless -and -not $State.AllowCommands)) { $traits += 'nocommands' }
    # Project setup (asked before the first request): the build form and a live data file.
    $setup = try { Get-ProjectSetup $root } catch { Write-CCBLogError agent 'project setup' $_; @{ build = ''; liveSource = '' } }
    $turnAnswers = if ($State.TurnAnswers -is [hashtable]) { $State.TurnAnswers } else { @{} }
    $setupText = try { Format-ProjectSetupContext $root $turnAnswers } catch { '' }
    if ($setupText) { $full += "`n`n$setupText" }
    # The databases the person connected (SqlServer): Copilot may query them, with approval.
    $dbText = try { Format-DbContext $root } catch { '' }
    if ($dbText) { $full += "`n$dbText" }
    # The tables ACTION sql can query (DataQuery), when the project has converted data.
    $sqlText = try { Format-QueryTablesContext $root } catch { '' }
    if ($sqlText) { $full += "`n$sqlText" }
    # Files the person added to the project and what they are for (FileIntake).
    $intakeText = try { Format-IntakeContext $root } catch { '' }
    if ($intakeText) { $full += "`n$intakeText" }
    # SharePoint files and lists the person linked for a SharePoint HTML page's LiveData.
    if (Test-SharePointPageProject $root) { $spText = try { Format-SharePointLinksContext $root } catch { '' }; if ($spText) { $full += "`n$spText" } }
    $tailwind = try { Test-TailwindProject $State.ProjectRoot } catch { $false }
    # A SharePoint HTML page is one file whatever else was chosen: SharePoint shows only that file.
    $build = if ($setup.answers -is [hashtable] -and "$($setup.answers['audience'])" -eq 'sharepoint') { 'single' } else { "$($setup.build)" }
    @{ Location = $location; Full = $full; Traits = $traits; Paths = $paths; Build = $build; Live = [bool]$setup.liveSource; Tailwind = $tailwind; Root = $State.ProjectRoot; Databases = [bool]$dbText; Answers = $(if ($setup.answers -is [hashtable]) { $setup.answers } else { @{} }) }
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
    # The whole block within the budget (plus room for the heads): what still does not fit is cut from
    # the largest parts first, each with a note, so one result never crowds out the rest or makes a
    # message too long to type.
    $parts = @($parts)
    $limit = $budget + 4000
    $total = ($parts | Measure-Object -Property Length -Sum).Sum
    if ($total -gt $limit) {
        $order = @(0..($parts.Count - 1) | Sort-Object { $parts[$_].Length } -Descending)
        foreach ($k in $order) {
            if ($total -le $limit) { break }
            $over = $total - $limit
            $keep = [Math]::Max(1500, $parts[$k].Length - $over)
            if ($keep -ge $parts[$k].Length) { continue }
            $cut = $parts[$k].Length - $keep
            $parts[$k] = $parts[$k].Substring(0, $keep) + "`n(cut to keep the message within its size: $cut more characters. Ask for a narrower range or use grep.)"
            $total -= $cut
        }
    }
    $parts -join "`n`n"
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max) + "`n(truncated: $($Text.Length - $Max) more characters)"
}

function Invoke-RolloverIfNeeded($State, [hashtable]$Turn = @{}) {
    <# A chat nearly full of messages: Copilot writes a handoff under fixed headings (Handoff.psm1;
       asked again once when three or more are missing), and the helper program adds the facts it
       kept itself ($Turn: changed, doneWhen, acceptance) before the task goes on in a new chat. #>
    $t = $State.Throttle
    if (-not $t.max -or $t.used -lt ($t.max - $State.Config.rolloverMargin)) { return }
    Write-CCBLog info agent "Chat rollover" @{ used = $t.used; max = $t.max }
    Add-AgentEvent $State 'status' @{ text = "This Copilot chat is nearly full ($($t.used)/$($t.max) messages). Summarizing and continuing in a new chat." }
    $r = Send-ToCopilot $State (Get-HandoffAsk)
    $text = "$($r.Text)"
    $missing = @(Get-HandoffMissing $text)
    if ($missing.Count -ge 3 -and -not $r.Cancelled -and -not $State.Cancel) {
        Write-CCBLog verbose agent 'Handoff without its headings: asked again' @{ missing = ($missing -join ', ') }
        $r2 = Send-ToCopilot $State (Get-HandoffRetry $missing)
        if (-not $r2.Cancelled -and @(Get-HandoffMissing "$($r2.Text)").Count -lt $missing.Count) { $text = "$($r2.Text)" }
    }
    $changed = @($Turn.changed | Where-Object { $_ })
    $outlines = if ($State.ProjectRoot -and $changed.Count) { try { Get-HandoffOutlines $State.ProjectRoot $changed } catch { Write-CCBLogError agent 'handoff outlines' $_; '' } } else { '' }
    $facts = try { Format-HandoffFacts -Request "$($State.TurnText)" -Mode "$($State.Mode)" -Changed $changed -Todos @($State.Todos) -DoneWhen @($Turn.doneWhen) -Acceptance @($Turn.acceptance) -IssueFix $State.IssueFix -Outlines $outlines } catch { Write-CCBLogError agent 'handoff facts' $_; '' }
    $State.Summary = (Limit-Text $text 4000) + $(if ($facts) { "`n`n$facts" } else { '' })
    if ($State.TaskRecord) {
        $State.TaskRecord.summary = $text
        $State.TaskRecord.changed = $changed; $State.TaskRecord.remaining = @($State.Todos)
        $State.TaskRecord.acceptance = @($Turn.acceptance)
        $null = Save-TaskRecord $State.TaskRecordDir $State.TaskRecord
    }
    $kind = $State.ChatKind
    Start-NewChat $State
    $State.ChatKind = $kind   # the new chat continues the same kind of task
    $true
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

function Get-LastDoneText($State) {
    <# What Copilot last reported as done in this chat (the text of the newest done event since the last
       New chat or cleared history), or $null when it reported nothing done yet. #>
    $events = @($State.Events)
    for ($i = $events.Count - 1; $i -ge 0; $i--) {
        $e = $events[$i]
        if (-not $e) { continue }
        if ($e.type -in 'newchat', 'history-cleared') { return $null }
        if ($e.type -eq 'done') { return "$($e.text)" }
    }
    $null
}

function Get-DisputeCandidates($State, [string]$Path) {
    <# The findings of the last file check on this file (texts), which an ACTION dispute may point at. #>
    $want = "$Path".Trim().Replace('\', '/').TrimStart('.', '/').ToLowerInvariant()
    @(@($State.LastFindings) | Where-Object { $_ -and "$($_.path)".Replace('\', '/').TrimStart('.', '/').ToLowerInvariant() -eq $want } | ForEach-Object { "$($_.text)" } | Select-Object -Unique)
}

function Invoke-AgentActionCore {
    <# Executes one action. Returns @{ ok; summary; output } where output goes back to Copilot. #>
    param($State, $Action, [string]$Id, $Checkpoint, [int]$Uncertain)
    $root = $State.ProjectRoot
    $mode = $State.Mode
    $evt = @{ id = $Id; action = $Action.type; target = $Action.arg; status = 'running' }
    if ($State.TaskIntent -in 'answer', 'investigate' -and $Action.type -in 'write', 'edit', 'remember', 'runbook') {
        return @{ ok = $false; summary = 'This task asks for an answer or investigation, not changes.'; output = 'Not applied: the current task does not authorize file changes. Continue reading or investigating, then answer with a done block.' }
    }

    switch ($Action.type) {
        'read' {
            $paths = Get-ActionPaths $Action
            # Lines Copilot read in this task (PATH:START-END): a SEARCH that matches several places
            # takes the one among them (Find-EditTarget).
            if ($null -eq $State.ReadRanges) { $State.ReadRanges = @{} }
            if ($null -eq $State.ReadStamps) { $State.ReadStamps = @{} }
            foreach ($rp in $paths) {
                $rm = [regex]::Match("$rp", '^(.+?):(\d+)-(\d+)$')
                $plainPath = if ($rm.Success) { $rm.Groups[1].Value } else { "$rp" }
                $stampKey = $plainPath.Replace('\', '/').TrimStart('/').ToLowerInvariant()
                # The file as read: a line-range edit is valid while it is unchanged since (Register-ReadStamp).
                try { Register-ReadStamp $State $root $stampKey } catch { }
                if (-not $rm.Success) { $State.ReadRanges[$stampKey] = @(@($State.ReadRanges[$stampKey] | Where-Object { $_ }) + @(@{ from = 1; to = 2000000000 })) }
                if ($rm.Success) { $key = $rm.Groups[1].Value.Replace('\', '/').TrimStart('/').ToLowerInvariant(); $State.ReadRanges[$key] = @(@($State.ReadRanges[$key]) + @(@{ from = [int]$rm.Groups[2].Value; to = [int]$rm.Groups[3].Value }) | Where-Object { $_ }) }
            }
            $evt.target = $paths -join ', '; Add-AgentEvent $State 'action' $evt
            $out = (Invoke-ReadAction $root $paths -MaxCharsPerFile 200000) -join "`n`n"
            $usedBy = try { Format-ImportUsers $root $paths } catch { '' }   # who imports it or uses its ids, functions, hooks
            if ($usedBy) { $out += "`n`n$usedBy" }
            # Images, PDFs and old binary Office files (.doc, .ppt, .xls) cannot be read here: Copilot reads them
            # from an attachment (at most 50 MB, as with @-attached files).
            $files = @(foreach ($rp in $paths) {
                $fp = $rp -replace ':(outline|\d+(-\d+)?)$', ''
                if ((Get-OfficeKind $fp) -notin 'old', 'pdf', 'image') { continue }
                try {
                    $f = Resolve-ProjectPath $root $fp
                    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
                    if ((Get-Item -LiteralPath $f).Length -gt 50MB) { $out += "`n`n($fp is over 50 MB and cannot be attached; ask the user for the part you need.)"; continue }
                    $f
                } catch { }
            })
            return @{ ok = $true; summary = "read $($paths.Count) file(s)"; output = $out; readPaths = @($paths); attach = @($files) }
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
        'dispute' {
            # Copilot says a finding of the file check is wrong: left out for the rest of this task
            # and recorded (.streamhub/check-disputes.json); only the user can ignore it for good.
            $path = "$($Action.arg)".Trim()
            $bodyLines = @("$($Action.body)".Replace("`r", '').Split("`n") | Where-Object { $_.Trim() })
            $finding = if ($bodyLines.Count) { $bodyLines[0].Trim() -replace '^-\s*', '' -replace ('^' + [regex]::Escape($path) + ':\s*'), '' } else { '' }
            $reason = (@($bodyLines | Select-Object -Skip 1) -join ' ').Trim()
            # Only a reason, without the finding first: the file's one open finding is the one meant.
            # With several, Copilot is told which ones there are.
            $open = @(Get-DisputeCandidates $State $path)
            if ($finding -and -not $reason -and -not @($open | Where-Object { (Get-CheckKey $path $_) -eq (Get-CheckKey $path $finding) }).Count) {
                if ($open.Count -eq 1) { $reason = $finding; $finding = $open[0] }
                elseif ($open.Count -gt 1) {
                    $evt.target = $path; Add-AgentEvent $State 'action' $evt
                    return @{ ok = $false; summary = 'dispute: which finding?'; output = "error: $path has $($open.Count) findings; write the one you mean on the line after ACTION dispute $path, as it was reported, then why it is wrong on the next line. The findings:`n$(@($open | Select-Object -First 8 | ForEach-Object { "- $_" }) -join "`n")" }
                }
            }
            $evt.target = "$path$(if ($finding) { ": $finding" })"; Add-AgentEvent $State 'action' $evt
            if (-not $path -or -not $finding) { return @{ ok = $false; summary = 'dispute without a finding'; output = 'error: write ACTION dispute PATH, then the finding as it was reported on the next line, then why it is wrong.' } }
            if (-not $reason) { return @{ ok = $false; summary = 'dispute without a reason'; output = "error: '$finding' has no reason: write why it is wrong on the line after it (one line is enough); a dispute without a reason is not accepted." } }
            if ($finding -match '(?i)\bnow has \d+ lines\b|\blines of inline data\b|\b(very )?complex\b|\bdeeply nested\b|\bbrain method\b|\btoo (long|many)\b') {
                return @{ ok = $false; summary = 'a measurement cannot be disputed'; output = "error: '$finding' is a measurement (size or complexity), not a guess, so it is not wrong. Split the code, or leave it as it is and say why in the done summary." }
            }
            if ($null -eq $State.CheckDisputes) { $State.CheckDisputes = New-Object 'System.Collections.Generic.HashSet[string]' }
            [void]$State.CheckDisputes.Add((Get-CheckKey $path $finding))
            try { Add-CheckDispute $root $path $finding $reason 'copilot' } catch { Write-CCBLogError agent 'check dispute' $_ }
            return @{ ok = $true; summary = "check disputed: $path"; output = "Noted: '$finding' in $path is left out for the rest of this task." }
        }
        'sql' {
            # ACTION sql db:NAME [save:FILE]: a query on a SQL Server database the person connected
            # (SqlServer.psm1): read-only by its checks, and only after the person approves it, since
            # company data then goes to Copilot. Never without a person (MCP / headless).
            $dbm = [regex]::Match("$($Action.arg)", '^\s*db:([\w-]+)(?:\s+save:([\w-]+))?\s*(.*)$')
            if ($dbm.Success) {
                $dbName = $dbm.Groups[1].Value; $saveAs = $dbm.Groups[2].Value
                $sql = ("$($dbm.Groups[3].Value)`n$($Action.body)").Trim()
                $evt.target = "db:$dbName$(if ($saveAs) { " -> Source/Database/$saveAs.csv" })"
                $conn = @(Get-DbConnections $root | Where-Object { $_.name -eq $dbName }) | Select-Object -First 1
                if (-not $conn) { Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = 'unknown database' }); return @{ ok = $false; summary = 'query: unknown database'; output = "error: there is no database connection named $dbName. The user connected: $((@(Get-DbConnections $root) | ForEach-Object { $_.name }) -join ', ')$(if (-not @(Get-DbConnections $root).Count) { 'none (the user adds them in Files > Project setup > Databases)' })." } }
                $why = Test-DbQuery $sql
                if ($why) { Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = $why }); return @{ ok = $false; summary = 'query refused'; output = "error: $why." } }
                if ($State.Headless) { Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = 'needs a person' }); return @{ ok = $false; summary = 'query needs a person'; output = 'not run: a database query needs the user''s approval in the StreamHub window.' } }
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'awaiting'; preview = @{ path = "$dbName.sql"; exists = $false; old = $null; new = $sql }; warning = "Copilot wants to run this query on $($conn.database) ($($conn.server)) with your Windows sign-in; the result goes to Copilot$(if ($saveAs) { " and into Source/Database/$saveAs.csv" }). It can only read: one SELECT, a read-only connection, everything rolled back." })
                $d = Wait-Approval $State $Id $true
                if ($d.decision -ne 'approve') {
                    Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $false; status = 'rejected'; output = $d.note; decidedBy = $d.by }
                    return @{ ok = $false; summary = 'query rejected'; output = "rejected by the user.$(if ($d.note) { " The user said: $($d.note)" })"; reported = $true }
                }
                Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $true; status = 'running'; decidedBy = $d.by }
                $prevAct = Enter-Activity $State 'page' "Querying $dbName"
                try { $res = Invoke-DbQuery $conn $sql } finally { Exit-Activity $State $prevAct }
                Write-CCBLog info agent 'Database query' @{ database = $dbName; ok = [bool]$res.ok; rows = $res.count }
                if (-not $res.ok) { return @{ ok = $false; summary = 'query failed'; output = "error: $($res.error)" } }
                $note = ''
                if ($saveAs) {
                    try {
                        $rel = Save-DbResult $root $saveAs $dbName $sql $res
                        Add-OwnChangeEvent $State 'write' $rel "StreamHub saved the query's $($res.count) row(s) as $rel; the query is kept so Scripts/Refresh-Database.ps1 can run it again."
                        if (-not (Test-Path -LiteralPath (Join-Path $root 'Scripts\Refresh-Database.ps1'))) { $null = Write-DbRefreshScript $root }
                        $note = "`nSaved as $rel (it is converted like any data file at the next task; Scripts/Refresh-Database.ps1 runs the saved queries again)."
                    } catch { $note = "`nThe result could not be saved: $($_.Exception.Message)" }
                }
                $view = [pscustomobject]@{ ok = $true; columns = @($res.columns); count = [int]$res.count; rows = @(@($res.rows) | Select-Object -First 200 | ForEach-Object { , @($_) }) }
                return @{ ok = $true; summary = "query: $($res.count) row(s)$(if ($res.truncated) { ' (cut off)' })"; output = (Format-DataQueryResult $view $sql) + $(if ($res.truncated) { "`n(The query returned more than $($res.count) rows; the rest was not read: aggregate or filter in the query.)" }) + $note }
            }
            # A read-only query over every row of the converted data (DataQuery.psm1): no approval,
            # since nothing is changed and nothing leaves the computer.
            $sql = ("$($Action.arg)`n$($Action.body)").Trim()
            $evt.target = if ($sql.Length -gt 120) { $sql.Substring(0, 117) + '...' } else { $sql }
            Add-AgentEvent $State 'action' $evt
            $prevAct = Enter-Activity $State 'page' 'Running a query over the data'
            try { $res = Invoke-DataQuery $root $State.AppRoot $sql -CdpPort ([int]$State.Config.cdpPort) } catch { $res = [pscustomobject]@{ ok = $false; error = "$($_.Exception.Message)" } } finally { Exit-Activity $State $prevAct }
            $out = Format-DataQueryResult $res $sql
            return @{ ok = [bool]$res.ok; summary = $(if ($res.ok) { "query: $($res.count) row(s)" } else { 'query failed' }); output = $out }
        }
        'screenshot' {
            # A screenshot of a project page after the clicks Copilot names (the automatic one shows
            # the page as it first opens). Read-only: the page is served from the preview address.
            $asked = "$($Action.arg)".Trim().Trim('`', '"', "'").TrimStart('/')
            $fallback = if ($State.LastShotPage) { "$($State.LastShotPage)" } else { 'index.html' }
            # Not a page file name (a placeholder such as PAGE copied from the hint): the page of the last screenshot.
            $page = if ($asked -match '(?i)\.html?$') { $asked } else { $fallback }
            $pageNote = if ($asked -and $asked -ne $page) { " ('$asked' is not a page file, so $page was used)" } else { '' }
            $steps = @(Get-ScreenshotSteps "$($Action.body)")
            $evt.target = $page + $(if ($steps.Count) { ' (' + (@($steps | ForEach-Object { if ($_.kind -eq 'click') { "click $($_.target)" } else { "wait $($_.ms)" } }) -join ', ') + ')' } else { '' })
            Add-AgentEvent $State 'action' $evt
            if (-not $State.PreviewPort) { return @{ ok = $false; summary = 'screenshot not available'; output = 'error: screenshots need the web app (its page preview); none was taken.' } }
            $full = try { Resolve-ProjectPath $root $page } catch { $null }
            if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf) -or $page -notmatch '(?i)\.html?$') { return @{ ok = $false; summary = "no page $page"; output = "error: $page is not an HTML page of the project. Name the page file, for example index.html." } }
            $problems = @(Test-WebPage $State @($page) -Screenshot -Steps $steps)
            $shot = @($State.PageShots | Where-Object { $_ } | Select-Object -Last 1)
            $State.PageShots = @()
            if (-not $shot.Count) { return @{ ok = $false; summary = 'no screenshot'; output = "error: the page could not be captured.$(if ($problems.Count) { "`n" + ($problems -join "`n") })" } }
            Add-AgentEvent $State 'status' @{ text = "Screenshot of $($evt.target): $($shot[0]) (shown to Copilot)."; path = $shot[0] }
            $note = if ($problems.Count) { "`nProblems seen:`n" + (($problems | Select-Object -First 10 | ForEach-Object { "- $_" }) -join "`n") } else { '' }
            return @{ ok = $true; summary = "screenshot of $page"; attach = (Join-Path $root $shot[0].Replace('/', '\')); output = "Attached: a screenshot of $($evt.target)$pageNote as it looks now. Compare it with what was asked.$note" }
        }
        'find' {
            $name = if ($Action.arg) { $Action.arg } else { "$($Action.body)".Split("`n")[0].Trim() }
            $evt.target = $name; Add-AgentEvent $State 'action' $evt
            return @{ ok = $true; summary = "found $name"; output = (Find-SymbolDefinition $root $name) }
        }
        'web' {
            # Reads public web pages for Copilot. Sites named in the request are read at once;
            # others need a person's approval (setting webRead), so no project data can leave
            # through an address Copilot made up. Local and intranet addresses are never read.
            # ACTION web source: the page, script or JSON as the site sends it, with the addresses it
            # refers to (WebFetch -Source); same site rules as a plain read.
            $srcMode = "$($Action.arg)" -match '^(?i)\s*source\b'
            # ACTION web save:NAME: the whole response (one address) saved as Source/Web/NAME.EXT, where it
            # is converted like any data file, instead of read into the chat in parts.
            $saveName = [regex]::Match("$($Action.arg)", '^(?i)\s*save:([A-Za-z][\w-]{0,60})\b').Groups[1].Value
            $urls = @(@("$($Action.arg)" -split '\s+') + @("$($Action.body)".Split("`n")) | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(?i)https?://\S+$' } | Select-Object -Unique -First $(if ($saveName) { 1 } else { 3 }))
            $evt.target = "$(if ($srcMode) { 'source: ' } elseif ($saveName) { "save as Source/Web/$($saveName): " })$($urls -join ', ')"
            if (-not $urls.Count) { Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed' }); return @{ ok = $false; summary = 'web without an address'; output = 'error: put one full address (https://...) per line in the web block' } }
            # Microsoft 365 files (SharePoint, OneDrive...): the helper program only gets a sign-in
            # page; Copilot opens them itself, with the user's access.
            $m365 = @($urls | Where-Object { Test-M365Address $_ })
            if ($m365.Count) {
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = 'a Microsoft 365 link: Copilot opens it itself' })
                return @{ ok = $false; summary = 'web skipped (Microsoft 365 link)'; output = "not read: $($m365 -join ', ') is a Microsoft 365 file (SharePoint or OneDrive). The helper program cannot open it (it only gets a sign-in page), but you can: open it yourself with the user's Microsoft 365 access and use its content. If the project needs its data, write that data into a project file with a write block (for example data/NAME.csv), exactly as it is in the file. If you cannot open it, say so: the user may need to turn Work IQ on." }
            }
            $policy = if ($State.Config.webRead) { "$($State.Config.webRead)" } else { 'named-sites' }
            if ($policy -eq 'off') { Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = 'reading web pages is off' }); return @{ ok = $false; summary = 'web pages are off'; output = 'error: reading web pages is turned off in the settings; use your own web search instead.' } }
            $named = @(Get-NamedSites "$($State.TurnText)")
            # Sites the person allowed for this project (from an earlier approval) need no approval again.
            $allowed = if ($policy -eq 'always-ask') { @() } else { @(Read-WebAllow $root) }
            $unnamed = @($urls | Where-Object { $policy -eq 'always-ask' -or -not ((Test-HostMatch ([Uri]$_).Host $named) -or (Test-WebAllowed $root $_ $allowed)) })
            if ($unnamed.Count) {
                $allowOptions = if ($policy -eq 'always-ask') { @() } else { @(Get-WebAllowCandidates $unnamed) }
                $waitWatch = [Diagnostics.Stopwatch]::StartNew()
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'awaiting'; allowOptions = $allowOptions; warning = "Copilot wants to read $($unnamed -join ', '). The address is sent to that site; approve only if it is a site you trust and the address holds no project data." })
                $d = Wait-Approval $State $Id $false
                Write-CCBLog verbose agent "approval ${Id}: $($d.decision) by $($d.by) after $($waitWatch.ElapsedMilliseconds) ms"
                # Approved with "from now on": the chosen part of the site is allowed for this project.
                if ($d.decision -eq 'approve' -and "$($d.allow)" -and $allowOptions -contains "$($d.allow)" -and $d.by -eq 'user') {
                    try { Add-WebAllow $root "$($d.allow)"; Add-AgentEvent $State 'status' @{ text = "From now on, pages under $($d.allow) are read without asking in this project (Files > Project setup lists the allowed sites)." } } catch { Write-CCBLogError agent 'web allow' $_ }
                }
                if ($d.decision -ne 'approve') {
                    Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $false; status = 'rejected'; output = $d.note; decidedBy = $d.by }
                    return @{ ok = $false; summary = 'web rejected'; output = "rejected by the user.$(if ($d.note) { " The user said: $($d.note)" })"; reported = $true }
                }
                Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $true; status = 'running'; decidedBy = $d.by }
            } else { Add-AgentEvent $State 'action' $evt }
            if ($saveName) {
                $res = Invoke-WebFetch $urls[0] -Source -MaxBytes 50MB -MaxChars ([int]::MaxValue) -TimeoutSec 60
                if (-not $res.ok) { return @{ ok = $false; summary = 'web save failed'; output = "error: $($urls[0]) was not saved: $($res.error)." } }
                if ($res.truncated) { return @{ ok = $false; summary = 'web save failed (too large)'; output = "error: $($urls[0]) is larger than 50 MB, the most the helper program saves. Ask the user for an export of the data instead." } }
                try { $saved = Save-WebData $root $saveName $res } catch { return @{ ok = $false; summary = 'web save failed'; output = "error: $($_.Exception.Message)" } }
                # Source/ is read-only for Copilot's commands: the saved file is taken in as source data.
                try { $null = Restore-SourceData $root -Accept @($saved.rel) } catch { Write-CCBLogError agent 'web save source' $_ }
                Add-OwnChangeEvent $State 'write' $saved.rel "StreamHub saved $($urls[0]) ($([Math]::Round($saved.bytes / 1KB)) KB) as $($saved.rel); Scripts/Refresh-Web-Data.ps1 downloads it again."
                if (-not (Test-Path -LiteralPath (Join-Path $root 'Scripts\Refresh-Web-Data.ps1'))) { try { $null = Write-WebRefreshScript $root } catch { Write-CCBLogError agent 'web refresh script' $_ } }
                # Converted now, so this task can query it and pages can load it.
                $null = Sync-DataImports $State -NoLive
                $man = try { Read-DataImportManifest $root } catch { @{} }
                $conv = @($man.Keys | Where-Object { "$($man[$_].source)" -eq $saved.rel }) | Select-Object -First 1
                $about = if ($conv) {
                    $it = $man[$conv]
                    $sh = @($it.sheets) | Select-Object -First 1
                    "It is converted to $conv$(if ($it.js) { " (for pages opened from disk: $($it.js), window.$($it.global))" })$(if ($sh) { ": $($sh.rows) rows; columns: $((@($sh.columns) | Select-Object -First 25 | ForEach-Object { "$($_.name) ($($_.type))" }) -join ', ')" }). Query it with ACTION sql (the table is listed in the project context) and build on that file; never copy its rows into a page or script by hand."
                } else { 'It is kept as it is (not a table the helper program converts); read parts of it with read, or grep it.' }
                return @{ ok = $true; summary = "saved as $($saved.rel)"; output = "Saved $($urls[0]) as $($saved.rel) ($([Math]::Round($saved.bytes / 1KB)) KB, the whole response). $about Scripts/Refresh-Web-Data.ps1 downloads it again (for a schedule)." }
            }
            $per = [Math]::Max(4000, [int]([int]$State.Config.resultCharBudget / ($urls.Count + 1)))
            $parts = foreach ($u in $urls) { Format-WebResult (Invoke-WebFetch $u -MaxChars $per -Source:$srcMode) }
            $okCount = @($parts | Where-Object { $_ -notmatch '^error:' }).Count
            return @{ ok = ($okCount -gt 0); summary = "read $(if ($srcMode) { 'the source of ' })$okCount of $($urls.Count) web page(s)"; output = ($parts -join "`n`n") }
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
    if ($Action.type -eq 'runbook') {
        # Run an existing runbook after this reply: a read-only export, like the Run button. Asks in
        # Ask mode, runs straight away in auto mode.
        $rbName = ("$($Action.arg)".Trim() -split '\s+')[0] -replace '(?i)^@?Runbooks/', '' -replace '(?i)\.runbook\.md$', ''
        $evt.target = $rbName
        $known = @(Get-Runbooks $root)
        $rb = @($known | Where-Object { "$($_.name)" -ieq $rbName }) | Select-Object -First 1
        if (-not $rb) {
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed' })
            return @{ ok = $false; summary = "no runbook named $rbName"; output = "There is no runbook named '$rbName'. Runbooks in this project: $(if ($known.Count) { (@($known | ForEach-Object { $_.name }) -join ', ') } else { 'none' })." }
        }
        $Action | Add-Member -NotePropertyName runbook -NotePropertyValue $rb -Force
        $needsApproval = ($mode -ne 'auto')
    }
    elseif ($Action.type -eq 'remember') {
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
            return @{ ok = $false; summary = "$($Action.type) $($Action.arg) refused"; output = "error: $($_.Exception.Message)" }
        }
        if ($Action.type -eq 'write') {
            $content = $Action.body
            $p = Get-WritePreview $root $Action.arg $content
            $preview = @{ path = $p.path; exists = $p.exists; old = (Get-PreviewText $p.old); new = (Get-PreviewText $p.new) }
        } else {
            $readKey = "$($Action.arg)".Replace('\', '/').TrimStart('/').ToLowerInvariant()
            $read = if ($State.ReadRanges) { @($State.ReadRanges[$readKey]) } else { @() }
            foreach ($pair in @($Action.edits)) { if ($pair -is [hashtable]) { $pair.readRanges = $read } }
            # Line-range pairs: only for lines read in this task, and only while the file is as it was read.
            $rangeProblem = Test-RangeEditAllowed $State $root $Action.arg $Action.edits
            if ($rangeProblem) {
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = $rangeProblem })
                return @{ ok = $false; summary = "edit $($Action.arg) failed"; output = "error: $rangeProblem" }
            }
            $staleNote = Get-StaleReadNote $State $root $Action.arg
            $er = Get-EditResult $root $Action.arg $Action.edits
            if (-not $er.ok) {
                # Several matches and no way to tell: not broken, Copilot only has to point at one.
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = $(if ($er.ambiguous) { 'ambiguous' } else { 'failed' }); error = $er.error })
                return @{ ok = $false; summary = "edit $($Action.arg) failed"; output = "error: $($er.error)$(if ($staleNote) { "`n$staleNote" })" }
            }
            if ($er.unchanged) {
                $out = Format-AlreadyApplied $Action.arg $er
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'done' })
                Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $true; status = 'already applied'; summary = 'already applied (verified)'; output = $out }
                return @{ ok = $true; summary = 'already applied'; output = $out; reported = $true }
            }
            $preview = @{ path = $Action.arg; exists = $true; old = (Get-PreviewText $er.old); new = (Get-PreviewText $er.new) }
        }
        # The text as it will be written: repairs of what the chat damages (a stripped script tag, entities)
        # come first, so the checks below look at the same text the file gets.
        $newText = if ($Action.type -eq 'write') { if ($null -ne $p.new) { "$($p.new)" } else { $content } } else { $er.new }
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
        # New dependencies and risky code (eval, innerHTML from a variable, shell=True, SQL from
        # strings, ...): a person approves them, also in auto mode (Guardrails.psm1).
        $guard = @()
        $deps = @(Find-NewDependencies $Action.arg $oldText $newText)
        if ($deps.Count) { $guard += "This change adds $(if ($deps.Count -eq 1) { 'a dependency' } else { "$($deps.Count) dependencies" }): $(($deps | Select-Object -First 5) -join ', '). Each one brings someone else's code into the project; approve only what you trust." }
        $risky = @(Find-RiskyCode $Action.arg $oldText $newText)
        if ($risky.Count) { $guard += "This change adds risky code: $(($risky | Select-Object -First 4) -join '; '). Approve only if it is needed and its input is trusted." }
        if ($guard.Count) {
            Write-CCBLog info agent "Guardrail approval needed for $($Action.arg)" @{ dependencies = $deps.Count; risky = $risky.Count }
            $riskWarning = (@(@($riskWarning) + $guard) | Where-Object { $_ }) -join ' '
        }
        # Code left out with a placeholder ("// rest of the code unchanged") would be lost: refuse.
        $ph = Find-PlaceholderLine $oldText $newText
        if ($ph) {
            $how = if ($Action.type -eq 'write') { 'A write block replaces the whole file, so the code that line stands for would be lost. Send the complete file, or use edit blocks for only the parts that change.' } else { 'The REPLACE text replaces the SEARCH lines completely, so the code that line stands for would be lost. Put the real lines in REPLACE, or make the SEARCH smaller so it covers only what changes.' }
            Write-CCBLog info agent "Placeholder line refused in $($Action.arg)" @{ line = $ph.line }
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = "left-out code: line $($ph.line) '$($ph.text)'" })
            return @{ ok = $false; summary = "$($Action.type) $($Action.arg) refused (left-out code)"; output = "error: not written: line $($ph.line) of the new text, '$($ph.text)', stands for code that was left out. $how" }
        }
        # A script that generates a page with stand-ins for its tags (LT in brackets before a tag
        # name): refused as a whole, whether the stand-ins are new or were there before (a page is
        # repaired instead).
        if ($Action.arg -match '(?i)\.(ps[md]?1|py|m?js|cjs|ts|rb|php|cmd|bat|sh)$') {
            $sm = Find-PlaceholderMarkup $Action.arg $newText
            if ($sm) {
                Write-CCBLog info agent "Stand-in markup script refused: $($Action.arg)"
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = 'a script writing markup with stand-ins' })
                return @{ ok = $false; summary = "$($Action.type) $($Action.arg) refused (stand-in markup)"; output = "error: not written: $sm" }
            }
        }
        # PowerShell whose [Type] before :: the chat removed cannot run: refuse, ask for a safe form.
        if ($Action.arg -match '(?i)\.ps[md]?1$') {
            $oldSet = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($l in "$oldText".Replace("`r`n", "`n").Split("`n")) { [void]$oldSet.Add($l.Trim()) }
            $added = (@("$newText".Replace("`r`n", "`n").Split("`n") | Where-Object { -not $oldSet.Contains($_.Trim()) }) -join "`n")
            $gone = Find-RemovedTypeName $added
            if ($gone) {
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = "type name removed by the chat: $gone" })
                return @{ ok = $false; summary = "$($Action.type) $($Action.arg) refused (type name removed)"; output = "error: not written: $(Format-RemovedTypeName $gone)" }
            }
        }
        # An HTML tag that arrived damaged from the chat would break the page: refuse, ask for it again.
        $bad = Find-DamagedHtmlLine $Action.arg $oldText $newText
        if ($bad) {
            Write-CCBLog info agent "Damaged HTML refused in $($Action.arg)" @{ line = $bad.line; why = $bad.why }
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'failed'; error = "damaged HTML on line $($bad.line) ($($bad.why)): $($bad.text)" })
            return @{ ok = $false; summary = "$($Action.type) $($Action.arg) refused (damaged HTML tag)"; output = "error: not written: $(Format-DamagedHtml $bad)" }
        }
        # A write that makes an existing file much shorter needs a person, also in auto mode (not a
        # to-do or plan list: ticking items off and clearing done ones is what those are for).
        if (-not $riskWarning -and $Action.type -eq 'write' -and -not (Test-TaskListFile $Action.arg) -and $oldText.Length -gt 3000 -and $newText.Length -lt $oldText.Length * 0.4) {
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
        # A to-do or plan list (TODO.md, PLAN.md...): applied without asking, in every mode but Plan only.
        if (Test-TaskListFile $Action.arg) { $needsApproval = $false }
    } elseif ($Action.type -eq 'run') {
        $evt.target = Repair-RunCommand $Action.body.Trim()   # &lt;/&gt; and [Type\]:: from the chat put back
        if (-not $evt.target) {
            # Nothing to run: no card to approve, the block goes back as a mistake.
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = 'empty run block' })
            return @{ ok = $false; summary = 'run skipped (no command)'; output = 'error: the run block has no command. Put the command on the line after ACTION run.' }
        }
        # A project script the command runs that writes a page with stand-ins for its tags would write
        # a broken page: not run, the page is to be written with a write action.
        foreach ($sm in [regex]::Matches($evt.target, '(?i)(?:-File\s+|\bpython3?\s+|\bnode\s+)"?([^\s"]+\.(?:ps1|py|m?js|cjs))"?')) {
            $sp = $sm.Groups[1].Value
            $sfull = try { Resolve-ProjectPath $State.ProjectRoot $sp } catch { $null }
            if (-not $sfull -or -not (Test-Path -LiteralPath $sfull -PathType Leaf)) { continue }
            $why = Find-PlaceholderMarkup $sp.Replace('\', '/') ([IO.File]::ReadAllText($sfull))
            if ($why) {
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = 'the script writes markup with stand-ins' })
                return @{ ok = $false; summary = 'run skipped (stand-in markup)'; output = "not executed: $sp would write a page with stand-ins for its tags ($why). Write the page itself with a write action holding its real tags, and leave the generator out." }
            }
        }
        # A script packed into one powershell -Command line: written as a script file instead, which
        # gets the syntax check before it runs and can be read when it is approved.
        if ($evt.target -match '(?i)\b(powershell|pwsh)\b') {
            # The code is the text after -Command, usually inside its double quotes.
            $cm = [regex]::Match($evt.target, '(?i)\s-(c|command)\s+(.*)$', 'Singleline')
            $payload = if ($cm.Success) { $cm.Groups[2].Value.Trim() -replace '^"(.*)"$', '$1' } else { $evt.target }
            $gone = Find-RemovedTypeName $payload
            if ($gone) {
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = 'type name removed by the chat' })
                return @{ ok = $false; summary = 'run skipped (type name removed)'; output = "not executed: $(Format-RemovedTypeName $gone)" }
            }
        }
        $useless = Get-UselessCheckCommand $evt.target
        if ($useless) {
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = 'not run: this command cannot work here' })
            return @{ ok = $false; summary = 'run skipped (command cannot work here)'; output = "not executed: $useless." }
        }
        $download = Get-WebDownloadCommand $evt.target $State.ProjectRoot
        if ($download) {
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = "not run: $download" })
            return @{ ok = $false; summary = 'run skipped (web page read by a command)'; output = "not executed: $download. Read web pages with the web action instead: ACTION web and the address for the page's text, ACTION web source and the address for the page, script or JSON as the site sends it, with the addresses it refers to (the scripts it loads and the data addresses in its code). The same rules apply as for any web read: public addresses only, and sites the user did not name only after the user approves." }
        }
        $broken = Get-CmdQuoteBreak $evt.target
        if ($broken) {
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = "not run: $broken" })
            return @{ ok = $false; summary = 'run skipped (quotes break in cmd.exe)'; output = "not executed: $broken. Commands run through cmd.exe. Put the code in a script file with a write block and run that file (Work/NAME.ps1 with powershell -NoProfile -ExecutionPolicy Bypass -File, Work/NAME.js with node, Work/NAME.py with python), or use single quotes inside the double-quoted code instead of \""." }
        }
        $packed = Test-LongPowerShellCommand $evt.target
        if ($packed) {
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = "not run: $packed" })
            return @{ ok = $false; summary = 'run skipped (script in one command line)'; output = "not executed: $packed. Write the code as a script file instead with a write block (plain ASCII, for Windows PowerShell 5.1): Work/NAME.ps1 for a one-off job, Scripts/NAME.ps1 if it is worth keeping to run again. Then run it with: powershell -NoProfile -ExecutionPolicy Bypass -File Work/NAME.ps1 (or the Scripts/ path)" }
        }
        # Hard boundary: deleting or moving files only inside the project. Not even a person can
        # approve past it. Only a target that comes from a variable (a build script's $dist) and
        # nothing else goes to a person: hold to run, never without one.
        $outside = Test-DeleteScope $State.ProjectRoot $evt.target
        $unchecked = if ($outside) { Test-DeleteNeedsPerson $State.ProjectRoot $evt.target } else { $null }
        if ($unchecked -and -not $State.Headless) { $outside = $null }
        if ($outside) {
            Write-CCBLog info agent 'Command refused: deletes or moves outside the project' @{ reason = $outside }
            Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = "refused: $outside" })
            return @{ ok = $false; summary = 'run refused (outside the project)'; output = "not executed: $outside. Files may only be deleted or moved inside the project folder. Name each file or folder as a plain path inside the project (relative to it), without .., variables, or changing folders first." }
        }
        # The project's own working folders (Work/, Scripts/, Logs/) a command names: made before it
        # runs, since a tool that writes into a missing folder fails (curl: "error on write").
        foreach ($kind in 'Work', 'Scripts', 'Logs') {
            $dir = Get-LayoutPath $kind
            if ($evt.target -match "(?i)(?<![\w.-])$([regex]::Escape($dir))[\\/]" -and $State.ProjectRoot) {
                $full = Join-Path $State.ProjectRoot $dir
                if (-not (Test-Path -LiteralPath $full)) { try { $null = New-Item -ItemType Directory -Path $full -ErrorAction Stop } catch { Write-CCBLogError agent "make $dir" $_ } }
            }
        }
        $needsApproval = -not (Test-AutoRun $State $evt.target)
        # The project scripts the command starts (and the scripts those start): the Microsoft 365 and
        # delete risk reads their text too, since the command line only names them.
        $runScripts = @(try { Get-RunScripts $State.ProjectRoot $evt.target } catch { Write-CCBLogError agent 'run scripts' $_ })
        $risk = Get-CommandRisk $evt.target
        foreach ($s in $runScripts) {
            $sr = Get-CommandRisk $s.text
            if ($sr.m365) { $risk.m365 = $true }
            if ($sr.destructive) { $risk.destructive = $true }
            foreach ($w in @($sr.reasons)) { $x = "$w (in $($s.path))"; if (@($risk.reasons) -notcontains $x) { $risk.reasons = @($risk.reasons) + $x } }
        }
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
        # A project script the command starts: its whole text on the card, so the person reads what
        # they approve (the command line alone shows only its name).
        if (-not $preview) { $preview = try { Get-RunScriptPreview $State.ProjectRoot $evt.target } catch { Write-CCBLogError agent 'script preview' $_; $null } }
        if ($unchecked) {
            $needsApproval = $true; $personOnly = $true
            $note = "StreamHub cannot check where this deletes or moves files: $unchecked. Read the script below and only approve it if every target stays inside the project."
            $riskWarning = if ($riskWarning) { "$riskWarning $note" } else { "Human in the loop: $note" }
        }
        # What it does beyond the project's files (writes outside, code built while it runs, changes to
        # the computer, data sent out): a person approves it, never without one.
        $effects = @(try { Get-RunEffects $State.ProjectRoot $evt.target $runScripts } catch { Write-CCBLogError agent 'run effects' $_ })
        if ($effects.Count) {
            $list = $effects -join '; '
            if ($State.Headless) {
                Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'skipped'; error = "refused: this command $list; that needs a person to approve it" })
                Add-AgentEvent $State 'human-required' @{ text = "Copilot wanted to run a command that $list. StreamHub does not run such commands without a person approving them. Command: $($evt.target)" }
                return @{ ok = $false; summary = 'run refused (needs a person)'; output = "not executed: this command $list. That reaches beyond the project, so it needs a person. Do not try a workaround; keep the work inside the project, or tell the user what to run themselves and why." }
            }
            $needsApproval = $true; $personOnly = $true
            $note = "This goes beyond the project: it $list. Read the script below and only approve it if you want exactly this to happen."
            $riskWarning = if ($riskWarning) { "$riskWarning $note" } else { "Human in the loop: $note" }
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
        return @{ ok = $false; summary = "$($Action.type) skipped (plan mode)"; output = $(if ($Action.type -eq 'run') { 'not executed: plan mode is on (read-only), so no commands run. To look at something for the plan, use the read-only actions: read, glob, grep and find for project files, web for a public web page (not a command that downloads it). Then describe the plan.' } else { 'not executed: plan mode is on (read-only). Describe the plan instead of changing files or running commands.' }) }
    }

    if ($needsApproval) {
        # Explicit $null: an if without else yields AutomationNull, which ConvertTo-Json writes as {}.
        $warn = $null
        if ($Uncertain -gt 0) { $warn = 'Copilot''s reply had to be repaired after its link filter removed text; check this change carefully.' }
        if ($riskWarning) { $warn = $riskWarning }
        # A change to an existing file in several places: the card offers each block on its own.
        if ($Action.type -in 'write', 'edit' -and $preview -and $preview.exists -and "$oldText".Length -le 200000 -and "$newText".Length -le 200000) {
            $hunks = @(try { Get-LineHunks "$oldText" "$newText" } catch { Write-CCBLogError agent 'change blocks' $_ })
            if ($hunks.Count -ge 2) { $preview.hunks = $hunks }
        }
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
        # Approved in part: only the blocks the person kept are written; Copilot is told which were left out.
        $skip = @(@($d.skip) | Where-Object { "$_" -match '^\d+$' } | ForEach-Object { [int]$_ })
        if ($skip.Count -and $Action.type -in 'write', 'edit' -and $preview -and $preview.hunks) {
            $all = @($preview.hunks)
            $merged = Merge-LineHunks "$oldText" "$newText" $skip
            $before = "$oldText"
            $out = Invoke-WriteAction $root $Action.arg $merged $Checkpoint
            try { Add-CheckpointCount $Checkpoint $Action.arg $before (Read-TextFile (Resolve-ProjectPath $root $Action.arg)).Text } catch { Write-CCBLogError agent 'line counts' $_ }
            $left = @($all | Where-Object { $skip -contains [int]$_.index } | ForEach-Object { "lines $($_.oldStart)-$($_.oldStart + [Math]::Max(0, $_.oldCount - 1)) of the old file ($($_.first))" })
            $note = "The user approved $($all.Count - $left.Count) of the $($all.Count) changed blocks and left these as they were: $($left -join '; '). Do not make those changes again unless the user asks."
            $view = try { $now = (Read-TextFile (Resolve-ProjectPath $root $Action.arg)).Text; Get-ChangedView $before $now (Resolve-ProjectPath $root $Action.arg) $Action.arg } catch { '' }
            try { Register-ReadStamp $State $root ("$($Action.arg)".Replace('\', '/').TrimStart('/').ToLowerInvariant()) -Seen } catch { }
            return @{ ok = $true; summary = "$out (in part: $($all.Count - $left.Count) of $($all.Count) blocks)"; output = "$out`n$note$(if ($view) { "`n$view" })"; changed = $true; path = $Action.arg }
        }
    } else {
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ preview = $preview })
    }

    if ($Action.type -in 'write', 'edit') { Save-BeforeShot $State "$($Action.arg)" }
    try {
        switch ($Action.type) {
            'write' {
                $before = try { $wf = Resolve-ProjectPath $root $Action.arg; if (Test-Path -LiteralPath $wf -PathType Leaf) { (Read-TextFile $wf).Text } else { '' } } catch { '' }
                $out = Invoke-WriteAction $root $Action.arg $Action.body $Checkpoint
                try { Add-CheckpointCount $Checkpoint $Action.arg $before (Read-TextFile (Resolve-ProjectPath $root $Action.arg)).Text } catch { Write-CCBLogError agent 'line counts' $_ }
                if (@($artNote).Count) { $out += '; ' + ($artNote -join '; ') }
                return @{ ok = $true; summary = $out; output = $out; changed = $true; path = $Action.arg }
            }
            'runbook' {
                # It runs right after this reply (a runbook starts its own chat, so not inside this turn).
                $rb = $Action.runbook
                $null = Submit-AgentTask $State @{ kind = 'runbook'; name = "$($rb.name)" } 'copilot'
                return @{ ok = $true; summary = "runbook $($rb.name) queued"; output = "Runbook '$($rb.title)' ($($rb.name)) is queued: it runs right after this reply, read-only, and saves its result to $($rb.output). Do not run it again; finish with done." }
            }
            'remember' { $null = Invoke-WriteAction $root 'AGENTS.md' $Action.newNotes $Checkpoint; return @{ ok = $true; summary = 'added to the project notes (AGENTS.md)'; output = 'saved to the project notes (AGENTS.md, ## Learned)'; changed = $true; path = 'AGENTS.md' } }
            'edit'  {
                $before = try { (Read-TextFile (Resolve-ProjectPath $root $Action.arg)).Text } catch { '' }
                $out = Invoke-EditAction $root $Action.arg $Action.edits $Checkpoint
                if (@($artNote).Count) { $out += '; ' + ($artNote -join '; ') }
                # The changed lines as they are now, so the next edit starts from the current text.
                $view = try { $now = (Read-TextFile (Resolve-ProjectPath $root $Action.arg)).Text; Get-ChangedView $before $now (Resolve-ProjectPath $root $Action.arg) $Action.arg } catch { '' }
                # Copilot saw this change (the lines above): no stale note for it; line numbers from its read are over.
                try { Register-ReadStamp $State $root ("$($Action.arg)".Replace('\', '/').TrimStart('/').ToLowerInvariant()) -Seen } catch { }
                try { Add-CheckpointCount $Checkpoint $Action.arg $before (Read-TextFile (Resolve-ProjectPath $root $Action.arg)).Text } catch { Write-CCBLogError agent 'line counts' $_ }
                return @{ ok = $true; summary = $out; output = $(if ($view) { "$out`n$view" } else { $out }); changed = $true; path = $Action.arg }
            }
            'run'   {
                # What the command changes joins this step's change set, so Undo restores it.
                $snap = if ($Checkpoint) { try { Start-RunSnapshot $Checkpoint $root } catch { Write-CCBLogError agent 'run snapshot' $_; $null } }
                $watch = New-RunWatch $State "$Id" 'command' $evt.target
                try { $r = Invoke-RunAction $root $evt.target -TimeoutSec $State.Config.commandTimeoutSec -CancelCheck ({ [bool]$State.Cancel }.GetNewClosure()) -OnProgress $watch } finally { Stop-RunWatch $State "$Id" }
                $status = if ($r.cancelled) { 'stopped by the user' } elseif ($r.timedOut) { "timed out after $($State.Config.commandTimeoutSec)s" } else { "exit code $($r.exitCode)" }
                $out = "$status`n~~~~`n$($r.output)`n~~~~"
                # A command that wanted a terminal to ask questions (StreamHub runs them without one).
                if ($r.exitCode -ne 0 -and -not $r.cancelled) { $tty = Get-InteractiveNote "$($r.output)"; if ($tty) { $out += "`n$tty" } }
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
                    Add-OwnChangeEvent $State 'restore' "$(@($fixed).Count) read-only file(s)" 'Source/ and protected files are read-only; StreamHub undid what the command did to them.' -Output ($fixed -join "`n")
                    $out += "`nNote: Source/ and the files the user protected are read-only. This command changed them, so they were put back: " + ($fixed -join '; ') + '. Work on copies elsewhere in the project.'
                }
                if ($runChanged.Count) { $out += "`nFiles this command changed: " + ($runChanged -join ', ') }
                # Exit code 0 with PowerShell errors in the output: the command did not do what it should.
                $hidden = if ($r.exitCode -eq 0 -and -not $r.cancelled -and -not $r.timedOut) { Get-HiddenErrorNote "$($r.output)" } else { '' }
                if ($hidden) { $out += "`n$hidden"; $status = 'exit code 0, with errors' }
                return @{ ok = (-not $r.timedOut -and -not $r.cancelled -and $r.exitCode -eq 0 -and -not $hidden); summary = "ran: $status"; output = $out; changed = [bool]$runChanged.Count }
            }
        }
    } catch {
        return @{ ok = $false; summary = "$($Action.type) failed"; output = "error: $($_.Exception.Message)" }
    }
}

# --- One user turn -------------------------------------------------------------------

# --- Issue cycle: index, change, scan the changed files, fix in cycles, scan again -------------

function Invoke-AgentAction {
    <# Runs generic project hooks around the action executor. beforeAction can block an action;
       afterAction is reported with the action result so a failed check is visible to Copilot. #>
    param($State, $Action, [string]$Id, $Checkpoint, [int]$Uncertain)
    $context = @{ action = "$($Action.type)"; target = "$($Action.arg)"; id = $Id }
    $before = @()
    try { $before = @(Invoke-ProjectHooks $State 'beforeAction' @() $context) }
    catch { Write-CCBLogError agent 'beforeAction hooks' $_ }
    if ($before.Count) {
        return @{ ok = $false; summary = 'A beforeAction hook blocked this action.'; output = "Not applied: a beforeAction hook failed.`n$($before -join "`n")"; hookFailures = $before }
    }
    $result = Invoke-AgentActionCore $State $Action $Id $Checkpoint $Uncertain
    $after = @()
    try { $after = @(Invoke-ProjectHooks $State 'afterAction' @() $context) }
    catch { Write-CCBLogError agent 'afterAction hooks' $_ }
    if ($after.Count) {
        $extra = "afterAction hook failure(s):`n$($after -join "`n")"
        $result.output = @($result.output, $extra) -join "`n"
        $result.hookWarnings = $after
        $result.summary = @($result.summary, 'afterAction hook warning') -join '; '
    }
    $result
}

function Get-IssueSettings($State) {
    <# harness.json "issues": enabled (on/off), autoFix (categories fixed without asking: error,
       secret, health), maxAttempts (fix tasks per file before 'gave up'). #>
    $c = $State.Config.issues
    @{ enabled = "$($c.enabled)" -ne 'off'
       autoFix = @(if ($c -and $null -ne $c.autoFix) { @("$(@($c.autoFix) -join ',')".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'none' }) } else { 'error' })
       maxAttempts = $(if ($c -and [int]$c.maxAttempts -gt 0) { [int]$c.maxAttempts } else { 3 }) }
}

function Get-IssueBaseline($State) {
    <# Step 1: the index is current before a change; returns the ids of the issues already there
       (only issues a change adds are fixed automatically). $null when issues are off or failed. #>
    if (-not (Get-IssueSettings $State).enabled -or -not $State.ProjectRoot) { return $null }
    $State.Activity.kind = 'index'; $State.Activity.label = 'Indexing the project for issues before the change'
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

$script:BracketProblem = "closes nothing|does not match the|is never closed|never closed|half open|half closed"

function Get-FixEvidence {
    <# What StreamHub can show Copilot about problems in a file, instead of letting it work from
       memory: the file as it is now around each problem (whole blocks), the bracket map for bracket
       problems, and the lines in other files that use it. Text, or "". #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Path, $Issues, [int]$MaxChars = 12000)
    $parts = New-Object System.Collections.Generic.List[string]
    $full = try { Resolve-ProjectPath $ProjectRoot $Path } catch { $null }
    if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { return '' }
    $text = (Read-TextFile $full).Text.Replace("`r`n", "`n")
    $lines = @($Issues | ForEach-Object { [int]$_.line } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    foreach ($l in $lines) {
        $msg = @($Issues | Where-Object { [int]$_.line -eq $l } | ForEach-Object { "$($_.message)$($_.text)" }) -join ' '
        if ($msg -match $script:BracketProblem) { $map = Format-OpenBlocks $Path $text $l; if ($map) { $parts.Add($map) } }
    }
    # Ranged reads widen to whole blocks (functions, <script> blocks); without line numbers the whole file.
    $specs = if ($lines.Count) { @($lines | ForEach-Object { "${Path}:$([Math]::Max(1, $_ - 25))-$($_ + 25)" }) } else { @($Path) }
    $read = try { (Invoke-ReadAction $ProjectRoot $specs -MaxCharsPerFile $MaxChars) -join "`n`n" } catch { '' }
    if ($read) { $parts.Add("The file as it is now, around the problems:`n$read") }
    $users = try { Format-ImportUsers $ProjectRoot @($Path) } catch { '' }
    if ($users) { $parts.Add($users) }
    $parts -join "`n`n"
}

function Add-ErrorView($State, $Results, $Findings) {
    <# The lines around new errors (at most 2 files, 3 places each), widened to whole blocks by the
       ranged read, as a result block; the ranges count as read in this task (Register-ReadStamp,
       ReadRanges), so a line-range edit can fix them straight away. #>
    $specs = @(foreach ($g in @($Findings | Group-Object path | Select-Object -First 2)) {
        foreach ($l in @($g.Group | ForEach-Object { [int]$_.line } | Sort-Object -Unique | Select-Object -First 3)) { "$($g.Name):$([Math]::Max(1, $l - 3))-$($l + 3)" }
    })
    if (-not $specs.Count) { return }
    $view = (Invoke-ReadAction $State.ProjectRoot $specs -MaxCharsPerFile 4000) -join "`n`n"
    if (-not "$view".Trim() -or $view -match '\(error: ') { return }
    if ($null -eq $State.ReadRanges) { $State.ReadRanges = @{} }
    foreach ($m in [regex]::Matches($view, '(?m)^### (\S+)(?: \(lines (\d+)-(\d+) of \d+)?')) {
        $key = $m.Groups[1].Value.Replace('\', '/').TrimStart('/').ToLowerInvariant()
        try { Register-ReadStamp $State $State.ProjectRoot $key } catch { }
        $range = if ($m.Groups[2].Success) { @{ from = [int]$m.Groups[2].Value; to = [int]$m.Groups[3].Value } } else { @{ from = 1; to = 2000000000 } }
        $State.ReadRanges[$key] = @(@($State.ReadRanges[$key] | Where-Object { $_ }) + @($range))
    }
    $Results.Add(@{ head = '### The code around these errors, as it is now'; output = "Fix the errors in these lines (they count as read, so ACTION edit PATH:START-END works on them):`n`n$view" })
}

function Get-FixDiagnosis($State, [int]$FromSeq) {
    <# Copilot's "Cause:" lines from a fix attempt's replies (at most 4 lines), or "". #>
    $texts = @(Get-AgentEvents $State $FromSeq | Where-Object { $_.type -eq 'assistant' } | ForEach-Object { "$($_.text)" })
    foreach ($t in $texts) {
        $m = [regex]::Match($t, '(?ms)^[\s*_#>-]{0,4}Cause[*_]{0,2}\s*:[*_]{0,2}\s*(.+?)(?=\n\s*\n|\n```|\z)')
        if ($m.Success) {
            $d = @($m.Groups[1].Value.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 4) -join ' '
            if ($d.Length -gt 600) { $d = $d.Substring(0, 597) + '...' }
            return $d
        }
    }
    ''
}

function New-FixAttemptMessage {
    <# The fix task text per attempt: 1 the problems (New-FixMessage); 2 diagnose before fixing,
       with evidence (the file now, the bracket map, what the previous attempt changed, users);
       3 fresh eyes: the last version without the problems and how the file differs from it. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Path, $Issues, [int]$Attempt = 1, $Context = @{})
    if ($Attempt -le 1) { return New-FixMessage $Path @($Issues) 1 }
    $sb = New-Object Text.StringBuilder
    $list = @(foreach ($i in @($Issues)) { "- $(if ($i.line) { "line $($i.line): " })$($i.message)" }) -join "`n"
    if ($Attempt -eq 2) {
        [void]$sb.AppendLine("These problems in $Path are still there after the previous attempt, so first find the real cause instead of repeating that change.")
    } else {
        [void]$sb.AppendLine("These problems in $Path are still there after $($Attempt - 1) attempts. Look at it with fresh eyes: do not patch the previous fix again.")
        if ($Context.diagnosis) { [void]$sb.AppendLine("Earlier diagnosis (it did not lead to a fix, so check it): $($Context.diagnosis)") }
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Problems now:`n$list")
    if ($Attempt -ge 3 -and $Context.origin) {
        $good = try { Get-ChangeSetFileDiff $ProjectRoot $Context.origin $Path } catch { $null }
        $now = try { (Read-TextFile (Resolve-ProjectPath $ProjectRoot $Path)).Text } catch { $null }
        if ($good -and $null -ne $now -and $good.old) {
            $d = Format-LineChange $good.old $now 120
            if ($d) {
                [void]$sb.AppendLine()
                [void]$sb.AppendLine("The last version of $Path without these problems is the one from before the change that brought them. How the file differs from it now (- that version, + now):")
                [void]$sb.AppendLine('```diff'); [void]$sb.AppendLine($d); [void]$sb.AppendLine('```')
                [void]$sb.AppendLine('Keep what those changes were meant to do, but rebuild the broken part from that version instead of patching the current text again.')
            }
        }
    } elseif ($Context.lastChange) {
        $prev = try { Get-ChangeSetFileDiff $ProjectRoot $Context.lastChange $Path } catch { $null }
        if ($prev) {
            $d = Format-LineChange $prev.old $prev.new 80
            if ($d) {
                [void]$sb.AppendLine()
                [void]$sb.AppendLine("What the previous attempt changed in $Path (- before, + after); the problems above are still there after it:")
                [void]$sb.AppendLine('```diff'); [void]$sb.AppendLine($d); [void]$sb.AppendLine('```')
            }
        }
    }
    $ev = Get-FixEvidence $ProjectRoot $Path $Issues
    if ($ev) { [void]$sb.AppendLine(); [void]$sb.AppendLine($ev) }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Start your reply with a line that begins with Cause: and, in 2 to 4 lines, what causes each problem and why the earlier change did not remove it. Then fix the cause with edit blocks and change nothing else. If a problem is not real, leave the code as it is and say why in the done summary.')
    $sb.ToString().TrimEnd()
}

function Submit-IssueFix {
    <# Queues one fix task for one file's issues (a coding turn in the current chat). Returns $null
       when it may not: past issues.maxAttempts, or a fix for that file is already waiting (that
       task scans the whole file afterwards, so it covers these issues too). #>
    # $Context: origin (the change set that brought the problems), lastChange (the previous
    # attempt's change set), diagnosis (Copilot's Cause: lines from attempt 2). Each attempt goes
    # further (New-FixAttemptMessage): from 2 on in Think deeper, from 3 on in a new chat.
    param($State, [string]$Path, $Issues, [int]$Attempt, $Categories, [string]$ProjectRoot, $Context = @{})
    $root = if ($ProjectRoot) { $ProjectRoot } else { $State.ProjectRoot }
    if ($Attempt -lt 1 -or $Attempt -gt (Get-IssueSettings $State).maxAttempts) { return $null }
    if (Get-QueuedIssueFix $State $root $Path) { return $null }
    $ids = @($Issues | ForEach-Object { $_.id })
    Set-IssueState $root $ids 'fixing' -Attempts $Attempt
    $text = try { New-FixAttemptMessage $root $Path @($Issues) $Attempt $Context } catch { Write-CCBLogError agent 'fix message' $_; New-FixMessage $Path @($Issues) $Attempt }
    $task = @{ kind = 'chat'; text = $text; forceKind = 'coding'; projectRoot = $root
        issueFix = @{ path = $Path; ids = $ids; attempt = $Attempt; categories = @($Categories); origin = "$($Context.origin)"; lastChange = "$($Context.lastChange)"; diagnosis = "$($Context.diagnosis)"
            # For the fix case log (FixCases.psm1): the request that brought the problems, the problems as found, earlier tries.
            request = "$($Context.request)"; problems = $(if ($Context.problems) { @($Context.problems) } else { @($Issues | ForEach-Object { "$(if ($_.line) { "line $($_.line): " })$($_.message)" }) }); history = @($Context.history) } }
    if ($Attempt -ge 2) { $task.responseMode = 'deep' }   # Copilot's own reasoning mode
    if ($Attempt -ge 3) { $task.freshChat = $true }       # earlier attempts' context can anchor the wrong idea
    Submit-AgentTask $State $task 'issues' "Fix $(@($ids).Count) issue(s) in $Path$(if ($Attempt -gt 1) { " (attempt $Attempt)" })"
}

function Invoke-IssueCycle {
    <# Steps 3 to 6: scans the files a turn changed; queues a fix task per file for issues the
       change added (categories in issues.autoFix); after a fix task checks that file again:
       gone = fixed, still there = another attempt (up to issues.maxAttempts), then 'gave up'.
       Returns the notes it showed. #>
    param($State, [string[]]$Paths, $Baseline, $Fix, [string]$ChangeSet = '', [string]$Request = '')
    $cfg = Get-IssueSettings $State
    if (-not $cfg.enabled -or $null -eq $Baseline) { return }
    $root = $State.ProjectRoot
    $list = @($Paths | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') } | Select-Object -Unique)
    $State.Activity.kind = 'index'; $State.Activity.label = "Scanning $($list.Count) changed file(s) for issues"
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
        # What this attempt brought: its change set (when it changed the file) and Copilot's diagnosis.
        $own = if ($State.IssueFixFromSeq) { Get-FixDiagnosis $State ([int]$State.IssueFixFromSeq) } else { '' }
        $diag = if ($own) { $own } else { "$($Fix.diagnosis)" }
        # This try, for the fix case log.
        $how = switch ([int]$Fix.attempt) { 1 { 'the problems listed' } 2 { 'cause first, with the file now, the bracket map and the last change (Think deeper)' } default { 'fresh eyes in a new chat, from the last version without the problem (Think deeper)' } }
        $history = @(@($Fix.history) | Where-Object { $_ }) + @(@{ attempt = [int]$Fix.attempt; how = $how; diagnosis = $own; left = @($left | ForEach-Object { "$(if ($_.line) { "line $($_.line): " })$($_.message)" }) })
        $ctx = @{ origin = "$($Fix.origin)"; lastChange = $(if ($ChangeSet -and @($Paths) -contains $Fix.path) { $ChangeSet } else { "$($Fix.lastChange)" }); diagnosis = $diag; request = "$($Fix.request)"; problems = @($Fix.problems); history = $history }
        # A problem that needed more than one try (fixed or not) gets a case log for review.
        $writeCase = {
            param([bool]$fixed, [string]$outcome)
            try {
                $change = ''
                if ($Fix.origin) { $d = try { Get-ChangeSetFileDiff $root "$($Fix.origin)" "$($Fix.path)" } catch { $null }; if ($d) { $change = Format-LineChange $d.old $d.new 60 } }
                $rel = Write-FixCase $root @{ kind = 'issue fix'; path = "$($Fix.path)"; problems = @($Fix.problems); request = "$($Fix.request)"; change = $change; attempts = $history; outcome = $outcome; fixed = $fixed }
                Add-AgentEvent $State 'status' @{ text = "Fix case recorded for review: $rel"; path = $rel }
            } catch { Write-CCBLogError agent 'fix case' $_ }
        }
        if (-not $left.Count) {
            $notes.Add("Issue fix: $($Fix.path) is clean again ($gone problem(s) fixed).")
            if ([int]$Fix.attempt -ge 2) { & $writeCase $true "fixed at try $($Fix.attempt)" }
        }
        elseif ([int]$Fix.attempt -lt $cfg.maxAttempts) {
            $next = Submit-IssueFix $State $Fix.path $left ([int]$Fix.attempt + 1) $cats $root $ctx
            $how = switch ([int]$Fix.attempt + 1) { 2 { ': Copilot looks for the cause first, with the file as it is now and what the last attempt changed (Think deeper)' } { $_ -ge 3 } { ': with fresh eyes in a new chat, from the last version without the problem (Think deeper)' } default { '' } }
            if ($next) { $notes.Add("Issue fix: $($left.Count) problem(s) left in $($Fix.path); trying again (attempt $([int]$Fix.attempt + 1) of $($cfg.maxAttempts))$how.") }
            else { $notes.Add("Issue fix: $($left.Count) problem(s) left in $($Fix.path); a fix for that file is already waiting in the queue.") }
        } else {
            & $writeCase $false "still there after $($Fix.attempt) tries; marked 'gave up'"
            Set-IssueState $root $leftIds 'gave up' -Attempts ([int]$Fix.attempt) -Note "still there after $($Fix.attempt) attempt(s)$(if ($diag) { ". Copilot's diagnosis: $diag" })"
            $notes.Add("Issue fix: $($left.Count) problem(s) in $($Fix.path) are still there after $($Fix.attempt) attempt(s); marked 'gave up'. They are listed under Code health > Issues$(if ($diag) { ", with Copilot's diagnosis: $diag" } else { '.' })")
        }
    }
    $new = @($report | Where-Object { -not $Baseline.ContainsKey($_.id) -and $_.status -eq 'open' -and (-not $Fix -or $_.path -ne $Fix.path) })
    # No chains: problems a fix task causes in other files are only reported. Otherwise fixing A
    # could break B, fixing B break A, and so on, each starting again at attempt 1.
    $auto = if ($Fix) { @() } else { @($new | Where-Object { $_.category -in $cfg.autoFix }) }
    $groups = @($auto | Group-Object path | Where-Object { Submit-IssueFix $State $_.Name @($_.Group) 1 $cfg.autoFix $root @{ origin = $ChangeSet; request = $Request } })
    if ($new.Count) {
        $files = @($new | Group-Object path).Count
        $reported = $new.Count - @($groups | ForEach-Object { $_.Group }).Count
        $notes.Add("Issue scan: $($new.Count) new problem(s) in $files $(if ($Fix) { 'other ' })changed file(s)$(if ($groups.Count) { "; queued a fix for $($groups.Count) file(s)" })$(if ($reported) { "; $reported only reported (Code health > Issues)" }).")
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
            # The import index too, so "Used by" and broken-link checks have data before the first task.
            try { Import-Module (Join-Path $Lib 'Imports.psm1'); $null = Update-ImportIndex $Root } catch { }
        } catch { $Progress.error = $_.Exception.Message } finally { $Progress.label = ''; $Progress.running = $false }
    }).AddArgument($PSScriptRoot).AddArgument($ProjectRoot).AddArgument($ix).AddArgument([bool]$Force)
    $null = $ps.BeginInvoke()
    $script:Indexer = $ps
    Write-CCBLog info agent 'Issue index started' @{ project = $ProjectRoot; force = [bool]$Force }
    $true
}

function Invoke-FinalChecks {
    <# When a task changed files but ended without Copilot reporting it done (the round limit, a reply
       without actions, Copilot stopping), the checks of the done step run anyway: problems the task
       added to its files, the page check and the script check of changed pages, and new files that
       nothing loads. The result goes into the task report and a card with Continue. #>
    param($State, $Checkpoint, $Ev, [string]$Reason)
    $root = $State.ProjectRoot
    $changes = @(Get-CheckpointChanges $root $Checkpoint | Where-Object { ($_.added -or $_.removed -or $_.created) -and -not $_.deleted })
    if (-not $changes.Count) { return }
    $paths = @($changes | ForEach-Object { $_.path })
    Add-AgentEvent $State 'status' @{ text = "Copilot did not report the task as done ($Reason). Checking the $($paths.Count) changed file(s) anyway..." }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($p in $paths) {
        try {
            $full = Resolve-ProjectPath $root $p
            if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-BinaryFile $full)) { continue }
            $now = Read-TextFile $full
            $before = ''
            if ($Checkpoint.Files[$p] -eq 'existed') { $bk = Join-Path $Checkpoint.Dir ($p.Replace('/', '\')); if (Test-Path -LiteralPath $bk) { $before = (Read-TextFile $bk).Text } }
            foreach ($i in @(Get-NewFileIssues $p $before $now.Text $now.Crlf $root)) { if ((Get-CheckLevel $i 'file') -eq 'error') { $found.Add("${p}: $i") } }
        } catch { Write-CCBLogError agent "final check $p" $_ }
    }
    if ("$($State.Config.pageCheck)" -ne 'off') {
        $pages = @($paths | Where-Object { $_ -match '(?i)\.html?$' })
        if (-not $pages.Count -and @($paths | Where-Object { $_ -match '(?i)\.(css|m?js|json)$' }).Count -and (Test-Path -LiteralPath (Join-Path $root 'index.html'))) { $pages = @('index.html') }
        if ($pages.Count -and $State.PreviewPort) {
            $pi = @(Test-WebPage $State $pages)
            $Ev.page = @($pi)
            foreach ($i in $pi) { $found.Add("page check: $i") }
        }
        $js = @($paths | Where-Object { $_ -match '(?i)\.(m?js|cjs|html?)$' })
        if ($js.Count) { foreach ($i in @(Test-ScriptSyntax $State $js)) { $found.Add("$i") } }
    }
    $unl = @(try { Find-UnloadedFiles $root @($changes | Where-Object { $_.created } | ForEach-Object { $_.path }) } catch { Write-CCBLogError agent 'unloaded files' $_ })
    if ($unl.Count) { $Ev.unloaded = @($unl); foreach ($u in $unl) { $found.Add("${u}: written in this task, but no page or script loads it") } }
    $Ev.unfinished = $Reason
    $Ev.final = @($found)
    $list = @($found | Select-Object -First 15)
    $continue = "You stopped before the task was finished ($Reason). " + $(if ($list.Count) {
        "The helper program checked your changes and found these problems:`n" + (($list | ForEach-Object { "- $_" }) -join "`n") + "`nFix them, finish what was asked, check it against the request, then send done."
    } else { 'The helper program checked your changes and found no problems. Finish what was asked, check it against the request, then send done.' })
    Add-AgentEvent $State 'task-unfinished' @{ text = "Copilot did not finish this task ($Reason). StreamHub checked the changed files: $(if ($found.Count) { "$($found.Count) problem(s) found" } else { 'no problems found' })."; findings = @($list); continueText = $continue }
}

function Get-LeakReport {
    <# What the helper program finds when the person reports markup or script shown as text on a
       page (Prompts Test-LeakReport), before the message goes to Copilot: the file check (Lint
       Find-LeakedMarkup) over the project's pages and scripts, the mechanical fixes applied as own
       changes (tags written with entities, a stray closing script tag), the root page as shown in a
       browser tab when the app can serve one, and each sample the page shows traced to the file
       line that holds it. Returns the text block for Copilot; a status line tells the person. #>
    param($State)
    $root = $State.ProjectRoot
    $files = @(Get-ProjectFiles $root | Where-Object { $_.path -match '(?i)\.(html?|xhtml|m?js|cjs|jsx|tsx|vue|svelte|svg|xaml)$' -and $_.path -notmatch '(?i)^(Source|\.streamhub|node_modules|dist|build|out|vendor|styles/kit|data)/|/(node_modules|dist|build|out|vendor)/|\.min\.js$' -and [int64]$_.size -le 2MB } | Select-Object -First 300)
    $fixed = New-Object System.Collections.Generic.List[string]
    $left = New-Object System.Collections.Generic.List[string]
    $texts = @{}
    foreach ($f in $files) {
        try {
            $full = Join-Path $root ($f.path.Replace('/', '\'))
            $info = Read-TextFile $full
            if ($info.Encoding -eq 'office') { continue }
            $text = $info.Text
            $found = @(Find-LeakedMarkup $f.path $text)
            if (@($found | Where-Object { $_.kind -in 'entity', 'entity-code', 'stray-close', 'broken-tag', 'lost-end', 'bare-path' }).Count) {
                $fix = Repair-MechanicalIssues $f.path $text
                $broke = @(Get-NewFileIssues $f.path $text $fix.text $info.Crlf $root | Where-Object { (Get-CheckLevel $_ 'file') -eq 'error' })
                if (@($fix.fixes).Count -and -not $broke.Count) {
                    Write-TextFile $full $fix.text $info.Bom $info.Crlf $info.Encoding
                    Add-OwnChangeEvent $State 'edit' $f.path "Fixed automatically: $(@($fix.fixes) -join '; ')." @{ path = $f.path; exists = $true; old = $text; new = $fix.text }
                    $fixed.Add("$($f.path): $(@($fix.fixes) -join '; ')")
                    $text = $fix.text
                    $found = @(Find-LeakedMarkup $f.path $text)
                }
            }
            $texts[$f.path] = $text
            foreach ($x in @($found | Select-Object -First 3)) { $left.Add("$($f.path) $($x.message)") }
        } catch { Write-CCBLogError agent "leak check $($f.path)" $_ }
    }
    # The page as shown: the root page in a browser tab, each sample traced to the file that holds it.
    $shown = New-Object System.Collections.Generic.List[string]
    if ("$($State.Config.pageCheck)" -ne 'off' -and $State.PreviewPort -and -not $State.Headless) {
        $page = if (Test-Path -LiteralPath (Join-Path $root 'index.html')) { 'index.html' } else { @($files | Where-Object { $_.path -match '(?i)^[^/]+\.html?$' } | Select-Object -First 1 | ForEach-Object { $_.path }) }
        if ($page) {
            try {
                foreach ($pi in @(Test-WebPage $State @($page) | Where-Object { $_ -match 'as plain text' })) {
                    $line = "$pi"
                    $sample = [regex]::Match($pi, "as plain text: '([^']{8,})").Groups[1].Value
                    $at = Find-TextInFiles $texts $sample
                    if ($at) { $line += " -> this text is written in $at" }
                    $shown.Add($line)
                }
            } catch { Write-CCBLogError agent 'leak page check' $_ }
        }
    }
    $n = @($files).Count
    Add-AgentEvent $State 'status' @{ text = "StreamHub checked $n page and script file(s) for markup or script shown as text: $($fixed.Count) file(s) fixed, $($left.Count) place(s) left for Copilot$(if ($shown.Count) { ", $($shown.Count) seen on the page" })." }
    if (-not $fixed.Count -and -not $left.Count -and -not $shown.Count) {
        return "THE HELPER PROGRAM CHECKED FOR MARKUP OR SCRIPT SHOWN AS TEXT`nIt read the text of $n page and script file(s) apart from their tags and found no tag written with entities, no script outside a script block and no markup given to textContent. If the page still shows code, it is written at run time by a script or comes from the data: read the script that fills that part of the page, not the page."
    }
    $out = 'THE HELPER PROGRAM CHECKED FOR MARKUP OR SCRIPT SHOWN AS TEXT'
    if ($fixed.Count) { $out += "`nFixed already (read a file again before you edit it):`n" + (($fixed | ForEach-Object { "- $_" }) -join "`n") }
    if ($left.Count) { $out += "`nStill to fix, at these lines:`n" + (($left | Select-Object -First 8 | ForEach-Object { "- $_" }) -join "`n") }
    if ($shown.Count) { $out += "`nWhat the page shows now:`n" + (($shown | ForEach-Object { "- $_" }) -join "`n") }
    $out
}

function Find-TextInFiles($Texts, [string]$Sample) {
    <# The file and line where a sample of a page's shown text is written ("FILE line N"), or $null:
       the sample's first words, in any spacing, as written or with its tags as entities, and with
       the quotes a script string escapes. #>
    if (-not $Sample) { return $null }
    $probe = $Sample.Substring(0, [Math]::Min(40, $Sample.Length)).Trim()
    $words = @($probe -split '\s+' | Where-Object { $_ })
    if ($words.Count -gt 1) { $words = @($words | Select-Object -First ($words.Count - 1)) }   # the last word may be cut
    if (-not $words.Count) { return $null }
    $forms = @(($words -join ' '), (($words -join ' ').Replace('<', '&lt;').Replace('>', '&gt;')))
    foreach ($k in @($Texts.Keys | Sort-Object)) {
        foreach ($form in $forms) {
            $re = (@($form -split ' ' | ForEach-Object { [regex]::Escape($_).Replace('"', '\\?"').Replace("'", "\\?'") }) -join '\s+')
            $m = [regex]::Match($Texts[$k], $re)
            if ($m.Success) { return "$k line $(($Texts[$k].Substring(0, $m.Index) -split "`n").Count)" }
        }
    }
    $null
}

# --- Gates of the done step ---------------------------------------------------------------------
# Each runs when Copilot says done and returns the message that sends it back, or nothing to let done
# through. $Turn holds the turn's counters and flags the gates update (a hashtable, so a change made
# here is the turn's own: assigning to a caller's variable would only make a local copy). Every call
# whose output is not wanted is discarded, so a gate returns exactly one string or nothing.

function Invoke-DoneUnloadedCheck($State, $Turn, $Checkpoint, $Ev) {
    <# New script and style files that no page, script or stylesheet loads: they have no effect.
       Once per task. #>
    if ($Turn.unloadedChecked -or -not $Checkpoint.Files.Count -or $State.Mode -eq 'plan' -or $State.Cancel) { return }
    $Turn.unloadedChecked = $true
    $created = @($Checkpoint.Files.Keys | Where-Object { $Checkpoint.Files[$_] -eq 'new' })
    $unl = @(try { Find-UnloadedFiles $State.ProjectRoot $created } catch { Write-CCBLogError agent 'unloaded files' $_ })
    if (-not $unl.Count) { return }
    $Ev.unloaded = @($unl)
    $null = Add-AgentEvent $State 'status' @{ text = "New file(s) that no page or script loads: $($unl -join ', '). Copilot is asked to load them where they are needed." }
    "These files were written in this task, but no page, script or stylesheet loads them, so they have no effect:`n" + (($unl | ForEach-Object { "- $_" }) -join "`n") + "`nAdd them where they are needed (a <script src> or <link> in the page, or an import), or delete them if they are not needed, then send done again."
}

function Invoke-DoneToolChecks($State, $Turn, $Checkpoint, $Enf) {
    <# The project's own build and check tools for the languages this task changed (ToolChecks: tsc,
       dotnet build, go vet, javac, PSScriptAnalyzer), when installed; errors go back like tests. #>
    if (-not $Checkpoint.Files.Count -or $State.Mode -eq 'plan' -or $State.NoCommands -or -not (Test-CheckSwitch 'tools') -or $Turn.toolNudges -ge [Math]::Max(1, $Enf.testTries) -or $State.Cancel) { return }
    $toolErrors = New-Object System.Collections.Generic.List[string]
    foreach ($tc in @(try { Get-ToolChecks $State.ProjectRoot @($Checkpoint.Files.Keys) } catch { Write-CCBLogError agent 'tool checks' $_ })) {
        $card = Start-OwnRunCard $State "Check with $($tc.name)" $tc.command
        $prevAct = Enter-Activity $State 'tests' "Checking with $($tc.name)"
        try { $tr = Invoke-RunAction $State.ProjectRoot $tc.command ([int]$State.Config.commandTimeoutSec) 6000 { $State.Cancel } } finally { $null = Exit-Activity $State $prevAct }
        $errs = @(Get-ToolCheckErrors $tc.kind "$($tr.output)" ([int]$tr.exitCode))
        if ($tr.timedOut) { $null = Complete-OwnRunCard $State $card $false 'timed out, not checked'; continue }
        $null = Complete-OwnRunCard $State $card (-not $errs.Count) $(if ($errs.Count) { "$($errs.Count) error(s)" } else { 'no errors' }) ($errs -join "`n")
        if ($errs.Count) { $toolErrors.Add("$($tc.name):`n" + (($errs | ForEach-Object { "- $_" }) -join "`n")) }
    }
    if (-not $toolErrors.Count) { return }
    $Turn.toolNudges++
    if ($Enf.testTries -gt 0) { "The project's own build and check tools found errors, so the task is not finished:`n" + ($toolErrors -join "`n`n") + "`nFix them, then send done again." }
}

function Invoke-DoneGuiTest($State, $Turn, $Checkpoint, $Enf) {
    <# PowerShell window apps the task changed: started once with STREAMHUB_GUI_TEST set, a picture of
       the window for Copilot, start errors sent back (GuiTest); like the tests, not without commands. #>
    if (-not $Checkpoint.Files.Count -or $State.Mode -eq 'plan' -or $State.NoCommands -or $State.Headless -or "$($State.Config.autoTests)" -in 'False', 'off' -or $Turn.guiNudges -ge [Math]::Max(1, $Enf.testTries) -or $State.Cancel) { return }
    $guiProblems = New-Object System.Collections.Generic.List[string]
    foreach ($gs in @(try { Find-GuiScripts $State.ProjectRoot @($Checkpoint.Files.Keys) } catch { Write-CCBLogError agent 'window apps' $_ })) {
        $card = Start-OwnRunCard $State "Open the window app $gs (start test)" "powershell -STA -File $gs"
        $prevAct = Enter-Activity $State 'tests' "Opening $gs"
        $shotRel = '.streamhub/Screenshots/window-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + ((Split-Path $gs -Leaf) -replace '[^\w.-]+', '-') + '.png'
        try { $gr = Test-PsGuiApp -ProjectRoot $State.ProjectRoot -Script $gs -ShotPath (Join-Path $State.ProjectRoot $shotRel.Replace('/', '\')) } catch { Write-CCBLogError agent 'window app test' $_; $gr = $null } finally { $null = Exit-Activity $State $prevAct }
        if (-not $gr) { $null = Complete-OwnRunCard $State $card $false 'the start test could not run'; continue }
        if ($gr.skipped) { $null = Complete-OwnRunCard $State $card $true "not started: $($gr.skipped)"; continue }
        if ($gr.shot) { $State.PageShots = @($State.PageShots) + @($shotRel) }
        # Must be fixed: errors at start and steps of NAME.guitest that failed. Said once:
        # controls without a name or cut off, the launcher, a missing test.
        $fails = @(@($gr.errors) + @($gr.steps) | Where-Object { $_ })
        $notes = New-Object System.Collections.Generic.List[string]
        foreach ($a in @($gr.access) + @($gr.layout)) { if ($a) { $notes.Add($a) } }
        $launch = try { Test-GuiLauncher $State.ProjectRoot $gs } catch { '' }
        if ($launch) { $notes.Add($launch) }
        $testFile = [IO.Path]::ChangeExtension($gs, '.guitest')
        if ($gr.opened -and -not $gr.ranSteps -and -not (Test-Path -LiteralPath (Join-Path $State.ProjectRoot $testFile.Replace('/', '\')))) { $notes.Add("no test: add $testFile with the steps a person takes (click NAME, type NAME = TEXT, select NAME = ITEM, expect NAME = TEXT), so the helper program can check them") }
        $okGui = $gr.opened -and -not $fails.Count
        $sum = if (-not $gr.opened) { 'no window opened' } elseif ($fails.Count) { "the window opened; $($fails.Count) problem(s)" } else { "the window '$($gr.title)' opened$(if ($gr.ranSteps) { ", $($gr.ranSteps) test step(s) passed" })" }
        $null = Complete-OwnRunCard $State $card $okGui $sum ((@($fails) + @($notes | ForEach-Object { "Note: $_" }) + @(if ($gr.shot) { "Picture: $shotRel" })) -join "`n")
        if ($fails.Count -or ($notes.Count -and $Turn.guiNudges -eq 0)) { $guiProblems.Add("$($gs):`n" + (((@($fails) + @($notes)) | ForEach-Object { "- $_" }) -join "`n")) }
    }
    if (-not $guiProblems.Count -or $Enf.testTries -le 0) { return }
    $Turn.guiNudges++
    "The helper program started the window app to check it (with STREAMHUB_GUI_TEST set), and it did not open cleanly:`n" + ($guiProblems -join "`n`n") + "`nFix the cause, then send done again."
}

function Invoke-DoneNotApplied($State, $Turn, $Checkpoint) {
    <# The person said the last change did not take effect: done with no file changed in this message
       is not a fix (at most three times, then it is taken as it is). #>
    if (-not $Turn.notApplied -or $Checkpoint.Files.Count -or $Turn.notAppliedNudges -ge 3 -or $State.Cancel) { return }
    $Turn.notAppliedNudges++
    $null = Add-AgentEvent $State 'status' @{ text = "Copilot said done without changing any file, while you said the change did not take effect. Sent back to find the cause and fix it ($($Turn.notAppliedNudges) of 3)." }
    Get-NotAppliedRefusal
}

function Invoke-DoneReminders($State, $Turn, $Checkpoint) {
    <# Once per task: code changed without a test (in a project with tests), or a new part in src/ or
       Scripts/ without a README line (Get-DoneReminders). Not for issue fixes. #>
    if ($Turn.doneReminded -or -not $Checkpoint.Files.Count -or $State.IssueFix -or $State.Mode -eq 'plan' -or $State.Cancel) { return }
    $Turn.doneReminded = $true
    $reminder = try { Get-DoneReminders $State.ProjectRoot $Checkpoint.Files -Request "$($State.TurnText)" } catch { Write-CCBLogError agent 'done reminders' $_; '' }
    if (-not $reminder) { return }
    $null = Add-AgentEvent $State 'status' @{ text = 'Before finishing: Copilot is reminded once about what is still open (tests, README, charts asked for, open TODO items).' }
    "$reminder"
}

function Invoke-DonePlanCoverage($State, $Turn, $Checkpoint, $Ev) {
    <# What the plan names and placeholder code (Get-PlanCoverage): the approved plan (a plan build) and
       Copilot's own steps against the project, at most twice per task. #>
    if ($Turn.coverageNudges -ge 2 -or -not $Checkpoint.Files.Count -or $State.IssueFix -or $State.Mode -eq 'plan' -or $State.Cancel) { return }
    $planText = ([regex]::Match("$($State.TurnText)", '(?s)(?:Approved plan|What you said you would do):\s*(.*)$').Groups[1].Value) + "`n" + ((@($State.Todos | Where-Object { $_ } | ForEach-Object { "$($_.text)" })) -join "`n")
    $cov = try { Get-PlanCoverage $State.ProjectRoot $Checkpoint.Files $Checkpoint.Dir $planText } catch { Write-CCBLogError agent 'plan coverage' $_; $null }
    $covText = if ($cov) { Format-PlanCoverage $cov } else { '' }
    if (-not $covText) { $Ev.coverage = @(); return }
    $Turn.coverageNudges++
    $Ev.coverage = @(@($cov.missing | ForEach-Object { "missing: $_" }) + @($cov.stubs))
    $null = Add-AgentEvent $State 'status' @{ text = "Before finishing: $(@($cov.missing).Count) file(s) the plan names are missing and $(@($cov.stubs).Count) placeholder(s) found; Copilot is asked to build them." }
    "$covText"
}

function Invoke-DoneVerify($State, $Turn, $Checkpoint, $Ev, $Enf) {
    <# The project's own check (verify: in AGENTS.md) after a task that changed files; without one, the
       project's tests for what changed (TestRunner.psm1, setting autoTests). Failures that were there
       before the change ($Turn.testBase, Get-TurnTestBaseline) are not Copilot's. #>
    $verifyCmd = Get-ProjectVerify $State.ProjectRoot
    $verifyLabel = 'Verify'; $isTests = $false
    if (-not $verifyCmd -and $Checkpoint.Files.Count -and $State.Mode -ne 'plan' -and "$($State.Config.autoTests)" -notin 'False', 'off') {
        $tc = try { Find-TestCommand $State.ProjectRoot @($Checkpoint.Files.Keys) } catch { Write-CCBLogError agent 'test detection' $_; $null }
        if ($tc) { $verifyCmd = $tc.command; $isTests = $true; $verifyLabel = "Tests ($($tc.kind), $(@($tc.tests).Count) file(s)$(if ($tc.scope -eq 'related') { ' for the changed files' }))" }
    }
    if (-not $verifyCmd -or -not $Checkpoint.Files.Count -or $State.Mode -eq 'plan') { return }
    $risk = Get-CommandRisk $verifyCmd
    $why = Test-DeleteScope $State.ProjectRoot $verifyCmd
    if ($State.NoCommands -or ($State.Headless -and -not $State.AllowCommands)) { $Ev.verify = @{ command = $verifyCmd; skipped = 'commands are not allowed for this task' }; return }
    if ($why -or $risk.m365 -or $risk.destructive) { $Ev.verify = @{ command = $verifyCmd; skipped = 'the command deletes files or works with Microsoft 365, so it only runs by hand' }; return }
    $null = Add-AgentEvent $State 'status' @{ text = "${verifyLabel}: running ``$verifyCmd``..." }
    $prevAct = Enter-Activity $State 'tests' $(if ($isTests) { 'Running the tests' } else { "Running the project's check" })
    # No card for this run: the app shows the live output under the waiting indicator.
    $watch = New-RunWatch $State 'verify' $verifyLabel $verifyCmd
    try { $vr = Invoke-RunAction $State.ProjectRoot $verifyCmd ([int]$State.Config.commandTimeoutSec) 20000 { $State.Cancel } -OnProgress $watch } finally { $null = Stop-RunWatch $State 'verify'; $null = Exit-Activity $State $prevAct }
    $passed = ($vr.exitCode -eq 0)
    $tail = ("$($vr.output)".Split("`n") | Select-Object -Last 25) -join "`n"
    $Ev.verify = @{ command = $verifyCmd; passed = $passed; exit = $vr.exitCode; tail = $tail }
    $testBase = $Turn.testBase
    $failNow = @(Get-TestFailureLines "$($vr.output)")
    $cmp = if (-not $passed -and -not $vr.timedOut -and $testBase -and -not $testBase.passed) { Compare-TestFailures @($testBase.failures) $failNow } else { $null }
    if ($cmp -and @($cmp.old).Count -and -not @($cmp.new).Count) { $Ev.verify.preexisting = $true }
    $null = Add-AgentEvent $State 'status' @{ text = "${verifyLabel}: ``$verifyCmd`` $(if ($passed) { 'passed' } elseif ($vr.timedOut) { 'timed out' } elseif ($Ev.verify.preexisting) { "failed (exit $($vr.exitCode)) with the same failures as before this task, so they are not sent to Copilot as its own" } else { "failed (exit $($vr.exitCode))" })." }
    if ($testBase -and "$($testBase.command)" -eq $verifyCmd -and -not $vr.timedOut -and -not $State.Cancel) {
        try { $null = Save-TestBaseline $State.TaskRecordDir @{ command = $verifyCmd; stamp = (Get-ProjectStamp $State.ProjectRoot); passed = $passed; failures = $failNow; when = (Get-Date).ToString('s') } } catch { Write-CCBLogError agent 'test baseline' $_ }
    }
    if ($passed -or $Ev.verify.preexisting -or $Turn.verifyNudges -ge $Enf.testTries -or $State.Cancel) { return }
    $Turn.verifyNudges++
    $fence = '```'
    $what = $(if ($isTests) { "The project's tests failed" } else { "The project's check failed" })
    $back = "$what, so the task is not finished. Command: $verifyCmd (exit $($vr.exitCode)). Output (end):`n$fence`n$tail`n$fence`nFix the cause (in the code, or in the test when the test is wrong about the new behaviour), then send done again."
    if ($cmp -and @($cmp.old).Count) {
        $back += "`n`nThe helper program ran the same tests before this task. These failures were already there then (leave them unless the request is about them):`n" + ((@($cmp.old) | Select-Object -First 10 | ForEach-Object { "- $_" }) -join "`n") + "`nNew since this task:`n" + ((@($cmp.new) | Select-Object -First 10 | ForEach-Object { "- $_" }) -join "`n")
    }
    $back
}

function Invoke-DoneHooks($State, $Turn, $Checkpoint, $Enf) {
    <# The project's beforeDone hooks: a failure goes back to Copilot (its own tries, so failing tests do
       not stop the hooks from running); with enforcement Light it is shown, not sent back. #>
    if (-not $Checkpoint.Files.Count -or $Turn.hookNudges -ge [Math]::Max(1, $Enf.hookTries) -or $State.Cancel) { return }
    $hookFails = @(try { Invoke-ProjectHooks $State 'beforeDone' } catch { Write-CCBLogError agent 'hooks' $_ })
    if (-not $hookFails.Count) { return }
    if ($Turn.hookNudges -ge $Enf.hookTries) {
        $Turn.hookNudges = 99
        $null = Add-AgentEvent $State 'status' @{ text = "A beforeDone hook failed (enforcement Light: shown here, not sent back to Copilot): $(("$($hookFails[0])" -split "`n")[0])" }
        return
    }
    $Turn.hookNudges++
    $fence = '```'
    "A check of the project failed, so the task is not finished:`n$fence`n$($hookFails -join "`n`n")`n$fence`nFix the cause, then send done again."
}

# --- The round's file check -------------------------------------------------------------------
# After every round that changed files, in this order (Invoke-AgentTurn): the afterEdit hooks,
# Invoke-RoundAutoFix, Invoke-RoundRollbacks, Update-RoundKitFiles, Get-RoundFindings and
# Add-RoundFindings. What they keep across rounds is in the turn's $Turn hashtable (fixTargets,
# rollbacks, warnedKeys, errorRounds, errorFirst, lastErrorKeys, syntaxNudges, warnNudges); what
# goes back to Copilot is added to the round's $Results list.

function Invoke-RoundAutoFix($State, $Changed, $Enf) {
    <# Mechanical problems with one right answer (curly quotes, odd spaces, HTML entities in code,
       mixed line endings...): fixed here by enforcement (light: silently, standard: and Copilot is
       told, strict: left to Copilot). Each fix is a card with its diff. Returns "PATH: fixes" lines. #>
    $autoFixed = New-Object System.Collections.Generic.List[string]
    if ($Enf.autoFix -eq 'off') { return }
    foreach ($p in $Changed) {
        try {
            $full = Resolve-ProjectPath $State.ProjectRoot $p
            if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-BinaryFile $full)) { continue }
            $info = Read-TextFile $full   # the text with LF only; .Crlf = what most lines had
            $fix = Repair-MechanicalIssues $p $info.Text
            $fixList = @($fix.fixes)
            # Mixed line endings (a command wrote some lines): the file on disk, written again with
            # the kind most lines have.
            $raw = [IO.File]::ReadAllText($full)
            if ($raw.Contains("`r`n") -and [regex]::IsMatch($raw, '(?<!\r)\n')) { $fixList += "line endings made all $(if ($info.Crlf) { 'CRLF' } else { 'LF' })" }
            if (-not $fixList.Count) { continue }
            # A fix that would add a problem that breaks the file is not applied.
            $broke = @(Get-NewFileIssues $p $info.Text $fix.text $info.Crlf $State.ProjectRoot | Where-Object { (Get-CheckLevel $_ 'file') -eq 'error' })
            if ($broke.Count) { $null = Write-CCBLog info agent "Auto-fix of $p not applied: it would add $($broke.Count) problem(s)"; continue }
            $fix = [pscustomobject]@{ text = $fix.text; fixes = $fixList }
            $null = Write-TextFile $full $fix.text $info.Bom $info.Crlf $info.Encoding
            $rel = $p.Replace('\', '/')
            $null = Add-OwnChangeEvent $State 'edit' $rel "Fixed automatically: $(@($fix.fixes) -join '; ')." @{ path = $rel; exists = $true; old = $info.Text; new = $fix.text }
            $autoFixed.Add("${rel}: $(@($fix.fixes) -join '; ')")
        } catch { Write-CCBLogError agent "Auto-fix $p" $_ }
    }
    $autoFixed.ToArray()
}

function Invoke-RoundRollbacks($State, $Turn, $Results, $RoundSnap) {
    <# A change to a file Copilot was fixing ($RoundSnap: its text before this round) that added a
       problem that breaks it is rolled back, at most twice per file per task ($Turn.rollbacks), with a
       wider read around the problem it was fixing ($Turn.fixTargets) in the results. #>
    foreach ($rp in @($RoundSnap.Keys)) {
        try {
            if ([int]$Turn.rollbacks[$rp] -ge 2) { continue }
            $full = Resolve-ProjectPath $State.ProjectRoot $rp
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $info = Read-TextFile $full
            $worse = @(Get-NewFileIssues $rp $RoundSnap[$rp] $info.Text $info.Crlf $State.ProjectRoot | Where-Object { (Get-CheckLevel $_ 'file') -eq 'error' })
            if (-not $worse.Count) { continue }
            $Turn.rollbacks[$rp] = 1 + [int]$Turn.rollbacks[$rp]
            $null = Write-TextFile $full $RoundSnap[$rp] $info.Bom $info.Crlf $info.Encoding
            $null = Add-OwnChangeEvent $State 'restore' $rp "Rolled back Copilot's change to ${rp}: it added $($worse.Count) new problem(s), first: $($worse[0])" @{ path = $rp; exists = $true; old = $info.Text; new = $RoundSnap[$rp] }
            # A wider read around the problem it was fixing (whole blocks), to understand the context.
            $center = [int]$Turn.fixTargets[$rp.ToLowerInvariant()]
            $spec = if ($center -gt 0) { "${rp}:$([Math]::Max(1, $center - 40))-$($center + 40)" } else { $rp }
            $context = (Invoke-ReadAction $State.ProjectRoot @($spec) -MaxCharsPerFile 12000) -join "`n"
            $Results.Add(@{ head = "### Rolled back: $rp"; output = "Your change to $rp made it worse, so it is back as it was before that change. New problems it caused:`n" + (($worse | Select-Object -First 5 | ForEach-Object { "- $_" }) -join "`n") + "`nBefore you fix it again, understand the context: below is the code around the original problem, as whole blocks. Check what it really does and confirm the cause, then make a change that fixes that cause and keeps the rest working.`n$context" })
        } catch { Write-CCBLogError agent "Rollback check $rp" $_ }
    }
}

function Update-RoundKitFiles($State, $Results, $Changed) {
    <# What StreamHub writes itself after a round, before the file checks look for missing files: the
       UI kit files the pages now use, a window app's theme and helpers, the layout of a window's tagged
       panels in its XAML, and the kit and data blocks of one-file pages. Returns the kit update (its
       unknown icon names become findings). #>
    # UI kit: what the pages now use comes from the project's kit catalogue (the rules of the kit
    # classes into styles/kit/kit.css, kit scripts and React parts a page refers to, the icons).
    $kitSync = $null
    if ((Test-UiKitOn $State.AppRoot) -and (Test-Path -LiteralPath (Join-Path (Get-UiKitCatalogPath $State.ProjectRoot) 'kit.css'))) {
        try {
            $kitSync = Update-UiKitProject $State.ProjectRoot $State.AppRoot
            $kitFiles = @(@($kitSync.added) + @($kitSync.updated))
            if ($kitFiles.Count) {
                $null = Add-OwnChangeEvent $State 'write' "$(Get-UiKitFolder)/ (UI kit)" "StreamHub took what the pages now use from the UI kit: $($kitFiles -join ', ')." -Output ($kitFiles -join "`n")
                $Results.Add(@{ head = '### UI kit'; output = "The helper program brought the kit up to date with what your pages use: $($kitFiles -join ', '). styles/kit/kit.css is written by it; do not edit it." })
            }
        } catch { Write-CCBLogError agent 'UI kit sync' $_ }
    } elseif ((Test-UiKitOn $State.AppRoot) -and (Test-UiKitPart 'icons' $State.AppRoot)) {
        # A project with the whole kit in styles/kit (from before the catalogue): only its icons.
        try { $kitSync = Update-KitIcons $State.ProjectRoot $State.AppRoot } catch { Write-CCBLogError agent 'kit icons' $_ }
    }
    # A PowerShell window app: the kit's WPF theme with the project's colours.
    try { foreach ($w in @(Update-KitWpf $State.ProjectRoot $State.AppRoot -NoTheme:(-not (Test-UiKitOn $State.AppRoot)))) { $null = Add-OwnChangeEvent $State 'write' $w $(if ($w -match 'KitWpf\.ps1$') { 'StreamHub wrote the helpers for the window app (KitWpf.ps1): dot-source it and use its functions.' } else { 'StreamHub wrote the UI kit''s theme for the window app, with the project''s colours (KitWpf.ps1 loads it).' }) } } catch { Write-CCBLogError agent 'window app kit' $_ }
    # Window apps: the layout of panels marked Tag="row" / "actions" / "form" (and, without the kit's
    # theme, one height for buttons and fields) written into the XAML itself, so the window lines up
    # however it is loaded. Copilot is told: its next edits must match.
    $laidOut = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Changed | Where-Object { $_ -match '(?i)\.xaml$' -and $_ -notmatch '(?i)^styles/kit/' -and (Test-PsGuiProject $State.ProjectRoot) })) {
        try {
            $full = Resolve-ProjectPath $State.ProjectRoot $p
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $info = Read-TextFile $full
            $lay = Expand-XamlLayout $info.Text -Heights:(-not (Test-UiKitOn $State.AppRoot))
            if (-not @($lay.changes).Count) { continue }
            $null = Write-TextFile $full $lay.text $info.Bom $info.Crlf $info.Encoding
            $rel = $p.Replace('\', '/')
            $null = Add-OwnChangeEvent $State 'edit' $rel "StreamHub wrote the window's layout into the XAML: $(@($lay.changes) -join '; ')." @{ path = $rel; exists = $true; old = $info.Text; new = $lay.text }
            $laidOut.Add("${rel}: $(@($lay.changes) -join '; ')")
        } catch { Write-CCBLogError agent "Window layout $p" $_ }
    }
    if ($laidOut.Count) { $Results.Add(@{ head = '### Window layout'; output = "The helper program wrote the layout values of the tagged panels into the XAML (Orientation, alignment, margins, grid rows and columns), so the window lines up however it is loaded. Read the lines again before you edit them:`n" + (($laidOut | ForEach-Object { "- $_" }) -join "`n") }) }
    # One-file pages: their UI kit and data blocks follow what the page uses now.
    $onePages = @(Sync-OneFilePages $State)
    if ($onePages.Count) { $Results.Add(@{ head = '### One-file page'; output = "The helper program filled the UI kit and data blocks (data-streamhub) of $($onePages -join ', ') with what the page uses now. Those lines are its own: they show as a note when you read the page; never edit them." }) }
    $kitSync
}

function Get-RoundFindings($State, $Turn, $Checkpoint, $Ev, $Changed, $HookIssues, $KitSync) {
    <# Every finding about the round's files with its source, so it gets a level (CheckPolicy.psm1):
       errors break the file and "done" waits for them; warnings are likely mistakes, said once per
       task ($Turn.warnedKeys). Left out: what Copilot disputed in this task and what the person
       ignored. Only problems the task added count. #>
    $found = New-Object System.Collections.Generic.List[object]
    $quality = Test-CheckSwitch 'quality'   # setting: quality notes
    foreach ($p in $Changed) {
        try {
            $full = Resolve-ProjectPath $State.ProjectRoot $p
            if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-BinaryFile $full)) { continue }
            $now = Read-TextFile $full
            $rel = $p.Replace('\', '/')
            if ($rel -match '(?i)\.html?$' -and (Get-GeneratedPage $State.ProjectRoot $rel $now.Text)) { continue }   # a page a project script built: its template is checked
            $before = ''
            if ($Checkpoint.Files[$rel] -eq 'existed') { $bk = Join-Path $Checkpoint.Dir ($rel.Replace('/', '\')); if (Test-Path -LiteralPath $bk) { $before = (Read-TextFile $bk).Text } }
            # Shown while it runs: the checks can start a tool (node --check, python, prisma validate).
            $prevAct = Enter-Activity $State 'syntax' "Checking $rel$(if ($rel -match '(?i)\.prisma$') { ' (prisma validate)' })"
            try { $issuesNow = @(Get-NewFileIssues $rel $before $now.Text $now.Crlf $State.ProjectRoot) } finally { $null = Exit-Activity $State $prevAct }
            foreach ($i in $issuesNow) { $found.Add((ConvertTo-CheckFinding $rel $i $(if ($i -match ' says: ') { 'tool' } else { 'file' }))) }
            # A SharePoint HTML page (the project's setup): what the sandbox would block, as errors.
            if (Test-SharePointPageProject $State.ProjectRoot) { foreach ($i in @(Find-SharePointPageIssues $rel $before $now.Text)) { $found.Add((ConvertTo-CheckFinding $rel $i 'file')) } }
            if ($quality) {
                foreach ($i in @(Find-ChangeSmells $rel $before $now.Text)) { $found.Add((ConvertTo-CheckFinding $rel $i 'smell')) }
                foreach ($i in @(Find-QualityIssues $rel $before $now.Text -UseKit:((Test-UiKitOn $State.AppRoot) -and (Test-UiKitInProject $State.ProjectRoot) -and (Get-UiKitColors $State.AppRoot) -ne 'none') -UserLook:([bool]$State.UserLook))) { $found.Add((ConvertTo-CheckFinding $rel $i 'quality')) }
            }
        } catch { Write-CCBLogError agent "File check $p" $_ }
    }
    # Other findings come as "PATH: message" (or without a path).
    $other = {
        param($text, $source)
        if ("$text" -match '^([^\s:][^:\n]*\.[\w]+):\s*(.+)$') { ConvertTo-CheckFinding $Matches[1] $Matches[2] $source } else { ConvertTo-CheckFinding '' "$text" $source }
    }
    if ("$($State.Config.pageCheck)" -ne 'off') { foreach ($i in @(Test-ScriptSyntax $State $Changed)) { $found.Add((& $other $i 'script')) } }
    # Import index: the changed files again, and what the round broke elsewhere (an import of a moved
    # file, an id, function or hook others still use).
    try { foreach ($i in @(Update-ImportsAfterRound $State.ProjectRoot $Changed)) { $found.Add((& $other $i 'imports')) } } catch { Write-CCBLogError agent 'import index' $_ }
    # Pages that use the UI kit's tokens without loading tokens.css; changes to the kit's own files.
    try { foreach ($i in @(Find-UnlinkedKitTokens $State.ProjectRoot $Changed)) { $found.Add((& $other $i 'quality')) } } catch { Write-CCBLogError agent 'kit tokens check' $_ }
    if (Test-Path -LiteralPath (Get-UiKitCatalogPath $State.ProjectRoot)) {
        foreach ($p in @($Changed | ForEach-Object { "$_".Replace('\', '/') } | Where-Object { $_ -match '(?i)^styles/kit/' -and $_ -notmatch '(?i)^styles/kit/(tokens\.css|kit\.css|kit-icons\.js)$' })) {
            if ($Ev.kitEdits -notcontains $p) { $Ev.kitEdits = @($Ev.kitEdits) + $p }
            $found.Add((ConvertTo-CheckFinding $p 'this is one of the UI kit''s own files: change how the kit looks through styles/kit/tokens.css, your own stylesheet or the component''s options and data attributes instead. Edit a kit file only when there is no other way, and say why in the done summary' 'quality'))
        }
    }
    # A new .env file that .gitignore does not cover would end up in git.
    try { foreach ($i in @(Find-UnignoredEnv $State.ProjectRoot $Changed)) { $found.Add((& $other $i 'env')) } } catch { Write-CCBLogError agent 'env check' $_ }
    # The built-in build (React or TypeScript without npm): its errors and type errors.
    foreach ($i in @(Invoke-ProjectBuild $State @($Changed))) { $found.Add((& $other $i 'tool')) }
    foreach ($i in @($HookIssues | Where-Object { $_ })) { $found.Add((ConvertTo-CheckFinding '' "$i" 'hook')) }
    foreach ($u in @($KitSync.unknown)) { $found.Add((ConvertTo-CheckFinding '' "there is no icon named '$($u.name)'$(if (@($u.like).Count) { "; close names: $(@($u.like) -join ', ')" }) (data-kit-icon takes a Lucide icon name)" 'quality')) }
    $ignoredList = try { (Read-IssueIndex $State.ProjectRoot).ignored } catch { @{} }
    $warnedKeys = $Turn.warnedKeys
    @($found | Where-Object {
        $f = $_
        if ($State.CheckDisputes -and $State.CheckDisputes.Contains($f.key)) { return $false }
        if ($f.path) {
            $lineText = ''
            if ($f.line -gt 0) { try { $lineText = ((Read-TextFile (Resolve-ProjectPath $State.ProjectRoot $f.path)).Text.Replace("`r`n", "`n").Split("`n"))[$f.line - 1] } catch { } }
            if (Test-CheckIgnored $State.ProjectRoot $f.path $f.text $lineText $ignoredList) { return $false }
        }
        if ($f.level -eq 'warning') { if ($warnedKeys.Contains($f.key)) { return $false }; [void]$warnedKeys.Add($f.key) }
        $true
    })
}

function Add-RoundFindings($State, $Turn, $Results, $Keep, $Ev, $Enf, [bool]$IsDone) {
    <# The round's findings: a checks card, what goes to Copilot by enforcement, the code around a new
       error at once (Add-ErrorView), and for an error still there after Copilot's next change the
       evidence and a diagnosis first. Returns whether a "done" in this reply still stands: errors hold
       it up (1, 2 or 3 times by enforcement), under strict also likely mistakes, once. #>
    $syntax = @($Keep | Where-Object level -eq 'error' | ForEach-Object { "$(if ($_.path) { "$($_.path): " })$($_.text)" })
    foreach ($f in @($Keep | Where-Object { $_.level -eq 'error' -and $_.path })) { $k2 = $f.path.ToLowerInvariant(); if (-not $Turn.fixTargets.ContainsKey($k2)) { $Turn.fixTargets[$k2] = [int]$f.line } }
    $Ev.syntaxLast = @($syntax)
    $State.LastFindings = @($Keep | Where-Object { $_.path } | ForEach-Object { @{ path = $_.path; text = $_.text } })   # what an ACTION dispute may point at
    if (-not $Keep.Count) { return $IsDone }
    $null = Write-CCBLog info agent 'File check findings after this round' @{ errors = $syntax.Count; warnings = $Keep.Count - $syntax.Count }
    $null = Add-AgentEvent $State 'checks' @{ text = "File check: $($syntax.Count) problem(s) that break a file, $($Keep.Count - $syntax.Count) likely mistake(s); Copilot is asked to look at them."; findings = @($Keep | Select-Object -First 30 | ForEach-Object { @{ path = $_.path; line = $_.line; text = $_.text; level = $_.level; source = $_.source } }) }
    # Light: only what breaks a file goes to Copilot; the chat card shows the rest.
    $toSend = @(if ($Enf.sendWarnings) { $Keep } else { $Keep | Where-Object level -eq 'error' })
    if ($toSend.Count) { $Results.Add(@{ head = '### File check of the files changed in this reply'; output = (Format-CheckResults $toSend) }) }
    # A new error comes with the code around it at once (the whole block it is in), read for Copilot,
    # so the fix needs no read round first.
    $firstErr = @($Keep | Where-Object { $_.level -eq 'error' -and $_.path -and [int]$_.line -gt 0 -and -not $Turn.errorRounds.ContainsKey($_.key) })
    if ($firstErr.Count) { try { $null = Add-ErrorView $State $Results $firstErr } catch { Write-CCBLogError agent 'error view' $_ } }
    # An error still there after Copilot's next change: once per problem, the evidence it needs (the
    # file now, the bracket map, users) and a diagnosis before another fix.
    $again = New-Object System.Collections.Generic.List[object]
    $Turn.lastErrorKeys = @($Keep | Where-Object { $_.level -eq 'error' -and $_.path } | ForEach-Object { $_.key })
    foreach ($f in @($Keep | Where-Object { $_.level -eq 'error' -and $_.path })) {
        if (-not $Turn.errorFirst.ContainsKey($f.key)) { $Turn.errorFirst[$f.key] = @{ path = $f.path; text = "$(if ($f.line) { "line $($f.line): " })$($f.text)" } }
        $Turn.errorRounds[$f.key] = 1 + [int]$Turn.errorRounds[$f.key]
        if ($Turn.errorRounds[$f.key] -eq 2) { $again.Add($f) }
    }
    foreach ($g in @($again | Group-Object path | Select-Object -First 2)) {
        $iss = @($g.Group | ForEach-Object { @{ line = [int]$_.line; message = $_.text } })
        $evd = try { Get-FixEvidence $State.ProjectRoot $g.Name $iss } catch { Write-CCBLogError agent 'fix evidence' $_; '' }
        $Results.Add(@{ head = "### Still there after your last change: $($g.Name)"; output = "Your last change did not remove $(if ($iss.Count -gt 1) { 'these problems' } else { 'this problem' }), so look for the real cause before changing it again. Start your reply with a line that begins with Cause: and, in 2 to 4 lines, what causes it and why the last change did not remove it; then fix that cause.$(if ($evd) { "`n`n$evd" })" })
    }
    if ($syntax.Count -and $IsDone -and $Turn.syntaxNudges -lt $Enf.errorTries) { $Turn.syntaxNudges++; return $false }
    if ($IsDone -and $Enf.warningsBlock -and $Turn.warnNudges -lt 1 -and @($Keep | Where-Object level -eq 'warning').Count) { $Turn.warnNudges++; return $false }
    $IsDone
}

function Add-DoneAcceptAsk($State, $Turn, $DoneWhen, [string]$Message) {
    <# The Done when checks Copilot set at the start ride with a message that goes back at done anyway,
       once per task ($Turn.acceptAsked; $Turn.acceptAskList is what the next reply answers). #>
    if (-not $DoneWhen.Count -or $Turn.acceptAsked) { return $Message }
    $Turn.acceptAsked = $true
    $st = Get-AcceptanceStep $State $DoneWhen
    $Turn.acceptAskList = @($st.asked)
    if ($st.text) { $Message += "`n`n" + $st.text }
    $Message
}

function Get-DonePageIssues($State, $Turn, $Ev, $Changes) {
    <# Page check: when web files changed, open the changed pages (or index.html) in a browser tab and
       collect JavaScript errors and files that fail to load (a screenshot the first time, or again after
       a page that looked the same); then a syntax check in Edge of changed scripts (also files no page
       loads). Pages with errors are opened again after Copilot's fix ($Turn.pagesToRecheck). #>
    $pageIssues = @()
    $webChanged = @($Changes | Where-Object { ($_.added -or $_.removed) -and $_.path -match '(?i)\.(html?|css|m?js|json)$' })
    if ($webChanged.Count -and "$($State.Config.pageCheck)" -ne 'off' -and $State.PreviewPort -and $State.Mode -ne 'plan') {
        $pages = @($webChanged | Where-Object { -not $_.deleted -and $_.path -match '(?i)\.html?$' } | ForEach-Object { $_.path })
        if (-not $pages.Count -and (Test-Path -LiteralPath (Join-Path $State.ProjectRoot 'index.html'))) { $pages = @('index.html') }
        if ($pages.Count) {
            $null = Add-AgentEvent $State 'status' @{ text = "Checking $($pages -join ', ') in a browser tab for JavaScript errors and files that fail to load..." }
            $wantShot = ((-not $Turn.shotShown) -or $Turn.shotAgain) -and "$($State.Config.pageScreenshot)" -notin 'False', 'off' -and -not $State.ReviewByCaller
            $pageIssues = @(Split-PageWarnings $State @(Test-WebPage $State $pages -Screenshot:$wantShot))
            if ($wantShot) { $State.LastShotPage = "$(@($pages)[0])" }
            $Ev.page = @($pageIssues)
            if ($pageIssues.Count) { $Turn.pagesToRecheck = @($pages) }
            if (-not $pageIssues.Count) { $null = Add-AgentEvent $State 'status' @{ text = "Page check: $($pages -join ', ') loaded without errors." } }
        }
    }
    $jsChanged = @($Changes | Where-Object { ($_.added -or $_.removed) -and -not $_.deleted -and $_.path -match '(?i)\.(m?js|cjs|html?)$' } | ForEach-Object { $_.path })
    if ($jsChanged.Count -and "$($State.Config.pageCheck)" -ne 'off' -and $State.Mode -ne 'plan') {
        $syntax = @(Test-ScriptSyntax $State $jsChanged)
        if ($syntax.Count) { $pageIssues = @($pageIssues) + $syntax }
    }
    $pageIssues
}

function Update-DoneScreenshots($State, $Turn) {
    <# The page check's screenshots go to Copilot once per task, or again after a page that looked
       exactly the same ($Turn.attach, $Turn.shotNote). Before/after: a page that looks exactly the same
       did not get the change (or it is in a view the page does not open with); measured, not Copilot's
       opinion. After a not-applied report that is sent back up to three times ($Turn.sameLimit). #>
    $shots = @($State.PageShots | Where-Object { $_ })
    $afterMap = if ($State.PageShotMap) { $State.PageShotMap.Clone() } else { @{} }
    $State.PageShots = @(); $State.PageShotMap = @{}
    $Turn.shotNote = ''
    if (-not $shots.Count -or ($Turn.shotShown -and -not $Turn.shotAgain)) { return }
    $again = $Turn.shotAgain
    $Turn.shotShown = $true; $Turn.shotAgain = $false
    foreach ($sh in $shots) { $null = Add-AgentEvent $State 'status' @{ text = "Screenshot of the page after the change: $sh (shown to Copilot)."; path = $sh } }
    $Turn.attach = @($shots | Select-Object -First 2 | ForEach-Object { Join-Path $State.ProjectRoot $_.Replace('/', '\') })
    $ba = Get-BeforeAfterNotes $State $afterMap
    foreach ($pg in @($ba.same)) { $null = Add-AgentEvent $State 'status' @{ text = "Before/after check: $pg looks exactly the same as before the change$(if ($again) { ', also after Copilot''s fix' })."; path = "$((@($ba.pairs) | Where-Object { $_.page -eq $pg } | Select-Object -First 1).before)" } }
    if (-not @($ba.notes).Count) { return }
    $note = 'Before/after check by the helper program (pixels, not an opinion): ' + (@($ba.notes) -join '; ') + '.'
    if (@($ba.same).Count) {
        $p0 = @($ba.pairs)[0]
        $Turn.attach = @((Join-Path $State.ProjectRoot $p0.after.Replace('/', '\')), (Join-Path $State.ProjectRoot $p0.before.Replace('/', '\')))
        $note += ' The first image is the page now, the second the page before your changes. If your change should show on this page as it opens, it is not working yet: check that the page loads the changed file, that the selectors match and that nothing overrides the new style, fix it and send done again. If it is in another view, use ACTION screenshot with the steps to get there.'
        if ($Turn.notApplied) { $note = 'The person already said the change did not show, and it still does not. ' + $note }
        if ($Turn.sameNudges -lt $Turn.sameLimit) { $Turn.sameNudges++; $Turn.shotAgain = $true }
        elseif ($Turn.notApplied) {
            $null = Add-AgentEvent $State 'error' @{ text = "After $($Turn.sameNudges) more tries, $(@($ba.same) -join ', ') still looks exactly the same as when you said the change did not take effect. Copilot's done is not a visible change."; code = 'NOT-APPLIED'; hint = 'Check the page yourself; if the change belongs in another view, say which one. Otherwise describe what you see, or try a New chat.' }
        }
    } else {
        $note += ' Check that this is the change that was asked for, and that nothing changed where it should not.'
        $c0 = @($ba.crops)[0]
        if ($c0) {
            $Turn.attach = @(@($Turn.attach | Select-Object -First 1) + @(Join-Path $State.ProjectRoot $c0.path.Replace('/', '\')))
            $note += " The last image shows the changed area$(if ($c0.areas -gt 1) { 's' }) of $($c0.page) close up: before on the left, after on the right."
            $null = Add-AgentEvent $State 'status' @{ text = "Before/after check: the changed area$(if ($c0.areas -gt 1) { 's' }) of $($c0.page) close up: $($c0.path) (shown to Copilot)."; path = $c0.path }
        }
    }
    $Turn.shotNote = $note
}

function Invoke-DoneFirstReview($State, $Turn, $Checkpoint, $Ev, $DoneWhen) {
    <# The first time done gets this far: the page check, the screenshots, and after a big change (or
       page problems) one consistency review by Copilot (dead code, broken references). A task reviewed
       by the calling model (MCP) gets the local check results instead and the turn ends ($Turn.stop). #>
    $changes = @(Get-CheckpointChanges $State.ProjectRoot $Checkpoint)
    $pageIssues = @(Get-DonePageIssues $State $Turn $Ev $changes)
    if ($State.ReviewByCaller) {
        $Turn.reviewed = $true; $Turn.stop = $true
        $paths = @($changes | Where-Object { $_.added -or $_.removed } | ForEach-Object { $_.path })
        if ($paths.Count) {
            $issues = @(@(Test-ProjectConsistency $State.ProjectRoot $paths) + @($pageIssues | ForEach-Object { "page check: $_" }))
            $checkText = if ($issues.Count) { "Local checks found $($issues.Count) problem(s):`n" + (($issues | ForEach-Object { "- $_" }) -join "`n") } else { 'Local checks (JSON, PowerShell syntax, local file references, page load) found no problems.' }
            $null = Add-AgentEvent $State 'status' @{ text = $checkText; checks = @($issues); review = 'caller' }
        }
        return
    }
    $null = Update-DoneScreenshots $State $Turn
    if (-not $pageIssues.Count -and -not (Test-NeedsReview $State $changes)) { return }
    $Turn.reviewed = $true
    $Ev.reviewed = $true
    $issues = @(@(Test-ProjectConsistency $State.ProjectRoot @($changes | ForEach-Object { $_.path })) + @($pageIssues | ForEach-Object { "page check: $_" }))
    $null = Write-CCBLog info agent 'Asking Copilot for a consistency review' @{ files = $changes.Count; issues = $issues.Count }
    $null = Add-AgentEvent $State 'status' @{ text = "Big change: asking Copilot to review $(@($changes).Count) changed file(s) for leftovers, dead code and broken references$(if ($issues.Count) { " ($($issues.Count) problem(s) found by the local checks)" })." }
    $back = New-ReviewMessage $State $changes $issues
    if (@($Turn.attach).Count) { $back += "`n`nAttached: a screenshot of the page as it looks now. Check it against the request too. $(Get-ScreenshotHint $State.LastShotPage)" + $(if ($Turn.shotNote) { "`n`n$($Turn.shotNote)" } else { '' }) }
    Add-DoneAcceptAsk $State $Turn $DoneWhen $back
}

function Invoke-DonePageRecheck($State, $Turn, $Ev, $Enf) {
    <# The page check found errors and Copilot has fixed them since: open the pages again (no
       screenshot) to see that the fix worked; what is left goes back, up to the enforcement's tries.
       Then how the pages are goes into the report and the chat once, so a task never ends as "done"
       with page errors nobody sees. #>
    if (-not @($Turn.pagesToRecheck).Count -or $State.Cancel) { return }
    if ($Turn.pageRechecks -lt [Math]::Max(1, [int]$Enf.errorTries)) {
        $Turn.pageRechecks++
        $null = Add-AgentEvent $State 'status' @{ text = "Checking $($Turn.pagesToRecheck -join ', ') again after the fix..." }
        $again = @(Split-PageWarnings $State @(Test-WebPage $State $Turn.pagesToRecheck) -Quiet)
        $Ev.page = @($again)
        if ($again.Count) { return "The page check still finds problems after your fix:`n" + (($again | Select-Object -First 15 | ForEach-Object { "- $_" }) -join "`n") + "`nFix them, then send done again." }
        $null = Add-AgentEvent $State 'status' @{ text = "Page check after the fix: $($Turn.pagesToRecheck -join ', ') loaded without errors." }
        $Turn.pagesToRecheck = @()
        return
    }
    if ($Turn.pageFinal) { return }
    $Turn.pageFinal = $true
    $final = @(Split-PageWarnings $State @(Test-WebPage $State $Turn.pagesToRecheck) -Quiet)
    $Ev.page = @($final)
    if ($final.Count) {
        $Ev.pageLeft = $true
        $null = Add-AgentEvent $State 'error' @{ text = "Finished with page errors that are still there after $($Turn.pageRechecks) fix attempt(s):`n" + (($final | Select-Object -First 8 | ForEach-Object { "- $_" }) -join "`n"); code = 'PAGE-ERRORS'; hint = 'Copilot said done, but the page check still finds these. Send a message to fix them, or check the page yourself.' }
    }
}

function Invoke-DoneReview($State, $Turn, $Checkpoint, $Ev, $Enf, $DoneWhen) {
    <# The review step of done: the first review once per message, after it the page rechecks; then a
       screenshot still to show goes to Copilot with what to compare. #>
    $back = if (-not $Turn.reviewed) { Invoke-DoneFirstReview $State $Turn $Checkpoint $Ev $DoneWhen } else { Invoke-DonePageRecheck $State $Turn $Ev $Enf }
    if ($back -or $Turn.stop -or -not @($Turn.attach).Count) { return $back }
    $msg = "Attached: a screenshot of the page as it looks now, after your changes. Compare it with what was asked (layout, parts that are missing, overlap or are cut off, colours, text). If something is wrong, fix it, then send done again. If it looks right, send done. $(Get-ScreenshotHint $State.LastShotPage)" + $(if ($Turn.shotNote) { "`n`n$($Turn.shotNote)" } else { '' })
    Add-DoneAcceptAsk $State $Turn $DoneWhen $msg
}

function Invoke-DoneAcceptanceAsk($State, $Turn, $Checkpoint, $DoneWhen) {
    <# The checks Copilot set at the start, asked once at the end when no message above carried them. #>
    if (-not $DoneWhen.Count -or $Turn.acceptAsked -or -not $Checkpoint.Files.Count -or $State.Cancel) { return }
    $Turn.acceptAsked = $true
    $st = Get-AcceptanceStep $State $DoneWhen
    $Turn.acceptAskList = @($st.asked)
    if (-not $st.text) { return }
    $null = Add-AgentEvent $State 'status' @{ text = "Before finishing: $(if (@($st.asked).Count) { "Copilot checks $(@($st.asked).Count) 'Done when' line(s) against the result" } else { 'Copilot fixes the Done when lines StreamHub found not met' })$(if (@($st.helper).Count) { "; StreamHub checked $(@($st.helper).Count) itself in the files" })." }
    "$($st.text)"
}

function Publish-DoneResults($State, $AcceptResults) {
    <# Done went through: the Done when results as a status line, and a Continue card when the
       project's to-do list still has open items or checks are not met: the person decides whether to
       go on, never StreamHub by itself. #>
    if ($AcceptResults) {
        $notMet = @($AcceptResults | Where-Object { $_.met -eq $false })
        $byHelper = @($AcceptResults | Where-Object { $_.by -eq 'helper' }).Count
        $who = if ($byHelper) { "Done when checks ($byHelper checked by StreamHub in the files)" } else { "Copilot's checks" }
        $null = Add-AgentEvent $State 'status' @{ text = $(if ($notMet.Count) { "${who}: $($notMet.Count) of $(@($AcceptResults).Count) not met: " + (@($notMet | ForEach-Object { $_.check }) -join '; ') } else { "${who}: all $(@($AcceptResults).Count) met." }) }
    }
    if ($State.IssueFix -or $State.Mode -eq 'plan' -or $State.ReviewByCaller -or $State.Headless -or $State.Cancel) { return }
    try {
        $openTodo = @(Get-OpenTodoItems $State.ProjectRoot)
        if ($openTodo.Count) {
            $n = (@($openTodo | ForEach-Object { @($_.items).Count }) | Measure-Object -Sum).Sum
            $list = @(foreach ($o in $openTodo) { foreach ($it in (@($o.items) | Select-Object -First 10)) { "$($o.file): $it" } })
            $null = Add-AgentEvent $State 'task-unfinished' @{ text = "Copilot reported the task as done, but the to-do list still has $n open item(s) ($((@($openTodo | ForEach-Object { $_.file })) -join ', ')). Continue to have Copilot do them."; findings = @($list); continueText = (Get-OpenTodoContinue $openTodo) }
        }
    } catch { Write-CCBLogError agent 'open to-do items' $_ }
    if ($AcceptResults) {
        $unmet = @($AcceptResults | Where-Object { $_.met -eq $false })
        if ($unmet.Count) {
            $null = Add-AgentEvent $State 'task-unfinished' @{ text = "Copilot reported the task as done, but $($unmet.Count) of its $(@($AcceptResults).Count) own checks are not met. Continue to have Copilot meet them, or explain why one cannot be met here."; findings = @($unmet | ForEach-Object { "$($_.check)$(if ($_.note) { ": $($_.note)" })" }); continueText = (Get-UnmetChecksContinue $unmet) }
        }
    }
}

function Invoke-AgentTurn {
    # -Shown: the message is in the chat already (sent again by a card's answer), so it is not posted twice.
    param($State, [string]$Text, [string]$ForceKind = '', [switch]$Shown)
    if (-not $State.ProjectRoot) { Add-AgentEvent $State 'error' @{ text = 'Open or create a project first.' }; $State.Busy = $false; return }
    $State.Busy = $true; $State.Cancel = $false
    $State.UserLook = Test-LookRequest $Text   # a look the person asks for wins over the kit's (Prompts)
    $State.VisualTurn = [bool]($State.UserLook -or (Test-LookUnclear $Text))   # only for the waiting indicator's light lines
    $turnWatch = [Diagnostics.Stopwatch]::StartNew()
    $previousLogContext = Get-CCBLogContext
    $turnLogContext = if ($State.CurrentQueueId) { "$($State.CurrentQueueId)" } else { 't-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    Set-CCBLogContext $turnLogContext
    Write-CCBLog info agent "Turn started" @{ chars = $Text.Length; mode = $State.Mode; headless = [bool]$State.Headless; allowCommands = [bool]$State.AllowCommands; workIq = $State.WorkIq; chatStarted = [bool]$State.ChatStarted }
    Write-CCBLog trace agent 'User message' @{ text = $Text }
    if (-not $Shown) { Add-AgentEvent $State 'user' @{ text = $Text } }
    $State.TurnText = $Text
    $State.TaskIntent = Get-TaskIntent $Text $State.Mode "$($State.TaskIntent)"
    $State.PendingGuidance = New-Object 'Collections.Generic.List[string]'
    $State.TaskGuidance = New-Object 'Collections.Generic.List[string]'
    # Busy is already set: a checkpoint that cannot be made must not leave it set.
    try { $checkpoint = New-Checkpoint $State.ProjectRoot $Text } catch { $State.Busy = $false; throw }
    $taskRecord = @{ request = $Text; intent = $State.TaskIntent; mode = $State.Mode; changed = @(); remaining = @(); acceptance = @(); verification = $null; summary = ''; status = 'running' }
    $State.TaskRecord = $taskRecord
    $State.TaskRecordDir = Get-ProjectStateDir $State.ProjectRoot
    $baseline = $null; $kind = ''; $testBase = $null
    try { Sync-SourceVault $State.ProjectRoot } catch { Add-AgentEvent $State 'error' @{ text = "Could not back up source data: $($_.Exception.Message)" } }
    try {
        if (Test-OtherSender) { $State.NeedNewChat = $true }
        Update-ChatScope $State $Text $ForceKind
        if ($State.NeedNewChat) { Start-NewChat $State }
        Add-ChatScopeFiles $State $Text
        # As little as the request needs: plain chat goes as it is; other kinds add only the parts
        # (role, actions, rules, project context) this chat has not had yet.
        $ctx = Get-ProjectContext $State
        if (@($State.ChatFiles).Count) {
            $ctx.TouchedPaths = @($State.ChatFiles)
            $ctx.TouchedTraits = @(Get-ProjectTraits $ctx.TouchedPaths)
        }
        $kind = Get-TurnKind $State $Text $ctx $ForceKind
        # Issue cycle step 1: index before the change (not for plain chat or plan mode).
        if ($kind -ne 'chat' -and $State.Mode -ne 'plan') { $baseline = Get-IssueBaseline $State }
        if ($kind -ne 'chat' -and $State.ProjectRoot) {
            # Data files the person added since: converted before Copilot sees the project.
            if (Sync-DataImports $State) { $ctx = Get-ProjectContext $State }
            $State.Activity.kind = 'index'; $State.Activity.label = 'Updating the import index'
            try { $null = Update-ImportIndex $State.ProjectRoot } catch { Write-CCBLogError agent 'import index' $_ } finally { $State.Activity.label = '' }
        }
        # The tests as they are before this task changes anything (TestRunner), so failures that were
        # already there are not sent back to Copilot as its own.
        if ($kind -in 'coding', 'mixed' -and $State.Mode -ne 'plan' -and -not $State.ReviewByCaller) {
            $testBase = try { Get-TurnTestBaseline $State } catch { Write-CCBLogError agent 'tests before the change' $_; $null }
        }
        # The app shows how a message was sent, with "Send again as a coding task" for plain chat.
        Add-AgentEvent $State 'kind' @{ taskKind = $kind }
        $summary = $State.Summary; $State.Summary = $null
        $partsBefore = $State.SentParts.Count
        # A report that a page shows markup or script as text: the helper program checks the pages
        # itself first, fixes what has one right answer, and names the lines for Copilot.
        $sendText = $Text
        if ($State.TaskIntent -eq 'change' -and $kind -ne 'chat' -and (Test-LeakReport $Text)) {
            $rep = try { Get-LeakReport $State } catch { Write-CCBLogError agent 'leak report' $_; '' }
            if ($rep) { $sendText = "$Text`n`n$rep" }
        }
        $message = New-PromptMessage -AppRoot $State.AppRoot -Kind $kind -Text $sendText -Sent $State.SentParts -Context $ctx -Summary $summary
        foreach ($notes in @((Get-ProjectNotes $State.ProjectRoot), (Get-SharedNotes $State.ProjectRoot))) {
            if ("$notes".Trim()) { $State.PendingGuidance.Add($notes); $State.TaskGuidance.Add($notes) }
        }
        # The UI kit rules go out: the kit must be in the project (added once, never overwritten).
        if ($State.TaskIntent -eq 'change' -and $State.ProjectRoot -and $State.SentParts.Contains('rules:uikit')) {
            try {
                # A catalogue from an older kit revision first, so the rules and the kit files match.
                $kitNewer = @(Update-UiKitCatalog $State.ProjectRoot $State.AppRoot)
                if ($kitNewer.Count) { Add-OwnChangeEvent $State 'write' "$(Get-UiKitFolder)/ (UI kit)" "StreamHub updated the project's UI kit to its newer version: the catalogue in $(Get-UiKitCatalog $State.ProjectRoot)/ and the kit files the pages use that the project had not changed ($($kitNewer -join ', ')). Kit files the project changed stay as they are." -Output ($kitNewer -join "`n") }
                $kitAdded = @(Install-UiKit $State.ProjectRoot $State.AppRoot)
                if ($kitAdded.Count) { Add-OwnChangeEvent $State 'write' "$(Get-UiKitFolder)/ (UI kit)" "StreamHub added its UI kit to the project: the whole kit as a catalogue in $(Get-UiKitCatalog $State.ProjectRoot)/, and in $(Get-UiKitFolder)/ only what the pages use ($($kitAdded -join ', ')); a kit class, script or React part a page uses is added after each change. Settings > UI kit turns this off." -Output ($kitAdded -join "`n") }
            } catch { Write-CCBLogError agent 'UI kit' $_ }
        }
        if ($State.SentParts.Count -gt $partsBefore -and $State.SentParts.Contains('actions')) { $State.FollowUps = 0 }
        if ($kind -ne 'chat') { $State.ChatKind = $kind }
        Write-CCBLog info agent "Task kind: $kind" @{ partsAdded = $State.SentParts.Count - $partsBefore; chars = $message.Length }
        $State.LastTurnActed = $null
        $message += Get-PinnedFiles $State.ProjectRoot $Text
        # The AGENTS.md of the folders of files the request names (the root one is in the project context).
        if ($kind -ne 'chat' -and $State.ProjectRoot) {
            if ($null -eq $State.FolderNotesSent) { $State.FolderNotesSent = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
            $fnText = try { Get-FolderNotes $State.ProjectRoot @(Get-NamedFiles $Text @(Get-ProjectFiles $State.ProjectRoot | ForEach-Object { $_.path })) $State.FolderNotesSent } catch { Write-CCBLogError agent 'folder notes' $_; '' }
            if ($fnText) { $message += "`n`n$fnText"; $State.PendingGuidance.Add($fnText); $State.TaskGuidance.Add($fnText) }
        }
        # What Copilot writes down for the helper program (TaskNotes): the checks this task must pass,
        # and notes on data files that have none yet (or whose data changed). Asked with this message,
        # read from the replies; no extra message.
        $doneWhen = @(); $acceptResults = $null
        $copilotAnswers = @()   # Copilot's answers to the checks it was asked about ($turn.acceptAskList)
        $State.LastTurnPlan = $null   # the steps and checks of this turn, for PLAN.md (Write-TurnPlan)
        $askChecks = ($kind -in 'coding', 'mixed', 'project') -and -not $State.IssueFix -and $State.Mode -ne 'plan' -and -not $State.ReviewByCaller -and (Test-BuildRequest $Text) -and $Text -notmatch '^\s*Continue and make the change now'
        if ($askChecks) { $message += "`n`n" + (Get-DoneWhenAsk) }
        $notesOnlyGo = $false   # a reply with only the notes asked for (no actions) got its short go-ahead
        # Tie-breakers: what the fixed rules cannot tell from the words, Copilot settles in its first reply.
        $scopeAsk = if ($State.ScopeAsk -and $kind -in 'coding', 'mixed', 'project' -and $State.Mode -ne 'plan') { "$($State.ScopeAsk)" } else { '' }
        if ($scopeAsk) { $message += "`n`n" + (Get-ScopeAsk $scopeAsk) }
        $typeAsk = ($kind -in 'coding', 'mixed', 'project') -and -not $State.IssueFix -and (Test-LookUnclear $Text) -and (Test-UiKitOn $State.AppRoot) -and (Test-UiKitInProject $State.ProjectRoot)
        if ($typeAsk) { $message += "`n`n" + (Get-RequestTypeAsk) }
        $notesFor = @()
        if ($kind -ne 'chat' -and $State.ProjectRoot -and -not $State.IssueFix -and (Test-DataImportOn $State.AppRoot)) {
            $dataMan = try { Read-DataImportManifest $State.ProjectRoot } catch { @{} }
            $notesFor = @(try { Get-DataNotesNeeded $State.ProjectRoot $dataMan } catch { Write-CCBLogError agent 'data notes' $_ })
            if ($notesFor.Count) { $message += "`n`n" + (Get-DataNotesAsk $notesFor) }
        }

        $nudges = 0   # times this message was sent again because Copilot explained instead of acting
        $userFirstSent = $false   # the request sent back once because Copilot kept an earlier choice the person asked to change
        $failSeen = @{}; $stopLoop = $false   # the same step failing the same way: warn at 2, stop at 3
        $turnSeq = [int]$State.Seq   # for the fix case log of errors that needed more than one change
        # The counters and flags the done-step gates (Invoke-Done*) update: times "done" was refused
        # because the project's verify command or tests failed, a build or check tool found errors
        # (ToolChecks), a window app did not open (GuiTest), a beforeDone hook failed, the plan's files
        # were missing (at most twice) or no file changed after a not-applied report (at most three
        # times); whether the one reminder (tests, README) was sent and new files nothing loads were
        # looked for (once each); and the test run before the change.
        # The review step (Invoke-DoneReview): the consistency review happens once per message
        # (reviewed); pages with errors are checked again after the fix (pagesToRecheck, pageRechecks)
        # and once more when the tries are used up (pageFinal); a task the calling model reviews ends
        # there (stop). Screenshots: one of a changed page goes to Copilot once per task (shotShown),
        # again after a page that looked exactly the same (shotAgain, sameNudges up to sameLimit), with
        # the before/after note (shotNote); attach holds the files for the next message. The Done when
        # checks are asked once (acceptAsked) and the next reply answers acceptAskList.
        $turn = @{ verifyNudges = 0; toolNudges = 0; guiNudges = 0; hookNudges = 0; coverageNudges = 0; notAppliedNudges = 0
            doneReminded = $false; unloadedChecked = $false; notApplied = $false; testBase = $testBase
            reviewed = $false; stop = $false; pagesToRecheck = @(); pageRechecks = 0; pageFinal = $false
            shotShown = $false; shotAgain = $false; sameNudges = 0; sameLimit = 1; shotNote = ''; attach = @()
            acceptAsked = $false; acceptAskList = @()
            # The round's file check (Get-RoundFindings, Add-RoundFindings): file-check errors per key
            # (still there a round later = evidence and a diagnosis first) and the first text of each,
            # for the fix case log; the error keys of the last check; times "done" was refused because
            # a changed file has an error, or (strict) a likely mistake; likely mistakes are said once
            # per task. Files Copilot is fixing (path -> line of the problem) and the rollbacks of
            # changes that made one worse (Invoke-RoundRollbacks).
            errorRounds = @{}; errorFirst = @{}; lastErrorKeys = @(); syntaxNudges = 0; warnNudges = 0
            warnedKeys = (New-Object System.Collections.Generic.HashSet[string]); fixTargets = @{}; rollbacks = @{} }
        $fileAttach = @()
        $State.BeforeShots = @{}; $State.ReadRanges = @{}   # before/after comparison (Save-BeforeShot)
        # The person says the last change did not take effect (Prompts Test-NotAppliedReport, after an
        # earlier done in this chat): Copilot starts from the page as it is now, finds the cause first,
        # and done is earned, not claimed: refused while no file changed, and the before/after check
        # sends it back up to three times while the page looks exactly the same.
        $askKind0 = if ($kind -eq 'chat' -and $State.ChatKind) { $State.ChatKind } else { $kind }
        $lastDone = Get-LastDoneText $State
        $notApplied = $askKind0 -in 'coding', 'mixed', 'project' -and $State.Mode -ne 'plan' -and -not $State.IssueFix -and $null -ne $lastDone -and (Test-NotAppliedReport $Text)
        $turn.notApplied = [bool]$notApplied; $turn.sameLimit = $(if ($notApplied) { 3 } else { 1 })
        if ($notApplied) {
            $hasShot = $false
            $shotPage = if ($State.LastShotPage) { "$($State.LastShotPage)" } elseif (Test-Path -LiteralPath (Join-Path $State.ProjectRoot 'index.html')) { 'index.html' } else { '' }
            if ($shotPage) {
                try { Save-BeforeShot $State $shotPage } catch { Write-CCBLogError agent 'screenshot at a not-applied report' $_ }
                $b = "$($State.BeforeShots[$shotPage])"
                if ($b) { $turn.attach = @(Join-Path $State.ProjectRoot $b.Replace('/', '\')); $hasShot = $true }
            }
            $message += "`n`n" + (Get-NotAppliedBrief $lastDone $hasShot)
            Write-CCBLog info agent 'The person says the last change did not take effect; cause first, done only with a visible change' @{ screenshot = $hasShot }
            Add-AgentEvent $State 'status' @{ text = "You said the change did not take effect: Copilot first finds out why$(if ($hasShot) { ', starting from the page as it looks now' }). Done is accepted only when files changed and the page looks different." }
        }
        $enf = Get-Enforcement "$($State.Config.enforcement)"   # setting enforcement: light, standard, strict
        if ($State.IssueFix -and $State.IssueFix.path) { $turn.fixTargets["$($State.IssueFix.path)".Replace('\', '/').ToLowerInvariant()] = 0 }
        $State.CheckDisputes = New-Object System.Collections.Generic.HashSet[string]   # findings Copilot disputed in this task
        $doneFinished = $false   # Copilot reported done and the done step's checks ran (else Invoke-FinalChecks)
        $endReason = 'it ended without reporting the task as done'
        if ($null -ne $State.HookTrace) { $State.HookTrace.Clear() }
        $ev = @{ syntaxLast = $null; page = $null; reviewed = $false; verify = $null; kitEdits = @(); unloaded = @(); pageLeft = $false; unfinished = $null; final = $null; hooks = @() }   # for the evidence file
        $msgStart = [int]$State.MessagesSent
        $lastReply = ''; $doneText = ''   # for the suggested next steps after the turn
        # Rounds: the budget (setting maxRounds) is against loops, not against work. A message whose
        # rounds keep changing files goes on past it, up to three times the budget, and stops as soon
        # as two rounds in a row change nothing (Test-RoundsLeft).
        $round = 0; $lastProgress = 0; $extended = $false
        $observations = New-Object 'Collections.Generic.HashSet[string]'
        $exploreRounds = 0; $missingReads = New-Object System.Collections.Generic.List[string]   # rounds that only looked around, and the files they looked for
        $loopWatch = New-LoopWatch   # a change undone again, rounds alternating between the same steps (LoopGuard)
        while ($true) {
            $round++
            Set-WorkRound $State $round
            if ($State.Cancel) { Add-AgentEvent $State 'status' @{ text = 'Stopped.' }; break }
            $rolled = [bool](Invoke-RolloverIfNeeded $State @{ changed = @($checkpoint.Files.Keys); doneWhen = @($doneWhen); acceptance = @($acceptResults) })
            if (-not $State.ChatStarted -and ($round -gt 1 -or $rolled)) {
                # A rollover started a fresh chat (also before the first send of this turn, when the
                # previous turn filled the chat): give it the parts again, with the summary.
                $prefix = New-PromptMessage -AppRoot $State.AppRoot -Kind $(if ($State.ChatKind) { $State.ChatKind } else { 'chat' }) -Text '' -Sent $State.SentParts -Context (Get-ProjectContext $State) -Summary $State.Summary
                $State.Summary = $null
                if ($prefix) { $message = "$prefix`n`n$message" }
            }
            $intentText = if ($State.TaskIntent -eq 'change') { 'Task intent: change. Complete the requested changes and verify them; useful investigation and tests are progress too.' } else { "Task intent: $($State.TaskIntent). Read, investigate and answer the request. Do not change project files. An answer or findings can finish the task without edits." }
            $required = @($intentText) + @($State.PendingGuidance.ToArray())
            # The user's request is a hard requirement on every turn. Optional context may be
            # shortened, but the actual task must remain available after a rollover or long loop.
            $required += @($Text)
            if ($round -eq 1 -or $rolled) {
                $required += @($State.TaskGuidance.ToArray())
                if ($kind -in 'coding', 'project', 'mixed') { $required += @((Get-PromptPart $State.AppRoot 'actions'), (Get-PromptPart $State.AppRoot 'rules'), (Get-PromptPart $State.AppRoot 'rules:environment')) }
                if ($State.Mode -eq 'plan') { $required += 'Mode: plan only. Do not change files or run commands.' }
            }
            $unbudgeted = $message
            $message = Format-TaskMessage $message $required ([int]$State.Config.promptCharBudget)
            # An optional module shortened out of this message was not delivered in full.
            foreach ($partId in @($State.SentParts)) {
                if ($partId -notmatch '^(rules|actions):') { continue }
                $partText = Get-PromptPart $State.AppRoot $partId $ctx
                if ($partText -and $unbudgeted.Contains($partText) -and -not $message.Contains($partText)) { [void]$State.SentParts.Remove($partId) }
            }
            $taskRecord.guidance = @($State.TaskGuidance.ToArray())
            $taskRecord.changed = @($checkpoint.Files.Keys); $taskRecord.remaining = @($State.Todos)
            $taskRecord.acceptance = @($acceptResults); $taskRecord.verification = $ev
            $null = Save-TaskRecord $State.TaskRecordDir $taskRecord

            Write-CCBLog verbose agent "Round ${round}: sending" @{ chars = $message.Length }
            $r = Send-ToCopilot $State $message -Files @(@($turn.attach) + @($fileAttach)) -OptionalFiles
            $State.PendingGuidance.Clear()
            if (@($turn.attach).Count -or $fileAttach.Count) {
                foreach ($why in @((Get-Bridge $State).AttachErrors)) { Add-AgentEvent $State 'status' @{ text = "A file was not shown to Copilot: $why" } }
            }
            $turn.attach = @(); $fileAttach = @()
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
            $notesOnly = $false   # this reply answered one of the helper program's asks (checks, type, scope, data notes, build form)
            if ($typeAsk) {
                $rt = Read-RequestType "$($r.Text)"
                if ($rt) {
                    $typeAsk = $false; $notesOnly = $true
                    $State.UserLook = $rt -in 'look', 'both'
                    Add-AgentEvent $State 'status' @{ text = "Copilot read this request as $(switch ($rt) { 'look' { 'a new look' } 'feature' { 'new or changed functionality' } default { 'both a new look and new functionality' } }): the kit's look checks $(if ($State.UserLook) { 'rest for the parts it restyles' } else { 'apply as usual' })." }
                    Write-CCBLog info agent 'Request type from Copilot' @{ type = $rt }
                }
            }
            if ($scopeAsk) {
                $sd = Read-ScopeDecision "$($r.Text)"
                if ($sd) { Write-CCBLog info agent 'Scope from Copilot' @{ scope = $sd } }
                if ($sd -eq 'plan' -and -not @($actions | Where-Object { $_.type -in 'write', 'edit', 'run' }).Count) {
                    $State.ScopeUpgrade = $scopeAsk
                    Add-AgentEvent $State 'status' @{ text = "Copilot judged this request too big to build in one go, so it $(if ($scopeAsk -eq 'clarify') { 'asks its questions first' } else { 'plans first' }), as chosen for this project." }
                    break
                }
                if ($sd) { $notesOnly = $true }
                $scopeAsk = ''
            }
            # Copilot's checks for this task ("Done when:"), and its notes on the data ("Data notes:").
            if ($askChecks -and -not $doneWhen.Count) {
                $doneWhen = @(Read-DoneWhen "$($r.Text)")
                if ($doneWhen.Count) { $notesOnly = $true; Add-AgentEvent $State 'status' @{ text = "Copilot's checks for this task (asked about at the end): " + ($doneWhen -join '; ') } }
            }
            if ($turn.acceptAsked -and @($turn.acceptAskList).Count) {
                $ans = @(Read-AcceptanceAnswers "$($r.Text)" @($turn.acceptAskList))
                if (@($ans | Where-Object { $null -ne $_.met }).Count) {
                    $copilotAnswers = $ans
                    $acceptResults = @(Merge-AcceptanceResults $State.ProjectRoot $doneWhen $ans); $ev.acceptance = $acceptResults
                }
            }
            if ($notesFor.Count) {
                $dnLines = @(Read-NoteBlock "$($r.Text)" 'Data notes' 12)
                if ($dnLines.Count) {
                    $notesOnly = $true
                    try { Save-DataNotes $State.ProjectRoot $dataMan $notesFor $dnLines; Add-AgentEvent $State 'status' @{ text = "Copilot's notes on the data saved for later tasks (.streamhub/data-notes.json): $($notesFor -join ', ')." } } catch { Write-CCBLogError agent 'data notes' $_ }
                    $notesFor = @()
                }
            }
            # The user left the build form to Copilot: the form it states is kept for the project.
            if ($State.ProjectRoot -and "$($r.Text)" -match '(?i)build form') {
                try {
                    $pick = Read-BuildDecision "$($r.Text)"
                    if ($pick -and (Get-ProjectSetup $State.ProjectRoot).build -eq 'copilot') {
                        $null = Save-ProjectSetup $State.ProjectRoot @{ build = $pick; chosenBy = 'copilot' }
                        Add-AgentEvent $State 'status' @{ text = "Copilot chose $(if ($pick -eq 'single') { 'one HTML file' } else { 'separate files' }) for this project; StreamHub keeps it for the next tasks (Files > Project setup)." }
                        Write-CCBLog info setup 'Build form chosen by Copilot' @{ build = $pick }
                    }
                } catch { Write-CCBLogError agent 'build decision' $_ }
            }
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
            if (-not $actions.Count -and $notesOnly -and -not $notesOnlyGo -and $State.Mode -ne 'plan' -and -not $State.ScopeUpgrade) {
                # The reply held only what the helper program asked for first (the checks, the request
                # type, data notes): a short go-ahead, not the whole task again as for a reply that
                # explained instead of acting.
                $notesOnlyGo = $true
                Write-CCBLog info agent 'Reply held only the notes asked for; asking Copilot to carry out the task'
                $message = (Get-NotesGoAhead)
                continue
            }
            # The person asked to change something and Copilot defends what is there ("intentional",
            # "by design", "not a bug") without changing anything: the person's request comes first,
            # over earlier choices of Copilot or the helper program. Sent back once per message.
            $askKind = if ($kind -eq 'chat' -and $State.ChatKind) { $State.ChatKind } else { $kind }
            if (-not $userFirstSent -and $lastProgress -eq 0 -and $askKind -in 'coding', 'mixed', 'project' -and $State.Mode -ne 'plan' -and -not $State.IssueFix -and
                -not @($actions | Where-Object { $_.type -in 'write', 'edit', 'run' }).Count -and (Test-ChangeAsk $Text) -and (Test-DefendedChoice $r.Text)) {
                $userFirstSent = $true
                Write-CCBLog info agent 'Copilot kept an earlier choice the person asked to change; sending the request back, the person first'
                Add-AgentEvent $State 'status' @{ text = 'Copilot kept its earlier choice instead of making the change you asked for. StreamHub sent your request back: what you ask comes first.' }
                $message = Get-UserFirstMessage
                continue
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
            $isDone = $false; $stepFailed = $false   # a write, edit or run step of this reply failed: done is not accepted
            # A change that is meant to fix a reported problem: the file as it was, to roll back to
            # when the change makes it worse.
            $roundSnap = @{}
            # Discover instructions for the whole proposed mutation batch before any action runs.
            # Do not replay the stale proposal: Copilot must reconsider it with these instructions.
            $destinations = @($actions | Where-Object { $_.type -in 'write', 'edit' } | ForEach-Object { "$($_.arg)" -replace ':\d+-\d+$', '' })
            # Read destination-folder guidance with a temporary sent set. A folder discovered in a
            # previous round is already known and must not cause the same proposal to be deferred forever.
            $newNotes = if ($destinations.Count) { Get-FolderNotes $State.ProjectRoot $destinations $null } else { '' }
            $knownNotes = $newNotes -and @($State.TaskGuidance | Where-Object { "$newNotes" -eq "$_" }).Count
            if ($newNotes -and -not $knownNotes) {
                $State.PendingGuidance.Add($newNotes); $State.TaskGuidance.Add($newNotes)
                $message = "No actions in this reply were executed. Read the newly discovered folder instructions below, reconsider your proposed actions, then send the appropriate actions again.`n`n$newNotes"
                Add-AgentEvent $State 'status' @{ text = 'New folder instructions found; Copilot must read them before the proposed changes run.' }
                if ($round -ge [Math]::Min(60, [Math]::Max(1, [int]$State.Config.maxRounds) * 3)) { break }
                continue
            }
            foreach ($a in $actions) {
                if ($a.type -notin 'write', 'edit' -or -not $a.arg) { continue }
                $rp = "$($a.arg)".Trim().Replace('\', '/')
                if (-not $turn.fixTargets.ContainsKey($rp.ToLowerInvariant()) -or $roundSnap.ContainsKey($rp)) { continue }
                try { $roundSnap[$rp] = (Read-TextFile (Resolve-ProjectPath $State.ProjectRoot $rp)).Text } catch { }
            }
            for ($k = 0; $k -lt $actions.Count; $k++) {
                if ($State.Cancel) { break }
                $a = $actions[$k]
                if ($a.type -eq 'done') {
                    # Done next to a step that failed in the same reply is not done: the failure goes back.
                    if ($stepFailed) { $results.Add(@{ head = '### done'; output = 'not accepted: a write, edit or run step in this reply failed (see above), so the task is not finished. Fix that step first, then send done in a reply of its own.' }); continue }
                    $isDone = $true; $doneText = $a.body.Trim(); continue   # the done card comes after the steps, when none failed
                }
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
                if ($res.attach) { $fileAttach = @(@($fileAttach) + @($res.attach) | Select-Object -Unique | Select-Object -First 5) }
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
                    $stepFailed = $true
                    if ($isDone) {
                        # Done came earlier in this reply: taken back, the failure goes to Copilot.
                        $isDone = $false
                        $results.Add(@{ head = '### done'; output = 'not accepted: a step in this reply failed (see below), so the task is not finished. Fix that step first, then send done in a reply of its own.' })
                    }
                    $times = Register-StepFailure $failSeen $a $out
                    if ($times -eq 2) {
                        $out += "`nThis is the second time this exact step failed in the same way. Do not send it again unchanged: read the lines it is about first and send a corrected step$(if ($a.type -eq 'edit') { ', or replace the whole file with a write block' })."
                        # A small file: the whole current text goes along, so one write block ends it.
                        if ($a.type -eq 'edit') { $whole = try { Get-WholeFileFallback $State.ProjectRoot $a.arg } catch { '' }; if ($whole) { $out += "`n$whole" } }
                    } elseif ($times -ge 3) {
                        $stopLoop = $true
                        Add-AgentEvent $State 'error' @{ text = "The same $($a.type) of $($a.arg) failed $times times in a row with: $(("$($res.output)" -split "`n")[0] -replace '^error:\s*', ''). Stopped this message so it does not loop."; code = 'STEP-LOOP'; hint = 'Ask Copilot to rewrite the whole file with a write block, or make this change by hand; then continue.' }
                    }
                }
                $results.Add(@{ head = "### $($k + 1). $($a.type) $($a.arg)".TrimEnd(); output = $out; observation = $res.output; ok = $res.ok; action = $a; readPaths = $res.readPaths; changedPath = $(if ($res.ok -and $res.changed) { $res.path } else { $null }) })
                if ($stopLoop) { break }
            }
            # File checks of what this round changed (per type: syntax, unclosed brackets, tags and
            # strings, duplicate keys or code, missing local files...), so a broken file is fixed in
            # the next round, before more edits build on it. Only problems the task added count.
            if ($isDone) { Add-AgentEvent $State 'done' @{ text = $doneText } }
            $roundChanged = @($results | ForEach-Object { $_.changedPath } | Where-Object { $_ } | Select-Object -Unique)
            # Fresh investigation is useful evidence, but it does not turn an exploratory answer
            # into an unbounded build. Only non-exploratory evidence or a real change extends rounds.
            if ((-not (Test-ExploreRound $actions $results)) -and (Test-RoundProgress $actions $results.ToArray() $observations)) { $lastProgress = $round }
            # Rounds that only look around (reads, searches, listings): after three of them in a row
            # Copilot is told the file list is complete and asked to write (Get-ExploreNudge).
            if (Test-ExploreRound $actions $results) {
                $exploreRounds++
                foreach ($res in $results) { foreach ($mm in [regex]::Matches("$($res.output)", '(?m)^### (\S+)\s*\n\(file not found')) { [void]$missingReads.Add($mm.Groups[1].Value) } }
                $nudge = Get-ExploreNudge $exploreRounds @($missingReads) (-not (Test-OwnCode @(Get-ProjectFiles $State.ProjectRoot | ForEach-Object { $_.path })))
                if ($nudge) { $results.Add(@{ head = '### Investigation progress'; output = $nudge }); Add-AgentEvent $State 'status' @{ text = "Round ${round}: checking whether further investigation will resolve a specific uncertainty." } }
            } else { $exploreRounds = 0 }
            # Going in circles: a file back to a version it had earlier in this task, or rounds that
            # alternate between the same two sets of steps. Said once, the second time stops the message.
            if (-not $stopLoop -and -not $isDone) {
                $flipped = @(foreach ($p in $roundChanged) {
                    $st = if ($State.ReadStamps) { $State.ReadStamps["$p".Replace('\', '/').TrimStart('/').ToLowerInvariant()] } else { $null }
                    if ($st -and $st.read) { $null = Add-LoopFileVersion $loopWatch $p $st.read -Seed }
                    $fullP = try { Resolve-ProjectPath $State.ProjectRoot $p } catch { $null }
                    if ($fullP -and (Test-Path -LiteralPath $fullP -PathType Leaf) -and (Add-LoopFileVersion $loopWatch $p (Get-FileFingerprint $fullP))) { $p }
                })
                $alternating = Add-LoopRound $loopWatch (Get-RoundKey $actions)
                if ($flipped.Count -or $alternating) {
                    $loopWatch.flips++
                    $what = if ($flipped.Count) { "$($flipped -join ', ') went back to an earlier version" } else { 'the rounds alternate between the same steps' }
                    Write-CCBLog info agent "Going in circles: $what" @{ round = $round; times = $loopWatch.flips }
                    if ($loopWatch.flips -ge 2) {
                        $stopLoop = $true
                        Add-AgentEvent $State 'error' @{ text = "Copilot is going in circles ($what, for the second time in this task). Stopped this message so it does not loop."; code = 'CIRCLE-LOOP'; hint = 'Say which version is right, or describe the change more precisely, and continue.' }
                    } else {
                        $results.Add(@{ head = '### Going in circles'; output = (Get-LoopNote $(if ($flipped.Count) { 'flip' } else { 'alternate' }) $flipped) })
                        Add-AgentEvent $State 'status' @{ text = "Round ${round}: $what; StreamHub asked Copilot to decide instead of switching back and forth." }
                    }
                }
            }
            # Files read or changed in a folder with its own AGENTS.md: its notes, once per chat.
            if ($State.ProjectRoot) {
                if ($null -eq $State.FolderNotesSent) { $State.FolderNotesSent = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
                $touched = @($results | ForEach-Object { @($_.readPaths) + @($_.changedPath) } | Where-Object { $_ } | ForEach-Object { "$_" -replace ':\d+-\d+$', '' })
                $fnText = if ($touched.Count) { try { Get-FolderNotes $State.ProjectRoot $touched $State.FolderNotesSent } catch { Write-CCBLogError agent 'folder notes' $_; '' } } else { '' }
                if ($fnText) { $results.Add(@{ head = '### Folder notes'; output = $fnText }); $State.PendingGuidance.Add($fnText); $State.TaskGuidance.Add($fnText) }
            }
            if ($null -ne $State.ChatFiles) { foreach ($f in @($results | ForEach-Object { @($_.readPaths) + @($_.changedPath) } | Where-Object { $_ })) { [void]$State.ChatFiles.Add("$f".Replace('\', '/')) } }
            if ($roundChanged.Count -and -not $State.Cancel -and -not $stopLoop) {
                # The project's afterEdit hooks first (a formatter changes the files), so the checks
                # below see the files as they stay; a failing hook goes back like a file check.
                $hookIssues = @(try { Invoke-ProjectHooks $State 'afterEdit' $roundChanged } catch { Write-CCBLogError agent 'hooks' $_ })
                $autoFixed = @(Invoke-RoundAutoFix $State $roundChanged $enf)
                Invoke-RoundRollbacks $State $turn $results $roundSnap
                if ($autoFixed.Count -and $enf.autoFix -eq 'tell') {
                    $results.Add(@{ head = '### Fixed by the helper program'; output = "These mechanical problems in your last changes were fixed for you; write them this way from now on:`n" + (($autoFixed | ForEach-Object { "- $_" }) -join "`n") })
                }
                $kitSync = Update-RoundKitFiles $State $results $roundChanged
                $keep = @(Get-RoundFindings $State $turn $checkpoint $ev $roundChanged $hookIssues $kitSync)
                $isDone = Add-RoundFindings $State $turn $results $keep $ev $enf $isDone
            }
            if ($State.Cancel) { Add-AgentEvent $State 'status' @{ text = 'Stopped. Changes made so far in this message can be undone.' }; break }
            if ($stopLoop) { break }
            if ($isDone) {
                # The gates in order (Invoke-Done*): each returns the message that sends Copilot back.
                $back = Invoke-DoneNotApplied $State $turn $checkpoint
                if ($back) { $message = $back; continue }
                $back = Invoke-DoneReminders $State $turn $checkpoint
                if ($back) { $message = $back; continue }
                $back = Invoke-DonePlanCoverage $State $turn $checkpoint $ev
                if ($back) { $message = $back; continue }
                $back = Invoke-DoneUnloadedCheck $State $turn $checkpoint $ev
                if ($back) { $message = $back; continue }
                $back = Invoke-DoneVerify $State $turn $checkpoint $ev $enf
                if ($back) { $message = $back; continue }
                $back = Invoke-DoneToolChecks $State $turn $checkpoint $enf
                if ($back) { $message = $back; continue }
                $back = Invoke-DoneGuiTest $State $turn $checkpoint $enf
                if ($back) { $message = $back; continue }
                $back = Invoke-DoneHooks $State $turn $checkpoint $enf
                if ($back) { $message = $back; continue }
                # The review step: the page check and screenshots, one consistency review after a big change
                # (or a task the calling model reviews: the local check results, and the turn ends), then the
                # page rechecks; a screenshot still to show goes to Copilot.
                $back = Invoke-DoneReview $State $turn $checkpoint $ev $enf $doneWhen
                if ($turn.stop) { break }
                if ($back) { $message = $back; continue }
                $back = Invoke-DoneAcceptanceAsk $State $turn $checkpoint $doneWhen
                if ($back) { $message = $back; continue }
                # The checks StreamHub can make in the files are made again now (a fix after the question
                # counts); the others keep Copilot's answer.
                if ($doneWhen.Count -and $turn.acceptAsked) {
                    $merged = @(Merge-AcceptanceResults $State.ProjectRoot $doneWhen $copilotAnswers)
                    if (@($merged | Where-Object { $null -ne $_.met }).Count) { $acceptResults = $merged; $ev.acceptance = $merged }
                }
                $doneFinished = $true
                Publish-DoneResults $State $acceptResults
                # A review of the change in a fresh chat (setting freshReview): the chat that made the
                # change does not grade it.
                if ("$($State.Config.freshReview)" -in 'True', 'on' -and $checkpoint.Files.Count -and -not $State.IssueFix -and $State.Mode -ne 'plan' -and -not $State.ReviewByCaller -and -not $State.Headless -and -not $State.Cancel) {
                    try { Invoke-FreshReview $State $checkpoint @($doneWhen) $ev } catch { Write-CCBLogError agent 'fresh review' $_; Add-AgentEvent $State 'status' @{ text = "The review in a fresh chat did not finish: $($_.Exception.Message)" } }
                }
                break
            }
            $left = Test-RoundsLeft ([int]$State.Config.maxRounds) $round $lastProgress
            if ($left.extend -and -not $extended) { $extended = $true; Add-AgentEvent $State 'status' @{ text = "Past $($State.Config.maxRounds) rounds, but the last round still changed files or gathered new evidence: continuing while progress continues (up to $($left.hard) rounds)." } }
            if (-not $left.go) { $endReason = $left.reason; Add-AgentEvent $State 'status' @{ text = "Stopped after $round rounds: $($left.reason). Send a message to continue." }; break }

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
        Set-CCBLogContext $previousLogContext
        $taskRecord.status = if ($State.Cancel) { 'cancelled' } elseif ($doneFinished) { 'finished' } else { 'stopped' }
        $taskRecord.changed = @($checkpoint.Files.Keys); $taskRecord.remaining = @($State.Todos)
        $taskRecord.acceptance = @($acceptResults); $taskRecord.verification = $ev
        $taskRecord.result = $doneText
        try { $null = Save-TaskRecord $State.TaskRecordDir $taskRecord } catch { Write-CCBLogError agent 'task record' $_ }
        # Project progress across chats (Progress, setting progressLog): every work task, not plain chat.
        if ("$kind" -and "$kind" -ne 'chat' -and $State.Mode -ne 'plan' -and "$($State.Config.progressLog)" -notin 'False', 'off') {
            try { Add-ProgressEntry $State.TaskRecordDir (New-ProgressEntry -Request $Text -Status $taskRecord.status -Result "$doneText" -Changed @($checkpoint.Files.Keys) -Acceptance @($acceptResults) -Verify $ev.verify -Todos @($State.Todos) -Kind "$kind") } catch { Write-CCBLogError agent 'progress' $_ }
        }
        try {
            $fixed = @(Restore-SourceData $State.ProjectRoot)
            if ($fixed.Count) { Add-OwnChangeEvent $State 'restore' "$(@($fixed).Count) read-only file(s)" 'Source/ and protected files are read-only; StreamHub undid changes to them.' -Output ($fixed -join "`n") }
        } catch { Add-AgentEvent $State 'error' @{ text = "Could not verify source data: $($_.Exception.Message)" } }
        try { Clear-RunSnapshot $checkpoint } catch { Write-CCBLogError agent 'run snapshot' $_ }
        if (-not $checkpoint.Files.Count) { Remove-Item $checkpoint.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        # File-check errors that needed more than one change in this task (fixed or not): a case log each.
        foreach ($k in @($turn.errorRounds.Keys | Where-Object { [int]$turn.errorRounds[$_] -ge 2 })) {
            try {
                $first = $turn.errorFirst[$k]
                $still = @($turn.lastErrorKeys) -contains $k
                $n = [int]$turn.errorRounds[$k]
                $change = ''
                if ($checkpoint.Files[$first.path] -eq 'existed') {
                    $bk = Join-Path $checkpoint.Dir ($first.path.Replace('/', '\'))
                    $nowFull = Join-Path $State.ProjectRoot ($first.path.Replace('/', '\'))
                    if ((Test-Path -LiteralPath $bk) -and (Test-Path -LiteralPath $nowFull)) { $change = Format-LineChange (Read-TextFile $bk).Text (Read-TextFile $nowFull).Text 60 }
                }
                $tries = @(for ($i = 1; $i -le $n; $i++) { @{ attempt = $i; how = $(if ($i -eq 1) { 'the change that brought it' } else { "Copilot's next change (with the evidence and a cause first from the second time on)" }); diagnosis = ''; left = @($first.text) } })
                if (-not $still) { $tries += @{ attempt = $n + 1; how = "Copilot's next change"; diagnosis = (Get-FixDiagnosis $State $turnSeq); left = @() } }
                else { $tries[-1].diagnosis = (Get-FixDiagnosis $State $turnSeq) }
                $rel = Write-FixCase $State.ProjectRoot @{ kind = 'in a task'; path = $first.path; problems = @($first.text); request = $Text; change = $change; attempts = $tries
                    outcome = $(if ($still) { "still there when the task ended, after $n changes" } else { "fixed within the task after $n changes" }); fixed = (-not $still) }
                Add-AgentEvent $State 'status' @{ text = "Fix case recorded for review: $rel"; path = $rel }
            } catch { Write-CCBLogError agent 'fix case' $_ }
        }
        # Copilot did not report done (round limit, a reply without actions, Copilot stopping): the done
        # step's checks run anyway, so problems in unfinished work are found and shown.
        if (-not $doneFinished -and $checkpoint.Files.Count -and -not $State.Cancel -and $State.Mode -ne 'plan' -and -not $State.ReviewByCaller -and -not $State.IssueFix) {
            try { Invoke-FinalChecks $State $checkpoint $ev $endReason } catch { Write-CCBLogError agent 'final checks' $_ }
        }
        $State.LastTurnPlan = @{ todos = @($State.Todos | Where-Object { $_ }); doneWhen = @($doneWhen); acceptance = $acceptResults }
        if ($checkpoint.Files.Count -and "$($State.Config.evidence)" -ne 'off' -and $State.Mode -ne 'plan') {
            try {
                $chg = @(Get-CheckpointChanges $State.ProjectRoot $checkpoint | Where-Object { $_.added -or $_.removed -or $_.created -or $_.deleted })
                if ($chg.Count) {
                    $ev.hooks = if ($null -ne $State.HookTrace) { @($State.HookTrace | ForEach-Object { $_ }) } else { @() }
                    $evPath = Save-TaskEvidence $State $Text $chg $ev $doneText ([int]$State.MessagesSent - $msgStart)
                    Add-AgentEvent $State 'status' @{ text = "Task report saved: $evPath"; path = $evPath }
                }
            } catch { Write-CCBLogError agent 'evidence' $_ }
        }
        if ($checkpoint.Files.Count -and $State.ReviewByCaller) {
            $contents = @(try { Get-ChangeSetContents $State.ProjectRoot $checkpoint } catch { Write-CCBLogError agent 'change set contents' $_ })
            Add-ChangeSetEvent $State $checkpoint $Text @{ contents = $contents }
        }
        elseif ($checkpoint.Files.Count) { Add-ChangeSetEvent $State $checkpoint $Text }
        # Issue cycle steps 3-6: scan what changed, queue fixes, check a fix task's file again.
        if (($checkpoint.Files.Count -or $State.IssueFix) -and $null -ne $baseline -and -not $State.Cancel) {
            $scan = @($checkpoint.Files.Keys) + @(if ($State.IssueFix) { "$($State.IssueFix.path)" })
            try { $null = Invoke-IssueCycle $State $scan $baseline $State.IssueFix $(if ($checkpoint.Files.Count) { $checkpoint.Id } else { '' }) $Text } catch { Write-CCBLogError agent 'issue cycle' $_ }
        }
        $State.Busy = $false; $State.Cancel = $false
    }
}

function Get-ResponseOptionsFile { Join-Path $env:LOCALAPPDATA 'CCBridge\response-options.json' }

function Read-ResponseOptionsFile {
    <# The response picker's options as last read: @{ read (ISO time or ''); options }. #>
    $f = Get-ResponseOptionsFile
    if (-not (Test-Path -LiteralPath $f)) { return @{ read = ''; options = @() } }
    try {
        $j = ConvertFrom-Json ([IO.File]::ReadAllText($f))
        @{ read = "$($j.read)"; options = @(foreach ($o in $j.options) { if ($o.path) { @{ path = "$($o.path)"; title = "$($o.title)"; description = "$($o.description)"; parent = "$($o.parent)" } } }) }
    } catch { @{ read = ''; options = @() } }
}

function Test-ResponseOptionsDue($State, [datetime]$Now = (Get-Date)) {
    <# Whether the picker's options should be read again: never read, or longer ago than the setting
       responseOptionsDays (default 7; 0 = only when asked, Settings > Copilot > Read now). Not more
       than once an hour when reading fails. #>
    $days = if ($null -ne $State.Config.responseOptionsDays -and "$($State.Config.responseOptionsDays)" -match '^\d+$') { [int]$State.Config.responseOptionsDays } else { 7 }
    if ($State.ResponseOptionsTried -and ($Now - [datetime]$State.ResponseOptionsTried).TotalHours -lt 1) { return $false }
    if (-not $State.ResponseOptionsRead) { return $true }
    if ($days -le 0) { return $false }
    $at = [datetime]::MinValue
    if (-not [datetime]::TryParse("$($State.ResponseOptionsRead)", [ref]$at)) { return $true }
    ($Now - $at).TotalDays -ge $days
}

function Update-ResponseOptions {
    <# Reads what Copilot's response picker offers now (Get-CopilotResponseOptions) into the state and
       response-options.json. -Report (Settings > Read now) says the result in the chat. #>
    param($State, $Bridge, [switch]$Report)
    $State.ResponseOptionsTried = (Get-Date).ToString('s')
    try {
        $list = @(Get-CopilotResponseOptions $Bridge | ForEach-Object { @{ path = "$($_.path)"; title = "$($_.title)"; description = "$($_.description)"; parent = "$($_.parent)" } })
        if (-not $list.Count) { throw 'the response picker was not found on Copilot''s page' }
        $State.ResponseOptions = $list
        $State.ResponseOptionsRead = (Get-Date).ToString('s')
        $f = Get-ResponseOptionsFile
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f)
        [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @{ read = $State.ResponseOptionsRead; options = $list } -Depth 4), (New-Object Text.UTF8Encoding($false)))
        Write-CCBLog info agent "Response options read: $(@($list | ForEach-Object { $_.path }) -join '; ')"
        if ($Report) { Add-AgentEvent $State 'status' @{ text = "Copilot's response picker offers: $(@($list | ForEach-Object { $_.path }) -join ', '). The Response menu next to New chat lists them." } }
    } catch {
        Write-CCBLogError agent 'Response options' $_
        if ($Report) { Add-AgentEvent $State 'error' @{ text = "Could not read Copilot's response options: $($_.Exception.Message)"; record = $_ } }
    }
}

function Reset-AfterWorkerStop {
    <# After the worker stopped unexpectedly (Server restarts it): the task that was running is marked
       failed (also its MCP job), the busy state, activity and live command view are cleared, the
       Copilot connection is made again by the new worker, and an error card says what happened.
       Returns the queue entries marked failed. #>
    param($State, [string]$Reason)
    $failed = @()
    Stop-WorkStatus $State
    foreach ($e in @($State.Queue | Where-Object { $_ -and $_.status -in 'running', 'awaiting' })) {
        $e.status = 'failed'; $e.finished = (Get-Date).ToString('s')
        $e.error = "StreamHub's task worker stopped while this task was running ($Reason). Files it changed so far can be undone; send it again to finish it."
        if ($e.jobId -and $State.Jobs[$e.jobId]) { $j = $State.Jobs[$e.jobId]; $j.status = 'error'; $j.error = $e.error; $j.endSeq = $State.Seq }
        $failed += $e
    }
    $State.Busy = $false; $State.Cancel = $false; $State.InChain = $false; $State.Progress = ''
    if ($State.Activity) { $State.Activity.kind = ''; $State.Activity.label = '' }
    $State.RunLive = $null
    $State.Copilot = 'connecting'; $State.CopilotMessage = 'Reconnecting to Copilot after a restart of the task worker.'
    $what = if ($failed.Count) { " The task that was running ($(@($failed | ForEach-Object { "$(if ($_.title) { $_.title } else { $_.kind })" }) -join ', ')) was stopped and marked failed; the queue carries on." } else { '' }
    Add-AgentEvent $State 'error' @{ text = "StreamHub's task worker stopped unexpectedly and was restarted: $Reason.$what"; code = 'WORKER-RESTART'; hint = 'Nothing to do unless it happens again. If it does, use Copy details or Menu > Export diagnostics and send it with the error id.' }
    try { Save-AgentQueue $State } catch { }
    $failed
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
                Write-CCBLog info agent "Retrying the Copilot connection (attempt $([int]$State.ConnectFailures + 1))"
                $State.Tasks.Enqueue(@{ kind = 'connect'; auto = $true })
            }
            Update-CopilotTheme $State   # idle: a theme just chosen in the app reaches the Copilot tab at once
            [Threading.Monitor]::Enter($State.ProjectGate)
            try {
            # A project just opened (Set-Project): data copies follow their JSON. Data files are not
            # converted for an open alone; a live data file the person chose is brought in at once.
            if ($State.OpenSync) {
                $openRoot = $State.OpenSync; $State.OpenSync = $null
                # The person wants another project (Set-Project could not get in): this one's preparation
                # stops here and runs again when it is opened next.
                if ($openRoot -eq $State.ProjectRoot -and -not $State.SwitchWanted) {
                    $live = try { [bool](Get-ProjectSetup $openRoot).liveSource } catch { $false }
                    $prev = if ($live) { Enter-Activity $State 'index' 'Bringing in the live data file' } else { $null }
                    try { Sync-DataMirrors $State -Import:$live } catch { Write-CCBLogError agent 'data at project open' $_ } finally { if ($prev) { Exit-Activity $State $prev } }
                    # A project from an older kit: the catalogue, the kit files the pages use and the
                    # project's tokens brought to this version's kit right at open, so a newer
                    # StreamHub's additions are there before the first task.
                    try {
                        # The shared library beside the projects (one kit, shared notes, runbooks for all): made at the first open.
                        $null = Get-SharedRoot $openRoot -Create
                        $kitNewer = @(if ((Test-UiKitOn $State.AppRoot) -and -not $State.SwitchWanted) { Update-UiKitCatalog $openRoot $State.AppRoot })   # only with the UI kit on (Settings)
                        if ($kitNewer.Count) {
                            Add-OwnChangeEvent $State 'write' "$(Get-UiKitFolder)/ (UI kit)" "StreamHub updated the project's UI kit to its newer version: the catalogue in $(Get-UiKitCatalog $State.ProjectRoot)/, new tokens in tokens.css (your own colours stay) and the kit files the pages use that the project had not changed ($($kitNewer -join ', ')). Kit files the project changed stay as they are." -Output ($kitNewer -join "`n")
                            $u = Update-UiKitProject $openRoot $State.AppRoot
                            foreach ($f in @($u.updated) + @($u.added)) { if ($f) { Add-OwnChangeEvent $State 'write' $f 'StreamHub wrote this kit file again from the newer kit.' } }
                        }
                        # One-file pages carry their own copy of the kit: filled again from the (newer) catalogue
                        # at open too, so a kit fix reaches them without waiting for the next task.
                        if ((Test-UiKitOn $State.AppRoot) -and -not $State.SwitchWanted) {
                            $prev = Enter-Activity $State 'index' 'Bringing one-file pages up to date'
                            try { $null = Sync-OneFilePages $State } finally { Exit-Activity $State $prev }
                        }
                    } catch { Write-CCBLogError agent 'UI kit at project open' $_ }
                }
            }
            # Live data (project setup): the outside file checked once a minute; a new version is
            # copied in, converted and filled into one-file pages at once.
            if ($State.ProjectRoot -and (-not $State.NextLiveCheck -or (Get-Date) -ge [datetime]$State.NextLiveCheck)) {
                $State.NextLiveCheck = (Get-Date).AddMinutes(1).ToString('o')
                try { if ((Get-ProjectSetup $State.ProjectRoot).liveSource -and (Sync-LiveData $State)) { $null = Sync-DataImports $State -NoLive } } catch { Write-CCBLogError agent 'live data' $_ }
            }
            } finally { [Threading.Monitor]::Exit($State.ProjectGate) }
            # Weekly (setting responseOptionsDays): what Copilot's response picker offers, while idle.
            if ($State.Copilot -eq 'ready' -and $script:Bridge -and (Test-ResponseOptionsDue $State)) { Update-ResponseOptions $State $script:Bridge }
            Start-Sleep -Milliseconds 150; continue
        }
        # Hold this through checks, approvals and cleanup, not just while Busy happens to be true.
        # Connecting does not use a project and must not prevent startup from opening the last one.
        $projectLocked = $task.kind -ne 'connect'
        if ($projectLocked) { [Threading.Monitor]::Enter($State.ProjectGate) }
        try {
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
        # The waiting card's status: phase, timers, counts and steps of this task (WorkStatus).
        if (-not $task.background -and $task.kind -ne 'connect') { Start-WorkStatus $State "$($task.kind)" "Started: $(if ($task.title) { "$($task.title)" } else { "$($task.kind) task" })" }
        # A task from another program can bring its own mode, project and command rule; the app's
        # own settings come back afterwards.
        $saved = @{ Mode = $State.Mode; ProjectRoot = $State.ProjectRoot; NoCommands = $State.NoCommands; ReviewByCaller = $State.ReviewByCaller; ResponseMode = $State.ResponseMode }
        if ($task.responseMode) { $State.ResponseMode = $task.responseMode }
        $State.ReviewByCaller = [bool]$task.reviewByCaller
        if ($task.mode) { $State.Mode = $task.mode }
        $State.NoCommands = [bool]$task.noCommands
        # A test run's 'off:' header: those checks and settings are off for this task only.
        $switchRestore = Set-TaskSwitchesOff $State @(if ($task.testRun) { @($task.testRun.off) })
        $projectReady = $false; $projectChanged = $false
        try {
            if ($task.kind -in $script:ProjectTaskKinds) {
                # Older direct MCP tasks can use the current project; an explicit captured null
                # must never inherit a project that was opened after the request.
                $taskRoot = if ($task.ContainsKey('projectRoot')) { $task.projectRoot } else { $State.ProjectRoot }
                if (-not $taskRoot) { throw 'Open or create a project first.' }
                if (-not (Test-Path -LiteralPath $taskRoot -PathType Container)) { throw "The project folder $taskRoot no longer exists" }
                if ($taskRoot -ne $State.ProjectRoot) {
                    $projectChanged = $true
                    $State.ProjectRoot = $taskRoot; $State.Todos = @(); $State.NeedNewChat = $true
                }
            }
            $projectReady = $true
            # Apply the task's project before reading its preferences or protected files.
            $State.ScopeAsk = ''
            if ($State.ProjectRoot -and -not $State.Headless -and (-not $task.source -or $task.source -eq 'user')) { try { Use-BigTaskPreference $State $task } catch { Write-CCBLogError agent 'big task preference' $_ } }
            if ($State.ProjectRoot -and $task.kind -notin 'connect', 'newchat') { try { Sync-ProtectedVault $State.ProjectRoot } catch { Write-CCBLogError agent 'protected files' $_ } }
            switch ($task.kind) {
                'connect' {
                    # Retry in the app (not the idle worker's own retry): the count of failures starts over.
                    if (-not $task.auto) { $State.ConnectFailures = 0 }
                    $null = Get-Bridge $State
                }
                'chat'    {
                    if ($task.newChat) { $State.NeedNewChat = $true }
                    $force = if ($task.forceKind) { "$($task.forceKind)" } elseif ($task.source -eq 'mcp' -or $task.source -eq 'api') { 'work' } else { '' }
                    # "Run the meetings runbook": the runbook job sends the runbook's instructions and
                    # contents to Copilot, as the Run button does. Not for "send again as a coding task".
                    $runReq = if ($force -ne 'coding' -and -not $task.noRunbook -and $State.ProjectRoot) { Get-RunbookRunRequest $task.text @(Get-Runbooks $State.ProjectRoot) } else { $null }
                    if ($runReq -and $runReq.ask) {
                        # A longer message that names a runbook: run it, or send the message to Copilot? The person chooses.
                        Add-AgentEvent $State 'user' @{ text = $task.text }
                        $rb = @(Get-Runbooks $State.ProjectRoot | Where-Object { $_.name -eq $runReq.name }) | Select-Object -First 1
                        Add-AgentEvent $State 'runbook-choice' @{ name = $runReq.name; title = "$($rb.title)"; request = $task.text }
                    } elseif ($runReq -and $runReq.name) {
                        Add-AgentEvent $State 'user' @{ text = $task.text }
                        Add-AgentEvent $State 'kind' @{ taskKind = 'runbook' }
                        Invoke-RunbookJob $State $runReq.name
                    } elseif ($runReq) {
                        Add-AgentEvent $State 'user' @{ text = $task.text }
                        $which = if (@($runReq.names).Count) { 'Which runbook should run? Name one of: ' + (@($runReq.names) -join ', ') + '. Or press Run on it in the Fetch tab.' } else { 'This project has no runbooks yet. Create one with "New runbook from a template" in the Fetch tab (or ask Copilot to create one), then run it.' }
                        Add-AgentEvent $State 'status' @{ text = $which }
                    } elseif (-not $task.setup -and (-not $task.source -or $task.source -eq 'user') -and -not $force -and -not $State.Headless -and $State.ProjectRoot -and (Publish-SetupQuestions $State $task)) {
                        # Asked how the project should be built: the answer sends the request again.
                    } elseif ($task.clarify) {
                        if ($task.setup) { $null = Save-SetupAnswer $State $task.setup }
                        Invoke-ClarifyStep $State $task
                    } else {
                        if ($task.setup) { $sa = Save-SetupAnswer $State $task.setup; if ($sa.textPrefix) { $task.text = $sa.textPrefix + $task.text } }
                        $State.IssueFix = $task.issueFix; $State.IssueFixHandled = $false; $State.IssueFixFromSeq = $fromSeq
                        if ($task.freshChat) { $State.NeedNewChat = $true }
                        $State.ScopeUpgrade = ''
                        try { Invoke-AgentTurn $State $task.text $force -Shown:([bool]$task.shown) }
                        finally {
                            $State.ScopeAsk = ''
                            $State.TurnAnswers = @{}
                            $State.IssueFix = $null
                            # Stopped or failed before the rescan: its issues go back to open (no retry).
                            if ($task.issueFix -and -not $State.IssueFixHandled) { try { $null = Reset-StaleIssueFixes $State $State.ProjectRoot } catch { Write-CCBLogError agent 'issue fix reset' $_ } }
                        }
                        if (-not $State.ScopeUpgrade -and -not $State.Stop) { $null = Write-TurnPlan $State $task $fromSeq }
                        if ($State.ScopeUpgrade) {
                            # Copilot judged it a big request: the same request again as Clarify first or Plan first.
                            $State.ScopeUpgrade = ''
                            $next = @{ kind = 'chat'; text = "$($task.text)"; bigByCopilot = $true; shown = $true }
                            if ($task.projectRoot) { $next.projectRoot = $task.projectRoot }
                            $null = Submit-AgentTask $State $next 'user'
                        }
                        elseif ($task.planFirst) { Publish-PlanReady $State $task $fromSeq }
                        elseif (-not $task.planBuild -and -not $task.issueFix -and -not $State.Stop) { try { $null = Publish-ProposalPlan $State $task $fromSeq } catch { Write-CCBLogError agent 'proposal plan' $_ } }
                        if ($task.planBuild -and $task.planId) { Write-PlanResult $State "$($task.planId)" $fromSeq }
                    }
                }
                'fetch' { if ($task.missingProject) { throw "The project folder $($task.projectRoot) no longer exists" }; Invoke-FetchJob $State $task.name }
                'runbook' { if ($task.missingProject) { throw "The project folder $($task.projectRoot) no longer exists" }; Invoke-RunbookJob $State $task.name }
                'agent' { Invoke-AgentRun $State ([string]$task.agent) ([string]$task.text) -FollowUp:([bool]$task.followUp) -AutoWhy ([string]$task.autoWhy) }
                'chain' { if ($task.missingProject) { throw "The project folder $($task.projectRoot) no longer exists" }; Invoke-ChainJob $State $task.name }
                'script' { if ($task.missingProject) { throw "The project folder $($task.projectRoot) no longer exists" }; Invoke-ScriptJob $State $task.name }
                'testrun-report' { Invoke-TestRunReport $State $task }
                'export' { Invoke-ExportJob $State $task }
                'packages' { if ($task.missingProject) { throw "The project folder $($task.projectRoot) no longer exists" }; Invoke-PackagesJob $State $task.folder }
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
                    # From New chat in the app the view already started over (background): only
                    # Copilot's page changes here, unless a message started a new chat meanwhile.
                    if (-not $task.background -or $State.NeedNewChat) { Start-NewChat $State }
                    if (-not $task.background) {
                        $State.Todos = @()
                        $State.Summary = $null
                        Add-AgentEvent $State 'newchat' @{ text = 'New Copilot chat started.' }
                    }
                }
                'undo' { Invoke-UndoTask $State "$($task.upTo)" }
                'response-options' { Update-ResponseOptions $State (Get-Bridge $State) -Report }
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
            try {
            if ($projectReady) {
            # Retention: old .streamhub/History, evidence and reviews and undo backups of the project go now.
            if ($State.ProjectRoot -and $task.kind -ne 'connect') { try { $null = Invoke-ProjectRetention $State.ProjectRoot $State.Config } catch { Write-CCBLogError agent 'retention' $_ } }
            # Data copies follow their JSON (a runbook, chain or change may have written the JSON).
            if ($State.ProjectRoot -and $task.kind -ne 'connect') { Sync-DataMirrors $State }
            # Packages a package.json lists that are not installed yet: a card to install them.
            if ($State.ProjectRoot -and $task.kind -notin 'connect', 'packages', 'newchat') { Publish-PackagesNeeded $State }
            # The project's afterTask hooks, after work that can change files.
            if ($State.ProjectRoot -and $task.kind -in 'chat', 'fetch', 'runbook', 'chain', 'script', 'agent') { try { $null = Invoke-ProjectHooks $State 'afterTask' } catch { Write-CCBLogError agent 'hooks' $_ } }
            }
            } finally {
            $State.CurrentQueueId = $null
            $State.VisualTurn = $false
            Stop-WorkStatus $State
            $State.Mode = $saved.Mode; $State.NoCommands = $saved.NoCommands; $State.ReviewByCaller = $saved.ReviewByCaller; $State.ResponseMode = $saved.ResponseMode
            Restore-TaskSwitches $switchRestore
            if ($projectChanged) {
                $State.ProjectRoot = $saved.ProjectRoot; $State.NeedNewChat = $true
            }
            }
        }
        } finally { if ($projectLocked) { [Threading.Monitor]::Exit($State.ProjectGate) } }
    }
    Reset-Bridge $State
}

Export-ModuleMember -Function Get-TurnTestBaseline, Get-AcceptanceStep, Invoke-FreshReview, Set-TaskSwitchesOff, Restore-TaskSwitches, Get-FolderNotes, Test-RoundsLeft, Test-ExploreRound, Get-ExploreNudge, Use-BigTaskPreference, Register-ReadStamp, Test-RangeEditAllowed, Get-StaleReadNote, Get-WholeFileFallback, Get-LeakReport, Find-TextInFiles, Sync-LiveData, Sync-OneFilePages, Publish-SetupQuestions, Save-SetupAnswer, Read-ResponseOptionsFile, Test-ResponseOptionsDue, Update-ResponseOptions, Reset-AfterWorkerStop, Get-FixEvidence, New-FixAttemptMessage, Publish-PackagesNeeded, Invoke-PackagesJob, Sync-DataImports, Publish-ProposalPlan, Test-NoAnswerError, Get-ChainRetryWaits, Get-CopilotThemeWanted, Update-CopilotTheme, Invoke-ProjectHooks, Invoke-UndoTask, Invoke-ScriptJob, Add-OwnChangeEvent, Sync-DataMirrors, Add-AgentOutputFormat, Add-ChangeSetEvent, Invoke-RunbookJob, Invoke-FetchJob, Resolve-AgentFiles, Get-AgentAttachments, Get-AgentSpec, Save-AgentCharts, Send-AgentJobMessage, Invoke-AgentRun, Invoke-ChainJob, Get-ChangeCountStart, Reset-ChatHistoryCount, Get-ChatHistoryPath, Save-ChatEvent, Read-ChatHistory, Restore-ChatHistory, Update-AgentSchedule, Get-ProjectScheduleFile, Import-ProjectSchedules, Sync-ProjectSchedules, Get-IssueSettings, Get-IssueBaseline, Submit-IssueFix, Reset-StaleIssueFixes, Get-QueuedIssueFix, Invoke-IssueCycle, Start-IssueIndexer, Get-ProjectVerify, Save-TaskEvidence, Publish-PlanReady, Invoke-ClarifyStep, Get-ReviewScope, Get-ReviewPlan, Invoke-ReviewJob, Submit-AgentTask, Get-QueueEntry, Save-AgentQueue, Restore-AgentQueue, Set-QueuePause, Resume-AgentQueue, Save-QueuePause, Restore-QueuePause, Save-Schedules, Restore-Schedules, New-AgentSchedule, Start-ScheduledItem, Invoke-DueSchedules, New-AgentState, Add-AgentEvent, Get-AgentEvents, Start-AgentWorker, Invoke-AgentTurn, Write-TurnPlan, Set-PlanBuildTask, Invoke-TestRunReport, Invoke-ExportJob
