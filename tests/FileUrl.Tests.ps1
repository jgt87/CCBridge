# Pages opened straight from disk (file://): what the browser blocks, and the exact replacement
# (a .js data file with a global, loaded by the page with a script tag).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

function New-PageProject {
    $dir = Join-Path $env:TEMP ('ccb-fileurl-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $dir
}
function Add-PageFile($Root, $Rel, $Text) {
    $full = Join-Path $Root $Rel
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
    [IO.File]::WriteAllText($full, $Text)
}

Describe 'Find-FileUrlBlocks' {
    It 'names the JS file, the global and the script tag for a fetch in a script the page loads' {
        $p = New-PageProject
        Add-PageFile $p 'index.html' "<html><body>`n<script src=""js/app.js""></script>`n</body></html>"
        Add-PageFile $p 'js\app.js' "const r = await fetch('data/expenses.json');`nconst d = await r.json();"
        Add-PageFile $p 'data\expenses.json' '[]'
        $f = @(Test-ProjectConsistency $p @('js/app.js', 'index.html'))
        $f.Count | Should Be 1
        $f[0] | Should Match '^js/app\.js:1: fetch\(''data/expenses\.json''\) is blocked'
        $f[0] | Should Match 'write data/expenses\.js containing window\.expensesData = the contents of data/expenses\.json;'
        $f[0] | Should Match 'add <script src="data/expenses\.js"></script> to index\.html before the script tag that loads js/app\.js'
        Remove-Item $p -Recurse -Force
    }
    It 'flags JSON imports, module scripts and script tags that point at JSON in an HTML page' {
        $p = New-PageProject
        Add-PageFile $p 'pages\list.html' "<script src=""../data/my-items.json""></script>`n<script type=""module"">`nimport items from '../data/my-items.json';`n</script>"
        $f = @(Find-FileUrlBlocks 'pages/list.html' ([IO.File]::ReadAllText((Join-Path $p 'pages\list.html'))) $p)
        ($f -join "`n") | Should Match 'list\.html:2: <script type="module"> is blocked'
        ($f -join "`n") | Should Match 'list\.html:1: <script src="\.\./data/my-items\.json"> cannot load JSON.*window\.myItemsData.*<script src="\.\./data/my-items\.js"></script> to pages/list\.html'
        ($f -join "`n") | Should Match 'list\.html:3: importing \.\./data/my-items\.json is blocked'
        Remove-Item $p -Recurse -Force
    }
    It 'leaves web addresses alone and keeps an existing .js file' {
        $p = New-PageProject
        Add-PageFile $p 'index.html' "<script src=""app.js""></script>"
        Add-PageFile $p 'app.js' "fetch('https://api.example.com/x.json'); fetch('config.json');"
        Add-PageFile $p 'config.js' 'function setup() {}'
        Add-PageFile $p 'config.json' '{}'
        $f = @(Test-ProjectConsistency $p @('app.js'))
        $f.Count | Should Be 1
        $f[0] | Should Match 'write config\.data\.js containing window\.configData'
        Remove-Item $p -Recurse -Force
    }
    It 'says nothing for a project with a build tool or web server' {
        $p = New-PageProject
        Add-PageFile $p 'package.json' '{ "name": "x" }'
        Add-PageFile $p 'index.html' "<script type=""module"" src=""main.js""></script>"
        Add-PageFile $p 'main.js' "fetch('data.json')"
        Add-PageFile $p 'data.json' '{}'
        @(Test-ProjectConsistency $p @('index.html', 'main.js')).Count | Should Be 0
        Remove-Item $p -Recurse -Force
    }
}
