<#
.SYNOPSIS
  CCBridge MCP server (stdio). Lets an MCP client (Claude Code, VS Code, ...) offload work to
  Microsoft 365 Copilot Chat through the same bridge and agent loop as the CCBridge web app.
.DESCRIPTION
  Register it in your MCP client as:
    command: powershell.exe
    args:    -NoProfile -ExecutionPolicy Bypass -File <path>\mcp\ccbridge-mcp.ps1
  stdout carries JSON-RPC only; diagnostics go to stderr.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# Update before anything is loaded; the updater writes only to stderr.
if ($env:CCBRIDGE_NO_UPDATE -ne '1') { & (Join-Path $root 'tools\update.ps1') }

$utf8 = New-Object Text.UTF8Encoding($false)
$stdin = New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$stdout = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$stdout.NewLine = "`n"
$stdout.AutoFlush = $true

function Write-Log([string]$Message) { [Console]::Error.WriteLine("[ccbridge-mcp] $Message") }

Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force

Import-Module (Join-Path $root 'lib\Config.psm1') -Force
$config = Get-CCBridgeConfig harness $root
# Log level: $env:CCBRIDGE_LOG (set it in the MCP client's server config) or logLevel in harness.local.json.
Import-Module (Join-Path $root 'lib\Log.psm1')
Initialize-CCBLog -Config $config -Build (Format-CCBBuild (Get-CCBridgeBuild $root)) -Role 'MCP server'
$State = New-AgentState -Config $config -AppRoot $root
$State.LogLevel = Get-CCBLogLevel
$State.Headless = $true
$State.Mode = 'auto'

# --- Worker: the same agent loop the web app uses, in a background runspace -----------------
$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'STA'
$rs.Open()
$rs.SessionStateProxy.SetVariable('State', $State)
$worker = [powershell]::Create()
$worker.Runspace = $rs
$null = $worker.AddScript("`$ErrorActionPreference = 'Stop'; Import-Module '$(Join-Path $root 'lib\Agent.psm1')'; Start-AgentWorker -State `$State")
$workerHandle = $worker.BeginInvoke()

# --- Jobs --------------------------------------------------------------------------------------

function New-BridgeJob([string]$Kind, [hashtable]$Extra = @{}) {
    $id = 'job-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $job = [hashtable]::Synchronized(@{ id = $id; kind = $Kind; status = 'queued'; created = (Get-Date).ToString('s') })
    foreach ($k in $Extra.Keys) { $job[$k] = $Extra[$k] }
    $State.Jobs[$id] = $job
    $script:LastJobId = $id
    $job
}

function Get-JobOrThrow([string]$Id) {
    if (-not $Id) { $Id = $script:LastJobId }
    if (-not $Id -or -not $State.Jobs.ContainsKey($Id)) { throw "Unknown job '$Id'." }
    $State.Jobs[$Id]
}

function Test-JobActive {
    foreach ($j in $State.Jobs.Values) { if ($j.status -eq 'queued' -or $j.status -eq 'running') { return $j } }
    $null
}

function Wait-BridgeJob($Job, [int]$Seconds, [scriptblock]$Until) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ($Job.status -ne 'queued' -and $Job.status -ne 'running') { return }
        if ($Until -and (& $Until)) { return }
        Start-Sleep -Milliseconds 300
    }
}

function Get-JobEvents($Job) {
    $from = if ($null -ne $Job.startSeq) { [int]$Job.startSeq } else { [int]$Job.queuedSeq }
    $events = @(Get-AgentEvents $State $from)
    if ($null -ne $Job.endSeq) { $events = @($events | Where-Object { $_.seq -le $Job.endSeq }) }
    $events
}

function Get-JobActions($Events) {
    $order = New-Object System.Collections.Generic.List[string]
    $map = @{}
    foreach ($e in $Events) {
        if ($e.type -eq 'action') {
            if (-not $map.ContainsKey($e.id)) { $order.Add($e.id); $map[$e.id] = @{ id = $e.id; action = $e.action } }
            foreach ($k in 'target', 'status', 'preview', 'warning', 'error') { if ($null -ne $e.$k) { $map[$e.id][$k] = $e.$k } }
        } elseif ($e.type -eq 'action-result' -and $map.ContainsKey($e.id)) {
            foreach ($k in 'status', 'summary', 'output', 'reasons', 'next', 'code') { if ($null -ne $e.$k) { $map[$e.id][$k] = $e.$k } }
        }
    }
    @($order | ForEach-Object { $map[$_] })
}

# --- Unified diff for approvals ---------------------------------------------------------------

function Format-UnifiedDiff([string]$Path, [string]$Old, [string]$New, [int]$Context = 3) {
    $a = if ($Old) { $Old.Replace("`r`n", "`n").TrimEnd("`n").Split("`n") } else { @() }
    $b = if ($New) { $New.Replace("`r`n", "`n").TrimEnd("`n").Split("`n") } else { @() }
    if (-not $Old) { return "--- /dev/null`n+++ $Path (new file)`n" + (($b | ForEach-Object { "+$_" }) -join "`n") }
    $n = $a.Length; $m = $b.Length
    if ($n * $m -gt 4000000) { return "(file too large for a diff: $n -> $m lines)" }
    # LCS table as a flat array: cell (i, j) lives at i * w + j.
    $w = $m + 1
    $t = New-Object 'int[]' (($n + 1) * $w)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            if ($a[$i] -ceq $b[$j]) { $t[$i * $w + $j] = $t[($i + 1) * $w + $j + 1] + 1 }
            else {
                $down = $t[($i + 1) * $w + $j]; $right = $t[$i * $w + $j + 1]
                $t[$i * $w + $j] = if ($down -gt $right) { $down } else { $right }
            }
        }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $i = 0; $j = 0
    while ($i -lt $n -or $j -lt $m) {
        if ($i -lt $n -and $j -lt $m -and $a[$i] -ceq $b[$j]) { $rows.Add(@(' ', $a[$i])); $i++; $j++ }
        elseif ($i -lt $n -and ($j -ge $m -or $t[($i + 1) * $w + $j] -ge $t[$i * $w + $j + 1])) { $rows.Add(@('-', $a[$i])); $i++ }
        else { $rows.Add(@('+', $b[$j])); $j++ }
    }
    $keep = New-Object bool[] $rows.Count
    for ($k = 0; $k -lt $rows.Count; $k++) {
        if ($rows[$k][0] -ne ' ') { for ($q = [Math]::Max(0, $k - $Context); $q -le [Math]::Min($rows.Count - 1, $k + $Context); $q++) { $keep[$q] = $true } }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("--- $Path"); $out.Add("+++ $Path")
    $gap = $false
    for ($k = 0; $k -lt $rows.Count; $k++) {
        if ($keep[$k]) { if ($gap) { $out.Add('@@ ... @@') }; $gap = $false; $out.Add($rows[$k][0] + $rows[$k][1]) } else { $gap = $true }
    }
    $out -join "`n"
}

# --- Tool implementations --------------------------------------------------------------------

function Limit([string]$Text, [int]$Max) { if (-not $Text -or $Text.Length -le $Max) { return $Text }; $Text.Substring(0, $Max) + "`n...(truncated, $($Text.Length - $Max) more characters)" }

function Format-JobStatus($Job, [switch]$Full, $Events, $Info) {
    $events = if ($null -ne $Events) { @($Events) } else { Get-JobEvents $Job }
    if (-not $Info) { $Info = @{ workIq = $State.WorkIq; workIqActual = $State.WorkIqActual; throttle = $State.Throttle; credits = $State.Credits } }
    $sb = New-Object Text.StringBuilder
    $null = $sb.AppendLine("job: $($Job.id) ($($Job.kind)) status: $($Job.status)")
    if ($Job.project) { $null = $sb.AppendLine("project: $($Job.project)  mode: $($Job.mode)  commands allowed: $($Job.allowCommands)") }
    if ($Info.workIq -and $Info.workIq -ne 'leave') { $null = $sb.AppendLine("Work IQ: requested $($Info.workIq), actual $(if ($Info.workIqActual) { $Info.workIqActual } else { 'unknown' })") }
    $rounds = @($events | Where-Object { $_.type -eq 'assistant' }).Count
    $null = $sb.AppendLine("Copilot rounds: $rounds  chat messages: $($Info.throttle.used)/$($Info.throttle.max)")
    if ($Info.credits) { $null = $sb.AppendLine("Copilot credits left today: $($Info.credits.remaining)/$($Info.credits.total)") }
    if ($Job.error) { $null = $sb.AppendLine("error: $($Job.error)") }

    $todos = @($events | Where-Object { $_.type -eq 'todos' } | Select-Object -Last 1)
    if ($todos.Count) { $null = $sb.AppendLine("plan:"); foreach ($t in $todos[0].items) { $null = $sb.AppendLine("  [$(if ($t.done) { 'x' } else { ' ' })] $($t.text)") } }

    $actions = Get-JobActions $events
    if ($actions.Count) {
        $null = $sb.AppendLine('actions:')
        foreach ($a in $actions) {
            $line = "  [$($a.id)] $($a.action) $($a.target) -> $($a.status)"
            if ($a.summary) { $line += " ($($a.summary))" }
            if ($a.error) { $line += " error: $($a.error)" }
            if ($a.code) { $line += " [$($a.code)]" }
            $null = $sb.AppendLine($line)
            if ($a.reasons) { foreach ($r in @($a.reasons)) { $null = $sb.AppendLine("      possible reason: $r") } }
            if ($Full -and $a.output) { $null = $sb.AppendLine('      ' + ((Limit $a.output 1500) -replace "`n", "`n      ")) }
        }
    }
    $pending = @($actions | Where-Object { $_.status -eq 'awaiting' })
    foreach ($p in $pending) {
        $null = $sb.AppendLine("PENDING APPROVAL [$($p.id)] $($p.action) $($p.target) - call copilot_approve with job_id and action_id")
        if ($p.warning) { $null = $sb.AppendLine("  warning: $($p.warning)") }
        if ($p.preview) { $null = $sb.AppendLine((Limit (Format-UnifiedDiff $p.preview.path $p.preview.old $p.preview.new) 12000)) }
    }
    foreach ($e in $events) {
        if ($e.type -in 'error', 'status') { $null = $sb.AppendLine("$($e.type): $($e.text)") }
        if ($e.type -eq 'human-required') { $null = $sb.AppendLine("HUMAN REQUIRED: $($e.text)") }
    }
    $done = @($events | Where-Object { $_.type -eq 'done' } | Select-Object -Last 1)
    if ($done.Count) { $null = $sb.AppendLine("done: $($done[0].text)") }
    $changed = @($events | Where-Object { $_.type -eq 'checkpoint' } | ForEach-Object { $_.files }) | Select-Object -Unique
    if ($changed) { $null = $sb.AppendLine("files changed: $($changed -join ', ')  (copilot_undo reverts them)") }
    $refs = @($events | Where-Object { $_.type -eq 'assistant' } | ForEach-Object { $_.references })
    $src = Format-Sources $refs
    if ($src) { $null = $sb.AppendLine($src) }
    if ($Full) { $check = Format-CheckSection $events $actions; if ($check) { $null = $sb.AppendLine($check) } }
    if ($Full) {
        $last = @($events | Where-Object { $_.type -eq 'assistant' } | Select-Object -Last 1)
        if ($last.Count) { $null = $sb.AppendLine("last Copilot reply:`n" + (Limit $last[0].text 8000)) }
    }
    if ($Job.kind -eq 'ask' -and $Job.reply) { $null = $sb.AppendLine("reply:`n$($Job.reply)") }
    $sb.ToString().TrimEnd()
}

function Format-CheckSection($Events, $Actions) {
    <# What the calling model should verify itself: StreamHub has no model of its own and, for MCP
       tasks, does not ask Copilot to review its own work. Every change as a diff, the local check
       results, and everything that went wrong or needed repair. #>
    $out = New-Object System.Collections.Generic.List[string]
    $diffs = @($Events | Where-Object { $_.type -eq 'checkpoint' -and $_.contents } | ForEach-Object { @($_.contents) })
    foreach ($d in $diffs) {
        $head = if ($d.created) { ' (new file)' } elseif ($d.deleted) { ' (deleted)' } else { '' }
        $out.Add("diff $($d.path)${head}:")
        $out.Add((Limit (Format-UnifiedDiff $d.path $d.old $d.new) 20000))
    }
    $checks = @($Events | Where-Object { $_.type -eq 'status' -and $_.review -eq 'caller' } | Select-Object -Last 1)
    if ($checks.Count) { $out.Add($checks[0].text) }
    foreach ($a in @($Actions | Where-Object { $_.status -in 'error', 'failed', 'rejected', 'skipped' })) {
        $out.Add("not carried out: [$($a.id)] $($a.action) $($a.target) -> $($a.status)$(if ($a.summary) { " ($($a.summary))" })")
    }
    foreach ($a in @($Actions | Where-Object { "$($_.summary) $($_.output)" -match 'already (contains these changes|applied)' })) {
        $out.Add("reported as already applied (check the file really has it): [$($a.id)] $($a.action) $($a.target)")
    }
    if (@($Events | Where-Object { $_.type -eq 'assistant' -and $_.uncertain }).Count) {
        $out.Add('Some Copilot replies were repaired after its link filter removed text; check code with [name]: or [x](...) patterns.')
    }
    if (-not $out.Count) { return '' }
    "CHECK (StreamHub has no model of its own; review Copilot's work before relying on it - compare the diffs with the task and Copilot's done summary, then run the project's tests):`n" + ($out -join "`n")
}

function Set-WorkIqFromArgs($ToolArgs) {
    $v = Get-Arg $ToolArgs 'work_iq' $null
    if ($null -eq $v) { return }
    $State.WorkIq = if ([bool]$v) { 'on' } else { 'off' }
    $State.WorkIqWarned = $false
}

function Format-Sources($Refs) {
    $refs = @($Refs | Where-Object { $_ })
    if (-not $refs.Count) { return '' }
    "sources Copilot cited:`n" + (($refs | ForEach-Object { "  - $(if ($_.kind) { "[$($_.kind)] " })$($_.title)$(if ($_.url) { " <$($_.url)>" })" }) -join "`n")
}

function Get-Arg($ToolArgs, [string]$Name, $Default) {
    if ($ToolArgs -and $ToolArgs.PSObject.Properties[$Name] -and $null -ne $ToolArgs.$Name) { return $ToolArgs.$Name }
    $Default
}

# --- Through the web app ---------------------------------------------------------------------
# When the StreamHub web app is running, tasks go to its queue: they show up in the app (queue,
# chat, approvals) and only one program drives Copilot. Without the app, this server works alone.

function Get-WebApp {
    if ($env:CCBRIDGE_MCP_STANDALONE -eq '1') { return $null }
    try {
        $tokenFile = Join-Path $env:LOCALAPPDATA 'CCBridge\session-token.txt'
        if (-not (Test-Path $tokenFile)) { return $null }
        $token = ([IO.File]::ReadAllText($tokenFile)).Trim()
        $port = [int](Get-CCBridgeConfig harness $root).port
        $base = "http://localhost:$port"
        $null = Invoke-RestMethod "$base/api/queue" -Headers @{ 'X-CCB-Token' = $token } -TimeoutSec 2
        @{ base = $base; token = $token }
    } catch { $null }
}

function Invoke-App($App, [string]$Method, [string]$Path, $Body) {
    $p = @{ Method = $Method; Uri = "$($App.base)$Path"; Headers = @{ 'X-CCB-Token' = $App.token }; TimeoutSec = 20 }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 6 -Compress); $p.ContentType = 'application/json' }
    try { Invoke-RestMethod @p }
    catch {
        $msg = $_.Exception.Message
        try { $d = $_.ErrorDetails.Message | ConvertFrom-Json; if ($d.error) { $msg = "$($d.error)$(if ($d.errId) { " (error $($d.errId))" })" } } catch { }
        throw $msg
    }
}

function Get-AppJob($App, [string]$Id) {
    if (-not $Id) { $Id = $script:LastJobId }
    if (-not $Id) { throw 'No job yet; start one first.' }
    Invoke-App $App GET "/api/jobs/$Id"
}

function Wait-AppJob($App, [string]$Id, [int]$Seconds, [switch]$UntilApproval) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $r = Get-AppJob $App $Id
    while ((Get-Date) -lt $deadline -and $r.job.status -in 'queued', 'running') {
        if ($UntilApproval -and @(Get-JobActions $r.events | Where-Object { $_.status -eq 'awaiting' }).Count) { break }
        Start-Sleep -Milliseconds 600
        $r = Get-AppJob $App $Id
    }
    $r
}

function Format-AppJob($R, [switch]$Full) {
    $note = "(running in the StreamHub app: it shows in the app's queue and chat, where the user can follow, approve or stop it)"
    (Format-JobStatus $R.job -Full:$Full -Events @($R.events) -Info $R.info) + "`n$note"
}

function Format-ReviewResult([string]$JsonPath, [string]$Report) {
    <# The checked findings for the calling model: verified and general ones in full, unverified
       ones counted. #>
    if (-not $JsonPath -or -not (Test-Path -LiteralPath $JsonPath)) { return 'The review finished without a report.' }
    $rv = [IO.File]::ReadAllText($JsonPath) | ConvertFrom-Json
    $ok = @($rv.findings | Where-Object { $_.status -ne 'unverified' })
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("Code review of $(@($rv.files).Count) file(s) ($($rv.scopeText)), $($rv.messages) Copilot message(s). Report: $Report")
    if ($rv.overall) { [void]$sb.AppendLine("Overall: $($rv.overall)") }
    [void]$sb.AppendLine("$($ok.Count) finding(s); each quotes code that StreamHub found in the file ('general' ones are about the whole project). Check them before acting on them.")
    foreach ($f in $ok) {
        [void]$sb.AppendLine("[$($f.id)] $($f.severity) $($f.category) $(if ($f.file) { "$($f.file):$($f.line)" } else { '(project)' }) - $($f.title)")
        if ($f.detail) { [void]$sb.AppendLine("    $($f.detail)") }
        if ($f.suggestion) { [void]$sb.AppendLine("    fix: $($f.suggestion)") }
    }
    $bad = @($rv.findings).Count - $ok.Count
    if ($bad) { [void]$sb.AppendLine("$bad more finding(s) quoted code that is not in the file and were left out.") }
    Limit $sb.ToString().TrimEnd() 30000
}

function Invoke-RemoteTool([string]$Name, $ToolArgs, $App) {
    $wiq = Get-Arg $ToolArgs 'work_iq' $null
    switch ($Name) {
        'copilot_ask' {
            $prompt = [string](Get-Arg $ToolArgs 'prompt' '')
            if (-not $prompt.Trim()) { throw 'prompt is required' }
            $s = Invoke-App $App POST '/api/jobs' @{ kind = 'ask'; text = $prompt; newChat = [bool](Get-Arg $ToolArgs 'new_chat' $false); workIq = $wiq; thinkDeeper = [bool](Get-Arg $ToolArgs 'think_deeper' $false); source = 'mcp' }
            $script:LastJobId = $s.job.id
            $r = Wait-AppJob $App $s.job.id ([int](Get-Arg $ToolArgs 'timeout_sec' 240))
            $j = $r.job
            if ($j.status -eq 'finished') {
                $note = if ($j.uncertain) { "`n`n(StreamHub note: parts of this reply were repaired after Copilot's link filter removed text; check code carefully.)" } else { '' }
                if (@($j.proposedActions).Count) { $note += "`n`nHUMAN REQUIRED: Copilot proposed a Microsoft 365 action (" + ((@($j.proposedActions) | ForEach-Object { $_.title }) -join '; ') + "). StreamHub never confirms it; the user must review it in the Copilot window." }
                foreach ($c in @($j.actionClaims)) { if ($c) { $note += "`n`nHUMAN CHECK: Copilot's reply says ""$c"" - StreamHub confirmed no Microsoft 365 action." } }
                $src = Format-Sources $j.references
                return @{ text = "$($j.reply)$note$(if ($src) { "`n`n$src" })" }
            }
            if ($j.status -eq 'error') { return @{ text = "Copilot error: $($j.error)"; isError = $true } }
            return @{ text = "Copilot has not answered yet; $($j.id) is $($j.status) in the StreamHub app's queue. Poll it with copilot_task_status." }
        }
        'copilot_start_task' {
            $path = [string](Get-Arg $ToolArgs 'project_path' '')
            $task = [string](Get-Arg $ToolArgs 'task' '')
            if (-not $path -or -not [IO.Path]::IsPathRooted($path)) { throw 'project_path must be an absolute folder path' }
            if (-not $task.Trim()) { throw 'task is required' }
            $mode = [string](Get-Arg $ToolArgs 'mode' 'auto')
            $allow = [bool](Get-Arg $ToolArgs 'allow_commands' $false)
            $s = Invoke-App $App POST '/api/jobs' @{ kind = 'task'; text = $task; projectPath = $path; mode = $mode; allowCommands = $allow; newChat = [bool](Get-Arg $ToolArgs 'new_chat' $false); copilotReview = [bool](Get-Arg $ToolArgs 'copilot_review' $false); workIq = $wiq; thinkDeeper = [bool](Get-Arg $ToolArgs 'think_deeper' $false); source = 'mcp' }
            $script:LastJobId = $s.job.id
            return @{ text = "Queued $($s.job.id) in the StreamHub app for $($s.job.project) (mode $mode, commands $(if ($allow) { 'allowed' } else { 'not allowed' })). The user sees it in the app's queue and chat.`nPoll with copilot_task_status; get the full report with copilot_task_result." }
        }
        'copilot_run_task' {
            $null = Invoke-RemoteTool 'copilot_start_task' $ToolArgs $App
            $wait = [Math]::Min(1800, [Math]::Max(10, [int](Get-Arg $ToolArgs 'wait_sec' 600)))
            $r = Wait-AppJob $App $script:LastJobId $wait -UntilApproval
            if ($r.job.status -in 'queued', 'running') {
                return @{ text = "Copilot is still working on $($r.job.id) (or waits for an approval, or for earlier tasks in the app's queue). Call copilot_task_status with job_id $($r.job.id) until it is finished.`n`n" + (Format-AppJob $r) }
            }
            return @{ text = "Task $($r.job.status).`n`n" + (Format-AppJob $r -Full); isError = ($r.job.status -eq 'error') }
        }
        'copilot_task_status' {
            $id = [string](Get-Arg $ToolArgs 'job_id' '')
            $wait = [Math]::Min(120, [Math]::Max(0, [int](Get-Arg $ToolArgs 'wait_sec' 20)))
            $r = Wait-AppJob $App $id $wait -UntilApproval
            return @{ text = (Format-AppJob $r) }
        }
        'copilot_task_result' {
            $r = Get-AppJob $App ([string](Get-Arg $ToolArgs 'job_id' ''))
            if ($r.job.reviewPath) { return @{ text = (Format-ReviewResult $r.job.reviewPath $r.job.reviewReport) } }
            return @{ text = (Format-AppJob $r -Full) }
        }
        'copilot_approve' {
            $r = Get-AppJob $App ([string](Get-Arg $ToolArgs 'job_id' ''))
            $actionId = [string](Get-Arg $ToolArgs 'action_id' '')
            $decision = [string](Get-Arg $ToolArgs 'decision' '')
            if (@('approve', 'reject') -notcontains $decision) { throw 'decision must be approve or reject' }
            $pending = @(Get-JobActions $r.events | Where-Object { $_.status -eq 'awaiting' } | ForEach-Object { $_.id })
            if ($pending -notcontains $actionId) { throw "Action '$actionId' is not waiting for approval. Pending: $(if ($pending) { $pending -join ', ' } else { 'none' })" }
            $null = Invoke-App $App POST '/api/approve' @{ id = $actionId; decision = $decision; note = [string](Get-Arg $ToolArgs 'note' ''); by = 'mcp' }
            return @{ text = "$decision sent for $actionId. Microsoft 365 actions and deleting data can only be approved by the user in the StreamHub app. Poll copilot_task_status for progress." }
        }
        'copilot_cancel_task' {
            $r = Get-AppJob $App ([string](Get-Arg $ToolArgs 'job_id' ''))
            if ($r.job.status -notin 'running', 'queued') { return @{ text = "$($r.job.id) is already $($r.job.status)." } }
            $null = Invoke-App $App POST '/api/queue/cancel' @{ id = $r.job.id }
            $r = Wait-AppJob $App $r.job.id 60
            return @{ text = "Cancel requested; $($r.job.id) is now $($r.job.status). Files already changed stay changed (copilot_undo reverts them)." }
        }
        'copilot_review' {
            $path = [string](Get-Arg $ToolArgs 'project_path' '')
            $s = Invoke-App $App POST '/api/jobs' @{ kind = 'review'; projectPath = $path; paths = @(Get-Arg $ToolArgs 'paths' @()); focus = @(Get-Arg $ToolArgs 'focus' @()); source = 'mcp' }
            $script:LastJobId = $s.job.id
            $r = Wait-AppJob $App $s.job.id ([Math]::Min(3600, [Math]::Max(30, [int](Get-Arg $ToolArgs 'wait_sec' 1200))))
            if ($r.job.status -in 'queued', 'running') { return @{ text = "The review is still running as $($r.job.id) in the StreamHub app's queue (a large review takes many Copilot messages and may wait for the daily limit). Call copilot_task_result with job_id $($r.job.id) later." } }
            if ($r.job.reviewPath) { return @{ text = (Format-ReviewResult $r.job.reviewPath $r.job.reviewReport) } }
            return @{ text = "Review $($r.job.status).`n`n" + (Format-AppJob $r); isError = $true }
        }
        'copilot_new_chat' {
            $s = Invoke-App $App POST '/api/jobs' @{ kind = 'newchat'; source = 'mcp' }
            $r = Wait-AppJob $App $s.job.id 60
            return @{ text = "New Copilot chat: $($r.job.status)$(if ($r.job.error) { " - $($r.job.error)" })" }
        }
        'copilot_undo' {
            $path = [string](Get-Arg $ToolArgs 'project_path' '')
            $s = Invoke-App $App POST '/api/jobs' @{ kind = 'undo'; projectPath = $path; source = 'mcp' }
            $r = Wait-AppJob $App $s.job.id 60
            $undo = @($r.events | Where-Object { $_.type -eq 'undo' } | Select-Object -Last 1)
            return @{ text = $(if ($undo.Count) { $undo[0].text } else { "Undo: $($r.job.status) $($r.job.error)" }) }
        }
    }
    throw "Unknown tool '$Name'"
}

function Invoke-Tool([string]$Name, $ToolArgs) {
    $app = Get-WebApp
    if ($app) { Write-CCBLog verbose mcp "$Name through the web app"; return Invoke-RemoteTool $Name $ToolArgs $app }
    switch ($Name) {
        'copilot_ask' {
            $prompt = [string](Get-Arg $ToolArgs 'prompt' '')
            if (-not $prompt.Trim()) { throw 'prompt is required' }
            $active = Test-JobActive
            if ($active) { throw "Copilot is busy with $($active.id) ($($active.kind)); wait for it or cancel it first." }
            Set-WorkIqFromArgs $ToolArgs
            $job = New-BridgeJob 'ask'
            $job.queuedSeq = $State.Seq
            $State.Tasks.Enqueue(@{ kind = 'ask'; jobId = $job.id; text = $prompt; newChat = [bool](Get-Arg $ToolArgs 'new_chat' $false); responseMode = $(if ([bool](Get-Arg $ToolArgs 'think_deeper' $false)) { 'deep' } else { $null }) })
            Wait-BridgeJob $job ([int](Get-Arg $ToolArgs 'timeout_sec' 240))
            if ($job.status -eq 'finished') {
                $note = if ($job.uncertain) { "`n`n(StreamHub note: parts of this reply were repaired after Copilot's link filter removed text; check code carefully.)" } else { '' }
                $src = Format-Sources $job.references
                if (@($job.proposedActions).Count) { $note += "`n`nHUMAN REQUIRED: Copilot proposed a Microsoft 365 action (" + ((@($job.proposedActions) | ForEach-Object { $_.title }) -join '; ') + "). CCBridge never confirms it; the user must review it in the Copilot window." }
                foreach ($c in @($job.actionClaims)) { $note += "`n`nHUMAN CHECK: Copilot's reply says ""$c"" - StreamHub confirmed no Microsoft 365 action." }
                return @{ text = "$($job.reply)$note$(if ($src) { "`n`n$src" })" }
            }
            if ($job.status -eq 'error') { return @{ text = "Copilot error: $($job.error)"; isError = $true } }
            return @{ text = "Copilot has not finished yet. Job $($job.id) keeps running; poll it with copilot_task_status." }
        }
        'copilot_start_task' {
            $path = [string](Get-Arg $ToolArgs 'project_path' '')
            $task = [string](Get-Arg $ToolArgs 'task' '')
            if (-not $path -or -not [IO.Path]::IsPathRooted($path)) { throw 'project_path must be an absolute folder path' }
            if (-not $task.Trim()) { throw 'task is required' }
            $mode = [string](Get-Arg $ToolArgs 'mode' 'auto')
            if (@('auto', 'plan', 'ask') -notcontains $mode) { throw "mode must be auto, plan or ask" }
            $active = Test-JobActive
            if ($active) { throw "Copilot is busy with $($active.id) ($($active.kind)); wait for it or cancel it first." }
            $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
            if (-not (Test-Path -LiteralPath $full)) { $null = New-Item -ItemType Directory -Path $full }
            $allow = [bool](Get-Arg $ToolArgs 'allow_commands' $false)
            Set-WorkIqFromArgs $ToolArgs
            $State.Mode = $mode
            $State.AllowCommands = $allow
            $State.Busy = $true
            $job = New-BridgeJob 'task' @{ project = $full; mode = $mode; allowCommands = $allow; task = $task }
            $job.queuedSeq = $State.Seq
            $State.Tasks.Enqueue(@{ kind = 'chat'; forceKind = 'work'; jobId = $job.id; text = $task; projectRoot = $full; newChat = [bool](Get-Arg $ToolArgs 'new_chat' $false); reviewByCaller = (-not [bool](Get-Arg $ToolArgs 'copilot_review' $false)); responseMode = $(if ([bool](Get-Arg $ToolArgs 'think_deeper' $false)) { 'deep' } else { $null }) })
            Wait-BridgeJob $job 3
            return @{ text = "Started $($job.id) in $full (mode $mode, commands $(if ($allow) { 'allowed' } else { 'not allowed' })).`nPoll with copilot_task_status (it waits up to wait_sec for progress); get the full report with copilot_task_result." }
        }
        'copilot_run_task' {
            # One call for the whole task: start, wait until finished, return the full report.
            $null = Invoke-Tool 'copilot_start_task' $ToolArgs
            $job = Get-JobOrThrow ''
            $wait = [Math]::Min(1800, [Math]::Max(10, [int](Get-Arg $ToolArgs 'wait_sec' 600)))
            $from = [int]$job.queuedSeq
            Wait-BridgeJob $job $wait { @(Get-AgentEvents $State $from | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' }).Count -gt 0 }
            if ($job.status -eq 'queued' -or $job.status -eq 'running') {
                return @{ text = "Copilot is still working on $($job.id) (or waits for an approval). Call copilot_task_status with job_id $($job.id) until it is finished.`n`n" + (Format-JobStatus $job) }
            }
            return @{ text = "Task $($job.status).`n`n" + (Format-JobStatus $job -Full); isError = ($job.status -eq 'error') }
        }
        'copilot_task_status' {
            $job = Get-JobOrThrow ([string](Get-Arg $ToolArgs 'job_id' ''))
            $wait = [Math]::Min(120, [Math]::Max(0, [int](Get-Arg $ToolArgs 'wait_sec' 20)))
            $seq = $State.Seq
            # Return early on a new approval request or when the job ends.
            Wait-BridgeJob $job $wait { @(Get-AgentEvents $State $seq | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' }).Count -gt 0 }
            return @{ text = (Format-JobStatus $job) }
        }
        'copilot_task_result' {
            $job = Get-JobOrThrow ([string](Get-Arg $ToolArgs 'job_id' ''))
            if ($job.reviewPath) { return @{ text = (Format-ReviewResult $job.reviewPath $job.reviewReport) } }
            return @{ text = (Format-JobStatus $job -Full) }
        }
        'copilot_approve' {
            $job = Get-JobOrThrow ([string](Get-Arg $ToolArgs 'job_id' ''))
            $actionId = [string](Get-Arg $ToolArgs 'action_id' '')
            $decision = [string](Get-Arg $ToolArgs 'decision' '')
            if (@('approve', 'reject') -notcontains $decision) { throw 'decision must be approve or reject' }
            $pending = @(Get-JobActions (Get-JobEvents $job) | Where-Object { $_.status -eq 'awaiting' } | ForEach-Object { $_.id })
            if ($pending -notcontains $actionId) { throw "Action '$actionId' is not waiting for approval. Pending: $(if ($pending) { $pending -join ', ' } else { 'none' })" }
            $State.Approvals[$actionId] = @{ decision = $decision; note = [string](Get-Arg $ToolArgs 'note' ''); by = 'mcp' }
            return @{ text = "$decision sent for $actionId. Poll copilot_task_status for progress." }
        }
        'copilot_cancel_task' {
            $job = Get-JobOrThrow ([string](Get-Arg $ToolArgs 'job_id' ''))
            if ($job.status -ne 'running' -and $job.status -ne 'queued') { return @{ text = "$($job.id) is already $($job.status)." } }
            $job.cancelled = $true
            $State.Cancel = $true
            Wait-BridgeJob $job 60
            return @{ text = "Cancel requested; $($job.id) is now $($job.status). Copilot finishes its current reply first; files already changed stay changed (copilot_undo reverts them)." }
        }
        'copilot_review' {
            $path = [string](Get-Arg $ToolArgs 'project_path' '')
            if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { throw 'project_path must be an existing folder' }
            $active = Test-JobActive
            if ($active) { throw "Copilot is busy with $($active.id); wait for it or cancel it first." }
            $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
            $paths = @(Get-Arg $ToolArgs 'paths' @() | Where-Object { $_ })
            $job = New-BridgeJob 'review' @{ project = $full }
            $job.queuedSeq = $State.Seq
            $State.Tasks.Enqueue(@{ kind = 'review'; jobId = $job.id; projectRoot = $full; scope = $(if ($paths.Count) { 'paths' } else { 'all' }); paths = $paths; focus = @(Get-Arg $ToolArgs 'focus' @()); reviewId = 'review-' + (Get-Date).ToString('yyyyMMdd-HHmmss'); source = 'mcp' })
            Wait-BridgeJob $job ([Math]::Min(3600, [Math]::Max(30, [int](Get-Arg $ToolArgs 'wait_sec' 1200))))
            if ($job.status -in 'queued', 'running') { return @{ text = "The review is still running as $($job.id). Call copilot_task_result with job_id $($job.id) later." } }
            if ($job.reviewPath) { return @{ text = (Format-ReviewResult $job.reviewPath $job.reviewReport) } }
            return @{ text = "Review $($job.status).`n`n" + (Format-JobStatus $job -Full); isError = $true }
        }
        'copilot_new_chat' {
            $active = Test-JobActive
            if ($active) { throw "Copilot is busy with $($active.id); wait for it or cancel it first." }
            $job = New-BridgeJob 'newchat'
            $State.Tasks.Enqueue(@{ kind = 'newchat'; jobId = $job.id })
            Wait-BridgeJob $job 60
            return @{ text = "New Copilot chat: $($job.status)$(if ($job.error) { " - $($job.error)" })" }
        }
        'copilot_undo' {
            $path = [string](Get-Arg $ToolArgs 'project_path' '')
            if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { throw 'project_path must be an existing folder' }
            $active = Test-JobActive
            if ($active) { throw "Copilot is busy with $($active.id); wait for it or cancel it first." }
            $State.ProjectRoot = [IO.Path]::GetFullPath($path).TrimEnd('\')
            $job = New-BridgeJob 'undo'
            $job.queuedSeq = $State.Seq
            $State.Tasks.Enqueue(@{ kind = 'undo'; jobId = $job.id })
            Wait-BridgeJob $job 60
            $undo = @(Get-JobEvents $job | Where-Object { $_.type -eq 'undo' } | Select-Object -Last 1)
            return @{ text = $(if ($undo.Count) { $undo[0].text } else { "Undo: $($job.status) $($job.error)" }) }
        }
    }
    throw "Unknown tool '$Name'"
}

# --- Tool catalog ----------------------------------------------------------------------------

$tools = @(
    @{ name = 'copilot_run_task'
       description = 'USE THIS for any coding task that needs thinking: more than a small, clear edit in one file, a bug you do not immediately understand, a new feature, a design, changes across several files, unfamiliar libraries or APIs. A stronger model (Microsoft 365 Copilot) does the whole task in the project folder (reads, edits, optionally builds and tests) and this call returns the full report when it is done. One call is enough; it waits up to wait_sec (default 600).'
       inputSchema = @{ type = 'object'; required = @('project_path', 'task'); properties = @{
           project_path = @{ type = 'string'; description = 'Absolute path of the project folder (created if missing).' }
           task = @{ type = 'string'; description = 'What to build, fix or change, in plain words: the goal, which files if known, how to check that it works.' }
           mode = @{ type = 'string'; enum = @('auto', 'plan', 'ask'); description = 'auto: Copilot changes files directly (default). plan: Copilot only reads and proposes. ask: every change waits for copilot_approve.' }
           allow_commands = @{ type = 'boolean'; description = 'true lets Copilot run commands such as builds and tests in the project folder. Default false.' }
           new_chat = @{ type = 'boolean'; description = 'Start a fresh Copilot conversation (default false; a different project always starts fresh).' }
           work_iq = @{ type = 'boolean'; description = 'true: Copilot may use the user''s Microsoft 365 data (Outlook mail, Teams chats and meetings, calendar, OneDrive/SharePoint files). Omit to keep the current setting.' }
           think_deeper = @{ type = 'boolean'; description = 'true: use Copilot''s Think deeper mode for this request (slower, for hard problems). Default: the app''s setting.' }
           wait_sec = @{ type = 'integer'; description = 'How long to wait for the result (default 600, max 1800). If it is not finished by then, call copilot_task_status.' }
           copilot_review = @{ type = 'boolean'; description = 'true: after big changes Copilot also reviews its own work (costs extra Copilot messages). Default false: you review the diffs in the report yourself.' } } } }
    @{ name = 'copilot_ask'
       description = 'USE THIS for any question that needs reasoning: explaining code or an error, finding a root cause, reviewing code, choosing an approach, making a plan, writing longer text, or (with work_iq) looking things up in the user''s email, calendar, Teams chats and files. Copilot sees only the prompt, so paste the code or error you ask about. Returns Copilot''s answer. No files are changed.'
       inputSchema = @{ type = 'object'; required = @('prompt'); properties = @{
           prompt = @{ type = 'string'; description = 'The full prompt. Copilot sees nothing else, so include any code or context it needs (up to about 75,000 characters).' }
           new_chat = @{ type = 'boolean'; description = 'Start a fresh Copilot conversation first (default false: continue the current one).' }
           work_iq = @{ type = 'boolean'; description = 'Turn Work IQ on (true: Copilot may use the user''s Microsoft 365 data - Outlook mail, Teams chats and meetings, calendar, OneDrive/SharePoint files, people) or off (false). Omit to keep the current setting.' }
           think_deeper = @{ type = 'boolean'; description = 'true: use Copilot''s Think deeper mode for this request (slower, for hard problems). Default: the app''s setting.' }
           timeout_sec = @{ type = 'integer'; description = 'Seconds to wait for the reply (default 240).' } } } }
    @{ name = 'copilot_start_task'
       description = 'Like copilot_run_task, but returns at once with a job id; then call copilot_task_status until it is finished. Use copilot_run_task instead unless you want to do other work meanwhile. Safety: paths stay inside the project, Source/ is read-only user data, every task is one undoable change set.'
       inputSchema = @{ type = 'object'; required = @('project_path', 'task'); properties = @{
           project_path = @{ type = 'string'; description = 'Absolute path of the project folder (created if missing).' }
           task = @{ type = 'string'; description = 'What to build or change, with acceptance criteria and how to verify.' }
           mode = @{ type = 'string'; enum = @('auto', 'plan', 'ask'); description = 'auto: apply changes directly (default). plan: read-only, Copilot only proposes. ask: every change/command waits for copilot_approve.' }
           allow_commands = @{ type = 'boolean'; description = 'Allow Copilot to run shell commands (cmd.exe) in the project folder, e.g. builds and tests. Default false.' }
           new_chat = @{ type = 'boolean'; description = 'Start a fresh Copilot conversation (default false; a different project always starts fresh).' }
           copilot_review = @{ type = 'boolean'; description = 'true: after big changes Copilot also reviews its own work (costs extra Copilot messages). Default false: you review the diffs in the report yourself.' }
           work_iq = @{ type = 'boolean'; description = 'Turn Work IQ on (true: Copilot may use the user''s Microsoft 365 data - Outlook mail, Teams chats and meetings, calendar, OneDrive/SharePoint files, people) or off (false). Omit to keep the current setting.' }
           think_deeper = @{ type = 'boolean'; description = 'true: use Copilot''s Think deeper mode for this request (slower, for hard problems). Default: the app''s setting.' } } } }
    @{ name = 'copilot_review'
       description = 'Full code review by Copilot of a project folder (or chosen files/folders), read-only: the code goes to Copilot in batches, every finding must quote real lines from the file (findings that do not are left out), plus one pass across the whole project. Returns the checked findings with severity, file:line, problem and suggested fix; also saved as reviews/review-<date>.md in the project. Large projects take many Copilot messages. Review the findings yourself before fixing them.'
       inputSchema = @{ type = 'object'; required = @('project_path'); properties = @{
           project_path = @{ type = 'string'; description = 'Absolute path of the project folder.' }
           paths = @{ type = 'array'; items = @{ type = 'string' }; description = 'Only these files or folders (relative to the project). Default: the whole project.' }
           focus = @{ type = 'array'; items = @{ type = 'string' }; description = 'What to look for, e.g. bugs, security, performance, structure, readability, tests. Default: bugs, security, performance, structure.' }
           wait_sec = @{ type = 'integer'; description = 'How long to wait for the review (default 1200, max 3600). If it is not finished, call copilot_task_result later.' } } } }
    @{ name = 'copilot_task_status'
       description = 'Progress of a job: status, Copilot''s plan, actions so far, pending approvals with diffs, errors. Waits up to wait_sec for the job to finish or to need an approval, so you can poll without busy-looping.'
       inputSchema = @{ type = 'object'; properties = @{
           job_id = @{ type = 'string'; description = 'Job id (default: the most recent job).' }
           wait_sec = @{ type = 'integer'; description = 'Long-poll up to this many seconds (default 20, max 120).' } } } }
    @{ name = 'copilot_task_result'
       description = 'Full report of a job: every action with its output, files changed, the done summary and Copilot''s last reply.'
       inputSchema = @{ type = 'object'; properties = @{ job_id = @{ type = 'string'; description = 'Job id (default: the most recent job).' } } } }
    @{ name = 'copilot_approve'
       description = 'Approve or reject a pending action of a job in ask mode (see PENDING APPROVAL in copilot_task_status).'
       inputSchema = @{ type = 'object'; required = @('job_id', 'action_id', 'decision'); properties = @{
           job_id = @{ type = 'string' }
           action_id = @{ type = 'string' }
           decision = @{ type = 'string'; enum = @('approve', 'reject') }
           note = @{ type = 'string'; description = 'Optional note for Copilot, e.g. why it was rejected.' } } } }
    @{ name = 'copilot_cancel_task'
       description = 'Stop a running job after Copilot''s current reply. Changes already made stay; use copilot_undo to revert them.'
       inputSchema = @{ type = 'object'; properties = @{ job_id = @{ type = 'string'; description = 'Job id (default: the most recent job).' } } } }
    @{ name = 'copilot_new_chat'
       description = 'Start a fresh Copilot conversation (for example when switching topics).'
       inputSchema = @{ type = 'object'; properties = @{} } }
    @{ name = 'copilot_undo'
       description = 'Revert the most recent change set (one task) in a project folder: restores edited files and deletes files the task created.'
       inputSchema = @{ type = 'object'; required = @('project_path'); properties = @{ project_path = @{ type = 'string'; description = 'Absolute project folder path.' } } } }
)

# --- JSON-RPC loop ---------------------------------------------------------------------------

function Send-Message($Object) { $stdout.WriteLine((ConvertTo-Json -InputObject $Object -Depth 30 -Compress)) }
function Send-Result($Id, $Result) { Send-Message @{ jsonrpc = '2.0'; id = $Id; result = $Result } }
function Send-Error($Id, [int]$Code, [string]$Message) { Send-Message @{ jsonrpc = '2.0'; id = $Id; error = @{ code = $Code; message = $Message } } }

$instructions = @"
This server lets you hand work to a stronger model: Microsoft 365 Copilot (in the user's Edge browser).

WHEN TO USE IT. Do it yourself only when the task is small and clear: one file, a few lines, and you know exactly what to change. Use Copilot for everything else:
- copilot_run_task: any coding task that needs thinking (a bug you do not understand, a new feature, several files, a design, unfamiliar libraries). One call; it returns the full report when done.
- copilot_ask: any question that needs reasoning (explain code or an error, find a root cause, review, plan, choose an approach, write longer text). Paste the code or error into the prompt.
- With work_iq=true Copilot can also use the user's Outlook mail, Teams chats and meetings, calendar and OneDrive/SharePoint files (only read; it never sends or deletes anything).

HOW. Give Copilot the whole task in plain words: the goal, the files if you know them, and how to check the result. Set allow_commands=true when Copilot should build or run tests. Copilot takes tens of seconds per step and has a daily limit, so send complete tasks, not tiny steps.

CHECK EVERYTHING THAT COMES BACK. The program in between has no model of its own, so you are the reviewer. Compare Copilot's answers with what you know. For tasks, read the CHECK section of the report (every change as a diff, local check results, actions that failed or were reported as already applied), compare it with the task, and run the tests. Fix small mistakes yourself or send a follow-up task; copilot_undo reverts the last task.
"@

Write-Log "started (pid $PID), app root $root, log $(Get-CCBLogDir) (level $(Get-CCBLogLevel))"
Write-CCBLog info mcp 'MCP server started' (Get-CCBridgeEnvironment $root)
try {
    while ($true) {
        $line = $stdin.ReadLine()
        if ($null -eq $line) { break }
        if (-not $line.Trim()) { continue }
        try { $msg = $line | ConvertFrom-Json } catch { Send-Error $null -32700 'Parse error'; continue }
        $hasId = $msg.PSObject.Properties['id'] -ne $null
        $id = if ($hasId) { $msg.id } else { $null }
        if (-not $msg.method) { continue }   # a response to us; we send no requests
        try {
            if ($msg.method -ne 'tools/call') { Write-CCBLog verbose mcp "request $($msg.method)" }
            switch ($msg.method) {
                'initialize' {
                    $pv = if ($msg.params -and $msg.params.protocolVersion) { [string]$msg.params.protocolVersion } else { '2025-06-18' }
                    Send-Result $id @{
                        protocolVersion = $pv
                        capabilities = @{ tools = @{ listChanged = $false } }
                        serverInfo = @{ name = 'ccbridge'; version = '0.1.0' }
                        instructions = $instructions
                    }
                }
                'ping' { Send-Result $id @{} }
                'tools/list' { Send-Result $id @{ tools = $tools } }
                'tools/call' {
                    $name = [string]$msg.params.name
                    $toolWatch = [Diagnostics.Stopwatch]::StartNew()
                    Write-CCBLog verbose mcp "tool $name called" @{ arguments = @($msg.params.arguments.PSObject.Properties | ForEach-Object { $_.Name }) }
                    Write-CCBLog trace mcp "tool $name arguments" $msg.params.arguments
                    try {
                        $r = Invoke-Tool $name $msg.params.arguments
                        Write-CCBLog verbose mcp "tool $name done ($($toolWatch.ElapsedMilliseconds) ms)" @{ isError = [bool]$r.isError; chars = "$($r.text)".Length }
                        Send-Result $id @{ content = @(@{ type = 'text'; text = [string]$r.text }); isError = [bool]$r.isError }
                    } catch {
                        Write-CCBLogError mcp "tool $name" $_
                        Write-Log "tool $name failed: $($_.Exception.Message)"
                        Send-Result $id @{ content = @(@{ type = 'text'; text = "Error: $($_.Exception.Message)" }); isError = $true }
                    }
                }
                'resources/list' { Send-Result $id @{ resources = @() } }
                'prompts/list' { Send-Result $id @{ prompts = @() } }
                default {
                    if ($hasId) { Send-Error $id -32601 "Method not found: $($msg.method)" }
                }
            }
        } catch {
            Write-Log "request failed: $($_.Exception.Message)"
            if ($hasId) { Send-Error $id -32603 $_.Exception.Message }
        }
    }
} finally {
    $State.Stop = $true
    if ($workerHandle.AsyncWaitHandle.WaitOne(5000)) { $null = $worker.EndInvoke($workerHandle) }
    $worker.Dispose(); $rs.Dispose()
    Write-Log 'stopped'
}
