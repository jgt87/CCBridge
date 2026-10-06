# Fix attempts that go further each time (Agent New-FixAttemptMessage, Submit-IssueFix,
# Invoke-IssueCycle; Lint Get-OpenBlocks; Executor Format-LineChange): 1 the problems, 2 a diagnosis
# with evidence in Think deeper, 3 fresh eyes in a new chat from the last good version.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Issues.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force

$broken = "function render(items) {`n  if (items.length) {`n    return items.map((it) => {`n      return it.name;`n    });`n  // the if is never closed`n}`n"

Describe 'The bracket map' {
    It 'names the blocks still open at a line and where they start, outermost first' {
        $text = "function render(items) {`n  if (items.length) {`n    const s = `"{ not a block`";`n    return items.map((it) => {`n"
        $open = @(Get-OpenBlocks 'app.js' $text 4)
        ($open | ForEach-Object { "$($_.line)$($_.ch)" }) -join ',' | Should Be '1{,2{,4(,4{'
        $map = Format-OpenBlocks 'app.js' $text 4
        $map | Should Match "- line 1 '\{': function render\(items\) \{"
        $map | Should Match "- line 4 '\(': return items\.map"
    }
    It 'works for Python, CSS and Prisma, and says nothing for files without brackets to count' {
        @(Get-OpenBlocks 'a.py' "x = foo(`n  [1, 2,`n" 2).Count | Should Be 2
        @(Get-OpenBlocks 'a.css' ".a {`n  color: red;`n" 2).Count | Should Be 1
        @(Get-OpenBlocks 'schema.prisma' "model A {`n  id Int @id`n" 2).Count | Should Be 1
        Format-OpenBlocks 'notes.md' "(open" 1 | Should Be ''
    }
}

Describe 'How a file changed' {
    It 'shows the lines that differ with a little context, and nothing for the same text' {
        $d = Format-LineChange "a`nb`nc`nd" "a`nb`nX`nY`nd"
        $d | Should Match '- c'
        $d | Should Match '\+ X'
        $d | Should Match '  d'
        Format-LineChange "same" "same" | Should Be ''
        $long = (1..300 | ForEach-Object { "line $_" }) -join "`n"
        Format-LineChange '' $long 20 | Should Match '\(281 more changed line\(s\) not shown\)'
    }
}

Describe 'Fix attempts' {
    $p = Join-Path $env:TEMP ('ccb-ladder-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $p | Out-Null
    $f = Join-Path $p 'app.js'
    # The good version, the change that broke it (change set 1), and a fix attempt that did not help (change set 2).
    [IO.File]::WriteAllText($f, "function render(items) {`n  if (items.length) {`n    return items.map((it) => it.name);`n  }`n}`n")
    $cp1 = New-Checkpoint $p 'broke it'; Save-CheckpointFile $cp1 $p $f
    [IO.File]::WriteAllText($f, $broken.Replace('  // the if is never closed', '  // first try'))
    Start-Sleep -Milliseconds 20
    $cp2 = New-Checkpoint $p 'attempt 1'; Save-CheckpointFile $cp2 $p $f
    [IO.File]::WriteAllText($f, $broken)
    $issues = @(@{ line = 1; message = "'{' is never closed" })

    It 'attempt 1 is the plain list of problems' {
        New-FixAttemptMessage $p 'app.js' $issues 1 | Should Be (New-FixMessage 'app.js' $issues 1)
    }
    It 'attempt 2 asks for the cause first and brings the evidence' {
        $m = New-FixAttemptMessage $p 'app.js' $issues 2 @{ origin = $cp1.Id; lastChange = $cp2.Id }
        $m | Should Match 'first find the real cause instead of repeating that change'
        $m | Should Match 'What the previous attempt changed in app\.js'
        $m | Should Match '-   // first try'
        $m | Should Match '\+   // the if is never closed'
        $m | Should Match "Brackets still open at the end of line 1 in app\.js"
        $m | Should Match 'The file as it is now, around the problems'
        $m | Should Match 'Start your reply with a line that begins with Cause:'
    }
    It 'attempt 3 starts from the last version without the problem, with the earlier diagnosis' {
        $m = New-FixAttemptMessage $p 'app.js' $issues 3 @{ origin = $cp1.Id; lastChange = $cp2.Id; diagnosis = 'The map callback closes the if.' }
        $m | Should Match 'fresh eyes'
        $m | Should Match 'Earlier diagnosis .*: The map callback closes the if\.'
        $m | Should Match 'The last version of app\.js without these problems'
        $m | Should Match '-     return items\.map\(\(it\) => it\.name\);'
        $m | Should Match 'rebuild the broken part from that version'
        $m | Should Not Match 'What the previous attempt changed'
    }
    It 'queues attempt 2 in Think deeper and attempt 3 in a new chat' {
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s.ProjectRoot = $p
        Mock -ModuleName Agent Set-IssueState { }
        Mock -ModuleName Agent Submit-AgentTask { @{ task = $Task } }
        $one = Submit-IssueFix $s 'app.js' @(@{ id = 'i1'; line = 1; message = 'x' }) 1 @('error') $p @{ origin = $cp1.Id }
        $one.task.responseMode | Should BeNullOrEmpty
        $one.task.issueFix.origin | Should Be $cp1.Id
        $two = Submit-IssueFix $s 'app.js' @(@{ id = 'i1'; line = 1; message = 'x' }) 2 @('error') $p @{ origin = $cp1.Id; lastChange = $cp2.Id }
        $two.task.responseMode | Should Be 'deep'
        $two.task.freshChat | Should BeNullOrEmpty
        $three = Submit-IssueFix $s 'app.js' @(@{ id = 'i1'; line = 1; message = 'x' }) 3 @('error') $p @{ origin = $cp1.Id; diagnosis = 'd' }
        $three.task.freshChat | Should Be $true
        $three.task.issueFix.diagnosis | Should Be 'd'
        (Submit-IssueFix $s 'app.js' @(@{ id = 'i1' }) 4 @('error') $p @{}) | Should BeNullOrEmpty   # past 3 attempts (the default)
    }
    It 'reads Copilot''s diagnosis from its reply' {
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        Add-AgentEvent $s 'assistant' @{ text = "Cause: the arrow function's block closes the if,`nso the function's brace closes the if instead.`n`nHere is the fix:`n``````text`nACTION edit app.js`n``````" }
        & (Get-Module Agent) { param($st) Get-FixDiagnosis $st 0 } $s | Should Be "the arrow function's block closes the if, so the function's brace closes the if instead."
        $s2 = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        Add-AgentEvent $s2 'assistant' @{ text = '**Cause:** a missing } after the map call.' }
        & (Get-Module Agent) { param($st) Get-FixDiagnosis $st 0 } $s2 | Should Be 'a missing } after the map call.'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
