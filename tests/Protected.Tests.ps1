# Protected files (setting protectedPaths): read-only like Source/ (lib/Workspace.psm1, Executor).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force

function Add-File($p, $rel, $text) { $full = Join-Path $p $rel; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, $text) }

Describe 'Test-ProtectedPath' {
    It 'matches files, folders and patterns' {
        $list = @('config/prod.json', 'docs/', '*.env', 'keys/*.pem')
        Test-ProtectedPath 'config/prod.json' $list | Should Be 'config/prod.json'
        Test-ProtectedPath 'CONFIG\prod.json' $list | Should Be 'config/prod.json'
        Test-ProtectedPath 'docs/guide/a.md' $list | Should Be 'docs/'
        Test-ProtectedPath 'app/.env' $list | Should Be '*.env'
        Test-ProtectedPath 'keys/server.pem' $list | Should Be 'keys/*.pem'
        Test-ProtectedPath 'config/dev.json' $list | Should Be $null
        Test-ProtectedPath 'docsite/x.md' $list | Should Be $null
    }
}

Describe 'Protected files' {
    It 'refuses writes, puts back what a command changed or deleted, and follows the user''s own edits' {
        $p = Join-Path $env:TEMP ('ccb-protect-' + [guid]::NewGuid().ToString('N'))
        Add-File $p 'config/prod.json' '{"url":"https://prod"}'
        Add-File $p 'app.js' 'let a = 1;'
        Mock -ModuleName Workspace Get-ProtectedPatterns { @('config/prod.json') }
        try {
            { Invoke-WriteAction $p 'config/prod.json' '{}' $null } | Should Throw 'is protected'
            { Invoke-WriteAction $p 'app.js' 'let a = 2;' $null } | Should Not Throw
            Sync-SourceVault $p                                         # a task starts: the user's version is kept aside
            [IO.File]::WriteAllText((Join-Path $p 'config/prod.json'), 'changed by a command')
            @(Restore-SourceData $p) -join ';' | Should Match 'restored protected file config/prod.json \(changed\)'
            [IO.File]::ReadAllText((Join-Path $p 'config/prod.json')) | Should Be '{"url":"https://prod"}'
            Remove-Item (Join-Path $p 'config/prod.json')
            @(Restore-SourceData $p) -join ';' | Should Match '\(deleted\)'
            # The user edits it between tasks: the next task keeps that version.
            [IO.File]::WriteAllText((Join-Path $p 'config/prod.json'), '{"url":"https://new"}')
            Sync-ProtectedVault $p
            @(Restore-SourceData $p).Count | Should Be 0
            [IO.File]::ReadAllText((Join-Path $p 'config/prod.json')) | Should Be '{"url":"https://new"}'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'saves the setting as a list, one path per line' {
        $app = Join-Path $env:TEMP ('ccb-app-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $app 'config') | Out-Null
        Copy-Item (Join-Path $root 'config\harness.json') (Join-Path $app 'config\harness.json')
        try {
            $v = Set-CCBridgeSetting 'protectedPaths' "config/prod.json`n docs/ `n`n*.env" $app
            @($v) -join '|' | Should Be 'config/prod.json|docs/|*.env'
            (Get-CCBridgeSettings $app | Where-Object key -eq 'protectedPaths').type | Should Be 'list'
        } finally { Remove-Item $app -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
