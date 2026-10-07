# Fix case logs (lib/FixCases.psm1, Agent Invoke-IssueCycle): a problem that needed more than one try
# gets a case file, fixed or not, with the change that brought it, every try and the outcome.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'FixCases', 'Executor', 'Issues', 'Agent', 'Config') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'A fix case file' {
    It 'tells the problem, what brought it, each try with the diagnosis, and the outcome' {
        $p = Join-Path $env:TEMP ('ccb-fc-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $rel = Write-FixCase $p @{ kind = 'issue fix'; path = 'js/app.js'; problems = @("line 4: '{' is never closed"); request = 'Add a filter to the list'
            change = "- old line`n+ new line"; outcome = 'fixed at try 2'; fixed = $true
            attempts = @(@{ attempt = 1; how = 'the problems listed'; diagnosis = ''; left = @("line 4: '{' is never closed") }, @{ attempt = 2; how = 'cause first'; diagnosis = 'The arrow function was closed twice.'; left = @() }) }
        $rel | Should Match '^\.streamhub/FixCases/case-\d{8}-\d{6}-app\.js\.md$'
        $t = [IO.File]::ReadAllText((Join-Path $p $rel.Replace('/', '\')))
        $t | Should Match '# Fix case: js/app\.js \(fixed\)'
        $t | Should Match '- StreamHub: '
        $t | Should Match 'Request: Add a filter to the list'
        $t | Should Match '(?s)```diff.*\+ new line'
        $t | Should Match "### Try 2: cause first"
        $t | Should Match "Copilot's diagnosis: The arrow function was closed twice\."
        $t | Should Match 'Still there after it: nothing \(fixed\)'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Fix cases from the issue cycle' {
    $mk = {
        $p = Join-Path $env:TEMP ('ccb-fc-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s.ProjectRoot = $p
        @{ p = $p; s = $s }
    }
    $fix = { param($attempt) @{ path = 'app.js'; ids = @('i1'); attempt = $attempt; categories = @('error'); origin = ''; request = 'Make the header sticky'; problems = @("line 1: '{' is never closed")
        history = @(@{ attempt = 1; how = 'the problems listed'; diagnosis = ''; left = @("line 1: '{' is never closed") }) } }
    It 'records a problem that is still there after the last try' {
        $c = & $mk
        Mock -ModuleName Agent Update-IssueIndex { }
        Mock -ModuleName Agent Get-IssueReport { @([pscustomobject]@{ id = 'i1'; path = 'app.js'; category = 'error'; status = 'fixing'; line = 1; message = "'{' is never closed" }) }
        Mock -ModuleName Agent Set-IssueState { }
        $null = Invoke-IssueCycle $c.s @('app.js') @{} (& $fix 3)
        $files = @(Get-ChildItem (Join-Path $c.p '.streamhub\FixCases') -Filter 'case-*.md')
        $files.Count | Should Be 1
        $t = [IO.File]::ReadAllText($files[0].FullName)
        $t | Should Match 'not fixed'
        $t | Should Match "Outcome: still there after 3 tries; marked 'gave up'"
        $t | Should Match 'Request: Make the header sticky'
        $t | Should Match '### Try 3: fresh eyes'
        @(Get-AgentEvents $c.s 0 | Where-Object { $_.text -match 'Fix case recorded for review' }).Count | Should Be 1
        Remove-Item $c.p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'records a problem fixed at the second try, and nothing for one fixed at the first' {
        $c = & $mk
        Mock -ModuleName Agent Update-IssueIndex { }
        Mock -ModuleName Agent Get-IssueReport { @() }
        Mock -ModuleName Agent Set-IssueState { }
        $null = Invoke-IssueCycle $c.s @('app.js') @{} (& $fix 2)
        $files = @(Get-ChildItem (Join-Path $c.p '.streamhub\FixCases') -Filter 'case-*.md' -ErrorAction SilentlyContinue)
        $files.Count | Should Be 1
        [IO.File]::ReadAllText($files[0].FullName) | Should Match 'Outcome: fixed at try 2'
        $c2 = & $mk
        $null = Invoke-IssueCycle $c2.s @('app.js') @{} (& $fix 1)
        Test-Path (Join-Path $c2.p '.streamhub\FixCases') | Should Be $false
        Remove-Item $c.p, $c2.p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
