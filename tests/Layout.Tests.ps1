# Project folder layout: the one-time move of older projects, the .streamhub/ write guard and the
# folder rules sent to Copilot.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Layout.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force

function New-LayoutProject {
    $dir = Join-Path $env:TEMP ('ccb-layout-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $dir
}
function Add-TestFile($Root, $Rel, $Text = 'x') {
    $full = Join-Path $Root $Rel
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
    [IO.File]::WriteAllText($full, $Text)
}

Describe 'Get-LayoutPath' {
    It 'gives the project-relative folders' {
        Get-LayoutPath Exports 'a.json' | Should BeExactly 'Runbooks/Exports/a.json'
        Get-LayoutPath History | Should BeExactly '.streamhub/History'
        Get-LayoutPath Evidence | Should BeExactly '.streamhub/Evidence'
        Get-LayoutPath Source | Should BeExactly 'Source'
        { Get-LayoutPath Nope } | Should Throw
    }
}

Describe 'Move-ProjectLayout' {
    It 'moves StreamHub records into .streamhub and capitalises its folders, leaving the project''s own files' {
        $p = New-LayoutProject
        Add-TestFile $p 'evidence\task-20261003-091500.md' 'e'
        Add-TestFile $p 'evidence\photo.png' 'mine'
        Add-TestFile $p 'reviews\review-20261002-120000.md' 'r'
        Add-TestFile $p 'reviews\review-20261002-120000.json' '{}'
        Add-TestFile $p 'History\prices-20261001-080000.md' 'h'
        Add-TestFile $p 'PLAN.md' "# Plan`n<!-- plan:abc -->"
        Add-TestFile $p 'source\keep.csv' 'a,b'
        Add-TestFile $p 'scripts\make.ps1' 'x'
        Add-TestFile $p 'data\d.json' '{}'
        $null = @(Move-ProjectLayout $p)
        Test-Path (Join-Path $p '.streamhub\Evidence\task-20261003-091500.md') | Should Be $true
        Test-Path (Join-Path $p 'evidence\photo.png') | Should Be $true          # not StreamHub's: stays
        Test-Path (Join-Path $p '.streamhub\Reviews\review-20261002-120000.json') | Should Be $true
        Test-Path (Join-Path $p 'reviews') | Should Be $false
        Test-Path (Join-Path $p '.streamhub\History\prices-20261001-080000.md') | Should Be $true
        Test-Path (Join-Path $p '.streamhub\PLAN.md') | Should Be $true
        Test-Path (Join-Path $p 'PLAN.md') | Should Be $false
        @([IO.Directory]::GetDirectories($p, 'Source') | Split-Path -Leaf) | Should BeExactly 'Source'
        @([IO.Directory]::GetDirectories($p, 'Scripts') | Split-Path -Leaf) | Should BeExactly 'Scripts'
        @([IO.Directory]::GetDirectories($p, 'data') | Split-Path -Leaf) | Should BeExactly 'data'          # code folders keep their name
        Test-Path (Join-Path $p 'Source\keep.csv') | Should Be $true
        Remove-Item $p -Recurse -Force
    }

    It 'moves fetch prompts, runbooks, exports and history into the new folders' {
        $p = New-LayoutProject
        Add-TestFile $p 'fetch\today.prompt.md' 'List my meetings.'
        Add-TestFile $p 'fetch\today.md' '# today'
        Add-TestFile $p 'runbooks\meetings.runbook.md' "---`ntitle: Meetings`noutput: exports/meetings.json`n---`nbody"
        Add-TestFile $p 'exports\meetings.json' '{}'
        Add-TestFile $p 'exports\history\meetings-20261001-080000.json' '{}'
        Add-TestFile $p 'source\keep.csv' 'a,b'
        $moved = @(Move-ProjectLayout $p)
        $moved.Count -gt 0 | Should Be $true
        Test-Path (Join-Path $p 'Runbooks\today.prompt.md') | Should Be $true
        Test-Path (Join-Path $p 'Runbooks\Exports\today.md') | Should Be $true
        Test-Path (Join-Path $p 'Runbooks\Exports\meetings.json') | Should Be $true
        Test-Path (Join-Path $p '.streamhub\History\meetings-20261001-080000.json') | Should Be $true
        @([IO.Directory]::GetDirectories($p, 'Runbooks') | Split-Path -Leaf) | Should BeExactly 'Runbooks'
        [IO.File]::ReadAllText((Join-Path $p 'Runbooks\meetings.runbook.md')) | Should Match '(?m)^output: Runbooks/Exports/meetings\.json'
        Test-Path (Join-Path $p 'fetch') | Should Be $false
        Test-Path (Join-Path $p 'exports') | Should Be $false
        Test-Path (Join-Path $p 'source\keep.csv') | Should Be $true
        @(Move-ProjectLayout $p).Count | Should Be 0     # once: a second run finds nothing to do
        Remove-Item $p -Recurse -Force
    }
    It 'never overwrites: a clash keeps both files' {
        $p = New-LayoutProject
        Add-TestFile $p 'exports\a.json' 'old'
        Add-TestFile $p 'Runbooks\Exports\a.json' 'new'
        $null = Move-ProjectLayout $p
        [IO.File]::ReadAllText((Join-Path $p 'Runbooks\Exports\a.json')) | Should BeExactly 'new'
        [IO.File]::ReadAllText((Join-Path $p 'exports\a.json')) | Should BeExactly 'old'
        Remove-Item $p -Recurse -Force
    }
    It 'does nothing in a project without the old folders' {
        $p = New-LayoutProject
        Add-TestFile $p 'src\app.js' 'let a = 1;'
        @(Move-ProjectLayout $p).Count | Should Be 0
        Remove-Item $p -Recurse -Force
    }
}

Describe '.streamhub/ is the app''s own' {
    It 'refuses writes there and allows them elsewhere' {
        $p = New-LayoutProject
        { Assert-Writable $p '.streamhub/schedules.json' } | Should Throw
        { Assert-Writable $p '.StreamHub\issues.json' } | Should Throw
        { Assert-Writable $p 'Scripts/setup.ps1' } | Should Not Throw
        Remove-Item $p -Recurse -Force
    }
}

Describe 'Folder rules sent to Copilot' {
    It 'adds the folder rules to work on files' {
        @(Get-PromptModules 'add a button' @{ Traits = @('code'); Paths = @('index.html') }) -contains 'rules:folders' | Should Be $true
        $m = New-PromptMessage -AppRoot $root -Kind 'coding' -Text 'add a button' -Sent (New-Object 'System.Collections.Generic.HashSet[string]')
        $m | Should Match 'Scripts/'
        $m | Should Match 'Runbooks/Exports/'
        $m | Should Match 'tests/.*docs/.*data/'
        $m | Should Match 'dist/.*never edit'
        $m | Should Not Match 'public/'     # the web folders come only with the web rules
    }
    It 'adds the web folders with the web rules' {
        $m = New-PromptMessage -AppRoot $root -Kind 'coding' -Text 'add a button' -Sent (New-Object 'System.Collections.Generic.HashSet[string]') -Context @{ Location = 'L'; Full = 'F'; Traits = @('web') }
        $m | Should Match 'public/ for files served'
        $m | Should Match 'src/components/'
        $m | Should Not Match 'CCBridge'
        $m -cmatch 'StreamHub' | Should Be $false     # only the folder name .streamhub
    }
}

Describe 'Where Copilot is told to find the plan' {
    It 'names the plan file where the layout keeps it, and that path can be read' {
        $server = [IO.File]::ReadAllText((Join-Path $root 'lib\Server.psm1'))
        $server | Should Match 'is in \.streamhub/PLAN\.md, in the section marked plan:'
        $server | Should Not Match 'is in PLAN\.md'
        Import-Module (Join-Path $root 'lib\Executor.psm1')
        $p = Join-Path $env:TEMP ('ccb-plan-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p '.streamhub') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $p '.streamhub\PLAN.md'), "# Plans`n<!-- plan:a -->`n## A")
        (Invoke-ReadAction $p @('.streamhub/PLAN.md')) -join '' | Should Match '## A'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}
