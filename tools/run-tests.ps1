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
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-tests.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-tests.ps1 -Workers 1
#>
param(
    [string]$Path,
    [int]$Workers = 0,
    # Worker mode (used by this script itself): run these files, write the results to -ResultFile.
    [string[]]$Files,
    [string]$ResultFile
)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')

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
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Pester -Script $f -PassThru -Quiet
        $sw.Stop()
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
    [IO.File]::WriteAllLines($listFile, $List)
    $cmd = "& '$self' -Files (Get-Content -LiteralPath '$listFile') -ResultFile '$result'"
    $p = Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $tmp "$Name.out.txt") -RedirectStandardError (Join-Path $tmp "$Name.err.txt")
    @{ name = $Name; process = $p; result = $result; files = $List }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$runs = @(for ($i = 0; $i -lt $buckets.Count; $i++) { if ($buckets[$i].files.Count) { & $start $buckets[$i].files.ToArray() "worker$i" } })
Write-Host "tests: $($parallel.Count) files in $($runs.Count) parallel processes, then $($alone.Count) on their own"
foreach ($r in $runs) { $r.process.WaitForExit() }
if ($alone.Count) { $a = & $start $alone 'alone'; $a.process.WaitForExit(); $runs += $a }
$sw.Stop()

$passed = 0; $failed = 0; $failures = New-Object System.Collections.Generic.List[string]
foreach ($r in $runs) {
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
