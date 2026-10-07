# Checks added after a review of real sessions (all generic, made-up project content): new files that
# nothing loads, the UI kit's tokens used without loading them, custom properties nobody defines,
# HTML tags written escaped in scripts, helper scripts that write a whole copy of a page, disputes
# without a reason, and the final checks when a task ends without "done".
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Lint', 'Imports', 'UiKit', 'AutoFix', 'Guardrails', 'Executor', 'Agent', 'Config') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

function New-WebProject {
    $p = Join-Path $env:TEMP ('ccb-rf-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory (Join-Path $p 'js'), (Join-Path $p 'css') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'index.html'), "<!doctype html><html><head><link rel=`"stylesheet`" href=`"css/site.css`"></head><body><div id=`"app`"></div><script src=`"js/app.js`"></script></body></html>")
    [IO.File]::WriteAllText((Join-Path $p 'js\app.js'), "import { load } from './store.js';`nload();")
    [IO.File]::WriteAllText((Join-Path $p 'js\store.js'), "export function load() {}")
    [IO.File]::WriteAllText((Join-Path $p 'css\site.css'), ".a { color: red; }")
    $p
}

Describe 'New files that nothing loads' {
    It 'reports a new script no page or script uses, and not one that is imported or named' {
        $p = New-WebProject
        [IO.File]::WriteAllText((Join-Path $p 'js\cache.js'), "window.Cache = {};")
        [IO.File]::WriteAllText((Join-Path $p 'js\worker-helper.js'), "self.x = 1;")
        [IO.File]::WriteAllText((Join-Path $p 'js\app.js'), "import { load } from './store.js';`nnew Worker('js/worker-helper.js');`nload();")
        [IO.File]::WriteAllText((Join-Path $p 'vite.config.js'), "export default {}")
        $null = Update-ImportIndex $p
        @(Find-UnloadedFiles $p @('js/cache.js', 'js/store.js', 'js/worker-helper.js', 'vite.config.js')) -join ',' | Should Be 'js/cache.js'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'says nothing in a project without a page' {
        $p = Join-Path $env:TEMP ('ccb-rf-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'tool.js'), "console.log(1)")
        @(Find-UnloadedFiles $p @('tool.js')) | Should BeNullOrEmpty
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The UI kit''s tokens used without loading them' {
    It 'names the page and the link to add, and accepts a link or an import' {
        $p = New-WebProject
        New-Item -ItemType Directory (Join-Path $p 'styles\kit') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'styles\kit\tokens.css'), ':root { --kit-accent: #123; }')
        [IO.File]::WriteAllText((Join-Path $p 'css\site.css'), ".a { color: var(--kit-accent); }")
        $r = @(Find-UnlinkedKitTokens $p @('css/site.css'))
        $r.Count | Should Be 1
        $r[0] | Should Match '^index\.html: uses the UI kit''s colours .* add <link rel="stylesheet" href="styles/kit/tokens\.css">'
        [IO.File]::WriteAllText((Join-Path $p 'index.html'), (Get-Content (Join-Path $p 'index.html') -Raw).Replace('<link rel="stylesheet" href="css/site.css">', '<link rel="stylesheet" href="styles/kit/tokens.css"><link rel="stylesheet" href="css/site.css">'))
        @(Find-UnlinkedKitTokens $p @('index.html')) | Should BeNullOrEmpty
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Custom properties nobody defines' {
    It 'reports var(--name) without a value, with a close name, and skips fallbacks and libraries' {
        $p = New-WebProject
        [IO.File]::WriteAllText((Join-Path $p 'css\theme.css'), ':root { --brand-color: #123; --space-2: 8px; }')
        $css = ".a { color: var(--brand-colour); margin: var(--space-2); padding: var(--gap, 4px); width: var(--tw-ring-offset-width); }"
        $r = @(Find-UndefinedCssVars $css 'css/site.css' $p)
        $r.Count | Should Be 1
        $r[0] | Should Match 'var\(--brand-colour\) is not defined anywhere in the project'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'HTML tags written escaped in scripts' {
    $page = "<!doctype html><html><body><script>`nfunction esc(s) { return s.replace(/</g, '&lt;'); }`nconst html = '&lt;span class=&quot;x&quot;&gt;Join&lt;/span&gt;';`n</script><script type=`"text/template`">&lt;b&gt;</script></body></html>"
    It 'finds a whole escaped tag in a page''s script, not an escape function or a template block' {
        $r = @(Test-FileContent 'index.html' $page)
        ($r -join ' ') | Should Match 'line 3: 2 HTML tag\(s\) written escaped in a script'
        @(Find-EscapedScriptTags 'index.html' $page).Count | Should Be 2
        @(Find-EscapedScriptTags 'notes.md' $page).Count | Should Be 0
    }
    It 'writes them as tags in the fix-up step' {
        $fix = Repair-MechanicalIssues 'index.html' $page
        $fix.text | Should Match "const html = '<span class=`"x`">Join</span>';"
        $fix.text | Should Match "s\.replace\(/</g, '&lt;'\)"
        $fix.text | Should Match 'text/template">&lt;b&gt;'
        @(Find-EscapedScriptTags 'app.js' "el.innerHTML = '&lt;div&gt;x&lt;/div&gt;';").Count | Should Be 2
    }
}

Describe 'Helper scripts that write a whole page' {
    It 'warns that running it again undoes later changes' {
        $body = (1..30 | ForEach-Object { "  <div class=`"row`">$_</div>" }) -join "`n"
        $ps = "`$html = @'`n<html>`n<body>`n$body`n</body>`n</html>`n'@`nSet-Content -Path index.html -Value `$html"
        Find-PageCopyScript 'Work/write-index.ps1' '' $ps | Should Match 'writes a whole copy of index\.html'
        Find-PageCopyScript 'src/app.ps1' '' $ps | Should BeNullOrEmpty
        Find-PageCopyScript 'Work/small.ps1' '' "Set-Content index.html '<p>x</p>'" | Should BeNullOrEmpty
    }
}

Describe 'Disputes' {
    $p = New-WebProject
    $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
    $s.ProjectRoot = $p
    $run = { param($body) & (Get-Module Agent) { param($st, $b) Invoke-AgentAction $st ([pscustomobject]@{ type = 'dispute'; arg = 'js/app.js'; body = $b }) 'd1' $null 0 } $s $body }
    It 'needs a reason, and does not accept one against a measurement' {
        (& $run 'line 3: unused variable x').output | Should Match 'say why the finding is wrong'
        (& $run "the file now has 612 lines (over 400): split it`nit is fine").output | Should Match 'is a measurement'
        $ok = & $run "line 3: unused variable x`nit is used by the page through window"
        $ok.ok | Should Be $true
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Checks when a task ends without done' {
    It 'checks the changed files, reports new files nothing loads, and offers Continue' {
        $p = New-WebProject
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s.ProjectRoot = $p
        $cp = New-Checkpoint $p 'test'
        $new = Join-Path $p 'js\cache.js'
        Save-CheckpointFile $cp $p $new
        [IO.File]::WriteAllText($new, "window.Cache = { get() { return 1; }")
        $null = Update-ImportIndex $p
        Mock -ModuleName Agent Test-WebPage { @('index.html: TypeError: Cannot read properties of null') }
        Mock -ModuleName Agent Test-ScriptSyntax { @() }
        $s.PreviewPort = 1
        $ev = @{ page = $null }
        & (Get-Module Agent) { param($st, $c, $e) Invoke-FinalChecks $st $c $e 'it reached the limit of 10 rounds' } $s $cp $ev
        $card = @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'task-unfinished' })[0]
        $card.text | Should Match 'Copilot did not finish this task \(it reached the limit of 10 rounds\)'
        ($card.findings -join ' ') | Should Match "js/cache\.js: .*'\{' is never closed"
        ($card.findings -join ' ') | Should Match 'page check: index\.html: TypeError'
        ($card.findings -join ' ') | Should Match 'js/cache\.js: written in this task, but no page or script loads it'
        $card.continueText | Should Match '^You stopped before the task was finished'
        $ev.unfinished | Should Be 'it reached the limit of 10 rounds'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
