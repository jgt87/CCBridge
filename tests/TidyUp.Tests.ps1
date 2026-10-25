# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests\TidyUp.Tests.ps1
# Tidy-up list: what a project likely no longer uses, never StreamHub's or the person's protected
# files, removed only when still unused at that moment, and all of it back with one Undo.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\TidyUp.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

$proj = Join-Path $env:TEMP ('ccb-tidy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$outside = Join-Path $env:TEMP ('ccb-tidy-out-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$write = {
    param($rel, $text)
    $p = Join-Path $proj $rel
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $p)
    [IO.File]::WriteAllText($p, $text)
}
$site = ".used { color: red; }`n.gone { color: blue; }`nh1 { margin: 0; }`n.btn-primary { padding: 0; }`n.x:not(.never) { margin: 0; }`n@media (max-width: 600px) {`n  .gone2 { display: none; }`n}`n#main .gone3, .also-gone { top: 0; }`n"
& $write 'index.html' "<html><head><link rel=`"stylesheet`" href=`"css/site.css`"></head><body><h1 class=`"used`" id=`"main`">Hi</h1><script src=`"js/app.js`"></script></body></html>"
& $write 'css\site.css' $site
& $write 'js\app.js' "const kind = 'primary'; document.body.className = 'btn-' + kind; DataTools.load('sales');`n"
& $write 'js\old.js' "console.log('nobody loads me');`n"
& $write 'js\sched.js' "console.log('a schedule runs me');`n"
& $write 'data\sales.json' '[{"a":1}]'
& $write 'data\old.csv' "a,b`n1,2`n"
& $write 'data\conv.json' '[{"b":2}]'
& $write 'data\data-tools.js' "/* Data tools v5 */`n"
& $write 'Work\old.txt' "scratch`n"
& $write 'Work\new.txt' "scratch`n"
& $write 'Source\raw.js' "untouched`n"
& $write 'Scripts\Refresh-Data.ps1' "# refresh`n"
& $write 'styles\kit\kit.js' "/* kit */`n"
& $write 'keep\z.js' "// protected`n"
& $write '.streamhub\schedules.json' '[{"kind":"script","name":"js/sched.js"}]'
& $write '.streamhub\data-imports.json' '{"items":[{"source":"Source/conv.csv","output":"data/conv.json"}]}'
(Get-Item (Join-Path $proj 'Work\old.txt')).LastWriteTime = (Get-Date).AddDays(-30)
# A junction inside the project to a folder outside it: never listed, never touched.
$null = New-Item -ItemType Directory -Force -Path $outside
[IO.File]::WriteAllText((Join-Path $outside 'far.js'), "outside`n")
$null = cmd /c "mklink /J `"$(Join-Path $proj 'linked')`" `"$outside`" >nul 2>&1"

Describe 'The tidy-up list' {
    $items = @(Get-TidyCandidates $proj -Protected @('keep/'))
    $ids = @($items | ForEach-Object { $_.id })

    It 'lists a script nothing loads, a data file nothing names and an old working file' {
        $ids -contains 'file|js/old.js' | Should Be $true
        $ids -contains 'data|data/old.csv' | Should Be $true
        $ids -contains 'work|Work/old.txt' | Should Be $true
    }
    It 'lists CSS rules whose classes or ids nothing uses, with a reason and a size' {
        $ids -contains 'css-rule|css/site.css|.gone' | Should Be $true
        $ids -contains 'css-rule|css/site.css|#main .gone3, .also-gone' | Should Be $true
        $gone = $items | Where-Object { $_.id -eq 'css-rule|css/site.css|.gone' }
        $gone.reason | Should Match '\.gone'
        $gone.size | Should Be '.gone { color: blue; }'.Length
    }
    It 'keeps what is used, built in code, tag-only, inside :not() or inside @media' {
        foreach ($sel in '.used', 'h1', '.btn-primary', '.x:not(.never)', '.gone2') { $ids -contains "css-rule|css/site.css|$sel" | Should Be $false }
        $ids -contains 'file|js/app.js' | Should Be $false
        $ids -contains 'data|data/sales.json' | Should Be $false
        $ids -contains 'work|Work/new.txt' | Should Be $false
    }
    It 'never lists StreamHub''s folders and files, protected paths, scheduled files or links' {
        foreach ($p in 'Source/raw.js', 'Scripts/Refresh-Data.ps1', 'styles/kit/kit.js', 'keep/z.js', 'js/sched.js', 'data/conv.json', 'data/data-tools.js', 'linked/far.js') {
            @($items | Where-Object { $_.path -eq $p }).Count | Should Be 0
        }
        @($items | Where-Object { $_.path -match '^\.streamhub' }).Count | Should Be 0
    }
    It 'checks an item again against the project as it is now' {
        Test-TidyItemStillUnused $proj @{ id = 'file|js/old.js' } $items | Should Be $true
        Test-TidyItemStillUnused $proj @{ id = 'file|js/app.js' } $items | Should Be $false
    }
}

Describe 'Removing ticked items' {
    It 'removes only what is still unused, refuses links, and keeps it all in one change set' {
        # Since the list was made, a page started loading old.csv: it stays.
        & $write 'index2.html' '<script>DataTools.load("x"); fetch("data/old.csv")</script>'
        $r = Invoke-TidyRemove $proj @('file|js/old.js', 'data|data/old.csv', 'work|Work/old.txt', 'css-rule|css/site.css|.gone', 'css-rule|css/site.css|#main .gone3, .also-gone', 'file|linked/far.js') -Protected @('keep/')
        (@($r.removed | ForEach-Object { $_.id }) | Sort-Object) -join ',' | Should Be 'css-rule|css/site.css|#main .gone3, .also-gone,css-rule|css/site.css|.gone,file|js/old.js,work|Work/old.txt'
        @($r.skipped | Where-Object { $_.id -eq 'data|data/old.csv' }).Count | Should Be 1
        @($r.skipped | Where-Object { $_.id -eq 'file|linked/far.js' }).Count | Should Be 1
        Test-Path (Join-Path $proj 'js\old.js') | Should Be $false
        Test-Path (Join-Path $proj 'data\old.csv') | Should Be $true
        Test-Path (Join-Path $outside 'far.js') | Should Be $true
        $css = [IO.File]::ReadAllText((Join-Path $proj 'css\site.css'))
        $css | Should Be ".used { color: red; }`nh1 { margin: 0; }`n.btn-primary { padding: 0; }`n.x:not(.never) { margin: 0; }`n@media (max-width: 600px) {`n  .gone2 { display: none; }`n}`n"
        @($r.edited).Count | Should Be 1
        @($r.checkpoint.Files.Keys).Count | Should Be 3
    }
    It 'brings everything back with Undo' {
        $null = Undo-LastCheckpoint $proj
        Test-Path (Join-Path $proj 'js\old.js') | Should Be $true
        Test-Path (Join-Path $proj 'Work\old.txt') | Should Be $true
        [IO.File]::ReadAllText((Join-Path $proj 'css\site.css')) | Should Be $site
    }
    It 'says a size people read' {
        Format-TidySize 512 | Should Be '512 bytes'
        Format-TidySize 3482 | Should Be '3.4 KB'
    }
}

$null = cmd /c "rmdir `"$(Join-Path $proj 'linked')`" >nul 2>&1"
Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
