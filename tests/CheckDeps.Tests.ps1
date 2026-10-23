# tools/check-deps.ps1: the shipped version of every third-party part is read from its own file.
# Offline: no registry requests. A part whose version can no longer be read (a marker file renamed or
# reworded) would make the weekly check silently skip it, so that fails here.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Describe 'Dependency check' {
    It 'reads the shipped version of every part it checks' {
        $md = Join-Path $env:TEMP ('ccb-deps-' + [guid]::NewGuid().ToString('N') + '.md')
        try {
            & (Join-Path $root 'tools\check-deps.ps1') -Offline -Markdown $md *> $null
            $rows = @(Get-Content -LiteralPath $md | Where-Object { $_ -match '^\| (?!Part \||---)' })
            $rows.Count -gt 10 | Should Be $true
            foreach ($part in 'pdf.js', 'sql.js', 'Pyodide', 'Lucide icons', 'esbuild-wasm', 'typescript', 'react') {
                @($rows | Where-Object { $_ -match "^\| $([regex]::Escape($part)) \|" }).Count -ge 1 | Should Be $true
            }
            # No part without its shipped version: column 4 is never "?".
            @($rows | Where-Object { ($_ -split '\|')[3].Trim() -eq '?' }) | Should BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $md -ErrorAction SilentlyContinue }
    }
}
