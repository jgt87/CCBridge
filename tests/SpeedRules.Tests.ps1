# Pester 3.4 syntax. No test file reads the clock itself, so a speed limit in seconds or milliseconds
# cannot come back (shared rule, 2026-11-15): a CI runner or a busy PC can be many times slower on
# one run. A speed test compares scaling with tests/Scaling.ps1 (Measure-Growth), which may read the
# clock. Covers the Pester tests and the UI's vitest files; comment lines are not read.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

# Files allowed to read the clock, each with its reason.
$allowed = @{
    # Checks how long a time-out waits (behaviour: it waits past the reply limit while Copilot works,
    # and stops at it otherwise), with seconds of margin; not a speed limit.
    'tests/BusyCopilot.Tests.ps1' = $true
    # Checks that a cancelled 30 s command stops at once (under 8 s): behaviour with 22 s of margin.
    'tests/Actions.Tests.ps1'     = $true
    'tests/SpeedRules.Tests.ps1'  = $true
}
# A deadline for waiting ((Get-Date) -lt $deadline) is fine: it measures nothing.
$psClock = '\[Diagnostics\.Stopwatch\]|\.Elapsed\b|New-TimeSpan|\(Get-Date\)\s*-\s*\$'
$jsClock = 'performance\.now\(|Date\.now\(\)\s*-'

function Find-ClockReads {
    <# Lines of $Text (comment lines left out) that read the clock, as "LINE: text". #>
    param([string]$Text, [string]$Pattern, [string]$Comment)
    $lines = $Text -split "`n"
    $hits = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i].Trim()
        if ($l.StartsWith($Comment)) { continue }
        if ($l -match $Pattern) { $hits.Add(('{0}: {1}' -f ($i + 1), $l)) }
    }
    return $hits.ToArray()
}

$testFiles = @()
$testFiles += @(Get-ChildItem -LiteralPath $here -Filter '*.Tests.ps1' -File | ForEach-Object { @{ file = $_; pattern = $psClock; comment = '#' } })
$uiSrc = Join-Path $root 'ui-src\src'
if (Test-Path -LiteralPath $uiSrc) {
    $testFiles += @(Get-ChildItem -LiteralPath $uiSrc -Recurse -File | Where-Object { $_.Name -match '\.test\.tsx?$' } | ForEach-Object { @{ file = $_; pattern = $jsClock; comment = '//' } })
}

Describe 'Speed tests compare scaling, never the clock' {
    It 'finds test files of both kinds (an empty run is not a pass)' {
        @($testFiles | Where-Object { $_.comment -eq '#' }).Count -gt 50 | Should Be $true
        @($testFiles | Where-Object { $_.comment -eq '//' }).Count -gt 5 | Should Be $true
    }
    It 'catches a clock read and skips a comment (the check itself works)' {
        @(Find-ClockReads "`$w = [Diagnostics.Stopwatch]::StartNew()`n# [Diagnostics.Stopwatch] in a comment" $psClock '#').Count | Should Be 1
        @(Find-ClockReads "`$s = ((Get-Date) - `$start).TotalSeconds`nwhile ((Get-Date) -lt `$deadline) { }" $psClock '#').Count | Should Be 1
        @(Find-ClockReads "const t = performance.now();`n// performance.now() in a comment" $jsClock '//').Count | Should Be 1
        @(Find-ClockReads "vi.useFakeTimers({ now: Date.now() + 60000 });" $jsClock '//').Count | Should Be 0
    }
    It 'no test file reads the clock (use tests/Scaling.ps1 for speed)' {
        $bad = @()
        foreach ($t in $testFiles) {
            $rel = $t.file.FullName.Substring($root.Length + 1).Replace('\', '/')
            if ($allowed.ContainsKey($rel)) { continue }
            foreach ($h in @(Find-ClockReads ([IO.File]::ReadAllText($t.file.FullName)) $t.pattern $t.comment)) { $bad += "${rel}:$h" }
        }
        ($bad -join "`n") | Should Be ''
    }
}
