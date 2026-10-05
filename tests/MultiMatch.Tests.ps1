# A SEARCH text that is in the file more than once (Find-EditTarget, Get-EditResult, Protocol
# Get-EditPairs, Agent read ranges): SEARCH all, SEARCH line N, the next match after the previous
# change, the only match in the lines Copilot read, else a soft stop that says how to point.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$text = "<div>`n</div>`nx`n<p>a</p>`n<div>`n</div>`ny`n<div>`n</div>"   # <div> on lines 1, 5 and 8

Describe 'The marker line says which match is meant' {
    It 'reads SEARCH line N and SEARCH all' {
        $p = @(& (Get-Module Protocol) { param($t) Get-EditPairs $t } "<<<<<<< SEARCH line 812`nold`n=======`nnew`n>>>>>>> REPLACE`n<<<<<<< SEARCH all`na`n=======`nb`n>>>>>>> REPLACE`n<<<<<<< SEARCH`nc`n=======`nd`n>>>>>>> REPLACE")
        $p[0].line | Should Be 812
        $p[1].all | Should Be $true
        $p[2].ContainsKey('line') | Should Be $false
        $p[2].ContainsKey('all') | Should Be $false
    }
}

Describe 'Find-EditTarget with several matches' {
    $s = "<div>`n</div>"
    It 'takes the match nearest a given line' {
        $h = & (Get-Module Executor) { param($t, $x) Find-EditTarget $t $x -NearLine 6 } $text $s
        (& (Get-Module Executor) { param($t, $i) Get-LineNumber $t $i } $text $h.start) | Should Be 5
        $h.note | Should Match 'nearest to line 6'
    }
    It 'takes the only match in the lines read, and stops softly when more than one is there' {
        $h = & (Get-Module Executor) { param($t, $x) Find-EditTarget $t $x -ReadRanges @(@{ from = 4; to = 6 }) } $text $s
        (& (Get-Module Executor) { param($t, $i) Get-LineNumber $t $i } $text $h.start) | Should Be 5
        $h.note | Should Match 'the only one in the lines you read'
        $amb = & (Get-Module Executor) { param($t, $x) Find-EditTarget $t $x -ReadRanges @(@{ from = 1; to = 9 }) } $text $s
        $amb.ambiguous | Should Be $true
        $amb.error | Should Match 'SEARCH line NUMBER'
    }
    It 'returns every match for SEARCH all' {
        $h = & (Get-Module Executor) { param($t, $x) Find-EditTarget $t $x -All } $text $s
        $h.all | Should Be $true
        @($h.hits).Count | Should Be 3
    }
}

Describe 'Editing a file with repeated text' {
    $p = Join-Path $env:TEMP ('ccb-multi-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    $f = Join-Path $p 'page.html'
    It 'changes every match for SEARCH all' {
        [IO.File]::WriteAllText($f, $text)
        $r = & (Get-Module Executor) { param($pp, $e) Get-EditResult $pp 'page.html' $e } $p @(@{ search = "<div>`n</div>"; replace = '<section></section>'; all = $true })
        $r.ok | Should Be $true
        ([regex]::Matches($r.new, '<section></section>')).Count | Should Be 3
        @($r.notes)[0] | Should Match 'changed all 3 places'
    }
    It 'stops softly, changing nothing, when nothing shows which match is meant' {
        [IO.File]::WriteAllText($f, $text)
        $r = & (Get-Module Executor) { param($pp, $e) Get-EditResult $pp 'page.html' $e } $p @(@{ search = "<div>`n</div>"; replace = 'z' })
        $r.ok | Should Be $false
        $r.ambiguous | Should Be $true
        $r.error | Should Not Match 'Read the file again'
    }
    It 'uses the lines Copilot read in this task (agent)' {
        [IO.File]::WriteAllText($f, $text)
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $null = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'read'; arg = ''; body = 'page.html:4-6' }) 'r1' $null 0 } $s
        $edits = @(@{ search = "<div>`n</div>"; replace = '<section></section>' })
        $r = & (Get-Module Agent) { param($st, $e) Invoke-AgentAction $st ([pscustomobject]@{ type = 'edit'; arg = 'page.html'; edits = $e; body = ''; closed = $true }) 'e1' $null 0 } $s $edits
        $r.ok | Should Be $true
        [IO.File]::ReadAllText($f) | Should Be "<div>`n</div>`nx`n<p>a</p>`n<section></section>`ny`n<div>`n</div>"
    }
    It 'shows a stop as needing a more exact SEARCH, not as failed' {
        [IO.File]::WriteAllText($f, $text)
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $edits = @(@{ search = "<div>`n</div>"; replace = 'z' })
        $null = & (Get-Module Agent) { param($st, $e) Invoke-AgentAction $st ([pscustomobject]@{ type = 'edit'; arg = 'page.html'; edits = $e; body = ''; closed = $true }) 'e2' $null 0 } $s $edits
        (@($s.Events | Where-Object { $_.type -eq 'action' }) | Select-Object -Last 1).status | Should Be 'ambiguous'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
