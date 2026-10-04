# The import index: who uses which file on which line (imports and hook points), kept current
# after every round, and what a round broke.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Imports.psm1') -Force

function New-ImportProject {
    $dir = Join-Path $env:TEMP ('ccb-imports-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $dir
}
function Set-ImportFile($Root, $Rel, $Text) {
    $full = Join-Path $Root $Rel
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
    [IO.File]::WriteAllText($full, $Text)
}

Describe 'Get-FileLinks' {
    It 'finds JS imports with their lines and resolves extensionless paths' {
        $p = New-ImportProject
        Set-ImportFile $p 'src\lib\util.ts' 'export const a = 1;'
        Set-ImportFile $p 'src\main.ts' "import React from 'react';`nimport { a } from './lib/util';`nconst b = require('./lib/util.js');"
        $l = Get-FileLinks $p 'src/main.ts' ([IO.File]::ReadAllText((Join-Path $p 'src\main.ts')))
        @($l.refs).Count | Should Be 2
        $l.refs[0].line | Should Be 2
        $l.refs[0].target | Should Be 'src/lib/util.ts'
        $l.refs[1].target | Should Be 'src/lib/util.ts'
        Remove-Item $p -Recurse -Force
    }
    It 'finds script and stylesheet tags, ids and inline handlers in HTML' {
        $p = New-ImportProject
        Set-ImportFile $p 'js\app.js' 'function save() {}'
        Set-ImportFile $p 'css\site.css' 'body {}'
        $html = "<link rel=""stylesheet"" href=""css/site.css"">`n<button id=""save-btn"" onclick=""save()"">Save</button>`n<script src=""js/app.js""></script>"
        $l = Get-FileLinks $p 'index.html' $html
        @($l.refs | ForEach-Object { "$($_.line):$($_.target)" }) -join ',' | Should Be '3:js/app.js,1:css/site.css'
        @($l.defs | Where-Object { $_.kind -eq 'id' }).name | Should Be 'save-btn'
        @($l.uses | Where-Object { $_.kind -eq 'fn' }).name | Should Be 'save'
        Remove-Item $p -Recurse -Force
    }
    It 'finds Python and PowerShell imports of project files' {
        $p = New-ImportProject
        Set-ImportFile $p 'pkg\helpers.py' 'def f(): pass'
        Set-ImportFile $p 'lib\Tools.psm1' 'function T {}'
        (Get-FileLinks $p 'main.py' "import os`nfrom pkg.helpers import f").refs[0].target | Should Be 'pkg/helpers.py'
        (Get-FileLinks $p 'run.ps1' "Import-Module (Join-Path `$PSScriptRoot 'lib\Tools.psm1')").refs[0].target | Should Be 'lib/Tools.psm1'
        Remove-Item $p -Recurse -Force
    }
}

Describe 'Get-ImportUsers and Format-ImportUsers' {
    It 'lists who imports a file and who uses its ids, functions and hooks, with lines' {
        $p = New-ImportProject
        Set-ImportFile $p 'index.html' "<div id=""total""></div>`n<button onclick=""save()"">S</button>`n<script src=""app.js""></script>"
        Set-ImportFile $p 'app.js' "function save() {}`ndocument.getElementById('total').textContent = '0';"
        Set-ImportFile $p 'src\hooks\useCart.ts' 'export function useCart() { return 1; }'
        Set-ImportFile $p 'src\Cart.tsx' "import { useCart } from './hooks/useCart';`n`nexport function Cart() { const c = useCart(); return null; }"
        $null = Update-ImportIndex $p
        $app = @(Get-ImportUsers $p 'app.js' | ForEach-Object { "$($_.path):$($_.line) $($_.what)" })
        $app -join ';' | Should Be 'index.html:3 imports app.js;index.html:2 uses save() in an inline handler'
        @(Get-ImportUsers $p 'index.html' | ForEach-Object { "$($_.path):$($_.line) $($_.what)" }) -join ';' | Should Be 'app.js:2 uses element #total'
        @(Get-ImportUsers $p 'src/hooks/useCart.ts' | ForEach-Object { "$($_.path):$($_.line)" }) -join ';' | Should Be 'src/Cart.tsx:1;src/Cart.tsx:3'
        Format-ImportUsers $p @('app.js:1-5') | Should Match '^Used by \(file:line\) for app\.js: index\.html:3 \(imports app\.js\)'
        Remove-Item $p -Recurse -Force
    }
}

Describe 'Update-ImportsAfterRound' {
    It 'follows line shifts in changed files' {
        $p = New-ImportProject
        Set-ImportFile $p 'b.js' 'export const b = 1;'
        Set-ImportFile $p 'a.js' "import { b } from './b.js';"
        $null = Update-ImportIndex $p
        Set-ImportFile $p 'a.js' "// one`n// two`nimport { b } from './b.js';"
        @(Update-ImportsAfterRound $p @('a.js')).Count | Should Be 0
        @(Get-ImportUsers $p 'b.js')[0].line | Should Be 3
        Remove-Item $p -Recurse -Force
    }
    It 'reports imports of a file the round deleted or moved' {
        $p = New-ImportProject
        Set-ImportFile $p 'b.js' 'export const b = 1;'
        Set-ImportFile $p 'a.js' "const x = 1;`nimport { b } from './b.js';"
        $null = Update-ImportIndex $p
        Move-Item (Join-Path $p 'b.js') (Join-Path $p 'c.js')
        $r = @(Update-ImportsAfterRound $p @('b.js', 'c.js'))
        $r.Count | Should Be 1
        $r[0] | Should Match '^a\.js:2: imports \./b\.js, but b\.js was deleted or moved'
        Remove-Item $p -Recurse -Force
    }
    It 'reports ids and functions a round removed while other files still use them' {
        $p = New-ImportProject
        Set-ImportFile $p 'index.html' "<div id=""total""></div>`n<button onclick=""save()"">S</button>`n<script src=""app.js""></script>"
        Set-ImportFile $p 'app.js' "function save() {}`ndocument.getElementById('total').textContent = '0';"
        $null = Update-ImportIndex $p
        Set-ImportFile $p 'index.html' "<div id=""sum""></div>`n<button onclick=""save()"">S</button>`n<script src=""app.js""></script>"
        Set-ImportFile $p 'app.js' "function store() {}`ndocument.getElementById('total').textContent = '0';"
        $r = @(Update-ImportsAfterRound $p @('index.html', 'app.js')) | Sort-Object
        $r.Count | Should Be 2
        $r[0] | Should Match '^app\.js:2: uses element #total, which this round removed from index\.html'
        $r[1] | Should Match '^index\.html:2: uses save\(\) in an inline handler, which this round removed from app\.js'
        Remove-Item $p -Recurse -Force
    }
    It 'keeps the index in .streamhub/imports.json and drops files that are gone' {
        $p = New-ImportProject
        Set-ImportFile $p 'a.js' "import './b.js';"
        Set-ImportFile $p 'b.js' ''
        $null = Update-ImportIndex $p
        Test-Path (Join-Path $p '.streamhub\imports.json') | Should Be $true
        Remove-Item (Join-Path $p 'a.js')
        (Update-ImportIndex $p).files.ContainsKey('a.js') | Should Be $false
        Remove-Item $p -Recurse -Force
    }
}
