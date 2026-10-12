# What Copilot writes down for the helper program: the checks a task must pass ("Done when:"),
# answered MET / NOT MET at the end, and notes on the project's data ("Data notes:").
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\TaskNotes.psm1') -Force

Describe 'Done when: the checks Copilot sets at the start' {
    It 'reads the list under the heading, in the forms Copilot writes it, and nothing from code blocks' {
        $reply = "I will build the dashboard.`n`n**Done when:**`n- the page shows a chart of users per tier`n- [ ] the sector filter changes every chart`n2. numbers show thousands separators`n`nNow the files:`n" + '```text' + "`nACTION write index.html`n" + '```'
        @(Read-DoneWhen $reply) -join ' | ' | Should Be 'the page shows a chart of users per tier | the sector filter changes every chart | numbers show thousands separators'
        @(Read-DoneWhen "Done when: it works").Count | Should Be 0
        @(Read-DoneWhen ('```text' + "`nDone when:`n- inside a block`n" + '```')).Count | Should Be 0
    }
    It 'matches MET / NOT MET answers to the checks by their text or in order' {
        $checks = @('the page shows a chart of users per tier', 'the sector filter changes every chart', 'numbers show thousands separators')
        $ans = "MET: the page shows a chart of users per tier`n**NOT MET:** the sector filter changes every chart - the bar list ignores it`nMET: numbers show thousands separators"
        $r = @(Read-AcceptanceAnswers $ans $checks)
        @($r | ForEach-Object { $_.met }) -join ',' | Should Be 'True,False,True'
        $r[1].note | Should Be 'the bar list ignores it'
        $r2 = @(Read-AcceptanceAnswers "MET: chart shows`nMET: filter works" $checks)
        @($r2 | ForEach-Object { "$($_.met)" }) -join ',' | Should Be 'True,True,'
        (@(Format-AcceptanceReport $r) -join "`n") | Should Match '- the sector filter changes every chart: NOT MET \(the bar list ignores it\)'
        (@(Format-AcceptanceReport $r2) -join "`n") | Should Match 'numbers show thousands separators: not answered'
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
            $man = @{ 'data/usage.json' = @{ hash = 'A1' }; 'data/hr.json' = @{ hash = 'B1' }; 'data/failed.json' = @{ hash = '' } }
            @(Get-DataNotesNeeded $p $man) -join ',' | Should Be 'data/hr.json,data/usage.json'
            $notes = @(Read-NoteBlock "Data notes:`n- usage: one row per user, key User Principal Name`n- hr: one row per employee; joins usage on Email = User Principal Name" 'Data notes' 12)
            $notes.Count | Should Be 2
            Save-DataNotes $p $man @('data/hr.json', 'data/usage.json') $notes
            @(Get-DataNotesNeeded $p $man).Count | Should Be 0
            Format-DataNotes $p | Should Match 'joins usage on Email = User Principal Name'
            $man['data/usage.json'] = @{ hash = 'A2' }   # the data changed
            @(Get-DataNotesNeeded $p $man) -join ',' | Should Be 'data/usage.json'
            Get-DataNotesAsk @('data/usage.json') | Should Match "line 'Data notes:'"
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
