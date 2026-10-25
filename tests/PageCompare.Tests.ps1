# Compare a page with an earlier version (lib/PageCompare.psm1): the before copy is built from real
# change sets (Executor checkpoints) in a temporary project, the small read-only server is asked for
# real, and Edge is stood in for by -Shoot (a picture drawn from the page's text). Made-up pages.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# Project state (backups) of the test project goes to a temporary folder, deleted below.
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib\PageCompare.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName System.Drawing

$proj = Join-Path $env:TEMP ('ccb-compare-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'css'), (Join-Path $proj 'node_modules\lib'), (Join-Path $proj '.streamhub')
$write = { param($rel, $text) [IO.File]::WriteAllText((Join-Path $proj $rel), $text) }
$read = { param($dir, $rel) [IO.File]::ReadAllText((Join-Path $dir $rel)) }
& $write 'index.html' '<!doctype html><link rel="stylesheet" href="css/site.css"><h1>blue</h1>'
& $write 'css\site.css' 'h1 { color: blue; }'
& $write 'node_modules\lib\x.js' 'module.exports = 1;'
& $write '.streamhub\project.json' '{}'

# Change set A: the stylesheet changed, a script added. Change set B: the stylesheet and the page.
$a = New-Checkpoint $proj 'A'
Save-CheckpointFile $a $proj (Join-Path $proj 'css\site.css')
Save-CheckpointFile $a $proj (Join-Path $proj 'js\new.js')
& $write 'css\site.css' 'h1 { color: green; }'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'js')
& $write 'js\new.js' 'console.log(1);'
Start-Sleep -Milliseconds 30
$b = New-Checkpoint $proj 'B'
Save-CheckpointFile $b $proj (Join-Path $proj 'css\site.css')
Save-CheckpointFile $b $proj (Join-Path $proj 'index.html')
& $write 'css\site.css' 'h1 { color: red; }'
& $write 'index.html' '<!doctype html><link rel="stylesheet" href="css/site.css"><h1>red</h1>'

# Edge stood in: a white 1280x800 picture with a red block when the page (and its stylesheet) say red.
$fakeShoot = {
    param($o)
    $text = [IO.File]::ReadAllText((Join-Path $o.root $o.page)) + [IO.File]::ReadAllText((Join-Path $o.root 'css\site.css'))
    $bmp = New-Object Drawing.Bitmap 1280, 800
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::White)
    if ($text -match 'red') { $g.FillRectangle([Drawing.Brushes]::Red, 100, 100, 300, 120) }
    $g.Dispose(); $bmp.Save($o.out, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    '[{"name":"h1","text":"Title","heading":true,"x":100,"y":100,"w":300,"h":120}]'
}

Describe 'The project before a change set' {
    It 'takes each file from the earliest change set from that one on' {
        $files = Get-BeforeFiles $proj $a.Id
        @($files.Keys | Sort-Object) -join ',' | Should Be 'css/site.css,index.html,js/new.js'
        $files['css/site.css'].from | Should Be $a.Id
        $files['js/new.js'].state | Should Be 'new'
        $files['index.html'].from | Should Be $b.Id
        @((Get-BeforeFiles $proj $b.Id).Keys | Sort-Object) -join ',' | Should Be 'css/site.css,index.html'
        { Get-BeforeFiles $proj '20000101-000000-000' } | Should Throw 'no longer kept'
        { Get-BeforeFiles $proj '..\x' } | Should Throw 'not a change set'
    }
    It 'builds a temporary copy as it was, and leaves the project alone' {
        $c = New-BeforeCopy $proj $a.Id
        try {
            $c.root.StartsWith([IO.Path]::GetTempPath().TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) | Should Be $true
            & $read $c.root 'css\site.css' | Should Be 'h1 { color: blue; }'
            & $read $c.root 'index.html' | Should Match 'blue'
            Test-Path (Join-Path $c.root 'js\new.js') | Should Be $false
            Test-Path (Join-Path $c.root 'node_modules') | Should Be $false
            Test-Path (Join-Path $c.root '.streamhub') | Should Be $false
            @($c.removed) -join ',' | Should Be 'js/new.js'
            @($c.sets).Count | Should Be 2
            # The project is as it was.
            & $read $proj 'css\site.css' | Should Be 'h1 { color: red; }'
            Test-Path (Join-Path $proj 'js\new.js') | Should Be $true
        } finally { Remove-BeforeCopy $c.root }
        Test-Path $c.root | Should Be $false
    }
    It 'between two change sets, puts back only what the later one touched' {
        $c = New-BeforeCopy $proj $b.Id
        try {
            & $read $c.root 'css\site.css' | Should Be 'h1 { color: green; }'
            Test-Path (Join-Path $c.root 'js\new.js') | Should Be $true
        } finally { Remove-BeforeCopy $c.root }
    }
    It 'removes only its own copies' {
        { Remove-BeforeCopy $proj } | Should Throw 'not a comparison copy'
        Test-Path $proj | Should Be $true
    }
}

Describe 'The read-only page server' {
    It 'serves files under its folder and nothing outside it' {
        Resolve-ServedFile $proj '/' | Should Be (Join-Path $proj 'index.html')
        Resolve-ServedFile $proj '/css/site.css?v=2' | Should Be (Join-Path $proj 'css\site.css')
        Resolve-ServedFile $proj '/css/../index.html' | Should BeNullOrEmpty
        Resolve-ServedFile $proj '/%2e%2e/x.txt' | Should BeNullOrEmpty
        Resolve-ServedFile $proj '/C:/Windows/win.ini' | Should BeNullOrEmpty
        Resolve-ServedFile $proj '/missing.js' | Should BeNullOrEmpty
    }
    It 'answers GET requests from its own runspace and stops' {
        $srv = Start-PageServer $proj
        try {
            $r = Invoke-WebRequest -UseBasicParsing ($srv.Url + 'css/site.css')
            $r.Content | Should Be 'h1 { color: red; }'
            "$($r.Headers['Content-Type'])" | Should Match 'text/css'
            $code = try { $null = Invoke-WebRequest -UseBasicParsing ($srv.Url + 'nothing.js'); 200 } catch { [int]$_.Exception.Response.StatusCode }
            $code | Should Be 404
        } finally { & $srv.Stop }
        { $null = Invoke-WebRequest -UseBasicParsing ($srv.Url + 'index.html') -TimeoutSec 3 } | Should Throw
    }
}

Describe 'Comparing a page with before a change set' {
    $now = Get-Date '2026-10-25 15:00:00'
    It 'writes the report, both screenshots and the changed area close up' {
        $r = Invoke-PageCompare -ProjectRoot $proj -ChangeSet $a.Id -Page 'index.html' -Shoot $fakeShoot -Now $now
        $r.path | Should Be '.streamhub/Reports/compare-index-20261025-150000.md'
        $r.same | Should Be $false
        $r.summary | Should Match "index\.html changed compared with before change set $($a.Id)"
        $r.summary | Should Match 'Title|h1'
        foreach ($f in $r.before, $r.after, $r.crop) { Test-Path (Join-Path $proj $f.Replace('/', '\')) | Should Be $true }
        $md = & $read $proj '.streamhub\Reports\compare-index-20261025-150000.md'
        $md | Should Match '# Page comparison: index\.html'
        $md | Should Match 'or one of the 1 later one'
        $md | Should Match '- css/site\.css'
        $md | Should Match 'Left out \(they did not exist yet\):'
        # No temporary copies left behind.
        @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'streamhub-compare-*' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) }).Count | Should Be 0
    }
    It 'says plainly when it looks exactly the same' {
        & $write 'index.html' '<!doctype html><h1>blue</h1>'
        & $write 'css\site.css' 'h1 { color: blue; }'
        $r = Invoke-PageCompare -ProjectRoot $proj -ChangeSet $a.Id -Page 'index.html' -Shoot $fakeShoot -Now $now.AddMinutes(1)
        $r.same | Should Be $true
        $r.summary | Should Match 'looks exactly the same now as before change set'
        $r.crop | Should Be ''
    }
    It 'says when the page did not exist before the change set' {
        $r = Invoke-PageCompare -ProjectRoot $proj -ChangeSet $a.Id -Page 'js/new.js' -Shoot { param($o) '' } -Now $now.AddMinutes(2)
        $r.summary | Should Match 'did not exist before change set'
    }
}

Describe 'PageCompare module text' {
    It 'is ASCII only' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $root 'lib\PageCompare.psm1'))
        @($bytes | Where-Object { $_ -gt 127 -or $_ -eq 8 }).Count | Should Be 0
    }
}

Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
