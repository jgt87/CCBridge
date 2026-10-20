# Read-only queries against the person's SQL Server databases, with their Windows sign-in (the SQL
# client ships with Windows: System.Data.SqlClient). Connections are added by the person per project
# (.streamhub/databases.json: name, server, database; never a password: Windows sign-in only); a query
# Copilot asks for (ACTION sql db:NAME) waits for the person's approval and runs:
#   - one SELECT / WITH statement only, nothing that writes or runs code (INTO, EXEC, OPENROWSET...),
#   - on a read-only connection (ApplicationIntent=ReadOnly), in a transaction that is always rolled back,
#   - at most $MaxRows rows.
# A result can be saved as Source/Database/NAME.csv (then converted like any data file), its query kept
# in .streamhub/db-queries.json, and Scripts/Refresh-Database.ps1 runs the saved queries again on its
# own (for a schedule or chain). ASCII only (Windows PowerShell 5.1).

# The parts of a query that hold text, not statements: a block or line comment, a 'string' (with ''
# inside), a [bracketed name], a "quoted name". Each becomes a blank, '' or x in that order.
$script:SqlTokens = '(?s)/\*.*?\*/|--[^\n]*|''(?:[^'']|'''')*''|\[[^\]]*\]|"[^"]*"'
$script:SqlTokenOut = { param($m) $v = $m.Value; if ($v[0] -eq '/' -or $v[0] -eq '-') { ' ' } elseif ($v[0] -eq "'") { "''" } else { 'x' } }
$script:Blocked = '(?i)\b(insert|update|delete|merge|drop|alter|create|truncate|grant|revoke|deny|exec|execute|sp_\w+|xp_\w+|openrowset|opendatasource|openquery|bulk|backup|restore|shutdown|dbcc|waitfor|kill|use|declare|set)\b|\binto\b'

function Get-DbConfigPath([string]$ProjectRoot) { Join-Path $ProjectRoot '.streamhub\databases.json' }

function Get-DbConnections([string]$ProjectRoot) {
    # @(@{ name; server; database; trustCertificate })
    $f = Get-DbConfigPath $ProjectRoot
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try { @(([IO.File]::ReadAllText($f) | ConvertFrom-Json) | ForEach-Object { $_ } | Where-Object { $_.name }) } catch { @() }
}

function Test-DbName([string]$Name) { [bool]($Name -match '^[A-Za-z][\w-]{0,40}$') }

function Save-DbConnection {
    <# Adds or replaces a connection (the person, in the app). Server and database names only: a
       connection string or a password is refused. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string]$Database, [bool]$TrustCertificate = $false)
    if (-not (Test-DbName $Name)) { throw "The name '$Name' must start with a letter and hold only letters, digits, - and _." }
    if ($Server -match '[;=]' -or $Database -match '[;=]') { throw 'Give the server and database names only, not a connection string: the connection always uses your Windows sign-in.' }
    if (-not $Server.Trim() -or -not $Database.Trim()) { throw 'Give a server and a database.' }
    $all = @(Get-DbConnections $ProjectRoot | Where-Object { $_.name -ne $Name }) + @([pscustomobject]@{ name = $Name; server = $Server.Trim(); database = $Database.Trim(); trustCertificate = $TrustCertificate })
    $f = Get-DbConfigPath $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f)
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @($all) -Depth 4), (New-Object Text.UTF8Encoding($false)))
    @($all)
}

function Remove-DbConnection([string]$ProjectRoot, [string]$Name) {
    $all = @(Get-DbConnections $ProjectRoot | Where-Object { $_.name -ne $Name })
    [IO.File]::WriteAllText((Get-DbConfigPath $ProjectRoot), (ConvertTo-Json -InputObject @($all) -Depth 4), (New-Object Text.UTF8Encoding($false)))
    @($all)
}

function Get-DbConnectionString($Connection, [int]$TimeoutSec = 15) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = "$($Connection.server)"; $b['Initial Catalog'] = "$($Connection.database)"
    $b['Integrated Security'] = $true; $b['ApplicationIntent'] = 'ReadOnly'; $b['Connect Timeout'] = $TimeoutSec
    $b['Application Name'] = 'StreamHub (read-only)'
    if ($Connection.trustCertificate) { $b['TrustServerCertificate'] = $true }
    $b.ConnectionString
}

function Test-DbQuery([AllowEmptyString()][string]$Sql) {
    <# Why a database query is refused ($null when it may run): one SELECT or WITH statement, and no
       word that writes, changes the database or runs code, outside quoted text. #>
    # One pass, left to right: a comment, a string or a quoted name is taken whole where it starts
    # (as SQL Server reads it), so a quote inside a [name], or -- or /* inside a string, can never
    # hide a second statement from the checks below.
    $bare = [regex]::Replace("$Sql", $script:SqlTokens, $script:SqlTokenOut)
    $s = $bare.Trim().TrimEnd(';').Trim()
    if (-not $s) { return 'the query is empty' }
    if ($s -notmatch '^(?i)(select|with)\b') { return 'only SELECT (or WITH ... SELECT) queries run against a database' }
    if ($s -match ';') { return 'one statement at a time' }
    $m = [regex]::Match($s, $script:Blocked)
    if ($m.Success) { return "the query holds '$($m.Value)', which can change data or run code: only reading queries run here" }
    $null
}

function Invoke-DbQuery {
    <# Runs a read-only query: @{ ok; columns; rows (arrays); count; truncated; error }. -Run stands in for
       the database in tests: param($connectionString, $sql, $maxRows). #>
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$Sql, [int]$MaxRows = 100000, [int]$TimeoutSec = 120, [scriptblock]$Run = $null)
    $why = Test-DbQuery $Sql
    if ($why) { return [pscustomobject]@{ ok = $false; error = $why } }
    $cs = Get-DbConnectionString $Connection
    if ($Run) { return (& $Run $cs $Sql $MaxRows) }
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    try {
        $conn.Open()
        $tx = $conn.BeginTransaction([System.Data.IsolationLevel]::ReadCommitted)
        try {
            $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx; $cmd.CommandText = $Sql; $cmd.CommandTimeout = $TimeoutSec
            $r = $cmd.ExecuteReader()
            try {
                $cols = @(for ($i = 0; $i -lt $r.FieldCount; $i++) { $r.GetName($i) })
                $rows = New-Object System.Collections.Generic.List[object]
                $truncated = $false
                while ($r.Read()) {
                    if ($rows.Count -ge $MaxRows) { $truncated = $true; break }
                    $vals = New-Object object[] $r.FieldCount
                    for ($i = 0; $i -lt $r.FieldCount; $i++) {
                        $v = $r.GetValue($i)
                        $vals[$i] = if ($v -is [DBNull]) { $null } elseif ($v -is [datetime]) { if ($v.TimeOfDay.Ticks) { $v.ToString('yyyy-MM-ddTHH:mm:ss') } else { $v.ToString('yyyy-MM-dd') } } elseif ($v -is [byte[]]) { '(binary)' } else { $v }
                    }
                    $rows.Add($vals)
                }
            } finally { $r.Dispose() }
        } finally { try { $tx.Rollback() } catch { } }   # always: nothing a query does stays
        [pscustomobject]@{ ok = $true; columns = $cols; rows = $rows.ToArray(); count = $rows.Count; truncated = $truncated }
    } catch {
        [pscustomobject]@{ ok = $false; error = "$($_.Exception.InnerException.Message)$(if (-not $_.Exception.InnerException) { $_.Exception.Message })" }
    } finally { $conn.Dispose() }
}

function ConvertTo-DbCsv($Result) {
    # The result as CSV text (a header row; values quoted when needed; numbers with a dot).
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $q = { param($v) if ($null -eq $v) { '' } else { $s = if ($v -is [IFormattable]) { $v.ToString($null, $inv) } else { "$v" }; if ($s -match '[",\r\n]') { '"' + $s.Replace('"', '""') + '"' } else { $s } } }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(((@($Result.columns) | ForEach-Object { & $q $_ }) -join ','))
    foreach ($r in @($Result.rows)) { $lines.Add(((@($r) | ForEach-Object { & $q $_ }) -join ',')) }
    ($lines -join "`r`n") + "`r`n"
}

function Save-DbResult {
    <# Saves a result as Source/Database/NAME.csv and keeps its query for a refresh
       (.streamhub/db-queries.json). Returns the project-relative path. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Connection, [Parameter(Mandatory)][string]$Sql, [Parameter(Mandatory)]$Result)
    if (-not (Test-DbName $Name)) { throw "The name '$Name' must start with a letter and hold only letters, digits, - and _." }
    $rel = "Source/Database/$Name.csv"
    $full = Join-Path $ProjectRoot $rel.Replace('/', '\')
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
    if (Test-Path -LiteralPath $full) { [IO.File]::SetAttributes($full, 'Normal') }   # the Source/ vault keeps files read-only
    [IO.File]::WriteAllText($full, (ConvertTo-DbCsv $Result), (New-Object Text.UTF8Encoding($true)))
    $qf = Join-Path $ProjectRoot '.streamhub\db-queries.json'
    $all = @()
    if (Test-Path -LiteralPath $qf) { try { $all = @(([IO.File]::ReadAllText($qf) | ConvertFrom-Json) | ForEach-Object { $_ }) } catch { } }
    $all = @($all | Where-Object { $_.name -ne $Name }) + @([pscustomobject]@{ name = $Name; connection = $Connection; sql = $Sql; file = $rel; saved = (Get-Date).ToString('s') })
    [IO.File]::WriteAllText($qf, (ConvertTo-Json -InputObject @($all) -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $rel
}

function Format-DbContext([string]$ProjectRoot) {
    # The project-context line: the databases Copilot may query (with approval) and the saved results.
    $c = @(Get-DbConnections $ProjectRoot)
    if (-not $c.Count) { return '' }
    "- SQL Server databases the user connected (query them with ACTION sql db:NAME; the user approves every query; SELECT only): " + (($c | ForEach-Object { "$($_.name) ($($_.database) on $($_.server))" }) -join ', ')
}

function Write-DbRefreshScript {
    <# Scripts/Refresh-Database.ps1: runs the saved queries again (read-only, the same checks) and writes
       their CSV files, for a schedule or a chain while StreamHub is closed. Returns its path. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $rel = 'Scripts/Refresh-Database.ps1'
    $guard = $script:Blocked.Replace("'", "''")
    $text = @"
<#
  Runs this project's saved database queries again (.streamhub\db-queries.json) and writes their CSV
  files in Source\Database\. Read-only: one SELECT per query, your Windows sign-in, a read-only
  connection, every change rolled back. Written by the helper program (StreamHub).
    powershell -NoProfile -ExecutionPolicy Bypass -File Scripts\Refresh-Database.ps1
#>
`$ErrorActionPreference = 'Stop'
`$root = Split-Path -Parent `$PSScriptRoot
`$list = Get-Content -Raw (Join-Path `$root '.streamhub\databases.json') | ConvertFrom-Json   # assigned first: piped on, a JSON array is one object in 5.1
`$conns = @{}; foreach (`$c in `$list) { `$conns[`$c.name] = `$c }
`$blocked = '$guard'
`$queries = Get-Content -Raw (Join-Path `$root '.streamhub\db-queries.json') | ConvertFrom-Json
foreach (`$q in `$queries) {
    `$c = `$conns[`$q.connection]
    if (-not `$c) { Write-Warning "No connection `$(`$q.connection) for `$(`$q.name)"; continue }
    `$bare = [regex]::Replace(`$q.sql, '$($script:SqlTokens.Replace("'", "''"))', { param(`$m) `$v = `$m.Value; if (`$v[0] -eq '/' -or `$v[0] -eq '-') { ' ' } elseif (`$v[0] -eq "'") { "''" } else { 'x' } })   # comments, strings and quoted names in one pass
    if (`$bare.Trim() -notmatch '^(?i)(select|with)\b' -or `$bare.Trim().TrimEnd(';') -match ';' -or `$bare -match `$blocked) { Write-Warning "`$(`$q.name) is not a single reading query: skipped"; continue }
    `$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    `$b['Data Source'] = `$c.server; `$b['Initial Catalog'] = `$c.database; `$b['Integrated Security'] = `$true; `$b['ApplicationIntent'] = 'ReadOnly'
    if (`$c.trustCertificate) { `$b['TrustServerCertificate'] = `$true }
    `$conn = New-Object System.Data.SqlClient.SqlConnection `$b.ConnectionString
    `$conn.Open()
    try {
        `$tx = `$conn.BeginTransaction()
        `$cmd = `$conn.CreateCommand(); `$cmd.Transaction = `$tx; `$cmd.CommandText = `$q.sql; `$cmd.CommandTimeout = 300
        `$t = New-Object System.Data.DataTable; `$t.Load(`$cmd.ExecuteReader()); `$tx.Rollback()
        `$out = Join-Path `$root (`$q.file -replace '/', '\')
        `$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent `$out)
        if (Test-Path -LiteralPath `$out) { [IO.File]::SetAttributes(`$out, 'Normal') }
        `$t | Export-Csv -LiteralPath `$out -NoTypeInformation -Encoding UTF8
        Write-Output "`$(`$q.name): `$(`$t.Rows.Count) rows -> `$(`$q.file)"
    } finally { `$conn.Dispose() }
}
"@
    $full = Join-Path $ProjectRoot $rel.Replace('/', '\')
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
    [IO.File]::WriteAllText($full, $text, (New-Object Text.UTF8Encoding($false)))
    $rel
}

Export-ModuleMember -Function Get-DbConnections, Test-DbName, Save-DbConnection, Remove-DbConnection, Get-DbConnectionString, Test-DbQuery, Invoke-DbQuery, ConvertTo-DbCsv, Save-DbResult, Format-DbContext, Write-DbRefreshScript
