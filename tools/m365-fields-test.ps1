<#
  Which fields and filters Copilot can use for five kinds of Microsoft 365 data: a Teams channel
  message, a Teams group chat message, a Teams 1:1 chat message, an email and a calendar item. For
  each topic it opens a new chat with Work IQ on and asks Copilot, read-only, to look at the most
  recent item of that kind and describe the fields it can see (name, type, description, an example
  written with placeholders only), the filters it can apply and its limits. No item content is
  asked for or kept: the report holds field names, types, filter names and the kinds of sources
  Copilot cited (no titles, addresses or values). If Copilot proposes any action (send, schedule,
  ...) the test stops that topic and never touches it.

  Needs a Microsoft 365 Copilot licence with Work IQ (the toggle from capture.cmd); uses one
  Copilot message per topic. Report: C:\temp\StreamHub-m365-fields-<time>.json and .md.
  Only some topics:  m365-fields-test.cmd -Topics email,calendar
#>
param([string]$Topics = 'teams-channel,teams-group-chat,teams-1to1-chat,email,calendar', [string]$OutRoot = 'C:\temp')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Log', 'Config', 'Cdp', 'CopilotBridge', 'Runbook') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$cfg = Get-CCBridgeConfig harness $root
Initialize-CCBLog -Level info -Config $cfg

# What each topic is called in the question to Copilot.
$what = [ordered]@{
    'teams-channel'    = 'message in a Microsoft Teams channel (a post or reply in a team''s channel)'
    'teams-group-chat' = 'message in a Microsoft Teams group chat (a chat with three or more people, not a channel)'
    'teams-1to1-chat'  = 'message in a Microsoft Teams one-on-one chat (a chat with exactly one other person)'
    'email'            = 'email in my Outlook mailbox'
    'calendar'         = 'calendar item (meeting or appointment) in my Outlook calendar'
}
$list = @($Topics.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
foreach ($t in $list) { if (-not $what.Contains($t)) { throw "Unknown topic '$t'. Use: $($what.Keys -join ', ')" } }

$fence = '```'
function New-FieldsQuestion([string]$Topic, [string]$Description) {
    @"
Read only: do not send, reply, forward, post, schedule, accept, decline, change or delete anything, and do not offer to.
Using my Microsoft 365 data, look at my most recent $Description.
I do not want its content. I want to know which information you can see for an item of this kind, so I can ask for it later.
Answer with only one $($fence)json code block, no text before or after it, in this shape:
{
  "topic": "$Topic",
  "found": true,
  "fields": [ { "name": "FIELD_NAME", "type": "text | date-time | person | people | number | boolean | url | list | rich-text | file", "description": "what it holds", "example": "an example written with placeholders only, such as PERSON_NAME or 2025-01-31T09:00" } ],
  "filters": [ { "name": "FILTER_NAME", "example": "how I would ask for it" } ],
  "limits": "what you cannot see or return for this kind of item (for example how far back, attachments, reactions)"
}
Rules: list every field you can see, including ones that are empty for this item. Never put a real name, address, subject, message text, date or link in the answer. If you cannot find any item of this kind, answer with "found": false and still list the fields and filters you would normally have.
"@
}

function Get-NoFieldsReason($Reply) {
    <# Why an answer has no fields, from fixed phrases only: the reply text itself is never copied
       into the report (it could hold Microsoft 365 content). #>
    $text = "$($Reply.Text)"
    if ("$($Reply.Result)" -and "$($Reply.Result)" -ne 'Success' -and -not $text.Trim()) { return "Copilot gave no answer ($($Reply.Result))." }
    if ($text -match '(?i)verify your request|verify (that )?you') { return 'Copilot asked to verify the request (its own anti-abuse check). Send one message by hand in the Copilot window, then run the test again later.' }
    if ($text -match '(?i)(can.?t|cannot|unable to|don.?t have|do not have)\s+(access|see|read|retrieve)') { return 'Copilot says it cannot access this data: Work IQ is off or the licence does not include it.' }
    if ($text -match '(?i)daily limit|check back') { return 'Copilot''s daily limit was reached.' }
    'The answer had no JSON block (Copilot answered in another form).'
}

$null = New-Item -ItemType Directory -Force -Path $OutRoot
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$jsonOut = Join-Path $OutRoot "StreamHub-m365-fields-$stamp.json"
$mdOut = Join-Path $OutRoot "StreamHub-m365-fields-$stamp.md"
$results = New-Object System.Collections.Generic.List[object]

Write-Host "StreamHub Microsoft 365 fields test: $($list -join ', ')"
$bridge = Connect-Copilot -Port ([int]$cfg.cdpPort)
try {
    foreach ($t in $list) {
        Write-Host "  $t ..." -NoNewline
        $entry = [ordered]@{ topic = $t; workIq = ''; result = ''; parsed = $false; found = $null; fields = @(); filters = @(); limits = ''; sourceKinds = @(); proposedActions = 0; note = '' }
        try {
            New-CopilotChat $bridge
            $entry.workIq = Set-CopilotWorkIq $bridge $true
            if ($entry.workIq -eq 'unavailable') { Write-Host ' (Work IQ toggle not found: run capture.cmd on a Microsoft 365 Copilot licence first)' -NoNewline -ForegroundColor Yellow }
            $r = Send-CopilotPrompt $bridge (New-FieldsQuestion $t $what[$t]) -TimeoutSec 240
            $entry.result = "$($r.Result)"
            $entry.proposedActions = @($r.ProposedActions).Count
            # Only the kinds of cited sources (Email, Teams, Event...), never their titles or links.
            $entry.sourceKinds = @(@($r.References) | Where-Object { $_.kind } | ForEach-Object { "$($_.kind)" } | Sort-Object -Unique)
            if ($entry.proposedActions) {
                $entry.note = 'Copilot proposed an action; the test left it alone and did not use this answer.'
            } else {
                $json = Get-JsonFromReply "$($r.Text)"
                if ($json) {
                    $o = $json | ConvertFrom-Json
                    $entry.parsed = $true
                    $entry.found = $o.found
                    $entry.fields = @(@($o.fields) | Where-Object { $_ } | ForEach-Object { [ordered]@{ name = "$($_.name)"; type = "$($_.type)"; description = "$($_.description)"; example = "$($_.example)" } })
                    $entry.filters = @(@($o.filters) | Where-Object { $_ } | ForEach-Object { [ordered]@{ name = "$($_.name)"; example = "$($_.example)" } })
                    $entry.limits = "$($o.limits)"
                } else {
                    $entry.note = Get-NoFieldsReason $r
                }
            }
        } catch { $entry.note = "Error: $($_.Exception.Message)" }
        $results.Add([pscustomobject]$entry)
        Write-Host (" {0} field(s), {1} filter(s){2}" -f @($entry.fields).Count, @($entry.filters).Count, $(if ($entry.note) { " - $($entry.note)" } else { '' }))
    }
} finally { Disconnect-Copilot $bridge }

# The report: JSON for tools, Markdown for reading.
$report = [ordered]@{ generatedAt = (Get-Date).ToString('s'); topics = $results.ToArray() }
[IO.File]::WriteAllText($jsonOut, ($report | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Microsoft 365 fields Copilot can use ($((Get-Date).ToString('yyyy-MM-dd HH:mm')))")
$md.Add('')
$md.Add('Field names, types and filters only; no item content. Review before sharing: field descriptions are written by Copilot.')
foreach ($e in $results) {
    $md.Add('')
    $md.Add("## $($e.topic)")
    $md.Add('')
    $md.Add("Work IQ: $($e.workIq); reply: $($e.result); item found: $($e.found); cited source kinds: $(if (@($e.sourceKinds).Count) { $e.sourceKinds -join ', ' } else { 'none' })")
    if ($e.note) { $md.Add(''); $md.Add("Note: $($e.note)") }
    if (@($e.fields).Count) {
        $md.Add(''); $md.Add('| Field | Type | Description | Example |'); $md.Add('|---|---|---|---|')
        foreach ($f in $e.fields) { $md.Add("| $($f.name) | $($f.type) | $($f.description -replace '\|', '/') | $($f.example -replace '\|', '/') |") }
    }
    if (@($e.filters).Count) {
        $md.Add(''); $md.Add('| Filter | How to ask |'); $md.Add('|---|---|')
        foreach ($f in $e.filters) { $md.Add("| $($f.name) | $($f.example -replace '\|', '/') |") }
    }
    if ($e.limits) { $md.Add(''); $md.Add("Limits: $($e.limits)") }
}
[IO.File]::WriteAllLines($mdOut, $md, (New-Object Text.UTF8Encoding($false)))
Write-Host ''
Write-Host "Saved: $mdOut" -ForegroundColor Green
Write-Host "       $jsonOut"
