# ACTION sql: a read-only SQL query over the project's converted data files, so Copilot answers data
# questions from every row instead of the first ones it read. The data (DataImport's data/NAME.json,
# one table per file or per sheet of a workbook) is loaded into an in-memory SQLite database in an
# Edge tab (templates/sql/sql.html with the UI kit's sql.js build), the query runs there, and the
# columns, the number of rows and the first rows come back as a table. Only SELECT / WITH queries;
# the files are never touched. ASCII only (Windows PowerShell 5.1).

Import-Module (Join-Path $PSScriptRoot 'Cdp.psm1')
Import-Module (Join-Path $PSScriptRoot 'DataImport.psm1')

function Get-QueryTableName([string]$Output, [string]$Sheet = '') {
    # data/sales-2026.json -> sales_2026; a sheet of a workbook -> sales_2026_SHEET (letters, digits, _).
    $stem = [IO.Path]::GetFileNameWithoutExtension($Output)
    $n = ("$stem$(if ($Sheet) { "_$Sheet" })" -replace '[^A-Za-z0-9_]+', '_').Trim('_').ToLowerInvariant()
    if ($n -match '^\d') { $n = "t_$n" }
    if (-not $n) { $n = 'data' }
    $n
}

function Get-QueryTables([Parameter(Mandatory)][string]$ProjectRoot) {
    <# The tables a query can use: @(@{ table; output; sheet; columns = @(@{ name; type }); rows }), from
       the data import manifest (files converted and still there). #>
    $man = Read-DataImportManifest $ProjectRoot.TrimEnd('\')
    @(foreach ($k in @($man.Keys | Sort-Object)) {
        $it = $man[$k]
        if ($it.status -or -not (Test-Path -LiteralPath (Join-Path $ProjectRoot $k.Replace('/', '\')))) { continue }
        $sheets = @($it.sheets)
        foreach ($s in $sheets) {
            $sheet = if ($sheets.Count -gt 1) { "$($s.name)" } else { '' }
            [pscustomobject]@{ table = (Get-QueryTableName $k $sheet); output = $k; sheet = $sheet; rows = [int]$s.rows; columns = @($s.columns | ForEach-Object { @{ name = "$($_.name)"; type = "$($_.type)" } }) }
        }
    })
}

function Test-ReadOnlyQuery([AllowEmptyString()][string]$Sql) {
    # Why a query is refused ($null when it may run): one SELECT or WITH statement.
    $t = [regex]::Replace("$Sql", '(?s)/\*.*?\*/|--[^\n]*', ' ').Trim().TrimEnd(';').Trim()
    if (-not $t) { return 'the query is empty' }
    if ($t -notmatch '^(?i)(select|with)\b') { return 'only SELECT (or WITH ... SELECT) queries run here: the data files are read-only' }
    if ($t -match ';\s*\S') { return 'one statement at a time' }
    $null
}

function Invoke-InEdgePage {
    <# Opens a local page in an Edge tab (StreamHub's own Edge on $CdpPort, else a headless Edge of
       its own), waits for $ReadyJs, runs each of $Steps (JavaScript expressions) and returns the last
       one's value. The tab, and an Edge it started, are closed afterwards. #>
    param([Parameter(Mandatory)][string]$PageFile, [Parameter(Mandatory)][string]$ReadyJs, [string[]]$Steps, [int]$CdpPort = 0, [int]$TimeoutMs = 120000)
    $own = $null; $port = $CdpPort; $target = $null; $s = $null
    $prof = Join-Path $env:LOCALAPPDATA 'CCBridge\query-edge'
    try {
        if (-not $port -or -not (Test-CdpEndpoint $port)) {
            $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
            $own = Start-CdpEdge -Port $port -ProfileDir $prof -Headless
        }
        $target = Invoke-RestMethod -Method Put "http://127.0.0.1:$port/json/new?about:blank"
        $s = Connect-Cdp $target.webSocketDebuggerUrl
        $null = Invoke-Cdp $s 'Page.navigate' @{ url = ('file:///' + $PageFile.Replace('\', '/')) }
        $ready = $false
        for ($i = 0; $i -lt 80 -and -not $ready; $i++) {
            Start-Sleep -Milliseconds 250
            $ready = try { [bool](Invoke-Cdp $s 'Runtime.evaluate' @{ expression = $ReadyJs; returnByValue = $true }).result.value } catch { $false }
        }
        if (-not $ready) { throw 'the query page did not start in Edge' }
        $value = $null
        foreach ($js in $Steps) {
            $r = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = $js; awaitPromise = $true; returnByValue = $true } -TimeoutMs $TimeoutMs
            if ($r.exceptionDetails) { throw "the query page failed: $($r.exceptionDetails.exception.description)" }
            $value = $r.result.value
        }
        $value
    } finally {
        if ($s) { try { Disconnect-Cdp $s } catch { } }
        if ($target) { try { $null = Invoke-RestMethod "http://127.0.0.1:$port/json/close/$($target.id)" } catch { } }
        if ($own) { Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)" -like "*$prof*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    }
}

function Invoke-DataQuery {
    <# Runs one read-only query over the tables it names (only those are loaded): @{ ok; columns;
       count; rows; error; tables }. -Run stands in for Edge in tests: param($tables, $parts, $spec). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Sql, [int]$CdpPort = 0, [int]$Max = 200, [scriptblock]$Run = $null)
    $why = Test-ReadOnlyQuery $Sql
    if ($why) { return [pscustomobject]@{ ok = $false; error = $why } }
    $all = @(Get-QueryTables $ProjectRoot)
    if (-not $all.Count) { return [pscustomobject]@{ ok = $false; error = 'the project has no converted data files to query (data files are converted when a task starts)' } }
    $used = @($all | Where-Object { $Sql -match ('(?i)(^|[^\w])"?' + [regex]::Escape($_.table) + '"?($|[^\w])') })
    if (-not $used.Count) { return [pscustomobject]@{ ok = $false; error = "the query names none of the tables: $(($all | ForEach-Object { $_.table }) -join ', ')" } }
    $files = @($used | ForEach-Object { $_.output } | Select-Object -Unique)
    $parts = @{}
    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText((Join-Path $ProjectRoot $f.Replace('/', '\')))
        $parts[$f] = @(for ($i = 0; $i -lt $text.Length; $i += 400000) { $text.Substring($i, [Math]::Min(400000, $text.Length - $i)) })
    }
    $spec = @{ sql = $Sql; max = $Max; tables = @($used | ForEach-Object { @{ table = $_.table; name = $_.output; sheet = $_.sheet; columns = @($_.columns) } }) }
    $raw = if ($Run) { & $Run $used $parts $spec } else {
        $steps = New-Object System.Collections.Generic.List[string]
        foreach ($f in $files) { foreach ($c in $parts[$f]) { $steps.Add("KitQuery.add($(ConvertTo-Json -InputObject $f -Compress), $(ConvertTo-Json -InputObject $c -Compress))") } }
        $steps.Add("KitQuery.run($(ConvertTo-Json -InputObject $spec -Depth 6 -Compress))")
        Invoke-InEdgePage (Join-Path $AppRoot 'templates\sql\sql.html') '!!(window.KitQuery && window.KitQuery.ready)' $steps.ToArray() $CdpPort
    }
    $o = "$raw" | ConvertFrom-Json
    if (-not $o.ok) { return [pscustomobject]@{ ok = $false; error = "$($o.error)"; tables = @($used | ForEach-Object { $_.table }) } }
    [pscustomobject]@{ ok = $true; columns = @($o.columns); count = [int]$o.total; rows = @($o.rows | ForEach-Object { , @($_) }); tables = @($o.tables) }
}

function Format-DataQueryResult($Result, [string]$Sql) {
    # The result for Copilot: a Markdown table of the first rows, with how many there are in all.
    if (-not $Result.ok) { return "error: $($Result.error)" }
    $cols = @($Result.columns)
    if (-not $cols.Count) { return 'The query ran and returned no columns.' }
    $cell = { param($v) if ($null -eq $v) { '' } else { ("$v" -replace '\|', '\|' -replace '\s+', ' ').Trim() } }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('| ' + (($cols | ForEach-Object { & $cell $_ }) -join ' | ') + ' |')
    $lines.Add('|' + (($cols | ForEach-Object { ' --- ' }) -join '|') + '|')
    foreach ($r in @($Result.rows)) { $lines.Add('| ' + ((@($r) | ForEach-Object { & $cell $_ }) -join ' | ') + ' |') }
    $shown = @($Result.rows).Count
    "Query result ($($Result.count) row(s)$(if ($shown -lt $Result.count) { ", the first $shown shown: narrow the query or aggregate for the rest" })), computed over every row of the data:`n" + ($lines -join "`n")
}

function Format-QueryTablesContext([string]$ProjectRoot) {
    # The project-context line: the tables ACTION sql can query, with their columns.
    $t = @(Get-QueryTables $ProjectRoot)
    if (-not $t.Count) { return '' }
    "- SQL tables for ACTION sql (every row of the converted data): " + (($t | ForEach-Object { "$($_.table) ($($_.rows) rows: $((@($_.columns) | Select-Object -First 15 | ForEach-Object { '"' + $_.name + '"' }) -join ', ')$(if (@($_.columns).Count -gt 15) { ', ...' }))" }) -join '; ')
}

Export-ModuleMember -Function Get-QueryTableName, Get-QueryTables, Test-ReadOnlyQuery, Invoke-InEdgePage, Invoke-DataQuery, Format-DataQueryResult, Format-QueryTablesContext
