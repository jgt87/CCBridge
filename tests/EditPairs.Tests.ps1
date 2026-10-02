# Edit blocks in the forms Copilot actually sends.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force

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