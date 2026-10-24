# The gates of the done step (Agent.psm1 Invoke-Done*), each on its own: when it runs, the message
# that sends Copilot back, the counters it keeps in the turn's $Turn hashtable, and that it returns
# exactly one string or nothing (a stray output would turn the message into a list). The checks
# themselves (tool runs, window apps, the import index) are stood in; nothing is started.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force

function New-GateState {
    $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
    $s.ProjectRoot = Join-Path $env:TEMP ('ccb-gates-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $s.ProjectRoot -Force | Out-Null
    $s.Mode = 'auto'
    $s
}
function New-GateTurn {
    @{ verifyNudges = 0; toolNudges = 0; guiNudges = 0; hookNudges = 0; coverageNudges = 0; notAppliedNudges = 0
        doneReminded = $false; unloadedChecked = $false; notApplied = $false; testBase = $null
        reviewed = $false; stop = $false; pagesToRecheck = @(); pageRechecks = 0; pageFinal = $false
        shotShown = $false; shotAgain = $false; sameNudges = 0; sameLimit = 1; shotNote = ''; attach = @()
        acceptAsked = $false; acceptAskList = @() }
}
$changed = @{ Files = @{ 'js/app.js' = 'changed'; 'js/extra.js' = 'new'; 'App.ps1' = 'changed' }; Dir = '' }
$nothing = @{ Files = @{}; Dir = '' }
$standard = @{ testTries = 2; hookTries = 2; errorTries = 2 }

function Invoke-Gate([string]$Name) {
    # One gate as the turn calls it, with the arguments after the name passed on as they are and its
    # result kept whole (not unrolled) to check its shape.
    # (No Should in here: in Pester 3.4 it adds $true to this helper's own output.)
    $r = @(& (Get-Module Agent) { param($n, [object[]]$rest) & $n @rest } $Name $args)
    if ($r.Count -gt 1 -or ($r.Count -and $r[0] -isnot [string])) { throw "$Name returned $($r.Count) item(s) of type $($r[0].GetType().Name), not one message" }
    if ($r.Count) { $r[0] } else { $null }
}

Describe 'Done gate: new files nothing loads' {
    Mock -ModuleName Agent Find-UnloadedFiles { @('js/extra.js') }
    It 'sends back the new files nothing loads, once per task, and records them' {
        $s = New-GateState; $t = New-GateTurn; $ev = @{ unloaded = @() }
        $m = Invoke-Gate 'Invoke-DoneUnloadedCheck' $s $t $changed $ev
        $m | Should Match 'no page, script or stylesheet loads them'
        $m | Should Match '- js/extra\.js'
        $t.unloadedChecked | Should Be $true
        @($ev.unloaded) | Should Be 'js/extra.js'
        Invoke-Gate 'Invoke-DoneUnloadedCheck' $s $t $changed $ev | Should BeNullOrEmpty   # once
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'does nothing in Plan only mode or when nothing changed, and leaves the flag for later' {
        $s = New-GateState; $t = New-GateTurn
        Invoke-Gate 'Invoke-DoneUnloadedCheck' $s $t $nothing @{} | Should BeNullOrEmpty
        $s.Mode = 'plan'
        Invoke-Gate 'Invoke-DoneUnloadedCheck' $s $t $changed @{} | Should BeNullOrEmpty
        $t.unloadedChecked | Should Be $false
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Done gate: the project''s build and check tools' {
    Mock -ModuleName Agent Test-CheckSwitch { $true }
    Mock -ModuleName Agent Get-ToolChecks { @(@{ name = 'tsc'; kind = 'tsc'; command = 'npx tsc --noEmit' }) }
    Mock -ModuleName Agent Invoke-RunAction { @{ output = 'src/a.ts(3,1): error TS2304'; exitCode = 2; timedOut = $false } }
    Mock -ModuleName Agent Get-ToolCheckErrors { @('src/a.ts:3: error TS2304') }
    It 'sends the errors back with a card, up to the enforcement''s tries' {
        $s = New-GateState; $t = New-GateTurn
        $m = Invoke-Gate 'Invoke-DoneToolChecks' $s $t $changed $standard
        $m | Should Match "build and check tools found errors"
        $m | Should Match '- src/a\.ts:3: error TS2304'
        $t.toolNudges | Should Be 1
        @($s.Events | Where-Object { $_.type -eq 'action' -and $_.target -eq 'Check with tsc' }).Count | Should Be 1
        @($s.Events | Where-Object { $_.type -eq 'action-result' -and -not $_.ok }).Count | Should Be 1
        Invoke-Gate 'Invoke-DoneToolChecks' $s $t $changed $standard | Should Match 'found errors'
        $t.toolNudges | Should Be 2
        Invoke-Gate 'Invoke-DoneToolChecks' $s $t $changed $standard | Should BeNullOrEmpty   # tries used up
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'counts but does not send back with enforcement Light, and runs nothing without commands' {
        $s = New-GateState; $t = New-GateTurn
        Invoke-Gate 'Invoke-DoneToolChecks' $s $t $changed @{ testTries = 0 } | Should BeNullOrEmpty
        $t.toolNudges | Should Be 1
        $s.NoCommands = $true; $t2 = New-GateTurn
        Invoke-Gate 'Invoke-DoneToolChecks' $s $t2 $changed $standard | Should BeNullOrEmpty
        $t2.toolNudges | Should Be 0
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Done gate: window apps' {
    Mock -ModuleName Agent Find-GuiScripts { @('App.ps1') }
    Mock -ModuleName Agent Test-GuiLauncher { '' }
    Mock -ModuleName Agent Test-PsGuiApp { @{ opened = $false; errors = @('Unable to find type [Windows.Window]'); steps = @(); access = @(); layout = @() } }
    It 'sends back a window app that did not open, with a card' {
        $s = New-GateState; $t = New-GateTurn
        $m = Invoke-Gate 'Invoke-DoneGuiTest' $s $t $changed $standard
        $m | Should Match 'did not open cleanly'
        $m | Should Match 'App\.ps1:'
        $m | Should Match 'Unable to find type'
        $t.guiNudges | Should Be 1
        @($s.Events | Where-Object { $_.type -eq 'action-result' -and $_.summary -eq 'no window opened' }).Count | Should Be 1
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'does not start window apps for a task from another program (headless) or with tests off' {
        $s = New-GateState; $t = New-GateTurn
        $s.Headless = $true
        Invoke-Gate 'Invoke-DoneGuiTest' $s $t $changed $standard | Should BeNullOrEmpty
        $s.Headless = $false; $s.Config.autoTests = $false
        Invoke-Gate 'Invoke-DoneGuiTest' $s $t $changed $standard | Should BeNullOrEmpty
        $t.guiNudges | Should Be 0
        Assert-MockCalled -ModuleName Agent Test-PsGuiApp -Times 0 -Exactly -Scope It
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Done gate: a change the person said did not take effect' {
    Mock -ModuleName Agent Get-NotAppliedRefusal { 'No file changed: find the cause.' }
    It 'refuses done without a changed file three times, then lets it through' {
        $s = New-GateState; $t = New-GateTurn; $t.notApplied = $true
        foreach ($i in 1..3) { Invoke-Gate 'Invoke-DoneNotApplied' $s $t $nothing | Should Be 'No file changed: find the cause.' }
        $t.notAppliedNudges | Should Be 3
        Invoke-Gate 'Invoke-DoneNotApplied' $s $t $nothing | Should BeNullOrEmpty
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'lets done through when files changed or the person reported nothing' {
        $s = New-GateState; $t = New-GateTurn; $t.notApplied = $true
        Invoke-Gate 'Invoke-DoneNotApplied' $s $t $changed | Should BeNullOrEmpty
        $t.notApplied = $false
        Invoke-Gate 'Invoke-DoneNotApplied' $s $t $nothing | Should BeNullOrEmpty
        $t.notAppliedNudges | Should Be 0
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Done gate: the one reminder' {
    Mock -ModuleName Agent Get-DoneReminders { 'Add a test for the change.' }
    It 'reminds once per task, not for issue fixes' {
        $s = New-GateState; $t = New-GateTurn
        Invoke-Gate 'Invoke-DoneReminders' $s $t $changed | Should Be 'Add a test for the change.'
        $t.doneReminded | Should Be $true
        Invoke-Gate 'Invoke-DoneReminders' $s $t $changed | Should BeNullOrEmpty
        $s.IssueFix = @{ path = 'js/app.js' }; $t2 = New-GateTurn
        Invoke-Gate 'Invoke-DoneReminders' $s $t2 $changed | Should BeNullOrEmpty
        $t2.doneReminded | Should Be $false
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Done gate: what the plan names' {
    Mock -ModuleName Agent Get-PlanCoverage { @{ missing = @('js/chart.js'); stubs = @('js/app.js: drawChart is empty') } }
    Mock -ModuleName Agent Format-PlanCoverage { 'The plan names js/chart.js, which is missing.' }
    It 'sends missing files and placeholders back at most twice, and records them' {
        $s = New-GateState; $t = New-GateTurn; $ev = @{}
        Invoke-Gate 'Invoke-DonePlanCoverage' $s $t $changed $ev | Should Be 'The plan names js/chart.js, which is missing.'
        @($ev.coverage) -join '|' | Should Be 'missing: js/chart.js|js/app.js: drawChart is empty'
        Invoke-Gate 'Invoke-DonePlanCoverage' $s $t $changed $ev | Should Not BeNullOrEmpty
        Invoke-Gate 'Invoke-DonePlanCoverage' $s $t $changed $ev | Should BeNullOrEmpty
        $t.coverageNudges | Should Be 2
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'records an empty list when everything is there' {
        Mock -ModuleName Agent Format-PlanCoverage { '' }
        $s = New-GateState; $t = New-GateTurn; $ev = @{ coverage = @('old') }
        Invoke-Gate 'Invoke-DonePlanCoverage' $s $t $changed $ev | Should BeNullOrEmpty
        @($ev.coverage).Count | Should Be 0
        $t.coverageNudges | Should Be 0
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Done gate: the project''s check or tests' {
    Mock -ModuleName Agent Get-ProjectVerify { 'npm test' }
    Mock -ModuleName Agent Get-CommandRisk { @{ m365 = $false; destructive = $false } }
    Mock -ModuleName Agent Test-DeleteScope { '' }
    Mock -ModuleName Agent New-RunWatch { { } }
    Mock -ModuleName Agent Stop-RunWatch { }
    Mock -ModuleName Agent Invoke-RunAction { @{ output = "1 failing`nX broke"; exitCode = 1; timedOut = $false } }
    Mock -ModuleName Agent Get-TestFailureLines { @('X broke') }
    It 'sends a failing check back up to the enforcement''s tries, with the end of its output' {
        $s = New-GateState; $t = New-GateTurn; $ev = @{}
        $m = Invoke-Gate 'Invoke-DoneVerify' $s $t $changed $ev $standard
        $m | Should Match "The project's check failed"
        $m | Should Match 'Command: npm test \(exit 1\)'
        $m | Should Match 'X broke'
        $ev.verify.passed | Should Be $false
        $t.verifyNudges | Should Be 1
        Invoke-Gate 'Invoke-DoneVerify' $s $t $changed $ev $standard | Should Not BeNullOrEmpty
        Invoke-Gate 'Invoke-DoneVerify' $s $t $changed $ev $standard | Should BeNullOrEmpty   # tries used up
        $t.verifyNudges | Should Be 2
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'does not send back failures that were there before the change' {
        $s = New-GateState; $t = New-GateTurn; $ev = @{}
        $t.testBase = @{ command = 'other'; passed = $false; failures = @('X broke') }
        Invoke-Gate 'Invoke-DoneVerify' $s $t $changed $ev $standard | Should BeNullOrEmpty
        $ev.verify.preexisting | Should Be $true
        $t.verifyNudges | Should Be 0
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'records the check as skipped when commands are not allowed, without running it' {
        $s = New-GateState; $t = New-GateTurn; $ev = @{}; $s.NoCommands = $true
        Invoke-Gate 'Invoke-DoneVerify' $s $t $changed $ev $standard | Should BeNullOrEmpty
        $ev.verify.skipped | Should Match 'not allowed'
        Assert-MockCalled -ModuleName Agent Invoke-RunAction -Times 0 -Exactly -Scope It
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Done gate: beforeDone hooks' {
    Mock -ModuleName Agent Invoke-ProjectHooks { @('lint: 2 errors') }
    It 'sends a failing hook back up to its tries' {
        $s = New-GateState; $t = New-GateTurn
        $m = Invoke-Gate 'Invoke-DoneHooks' $s $t $changed $standard
        $m | Should Match 'A check of the project failed'
        $m | Should Match 'lint: 2 errors'
        Invoke-Gate 'Invoke-DoneHooks' $s $t $changed $standard | Should Not BeNullOrEmpty
        Invoke-Gate 'Invoke-DoneHooks' $s $t $changed $standard | Should BeNullOrEmpty
        $t.hookNudges | Should Be 2
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'only shows a failing hook with enforcement Light' {
        $s = New-GateState; $t = New-GateTurn
        Invoke-Gate 'Invoke-DoneHooks' $s $t $changed @{ hookTries = 0 } | Should BeNullOrEmpty
        $t.hookNudges | Should Be 99
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match 'enforcement Light' }).Count | Should Be 1
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Done step: the review, the page rechecks and the screenshot' {
    Mock -ModuleName Agent Get-CheckpointChanges { @(@{ path = 'index.html'; added = 3; removed = 1; deleted = $false }) }
    Mock -ModuleName Agent Test-ScriptSyntax { @() }
    Mock -ModuleName Agent Test-ProjectConsistency { @() }
    Mock -ModuleName Agent Get-ScreenshotHint { 'HINT' }
    Mock -ModuleName Agent Get-AcceptanceStep { @{ asked = @('the chart shows'); helper = @(); text = 'Answer MET or NOT MET.' } }
    Mock -ModuleName Agent Get-BeforeAfterNotes { @{ same = @(); notes = @(); pairs = @(); crops = @() } }
    Mock -ModuleName Agent Test-WebPage { @('index.html: Uncaught TypeError') }
    Mock -ModuleName Agent Split-PageWarnings { @($Issues) }
    Mock -ModuleName Agent New-ReviewMessage { 'Review the change.' }
    function New-PageState { $s = New-GateState; $s.PreviewPort = 1; $s.Config.pageCheck = 'on'; $s }

    It 'asks for a review when the page check finds errors, with the Done when checks once, then rechecks the page' {
        $s = New-PageState; $t = New-GateTurn; $ev = @{}
        $m = Invoke-Gate 'Invoke-DoneReview' $s $t $changed $ev $standard @('the chart shows')
        $m | Should Match '^Review the change\.'
        $m | Should Match 'Answer MET or NOT MET\.'
        $t.reviewed | Should Be $true; $t.acceptAsked | Should Be $true
        @($t.acceptAskList) | Should Be 'the chart shows'
        @($t.pagesToRecheck) | Should Be 'index.html'
        $m2 = Invoke-Gate 'Invoke-DoneReview' $s $t $changed $ev $standard @('the chart shows')
        $m2 | Should Match 'still finds problems after your fix'
        $m2 | Should Not Match 'MET or NOT MET'   # asked once
        $t.pageRechecks | Should Be 1
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'reports the page errors left once the tries are used up, without sending them back' {
        $s = New-PageState; $t = New-GateTurn; $ev = @{}
        $t.reviewed = $true; $t.pagesToRecheck = @('index.html'); $t.pageRechecks = 2
        Invoke-Gate 'Invoke-DoneReview' $s $t $changed $ev $standard @() | Should BeNullOrEmpty
        $t.pageFinal | Should Be $true; $ev.pageLeft | Should Be $true
        @($s.Events | Where-Object { $_.type -eq 'error' -and $_.code -eq 'PAGE-ERRORS' }).Count | Should Be 1
        Invoke-Gate 'Invoke-DoneReview' $s $t $changed $ev $standard @() | Should BeNullOrEmpty
        @($s.Events | Where-Object { $_.code -eq 'PAGE-ERRORS' }).Count | Should Be 1   # once
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'gives a task the calling model reviews the local check results and ends the turn' {
        $s = New-PageState; $t = New-GateTurn; $s.ReviewByCaller = $true
        Invoke-Gate 'Invoke-DoneReview' $s $t $changed @{} $standard @() | Should BeNullOrEmpty
        $t.stop | Should Be $true
        @($s.Events | Where-Object { $_.review -eq 'caller' -and $_.text -match 'Local checks found 1 problem' }).Count | Should Be 1
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'sends a clean page''s screenshot to compare, once per task' {
        Mock -ModuleName Agent Test-WebPage { @() }
        Mock -ModuleName Agent Test-NeedsReview { $false }
        $s = New-PageState; $t = New-GateTurn
        $s.PageShots = @('.streamhub/Screenshots/page-1.png')
        $m = Invoke-Gate 'Invoke-DoneReview' $s $t $changed @{} $standard @()
        $m | Should Match '^Attached: a screenshot of the page as it looks now'
        $m | Should Match 'HINT'
        $t.shotShown | Should Be $true
        @($t.attach).Count | Should Be 1
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'sends a page that looks exactly the same back with before and after, up to the limit' {
        Mock -ModuleName Agent Test-WebPage { @() }
        Mock -ModuleName Agent Test-NeedsReview { $false }
        Mock -ModuleName Agent Get-BeforeAfterNotes { @{ same = @('index.html'); notes = @('index.html looks exactly the same'); pairs = @(@{ page = 'index.html'; before = 'b.png'; after = 'a.png' }); crops = @() } }
        $s = New-PageState; $t = New-GateTurn
        $s.PageShots = @('a.png')
        $m = Invoke-Gate 'Invoke-DoneReview' $s $t $changed @{} $standard @()
        $m | Should Match 'The first image is the page now'
        @($t.attach).Count | Should Be 2
        $t.shotAgain | Should Be $true; $t.sameNudges | Should Be 1
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Done step: the Done when checks and the closing cards' {
    Mock -ModuleName Agent Get-AcceptanceStep { @{ asked = @('a', 'b'); helper = @('c'); text = 'Check these.' } }
    It 'asks the Done when checks once when no other message carried them' {
        $s = New-GateState; $t = New-GateTurn
        Invoke-Gate 'Invoke-DoneAcceptanceAsk' $s $t $changed @('a', 'b', 'c') | Should Be 'Check these.'
        @($t.acceptAskList).Count | Should Be 2
        Invoke-Gate 'Invoke-DoneAcceptanceAsk' $s $t $changed @('a', 'b', 'c') | Should BeNullOrEmpty
        Invoke-Gate 'Invoke-DoneAcceptanceAsk' $s (New-GateTurn) $changed @() | Should BeNullOrEmpty
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'shows the results and a Continue card for open to-do items and checks not met' {
        Mock -ModuleName Agent Get-OpenTodoItems { @(@{ file = 'TODO.md'; items = @('add export') }) }
        Mock -ModuleName Agent Get-OpenTodoContinue { 'Do the open items.' }
        Mock -ModuleName Agent Get-UnmetChecksContinue { 'Meet the checks.' }
        $s = New-GateState
        $res = @(@{ check = 'a'; met = $true; by = 'copilot' }, @{ check = 'b'; met = $false; by = 'helper'; note = 'missing' })
        $out = @(& (Get-Module Agent) { param($s, $r) Publish-DoneResults $s $r } $s $res)
        $out.Count | Should Be 0
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match '1 checked by StreamHub.*1 of 2 not met: b' }).Count | Should Be 1
        $cards = @($s.Events | Where-Object { $_.type -eq 'task-unfinished' })
        $cards.Count | Should Be 2
        $cards[0].continueText | Should Be 'Do the open items.'
        $cards[1].findings | Should Be 'b: missing'
        $s.Headless = $true; $s.Events.Clear()
        $null = & (Get-Module Agent) { param($s, $r) Publish-DoneResults $s $r } $s $res
        @($s.Events | Where-Object { $_.type -eq 'task-unfinished' }).Count | Should Be 0   # never for another program
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Remove-Item -LiteralPath $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
