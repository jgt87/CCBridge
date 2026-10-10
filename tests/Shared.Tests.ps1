# The shared library beside the projects (<projects folder>\.streamhub, read by Copilot as shared/...):
# one central UI kit catalogue every project pulls from (Workspace Get-SharedRoot, UiKit), shared
# instructions, runbooks, chains, scripts and data tools. Made-up project content.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Config', 'Workspace', 'Executor', 'UiKit', 'Runbook', 'Fetch', 'Chain', 'DataImport', 'Prompts') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

$base = Join-Path $env:TEMP ('ccb-shared-' + [guid]::NewGuid().ToString('N'))
$shared = Join-Path $base '.streamhub'
$p1 = Join-Path $base 'P1'; $p2 = Join-Path $base 'P2'; $p3 = Join-Path $base 'P3'
foreach ($d in $shared, $p1, $p2, $p3) { New-Item -ItemType Directory -Force $d | Out-Null }
$utf8 = New-Object Text.UTF8Encoding($false)

Describe 'The shared library beside the projects' {
    It 'is the .streamhub folder next to the project, read as shared/ and never written' {
        Get-SharedRoot $p1 | Should Be $shared
        Get-SharedRoot (Join-Path $env:TEMP 'ccb-nowhere\P') | Should Be $null
        Resolve-ProjectPath $p1 'shared/ui-kit/kit.css' | Should Be (Join-Path $shared 'ui-kit\kit.css')
        { Resolve-ProjectPath $p1 'shared/../P2/index.html' } | Should Throw
        { Assert-Writable $p1 'shared/AGENTS.md' } | Should Throw
        ConvertTo-RelativePath $p1 (Join-Path $shared 'Runbooks\x.runbook.md') | Should Be 'shared/Runbooks/x.runbook.md'
        ConvertTo-RelativePath $p1 (Join-Path $p1 'src\app.js') | Should Be 'src/app.js'
    }
    It 'lists no .streamhub folder among the projects' {
        $names = @(Get-ChildItem -Directory $base | Where-Object { -not $_.Name.StartsWith('.') } | ForEach-Object { $_.Name })
        $names -contains '.streamhub' | Should Be $false
        $names -contains 'P1' | Should Be $true
    }
    It 'installs the kit once into the central catalogue and gives each project its tokens from there' {
        @(Install-UiKit $p1 $root) -join ',' | Should Be 'styles/kit/tokens.css,styles/kit/kit.css'
        Test-Path (Join-Path $shared 'ui-kit\kit.css') | Should Be $true
        Test-Path (Join-Path $shared 'ui-kit\kit-examples.html') | Should Be $true
        Test-Path (Join-Path $shared 'ui-kit\manifest.json') | Should Be $true
        Test-Path (Join-Path $shared 'ui-kit\.pristine\tokens.css') | Should Be $true
        Test-Path (Join-Path $p1 '.streamhub\ui-kit') | Should Be $false
        Test-Path (Join-Path $p1 '.streamhub\kit-copies.json') | Should Be $true
        Test-Path (Join-Path $p1 '.streamhub\kit-tokens-base.css') | Should Be $true
        Get-UiKitCatalog $p1 | Should Be 'shared/ui-kit'
        Get-UiKitCatalogPath $p1 | Should Be (Join-Path $shared 'ui-kit')
        # The organisation changes the central tokens: the next project starts with them.
        $ct = Join-Path $shared 'ui-kit\tokens.css'
        [IO.File]::WriteAllText($ct, ([IO.File]::ReadAllText($ct) -replace '(--kit-accent:\s*)[^;]+;', '${1}#123456;'), $utf8)
        $null = Install-UiKit $p2 $root
        [IO.File]::ReadAllText((Join-Path $p2 'styles\kit\tokens.css')) | Should Match '--kit-accent:\s*#123456;'
        @(Get-KitCustomFiles (Join-Path $shared 'ui-kit')) -join ',' | Should Be 'tokens.css'
    }
    It 'brings an unchanged project copy up when the central file changes, and leaves a changed copy alone' {
        [IO.File]::WriteAllText((Join-Path $p1 'index.html'), "<!doctype html><html><head><meta charset=""utf-8""><link rel=""stylesheet"" href=""styles/kit/tokens.css""><link rel=""stylesheet"" href=""styles/kit/kit.css""></head><body><button class=""kit-btn"">Go</button><script src=""styles/kit/kit.js""></script></body></html>", $utf8)
        $u = Update-UiKitProject $p1 $root
        @($u.added) -contains 'styles/kit/kit.js' | Should Be $true
        (Get-KitCopyRecord $p1).files.ContainsKey('styles/kit/kit.js') | Should Be $true
        $ck = Join-Path $shared 'ui-kit\kit.js'
        [IO.File]::WriteAllText($ck, ([IO.File]::ReadAllText($ck) + "`n// central change 1`n"), $utf8)
        @(Update-UiKitCatalog $p1 $root) -contains 'styles/kit/kit.js' | Should Be $true
        [IO.File]::ReadAllText((Join-Path $p1 'styles\kit\kit.js')) | Should Match 'central change 1'
        # The project changes its copy: it is the project's own from then on.
        [IO.File]::WriteAllText((Join-Path $p1 'styles\kit\kit.js'), ([IO.File]::ReadAllText((Join-Path $p1 'styles\kit\kit.js')) + "// own change`n"), $utf8)
        [IO.File]::WriteAllText($ck, ([IO.File]::ReadAllText($ck) + "// central change 2`n"), $utf8)
        @(Update-UiKitCatalog $p1 $root) -contains 'styles/kit/kit.js' | Should Be $false
        [IO.File]::ReadAllText((Join-Path $p1 'styles\kit\kit.js')) | Should Not Match 'central change 2'
        # The central tokens change again: a project value still at the default follows, an own value stays.
        $ct = Join-Path $shared 'ui-kit\tokens.css'
        [IO.File]::WriteAllText($ct, ([IO.File]::ReadAllText($ct) -replace '(--kit-accent:\s*)[^;]+;', '${1}#654321;'), $utf8)
        $pt = Join-Path $p1 'styles\kit\tokens.css'
        [IO.File]::WriteAllText($pt, ([IO.File]::ReadAllText($pt) -replace '(--kit-radius:\s*)[^;]+;', '${1}3px;'), $utf8)
        @(Update-UiKitCatalog $p1 $root) -contains 'styles/kit/tokens.css' | Should Be $true
        $after = [IO.File]::ReadAllText($pt)
        $after | Should Match '--kit-accent:\s*#654321;'
        $after | Should Match '--kit-radius:\s*3px;'
    }
    It 'moves an older project''s own catalogue into the central one and updates the copies that were its' {
        $local = Join-Path $p3 '.streamhub\ui-kit'
        New-Item -ItemType Directory -Force (Join-Path $p3 'styles\kit') | Out-Null
        New-Item -ItemType Directory -Force $local | Out-Null
        [IO.File]::WriteAllText((Join-Path $local 'kit.js'), "// an older kit.js`nwindow.KitUI = {};`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $local 'kit.css'), ".kit-btn { color: red }`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $local 'tokens.css'), ":root {`n  --kit-accent: #000000;`n  --kit-radius: 8px;`n}`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $p3 'styles\kit\tokens.css'), ":root {`n  --kit-accent: #111111;`n  --kit-radius: 8px;`n}`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $local 'VERSION.txt'), "UI kit from StreamHub v0.1.100, copied 2026-01-01. Kit revision 9.`n", $utf8)
        Copy-Item (Join-Path $local 'kit.js') (Join-Path $p3 'styles\kit\kit.js')
        [IO.File]::WriteAllText((Join-Path $p3 'index.html'), "<!doctype html><html><head><meta charset=""utf-8""></head><body><button class=""kit-btn"">Go</button><script src=""styles/kit/kit.js""></script></body></html>", $utf8)
        $r = @(Update-UiKitCatalog $p3 $root)
        ($r -join ';') | Should Match 'moved to the shared shared/ui-kit/'
        Test-Path $local | Should Be $false
        $r -contains 'styles/kit/kit.js' | Should Be $true
        [IO.File]::ReadAllText((Join-Path $p3 'styles\kit\kit.js')) | Should Be ([IO.File]::ReadAllText((Join-Path $shared 'ui-kit\kit.js')))
        # The tokens: the project's own value (#111111, not the old default #000000) stays; a value still
        # at the old default (the radius) follows the central file; new tokens arrive.
        $t = [IO.File]::ReadAllText((Join-Path $p3 'styles\kit\tokens.css'))
        $t | Should Match '--kit-accent:\s*#111111;'
        $t | Should Not Match '--kit-radius:\s*8px;'
        $t | Should Match '--kit-palette-blue'
    }
    It 'keeps the organisation''s catalogue changes across a kit revision and reports them in the kit context' {
        $cat = Join-Path $shared 'ui-kit'
        $cc = Join-Path $cat 'kit-charts.js'
        [IO.File]::WriteAllText($cc, ([IO.File]::ReadAllText($cc) + "`n// central chart change`n"), $utf8)
        # kit-data.js as an older version StreamHub itself wrote (the manifest says so): it is replaced.
        $cd = Join-Path $cat 'kit-data.js'
        [IO.File]::WriteAllText($cd, "/* an older kit-data.js */`n", $utf8)
        $man = Get-KitManifest $cat; $man.files['kit-data.js'] = Get-FileSha $cd; Save-KitManifest $cat $man
        [IO.File]::WriteAllText((Join-Path $cat 'VERSION.txt'), "UI kit from StreamHub v0.1.100, copied 2026-01-01. Kit revision 9.`n", $utf8)
        $u = Update-KitCatalogFiles $cat $root -Shared
        @($u.custom) -contains 'kit-charts.js' | Should Be $true
        @($u.custom) -contains 'kit.js' | Should Be $true      # changed centrally in the test before
        @($u.custom) -contains 'tokens.css' | Should Be $true
        @($u.replaced) -contains 'kit-data.js' | Should Be $true
        [IO.File]::ReadAllText($cc) | Should Match 'central chart change'
        [IO.File]::ReadAllText((Join-Path $cat 'kit.js')) | Should Match 'central change 2'
        [IO.File]::ReadAllText((Join-Path $cat 'tokens.css')) | Should Match '--kit-accent:\s*#654321;'
        [IO.File]::ReadAllText($cd) | Should Be ([IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit-data.js')))
        (Get-KitCatalogRevision $cat) -ge 10 | Should Be $true
        $c = Format-UiKitContext $p1 $root
        $c | Should Match 'The whole kit is in shared/ui-kit/ \(read-only here: the central kit of every project in this folder'
        $c | Should Match 'The organisation changed these kit files, so they differ from the helper program''s standard kit: kit-charts.js, kit.js, tokens.css'
        $c | Should Match 'shared/ui-kit/kit-examples\.html has the markup of every part'
        # The kit rule names the central catalogue for this project.
        $rule = & (Get-Module Prompts) { param($a, $c) Get-PromptPart -AppRoot $a -Id 'rules:uikit' -Context $c } $root @{ Root = $p1 }
        $rule | Should Match 'shared/ui-kit/'
        $rule | Should Not Match '\.streamhub/ui-kit'
    }
    It 'searches the central kit with glob and grep under shared/' {
        Invoke-GlobAction $p1 '**/kit-examples.html' | Should Match '^shared/ui-kit/kit-examples\.html'
        Invoke-GrepAction $p1 'kit-btn' 'shared/ui-kit/kit.css' | Should Match 'shared/ui-kit/kit\.css:\d+:'
        Invoke-GlobAction $p1 '**/pdf.min.js' | Should Match 'shared/ui-kit/vendor/pdfjs/pdf\.min\.js'
        Invoke-GlobAction $p1 '**/.pristine/*' | Should Match '^\(no files match'
    }
    It 'lists shared runbooks, fetch prompts, chains and scripts with the project''s, the project''s winning on a name' {
        New-Item -ItemType Directory -Force (Join-Path $shared 'Runbooks'), (Join-Path $shared 'Scripts'), (Join-Path $p1 'Runbooks'), (Join-Path $p1 'Scripts') | Out-Null
        $tpl = [IO.File]::ReadAllText((Join-Path $root 'templates\runbooks\blank.runbook.md'))
        [IO.File]::WriteAllText((Join-Path $shared 'Runbooks\weekly-numbers.runbook.md'), $tpl, $utf8)
        [IO.File]::WriteAllText((Join-Path $shared 'Runbooks\team-news.runbook.md'), $tpl, $utf8)
        [IO.File]::WriteAllText((Join-Path $p1 'Runbooks\team-news.runbook.md'), $tpl, $utf8)
        [IO.File]::WriteAllText((Join-Path $shared 'Runbooks\market.prompt.md'), "sources: web`n`nWhat happened in the market this week?`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $shared 'Runbooks\monday.chain.md'), "title: Monday`n`n1. runbook: weekly-numbers`n2. script: shared/Scripts/hello.ps1`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $shared 'Scripts\hello.ps1'), "Write-Output 'hello'`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $p1 'Scripts\own.ps1'), "Write-Output 'own'`n", $utf8)
        $rbs = @(Get-Runbooks $p1)
        ($rbs | Where-Object name -eq 'weekly-numbers').path | Should Be 'shared/Runbooks/weekly-numbers.runbook.md'
        ($rbs | Where-Object name -eq 'weekly-numbers').shared | Should Be $true
        ($rbs | Where-Object name -eq 'weekly-numbers').output | Should Match '^Runbooks/Exports/'
        ($rbs | Where-Object name -eq 'team-news').path | Should Be 'Runbooks/team-news.runbook.md'
        @($rbs | Where-Object name -eq 'team-news').Count | Should Be 1
        (Get-FetchPrompts $p1 | Where-Object name -eq 'market').promptPath | Should Be 'shared/Runbooks/market.prompt.md'
        $ch = @(Get-Chains $p1 | Where-Object name -eq 'monday')
        $ch[0].path | Should Be 'shared/Runbooks/monday.chain.md'
        @($ch[0].problems).Count | Should Be 0
        $s = Resolve-ChainScript $p1 'shared/Scripts/hello.ps1'
        $s.error | Should Be $null
        $s.command | Should Match ([regex]::Escape((Join-Path $shared 'Scripts\hello.ps1')))
        (Resolve-ChainScript $p1 'Scripts/own.ps1').command | Should Match 'Scripts\\own\.ps1'
        (Resolve-ChainScript $p1 'shared/Runbooks/hello.ps1').error | Should Match 'shared/Scripts/'
        @(Get-ProjectScripts $p1) -join ',' | Should Be 'Scripts/own.ps1,shared/Scripts/hello.ps1'
        [IO.File]::ReadAllText((Resolve-ProjectPath $p1 $ch[0].path)) | Should Match 'weekly-numbers'
    }
    It 'sends the shared instructions with the project notes once someone wrote them' {
        Initialize-SharedRoot $shared
        Get-SharedNotes $p1 | Should Be ''
        Add-Content -LiteralPath (Join-Path $shared 'AGENTS.md') -Value "Every page shows the company name in the band header." -Encoding UTF8
        Get-SharedNotes $p1 | Should Match 'company name in the band header'
        Get-SharedNotes $p1 | Should Not Match 'Describe here what every project'
    }
    It 'takes the data tools from the library when its copy is at least as new' {
        $tpl = Join-Path $root 'templates\data\data-tools.js'
        Get-DataToolsSource $p1 $root | Should Be $tpl
        New-Item -ItemType Directory -Force (Join-Path $shared 'data') | Out-Null
        $own = Join-Path $shared 'data\data-tools.js'
        [IO.File]::WriteAllText($own, "/* Data tools v1: the organisation's version */`nwindow.DataTools = {};`n", $utf8)
        Get-DataToolsSource $p1 $root | Should Be $tpl   # older than the template
        [IO.File]::WriteAllText($own, "/* Data tools v999: the organisation's version */`nwindow.DataTools = {};`n", $utf8)
        Get-DataToolsSource $p1 $root | Should Be $own
    }
    It 'reads the library as library/ in a project that has a shared folder of its own' {
        $own = Join-Path $p2 'shared'; New-Item -ItemType Directory -Force $own | Out-Null
        [IO.File]::WriteAllText((Join-Path $own 'notes.txt'), 'the project''s own shared folder', $utf8)
        try {
            Get-SharedPrefix $p2 | Should Be 'library'
            Get-SharedPrefix $p1 | Should Be 'shared'
            Resolve-ProjectPath $p2 'shared/notes.txt' | Should Be (Join-Path $own 'notes.txt')
            Resolve-ProjectPath $p2 'library/ui-kit/kit.css' | Should Be (Join-Path $shared 'ui-kit\kit.css')
            { Assert-Writable $p2 'library/AGENTS.md' } | Should Throw
            Assert-Writable $p2 'shared/notes.txt' | Should Be (Join-Path $own 'notes.txt')
            Get-UiKitCatalog $p2 | Should Be 'library/ui-kit'
            Invoke-GlobAction $p2 '**/kit-examples.html' | Should Match '^library/ui-kit/kit-examples\.html'
            Invoke-GlobAction $p2 'shared/*' | Should Match '^shared/notes\.txt'
            (Get-Runbooks $p2 | Where-Object name -eq 'weekly-numbers').path | Should Be 'library/Runbooks/weekly-numbers.runbook.md'
            (Resolve-ChainScript $p2 'library/Scripts/hello.ps1').error | Should Be $null
            Format-UiKitContext $p2 $root | Should Match 'The whole kit is in library/ui-kit/'
        } finally { Remove-Item -LiteralPath $own -Recurse -Force }
    }
    It 'leaves a project without a library as before: its own catalogue, .streamhub/ui-kit' {
        $lone = Join-Path $env:TEMP ('ccb-lone-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $lone | Out-Null
        try {
            Get-UiKitCatalog $lone | Should Be '.streamhub/ui-kit'
            $null = Install-UiKit $lone $root
            Test-Path (Join-Path $lone '.streamhub\ui-kit\kit.css') | Should Be $true
            Test-Path (Join-Path $lone '.streamhub\ui-kit\manifest.json') | Should Be $true
            Invoke-GlobAction $lone '**/kit-examples.html' | Should Match '^\.streamhub/ui-kit/kit-examples\.html'
            { Resolve-ProjectPath $lone 'shared/ui-kit/kit.css' } | Should Throw
        } finally { Remove-Item -LiteralPath $lone -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
