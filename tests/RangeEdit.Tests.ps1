# Edits by line range (ACTION edit PATH:START-END, no SEARCH): parsed by Protocol, applied by
# Executor, allowed by Agent only for lines read in this task while the file is still as read; the
# stale note on a failed edit; the whole-file fallback after the second failed edit. Made-up files.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'Protocol', 'Executor', 'Agent') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$fence = '````'

Describe 'Parsing a line-range edit' {
    It 'reads ACTION edit PATH:START-END with the new lines, with or without the REPLACE and END markers' {
        $a = @(Get-ActionBlocks "${fence}text`nACTION edit js/app.js:3-4`n  return 2;`n  // done`n$fence")
        $a[0].type | Should Be 'edit'
        $a[0].arg | Should Be 'js/app.js'
        $a[0].edits[0].range.from | Should Be 3
        $a[0].edits[0].range.to | Should Be 4
        $a[0].edits[0].replace | Should Be "  return 2;`n  // done"
        $b = @(Get-ActionBlocks "${fence}text`nACTION edit js/app.js:3-3`n####### REPLACE`n  return 2;`n####### END`n$fence")
        $b[0].edits[0].replace | Should Be '  return 2;'
        $b[0].edits[0].range.to | Should Be 3
        # A SEARCH marker in the body: an ordinary edit of the file, the range on the path ignored.
        $c = @(Get-ActionBlocks "${fence}text`nACTION edit js/app.js:3-4`n####### SEARCH`nreturn 1;`n####### REPLACE`nreturn 2;`n####### END`n$fence")
        $c[0].arg | Should Be 'js/app.js'
        $c[0].edits[0].search | Should Be 'return 1;'
        $c[0].edits[0].ContainsKey('range') | Should Be $false
    }
}

Describe 'Applying line ranges' {
    $p = Join-Path $env:TEMP ('ccb-range-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    $text = "function a() {`n  return 1;`n}`nfunction b() {`n  return 2;`n}`n"
    It 'replaces the lines, bottom up, and SEARCH pairs after them; refuses lines outside the file and overlaps' {
        [IO.File]::WriteAllText((Join-Path $p 'app.js'), $text)
        $r = Get-EditResult $p 'app.js' @(@{ search = $null; replace = '  return 10;'; range = @{ from = 2; to = 2 } }, @{ search = $null; replace = "  return 20;`n  // b"; range = @{ from = 5; to = 5 } }, @{ search = 'function b()'; replace = 'function bb()' })
        $r.ok | Should Be $true
        $r.new.Replace("`r`n", "`n") | Should Be "function a() {`n  return 10;`n}`nfunction bb() {`n  return 20;`n  // b`n}`n"
        ($r.notes -join ';') | Should Match 'lines 5-5 replaced by line range'
        (Get-EditResult $p 'app.js' @(@{ search = $null; replace = 'x'; range = @{ from = 9; to = 9 } })).error | Should Match 'lines 9-9 are not in the file \(7 lines\)'
        (Get-EditResult $p 'app.js' @(@{ search = $null; replace = 'x'; range = @{ from = 1; to = 3 } }, @{ search = $null; replace = 'y'; range = @{ from = 3; to = 4 } })).error | Should Match 'overlap another range'
        # An empty replacement deletes the lines.
        (Get-EditResult $p 'app.js' @(@{ search = $null; replace = ''; range = @{ from = 4; to = 6 } })).new.Replace("`r`n", "`n") | Should Be "function a() {`n  return 1;`n}`n"
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'When a line-range edit is allowed (Agent)' {
    $p = Join-Path $env:TEMP ('ccb-rangea-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    $text = "function a() {`n  return 1;`n}`nfunction b() {`n  return 2;`n}`n"
    [IO.File]::WriteAllText((Join-Path $p 'app.js'), $text)
    $config = Get-CCBridgeConfig harness $root; $config.pageCheck = 'off'
    $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
    $act = { param($type, $arg, $edits, $body) [pscustomobject]@{ type = $type; arg = $arg; edits = $edits; body = "$body"; closed = $true } }
    $run = { param($st, $a) & (Get-Module Agent) { param($st, $a) Invoke-AgentAction $st $a 'a1' $null 0 } $st $a }
    It 'needs a read of the lines first, then applies the edit; after a change the numbers are stale' {
        $r = & $run $s (& $act 'edit' 'app.js' @(@{ search = $null; replace = '  return 10;'; range = @{ from = 2; to = 2 } }))
        $r.ok | Should Be $false
        $r.output | Should Match 'needs the lines read in this task first'
        $null = & $run $s (& $act 'read' 'app.js:1-3' @() '')
        $r = & $run $s (& $act 'edit' 'app.js' @(@{ search = $null; replace = '  return 10;'; range = @{ from = 2; to = 2 } }))
        $r.ok | Should Be $true
        [IO.File]::ReadAllText((Join-Path $p 'app.js')).Replace("`r`n", "`n") | Should Be "function a() {`n  return 10;`n}`nfunction b() {`n  return 2;`n}`n"
        # The file changed (by that edit): the same numbers are refused with the current lines.
        $r = & $run $s (& $act 'edit' 'app.js' @(@{ search = $null; replace = '  return 11;'; range = @{ from = 2; to = 2 } }))
        $r.ok | Should Be $false
        $r.output | Should Match 'changed since your read'
        $r.output | Should Match 'Current lines 2-2 of app.js'
        $r.output | Should Match 'return 10;'
        # Lines outside what was read are refused; a whole-file read covers everything.
        $null = & $run $s (& $act 'read' 'app.js:1-3' @() '')
        (& $run $s (& $act 'edit' 'app.js' @(@{ search = $null; replace = '  return 20;'; range = @{ from = 5; to = 5 } }))).output | Should Match 'were not among the lines you read'
        $null = & $run $s (& $act 'read' 'app.js' @() '')
        (& $run $s (& $act 'edit' 'app.js' @(@{ search = $null; replace = '  return 20;'; range = @{ from = 5; to = 5 } }))).ok | Should Be $true
    }
    It 'notes on a failed edit that the file changed since Copilot last saw it, only after an outside change' {
        $null = & $run $s (& $act 'read' 'app.js' @() '')
        $r = & $run $s (& $act 'edit' 'app.js' @(@{ search = 'return 99;'; replace = 'return 98;' }))
        $r.ok | Should Be $false
        $r.output | Should Not Match 'changed since you last saw it'
        # The helper program (or anyone) changes the file after the read.
        [IO.File]::WriteAllText((Join-Path $p 'app.js'), ([IO.File]::ReadAllText((Join-Path $p 'app.js')) + "// repaired`n"))
        $r = & $run $s (& $act 'edit' 'app.js' @(@{ search = 'return 99;'; replace = 'return 98;' }))
        $r.output | Should Match 'Note: app.js changed since you last saw it'
        (& (Get-Module Agent) { Get-StepFailureInfo 'edit' 'app.js changed since your read' }).code | Should Be 'EDIT-STALE'
    }
    It 'sends the whole file for a small file, a pointer for a one-file page, nothing for a large file' {
        $w = Get-WholeFileFallback $p 'app.js'
        $w | Should Match '^The whole file as it is now \(\d+ lines\) is below\. Reply with one write block \(ACTION write app.js\)'
        $w | Should Match 'function b\(\)'
        [IO.File]::WriteAllText((Join-Path $p 'big.js'), (("// line`n" * 450)))
        Get-WholeFileFallback $p 'big.js' | Should Be ''
        [IO.File]::WriteAllText((Join-Path $p 'page.html'), "<!doctype html><html><head><style data-streamhub=""kit"">`n.kit-btn{}`n</style></head><body><p>x</p></body></html>")
        Get-WholeFileFallback $p 'page.html' | Should Match 'cannot be rewritten whole'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
