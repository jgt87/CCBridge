# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# Safeguards around Copilot's changes: left-out code, cut-off replies, the view after an edit,
# and syntax checks of changed files.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

$old = "function a() {`n  return 1;`n}`nfunction b() {`n  return 2;`n}`n"

Describe 'Find-PlaceholderLine (left-out code)' {
    It 'finds the usual ways of leaving code out' {
        foreach ($p in @(
            '// ... rest of the code unchanged',
            '// rest of the file stays the same',
            '/* existing functions remain unchanged */',
            '<!-- existing content here -->',
            '<!-- ... -->',
            '# ... existing code ...',
            '...',
            '// (other methods omitted for brevity)',
            '  // ...'
        )) {
            $hit = Find-PlaceholderLine $old "function a() {`n  return 1;`n}`n$p`n"
            $hit.text | Should Be $p.Trim()
            $hit.line | Should Be 4
        }
    }
    It 'leaves normal comments and code alone' {
        foreach ($ok in @(
            '// remaining items are added below',
            '// keep the user signed in',
            '# other options: see the README',
            'const rest = items.slice(1);',
            'console.log("...");',
            '// TODO: handle errors',
            'for (const x of xs) { /* ... */ }'
        )) { Find-PlaceholderLine $old "$old$ok`n" | Should BeNullOrEmpty }
    }
    It 'ignores a placeholder line that was already in the file' {
        Find-PlaceholderLine "a`n// ...`nb" "a`n// ...`nb`nc" | Should BeNullOrEmpty
    }
}

Describe 'Get-ChangedView (the lines after an edit)' {
    $new = $old.Replace("  return 2;", "  const x = 2;`n  return x;")
    It 'shows the changed lines with a line of context, and their line numbers' {
        $v = Get-ChangedView $old $new 'app.js' 'app.js'
        $v | Should Match 'Lines 4-7 of app\.js now'
        $v | Should Match '(?s)````\nfunction b\(\) \{\n  const x = 2;\n  return x;\n\}\n````'
    }
    It 'returns nothing when nothing changed' {
        Get-ChangedView $old $old 'app.js' 'app.js' | Should BeNullOrEmpty
    }
}

Describe 'Test-ProjectConsistency -SyntaxOnly' {
    $proj = Join-Path $env:TEMP ('ccb-safe-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $proj
    [IO.File]::WriteAllText((Join-Path $proj 'data.json'), '{ "a": 1, }x')
    [IO.File]::WriteAllText((Join-Path $proj 'page.html'), '<link href="missing.css">')
    It 'reports syntax errors but not missing references' {
        @(Test-ProjectConsistency $proj @('data.json') -SyntaxOnly)[0] | Should Match 'not valid JSON'
        @(Test-ProjectConsistency $proj @('page.html') -SyntaxOnly).Count | Should Be 0
        @(Test-ProjectConsistency $proj @('page.html')).Count | Should Be 1
    }
    cmd /c "rmdir /s /q ""$proj"" >nul 2>&1"
}

Describe 'Cut-off replies' {
    It 'marks a last block without a closing fence as not closed' {
        $f4 = '````'
        $reply = "Here it is:`n$($f4)write app.js`nfunction a() {`n  return 1;"
        $acts = @(Get-ActionBlocks $reply)
        $acts.Count | Should Be 1
        $acts[0].closed | Should Be $false
        @(Get-ActionBlocks "$reply`n}`n$f4")[0].closed | Should Be $true
    }
}

Describe 'Get-ChangedView widens a change that cuts into blocks' {
    It 'shows whole blocks when the change spans the end of one and the start of the next' {
        $n2 = $old.Replace("}`nfunction b() {", "}`n`nfunction b() {")
        $v = Get-ChangedView $old $n2 'app.js' 'app.js'
        $v | Should Match 'Lines \d+-\d+ of app\.js now'
    }
}
Describe 'Invoke-AgentAction safeguards' {
    Import-Module (Join-Path $root 'lib\Config.psm1') -Force
    Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
    $config = Get-CCBridgeConfig harness $root
    $proj = Join-Path $env:TEMP ('ccb-act-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $proj
    $big = ((1..200 | ForEach-Object { "function f$_() {`n  return $_;`n}" }) -join "`n") + "`n"
    [IO.File]::WriteAllText((Join-Path $proj 'app.js'), $big)
    $s = New-AgentState -Config $config -AppRoot $root
    $s.ProjectRoot = $proj
    $s.Mode = 'auto'
    $act = { param($st, $a) & (Get-Module Agent) { param($st2, $a2) Invoke-AgentAction $st2 $a2 'x-1' $null 0 } $st $a }

    It 'refuses a write that leaves code out with a placeholder, and keeps the file' {
        $a = [pscustomobject]@{ type = 'write'; arg = 'app.js'; body = "function f1() {`n  return 1;`n}`n// ... rest of the code unchanged`n"; closed = $true; edits = @() }
        $r = & $act $s $a
        $r.ok | Should Be $false
        $r.output | Should Match 'stands for code that was left out'
        [IO.File]::ReadAllText((Join-Path $proj 'app.js')) | Should BeExactly $big
    }
    It 'stops a write that makes a file much shorter for approval, also in auto mode' {
        $s.Cancel = $true   # nobody approves: the wait ends as rejected
        $a = [pscustomobject]@{ type = 'write'; arg = 'app.js'; body = "function f1() {`n  return 1;`n}`n"; closed = $true; edits = @() }
        $r = & $act $s $a
        $r.ok | Should Be $false
        @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'action' -and $_.warning -match 'much shorter' }).Count | Should BeGreaterThan 0
        [IO.File]::ReadAllText((Join-Path $proj 'app.js')) | Should BeExactly $big
        $s.Cancel = $false
    }
    It 'reports the changed lines after an edit' {
        $a = [pscustomobject]@{ type = 'edit'; arg = 'app.js'; body = ''; closed = $true; edits = @(@{ search = "function f2() {`n  return 2;"; replace = "function f2() {`n  return 22;" }) }
        $r = & $act $s $a
        $r.ok | Should Be $true
        $r.output | Should Match '(?s)edited app\.js.*Lines \d+-\d+ of app\.js now.*return 22;'
    }
    cmd /c "rmdir /s /q ""$proj"" >nul 2>&1"
}