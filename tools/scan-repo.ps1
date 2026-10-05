<#
.SYNOPSIS
    Runs StreamHub's own file checks over this repository: every check must stay at 0 reports, so a
    rule that would flag correct code is caught before a release (build-release.ps1 runs it).
.DESCRIPTION
    Test-FileContent (all fixed rules, including the generated-code checks) and, when installed,
    the tools' syntax checks (node --check, python -m py_compile) on every code file, skipping
    build output, the built ui/, dist/, temp/ and recorded fixtures. Exit code 1 when anything is reported.
#>
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
$reports = New-Object System.Collections.Generic.List[string]
$files = 0
foreach ($f in Get-ProjectFiles $root) {
    if ($f.path -match '^(ui/|dist/|temp/|ui-src/node_modules/|tests/fixtures/)' -or [int64]$f.size -gt 600KB) { continue }
    $full = Join-Path $root $f.path.Replace('/', '\')
    $text = [IO.File]::ReadAllText($full).Replace("`r`n", "`n")
    $files++
    foreach ($i in @(Test-FileContent $f.path $text)) { $reports.Add("$($f.path): $i") }
    foreach ($i in @(Test-ToolSyntax $f.path $text)) { $reports.Add("$($f.path): $i") }
}
if (-not $Quiet) { $reports | ForEach-Object { Write-Host $_ -ForegroundColor Yellow } }
Write-Host "Repository scan: $files file(s), $($reports.Count) report(s)."
if ($reports.Count) { exit 1 }
