# The project's own tests after a change (lib/TestRunner.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\TestRunner.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

function Add-File($p, $rel, $text) { $full = Join-Path $p $rel; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, $text) }
function New-PsProject {
    $p = Join-Path $env:TEMP ('ccb-tests-' + [guid]::NewGuid().ToString('N'))
    Add-File $p 'src/Calc.psm1' "function Add-Two(`$a) { `$a + 2 }`nExport-ModuleMember -Function Add-Two`n"
    Add-File $p 'src/Other.psm1' "function Get-One { 1 }`n"
    Add-File $p 'tests/Calc.Tests.ps1' "Import-Module (Join-Path `$PSScriptRoot '..\src\Calc.psm1') -Force`nDescribe 'Calc' { It 'adds two' { Add-Two 1 | Should Be 3 } }`n"
    Add-File $p 'tests/Uses.Tests.ps1' "# checks Other.psm1`nDescribe 'Other' { It 'is one' { 1 | Should Be 1 } }`n"
    Add-File $p 'tests/Unrelated.Tests.ps1' "Describe 'x' { It 'y' { 1 | Should Be 1 } }`n"
    $p
}

Describe 'Find-TestCommand' {
    It 'picks the Pester tests that belong to the changed files' {
        $p = New-PsProject
        try {
            $t = Find-TestCommand $p @('src/Calc.psm1')
            $t.kind | Should Be 'pester'
            $t.scope | Should Be 'related'
            @($t.tests) -join ',' | Should Be 'tests/Calc.Tests.ps1'
            $t.command | Should Match "Invoke-Pester -Path 'tests/Calc.Tests.ps1' -EnableExit"
            @((Find-TestCommand $p @('src/Other.psm1')).tests) -join ',' | Should Be 'tests/Uses.Tests.ps1'   # mentions the file
            # Nothing related: all tests. Only non-code changes: no tests at all.
            $none = Join-Path $p 'src/New.psm1'; [IO.File]::WriteAllText($none, 'function New-X { }')
            (Find-TestCommand $p @('src/New.psm1')).scope | Should Be 'all'
            Find-TestCommand $p @('README.md') | Should Be $null
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'runs, and a failing test gives a non-zero exit code' {
        $p = New-PsProject
        try {
            $t = Find-TestCommand $p @('src/Calc.psm1')
            (Invoke-RunAction $p $t.command 120 6000).exitCode | Should Be 0
            [IO.File]::WriteAllText((Join-Path $p 'src/Calc.psm1'), "function Add-Two(`$a) { `$a + 3 }`nExport-ModuleMember -Function Add-Two`n")
            (Invoke-RunAction $p $t.command 120 6000).exitCode | Should Not Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'uses npm test only when the project has a real test script and npm is installed' {
        $p = Join-Path $env:TEMP ('ccb-npm-' + [guid]::NewGuid().ToString('N'))
        Add-File $p 'package.json' '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}'
        Add-File $p 'src/app.js' 'export const a = 1;'
        try {
            Find-TestCommand $p @('src/app.js') | Should Be $null
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
