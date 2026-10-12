# Test runs: a person's own requests, saved once and run again unattended in a fresh project, so a
# new version of the helper program can be compared with the last one on the same work. A test run
# is TestRuns/NAME.testrun.md in the library beside the projects (<projects>\.streamhub\TestRuns):
#   ---
#   title: TITLE
#   answers: audience=me, bigtask=build     (project setup answers, saved before the first step)
#   build: single                            (the build form, optional)
#   files: NAME/data.csv, NAME/notes.md      (copied into the new project's root)
#   source: NAME/export.xlsx                 (copied into the new project's Source/)
#   mode: auto                               (the mode every step runs in; auto by default)
#   ---
#   1. The first request
#      a second line of it
#   2. The next request
# Server starts a run (a new project "NAME run STAMP", its files and setup, one queued task per step
# with source testrun, then a testrun-report task); Agent Invoke-TestRunReport writes the report
# (SessionReport for the run's time span, its numbers next to the last run of the same test).
# ASCII only (Windows PowerShell 5.1).

Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')

function Get-TestRunsDir([string]$ProjectsRoot, [switch]$Create) {
    $d = Join-Path $ProjectsRoot '.streamhub\TestRuns'
    if ($Create -and -not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Force -Path $d }
    $d
}

function Read-TestRun([Parameter(Mandatory)][string]$Path) {
    <# A test run file: @{ name; title; answers (hashtable); build; files; source; mode; steps }. #>
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $name = [IO.Path]::GetFileName($Path) -replace '\.testrun\.md$', ''
    $meta = @{}
    $body = $text
    $m = [regex]::Match($text, '(?s)^---\n(.*?)\n---\n?(.*)$')
    if ($m.Success) {
        foreach ($l in $m.Groups[1].Value.Split("`n")) { $kv = [regex]::Match($l, '^\s*([\w-]+)\s*:\s*(.*?)\s*$'); if ($kv.Success) { $meta[$kv.Groups[1].Value.ToLowerInvariant()] = $kv.Groups[2].Value } }
        $body = $m.Groups[2].Value
    }
    $answers = @{}
    foreach ($p in @("$($meta['answers'])" -split '\s*[,;]\s*' | Where-Object { $_ -match '=' })) { $k, $v = $p -split '\s*=\s*', 2; $answers[$k.Trim()] = $v.Trim() }
    $list = { param($v) @("$v" -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    # Steps: "N. text" lines, with the indented or plain lines below them up to the next number.
    $steps = New-Object System.Collections.Generic.List[string]
    $cur = $null
    foreach ($l in $body.Split("`n")) {
        $s = [regex]::Match($l, '^\s*\d+[.)]\s+(.*)$')
        if ($s.Success) { if ($null -ne $cur) { $steps.Add($cur.Trim()) }; $cur = $s.Groups[1].Value; continue }
        if ($null -ne $cur) { $cur += "`n" + $l.Trim() }
    }
    if ($null -ne $cur -and $cur.Trim()) { $steps.Add($cur.Trim()) }
    [pscustomobject]@{
        name = $name; path = $Path
        title = $(if ($meta['title']) { $meta['title'] } else { $name })
        answers = $answers; build = "$($meta['build'])"
        files = @(& $list $meta['files']); source = @(& $list $meta['source'])
        mode = $(if ($meta['mode'] -in 'auto', 'ask') { $meta['mode'] } else { 'auto' })
        steps = $steps.ToArray()
    }
}

function Get-TestRuns([string]$ProjectsRoot) {
    # The saved test runs: @(@{ name; title; steps; path; lastRun }).
    $d = Get-TestRunsDir $ProjectsRoot
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    @(foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.testrun.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            $t = Read-TestRun $f.FullName
            $h = @(Read-TestRunHistory $ProjectsRoot $t.name)
            [pscustomobject]@{ name = $t.name; title = $t.title; steps = @($t.steps).Count; path = $f.FullName; lastRun = $(if ($h.Count) { $h[-1].when } else { '' }) }
        } catch { }
    })
}

function Test-TestRunName([string]$Name) { [bool]($Name -match '^[\w][\w .-]{0,48}$') }

function Save-TestRun {
    <# Saves requests as a test run: NAME.testrun.md and, in a NAME folder beside it, copies of the
       project's data files (CSV, TSV, Excel, JSON in Source/ or at the root) so the run starts from
       the same data. Returns the file's path. #>
    param([Parameter(Mandatory)][string]$ProjectsRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Requests, [string]$ProjectRoot = '', $Setup = $null, [string]$Title = '')
    if (-not (Test-TestRunName $Name)) { throw "Invalid test run name '$Name' (letters, digits, space, . _ - only)" }
    $steps = @($Requests | Where-Object { "$_".Trim() })
    if (-not $steps.Count) { throw 'There are no requests to save.' }
    $dir = Get-TestRunsDir $ProjectsRoot -Create
    $files = @(); $source = @()
    if ($ProjectRoot) {
        $seed = Join-Path $dir $Name
        foreach ($f in @(Get-ChildItem -LiteralPath $ProjectRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '(?i)^\.(csv|tsv|xlsx|xlsm|json)$' -and $_.Length -le 50MB })) {
            $null = New-Item -ItemType Directory -Force -Path $seed; Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $seed $f.Name) -Force; $files += "$Name/$($f.Name)"
        }
        $src = Join-Path $ProjectRoot 'Source'
        if (Test-Path -LiteralPath $src) {
            foreach ($f in @(Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -le 50MB })) {
                $null = New-Item -ItemType Directory -Force -Path (Join-Path $seed 'Source'); Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $seed "Source\$($f.Name)") -Force; $source += "$Name/Source/$($f.Name)"
            }
        }
    }
    $answers = @()
    if ($Setup -and $Setup.answers) { foreach ($k in @($Setup.answers.Keys | Sort-Object)) { if ("$($Setup.answers[$k])") { $answers += "$k=$($Setup.answers[$k])" } } }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('---').AppendLine("title: $(if ($Title) { $Title } else { $Name })")
    if ($answers.Count) { [void]$sb.AppendLine("answers: $($answers -join ', ')") }
    if ($Setup -and "$($Setup.build)") { [void]$sb.AppendLine("build: $($Setup.build)") }
    if ($files.Count) { [void]$sb.AppendLine("files: $($files -join ', ')") }
    if ($source.Count) { [void]$sb.AppendLine("source: $($source -join ', ')") }
    [void]$sb.AppendLine('mode: auto').AppendLine('---')
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $lines = "$($steps[$i])".Trim().Replace("`r`n", "`n").Split("`n")
        [void]$sb.AppendLine("$($i + 1). $($lines[0])")
        foreach ($l in @($lines | Select-Object -Skip 1)) { [void]$sb.AppendLine("   $l") }
    }
    $path = Join-Path $dir "$Name.testrun.md"
    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    $path
}

function New-TestRunProject {
    <# A fresh project for a run: "<name> run <stamp>" in the projects folder, with the test's files
       copied in (files at the root, source into Source/) and its setup answers saved. Returns its path. #>
    param([Parameter(Mandatory)][string]$ProjectsRoot, [Parameter(Mandatory)]$Run, [datetime]$Now = (Get-Date))
    $path = Join-Path $ProjectsRoot "$($Run.name) run $($Now.ToString('yyyyMMdd-HHmm'))"
    $n = 2; while (Test-Path -LiteralPath $path) { $path = Join-Path $ProjectsRoot "$($Run.name) run $($Now.ToString('yyyyMMdd-HHmm'))-$n"; $n++ }
    $null = New-Item -ItemType Directory -Path $path
    [IO.File]::WriteAllText((Join-Path $path 'AGENTS.md'), "# $($Run.title)`n`nA test run of saved requests ($($Run.name)).`n", (New-Object Text.UTF8Encoding($false)))
    $dir = Split-Path -Parent $Run.path
    foreach ($f in @($Run.files)) { $s = Join-Path $dir $f.Replace('/', '\'); if (Test-Path -LiteralPath $s -PathType Leaf) { Copy-Item -LiteralPath $s -Destination (Join-Path $path ([IO.Path]::GetFileName($s))) } }
    foreach ($f in @($Run.source)) {
        $s = Join-Path $dir $f.Replace('/', '\')
        if (Test-Path -LiteralPath $s -PathType Leaf) { $null = New-Item -ItemType Directory -Force -Path (Join-Path $path 'Source'); Copy-Item -LiteralPath $s -Destination (Join-Path $path "Source\$([IO.Path]::GetFileName($s))") }
    }
    if ($Run.answers.Count -or $Run.build) {
        Import-Module (Join-Path $PSScriptRoot 'ProjectSetup.psm1')
        $ch = @{ answers = $Run.answers; chosenBy = 'user' }
        if ($Run.build) { $ch.build = $Run.build }
        $null = Save-ProjectSetup $path $ch
    }
    $path
}

function Get-TestRunHistoryPath([string]$ProjectsRoot, [string]$Name) { Join-Path (Get-TestRunsDir $ProjectsRoot) "$Name\history.json" }

function Read-TestRunHistory([string]$ProjectsRoot, [string]$Name) {
    $f = Get-TestRunHistoryPath $ProjectsRoot $Name
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try { @(([IO.File]::ReadAllText($f) | ConvertFrom-Json) | ForEach-Object { $_ }) } catch { @() }
}

function Add-TestRunHistory([string]$ProjectsRoot, [string]$Name, $Entry) {
    # The run's numbers, the last 20 runs kept.
    $f = Get-TestRunHistoryPath $ProjectsRoot $Name
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f)
    $all = @(@(Read-TestRunHistory $ProjectsRoot $Name) + @([pscustomobject]$Entry)) | Select-Object -Last 20
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @($all) -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

function Format-TestRunComparison($Now, $Before) {
    # The run's numbers next to the last run's: "| what | this run | last run |" rows (Markdown).
    $rows = [ordered]@{ tasks = 'Tasks'; messages = 'Copilot messages'; rounds = 'Rounds'; nudges = 'Nudges (the helper program correcting Copilot)'; failedSteps = 'Failed steps'; pageProblems = 'Page problems left'; planLoops = 'Plans planned again'; typing = 'Typing failures'; noAnswer = 'No answer from Copilot'; errors = 'Errors in the log'; minutes = 'Minutes' }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("| | This run ($($Now.build)) | $(if ($Before) { "Last run ($($Before.build), $($Before.when))" } else { 'Last run' }) |").AppendLine('|---|---|---|')
    foreach ($k in $rows.Keys) {
        $b = if ($Before) { "$($Before.$k)" } else { '-' }
        [void]$sb.AppendLine("| $($rows[$k]) | $($Now[$k]) | $b |")
    }
    $sb.ToString()
}

Export-ModuleMember -Function Get-TestRunsDir, Read-TestRun, Get-TestRuns, Test-TestRunName, Save-TestRun, New-TestRunProject, Read-TestRunHistory, Add-TestRunHistory, Format-TestRunComparison
