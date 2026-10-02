# Runbooks: templates, placeholders, JSON extraction and validation.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Runbook.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force

Describe 'Runbook templates' {
    $templates = @(Get-ChildItem (Join-Path $root 'templates\runbooks') -Filter '*.runbook.md')
    It 'ships the blank template and the ready-made ones' {
        $ids = @(Get-RunbookTemplates $root | ForEach-Object { $_.id })
        foreach ($id in 'blank', 'meetings', 'email-followups', 'teams-actions', 'documents-recent', 'topic-digest') { $ids -contains $id | Should Be $true }
    }
    foreach ($t in $templates) {
        It "$($t.Name): its example passes its own checks, and it is read-only and ASCII" {
            $text = [IO.File]::ReadAllText($t.FullName)
            $rb = Read-Runbook $text
            $rb.meta.output | Should Match '^exports/.+\.json$'
            $rb.meta.itemsKey | Should Not BeNullOrEmpty
            $rb.body | Should Not Match '<!--'                   # notes for the person are not sent
            $rb.body | Should Match '(?i)read-only'
            $rb.body | Should Not Match 'StreamHub|CCBridge'
            $example = [regex]::Matches($rb.body, '(?s)```json\n(.*?)\n```') | Select-Object -Last 1
            $check = Test-RunbookOutput $example.Groups[1].Value $rb.meta
            ($check.errors -join '; ') | Should BeNullOrEmpty
            $check.count -ge 1 | Should Be $true
            @($text.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should Be 0
        }
    }
}

Describe 'Placeholders' {
    It 'fills in dates, offsets, the time zone and header keys' {
        $now = [datetime]'2026-10-07 09:15'   # a Wednesday
        $t = Resolve-RunbookText 'From {{today-7d}} to {{today+14d}}; week {{weekStart}}..{{weekEnd}}; month {{monthStart}}..{{monthEnd}}; tz {{timezone}}; topic {{topic}}; {{unknown}}' @{ topic = 'Apollo'; output = 'x' } $now
        $t | Should Match 'From 2026-09-30 to 2026-10-21'
        $t | Should Match 'week 2026-10-05\.\.2026-10-11'
        $t | Should Match 'month 2026-10-01\.\.2026-10-31'
        $t | Should Match 'tz .+UTC[+-]\d\d:\d\d'
        $t | Should Match 'topic Apollo'
        $t | Should Match '\{\{unknown\}\}'
    }
}

Describe 'JSON from a reply, checked against the runbook' {
    $meta = @{ itemsKey = 'items'; required = 'generatedAt, items, truncated'; requiredItemFields = 'id, title' }
    It 'takes the json code block' {
        Get-JsonFromReply "Here you go:`n``````json`n{ ""a"": 1 }`n``````" | Should BeExactly '{ "a": 1 }'
        Get-JsonFromReply '{ "b": 2 }' | Should BeExactly '{ "b": 2 }'
        Get-JsonFromReply 'no json here' | Should BeNullOrEmpty
    }
    It 'accepts a matching result, null values included' {
        $c = Test-RunbookOutput '{ "generatedAt": "x", "items": [ { "id": null, "title": "a" } ], "truncated": false }' $meta
        $c.ok | Should Be $true
        $c.count | Should Be 1
    }
    It 'lists what is wrong' {
        $c = Test-RunbookOutput '{ "items": [ { "id": 1 } ] }' $meta
        $c.ok | Should Be $false
        ($c.errors -join "`n") | Should Match 'generatedAt" is missing'
        ($c.errors -join "`n") | Should Match 'items\[0\] is missing: title'
        (Test-RunbookOutput '{ broken' $meta).errors[0] | Should Match 'does not parse'
        (Test-RunbookOutput '' $meta).errors[0] | Should Match 'no JSON'
    }
}

Describe 'Runbooks in a project' {
    $p = Join-Path $env:TEMP ('ccb-rb-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $p | Out-Null
    It 'creates a runbook from a template, lists it and saves its output with a dated copy' {
        $rb = New-RunbookFromTemplate $root $p 'meetings' 'Meetings next week'
        $rb.name | Should Be 'meetings-next-week'
        $rb.output | Should Be 'exports/meetings-next-week.json'
        { New-RunbookFromTemplate $root $p 'meetings' 'Meetings next week' } | Should Throw 'already exists'
        @(Get-Runbooks $p).Count | Should Be 1
        $saved = Save-RunbookOutput $p 'meetings-next-week' 'exports/meetings-next-week.json' '{ "meetings": [] }'
        Test-Path (Join-Path $p 'exports\meetings-next-week.json') | Should Be $true
        $saved.history | Should Match '^exports/history/meetings-next-week-\d{8}-\d{6}\.json$'
        (Get-Runbooks $p)[0].lastRun | Should Not BeNullOrEmpty
    }
    It 'sends the runbook with the assistant role, the read-only rule and the JSON instruction' {
        $m = New-PromptMessage -AppRoot $root -Kind 'runbook' -Text 'RUNBOOK BODY' -Sent (New-Object 'System.Collections.Generic.HashSet[string]')
        $m | Should Match 'personal assistant'
        $m | Should Match 'only to read it'
        $m | Should Match 'one ```json code block'
        $m | Should Match 'Request: RUNBOOK BODY$'
    }
    Remove-Item $p -Recurse -Force
}
