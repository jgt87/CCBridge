# The rename (2026-11-24): the app, its code and its folders are called StreamHub. The old name
# (CCBridge) stays only where it is needed to find, move or accept what releases before the rename
# left behind, and there it is marked: a file listed below as a whole, or a line that says
# "pre-rename". Everything else names the new name only.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# Whole files that are about the old name by nature.
$script:WholeFiles = @(
    'CHANGELOG.md'                   # history entries stay as they were written
    'lib/AppPaths.psm1'              # the one module that names the old folders and moves them
    'mcp/ccbridge-mcp.ps1'           # the old MCP script name, which starts the new one
    'tools/rebrand-check.ps1'        # the check after the update on an installed PC
    'docs/runbooks/rebrand-check.md' # its runbook
    'tests/AppPaths.Tests.ps1'       # tests of the move from the old folders
    'tests/Shortcuts.Tests.ps1'      # tests of renaming the old shortcuts
    'tests/OldName.Tests.ps1'        # this file
)
# File names that may hold the old name (the files above).
$script:OldFileNames = @('mcp/ccbridge-mcp.ps1')

Describe 'The old name stays only where it is marked' {
    $listed = @(Push-Location $root; try { git ls-files -co --exclude-standard 2>$null } finally { Pop-Location })
    $files = @($listed | Where-Object { $_ -and $_ -notmatch '(^|/)(node_modules|dist|temp)/|package-lock\.json$|\.(zip|png|jpe?g|gif|ico|woff2?|ttf|otf|wasm|pptx|docx|xlsx|pdf)$' -and (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) })

    It 'finds the files to check (an empty run is not a pass)' {
        ($files.Count -gt 200) | Should Be $true
    }
    It 'has no file named after the old name but the old MCP script' {
        @($files | Where-Object { $_ -match '(?i)ccbridge' -and $script:OldFileNames -notcontains $_ }) -join "`n" | Should BeNullOrEmpty
    }
    It 'names the old name only in the listed files and on lines marked pre-rename' {
        $hits = foreach ($f in @($files | Where-Object { $script:WholeFiles -notcontains $_ })) {
            $full = Join-Path $root $f
            if ((Get-Item -LiteralPath $full).Length -gt 5MB) { continue }
            $text = [IO.File]::ReadAllText($full)
            if ($text -notmatch '(?i)ccbridge') { continue }
            $n = 0
            foreach ($line in $text.Split("`n")) {
                $n++
                if ($line -match '(?i)ccbridge' -and $line -notmatch 'pre-rename') { "${f}:${n}: $($line.Trim().Substring(0, [Math]::Min(140, $line.Trim().Length)))" }
            }
        }
        @($hits) -join "`n" | Should BeNullOrEmpty
    }
    It 'keeps the listed files real (a file that is gone leaves the list)' {
        foreach ($f in $script:WholeFiles) { Test-Path -LiteralPath (Join-Path $root $f) | Should Be $true }
    }
}
