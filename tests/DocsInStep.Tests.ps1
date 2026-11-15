# Pester 3.4 syntax. Docs in step with the scripts a person runs: every parameter of a script in the
# root, tools/, mcp/ and test-tools/, and every .cmd launcher (root and test-tools/), is named in
# README.md, AGENTS.md, CLAUDE.md or docs/architecture.md ("Script parameters").
# Why (shared rule, 2026-11-15): "update the README and the agent doc in the same turn" existed, and
# nothing checked it; the first run here found 36 parameters and one launcher no doc named.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

$scriptDirs = @($root, (Join-Path $root 'tools'), (Join-Path $root 'mcp'), (Join-Path $root 'test-tools'))
$entryScripts = @(foreach ($d in $scriptDirs) { Get-ChildItem -LiteralPath $d -Filter '*.ps1' -File | Where-Object { $_.Name -notlike '*.Tests.ps1' } })
$launchers = @(foreach ($d in @($root, (Join-Path $root 'test-tools'))) { Get-ChildItem -LiteralPath $d -Filter '*.cmd' -File })
$docs = ''
foreach ($name in 'README.md', 'AGENTS.md', 'CLAUDE.md', 'docs\architecture.md') {
    $p = Join-Path $root $name
    if (Test-Path -LiteralPath $p) { $docs += "`n" + [IO.File]::ReadAllText($p) }
}

function Get-ScriptParameterNames {
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (-not $ast.ParamBlock) { return @() }
    return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

Describe 'Docs in step with the scripts people run' {
    It 'finds something to check (an empty run is not a pass)' {
        ($entryScripts.Count -gt 10) | Should Be $true
        ($launchers.Count -gt 5) | Should Be $true
        ($docs.Length -gt 0) | Should Be $true
    }
    foreach ($script in $entryScripts) {
        $rel = $script.FullName.Substring($root.Length + 1).Replace('\', '/')
        foreach ($name in (Get-ScriptParameterNames -Path $script.FullName)) {
            It "names -$name of $rel in the docs" {
                ($docs -match ('(?i)-' + [regex]::Escape($name) + '\b')) | Should Be $true
            }
        }
    }
    foreach ($cmd in $launchers) {
        It "names the launcher '$($cmd.Name)' in the docs" {
            $docs.Contains($cmd.Name) | Should Be $true
        }
    }
    It 'reads parameter names from a script (the check itself works)' {
        $tmp = Join-Path $env:TEMP ('docs-in-step-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            [IO.File]::WriteAllText($tmp, 'param([string]$Name, [switch]$DryRun)')
            (Get-ScriptParameterNames -Path $tmp) -join ',' | Should Be 'Name,DryRun'
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}
