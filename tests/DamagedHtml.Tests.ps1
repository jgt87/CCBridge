# HTML tags that arrive damaged from the chat (parts stripped or mangled on the way) are not written:
# the edit is refused and Copilot is asked to send it again (Executor Find-DamagedHtmlLine, Agent).
# The damaged lines are the shapes seen in a real reply; the file names are made up.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

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
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
