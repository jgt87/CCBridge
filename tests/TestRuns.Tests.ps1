# Test runs: saved requests run again in a fresh project, with a report next to the last run.
# Made-up requests and data in a temporary projects folder.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-tr-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'ProjectSetup', 'TestRuns', 'SessionReport') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

$projects = Join-Path $env:TEMP ('ccb-tr-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $projects

Describe 'A test run file' {
    It 'reads its header and numbered steps, a step running over several lines' {
        $dir = Get-TestRunsDir $projects -Create
        $f = Join-Path $dir 'orders.testrun.md'
        [IO.File]::WriteAllText($f, "---`ntitle: Orders page`nanswers: audience=me, bigtask=build`nbuild: single`nfiles: orders/orders.csv`nmode: ask`n---`n1. Build a page that lists the orders`n   with a total per month`n2. Add a filter on the customer`n")
        $t = Read-TestRun $f
        $t.name | Should Be 'orders'
        $t.title | Should Be 'Orders page'
        $t.answers['audience'] | Should Be 'me'
        $t.answers['bigtask'] | Should Be 'build'
        $t.build | Should Be 'single'
        $t.mode | Should Be 'ask'
        @($t.files) -join ',' | Should Be 'orders/orders.csv'
        @($t.steps).Count | Should Be 2
        $t.steps[0] | Should Be "Build a page that lists the orders`nwith a total per month"
        (Read-TestRun (Join-Path $dir 'orders.testrun.md')).steps[1] | Should Be 'Add a filter on the customer'
    }
    It 'is saved from a project''s requests with its data files and setup, and read back the same' {
        $proj = Join-Path $projects 'Tickets'; $null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'Source')
        [IO.File]::WriteAllText((Join-Path $proj 'tickets.csv'), "id,state`n1,open`n")
        [IO.File]::WriteAllText((Join-Path $proj 'Source\export.xlsx'), 'not really a workbook')
        [IO.File]::WriteAllText((Join-Path $proj 'index.html'), '<!doctype html>')
        $null = Save-ProjectSetup $proj @{ build = 'modular'; answers = @{ audience = 'sharepoint' } }
        $p = Save-TestRun $projects 'Tickets' @("Build a ticket list`nsorted by state", 'Add a chart of tickets per state') $proj (Get-ProjectSetup $proj)
        $t = Read-TestRun $p
        @($t.steps).Count | Should Be 2
        $t.steps[0] | Should Be "Build a ticket list`nsorted by state"
        $t.answers['audience'] | Should Be 'sharepoint'
        $t.build | Should Be 'modular'
        @($t.files) -join ',' | Should Be 'Tickets/tickets.csv'
        @($t.source) -join ',' | Should Be 'Tickets/Source/export.xlsx'
        { Save-TestRun $projects 'bad/name' @('x') } | Should Throw
        { Save-TestRun $projects 'Empty' @('  ') } | Should Throw
        @(Get-TestRuns $projects | ForEach-Object { $_.name }) -join ',' | Should Be 'orders,Tickets'
    }
    It 'starts in a fresh project with its files and setup' {
        $run = Read-TestRun (Join-Path (Get-TestRunsDir $projects) 'Tickets.testrun.md')
        $p = New-TestRunProject $projects $run ([datetime]'2026-01-05 09:30')
        Split-Path -Leaf $p | Should Be 'Tickets run 20260105-0930'
        Test-Path -LiteralPath (Join-Path $p 'tickets.csv') | Should Be $true
        Test-Path -LiteralPath (Join-Path $p 'Source\export.xlsx') | Should Be $true
        (Get-ProjectSetup $p).answers['audience'] | Should Be 'sharepoint'
        Split-Path -Leaf (New-TestRunProject $projects $run ([datetime]'2026-01-05 09:30')) | Should Be 'Tickets run 20260105-0930-2'
    }
    It 'keeps each run''s numbers and puts this run next to the last' {
        Add-TestRunHistory $projects 'Tickets' @{ when = '2026-01-05 10:00'; build = 'v0.1.1'; tasks = 2; messages = 14; rounds = 12; nudges = 4; failedSteps = 3; pageProblems = 1; planLoops = 0; typing = 0; noAnswer = 0; errors = 0; minutes = 9 }
        $last = @(Read-TestRunHistory $projects 'Tickets') | Select-Object -Last 1
        $last.messages | Should Be 14
        $t = Format-TestRunComparison @{ build = 'v0.1.2'; tasks = 2; messages = 9; rounds = 8; nudges = 1; failedSteps = 0; pageProblems = 0; planLoops = 0; typing = 0; noAnswer = 0; errors = 0; minutes = 6 } $last
        $t | Should Match '\| \| This run \(v0\.1\.2\) \| Last run \(v0\.1\.1, 2026-01-05 10:00\) \|'
        $t | Should Match '\| Copilot messages \| 9 \| 14 \|'
        $t | Should Match '\| Nudges \(the helper program correcting Copilot\) \| 1 \| 4 \|'
        Format-TestRunComparison @{ build = 'v0.1.2'; tasks = 1 } $null | Should Match '\| Tasks \| 1 \| - \|'
    }
}

Describe 'The run''s numbers from the log' {
    It 'counts tasks, messages, rounds, nudges and failed steps' {
        $lines = @(
            '2026-01-05 09:00:00.000 [ 50] INFO    agent    Queued q-1 (chat, from testrun) {"title":"Build a list"}',
            '2026-01-05 09:00:01.000 [ 50] INFO    agent    Turn started {"mode":"auto"}',
            '2026-01-05 09:00:02.000 [ 50] VERBOSE agent    Round 2: sending {"chars":10}',
            '2026-01-05 09:00:03.000 [ 50] VERBOSE agent    status: Before finishing: Copilot is reminded once about what is still open.',
            '2026-01-05 09:00:04.000 [ 50] INFO    agent    action failed 1-0 [EDIT-NOT-FOUND]: edit a.js failed {"x":1}',
            '2026-01-05 09:00:09.000 [ 50] INFO    agent    Queue q-1 done {"messages":3}'
        )
        $m = Get-SessionReport (Read-LogEntries $lines 50) 'StreamHub v0.1.9 (commit abc)' -Metrics
        $m.build | Should Be 'v0.1.9 (commit abc)'
        $m.tasks | Should Be 1
        $m.messages | Should Be 3
        $m.rounds | Should Be 2
        $m.nudges | Should Be 1
        $m.failedSteps | Should Be 1
    }
}

Remove-Item $projects -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
