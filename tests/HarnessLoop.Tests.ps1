# Ideas from harness engineering, as fixed rules: progress across chats, Done when lines the helper
# program checks in the files itself, the tests before a change, a review in a fresh chat, and test
# runs with checks turned off. Made-up projects in a temporary folder.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-hl-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'Workspace', 'Progress', 'TaskNotes', 'TestRunner', 'Review', 'TestRuns', 'Agent') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

$proj = Join-Path $env:TEMP ('ccb-hl-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'src')
[IO.File]::WriteAllText((Join-Path $proj 'index.html'), "<html><body><h1>Orders</h1><canvas id=`"chart`"></canvas></body></html>")
[IO.File]::WriteAllText((Join-Path $proj 'src\app.js'), "function total(rows) {`n  return rows.length;`n}`n")

Describe 'Progress across chats' {
    $dir = Join-Path $env:CCBRIDGE_STATE_ROOT 'progress'
    $null = New-Item -ItemType Directory -Force -Path $dir
    It 'keeps what a task did on one line each, the newest last, within its limits' {
        $e = New-ProgressEntry -Request "Add a chart of orders`nper region" -Status 'finished' -Result "## Summary`nAdded the chart to index.html." -Changed @('index.html', 'src/app.js') -Acceptance @(@{ check = 'the chart shows regions'; met = $false }, @{ check = 'x'; met = $true }) -Verify @{ passed = $false; preexisting = $true } -Todos @(@{ text = 'add a legend'; done = $false }, @{ text = 'done one'; done = $true }) -Kind 'coding'
        $e.request | Should Be 'Add a chart of orders per region'
        $e.result | Should Be 'Added the chart to index.html.'
        @($e.unmet) -join '|' | Should Be 'the chart shows regions'
        $e.verify | Should Be 'failed as before the task'
        @($e.open) -join '|' | Should Be 'add a legend'
        Add-ProgressEntry $dir $e
        $text = Format-ProgressContext @(Read-ProgressEntries $dir 5)
        $text | Should Match 'Earlier work in this project'
        $text | Should Match 'finished: Add a chart of orders per region Result: Added the chart'
        $text | Should Match 'Changed: index.html, src/app.js\.'
        $text | Should Match 'Checks not met: the chart shows regions\.'
        $text | Should Match 'Still open: add a legend\.'
        $text | Should Not Match 'CCBridge'
    }
    It 'keeps only the newest 50 entries and drops the oldest from the context first' {
        for ($i = 1; $i -le 60; $i++) { Add-ProgressEntry $dir (New-ProgressEntry -Request "Request number $i $('x' * 200)" -Status 'finished' -Result '' -Changed @() -Acceptance @() -Verify $null -Todos @()) }
        @([IO.File]::ReadAllLines((Get-ProgressPath $dir)) | Where-Object { $_ }).Count | Should Be 50
        $last = @(Read-ProgressEntries $dir 5)
        $last.Count | Should Be 5
        $last[4].request | Should Match '^Request number 60 '
        $short = Format-ProgressContext $last 700
        $short | Should Match 'Request number 60'
        $short | Should Not Match 'Request number 56'
        Format-ProgressContext @() | Should Be ''
        Clear-ProgressEntries $dir
        @(Read-ProgressEntries $dir).Count | Should Be 0
    }
}

Describe 'Done when lines the helper program checks itself' {
    It 'checks exists, does not exist, contains and does not contain in the files' {
        (Test-DoneWhenCheck $proj 'index.html exists').met | Should Be $true
        (Test-DoneWhenCheck $proj '`src/app.js` exists').met | Should Be $true
        (Test-DoneWhenCheck $proj 'the file docs/README.md exists').met | Should Be $false
        (Test-DoneWhenCheck $proj 'old.html does not exist').met | Should Be $true
        (Test-DoneWhenCheck $proj 'index.html contains "<canvas id=\"chart\">"') | Should Not BeNullOrEmpty
        (Test-DoneWhenCheck $proj 'index.html contains `<canvas id="chart">`').met | Should Be $true
        (Test-DoneWhenCheck $proj 'index.html contains "&lt;h1&gt;Orders"').met | Should Be $true
        $r = Test-DoneWhenCheck $proj 'index.html contains "<table"'
        $r.met | Should Be $false
        $r.by | Should Be 'helper'
        $r.note | Should Match 'does not contain'
        (Test-DoneWhenCheck $proj "src/app.js does not contain 'console.log'").met | Should Be $true
        (Test-DoneWhenCheck $proj 'src/app.js includes "rows.length"').met | Should Be $true
    }
    It 'leaves judgements and other lines to Copilot' {
        Test-DoneWhenCheck $proj 'README.md contains a usage section' | Should BeNullOrEmpty
        Test-DoneWhenCheck $proj 'the page shows a chart of orders per region' | Should BeNullOrEmpty
        Test-DoneWhenCheck $proj 'index.html exists and loads the chart' | Should BeNullOrEmpty
        (Test-DoneWhenCheck $proj 'index.html contains Orders' -Literal).met | Should Be $true
    }
    It 'never looks outside the project' {
        $r = Test-DoneWhenCheck $proj '../secret.txt exists'
        $r.met | Should Be $false
        $r.note | Should Match 'outside the project'
    }
    It 'asks Copilot only about the rest, names the file lines not met, and keeps its own result' {
        $checks = @('index.html exists', 'index.html contains "<table"', 'the chart shows regions')
        $helper = @(Get-HelperChecks $proj $checks)
        $helper.Count | Should Be 2
        $ask = New-AcceptanceAsk $checks $helper
        $ask | Should Match 'NOT MET:\s*\n- index.html contains "<table"'
        $ask | Should Match "MET: CHECK"
        $ask | Should Not Match '- index.html exists'
        New-AcceptanceAsk @('index.html exists') @(Get-HelperChecks $proj @('index.html exists')) | Should Be ''
        $step = Get-AcceptanceStep @{ ProjectRoot = $proj } $checks
        @($step.asked) -join '|' | Should Be 'the chart shows regions'
        # Copilot says MET for a file line StreamHub finds not met: StreamHub's result counts.
        $answers = @(Read-AcceptanceAnswers "MET: the chart shows regions" @($step.asked))
        $merged = @(Merge-AcceptanceResults $proj $checks $answers)
        @($merged | ForEach-Object { "$($_.met)" }) -join ',' | Should Be 'True,False,True'
        (@(Format-AcceptanceReport $merged) -join "`n") | Should Match 'index.html exists: MET \(checked by StreamHub in the files\)'
        (Get-DoneWhenAsk) | Should Match 'PATH contains "TEXT"'
    }
}

Describe 'Tests before the change' {
    It 'compares failure lines without durations or counts' {
        $before = @(Get-TestFailureLines "Describing A`n [-] adds numbers 12ms`n   Expected 3 but got 4`n [+] other 3ms`nTests completed in 1.2s`nPassed: 1 Failed: 1")
        $before.Count | Should Be 3
        $after = @(Get-TestFailureLines "Describing A`n [-] adds numbers 31ms`n   Expected 3 but got 4`n [-] reads the file 5ms`n   Expected true`nPassed: 0 Failed: 2")
        $cmp = Compare-TestFailures $before $after
        @($cmp.new) -join '|' | Should Be '[-] reads the file Nms|Expected true'
        @($cmp.old).Count | Should Be 3
        $same = Compare-TestFailures $before @(Get-TestFailureLines "[-] adds numbers 99ms`nExpected 3 but got 4`nPassed: 7 Failed: 9")
        @($same.new).Count | Should Be 0
        @(Get-TestFailureLines "FAILED tests/test_x.py::test_y - AssertionError: 1 != 2").Count | Should Be 1
    }
    It 'sees a project file change in its stamp and keeps the last run' {
        $s1 = Get-ProjectStamp $proj
        Get-ProjectStamp $proj | Should Be $s1
        [IO.File]::WriteAllText((Join-Path $proj 'src\more.js'), 'var a = 1;')
        Get-ProjectStamp $proj | Should Not Be $s1
        $dir = Join-Path $env:CCBRIDGE_STATE_ROOT 'tb'
        $null = New-Item -ItemType Directory -Force -Path $dir
        Read-TestBaseline $dir | Should BeNullOrEmpty
        Save-TestBaseline $dir @{ command = 'npm test --silent'; stamp = 'S'; passed = $false; failures = @('a', 'b'); when = 'now' }
        $b = Read-TestBaseline $dir
        $b.command | Should Be 'npm test --silent'
        $b.passed | Should Be $false
        @($b.failures) -join ',' | Should Be 'a,b'
    }
    It 'is not taken when the setting is off or commands are not allowed' {
        Get-TurnTestBaseline @{ ProjectRoot = $proj; Config = [pscustomobject]@{ testBaseline = $false; autoTests = $true } } | Should BeNullOrEmpty
        Get-TurnTestBaseline @{ ProjectRoot = $proj; NoCommands = $true; Config = [pscustomobject]@{ testBaseline = $true; autoTests = $true } } | Should BeNullOrEmpty
    }
}

Describe 'Review in a fresh chat' {
    It 'shows the request, the checks and the change, and names files that do not fit' {
        $contents = @(
            @{ path = 'src/app.js'; created = $false; deleted = $false; old = "function total(rows) {`n  return 0;`n}"; new = "function total(rows) {`n  return rows.length;`n}" },
            @{ path = 'big.js'; created = $true; deleted = $false; old = ''; new = ('var x = "' + ('y' * 200) + '";' + "`n") * 300 })
        $m = New-FreshReviewMessage 'Count the rows' @('src/app.js contains "rows.length"') $contents 9000
        $m | Should Match 'someone else made'
        $m | Should Match 'Count the rows'
        $m | Should Match '- src/app.js contains "rows.length"'
        $m | Should Match '### src/app.js \(changed\)'
        $m | Should Match '\+ \s*return rows.length;'
        $m | Should Match 'Not shown \(too long for one message\): big.js'
        $m | Should Match 'NO PROBLEMS'
        $m | Should Not Match 'CCBridge'
    }
    It 'reads PROBLEM lines with their quote, and nothing from NO PROBLEMS' {
        $reply = "PROBLEM: src/app.js:2 - returns the count, not the total of the amounts`n> return rows.length;`n`n**PROBLEM:** ``index.html``:1 - no chart script is loaded`n> <canvas id=`"chart`"></canvas>`nSome closing words."
        $f = @(Read-FreshReviewFindings $reply)
        $f.Count | Should Be 2
        $f[0].file | Should Be 'src/app.js'
        $f[0].line | Should Be 2
        $f[0].text | Should Be 'returns the count, not the total of the amounts'
        $f[0].quote | Should Be 'return rows.length;'
        $f[1].file | Should Be 'index.html'
        @(Read-FreshReviewFindings 'NO PROBLEMS').Count | Should Be 0
        (Test-ReviewQuote $proj $f[0]).status | Should Be 'verified'
        (Test-ReviewQuote $proj @{ file = 'src/app.js'; line = 1; text = 'x'; quote = 'return rows.size;' }).status | Should Be 'unverified'
        (Get-FreshReviewContinue $f) | Should Match '- src/app.js:2 - returns the count'
    }
}

Describe 'Test runs with checks turned off' {
    It 'turns check switches and on/off settings off for one task and puts them back' {
        $cfg = [pscustomobject]@{ autoTests = $true; pageScreenshot = $true; promptCharBudget = 75000 }
        $st = @{ Config = $cfg }
        Test-CheckSwitch 'quality' | Should Be $true
        $r = Set-TaskSwitchesOff $st @('quality', 'autoTests', 'promptCharBudget', 'unknownThing')
        Test-CheckSwitch 'quality' | Should Be $false
        Test-CheckSwitch 'contrast' | Should Be $true
        $cfg.autoTests | Should Be $false
        $cfg.pageScreenshot | Should Be $true
        $cfg.promptCharBudget | Should Be 75000
        Restore-TaskSwitches $r
        Test-CheckSwitch 'quality' | Should Be $true
        $cfg.autoTests | Should Be $true
        $r2 = Set-TaskSwitchesOff $st @()
        Restore-TaskSwitches $r2
        $cfg.autoTests | Should Be $true
    }
    It 'reads the off: header' {
        $projects = Join-Path $env:TEMP ('ccb-hl-tr-' + [guid]::NewGuid().ToString('N'))
        try {
            $f = Join-Path (Get-TestRunsDir $projects -Create) 'abl.testrun.md'
            [IO.File]::WriteAllText($f, "---`ntitle: Ablation`noff: quality, contrast`n---`n1. Build the page`n")
            @((Read-TestRun $f).off) -join ',' | Should Be 'quality,contrast'
        } finally { Remove-Item $projects -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Remove-Item $proj -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_STATE_ROOT = $null
