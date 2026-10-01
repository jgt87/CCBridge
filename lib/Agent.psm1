# The agent loop. Runs in a background runspace and talks to the web server only through
# the synchronized $State hashtable (events out, tasks and approval decisions in).

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'CopilotBridge', 'Workspace', 'Protocol', 'Executor') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

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
        [void]$State.Events.Add($Data)
        switch ($Type) {
            'error'          { Write-CCBLog info agent "error event: $($Data.text)" }
            'human-required' { Write-CCBLog info agent "HUMAN REQUIRED: $($Data.text)" }
            'status'         { Write-CCBLog verbose agent "status: $($Data.text)" }
            'action'         { Write-CCBLog verbose agent "action $($Data.id) $($Data.action) -> $($Data.status)" @{ target = $Data.target; error = $Data.error } }
            'action-result'  { Write-CCBLog verbose agent "result $($Data.id) $($Data.status)" @{ summary = $Data.summary } }
            'checkpoint'     { Write-CCBLog verbose agent "change set saved" @{ files = $Data.files } }
            'undo'           { Write-CCBLog info agent "undo: $($Data.text)" }
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
    if ($script:Bridge) { return $script:Bridge }
    $State.Copilot = 'connecting'
    $State.CopilotMessage = 'Opening Copilot in Edge. Sign in there if asked.'
    try {
        $save = if ($null -ne $State.Config.saveReplyFrames) { [bool]$State.Config.saveReplyFrames } else { $true }
        $script:Bridge = Connect-Copilot -Port $State.Config.cdpPort -SaveReplyFrames $save
        $State.Copilot = 'ready'; $State.CopilotMessage = ''
        $script:Bridge
    } catch {
        $State.Copilot = 'error'; $State.CopilotMessage = $_.Exception.Message
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
        $r = Send-CopilotPrompt $bridge $Message -TimeoutSec $State.Config.replyTimeoutSec -OnProgress $progress -CancelCheck $cancel
    } catch {
        Reset-Bridge $State   # the next send reconnects
        throw
    } finally { $State.Progress = '' }
    if ($r.Throttling -and $r.Throttling.maxNumUserMessagesInConversation) {
        $State.Throttle = @{ used = [int]$r.Throttling.numUserMessagesInConversation; max = [int]$r.Throttling.maxNumUserMessagesInConversation }
    }
    if ($r.Metering -and $null -ne $r.Metering.remainingAllowance) {
        $State.Credits = @{ remaining = [int]$r.Metering.remainingAllowance; total = [int]$r.Metering.totalAllowance; resetAt = [string]$r.Metering.resetAt }
    }
    $State.ChatStarted = $true
    Set-LastSender
    $r
}

function Start-NewChat($State) {
    New-CopilotChat (Get-Bridge $State)
    $State.ChatStarted = $false
    $State.NeedNewChat = $false
    $State.Throttle = @{ used = 0; max = $State.Throttle.max }
}

# --- Prompt building -----------------------------------------------------------------

function Get-PinnedFiles {
    param([string]$ProjectRoot, [string]$Text)
    $paths = @([regex]::Matches($Text, '(?<![\w@])@([\w.][\w./\\-]*\w)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique |
        Where-Object { try { Test-Path -LiteralPath (Resolve-ProjectPath $ProjectRoot $_) -PathType Leaf } catch { $false } })
    if (-not $paths.Count) { return '' }
    "`n`n# Attached files`n" + ((Invoke-ReadAction $ProjectRoot $paths) -join "`n`n")
}

function Get-FirstMessage {
    param($State, [string]$Task)
    $root = $State.ProjectRoot
    $system = [IO.File]::ReadAllText((Join-Path $State.AppRoot 'prompts\system.md'))
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine($system.Trim()).AppendLine()
    [void]$sb.AppendLine("# Project: $(Split-Path $root -Leaf)").AppendLine()
    $memo = Join-Path $root 'AGENTS.md'
    if (Test-Path $memo) { [void]$sb.AppendLine('## Project notes (AGENTS.md)').AppendLine(([IO.File]::ReadAllText($memo)).Trim()).AppendLine() }
    $treeBudget = [Math]::Max(2000, [int]($State.Config.promptCharBudget * 0.25))
    [void]$sb.AppendLine('## Files').AppendLine('```').AppendLine((Format-ProjectTree $root -MaxChars $treeBudget)).AppendLine('```').AppendLine()
    if ($State.Summary) { [void]$sb.AppendLine('## Summary of the previous chat').AppendLine($State.Summary).AppendLine(); $State.Summary = $null }
    [void]$sb.AppendLine('# Task').AppendLine($Task)
    $sb.ToString()
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max) + "`n(truncated by CCBridge: $($Text.Length - $Max) more characters)"
}

function Invoke-RolloverIfNeeded($State) {
    $t = $State.Throttle
    if (-not $t.max -or $t.used -lt ($t.max - $State.Config.rolloverMargin)) { return }
    Write-CCBLog info agent "Chat rollover" @{ used = $t.used; max = $t.max }
    Add-AgentEvent $State 'status' @{ text = "This Copilot chat is nearly full ($($t.used)/$($t.max) messages). Summarizing and continuing in a new chat." }
    $r = Send-ToCopilot $State 'Summarize this conversation so it can continue in a fresh chat: the task, decisions made, files created or changed, the current state and the next steps. At most 2500 characters. Do not use action blocks.'
    $State.Summary = Limit-Text $r.Text 4000
    Start-NewChat $State
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
            return @{ ok = $true; summary = "read $($paths.Count) file(s)"; output = ((Invoke-ReadAction $root $paths) -join "`n`n") }
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
                Add-AgentEvent $State 'human-required' @{ text = "Copilot wanted to run a command that $why. CCBridge does not run such commands without a person approving them. Command: $($evt.target)" }
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
        return @{ ok = $false; summary = "$($Action.type) skipped (plan mode)"; output = 'not executed: CCBridge is in plan mode (read-only). Describe the plan instead of changing files or running commands.' }
    }

    if ($needsApproval) {
        # Explicit $null: an if without else yields AutomationNull, which ConvertTo-Json writes as {}.
        $warn = $null
        if ($Uncertain -gt 0) { $warn = 'Copilot''s reply had to be repaired after its link filter removed text; check this change carefully.' }
        if ($riskWarning) { $warn = $riskWarning }
        Add-AgentEvent $State 'action' (Join-Hash $evt @{ status = 'awaiting'; preview = $preview; warning = $warn })
        $waitWatch = [Diagnostics.Stopwatch]::StartNew()
        $d = Wait-Approval $State $Id
        Write-CCBLog verbose agent "approval ${Id}: $($d.decision) after $($waitWatch.ElapsedMilliseconds) ms"
        if ($d.decision -ne 'approve') {
            Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $false; status = 'rejected'; output = $d.note }
            $why = if ($d.note) { " The user said: $($d.note)" } else { '' }
            return @{ ok = $false; summary = "$($Action.type) rejected"; output = "rejected by the user.$why" ; reported = $true }
        }
        Add-AgentEvent $State 'action-result' @{ id = $Id; ok = $true; status = 'running' }
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
                    Add-AgentEvent $State 'status' @{ text = "Source data is read-only; CCBridge undid what the command did to it: " + ($fixed -join '; ') }
                    $out += "`nCCBridge: source/ is the user's read-only source data. This command changed it, so CCBridge " + ($fixed -join '; ') + '. Work on copies outside source/.'
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
        $message = if ($State.ChatStarted) { $Text } else { Get-FirstMessage $State $Text }
        $message += Get-PinnedFiles $State.ProjectRoot $Text

        for ($round = 1; $round -le $State.Config.maxRounds; $round++) {
            if ($State.Cancel) { Add-AgentEvent $State 'status' @{ text = 'Stopped.' }; break }
            Invoke-RolloverIfNeeded $State
            if (-not $State.ChatStarted -and $round -gt 1) { $message = (Get-FirstMessage $State 'Continue the task described in the summary above.') + "`n`n" + $message }
            $message = Limit-Text $message $State.Config.promptCharBudget

            Write-CCBLog verbose agent "Round ${round}: sending" @{ chars = $message.Length }
            $r = Send-ToCopilot $State $message
            if ($r.Cancelled) {
                Add-AgentEvent $State 'status' @{ text = 'Stopped while Copilot was writing; its partial reply was discarded.' }
                break
            }
            $actions = @(Get-ActionBlocks $r.Text)
            Write-CCBLog verbose agent "Round ${round}: reply parsed" @{ actions = @($actions | ForEach-Object { "$($_.type) $($_.arg)".Trim() }) }
            Add-AgentEvent $State 'assistant' @{ text = $r.Text; uncertain = $r.Uncertain; round = $round; used = $State.Throttle.used; max = $State.Throttle.max; references = @($r.References) }
            if ($r.Result -and $r.Result -ne 'Success') { Add-AgentEvent $State 'error' @{ text = "Copilot answered with '$($r.Result)': $($r.ResultMessage)" }; break }
            if (@($r.ProposedActions).Count) {
                $what = (@($r.ProposedActions) | ForEach-Object { $_.title } | Where-Object { $_ } | Select-Object -Unique) -join '; '
                Add-AgentEvent $State 'human-required' @{ text = "Copilot proposed an action in Microsoft 365 ($what). CCBridge never confirms Microsoft 365 actions. Look at it in the Copilot window in Edge and confirm or cancel it yourself; the task has stopped here." }
                break
            }
            foreach ($claim in @($r.ActionClaims)) {
                Add-AgentEvent $State 'human-required' @{ text = "Copilot's reply says: ""$claim"" CCBridge did not confirm any Microsoft 365 action. Check Outlook / Teams if this is unexpected." }
            }
            if (-not $actions.Count) { break }

            $results = New-Object Collections.Generic.List[string]
            $isDone = $false
            for ($k = 0; $k -lt $actions.Count; $k++) {
                if ($State.Cancel) { break }
                $a = $actions[$k]
                if ($a.type -eq 'done') { $isDone = $true; Add-AgentEvent $State 'done' @{ text = $a.body.Trim() }; continue }
                $id = "$($State.Seq)-$k"
                $res = Invoke-AgentAction $State $a $id $checkpoint $r.Uncertain
                if (-not $res.reported) { Add-AgentEvent $State 'action-result' @{ id = $id; ok = $res.ok; status = $(if ($res.ok) { 'ok' } else { 'failed' }); summary = $res.summary; output = (Limit-Text $res.output 4000); changed = [bool]$res.changed } }
                $results.Add("### $($k + 1). $($a.type) $($a.arg)`n$($res.output)".TrimEnd())
            }
            if ($State.Cancel) { Add-AgentEvent $State 'status' @{ text = 'Stopped. Changes made so far in this message can be undone.' }; break }
            if ($isDone) { break }
            if ($round -eq $State.Config.maxRounds) { Add-AgentEvent $State 'status' @{ text = "Stopped after $($State.Config.maxRounds) rounds. Send a message to continue." }; break }

            $perResult = [Math]::Max(1500, [int]($State.Config.resultCharBudget / [Math]::Max(1, $results.Count)))
            $message = "CCBridge results:`n`n" + (($results | ForEach-Object { Limit-Text $_ $perResult }) -join "`n`n") + "`n`nContinue. Use done when the task is finished."
        }
    } catch {
        Write-CCBLogError agent 'turn failed' $_
        Add-AgentEvent $State 'error' @{ text = $_.Exception.Message }
    } finally {
        Write-CCBLog info agent "Turn finished" @{ ms = $turnWatch.ElapsedMilliseconds; chat = "$($State.Throttle.used)/$($State.Throttle.max)"; cancelled = [bool]$State.Cancel }
        try {
            $fixed = @(Restore-SourceData $State.ProjectRoot)
            if ($fixed.Count) { Add-AgentEvent $State 'status' @{ text = 'Source data is read-only; CCBridge undid changes to it: ' + ($fixed -join '; ') } }
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
        if (-not $State.Tasks.TryDequeue([ref]$task)) { Start-Sleep -Milliseconds 150; continue }
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
                'ask' {
                    # A plain question to Copilot, without project context or actions.
                    if ($task.newChat -or (Test-OtherSender)) { Start-NewChat $State }
                    $r = Send-ToCopilot $State $task.text
                    if ($r.Cancelled) { $job.cancelled = $true }
                    $job.reply = $r.Text; $job.result = $r.Result; $job.resultMessage = $r.ResultMessage; $job.uncertain = $r.Uncertain; $job.references = @($r.References)
                    $job.proposedActions = @($r.ProposedActions); $job.actionClaims = @($r.ActionClaims)
                    if ($r.Result -and $r.Result -ne 'Success') { $job.status = 'error'; $job.error = "Copilot answered with '$($r.Result)': $($r.ResultMessage)" }
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
            Add-AgentEvent $State 'error' @{ text = $_.Exception.Message }
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
