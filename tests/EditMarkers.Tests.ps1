# The edit markers Copilot is taught: ####### SEARCH / ####### REPLACE / ####### END (Protocol
# Get-EditMarker, Get-EditPairs, Get-ActionBlocks). Whole lines no language uses, without the < >
# the chat can damage. The old <<<<<<< / ======= / >>>>>>> markers are still read.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force
$fence = '````'
function Get-Pairs([string]$Body) { @(& (Get-Module Protocol) { param($t) Get-EditPairs $t } $Body) }

Describe 'The new edit markers' {
    It 'are read from a reply, with line and all hints' {
        $a = @(Get-ActionBlocks "${fence}text`nACTION edit index.html`n####### SEARCH`n<h1>Old</h1>`n####### REPLACE`n<h1>New</h1>`n####### END`n####### SEARCH line 40`nx = 1`n####### REPLACE`nx = 2`n####### END`n####### SEARCH all`nfoo`n####### REPLACE`nbar`n####### END`n${fence}")[0]
        $a.type | Should Be 'edit'
        @($a.edits).Count | Should Be 3
        $a.edits[0].search | Should Be '<h1>Old</h1>'
        $a.edits[0].replace | Should Be '<h1>New</h1>'
        $a.edits[1].line | Should Be 40
        $a.edits[2].all | Should Be $true
    }
    It 'keep lines of other languages as file content' {
        # reStructuredText heading and a merge-conflict-like line inside a new-style edit.
        $p = @(Get-Pairs "####### SEARCH`nTitle`n=======`n####### REPLACE`nNew title`n=========`n####### END")
        $p.Count | Should Be 1
        $p[0].search | Should Be "Title`n======="
        $p[0].replace | Should Be "New title`n========="
        # Comment lines made of # in Python, shell, PowerShell or YAML are no markers.
        $p = @(Get-Pairs "####### SEARCH`n########`n# SEARCH`n####### helper`n####### REPLACE`n## replaced`n####### END")
        $p[0].search | Should Be "########`n# SEARCH`n####### helper"
        $p[0].replace | Should Be '## replaced'
        # Section comments with another number of # are file content too.
        $p = @(Get-Pairs "####### SEARCH`n##### END`n######## SEARCH`n####### REPLACE`n##### END`n####### END")
        $p.Count | Should Be 1
        $p[0].search | Should Be "##### END`n######## SEARCH"
        $p[0].replace | Should Be '##### END'
    }
    It 'still read the old markers' {
        $p = @(Get-Pairs "<<<<<<< SEARCH`nold`n=======`nnew`n>>>>>>> REPLACE")
        $p.Count | Should Be 1
        $p[0].search | Should Be 'old'; $p[0].replace | Should Be 'new'
    }
    It 'are what the prompt teaches' {
        $t = [IO.File]::ReadAllText((Join-Path $root 'prompts\actions.md'))
        $t | Should Match '####### SEARCH'
        $t | Should Not Match '<<<<<<<'
    }
}
