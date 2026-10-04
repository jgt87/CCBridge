# After the folder layout moved or renamed folders, the project's own code follows (lib/Relink.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Layout.psm1') -Force
Import-Module (Join-Path $root 'lib\Relink.psm1') -Force

function Add-File($p, $rel, $text) {
    $full = Join-Path $p $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
    [IO.File]::WriteAllText($full, $text)
}

Describe 'Path helpers' {
    It 'normalises and builds relative paths' {
        ConvertTo-NormalPath 'a/./b/../c' | Should Be 'a/c'
        ConvertTo-NormalPath '../x' | Should Be $null
        Get-RelativeRef 'Scripts' 'Runbooks/Exports/m.json' | Should Be '../Runbooks/Exports/m.json'
        Get-RelativeRef '' 'Scripts/app.js' | Should Be 'Scripts/app.js'
        Get-RelativeRef 'Scripts/lib' 'Scripts/app.js' | Should Be '../app.js'
    }
    It 'knows where a moved path went, and ignores a rename with the same case' {
        $moves = @([pscustomobject]@{ from = 'scripts'; to = 'Scripts'; folder = $true }, [pscustomobject]@{ from = 'exports/m.json'; to = 'Runbooks/Exports/m.json'; folder = $false })
        Get-MovedTarget 'scripts/app.js' $moves | Should BeExactly 'Scripts/app.js'
        Get-MovedTarget 'Scripts/app.js' $moves | Should Be $null
        Get-MovedTarget 'exports/m.json' $moves | Should Be 'Runbooks/Exports/m.json'
        Get-MovedTarget 'src/app.js' $moves | Should Be $null
    }
}

Describe 'Update-MovedReferences' {
    It 'rewrites links, imports, fetches and script paths to the new folders, and nothing else' {
        $p = Join-Path $env:TEMP ('ccb-relink-' + [guid]::NewGuid().ToString('N'))
        Add-File $p 'index.html' @'
<link rel="stylesheet" href="./scripts/style.css">
<script src="scripts/app.js"></script>
<script src="https://cdn.example.com/scripts/lib.js"></script>
<a href="/scripts/app.js">abs</a>
<p>my-scripts/app.js stays</p>
'@
        Add-File $p 'scripts\app.js' "import { f } from './util.js';`nfetch('../exports/meetings.json');`nconst h = 'exports/history/meetings-20261001-080000.json';`n"
        Add-File $p 'scripts\util.js' 'export const f = 1;'
        Add-File $p 'scripts\style.css' 'body {}'
        Add-File $p 'scripts\load.ps1' "Import-Csv source\data.csv`n"
        Add-File $p 'README.md' "See [the review](reviews/review-20261002-120000.md) and src/main.js.`n"
        Add-File $p 'src\main.js' "console.log('src stays');`n"
        Add-File $p 'exports\meetings.json' '{}'
        Add-File $p 'exports\history\meetings-20261001-080000.json' '{}'
        Add-File $p 'reviews\review-20261002-120000.md' '# r'
        Add-File $p 'source\data.csv' 'a,b'
        Add-File $p 'source\notes.md' 'scripts/app.js is here'
        try {
            $moves = New-Object System.Collections.ArrayList
            $null = @(Move-ProjectLayout $p -Moves $moves)
            $r = Update-MovedReferences $p $moves
            $html = [IO.File]::ReadAllText((Join-Path $p 'index.html'))
            $html | Should MatchExactly 'href="\./Scripts/style\.css"'
            $html | Should MatchExactly '<script src="Scripts/app\.js">'
            $html | Should MatchExactly 'https://cdn\.example\.com/scripts/lib\.js'      # a URL stays
            $html | Should MatchExactly 'href="/Scripts/app\.js"'
            $html | Should MatchExactly 'my-scripts/app\.js stays'
            $js = [IO.File]::ReadAllText((Join-Path $p 'Scripts\app.js'))
            $js | Should MatchExactly "from '\./util\.js'"
            $js | Should MatchExactly "fetch\('\.\./Runbooks/Exports/meetings\.json'\)"
            $js | Should MatchExactly "'\.streamhub/History/meetings-20261001-080000\.json'"
            [IO.File]::ReadAllText((Join-Path $p 'Scripts\load.ps1')) | Should MatchExactly 'Import-Csv Source\\data\.csv'
            $md = [IO.File]::ReadAllText((Join-Path $p 'README.md'))
            $md | Should MatchExactly '\(\.streamhub/Reviews/review-20261002-120000\.md\)'
            $md | Should MatchExactly 'src/main\.js'
            [IO.File]::ReadAllText((Join-Path $p 'Source\notes.md')) | Should Be 'scripts/app.js is here'   # read-only data: untouched
            @($r.files).Count | Should Be 4
            Test-Path (Join-Path $r.backup 'index.html') | Should Be $true
            [IO.File]::ReadAllText((Join-Path $r.backup 'index.html')) | Should MatchExactly 'src="scripts/app\.js"'
            # A second open finds nothing to move and changes nothing.
            $again = New-Object System.Collections.ArrayList
            $null = @(Move-ProjectLayout $p -Moves $again)
            $again.Count | Should Be 0
            @((Update-MovedReferences $p $again).files).Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
