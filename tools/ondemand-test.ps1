<#
.SYNOPSIS
    Live test of StreamHub's on-demand features, run by a person while the StreamHub web app runs:
    Check this page in full, Compare page, Data profile report, Save the last request as a runbook,
    Write a project overview, Package for sharing, Theme from your colours and Tidy-up list. It
    checks what each feature writes, and how Copilot deals with the instructions StreamHub sends.
.DESCRIPTION
    What it does:
      1. Checks that the app answers on its port (config\harness.json, harness.local.json) with the
         session token in %LOCALAPPDATA%\CCBridge\session-token.txt; stops with a message if not.
      2. Creates a new project "On-demand test STAMP" through the app (in the projects folder in
         OneDrive) and writes invented test files into it: a UI kit page, data\sales.csv, files
         nothing uses, a .env with a made-up value. Invented data only.
      3. Copilot steps (about 4 Copilot messages of the daily limit in all, pptx-ask included; -SkipCopilot leaves them
         out): coding (a total row in index.html, 1 message or a few rounds of it), runbook (a data
         question, then "Save the last request as a runbook", 2 tasks), overview (Write a project
         overview, 1 task). While one runs, an approval card is approved only when it is a write or
         edit of the file that step expects; anything else is denied and counted as a failure. A
         run command, a delete or a Microsoft 365 action is never approved.
      4. Steps without Copilot: page-report, page-compare (needs the coding step's change set),
         data-profile (needs the data import, which runs with a Copilot step), share-package, theme
         (preview, apply, undo), tidy (list, remove one file, undo) and pptx (Apply a PowerPoint
         template: a template and a content deck built from XML strings in Decks\, the plan, the new
         deck checked as a package). pptx-ask asks Copilot for the layouts (one more Copilot
         message; -SkipCopilot leaves it out). On a build without the PowerPoint routes both report
         SKIP.
      5. Writes C:\temp\ondemand-test-STAMP.md: a PASS/FAIL table, what Copilot did per step (rounds,
         actions, done, StreamHub's status lines, the first 200 characters of the done summary; no
         other reply text), timings, the app version and the test project's path. Exit code 1 when
         a check failed.

    How it talks to the app: like the app's own page, with the session token in X-CCB-Token and the
    page's Origin (http://localhost:PORT). The routes behind these features accept only the
    StreamHub page (Server Test-PageOrigin); this tool acts for the person at their own app on their
    own computer, so it sends that Origin (Windows PowerShell's HttpWebRequest lets a script set it,
    a web page cannot). It never starts StreamHub, Edge or Copilot itself.

    It deletes nothing outside the test project. The test project is always kept (-Keep is accepted
    and changes nothing); its path is printed and is in the report. The project that was open
    before is opened again at the end.

    New steps (as the PowerPoint template steps were) are one more entry in $steps below:
    a name, whether it needs Copilot, and the scriptblock that runs and checks it.
.EXAMPLE
    test-tools\ondemand-test.cmd
    test-tools\ondemand-test.cmd -SkipCopilot
    test-tools\ondemand-test.cmd -Only page-report,tidy
#>
param(
    [switch]$SkipCopilot,
    [string[]]$Only = @(),
    [switch]$Keep,
    [int]$Port = 0,
    [int]$StepTimeoutMin = 6,
    [string]$OutRoot = 'C:\temp'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'OnDemandTest.psm1') -Force

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$allSteps = @('coding', 'runbook', 'overview', 'page-report', 'page-compare', 'data-profile', 'share-package', 'theme', 'tidy', 'pptx', 'pptx-ask')
try { $selected = @(Resolve-OnlySteps $allSteps $Only) } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }

# --- The app ---------------------------------------------------------------------------------------

if (-not $Port) {
    try {
        Import-Module (Join-Path $root 'lib\Config.psm1') -Force
        $Port = [int](Get-CCBridgeConfig harness $root).port
    } catch { $Port = 0 }
    if (-not $Port) { $Port = 8765 }
}
$script:Base = "http://localhost:$Port"
$tokenFile = Join-Path $env:LOCALAPPDATA 'CCBridge\session-token.txt'
$script:Token = if (Test-Path -LiteralPath $tokenFile) { [IO.File]::ReadAllText($tokenFile).Trim() } else { '' }

function Get-WebError($ErrorRecord) {
    # The WebException inside a PowerShell error, or $null.
    for ($e = $ErrorRecord.Exception; $e; $e = $e.InnerException) { if ($e -is [Net.WebException]) { return $e } }
    $null
}

function Invoke-App {
    <# One API call as the app's page makes it. Returns @{ status; body (parsed JSON or $null); text }.
       A connection failure throws. #>
    param([string]$Method, [string]$Path, $Body = $null, [int]$TimeoutSec = 60)
    $req = [Net.HttpWebRequest]::Create($script:Base + $Path)
    $req.Method = $Method
    $req.Proxy = $null
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.Headers.Add('X-CCB-Token', $script:Token)
    $req.Headers.Add('Origin', $script:Base)
    if ($Method -eq 'POST') {
        $json = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 8 -Compress } else { '{}' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $req.ContentType = 'application/json'
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
    }
    $resp = $null
    try { $resp = $req.GetResponse() } catch {
        $we = Get-WebError $_
        if (-not $we -or -not $we.Response) { throw }
        $resp = $we.Response
    }
    try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd(); $sr.Dispose()
        $obj = $null
        if ($text) { try { $obj = $text | ConvertFrom-Json } catch { $obj = $null } }
        @{ status = [int]$resp.StatusCode; body = $obj; text = $text }
    } finally { $resp.Close() }
}

function Get-AppError($Answer) {
    # The error an answer carries ('' when none).
    if ($Answer.status -ge 400) { if ($Answer.body -and "$($Answer.body.error)") { return "HTTP $($Answer.status): $($Answer.body.error)" } else { return "HTTP $($Answer.status)" } }
    if ($Answer.body -and $Answer.body.PSObject.Properties['ok'] -and $Answer.body.ok -eq $false) { return "$(if ($Answer.body.error) { $Answer.body.error } elseif ($Answer.body.message) { $Answer.body.message } else { $Answer.body.reason })" }
    ''
}

Write-Host "StreamHub on-demand test, $((Get-Date).ToString('yyyy-MM-dd HH:mm')). App: $script:Base" -ForegroundColor Cyan
if ($script:Token -notmatch '^[0-9a-f]{32}$') {
    Write-Host "StreamHub has no session token yet ($tokenFile). Start StreamHub with start.cmd, then run this again." -ForegroundColor Red
    exit 1
}
$first = $null
try { $first = Invoke-App GET '/api/poll?after=0' -TimeoutSec 10 } catch {
    Write-Host "StreamHub does not answer on $script:Base ($($_.Exception.Message)). Start it with start.cmd (and wait for its page), then run this again. Another port: -Port N." -ForegroundColor Red
    exit 1
}
if ($first.status -ne 200 -or -not $first.body) {
    Write-Host "StreamHub on $script:Base refused the request (HTTP $($first.status)): the session token in $tokenFile does not match the running app. Restart StreamHub, then run this again." -ForegroundColor Red
    exit 1
}
$script:Seq = 0
foreach ($e in @(Get-AsList $first.body.events)) { if ([int]$e.seq -gt $script:Seq) { $script:Seq = [int]$e.seq } }
$state = $first.body.state
$version = "$($state.release)$(if ("$($state.commit)") { " ($($state.commit))" })"
if (-not "$($state.release)") { $vf = Join-Path $root 'version.txt'; $version = if (Test-Path -LiteralPath $vf) { [IO.File]::ReadAllText($vf).Trim() } else { 'dev' } }
$previousProject = if ($state.project) { "$($state.project.path)" } else { '' }
Write-Host "StreamHub $version is running." -ForegroundColor Green

# --- Results ---------------------------------------------------------------------------------------

$checks = New-Object System.Collections.Generic.List[object]
$stepInfo = New-Object System.Collections.Generic.List[object]
$script:Current = $null   # the step being run: approvals and Copilot records go to it

function Add-Check([string]$Check, [string]$Result, [string]$Reason = '') {
    $checks.Add(@{ step = $script:Current.name; check = $Check; result = $Result; reason = $Reason })
    $color = switch ($Result) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host ("  {0,-4} {1}{2}" -f $Result, $Check, $(if ($Reason) { ": $Reason" } else { '' })) -ForegroundColor $color
}
function Test-That([bool]$Ok, [string]$Check, [string]$Why = '', [string]$PassNote = '') {
    if ($Ok) { Add-Check $Check 'PASS' $PassNote } else { Add-Check $Check 'FAIL' $Why }
    $Ok
}

# --- Waiting for the app's tasks -------------------------------------------------------------------

function Get-QueueIds { @(Get-AsList (Invoke-App GET '/api/queue').body.queue | ForEach-Object { "$($_.id)" }) }

function Wait-AppTasks {
    <# Waits until the tasks the step queued (queue entries of the test project not in $Known) have
       finished and the app is idle, answering approval cards (Get-ApprovalDecision) and setup cards
       (Get-SetupAutoAnswer) on the way. $OnEvent sees every event. Returns @{ events; entries;
       timedOut }. #>
    param([string[]]$Known, [string[]]$Expected = @(), [int]$TimeoutSec = ($StepTimeoutMin * 60), [scriptblock]$OnEvent = $null)
    $events = New-Object System.Collections.Generic.List[object]
    $answered = @{}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $calm = 0; $entries = @()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $p = Invoke-App GET "/api/poll?after=$script:Seq"
        foreach ($e in @(Get-AsList $p.body.events)) {
            if ([int]$e.seq -gt $script:Seq) { $script:Seq = [int]$e.seq }
            $events.Add($e)
            if ("$($e.type)" -eq 'action' -and "$($e.status)" -eq 'awaiting' -and -not $answered.ContainsKey("$($e.id)")) {
                $answered["$($e.id)"] = 1
                $d = Get-ApprovalDecision $e $Expected
                $null = Invoke-App POST '/api/approve' @{ id = "$($e.id)"; decision = $d.decision; note = $(if ($d.decision -eq 'reject') { "Denied by the on-demand test: $($d.reason)" } else { '' }); by = 'user' }
                $script:Current.approvals.Add("$($d.decision)d $($d.action) $($d.path): $($d.reason)")
                if ($d.decision -eq 'approve') { Write-Host "  approved: $($d.reason)" -ForegroundColor DarkGray }
                else { Add-Check "Approval card $($d.action) $($d.path)" 'FAIL' "denied: $($d.reason)" }
            }
            if ("$($e.type)" -eq 'setup-choice') {
                $a = Get-SetupAutoAnswer $e
                $setup = @{ answers = $a.answers }
                if ($a.build) { $setup.build = $a.build }
                $null = Invoke-App POST '/api/chat' @{ text = "$($e.request)"; setup = $setup }
                $script:Current.approvals.Add("setup card answered with the first choices: $(@(foreach ($k in $a.answers.Keys) { "$k=$($a.answers[$k])" }) -join ', ')$(if ($a.build) { " build=$($a.build)" })")
                Write-Host '  answered a project setup card with its first choices' -ForegroundColor DarkGray
            }
            if ($OnEvent) { & $OnEvent $e }
        }
        $q = Invoke-App GET '/api/queue'
        $s = Test-QueueSettled $q.body.queue $Known $script:ProjectRoot
        $entries = @($s.entries)
        if ($s.settled -and -not $p.body.state.busy) { $calm++; if ($calm -ge 3) { break } } else { $calm = 0 }
        Start-Sleep -Milliseconds 1000
    }
    @{ events = $events.ToArray(); entries = $entries; timedOut = ($calm -lt 3) }
}

function Invoke-Queued {
    <# Calls a route that queues a task and waits for it. Returns the wait result plus answer. #>
    param([string]$Path, $Body = $null, [string[]]$Expected = @(), [scriptblock]$OnEvent = $null)
    $known = Get-QueueIds
    $ans = Invoke-App POST $Path $Body
    $err = Get-AppError $ans
    if ($err) { return @{ answer = $ans; error = $err; events = @(); entries = @(); timedOut = $false } }
    $w = Wait-AppTasks -Known $known -Expected $Expected -OnEvent $OnEvent
    $w.answer = $ans; $w.error = ''
    if ($w.timedOut) { Add-Check "$Path finished within $StepTimeoutMin min" 'FAIL' 'timed out (is the queue paused, or Copilot at its daily limit?)' }
    $w
}

function Get-EventErrors($Wait) { @(Get-AsList $Wait.events | Where-Object { "$($_.type)" -eq 'error' } | ForEach-Object { Limit-Line "$($_.text)" }) }

function Get-ProjectFile([string]$Rel) { Join-Path $script:ProjectRoot ($Rel.TrimStart('/').Replace('/', '\')) }

function Get-Snapshot { New-FileSnapshot $script:ProjectRoot }

# What StreamHub itself writes during a task (the data import, the UI kit): never counted as Copilot's.
$script:OwnPaths = @('data/*.json', 'data/*.js', 'styles/kit/*')

function Get-OwnChangePaths($Events) {
    @(Get-AsList $Events | Where-Object { "$($_.type)" -eq 'action' -and "$($_.by)" -eq 'streamhub' } | ForEach-Object {
            if ($_.preview -and "$($_.preview.path)") { Get-ActionPath "$($_.preview.path)" } else { Get-ActionPath (("$($_.target)" -replace '\s+\(.*$', '')) } } | Where-Object { $_ })
}

function Send-CopilotRequest {
    <# One chat message as the person types it, waited for. Returns the wait result with the record. #>
    param([string]$Text, [string[]]$Expected = @())
    $known = Get-QueueIds
    $ans = Invoke-App POST '/api/chat' @{ text = $Text }
    $err = Get-AppError $ans
    if ($err) { throw "the app refused the message: $err" }
    $w = Wait-AppTasks -Known $known -Expected $Expected
    if ($w.timedOut) { Add-Check "Copilot step finished within $StepTimeoutMin min" 'FAIL' 'timed out (Copilot busy, at its daily limit, or the queue paused)' }
    $w
}

function Add-CopilotRecord([string]$Label, $Wait) {
    $rec = Get-CopilotStepRecord $Wait.events
    $script:Current.copilot = $rec
    $script:Current.records.Add(@{ label = $Label; record = $rec })
    $acts = @(foreach ($k in $rec.actions.Keys) { "$k $($rec.actions[$k])" }) -join ', '
    Write-Host "  Copilot ($Label): $($rec.rounds) round(s), actions: $(if ($acts) { $acts } else { 'none' }), done: $(if ($rec.done) { 'yes' } else { 'no' })" -ForegroundColor DarkCyan
    $rec
}

# --- The test project ------------------------------------------------------------------------------

$name = "On-demand test $stamp"
Write-Host "Creating the test project '$name'..."
$created = Invoke-App POST '/api/projects' @{ name = $name }
if ($created.status -ge 400) { Write-Host "The app could not create the test project: $(Get-AppError $created)" -ForegroundColor Red; exit 1 }
$script:ProjectRoot = "$($created.body.path)"
if (-not $script:ProjectRoot) { Write-Host "The app did not say where it created the project: $($created.text)" -ForegroundColor Red; exit 1 }
if ($created.body.ok -eq $false) {
    # Not opened yet: the app is busy with a task, or still getting the open project ready.
    $opened = $false
    for ($i = 0; $i -lt 40 -and -not $opened; $i++) {
        Start-Sleep -Seconds 3
        $o = Invoke-App POST '/api/project/open' @{ path = $script:ProjectRoot }
        if ($o.status -lt 400 -and $o.body.ok -ne $false) { $opened = $true }
    }
    if (-not $opened) { Write-Host "The test project was created at $script:ProjectRoot, but the app would not open it (a task is still running?). Let it finish and run the test again." -ForegroundColor Red; exit 1 }
}
Write-Host "Test project: $script:ProjectRoot" -ForegroundColor Green

$enc = New-Object Text.UTF8Encoding($false)
function Write-Fixture([string]$Rel, [string]$Text) {
    $full = Get-ProjectFile $Rel
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
    [IO.File]::WriteAllText($full, $Text.Replace("`r`n", "`n"), $enc)
}

# The low-contrast note's text, found again in the page report.
$noteText = 'Figures are provisional until the month is closed.'
Write-Fixture 'index.html' @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Regional revenue</title>
<link rel="stylesheet" href="styles/kit/tokens.css">
<link rel="stylesheet" href="styles/kit/kit.css">
<link rel="stylesheet" href="styles/app.css">
</head>
<body class="kit-page">
<main class="kit-stack">
<h1>Regional revenue</h1>
<p class="faint-note">$noteText</p>
<div class="kit-table-wrap">
<table class="kit-table" data-kit-sort>
<thead><tr><th>Region</th><th>Last order</th><th class="kit-num">Revenue</th></tr></thead>
<tbody>
<tr><td>North</td><td>2026-03-14</td><td class="kit-num">1234567</td></tr>
<tr><td>South</td><td>12 March 2026</td><td class="kit-num">845,200</td></tr>
<tr><td>East</td><td>9 March 2026</td><td class="kit-num">512,300</td></tr>
</tbody>
</table>
</div>
<div class="kit-chart" data-kit-chart="bar" aria-label="Revenue per region" data-kit-data='[{"label":"North","value":1234567},{"label":"South","value":845200},{"label":"East","value":512300}]'></div>
<p class="kit-caption">Source: data/sales.csv</p>
</main>
<script src="styles/kit/kit.js"></script>
<script src="styles/kit/kit-charts.js"></script>
</body>
</html>
"@
Write-Fixture 'styles/app.css' @"
.faint-note { color: #c8c8c8; }
.legacy-banner { padding: 12px; border: 1px solid #999999; }
"@
Write-Fixture 'styles/unused.css' @"
.old-theme-header { font-weight: 700; }
"@
Write-Fixture 'js/unused.js' @"
// Left over from an earlier version: no page loads this file.
function countOldRows(rows) {
  return rows.length;
}
"@
# Semicolons with decimal commas, day-month-year dates, one value far outside the rest, one row
# repeated exactly, and text in a column of numbers.
$rows = @(
    'Date;Region;Product;Amount;Units'
    '02-01-2026;North;Tea;125,50;10', '05-01-2026;South;Coffee;210,00;14', '07-01-2026;East;Tea;98,75;8'
    '09-01-2026;North;Cocoa;150,25;12', '13-01-2026;South;Tea;132,40;11', '14-01-2026;East;Coffee;188,10;13'
    '16-01-2026;North;Coffee;205,60;15', '19-01-2026;South;Cocoa;99,90;7', '21-01-2026;East;Cocoa;143,00;unknown'
    '23-01-2026;North;Tea;118,30;9', '26-01-2026;South;Coffee;98765,00;16', '27-01-2026;East;Tea;121,80;10'
    '28-01-2026;North;Cocoa;160,45;12', '29-01-2026;South;Tea;135,15;11', '30-01-2026;East;Coffee;176,90;13'
    '30-01-2026;East;Coffee;176,90;13', '31-01-2026;North;Coffee;199,99;14', '31-01-2026;South;Cocoa;111,11;8'
)
Write-Fixture 'data/sales.csv' (($rows -join "`n") + "`n")
Write-Fixture 'Work/old.txt' "Notes from a one-off comparison, kept for a while.`n"
[IO.File]::SetLastWriteTime((Get-ProjectFile 'Work/old.txt'), (Get-Date).AddDays(-20))
Write-Fixture '.env' "DEMO_SERVICE_KEY=made-up-value-for-the-test`n"
Write-Fixture '.gitignore' ".env`n"
Write-Fixture 'Source/notes.txt' "Source data stays out of a package unless it is asked for.`n"
foreach ($kf in 'tokens.css', 'kit.css', 'kit.js', 'kit-charts.js') {
    $from = Join-Path $root "templates\ui-kit\$kf"
    $to = Get-ProjectFile "styles/kit/$kf"
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to)
    [IO.File]::Copy($from, $to, $true)
}
Write-Host 'Wrote the test files (invented data only).'
# Let the app finish what it does after a project opens.
for ($i = 0; $i -lt 30; $i++) { $p = Invoke-App GET "/api/poll?after=$script:Seq"; foreach ($e in @(Get-AsList $p.body.events)) { if ([int]$e.seq -gt $script:Seq) { $script:Seq = [int]$e.seq } }; if (-not $p.body.state.busy) { break }; Start-Sleep -Seconds 1 }
Start-Sleep -Seconds 2

$ctx = @{ changeSet = ''; copilotRan = $false }

# The PowerPoint step's decks, made when a PowerPoint step first runs (so the other steps never see them).
$script:TemplateDeck = 'Decks/brand-template.pptx'
$script:ContentDeck = 'Decks/results.pptx'
$script:DeckInfo = $null
function Initialize-TestDecks {
    if (-not $script:DeckInfo) { $script:DeckInfo = New-OdtTestDecks -TemplatePath (Get-ProjectFile $script:TemplateDeck) -ContentPath (Get-ProjectFile $script:ContentDeck) }
    $script:DeckInfo
}
function Test-PptxRoutes {
    # Whether the running app has the PowerPoint routes (an older build answers 404 Unknown API).
    $r = Invoke-App GET '/api/pptx/decks'
    $r.status -ne 404
}

# --- The steps -------------------------------------------------------------------------------------
# One entry per feature: name (for -Only), copilot (needs Copilot messages), run (the scriptblock that
# runs it and adds its checks). A later feature (for example the PowerPoint template) is one more entry.

$steps = @(
    @{ name = 'coding'; copilot = $true; run = {
            # a. A change to the fixture page: a change set for page-compare, and the data import runs.
            $null = Invoke-App POST '/api/newchat'
            Start-Sleep -Seconds 2
            $before = Get-Snapshot
            $w = Send-CopilotRequest 'In index.html, add a total row at the bottom of the revenue table that adds up the Revenue column. Change only index.html.' @('index.html')
            $rec = Add-CopilotRecord 'total row' $w
            $diff = Compare-FileSnapshot $before (Get-Snapshot)
            $split = Split-ChangedPaths $diff @('index.html') (@($script:OwnPaths) + @(Get-OwnChangePaths $w.events))
            $null = Test-That (@($split.expected) -contains 'index.html') 'index.html changed' 'Copilot did not change index.html'
            $null = Test-That (-not @($split.other).Count) 'No other file changed by Copilot' "also changed: $(@($split.other) -join ', ')"
            $null = Test-That $rec.done 'Copilot ended with done' 'no done step'
            $cp = @(Get-AsList $w.events | Where-Object { "$($_.type)" -eq 'checkpoint' -and "$($_.changeSet)" -match '^\d{8}-\d{6}-\d{3}$' -and @(Get-AsList $_.files | Where-Object { "$_".Replace('\', '/') -match '(^|/)index\.html$' }).Count }) | Select-Object -Last 1
            if ($cp) { $ctx.changeSet = "$($cp.changeSet)" }
            $null = Test-That ([bool]$ctx.changeSet) 'A change set holds index.html' 'no change set with index.html' "change set $($ctx.changeSet)"
            foreach ($x in @(Get-EventErrors $w)) { Add-Check 'Error shown during the step' 'FAIL' $x }
        }
    }
    @{ name = 'runbook'; copilot = $true; run = {
            # b. A plain data question, then Save the last request as a runbook.
            $before = Get-Snapshot
            $w = Send-CopilotRequest 'Which region has the highest total Amount in data/sales.csv? Just tell me the region and the total.' @()
            $rec = Add-CopilotRecord 'data question' $w
            $null = Test-That (@(Get-AsList $w.events | Where-Object { "$($_.type)" -in 'assistant', 'done' }).Count -gt 0) 'Copilot answered the data question' 'no reply'
            $diff = Compare-FileSnapshot $before (Get-Snapshot)
            $split = Split-ChangedPaths $diff @() (@($script:OwnPaths) + @(Get-OwnChangePaths $w.events))
            $null = Test-That (-not @($split.other).Count) 'The question changed no file' "changed: $(@($split.other) -join ', ')"

            $before = Get-Snapshot
            $known = Get-QueueIds
            $ans = Invoke-App POST '/api/runbook-from-chat'
            $err = Get-AppError $ans
            if (-not (Test-That (-not $err) 'Save the last request as a runbook was accepted' "$err$(if ($ans.body.reason) { " (reason: $($ans.body.reason))" })" "name $($ans.body.name)")) { return }
            $w = Wait-AppTasks -Known $known -Expected @('Runbooks/*.runbook.md')
            if ($w.timedOut) { Add-Check "Runbook task finished within $StepTimeoutMin min" 'FAIL' 'timed out' }
            $rec = Add-CopilotRecord 'save as runbook' $w
            $diff = Compare-FileSnapshot $before (Get-Snapshot)
            $books = @(@($diff.added) + @($diff.changed) | Where-Object { $_ -match '^Runbooks/[^/]+\.runbook\.md$' })
            $null = Test-That ($books.Count -eq 1) 'Copilot wrote exactly one Runbooks/NAME.runbook.md' "runbook files written: $($books.Count) ($($books -join ', '))" "$($books -join '')"
            if ($books.Count -eq 1 -and $ans.body.name -and $books[0] -ne "Runbooks/$($ans.body.name).runbook.md") { Add-Check 'Runbook has the name StreamHub asked for' 'FAIL' "asked Runbooks/$($ans.body.name).runbook.md, got $($books[0])" }
            foreach ($b in $books) {
                Import-Module (Join-Path $root 'lib\Runbook.psm1') -Force
                $problems = @(Test-RunbookFile -Path $b -Text ([IO.File]::ReadAllText((Get-ProjectFile $b))) -AboutRunbooks $true)
                $null = Test-That (-not $problems.Count) "$b passes Test-RunbookFile" ($problems -join '; ')
            }
            $ran = @($w.entries | Where-Object { "$($_.kind)" -in 'runbook', 'fetch' })
            $exports = @($diff.added | Where-Object { $_ -like 'Runbooks/Exports/*' })
            $null = Test-That (-not $ran.Count -and -not $exports.Count) 'Copilot did not run the runbook' "runbook tasks: $($ran.Count); new exports: $($exports -join ', ')"
            $split = Split-ChangedPaths $diff @('Runbooks/*.runbook.md') (@($script:OwnPaths) + @(Get-OwnChangePaths $w.events))
            $null = Test-That (-not @($split.other).Count) 'No other file changed' "also changed: $(@($split.other) -join ', ')"
            foreach ($x in @(Get-EventErrors $w)) { Add-Check 'Error shown during the step' 'FAIL' $x }
        }
    }
    @{ name = 'overview'; copilot = $true; run = {
            # c. Write a project overview: StreamHub writes the facts, Copilot fills three sections.
            $before = Get-Snapshot
            $seen = @{ rel = ''; written = $null; preview = $null }
            $onEvent = {
                param($e)
                if ("$($e.type)" -eq 'action' -and "$($e.by)" -eq 'streamhub' -and "$($e.target)" -like 'Runbooks/Exports/project-overview*.md' -and -not $seen.rel) {
                    # Read right after StreamHub wrote it, before Copilot's edit (which comes in a later task).
                    $seen.rel = Get-ActionPath "$($e.target)"
                    if ($e.preview) { $seen.preview = "$($e.preview.new)" }
                    $f = Get-ProjectFile $seen.rel
                    if (Test-Path -LiteralPath $f) { $seen.written = [IO.File]::ReadAllText($f) }
                }
            }
            $w = Invoke-Queued '/api/overview' $null @('Runbooks/Exports/project-overview*.md') $onEvent
            if ($w.error) { Add-Check 'Write a project overview was accepted' 'FAIL' $w.error; return }
            $rec = Add-CopilotRecord 'overview' $w
            if (-not (Test-That ([bool]$seen.rel -and $null -ne $seen.written) 'StreamHub wrote the overview' 'no write card for Runbooks/Exports/project-overview.md' $seen.rel)) { return }
            if ($null -ne $seen.preview -and -not [string]::Equals($seen.preview.Replace("`r`n", "`n"), $seen.written.Replace("`r`n", "`n"), [StringComparison]::Ordinal)) {
                Add-Check 'Overview read before Copilot edited it' 'FAIL' 'the file already differed from what the write card showed (read too late?)'
            }
            $final = [IO.File]::ReadAllText((Get-ProjectFile $seen.rel))
            $r = Test-OverviewResult $seen.written $final
            $null = Test-That $r.marker 'The overview starts with the StreamHub marker' $r.reason
            $null = Test-That (-not @($r.placeholders).Count) 'Every placeholder line was replaced' "left: $(@($r.placeholders) -join '; ')"
            $null = Test-That $r.factsSame 'The Facts part is byte-identical to what StreamHub wrote' $r.reason
            $diff = Compare-FileSnapshot $before (Get-Snapshot)
            $split = Split-ChangedPaths $diff @($seen.rel) (@($script:OwnPaths) + @(Get-OwnChangePaths $w.events))
            $null = Test-That (-not @($split.other).Count) 'Copilot changed no other file' "also changed: $(@($split.other) -join ', ')"
            $null = Test-That $rec.done 'Copilot ended with done' 'no done step'
            foreach ($x in @(Get-EventErrors $w)) { Add-Check 'Error shown during the step' 'FAIL' $x }
        }
    }
    @{ name = 'page-report'; copilot = $false; run = {
            $w = Invoke-Queued '/api/page-report' @{ page = 'index.html' }
            if ($w.error) { Add-Check 'Check this page in full was accepted' 'FAIL' $w.error; return }
            $ev = @(Get-AsList $w.events | Where-Object { "$($_.type)" -eq 'page-report' }) | Select-Object -Last 1
            if (-not (Test-That ([bool]$ev) 'A page-report card came' "$(@(Get-EventErrors $w) -join '; ')")) { return }
            $file = Get-ProjectFile "$($ev.path)"
            $null = Test-That ("$($ev.path)" -like '.streamhub/Reports/page-check-*.md' -and (Test-Path -LiteralPath $file)) 'The report is in .streamhub/Reports' "path: $($ev.path)" "$($ev.path)"
            if (Test-Path -LiteralPath $file) {
                $problems = @(Test-PageReportText ([IO.File]::ReadAllText($file)) 'Figures are provisional')
                $null = Test-That (-not $problems.Count) 'The report finds the low-contrast note, the raw date and the number' ($problems -join '; ')
                $stem = $file -replace '\.md$', ''
                $shots = @('-light.png', '-dark.png', '-375px.png' | Where-Object { -not (Test-Path -LiteralPath "$stem$_") })
                $null = Test-That (-not $shots.Count) 'The three screenshots are there' "missing: $($shots -join ', ')"
            }
            $null = Test-That ([bool]"$($ev.fixRequest)".Trim()) 'The card carries a fix list' 'fixRequest is empty'
        }
    }
    @{ name = 'page-compare'; copilot = $false; run = {
            if (-not $ctx.changeSet) { Add-Check 'Compare page with before the coding change' 'SKIP' 'no change set from the coding step (it was skipped or changed nothing)'; return }
            $w = Invoke-Queued '/api/page-compare' @{ changeSet = $ctx.changeSet; page = 'index.html' }
            if ($w.error) { Add-Check 'Compare page was accepted' 'FAIL' $w.error; return }
            $ev = @(Get-AsList $w.events | Where-Object { "$($_.type)" -eq 'status' -and "$($_.path)" -like '.streamhub/Reports/compare-*.md' }) | Select-Object -Last 1
            if (-not (Test-That ([bool]$ev) 'A comparison report was written' "$(@(Get-EventErrors $w) -join '; ')" "$($ev.path)")) { return }
            $file = Get-ProjectFile "$($ev.path)"
            $stem = $file -replace '\.md$', ''
            $missing = @('-before.png', '-after.png' | Where-Object { -not (Test-Path -LiteralPath "$stem$_") })
            $null = Test-That ((Test-Path -LiteralPath $file) -and -not $missing.Count) 'Report and before/after pictures are there' "missing: $(@($missing) -join ', ')"
            $text = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { '' }
            $null = Test-That ($text -notmatch '(?i)exactly the same' -and (Test-Path -LiteralPath "$stem-changes.png")) 'Differences found (the total row)' 'the report says the page looks exactly the same, or has no -changes.png'
        }
    }
    @{ name = 'data-profile'; copilot = $false; run = {
            $src = @(Get-AsList (Invoke-App GET '/api/data-profile/sources').body.items | Where-Object { "$($_.source)" -ieq 'data/sales.csv' })
            if (-not $src.Count) { Add-Check 'Data profile of data/sales.csv' 'SKIP' 'the data import has not run (it runs with a Copilot step; run without -SkipCopilot)'; return }
            $w = Invoke-Queued '/api/data-profile' @{ source = 'data/sales.csv' }
            if ($w.error) { Add-Check 'Data profile was accepted' 'FAIL' $w.error; return }
            $ev = @(Get-AsList $w.events | Where-Object { "$($_.type)" -eq 'status' -and "$($_.path)" -like '*.md' -and "$($_.text)" -like 'Data profile of*' }) | Select-Object -Last 1
            if (-not (Test-That ([bool]$ev) 'A data profile was saved' "$(@(Get-EventErrors $w) -join '; ')" "$($ev.path)")) { return }
            $md = if ([IO.Path]::IsPathRooted("$($ev.path)")) { "$($ev.path)" } else { Get-ProjectFile "$($ev.path)" }
            $xl = $md -replace '\.md$', '.xlsx'
            $null = Test-That ((Test-Path -LiteralPath $md) -and (Test-Path -LiteralPath $xl)) 'The .md and .xlsx are there' "md: $(Test-Path -LiteralPath $md), xlsx: $(Test-Path -LiteralPath $xl)"
            if (Test-Path -LiteralPath $md) {
                $problems = @(Test-DataProfileReport ([IO.File]::ReadAllText($md)))
                $null = Test-That (-not $problems.Count) 'The outlier, the mixed values and the duplicate row are reported' ($problems -join '; ')
            }
        }
    }
    @{ name = 'share-package'; copilot = $false; run = {
            $w = Invoke-Queued '/api/share-package' @{ includeSource = $false }
            if ($w.error) { Add-Check 'Package for sharing was accepted' 'FAIL' $w.error; return }
            $ev = @(Get-AsList $w.events | Where-Object { "$($_.type)" -eq 'status' -and "$($_.path)" -like '*.zip' }) | Select-Object -Last 1
            if (-not (Test-That ([bool]$ev) 'A zip was made' "$(@(Get-EventErrors $w) -join '; ')" "$($ev.path)")) { return }
            $zip = Get-ProjectFile "$($ev.path)"
            $null = Test-That ("$($ev.path)" -like 'Runbooks/Exports/*.zip' -and (Test-Path -LiteralPath $zip)) 'The zip is in Runbooks/Exports' "path: $($ev.path)"
            if (Test-Path -LiteralPath $zip) {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $z = [IO.Compression.ZipFile]::OpenRead($zip)
                try { $names = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
                $problems = @(Test-PackageEntries $names)
                $null = Test-That (-not $problems.Count) 'No .streamhub, no .env, no Source; README-SHARING.md present' ($problems -join '; ') "$($names.Count) entries"
            }
        }
    }
    @{ name = 'theme'; copilot = $false; run = {
            $tokens = Get-ProjectFile 'styles/kit/tokens.css'
            $orig = Read-FileBytes $tokens
            $colours = @{ accent = '#0d9488'; accent2 = ''; neutral = '' }
            $pv = Invoke-App POST '/api/kit-theme/preview' $colours
            $err = Get-AppError $pv
            $null = Test-That (-not $err -and $pv.body.ok -eq $true -and -not "$($pv.body.error)") 'Theme preview: contrast passes' "$err $($pv.body.error)" "$(@(Get-AsList $pv.body.adjusted).Count) adjustment(s)"
            if ($err -or $pv.body.ok -ne $true) { return }
            $before = Get-Snapshot
            $w = Invoke-Queued '/api/kit-theme/apply' $colours
            if ($w.error) { Add-Check 'Theme apply was accepted' 'FAIL' $w.error; return }
            $now = Read-FileBytes $tokens
            $t = Test-TokensColourOnly ($enc.GetString($orig)) ($enc.GetString($now))
            $null = Test-That $t.ok 'tokens.css changed only in colour values' (@($t.problems) -join '; ') "$($t.changed) changed, $($t.added) added"
            $diff = Compare-FileSnapshot $before (Get-Snapshot)
            $split = Split-ChangedPaths $diff @('styles/kit/tokens.css') @()
            $null = Test-That (-not @($split.other).Count) 'Nothing else changed' "also changed: $(@($split.other) -join ', ')"
            $u = Invoke-Queued '/api/undo' @{}
            if ($u.error) { Add-Check 'Undo was accepted' 'FAIL' $u.error; return }
            $back = Read-FileBytes $tokens
            $null = Test-That ((Get-TextHash $back) -eq (Get-TextHash $orig)) 'Undo restored tokens.css byte for byte' 'tokens.css differs from before the theme'
        }
    }
    @{ name = 'tidy'; copilot = $false; run = {
            $w = Invoke-Queued '/api/tidy/list' $null
            if ($w.error) { Add-Check 'Tidy-up list was accepted' 'FAIL' $w.error; return }
            $ev = @(Get-AsList $w.events | Where-Object { "$($_.type)" -eq 'tidy-list' }) | Select-Object -Last 1
            if (-not (Test-That ([bool]$ev) 'A tidy-up card came' "$(@(Get-EventErrors $w) -join '; ')")) { return }
            $items = @(Get-AsList $ev.tidyItems)
            $problems = @(Test-TidyItems $items @('js/unused.js', 'styles/unused.css', 'styles/app.css', 'Work/old.txt') @('index.html', 'data/sales.csv', '.env'))
            $null = Test-That (-not $problems.Count) 'Lists the unused files, the unused rule and Work/old.txt; never index.html, data/sales.csv or .env' ($problems -join '; ') "$($items.Count) item(s)"
            $target = @($items | Where-Object { "$($_.path)" -eq 'js/unused.js' }) | Select-Object -First 1
            if (-not $target) { Add-Check 'Remove js/unused.js' 'SKIP' 'not on the list'; return }
            $file = Get-ProjectFile 'js/unused.js'
            $orig = Read-FileBytes $file
            $before = Get-Snapshot
            $r = Invoke-Queued '/api/tidy/apply' @{ ids = @("$($target.id)") }
            if ($r.error) { Add-Check 'Tidy apply was accepted' 'FAIL' $r.error; return }
            $diff = Compare-FileSnapshot $before (Get-Snapshot)
            $null = Test-That ((@($diff.removed) -join ',') -eq 'js/unused.js' -and -not @($diff.added).Count -and -not @($diff.changed).Count) 'Only js/unused.js was removed' "removed: $(@($diff.removed) -join ', '); added: $(@($diff.added) -join ', '); changed: $(@($diff.changed) -join ', ')"
            $u = Invoke-Queued '/api/undo' @{}
            if ($u.error) { Add-Check 'Undo was accepted' 'FAIL' $u.error; return }
            $ok = (Test-Path -LiteralPath $file) -and ((Get-TextHash (Read-FileBytes $file)) -eq (Get-TextHash $orig))
            $null = Test-That $ok 'Undo brought js/unused.js back byte for byte' 'missing or different'
        }
    }
    @{ name = 'pptx'; copilot = $false; run = {
            # Apply a PowerPoint template: the plan by StreamHub's rules, then the new deck, checked as a package.
            if (-not (Test-PptxRoutes)) { Add-Check 'Apply a PowerPoint template' 'SKIP' 'the PowerPoint routes are not in this build'; return }
            $decks = Initialize-TestDecks
            $tplHash = Get-TextHash (Read-FileBytes (Get-ProjectFile $script:TemplateDeck))
            $conHash = Get-TextHash (Read-FileBytes (Get-ProjectFile $script:ContentDeck))
            $list = (Invoke-App GET '/api/pptx/decks').body
            $null = Test-That (@(Get-AsList $list.templates) -contains $script:TemplateDeck -and @(Get-AsList $list.contents) -contains $script:ContentDeck) 'The project''s decks are listed' "templates: $(@(Get-AsList $list.templates) -join ', '); contents: $(@(Get-AsList $list.contents) -join ', ')"
            $w = Invoke-Queued '/api/pptx/plan' @{ template = $script:TemplateDeck; content = $script:ContentDeck }
            if ($w.error) { Add-Check 'Propose layouts was accepted' 'FAIL' $w.error; return }
            $ev = @(Get-AsList $w.events | Where-Object { "$($_.type)" -eq 'pptx-plan' -and "$($_.pptx.step)" -eq 'plan' }) | Select-Object -Last 1
            if (-not (Test-That ([bool]$ev) 'A layout proposal came' "$(@(Get-EventErrors $w) -join '; ')")) { return }
            $plan = $ev.pptx
            $problems = @(Test-PptxPlan $plan $decks.contentSlides $decks.freeHeadingSlide)
            $null = Test-That (-not $problems.Count) 'Every content slide gets a template layout; the free-text-box heading is checked or converted' ($problems -join '; ')
            $a = Invoke-Queued '/api/pptx/apply' @{ template = $script:TemplateDeck; content = $script:ContentDeck; choices = (New-PptxApplyChoices $plan) }
            if ($a.error) { Add-Check 'Apply was accepted' 'FAIL' $a.error; return }
            $rel = "$($a.answer.body.path)"
            $out = Get-ProjectFile $rel
            if (-not (Test-That ($rel -like 'Runbooks/Exports/*.pptx' -and (Test-Path -LiteralPath $out)) 'The new deck is in Runbooks/Exports' "path: '$rel'; $(@(Get-EventErrors $a) -join '; ')" $rel)) { return }
            $pk = Test-PptxPackage $out
            $null = Test-That (-not @($pk.problems).Count) 'The new deck is a valid package (relationships, slide ids)' (@($pk.problems) -join '; ')
            $want = $(if ([int]$plan.start -gt 0) { 1 } else { 0 }) + $decks.contentSlides + $(if ([int]$plan.end -gt 0) { 1 } else { 0 })
            $null = Test-That ($pk.slides -eq $want) 'Slide count = start + content + end' "$($pk.slides) slide(s), expected $want" "$($pk.slides) slides"
            $same = ((Get-TextHash (Read-FileBytes (Get-ProjectFile $script:TemplateDeck))) -eq $tplHash) -and ((Get-TextHash (Read-FileBytes (Get-ProjectFile $script:ContentDeck))) -eq $conHash)
            $null = Test-That $same 'The template and the content deck are unchanged' 'a deck changed'
        }
    }
    @{ name = 'pptx-ask'; copilot = $true; run = {
            # Ask Copilot for the layouts: its answer must name only known layouts and slides, and fill the card.
            if (-not (Test-PptxRoutes)) { Add-Check 'Ask Copilot for the layouts' 'SKIP' 'the PowerPoint routes are not in this build'; return }
            $decks = Initialize-TestDecks
            $w = Invoke-Queued '/api/pptx/ask' @{ template = $script:TemplateDeck; content = $script:ContentDeck } @()
            if ($w.error) { Add-Check 'Ask Copilot was accepted' 'FAIL' $w.error; return }
            $null = Add-CopilotRecord 'layouts' $w
            $ev = @(Get-AsList $w.events | Where-Object { "$($_.type)" -eq 'pptx-plan' -and "$($_.pptx.step)" -eq 'plan' }) | Select-Object -Last 1
            if (-not (Test-That ([bool]$ev) 'StreamHub filled a card from Copilot''s answer' "$(@(Get-EventErrors $w) -join '; ')")) { return }
            $problems = @(Test-PptxAskPlan $ev.pptx $decks.contentSlides)
            $null = Test-That (-not $problems.Count) 'The answer names only known layouts and slide numbers' ($problems -join '; ')
        }
    }
)

# --- Run -------------------------------------------------------------------------------------------

foreach ($s in $steps) {
    if ($selected -notcontains $s.name) { continue }
    $script:Current = @{ name = $s.name; seconds = 0; copilot = $null; approvals = (New-Object System.Collections.Generic.List[string]); records = (New-Object System.Collections.Generic.List[object]) }
    $stepInfo.Add($script:Current)
    Write-Host ''
    Write-Host "== $($s.name)$(if ($s.copilot) { ' (uses Copilot)' })" -ForegroundColor Cyan
    if ($s.copilot -and $SkipCopilot) { Add-Check 'Not run' 'SKIP' '-SkipCopilot'; continue }
    if ($s.copilot) { $ctx.copilotRan = $true }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { & $s.run } catch { Add-Check 'Step ran to the end' 'FAIL' "stopped: $($_.Exception.Message)" }
    $script:Current.seconds = $watch.Elapsed.TotalSeconds
}

# --- Report ----------------------------------------------------------------------------------------

if ($previousProject -and $previousProject -ne $script:ProjectRoot -and (Test-Path -LiteralPath $previousProject)) {
    try { $o = Invoke-App POST '/api/project/open' @{ path = $previousProject }; if ($o.status -lt 400 -and $o.body.ok -ne $false) { Write-Host "Opened $previousProject again." } } catch { }
}
# Several Copilot records in one step (the runbook step has two tasks): the report lists each.
$reportSteps = foreach ($si in $stepInfo) {
    if ($si.records.Count -le 1) { @{ name = $si.name; seconds = $si.seconds; copilot = $si.copilot; approvals = $si.approvals.ToArray() } }
    else {
        $n = 0
        foreach ($r in $si.records) { $n++; @{ name = "$($si.name): $($r.label)"; seconds = $(if ($n -eq 1) { $si.seconds } else { 0 }); copilot = $r.record; approvals = $(if ($n -eq 1) { $si.approvals.ToArray() } else { @() }) } }
    }
}
$md = Format-OnDemandReport @{ when = (Get-Date).ToString('yyyy-MM-dd HH:mm'); version = $version; project = $script:ProjectRoot; copilotRan = $ctx.copilotRan; checks = $checks.ToArray(); steps = @($reportSteps) }
$null = New-Item -ItemType Directory -Force -Path $OutRoot
$out = Join-Path $OutRoot "ondemand-test-$stamp.md"
[IO.File]::WriteAllText($out, $md, $enc)
$fails = @($checks | Where-Object { $_.result -eq 'FAIL' }).Count
$passes = @($checks | Where-Object { $_.result -eq 'PASS' }).Count
$skips = @($checks | Where-Object { $_.result -eq 'SKIP' }).Count
Write-Host ''
Write-Host "Result: $passes passed, $fails failed, $skips skipped." -ForegroundColor $(if ($fails) { 'Red' } else { 'Green' })
Write-Host "Report: $out"
Write-Host "Test project (kept; delete it yourself when done): $script:ProjectRoot"
if ($fails) { exit 1 }
exit 0
