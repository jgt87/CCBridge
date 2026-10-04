# Coding guardrails, second batch: personal paths, large files and inline data, HTML basics,
# helper scripts, and the reminders at "done".
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Guardrails.psm1') -Force

Describe 'Find-PersonalPaths' {
    It 'reports paths into a user folder that a change adds' {
        $r = @(Find-PersonalPaths 'src/config.js' '' "const dir = 'C:\\Users\\jane\\Documents\\data';`nconst x = 1;")
        $r.Count | Should Be 1
        $r[0] | Should Match '^line 1: an absolute path into a user'
        @(Find-PersonalPaths 'run.py' '' 'p = "/home/jane/data.csv"').Count | Should Be 1
    }
    It 'allows relative paths, variables, public folders, docs and what was already there' {
        @(Find-PersonalPaths 'a.ps1' '' 'Join-Path $env:USERPROFILE ''x''; "C:\Users\Public\x"; %USERPROFILE%').Count | Should Be 0
        @(Find-PersonalPaths 'README.md' '' 'C:\Users\jane\x').Count | Should Be 0
        @(Find-PersonalPaths 'a.js' "p = '/Users/jane/x';" "p = '/Users/jane/x';`nq = 1;").Count | Should Be 0
    }
}

Describe 'Find-LargeCode' {
    It 'reports a code file that a change makes longer than 400 lines, once' {
        $big = (1..450 | ForEach-Object { "const v$_ = compute($_);" }) -join "`n"
        @(Find-LargeCode 'src/app.js' 'const a = 1;' $big)[0] | Should Match 'now has 450 lines'
        @(Find-LargeCode 'src/app.js' $big "$big`nconst z = 0;").Count | Should Be 0
        @(Find-LargeCode 'tests/app.test.js' '' $big).Count | Should Be 0
    }
    It 'reports a large block of inline data, not in data/' {
        $data = "export const rows = [`n" + ((1..150 | ForEach-Object { "  { id: $_, name: `"n$_`" }," }) -join "`n") + "`n];"
        @(Find-LargeCode 'src/app.js' '' $data) -join ' ' | Should Match 'inline data'
        @(Find-LargeCode 'src/data/rows.js' '' $data).Count | Should Be 0
    }
}

Describe 'Find-HtmlBasics' {
    It 'reports images without alt, empty buttons and unlabeled fields' {
        $html = "<img src=`"a.png`">`n<button><svg></svg></button>`n<input id=`"q`" type=`"text`">"
        $r = @(Find-HtmlBasics 'index.html' '' $html)
        $r.Count | Should Be 3
        ($r -join "`n") | Should Match 'line 1: an image without alt'
        ($r -join "`n") | Should Match 'line 2: a button without text'
        ($r -join "`n") | Should Match 'line 3: a form field \(input\) without a label'
    }
    It 'accepts alt, text, aria-label, label for, wrapping labels and hidden fields' {
        $ok = "<img src=`"a.png`" alt=`"`">`n<button aria-label=`"Close`"><svg></svg></button>`n<button>Save</button>`n<label for=`"q`">Search</label><input id=`"q`">`n<label>Name <input name=`"n`"></label>`n<input type=`"hidden`" name=`"t`">"
        @(Find-HtmlBasics 'index.html' '' $ok).Count | Should Be 0
        @(Find-HtmlBasics 'App.tsx' '' '<label htmlFor="q">Q</label><input id="q" />').Count | Should Be 0
        # JSX expressions with > or => inside are part of the tag.
        $jsx = "<label htmlFor=`"s`">Find</label>`n<Input`n  aria-activedescendant={i >= 0 ? ``a`${i}`` : undefined}`n  onChange={(e) => set(e.target.value)}`n  id=`"s`"`n/>"
        @(Find-HtmlBasics 'Bar.tsx' '' $jsx).Count | Should Be 0
        @(Find-HtmlBasics 'Bar.tsx' '' '<input onChange={(e) => go(e)} aria-label="Find" />').Count | Should Be 0
    }
}

Describe 'Find-ScriptBasics' {
    It 'asks a new helper script for a header and to stop on errors' {
        $r = @(Find-ScriptBasics 'Scripts/setup.ps1' '' "Get-ChildItem")
        $r.Count | Should Be 2
        @(Find-ScriptBasics 'Scripts/setup.ps1' '' "# Sets up the data folder. Run: .\Scripts\setup.ps1`n`$ErrorActionPreference = 'Stop'`nGet-ChildItem").Count | Should Be 0
        @(Find-ScriptBasics 'Scripts/go.sh' '' "#!/bin/bash`n# Copies the files.`nset -euo pipefail`ncp a b").Count | Should Be 0
        @(Find-ScriptBasics 'Scripts/go.sh' '' "#!/bin/bash`ncp a b").Count | Should Be 2
    }
    It 'leaves existing scripts and files outside Scripts/ alone' {
        @(Find-ScriptBasics 'Scripts/setup.ps1' 'old' 'Get-ChildItem').Count | Should Be 0
        @(Find-ScriptBasics 'src/app.ps1' '' 'Get-ChildItem').Count | Should Be 0
    }
}

Describe 'Get-DoneReminders' {
    It 'reminds about tests when code changed without a test, in a project with tests' {
        $r = Get-DoneReminders 'C:\p' @{ 'src/app.js' = 'existed' } @('src/app.js', 'tests/app.test.js')
        $r | Should Match 'but no test'
        Get-DoneReminders 'C:\p' @{ 'src/app.js' = 'existed'; 'tests/app.test.js' = 'existed' } @('src/app.js', 'tests/app.test.js') | Should BeNullOrEmpty
        Get-DoneReminders 'C:\p' @{ 'src/app.js' = 'existed' } @('src/app.js') | Should BeNullOrEmpty
    }
    It 'reminds about the README for a new part in src/ or Scripts/' {
        $r = Get-DoneReminders 'C:\p' @{ 'Scripts/export.ps1' = 'new' } @('README.md', 'Scripts/export.ps1')
        $r | Should Match 'README\.md does not mention'
        Get-DoneReminders 'C:\p' @{ 'Scripts/export.ps1' = 'new'; 'README.md' = 'existed' } @('README.md', 'Scripts/export.ps1') | Should BeNullOrEmpty
        Get-DoneReminders 'C:\p' @{ 'notes.md' = 'new' } @('README.md') | Should BeNullOrEmpty
    }
}
