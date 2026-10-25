# The helpers of the live on-demand test (tools/OnDemandTest.psm1): the approval rule, the setup-card
# answer, snapshots, the checks on what the features write, Copilot's record, the report, and the
# PowerPoint deck builder and package check. No running app is needed.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\tools\OnDemandTest.psm1') -Force
$script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('ondemand-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $script:Tmp

Describe 'Approval cards' {
    It 'approves only a write or edit of an expected file' {
        $d = Get-ApprovalDecision ([pscustomobject]@{ action = 'edit'; target = 'index.html:10-20'; status = 'awaiting' }) @('index.html')
        $d.decision | Should Be 'approve'
        $d.path | Should Be 'index.html'
        (Get-ApprovalDecision ([pscustomobject]@{ action = 'write'; target = 'Runbooks/sales-total.runbook.md' }) @('Runbooks/*.runbook.md')).decision | Should Be 'approve'
    }
    It 'takes the preview path when there is one' {
        $card = [pscustomobject]@{ action = 'write'; target = 'x'; preview = [pscustomobject]@{ path = 'Runbooks\Exports\project-overview.md' } }
        (Get-ApprovalDecision $card @('Runbooks/Exports/project-overview*.md')).decision | Should Be 'approve'
    }
    It 'denies a change to another file' {
        $d = Get-ApprovalDecision ([pscustomobject]@{ action = 'edit'; target = 'styles/app.css' }) @('index.html')
        $d.decision | Should Be 'reject'
        $d.reason | Should Match 'styles/app.css'
    }
    It 'never approves a run, a delete, a web read or a query, whatever is expected' {
        foreach ($a in 'run', 'delete', 'web', 'sql', 'remember') {
            (Get-ApprovalDecision ([pscustomobject]@{ action = $a; target = 'index.html' }) @('*')).decision | Should Be 'reject'
        }
        (Get-ApprovalDecision ([pscustomobject]@{ action = 'run'; target = 'npm test' }) @('*')).reason | Should Match 'never approves a run'
    }
    It 'denies a write when the step expects no file' {
        (Get-ApprovalDecision ([pscustomobject]@{ action = 'write'; target = 'notes.md' }) @()).reason | Should Match 'no file'
    }
}

Describe 'Setup cards' {
    It 'takes the first choice, but never one that holds the request back, and ticks nothing in a multi choice' {
        $card = '{"request":"r","choices":[{"id":"build","options":[{"value":"single"},{"value":"modular"}]},{"id":"sampledata","options":[{"value":"wait"},{"value":"sample"}]},{"id":"extras","multi":true,"options":[{"value":"export"}]},{"id":"bigtask","options":{"value":"plan"}}]}' | ConvertFrom-Json
        $a = Get-SetupAutoAnswer $card
        $a.build | Should Be 'single'
        $a.answers.sampledata | Should Be 'sample'
        $a.answers.extras | Should Be ''
        $a.answers.bigtask | Should Be 'plan'   # the only choice is still taken
        $a.answers.ContainsKey('build') | Should Be $false
    }
}

Describe 'Snapshots' {
    It 'finds added, removed and changed files and skips .streamhub' {
        $d = Join-Path $script:Tmp 'snap'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $d 'a'), (Join-Path $d '.streamhub')
        [IO.File]::WriteAllText((Join-Path $d 'a\one.txt'), '1')
        [IO.File]::WriteAllText((Join-Path $d 'two.txt'), '2')
        [IO.File]::WriteAllText((Join-Path $d '.streamhub\own.json'), '{}')
        $before = New-FileSnapshot $d
        $before.ContainsKey('.streamhub/own.json') | Should Be $false
        [IO.File]::WriteAllText((Join-Path $d 'a\one.txt'), '1b')
        Remove-Item -LiteralPath (Join-Path $d 'two.txt')
        [IO.File]::WriteAllText((Join-Path $d 'three.txt'), '3')
        [IO.File]::WriteAllText((Join-Path $d '.streamhub\own.json'), '{"x":1}')
        $diff = Compare-FileSnapshot $before (New-FileSnapshot $d)
        (@($diff.changed) -join ',') | Should Be 'a/one.txt'
        (@($diff.removed) -join ',') | Should Be 'two.txt'
        (@($diff.added) -join ',') | Should Be 'three.txt'
    }
    It 'sorts changed paths into expected, StreamHub''s own and other' {
        $s = Split-ChangedPaths @{ added = @('Runbooks/a.runbook.md', 'data/sales.json'); removed = @(); changed = @('index.html') } @('Runbooks/*.runbook.md') @('data/*.json')
        (@($s.expected) -join ',') | Should Be 'Runbooks/a.runbook.md'
        (@($s.ignored) -join ',') | Should Be 'data/sales.json'
        (@($s.other) -join ',') | Should Be 'index.html'
    }
}

Describe 'The project overview' {
    $written = "<!-- streamhub:project-overview (remove this line to keep your own changes) -->`n# P: project overview`n`n## What it is for`n`nTO BE WRITTEN: what it is for`n`n## Facts`n`n### Built from`n`n- 3 files.`n"
    It 'passes when only the sections were written' {
        $final = $written.Replace('TO BE WRITTEN: what it is for', 'A page with regional revenue.')
        $r = Test-OverviewResult $written $final
        $r.marker | Should Be $true
        @($r.placeholders).Count | Should Be 0
        $r.factsSame | Should Be $true
        $r.reason | Should Be ''
    }
    It 'names a placeholder left, a changed fact and a lost marker' {
        $final = $written.Replace('- 3 files.', '- three files.').Replace('<!-- streamhub:project-overview (remove this line to keep your own changes) -->', '# Overview')
        $r = Test-OverviewResult $written $final
        $r.marker | Should Be $false
        @($r.placeholders).Count | Should Be 1
        $r.factsSame | Should Be $false
        $r.reason | Should Match 'differs from line 5'
    }
    It 'says when the facts differ only in line endings' {
        $r = Test-OverviewResult $written $written.Replace("`n", "`r`n")
        $r.reason | Should Match 'line endings'
        (Get-OverviewFactsPart 'no facts here') | Should Be $null
    }
}

Describe 'Theme tokens' {
    $old = ":root {`n  --kit-accent: #2563eb;`n  --kit-radius: 6px;`n}`n"
    It 'accepts a change of colour values only, also a colour token added' {
        $t = Test-TokensColourOnly $old ($old.Replace('#2563eb', '#0d7c74').Replace('}', "  --kit-accent-2: hsl(175 60% 40%);`n}"))
        $t.ok | Should Be $true
        $t.changed | Should Be 1
        $t.added | Should Be 1
    }
    It 'refuses a size change, a removed token, other lines and no change at all' {
        (Test-TokensColourOnly $old $old.Replace('6px', '8px')).ok | Should Be $false
        (Test-TokensColourOnly $old $old.Replace("  --kit-radius: 6px;`n", '')).problems -join ';' | Should Match 'removed'
        (Test-TokensColourOnly $old $old.Replace(':root', '.dark').Replace('#2563eb', '#000000')).problems -join ';' | Should Match 'more than token values'
        (Test-TokensColourOnly $old $old).problems -join ';' | Should Match 'no colour token changed'
    }
}

Describe 'Reports the features write' {
    It 'finds the page report''s contrast note, date and number sections' {
        $md = "# Full page check`n`n## Contrast (WCAG AA) (1)`n`n- text 'Figures are provisional until' (p) is 1.7:1`n`n## Dates (1)`n`n- x`n`n## Numbers (1)`n`n- y`n"
        @(Test-PageReportText $md 'Figures are provisional').Count | Should Be 0
        (@(Test-PageReportText "## Dates (1)`n" 'x') -join ';') | Should Match 'no Contrast section'
        (@(Test-PageReportText $md.Replace('Figures', 'Totals') 'Figures are provisional') -join ';') | Should Match 'does not name'
    }
    It 'checks the data profile sections' {
        $md = "## Values far outside the rest`n`n| a |`n`n## Numbers mixed with text`n`nNone.`n`n## Duplicate rows`n`n1 row(s)`n"
        (@(Test-DataProfileReport $md) -join ';') | Should Be "'Numbers mixed with text' says None."
        (Get-MdSection $md 'Duplicate rows') | Should Be '1 row(s)'
        (Get-MdSection $md 'Missing') | Should Be $null
    }
    It 'checks a sharing zip''s entries' {
        @(Test-PackageEntries @('README-SHARING.md', 'index.html', 'data/sales.csv')).Count | Should Be 0
        $p = @(Test-PackageEntries @('.streamhub/issues.json', '.env', 'Source/notes.txt', 'index.html')) -join ';'
        $p | Should Match '\.streamhub'
        $p | Should Match '\.env'
        $p | Should Match 'Source'
        $p | Should Match 'README-SHARING'
    }
    It 'checks the tidy-up list' {
        $items = @([pscustomobject]@{ path = 'js/unused.js' }, [pscustomobject]@{ path = 'index.html' })
        $p = @(Test-TidyItems $items @('js/unused.js', 'Work/old.txt') @('index.html', '.env')) -join ';'
        $p | Should Match 'Work/old.txt is not listed'
        $p | Should Match 'index.html is listed'
        $p | Should Not Match '\.env'
        @(Test-TidyItems ([pscustomobject]@{ path = 'js/unused.js' }) @('js/unused.js') @()).Count | Should Be 0
    }
}

Describe 'Waiting for the app' {
    It 'is settled once the step''s own entries of this project have finished' {
        $q = @([pscustomobject]@{ id = 'q-old'; status = 'running'; projectRoot = 'C:\P' }, [pscustomobject]@{ id = 'q-new'; status = 'done'; projectRoot = 'C:\P\' }, [pscustomobject]@{ id = 'q-other'; status = 'running'; projectRoot = 'C:\Q' })
        $s = Test-QueueSettled $q @('q-old') 'C:\P'
        $s.settled | Should Be $true
        @($s.entries).Count | Should Be 1
        (Test-QueueSettled $q @('q-old', 'q-new') 'C:\P').settled | Should Be $false   # nothing of its own yet
        $q[1].status = 'awaiting'
        (Test-QueueSettled $q @('q-old') 'C:\P').pending | Should Be 1
    }
    It 'picks steps by -Only and refuses an unknown name' {
        (@(Resolve-OnlySteps @('a', 'b', 'c') @('c,a')) -join ',') | Should Be 'a,c'
        (@(Resolve-OnlySteps @('a', 'b') @()) -join ',') | Should Be 'a,b'
        { Resolve-OnlySteps @('a') @('x') } | Should Throw 'Unknown step'
    }
}

Describe 'What Copilot did, and the report' {
    $events = @(
        [pscustomobject]@{ type = 'kind'; taskKind = 'coding' }
        [pscustomobject]@{ type = 'assistant'; round = 1; text = 'secret reply text' }
        [pscustomobject]@{ type = 'action'; id = 'a1'; action = 'read'; status = 'running' }
        [pscustomobject]@{ type = 'action'; id = 'a1'; action = 'read'; status = 'done' }
        [pscustomobject]@{ type = 'action'; id = 'own-1'; action = 'write'; by = 'streamhub' }
        [pscustomobject]@{ type = 'assistant'; round = 2; text = 'more' }
        [pscustomobject]@{ type = 'action'; id = 'a2'; action = 'edit'; status = 'awaiting' }
        [pscustomobject]@{ type = 'action-result'; id = 'a3'; ok = $false; status = 'failed'; summary = 'edit refused: placeholder line' }
        [pscustomobject]@{ type = 'status'; text = 'Copilot read and searched but changed nothing' }
        [pscustomobject]@{ type = 'done'; text = ('Added a total row. ' * 30) }
    )
    $rec = Get-CopilotStepRecord $events
    It 'counts rounds and Copilot''s own actions once each' {
        $rec.rounds | Should Be 2
        $rec.actions['read'] | Should Be 1
        $rec.actions['edit'] | Should Be 1
        $rec.actions.Contains('write') | Should Be $false
        $rec.done | Should Be $true
        $rec.summary.Length | Should Be 200
        (@($rec.lines) -join ';') | Should Match 'refused or failed: edit refused'
        (@($rec.lines) -join ';') | Should Not Match 'secret reply'
    }
    It 'writes the report with the table, the Copilot part and the timings' {
        $md = Format-OnDemandReport @{ when = '2026-10-25 10:00'; version = 'v0.1.152'; project = 'C:\P'; copilotRan = $true
            checks = @(@{ step = 'coding'; check = 'index.html changed'; result = 'PASS'; reason = '' }, @{ step = 'tidy'; check = 'a | b'; result = 'FAIL'; reason = 'x' })
            steps = @(@{ name = 'coding'; seconds = 61.4; copilot = $rec; approvals = @('approved edit index.html') }, @{ name = 'tidy'; seconds = 3; copilot = $null }) }
        $md | Should Match '1 passed, 1 failed, 0 skipped'
        $md | Should Match '\| tidy \| a \\\| b \| FAIL \| x \|'
        $md | Should Match '### coding'
        $md | Should Match 'Actions: read 1, edit 1'
        $md | Should Match 'Approval: approved edit index.html'
        $md | Should Match '\| coding \| 61 \|'
    }
}

Describe 'PowerPoint decks' {
    $tpl = Join-Path $script:Tmp 'Decks\brand-template.pptx'
    $con = Join-Path $script:Tmp 'Decks\results.pptx'
    $info = New-OdtTestDecks -TemplatePath $tpl -ContentPath $con
    It 'builds a valid template and content deck' {
        $t = Test-PptxPackage $tpl
        @($t.problems).Count | Should Be 0
        $t.slides | Should Be $info.templateSlides
        $c = Test-PptxPackage $con
        @($c.problems).Count | Should Be 0
        $c.slides | Should Be 4
    }
    It 'puts a logo on the template''s master and its own fonts and accent in its theme' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($tpl)
        try {
            @($z.Entries | Where-Object { $_.FullName -eq 'ppt/media/logo1.png' }).Count | Should Be 1
            $r = New-Object IO.StreamReader(($z.Entries | Where-Object { $_.FullName -eq 'ppt/theme/theme1.xml' }).Open()); $theme = $r.ReadToEnd(); $r.Dispose()
        } finally { $z.Dispose() }
        $theme | Should Match 'Georgia'
        $theme | Should Match '0E7C86'
    }
    It 'reports a dangling relationship id, repeated slide ids and a file that is no package' {
        $bad = Join-Path $script:Tmp 'bad.pptx'
        $slide = '<p:sp><p:nvSpPr><p:cNvPr id="2" name="x"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp><p:pic><p:nvPicPr><p:cNvPr id="3" name="p"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId99"/></p:blipFill><p:spPr/></p:pic>'
        $null = New-OdtDeck -Path $bad -Layouts @(@{ name = 'Blank'; type = 'blank'; ph = @() }) -Slides @(@{ layout = 1; shapes = $slide }, @{ layout = 1; shapes = '' })
        $p = @((Test-PptxPackage $bad).problems) -join ';'
        $p | Should Match 'rId99 has no relationship'
        Add-Type -AssemblyName WindowsBase
        $pkg = [IO.Packaging.Package]::Open($bad, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
        try {
            $part = $pkg.GetPart((New-Object Uri('/ppt/presentation.xml', [UriKind]::Relative)))
            $s = $part.GetStream([IO.FileMode]::Open, [IO.FileAccess]::Read); $sr = New-Object IO.StreamReader($s); $x = $sr.ReadToEnd(); $sr.Dispose()
            $x = $x.Replace('id="257"', 'id="256"')
            $s = $part.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); $b = [Text.Encoding]::UTF8.GetBytes($x); $s.Write($b, 0, $b.Length); $s.Dispose()
        } finally { $pkg.Close() }
        (@((Test-PptxPackage $bad).problems) -join ';') | Should Match 'slide ids repeat'
        $notZip = Join-Path $script:Tmp 'not.pptx'; [IO.File]::WriteAllText($notZip, 'text')
        (@((Test-PptxPackage $notZip).problems) -join ';') | Should Match 'does not open'
    }
    It 'checks a plan: known layouts, and the free-heading slide marked or converted' {
        $plan = '{"layouts":["Cover","Title and text","Title only","Empty"],"start":1,"end":2,"slides":[{"index":1,"layout":"Cover","sure":true,"heading":0},{"index":2,"layout":"Title and text","sure":true,"heading":0},{"index":3,"layout":"Title only","sure":true,"heading":0},{"index":4,"layout":"Title only","sure":false,"heading":0}]}' | ConvertFrom-Json
        @(Test-PptxPlan $plan 4 4).Count | Should Be 0
        $plan.slides[3].sure = $true
        (@(Test-PptxPlan $plan 4 4) -join ';') | Should Match 'neither marked'
        $plan.slides[3].heading = 2
        @(Test-PptxPlan $plan 4 4).Count | Should Be 0
        $plan.slides[1].layout = 'Two Content'
        (@(Test-PptxPlan $plan 4 4) -join ';') | Should Match 'does not have'
        $c = New-PptxApplyChoices $plan
        $c.layouts['2'] | Should Be 'Two Content'
        $c.titles['4'] | Should Be 2
        $c.start | Should Be 1
        $c.end | Should Be 2
    }
    It 'checks the card filled from Copilot''s answer' {
        $plan = '{"copilot":true,"errors":[],"layouts":["Cover","Empty"],"slides":[{"index":1,"layout":"Cover","why":"Copilot"},{"index":2,"layout":"Empty","why":"same type"}]}' | ConvertFrom-Json
        @(Test-PptxAskPlan $plan 2).Count | Should Be 0
        $plan.slides[1].layout = 'Invented'
        $plan.copilot = $false
        $p = @(Test-PptxAskPlan $plan 1) -join ';'
        $p | Should Match 'unknown layout'
        $p | Should Match 'not in the content deck'
        $p | Should Match 'not marked'
    }
}

Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
