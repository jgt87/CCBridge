<#
.SYNOPSIS
  Sends a ladder of prompts, from simple to complex, to Microsoft 365 Copilot (each in a fresh chat)
  and reports per step how Copilot responded (answered, blocked, no answer, out of credits) and how
  fast: the exact time (HH:mm:ss.fff, +ms after Send) of each step of the reply, the route it came
  by (StreamHub, Chathub or the page) and how long CCBridge waited after Copilot had finished.
  Use it to find where (if anywhere) Copilot starts to fail or refuse, and where time is lost.
.DESCRIPTION
  Every step costs one Copilot message. The report (text + JSON in a new folder C:\temp\CCBridge-test-<date>, see -OutRoot) contains no
  Microsoft 365 data: for the Microsoft 365 steps only codes, sizes and timings are kept.
.PARAMETER From
  First step to run (default 1).
.PARAMETER To
  Last step to run (default 19, the last step).
.PARAMETER StepTimeoutSec
  Longest wait for one reply (default 300).
.EXAMPLE
  complexity-test.cmd
  complexity-test.cmd -From 5 -To 9
#>
param([int]$From = 1, [int]$To = 19, [int]$StepTimeoutSec = 300, [int]$PauseSec = 3, [int]$PageCheckMs = 200, [string]$OutRoot = 'C:\temp')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Log', 'Config', 'CopilotBridge', 'Prompts', 'Protocol') { Import-Module (Join-Path $root "lib\$m.psm1") }
$config = Get-CCBridgeConfig harness $root
Initialize-CCBLog -Config $config

# --- Building blocks --------------------------------------------------------------------

function New-CodeContext([int]$Chars) {
    <# Synthetic but realistic PowerShell module text of about $Chars characters. #>
    $sb = New-Object Text.StringBuilder
    $sb.AppendLine('### src/Inventory.psm1').AppendLine('````') | Out-Null
    $i = 0
    while ($sb.Length -lt $Chars) {
        $i++
        $sb.AppendLine(@"
function Get-Item$i {
    param([string]`$Name, [int]`$Quantity = $i)
    # Returns item $i with a computed price; used by the report and the export.
    `$price = [math]::Round(`$Quantity * 1.$($i % 10)5, 2)
    if (`$Quantity -lt 0) { throw "Quantity for item $i must not be negative" }
    [pscustomobject]@{ Id = $i; Name = `$Name; Quantity = `$Quantity; Price = `$price }
}
"@) | Out-Null
    }
    $sb.AppendLine('````') | Out-Null
    $sb.ToString()
}

function New-MultiFileContext([int]$Files, [int]$CharsPerFile) {
    <# Several attached modules that call each other, for coordinated edits across files. #>
    $sb = New-Object Text.StringBuilder
    for ($f = 1; $f -le $Files; $f++) {
        $sb.AppendLine("### src/Part$f.psm1").AppendLine('````') | Out-Null
        $start = $sb.Length; $i = 0
        while ($sb.Length - $start -lt $CharsPerFile) {
            $i++
            $callee = if ($f -gt 1) { "Get-Item7 -Name `$Name" } else { "`$null" }
            $sb.AppendLine(@"
function Get-Part${f}Value$i {
    param([string]`$Name, [int]`$Count = $i)
    # Part $f, value ${i}: combines the inventory lookup with a local factor.
    `$base = $callee
    if (`$Count -lt 0) { throw "Count for part $f value $i must not be negative" }
    [pscustomobject]@{ Part = $f; Id = $i; Name = `$Name; Total = `$Count * $f; Base = `$base }
}
"@) | Out-Null
        }
        if ($f -eq 1) { $sb.AppendLine("function Get-Item7 { param([string]`$Name) [pscustomobject]@{ Id = 7; Name = `$Name } }") | Out-Null }
        $sb.AppendLine('````').AppendLine() | Out-Null
    }
    $sb.ToString()
}

function New-AgentPrompt([string]$Kind, [string]$Task, [string]$Context = '') {
    <# The same shape CCBridge sends as the first message of a chat (New-PromptMessage). #>
    $location = "Project folder: complexity-test on the user's computer; use the read action to see its files."
    $ctx = @{ Location = $location; Full = "$location`nThe folder is empty." }
    $text = if ($Context) { "$Task`n`nAttached files:`n$Context" } else { $Task }
    New-PromptMessage -AppRoot $root -Kind $Kind -Text $text -Sent (New-Object 'System.Collections.Generic.HashSet[string]') -Context $ctx
}

$steps = @(
    @{ n = 1;  name = 'Tiny: one word';                      m365 = $false; prompt = 'Reply with only the word OK.' }
    @{ n = 2;  name = 'Short question';                      m365 = $false; prompt = 'In two sentences: what is recursion in programming?' }
    @{ n = 3;  name = 'Small code request';                  m365 = $false; prompt = 'Write a PowerShell function Get-Initials that turns "Anna de Vries" into "AdV". Only the code in one code block.' }
    @{ n = 4;  name = 'Code with constraints';               m365 = $false; prompt = 'Write a PowerShell 5.1 function ConvertTo-Slug: lowercase, spaces and underscores become "-", remove everything except a-z, 0-9 and "-", collapse repeated "-", trim "-" at both ends. Add three example calls with the expected output as comments. Then explain the regex in three short bullets.' }
    @{ n = 5;  name = 'Full instructions + tiny task';      m365 = $false; prompt = { New-AgentPrompt 'coding' 'Create hello.ps1 that prints "Hello". Then use done.' } }
    @{ n = 6;  name = 'Full instructions + medium task';    m365 = $false; prompt = { New-AgentPrompt 'coding' 'Create src/Temperature.psm1 with ConvertTo-Celsius and ConvertTo-Fahrenheit (rounded to 1 decimal, reject values below absolute zero) and tests/Temperature.Tests.ps1 with four Pester 3.4 tests (Should Be syntax). Use todo, write and done.' } }
    @{ n = 7;  name = 'Instructions + ~10k chars of code';  m365 = $false; prompt = { New-AgentPrompt 'coding' 'In the attached src/Inventory.psm1, add input validation to Get-Item3 so that Name must not be empty. Use an edit block with SEARCH/REPLACE, then done.' (New-CodeContext 10000) } }
    @{ n = 8;  name = 'Instructions + ~30k chars of code';  m365 = $false; prompt = { New-AgentPrompt 'coding' 'Review the attached src/Inventory.psm1: list the three most important problems in short bullets, then fix the rounding in Get-Item5 with an edit block, then done.' (New-CodeContext 30000) } }
    @{ n = 9;  name = 'Instructions + ~60k chars of code';  m365 = $false; prompt = { New-AgentPrompt 'coding' 'The attached src/Inventory.psm1 has many near-duplicate functions. Propose a refactoring into one Get-InventoryItem function (short explanation), then write the new module with a write block, then done.' (New-CodeContext 60000) } }
    @{ n = 10; name = 'Long answer: design + several files'; m365 = $false; prompt = { New-AgentPrompt 'coding' 'Design and build a small PowerShell 5.1 to-do CLI: todo.ps1 (add, list, done, remove, export to CSV), src/Todo.psm1 with the logic and JSON storage in data/todos.json, tests/Todo.Tests.ps1 with at least eight Pester 3.4 tests, and README.md with usage. Start with a todo checklist, write all files, then done.' } }
    @{ n = 11; name = 'Microsoft 365: assistant question';   m365 = $true;  prompt = { New-AgentPrompt 'assistant' 'What meetings do I have tomorrow, and which emails from this week still need an answer from me? Keep it short. Do not use actions.' } }
    @{ n = 12; name = 'Microsoft 365 + files: mixed task';   m365 = $true;  prompt = { New-AgentPrompt 'mixed' 'Summarise the decisions and follow-ups from my Teams meetings of this week and write them to notes/weekly-summary.md as a markdown table (date, meeting, decision or follow-up, owner). Then done.' } }
    # Harder: bigger input, longer output, coordinated edits, reasoning, a multi-turn agent loop.
    @{ n = 13; name = 'Instructions + ~100k chars of code';  m365 = $false; prompt = { New-AgentPrompt 'coding' 'In the attached src/Inventory.psm1, make Get-Item42 reject an empty Name and a Quantity above 1000 with clear error messages. Use an edit block with SEARCH/REPLACE, then done.' (New-CodeContext 100000) } }
    @{ n = 14; name = 'Instructions + ~125k chars (near max)'; m365 = $false; prompt = { New-AgentPrompt 'coding' 'In the attached src/Inventory.psm1, find the function whose price factor is 1.95 for the highest item number and add a comment above it saying "highest 1.95 item". Use an edit block, then done.' (New-CodeContext 124000) } }
    @{ n = 15; name = 'Long output: one large file';         m365 = $false; prompt = { New-AgentPrompt 'coding' 'Write src/Geometry.psm1 for PowerShell 5.1 with 24 functions: area and perimeter (or surface area and volume for solids) for circle, square, rectangle, triangle, ellipse, trapezoid, parallelogram, regular hexagon, cube, sphere, cylinder and cone. Each function gets comment-based help (synopsis, parameters, an example) and parameter validation that rejects negative or zero sizes. One write block with the complete file, then done.' } }
    @{ n = 16; name = 'Coordinated edits across 5 files';    m365 = $false; prompt = { New-AgentPrompt 'coding' 'Rename Get-Item7 to Get-InventoryItem7 everywhere in the attached files: its definition in src/Part1.psm1 and every call in the other files. Use edit blocks (one block per file, several SEARCH/REPLACE pairs where needed), then done.' (New-MultiFileContext 5 7000) } }
    @{ n = 17; name = 'Reasoning: algorithm + tests';        m365 = $false; prompt = { New-AgentPrompt 'coding' 'Build an arithmetic expression evaluator in PowerShell 5.1 without Invoke-Expression: src/Calc.psm1 with Invoke-Calc that supports + - * / ^, parentheses, unary minus, decimals, right-associative ^, and clear errors for division by zero, unbalanced parentheses and unknown characters (with the position). Use a tokenizer and a recursive-descent parser. Add tests/Calc.Tests.ps1 with at least 15 Pester 3.4 tests (Should Be syntax) covering precedence, associativity and every error. Start with a todo checklist, write both files, then done.' } }
    @{ n = 18; name = 'Agent loop: 4 turns in one chat';     m365 = $false; prompt = { New-AgentPrompt 'coding' 'Create src/Stats.psm1 with Get-Median (handles even and odd counts, rejects empty input) and tests/Stats.Tests.ps1 with four Pester 3.4 tests. Write both files and run the tests with: powershell -NoProfile -Command "Invoke-Pester tests"' }
        followUps = @(
            "Results:`n- wrote src/Stats.psm1 (18 lines)`n- wrote tests/Stats.Tests.ps1 (22 lines)`n- run: exit code 1`n  [-] returns the middle of an even count 41ms`n    Expected: {2.5}`n    But was:  {2}`n    at line: 9 in tests\Stats.Tests.ps1`nTests Passed: 3, Failed: 1",
            "Results:`n- edit src/Stats.psm1: applied 1 change`n- run: exit code 0`nTests Passed: 4, Failed: 0`n`nNow also add Get-Mode (most frequent value; all values when tied, sorted) with two tests, and run the tests again.",
            "Results:`n- edit src/Stats.psm1: applied 1 change`n- edit tests/Stats.Tests.ps1: applied 1 change`n- run: exit code 0`nTests Passed: 6, Failed: 0"
        ) }
    @{ n = 19; name = 'Microsoft 365: month-wide synthesis';  m365 = $true;  prompt = { New-AgentPrompt 'mixed' 'Go through my email, meetings and Teams chats of the past four weeks and write notes/month-overview.md with: the five main topics (each with the sources it is based on), the open action items for me with due dates, and the people waiting for an answer from me. Read-only: do not send or change anything. Then done.' } }
)

# --- Run ----------------------------------------------------------------------------------

Write-Host 'Copilot complexity and timing test: each step sends one prompt in a new Copilot chat (one message each).' -ForegroundColor White
$bridge = Connect-Copilot -Port $config.cdpPort -SaveReplyFrames $true
$bridge | Add-Member -NotePropertyName PageCheckMs -NotePropertyValue $PageCheckMs -Force
$results = New-Object System.Collections.Generic.List[object]
$repliesDir = Join-Path $env:LOCALAPPDATA 'CCBridge\replies'
try {
    foreach ($step in $steps | Where-Object { $_.n -ge $From -and $_.n -le $To }) {
        $prompt = if ($step.prompt -is [scriptblock]) { & $step.prompt } else { $step.prompt }
        Write-Host ("[{0,2}] {1} ({2} chars)... " -f $step.n, $step.name, $prompt.Length) -NoNewline
        $res = [ordered]@{ step = $step.n; name = $step.name; promptChars = $prompt.Length; microsoft365 = $step.m365 }
        $before = Get-Date
        $firstText = $null
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try {
            New-CopilotChat $bridge
            $bridge | Add-Member -NotePropertyName Timeline -NotePropertyValue (New-ReplyTimeline) -Force
            # The callback runs inside the bridge module, so it keeps its state in a captured hashtable.
            $first = @{ ms = $null }
            $onProgress = { param($t) if (-not $first.ms -and $t) { $first.ms = $watch.ElapsedMilliseconds } }.GetNewClosure()
            $r = Send-CopilotPrompt $bridge $prompt -TimeoutSec $StepTimeoutSec -OnProgress $onProgress -StallSec ([int]$config.stallSec)
            $res.result = if ($r.Result) { $r.Result } else { 'Success' }
            $res.resultMessage = $r.ResultMessage
            $res.seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
            $res.firstTextSeconds = if ($first.ms) { [Math]::Round($first.ms / 1000, 1) } else { $null }
            $res.replyChars = "$($r.Text)".Length
            $res.repaired = [int]$r.Uncertain
            $res.actions = @(Get-ActionBlocks "$($r.Text)" | ForEach-Object { $_.type })
            $res.references = @($r.References).Count
            $res.proposedActions = @($r.ProposedActions).Count
            $res.source = $(if ($r.Source) { $r.Source } else { 'socket' })
            $res.chat = "$($r.Throttling.numUserMessagesInConversation)/$($r.Throttling.maxNumUserMessagesInConversation)"
            if ($r.Metering) { $res.creditsLeft = $r.Metering.remainingAllowance }
            # Timing of the first turn; follow-up turns (agent loop) go into the same chat.
            if ($bridge.PSObject.Properties['Timeline'] -and $bridge.Timeline) {
                $sum = Get-ReplyTimelineSummary $bridge.Timeline
                foreach ($k in 'sentAt', 'route', 'firstTextOnPageMs', 'stopShownMs', 'stopGoneMs', 'firstHubFrameMs', 'lastHubFrameMs', 'returnedMs', 'waitAfterStopGoneMs', 'waitAfterLastHubFrameMs', 'timeline') { $res[$k] = $sum.$k }
                $bridge.Timeline = $null
            }
            if ($step.followUps -and $res.result -eq 'Success') {
                $turns = @([ordered]@{ turn = 1; result = $res.result; seconds = $res.seconds; replyChars = $res.replyChars; actions = (@($res.actions) -join ',') })
                $t = 1
                foreach ($fu in $step.followUps) {
                    $t++
                    $tw = [Diagnostics.Stopwatch]::StartNew()
                    $r2 = Send-CopilotPrompt $bridge $fu -TimeoutSec $StepTimeoutSec -StallSec ([int]$config.stallSec)
                    $turns += [ordered]@{ turn = $t; result = $(if ($r2.Result) { $r2.Result } else { 'Success' }); seconds = [Math]::Round($tw.Elapsed.TotalSeconds, 1); replyChars = "$($r2.Text)".Length; actions = ((@(Get-ActionBlocks "$($r2.Text)" | ForEach-Object { $_.type })) -join ',') }
                    if ($turns[-1].result -ne 'Success' -or -not $turns[-1].replyChars) { $res.result = $turns[-1].result; if ($res.result -eq 'Success') { $res.result = 'EmptyReply' }; $res.resultMessage = "turn ${t}: $($r2.ResultMessage)"; break }
                }
                $res.turns = $turns
                $res.seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
                $res.actions = @($turns | ForEach-Object { "t$($_.turn):$($_.actions)" })
            }
            # Refusals show up in the first words; never kept for Microsoft 365 steps.
            if (-not $step.m365) {
                $flat = "$($r.Text)" -replace '\s+', ' '
                $res.replyStart = Protect-LogText $flat.Substring(0, [Math]::Min(120, $flat.Length))
            }
        } catch {
            $res.result = 'Error'
            $res.resultMessage = Protect-LogText $_.Exception.Message
            $res.seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
        }
        # Exact timings of this reply (names, sizes and times only).
        if ($bridge.PSObject.Properties['Timeline'] -and $bridge.Timeline) {
            $sum = Get-ReplyTimelineSummary $bridge.Timeline
            foreach ($k in 'sentAt', 'route', 'firstTextOnPageMs', 'stopShownMs', 'stopGoneMs', 'firstHubFrameMs', 'lastHubFrameMs', 'returnedMs', 'waitAfterStopGoneMs', 'waitAfterLastHubFrameMs', 'timeline') { $res[$k] = $sum.$k }
            $bridge.Timeline = $null
        }
        # Message types and filter markers from the raw frames of this step.
        $file = Get-ChildItem $repliesDir -Filter *.jsonl -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $before } | Sort-Object Name | Select-Object -Last 1
        if ($file) {
            $types = New-Object System.Collections.Generic.HashSet[string]
            $offense = New-Object System.Collections.Generic.HashSet[string]
            foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
                foreach ($rec in Read-HubRecords $line) {
                    $msgs = @(); if ($rec.arguments) { $msgs += @($rec.arguments[0].messages) }; if ($rec.item -and $rec.item.PSObject.Properties['messages']) { $msgs += @($rec.item.messages) }
                    foreach ($mm in $msgs | Where-Object { $_ }) {
                        [void]$types.Add("$($mm.author):$($mm.messageType):$($mm.contentOrigin)")
                        if ($mm.offense) { [void]$offense.Add([string]$mm.offense) }
                    }
                }
            }
            $res.messageTypes = @($types)
            $res.offense = @($offense)
            $res.frames = @([IO.File]::ReadAllLines($file.FullName)).Count
        }
        $results.Add([pscustomobject]$res)
        $color = if ($res.result -eq 'Success' -and $res.replyChars -gt 0) { 'Green' } else { 'Yellow' }
        Write-Host ("{0} in {1}s, reply {2} chars, via {3}, waited {4} ms after Copilot finished" -f $res.result, $res.seconds, $res.replyChars, $res.route, $res.waitAfterStopGoneMs) -ForegroundColor $color
        Write-CCBLog info complexity "step $($step.n) $($step.name): $($res.result)" $res
        if ($res.result -eq 'OutOfCredits') { Write-Host 'Out of Copilot credits: stopping.' -ForegroundColor Yellow; break }
        Start-Sleep -Seconds $PauseSec
    }
} finally {
    Disconnect-Copilot $bridge
}

# --- Report -------------------------------------------------------------------------------

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
# Each run gets its own folder under $OutRoot (default C:\temp).
$outDir = Join-Path $OutRoot "CCBridge-test-$stamp"
$null = New-Item -ItemType Directory -Force -Path $outDir
$jsonFile = Join-Path $outDir "CCBridge-complexity-$stamp.json"
$txtFile = Join-Path $outDir "CCBridge-complexity-$stamp.txt"
$envInfo = Get-CCBridgeEnvironment $root
[IO.File]::WriteAllText($jsonFile, (Protect-LogText (@{ environment = $envInfo; steps = $results } | ConvertTo-Json -Depth 6)), (New-Object Text.UTF8Encoding($false)))
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("CCBridge complexity and timing test $stamp (CCBridge $($envInfo.ccbridge)), page checked every $PageCheckMs ms")
$lines.Add('Times: ms after Send was clicked; network times are Edge''s own. Names, sizes and times only.')
$lines.Add('')
$lines.Add(('{0,-4} {1,-38} {2,8} {3,-12} {4,7} {5,8} {6}' -f 'Step', 'Name', 'Prompt', 'Result', 'Seconds', 'Reply', 'Actions / first words'))
foreach ($r in $results) {
    $detail = if ($r.actions -and @($r.actions).Count) { (@($r.actions) -join ',') } elseif ($r.replyStart) { $r.replyStart } else { '' }
    $lines.Add(('{0,-4} {1,-38} {2,8} {3,-12} {4,7} {5,8} {6}' -f $r.step, $r.name, $r.promptChars, $r.result, $r.seconds, $r.replyChars, $detail))
    if ($r.result -ne 'Success' -and $r.resultMessage) { $lines.Add("     -> $($r.resultMessage)") }
    foreach ($tn in @($r.turns)) { if ($tn) { $lines.Add(("     turn {0}: {1} in {2}s, reply {3} chars, actions {4}" -f $tn.turn, $tn.result, $tn.seconds, $tn.replyChars, $tn.actions)) } }
}
$firstFail = $results | Where-Object { $_.result -ne 'Success' -or $_.replyChars -eq 0 } | Select-Object -First 1
$lines.Add('')
$lines.Add($(if ($firstFail) { "First problem at step $($firstFail.step) ($($firstFail.name)): $($firstFail.result). Send this file and the .json to whoever helps you." } else { 'All steps answered.' }))
$lines.Add('')
$lines.Add('TIMING (ms after Send)')
$lines.Add(('{0,-4} {1,-36} {2,-13} {3,9} {4,9} {5,9} {6,9} {7,9} {8,9}' -f 'Step', 'Route', 'Sent at', 'FirstText', 'StopGone', 'LastHub', 'Returned', 'WaitStop', 'WaitHub'))
foreach ($r in $results) {
    $lines.Add(('{0,-4} {1,-36} {2,-13} {3,9} {4,9} {5,9} {6,9} {7,9} {8,9}' -f $r.step, $r.route, $r.sentAt, $r.firstTextOnPageMs, $r.stopGoneMs, $r.lastHubFrameMs, $r.returnedMs, $r.waitAfterStopGoneMs, $r.waitAfterLastHubFrameMs))
}
foreach ($r in $results) {
    if (-not $r.timeline) { continue }
    $lines.Add('')
    $lines.Add("=== [$($r.step)] $($r.name): $($r.result) via $($r.route)")
    foreach ($t in $r.timeline) { $lines.Add("    $t") }
}
[IO.File]::WriteAllText($txtFile, (Protect-LogText ($lines -join "`r`n")), (New-Object Text.UTF8Encoding($false)))
Write-Host ''
Write-Host "Folder: $outDir" -ForegroundColor Green
Write-Host "Report: $txtFile" -ForegroundColor Green
Write-Host "Details: $jsonFile"
