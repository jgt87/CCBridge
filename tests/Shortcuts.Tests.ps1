# Shortcuts from before the rename (CCBridge.lnk) become StreamHub.lnk at start; others stay.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Prereq.psm1') -Force

Describe 'Rename-AppShortcuts' {
    $dir = Join-Path $env:TEMP ('ccb-lnk-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $target = Join-Path $dir 'CCBridge\start.cmd'
    New-Item -ItemType Directory (Split-Path $target) | Out-Null
    [IO.File]::WriteAllText($target, '@echo off')
    $shell = New-Object -ComObject WScript.Shell
    $make = { param($name, $to) $l = $shell.CreateShortcut((Join-Path $dir $name)); $l.TargetPath = $to; $l.Save() }

    It 'renames our CCBridge shortcut to StreamHub and keeps its target' {
        & $make 'CCBridge.lnk' $target
        @(Rename-AppShortcuts -Folders @($dir) -Target $target).Count | Should Be 1
        Test-Path (Join-Path $dir 'CCBridge.lnk') | Should Be $false
        $shell.CreateShortcut((Join-Path $dir 'StreamHub.lnk')).TargetPath | Should Be $target
    }
    It 'removes the old shortcut when StreamHub.lnk already exists' {
        & $make 'CCBridge.lnk' $target
        $null = Rename-AppShortcuts -Folders @($dir) -Target $target
        Test-Path (Join-Path $dir 'CCBridge.lnk') | Should Be $false
        Test-Path (Join-Path $dir 'StreamHub.lnk') | Should Be $true
    }
    It 'leaves a CCBridge shortcut to something else alone' {
        & $make 'CCBridge.lnk' (Join-Path $env:WINDIR 'notepad.exe')
        @(Rename-AppShortcuts -Folders @($dir) -Target $target).Count | Should Be 0
        Test-Path (Join-Path $dir 'CCBridge.lnk') | Should Be $true
    }
    Remove-Item $dir -Recurse -Force
}
