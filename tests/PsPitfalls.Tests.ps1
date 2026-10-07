# Windows PowerShell 5.1 traps in code Copilot writes (Lint Find-LanguagePitfalls): each passes the
# syntax check but goes wrong at run time. A broken sample and a correct one per trap; all warnings.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Lint', 'CheckPolicy') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

function Get-Pitfalls([string]$Text) { @(Find-LanguagePitfalls 'Scripts/tool.ps1' $Text) -join "`n" }

Describe 'PowerShell 5.1 traps' {
    It 'a loop variable that overwrites a parameter differing only in case' {
        $bad = "function Copy-Items([string]`$To, [string[]]`$Items) {`n    foreach (`$to in `$Items) { Write-Output `$to }`n    `$To`n}"
        Get-Pitfalls $bad | Should Match 'line 2: the loop variable \$to overwrites the parameter \$To'
        Get-Pitfalls ($bad -replace '\$to in', '$item in' -replace 'Write-Output \$to', 'Write-Output $item') | Should Not Match 'overwrites'
    }
    It '$Matches after a -match whose result is not checked' {
        Get-Pitfalls "`$line -match 'id=(\d+)'`n`$id = `$Matches[1]" | Should Match "line 2: \`$Matches after the -match on line 1, whose result is not checked"
        Get-Pitfalls "switch -Regex (`$lines) {`n    '^a' { `$null = `$_ -match 'b(\d)'; `$n = `$Matches[1] }`n}" | Should Match 'whose result is not checked'
        Get-Pitfalls "if (`$line -match 'id=(\d+)') { `$id = `$Matches[1] }" | Should Not Match 'not checked'
        Get-Pitfalls "`$has = `$v -match '(\d+)'`n`$x = if (`$has) { `$Matches[1] }" | Should Not Match 'not checked'
        Get-Pitfalls "switch -Regex (`$lines) {`n    '^a(\d)' { `$n = `$Matches[1]; if (`$_ -match 'b(\d)') { `$m = `$Matches[1] } }`n}" | Should Not Match 'not checked'
    }
    It 'a function returning , $list called inside @()' {
        $bad = "function Get-Names { `$l = New-Object Collections.Generic.List[string]; `$l.Add('a'); return , `$l.ToArray() }`n`$all = @(Get-Names)"
        Get-Pitfalls $bad | Should Match 'line 2: Get-Names returns its list with a leading comma .* a list inside a list'
        Get-Pitfalls ($bad -replace 'return , ', 'return ') | Should Not Match 'list inside a list'
        Get-Pitfalls ($bad -replace '@\(Get-Names\)', 'Get-Names') | Should Not Match 'list inside a list'
    }
    It '.Count on what may be one [pscustomobject]' {
        $bad = "`$rows = Import-Csv data.csv | Where-Object { `$_.Amount -gt 0 }`nif (`$rows.Count -gt 0) { 'some' }"
        Get-Pitfalls $bad | Should Match 'line 2: \$rows\.Count is empty in Windows PowerShell 5\.1 when line 1 gives one object'
        Get-Pitfalls "`$rows = @(Import-Csv data.csv | Where-Object { `$_.Amount -gt 0 })`nif (`$rows.Count -gt 0) { 'some' }" | Should Not Match 'is empty'
        Get-Pitfalls "`$files = Get-ChildItem . | Where-Object Length`n`$files.Count" | Should Not Match 'is empty'
        Get-Pitfalls "`$top = Get-Process | Select-Object -First 3`n`$top.Count" | Should Not Match 'is empty'
    }
    It 'a function named like a built-in cmdlet' {
        Get-Pitfalls "function Get-Content([string]`$P) { 'x' }" | Should Match 'the function Get-Content has the same name as the built-in cmdlet'
        Get-Pitfalls "function Get-ReportContent([string]`$P) { 'x' }" | Should Not Match 'built-in'
    }
    It 'names every parameter of the function in the overwrite message' {
        $bad = "function Copy-Items([string]`$To, [string[]]`$Items) {`n    foreach (`$to in `$Items) { Write-Output `$to }`n}"
        Get-Pitfalls $bad | Should Match 'use another name, not one of the parameters of Copy-Items: \$To, \$Items'
    }
    It 'reports them as likely mistakes, not errors' {
        foreach ($t in 'line 2: the loop variable $to overwrites the parameter $To (variable names ignore case): use another name',
            'line 2: $Matches after the -match on line 1, whose result is not checked: when it does not match',
            'line 2: F returns its list with a leading comma (one item), so @(F ...) here gives a list inside a list',
            'line 2: $rows.Count is empty in Windows PowerShell 5.1 when line 1 gives one object',
            'line 1: the function Get-Content has the same name as the built-in cmdlet and replaces it') { Get-CheckLevel $t | Should Be 'warning' }
    }
}

# Prevention: a part of a script shown to Copilot names the parameters of the function it is in
# (Executor Get-PsScopeNote), in ranged reads and in the view after an edit.
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Describe 'Parameters named with a part of a script' {
    $script = @(
        'param([string]$Path)'
        ''
        'function Copy-Items {'
        '    param([string]$To, [string[]]$Items, [switch]$Inner)'
        '    foreach ($item in $Items) {'
        '        Write-Output $item'
        '    }'
        '}'
    ) -join "`n"
    It 'names the function, its parameters and the script parameters when the header is not shown' {
        $n = Get-PsScopeNote $script 'Scripts/copy.ps1' 5 7
        $n | Should Match '^\(Lines 5-7 are inside function Copy-Items \(line 3\): parameters \$To, \$Items, \[switch\]\$Inner\. Script parameters: \$Path\. Variable names ignore case'
        Get-PsScopeNote $script 'Scripts/copy.ps1' 3 8 | Should Match '^\(Script parameters: \$Path\.'
        Get-PsScopeNote $script 'app.js' 5 7 | Should Be ''
        Get-PsScopeNote "function A { 'x' }`n`n" 'a.ps1' 3 3 | Should Be ''
    }
    It 'goes with a ranged read and with the view after an edit' {
        $p = Join-Path $env:TEMP ('ccb-scope-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p 'Scripts') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'Scripts\copy.ps1'), $script)
        (@(Invoke-ReadAction $p 'Scripts/copy.ps1:6-6') -join "`n") | Should Match 'inside function Copy-Items \(line 3\): parameters \$To'
        $new = $script.Replace('        Write-Output $item', '        Write-Output "copy $item"')
        Get-ChangedView $script $new 'Scripts/copy.ps1' 'Scripts/copy.ps1' | Should Match 'inside function Copy-Items'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}
