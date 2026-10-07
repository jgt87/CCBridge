# Release updates (lib/Update.psm1, tools/update.ps1): files in use stop the update before anything is
# copied, with their names, instead of robocopy failing halfway.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Update.psm1') -Force

function New-UpdateDirs {
    $b = Join-Path $env:TEMP ('ccb-upd-' + [guid]::NewGuid().ToString('N'))
    foreach ($d in 'new\test-tools', 'new\lib', 'app\test-tools', 'app\lib', 'app\node_modules\x', 'app\config') { New-Item -ItemType Directory (Join-Path $b $d) -Force | Out-Null }
    foreach ($f in 'test-tools\echo-test.cmd', 'lib\A.psm1') { [IO.File]::WriteAllText((Join-Path $b "new\$f"), 'new') }
    [IO.File]::WriteAllText((Join-Path $b 'app\test-tools\echo-test.cmd'), 'old one')
    [IO.File]::WriteAllText((Join-Path $b 'app\lib\A.psm1'), 'new'); (Get-Item (Join-Path $b 'app\lib\A.psm1')).LastWriteTimeUtc = (Get-Item (Join-Path $b 'new\lib\A.psm1')).LastWriteTimeUtc
    [IO.File]::WriteAllText((Join-Path $b 'app\gone.cmd'), 'removed in the release')
    [IO.File]::WriteAllText((Join-Path $b 'app\node_modules\x\i.js'), '')
    [IO.File]::WriteAllText((Join-Path $b 'app\config\harness.local.json'), '{}')
    $b
}

Describe 'Files an update touches' {
    It 'lists changed and removed files, not identical or excluded ones' {
        $b = New-UpdateDirs
        $r = @(Get-UpdateTouchedFiles -Source "$b\new" -Target "$b\app" -ExcludeFiles @('*.local.json') -ExcludeDirs @('node_modules')) | Sort-Object
        ($r -join ',') | Should Be 'gone.cmd,test-tools\echo-test.cmd'
        Remove-Item $b -Recurse -Force
    }
}

Describe 'Files in use' {
    It 'names a file another program has open, and nothing once it is closed' {
        $b = New-UpdateDirs
        $fs = [IO.File]::Open("$b\app\test-tools\echo-test.cmd", 'Open', 'Read', 'Read')
        try {
            $l = Get-LockedUpdateFiles -Source "$b\new" -Target "$b\app" -ExcludeDirs @('node_modules')
            (@($l.blocking) -join ',') | Should Be 'test-tools\echo-test.cmd'
            $msg = Format-LockedUpdateFiles @($l.blocking) 'v9.9.9'
            $msg | Should Match '^update to v9\.9\.9 waits: in use by another program: test-tools\\echo-test\.cmd\. Nothing was changed\. Close the test tool'
        } finally { $fs.Close() }
        @((Get-LockedUpdateFiles -Source "$b\new" -Target "$b\app" -ExcludeDirs @('node_modules')).blocking).Count | Should Be 0
        Remove-Item $b -Recurse -Force
    }
    It 'skips an open file with the same content and an open file the release removes' {
        $b = New-UpdateDirs
        [IO.File]::WriteAllText("$b\app\test-tools\echo-test.cmd", 'new')
        (Get-Item "$b\app\test-tools\echo-test.cmd").LastWriteTimeUtc = (Get-Date).AddDays(-3).ToUniversalTime()
        $f1 = [IO.File]::Open("$b\app\test-tools\echo-test.cmd", 'Open', 'Read', 'Read')
        $f2 = [IO.File]::Open("$b\app\gone.cmd", 'Open', 'Read', 'Read')
        try {
            $l = Get-LockedUpdateFiles -Source "$b\new" -Target "$b\app" -ExcludeDirs @('node_modules')
            @($l.blocking).Count | Should Be 0
            (@($l.same) -join ',') | Should Be 'test-tools\echo-test.cmd'
            (@($l.removed) -join ',') | Should Be 'gone.cmd'
        } finally { $f1.Close(); $f2.Close() }
        Remove-Item $b -Recurse -Force
    }
    It 'reads the file names from robocopy errors' {
        $lines = @('', '2026/10/07 10:00:01 ERROR 32 (0x00000020) Copying File C:\App\test-tools\echo-test.cmd', 'The process cannot access the file because it is being used by another process.', '2026/10/07 10:00:02 ERROR 5 (0x00000005) Deleting Extra File C:\App\old.cmd')
        (@(Get-RobocopyFailures $lines) -join ',') | Should Be 'C:\App\test-tools\echo-test.cmd,C:\App\old.cmd'
    }
}

Describe 'An update that fails halfway' {
    It 'puts the old version back whole: replaced and removed files return, added files go' {
        $b = New-UpdateDirs
        $touched = @(Get-UpdateTouchedFiles -Source "$b\new" -Target "$b\app" -ExcludeDirs @('node_modules'))
        $added = @(Get-UpdateNewFiles -Source "$b\new" -Target "$b\app" -ExcludeDirs @('node_modules'))
        [IO.File]::WriteAllText("$b\new\lib\Added.psm1", 'added in the release')
        $added = @(Get-UpdateNewFiles -Source "$b\new" -Target "$b\app" -ExcludeDirs @('node_modules'))
        ($added -join ',') | Should Be 'lib\Added.psm1'
        Save-UpdateBackup -Target "$b\app" -Files $touched -BackupDir "$b\backup"
        # Half a copy: one file replaced, one removed, one added.
        [IO.File]::WriteAllText("$b\app\test-tools\echo-test.cmd", 'new')
        Remove-Item "$b\app\gone.cmd"
        New-Item -ItemType Directory "$b\app\newdir" | Out-Null; [IO.File]::WriteAllText("$b\app\newdir\x.txt", 'x')
        [IO.File]::WriteAllText("$b\app\lib\Added.psm1", 'added in the release')
        @(Restore-UpdateBackup -Target "$b\app" -BackupDir "$b\backup" -NewFiles @($added + 'newdir\x.txt')).Count | Should Be 0
        [IO.File]::ReadAllText("$b\app\test-tools\echo-test.cmd") | Should Be 'old one'
        [IO.File]::ReadAllText("$b\app\gone.cmd") | Should Be 'removed in the release'
        Test-Path "$b\app\lib\Added.psm1" | Should Be $false
        Test-Path "$b\app\newdir" | Should Be $false
        Test-Path "$b\app\config\harness.local.json" | Should Be $true
        Remove-Item $b -Recurse -Force
    }
}

Describe 'The updater of the new release' {
    It 'installs an unpacked release into the app folder when handed over, keeping machine files' {
        $b = New-UpdateDirs
        [IO.File]::WriteAllText("$b\app\version.txt", 'v0.0.1')
        New-Item -ItemType Directory "$b\new\config" | Out-Null; [IO.File]::WriteAllText("$b\new\config\harness.json", '{}')   # a release has config\
        # The updater reports on stderr: with ErrorActionPreference Stop (the release gate) 2>&1 would turn that into an error.
        $ErrorActionPreference = 'Continue'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\update.ps1') -AppRoot "$b\app" -FromFolder "$b\new" -Version 'v9.9.9' 2>&1 | ForEach-Object { "$_" }
        ($out -join ' ') | Should Match 'updated v0\.0\.1 -> v9\.9\.9'
        [IO.File]::ReadAllText("$b\app\version.txt") | Should Be 'v9.9.9'
        [IO.File]::ReadAllText("$b\app\test-tools\echo-test.cmd") | Should Be 'new'
        Test-Path "$b\app\gone.cmd" | Should Be $false
        Test-Path "$b\app\config\harness.local.json" | Should Be $true
        Test-Path "$b\app\node_modules\x\i.js" | Should Be $true
        Remove-Item $b -Recurse -Force
    }
}

Describe 'The install check' {
    It 'finds files missing or different from the release, and nothing in a complete folder' {
        $b = New-UpdateDirs
        [IO.File]::WriteAllText("$b\new\version.txt", 'v9.9.9')
        (New-InstallManifest -AppFolder "$b\new" -Version 'v9.9.9') | Should Be 2
        $ok = Test-InstallIntegrity "$b\new"
        @($ok.missing).Count + @($ok.changed).Count | Should Be 0
        Format-InstallProblem $ok | Should Be ''
        [IO.File]::WriteAllText("$b\new\lib\A.psm1", 'damaged')
        Remove-Item "$b\new\test-tools\echo-test.cmd"
        [IO.File]::WriteAllText("$b\new\config.local.json", '{}')   # machine files are not part of the release
        $bad = Test-InstallIntegrity "$b\new"
        (@($bad.missing) -join ',') | Should Be 'test-tools/echo-test.cmd'
        (@($bad.changed) -join ',') | Should Be 'lib/A.psm1'
        Format-InstallProblem $bad | Should Match '^StreamHub v9\.9\.9 is not complete: 1 file\(s\) missing and 1 different from the release \(test-tools/echo-test\.cmd, lib/A\.psm1\)\. An update probably stopped halfway\.'
        Test-InstallIntegrity "$b\app" | Should BeNullOrEmpty   # no manifest: a git clone or development copy
        Remove-Item $b -Recurse -Force
    }
}
