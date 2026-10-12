# Approving a change in parts: the change split into blocks of lines (Get-LineHunks), and the file
# written with only the blocks the person kept (Merge-LineHunks). Made-up texts.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

$old = (1..12 | ForEach-Object { "line $_" }) -join "`n"
$new = $old.Replace('line 3', 'line three').Replace("line 9`n", "line 9`nline 9b`n")

Describe 'A change in blocks' {
    It 'splits separate changes into blocks with their place and first line' {
        $h = @(Get-LineHunks $old $new)
        $h.Count | Should Be 2
        $h[0].oldStart | Should Be 3
        $h[0].oldCount | Should Be 1
        $h[0].newCount | Should Be 1
        $h[0].first | Should Be '- line 3'
        $h[1].oldCount | Should Be 0
        $h[1].newStart | Should Be 10
        $h[1].first | Should Be '+ line 9b'
        @(Get-LineHunks $old $old).Count | Should Be 0
    }
    It 'writes only the blocks that were kept' {
        Merge-LineHunks $old $new @() | Should BeExactly $new
        Merge-LineHunks $old $new @(0, 1) | Should BeExactly $old
        $onlySecond = Merge-LineHunks $old $new @(0)
        $onlySecond | Should Match 'line 3\n'
        $onlySecond | Should Match 'line 9b'
        $onlyFirst = Merge-LineHunks $old $new @(1)
        $onlyFirst | Should Match 'line three'
        $onlyFirst | Should Not Match 'line 9b'
    }
    It 'keeps Windows line endings and handles removed lines' {
        $o = "a`r`nb`r`nc`r`nd`r`ne`r`n"
        $n = "a`r`nc`r`nd`r`nE`r`n"
        $h = @(Get-LineHunks $o $n)
        $h.Count | Should Be 2
        $h[0].first | Should Be '- b'
        Merge-LineHunks $o $n @(1) | Should BeExactly "a`r`nc`r`nd`r`ne`r`n"
        Merge-LineHunks $o $n @(0) | Should BeExactly "a`r`nb`r`nc`r`nd`r`nE`r`n"
    }
    It 'treats a very large rewrite as one block' {
        $o = (1..700 | ForEach-Object { "old $_" }) -join "`n"
        $n = (1..700 | ForEach-Object { "new $_" }) -join "`n"
        @(Get-LineHunks $o $n).Count | Should Be 1
        Merge-LineHunks $o $n @(0) | Should BeExactly $o
    }
}
