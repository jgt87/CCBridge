# How the round's file-check findings are handled, so a wrong rule cannot break good code or hold a
# task hostage: each finding has a level (error: it breaks the file, and "done" waits for it;
# warning: a likely mistake, said once and never blocking), a key without line numbers, and can be
# disputed by Copilot (left out for the rest of the task) or ignored by the user (left out for good,
# the same list as Code health > Issues). Disputes and ignores are kept in
# .streamhub/check-disputes.json: false alarms to turn into test samples.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

# Findings that are likely mistakes rather than a broken file (matched on the message text).
$script:WarningPatterns = @(
    'only work from Python 3\.12', 'PowerShell 7 only', 'is not a comment in CSS', 'SCSS syntax', 'needs setlocal enabledelayedexpansion',
    'is not a command on this computer', 'duplicate (function|block|code)', 'appears twice', 'is defined twice',
    'mixes CRLF and LF', 'overwrites the parameter', 'is an automatic variable', 'holds double quotes', 'stops the script here', 'arrives as one object', 'the comma binds first'
)

function Get-Enforcement {
    <# What the setting enforcement (light, standard, strict) means for the checks: how often an
       error may hold up "done", whether likely mistakes go to Copilot and may hold it up (once), and
       how often failing tests and beforeDone hooks go back (0 = shown in the chat only), and whether
       mechanical problems are fixed by the helper (AutoFix.psm1): silent, tell (Copilot is told) or
       off (left to Copilot). #>
    param([string]$Level)
    switch ("$Level".ToLowerInvariant()) {
        'light' { [pscustomobject]@{ level = 'light'; errorTries = 1; sendWarnings = $false; warningsBlock = $false; testTries = 0; hookTries = 0; autoFix = 'silent' } }
        'strict' { [pscustomobject]@{ level = 'strict'; errorTries = 3; sendWarnings = $true; warningsBlock = $true; testTries = 3; hookTries = 3; autoFix = 'off' } }
        default { [pscustomobject]@{ level = 'standard'; errorTries = 2; sendWarnings = $true; warningsBlock = $false; testTries = 2; hookTries = 2; autoFix = 'tell' } }
    }
}

function Get-CheckLevel {
    <# 'error' (breaks the file: "done" waits until it is fixed) or 'warning' (a likely mistake: said
       once, never blocking). $Source: file (the file checks), tool (node/python), script (Edge),
       imports, hook: errors unless the message is a known likely mistake; smell, quality, env:
       warnings. #>
    param([string]$Text, [string]$Source = 'file')
    if ($Source -in 'smell', 'quality', 'env') { return 'warning' }
    foreach ($p in $script:WarningPatterns) { if ($Text -match $p) { return 'warning' } }
    'error'
}

function Get-CheckKey([string]$Path, [string]$Text) {
    # The same finding however its line moves: the file, and the message without "line N:" and numbers.
    $msg = ("$Text" -replace '^\s*line \d+:\s*', '' -replace '\d+', '#').Trim()
    "$("$Path".Replace('\', '/').ToLowerInvariant())|$msg"
}

function ConvertTo-CheckFinding {
    <# One finding of the round as an object: path, line, text (the message), level, key, source. #>
    param([string]$Path, [string]$Text, [string]$Source = 'file')
    $line = if ($Text -match '^\s*line (\d+):') { [int]$Matches[1] } else { 0 }
    [pscustomobject]@{ path = "$Path".Replace('\', '/'); line = $line; text = $Text; level = (Get-CheckLevel $Text $Source); key = (Get-CheckKey $Path $Text); source = $Source }
}

function Get-CheckDisputesPath([string]$ProjectRoot) { Join-Path $ProjectRoot '.streamhub\check-disputes.json' }

function Read-CheckDisputes([string]$ProjectRoot) {
    $f = Get-CheckDisputesPath $ProjectRoot
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    # In parentheses: Windows PowerShell 5.1 hands over a JSON array as one object.
    try { @(([IO.File]::ReadAllText($f) | ConvertFrom-Json)) } catch { @() }
}

function Add-CheckDispute {
    <# Records a finding someone said is wrong: by copilot (a dispute) or user (Ignore in the chat),
       with the reason and the code line, for review and new test samples. Keeps the newest 500. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Path, [string]$Finding, [string]$Reason, [ValidateSet('copilot', 'user')][string]$By = 'copilot', [string]$LineText = '')
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Read-CheckDisputes $ProjectRoot)) { $list.Add($d) }
    $list.Add([pscustomobject]@{ at = (Get-Date).ToString('s'); by = $By; path = "$Path".Replace('\', '/'); finding = "$Finding"; reason = "$Reason".Trim(); line = "$LineText".Trim() })
    $keep = @($list | Select-Object -Last 500)
    $f = Get-CheckDisputesPath $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $f)
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @($keep) -Depth 4), (New-Object Text.UTF8Encoding($false)))
}

function Format-CheckResults {
    <# The round's findings for Copilot: what breaks the file first (fix these; "done" waits for
       them), then likely mistakes (fix when real), and how to dispute a wrong one. #>
    param($Findings)
    $errors = @($Findings | Where-Object level -eq 'error')
    $warnings = @($Findings | Where-Object level -eq 'warning')
    $sb = New-Object Text.StringBuilder
    if ($errors.Count) {
        [void]$sb.AppendLine('These break the file; fix them first (done waits for them):')
        foreach ($f in @($errors | Select-Object -First 15)) { [void]$sb.AppendLine("- $($f.path): $($f.text)") }
    }
    if ($warnings.Count) {
        [void]$sb.AppendLine('Likely mistakes; fix them when they are real:')
        foreach ($f in @($warnings | Select-Object -First 10)) { [void]$sb.AppendLine("- $($f.path): $($f.text)") }
    }
    [void]$sb.Append('If a finding is wrong (the code is right as it is), do not change the code for it: send ACTION dispute PATH with the finding on the next line and why it is wrong, and it is left out.')
    $sb.ToString()
}

Export-ModuleMember -Function Get-Enforcement, Get-CheckLevel, Get-CheckKey, ConvertTo-CheckFinding, Get-CheckDisputesPath, Read-CheckDisputes, Add-CheckDispute, Format-CheckResults
