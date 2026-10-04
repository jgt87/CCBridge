# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# Language-specific helpers around edits: indentation, outlines, local checks.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# Project state (backups, chat history) of the test projects goes to a temporary folder, deleted below.
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force

function New-TestProject([hashtable]$Files) {
    $p = Join-Path $env:TEMP ('ccb-test-' + [guid]::NewGuid().ToString('N'))
    foreach ($k in $Files.Keys) {
        $f = Join-Path $p $k
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f)
        [IO.File]::WriteAllText($f, $Files[$k])
    }
    $p
}

Describe 'Set-EditIndent (SEARCH matched ignoring indentation)' {
    It 'shifts the new lines by as much as the file differs' {
        $r = Set-EditIndent "def f(self):`n    return 1" "    def f(self):`n        return 1" "def f(self):`n    x = 2`n    return x" 'a.py'
        $r.text | Should Be "    def f(self):`n        x = 2`n        return x"
    }
    It 'writes the indentation in the file''s style (tabs)' {
        $r = Set-EditIndent "if (a) {`n  b();`n}" "`tif (a) {`n`t`tb();`n`t}" "if (a) {`n  c();`n}" 'a.js'
        $r.text | Should Be "`tif (a) {`n`t  c();`n`t}"
    }
    It 'refuses an uneven match in Python' {
        $r = Set-EditIndent "if a:`n  b()" "    if a:`n            b()" "if a:`n  c()" 'a.py'
        $r.error | Should Match 'Python'
    }
    It 'refuses Python lines that would end up left of column 0' {
        $r = Set-EditIndent "        x = 1" "    x = 1" "y = 0`n        x = 1" 'a.py'
        $r.error | Should Match 'indented less'
    }
    It 're-indents a Python edit end to end' {
        $p = New-TestProject @{ 'm.py' = "class A:`n    def f(self):`n        return 1`n" }
        $r = Get-EditResult $p 'm.py' @(@{ search = "def f(self):`n    return 1"; replace = "def f(self):`n    return 2" })
        $r.ok | Should Be $true
        $r.new | Should Be "class A:`n    def f(self):`n        return 2`n"
        Remove-Item $p -Recurse -Force
    }
}

Describe 'Get-FileOutline for Python' {
    It 'lists classes, functions, methods and the main block' {
        $o = @(Get-FileOutline "import os`n`nclass A:`n    def f(self):`n        pass`n`nasync def main():`n    pass`n`nif __name__ == '__main__':`n    main()`n" 'x.py')
        $o -join '|' | Should Be '3  class A|4      def f|7  def main|10  if __name__ == "__main__"'
    }
}

Describe 'Test-ProjectConsistency per language' {
    It 'resolves imports like a bundler and skips packages and aliases' {
        $p = New-TestProject @{
            'src/App.tsx' = "import React from 'react';`nimport { api } from '@/lib/api';`nimport Button from './Button';`nimport { x } from './lib';`nimport { u } from './util.js';`nimport './App.css';`nimport M from './Missing';`nconst L = () => import('./Lazy');`n"
            'src/Button.tsx' = 'export default 1'
            'src/lib/index.ts' = 'export const x = 1'
            'src/util.ts' = 'export const u = 1'
            'src/App.css' = 'a {}'
            'src/Lazy.jsx' = 'export default 1'
        }
        $issues = @(Test-ProjectConsistency $p @('src/App.tsx'))
        $issues.Count | Should Be 1
        $issues[0] | Should Match 'Missing'
        Remove-Item $p -Recurse -Force
    }
    It 'finds Python indentation that mixes tabs and spaces' {
        $p = New-TestProject @{ 'a.py' = "def f():`n    x = 1`n`treturn x`n"; 'b.py' = "def f():`n `treturn 1`n"; 'ok.py' = "def f():`n    return 1`n" }
        @(Test-ProjectConsistency $p @('a.py')) -join '' | Should Match 'tabs and others with spaces'
        @(Test-ProjectConsistency $p @('b.py')) -join '' | Should Match 'b.py:2: indentation mixes'
        @(Test-ProjectConsistency $p @('ok.py')).Count | Should Be 0
        Remove-Item $p -Recurse -Force
    }
    It 'checks a PowerShell data file as data' {
        $p = New-TestProject @{ 'good.psd1' = "@{ ModuleVersion = '1.0'; FunctionsToExport = @('A') }"; 'bad.psd1' = "@{ ModuleVersion = (Get-Date) }" }
        @(Test-ProjectConsistency $p @('good.psd1')).Count | Should Be 0
        @(Test-ProjectConsistency $p @('bad.psd1')) -join '' | Should Match 'not a valid data file'
        Remove-Item $p -Recurse -Force
    }
}

Describe 'ConvertTo-CheckableScript' {
    It 'removes module syntax and keeps the line numbers' {
        $src = "import a from './a.js';`nimport {`n  b,`n  c`n} from './b.js';`nexport const x = 1;`nexport default function f() { return import.meta.url }`nexport { x as y };`nexport * from './z.js';`nawait g();`nfoo(;"
        $out = ConvertTo-CheckableScript $src
        $out | Should Not Match '\bimport\b|\bexport\b'
        ($out.Split("`n")).Count | Should Be (($src.Split("`n")).Count + 1)
        $out.Split("`n")[10] | Should Be 'foo(;'
    }
}

if ($env:CCBRIDGE_STATE_ROOT -and (Test-Path -LiteralPath $env:CCBRIDGE_STATE_ROOT)) { [IO.Directory]::Delete($env:CCBRIDGE_STATE_ROOT, $true) }
$env:CCBRIDGE_STATE_ROOT = $null