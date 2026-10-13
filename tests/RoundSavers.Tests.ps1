# Rules that save Copilot rounds (each costs a message and tens of seconds): a structured handoff
# at a chat rollover with the facts the helper program kept, going in circles (a change undone,
# rounds alternating), grep hits with the part of the file they are in, the code around a new error
# at once, the AGENTS.md of a file's folder, and a long SEARCH matched by its first and last lines.
# Made-up files.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-rs-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Log', 'Config', 'Workspace', 'Executor', 'Handoff', 'LoopGuard', 'Agent') { Import-Module (Join-Path $root "lib\$m.psm1") -Force -DisableNameChecking }

function New-TestProject { $p = Join-Path $env:TEMP ('ccb-rs-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null; $p }
function Set-TestFile([string]$P, [string]$Rel, [string]$Text) { $f = Join-Path $P $Rel; New-Item -ItemType Directory (Split-Path $f) -Force | Out-Null; [IO.File]::WriteAllText($f, $Text) }

Describe 'The handoff at a chat rollover' {
    It 'asks for fixed headings and finds the ones missing' {
        Get-HandoffAsk | Should Match 'Objective: Requirements: Decisions: Done: Active: Blocked: Next steps: Relevant files:'
        Get-HandoffAsk | Should Not Match '(?i)ccbridge|streamhub'
        @(Get-HandoffMissing "**Objective:** a page`n## Requirements: totals`nDecisions: none`nDone: x`nActive: y`nBlocked: none`nNext steps: z`nRelevant files: src/app.js").Count | Should Be 0
        (Get-HandoffMissing "We built the page and the next step is the chart.") -join ',' | Should Be 'Objective,Requirements,Decisions,Done,Active,Blocked,Next steps,Relevant files'
    }
    It 'adds the facts the helper program kept: request, mode, changed files, open items, checks, fix' {
        $f = Format-HandoffFacts -Request 'Build a sales page' -Mode 'plan' -Changed @('src/app.js', 'src\app.js', 'index.html') `
            -Todos @([pscustomobject]@{ done = $true; text = 'Read the data' }, [pscustomobject]@{ done = $false; text = 'Draw the chart' }) `
            -DoneWhen @('The page shows totals', 'The chart draws') -Acceptance @(@{ check = 'The page shows totals'; met = $false; note = 'no data yet' }) `
            -IssueFix @{ path = 'src/app.js'; attempt = 2 } -Outlines 'src/app.js: render 4'
        $f | Should Match 'The request of this task: Build a sales page'
        $f | Should Match 'Mode: plan only'
        $f | Should Match 'Files this task changed so far \(2\): src/app\.js, index\.html'
        $f | Should Match 'Open to-do items \(1 done\): Draw the chart'
        $f | Should Match 'The page shows totals \(NOT MET: no data yet\)'
        $f | Should Match 'The chart draws \(not answered yet\)'
        $f | Should Match 'Fixing the problems in src/app\.js \(attempt 2\)'
        $f | Should Match 'src/app\.js: render 4'
        Format-HandoffFacts | Should Be ''
    }
    It 'outlines the changed code files, not data or Source/' {
        $p = New-TestProject
        try {
            Set-TestFile $p 'src\app.js' "function render() {`n  return 1;`n}`nfunction drawChart() {`n  return 2;`n}`n"
            Set-TestFile $p 'Source\x.csv' "a,b`n1,2`n"
            $o = Get-HandoffOutlines $p @('src/app.js', 'Source/x.csv')
            $o | Should Match '^src/app\.js: render 1, drawChart 4'
            $o | Should Not Match 'x\.csv'
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'asks once more when most headings are missing, and keeps the facts with the summary' {
        $p = New-TestProject
        try {
            Set-TestFile $p 'src\app.js' "function render() {`n  return 1;`n}`n"
            $global:rsSent = New-Object System.Collections.Generic.List[string]
            Mock -ModuleName Agent Send-ToCopilot { param($State, $Message) $global:rsSent.Add($Message); if ($global:rsSent.Count -eq 1) { @{ Text = 'We made the page.' } } else { @{ Text = "Objective: a page`nRequirements: totals`nDecisions: none`nDone: render`nActive: chart`nBlocked: none`nNext steps: chart`nRelevant files: src/app.js" } } }
            Mock -ModuleName Agent Start-NewChat { }
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p; $s.Throttle = @{ used = 9; max = 10 }; $s.TurnText = 'Build a sales page'
            & (Get-Module Agent) { param($st) Invoke-RolloverIfNeeded $st @{ changed = @('src/app.js'); doneWhen = @('The page shows totals') } } $s | Should Be $true
            $global:rsSent.Count | Should Be 2
            $global:rsSent[1] | Should Match '^Your handoff lacks these headings: Objective'
            $s.Summary | Should Match '^Objective: a page'
            $s.Summary | Should Match 'WHAT THE HELPER PROGRAM KEPT'
            $s.Summary | Should Match 'src/app\.js: render 1'
            $s.Summary | Should Match 'The page shows totals \(not answered yet\)'
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Going in circles' {
    It 'sees a file go back to an earlier version, not a file that keeps changing' {
        $w = New-LoopWatch
        Add-LoopFileVersion $w 'src/a.js' 'V0' -Seed | Should Be $false
        Add-LoopFileVersion $w 'src/a.js' 'V1' | Should Be $false
        Add-LoopFileVersion $w 'src/a.js' 'V1' | Should Be $false   # unchanged
        Add-LoopFileVersion $w 'src/a.js' 'V2' | Should Be $false
        Add-LoopFileVersion $w 'SRC\a.js' 'V0' | Should Be $true      # back to the version before the task
        Add-LoopFileVersion $w 'src/b.js' 'V0' -Seed | Should Be $false
        Add-LoopFileVersion $w 'src/b.js' 'W1' | Should Be $false
    }
    It 'sees rounds alternate A, B, A, B, not the same round twice or a new one' {
        $w = New-LoopWatch
        $ka = Get-RoundKey @(@{ type = 'read'; arg = 'src/a.js' })
        $kb = Get-RoundKey @(@{ type = 'edit'; arg = 'src/a.js' }, @{ type = 'done'; arg = '' })
        $kb | Should Be 'edit src/a.js'
        Add-LoopRound $w $ka | Should Be $false
        Add-LoopRound $w $kb | Should Be $false
        Add-LoopRound $w $ka | Should Be $false
        Add-LoopRound $w $kb | Should Be $true
        $w2 = New-LoopWatch
        foreach ($k in 'x', 'x', 'x') { Add-LoopRound $w2 $k | Should Be $false }
        Add-LoopRound $w2 'x' | Should Be $false
    }
    It 'tells Copilot to decide, without the program name' {
        Get-LoopNote flip @('src/a.js') | Should Match '^src/a\.js is back to a version it had earlier'
        Get-LoopNote alternate | Should Match 'alternate between the same two sets of steps'
        (Get-LoopNote flip @('a', 'b')) + (Get-LoopNote alternate) | Should Not Match '(?i)ccbridge|streamhub'
    }
}

Describe 'Grep hits with the part of the file they are in' {
    It 'names the function a hit is in and counts what it did not show' {
        $p = New-TestProject
        try {
            Set-TestFile $p 'src\app.js' "function alpha() {`n  const x = 1;`n  return needle;`n}`nfunction beta() {`n  return needle + needle2;`n}`n// needle at the end`n"
            Set-TestFile $p 'data\rows.json' '[{"a":"needle"}]'
            $g = Invoke-GrepAction $p 'needle' 'src/*.js'
            $g | Should Match '(?m)^src/app\.js:3: return needle;   \(in alpha \(line 1\)\)$'
            $g | Should Match '(?m)^src/app\.js:6: return needle \+ needle2;   \(in beta \(line 5\)\)$'
            $g | Should Not Match 'showing the first'
            $c = Invoke-GrepAction $p 'needle' '' 2
            $c | Should Match 'showing the first 2 of 4 matches in 2 files'
            (Invoke-GrepAction $p 'needle' 'data/*.json') | Should Match '(?m)^data/rows\.json:1: \[\{"a":"needle"\}\]$'
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'A long SEARCH matched by its first and last lines' {
    $file = "function total(rows) {`n  let sum = 0;`n  for (const r of rows) {`n    sum += r.amount;`n  }`n  return sum;`n}`n`nfunction other() {`n  return 1;`n}`n"
    It 'replaces the one place whose first and last lines fit, and says so' {
        $search = "function total(rows) {`n  let sum = 0;`n  for (const r of rows) sum += r.amount // damaged`n  }`n  return sum;`n}"
        $hit = Find-AnchorTarget $file $search
        $hit.loose | Should Be $true
        $hit.note | Should Match "the file's lines 1-7"
        $file.Substring($hit.start, $hit.length) | Should Be ($file.Split("`n")[0..6] -join "`n")
        $p = New-TestProject
        try {
            Set-TestFile $p 'src\t.js' $file
            $r = Get-EditResult $p 'src/t.js' @(@{ search = $search; replace = "function total(rows) {`n  return rows.reduce((s, r) => s + r.amount, 0);`n}" })
            $r.ok | Should Be $true
            $r.new | Should Match '^function total\(rows\) \{\n  return rows\.reduce'
            $r.new | Should Match 'function other\(\)'
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'refuses when the middle is mostly different, the SEARCH is short, or several places fit' {
        Find-AnchorTarget $file "function total(rows) {`n  a();`n  b();`n  c();`n  return sum;`n}" | Should BeNullOrEmpty
        Find-AnchorTarget $file "function total(rows) {`n  x`n}" | Should BeNullOrEmpty
        $two = "function go() {`n  step one here;`n  step two here;`n  step three;`n  finish now;`n}`nfunction go() {`n  step one here;`n  step two here;`n  step 3;`n  finish now;`n}`n"
        (Find-AnchorTarget $two "function go() {`n  step one here;`n  step two here;`n  step four;`n  finish now;`n}").error | Should Match 'fit 2 places \(lines 1-6, 7-12\)'
    }
}

Describe 'Folder notes and the code around a new error' {
    It 'sends the AGENTS.md of a file''s folders once per chat, never the root one or package folders' {
        $p = New-TestProject
        try {
            Set-TestFile $p 'AGENTS.md' 'Root rules.'
            Set-TestFile $p 'src\AGENTS.md' 'Use two spaces.'
            Set-TestFile $p 'src\api\AGENTS.md' 'Handlers are async.'
            Set-TestFile $p 'src\api\x.js' 'x'
            Set-TestFile $p 'node_modules\pkg\AGENTS.md' 'Package rules.'
            $sent = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $t = Get-FolderNotes $p @('src/api/x.js', 'node_modules/pkg/index.js') $sent
            $t | Should Match '(?s)Folder notes \(src/AGENTS\.md.*Use two spaces\..*Folder notes \(src/api/AGENTS\.md; they apply to the files in src/api/.*Handlers are async\.'
            $t | Should Not Match 'Root rules|Package rules'
            Get-FolderNotes $p @('src/api/x.js') $sent | Should Be ''
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'shows the whole block around a new error and counts it as read' {
        $p = New-TestProject
        try {
            $lines = @('// top') + @(1..20 | ForEach-Object { "// filler $_" }) + @('function broken() {', '  const a = 1;', '  return a +;', '}', '// end')
            Set-TestFile $p 'src\b.js' ($lines -join "`n")
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p
            $res = New-Object System.Collections.Generic.List[object]
            & (Get-Module Agent) { param($st, $r) Add-ErrorView $st $r @([pscustomobject]@{ path = 'src/b.js'; line = 24; level = 'error' }) } $s $res
            $res.Count | Should Be 1
            $res[0].output | Should Match 'count as read, so ACTION edit PATH:START-END'
            $res[0].output | Should Match '(?s)function broken\(\) \{.*return a \+;.*\}'
            @($s.ReadRanges['src/b.js']).Count | Should Be 1
            $s.ReadStamps['src/b.js'].read | Should Not BeNullOrEmpty
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
