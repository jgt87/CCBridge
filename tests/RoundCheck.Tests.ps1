# The round's file check (Agent.psm1 Invoke-RoundAutoFix, Invoke-RoundRollbacks, Get-RoundFindings,
# Add-RoundFindings), each on its own: what goes back to Copilot in the round's results, what holds up
# a "done", and what the turn keeps across rounds in its $Turn hashtable. The file checks themselves
# (Lint, Guardrails) are stood in where they would need a real project.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force

function New-RoundState {
    $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
    $s.ProjectRoot = Join-Path $env:TEMP ('ccb-round-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $s.ProjectRoot -Force | Out-Null
    $s.Mode = 'auto'
    $s
}
function New-RoundTurn {
    @{ errorRounds = @{}; errorFirst = @{}; lastErrorKeys = @(); syntaxNudges = 0; warnNudges = 0
        warnedKeys = (New-Object System.Collections.Generic.HashSet[string]); fixTargets = @{}; rollbacks = @{} }
}
function New-Results { New-Object System.Collections.Generic.List[object] }
function New-Finding([string]$Path, [string]$Text, [string]$Source) { & (Get-Module Agent) { param($p, $t, $s) ConvertTo-CheckFinding $p $t $s } $Path $Text $Source }
function Invoke-InAgent([string]$Name) {
    # A function of the module with the arguments after the name, its output kept whole.
    # (No Should in here: in Pester 3.4 it adds $true to this helper's own output.)
    , @(& (Get-Module Agent) { param($n, [object[]]$rest) & $n @rest } $Name $args)
}
$standard = & (Get-Module Agent) { Get-Enforcement 'standard' }
$strict = & (Get-Module Agent) { Get-Enforcement 'strict' }

Describe 'Round check: reporting the findings' {
    Mock -ModuleName Agent Add-ErrorView { }
    Mock -ModuleName Agent Get-FixEvidence { 'EVIDENCE' }
    $err = New-Finding 'js/app.js' 'line 3: a closing brace is missing' 'file'
    $warn = New-Finding 'js/app.js' 'line 9: a debug leftover (console.log)' 'smell'

    It 'holds up done for an error up to the enforcement''s tries and keeps the file as one being fixed' {
        $s = New-RoundState; $t = New-RoundTurn; $r = New-Results; $ev = @{}
        $out = Invoke-InAgent 'Add-RoundFindings' $s $t $r @($err) $ev $standard $true
        $out.Count | Should Be 1
        $out[0] | Should Be $false
        $t.syntaxNudges | Should Be 1
        $t.fixTargets['js/app.js'] | Should Be 3
        @($ev.syntaxLast).Count | Should Be 1
        @($r | Where-Object { $_.head -match 'File check of the files changed' }).Count | Should Be 1
        @($s.Events | Where-Object { $_.type -eq 'checks' }).Count | Should Be 1
        (Invoke-InAgent 'Add-RoundFindings' $s $t $r @($err) $ev $standard $true)[0] | Should Be $false
        (Invoke-InAgent 'Add-RoundFindings' $s $t $r @($err) $ev $standard $true)[0] | Should Be $true   # tries used up
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'sends the evidence and asks for a cause the second time an error is still there, once' {
        $s = New-RoundState; $t = New-RoundTurn; $r = New-Results
        $null = Invoke-InAgent 'Add-RoundFindings' $s $t $r @($err) @{} $standard $false
        @($r | Where-Object { $_.head -match 'Still there' }).Count | Should Be 0
        $null = Invoke-InAgent 'Add-RoundFindings' $s $t $r @($err) @{} $standard $false
        $still = @($r | Where-Object { $_.head -eq '### Still there after your last change: js/app.js' })
        $still.Count | Should Be 1
        $still[0].output | Should Match 'begins with Cause:'
        $still[0].output | Should Match 'EVIDENCE'
        $null = Invoke-InAgent 'Add-RoundFindings' $s $t $r @($err) @{} $standard $false
        @($r | Where-Object { $_.head -match 'Still there' }).Count | Should Be 1
        $t.errorRounds[$err.key] | Should Be 3
        @($t.lastErrorKeys) | Should Be $err.key
        $t.errorFirst[$err.key].text | Should Match 'line 3: a closing brace is missing$'
        Assert-MockCalled -ModuleName Agent Add-ErrorView -Times 1 -Exactly -Scope It   # the code around it, the first time only
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'holds up done once for a likely mistake only under strict' {
        $s = New-RoundState; $t = New-RoundTurn; $r = New-Results
        (Invoke-InAgent 'Add-RoundFindings' $s $t $r @($warn) @{} $standard $true)[0] | Should Be $true
        (Invoke-InAgent 'Add-RoundFindings' $s $t $r @($warn) @{} $strict $true)[0] | Should Be $false
        (Invoke-InAgent 'Add-RoundFindings' $s $t $r @($warn) @{} $strict $true)[0] | Should Be $true
        $t.warnNudges | Should Be 1
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'leaves done alone and the results empty when nothing was found' {
        $s = New-RoundState; $t = New-RoundTurn; $r = New-Results
        (Invoke-InAgent 'Add-RoundFindings' $s $t $r @() @{} $standard $true)[0] | Should Be $true
        $r.Count | Should Be 0
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Round check: collecting the findings' {
    Mock -ModuleName Agent Test-ScriptSyntax { @() }
    Mock -ModuleName Agent Update-ImportsAfterRound { @() }
    Mock -ModuleName Agent Find-UnlinkedKitTokens { @() }
    Mock -ModuleName Agent Find-UnignoredEnv { @() }
    Mock -ModuleName Agent Invoke-ProjectBuild { @() }
    It 'takes hook failures and unknown icons, says a likely mistake once per task, and leaves out a disputed one' {
        $s = New-RoundState; $t = New-RoundTurn
        $cp = @{ Files = @{}; Dir = '' }
        $kit = @{ unknown = @(@{ name = 'trashcan'; like = @('trash', 'trash-2') }) }
        $a = Invoke-InAgent 'Get-RoundFindings' $s $t $cp @{} @('gone.js') @('lint: 2 errors') $kit
        @($a | ForEach-Object { $_.source }) -join ',' | Should Be 'hook,quality'
        ($a | Where-Object source -eq 'quality').text | Should Match "no icon named 'trashcan'; close names: trash, trash-2"
        $b = Invoke-InAgent 'Get-RoundFindings' $s $t $cp @{} @('gone.js') @('lint: 2 errors') $kit
        @($b | ForEach-Object { $_.source }) -join ',' | Should Be 'hook'   # the warning was said already
        $s.CheckDisputes = New-Object System.Collections.Generic.HashSet[string]
        [void]$s.CheckDisputes.Add(@($b)[0].key)
        (Invoke-InAgent 'Get-RoundFindings' $s $t $cp @{} @('gone.js') @('lint: 2 errors') $kit).Count | Should Be 0
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Describe 'Round check: auto-fix and rollbacks' {
    It 'fixes nothing when enforcement says off' {
        $s = New-RoundState
        Set-Content -LiteralPath (Join-Path $s.ProjectRoot 'a.js') -Value "var a = 1;`r`nvar b = 2;`n" -NoNewline
        (Invoke-InAgent 'Invoke-RoundAutoFix' $s @('a.js') $strict).Count | Should Be 0
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'writes mixed line endings as the majority, with a card' {
        $s = New-RoundState
        [IO.File]::WriteAllText((Join-Path $s.ProjectRoot 'a.js'), "var a = 1;`nvar b = 2;`nvar c = 3;`r`n")
        $fixed = Invoke-InAgent 'Invoke-RoundAutoFix' $s @('a.js') $standard
        @($fixed) | Should Be 'a.js: line endings made all LF'
        [IO.File]::ReadAllText((Join-Path $s.ProjectRoot 'a.js')).Contains("`r") | Should Be $false
        @($s.Events | Where-Object { $_.type -eq 'action' -and $_.by -eq 'streamhub' }).Count | Should Be 1
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
    It 'rolls back a change that broke a file being fixed, at most twice' {
        $s = New-RoundState; $t = New-RoundTurn; $r = New-Results
        $f = Join-Path $s.ProjectRoot 'a.json'
        $good = "{ ""a"": 1 }`n"
        foreach ($i in 1..3) {
            [IO.File]::WriteAllText($f, "{ ""a"": 1 `n")
            $null = Invoke-InAgent 'Invoke-RoundRollbacks' $s $t $r @{ 'a.json' = $good }
        }
        $t.rollbacks['a.json'] | Should Be 2
        @($r | Where-Object { $_.head -eq '### Rolled back: a.json' }).Count | Should Be 2
        [IO.File]::ReadAllText($f).Trim() | Should Be '{ "a": 1'   # the third time it stays
        Remove-Item $s.ProjectRoot -Recurse -Force
    }
}

Remove-Item -LiteralPath $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
