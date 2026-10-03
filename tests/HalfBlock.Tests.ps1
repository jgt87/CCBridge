# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# The half-block guard: only real block braces count, and the refusal says where.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$page = @'
<!doctype html>
<html>
<head>
<style>
  body { background: url(http://example.invalid/bg.png); }
  .card { padding: 4px; } /* a { in a comment */
</style>
</head>
<body>
<p>Use {name} in the template, or { to start.</p>
<!-- old: function x() { -->
<script>
  const label = `Total: ${sum} {items}`;
  // a } in a comment
  function total(items) {
    let s = 0;
    for (const i of items) { s += i.price; }
    return s;
  }
</script>
</body>
</html>
'@

Describe 'Test-HalfBlock in HTML' {
    It 'ignores braces in page text, comments, strings and template strings' {
        $new = $page.Replace('<p>Use {name} in the template, or { to start.</p>', '<p>Use {name} here.</p>')
        Test-HalfBlock $page $new 'index.html' | Should BeNullOrEmpty
        $new2 = $page.Replace('`Total: ${sum} {items}`', '`Total: ${sum} {{items`')
        Test-HalfBlock $page $new2 'index.html' | Should BeNullOrEmpty
        $new3 = $page.Replace('<!-- old: function x() { -->', '')
        Test-HalfBlock $page $new3 'index.html' | Should BeNullOrEmpty
    }
    It 'does not read url(http://...) in CSS as a comment' {
        (Get-BlockBalance $page 'index.html').braces | Should Be 0
    }
    It 'still refuses a real half block in a script, and says where' {
        $broken = $page.Replace("    return s;`n  }`n", "    return s;`n")
        $broken = $broken.Replace("    return s;`r`n  }`r`n", "    return s;`r`n")
        $why = Test-HalfBlock $page $broken 'index.html'
        $why | Should Match 'half open'
        $why | Should Match 'never closed at line 15: function total\(items\) \{'
        $why | Should Not Match 'send the whole edit block again'
    }
    It 'still refuses a half <style> block' {
        Test-HalfBlock $page ($page -replace '</style>', '') 'index.html' | Should Match '<style> block'
    }
}

Describe 'Test-HalfBlock per language' {
    It 'checks JavaScript, CSS and PowerShell, skipping their strings and comments' {
        Test-HalfBlock "a = 1;`n" "a = '{';`n// }`n" 'app.js' | Should BeNullOrEmpty
        Test-HalfBlock "function f() {`n}`n" "function f() {`n" 'app.js' | Should Match 'line 1'
        Test-HalfBlock ".a { b: c; }`n" ".a { content: '{'; }`n" 'x.css' | Should BeNullOrEmpty
        Test-HalfBlock "function F {`n}`n" "function F {`n  # }`n" 'x.ps1' | Should Match 'never closed'
        Test-HalfBlock "`$a = 1`n" "`$a = '{'`n# {`n" 'x.ps1' | Should BeNullOrEmpty
    }
    It 'does not check files without block braces' {
        Test-HalfBlock "text`n" "a { b`n" 'notes.md' | Should BeNullOrEmpty
        Test-HalfBlock "x = 1`n" "d = {`n" 'x.py' | Should BeNullOrEmpty
    }
    It 'finds a stray closing brace' {
        (Find-UnbalancedBrace "a {`n}`n}`n" 'x.js').line | Should Be 3
    }
}

Describe 'Register-StepFailure (no loops)' {
    It 'counts the same failure, with line numbers ignored' {
        $seen = @{}
        $a = @{ type = 'edit'; arg = 'index.html' }
        & (Get-Module Agent) { param($s, $x) Register-StepFailure $s $x 'error: pair 1: half open at line 40' } $seen $a | Should Be 1
        & (Get-Module Agent) { param($s, $x) Register-StepFailure $s $x 'error: pair 1: half open at line 41' } $seen $a | Should Be 2
        & (Get-Module Agent) { param($s, $x) Register-StepFailure $s $x 'error: SEARCH text not found' } $seen $a | Should Be 1
        & (Get-Module Agent) { param($s, $x) Register-StepFailure $s $x 'error: pair 1: half open at line 7' } $seen @{ type = 'edit'; arg = 'other.html' } | Should Be 1
    }
}

Describe 'Reads show whole blocks' {
    $proj = Join-Path $env:TEMP ('ccb-blocks-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $proj
    $js = (@(
        'const a = 1;',                 # 1
        'function total(items) {',      # 2
        '  let s = 0;',                 # 3
        '  for (const i of items) {',   # 4
        '    s += i.price;',            # 5
        '  }',                          # 6
        '  return s;',                  # 7
        '}',                            # 8
        'const b = 2;'                  # 9
    ) -join "`n")
    [IO.File]::WriteAllText((Join-Path $proj 'app.js'), $js)
    [IO.File]::WriteAllText((Join-Path $proj 'index.html'), $page)

    It 'widens a range that starts inside a block and ends after it' {
        $w = Expand-ToWholeBlocks $js 'app.js' 3 9
        "$($w.from)-$($w.to)" | Should Be '2-9'
    }
    It 'widens a range that cuts a block at its end' {
        $w = Expand-ToWholeBlocks $js 'app.js' 1 4
        "$($w.from)-$($w.to)" | Should Be '1-8'
    }
    It 'leaves a range that cuts no block (inside one, or around whole ones) as it is' {
        $w = Expand-ToWholeBlocks $js 'app.js' 4 7
        "$($w.from)-$($w.to)" | Should Be '4-7'
        $w = Expand-ToWholeBlocks $js 'app.js' 3 3
        "$($w.from)-$($w.to)" | Should Be '3-3'
        $w = Expand-ToWholeBlocks $js 'app.js' 2 8
        "$($w.from)-$($w.to)" | Should Be '2-8'
    }
    It 'shows the widened lines in a ranged read and says so' {
        $out = (Invoke-ReadAction $proj @('app.js:5-8')) -join "`n"
        $out | Should Match 'lines 5-8 asked; widened to 2-8 so every block in it is complete'
        $out | Should Match 'function total\(items\) \{'
        $out | Should Not Match 'const b = 2'
    }
    It 'widens a range that cuts a <style> block in HTML' {
        $out = (Invoke-ReadAction $proj @('index.html:3-5')) -join "`n"
        $out | Should Match 'widened to 3-7'
        $out | Should Match '</style>'
    }
    It 'shows the whole block with a half-block refusal' {
        $r = Get-EditResult $proj 'app.js' @(@{ search = "function total(items) {`n  let s = 0;"; replace = '' })
        $r.ok | Should Be $false
        $r.error | Should Match 'Current lines 2-8 of app\.js'
        $r.error | Should Match '(?s)````\nfunction total\(items\) \{.*  return s;\n\}\n````'
    }
    cmd /c "rmdir /s /q ""$proj"" >nul 2>&1"
}