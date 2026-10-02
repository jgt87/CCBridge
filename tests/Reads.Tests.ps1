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