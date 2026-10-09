# A junction inside Source/ (no rights needed to create one) must never make the vault or the
# end-of-task restore touch files outside the project, and a file already in Work/ is never replaced.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-srclink-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Workspace', 'Executor') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

$base = Join-Path $env:TEMP ('ccb-srclink-p-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$proj = Join-Path $base 'proj'
$outside = Join-Path $base 'outside'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'Source'), (Join-Path $proj 'Work'), $outside
[IO.File]::WriteAllText((Join-Path $proj 'Source\real.txt'), 'real')
[IO.File]::WriteAllText((Join-Path $outside 'users-document.txt'), 'mine')

Describe 'Source/ and links' {
    It 'keeps the vault to real files and leaves a linked outside folder alone' {
        Sync-SourceVault $proj
        $null = cmd /c mklink /J "$proj\Source\lnk" "$outside" 2>&1
        (Test-Path -LiteralPath "$proj\Source\lnk\users-document.txt") | Should Be $true
        $fixed = @(Restore-SourceData $proj)
        ($fixed -join "`n") | Should Not Match 'users-document'
        (Test-Path -LiteralPath (Join-Path $outside 'users-document.txt')) | Should Be $true
        ([IO.File]::GetAttributes((Join-Path $outside 'users-document.txt')) -band [IO.FileAttributes]::ReadOnly) | Should Be 0
        Sync-SourceVault $proj
        (Test-Path -LiteralPath (Join-Path $outside 'users-document.txt')) | Should Be $true
        ([IO.File]::GetAttributes((Join-Path $outside 'users-document.txt')) -band [IO.FileAttributes]::ReadOnly) | Should Be 0
    }
    It 'moves a new Source/ file to Work/ without replacing a file already there' {
        [IO.File]::WriteAllText((Join-Path $proj 'Work\new.txt'), 'the person''s file')
        [IO.File]::WriteAllText((Join-Path $proj 'Source\new.txt'), 'copilot wrote this')
        $fixed = @(Restore-SourceData $proj)
        ($fixed -join "`n") | Should Match 'Work/new \(2\)\.txt'
        [IO.File]::ReadAllText((Join-Path $proj 'Work\new.txt')) | Should Be 'the person''s file'
        [IO.File]::ReadAllText((Join-Path $proj 'Work\new (2).txt')) | Should Be 'copilot wrote this'
    }
    It 'asks a person before a command creates a link' {
        (Get-CommandRisk 'mklink /J Source\lnk C:\Users\x\Documents').destructive | Should Be $true
        (Get-CommandRisk 'New-Item -ItemType Junction -Path Source\x -Target C:\x').destructive | Should Be $true
        (Get-CommandRisk 'New-Item -ItemType Directory build').destructive | Should Be $false
    }
}
cmd /c rmdir "$proj\Source\lnk" 2>&1 | Out-Null
Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
