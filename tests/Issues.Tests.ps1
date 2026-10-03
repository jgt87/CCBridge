# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# The issue cycle: code-health limits, the project's issue details (.streamhub\issues.json), the app
# index that imports them, incremental re-indexing, statuses, and the fix cycle after a task.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Issues.psm1') -Force
Import-Module (Join-Path $root 'lib\Health.psm1') -Force

function New-TestProject {
    $dir = Join-Path $env:TEMP ('ccb-issues-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path $dir
    $dir
}
function Set-TestFile([string]$Dir, [string]$Rel, [string]$Text) {
    $p = Join-Path $Dir $Rel
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $p)
    [IO.File]::WriteAllText($p, $Text)
    # A different time each write, so the incremental index sees the change even within a second.
    (Get-Item -LiteralPath $p).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(- (Get-Random -Maximum 100000))
}
function Get-BigPsFunction([string]$Name) {
    $body = (1..25 | ForEach-Object { "    if (`$x -eq $_) { if (`$y) { foreach (`$z in 1..2) { while (`$z) { if (`$z -gt $_) { `$z-- } else { break } } } } }" }) -join "`n"
    "function $Name(`$x, `$y) {`n$body`n}`n"
}

$env:CCBRIDGE_ISSUE_INDEX = Join-Path $env:TEMP ('ccb-app-index-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')

Describe 'Code health per language' {
    It 'measures PowerShell, JavaScript and Python functions' {
        $ps = @(Get-FunctionMetrics 'a.ps1' "function Small { if (`$a) { 1 } else { 2 } }")
        $ps[0].name | Should Be 'Small'
        $ps[0].ccn | Should Be 2
        $js = @(Get-FunctionMetrics 'a.js' "function f(a) {`n  if (a && b) { return 1; }`n  for (;;) { break; }`n}")
        $js[0].name | Should Be 'f'
        $js[0].ccn -ge 3 | Should Be $true
        $py = @(Get-FunctionMetrics 'a.py' "def g(a):`n    if a:`n        return 1`n    return 2`n")
        $py[0].name | Should Be 'g'
        $py[0].ccn | Should Be 2
    }
    It 'reports only functions that are clearly too much, without scores' {
        @(Get-HealthIssues 'a.ps1' "function Small { 1 }").Count | Should Be 0
        $h = @(Get-HealthIssues 'a.ps1' (Get-BigPsFunction 'Huge'))
        $h.Count | Should Be 1
        $h[0].message | Should Match "function 'Huge' \(lines 1-27\) is very complex"
        $h[0].PSObject.Properties.Name -contains 'score' | Should Be $false
    }
}

Describe 'Get-FileIssues' {
    $dir = New-TestProject
    It 'sorts problems into error, secret and health with stable ids' {
        $text = "const a = [1, 2;`nconst key = 'AKIAABCDEFGHIJKLMNOP';`n"
        $i = @(Get-FileIssues $dir 'app.js' $text)
        @($i | Where-Object category -eq 'error').Count -ge 1 | Should Be $true
        @($i | Where-Object category -eq 'secret').Count | Should Be 1
        $again = @(Get-FileIssues $dir 'app.js' ("// moved down`n" + $text))
        ($again | Where-Object category -eq 'secret').id | Should Be ($i | Where-Object category -eq 'secret').id
    }
    It 'does not report fake keys in test files' {
        @(Get-FileIssues $dir 'tests/app.test.js' "const key = 'AKIAABCDEFGHIJKLMNOP';`n" | Where-Object category -eq 'secret').Count | Should Be 0
    }
    It 'knows functions defined anywhere in the project (no "not a command" false alarm)' {
        Set-TestFile $dir 'lib/Tools.psm1' "function Get-ProjectThing { 1 }`n"
        @(Get-FileIssues $dir 'run.ps1' "Get-ProjectThing`n" | Where-Object message -match 'not a command').Count | Should Be 0
        @(Get-FileIssues $dir 'run.ps1' "Get-ProjectThingz`n" | Where-Object message -match 'not a command').Count | Should Be 1
    }
    Remove-Item -LiteralPath $dir -Recurse -Force
}

Describe 'Issue index: details in the project, summary in the app index' {
    $dir = New-TestProject
    Set-TestFile $dir 'ok.js' "const a = 1;`n"
    Set-TestFile $dir 'bad.js' "const a = [1, 2;`n"
    Set-TestFile $dir 'source/data.js' "const broken = [;`n"   # user data: never indexed

    It 'indexes every file and keeps the details in .streamhub\issues.json' {
        $r = Update-IssueIndex $dir
        $r.scanned | Should Be 2
        $r.counts.error -ge 1 | Should Be $true
        Test-Path (Join-Path $dir '.streamhub\issues.json') | Should Be $true
        @(Get-IssueReport $dir | Where-Object path -eq 'source/data.js').Count | Should Be 0
    }
    It 'imports the project into the app index' {
        $p = @(Get-AppIssueIndex | Where-Object { $_.root -eq $dir })
        $p.Count | Should Be 1
        $p[0].files | Should Be 2
        $p[0].open.error -ge 1 | Should Be $true
    }
    It 'scans only what changed the next time' {
        (Update-IssueIndex $dir).scanned | Should Be 0
        Set-TestFile $dir 'bad.js' "const a = [1, 2];`n"
        $r = Update-IssueIndex $dir
        $r.scanned | Should Be 1
        $r.counts.error | Should Be 0
    }
    It 'drops files that are gone' {
        Remove-Item -LiteralPath (Join-Path $dir 'ok.js')
        $null = Update-IssueIndex $dir
        (Read-IssueIndex $dir).files.ContainsKey('ok.js') | Should Be $false
    }
    It 'keeps an ignored issue out of the counts, and forgets the status once the issue is gone' {
        Set-TestFile $dir 'bad.js' "const a = [1, 2;`n"
        $null = Update-IssueIndex $dir -Paths 'bad.js'
        $id = @(Get-IssueReport $dir)[0].id
        Set-IssueState $dir @($id) 'ignored'
        @(Get-IssueReport $dir)[0].status | Should Be 'ignored'
        (Update-IssueIndex $dir -Paths 'bad.js').counts.error | Should Be 0
        @(Get-AppIssueIndex | Where-Object { $_.root -eq $dir })[0].ignored | Should Be 1
        Set-TestFile $dir 'bad.js' "const a = [1, 2];`n"
        $null = Update-IssueIndex $dir -Paths 'bad.js'
        (Read-IssueIndex $dir).states.ContainsKey($id) | Should Be $false
    }
    It 'drops a project from the app index when its details are gone' {
        Remove-Item -LiteralPath $dir -Recurse -Force
        @(Get-AppIssueIndex | Where-Object { $_.root -eq $dir }).Count | Should Be 0
    }
}

Describe 'The fix cycle after a task' {
    $dir = New-TestProject
    $config = [pscustomobject]@{ issues = [pscustomobject]@{ enabled = 'on'; autoFix = 'error'; maxAttempts = 2 } }
    $state = New-AgentState -Config $config -AppRoot $root
    $state.ProjectRoot = $dir
    Set-TestFile $dir 'old.js' "const x = [1;`n"   # a problem from before: not fixed automatically
    Set-TestFile $dir 'app.js' "const a = 1;`n"

    It 'reads the settings (autoFix as a comma list, none = nothing)' {
        (Get-IssueSettings $state).autoFix -join ',' | Should Be 'error'
        $s2 = New-AgentState -Config ([pscustomobject]@{ issues = [pscustomobject]@{ autoFix = 'error,secret,health' } }) -AppRoot $root
        (Get-IssueSettings $s2).autoFix -join ',' | Should Be 'error,secret,health'
        $s3 = New-AgentState -Config ([pscustomobject]@{ issues = [pscustomobject]@{ autoFix = 'none' } }) -AppRoot $root
        @((Get-IssueSettings $s3).autoFix).Count | Should Be 0
        (Get-IssueSettings $s3).maxAttempts | Should Be 2
    }
    It 'queues a fix only for problems the change added, one task per file' {
        $baseline = Get-IssueBaseline $state
        $baseline.Count | Should Be 1
        Set-TestFile $dir 'app.js' "const a = [1, 2;`nconst key = 'AKIAABCDEFGHIJKLMNOP';`n"
        $notes = @(Invoke-IssueCycle $state @('app.js', 'old.js') $baseline $null)
        $notes -join ' ' | Should Match '2 new problem\(s\) in 1 changed file\(s\); queued a fix for 1 file\(s\); 1 only reported'
        $fixes = @($state.Queue | Where-Object { $_.source -eq 'issues' })
        $fixes.Count | Should Be 1
        $fixes[0].task.issueFix.path | Should Be 'app.js'
        $fixes[0].task.issueFix.attempt | Should Be 1
        $fixes[0].task.text | Should Match 'Fix these problems in app.js'
        $fixes[0].task.text | Should Not Match 'old.js'
        @(Get-IssueReport $dir | Where-Object { $_.path -eq 'app.js' -and $_.category -eq 'error' })[0].status | Should Be 'fixing'
    }
    It 'tries again when the problem is still there, then gives up' {
        $first = @($state.Queue | Where-Object { $_.source -eq 'issues' })[0]
        $first.status = 'done'   # it ran
        $fix = $first.task.issueFix
        $baseline = Get-IssueBaseline $state
        $notes = @(Invoke-IssueCycle $state @('app.js') $baseline $fix)
        $notes -join ' ' | Should Match 'trying again \(attempt 2 of 2\)'
        $second = @($state.Queue | Where-Object { $_.source -eq 'issues' })[-1]
        $second.status = 'done'
        $fix2 = $second.task.issueFix
        $fix2.attempt | Should Be 2
        $notes = @(Invoke-IssueCycle $state @('app.js') (Get-IssueBaseline $state) $fix2)
        $notes -join ' ' | Should Match "marked 'gave up'"
        @(Get-IssueReport $dir | Where-Object { $_.path -eq 'app.js' -and $_.category -eq 'error' })[0].status | Should Be 'gave up'
    }
    It 'reports the file clean when the fix worked' {
        Set-TestFile $dir 'app.js' "const a = [1, 2];`n"
        $fix = @{ path = 'app.js'; ids = @('x'); attempt = 1; categories = @('error') }
        $notes = @(Invoke-IssueCycle $state @('app.js') (Get-IssueBaseline $state) $fix)
        $notes -join ' ' | Should Match 'app.js is clean again'
    }
    It 'shows what it is doing while it scans' {
        $state.Activity.label | Should Be ''
        $state.Activity.total | Should Be 1   # the last scan covered one file
    }
    Remove-Item -LiteralPath $dir -Recurse -Force
}

Describe 'The fix cycle cannot loop' {
    $config = [pscustomobject]@{ issues = [pscustomobject]@{ enabled = 'on'; autoFix = 'error'; maxAttempts = 2 } }

    It 'never queues past the attempt limit or twice for the same file' {
        $dir = New-TestProject
        $state = New-AgentState -Config $config -AppRoot $root
        $state.ProjectRoot = $dir
        $issue = [pscustomobject]@{ id = 'abc'; line = 1; category = 'error'; message = 'x' }
        Submit-IssueFix $state 'a.js' @($issue) 3 @('error') | Should BeNullOrEmpty
        Submit-IssueFix $state 'a.js' @($issue) 0 @('error') | Should BeNullOrEmpty
        (Submit-IssueFix $state 'a.js' @($issue) 1 @('error')) | Should Not BeNullOrEmpty
        Submit-IssueFix $state 'a.js' @($issue) 1 @('error') | Should BeNullOrEmpty
        @($state.Queue).Count | Should Be 1
        Remove-Item -LiteralPath $dir -Recurse -Force
    }

    It 'a fix task that breaks another file only reports it (no chain)' {
        $dir = New-TestProject
        $state = New-AgentState -Config $config -AppRoot $root
        $state.ProjectRoot = $dir
        Set-TestFile $dir 'a.js' "const a = [1;`n"
        Set-TestFile $dir 'b.js' "const b = 1;`n"
        $null = Update-IssueIndex $dir
        $fix = @{ path = 'a.js'; ids = @(@(Get-IssueReport $dir)[0].id); attempt = 2; categories = @('error') }
        $baseline = Get-IssueBaseline $state
        Set-TestFile $dir 'b.js' "const b = [1;`n"
        $notes = @(Invoke-IssueCycle $state @('a.js', 'b.js') $baseline $fix)
        $notes -join ' ' | Should Match "1 new problem\(s\) in 1 other changed file\(s\); 1 only reported"
        @($state.Queue).Count | Should Be 0
        Remove-Item -LiteralPath $dir -Recurse -Force
    }

    It 'puts issues of a stopped or lost fix task back to open' {
        $dir = New-TestProject
        $state = New-AgentState -Config $config -AppRoot $root
        $state.ProjectRoot = $dir
        Set-TestFile $dir 'a.js' "const a = [1;`n"
        $null = Update-IssueIndex $dir
        $id = @(Get-IssueReport $dir)[0].id
        $e = Submit-IssueFix $state 'a.js' @(Get-IssueReport $dir) 1 @('error')
        Reset-StaleIssueFixes $state $dir | Should Be 0          # its task is still waiting
        $e.status = 'failed'
        Reset-StaleIssueFixes $state $dir | Should Be 1
        @(Get-IssueReport $dir)[0].status | Should Be 'open'
        Remove-Item -LiteralPath $dir -Recurse -Force
    }

    It 'ends even when Copilot never fixes anything and breaks a new file every time' {
        $dir = New-TestProject
        $state = New-AgentState -Config $config -AppRoot $root
        $state.ProjectRoot = $dir
        Set-TestFile $dir 'start.js' "const s = 1;`n"
        # A user task breaks two files.
        $baseline = Get-IssueBaseline $state
        Set-TestFile $dir 'a.js' "const a = [1;`n"
        Set-TestFile $dir 'b.js' "const b = (1;`n"
        $null = Invoke-IssueCycle $state @('a.js', 'b.js') $baseline $null
        $runs = 0; $n = 0
        while ($runs -lt 50) {
            $entry = @($state.Queue | Where-Object { $_.source -eq 'issues' -and $_.status -eq 'queued' }) | Select-Object -First 1
            if (-not $entry) { break }
            $runs++; $entry.status = 'running'
            $fix = $entry.task.issueFix
            $base = Get-IssueBaseline $state
            # The worst fix: the file breaks in a new way, and another file breaks too.
            $n++
            Set-TestFile $dir $fix.path ("const a = [1;`n" * ($n + 1))
            Set-TestFile $dir "new$n.js" "const n = {1;`n"
            $null = Invoke-IssueCycle $state @($fix.path, "new$n.js") $base $fix
            $entry.status = 'done'
        }
        $runs | Should Be 4    # 2 files x 2 attempts, nothing more
        @(Get-IssueReport $dir | Where-Object { $_.path -in 'a.js', 'b.js' -and $_.status -ne 'gave up' }).Count | Should Be 0
        @(Get-IssueReport $dir | Where-Object { $_.path -like 'new*' -and $_.status -eq 'open' }).Count | Should Be 4
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

Describe 'Reset-CCBridgeSettings' {
    $app = Join-Path $env:TEMP ('ccb-app-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $app 'config')
    Copy-Item (Join-Path $root 'config\harness.json') (Join-Path $app 'config\harness.json')
    [IO.File]::WriteAllText((Join-Path $app 'config\harness.local.json'), '{ "port": 9999, "maxRounds": 7, "pacing": { "beforeSendSec": 3 }, "issues": { "autoFix": "none" } }')

    It 'puts every adjustable setting back to the default and keeps other local values' {
        $changed = @(Reset-CCBridgeSettings $app)
        ($changed | Sort-Object) -join ',' | Should Be 'issues.autoFix,maxRounds,pacing.beforeSendSec'
        @(Get-CCBridgeSettings $app | Where-Object custom).Count | Should Be 0
        $local = [IO.File]::ReadAllText((Join-Path $app 'config\harness.local.json')) | ConvertFrom-Json
        $local.port | Should Be 9999
    }
    Remove-Item -LiteralPath $app -Recurse -Force
}

Remove-Item -LiteralPath $env:CCBRIDGE_ISSUE_INDEX -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_ISSUE_INDEX = $null
