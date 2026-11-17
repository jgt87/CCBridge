<#
.SYNOPSIS
    Runs the whole Pester suite the way it has to run: in Windows PowerShell 5.1 with its own module
    paths (PowerShell 7's paths make some tests fail falsely). Exit code 1 when a test fails.
    Used by build-release.ps1 as the release gate.
.DESCRIPTION
    The test files run in parallel Windows PowerShell processes (-Workers, default: the number of
    processors, at most 8), each taking a share of the files balanced by how long each file took the
    last time (kept in %TEMP%\CCBridge-test-timings.json; file size the first time). Files that use
    something machine-wide (a window on the screen, the Copilot lock, the real last-project file) run
    after that in one process of their own. -Workers 1 runs everything in one process, as before.
    A file that runs longer than -FileTimeoutSec (default 300; not with -Workers 1) is stopped with its worker: the run
    fails and names it, and the files that worker had not reached yet. On GitHub Actions each file
    is printed as it finishes, so a run's log shows how far it got.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-tests.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-tests.ps1 -Workers 1
#>
param(
    [string]$Path,
    [int]$Workers = 0,
    # Worker mode (used by this script itself): run these files, write the results to -ResultFile.
    [string[]]$Files,
    [string]$ResultFile,
    # Worker mode: a line per file started and finished, which the main process watches.
    [string]$ProgressFile,
    [int]$FileTimeoutSec = 300
)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
# TEMP in its long form: GitHub's Windows runners give an 8.3 short path (a user folder named RUNNER~1), the
# tests make their projects under it, and paths the code reads back from the disk come in the long
# form, so 171 tests failed there and one hung (2026-11-16). The workers inherit the long form.
foreach ($v in 'TEMP', 'TMP') {
    $t = [Environment]::GetEnvironmentVariable($v)
    if ($t -and (Test-Path -LiteralPath $t)) { [Environment]::SetEnvironmentVariable($v, [IO.Path]::GetFullPath($t).TrimEnd('\')) }
}
# The tests are written for Pester 3.4, the version Windows ships. A newer Pester beside it (GitHub's
# Windows runners have one) would load first and does not read `Should Be`. Each worker runs this too.
try { Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop } catch { Write-Warning "Pester 3.4.0 is not installed: the tests run with the newest Pester found." }

# Test files that use something machine-wide, so they never run next to each other or the rest.
$script:Alone = @(
    'CopilotLock.Tests.ps1'   # holds the machine-wide Copilot send lock and its holder file
    'WindowApps.Tests.ps1'    # opens real windows and closes message boxes on the screen
    'McpServer.Tests.ps1'     # starts the MCP server, which looks for a running app
    'DataMirror.Tests.ps1'    # saves and puts back the real last-project.txt
)

if ($Files) {
    # Worker: one Invoke-Pester per file, so each file's time is known for the next balancing.
    $out = foreach ($f in $Files) {
        if ($ProgressFile) { [IO.File]::AppendAllText($ProgressFile, "start`t$f`t$([DateTime]::UtcNow.Ticks)`r`n") }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Pester -Script $f -PassThru -Quiet
        $sw.Stop()
        if ($ProgressFile) { [IO.File]::AppendAllText($ProgressFile, "done`t$f`t$([math]::Round($sw.Elapsed.TotalSeconds, 1))`r`n") }
        @{ file = (Split-Path -Leaf $f); passed = $r.PassedCount; failed = $r.FailedCount; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
           failures = @($r.TestResult | Where-Object { -not $_.Passed } | ForEach-Object { @{ name = "$($_.Describe) / $($_.Name)"; message = "$($_.FailureMessage)" } }) }
    }
    [IO.File]::WriteAllText($ResultFile, (ConvertTo-Json -InputObject @($out) -Depth 5), (New-Object Text.UTF8Encoding($false)))
    exit 0
}

if (-not $Path) { $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests' }
if ($Workers -lt 1) { $Workers = [math]::Min(8, [Environment]::ProcessorCount) }

if ($Workers -eq 1) {
    $r = Invoke-Pester $Path -PassThru -Quiet
    Write-Host "tests: $($r.PassedCount) passed, $($r.FailedCount) failed"
    if ($r.FailedCount) {
        $r.TestResult | Where-Object { -not $_.Passed } | ForEach-Object { Write-Host "  FAILED: $($_.Describe) / $($_.Name)" -ForegroundColor Red }
        exit 1
    }
    exit 0
}

$all = @(Get-ChildItem -LiteralPath $Path -Filter '*.Tests.ps1' -Recurse | Sort-Object FullName)
$timingFile = Join-Path ([IO.Path]::GetTempPath()) 'CCBridge-test-timings.json'
$timings = @{}
if (Test-Path -LiteralPath $timingFile) {
    try { (Get-Content -LiteralPath $timingFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $timings[$_.Name] = [double]$_.Value } } catch { }
}
# The expected time of a file: its last run, else about one second per 4 KB of test code.
$cost = { param($f) if ($timings.ContainsKey($f.Name)) { $timings[$f.Name] } else { [math]::Max(1, $f.Length / 4096) } }

# Longest first onto the least loaded worker.
$parallel = @($all | Where-Object { $script:Alone -notcontains $_.Name } | Sort-Object { & $cost $_ } -Descending)
$buckets = @(for ($i = 0; $i -lt $Workers; $i++) { @{ files = New-Object System.Collections.Generic.List[string]; load = 0.0 } })
foreach ($f in $parallel) {
    $b = $buckets | Sort-Object { $_.load } | Select-Object -First 1
    $b.files.Add($f.FullName); $b.load += (& $cost $f)
}
$alone = @($all | Where-Object { $script:Alone -contains $_.Name } | ForEach-Object { $_.FullName })

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ccb-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $tmp
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$self = $MyInvocation.MyCommand.Path
$start = {
    param([string[]]$List, [string]$Name)
    $result = Join-Path $tmp "$Name.json"
    $listFile = Join-Path $tmp "$Name.files.txt"
    $progress = Join-Path $tmp "$Name.progress.txt"
    [IO.File]::WriteAllLines($listFile, $List)
    $cmd = "& '$self' -Files (Get-Content -LiteralPath '$listFile') -ResultFile '$result' -ProgressFile '$progress'"
    $p = Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $tmp "$Name.out.txt") -RedirectStandardError (Join-Path $tmp "$Name.err.txt")
    @{ name = $Name; process = $p; result = $result; files = $List; progress = $progress; shown = 0; timedOut = $null }
}

# Waits for the workers, watching their progress files: prints each finished file on GitHub Actions,
# and stops a worker (with the processes it started) whose current file runs past -FileTimeoutSec.
$onCi = [bool]$env:GITHUB_ACTIONS
$watch = {
    param([object[]]$List)
    while (@($List | Where-Object { -not $_.process.HasExited }).Count) {
        foreach ($r in $List) {
            if (-not (Test-Path -LiteralPath $r.progress)) { continue }
            $lines = @(try { [IO.File]::ReadAllLines($r.progress) } catch { @() })
            for ($k = $r.shown; $k -lt $lines.Count; $k++) {
                $p = $lines[$k] -split "`t"
                if ($onCi -and $p[0] -eq 'done') { Write-Host ("  {0} ({1} s, {2})" -f (Split-Path -Leaf $p[1]), $p[2], $r.name) }
            }
            $r.shown = $lines.Count
            if ($r.process.HasExited -or -not $lines.Count) { continue }
            $last = $lines[$lines.Count - 1] -split "`t"
            if ($last[0] -ne 'start') { continue }
            $secs = ([DateTime]::UtcNow - [DateTime]::new([long]$last[2], [DateTimeKind]::Utc)).TotalSeconds
            if ($secs -gt $FileTimeoutSec) {
                $r.timedOut = $last[1]
                Write-Host "  $(Split-Path -Leaf $last[1]) has run for $([math]::Round($secs)) s: stopping $($r.name)" -ForegroundColor Red
                $null = cmd /c "taskkill /PID $($r.process.Id) /T /F >nul 2>&1"
            }
        }
        Start-Sleep -Milliseconds 1000
    }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$runs = @(for ($i = 0; $i -lt $buckets.Count; $i++) { if ($buckets[$i].files.Count) { & $start $buckets[$i].files.ToArray() "worker$i" } })
Write-Host "tests: $($parallel.Count) files in $($runs.Count) parallel processes, then $($alone.Count) on their own"
& $watch $runs
if ($alone.Count) { $a = & $start $alone 'alone'; & $watch @($a); $runs += $a }
$sw.Stop()

$passed = 0; $failed = 0; $failures = New-Object System.Collections.Generic.List[string]
foreach ($r in $runs) {
    if ($r.timedOut) {
        # Stopped on the time limit: name the file, and the files of that worker that never ran.
        $failed++
        $at = [array]::IndexOf([string[]]$r.files, [string]$r.timedOut)
        $notRun = @(if ($at -ge 0) { $r.files | Select-Object -Skip ($at + 1) | ForEach-Object { Split-Path -Leaf $_ } })
        $failures.Add("$(Split-Path -Leaf $r.timedOut) did not finish within $FileTimeoutSec s, so $($r.name) was stopped$(if ($notRun.Count) { "; not run: $($notRun -join ', ')" })")
        continue
    }
    if (-not (Test-Path -LiteralPath $r.result)) {
        # The process ended without its results (it crashed): every file it had counts as failed.
        $failed++
        $err = if (Test-Path -LiteralPath (Join-Path $tmp "$($r.name).err.txt")) { (Get-Content -LiteralPath (Join-Path $tmp "$($r.name).err.txt") -Raw) } else { '' }
        $failures.Add("$($r.name) stopped without results (files: $((@($r.files) | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')) $err")
        continue
    }
    # ConvertFrom-Json as a command, not in a pipeline: 5.1 passes a JSON array on as one object.
    # (Not $files: that is the [string[]]$Files parameter, and 5.1 names ignore case.)
    $results = ConvertFrom-Json (Get-Content -LiteralPath $r.result -Raw)
    foreach ($f in $results) {
        $passed += [int]$f.passed; $failed += [int]$f.failed
        $timings[$f.file] = [double]$f.seconds
        foreach ($x in @($f.failures)) { if ($x) { $failures.Add("$($f.file): $($x.name)`n      $($x.message)") } }
    }
}
try { [IO.File]::WriteAllText($timingFile, (ConvertTo-Json -InputObject $timings), (New-Object Text.UTF8Encoding($false))) } catch { }
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "tests: $passed passed, $failed failed ($([math]::Round($sw.Elapsed.TotalMinutes, 1)) min)"
if ($failed) {
    foreach ($m in $failures) { Write-Host "  FAILED: $m" -ForegroundColor Red }
    exit 1
}
exit 0
