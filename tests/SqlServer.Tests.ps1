# Read-only SQL Server queries with the person's Windows sign-in (lib/SqlServer.psm1). The database is
# stood in for by -Run (no SQL Server in the tests). Made-up names and rows.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\SqlServer.psm1') -Force

$p = Join-Path $env:TEMP ('ccb-sql-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $p

Describe 'Database connections' {
    It 'keeps server and database names only, never a connection string or password' {
        @(Save-DbConnection $p 'sales' 'SQL01\REPORTING' 'SalesDW').Count | Should Be 1
        @(Save-DbConnection $p 'hr' 'SQL02' 'People' $true).Count | Should Be 2
        @(Save-DbConnection $p 'sales' 'SQL01' 'SalesDW').Count | Should Be 2      # replaced, not added
        { Save-DbConnection $p 'x' 'SQL01;User Id=sa;Password=secret' 'db' } | Should Throw 'not a connection string'
        { Save-DbConnection $p '1bad' 'SQL01' 'db' } | Should Throw 'start with a letter'
        $cs = Get-DbConnectionString (@(Get-DbConnections $p) | Where-Object name -eq 'hr')
        $cs | Should Match 'Integrated Security=True'
        $cs | Should Match 'ApplicationIntent=ReadOnly'
        $cs | Should Match 'TrustServerCertificate=True'
        $cs | Should Not Match '(?i)password'
        Format-DbContext $p | Should Match 'hr \(People on SQL02\), sales \(SalesDW on SQL01\)'
        @(Remove-DbConnection $p 'hr').Count | Should Be 1
    }
}

Describe 'Which database queries run' {
    It 'runs one reading query and refuses anything that writes or runs code' {
        Test-DbQuery 'SELECT TOP 10 Region, SUM(Amount) FROM dbo.Sales GROUP BY Region' | Should BeNullOrEmpty
        Test-DbQuery "WITH t AS (SELECT * FROM dbo.Sales WHERE Note = 'please delete; insert into x') SELECT COUNT(*) FROM t" | Should BeNullOrEmpty
        Test-DbQuery 'SELECT [Update], [Set] FROM dbo.Log' | Should BeNullOrEmpty
        Test-DbQuery 'SELECT * INTO dbo.Copy FROM dbo.Sales' | Should Match "holds 'INTO'"
        Test-DbQuery 'DELETE FROM dbo.Sales' | Should Match 'only SELECT'
        Test-DbQuery 'SELECT 1; DROP TABLE dbo.Sales' | Should Match 'one statement'
        Test-DbQuery 'SELECT * FROM OPENROWSET(''SQLNCLI'', ''x'', ''y'')' | Should Match 'OPENROWSET'
        Test-DbQuery "SELECT 1 EXEC('drop table x')" | Should Match 'EXEC'
        (Invoke-DbQuery ([pscustomobject]@{ server = 's'; database = 'd' }) 'UPDATE x SET y = 1' -Run { throw 'must not run' }).error | Should Match 'only SELECT'
    }
    It 'reads comments, strings and quoted names in one pass, so none of them hides a second statement' {
        # A quote inside a bracketed name, and -- or /* inside a string, as SQL Server reads them.
        Test-DbQuery "SELECT [a'] FROM t; EXEC xp_cmdshell 'dir' --'" | Should Match 'one statement|EXEC'
        Test-DbQuery "SELECT '--', 1`n; EXEC xp_cmdshell 'dir'" | Should Match 'one statement|EXEC'
        Test-DbQuery "SELECT '/*' ; EXEC xp_cmdshell 'dir' -- */" | Should Match 'one statement|EXEC'
        Test-DbQuery "SELECT [x;y], 'a;b' FROM t -- ; drop`n/* ; drop */" | Should BeNullOrEmpty
        Test-DbQuery 'SELECT "insert" FROM t' | Should BeNullOrEmpty
    }
    It 'saves a result as CSV in Source/Database and keeps the query for a refresh' {
        $res = Invoke-DbQuery ([pscustomobject]@{ server = 's'; database = 'd' }) 'SELECT Region, Amount FROM dbo.Sales' -Run { param($cs, $sql, $max) [pscustomobject]@{ ok = $true; columns = @('Region', 'Amount'); rows = @(, @('North, east', 1250.5)) + @(, @($null, 3)); count = 2; truncated = $false } }
        $res.ok | Should Be $true
        ConvertTo-DbCsv $res | Should Be "Region,Amount`r`n`"North, east`",1250.5`r`n,3`r`n"
        $rel = Save-DbResult $p 'sales-by-region' 'sales' 'SELECT Region, Amount FROM dbo.Sales' $res
        $rel | Should Be 'Source/Database/sales-by-region.csv'
        Test-Path -LiteralPath (Join-Path $p 'Source\Database\sales-by-region.csv') | Should Be $true
        ([IO.File]::ReadAllText((Join-Path $p '.streamhub\db-queries.json')) | ConvertFrom-Json).connection | Should Be 'sales'
    }
    It 'writes a refresh script that parses and carries the same checks' {
        Write-DbRefreshScript $p | Should Be 'Scripts/Refresh-Database.ps1'
        $f = Join-Path $p 'Scripts\Refresh-Database.ps1'
        $e = $null; $null = [Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
        @($e).Count | Should Be 0
        $t = [IO.File]::ReadAllText($f)
        $t | Should Match 'ApplicationIntent'
        $t | Should Match 'Rollback'
        $t | Should Match 'openrowset'
        # The same one-pass reading of comments, strings and quoted names as Test-DbQuery.
        $t | Should Match 'comments, strings and quoted names in one pass'
        $t | Should Match ([regex]::Escape('|\[[^\]]*\]|"[^"]*"'))
    }
}

Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
