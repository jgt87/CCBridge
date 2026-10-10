# Project setup (lib/ProjectSetup.psm1, lib/OneFile.psm1): the questions StreamHub asks before a new
# project's first request goes to Copilot (a fixed rule on the request and the files), the saved
# choice, one-file pages whose UI kit and data blocks the helper program fills (and Copilot never
# sees or edits), and a live data file outside the project copied in when it changes. Made-up data.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'UiKit', 'DataImport', 'OneFile', 'ProjectSetup', 'Executor', 'Lint', 'Guardrails', 'Prompts') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

function New-SetupProject([switch]$WithData) {
    $p = Join-Path $env:TEMP ('ccb-setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory (Join-Path $p 'Source') -Force | Out-Null
    if ($WithData) { [IO.File]::WriteAllText((Join-Path $p 'Source\sales.csv'), "region,amount`nNorth,10`nSouth,25`n") }
    $p
}

$script:OnePage = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Sales</title>
<style data-streamhub="kit"></style>
</head><body class="kit-page">
<header class="kit-header kit-header--band"><div class="kit-container"><h1 class="kit-header__title">Sales</h1>
<button class="kit-btn kit-btn--ghost kit-btn--icon" type="button" data-kit-theme aria-label="Switch the theme"><span data-kit-icon="moon" aria-hidden="true"></span></button></div></header>
<main class="kit-container"><div class="kit-chart" id="regions" aria-label="Sales per region"></div></main>
<script data-streamhub="kit"></script>
<script data-streamhub="data" data-source="Source/sales.csv"></script>
<script>
KitCharts.barlist(document.getElementById("regions"), { items: salesData.map(function (r) { return { label: r.region, value: r.amount }; }) });
</script>
</body></html>
'@

Describe 'When StreamHub asks how a project is built (Get-SetupQuestions)' {
    $paths = @('Source/sales.csv')
    It 'asks for "<text>"' -TestCases @(
        @{ text = 'Build a dashboard from the sales CSV' },
        @{ text = 'Create an overview page of the license holders' },
        @{ text = 'make me a report with charts of Source/sales.csv' },
        @{ text = 'Maak een dashboard van de verkoopcijfers' }
    ) {
        param($text)
        $q = Get-SetupQuestions $text $paths @{ build = '' }
        $q | Should Not BeNullOrEmpty
        @($q.questions)[0].id | Should Be 'build'
        @(@($q.questions)[0].options | ForEach-Object { $_.value }) -join ',' | Should Be 'single,modular,copilot'
        $q.live | Should Be $true
    }
    It 'does not ask for "<text>"' -TestCases @(
        @{ text = 'What is in the sales file?' },
        @{ text = 'Summarise the sales per region' },
        @{ text = 'Build a dashboard from the sales CSV as one html file' },
        @{ text = 'Build a dashboard with separate files for the styles and scripts' },
        @{ text = 'Create a dashboard, all in one file please' },
        @{ text = 'Make the report modular' }
    ) {
        param($text)
        Get-SetupQuestions $text $paths @{ build = '' } | Should BeNullOrEmpty
    }
    It 'does not ask once the project has a build form or code of its own' {
        Get-SetupQuestions 'Build a dashboard' $paths @{ build = 'single' } | Should BeNullOrEmpty
        Get-SetupQuestions 'Build a dashboard' @('Source/sales.csv', 'index.html') @{ build = '' } | Should BeNullOrEmpty
        # StreamHub's own kit and data files are not the project's code.
        Get-SetupQuestions 'Build a dashboard' @('Source/sales.csv', 'styles/kit/tokens.css', 'data/sales.js', 'data/data-tools.js') @{ build = '' } | Should Not BeNullOrEmpty
    }
    It 'offers live data only with data, and suggests a path the request names' {
        (Get-SetupQuestions 'Build a dashboard of our team' @() @{ build = '' }).live | Should Be $false
        $q = Get-SetupQuestions 'Build a dashboard from C:\Users\Someone\Company\Site - Documents\licences.csv' @() @{ build = '' }
        $q.live | Should Be $true
        $q.suggest | Should Be 'C:\Users\Someone\Company\Site - Documents\licences.csv'
    }
    It 'reads the build form a request names itself' {
        Get-StatedBuild 'put everything in a single HTML file' | Should Be 'single'
        Get-StatedBuild 'a self-contained file I can mail' | Should Be 'single'
        Get-StatedBuild 'with a styles.css and a script file' | Should Be 'modular'
        Get-StatedBuild 'Build a dashboard' | Should Be ''
    }
}

Describe 'The saved project setup' {
    It 'keeps the build form and the live data file, and ignores an unknown form' {
        $p = New-SetupProject
        try {
            (Get-ProjectSetup $p).build | Should Be ''
            $null = Save-ProjectSetup $p @{ build = 'single'; chosenBy = 'user' }
            (Get-ProjectSetup $p).build | Should Be 'single'
            Test-Path (Join-Path $p '.streamhub\project.json') | Should Be $true
            $null = Save-ProjectSetup $p @{ build = 'giant' }
            (Get-ProjectSetup $p).build | Should Be ''
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'is named to Copilot in the project context' {
        $p = New-SetupProject
        try {
            Format-ProjectSetupContext $p | Should Be ''
            $null = Save-ProjectSetup $p @{ build = 'single'; liveSource = 'C:\Data\licences.csv' }
            $t = Format-ProjectSetupContext $p
            $t | Should Match 'Build form: one HTML file'
            $t | Should Match 'Live data: Source/Live/licences\.csv is a copy of a file outside the project'
            $t | Should Match 'never put the outside path in the page'
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Live data from a file outside the project' {
    It 'accepts only a full path to an existing data file outside the project' {
        $p = New-SetupProject -WithData
        $out = Join-Path $env:TEMP ('ccb-live-' + [guid]::NewGuid().ToString('N') + '.csv')
        try {
            [IO.File]::WriteAllText($out, "a,b`n1,2`n")
            Test-LiveSourcePath $out $p | Should Be ''
            Test-LiveSourcePath 'data\x.csv' $p | Should Match 'not a full path'
            Test-LiveSourcePath ($out + '.txt') $p | Should Match 'not a CSV'
            Test-LiveSourcePath ($out -replace '\.csv$', '-gone.csv') $p | Should Match 'was not found'
            Test-LiveSourcePath (Join-Path $p 'Source\sales.csv') $p | Should Match 'already in the project'
        } finally { Remove-Item $p -Recurse -Force; Remove-Item $out -Force -ErrorAction SilentlyContinue }
    }
    It 'copies the file into Source/Live/ when it changes, never writing to it' {
        $p = New-SetupProject
        $out = Join-Path $env:TEMP ('ccb-live-' + [guid]::NewGuid().ToString('N') + '.csv')
        try {
            [IO.File]::WriteAllText($out, "name,team`nAnn,North`n")
            $before = (Get-Item $out).LastWriteTimeUtc
            Sync-LiveSource $p | Should BeNullOrEmpty   # no live file chosen
            $null = Save-ProjectSetup $p @{ liveSource = $out }
            $r = Sync-LiveSource $p
            $r.changed | Should Be $true
            $r.rel | Should Be ('Source/Live/' + [IO.Path]::GetFileName($out))
            [IO.File]::ReadAllText((Join-Path $p $r.rel.Replace('/', '\'))) | Should Match 'Ann,North'
            (Sync-LiveSource $p).changed | Should Be $false
            [IO.File]::WriteAllText($out, "name,team`nAnn,North`nBob,South`n")
            (Get-Item $out).LastWriteTimeUtc = $before.AddMinutes(1)
            (Sync-LiveSource $p).changed | Should Be $true
            [IO.File]::ReadAllText((Join-Path $p $r.rel.Replace('/', '\'))) | Should Match 'Bob,South'
            Remove-Item $out -Force
            $gone = Sync-LiveSource $p
            $gone.missing | Should Be $true
            Test-Path (Join-Path $p $r.rel.Replace('/', '\')) | Should Be $true   # the last copy stays
        } finally { Remove-Item $p -Recurse -Force; Remove-Item $out -Force -ErrorAction SilentlyContinue }
    }
    It 'writes a refresh script for when StreamHub is closed: ASCII, parses, stops on errors' {
        $p = New-SetupProject
        try {
            Write-RefreshScript $p $root | Should Be 'Scripts/Refresh-Data.ps1'
            Write-RefreshScript $p $root | Should Be ''   # already current
            $f = Join-Path $p 'Scripts\Refresh-Data.ps1'
            @([IO.File]::ReadAllBytes($f) | Where-Object { $_ -gt 127 }).Count | Should Be 0
            $e = $null; $null = [Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
            @($e).Count | Should Be 0
            $t = [IO.File]::ReadAllText($f)
            $t | Should Match "\`$ErrorActionPreference = 'Stop'"
            $t | Should Match 'Invoke-LiveRefresh'
            Invoke-LiveRefresh $p $root | Should Be 'This project has no live data file.'
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'One-file pages (OneFile.psm1)' {
    $filled = "<html><head><style data-streamhub=`"kit`">`n.kit-btn { color: red; }`n.kit-x { }`n</style></head><body>`n<p>Hi</p>`n<script data-streamhub=`"data`" data-source=`"Source/a.csv`">window.aData = [1,2];</script>`n<script>go();</script></body></html>"
    It 'shows each filled block as a one-line note, keeping the line numbers' {
        $h = Hide-GeneratedBlocks $filled
        ($h -split "`n").Count | Should Be ($filled -split "`n").Count
        $h | Should Not Match 'color: red|aData = \[1'
        $h | Should Match "the UI kit's styles this page uses: written by the helper program"
        $h | Should Match 'the rows of Source/a\.csv: written by the helper program'
        $h | Should Match '<script>go\(\);</script>'
        Hide-GeneratedBlocks '<p>plain page</p>' | Should Be '<p>plain page</p>'
    }
    It 'refuses an edit that changes a block, and allows edits to the rest of the page' {
        Find-BlockEdit $filled ($filled.Replace('[1,2]', '[3]')) | Should Match "data block for Source/a\.csv"
        Find-BlockEdit $filled ($filled.Replace('<p>Hi</p>', '<p>Hello</p>')) | Should Be ''
        Find-BlockEdit $filled ($filled.Replace('color: red', 'color: blue')) | Should Match 'UI kit style block'
    }
    It 'reports a one-file page that loads a project file, not one that links another site' {
        $old = '<html><head><style data-streamhub="kit"></style></head><body></body></html>'
        Find-OneFileLoads 'index.html' $old ($old.Replace('</head>', '<link rel="stylesheet" href="css/app.css"></head>')) | Should Match 'loads css/app\.css'
        Find-OneFileLoads 'index.html' $old ($old.Replace('</body>', '<script src="https://example.org/x.js"></script></body>')) | Should BeNullOrEmpty
        Find-OneFileLoads 'index.html' '<html></html>' '<html><link rel="stylesheet" href="css/app.css"></html>' | Should BeNullOrEmpty   # not a one-file page
    }
    It 'keeps the blocks out of the file checks and the quality checks' {
        $page = "<html><head><meta charset=`"utf-8`"></head><body>`n<script data-streamhub=`"kit`">`nfunction show() {}`nfunction show() {}`n</script>`n<script>var a = 1;</script></body></html>"
        @(Test-FileContent 'index.html' $page) | Should BeNullOrEmpty
        @(Find-QualityIssues 'index.html' '' $page -UseKit) | Should BeNullOrEmpty
    }
}

Describe 'Filling one-file pages (Update-OneFilePages)' {
    It 'fills the kit and data blocks from the project, and Copilot sees and searches only the page' {
        $p = New-SetupProject -WithData
        try {
            $null = Install-UiKit $p $root
            $null = Update-DataImports $p -JsCopy $true -AppRoot $root
            [IO.File]::WriteAllText((Join-Path $p 'index.html'), $script:OnePage)
            $r = Update-OneFilePages $p $root -NoCheckpoint
            @($r.files) -join ',' | Should Be 'index.html'
            $t = [IO.File]::ReadAllText((Join-Path $p 'index.html'))
            $t | Should Match '--kit-accent'                       # the project's tokens
            $t | Should Match '\.kit-header--band'                 # the rules of the classes in use
            $t | Should Not Match '\.kit-dialog \{'                # not the rules of classes not in use
            $t | Should Match 'function barlist'                   # the charts it calls
            $t | Should Match 'function setupTheme'                # kit.js for the theme switch
            $t | Should Match '"sun"'                              # the icon the switch turns to
            $t | Should Match 'window\.salesData = '
            @(Update-OneFilePages $p $root -NoCheckpoint).files | Should BeNullOrEmpty   # nothing new
            (Invoke-ReadAction $p @('index.html')) -join "`n" | Should Match 'not shown here, never edit these lines'
            (Invoke-ReadAction $p @('index.html')) -join "`n" | Should Not Match 'function barlist'
            Invoke-GrepAction $p 'barlist' 'index.html' | Should Match '^index\.html:\d+: KitCharts\.barlist'
            # A change Copilot sends for the page itself goes in; one into a block is refused.
            $ok = Get-EditResult $p 'index.html' @(@{ search = '<title>Sales</title>'; replace = '<title>Sales per region</title>' })
            $ok.ok | Should Be $true
            $bad = Get-EditResult $p 'index.html' @(@{ search = 'window.salesData = '; replace = 'window.other = ' })
            $bad.ok | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'writes data that cannot end its script block, names another global, and says what is missing' {
        $p = New-SetupProject
        try {
            [IO.File]::WriteAllText((Join-Path $p 'Source\notes.csv'), "id,text`n1,</script><b>x</b>`n")
            $null = Update-DataImports $p -JsCopy $true -AppRoot $root
            [IO.File]::WriteAllText((Join-Path $p 'page.html'), "<html><body>`n<script data-streamhub=`"data`" data-source=`"Source/notes.csv`" data-global=`"rows`"></script>`n<script data-streamhub=`"data`" data-source=`"Source/gone.csv`"></script>`n</body></html>")
            $r = Update-OneFilePages $p $root -NoCheckpoint
            $t = [IO.File]::ReadAllText((Join-Path $p 'page.html'))
            $t | Should Match 'window\.rows = '
            ([regex]::Matches($t, '</script>')).Count | Should Be 2
            @($r.notes) -join ' ' | Should Match "no data file 'Source/gone\.csv'"
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'What Copilot is told for each build form' {
    $ctx = @{ Traits = @('web'); Paths = @('index.html'); Build = 'single'; Live = $true }
    It 'sends the one-file and live rules with a project set up that way' {
        $ids = @(Get-PromptModules 'Add a chart of the regions' $ctx)
        $ids -contains 'rules:build-single' | Should Be $true
        $ids -contains 'rules:build-live' | Should Be $true
        @(Get-PromptModules 'Add a chart' @{ Traits = @('web'); Paths = @('index.html'); Build = 'modular' }) -contains 'rules:build-modular' | Should Be $true
        @(Get-PromptModules 'Add a chart' @{ Traits = @('web'); Paths = @('index.html'); Build = '' }) -match '^rules:build-' | Should BeNullOrEmpty
    }
    It 'leaves the split-into-files lines out of the web rules for a one-file project' {
        $single = & (Get-Module Prompts) { param($r, $c) Get-PromptPart $r 'rules:web' $c } $root $ctx
        $single | Should Not Match 'one part per file'
        $single | Should Not Match 'Put data in a \.js file'
        $modular = & (Get-Module Prompts) { param($r, $c) Get-PromptPart $r 'rules:web' $c } $root @{ Build = 'modular' }
        $modular | Should Match 'one part per file'
    }
    It 'describes the blocks in the one-file rule and in the kit rule' {
        $rule = [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\build-single.md'))
        $rule | Should Match '<style data-streamhub="kit"></style>'
        $rule | Should Match '<script data-streamhub="data" data-source="SOURCE PATH"></script>'
        $rule | Should Match 'never put those lines'
        $kit = & (Get-Module Prompts) { param($r, $c) Get-PromptPart $r 'rules:uikit' $c } $root $ctx
        $kit | Should Match 'One-file page: the kit reaches the page through its data-streamhub="kit" blocks'
        [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\build-live.md')) | Should Match 'Never put the outside path in the page'
    }
    It 'tells a one-file page how to take the data instead of loading files' {
        $p = New-SetupProject -WithData
        try {
            $null = Update-DataImports $p -JsCopy $true -AppRoot $root
            $one = Format-DataImportContext $p -OneFile
            $one | Should Match 'in a one-file page: window\.salesData'
            $one | Should Match '<script data-streamhub="data" data-source="SOURCE PATH"></script> \(for example data-source="Source/sales\.csv"\)'
            $one | Should Not Match 'DataTools\.load'
            Format-DataImportContext $p | Should Match 'DataTools\.load'
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Asking in the chat (Agent Publish-SetupQuestions, Save-SetupAnswer)' {
    Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
    It 'asks before the first request of a new project, then saves the answer' {
        $p = New-SetupProject -WithData
        try {
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p
            Publish-SetupQuestions $s @{ kind = 'chat'; text = 'Build a dashboard from the sales CSV'; clarify = $true } | Should Be $true
            $card = @(@($s.Events) | Where-Object { $_.type -eq 'setup-choice' })[0]
            $card.request | Should Be 'Build a dashboard from the sales CSV'
            $card.live | Should Be $true
            $card.clarify | Should Be $true
            Save-SetupAnswer $s @{ build = 'single'; liveSource = '' }
            (Get-ProjectSetup $p).build | Should Be 'single'
            (Get-ProjectSetup $p).chosenBy | Should Be 'user'
            Publish-SetupQuestions $s @{ kind = 'chat'; text = 'Build another dashboard' } | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'saves a form the request names without asking, and refuses a live path that is not there' {
        $p = New-SetupProject -WithData
        try {
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p
            # The build form is saved from the request itself; other questions the data triggers (personal details) may still come, never the build one.
            $asked = Publish-SetupQuestions $s @{ kind = 'chat'; text = 'Build a dashboard as a single html file' }
            (Get-ProjectSetup $p).build | Should Be 'single'
            if ($asked) { @(@(@($s.Events) | Where-Object { $_.type -eq 'setup-choice' })[-1].choices | Where-Object { $_.id -eq 'build' }).Count | Should Be 0 }
            (Get-ProjectSetup $p).chosenBy | Should Be 'request'
            Save-SetupAnswer $s @{ build = 'modular'; liveSource = 'C:\nowhere\gone.csv' }
            (Get-ProjectSetup $p).liveSource | Should Be ''
            @(@($s.Events) | Where-Object { $_.type -eq 'status' -and $_.text -match 'live data file was not set' }).Count | Should Be 1
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Describe 'The setup in the API (Server /api/chat setup, /api/project-setup)' {
    Import-Module (Join-Path $root 'lib\Server.psm1') -Force
    # A request as HttpListener gives it, and a response that keeps what was sent.
    function New-FakeCtx([string]$Method, [string]$Path, $Body, [string]$Origin) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($(if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 5 } else { '' }))
        $res = [pscustomobject]@{ StatusCode = 200; ContentType = ''; Headers = @{}; ContentLength64 = 0; OutputStream = (New-Object IO.MemoryStream) }
        $res | Add-Member -MemberType ScriptMethod -Name Close -Value { }
        [pscustomobject]@{
            Request = [pscustomobject]@{ HttpMethod = $Method; Url = [Uri]"http://localhost:8765$Path"; Headers = @{ Origin = $Origin }; InputStream = (New-Object IO.MemoryStream(, $bytes)); QueryString = @{} }
            Response = $res
        }
    }
    function Invoke-FakeApi($Ctx, $State) { & (Get-Module Server) { param($c, $st) Invoke-ApiRequest $c $st } $Ctx $State }
    function Get-FakeJson($Ctx) { [Text.Encoding]::UTF8.GetString($Ctx.Response.OutputStream.ToArray()) | ConvertFrom-Json }
    $page = 'http://localhost:8765'
    It 'takes the setup answer with a chat message only from the StreamHub page' {
        $p = New-SetupProject -WithData
        try {
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p; $s.Config.port = 8765
            Invoke-FakeApi (New-FakeCtx 'POST' '/api/chat' @{ text = 'Build a dashboard'; setup = @{ build = 'single'; liveSource = 'C:\Data\x.csv' } } $page) $s
            $t = $null; $null = $s.Tasks.TryDequeue([ref]$t)
            $t.setup.build | Should Be 'single'
            $t.setup.liveSource | Should Be 'C:\Data\x.csv'
            Invoke-FakeApi (New-FakeCtx 'POST' '/api/chat' @{ text = 'Build a dashboard'; setup = @{ build = 'single'; liveSource = 'C:\Data\x.csv' } } 'http://elsewhere.example') $s
            $t = $null; $null = $s.Tasks.TryDequeue([ref]$t)
            $t.setup | Should BeNullOrEmpty
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'gives a served page the live file as it is now, on every load' {
        $p = New-SetupProject
        $out = Join-Path $env:TEMP ('ccb-live-' + [guid]::NewGuid().ToString('N') + '.csv')
        try {
            [IO.File]::WriteAllText($out, "name`nAnn`n")
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p
            $null = Save-ProjectSetup $p @{ build = 'modular'; liveSource = $out }
            $rel = 'Source/Live/' + [IO.Path]::GetFileName($out)
            $serve = { $c = New-FakeCtx 'GET' "/preview/x/$rel" $null $page; & (Get-Module Server) { param($c, $st, $r) Send-PreviewFile $c $st $r } $c $s $rel; [Text.Encoding]::UTF8.GetString($c.Response.OutputStream.ToArray()) }
            & $serve | Should Match 'Ann'
            [IO.File]::WriteAllText($out, "name`nAnn`nBob`n")
            (Get-Item $out).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(1)
            & $serve | Should Match 'Bob'   # a reload, after the file changed: the new rows
            Format-ProjectSetupContext $p | Should Match ([regex]::Escape("DataTools.load(`"$rel`")"))
        } finally { Remove-Item $p -Recurse -Force; Remove-Item $out -Force -ErrorAction SilentlyContinue }
    }
    It 'shows and changes the project setup, only from the page, and checks a live path' {
        $p = New-SetupProject -WithData
        $out = Join-Path $env:TEMP ('ccb-live-' + [guid]::NewGuid().ToString('N') + '.csv')
        try {
            [IO.File]::WriteAllText($out, "a,b`n1,2`n")
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p; $s.Config.port = 8765
            $c = New-FakeCtx 'GET' '/api/project-setup' $null $page; Invoke-FakeApi $c $s
            (Get-FakeJson $c).setup.build | Should Be ''
            $c = New-FakeCtx 'POST' '/api/project-setup' @{ build = 'modular' } 'http://elsewhere.example'; Invoke-FakeApi $c $s
            $c.Response.StatusCode | Should Be 403
            $c = New-FakeCtx 'POST' '/api/project-setup' @{ build = 'modular'; liveSource = $out } $page; Invoke-FakeApi $c $s
            $c.Response.StatusCode | Should Be 200
            $j = (Get-FakeJson $c).setup
            $j.build | Should Be 'modular'
            $j.live.copy | Should Be ('Source/Live/' + [IO.Path]::GetFileName($out))
            Test-Path (Join-Path $p 'Scripts\Refresh-Data.ps1') | Should Be $true
            $c = New-FakeCtx 'POST' '/api/project-setup' @{ liveSource = 'relative\x.csv' } $page; Invoke-FakeApi $c $s
            $c.Response.StatusCode | Should Be 400
            (Get-FakeJson $c).error | Should Match 'not a full path'
            $c = New-FakeCtx 'POST' '/api/project-setup' @{ liveSource = '' } $page; Invoke-FakeApi $c $s
            (Get-ProjectSetup $p).liveSource | Should Be ''
        } finally { Remove-Item $p -Recurse -Force; Remove-Item $out -Force -ErrorAction SilentlyContinue }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
