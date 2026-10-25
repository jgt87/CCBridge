# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests\ProjectOverviewFile.Tests.ps1
# The project overview for a colleague (lib/ProjectOverview.psm1): the facts by fixed rules, the file
# with its sections for Copilot, the replace-or-keep rule and the request that fills it.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# Project state (progress) of the test projects goes to a temporary folder, deleted below.
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
foreach ($m in 'ProjectOverview', 'Progress', 'Executor', 'Prompts') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'The app entry page' {
    It 'takes a build output before index.html at the root, as the app does' {
        Select-AppEntryPage @('index.html', 'dist/index.html', 'src/main.tsx') | Should Be 'dist/index.html'
        Select-AppEntryPage @('index.html', 'out/index.html', 'build/index.html') | Should Be 'build/index.html'
        Select-AppEntryPage @('index.html', 'src/app.js') | Should Be 'index.html'
    }
    It 'reads backslashes and any case, and gives nothing without an entry page' {
        Select-AppEntryPage @('Dist\Index.HTML') | Should Be 'dist/index.html'
        Select-AppEntryPage @('pages/index.html', 'docs/readme.md') | Should Be $null
        Select-AppEntryPage @() | Should Be $null
    }
}

Describe 'Project overview facts' {
    $proj = Join-Path $env:TEMP ('ccb-overview-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $state = Join-Path $env:CCBRIDGE_STATE_ROOT 'overview-state'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'src'), (Join-Path $proj 'dist'), (Join-Path $proj 'Scripts'), (Join-Path $proj 'Runbooks'), (Join-Path $proj '.streamhub'), (Join-Path $proj 'Source'), $state
    $enc = New-Object Text.UTF8Encoding($false)
    $write = { param($rel, $text) $p = Join-Path $proj $rel; $null = New-Item -ItemType Directory -Force -Path (Split-Path $p); [IO.File]::WriteAllText($p, $text, $enc) }
    & $write 'dist\index.html' "<!doctype html><script type=""module"" src=""./app.js""></script>"
    & $write 'src\app.js' "export const a = 1;`n"
    & $write 'Source\sales.csv' "region,amount`nNorth,10`n"
    & $write 'Scripts\Refresh-Data.ps1' "# refresh`n"
    & $write 'Scripts\Other.ps1' "# not a refresh script`n"
    & $write 'Runbooks\weekly.runbook.md' "---`ntitle: Weekly numbers`noutput: Runbooks/Exports/weekly.json`n---`nCollect the numbers.`n"
    & $write 'Runbooks\morning.chain.md' "---`ntitle: Morning report`n---`n1. runbook: weekly`n"
    & $write 'TODO.md' "# To do`n- [ ] Add a legend to the chart`n- [x] Done already`n"
    & $write '.streamhub\project.json' '{"build":"single","liveSource":"C:\\Users\\someone\\OneDrive\\Team\\live-sales.xlsx","chosenBy":"user","answers":{"language":"en"}}'
    & $write '.streamhub\data-imports.json' '{"version":1,"items":[{"output":"data/sales.json","source":"Source/sales.csv","sheets":[{"name":"","rows":1}]}]}'
    & $write '.streamhub\databases.json' '[{"name":"finance","server":"SQLPROD01.corp.example","database":"Ledger","trustCertificate":false}]'
    & $write '.streamhub\sharepoint.json' '{"sources":[{"kind":"file","spItemUrl":"https://contoso.sharepoint.com/_api/v2.0/drives/b!x/items/01","fileName":"Budget.xlsx","label":"Budget.xlsx"}],"site":"","page":""}'
    & $write '.streamhub\schedules.json' '[{"id":"s-1","title":"Morning report","kind":"chain","name":"morning","repeat":"daily","times":["08:00"],"enabled":true}]'
    Add-ProgressEntry $state (New-ProgressEntry -Request "Build the sales page from $env:USERPROFILE\Documents\x.csv" -Status 'done' -Result "Built the page.`nMore text." -Changed @('index.html'))

    $facts = Get-ProjectOverviewFacts $proj '' $state
    $text = Format-ProjectOverviewFacts $facts

    It 'names what the project is built from and how to open it' {
        $facts.entry | Should Be 'dist/index.html'
        $facts.entryModule | Should Be $true
        $text | Should Match 'Open dist/index.html'
        $text | Should Match 'works from a web server'
        $text | Should Match 'One HTML file with everything in it'
    }
    It 'lists the data, the refresh scripts and the automation by name' {
        $text | Should Match 'Source/sales.csv \(1 rows\), converted to data/sales.json'
        $text | Should Match 'Live data: live-sales\.xlsx'
        $text | Should Match 'From SharePoint: Budget\.xlsx'
        $text | Should Match 'Database connection: finance'
        $text | Should Match 'Scripts/Refresh-Data\.ps1'
        $text | Should Not Match 'Other\.ps1'
        $text | Should Match 'Runbook weekly: Weekly numbers'
        $text | Should Match 'Chain morning: Morning report \(1 step'
        $text | Should Match 'Schedule: Morning report, Every day at 08:00'
    }
    It 'says what earlier tasks did and what is still open' {
        $text | Should Match 'done: Build the sales page'
        $text | Should Match 'Result: Built the page\.'
        $text | Should Match 'Add a legend to the chart \(TODO\.md\)'
        $text | Should Not Match 'Done already'
    }
    It 'leaves out connection details and personal paths' {
        $text | Should Not Match 'SQLPROD01'
        $text | Should Not Match 'Ledger'
        $text | Should Not Match 'someone'
        $text | Should Not Match 'OneDrive\\Team'
        $text | Should Not Match ([regex]::Escape($env:USERPROFILE))
        $text | Should Not Match 'sharepoint\.com'
    }
    It 'says whether the pages use the UI kit' {
        $text | Should Match "Does not use StreamHub's UI kit"
        & $write 'styles\kit\tokens.css' ":root { --kit-accent: #000; }`n"
        $t = Format-ProjectOverviewFacts (Get-ProjectOverviewFacts $proj $root $state)
        $t | Should Match "Built with StreamHub's UI kit \(styles/kit/\)"
    }
    It 'still gives the other facts when one part cannot be read' {
        & $write '.streamhub\schedules.json' 'not json'
        $t = Format-ProjectOverviewFacts (Get-ProjectOverviewFacts $proj '' $state)
        $t | Should Match 'No runbooks, chains or schedules|Runbook weekly'
        $t | Should Match 'Open dist/index.html'
    }

    Remove-Item -Recurse -Force $proj
}

Describe 'The overview file' {
    $proj = Join-Path $env:TEMP ('ccb-overview-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $state = Join-Path $env:CCBRIDGE_STATE_ROOT 'overview-file-state'
    $null = New-Item -ItemType Directory -Force -Path $proj, $state
    [IO.File]::WriteAllText((Join-Path $proj 'index.html'), '<!doctype html><title>x</title>')
    $now = [datetime]'2026-10-25T09:30:00'

    It 'is written with the three sections to fill, then the facts' {
        $r = Write-ProjectOverview $proj '' $state $now
        $r.rel | Should Be 'Runbooks/Exports/project-overview.md'
        $r.exists | Should Be $false
        $r.kept | Should Be ''
        $t = [IO.File]::ReadAllText($r.full)
        $t | Should Match '^<!-- streamhub:project-overview'
        foreach ($s in Get-OverviewSections) { $t | Should Match ([regex]::Escape("## $($s.heading)`n`n$($s.placeholder)")) }
        $t.IndexOf('## Facts') | Should BeGreaterThan $t.IndexOf('TO BE WRITTEN: things to know')
        $t | Should Not Match 'CCBridge'
    }
    It 'has placeholder lines an ordinary edit replaces' {
        $edits = @(Get-OverviewSections | ForEach-Object { @{ search = $_.placeholder; replace = "Filled: $($_.heading)." } })
        $res = Get-EditResult $proj 'Runbooks/Exports/project-overview.md' $edits
        $res.ok | Should Be $true
        $res.new | Should Match 'Filled: What it is for\.'
        $res.new | Should Not Match 'TO BE WRITTEN'
        $res.new | Should Match '## Facts'
        [IO.File]::WriteAllText($res.full, $res.new)
    }
    It 'replaces its own earlier overview, also once Copilot filled it' {
        $r = Write-ProjectOverview $proj '' $state $now
        $r.rel | Should Be 'Runbooks/Exports/project-overview.md'
        $r.exists | Should Be $true
        $r.old | Should Match 'Filled: What it is for'
        [IO.File]::ReadAllText($r.full) | Should Match 'TO BE WRITTEN: what it is for'
    }
    It "keeps a person's version (marker removed) and writes the new one next to it" {
        $f = Join-Path $proj 'Runbooks\Exports\project-overview.md'
        [IO.File]::WriteAllText($f, "# My own overview`n")
        $r = Write-ProjectOverview $proj '' $state $now
        $r.kept | Should Be 'Runbooks/Exports/project-overview.md'
        $r.rel | Should Be 'Runbooks/Exports/project-overview-20261025-0930.md'
        [IO.File]::ReadAllText($f) | Should Be "# My own overview`n"
        Test-OwnOverview $r.full | Should Be $true
        # The same minute again: the stamped file is its own, so it is replaced, not numbered.
        (Write-ProjectOverview $proj '' $state $now).rel | Should Be 'Runbooks/Exports/project-overview-20261025-0930.md'
    }

    Remove-Item -Recurse -Force $proj
}

Describe 'The request that fills the overview' {
    $req = Get-ProjectOverviewRequest 'Runbooks/Exports/project-overview.md'

    It 'goes to Copilot as project work that changes a file' {
        Get-TaskKind $req | Should Match '^(project|coding)$'
        Get-TaskKind $req @('code') @('index.html', 'Runbooks/Exports/project-overview.md') | Should Match '^(project|coding)$'
        Get-TaskIntent $req | Should Be 'change'
    }
    It 'names the file, every placeholder, and keeps the facts' {
        $req | Should Match 'Runbooks/Exports/project-overview\.md'
        foreach ($s in Get-OverviewSections) { $req | Should Match ([regex]::Escape($s.placeholder)) }
        $req | Should Match 'Facts section stay'
        $req | Should Not Match 'CCBridge'
    }
    It 'is never taken as a runbook to run' {
        Import-Module (Join-Path $root 'lib\Runbook.psm1') -Force
        Get-RunbookRunRequest $req @([pscustomobject]@{ name = 'overview'; title = 'Project overview'; path = 'Runbooks/overview.runbook.md' }) | Should Be $null
    }
}

Remove-Item -Recurse -Force $env:CCBRIDGE_STATE_ROOT -ErrorAction SilentlyContinue
