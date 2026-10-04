# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# Project state (backups, chat history) of the test projects goes to a temporary folder, deleted below.
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Review.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

function New-ReviewProject {
    $p = Join-Path $env:TEMP ('ccb-review-' + [guid]::NewGuid().ToString('N'))
    $files = @{
        'src/app.js' = "function total(items) {`n  let sum = 0;`n  for (let i = 0; i <= items.length; i++) { sum += items[i].price; }`n  return sum;`n}`n"
        'src/util.ps1' = "function Get-Thing {`n    param(`$Name)`n    Invoke-Expression `"Get-Item `$Name`"`n}`n"
        'node_modules/x/index.js' = 'module.exports = 1;'
        'package-lock.json' = '{}'
        'dist/app.min.js' = 'x'
        'source/data.json' = '{}'
        'README.md' = '# readme'
        'styles.css' = "body { color: red; }`n"
    }
    foreach ($k in $files.Keys) { $f = Join-Path $p $k; $null = New-Item -ItemType Directory -Force (Split-Path $f); [IO.File]::WriteAllText($f, $files[$k]) }
    $p
}

Describe 'Get-ReviewFiles and New-ReviewBatches' {
    $p = New-ReviewProject
    It 'takes code files only (no build output, lock files, data, docs)' {
        (Get-ReviewFiles $p).files -join ',' | Should Be 'src/app.js,src/util.ps1,styles.css'
        (Get-ReviewFiles $p -Paths @('src')).files -join ',' | Should Be 'src/app.js,src/util.ps1'
    }
    It 'batches files with line numbers and splits a file that does not fit' {
        $b = @(New-ReviewBatches $p @('src/app.js', 'src/util.ps1', 'styles.css'))
        $b.Count | Should Be 1
        $b[0].text | Should Match '=== FILE src/app.js \(lines 1-5 of 5\) ==='
        $b[0].text | Should Match '    3\|   for \(let i = 0'
        $small = @(New-ReviewBatches $p @('src/app.js') 150)
        $small.Count | Should BeGreaterThan 1
        $small[0].text | Should Match 'lines 1-\d of 5'
        $small[-1].text | Should Match 'lines \d-5 of 5'
    }
    cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
}

Describe 'Test-ReviewOutput and Test-ReviewQuote' {
    $p = New-ReviewProject
    It 'reads findings and maps severities' {
        $o = Test-ReviewOutput '{"findings":[{"file":"src/app.js","line":3,"severity":"Critical","title":"Off by one"},{"file":"x"}],"summary":"ok"}'
        $o.ok | Should Be $true
        $o.findings.Count | Should Be 1
        $o.findings[0].severity | Should Be 'high'
        $o.dropped | Should Be 1
        (Test-ReviewOutput 'not json').ok | Should Be $false
        (Test-ReviewOutput '{"items":[]}').errors -join '' | Should Match 'findings'
    }
    It 'verifies a finding whose quoted lines are in the file, and corrects its line' {
        $f = Test-ReviewQuote $p @{ file = 'src/app.js'; line = 9; quote = "    3|   for (let i = 0; i <= items.length; i++) { sum += items[i].price; }" }
        $f.status | Should Be 'verified'
        $f.line | Should Be 3
        $f.reportedLine | Should Be 9
    }
    It 'marks invented code as unverified, and project-wide findings as general' {
        (Test-ReviewQuote $p @{ file = 'src/app.js'; line = 2; quote = 'let total = items.reduce(add);' }).status | Should Be 'unverified'
        (Test-ReviewQuote $p @{ file = 'src/nope.js'; line = 1; quote = 'x' }).reason | Should Match 'not found'
        (Test-ReviewQuote $p @{ file = ''; quote = '' } -AllowGeneral).status | Should Be 'general'
    }
    cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
}

Describe 'Fix tasks from findings' {
    It 'groups by file and says what to change' {
        $fs = @(
            @{ id = 'f1'; file = 'a.js'; line = 3; severity = 'high'; category = 'bug'; title = 'Off by one'; detail = 'reads past the end'; suggestion = 'use <'; quote = 'i <= n' },
            @{ id = 'f2'; file = 'b.js'; line = 1; severity = 'low'; category = 'readability'; title = 'Name'; detail = ''; suggestion = ''; quote = '' },
            @{ id = 'f3'; file = 'a.js'; line = 9; severity = 'medium'; category = 'bug'; title = 'No null check'; detail = ''; suggestion = ''; quote = '' }
        )
        $t = @(New-ReviewFixTasks $fs)
        $t.Count | Should Be 2
        ($t | Where-Object { $_.title -like '*a.js (2)' }).text | Should Match '(?s)1\. a\.js:3 - Off by one \(high, bug\).*Suggested fix: use <.*2\. a\.js:9'
        ($t | Where-Object { $_.title -like '*a.js (2)' }).ids -join ',' | Should Be 'f1,f3'
    }
}

Describe 'Invoke-ReviewJob (Copilot mocked)' {
    # The mock runs in the Agent module's scope: its bookkeeping lives in globals.
    $p = New-ReviewProject
    $config = Get-CCBridgeConfig harness $root
    $global:ccbReviewCalls = New-Object System.Collections.Generic.List[string]
    $global:ccbReviewFailPart2 = $true
    Mock -ModuleName Agent Start-NewChat { }
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, [string]$Message)
        $global:ccbReviewCalls.Add($Message)
        $json = $null
        if ($Message -match 'part 1 of') {
            $json = '{"findings":[{"file":"src/app.js","line":3,"severity":"high","category":"bug","title":"Reads past the end","detail":"<= runs one too far","quote":"for (let i = 0; i <= items.length; i++) { sum += items[i].price; }","suggestion":"use <"},{"file":"src/app.js","line":1,"severity":"low","title":"Invented","quote":"const nothing = 1;"}],"summary":"app.js has a bug"}'
        } elseif ($Message -match 'part 2 of') {
            if ($global:ccbReviewFailPart2) { return [pscustomobject]@{ Result = 'OutOfCredits'; ResultMessage = 'You''ve reached your daily limit. Check back at 2:00 AM.'; Text = '' } }
            return [pscustomobject]@{ Result = 'Success'; Text = 'Here you go, no JSON at all.' }
        } elseif ($Message -match 'was not the review JSON') {
            $json = '{"findings":[{"file":"src/util.ps1","line":3,"severity":"high","category":"security","title":"Invoke-Expression with input","quote":"Invoke-Expression \"Get-Item $Name\"","suggestion":"call Get-Item directly"}],"summary":"util has an injection risk"}'
        } elseif ($Message -match 'WHOLE PROJECT') {
            $json = '{"findings":[{"file":"","severity":"medium","category":"tests","title":"No tests","quote":""}],"summary":"Small project with two real issues."}'
        }
        [pscustomobject]@{ Result = 'Success'; Text = "``````json`n$json`n``````" }
    }

    $s = New-AgentState -Config $config -AppRoot $root
    $s.ProjectRoot = $p
    $s.Config = $s.Config.PSObject.Copy()
    $s.Config | Add-Member -NotePropertyName reviewBatchChars -NotePropertyValue 320 -Force   # part 1: app.js, part 2: util.ps1 + styles.css
    $task = @{ kind = 'review'; scope = 'all'; reviewId = 'review-20261002-120000' }

    It 'stops at the daily limit after part 1 and keeps the progress' {
        Invoke-ReviewJob $s $task
        $global:ccbReviewCalls.Count | Should Be 2
        @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'error' })[-1].text | Should Match 'OutOfCredits'
        Test-Path (Join-Path $p 'reviews\review-20261002-120000.json') | Should Be $false
    }

    It 'continues with part 2 (asking once for valid JSON), runs the whole-project pass and saves a checked report' {
        $global:ccbReviewFailPart2 = $false
        $global:ccbReviewCalls.Clear()
        Invoke-ReviewJob $s $task
        @($global:ccbReviewCalls | Where-Object { $_ -match 'part 1 of' }).Count | Should Be 0
        $rv = [IO.File]::ReadAllText((Join-Path $p 'reviews\review-20261002-120000.json')) | ConvertFrom-Json
        $rv.overall | Should Be 'Small project with two real issues.'
        @($rv.findings | Where-Object { $_.status -eq 'verified' }).Count | Should Be 2
        @($rv.findings | Where-Object { $_.status -eq 'unverified' }).title | Should Be 'Invented'
        @($rv.findings | Where-Object { $_.status -eq 'general' }).title | Should Be 'No tests'
        $rv.findings[0].id | Should Be 'f1'
        $rv.findings[0].severity | Should Be 'high'
        $md = [IO.File]::ReadAllText((Join-Path $p 'reviews\review-20261002-120000.md'))
        $md | Should Match '## High'
        $md | Should Match '## Unverified'
        (@(Get-Reviews $p))[0].high | Should Be 2
        @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'review' }).Count | Should Be 1
    }
    cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
}

if ($env:CCBRIDGE_STATE_ROOT -and (Test-Path -LiteralPath $env:CCBRIDGE_STATE_ROOT)) { [IO.Directory]::Delete($env:CCBRIDGE_STATE_ROOT, $true) }
$env:CCBRIDGE_STATE_ROOT = $null