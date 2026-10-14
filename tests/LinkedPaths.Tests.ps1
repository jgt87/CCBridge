# Link targets must obey the same confinement and write protections as their visible paths.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$base = Join-Path $env:TEMP ('ccb-links-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_STATE_ROOT = Join-Path $base 'state'
foreach ($m in 'Workspace', 'Executor') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$p = Join-Path $base 'project'; $outside = Join-Path $base 'outside'
$null = New-Item -ItemType Directory -Force -Path $p, $outside, (Join-Path $p 'Source'), (Join-Path $p 'safe'), (Join-Path $p '.streamhub'), (Join-Path $p 'config')
[IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'), 'outside')
[IO.File]::WriteAllText((Join-Path $p 'Source\input.txt'), 'source')
[IO.File]::WriteAllText((Join-Path $p 'config\prod.txt'), 'protected')
$links = [ordered]@{
    'outer' = $outside; 'chain' = (Join-Path $p 'outer'); 'source-alias' = (Join-Path $p 'Source')
    'own-alias' = (Join-Path $p '.streamhub'); 'config-alias' = (Join-Path $p 'config')
    'safe-alias' = (Join-Path $p 'safe'); 'safe-chain' = (Join-Path $p 'safe-alias')
}
foreach ($name in $links.Keys) { $null = New-Item -ItemType Junction -Path (Join-Path $p $name) -Target $links[$name] }
# PowerShell 5.1 requires the target to exist when creating a junction. Seed the
# cycle with an empty directory, then replace that directory with the second link.
$null = New-Item -ItemType Directory -Path (Join-Path $p 'loop-b')
$null = New-Item -ItemType Junction -Path (Join-Path $p 'loop-a') -Target (Join-Path $p 'loop-b')
[IO.Directory]::Delete((Join-Path $p 'loop-b'))
$null = New-Item -ItemType Junction -Path (Join-Path $p 'loop-b') -Target (Join-Path $p 'loop-a')
$links['loop-a'] = Join-Path $p 'loop-b'
$links['loop-b'] = Join-Path $p 'loop-a'

Describe 'Fully resolved linked paths' {
    It 'refuses chained links outside for reads, writes and deleting commands, including new files' {
        { Resolve-ProjectPath $p 'chain/sentinel.txt' } | Should Throw 'outside the project'
        { Assert-Writable $p 'chain/new/file.txt' } | Should Throw 'outside the project'
        Test-DeleteScope $p 'del chain\sentinel.txt' | Should Match 'link'
        [IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) | Should Be 'outside'
    }
    It 'applies Source and internal-folder protections to aliases and new descendants' {
        { Invoke-WriteAction $p 'source-alias/input.txt' 'changed' $null } | Should Throw 'Source/'
        { Assert-Writable $p 'source-alias/new/future.txt' } | Should Throw 'Source/'
        { Assert-Writable $p 'own-alias/records.txt' } | Should Throw '.streamhub/'
        [IO.File]::ReadAllText((Join-Path $p 'Source\input.txt')) | Should Be 'source'
    }
    It 'applies configured protected-file patterns to the destination' {
        Mock -ModuleName Workspace Get-ProtectedPatterns { @('config/prod.txt') }
        { Invoke-WriteAction $p 'config-alias/prod.txt' 'changed' $null } | Should Throw 'protected'
        [IO.File]::ReadAllText((Join-Path $p 'config\prod.txt')) | Should Be 'protected'
    }
    It 'keeps valid in-project link chains writable' {
        Invoke-WriteAction $p 'safe-chain/new/file.txt' 'safe content' $null | Should Match 'wrote'
        [IO.File]::ReadAllText((Join-Path $p 'safe\new\file.txt')).TrimEnd("`r", "`n") | Should Be 'safe content'
        Resolve-ProjectPath $p 'safe-chain/new/file.txt' | Should Be (Join-Path $p 'safe-chain\new\file.txt')
    }
    It 'refuses link cycles instead of following them forever' {
        { Resolve-ProjectPath $p 'loop-a/new.txt' } | Should Throw 'link cycle'
    }
    It 'lists real project files without walking linked folders or cycles' {
        $files = @(Get-ProjectFiles $p)
        @($files | Where-Object { $_.path -match '^(outer|chain|.*-alias|safe-chain|loop-a|loop-b)/' }).Count | Should Be 0
        @($files | Where-Object { $_.path -eq 'Source/input.txt' }).Count | Should Be 1
    }
}

# Delete the links themselves first; never recursively remove a fixture through a junction.
foreach ($name in $links.Keys) { [IO.Directory]::Delete((Join-Path $p $name)) }
$resolvedBase = [IO.Path]::GetFullPath($base)
if ($resolvedBase.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\ccb-links-', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedBase -Recurse -Force }
$env:CCBRIDGE_STATE_ROOT = $null
