# The code map for the first message of a chat (lib/RepoMap.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\RepoMap.psm1') -Force
Import-Module (Join-Path $root 'lib\Imports.psm1') -Force

function Add-File($p, $rel, $text) { $full = Join-Path $p $rel; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, $text) }

Describe 'Get-RepoMap' {
    It 'lists functions with line numbers, most relevant files first, within the budget' {
        $p = Join-Path $env:TEMP ('ccb-map-' + [guid]::NewGuid().ToString('N'))
        Add-File $p 'src/shared/dates.js' "export function formatDay(d) {`n  return d;`n}`nexport function parseDay(s) { return s; }`n"
        Add-File $p 'src/calendar/view.js' "import { formatDay } from '../shared/dates.js';`nexport function renderWeek() { return formatDay(1); }`n"
        Add-File $p 'src/expenses/list.js' "import { formatDay } from '../shared/dates.js';`nfunction addExpense() { }`n"
        Add-File $p 'Scripts/export.ps1' "function Export-Week {`n  1`n}`n"
        Add-File $p 'README.md' "# Notes`n"
        $null = Update-ImportIndex $p
        try {
            $map = Get-RepoMap $p 'Add a total to list.js' @() 4000
            $map | Should Match '^Code map'
            $lines = @($map -split "`n" | Where-Object { $_ -match ': ' -and $_ -notmatch '^Code map' })
            $lines[0] | Should Match '^src/expenses/list\.js: addExpense 2'                 # named in the message
            $lines[1] | Should Match '^src/shared/dates\.js \(used by 2\): formatDay 1, parseDay 4'   # used by others
            $map | Should Match 'Scripts/export\.ps1: Export-Week 1'
            $map | Should Not Match 'README'
            # A small budget: fewer files, never more characters than allowed (plus the heading).
            $small = Get-RepoMap $p '' @() 120
            ($small -split "`n" | Where-Object { $_ -match '\.(js|ps1)' -and $_ -notmatch 'not in this map' }).Count | Should BeLessThan 3
            $small | Should Match 'more code file\(s\) not in this map'
            Get-RepoMap $p 'x' @() 0 | Should Be ''
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
