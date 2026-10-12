# Window apps read SQL Server only through the kit's read-only helpers (KitWpf.ps1 Invoke-KitSql /
# Start-KitSql), and a file check reports app code that opens a database itself. No SQL Server here:
# the refusals happen before a connection is made. Made-up names.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'templates\ui-kit\wpf\KitWpf.ps1')
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force

$p = Join-Path $env:TEMP ('ccb-kitsql-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path (Join-Path $p '.streamhub')
[IO.File]::WriteAllText((Join-Path $p '.streamhub\databases.json'), '[ { "name": "hr", "server": "SQL02", "database": "People" }, { "name": "sales", "server": "SQL01", "database": "SalesDW" } ]')

Describe 'Invoke-KitSql (window apps)' {
    It 'refuses what is not one reading query, before connecting' {
        { Invoke-KitSql -Database sales -Query 'DELETE FROM dbo.Sales' -ProjectRoot $p } | Should Throw 'Only SELECT'
        { Invoke-KitSql -Database sales -Query 'SELECT * INTO dbo.Copy FROM dbo.Sales' -ProjectRoot $p } | Should Throw "holds 'INTO'"
        { Invoke-KitSql -Database sales -Query 'SELECT 1; DROP TABLE dbo.Sales' -ProjectRoot $p } | Should Throw 'One statement'
        { Invoke-KitSql -Database sales -Query 'SELECT * FROM dbo.Sales WHERE Region = @region' -ProjectRoot $p } | Should Throw '@region'
        { Invoke-KitSql -Database other -Query 'SELECT 1' -ProjectRoot $p } | Should Throw 'no database named other'
        { Invoke-KitSql -Database sales -Query 'SELECT 1' -ProjectRoot (Join-Path $p 'nowhere') } | Should Throw 'Project setup > Databases'
    }
    It 'connects to nothing while the helper program checks the window' {
        $env:STREAMHUB_GUI_TEST = '1'
        try { @(Invoke-KitSql -Database sales -Query 'SELECT * FROM dbo.Sales' -ProjectRoot $p).Count | Should Be 0 }
        finally { $env:STREAMHUB_GUI_TEST = $null }
    }
}

Describe 'Database access a window app writes itself' {
    It 'reports its own connection and values pasted into a query' {
        $app = ". (Join-Path `$PSScriptRoot 'styles\kit\wpf\KitWpf.ps1')`n`$c = New-Object System.Data.SqlClient.SqlConnection 'Server=SQL01;Integrated Security=true'`n"
        (@(Find-OwnDbAccess 'Orders.ps1' $app) -join "`n") | Should Match '^line 2: the app opens a database itself'
        $pasted = ". (Join-Path `$PSScriptRoot 'styles\kit\wpf\KitWpf.ps1')`n`$rows = Invoke-KitSql -Database sales -Query `"SELECT * FROM dbo.Sales WHERE Region = '`$region'`"`n"
        (@(Find-OwnDbAccess 'Orders.ps1' $pasted) -join "`n") | Should Match 'line 2: a value is pasted into the query text'
        $ok = ". (Join-Path `$PSScriptRoot 'styles\kit\wpf\KitWpf.ps1')`nStart-KitSql -Database sales -Query 'SELECT * FROM dbo.Sales WHERE Region = @region' -Parameters @{ region = `$ui.Region.Text } -OnDone { param(`$rows) Set-KitGrid `$ui.Grid `$rows }`n"
        @(Find-OwnDbAccess 'Orders.ps1' $ok).Count | Should Be 0
        @(Find-OwnDbAccess 'Scripts/Refresh-Database.ps1' $app).Count | Should Be 0
        @(Find-OwnDbAccess 'Scripts/Report.ps1' '$c = New-Object System.Data.SqlClient.SqlConnection $cs').Count | Should Be 0   # not a window app
    }
}

Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
