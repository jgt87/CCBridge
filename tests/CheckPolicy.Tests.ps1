# How file-check findings are handled (lib/CheckPolicy.psm1, Issues ignores, the dispute action).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_ISSUE_INDEX = Join-Path $env:TEMP ('ccb-app-index-' + [guid]::NewGuid().ToString('N') + '.json')
Import-Module (Join-Path $root 'lib\CheckPolicy.psm1') -Force
Import-Module (Join-Path $root 'lib\Issues.psm1') -Force
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force

Describe 'Levels and keys' {
    It 'tells what breaks a file from a likely mistake' {
        Get-CheckLevel 'line 3: a { is never closed' 'file' | Should Be 'error'
        Get-CheckLevel 'line 1: node says: SyntaxError: Unexpected token' 'tool' | Should Be 'error'
        Get-CheckLevel 'line 2: PowerShell 7 only (Windows PowerShell 5.1 does not have it)' 'file' | Should Be 'warning'
        Get-CheckLevel 'line 9: // is not a comment in CSS' 'file' | Should Be 'warning'
        Get-CheckLevel 'line 4: a debug print left in' 'smell' | Should Be 'warning'
        Get-CheckLevel 'a .env file not covered by .gitignore' 'env' | Should Be 'warning'
    }
    It 'keys a finding without its line number, so it is the same finding when lines move' {
        Get-CheckKey 'src\a.js' 'line 3: a { is never closed' | Should Be (Get-CheckKey 'src/a.js' 'line 40: a { is never closed')
        Get-CheckKey 'src/a.js' 'line 3: a { is never closed' | Should Not Be (Get-CheckKey 'src/b.js' 'line 3: a { is never closed')
        $f = ConvertTo-CheckFinding 'src/a.js' 'line 12: TypeScript syntax in a JavaScript file' 'file'
        $f.line | Should Be 12
        $f.level | Should Be 'error'
    }
}

Describe 'Enforcement' {
    It 'maps light, standard (the default) and strict to tries and what goes to Copilot' {
        $l = Get-Enforcement 'light'; $s = Get-Enforcement ''; $x = Get-Enforcement 'Strict'
        $s.level | Should Be 'standard'
        "$($l.errorTries),$($s.errorTries),$($x.errorTries)" | Should Be '1,2,3'
        "$($l.sendWarnings),$($s.sendWarnings),$($x.sendWarnings)" | Should Be 'False,True,True'
        "$($l.warningsBlock),$($s.warningsBlock),$($x.warningsBlock)" | Should Be 'False,False,True'
        "$($l.testTries),$($s.testTries),$($x.testTries)" | Should Be '0,2,3'
    }
}

Describe 'What Copilot is told' {
    It 'puts what breaks a file first, then likely mistakes, and says how to dispute' {
        $f = @((ConvertTo-CheckFinding 'a.js' 'line 2: // is not a comment in CSS' 'file'), (ConvertTo-CheckFinding 'a.js' 'line 3: a { is never closed' 'file'))
        $t = Format-CheckResults $f
        $t | Should Match '(?s)These break the file.*never closed.*Likely mistakes.*not a comment'
        $t | Should Match 'ACTION dispute PATH'
    }
    It 'reads a dispute from a reply' {
        $a = @(Get-ActionBlocks ("Done.`n" + '```text' + "`nACTION dispute src/a.css`nline 2: // is not a comment in CSS`nThis file is SCSS compiled by the build.`n" + '```'))
        $a[0].type | Should Be 'dispute'
        $a[0].arg | Should Be 'src/a.css'
        $a[0].body | Should Match 'is not a comment in CSS'
    }
}

Describe 'Disputes and ignores' {
    It 'keeps a log of false alarms, and an ignored finding stays ignored (also in Issues)' {
        $p = Join-Path $env:TEMP ('ccb-policy-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        try {
            Add-CheckDispute $p 'src/a.css' 'line 2: // is not a comment in CSS' 'SCSS compiled by the build' 'copilot'
            Add-CheckDispute $p 'src/a.js' 'line 3: x' 'ignored in the chat' 'user' 'let x = 1;'
            $log = @(Read-CheckDisputes $p)
            $log.Count | Should Be 2
            $log[0].by | Should Be 'copilot'
            $log[1].line | Should Be 'let x = 1;'
            Test-CheckIgnored $p 'src/a.js' 'line 3: a { is never closed' 'function f() {' | Should Be $false
            Set-IgnoredCheck $p 'src/a.js' 'error' 'line 3: a { is never closed' 'function f() {'
            Test-CheckIgnored $p 'src/a.js' 'line 30: a { is never closed' 'function f() {' | Should Be $true   # moved: still the same
            Test-CheckIgnored $p 'src/a.js' 'line 3: a { is never closed' 'function g() {' | Should Be $false  # another line: not ignored
            @(Get-IgnoredFindings $p | Where-Object { $_.category -eq 'error' }).Count | Should Be 1        # Code health uses the same list
            Set-IgnoredCheck $p 'src/a.js' 'error' 'line 3: a { is never closed' 'function f() {' -Undo
            Test-CheckIgnored $p 'src/a.js' 'line 3: a { is never closed' 'function f() {' | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item -LiteralPath $env:CCBRIDGE_ISSUE_INDEX -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_ISSUE_INDEX = $null
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
