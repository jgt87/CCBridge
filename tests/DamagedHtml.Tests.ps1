# HTML tags that arrive damaged from the chat (parts stripped or mangled on the way) are not written:
# the edit is refused and Copilot is asked to send it again (Executor Find-DamagedHtmlLine, Agent).
# The damaged lines are the shapes seen in a real reply; the file names are made up.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force

Describe 'Find-DamagedHtmlLine' {
    $old = "<head>`n  <link rel=`"stylesheet`" href=`"styles.css`">`n</head>"
    It 'finds tags whose start was stripped or whose quote is never closed' {
        $r = Find-DamagedHtmlLine 'index.html' $old "<head>`n  <link rel=`"stylesheet`" href=`"styles.css`">`n  <script src=`"data/example-manifest.jsd>`n</head>"
        $r.line | Should Be 3
        $r.why | Should Match 'quote in a tag is never closed'
        (Find-DamagedHtmlLine 'index.html' $old "<head>`n  data/example-manifest.jsscript>`n</head>").why | Should Match 'start of a tag is missing'
    }
    It 'accepts correct HTML and JSX, lines the file already had, and other file types' {
        Find-DamagedHtmlLine 'index.html' $old "<head>`n  <script src=`"data/example-manifest.js`"></script>`n  <img src=`"a.png`" alt=`"A`">`n</head>" | Should BeNullOrEmpty
        Find-DamagedHtmlLine 'App.tsx' '' "<button onClick={() => go(`"a`")} className=`"btn`">Go</button>" | Should BeNullOrEmpty
        Find-DamagedHtmlLine 'index.html' "<p>`n  broken.jsscript>`n</p>" "<p>`n  broken.jsscript>`n  <b>ok</b>`n</p>" | Should BeNullOrEmpty
        Find-DamagedHtmlLine 'notes.md' '' 'see <script src="x.jsd>' | Should BeNullOrEmpty
    }
}

Describe 'A damaged HTML edit is refused before it is written' {
    It 'refuses the edit, leaves the file as it was, and asks Copilot to send it again' {
        $p = Join-Path $env:TEMP ('ccb-dmghtml-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $file = Join-Path $p 'index.html'
        $orig = "<html>`n<head>`n  <link rel=`"stylesheet`" href=`"styles.css`">`n</head>`n<body></body>`n</html>`n"
        [IO.File]::WriteAllText($file, $orig)
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $edits = @(@{ search = "  <link rel=`"stylesheet`" href=`"styles.css`">`n</head>"; replace = "  <link rel=`"stylesheet`" href=`"styles.css`">`n  <script src=`"data/example-manifest.jsd>`n</head>" })
        $r = & (Get-Module Agent) { param($st, $e) Invoke-AgentAction $st ([pscustomobject]@{ type = 'edit'; arg = 'index.html'; edits = $e; body = ''; closed = $true }) 'a1' $null 0 } $s $edits
        $r.ok | Should Be $false
        $r.output | Should Match 'arrived damaged'
        $r.output | Should Match 'tell the user the exact line'
        [IO.File]::ReadAllText($file) | Should Be $orig
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Describe 'A script tag stripped to PATH.jsscript> is put back' {
    It 'repairs the address form in page files only, and leaves real text alone' {
        Repair-StrippedScriptTag '  ./data/example-manifest.jsscript>' | Should Be '  <script src="./data/example-manifest.js"></script>'
        Repair-StrippedScriptTag '<head>data/a.jsscript></head>' | Should Be '<head><script src="data/a.js"></script></head>'
        Repair-StrippedScriptTag '<script src="app.js"></script>' | Should Be '<script src="app.js"></script>'
        Repair-StrippedScriptTag 'see the javascript> docs' | Should Be 'see the javascript> docs'
        Repair-CodeText 'web/index.html' 'x/a.jsscript>' | Should Be '<script src="x/a.js"></script>'
        Repair-CodeText 'docs/notes.md' 'x/a.jsscript>' | Should Be 'x/a.jsscript>'
    }
    It 'turns a page part written only as entities back into tags, and leaves real entities and Markdown alone' {
        $esc = "&lt;div class=""kit-panel""&gt;`n  &lt;h2 class=""kit-panel__title""&gt;Users&lt;/h2&gt;`n  &lt;div id=""chart""&gt;&lt;/div&gt;`n&lt;/div&gt;"
        Repair-CodeText 'index.html' $esc | Should Be "<div class=""kit-panel"">`n  <h2 class=""kit-panel__title"">Users</h2>`n  <div id=""chart""></div>`n</div>"
        # A real tag in the text: the entities are content (a code sample).
        Repair-CodeText 'index.html' '<code>&lt;div&gt;</code>' | Should Be '<code>&lt;div&gt;</code>'
        # Entities that are not tags, and Markdown, stay.
        Repair-CodeText 'index.html' 'a &lt; b &gt; c' | Should Be 'a &lt; b &gt; c'
        Repair-CodeText 'README.md' '&lt;div&gt;' | Should Be '&lt;div&gt;'
    }
    It 'fixes the damaged line in the file through an edit whose REPLACE arrived stripped' {
        $p = Join-Path $env:TEMP ('ccb-strip-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $file = Join-Path $p 'index.html'
        [IO.File]::WriteAllText($file, "<html>`n<head>`n  data/example-manifest.jsscript>`n</head>`n<body></body>`n</html>`n")
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $edits = @(@{ search = "  data/example-manifest.jsscript>`n</head>"; replace = "  ./data/example-manifest.jsscript>`n</head>" })
        $r = & (Get-Module Agent) { param($st, $e) Invoke-AgentAction $st ([pscustomobject]@{ type = 'edit'; arg = 'index.html'; edits = $e; body = ''; closed = $true }) 'a1' $null 0 } $s $edits
        $r.ok | Should Be $true
        [IO.File]::ReadAllText($file) | Should Match '  <script src="\./data/example-manifest\.js"></script>
</head>'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'writes a whole page whose script tag arrived stripped, with the tag put back (not refused)' {
        $p = Join-Path $env:TEMP ('ccb-strip-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $page = "<!doctype html>`n<html>`n<head>`n  <meta charset=`"utf-8`">`n  <title>Usage</title>`n</head>`n<body>`n  <p>Usage</p>`n  data/data-tools.jsscript>`n</body>`n</html>`n"
        $r = & (Get-Module Agent) { param($st, $b) Invoke-AgentAction $st ([pscustomobject]@{ type = 'write'; arg = 'index.html'; body = $b; closed = $true }) 'a1' $null 0 } $s $page
        $r.ok | Should Be $true
        [IO.File]::ReadAllText((Join-Path $p 'index.html')) | Should Match '  <script src="data/data-tools\.js"></script>'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Describe 'A reply with a damaged tag is replaced by the page copy of the same reply' {
    It 'recognises damaged tag text and leaves correct HTML and code alone' {
        Test-DamagedTagText "ACTION edit index.html`n  ./data/example.jsscript>`n</head>" | Should Be $true
        Test-DamagedTagText '<script src="./data/example.jsd>' | Should Be $true
        Test-DamagedTagText "<script src=`"./data/example.js`"></script>`n<button onClick={() => go(`"a`")}>Go</button>" | Should Be $false
        Test-DamagedTagText 'if (a < b && c > d) { x = 1; }' | Should Be $false
    }
    It 'takes the page copy when it starts the same and is intact' {
        # The page is replaced inside the module (no Edge): the page copy of the reply is intact.
        $m = @(Get-Module CopilotBridge)[-1]
        $r = & $m {
            function Receive-CdpEvent { $null }
            function Get-PageReplyState { [pscustomobject]@{ stop = $false } }
            function Get-PageReplyText { [pscustomobject]@{ how = 'state'; text = "Fixing it.`n<script src=`"./data/example.js`"></script>" } }
            $bridge = [pscustomobject]@{ Session = $null; Pacing = @{ lateReplySec = 0.1 } }
            Update-LateReply $bridge ([pscustomobject]@{ Text = "Fixing it.`n./data/example.jsscript>"; Uncertain = 0 })
        }
        $r.Text | Should Match '<script src="\./data/example\.js"></script>'
        $r.TagRepaired | Should Be $true
    }
}
Describe 'The HTML file check finds what is left of a damaged tag' {
    It 'reports PATH.jsscript> in a page, not a correct script tag' {
        $bad = @(Test-FileContent 'index.html' "<html>`n<head>`n  data/example-manifest.jsscript>`n</head>`n<body></body>`n</html>`n")
        ($bad -join ' ') | Should Match "line 3: 'data/example-manifest.jsscript>' is what is left of a damaged <script> tag"
        @(Test-FileContent 'index.html' "<html>`n<head>`n  <meta charset=`"utf-8`">`n  <script src=`"data/example-manifest.js`"></script>`n</head>`n<body></body>`n</html>`n").Count | Should Be 0
    }
}
Describe 'An edit whose end marker and script close were eaten' {
    It 'takes </EPLACE, REPLACE alone or >>> as the end marker, not ordinary text' {
        foreach ($m in '</EPLACE', 'EPLACE', 'REPLACE', '>>>', '>>>>>>> REPLACE') { & (Get-Module Protocol) { param($x) Get-EditMarker $x } $m | Should Be 'replace' }
        foreach ($t in 'replace', 'Replace the text', '> quoted', '>>') { & (Get-Module Protocol) { param($x) Get-EditMarker $x } $t | Should BeNullOrEmpty }
        $fence = '````'
        $reply = "${fence}text`nACTION edit index.html`n<<<<<<< SEARCH`n  data/example.jsscript>`n=======`n  <script src=`"data/example.js`">`n</EPLACE`n${fence}"
        $a = @(Get-ActionBlocks $reply)[0]
        $a.edits[0].replace | Should Be '  <script src="data/example.js">'
    }
    It 'closes an added script tag with src whose </script> is missing, and leaves the two-line form alone' {
        Close-LoneScriptTag 'index.html' '' "<head>`n  <script src=`"data/example.js`">`n</head>" | Should Be "<head>`n  <script src=`"data/example.js`"></script>`n</head>"
        Close-LoneScriptTag 'index.html' '' "<script src=`"a.js`" defer>`n</script>" | Should Be "<script src=`"a.js`" defer>`n</script>"
        Close-LoneScriptTag 'index.html' '' '<script>' | Should Be '<script>'
        Close-LoneScriptTag 'index.html' '<script src="old.js">' "<script src=`"old.js`">`nx" | Should Be "<script src=`"old.js`">`nx"
        Close-LoneScriptTag 'notes.md' '' '<script src="a.js">' | Should Be '<script src="a.js">'
    }
}
Describe 'An edit whose start marker was damaged or lost' {
    It 'takes SEARCH or EARCH alone, with leftover arrows, as the start marker, not ordinary text' {
        foreach ($m in 'SEARCH', 'EARCH', '<<< SEARCH', '&lt;&lt;SEARCH', 'SEARCH line 12', '<<<<<<< SEARCH') { & (Get-Module Protocol) { param($x) Get-EditMarker $x } $m | Should Be 'search' }
        foreach ($t in 'search', 'SEARCH the file', 'Search') { & (Get-Module Protocol) { param($x) Get-EditMarker $x } $t | Should BeNullOrEmpty }
    }
    It 'reads a block without a start marker but with one divider as one pair' {
        $p = @(& (Get-Module Protocol) { param($t) Get-EditPairs $t } "`n  elements.caption.textContent = x;`n  render();`n=======`n  render();`n>>>>>>> REPLACE")
        $p.Count | Should Be 1
        $p[0].search | Should Be "  elements.caption.textContent = x;`n  render();"
        $p[0].replace | Should Be '  render();'
    }
    It 'leaves a block with two dividers and no start marker alone (it cannot tell the pairs apart)' {
        @(& (Get-Module Protocol) { param($t) Get-EditPairs $t } "a`n=======`nb`n=======`nc").Count | Should Be 0
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
