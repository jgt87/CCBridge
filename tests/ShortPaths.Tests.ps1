# Pester 3.4. A project opened by its 8.3 short path (a user folder named RUNNER~1) is the same folder as its
# long path: its own files are inside it. Every root a path is compared against goes through
# Workspace Get-FullRoot, the form [IO.Path]::GetFullPath gives the paths. Seen 2026-11-16 on GitHub's
# Windows runners, whose TEMP is a short path: 250 tests refused a project's own files as "outside
# the project". Skipped (with the reason) on a volume that keeps no 8.3 names.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\ProjectSetup.psm1') -Force

Describe 'A project opened by its 8.3 short path' {
    $long = Join-Path $env:TEMP ('ccb short path test ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $long 'src')
    $long = [IO.Path]::GetFullPath($long)   # long all the way up, also when TEMP itself is a short path
    [IO.File]::WriteAllText((Join-Path $long 'src\app.js'), 'x')
    $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($long).ShortPath
    $hasShort = $short -ne $long
    $why = if ($hasShort) { '' } else { ' (skipped: this volume keeps no 8.3 names)' }

    It "has a short form to test with$why" -Skip:(-not $hasShort) {
        $short | Should Match '~'
    }
    It "Get-FullRoot gives the long form of a short root, and the path as given when GetFullPath refuses it$why" -Skip:(-not $hasShort) {
        Get-FullRoot $short | Should Be $long
        Get-FullRoot ($short + '\') | Should Be $long
        Get-FullRoot 'C:\a"b' | Should Be 'C:\a"b'
        Get-FullRoot '' | Should Be ''
    }
    It "resolves the project's own files from a short root, and still refuses one outside it$why" -Skip:(-not $hasShort) {
        Resolve-ProjectPath -ProjectRoot $short -RelativePath 'src/app.js' | Should Be (Join-Path $long 'src\app.js')
        { Resolve-ProjectPath -ProjectRoot $short -RelativePath '..\outside.txt' } | Should Throw 'outside the project'
    }
    It "turns a long path into a project path for a short root, and the other way round$why" -Skip:(-not $hasShort) {
        & (Get-Module Workspace) { param($r, $p) ConvertTo-RelativePath $r $p } $short (Join-Path $long 'src\app.js') | Should Be 'src/app.js'
        & (Get-Module Workspace) { param($r, $p) ConvertTo-RelativePath $r $p } $long (Join-Path $short 'src\app.js') | Should Be 'src/app.js'
    }
    It "checks a deleting command's path against a short root as against the long one$why" -Skip:(-not $hasShort) {
        & (Get-Module Executor) { param($r) Test-InProject $r ([IO.Path]::GetFullPath((Join-Path $r 'src\app.js'))) } $short | Should Be $true
        & (Get-Module Executor) { param($r) Test-ScopedPath $r 'src\app.js' } $short | Should BeNullOrEmpty
        & (Get-Module Executor) { param($r) Test-ScopedPath $r '..\other' } $short | Should Match 'outside the project'
    }
    It "takes a live data file in the project as in the project for a short root$why" -Skip:(-not $hasShort) {
        [IO.File]::WriteAllText((Join-Path $long 'data.csv'), "a,b`n1,2`n")
        & (Get-Module ProjectSetup) { param($r, $p) Test-LiveSourcePath $p $r } $short (Join-Path $long 'data.csv') | Should Match 'already in the project'
    }

    Remove-Item -LiteralPath $long -Recurse -Force -ErrorAction SilentlyContinue
}
