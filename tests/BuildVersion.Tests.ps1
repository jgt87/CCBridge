# Version and commit of a git copy (lib/Config.psm1 Get-StreamHubBuild): native commands run under
# $ErrorActionPreference = 'Stop', where Windows PowerShell 5.1 turns a failing command's stderr into
# a terminating error. A copy without release tags (GitHub's runners) must still show its commit.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Config.psm1') -Force

$repo = Join-Path $env:TEMP ('ccb-build-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $repo
$haveGit = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
if ($haveGit) {
    $ErrorActionPreference = 'Continue'
    $null = & cmd.exe /c "git -C `"$repo`" init -q >nul 2>&1 && git -C `"$repo`" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m start >nul 2>&1"
}

Describe 'The build of a git copy' {
    It 'shows the commit when the copy has no release tags' {
        if (-not $haveGit) { Set-TestInconclusive 'git is not on this machine'; return }
        $ErrorActionPreference = 'Stop'
        $b = Get-StreamHubBuild $repo
        $b.version | Should Be 'dev'
        $b.commit | Should Match '^[0-9a-f]{7,}$'
        Get-StreamHubVersion $repo | Should Match '^git-[0-9a-f]{7,}$'
    }

    It 'keeps standard output, drops stderr and gives nothing for a failing command' {
        $ErrorActionPreference = 'Stop'
        $lines = @(& (Get-Module Config) { Invoke-NativeLines -Exe 'cmd.exe' -Arguments @('/c', 'echo warn 1>&2 & echo abc123') })
        @($lines).Count | Should Be 1
        "$($lines[0])".Trim() | Should Be 'abc123'
        @(& (Get-Module Config) { Invoke-NativeLines -Exe 'cmd.exe' -Arguments @('/c', 'echo out & echo failed 1>&2 & exit 3') }).Count | Should Be 0
        @(& (Get-Module Config) { Invoke-NativeLines -Exe 'no-such-command-ccb.exe' }).Count | Should Be 0
    }
}

Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
