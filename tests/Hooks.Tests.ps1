# Hooks: the user's own commands at fixed moments (lib/Hooks.psm1, Invoke-ProjectHooks in Agent.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Hooks.psm1') -Force
Import-Module (Join-Path $root 'lib\Chain.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

function New-HookProject([string]$Json) {
    $p = Join-Path $env:TEMP ('ccb-hooks-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $p '.streamhub') | Out-Null
    if ($Json) { [IO.File]::WriteAllText((Join-Path $p '.streamhub\hooks.json'), $Json) }
    $p
}
function New-HookState($p) {
    $s = New-AgentState -Config ([pscustomobject]@{ commandTimeoutSec = 60 }) -AppRoot $root
    $s.ProjectRoot = $p; $s.Mode = 'auto'
    $s
}

Describe 'Read-Hooks' {
    It 'reads the hooks per moment, with patterns and {file}' {
        $p = New-HookProject '{"_help":"x","afterEdit":[{"match":"*.ps1","run":"echo {file}","name":"Show"}],"beforeDone":["exit 0"],"afterTask":[]}'
        try {
            $h = Read-Hooks $p
            $h.error | Should Be $null
            @($h.hooks).Count | Should Be 2
            $edit = @($h.hooks | Where-Object event -eq 'afterEdit')[0]
            Test-HookMatch $edit 'src/a.ps1' | Should Be $true
            Test-HookMatch $edit 'src/a.js' | Should Be $false
            Get-HookCommand $edit 'src/a.ps1' | Should Be 'echo "src\a.ps1"'
            (Read-Hooks (New-HookProject '{"afterSave":[]}')).error | Should Match "unknown hook moment 'afterSave'"
            (Read-Hooks (New-HookProject '{ not json')).error | Should Match 'not valid JSON'
            (Read-Hooks (New-HookProject '')).exists | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'writes a starting file once' {
        $p = New-HookProject ''
        try {
            New-HooksFile $p | Should Be '.streamhub/hooks.json'
            (Read-Hooks $p).hooks.Count | Should Be 0       # the examples do not run
            { New-HooksFile $p } | Should Throw 'already has'
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Invoke-ProjectHooks' {
    It 'runs approved hooks, reports failures, and never runs deleting or unapproved ones' {
        $p = New-HookProject '{"afterEdit":[{"match":"*.txt","run":"findstr /c:bad {file} && exit 1 || exit 0"}],"beforeDone":[{"name":"wipe","run":"del /q notes.txt"}]}'
        [IO.File]::WriteAllText((Join-Path $p 'notes.txt'), "bad line`n")
        [IO.File]::WriteAllText((Join-Path $p 'ok.txt'), "fine`n")
        try {
            # Not approved yet and no person (headless): nothing runs.
            $s = New-HookState $p; $s.Headless = $true
            @(Invoke-ProjectHooks $s 'afterEdit' @('notes.txt')).Count | Should Be 0
            (@($s.Events) | Where-Object type -eq 'status' | Select-Object -Last 1).text | Should Match 'needs a person'
            # Approved: the afterEdit hook runs per matching file; a failing one is reported.
            Add-ApprovedScript $p '.streamhub/hooks.json' (Get-ScriptHash (Join-Path $p '.streamhub\hooks.json'))
            $s = New-HookState $p
            $f = @(Invoke-ProjectHooks $s 'afterEdit' @('notes.txt', 'ok.txt', 'app.js'))
            $f.Count | Should Be 1
            $f[0] | Should Match 'afterEdit hook for notes.txt failed'
            @($s.Events | Where-Object { $_.type -eq 'action' -and $_.by -eq 'streamhub' }).Count | Should Be 2
            # A deleting hook never runs.
            @(Invoke-ProjectHooks $s 'beforeDone').Count | Should Be 0
            Test-Path (Join-Path $p 'notes.txt') | Should Be $true
            (@($s.Events) | Where-Object type -eq 'action-result' | Select-Object -Last 1).output | Should Match 'Not run'
            # Plan mode: no hooks.
            $s.Mode = 'plan'
            @(Invoke-ProjectHooks $s 'afterEdit' @('notes.txt')).Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
