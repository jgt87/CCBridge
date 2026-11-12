# A scriptblock made with .GetNewClosure() inside a module runs in a new dynamic module that cannot see
# the commands that module imported (Agent.psm1 imports WorkStatus, Cdp...). Where only Agent.psm1 is
# imported - the MCP worker - such a call fails with "The term 'Set-WorkSign' is not recognized".
# Rule: inside a closure, call only built-in commands, commands the same module exports, or a command
# object taken before the closure was made (& $cmd).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Get-ClosureCommandProblem {
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $exported = @()
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember' }, $true)) {
        $exported += @($c.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
    }
    $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $closures = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and "$($n.Member)" -eq 'GetNewClosure' -and $n.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
    foreach ($cl in $closures) {
        foreach ($cmd in $cl.Expression.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $cmd.GetCommandName()
            if (-not $name) { continue }   # & $cmd, & { }
            if ($exported -contains $name) { continue }
            $info = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($info -and $info.CommandType -eq 'Alias') { $info = $info.ResolvedCommand }
            # built in = a cmdlet that ships with Windows PowerShell (Microsoft.PowerShell.*, CimCmdlets...)
            $builtIn = $info -and $info.CommandType -eq 'Cmdlet' -and (-not $info.Module -or "$($info.Module.ModuleBase)" -like "$PSHOME*" -or "$($info.ModuleName)" -like 'Microsoft.PowerShell.*' -or "$($info.ModuleName)" -in 'CimCmdlets', 'Microsoft.WSMan.Management', 'PSDiagnostics')
            if ($builtIn -and $defined -notcontains $name) { continue }
            '{0}:{1} {2}' -f (Split-Path $Path -Leaf), $cmd.Extent.StartLineNumber, $name
        }
    }
}

Describe 'Closures made with GetNewClosure' {
    It 'call no command the closure cannot see, in any lib module' {
        $problems = @(Get-ChildItem (Join-Path $root 'lib') -Filter *.psm1 | ForEach-Object { Get-ClosureCommandProblem $_.FullName })
        ($problems -join '; ') | Should Be ''
    }

    It 'finds an imported command called inside a closure' {
        $tmp = Join-Path $env:TEMP ('ccb-closure-' + [guid]::NewGuid().ToString('N') + '.psm1')
        [IO.File]::WriteAllText($tmp, "Import-Module .\WorkStatus.psm1`nfunction Send-X(`$State) { `$p = { Set-WorkSign `$State -Data; Write-Output 1 }.GetNewClosure(); `$p }`nExport-ModuleMember -Function Send-X`n")
        try { @(Get-ClosureCommandProblem $tmp) | Should Be @(((Split-Path $tmp -Leaf) + ':2 Set-WorkSign')) }
        finally { Remove-Item -LiteralPath $tmp -Force }
    }

    It 'accepts a command object taken before the closure' {
        $tmp = Join-Path $env:TEMP ('ccb-closure-' + [guid]::NewGuid().ToString('N') + '.psm1')
        [IO.File]::WriteAllText($tmp, "function Send-X(`$State) { `$c = Get-Command Set-WorkSign; `$p = { & `$c `$State -Data }.GetNewClosure(); `$p }`n")
        try { @(Get-ClosureCommandProblem $tmp).Count | Should Be 0 }
        finally { Remove-Item -LiteralPath $tmp -Force }
    }
}
