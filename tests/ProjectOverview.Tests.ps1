# Size and type of a project for the project list (Get-ProjectOverview, Workspace.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force

Describe 'Get-ProjectOverview' {
    It 'counts files and bytes and names the main languages, most files first' {
        $p = Join-Path $env:TEMP ('ccb-ov-' + [guid]::NewGuid().ToString('N'))
        foreach ($f in 'index.html', 'js\a.js', 'js\b.js', 'js\c.js', 'css\s.css', 'css\t.css', 'Scripts\x.ps1', 'Source\data.csv', 'node_modules\lib\i.js') {
            $full = Join-Path $p $f
            New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
            [IO.File]::WriteAllText($full, '0123456789')
        }
        try {
            $o = Get-ProjectOverview $p
            $o.files | Should Be 8                     # node_modules is not counted
            $o.bytes | Should Be 80
            @($o.languages) -join ',' | Should BeExactly 'JavaScript,CSS,HTML'
            $o.sourceFiles | Should Be 1
            $o.capped | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'gives an empty overview for an empty project' {
        $p = Join-Path $env:TEMP ('ccb-ov-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $p | Out-Null
        try { (Get-ProjectOverview $p).files | Should Be 0; @((Get-ProjectOverview $p).languages).Count | Should Be 0 } finally { Remove-Item $p -Recurse -Force }
    }
}
