<#
.SYNOPSIS
    Measures where the time goes between sending a prompt and CCBridge having the reply.
.DESCRIPTION
    Sends a few short prompts (one Copilot message each, each in a new chat) and records the exact
    time (HH:mm:ss.fff) of every step, plus the milliseconds since Send was clicked:
      - what the page shows (Stop button, reply length, Copy button, reply state flags)
      - every WebSocket (first/last frame, record types such as type1:update or type2 (end))
      - every other request (response type, first/last data, streaming chunks)
      - when CCBridge returned the reply and by which route (Chathub socket or the page)
    Network times are Edge's own timestamps (when the data arrived in the browser); page times
    come from the page clock. Only names, sizes and times are recorded: no prompt or reply text,
    no URL queries. Writes CCBridge-timing-<date>.txt and .json to the desktop.
.EXAMPLE
    reply-timing.cmd
    reply-timing.cmd -Count 1
#>
param(
    [int]$Count = 3,
    [int]$PageCheckMs = 200
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Log.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Cdp.psm1') -Force
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force
Set-CCBLogLevel verbose

$prompts = @(@(
    @{ name = 'Greeting'; text = 'Hi' },
    @{ name = 'Short list'; text = 'Name three colours, one per line, nothing else.' },
    @{ name = 'Small code'; text = 'Write a PowerShell function Get-Total that sums the numbers piped into it. Reply with only the code block.' }
) | Select-Object -First $Count)

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$desktop = [Environment]::GetFolderPath('Desktop')
Write-Host "CCBridge reply timing: $($prompts.Count) prompt(s), one Copilot message each." -ForegroundColor Cyan
Write-Host 'Connecting to Copilot in Edge...'
$bridge = Connect-Copilot
$bridge | Add-Member -NotePropertyName PageCheckMs -NotePropertyValue $PageCheckMs -Force

function Format-At($At) { if ($At) { ([datetime]$At).ToString('HH:mm:ss.fff') } else { '-' } }

$results = @()
$i = 0
foreach ($p in $prompts) {
    $i++
    Write-Host ("[{0}] {1}... " -f $i, $p.name) -NoNewline
    New-CopilotChat $bridge
    $tl = New-ReplyTimeline
    $bridge | Add-Member -NotePropertyName Timeline -NotePropertyValue $tl -Force
    $res = [ordered]@{ step = $i; name = $p.name; result = $null; route = $null; replyChars = 0; error = $null }
    try {
        $r = Send-CopilotPrompt $bridge $p.text -TimeoutSec 240
        $res.result = "$($r.Result)"
        $res.replyChars = "$($r.Text)".Length
    } catch {
        $res.result = 'Error'; $res.error = (Protect-LogText $_.Exception.Message)
    }
    $bridge.Timeline = $null

    # One chronological list of everything that happened, with exact times.
    $sent = @($tl.Events | Where-Object what -eq 'sent' | Select-Object -First 1)
    $t0 = if ($sent) { [datetime]$sent[0].at } else { Get-Date }
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Row($At, [string]$Text) { if ($At) { $rows.Add([pscustomobject]@{ at = [datetime]$At; text = $Text }) } }
    foreach ($e in $tl.Events) { Add-Row $e.at ($(if ($e.data) { "$($e.what): $($e.data)" } else { $e.what })) }
    foreach ($s in $tl.Sockets.Values) {
        if (-not $s.frames) { continue }
        $u = Protect-LogText $s.url
        Add-Row $s.created "socket opened $u"
        Add-Row $s.first "socket first frame $u"
        Add-Row $s.last "socket last frame $u ($($s.frames) frames, $($s.binary) binary)"
        foreach ($k in $s.shapes.Keys) {
            $x = $s.shapes[$k]
            Add-Row $x.first "  record $k first (x$($x.n)) on $u"
            if ($x.n -gt 1) { Add-Row $x.last "  record $k last on $u" }
        }
    }
    foreach ($q in $tl.Requests.Values) {
        $n = Protect-LogText $q.req
        Add-Row $q.sent "request $n [$($q.type)]"
        Add-Row $q.response "  response $n ($($q.mime))"
        Add-Row $q.firstData "  first data $n"
        if ($q.chunks -gt 1) { Add-Row $q.lastData "  last data $n ($($q.chunks) chunks, $($q.bytes) B)" }
        Add-Row $q.done "  finished $n"
    }
    $sorted = @($rows | Sort-Object at)
    $res.timeline = @($sorted | ForEach-Object { '{0}  {1,7}  {2}' -f (Format-At $_.at), ('+' + [long]($_.at - $t0).TotalMilliseconds), $_.text })

    # Milestones (ms after Send was clicked)
    $ms = { param($At) if ($At) { [long](([datetime]$At) - $t0).TotalMilliseconds } else { $null } }
    $pages = @($tl.Events | Where-Object what -eq 'page')
    $stopOn = @($pages | Where-Object { "$($_.data)" -match 'stop=True' } | Select-Object -First 1)
    $stopOff = if ($stopOn) { @($pages | Where-Object { $_.at -gt $stopOn[0].at -and "$($_.data)" -match 'stop=False' } | Select-Object -First 1) } else { @() }
    $text1 = @($pages | Where-Object { "$($_.data)" -match 'len=[1-9]' } | Select-Object -First 1)
    $ret = @($tl.Events | Where-Object what -eq 'returned' | Select-Object -First 1)
    $hub = @($tl.Events | Where-Object what -eq 'first Chathub frame' | Select-Object -First 1)
    $ends = @($tl.Sockets.Values | ForEach-Object { $s = $_; $s.shapes.Keys | Where-Object { $_ -match '\(end\)' } | ForEach-Object { $s.shapes[$_].first } } | Sort-Object)
    $res.sentAt = Format-At $t0
    $res.firstTextOnPageMs = & $ms $(if ($text1) { $text1[0].at })
    $res.stopShownMs = & $ms $(if ($stopOn) { $stopOn[0].at })
    $res.stopGoneMs = & $ms $(if ($stopOff) { $stopOff[0].at })
    $res.firstChathubFrameMs = & $ms $(if ($hub) { $hub[0].at })
    $res.firstEndRecordMs = & $ms $(if ($ends) { $ends[0] })
    $res.returnedMs = & $ms $(if ($ret) { $ret[0].at })
    $res.route = if ($ret) { "$($ret[0].data)" } else { $null }
    if ($null -ne $res.returnedMs -and $null -ne $res.stopGoneMs) { $res.waitAfterStopGoneMs = $res.returnedMs - $res.stopGoneMs }
    if ($null -ne $res.returnedMs -and $null -ne $res.firstEndRecordMs) { $res.waitAfterEndRecordMs = $res.returnedMs - $res.firstEndRecordMs }
    $results += [pscustomobject]$res

    if ($res.result -eq 'Error') { Write-Host "Error: $($res.error)" -ForegroundColor Red }
    else {
        Write-Host ("{0} via {1}: returned +{2} ms; Copilot done on the page +{3} ms" -f $res.result, $res.route, $res.returnedMs, $(if ($null -ne $res.stopGoneMs) { $res.stopGoneMs } else { '?' }))
    }
}

# Report
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("CCBridge reply timing $stamp ($(Get-CCBridgeVersion $root)), page checked every $PageCheckMs ms")
$lines.Add('Times: HH:mm:ss.fff and +ms after Send was clicked. Network times are Edge''s own; page times the page clock.')
$lines.Add('Names, sizes and times only; no prompt or reply text.')
$lines.Add('')
$lines.Add('Step                Result   Route                 Sent at       First text  Stop gone  End record  Returned  Wait after Stop gone')
foreach ($r in $results) {
    $lines.Add(('{0,-19} {1,-8} {2,-21} {3,-13} {4,10} {5,10} {6,11} {7,9} {8,10}' -f "[$($r.step)] $($r.name)", $r.result, $r.route, $r.sentAt, $r.firstTextOnPageMs, $r.stopGoneMs, $r.firstEndRecordMs, $r.returnedMs, $r.waitAfterStopGoneMs))
}
foreach ($r in $results) {
    $lines.Add('')
    $lines.Add("=== [$($r.step)] $($r.name): $($r.result) via $($r.route)")
    if ($r.error) { $lines.Add("    error: $($r.error)") }
    foreach ($t in $r.timeline) { $lines.Add("    $t") }
}
$txt = Join-Path $desktop "CCBridge-timing-$stamp.txt"
$json = Join-Path $desktop "CCBridge-timing-$stamp.json"
[IO.File]::WriteAllLines($txt, [string[]]$lines)
[IO.File]::WriteAllText($json, ($results | ConvertTo-Json -Depth 6))
Write-Host ''
Write-Host "Report:  $txt" -ForegroundColor Cyan
Write-Host "Details: $json"
