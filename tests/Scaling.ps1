# Speed tests without a clock limit (shared rule, 2026-11-15): time a small and a big input in the
# same run and bound the ratio, never the seconds. A CI runner or a busy PC can be many times slower
# than usual on one run; the ratio stays. For ten times the input, linear work gives about 10,
# n log n about 13, work that compares every item with every other about 100.
# Dot-source it in a test: . (Join-Path $PSScriptRoot 'Scaling.ps1'). This file may read the clock;
# test files may not (tests/SpeedRules.Tests.ps1).

function Measure-CallTime {
    <# Mean seconds of one call of $Script, repeating it until at least $MinSec have passed. #>
    param([Parameter(Mandatory)][scriptblock]$Script, [double]$MinSec = 0.2)
    $n = 0
    $w = [Diagnostics.Stopwatch]::StartNew()
    do { $null = & $Script; $n++ } while ($w.Elapsed.TotalSeconds -lt $MinSec)
    return [double]$w.Elapsed.TotalSeconds / $n
}

function Measure-Growth {
    <# How many times longer $Big takes than $Small: best of $Rounds each, after one warm-up call. #>
    param([Parameter(Mandatory)][scriptblock]$Small, [Parameter(Mandatory)][scriptblock]$Big, [int]$Rounds = 2)
    $null = & $Small
    $bestSmall = [double]::MaxValue; $bestBig = [double]::MaxValue
    for ($r = 0; $r -lt $Rounds; $r++) {
        $bestSmall = [Math]::Min($bestSmall, (Measure-CallTime $Small))
        $bestBig = [Math]::Min($bestBig, (Measure-CallTime $Big -MinSec 0))
    }
    return [double]$bestBig / [Math]::Max($bestSmall, 1e-6)
}
