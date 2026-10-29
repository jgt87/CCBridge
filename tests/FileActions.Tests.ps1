# Pester 3.4. Copilot's move, delete, refs, changes and test actions (lib/FileActions.psm1, Agent
# Invoke-AgentActionCore): moves and deletes stay inside the project, go into the change set (Undo puts
# them back) and keep the paths that lead to moved files working; refs lists the uses of a name;
# changes shows the message's change set; test runs the project's tests by the helper's own command.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-fa-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force
Import-Module (Join-Path $root 'lib\Imports.psm1') -Force
Import-Module (Join-Path $root 'lib\FileActions.psm1') -Force
Import-Module (Join-Path $root 'lib\TaskGuidance.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$base = Join-Path $env:TEMP ('ccb-fa-' + [guid]::NewGuid().ToString('N'))
function New-Proj([string]$Name) {
    $p = Join-Path $base $Name
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $p 'css'), (Join-Path $p 'Source')
    $files = @{
        'index.html' = "<html><head><link rel=""stylesheet"" href=""css/site.css""></head><body><h1>Hi</h1><button class=""btn"">Go</button><script src=""app.js""></script></body></html>`n"
        'app.js' = "function greet(name) { return 'hi ' + name; }`n// greet is old`nconsole.log(greet('a'));`n"
        'util.js' = "const x = greet('b');`n"
        'css/site.css' = ".btn { color: red; }`n.btn-primary { color: blue; }`n"
        'Readme.md' = "# Readme`n"
        'Source/data.csv' = "a,b`n1,2`n"
    }
    foreach ($k in $files.Keys) { [IO.File]::WriteAllText((Join-Path $p $k), $files[$k]) }
    $null = Update-ImportIndex $p
    $p
}
function Get-Text([string]$Proj, [string]$Rel) { [IO.File]::ReadAllText((Join-Path $Proj $Rel)) }
function New-TestState([string]$Proj, [string]$Mode = 'auto') {
    $cfg = [pscustomobject]@{ commandTimeoutSec = 120; resultCharBudget = 20000; autoApproveCommands = @() }
    $s = New-AgentState -Config $cfg -AppRoot $root
    $s.ProjectRoot = $Proj; $s.Mode = $Mode
    $s
}
function Invoke-Act($State, $Action, [string]$Id, $Checkpoint) { & (Get-Module Agent) { param($s, $a, $i, $c) Invoke-AgentAction $s $a $i $c 0 } $State $Action $Id $Checkpoint }
function New-Act([string]$Type, [string]$Arg, [string]$Body) { [pscustomobject]@{ type = $Type; arg = $Arg; body = $Body; closed = $true; edits = @() } }

Describe 'Reading the new actions from a reply' {
    It 'takes move, delete, refs, changes and test only in the ACTION form, never from a code block label' {
        $fence = '```'
        $reply = "${fence}text`nACTION move`napp.js -> js/app.js`nold.css -> css/`n$fence`n${fence}text`nACTION delete`ntmp.txt`nWork/old`n$fence`n${fence}text`nACTION test`n$fence`n${fence}test`nexpect(1).toBe(1)`n$fence`n${fence}delete`nx`n$fence"
        $a = @(Get-ActionBlocks $reply)
        @($a | ForEach-Object { $_.type }) | Should Be @('move', 'delete', 'test')
        $pairs = @(Get-MovePairs $a[0].arg $a[0].body)
        $pairs.Count | Should Be 2
        $pairs[1].to | Should Be 'css/'
        @(Get-DeletePaths $a[1].arg $a[1].body) | Should Be @('tmp.txt', 'Work/old')
        @(Get-MovePairs '' "a.js`njs/a.js").Count | Should Be 1
        (@(Get-MovePairs '' "a.js`njs/a.js"))[0].to | Should Be 'js/a.js'
    }
}

Describe 'move' {
    It 'moves a file into a folder, rewrites the pages that load it, and Undo puts both back' {
        $p = New-Proj 'm1'
        $cp = New-Checkpoint $p
        $plan = Get-MovePlan $p @(@{ from = 'app.js'; to = 'js/' })
        $plan.error | Should Be ''
        $r = Invoke-MovePlan $p $plan $cp
        Test-Path (Join-Path $p 'js\app.js') | Should Be $true
        Test-Path (Join-Path $p 'app.js') | Should Be $false
        Get-Text $p 'index.html' | Should Match 'src="js/app.js"'
        @($r.relinked | ForEach-Object { $_.path }) -contains 'index.html' | Should Be $true
        $cp.Files['app.js'] | Should Be 'existed'
        $cp.Files['js/app.js'] | Should Be 'new'
        $cp.MovedFrom['js/app.js'] | Should Be 'app.js'
        $null = Undo-LastCheckpoint $p
        Test-Path (Join-Path $p 'app.js') | Should Be $true
        Test-Path (Join-Path $p 'js') | Should Be $false
        Get-Text $p 'index.html' | Should Match 'src="app.js"'
    }
    It 'rewrites the relative paths inside a file that moves to another folder' {
        $p = New-Proj 'm2'
        $r = Invoke-MovePlan $p (Get-MovePlan $p @(@{ from = 'index.html'; to = 'pages/index.html' })) (New-Checkpoint $p)
        $t = Get-Text $p 'pages\index.html'
        $t | Should Match 'href="\.\./css/site\.css"'
        $t | Should Match 'src="\.\./app\.js"'
    }
    It 'moves a folder with its files and removes the empty source' {
        $p = New-Proj 'm3'
        $null = Invoke-MovePlan $p (Get-MovePlan $p @(@{ from = 'css'; to = 'styles' })) (New-Checkpoint $p)
        Test-Path (Join-Path $p 'styles\site.css') | Should Be $true
        Test-Path (Join-Path $p 'css') | Should Be $false
        Get-Text $p 'index.html' | Should Match 'href="styles/site\.css"'
    }
    It 'renames a file when only the case changes' {
        $p = New-Proj 'm4'
        (Get-MovePlan $p @(@{ from = 'Readme.md'; to = 'README.md' })).error | Should Be ''
        $null = Invoke-MovePlan $p (Get-MovePlan $p @(@{ from = 'Readme.md'; to = 'README.md' })) (New-Checkpoint $p)
        @(Get-ChildItem -LiteralPath $p -File | Where-Object { $_.Name -ceq 'README.md' }).Count | Should Be 1
    }
    It 'refuses to overwrite, to leave the project, to touch Source/ or .streamhub/, and a folder into itself' {
        $p = New-Proj 'm5'
        (Get-MovePlan $p @(@{ from = 'app.js'; to = 'util.js' })).error | Should Match 'already exists'
        (Get-MovePlan $p @(@{ from = 'app.js'; to = '../app.js' })).error | Should Match 'outside the project'
        (Get-MovePlan $p @(@{ from = 'Source/data.csv'; to = 'data.csv' })).error | Should Match 'Source/'
        (Get-MovePlan $p @(@{ from = 'app.js'; to = '.streamhub/app.js' })).error | Should Match '\.streamhub'
        (Get-MovePlan $p @(@{ from = 'css'; to = 'css/inner' })).error | Should Match 'into itself'
        (Get-MovePlan $p @(@{ from = 'nope.js'; to = 'x.js' })).error | Should Match 'does not exist'
        (Get-MovePlan $p @(@{ from = 'app.js'; to = '' })).error | Should Match 'no target'
        Test-Path (Join-Path $p 'app.js') | Should Be $true
    }
}

Describe 'delete' {
    It 'deletes files and folders, names what still uses them, and Undo brings them back' {
        $p = New-Proj 'd1'
        $cp = New-Checkpoint $p
        $plan = Get-DeletePlan $p @('app.js', 'css')
        $plan.error | Should Be ''
        $plan.files | Should Be 2
        $r = Invoke-DeletePlan $p $plan $cp
        Test-Path (Join-Path $p 'app.js') | Should Be $false
        Test-Path (Join-Path $p 'css') | Should Be $false
        ($r.broken -join "`n") | Should Match 'index\.html.*app\.js'
        $null = Undo-LastCheckpoint $p
        Get-Text $p 'app.js' | Should Match 'function greet'
        Test-Path (Join-Path $p 'css\site.css') | Should Be $true
    }
    It 'refuses the project folder, Source/, a missing path and a folder holding a link, and leaves the link target alone' {
        $p = New-Proj 'd2'
        (Get-DeletePlan $p @('.')).error | Should Match 'outside the project'
        (Get-DeletePlan $p @('Source/data.csv')).error | Should Match 'Source/'
        (Get-DeletePlan $p @('gone.txt')).error | Should Match 'does not exist'
        $outside = Join-Path $base 'outside-d2'
        $null = New-Item -ItemType Directory -Force -Path $outside
        [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'keep')
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $p 'Work')
        cmd /c "mklink /J ""$(Join-Path $p 'Work\link')"" ""$outside"" >nul 2>&1"
        (Get-DeletePlan $p @('Work')).error | Should Match 'link'
        Test-Path (Join-Path $outside 'keep.txt') | Should Be $true
        cmd /c "rmdir ""$(Join-Path $p 'Work\link')"" >nul 2>&1"
    }
}

Describe 'refs' {
    It 'lists the uses of a name with its definition marked, leaving comment lines out' {
        $p = New-Proj 'r1'
        $out = Find-SymbolUses $p 'greet'
        $out | Should Match 'app\.js:1 .*\[definition\]'
        $out | Should Match 'util\.js:1'
        $out | Should Match 'app\.js:3'
        $out | Should Not Match 'app\.js:2 '
        $out | Should Match '3 place\(s\) in 2 file\(s\)'
    }
    It 'takes a CSS class with its dash as part of the name' {
        $p = New-Proj 'r2'
        $out = Find-SymbolUses $p '.btn'
        $out | Should Match 'css/site\.css:1'
        $out | Should Not Match 'css/site\.css:2'
        $out | Should Match 'index\.html:1'
    }
    It 'lists what loads a file for a path' {
        $p = New-Proj 'r3'
        Find-SymbolUses $p 'app.js' | Should Match 'index\.html'
        Find-SymbolUses $p 'nothingLikeThis' | Should Match 'no uses found'
    }
}

Describe 'changes' {
    It 'lists what this message created, edited and deleted, and one file in detail' {
        $p = New-Proj 'c1'
        Format-TaskChanges $p $null | Should Match 'No file has changed'
        $cp = New-Checkpoint $p
        $null = Invoke-WriteAction $p 'new.js' "let a = 1;`n" $cp
        $null = Invoke-WriteAction $p 'util.js' "const x = greet('c');`n" $cp
        $null = Invoke-DeletePlan $p (Get-DeletePlan $p @('Readme.md')) $cp
        $all = Format-TaskChanges $p $cp
        $all | Should Match 'new\.js: created, \+1 -0'
        $all | Should Match 'util\.js: edited, \+1 -1'
        $all | Should Match 'Readme\.md: deleted'
        $all | Should Match "\+ const x = greet\('c'\);"
        Format-TaskChanges $p $cp 'util.js' | Should Not Match 'new\.js'
        Format-TaskChanges $p $cp 'app.js' | Should Match 'has not changed'
    }
}

Describe 'The actions in the agent' {
    It 'moves without approval in auto mode and reports the changed paths for the round check' {
        $p = New-Proj 'a1'
        $s = New-TestState $p
        $res = Invoke-Act $s (New-Act 'move' '' 'app.js -> js/app.js') 'a1' (New-Checkpoint $p)
        $res.ok | Should Be $true
        $res.changed | Should Be $true
        @($res.path) -contains 'js/app.js' | Should Be $true
        @($res.path) -contains 'index.html' | Should Be $true
        @($s.Events | Where-Object { $_.type -eq 'action' -and $_.by -eq 'streamhub' -and $_.target -eq 'index.html' }).Count | Should Be 1
    }
    It 'lets only a person in the app approve a delete, also in auto mode, and refuses it without one' {
        $p = New-Proj 'a2'
        $s = New-TestState $p
        $s.Approvals['d1'] = @{ decision = 'approve'; note = ''; by = 'mcp' }
        (Invoke-Act $s (New-Act 'delete' 'app.js' '') 'd1' (New-Checkpoint $p)).ok | Should Be $false
        Test-Path (Join-Path $p 'app.js') | Should Be $true
        $s.Approvals['d2'] = @{ decision = 'approve'; note = ''; by = 'user' }
        (Invoke-Act $s (New-Act 'delete' 'app.js' '') 'd2' (New-Checkpoint $p)).ok | Should Be $true
        Test-Path (Join-Path $p 'app.js') | Should Be $false
        $s.Headless = $true
        $res = Invoke-Act $s (New-Act 'delete' 'util.js' '') 'd3' (New-Checkpoint $p)
        $res.output | Should Match 'needs a person'
        @($s.Events | Where-Object { $_.type -eq 'human-required' }).Count | Should Be 1
        Test-Path (Join-Path $p 'util.js') | Should Be $true
    }
    It 'refuses a move in an answer-only task and skips it in plan mode' {
        $p = New-Proj 'a3'
        $s = New-TestState $p
        $s.TaskIntent = 'answer'
        (Invoke-Act $s (New-Act 'move' '' 'app.js -> js/app.js') 'm1' (New-Checkpoint $p)).output | Should Match 'does not authorize file changes'
        $s.TaskIntent = $null; $s.Mode = 'plan'
        (Invoke-Act $s (New-Act 'move' '' 'app.js -> js/app.js') 'm2' (New-Checkpoint $p)).output | Should Match 'plan mode'
        Test-Path (Join-Path $p 'app.js') | Should Be $true
    }
    It 'answers refs and changes as read-only steps' {
        $p = New-Proj 'a4'
        $s = New-TestState $p 'plan'
        (Invoke-Act $s (New-Act 'refs' 'greet' '') 'r1' $null).output | Should Match 'util\.js:1'
        (Invoke-Act $s (New-Act 'changes' '' '') 'c1' (New-Checkpoint $p)).output | Should Match 'No file has changed'
    }
    It 'runs the project''s tests by the helper''s own command, and says when there are none or commands are off' {
        $p = New-Proj 'a5'
        $s = New-TestState $p
        (Invoke-Act $s (New-Act 'test' '' '') 't1' (New-Checkpoint $p)).output | Should Match 'no tests the helper program can run'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $p 'tests')
        [IO.File]::WriteAllText((Join-Path $p 'Calc.ps1'), "function Add-One([int]`$n) { `$n + 1 }`n")
        [IO.File]::WriteAllText((Join-Path $p 'tests\Calc.Tests.ps1'), ". (Join-Path (Split-Path -Parent `$PSScriptRoot) 'Calc.ps1')`nDescribe 'Calc' { It 'adds one' { Add-One 1 | Should Be 2 } }`n")
        $res = Invoke-Act $s (New-Act 'test' 'Calc.ps1' '') 't2' (New-Checkpoint $p)
        $res.output | Should Match 'Invoke-Pester'
        $res.ok | Should Be $true
        (Invoke-Act $s (New-Act 'test' 'nope.ps1' '') 't3' (New-Checkpoint $p)).output | Should Match 'not a file of the project'
        $s.NoCommands = $true
        (Invoke-Act $s (New-Act 'test' '' '') 't4' (New-Checkpoint $p)).output | Should Match 'commands are not allowed'
    }
    It 'counts a delete as progress and refs, changes and test as looking around' {
        $del = New-Act 'delete' 'x' ''
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        Test-RoundProgress @($del) @(@{ ok = $true; action = $del; output = 'deleted x'; changedPath = @() }) $seen | Should Be $true
        & (Get-Module Agent) { param($a) Test-ExploreRound $a @() } @((New-Act 'refs' 'x' ''), (New-Act 'changes' '' '')) | Should Be $true
        & (Get-Module Agent) { param($a) Test-ExploreRound $a @() } @((New-Act 'move' '' 'a -> b')) | Should Be $false
    }
}

Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_STATE_ROOT = $null
