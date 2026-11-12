# install.ps1 must survive being run line by line: on some machines "irm <url> | iex" hands iex one
# line at a time (2026-11-12), and every multi-line block or blank line then fails. So the bootstrap
# has no blank lines, every line parses on its own, and it holds exactly one line of code.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$lines = [IO.File]::ReadAllLines((Join-Path $root 'install.ps1'))

Describe 'The install bootstrap (install.ps1)' {
    It 'has no blank lines' {
        @($lines | Where-Object { -not $_.Trim() }).Count | Should Be 0
    }
    It 'does not end with a newline (split into lines, it would end with an empty one)' {
        [IO.File]::ReadAllText((Join-Path $root 'install.ps1')).EndsWith("`n") | Should Be $false
    }
    It 'parses line by line, each line on its own' {
        $bad = @()
        foreach ($l in $lines) {
            $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($l, [ref]$null, [ref]$e)
            if ($e -and $e.Count) { $bad += $l }
        }
        $bad.Count | Should Be 0
    }
    It 'has exactly one line of code, which runs the full installer as a file' {
        $code = @($lines | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
        $code.Count | Should Be 1
        $code[0] | Should Match 'tools/install-main\.ps1'
        $code[0] | Should Match '-File \$ccbInstaller'
    }
    It 'points at a full installer that exists in the repo' {
        Test-Path -LiteralPath (Join-Path $root 'tools\install-main.ps1') | Should Be $true
    }
}
