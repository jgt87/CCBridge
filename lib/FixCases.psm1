# Fix cases: a log file per problem that needed more than one try, whether it got fixed or not, so
# it can be reviewed and StreamHub's rules improved to catch or prevent it. Two kinds:
#   issue fix  - a problem the issue scan found after a change, fixed by fix tasks (attempts 1..3);
#   in a task  - a file-check error still there after Copilot's next change within one task.
# Each case is .streamhub/FixCases/case-<stamp>-<file>.md: the problem, the change and request that
# brought it, every attempt with Copilot's diagnosis and what was still there, the outcome and the
# StreamHub build. The main log gets a line pointing to it; Export diagnostics collects the files.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Config') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:CaseDir = '.streamhub/FixCases'
$script:KeepCases = 200

function Get-FixCaseDir([string]$ProjectRoot) { Join-Path $ProjectRoot $script:CaseDir.Replace('/', '\') }

function Write-FixCase {
    <# Writes one case file and returns its project-relative path. $Case: kind ('issue fix' or
       'in a task'), path, problems (texts), request, change (how the file changed, Format-LineChange
       text), attempts (@{ attempt; how; diagnosis; left }), outcome (text), fixed (bool). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][hashtable]$Case)
    $dir = Get-FixCaseDir $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path $dir
    $leaf = ([IO.Path]::GetFileName("$($Case.path)") -replace '[^A-Za-z0-9._-]+', '-')
    $name = "case-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$leaf.md"
    $build = try { Format-CCBBuild (Get-CCBridgeBuild (Split-Path -Parent $PSScriptRoot)) } catch { 'unknown' }
    $fence = '```'
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("# Fix case: $($Case.path) ($(if ($Case.fixed) { 'fixed' } else { 'not fixed' }))").AppendLine()
    [void]$sb.AppendLine("- When: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
    [void]$sb.AppendLine("- StreamHub: $build")
    [void]$sb.AppendLine("- Kind: $($Case.kind)")
    [void]$sb.AppendLine("- Outcome: $($Case.outcome)")
    [void]$sb.AppendLine("- Tries: $(@($Case.attempts).Count)").AppendLine()
    [void]$sb.AppendLine('## The problem').AppendLine()
    foreach ($p in @($Case.problems)) { [void]$sb.AppendLine("- $p") }
    [void]$sb.AppendLine().AppendLine('## What brought it').AppendLine()
    if ($Case.request) { [void]$sb.AppendLine("Request: $(("$($Case.request)" -replace '\s+', ' ').Trim())").AppendLine() }
    if ($Case.change) { [void]$sb.AppendLine("How $($Case.path) changed (- before, + after):").AppendLine("${fence}diff").AppendLine("$($Case.change)").AppendLine($fence) }
    else { [void]$sb.AppendLine('(the change is no longer kept)') }
    [void]$sb.AppendLine().AppendLine('## Tries').AppendLine()
    foreach ($a in @($Case.attempts)) {
        [void]$sb.AppendLine("### Try $($a.attempt)$(if ($a.how) { ": $($a.how)" })").AppendLine()
        [void]$sb.AppendLine("- Copilot's diagnosis: $(if ($a.diagnosis) { $a.diagnosis } else { '(none given)' })")
        $left = @($a.left | Where-Object { $_ })
        [void]$sb.AppendLine("- Still there after it: $(if ($left.Count) { $left -join '; ' } else { 'nothing (fixed)' })").AppendLine()
    }
    [void]$sb.AppendLine('## For review').AppendLine()
    [void]$sb.AppendLine('Could a check have caught this earlier, or a rule for Copilot have prevented it? Which file type and kind of change was it?')
    [IO.File]::WriteAllText((Join-Path $dir $name), $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    # Keep the newest cases.
    $all = @(Get-ChildItem -LiteralPath $dir -Filter 'case-*.md' -File | Sort-Object Name)
    if ($all.Count -gt $script:KeepCases) { $all | Select-Object -First ($all.Count - $script:KeepCases) | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force } }
    $rel = "$($script:CaseDir)/$name"
    Write-CCBLog info fixcase "Fix case recorded: $rel" @{ path = "$($Case.path)"; kind = "$($Case.kind)"; fixed = [bool]$Case.fixed; tries = @($Case.attempts).Count }
    $rel
}

Export-ModuleMember -Function Write-FixCase, Get-FixCaseDir
