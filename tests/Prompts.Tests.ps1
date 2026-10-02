# The prompt sent to Copilot is as small as the request allows.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Log.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

function New-Sent { New-Object 'System.Collections.Generic.HashSet[string]' }
$ctx = @{ Location = 'Project folder: OneDrive > CCBridge > budget tracker.'; Full = "Project folder: OneDrive > CCBridge > budget tracker.`nThe folder is empty." }

Describe 'Get-TaskKind' {
    It 'treats greetings and general questions as plain chat' {
        foreach ($t in @('hi', 'Hi', 'Thanks!', 'Explain the difference between a lease and a loan', '')) { Get-TaskKind $t | Should Be 'chat' }
    }
    It 'recognises coding tasks' {
        foreach ($t in @('Fix the bug in src/app.py', 'Add Pester tests and run the build', 'Maak een functie die de totalen berekent')) { Get-TaskKind $t | Should Be 'coding' }
    }
    It 'recognises project work without code' {
        foreach ($t in @('Summarise the notes in this project', 'What is in @budget.csv?', 'Maak een samenvatting van de bestanden')) { Get-TaskKind $t | Should Be 'project' }
    }
    It 'recognises Microsoft 365 work as an assistant task, also when the result goes into a file' {
        foreach ($t in @('What meetings do I have tomorrow?', 'Summarise my emails from today into notes/today.md', 'Welke vergaderingen heb ik morgen?')) { Get-TaskKind $t | Should Be 'assistant' }
    }
    It 'recognises code that works with Microsoft 365 data as mixed' {
        Get-TaskKind 'Write a script that exports my Outlook emails to CSV' | Should Be 'mixed'
    }
}

Describe 'New-PromptMessage' {
    It 'sends a plain chat message exactly as typed' {
        New-PromptMessage -AppRoot $root -Kind 'chat' -Text 'hi' -Sent (New-Sent) -Context $ctx | Should BeExactly 'hi'
    }

    It 'gives coding tasks a compact instruction set without example files' {
        $m = New-PromptMessage -AppRoot $root -Kind 'coding' -Text 'Fix the build' -Sent (New-Sent) -Context $ctx
        $m | Should Match '^You are an expert software developer'
        $m | Should Match 'PATH'
        $m | Should Match 'OneDrive > CCBridge > budget tracker'
        $m | Should Match 'Request: Fix the build$'
        $m | Should Not Match 'app\.py|hello\.py|dotnet build|CCBridge sends'
        $m.Length -lt 2600 | Should Be $true
    }

    It 'gives assistant tasks only the role, the read-only rule, saving and the location' {
        $m = New-PromptMessage -AppRoot $root -Kind 'assistant' -Text 'What meetings do I have?' -Sent (New-Sent) -Context $ctx
        $m | Should Match '^You are the user''s personal assistant'
        $m | Should Match 'only to read it'
        $m | Should Match 'write notes/NAME.md'
        $m | Should Not Match 'SEARCH|```read'
        $m.Length -lt 900 | Should Be $true
    }

    It 'adds only the missing parts later in the same chat' {
        $sent = New-Sent
        New-PromptMessage -AppRoot $root -Kind 'chat' -Text 'hi' -Sent $sent -Context $ctx | Should BeExactly 'hi'
        $second = New-PromptMessage -AppRoot $root -Kind 'coding' -Text 'Create hello.ps1' -Sent $sent -Context $ctx
        $second | Should Match 'expert software developer'
        $third = New-PromptMessage -AppRoot $root -Kind 'coding' -Text 'Now add a test' -Sent $sent -Context $ctx
        $third | Should Match '^Now add a test\n\n\(How to answer: you cannot open or change the files, but the helper program applies the action blocks you write'
        $third | Should Match '````edit PATH````'
        $third | Should Not Match 'expert software developer'
        New-PromptMessage -AppRoot $root -Kind 'chat' -Text 'thanks' -Sent $sent -Context $ctx | Should BeExactly 'thanks'
        $fourth = New-PromptMessage -AppRoot $root -Kind 'mixed' -Text 'Also read my emails about it' -Sent $sent -Context $ctx
        $fourth | Should Match 'only to read it'
        $fourth | Should Not Match 'expert software developer'
    }

    It 'never mentions the tool''s name' {
        foreach ($k in 'assistant', 'project', 'coding', 'mixed') {
            New-PromptMessage -AppRoot $root -Kind $k -Text 'x' -Sent (New-Sent) -Context $ctx | Should Not Match 'CCBridge sends|helper program called|CCBridge,'
        }
    }
}

Describe 'Project notes (AGENTS.md)' {
    It 'leaves out an AGENTS.md that only has the template text' {
        $dir = Join-Path $env:TEMP ('ccb-notes-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# budget tracker`n`nInstructions for coding agents (CCBridge and others). CCBridge sends this file to Copilot at the start of each chat.`nDescribe the goal, tech stack, build/run commands and conventions here.`n")
        (& (Get-Module Agent) { param($d) Get-ProjectNotes $d } $dir) | Should Be ''
        [IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# budget tracker`n`nInstructions for coding assistants. This file is sent to the assistant at the start of each chat.`nTrack monthly spending per category in CSV files.`n")
        $notes = & (Get-Module Agent) { param($d) Get-ProjectNotes $d } $dir
        $notes | Should Match 'Track monthly spending'
        $notes | Should Not Match 'Instructions for coding'
        Remove-Item $dir -Recurse -Force
    }
}

Describe 'Test-NeedsActionNudge' {
    $m = Get-Module Agent
    $st = @{ Mode = 'ask' }
    $steps = "To move the CSS:`n1. Create style.css`n2. Cut the style block`n3. Add a link tag"
    $code = "Put this in style.css:`n``````css`nbody { margin: 0; }`n```````n"
    It 'spots instructions for doing it by hand' {
        foreach ($t in @($steps, $code, 'You can open the file and replace the style tag with a link.', 'I can''t access your project files. Once you provide them I will edit them.', 'Please upload the files first.')) {
            (& $m { param($s, $x) Test-NeedsActionNudge $s 'coding' $x 0 2 } $st $t) | Should Be $true
        }
    }
    It 'stops after the maximum number of retries' {
        (& $m { param($s, $x) Test-NeedsActionNudge $s 'coding' $x 2 2 } $st $steps) | Should Be $false
        (& $m { param($s, $x) Test-NeedsActionNudge $s 'coding' $x 1 2 } $st $steps) | Should Be $true
    }
    It 'leaves plain answers, plain chat and plan mode alone' {
        (& $m { param($s, $x) Test-NeedsActionNudge $s 'coding' $x 0 2 } $st 'Done, nothing else to change.') | Should Be $false
        (& $m { param($s, $x) Test-NeedsActionNudge $s 'chat' $x 0 2 } $st $steps) | Should Be $false
        (& $m { param($s, $x) Test-NeedsActionNudge $s 'coding' $x 0 2 } @{ Mode = 'plan' } $steps) | Should Be $false
    }
}

Describe 'New-ActionRetryMessage' {
    It 'sends the instructions in full, the note and the original task' {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        $s = @{ AppRoot = $root; SentParts = $set }
        $msg = & (Get-Module Agent) { param($st) New-ActionRetryMessage $st 'Update index.html to use styles.css' } $s
        $msg | Should Match '^HOW THIS WORKS'
        $msg | Should Match 'RULES'
        $msg | Should Match 'nothing has been changed yet'
        $msg | Should Match 'Task: Update index\.html to use styles\.css$'
        $msg | Should Not Match 'CCBridge'
        $set.Contains('actions') | Should Be $true
    }
}
Describe 'Follow-ups in a work chat (Get-TurnKind)' {
    $m = Get-Module Agent
    function New-ChatState([string]$ChatKind = 'coding') {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($p in 'role:coding', 'actions', 'rules', 'project') { [void]$set.Add($p) }
        @{ ChatKind = $ChatKind; SentParts = $set; FollowUps = 0; LastTurnActed = $true }
    }
    It 'gives a chat-like follow-up the task of the chat' {
        $s = New-ChatState
        (& $m { param($st) Get-TurnKind $st 'do it now please' } $s) | Should Be 'coding'
        $s.SentParts.Contains('actions') | Should Be $true
    }
    It 'sends the full instructions again after a turn without actions' {
        $s = New-ChatState; $s.LastTurnActed = $false
        $null = & $m { param($st) Get-TurnKind $st 'and now the other page' } $s
        $s.SentParts.Contains('actions') | Should Be $false
        $s.SentParts.Contains('rules') | Should Be $false
        $s.SentParts.Contains('project') | Should Be $true
    }
    It 'sends them again after every 5 follow-ups' {
        $s = New-ChatState
        1..4 | ForEach-Object { $null = & $m { param($st) Get-TurnKind $st 'next step' } $s }
        $s.SentParts.Contains('actions') | Should Be $true
        $null = & $m { param($st) Get-TurnKind $st 'next step' } $s
        $s.SentParts.Contains('actions') | Should Be $false
    }
    It 'leaves a plain chat alone' {
        $s = @{ ChatKind = $null; SentParts = (New-Object 'System.Collections.Generic.HashSet[string]'); FollowUps = 0; LastTurnActed = $null }
        (& $m { param($st) Get-TurnKind $st 'thanks!' } $s) | Should Be 'chat'
    }
}
Describe 'Errors carry what is needed to investigate them' {
    It 'recognises the main kinds of errors' {
        (Get-CCBErrorHelp 'Lost the connection to the Copilot tab in Edge (connection Aborted)').code | Should Be 'EDGE-LOST'
        (Get-CCBErrorHelp "Copilot answered with 'NoAnswer': Copilot stopped without answering").code | Should Be 'NO-ANSWER'
        (Get-CCBErrorHelp 'No complete reply within 300 s (partial: 0 chars)').code | Should Be 'TIMEOUT'
        (Get-CCBErrorHelp "pair 1: SEARCH text not found in the file").code | Should Be 'EDIT'
        (Get-CCBErrorHelp 'Copilot message box did not appear after starting a new chat; the page shows a sign-in page').code | Should Be 'SIGN-IN'
        (Get-CCBErrorHelp "You've reached your daily limit").code | Should Be 'CREDITS'
        $u = Get-CCBErrorHelp 'Something entirely new'
        $u.code | Should Be 'UNEXPECTED'
        $u.hint | Should Match 'Copy details'
    }
    It 'gives error events an id, a category, a hint and the technical detail' {
        $s = New-AgentState -Config ([pscustomobject]@{}) -AppRoot $root
        $s.Version = 'v9.9.9'
        try { throw 'No complete reply within 300 s (partial: 0 chars)' } catch { Add-AgentEvent $s 'error' @{ text = $_.Exception.Message; record = $_ } }
        $e = $s.Events[$s.Events.Count - 1]
        $e.errId | Should Match '^E-\d{6}-[0-9a-f]{4}$'
        $e.code | Should Be 'TIMEOUT'
        $e.hint | Should Match 'replyTimeoutSec'
        $e.detail | Should Match 'RuntimeException: No complete reply'
        $e.version | Should Be 'v9.9.9'
        $e.ContainsKey('record') | Should Be $false
    }
}
Describe 'Why a step failed (Get-StepFailureInfo)' {
    $m = Get-Module Agent
    It 'explains the common step failures, one category each' {
        $cases = @{
            'edit index.html failed error: pair 1: SEARCH text not found in the file. The closest place is lines 2-5' = 'EDIT-NOT-FOUND'
            'edit failed error: pair 2: SEARCH text matches 3 places (lines 4, 9, 12)' = 'EDIT-AMBIGUOUS'
            'edit failed error: this edit would leave a <style> block half open or half closed in the file' = 'EDIT-HALF-BLOCK'
            'edit failed error: ... but styles.css does not contain them yet (only 0 of 22 found)' = 'EDIT-MOVE-ORDER'
            'edit refused (source data) error: source/x.csv is in source/, which holds the user''s source data and is read-only' = 'SOURCE-DATA'
            'ran: exit code 1 exit code 1 ~~~~ build failed' = 'RUN-FAILED'
            'ran: timed out after 180s' = 'RUN-TIMEOUT'
            'edit failed error: file not found: app.js (use write to create it)' = 'FILE-NOT-FOUND'
        }
        foreach ($k in $cases.Keys) {
            $i = & $m { param($r) Get-StepFailureInfo 'edit' $r } $k
            @($i).Count | Should Be 1
            $i.code | Should Be $cases[$k]
            @($i.reasons).Count -ge 1 | Should Be $true
            $i.next | Should Not BeNullOrEmpty
        }
    }
    It 'has a fallback for anything else' {
        (& $m { Get-StepFailureInfo 'grep' 'something odd' }).code | Should Be 'GREP-FAILED'
    }
}