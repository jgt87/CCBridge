<#
.SYNOPSIS
    Runs StreamHub's own file checks over this repository: every check must stay at 0 reports, so a
    rule that would flag correct code is caught before a release (build-release.ps1 runs it).
.DESCRIPTION
    Test-FileContent (all fixed rules, including the generated-code checks) and, when installed,
    the tools' syntax checks (node --check, python -m py_compile) on every code file, skipping
    build output, the built ui/, dist/, temp/, recorded fixtures and third-party builds (templates/ui-kit/vendor/). Exit code 1 when anything is reported.
#>
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
$reports = New-Object System.Collections.Generic.List[string]
$files = 0
foreach ($f in Get-ProjectFiles $root) {
    if ($f.path -match '^(ui/|dist/|temp/|ui-src/node_modules/|tests/fixtures/|templates/ui-kit/vendor/)' -or [int64]$f.size -gt 600KB) { continue }
    $full = Join-Path $root $f.path.Replace('/', '\')
    $text = [IO.File]::ReadAllText($full)
    $files++
    # Shell and batch scripts as they are on disk: CRLF breaks a shell script and LF breaks a batch
    # file's labels, so those checks need the real endings. Other files with LF, as git stores them
    # (core.autocrlf can leave a working copy with both endings that git itself sees as unchanged).
    $checked = if ($f.path -match '(?i)\.(sh|bash|cmd|bat)$') { $text } else { $text.Replace("`r`n", "`n") }
    foreach ($i in @(Test-FileContent $f.path $checked)) { $reports.Add("$($f.path): $i") }
    foreach ($i in @(Test-ToolSyntax $f.path $text.Replace("`r`n", "`n"))) { $reports.Add("$($f.path): $i") }
    # PowerShell files stay ASCII-only (AGENTS.md): a BOM-less file with other characters is read as
    # ANSI by 5.1, so the characters change when the file is read.
    if ($f.path -match '(?i)\.ps[md]?1$') {
        $m = [regex]::Match($text, '[^\x00-\x7F]')
        if ($m.Success) { $reports.Add("$($f.path): line $(([regex]::Matches($text.Substring(0, $m.Index), "`n")).Count + 1): a non-ASCII character (U+$(([int][char]$m.Value).ToString('X4'))) in a PowerShell file: write it as [char]0x.. or a \u escape in a string") }
    }
}
if (-not $Quiet) { $reports | ForEach-Object { Write-Host $_ -ForegroundColor Yellow } }
Write-Host "Repository scan: $files file(s), $($reports.Count) report(s)."
if ($reports.Count) { exit 1 }
