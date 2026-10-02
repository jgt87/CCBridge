# Targeted reads: line ranges, cutting at whole lines, and how results share the budget.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$proj = Join-Path $env:TEMP ('ccb-reads-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $proj | Out-Null
$lines = 1..400 | ForEach-Object { "line $_ " + ('x' * 40) }
[IO.File]::WriteAllText((Join-Path $proj 'index.html'), ($lines -join "`n"))

Describe 'Invoke-ReadAction' {
    It 'shows a whole small file without a range note' {
        [IO.File]::WriteAllText((Join-Path $proj 'small.txt'), "a`nb")
        $out = @(Invoke-ReadAction $proj @('small.txt'))[0]
        $out | Should Match '^### small\.txt\n````\na\nb\n````$'
    }
    It 'reads a line range' {
        $out = @(Invoke-ReadAction $proj @('index.html:181-183'))[0]
        $out | Should Match '^### index\.html \(lines 181-183 of 400\)'
        $out | Should Match 'line 181 x'
        $out | Should Match 'line 183 x'
        $out | Should Not Match 'line 184 '
        $out | Should Not Match 'cut to fit'
    }
    It 'reads from a line to the end' {
        $out = @(Invoke-ReadAction $proj @('index.html:399-'))[0]
        $out | Should Match '\(lines 399-400 of 400\)'
    }
    It 'cuts at a whole line and says how to read the rest' {
        $out = @(Invoke-ReadAction $proj @('index.html') -MaxCharsPerFile 1000)[0]
        $out | Should Match '\(lines 1-\d+ of 400\)'
        $out | Should Match 'Read index\.html:\d+-400 for the rest'
        $out | Should Match '````\n\(cut to fit'
    }
}

Describe 'Format-ActionResults' {
    It 'gives the files read the budget and keeps other output short' {
        $state = @{ Config = [pscustomobject]@{ resultCharBudget = 12000 }; ProjectRoot = $proj }
        $full = (Invoke-ReadAction $proj @('index.html') -MaxCharsPerFile 200000) -join "`n`n"
        $results = @(
            @{ head = '### 1. read index.html'; output = $full; readPaths = @('index.html') },
            @{ head = '### 2. run'; output = ('o' * 20000); readPaths = $null }
        )
        $msg = & (Get-Module Agent) { param($s, $r) Format-ActionResults $s $r } $state $results
        $msg | Should Match '### 1\. read index\.html\n### index\.html \(lines 1-\d+ of 400\)'
        $msg | Should Match 'Read index\.html:\d+-400 for the rest'
        $msg | Should Match '### 2\. run\no+\n\(truncated: 14000 more characters\)'
    }
}

Describe '@file:START-END in a message' {
    It 'attaches only the lines asked for' {
        $att = & (Get-Module Agent) { param($p) Get-PinnedFiles $p 'Look at @index.html:10-12 please' } $proj
        $att | Should Match '### index\.html \(lines 10-12 of 400\)'
        $att | Should Not Match 'line 13 '
    }
}

Remove-Item $proj -Recurse -Force

Describe 'Invoke-GrepAction' {
    It 'searches literally when the pattern is not a valid regular expression' {
        $p = Join-Path $env:TEMP ('ccb-grep-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $p | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'index.html'), "<script>`nfetch('calendar.json')`n</script>")
        $out = Invoke-GrepAction $p 'fetch(' ''
        $out | Should Match 'searched for the text literally'
        $out | Should Match 'index\.html:2: fetch\('
        (Invoke-GrepAction $p 'fetch\(|script' '') | Should Not Match 'literally'
        Remove-Item $p -Recurse -Force
    }
}
Describe 'Consistency review after big changes' {
    $proj = Join-Path $env:TEMP ('ccb-review-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $proj | Out-Null
    It 'finds broken references and invalid JSON, and accepts what is fine' {
        [IO.File]::WriteAllText((Join-Path $proj 'index.html'), "<link rel=""stylesheet"" href=""styles.css"">`n<script src=""app.js""></script>`n<script>fetch('calendar-data.json')</script>`n<a href=""https://example.com"">x</a>")
        [IO.File]::WriteAllText((Join-Path $proj 'styles.css'), 'body { background: url("img/bg.png"); }')
        [IO.File]::WriteAllText((Join-Path $proj 'calendar-data.json'), '{ "meetings": [ }')
        $issues = @(Test-ProjectConsistency $proj @('index.html', 'styles.css', 'calendar-data.json'))
        ($issues -join "`n") | Should Match 'index\.html: refers to app\.js, which does not exist'
        ($issues -join "`n") | Should Match 'styles\.css: refers to img/bg\.png'
        ($issues -join "`n") | Should Match 'calendar-data\.json: not valid JSON'
        ($issues -join "`n") | Should Not Match 'styles\.css, which|example\.com'
    }
    It 'measures what a checkpoint changed' {
        $f = Join-Path $proj 'page.html'
        [IO.File]::WriteAllText($f, (1..30 | ForEach-Object { "line $_" }) -join "`n")
        $cp = New-Checkpoint $proj 'test'
        $null = Invoke-WriteAction $proj 'page.html' ((1..5 | ForEach-Object { "line $_" }) -join "`n") $cp
        $null = Invoke-WriteAction $proj 'moved.css' ((1..25 | ForEach-Object { "rule $_" }) -join "`n") $cp
        $ch = @(Get-CheckpointChanges $proj $cp)
        ($ch | Where-Object path -eq 'page.html').removed | Should Be 25
        ($ch | Where-Object path -eq 'moved.css').created | Should Be $true
        $state = @{ Config = [pscustomobject]@{ reviewAfterChanges = 'big'; reviewMinLines = 400 }; Mode = 'ask' }
        (& (Get-Module Agent) { param($s, $c) Test-NeedsReview $s $c } $state $ch) | Should Be $true    # moved out
        $state.Config.reviewAfterChanges = 'off'
        (& (Get-Module Agent) { param($s, $c) Test-NeedsReview $s $c } $state $ch) | Should Be $false
    }
    Remove-Item $proj -Recurse -Force
}
Describe 'Get-FileOutline' {
    It 'outlines an HTML page with style and script blocks' {
        $html = "<html>`n<head>`n<title>x</title>`n<style>`nbody{}`n.a{}`n</style>`n</head>`n<body>`n<h1>Calendar</h1>`n<div id=""list""></div>`n<script>`nfunction loadMeetings() {`n}`nconst render = (m) => {`n};`n</script>`n</body>`n</html>"
        $o = @(Get-FileOutline $html 'index.html')
        ($o -join "`n") | Should Match '(?m)^2  <head>'
        ($o -join "`n") | Should Match '(?m)^4-7  <style> block'
        ($o -join "`n") | Should Match '(?m)^10  <h1> Calendar'
        ($o -join "`n") | Should Match '(?m)^11  <div id="list">'
        ($o -join "`n") | Should Match '(?m)^13    function loadMeetings \(in script\)'
        ($o -join "`n") | Should Match '(?m)^15    function render'
        ($o -join "`n") | Should Match '(?m)^12-17  <script> block'
    }
    It 'outlines CSS and JavaScript' {
        (@(Get-FileOutline "/* Layout */`n.page {`n  margin: 0;`n}`n@media (max-width: 600px) {`n}" 'styles.css') -join "`n") | Should Match '1  /\* Layout \*/[\s\S]*2  \.page[\s\S]*5  @media \(max-width: 600px\)'
        (@(Get-FileOutline "export async function load() {}`nclass Cal {}" 'app.js') -join "`n") | Should Match '1  function load[\s\S]*2  class Cal'
    }
    It 'is offered with read PATH:outline and after a cut' {
        $p = Join-Path $env:TEMP ('ccb-ol-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $big = "<html>`n<head>`n<style>`n" + ((1..300 | ForEach-Object { ".r$_ { margin: 0; }" }) -join "`n") + "`n</style>`n</head>`n<body>`n<h1>T</h1>`n</body>`n</html>"
        [IO.File]::WriteAllText((Join-Path $p 'index.html'), $big)
        @(Invoke-ReadAction $p @('index.html:outline'))[0] | Should Match '### index\.html \(outline, 309 lines\)[\s\S]*3-304  <style> block'
        $cut = @(Invoke-ReadAction $p @('index.html') -MaxCharsPerFile 800)[0]
        $cut | Should Match 'Outline of index\.html:[\s\S]*3-304  <style> block'
        Remove-Item $p -Recurse -Force
    }
}