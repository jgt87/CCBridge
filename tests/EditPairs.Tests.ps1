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
Describe 'SEARCH text that is not in the file as written' {
    $proj = Join-Path $env:TEMP ('ccb-closest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $proj | Out-Null
    $f = Join-Path $proj 'index.html'
    It 'applies a change whose lines only differ in indentation, and says so' {
        [IO.File]::WriteAllText($f, "<head>`n`t<title>x</title>`n`t<style>`n`t`tbody{}`n`t</style>`n</head>")
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = "  <style>`n    body{}`n  </style>"; replace = '  <link rel="stylesheet" href="styles.css">' }) $null
        $out | Should Match 'matched ignoring indentation'
        [IO.File]::ReadAllText($f) | Should Match '<link rel="stylesheet" href="styles.css">'
        [IO.File]::ReadAllText($f) | Should Not Match 'body\{\}'
    }
    It 'shows the closest current lines when the text is not there' {
        [IO.File]::WriteAllText($f, "<html>`n<head>`n<title>Calendar</title>`n<link rel=""stylesheet"" href=""styles.css"">`n</head>`n<body>`n</body>`n</html>")
        $err = $null
        try { Invoke-EditAction $proj 'index.html' @(@{ search = "<link rel=""stylesheet"" href=""styles.css"">`n<style data-remove-me>"; replace = 'x' }) $null } catch { $err = $_.Exception.Message }
        $err | Should Match 'SEARCH text not found in the file\. The closest place is lines 2-'
        $err | Should Match '<title>Calendar</title>'
        $err | Should Match 'Nothing was changed'
        $err | Should Match ("text is:`n" + '```' + "`n<head>")   # a real code fence, not backticks and an n
        $err | Should Not Match '`n<head>'
    }
    Remove-Item $proj -Recurse -Force
}
Describe 'Changes that were already made' {
    $proj = Join-Path $env:TEMP ('ccb-applied-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $proj | Out-Null
    $f = Join-Path $proj 'index.html'
    $after = "<head>`n  <link rel=""stylesheet"" href=""styles.css"">`n</head>`n<body></body>"
    It 'reports a replacement that is already in the file, with evidence, and writes nothing' {
        [IO.File]::WriteAllText($f, $after)
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = "  <style>`n    body { margin: 0; }`n  </style>"; replace = '  <link rel="stylesheet" href="styles.css">' }) $null
        $out | Should Match '^no change needed: index\.html already contains these changes'
        $out | Should Match 'the new text is already at lines 2-2 and none of the old lines are in the file'
        [IO.File]::ReadAllText($f) | Should BeExactly $after
    }
    It 'reports a removal of text that is no longer there' {
        [IO.File]::WriteAllText($f, $after)
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = "  <style>`n    body { margin: 0; }`n  </style>"; replace = '' }) $null
        $out | Should Match 'removes text that is no longer in the file'
    }
    It 'is still an error when old lines are left (a typo, not a finished change)' {
        [IO.File]::WriteAllText($f, "<style>`n    body { margin: 0; }`n</style>")
        { Invoke-EditAction $proj 'index.html' @(@{ search = "<style>`n    body { margin: 1px; }`n</style>"; replace = '<link rel="stylesheet" href="styles.css">' }) $null } | Should Throw 'not found'
    }
    It 'applies the other changes of a block and lists the ones already made' {
        [IO.File]::WriteAllText($f, $after)
        $out = Invoke-EditAction $proj 'index.html' @(
            @{ search = "  <style>`n    body { margin: 0; }`n  </style>"; replace = '  <link rel="stylesheet" href="styles.css">' },
            @{ search = '<body></body>'; replace = '<body><main></main></body>' }) $null
        $out | Should Match '^edited index\.html \(1 change\(s\)\); pair 1: already applied'
        [IO.File]::ReadAllText($f) | Should Match '<main></main>'
    }
    Remove-Item $proj -Recurse -Force
}
Describe 'Moving code to another file (Test-MoveOrder)' {
    $proj = Join-Path $env:TEMP ('ccb-move-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $proj | Out-Null
    $css = (1..20 | ForEach-Object { "  .rule$_ { margin: ${_}px; }" }) -join "`n"
    $page = "<head>`n<style>`n$css`n</style>`n</head>`n<body></body>"
    $edit = @(@{ search = "<style>`n$css`n</style>"; replace = '<link rel="stylesheet" href="styles.css">' })
    It 'refuses to remove the code while the new file only has a placeholder' {
        [IO.File]::WriteAllText((Join-Path $proj 'index.html'), $page)
        [IO.File]::WriteAllText((Join-Path $proj 'styles.css'), '/* styles moved here */')
        { Invoke-EditAction $proj 'index.html' $edit $null } | Should Throw 'does not contain them yet (only 0 of 22 found)'
        [IO.File]::ReadAllText((Join-Path $proj 'index.html')) | Should BeExactly $page
    }
    It 'refuses when the new file does not exist yet' {
        Remove-Item (Join-Path $proj 'styles.css')
        { Invoke-EditAction $proj 'index.html' $edit $null } | Should Throw 'First write styles.css'
    }
    It 'allows the edit once the new file holds the moved code' {
        [IO.File]::WriteAllText((Join-Path $proj 'styles.css'), $css)
        $out = Invoke-EditAction $proj 'index.html' $edit $null
        $out | Should Match '^edited index\.html'
        [IO.File]::ReadAllText((Join-Path $proj 'index.html')) | Should Match 'href="styles.css"'
    }
    It 'leaves small edits and plain removals alone' {
        [IO.File]::WriteAllText((Join-Path $proj 'index.html'), $page)
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = "<style>`n$css`n</style>"; replace = '' }) $null
        $out | Should Match '^edited index\.html'
    }
    Remove-Item $proj -Recurse -Force
}
Describe 'Long blocks: SEARCH shortened with ..., and half blocks' {
    $proj = Join-Path $env:TEMP ('ccb-long-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $proj | Out-Null
    $f = Join-Path $proj 'index.html'
    $css = (1..30 | ForEach-Object { "    .rule$_ { margin: ${_}px; }" }) -join "`n"
    $page = "<head>`n  <title>x</title>`n  <style>`n$css`n  </style>`n</head>`n<body></body>"
    It 'replaces the whole block between the first and the last lines' {
        [IO.File]::WriteAllText($f, $page)
        [IO.File]::WriteAllText((Join-Path $proj 'x.css'), $css)   # moved code first (see Test-MoveOrder)
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = "  <style>`n    .rule1 { margin: 1px; }`n    ...`n  </style>"; replace = '  <link rel="stylesheet" href="x.css">' }) $null
        $out | Should Match 'SEARCH shortened with \.\.\.'
        $text = [IO.File]::ReadAllText($f)
        $text | Should Not Match 'rule'
        $text | Should Match "<title>x</title>`n  <link rel=""stylesheet"" href=""x.css"">`n</head>"
    }
    It 'accepts /* ... */ and <!-- ... --> as the shortening line' {
        [IO.File]::WriteAllText($f, $page)
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = "  <style>`n    /* ... */`n  </style>"; replace = '' }) $null
        [IO.File]::ReadAllText($f) | Should Not Match 'rule'
    }
    It 'refuses only the first lines of a block (half a block) and changes nothing' {
        [IO.File]::WriteAllText($f, $page)
        $first9 = "  <style>`n" + ((1..8 | ForEach-Object { "    .rule$_ { margin: ${_}px; }" }) -join "`n")
        { Invoke-EditAction $proj 'index.html' @(@{ search = $first9; replace = '  <link rel="stylesheet" href="x.css">' }) $null } | Should Throw 'would leave a <style> block half open'
        [IO.File]::ReadAllText($f) | Should BeExactly $page
    }
    It 'refuses an edit that cuts a { } block in half' {
        # In HTML only the code inside <script> and <style> counts.
        [IO.File]::WriteAllText($f, "<script>`nfunction a() {`n  return 1;`n}`nfunction b() {`n  return 2;`n}`n</script>")
        { Invoke-EditAction $proj 'index.html' @(@{ search = "function a() {`n  return 1;"; replace = '' }) $null } | Should Throw 'would leave a { } block half open'
    }
    It 'allows repairing a file whose blocks are already broken' {
        # An earlier partial edit left CSS rules and a closing </style> without its opening tag.
        [IO.File]::WriteAllText($f, "<head>`n  <link rel=""stylesheet"" href=""x.css"">`n    .rule9 { margin: 9px; }`n    .rule10 { margin: 10px; }`n  </style>`n</head>")
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = "    .rule9 { margin: 9px; }`n    .rule10 { margin: 10px; }`n  </style>"; replace = '' }) $null
        $out | Should Match '^edited'
        [IO.File]::ReadAllText($f) | Should Not Match 'rule9|</style>'
    }
    It 'allows an edit elsewhere in a broken file that does not make it worse' {
        [IO.File]::WriteAllText($f, "<script>`nlet a = 1;`n<body><h1>Old</h1></body>")
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = '<h1>Old</h1>'; replace = '<h1>New</h1>' }) $null
        $out | Should Match '^edited'
    }
    It 'still allows ordinary edits inside a block' {
        [IO.File]::WriteAllText($f, "function a() {`n  return 1;`n}")
        $out = Invoke-EditAction $proj 'index.html' @(@{ search = "function a() {`n  return 1;"; replace = "function a() {`n  return 2;" }) $null
        $out | Should Match '^edited'
    }
    Remove-Item $proj -Recurse -Force
}
Describe 'Get-NextSteps' {
    It 'takes the list under a Next steps heading' {
        $r = "Done with the CSS.`n`n### Next steps`n1. Populate **styles.css** with the extracted CSS`n2. Remove the inline <style> block from index.html`n`nThanks!"
        $s = @(Get-NextSteps $r)
        $s.Count | Should Be 2
        $s[0] | Should BeExactly 'Populate **styles.css** with the extracted CSS'
        $s[1] | Should Match '^Remove the inline'
    }
    It 'understands bold headings, bullets and Dutch' {
        @(Get-NextSteps "**Next steps:**`n- add tests for the parser").Count | Should Be 1
        @(Get-NextSteps "## Volgende stappen`n- voeg de JSON toe aan de pagina")[0] | Should Be 'Voeg de JSON toe aan de pagina'
    }
    It 'takes a "the next step is to ..." sentence' {
        $s = @(Get-NextSteps 'The CSS was removed. The next step is to populate styles.css with the extracted css content, after which index.html only links it.')
        $s[0] | Should Match '^Populate styles\.css with the extracted css content'
    }
    It 'ignores code blocks and replies without next steps' {
        @(Get-NextSteps "``````md`n## Next steps`n- inside code`n``````").Count | Should Be 0
        @(Get-NextSteps 'All done, nothing else to do.').Count | Should Be 0
    }
    It 'keeps at most five' {
        $list = "Next steps:`n" + ((1..8 | ForEach-Object { "- step number $_" }) -join "`n")
        @(Get-NextSteps $list).Count | Should Be 5
    }
}