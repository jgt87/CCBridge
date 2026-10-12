# What Copilot writes down for the helper program: the checks a task must pass ("Done when:"),
# answered MET / NOT MET at the end, and notes on the project's data ("Data notes:").
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\TaskNotes.psm1') -Force

Describe 'Done when: the checks Copilot sets at the start' {
    It 'reads the list under the heading, in the forms Copilot writes it, and nothing from code blocks' {
        $reply = "I will build the dashboard.`n`n**Done when:**`n- the page shows a chart of orders per region`n- [ ] the status filter changes every chart`n2. numbers show thousands separators`n`nNow the files:`n" + '```text' + "`nACTION write index.html`n" + '```'
        @(Read-DoneWhen $reply) -join ' | ' | Should Be 'the page shows a chart of orders per region | the status filter changes every chart | numbers show thousands separators'
        @(Read-DoneWhen "Done when: it works").Count | Should Be 0
        @(Read-DoneWhen ('```text' + "`nDone when:`n- inside a block`n" + '```')).Count | Should Be 0
    }
    It 'matches MET / NOT MET answers to the checks by their text or in order' {
        $checks = @('the page shows a chart of orders per region', 'the status filter changes every chart', 'numbers show thousands separators')
        $ans = "MET: the page shows a chart of orders per region`n**NOT MET:** the status filter changes every chart - the list ignores it`nMET: numbers show thousands separators"
        $r = @(Read-AcceptanceAnswers $ans $checks)
        @($r | ForEach-Object { $_.met }) -join ',' | Should Be 'True,False,True'
        $r[1].note | Should Be 'the list ignores it'
        $r2 = @(Read-AcceptanceAnswers "MET: chart shows`nMET: filter works" $checks)
        @($r2 | ForEach-Object { "$($_.met)" }) -join ',' | Should Be 'True,True,'
        (@(Format-AcceptanceReport $r) -join "`n") | Should Match '- the status filter changes every chart: NOT MET \(the list ignores it\)'
        (@(Format-AcceptanceReport $r2) -join "`n") | Should Match 'numbers show thousands separators: not answered'
    }
    It 'takes the last answer when a reply answers a check twice (not met, fixed, met)' {
        $checks = @('the page shows figures and charts', 'the table sorts')
        $ans = "NOT MET: the page shows figures and charts - percentages were wrong`nFixed the percentages.`nMET: the page shows figures and charts`nMET: the table sorts"
        @(Read-AcceptanceAnswers $ans $checks | ForEach-Object { $_.met }) -join ',' | Should Be 'True,True'
    }
    It 'asks for the checks and for each answer on its own line' {
        Get-DoneWhenAsk | Should Match "line 'Done when:'"
        New-AcceptanceAsk @('a', 'b') | Should Match "'MET: CHECK' or 'NOT MET: CHECK - why'"
    }
}

Describe 'Data notes: what Copilot wrote about the data, kept per data file' {
    It 'asks for files without notes or with changed data, saves the notes and gives them as context' {
        $p = Join-Path $env:TEMP ('ccb-notes-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        try {
            $man = @{ 'data/orders.json' = @{ hash = 'A1' }; 'data/customers.json' = @{ hash = 'B1' }; 'data/failed.json' = @{ hash = '' } }
            @(Get-DataNotesNeeded $p $man) -join ',' | Should Be 'data/customers.json,data/orders.json'
            $notes = @(Read-NoteBlock "Data notes:`n- orders: one row per order, key Order ID`n- customers: one row per customer; joins orders on Customer ID" 'Data notes' 12)
            $notes.Count | Should Be 2
            Save-DataNotes $p $man @('data/customers.json', 'data/orders.json') $notes
            @(Get-DataNotesNeeded $p $man).Count | Should Be 0
            Format-DataNotes $p | Should Match 'joins orders on Customer ID'
            $man['data/orders.json'] = @{ hash = 'A2' }   # the data changed
            @(Get-DataNotesNeeded $p $man) -join ',' | Should Be 'data/orders.json'
            Get-DataNotesAsk @('data/orders.json') | Should Match "line 'Data notes:'"
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Tie-breakers: Copilot settles what the fixed rules cannot tell from the words' {
    Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
    Import-Module (Join-Path $root 'lib\ProjectSetup.psm1') -Force
    It 'finds a look request the words leave unclear, and leaves clear ones alone' {
        Test-LookUnclear 'add a dark mode to the dashboard' | Should Be $true
        Test-LookUnclear 'add a chart per sector and make the bars blue' | Should Be $true
        Test-LookUnclear 'make the header blue' | Should Be $false
        Test-LookUnclear 'restyle the figures and add a new filter' | Should Be $false
        Test-LookUnclear 'add an export button to the table' | Should Be $false
    }
    It 'reads the request type Copilot states, not from code blocks' {
        Read-RequestType "**Request type:** both`nACTION ..." | Should Be 'both'
        Read-RequestType "Request type: Feature" | Should Be 'feature'
        Read-RequestType ('```text' + "`nRequest type: look`n" + '```') | Should Be ''
        Get-RequestTypeAsk | Should Match "'Request type: look'"
    }
    It 'finds a request near the big-request line, and reads the scope Copilot decides' {
        Test-BigUnclear "Build a page with:`n- a usage chart`n- a sector filter`n- an export button" | Should Be $true
        Test-BigUnclear 'make the header blue' | Should Be $false
        Test-BigUnclear ('x' * 700) | Should Be $false   # clearly big: the project's choice applies without asking
        Read-ScopeDecision "Scope: plan" | Should Be 'plan'
        Read-ScopeDecision "**Scope:** build`nI will now..." | Should Be 'build'
        Read-ScopeDecision 'The scope of this is large' | Should Be ''
        Get-ScopeAsk 'clarify' | Should Match 'questions first'
        Get-ScopeAsk 'plan' | Should Match "'Scope: plan'"
    }
}

Describe 'A reply with only the notes asked for' {
    It 'gets a short go-ahead, and the asks say to go on in the same reply' {
        Get-NotesGoAhead | Should Match 'carry out the task'
        Get-DoneWhenAsk | Should Match 'same reply'
        Get-RequestTypeAsk | Should Match 'same reply'
    }
}

Describe 'Open items in the project to-do list at done' {
    It 'finds open items in TODO.md at the root or in docs/, not in code blocks, and words the Continue message' {
        $p = Join-Path $env:TEMP ('ccb-todo-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p 'docs'), (Join-Path $p '.streamhub') -Force | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $p 'TODO.md'), "# Work`n- [x] Load the data`n- [ ] Add a filter`n1. [ ] Add an export`n" + '```' + "`n- [ ] not an item`n" + '```' + "`n")
            [IO.File]::WriteAllText((Join-Path $p 'docs\TASKS.md'), "- [x] all done`n")
            [IO.File]::WriteAllText((Join-Path $p '.streamhub\PLAN.md'), "- [ ] the helper's own plan`n")
            $o = @(Get-OpenTodoItems $p)
            $o.Count | Should Be 1
            $o[0].file | Should Be 'TODO.md'
            @($o[0].items) -join '|' | Should Be 'Add a filter|Add an export'
            $c = Get-OpenTodoContinue $o
            $c | Should Match 'TODO.md: - Add a filter'
            $c | Should Match 'tick each one off'
            [IO.File]::WriteAllText((Join-Path $p 'TODO.md'), "- [x] done`n")
            @(Get-OpenTodoItems $p).Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Plan coverage before done' {
    It 'takes the files a plan creates or changes, not the ones it removes or temporary ones' {
        $plan = "Files to create:`n- index.html`n- js/app-data.js and css/layout.css`n- tests/app-data.test.js`nFILES TO REMOVE AFTER DISCOVERY`n- Work/probe.js`n- notes/old-list.md`nHOW TO CHECK`n- Open index.html and check the totals`n- Read https://example.com/x.js for reference"
        $files = @(Get-PlanFiles $plan)
        $files -join ',' | Should Be 'index.html,js/app-data.js,css/layout.css,tests/app-data.test.js'
        @(Get-PlanFiles "1. Write Scripts/Export-Items.ps1`n2. Delete the scratch file temp/a.js`n3. Version 1.2 notes") -join ',' | Should Be 'Scripts/Export-Items.ps1'
        # Seen: the build message names .streamhub/PLAN.md; without its dot it was taken for a missing streamhub/PLAN.md.
        @(Get-PlanFiles "Every decision is in .streamhub/PLAN.md. Read it (read .streamhub/PLAN.md) if you need it.`n- ./js/app.js") -join ',' | Should Be 'js/app.js'
    }
    It 'finds placeholder code a change adds, in several languages' {
        (@(Find-StubCode 'js/app.js' '' "function loadItems() {`n  // TODO: read the data`n}`nfunction draw(items) { return items.length; }") -join '|') | Should Match 'function loadItems has an empty body'
        (@(Find-StubCode 'js/app.js' '' "const parse = (text) => {`n}`nexport function total() { throw new Error('Not implemented'); }") -join '|') | Should Match "function parse has an empty body\|code that throws 'not implemented'"
        (@(Find-StubCode 'tool.py' '' "def load(path):`n    `"`"`"Read it.`"`"`"`n    pass`n`ndef run():`n    raise NotImplementedError`n") -join '|') | Should Match 'function load only does pass\|function run only does raise NotImplementedError'
        (@(Find-StubCode 'Scripts/Get-Items.ps1' '' "function Get-Items {`n    # later`n}`n") -join '|') | Should Match 'function Get-Items has an empty body'
        (@(Find-StubCode 'js/app.js' 'let a = 1;' "let a = 1; // FIXME: rounding`nlet b = 2;`nlet c = 3;`nlet d = 4;") -join '|') | Should Match 'a FIXME marker: rounding'
        (@(Find-StubCode 'js/new.js' '' "'use strict';`nwindow.App = {};") -join '|') | Should Match 'the file has only 1 line'
    }
    It 'leaves working code, tests, callbacks and what was already there alone' {
        @(Find-StubCode 'js/app.js' '' "function sum(a, b) { return a + b; }`nbutton.addEventListener('click', () => {});`nconst x = 1;`nconst y = 2;").Count | Should Be 0
        @(Find-StubCode 'tests/app.test.js' '' 'function helper() {}').Count | Should Be 0
        $old = "function keep() {`n}`n// TODO: old note`nconst a = 1;`nconst b = 2;"
        @(Find-StubCode 'js/app.js' $old ($old + "`nconst c = 3;")).Count | Should Be 0
        @(Find-StubCode 'styles/site.css' '' '/* TODO */').Count | Should Be 0
        @(Find-StubCode 'app.js' '' "function a() {`n  return 1;`n}`n").Count | Should Be 0   # short, but real
    }
    It 'reports missing plan files and placeholders against the project, as one message' {
        $p = Join-Path $env:TEMP ('ccb-cov-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p 'js') -Force | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $p 'index.html'), '<!doctype html><title>x</title>')
            [IO.File]::WriteAllText((Join-Path $p 'js\app.js'), "function loadItems() {`n}`nconst a = 1;`nconst b = 2;")
            $cov = Get-PlanCoverage $p @{ 'index.html' = 'new'; 'js/app.js' = 'new' } '' "Files to create:`n- index.html`n- js/app.js`n- js/report.js"
            @($cov.missing) -join ',' | Should Be 'js/report.js'
            @($cov.stubs) -join '|' | Should Match '^js/app\.js: function loadItems has an empty body'
            $m = Format-PlanCoverage $cov
            $m | Should Match '(?s)does not have them:.*- js/report\.js.*placeholders.*Build them now'
            Format-PlanCoverage @{ missing = @(); stubs = @() } | Should Be ''
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'To-do and plan lists are changed without approval' {
    It 'knows the lists by name, not the helper program''s own plan' {
        Test-TaskListFile 'TODO.md' | Should Be $true
        Test-TaskListFile 'docs/PLAN.md' | Should Be $true
        Test-TaskListFile 'notes\tasks.md' | Should Be $true
        Test-TaskListFile 'To-Do.md' | Should Be $true
        Test-TaskListFile '.streamhub/PLAN.md' | Should Be $false
        Test-TaskListFile 'README.md' | Should Be $false
        Test-TaskListFile 'TODO.txt' | Should Be $false
    }
    It 'applies them in Ask before changes mode without a card to approve; other files still ask' {
        Import-Module (Join-Path $root 'lib\Config.psm1') -Force
        Import-Module (Join-Path $root 'lib\Agent.psm1') -Force -DisableNameChecking
        $p = Join-Path $env:TEMP ('ccb-todoauto-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $p 'TODO.md'), "- [ ] First`n- [ ] Second`n")
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'ask'
            # Answers ready, so a wrong approval card cannot hang the test; the check is that none was shown.
            $s.Approvals['t1'] = @{ decision = 'approve'; note = ''; by = 'user' }; $s.Approvals['t2'] = @{ decision = 'approve'; note = ''; by = 'user' }
            $edit = [pscustomobject]@{ type = 'write'; arg = 'TODO.md'; body = "- [x] First`n- [ ] Second`n"; content = "- [x] First`n- [ ] Second`n"; closed = $true }
            $r = & (Get-Module Agent) { param($st, $a) Invoke-AgentAction $st $a 't1' $null 0 } $s $edit
            $r.ok | Should Be $true
            [IO.File]::ReadAllText((Join-Path $p 'TODO.md')) | Should Match '\[x\] First'
            @($s.Events | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' }).Count | Should Be 0
            $other = [pscustomobject]@{ type = 'write'; arg = 'notes.md'; body = 'x'; content = 'x'; closed = $true }
            $null = & (Get-Module Agent) { param($st, $a) Invoke-AgentAction $st $a 't2' $null 0 } $s $other
            @($s.Events | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' }).Count | Should Be 1
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
