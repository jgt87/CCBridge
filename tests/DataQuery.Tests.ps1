# ACTION sql: read-only queries over the converted data. Edge is stood in for by -Run here (the
# query page itself runs in Edge: templates/sql/sql.html). Made-up data.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'DataQuery', 'Protocol', 'Prompts') { Import-Module (Join-Path $root "lib\$m.psm1") -Force -DisableNameChecking }

$p = Join-Path $env:TEMP ('ccb-query-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path (Join-Path $p '.streamhub'), (Join-Path $p 'data')
[IO.File]::WriteAllText((Join-Path $p 'data\sales-2026.json'), '[{"Region":"North","Amount":10},{"Region":"South","Amount":5}]')
[IO.File]::WriteAllText((Join-Path $p 'data\book.json'), '{"Q1":[{"a":1}],"Q2":[{"a":2}]}')
[IO.File]::WriteAllText((Join-Path $p '.streamhub\data-imports.json'), '{ "version": 1, "items": [ { "output": "data/sales-2026.json", "source": "sales 2026.csv", "sheets": [ { "name": "", "rows": 2, "columns": [ { "name": "Region", "type": "text" }, { "name": "Amount", "type": "number" } ] } ] }, { "output": "data/book.json", "source": "book.xlsx", "sheets": [ { "name": "Q1", "rows": 1, "columns": [ { "name": "a", "type": "number" } ] }, { "name": "Q2", "rows": 1, "columns": [ { "name": "a", "type": "number" } ] } ] } ] }')

Describe 'Querying the data' {
    It 'names a table per file and per sheet, and lists them for Copilot' {
        Get-QueryTableName 'data/sales-2026.json' | Should Be 'sales_2026'
        Get-QueryTableName 'data/2026 report.json' | Should Be 't_2026_report'
        @(Get-QueryTables $p | ForEach-Object { $_.table }) -join ',' | Should Be 'book_q1,book_q2,sales_2026'
        Format-QueryTablesContext $p | Should Match 'sales_2026 \(2 rows: "Region", "Amount"\)'
    }
    It 'runs only one SELECT or WITH query' {
        Test-ReadOnlyQuery 'SELECT * FROM sales_2026' | Should BeNullOrEmpty
        Test-ReadOnlyQuery "-- totals`nWITH t AS (SELECT 1) SELECT * FROM t;" | Should BeNullOrEmpty
        Test-ReadOnlyQuery 'DELETE FROM sales_2026' | Should Match 'only SELECT'
        Test-ReadOnlyQuery 'SELECT 1; DROP TABLE x' | Should Match 'one statement'
        Test-ReadOnlyQuery '  ' | Should Match 'empty'
    }
    It 'loads only the tables the query names, and formats the result' {
        $seen = @{}
        $run = { param($tables, $parts, $spec) $seen.tables = @($tables | ForEach-Object { $_.table }); $seen.parts = @($parts.Keys); '{"ok":true,"tables":["sales_2026"],"columns":["Region","total"],"total":2,"rows":[["North",10],["South",5]]}' }.GetNewClosure()
        $r = Invoke-DataQuery $p $root 'SELECT Region, SUM(Amount) AS total FROM sales_2026 GROUP BY Region' -Run $run
        $seen.tables -join ',' | Should Be 'sales_2026'
        $seen.parts -join ',' | Should Be 'data/sales-2026.json'
        $r.ok | Should Be $true
        $f = Format-DataQueryResult $r ''
        $f | Should Match '^Query result \(2 row\(s\)\), computed over every row'
        $f | Should Match '\| Region \| total \|'
        $f | Should Match '\| North \| 10 \|'
        (Invoke-DataQuery $p $root 'SELECT * FROM nothing_here' -Run $run).error | Should Match 'names none of the tables: book_q1, book_q2, sales_2026'
        Format-DataQueryResult ([pscustomobject]@{ ok = $true; columns = @('a'); count = 500; rows = @(, @(1)) }) '' | Should Match 'the first 1 shown'
    }
    It 'is an action Copilot can write, and its instructions go with projects that have data' {
        $a = @(Get-ActionBlocks ("``````text`nACTION sql`nSELECT COUNT(*) FROM sales_2026`n``````"))
        $a[0].type | Should Be 'sql'
        $a[0].body | Should Match 'SELECT COUNT'
        (Get-PromptModules 'How many orders are there?' @{ Traits = @('data'); Paths = @('data/sales-2026.json') }) -contains 'actions:sql' | Should Be $true
        (Get-PromptModules 'How many orders are there?' @{ Traits = @(); Paths = @('index.html') }) -contains 'actions:sql' | Should Be $false
        Get-PromptPart $root 'actions:sql' | Should Match 'ACTION sql'
    }
}

Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
