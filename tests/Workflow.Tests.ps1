# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# Clarify -> plan -> build, verification and evidence, project memory, find.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\PlanFile.psm1') -Force

function New-Proj([hashtable]$Files) {
    $p = Join-Path $env:TEMP ('ccb-wf-' + [guid]::NewGuid().ToString('N'))
    foreach ($k in $Files.Keys) { $f = Join-Path $p $k; $null = New-Item -ItemType Directory -Force (Split-Path $f); [IO.File]::WriteAllText($f, $Files[$k]) }
    $p
}

Describe 'Find-SymbolDefinition' {
    $p = New-Proj @{
        'js/app.js' = "const a = 1;`nfunction total(items) {`n  return items.length;`n}`nexport const fmt = (x) => x;`nclass Cart {`n  add(item) {`n    return 1;`n  }`n}`n"
        'css/site.css' = ".card {`n  padding: 4px;`n}`n#main, .wide {`n  width: 100%;`n}`n"
        'tools/build.ps1' = "function Invoke-Build {`n  'x'`n}`n"
        'index.html' = "<div id=""main""></div>`n"
    }
    It 'finds functions, arrow functions, classes and methods with the block to read' {
        Find-SymbolDefinition $p 'total' | Should Match 'js/app\.js:2  function total\(items\) \{  \(block: read js/app\.js:2-4\)'
        Find-SymbolDefinition $p 'fmt' | Should Match 'js/app\.js:5'
        Find-SymbolDefinition $p 'Cart' | Should Match 'js/app\.js:6  class Cart'
        Find-SymbolDefinition $p 'add' | Should Match 'js/app\.js:7'
    }
    It 'finds CSS classes, ids and PowerShell functions' {
        Find-SymbolDefinition $p '.card' | Should Match 'css/site\.css:1'
        $m = Find-SymbolDefinition $p 'main'
        $m | Should Match 'css/site\.css:4'
        $m | Should Match 'index\.html:1'
        Find-SymbolDefinition $p 'Invoke-Build' | Should Match 'tools/build\.ps1:1'
    }
    It 'says when nothing is found, and refuses odd names' {
        Find-SymbolDefinition $p 'nothingHere' | Should Match 'no definition found'
        Find-SymbolDefinition $p 'a b' | Should Match 'give one name'
    }
    cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
}

Describe 'Get-LearnedNotes (project memory)' {
    It 'adds to the Learned section, making it when missing' {
        Get-LearnedNotes '' 'Use metric units' '2026-10-03' | Should Be "# Project notes`n`n## Learned`n- Use metric units (2026-10-03)`n"
        $t = Get-LearnedNotes "# App`n`nverify: npm test`n" "- Dates are ISO 8601`nPrices include VAT" '2026-10-03'
        $t | Should Match "(?s)verify: npm test\n\n## Learned\n- Dates are ISO 8601 \(2026-10-03\)\n- Prices include VAT \(2026-10-03\)"
    }
    It 'appends to an existing Learned section before the next section' {
        $t = Get-LearnedNotes "# App`n`n## Learned`n- Old (2026-01-01)`n`n## Other`nx`n" 'New fact' '2026-10-03'
        $t | Should Match "(?s)## Learned\n- Old \(2026-01-01\)\n- New fact \(2026-10-03\)\n\n## Other"
    }
}

Describe 'Get-ProjectVerify' {
    It 'reads a verify line from AGENTS.md' {
        $p = New-Proj @{ 'AGENTS.md' = "# Notes`n`n- verify: ``powershell -File tests\run.ps1```n" }
        Get-ProjectVerify $p | Should Be 'powershell -File tests\run.ps1'
        cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
        $q = New-Proj @{ 'AGENTS.md' = "# Notes`nno check here`n" }
        Get-ProjectVerify $q | Should BeNullOrEmpty
        cmd /c "rmdir /s /q ""$q"" >nul 2>&1"
    }
}

Describe 'Save-TaskEvidence' {
    It 'writes what was asked, what changed and the checks' {
        $p = New-Proj @{ 'a.txt' = 'x' }
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root
        $s.ProjectRoot = $p
        $rel = Save-TaskEvidence $s 'Fix the total' @([pscustomobject]@{ path = 'js/app.js'; added = 3; removed = 1; created = $false; deleted = $false }) @{ syntaxLast = @(); page = $null; reviewed = $true; verify = @{ command = 'npm test'; passed = $false; exit = 1; tail = 'FAIL total' } } 'Fixed the off-by-one.' 4
        $rel | Should Match '^\.streamhub/Evidence/task-\d{8}-\d{6}\.md$'
        $t = [IO.File]::ReadAllText((Join-Path $p $rel))
        $t | Should Match 'Fix the total'
        $t | Should Match '`js/app\.js` \+3 -1'
        $t | Should Match 'File checks \(syntax and structure per file type\): passed'
        $t | Should Match 'Copilot consistency review: done'
        $t | Should Match 'Verify: FAILED \(`npm test`, exit 1\)'
        $t | Should Match 'Copilot messages: 4'
        cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
    }
}

Describe 'find and remember instructions' {
    It 'go only to projects that have files' {
        (Get-PromptModules 'Fix the build' @{ Traits = @(); Paths = @() }) -contains 'actions:project' | Should Be $false
        (Get-PromptModules 'Fix the build' @{ Traits = @('code'); Paths = @('a.js') }) -contains 'actions:project' | Should Be $true
        Get-PromptPart $root 'actions:project' @{} | Should Match '(?s)```find.*```remember'
    }
}

Describe 'Invoke-ClarifyStep (Copilot mocked)' {
    $p = New-Proj @{ 'index.html' = '<p>hi</p>' }
    $config = Get-CCBridgeConfig harness $root
    Mock -ModuleName Agent Start-NewChat { }
    Mock -ModuleName Agent Test-OtherSender { $false }
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, [string]$Message)
        $global:ccbClarifyMsg = $Message
        if ($global:ccbClarifyNone) { return [pscustomobject]@{ Result = 'Success'; Text = "``````json`n{""questions"":[],""summary"":""A dark mode toggle.""}`n``````" } }
        [pscustomobject]@{ Result = 'Success'; Text = "``````json`n{""questions"":[{""question"":""Where should the toggle go?"",""options"":[""Header"",""Settings""]},{""question"":""Remember the choice?"",""options"":[""Yes"",""No""]}],""summary"":""Add a dark mode toggle.""}`n``````" }
    }
    Mock -ModuleName Agent Invoke-AgentTurn { param($State, $Text, $Force) $global:ccbPlanTurn = @{ text = $Text; mode = $State.Mode; force = $Force }; Add-AgentEvent $State 'done' @{ text = 'Add a toggle in the header; store the choice.' } }

    It 'asks Copilot for questions with the project context, and shows them as a form' {
        $global:ccbClarifyNone = $false
        $s = New-AgentState -Config $config -AppRoot $root
        $s.ProjectRoot = $p
        Invoke-ClarifyStep $s @{ request = 'Add dark mode' }
        $global:ccbClarifyMsg | Should Match '(?s)CLARIFY FIRST.*Request: Add dark mode'
        $global:ccbClarifyMsg | Should Match 'index\.html'
        $e = @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'clarify' })
        $e.Count | Should Be 1
        @($e[0].questions).Count | Should Be 2
        @($e[0].questions)[0].options -join ',' | Should Be 'Header,Settings'
        $e[0].summary | Should Be 'Add a dark mode toggle.'
        $e[0].planId | Should Match '^\d{8}-\d{4}-add-dark-mode$'
        $plan = [IO.File]::ReadAllText((Join-Path $p '.streamhub\PLAN.md'))
        $plan | Should Match '(?s)## \d{4}-\d\d-\d\d \d\d:\d\d - Add dark mode\n<!-- plan:\d{8}-\d{4}-add-dark-mode -->\n\nStatus: waiting for your answers'
        $plan | Should Match '(?s)### Copilot''s questions\n\n1\. Where should the toggle go\?\n   Suggested answers: Header / Settings'
    }
    It 'plans right away when Copilot has no questions, and offers the plan' {
        $global:ccbClarifyNone = $true
        $s = New-AgentState -Config $config -AppRoot $root
        $s.ProjectRoot = $p
        Invoke-ClarifyStep $s @{ request = 'Add dark mode' }
        $global:ccbPlanTurn.mode | Should Be 'plan'
        $global:ccbPlanTurn.text | Should Match '(?s)PLAN FIRST.*Add dark mode'
        $plan = @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'plan-ready' })
        $plan.Count | Should Be 1
        $plan[0].plan | Should Match 'header'
        $plan[0].request | Should Be 'Add dark mode'
        $md = [IO.File]::ReadAllText((Join-Path $p '.streamhub\PLAN.md'))
        $md | Should Match '(?s)### Copilot''s questions\n\nNone: the request was clear\..*### Plan \(version 1\)\n\nAdd a toggle in the header'
        $md | Should Match 'Status: waiting for approval'
    }
    cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
}

Describe 'remember action' {
    It 'adds to AGENTS.md only after approval, also in auto mode' {
        $p = New-Proj @{ 'AGENTS.md' = "# Notes`n" }
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root
        $s.ProjectRoot = $p; $s.Mode = 'auto'; $s.Cancel = $true   # nobody approves: rejected
        $a = [pscustomobject]@{ type = 'remember'; arg = ''; body = 'Prices include VAT'; closed = $true; edits = @() }
        $r = & (Get-Module Agent) { param($st, $x) Invoke-AgentAction $st $x 'r-1' $null 0 } $s $a
        $r.ok | Should Be $false
        [IO.File]::ReadAllText((Join-Path $p 'AGENTS.md')) | Should Be "# Notes`n"
        $ev = @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' })
        $ev[0].preview.new | Should Match 'Prices include VAT'
        cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
    }
}

Describe 'Format-ProjectTree with one file' {
    It 'lists the single file instead of calling the project empty' {
        $p = New-Proj @{ 'index.html' = '<p>hi</p>' }
        Format-ProjectTree $p | Should Match '^index\.html \(\d+ B\)$'
        cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
    }
}
Describe 'PLAN.md' {
    It 'keeps every decision of each request in its own section' {
        $p = New-Proj @{ 'a.txt' = 'x' }
        $t1 = Get-Date -Year 2026 -Month 10 -Day 3 -Hour 9 -Minute 15
        $a = New-PlanEntry $p 'Add dark mode' $t1
        $b = New-PlanEntry $p 'Export to CSV' $t1.AddMinutes(5)
        $a | Should Be '20261003-0915-add-dark-mode'
        Add-PlanSection $p $a "Copilot's questions" (Format-PlanQuestions @(@{ question = 'Where?'; options = @('Header', 'Footer') }) 'A toggle.') 'waiting for your answers'
        Add-PlanSection $p $b 'Plan (version 1)' "1. Add a button" 'waiting for approval'
        Add-PlanSection $p $a 'Your answers' (Format-PlanAnswers @(@{ question = 'Where?'; answer = 'Header' })) 'planning'
        Add-PlanSection $p $a "Plan (version $((Get-PlanVersionCount $p $a) + 1))" "1. Toggle in the header" 'waiting for approval'
        Add-PlanSection $p $a 'Change requested' 'Also remember the choice' 'planning'
        Add-PlanSection $p $a "Plan (version $((Get-PlanVersionCount $p $a) + 1))" "1. Toggle in the header`n2. Store it" 'waiting for approval'
        Add-PlanSection $p $a 'Approved' 'Approved; building started.' 'building'
        $md = [IO.File]::ReadAllText((Join-Path $p '.streamhub\PLAN.md'))
        $md | Should Match '^# PLAN\n'
        # dark mode first, then CSV; each with its own steps in order
        $md | Should Match "(?s)## 2026-10-03 09:15 - Add dark mode\n<!-- plan:$a -->\n\nStatus: building\n\n### Request\n\nAdd dark mode\n\n### Copilot's questions.*### Your answers\n\n1\. Where\?\n   Answer: Header\n\n### Plan \(version 1\).*### Change requested\n\nAlso remember the choice\n\n### Plan \(version 2\)\n\n1\. Toggle in the header\n2\. Store it\n\n### Approved.*\n## 2026-10-03 09:20 - Export to CSV\n<!-- plan:$b -->\n\nStatus: waiting for approval\n\n### Request\n\nExport to CSV\n\n### Plan \(version 1\)\n\n1\. Add a button\n$"
        Get-PlanVersionCount $p $a | Should Be 2
        Get-PlanVersionCount $p $b | Should Be 1
        { Add-PlanSection $p 'nope-id' 'X' 'y' } | Should Throw 'no section'
        { Add-PlanSection $p '../evil' 'X' 'y' } | Should Throw 'Not a plan id'
        cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
    }
    It 'writes the result of the build' {
        $p = New-Proj @{ 'a.txt' = 'x' }
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root
        $s.ProjectRoot = $p
        $id = New-PlanEntry $p 'Add dark mode'
        $from = [int]$s.Seq
        Add-AgentEvent $s 'done' @{ text = 'Added the toggle.' }
        Add-AgentEvent $s 'checkpoint' @{ files = @('css/theme.css', 'js/app.js') }
        Add-AgentEvent $s 'status' @{ text = 'Evidence saved: evidence/task-20261003-091500.md' }
        & (Get-Module Agent) { param($st, $i, $f) Write-PlanResult $st $i $f } $s $id $from
        $md = [IO.File]::ReadAllText((Join-Path $p '.streamhub\PLAN.md'))
        $md | Should Match 'Status: done'
        $md | Should Match '(?s)### Result \(\d{4}-\d\d-\d\d \d\d:\d\d\)\n\nAdded the toggle\.\n\nFiles changed: `css/theme\.css`, `js/app\.js`\n\nEvidence: evidence/task-20261003-091500\.md'
        cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
    }
}