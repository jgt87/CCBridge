# Edit blocks in the forms Copilot actually sends.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

function Edit([string]$Body) { "````````edit index.html`n$Body`n````````" }

Describe 'Edit blocks' {
    It 'reads the standard form' {
        $a = @(Get-ActionBlocks (Edit "<<<<<<< SEARCH`n<style>a{}</style>`n=======`n<link rel=""stylesheet"" href=""style.css"">`n>>>>>>> REPLACE"))
        $a[0].edits.Count | Should Be 1
        $a[0].edits[0].search | Should BeExactly '<style>a{}</style>'
        $a[0].edits[0].replace | Should BeExactly '<link rel="stylesheet" href="style.css">'
    }
    It 'reads markers written as &lt; and &gt;' {
        $a = @(Get-ActionBlocks (Edit "&lt;&lt;&lt;&lt;&lt;&lt;&lt; SEARCH`nold`n=======`nnew`n&gt;&gt;&gt;&gt;&gt;&gt;&gt; REPLACE"))
        $a[0].edits.Count | Should Be 1
        $a[0].edits[0].search | Should BeExactly 'old'
        $a[0].edits[0].replace | Should BeExactly 'new'
    }
    It 'reads indented markers' {
        $a = @(Get-ActionBlocks (Edit "  <<<<<<< SEARCH`nold`n  =======`nnew`n  >>>>>>> REPLACE"))
        $a[0].edits[0].search | Should BeExactly 'old'
        $a[0].edits[0].replace | Should BeExactly 'new'
    }
    It 'accepts a missing REPLACE marker before the next pair and at the end' {
        $a = @(Get-ActionBlocks (Edit "<<<<<<< SEARCH`na`n=======`nb`n<<<<<<< SEARCH`nc`n=======`nd"))
        $a[0].edits.Count | Should Be 2
        $a[0].edits[0].replace | Should BeExactly 'b'
        $a[0].edits[1].search | Should BeExactly 'c'
        $a[0].edits[1].replace | Should BeExactly 'd'
    }
    It 'keeps several pairs and a removal (empty replacement)' {
        $a = @(Get-ActionBlocks (Edit "<<<<<<< SEARCH`n<style>`nbody{}`n</style>`n=======`n>>>>>>> REPLACE`n<<<<<<< SEARCH`n</head>`n=======`n<link href=""s.css"">`n</head>`n>>>>>>> REPLACE"))
        $a[0].edits.Count | Should Be 2
        $a[0].edits[0].search | Should BeExactly "<style>`nbody{}`n</style>"
        $a[0].edits[0].replace | Should BeExactly ''
        $a[0].edits[1].replace | Should BeExactly "<link href=""s.css"">`n</head>"
    }
    It 'keeps ======= lines that are file content outside a pair' {
        $a = @(Get-ActionBlocks (Edit "<<<<<<< SEARCH`nTitle`n=======`nNew title`n>>>>>>> REPLACE"))
        $a[0].edits.Count | Should Be 1
    }
}

Describe 'Action as the first line of a plain code block' {
    It 'reads "read PATH" in a block without an action name' {
        $a = @(Get-ActionBlocks "Let me look first:`n```````n read index.html`n``````")
        $a.Count | Should Be 1
        $a[0].type | Should Be 'read'
        $a[0].arg | Should Be 'index.html'
    }
    It 'reads an edit whose name is on the first line of a text block' {
        $a = @(Get-ActionBlocks "````````text`nedit index.html`n<<<<<<< SEARCH`nold`n=======`nnew`n>>>>>>> REPLACE`n````````")
        $a[0].type | Should Be 'edit'
        $a[0].arg | Should Be 'index.html'
        $a[0].edits[0].replace | Should Be 'new'
    }
    It 'leaves ordinary code blocks alone' {
        @(Get-ActionBlocks "``````js`nread(file)`n``````").Count | Should Be 0
        @(Get-ActionBlocks "```````nconsole.log(1)`n``````").Count | Should Be 0
    }
}
Describe 'Edits whose SEARCH text matches several places' {
    $proj = Join-Path $env:TEMP ('ccb-ambig-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $proj | Out-Null
    $f = Join-Path $proj 'index.html'
    It 'takes the first match after the previous change and says so' {
        [IO.File]::WriteAllText($f, "<head>`n<style>a{}</style>`n</head>`n<div>`n</div>`n<script>`n</script>`n<div>`n</div>")
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = '<script>'; replace = '<script src="app.js">' }, @{ search = "<div>`n</div>"; replace = '<section></section>' }) $null
        $out | Should Match 'matched 2 places \(lines 4, 8\); changed the one at line 8'
        $text = [IO.File]::ReadAllText($f)
        $text | Should Match "<div>`n</div>`n<script src=""app.js"">`n</script>`n<section></section>$"
    }
    It 'lists the lines of every match when there is no previous change, and changes nothing' {
        [IO.File]::WriteAllText($f, "<div>`n</div>`nx`n<div>`n</div>")
        { Invoke-EditAction $proj 'index.html' @(@{ search = "<div>`n</div>"; replace = 'y' }) $null } | Should Throw 'matches 2 places (lines 1, 4)'
        [IO.File]::ReadAllText($f) | Should BeExactly "<div>`n</div>`nx`n<div>`n</div>"
    }
    Remove-Item $proj -Recurse -Force
}