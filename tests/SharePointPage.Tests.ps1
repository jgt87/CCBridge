# A project whose pages are opened as SharePoint HTML pages (setup answer audience = sharepoint):
# what SharePoint's sandbox blocks is reported on every change, the rules go to Copilot, the page
# check serves the page under SharePoint's policy with LiveData from the project's own files.
# Made-up pages and data.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-sp-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'ProjectSetup', 'Prompts', 'CheckPolicy', 'SharePointPage') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

$clean = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Items</title>
<style>body { font-family: system-ui, sans-serif; } .logo { background: url("data:image/png;base64,iVBORw0KGgo=") }</style>
<style data-streamhub="kit">.kit-page{margin:0}</style>
</head><body class="kit-page">
<h1>Items</h1><img alt="logo" src="data:image/png;base64,iVBORw0KGgo="><a href="#totals">Totals</a>
<script data-streamhub="kit">window.KitUI = {}; fetch("/x"); localStorage.getItem("t");</script>
<script type="application/json" class="ka-livedata-manifest">[{ "spItemUrl": "https://example.sharepoint.com/_api/v2.0/drives/b!abc/items/01XYZ", "fileName": "items.csv" }]</script>
<script>
  const r = window.__LD_RESULTS__ || {};
  const item = r[Object.keys(r)[0]];
  if (!item || item.error) { document.title = "No data"; }
  location.hash = "view=all";
  KitUI.confirm && KitUI.confirm("Sure?");
</script>
</body></html>
'@

Describe 'What a SharePoint HTML page cannot do' {
    It 'leaves an inline page alone, including the helper program''s filled blocks' {
        @(Get-SharePointPageFindings $clean).Count | Should Be 0
    }
    It 'reports files and addresses the page loads' {
        $p = "<html><head><script src=""js/app.js""></script><link rel=""stylesheet"" href=""css/site.css""><style>@import url(""https://fonts.example.com/x.css"");</style></head>`n<body><img src=""img/logo.png"" alt=""l""><iframe src=""https://app.example.com""></iframe><form action=""/save""></form><a href=""javascript:void(0)"">x</a></body></html>"
        $f = @(Get-SharePointPageFindings $p) -join "`n"
        $f | Should Match 'loads a script from a file or address \(js/app\.js\)'
        $f | Should Match 'stylesheet or file with <link> \(css/site\.css\)'
        $f | Should Match '@import or url\(\)'
        $f | Should Match 'image or media file from a file or address \(img/logo\.png\)'
        $f | Should Match 'uses <iframe>'
        $f | Should Match 'a form posts to an address'
        $f | Should Match 'a link with a javascript: address'
    }
    It 'reports what the page''s own scripts do that the sandbox blocks or loses' {
        $p = "<html><body><script>`nfetch('data.json');`nimport('./x.js');`nhistory.pushState({}, '', '?a');`nwindow.open('https://example.com');`nalert('hi');`nlocalStorage.setItem('a', 1);`n</script></body></html>"
        $f = @(Get-SharePointPageFindings $p)
        ($f -join "`n") | Should Match 'line 2: reads data over the network \(fetch\)'
        ($f -join "`n") | Should Match 'loads code at run time \(import\)'
        ($f -join "`n") | Should Match 'history\.pushState: it throws'
        ($f -join "`n") | Should Match 'navigates from script \(window\.open\)'
        ($f -join "`n") | Should Match 'calls alert\(\): it does nothing'
        ($f -join "`n") | Should Match 'uses localStorage'
        # Breaking ones are errors; the ones that only lose something are warnings.
        Get-CheckLevel (@($f | Where-Object { $_ -match 'network' })[0]) 'file' | Should Be 'error'
        Get-CheckLevel (@($f | Where-Object { $_ -match 'localStorage' })[0]) 'file' | Should Be 'warning'
        Get-CheckLevel (@($f | Where-Object { $_ -match 'alert' })[0]) 'file' | Should Be 'warning'
    }
    It 'checks the LiveData manifest and that the page handles an item it could not read' {
        $bad = "<html><body><script type=""application/json"" class=""ka-livedata-manifest"">[{ ""spItemUrl"": ""https://contoso.sharepoint.com/sites/x/data.csv"" }]</script><script>const d = window.__LD_RESULTS__; draw(d);</script></body></html>"
        $f = @(Get-SharePointPageFindings $bad) -join "`n"
        $f | Should Match 'has no /drives/DRIVE-ID/items/ITEM-ID part'
        $f | Should Match 'needs fileName with the file''s extension'
        $f | Should Match 'without handling an item''s error'
        @(Get-SharePointPageFindings '<script type="application/json" class="ka-livedata-manifest">{ "a": 1 }</script>') -join "`n" | Should Match 'manifest is not valid: it is not a JSON array'
        @(Get-SharePointPageFindings '<script type="application/json" class="ka-livedata-manifest">[{ "spItemUrl": "https://x/_api/v2.0/drives/{driveId}/items/{itemId}", "fileName": "a.csv" }]</script><script>if (r.error) {}</script>') -join "`n" | Should Match 'is a placeholder'
    }
    It 'reports a page over 10 MB, and only what a change adds' {
        $big = '<html><body><img alt="x" src="data:image/png;base64,' + ('A' * (10MB + 10)) + '"></body></html>'
        @(Get-SharePointPageFindings $big) -join "`n" | Should Match 'SharePoint HTML pages hold at most 10 MB'
        $old = '<html><body><script src="a.js"></script></body></html>'
        @(Find-SharePointPageIssues 'index.html' $old $old).Count | Should Be 0
        @(Find-SharePointPageIssues 'index.html' $old ($old + '<script>fetch("x")</script>')).Count | Should Be 1
        @(Find-SharePointPageIssues 'js/app.js' '' 'fetch("x")').Count | Should Be 0
    }
}

Describe 'A SharePoint HTML page as a project choice' {
    It 'is read from the request, sends the rules and builds one file' {
        $none = @{ build = ''; answers = @{} }
        (Get-SetupQuestions 'Build a dashboard of the releases as a SharePoint HTML page' @() $none).stated.audience | Should Be 'sharepoint'
        (Get-SetupQuestions 'Make an overview page I upload to the SharePoint Site Pages library' @() $none).stated.audience | Should Be 'sharepoint'
        (Get-PromptModules 'Add a filter' @{ Traits = @('code'); Answers = @{ audience = 'sharepoint' } }) -contains 'rules:sharepoint' | Should Be $true
        (Get-PromptModules 'Add a filter' @{ Traits = @('code'); Answers = @{ audience = 'me' } }) -contains 'rules:sharepoint' | Should Be $false
        $rules = Get-PromptPart $root 'rules:sharepoint'
        $rules | Should Match 'ka-livedata-manifest'
        $rules | Should Match 'window\.__LD_RESULTS__'
        $rules | Should Not Match '(?i)ccbridge|streamhub'
    }
    It 'is known to the checks and the page check once saved' {
        $p = Join-Path $env:TEMP ('ccb-spp-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        try {
            Test-SharePointPageProject $p | Should Be $false
            $null = Save-ProjectSetup $p @{ answers = @{ audience = 'sharepoint' } }
            Test-SharePointPageProject $p | Should Be $true
            (Format-ProjectSetupContext $p) | Should Match 'opened as a SharePoint HTML page'
            Get-SharePointPolicy | Should Match "connect-src 'none'"
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'LiveData in the page check' {
    It 'hands the page the project''s copy of a manifest file as SharePoint would, and an error for the rest' {
        $p = Join-Path $env:TEMP ('ccb-spl-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p 'Source') -Force | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $p 'Source\items.csv'), "name,count`nFirst,3`n")
            $html = "<html><head></head><body><script type=""application/json"" class=""ka-livedata-manifest"">[{ ""spItemUrl"": ""https://h/_api/v2.0/drives/d1/items/i1"", ""fileName"": ""items.csv"" }, { ""spItemUrl"": ""https://h/_api/v2.0/drives/d1/items/i2"", ""fileName"": ""other.csv"" }, { ""kind"": ""list"", ""spItemUrl"": ""list:https://h/sites/a/L1"", ""webUrl"": ""https://h/sites/a"", ""listId"": ""L1"" }]</script><script>draw();</script></body></html>"
            $s = Get-LiveDataStandIn $p $html
            $s | Should Match '^<script>window\.__LD_RESULTS__ = '
            $json = ($s -replace '^<script>window\.__LD_RESULTS__ = ', '' -replace ';</script>$', '') | ConvertFrom-Json
            $json.'https://h/_api/v2.0/drives/d1/items/i1'.format | Should Be 'csv'
            $json.'https://h/_api/v2.0/drives/d1/items/i1'.content | Should Match 'First,3'
            $json.'https://h/_api/v2.0/drives/d1/items/i2'.errorCode | Should Be 'not-found'
            $json.'list:https://h/sites/a/L1'.errorCode | Should Be 'not-found'
            $out = Add-LiveDataStandIn $html $s
            $out.IndexOf('window.__LD_RESULTS__') -lt $out.IndexOf('<script type="application/json"') | Should Be $true
            Get-LiveDataStandIn $p '<html><body></body></html>' | Should Be ''
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
