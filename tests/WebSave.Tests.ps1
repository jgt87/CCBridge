# Web data saved into the project (ACTION web save:NAME), JSON tables, the Continue card for checks
# that are not met, and what the session report finds. No internet: the fetch is stood in for.
# Made-up sites and records.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-ws-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'WebFetch', 'DataImport', 'TaskNotes', 'SessionReport', 'Agent') { Import-Module (Join-Path $root "lib\$m.psm1") -Force -DisableNameChecking }

$global:wsFeed = ConvertTo-Json -Depth 6 -Compress -InputObject ([ordered]@{ updated = '2026-01-05'; items = @(1..300 | ForEach-Object { [ordered]@{ id = "A$_"; title = "Item $_"; products = @('Alpha', 'Beta'); score = $_ * 2; flags = [ordered]@{ user = $true } } }) })

Describe 'Saving web data into the project' {
    It 'picks the file type' {
        Get-WebSaveExtension 'application/json' 'https://x.example.com/api/items' '' | Should Be '.json'
        Get-WebSaveExtension 'text/plain' 'https://x.example.com/export.csv' '' | Should Be '.csv'
        Get-WebSaveExtension 'text/plain' 'https://x.example.com/api/items' '[{"a":1}]' | Should Be '.json'
        Get-WebSaveExtension 'text/html' 'https://x.example.com/' '<html>' | Should Be '.html'
    }
    It 'tells Copilot to save a response that does not fit' {
        Format-WebResult ([pscustomobject]@{ ok = $true; url = 'https://x.example.com/api/items'; type = 'application/json'; text = '[...'; chars = 30000; truncated = $true; source = $true; refs = @() }) | Should Match 'ACTION web save:NAME'
        Format-WebResult ([pscustomobject]@{ ok = $true; url = 'https://x.example.com/'; type = 'text/html'; text = 'short'; chars = 5 }) | Should Not Match 'web save'
    }
    It 'saves the whole response, converts it to a table at once and keeps the address for a refresh' {
        $p = Join-Path $env:TEMP ('ccb-ws-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        try {
            Mock -ModuleName Agent Invoke-WebFetch { [pscustomobject]@{ ok = $true; url = 'https://data.example.com/api/items'; type = 'application/json; charset=utf-8'; text = $global:wsFeed; chars = $global:wsFeed.Length; truncated = $false } }
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'; $s.TurnText = 'Use the data of https://data.example.com/api/items'
            $r = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'web'; arg = 'save:items'; body = 'https://data.example.com/api/items' }) 'w1' $null 0 } $s
            $r.output | Should Match '^Saved'
            $r.ok | Should Be $true
            $r.output | Should Match 'Saved https://data\.example\.com/api/items as Source/Web/items\.json'
            $r.output | Should Match 'converted to data/items\.json'
            $r.output | Should Match '300 rows; columns: id \(text\), title \(text\), products \(text\), score \(number\), flags \(text\)'
            Test-Path -LiteralPath (Join-Path $p 'Source\Web\items.json') | Should Be $true
            Test-Path -LiteralPath (Join-Path $p 'Scripts\Refresh-Web-Data.ps1') | Should Be $true
            # Taken in as source data: a command afterwards keeps it, it is not moved to Work/.
            Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force -DisableNameChecking
            @(Restore-SourceData $p).Count | Should Be 0
            Test-Path -LiteralPath (Join-Path $p 'Source\Web\items.json') | Should Be $true
            # A changed copy is put back, unless the helper program's own refresh wrote it (-Accept).
            [IO.File]::SetAttributes((Join-Path $p 'Source\Web\items.json'), 'Normal'); [IO.File]::WriteAllText((Join-Path $p 'Source\Web\items.json'), '[]')
            @(Restore-SourceData $p -Accept @('Source/Web/items.json')).Count | Should Be 0
            [IO.File]::ReadAllText((Join-Path $p 'Source\Web\items.json')) | Should Be '[]'
            [IO.File]::SetAttributes((Join-Path $p 'Source\Web\items.json'), 'Normal'); [IO.File]::WriteAllText((Join-Path $p 'Source\Web\items.json'), 'x')
            @(Restore-SourceData $p) -join ' ' | Should Match 'restored Source/Web/items.json'
            ([IO.File]::ReadAllText((Join-Path $p '.streamhub\web-saves.json')) | ConvertFrom-Json).url | Should Be 'https://data.example.com/api/items'
            $e = $null; $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $p 'Scripts\Refresh-Web-Data.ps1'), [ref]$null, [ref]$e); @($e).Count | Should Be 0
            { Save-WebData $p '../x' ([pscustomobject]@{ url = 'https://x'; type = 'text/plain'; text = 'x' }) } | Should Throw 'must start with a letter'
        } finally { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'JSON tables' {
    It 'finds the records in a list, an object holding one, or one level deeper' {
        (Get-JsonRecords (ConvertFrom-Json '[{"a":1},{"a":2}]')).path | Should Be ''
        (Get-JsonRecords (ConvertFrom-Json '{"meta":{"n":2},"items":[{"a":1},{"a":2}]}')).path | Should Be 'items'
        (Get-JsonRecords (ConvertFrom-Json '{"data":{"rows":[{"a":1}]}}')).path | Should Be 'data.rows'
        Get-JsonRecords (ConvertFrom-Json '["a","b"]') | Should BeNullOrEmpty
        Get-JsonRecords (ConvertFrom-Json '{"name":"x","size":3}') | Should BeNullOrEmpty
    }
    It 'turns records into typed rows: lists joined, nested objects as JSON, columns in first-seen order' {
        $recs = ConvertFrom-Json '[{"id":1,"tags":["x","y"],"ok":true},{"id":2,"extra":{"k":1},"tags":[]}]'   # assigned first: 5.1 hands a JSON array on as one object
        $rows = @(ConvertTo-JsonTableRows $recs)
        $rows[0] -join ',' | Should Be 'id,tags,ok,extra'
        $rows[1] -join '|' | Should Be '1|x; y|true|'
        $rows[2] -join '|' | Should Be '2||| {"k":1}'.Replace('| {', '|{')
    }
    It 'leaves JSON that is not a table as it is' {
        $f = Join-Path $env:TEMP ('ccb-js-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            [IO.File]::WriteAllText($f, '{ "name": "config", "size": 3 }')
            $r = ConvertFrom-DataFile $f
            @($r.sheets).Count | Should Be 0
            $r.json | Should Be '{ "name": "config", "size": 3 }'
        } finally { Remove-Item $f -Force }
    }
}

Describe 'Checks that are not met at done' {
    It 'gives the Continue card a message with each unmet check and the reason Copilot gave' {
        $t = Get-UnmetChecksContinue @(@{ check = 'The page shows every product'; met = $false; note = 'only two in the data' })
        $t | Should Match '^These checks you set for this task are not met yet:'
        $t | Should Match '- The page shows every product \(you said: only two in the data\)'
        $t | Should Match 'say why in one line'
    }
}

Describe 'What the session report finds' {
    It 'names unfinished tasks, approval waits and web reads cut off at the size limit' {
        $log = @(
            '2026-01-05 09:00:00.000 [ 70] INFO    agent    Queued q-1 (chat, from user) {"title":"Use the data of the site"}',
            '2026-01-05 09:00:01.000 [ 70] VERBOSE agent    action 5-0 web -> awaiting {"target":"https://x.example.com/api","error":null}',
            '2026-01-05 09:04:01.000 [ 70] INFO    web      Read a web page {"host":"x.example.com","truncated":true,"status":200,"chars":30000}',
            '2026-01-05 09:04:01.100 [ 70] VERBOSE agent    result 5-0 ok {"summary":"read 1 of 1 web page(s)"}',
            '2026-01-05 09:05:00.000 [ 70] INFO    agent    Queued q-2 (chat, from user) {"title":"continue"}'
        )
        $r = Get-SessionReport (Read-LogEntries $log 70)
        $r | Should Match '\*\*Did not finish: 2 task\(s\)\*\*'
        $r | Should Match '\*\*Waiting for approvals: 4 min in all\*\*'
        $r | Should Match '\*\*Web reads cut off at the size limit: 1\*\*'
        $r | Should Match 'waited 4 min for approvals; web reads: 1 \(1 cut off\)'
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
