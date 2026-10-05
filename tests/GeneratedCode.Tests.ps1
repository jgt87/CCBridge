# Checks for mistakes typical of generated code (Find-GeneratedCodeIssues and Test-ToolSyntax in
# lib/Lint.psm1): each breakage is reported, the correct form is not. Non-ASCII characters are made
# with [char] so this file stays ASCII.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force

$lq = [char]0x201C; $rq = [char]0x201D; $nbsp = [char]0x00A0; $zw = [char]0x200B; $cite1 = [char]0x3010; $cite2 = [char]0x2020; $cite3 = [char]0x3011
function Get-Gen([string]$Path, [string]$Text) { @(Find-GeneratedCodeIssues $Path $Text) -join ' | ' }

Describe 'Find-GeneratedCodeIssues: what a chat answer brings along' {
    It 'finds curly quotes, odd spaces, citation markers, HTML entities, chat sentences and escaped files' {
        Get-Gen 'a.js' "const s = ${lq}hi${rq};`n" | Should Match 'typographic quotes'
        Get-Gen 'a.js' "const s = 'say ${lq}hi${rq}';`n" | Should Be ''              # inside a string: text, fine
        Get-Gen 'a.py' "x =${nbsp}1`n" | Should Match 'non-breaking or zero-width'
        Get-Gen 'a.ps1' "`$a = 1$zw`n" | Should Match 'non-breaking or zero-width'
        Get-Gen 'a.js' "const a = 1; ${cite1}4:0${cite2}source${cite3}`n" | Should Match 'citation marker'
        Get-Gen 'a.py' "x = 1 [1](https://example.org)`n" | Should Match 'citation marker'
        Get-Gen 'a.py' "x = 1  # see [1](https://example.org)`n" | Should Be ''   # in a comment: harmless
        Get-Gen 'a.js' "if (a &amp;&amp; b) { go(); }`n" | Should Match 'HTML entities'
        Get-Gen 'a.tsx' "const t = <p>Fish &amp; chips</p>;`n" | Should Be ''        # JSX text may hold entities
        Get-Gen 'a.ps1' "Here is the updated script:`nGet-Date`n" | Should Match 'starts with a sentence'
        Get-Gen 'a.js' ('const a = 1;\nconst b = 2;\nconst c = 3;\nconst d = 4;\nconst e = 5;\nconst f = 6;\n' * 4) | Should Match 'one line with \\n'
        Get-Gen 'a.md' "Here is the text with ${lq}quotes${rq}`n" | Should Be ''      # documents are not code
    }
}

Describe 'Find-GeneratedCodeIssues: per language' {
    It 'JavaScript: TypeScript syntax, imports in blocks, mixed module systems, two default exports, top-level redeclarations' {
        Get-Gen 'a.js' "function add(a: number, b: number) { return a + b; }`n" | Should Match 'TypeScript syntax'
        Get-Gen 'a.js' "interface User { name: string }`n" | Should Match 'TypeScript syntax'
        Get-Gen 'a.ts' "interface User { name: string }`n" | Should Be ''
        Get-Gen 'a.js' "function f() {`n  import x from './x.js';`n}`n" | Should Match 'import inside a block'
        Get-Gen 'a.js' "import x from './x.js';`nmodule.exports = { x };`n" | Should Match 'mixes ES modules'
        Get-Gen 'a.js' "export default 1;`nexport default 2;`n" | Should Match 'second export default'
        Get-Gen 'a.js' "const total = 1;`nconst total = 2;`n" | Should Match "'total' is declared a second time"
        Get-Gen 'a.js' "import x from './x.js';`nexport const total = x + 1;`nfunction f() { const total = 2; return total; }`n" | Should Be ''
    }
    It 'Python: Python 2 print and nested f-string quotes' {
        Get-Gen 'a.py' "print 'hello'`n" | Should Match 'Python 2 print'
        Get-Gen 'a.py' "print('hello')`nprinter = 1`n" | Should Be ''
        Get-Gen 'a.py' "s = f`"{row[`"name`"]}`"`n" | Should Match 'f-string'
        Get-Gen 'a.py' "s = f`"{row['name']}`"`n" | Should Be ''
    }
    It 'PowerShell: PowerShell 7 features in a 5.1 script, unless the script asks for 7 or defines the name itself' {
        Get-Gen 'a.ps1' "`$o = `$j | ConvertFrom-Json -AsHashtable`n" | Should Match 'PowerShell 7 only'
        Get-Gen 'a.ps1' "1..3 | ForEach-Object -Parallel { `$_ }`n" | Should Match 'PowerShell 7 only'
        Get-Gen 'a.ps1' "#Requires -Version 7`n`$o = `$j | ConvertFrom-Json -AsHashtable`n" | Should Be ''
        Get-Gen 'a.ps1' "function Test-Json(`$t) { `$t }`nTest-Json 'x'`n" | Should Be ''
        Get-Gen 'a.ps1' "# ConvertFrom-Json -AsHashtable is 7 only`n`$o = `$j | ConvertFrom-Json`n" | Should Be ''   # in a comment
    }
    It 'CSS: // comments and SCSS syntax' {
        Get-Gen 'a.css' "// header`nh1 { color: red; }`n" | Should Match 'not a comment in CSS'
        Get-Gen 'a.css' "body { background: url(https://example.org/a.png); }`n" | Should Be ''
        Get-Gen 'a.css' "`$main: #333;`nh1 { color: `$main; }`n" | Should Match 'SCSS syntax'
        Get-Gen 'a.scss' "`$main: #333;`n" | Should Be ''
    }
    It 'Batch: single % in for loops and !name! without delayed expansion' {
        Get-Gen 'a.cmd' "@echo off`r`nfor %f in (*.txt) do echo %f`r`n" | Should Match 'needs %%'
        Get-Gen 'a.cmd' "@echo off`r`nfor %%f in (*.txt) do echo %%f`r`n" | Should Be ''
        Get-Gen 'a.cmd' "@echo off`r`nset n=1`r`necho !n!`r`n" | Should Match 'enabledelayedexpansion'
        Get-Gen 'a.cmd' "@echo off`r`nsetlocal enabledelayedexpansion`r`nset n=1`r`necho !n!`r`n" | Should Be ''
    }
}

Describe 'Test-ToolSyntax and Get-NewFileIssues' {
    It 'uses node --check when Node.js is installed, and reports only what a change broke' {
        $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
        if (-not $node) { Set-TestInconclusive 'Node.js is not installed here'; return }
        @(Test-ToolSyntax 'a.js' "const a = 1;`n").Count | Should Be 0
        $bad = @(Test-ToolSyntax 'a.js' "const a = ;`n")
        $bad[0] | Should Match '^line 1: node says: SyntaxError'
        # A change that breaks the file is reported; the same problem already there is not.
        (@(Get-NewFileIssues 'a.js' "const a = 1;`n" "const a = ;`n") -join ' | ') | Should Match 'node says'
        (@(Get-NewFileIssues 'a.js' "const a = ;`n" "const a = ;`nconst b = 2;`n") -join ' | ') | Should Not Match 'node says'
        @(Test-ToolSyntax 'a.mjs' "import x from './x.js';`nexport const y = x;`n").Count | Should Be 0   # modules are fine
    }
}
