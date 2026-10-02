<#
.SYNOPSIS
  Sends a ladder of prompts, from simple to complex, to Microsoft 365 Copilot (each in a fresh chat)
  and reports per step how Copilot responded: answered, blocked, no answer, out of credits, timings.
  Use it to find where (if anywhere) Copilot starts to fail or refuse.
.DESCRIPTION
  Every step costs one Copilot message. The report (text + JSON on the desktop) contains no
  Microsoft 365 data: for the Microsoft 365 steps only codes, sizes and timings are kept.
.PARAMETER From
  First step to run (default 1).
.PARAMETER To
  Last step to run (default 12).
.PARAMETER StepTimeoutSec
  Longest wait for one reply (default 300).
.EXAMPLE
  complexity-test.cmd
  complexity-test.cmd -From 5 -To 9
#>
param([int]$From = 1, [int]$To = 12, [int]$StepTimeoutSec = 300, [int]$PauseSec = 3)

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

function New-AgentPrompt([string]$Kind, [string]$Task, [string]$Context = '') {
    <# The same shape CCBridge sends as the first message of a chat. #>
    $fence = '```'
    $p = (Get-Instructions $root $Kind) + "`n`n# Project: complexity-test`n`n## Files`n$fence`n(empty project)`n$fence`n"
    if ($Context) { $p += "`n# Attached files`n$Context`n" }
    $p + "`n# Task`n$Task"
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
)

# --- Run ----------------------------------------------------------------------------------

Write-Host 'Copilot complexity test: each step sends one prompt in a new Copilot chat (one message each).' -ForegroundColor White
$bridge = Connect-Copilot -Port $config.cdpPort -SaveReplyFrames $true
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
            $res.chat = "$($r.Throttling.numUserMessagesInConversation)/$($r.Throttling.maxNumUserMessagesInConversation)"
            if ($r.Metering) { $res.creditsLeft = $r.Metering.remainingAllowance }
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
        # Message types and filter markers from the raw frames of this step.
        $file = Get-ChildItem $repliesDir -Filter *.jsonl -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $before } | Sort-Object Name | Select-Object -Last 1
        if ($file) {
            $types = New-Object System.Collections.Generic.HashSet[string]
            $offense = New-Object System.Collections.Generic.HashSet[string]
            foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
                foreach ($rec in Read-HubRecords $line) {
                    $msgs = @(); if ($rec.arguments) { $msgs += @($rec.arguments[0].messages) }; if ($rec.item) { $msgs += @($rec.item.messages) }
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
        Write-Host ("{0} in {1}s, reply {2} chars" -f $res.result, $res.seconds, $res.replyChars) -ForegroundColor $color
        Write-CCBLog info complexity "step $($step.n) $($step.name): $($res.result)" $res
        if ($res.result -eq 'OutOfCredits') { Write-Host 'Out of Copilot credits: stopping.' -ForegroundColor Yellow; break }
        Start-Sleep -Seconds $PauseSec
    }
} finally {
    Disconnect-Copilot $bridge
}

# --- Report -------------------------------------------------------------------------------

$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$desktop = [Environment]::GetFolderPath('Desktop')
$jsonFile = Join-Path $desktop "CCBridge-complexity-$stamp.json"
$txtFile = Join-Path $desktop "CCBridge-complexity-$stamp.txt"
$envInfo = Get-CCBridgeEnvironment $root
[IO.File]::WriteAllText($jsonFile, (Protect-LogText (@{ environment = $envInfo; steps = $results } | ConvertTo-Json -Depth 6)), (New-Object Text.UTF8Encoding($false)))
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("CCBridge complexity test $stamp (CCBridge $($envInfo.ccbridge))")
$lines.Add('')
$lines.Add(('{0,-4} {1,-38} {2,8} {3,-12} {4,7} {5,8} {6}' -f 'Step', 'Name', 'Prompt', 'Result', 'Seconds', 'Reply', 'Actions / first words'))
foreach ($r in $results) {
    $detail = if ($r.actions -and @($r.actions).Count) { (@($r.actions) -join ',') } elseif ($r.replyStart) { $r.replyStart } else { '' }
    $lines.Add(('{0,-4} {1,-38} {2,8} {3,-12} {4,7} {5,8} {6}' -f $r.step, $r.name, $r.promptChars, $r.result, $r.seconds, $r.replyChars, $detail))
    if ($r.result -ne 'Success' -and $r.resultMessage) { $lines.Add("     -> $($r.resultMessage)") }
}
$firstFail = $results | Where-Object { $_.result -ne 'Success' -or $_.replyChars -eq 0 } | Select-Object -First 1
$lines.Add('')
$lines.Add($(if ($firstFail) { "First problem at step $($firstFail.step) ($($firstFail.name)): $($firstFail.result). Send this file and the .json to whoever helps you." } else { 'All steps answered.' }))
[IO.File]::WriteAllText($txtFile, (Protect-LogText ($lines -join "`r`n")), (New-Object Text.UTF8Encoding($false)))
Write-Host ''
Write-Host "Report: $txtFile" -ForegroundColor Green
Write-Host "Details: $jsonFile"
