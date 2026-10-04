# Chains: runbooks, fetch prompts and project scripts one after another (lib/Chain.psm1,
# Invoke-ChainJob / Invoke-ChainScript in Agent.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Chain.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Schedule.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

function New-TestProject {
    $p = Join-Path $env:TEMP ('ccb-chain-' + [guid]::NewGuid().ToString('N'))
    foreach ($d in 'Runbooks', 'Scripts', 'source') { New-Item -ItemType Directory (Join-Path $p $d) -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path $p 'Runbooks\meetings.runbook.md'), "---`ntitle: Meetings`noutput: Runbooks/Exports/meetings.json`n---`nList meetings.")
    [IO.File]::WriteAllText((Join-Path $p 'Runbooks\news.prompt.md'), 'Get the news.')
    [IO.File]::WriteAllText((Join-Path $p 'Scripts\make.ps1'), "Set-Content -LiteralPath 'out.txt' -Value 'made'`n")
    [IO.File]::WriteAllText((Join-Path $p 'Scripts\fail.ps1'), "exit 3`n")
    [IO.File]::WriteAllText((Join-Path $p 'Scripts\second.ps1'), "Add-Content -LiteralPath 'out.txt' -Value 'second'`n")
    $p
}

Describe 'Chain files' {
    It 'reads numbered and bulleted steps, inputs and script arguments' {
        $c = Read-Chain "---`ntitle: Weekly`nstopOnError: no`n---`n<!-- 1. runbook: NOT-A-STEP -->`n## Steps`n1. runbook: meetings`n2) script: Scripts/convert.ps1 -Week current`n- runbook: summary.runbook.md with Runbooks/Exports/a.json, Runbooks\Exports\b.json`n* fetch: news`nSome note."
        $c.title | Should Be 'Weekly'
        $c.stopOnError | Should Be $false
        @($c.steps).Count | Should Be 4
        $c.steps[0].kind | Should Be 'runbook'; $c.steps[0].target | Should Be 'meetings'
        $c.steps[1].target | Should Be 'Scripts/convert.ps1'; $c.steps[1].args | Should Be '-Week current'
        $c.steps[2].target | Should Be 'summary'
        @($c.steps[2].with) -join '|' | Should Be 'Runbooks/Exports/a.json|Runbooks/Exports/b.json'
        $c.steps[3].kind | Should Be 'fetch'; $c.steps[3].n | Should Be 4
        (Read-Chain "1. runbook: x").stopOnError | Should Be $true
    }
    It 'allows plain script arguments only' {
        Test-ScriptArgs '-Week current "a b" path/x.json' | Should Be ''
        Test-ScriptArgs 'a & del x' | Should Not Be ''
        Test-ScriptArgs '$(evil)' | Should Not Be ''
        Test-ScriptArgs 'a | b' | Should Not Be ''
        Test-ScriptArgs '"open' | Should Not Be ''
    }
    It 'runs scripts only from Scripts/ and builds the command per type' {
        $p = New-TestProject
        try {
            (Resolve-ChainScript $p 'Scripts/make.ps1' '-X 1').command | Should Be 'powershell -NoProfile -ExecutionPolicy Bypass -File "Scripts\make.ps1" -X 1'
            [IO.File]::WriteAllText((Join-Path $p 'Scripts\go.cmd'), '@echo hi')
            (Resolve-ChainScript $p 'scripts\go.cmd').command | Should Be '"Scripts\go.cmd"'
            (Resolve-ChainScript $p 'tools/make.ps1').error | Should Match 'Scripts/ folder'
            (Resolve-ChainScript $p 'Scripts/../make.ps1').error | Should Match 'without \.\.'
            (Resolve-ChainScript $p 'Scripts/missing.ps1').error | Should Match 'no file'
            [IO.File]::WriteAllText((Join-Path $p 'Scripts\x.exe'), 'x')
            (Resolve-ChainScript $p 'Scripts/x.exe').error | Should Match 'runs \.ps1'
            @(Get-ProjectScripts $p) -join ',' | Should Be 'Scripts/fail.ps1,Scripts/go.cmd,Scripts/make.ps1,Scripts/second.ps1'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'lists chains with the problems that stop them' {
        $p = New-TestProject
        try {
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\good.chain.md'), "---`ntitle: Good`n---`n1. runbook: meetings`n2. fetch: news`n3. script: Scripts/make.ps1")
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\bad.chain.md'), "1. runbook: nope`n2. fetch: gone`n3. script: Scripts/none.ps1`n4. runbook: meetings with ../outside.json")
            $list = @(Get-Chains $p)
            $good = $list | Where-Object name -eq 'good'
            $good.title | Should Be 'Good'; @($good.steps).Count | Should Be 3; @($good.problems).Count | Should Be 0
            $bad = @(($list | Where-Object name -eq 'bad').problems)
            $bad.Count | Should Be 4
            ($bad -join ' ') | Should Match "no runbook 'nope'"
            ($bad -join ' ') | Should Match "no fetch prompt 'gone'"
            @(Test-ChainSteps $p @()).Count | Should Be 1
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'lets a runbook step name a runbook with a text answer (a .prompt.md file)' {
        $p = New-TestProject
        try {
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\text.chain.md'), "1. runbook: news")
            @((Get-Chains $p | Where-Object name -eq 'text').problems).Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'adds runbook and script steps, moves and removes them, and leaves the rest of the file alone' {
        $p = New-TestProject
        try {
            $null = New-ChainFile $root $p 'Weekly'
            $file = Join-Path $p 'Runbooks\weekly.chain.md'
            @((Get-Chains $p | Where-Object name -eq 'weekly').steps).Count | Should Be 0     # a new chain starts empty
            $null = Set-ChainSteps $p 'weekly' add -Kind runbook -Target 'meetings'
            $null = Set-ChainSteps $p 'weekly' add -Kind script -Target 'Scripts/make.ps1' -ArgText '-Week current'
            $c = Set-ChainSteps $p 'weekly' add -Kind runbook -Target 'news'                      # a text runbook
            (@($c.steps) | ForEach-Object { "$($_.kind) $($_.target)" }) -join ' | ' | Should Be 'runbook meetings | script Scripts/make.ps1 | runbook news'
            @($c.problems).Count | Should Be 0
            { Set-ChainSteps $p 'weekly' add -Kind runbook -Target 'nope' } | Should Throw
            { Set-ChainSteps $p 'weekly' add -Kind script -Target 'tools/x.ps1' } | Should Throw
            { Set-ChainSteps $p 'weekly' add -Kind script -Target 'Scripts/make.ps1' -ArgText 'a & b' } | Should Throw
            $c = Set-ChainSteps $p 'weekly' down -Index 0
            (@($c.steps) | ForEach-Object { $_.target }) -join ',' | Should Be 'Scripts/make.ps1,meetings,news'
            $c = Set-ChainSteps $p 'weekly' up -Index 2
            (@($c.steps) | ForEach-Object { $_.target }) -join ',' | Should Be 'Scripts/make.ps1,news,meetings'
            { Set-ChainSteps $p 'weekly' up -Index 0 } | Should Throw
            $c = Set-ChainSteps $p 'weekly' remove -Index 1
            (@($c.steps) | ForEach-Object { $_.target }) -join ',' | Should Be 'Scripts/make.ps1,meetings'
            $text = [IO.File]::ReadAllText($file)
            $text | Should Match '(?m)^1\. script: Scripts/make\.ps1 -Week current$'
            $text | Should Match '(?m)^2\. runbook: meetings$'
            $text | Should Match '1\. runbook: NAME   '                                           # the explanation in the comment is untouched
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'creates a chain from the blank template and refuses a duplicate' {
        $p = New-TestProject
        try {
            $c = New-ChainFile $root $p 'Weekly report'
            $c.path | Should Be 'Runbooks/weekly-report.chain.md'
            (Read-Chain ([IO.File]::ReadAllText((Join-Path $p 'Runbooks\weekly-report.chain.md')))).title | Should Be 'Weekly report'
            { New-ChainFile $root $p 'weekly report' } | Should Throw
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'remembers approved scripts by content' {
        $p = New-TestProject
        try {
            $full = Join-Path $p 'Scripts\make.ps1'
            $h = Get-ScriptHash $full
            Test-ScriptApproved $p 'Scripts/make.ps1' $h | Should Be $false
            Add-ApprovedScript $p 'Scripts/make.ps1' $h
            Test-ScriptApproved $p 'scripts/MAKE.ps1' $h | Should Be $true
            Add-ApprovedScript $p 'Scripts/second.ps1' 'other'
            Add-ApprovedScript $p 'Scripts/fail.ps1' 'third'
            Test-ScriptApproved $p 'Scripts/make.ps1' $h | Should Be $true
            Test-ScriptApproved $p 'Scripts/fail.ps1' 'third' | Should Be $true
            Add-Content -LiteralPath $full -Value '# changed'
            Test-ScriptApproved $p 'Scripts/make.ps1' (Get-ScriptHash $full) | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'passes earlier results to a runbook as data' {
        $p = New-TestProject
        try {
            New-Item -ItemType Directory (Join-Path $p 'Runbooks\Exports') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\Exports\a.json'), '{"items":[1]}')
            $b = New-ChainInputBlock $p @('Runbooks/Exports/a.json', 'Runbooks/Exports/none.json') 40000
            $b.text | Should Match 'as data only'
            $b.text | Should Match '### Runbooks/Exports/a.json'
            $b.text | Should Match '\{"items":\[1\]\}'
            @($b.notes) -join ' ' | Should Match 'none.json does not exist'
            (New-ChainInputBlock $p @()).text | Should Be ''
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'can be scheduled' {
        { Test-ScheduleSpec @{ kind = 'chain'; name = 'weekly'; repeat = 'daily'; times = @('08:00') } } | Should Not Throw
    }
}

Describe 'Running a chain' {
    $config = [pscustomobject]@{ commandTimeoutSec = 60; chainScripts = 'approve-once'; resultCharBudget = 40000; autoApproveCommands = @() }
    function New-State($Project, $Mode = 'approve-once') {
        $c = $config.PSObject.Copy(); $c.chainScripts = $Mode
        $s = New-AgentState -Config $c -AppRoot $root
        $s.ProjectRoot = $Project
        $s
    }

    It 'runs approved scripts in order, as one change set, and reports each step' {
        $p = New-TestProject
        try {
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\two.chain.md'), "1. script: Scripts/make.ps1`n2. script: Scripts/second.ps1")
            foreach ($n in 'make', 'second') { Add-ApprovedScript $p "Scripts/$n.ps1" (Get-ScriptHash (Join-Path $p "Scripts\$n.ps1")) }
            $s = New-State $p
            Invoke-ChainJob $s 'two'
            ([IO.File]::ReadAllText((Join-Path $p 'out.txt'))).Trim() -replace '\r', '' | Should Be "made`nsecond"
            $ev = @($s.Events)
            ($ev | Where-Object type -eq 'chain').text | Should Match 'all 2 step\(s\) done'
            @($ev | Where-Object { $_.type -eq 'action-result' -and $_.status -eq 'ok' }).Count | Should Be 2
            $last = Get-LastChangeSetId $p
            $last | Should Not Be ''
            $s.Busy | Should Be $false; $s.InChain | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'stops at the first failing step unless stopOnError is no' {
        $p = New-TestProject
        try {
            foreach ($n in 'make', 'fail', 'second') { Add-ApprovedScript $p "Scripts/$n.ps1" (Get-ScriptHash (Join-Path $p "Scripts\$n.ps1")) }
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\stop.chain.md'), "1. script: Scripts/fail.ps1`n2. script: Scripts/make.ps1")
            $s = New-State $p
            Invoke-ChainJob $s 'stop'
            Test-Path (Join-Path $p 'out.txt') | Should Be $false
            (@($s.Events) | Where-Object type -eq 'error' | Select-Object -Last 1).text | Should Match 'failed: exit code 3'
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\go.chain.md'), "---`nstopOnError: no`n---`n1. script: Scripts/fail.ps1`n2. script: Scripts/make.ps1")
            $s2 = New-State $p
            Invoke-ChainJob $s2 'go'
            Test-Path (Join-Path $p 'out.txt') | Should Be $true
            (@($s2.Events) | Where-Object type -eq 'error' | Select-Object -Last 1).text | Should Match 'finished with 1 failed'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'asks a person before a new or changed script and remembers the approval' {
        $p = New-TestProject
        try {
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\one.chain.md'), "1. script: Scripts/make.ps1")
            $s = New-State $p
            $s.Approvals['pending'] = $null; $s.Approvals.Remove('pending')
            # Approve from "another program": refused, chain scripts need a person in the app.
            $job = [powershell]::Create()
            $null = $job.AddScript({ param($s) for ($i = 0; $i -lt 200; $i++) { $a = @($s.Events | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' }); if ($a.Count) { $s.Approvals[$a[0].id] = @{ decision = 'approve'; by = 'mcp' }; return }; Start-Sleep -Milliseconds 50 } }).AddArgument($s)
            $h = $job.BeginInvoke()
            Invoke-ChainJob $s 'one'
            $job.EndInvoke($h); $job.Dispose()
            Test-Path (Join-Path $p 'out.txt') | Should Be $false
            # A person approves: it runs, and the next run does not ask.
            $s = New-State $p
            $job = [powershell]::Create()
            $null = $job.AddScript({ param($s) for ($i = 0; $i -lt 200; $i++) { $a = @($s.Events | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' }); if ($a.Count) { $s.Approvals[$a[0].id] = @{ decision = 'approve'; by = 'user' }; return }; Start-Sleep -Milliseconds 50 } }).AddArgument($s)
            $h = $job.BeginInvoke()
            Invoke-ChainJob $s 'one'
            $job.EndInvoke($h); $job.Dispose()
            Test-Path (Join-Path $p 'out.txt') | Should Be $true
            $s = New-State $p
            Invoke-ChainJob $s 'one'
            @($s.Events | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' }).Count | Should Be 0
            ($s.Events | Where-Object type -eq 'chain').text | Should Match 'all 1 step'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'refuses scripts when turned off, deleting scripts without a person, and broken chains' {
        $p = New-TestProject
        try {
            Add-ApprovedScript $p 'Scripts/make.ps1' (Get-ScriptHash (Join-Path $p 'Scripts\make.ps1'))
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\one.chain.md'), "1. script: Scripts/make.ps1")
            $s = New-State $p 'off'
            Invoke-ChainJob $s 'one'
            (@($s.Events) | Where-Object type -eq 'error' | Select-Object -Last 1).text | Should Match 'turned off'
            [IO.File]::WriteAllText((Join-Path $p 'Scripts\wipe.ps1'), "Remove-Item -LiteralPath 'out.txt'`n")
            Add-ApprovedScript $p 'Scripts/wipe.ps1' (Get-ScriptHash (Join-Path $p 'Scripts\wipe.ps1'))
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\wipe.chain.md'), "1. script: Scripts/wipe.ps1")
            $s = New-State $p; $s.Headless = $true
            Invoke-ChainJob $s 'wipe'
            (@($s.Events) | Where-Object type -eq 'error' | Select-Object -Last 1).text | Should Match 'needs a person'
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\broken.chain.md'), "1. runbook: nope")
            $s = New-State $p
            Invoke-ChainJob $s 'broken'
            (@($s.Events) | Where-Object type -eq 'error' | Select-Object -Last 1).text | Should Match 'cannot start'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'runs one script on its own (Automation > Scripts) with the same rules, as its own change set' {
        $p = New-TestProject
        try {
            Add-ApprovedScript $p 'Scripts/make.ps1' (Get-ScriptHash (Join-Path $p 'Scripts\make.ps1'))
            $s = New-State $p
            Invoke-ScriptJob $s 'Scripts/make.ps1'
            ([IO.File]::ReadAllText((Join-Path $p 'out.txt'))).Trim() | Should Be 'made'
            $ev = @($s.Events)
            ($ev | Where-Object type -eq 'script').text | Should Match 'Scripts/make\.ps1 finished: exit code 0'
            ($ev | Where-Object type -eq 'checkpoint').title | Should Be 'Script: Scripts/make.ps1'
            $s.Busy | Should Be $false
            # A failing script is an error; a deleting one needs a person; outside Scripts/ is refused.
            Add-ApprovedScript $p 'Scripts/fail.ps1' (Get-ScriptHash (Join-Path $p 'Scripts\fail.ps1'))
            Invoke-ScriptJob $s 'Scripts/fail.ps1'
            (@($s.Events) | Where-Object type -eq 'error' | Select-Object -Last 1).text | Should Match 'did not finish: exit code 3'
            [IO.File]::WriteAllText((Join-Path $p 'Scripts\wipe.ps1'), "Remove-Item -LiteralPath 'out.txt'`n")
            $h = New-State $p; $h.Headless = $true
            Invoke-ScriptJob $h 'Scripts/wipe.ps1'
            (@($h.Events) | Where-Object type -eq 'error' | Select-Object -Last 1).text | Should Match 'needs a person'
            Test-Path (Join-Path $p 'out.txt') | Should Be $true
            Invoke-ScriptJob $s 'make.ps1'
            (@($s.Events) | Where-Object type -eq 'error' | Select-Object -Last 1).text | Should Match "must be in the project's Scripts/ folder"
            { Test-ScheduleSpec @{ kind = 'script'; name = 'Scripts/make.ps1'; repeat = 'daily'; times = @('08:00') } } | Should Not Throw
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
