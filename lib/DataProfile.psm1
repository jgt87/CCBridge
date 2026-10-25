# A data profile for the person: for one data file the project converted (DataImport's manifest),
# a readable report of what it holds: rows, columns with their type, empty cells, distinct values,
# lowest and highest values or the most common ones, values far outside the rest with examples,
# numbers mixed with text with examples, duplicate rows, and the notable points first. Written as
# Runbooks/Exports/NAME-profile-STAMP.md and the same as an Excel workbook (one sheet per section).
# Only on request (command menu): nothing runs it by itself. The file is read the way DataImport
# reads it, and the columns are typed and profiled by DataImport's own rules (Get-ColumnType,
# Get-ColumnProfile, Get-DataQualityNotes); only the examples are gathered here.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Workspace', 'Layout', 'Office', 'DataImport') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:MaxRows = 200000          # as DataImport: the rest of a larger file is left out (said in the report)
$script:Examples = 5              # examples per finding
$script:TopValues = 5             # most common values per text column
# A missing value and a value that looks like a number: the same patterns as DataImport's profile.
$script:MissingRe = New-Object regex ('^(|null|NULL|N/A|n/a|NA|#N/A)$', 'Compiled')
$script:NumLikeRe = New-Object regex ('^[-+]?[\d.,]+$', 'Compiled')
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Get-DataProfileSources([string]$ProjectRoot) {
    <# The data files a profile can be made of: the sources in DataImport's manifest that are still there
       and could be read (not failed or too large), with rows, columns and sheets as last converted
       (rows 0 for a file the project's own script converts: DataImport did not read it). #>
    $root = $ProjectRoot.TrimEnd('\')
    $man = Read-DataImportManifest $root
    $seen = @{}
    $list = @(foreach ($k in @($man.Keys | Sort-Object)) {
        $it = $man[$k]
        $src = "$($it.source)"
        if (-not $src -or $seen.ContainsKey($src) -or "$($it.status)" -in 'failed', 'too-large') { continue }
        $full = Join-Path $root $src.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $seen[$src] = $true
        $sheets = @($it.sheets | Where-Object { $_ })
        $rows = 0; foreach ($s in $sheets) { $rows += [int]$s.rows }
        $cols = if ($sheets.Count) { @($sheets[0].columns).Count } else { 0 }
        [pscustomobject]@{ source = $src; output = $k; rows = $rows; columns = $cols; sheets = $sheets.Count; size = (Get-Item -LiteralPath $full).Length }
    })
    @($list | Sort-Object source)
}

function Read-ProfileTables([string]$Path) {
    <# The tables of a data file as DataImport reads them: @(@{ name; rows (header first); delimiter;
       cut }) plus the encoding and delimiter name. Throws for a file it cannot read. #>
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -in '.xlsx', '.xlsm') {
        $sheets = @(Read-XlsxSheets $Path $script:MaxRows | Where-Object { $_.rows.Count -and $_.state -notin 'hidden', 'veryHidden' })
        if (-not $sheets.Count) { throw 'the workbook has no visible sheet with data' }
        $tables = @(foreach ($s in $sheets) { @{ name = "$($s.name)"; rows = @($s.rows); delimiter = ','; cut = ($s.total -gt $s.rows.Count) } })
        return @{ kind = 'Excel workbook'; encoding = ''; delimiter = ''; tables = $tables }
    }
    $read = Read-DataText ([IO.File]::ReadAllBytes($Path))
    if ($ext -eq '.json') {
        $parsed = $null
        try { $parsed = ConvertFrom-Json $read.text } catch { throw 'not valid JSON' }
        $rec = Get-JsonRecords $parsed
        if (-not $rec) { throw 'the JSON is not a table (a list of records)' }
        $list = @($rec.records)
        $cut = $list.Count -gt $script:MaxRows
        if ($cut) { $list = $list[0..($script:MaxRows - 1)] }
        return @{ kind = 'JSON'; encoding = $read.encoding; delimiter = ''; tables = @(@{ name = "$($rec.path)"; rows = @(ConvertTo-JsonTableRows $list); delimiter = ','; cut = $cut }) }
    }
    $delim = Get-CsvDelimiter $read.text $ext
    $rows = @(Read-CsvRows $read.text $delim)
    if (-not $rows.Count) { throw 'the file is empty' }
    $cut = $rows.Count -gt $script:MaxRows + 1
    if ($cut) { $rows = $rows[0..$script:MaxRows] }
    $dn = switch ($delim) { ',' { 'comma' } ';' { 'semicolon' } "`t" { 'tab' } '|' { 'bar' } }
    @{ kind = $(if ($ext -eq '.tsv') { 'TSV' } else { 'CSV' }); encoding = $read.encoding; delimiter = $dn; tables = @(@{ name = ''; rows = $rows; delimiter = $delim; cut = $cut }) }
}

function Get-TypeLabel($Type) {
    # The column type in words, with how its numbers or dates are written.
    switch ($Type.type) {
        'number' { if ($Type.decimal -eq ',') { 'number (decimal comma)' } else { 'number' } }
        'date' { switch ($Type.order) { 'iso' { 'date (year-month-day)' } 'dmy' { 'date (day-month-year)' } 'mdy' { 'date (month-day-year)' } default { 'date' } } }
        'boolean' { 'true/false' }
        default { 'text' }
    }
}

function ConvertTo-ProfileNumber([string]$Value, $Type) {
    # A number column's value as a double, as DataImport's profile reads it ($null when it is not one).
    $t = if ($Type.decimal -eq ',') { $Value.Replace('.', '').Replace(',', '.') } else { $Value.Replace(',', '') }
    $d = 0.0
    if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $d }
    $null
}

function Format-ProfileNumber($Value) {
    # A number for the report: whole numbers without decimals, others with at most 4.
    if ($null -eq $Value -or $Value -is [string]) { return "$Value" }
    $d = [double]$Value
    if ($d -eq [Math]::Floor($d) -and [Math]::Abs($d) -lt 1e15) { return ([int64]$d).ToString($script:Inv) }
    [Math]::Round($d, 4).ToString($script:Inv)
}

function Get-ColumnDetails {
    <# One column: DataImport's type and profile, plus the most common values (text and true/false),
       examples of values far outside the rest (number columns: the same rule as the profile, beyond
       three times the middle half's spread from it) and of values that are not numbers in a column of
       mostly numbers. Rows are counted from the first row under the header (row 1). #>
    param([string]$Name, [string[]]$Values, [string]$Delimiter)
    $type = Get-ColumnType $Values $Delimiter
    $p = Get-ColumnProfile $Values $type
    $counts = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $nums = New-Object System.Collections.Generic.List[object]
    $mixed = New-Object System.Collections.Generic.List[object]
    $wantMixed = [int]$p.notNumbers -gt 0
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $v = $Values[$i]
        if ($script:MissingRe.IsMatch($v)) { continue }
        if ($type.type -in 'text', 'boolean') {
            if ($counts.ContainsKey($v)) { $counts[$v]++ } elseif ($counts.Count -lt 100000) { $counts[$v] = 1 }
            if ($wantMixed -and $mixed.Count -lt $script:Examples -and -not $script:NumLikeRe.IsMatch($v)) { $mixed.Add([pscustomobject]@{ row = $i + 1; value = $v }) }
        } elseif ($type.type -eq 'number') {
            $d = ConvertTo-ProfileNumber $v $type
            if ($null -ne $d) { $nums.Add([pscustomobject]@{ row = $i + 1; value = $d; text = $v }) }
        }
    }
    $top = @()
    if ($counts.Count) {
        $top = @($counts.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Key } } | Select-Object -First $script:TopValues | ForEach-Object { [pscustomobject]@{ value = $_.Key; count = $_.Value } })
    }
    $outliers = @(); $q1 = $null; $q3 = $null
    if ([int]$p.outliers -gt 0 -and $nums.Count -ge 8) {
        $sorted = New-Object double[] $nums.Count
        for ($k = 0; $k -lt $nums.Count; $k++) { $sorted[$k] = $nums[$k].value }
        [Array]::Sort($sorted)
        $q1 = $sorted[[int][Math]::Floor(($sorted.Count - 1) * 0.25)]; $q3 = $sorted[[int][Math]::Floor(($sorted.Count - 1) * 0.75)]
        $spread = $q3 - $q1; $lo = $q1 - 3 * $spread; $hi = $q3 + 3 * $spread
        $outliers = @($nums | Where-Object { $_.value -lt $lo -or $_.value -gt $hi } | Select-Object -First $script:Examples | ForEach-Object { [pscustomobject]@{ row = $_.row; value = $_.text } })
    }
    $rows = $Values.Count
    [pscustomobject]@{
        name = $Name; type = $type.type; typeLabel = (Get-TypeLabel $type); typeNote = "$($type.note)"; profile = $p
        empty = [int]$p.empty; emptyPct = $(if ($rows) { [Math]::Round(100.0 * [int]$p.empty / $rows, 1) } else { 0 })
        distinct = [int]$p.distinct
        min = $(if ($null -ne $p.min) { Format-ProfileNumber $p.min } else { '' }); max = $(if ($null -ne $p.max) { Format-ProfileNumber $p.max } else { '' })
        top = $top
        outliers = [int]$p.outliers; outlierExamples = $outliers
        middleFrom = $(if ($null -ne $q1) { Format-ProfileNumber $q1 } else { '' }); middleTo = $(if ($null -ne $q3) { Format-ProfileNumber $q3 } else { '' })
        notNumbers = [int]$p.notNumbers; mixedExamples = @($mixed.ToArray())
    }
}

function Get-TableProfile {
    <# One table (rows of text, header first) profiled: rows, columns (Get-ColumnDetails), duplicate
       rows with examples (the same values in every column; which earlier row each repeats) and the
       notable points (DataImport Get-DataQualityNotes, plus the type notes). #>
    param([object[]]$Rows, [string]$Delimiter = ',', [string]$Name = '', [bool]$Cut = $false)
    $rows = @($Rows)
    $width = 0; foreach ($r in $rows) { if (@($r).Count -gt $width) { $width = @($r).Count } }
    $n = [Math]::Max(0, $rows.Count - 1)
    # Column names by DataImport's own rule (trimmed, empty ones "Column N", repeats numbered): the
    # header alone through ConvertTo-DataTable, which costs nothing without data rows.
    $header = New-Object string[] $width
    for ($c = 0; $c -lt $width; $c++) { if ($c -lt @($rows[0]).Count) { $header[$c] = "$(@($rows[0])[$c])" } else { $header[$c] = '' } }
    $names = @(if ($width) { (ConvertTo-DataTable @(, $header) $Delimiter).columns | ForEach-Object { $_.name } })
    $cols = @(for ($c = 0; $c -lt $width; $c++) {
        $vals = New-Object string[] $n
        for ($i = 1; $i -lt $rows.Count; $i++) { $vals[$i - 1] = if ($c -lt $rows[$i].Count) { "$($rows[$i][$c])".Trim() } else { '' } }
        Get-ColumnDetails $names[$c] $vals $Delimiter
    })
    $first = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $dups = 0; $dupExamples = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $key = [string]::Join([string][char]31, [string[]]@($rows[$i]))
        if ($first.ContainsKey($key)) { $dups++; if ($dupExamples.Count -lt $script:Examples) { $dupExamples.Add([pscustomobject]@{ row = $i; sameAs = $first[$key] }) } }
        else { $first[$key] = $i }
    }
    $sheet = @{ rows = $n; duplicates = $dups; columns = @($cols | ForEach-Object { @{ name = $_.name; profile = $_.profile } }) }
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($q in @(Get-DataQualityNotes $sheet 50)) { $notes.Add($q) }
    foreach ($c in $cols) { if ($c.typeNote) { $notes.Add("$($c.name): $($c.typeNote)") } }
    if ($Cut) { $notes.Add("only the first $($script:MaxRows) rows are in this profile") }
    [pscustomobject]@{ name = $Name; rows = $n; columns = $cols; duplicates = $dups; duplicateExamples = @($dupExamples.ToArray()); notes = @($notes.ToArray()); cut = $Cut }
}

function Get-DataProfile {
    <# The profile of one data file of the project: $Source is a project-relative path that must be one
       of Get-DataProfileSources (the files DataImport converted). Returns @{ source; kind; encoding;
       delimiter; made; tables = @(Get-TableProfile ...) }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Source, [datetime]$Now = (Get-Date))
    $root = $ProjectRoot.TrimEnd('\')
    $rel = $Source.Trim().Replace('\', '/').TrimStart('/')
    $known = @(Get-DataProfileSources $root | Where-Object { $_.source -ieq $rel }) | Select-Object -First 1
    if (-not $known) { throw "$Source is not one of the project's converted data files." }
    $full = Resolve-ProjectPath $root $known.source
    $read = Read-ProfileTables $full
    $tables = @(foreach ($t in @($read.tables)) { Get-TableProfile $t.rows $t.delimiter $t.name ([bool]$t.cut) })
    Write-CCBLog info dataprofile 'Data profile made' @{ source = $known.source; tables = $tables.Count; rows = (($tables | Measure-Object rows -Sum).Sum) }
    [pscustomobject]@{ source = $known.source; kind = $read.kind; encoding = $read.encoding; delimiter = $read.delimiter; made = $Now; tables = $tables }
}

function Get-ProfileNotes($Profile) {
    # The notable points of every table, with the sheet's name when there are more.
    $many = @($Profile.tables).Count -gt 1
    @(foreach ($t in @($Profile.tables)) { foreach ($q in @($t.notes)) { if ($many -and $t.name) { "sheet $($t.name): $q" } else { $q } } })
}

function Format-TopValues($Column) {
    (@($Column.top | ForEach-Object { "$($_.value) ($($_.count))" }) -join ', ')
}

function Format-DataProfileReport {
    <# The profile as a Markdown page for the person: the notable points first, then per table the
       columns, values far outside the rest, numbers mixed with text and duplicate rows. #>
    param([Parameter(Mandatory)]$Profile)
    $out = New-Object System.Collections.Generic.List[string]
    $how = @($Profile.kind)
    if ($Profile.delimiter) { $how += "$($Profile.delimiter) separated" }
    if ($Profile.encoding) { $how += $Profile.encoding }
    $out.Add("# Data profile: $($Profile.source)")
    $out.Add('')
    $out.Add("Made by StreamHub on $($Profile.made.ToString('yyyy-MM-dd HH:mm')) from $($Profile.source) ($($how -join ', ')). It describes the file as it is; nothing in the project was changed. Row numbers count the rows under the header: row 1 is the first row of data.")
    $out.Add('')
    $out.Add('## Notable points')
    $out.Add('')
    $notes = @(Get-ProfileNotes $Profile)
    if ($notes.Count) { foreach ($q in $notes) { $out.Add("- $q") } }
    else { $out.Add('- Nothing stands out: no duplicate rows, no column that is often empty or holds one value only, no values far outside the rest, no numbers mixed with text.') }
    $many = @($Profile.tables).Count -gt 1
    $h = if ($many) { '###' } else { '##' }
    foreach ($t in @($Profile.tables)) {
        $out.Add('')
        if ($many) { $out.Add("## Sheet $($t.name)"); $out.Add('') }
        $out.Add("$($t.rows) rows, $(@($t.columns).Count) columns, $($t.duplicates) duplicate row(s).")
        $out.Add('')
        $out.Add("$h Columns")
        $out.Add('')
        $rows = @(, @('Column', 'Type', 'Empty', 'Distinct', 'Lowest', 'Highest', 'Most common'))
        foreach ($c in @($t.columns)) { $rows += , @($c.name, $c.typeLabel, "$($c.empty) ($($c.emptyPct)%)", "$($c.distinct)", $c.min, $c.max, (Format-TopValues $c)) }
        $out.Add((Format-MdTable $rows))
        $out.Add('')
        $out.Add("$h Values far outside the rest")
        $out.Add('')
        $ol = @(foreach ($c in @($t.columns)) { foreach ($e in @($c.outlierExamples)) { , @($c.name, "$($e.row)", "$($e.value)", "$($c.middleFrom) to $($c.middleTo)") } })
        if ($ol.Count) {
            $out.Add('Numbers beyond three times the spread of the middle half of the column, measured from that middle half. Up to five examples per column.')
            $out.Add('')
            $out.Add((Format-MdTable (@(, @('Column', 'Row', 'Value', 'Middle half of the values')) + $ol)))
            foreach ($c in @($t.columns | Where-Object { $_.outliers -gt @($_.outlierExamples).Count })) { $out.Add(''); $out.Add("$($c.name) has $($c.outliers) such values in all.") }
        } else { $out.Add('None.') }
        $out.Add('')
        $out.Add("$h Numbers mixed with text")
        $out.Add('')
        $mx = @(foreach ($c in @($t.columns)) { foreach ($e in @($c.mixedExamples)) { , @($c.name, "$($e.row)", "$($e.value)") } })
        if ($mx.Count) {
            $out.Add('Columns that are mostly numbers but also hold other text, so they are read as text. Up to five examples per column.')
            $out.Add('')
            $out.Add((Format-MdTable (@(, @('Column', 'Row', 'Value')) + $mx)))
        } else { $out.Add('None.') }
        $out.Add('')
        $out.Add("$h Duplicate rows")
        $out.Add('')
        if ($t.duplicates) {
            $out.Add("$($t.duplicates) row(s) repeat an earlier row in every column. The first ones:")
            $out.Add('')
            $out.Add((Format-MdTable (@(, @('Row', 'Same as row')) + @($t.duplicateExamples | ForEach-Object { , @("$($_.row)", "$($_.sameAs)") }))))
        } else { $out.Add('None.') }
    }
    ($out -join "`n") + "`n"
}

function ConvertTo-ProfileCsvLine([object[]]$Cells) {
    # One CSV line, every cell quoted (so no line starts with "###"), line breaks inside as spaces.
    (@($Cells | ForEach-Object { '"' + ("$_" -replace '\r?\n', ' ').Replace('"', '""') + '"' }) -join ',')
}

function ConvertTo-DataProfileCsv {
    <# The profile as workbook text for Office ConvertTo-XlsxBytes: one "### NAME" sheet per section
       (Summary, Notable points, Columns, Most common, Far outside, Mixed values, Duplicates); with more
       than one table every sheet starts with a Sheet column. #>
    param([Parameter(Mandatory)]$Profile)
    $many = @($Profile.tables).Count -gt 1
    $lead = { param($t, [object[]]$cells) if ($many) { @("$($t.name)") + $cells } else { $cells } }
    $head = { param([object[]]$cells) if ($many) { @('Sheet') + $cells } else { $cells } }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('### Summary')
    $out.Add((ConvertTo-ProfileCsvLine @('Item', 'Value')))
    $out.Add((ConvertTo-ProfileCsvLine @('Source', $Profile.source)))
    $out.Add((ConvertTo-ProfileCsvLine @('Made', $Profile.made.ToString('yyyy-MM-dd HH:mm'))))
    $out.Add((ConvertTo-ProfileCsvLine @('Kind', (@($Profile.kind, $(if ($Profile.delimiter) { "$($Profile.delimiter) separated" }), $Profile.encoding) | Where-Object { $_ }) -join ', ')))
    foreach ($t in @($Profile.tables)) {
        $pre = if ($many -and $t.name) { "Sheet $($t.name): " } else { '' }
        $out.Add((ConvertTo-ProfileCsvLine @("${pre}Rows", "$($t.rows)")))
        $out.Add((ConvertTo-ProfileCsvLine @("${pre}Columns", "$(@($t.columns).Count)")))
        $out.Add((ConvertTo-ProfileCsvLine @("${pre}Duplicate rows", "$($t.duplicates)")))
    }
    $out.Add('### Notable points')
    $out.Add((ConvertTo-ProfileCsvLine @('Point')))
    foreach ($q in @(Get-ProfileNotes $Profile)) { $out.Add((ConvertTo-ProfileCsvLine @($q))) }
    $out.Add('### Columns')
    $out.Add((ConvertTo-ProfileCsvLine (& $head @('Column', 'Type', 'Empty', 'Empty %', 'Distinct', 'Lowest', 'Highest', 'Far outside', 'Not numbers'))))
    foreach ($t in @($Profile.tables)) { foreach ($c in @($t.columns)) { $out.Add((ConvertTo-ProfileCsvLine (& $lead $t @($c.name, $c.typeLabel, "$($c.empty)", $c.emptyPct.ToString($script:Inv), "$($c.distinct)", $c.min, $c.max, "$($c.outliers)", "$($c.notNumbers)")))) } }
    $out.Add('### Most common')
    $out.Add((ConvertTo-ProfileCsvLine (& $head @('Column', 'Value', 'Count'))))
    foreach ($t in @($Profile.tables)) { foreach ($c in @($t.columns)) { foreach ($v in @($c.top)) { $out.Add((ConvertTo-ProfileCsvLine (& $lead $t @($c.name, "$($v.value)", "$($v.count)")))) } } }
    $out.Add('### Far outside')
    $out.Add((ConvertTo-ProfileCsvLine (& $head @('Column', 'Row', 'Value', 'Middle half from', 'Middle half to'))))
    foreach ($t in @($Profile.tables)) { foreach ($c in @($t.columns)) { foreach ($e in @($c.outlierExamples)) { $out.Add((ConvertTo-ProfileCsvLine (& $lead $t @($c.name, "$($e.row)", "$($e.value)", $c.middleFrom, $c.middleTo)))) } } }
    $out.Add('### Mixed values')
    $out.Add((ConvertTo-ProfileCsvLine (& $head @('Column', 'Row', 'Value'))))
    foreach ($t in @($Profile.tables)) { foreach ($c in @($t.columns)) { foreach ($e in @($c.mixedExamples)) { $out.Add((ConvertTo-ProfileCsvLine (& $lead $t @($c.name, "$($e.row)", "$($e.value)")))) } } }
    $out.Add('### Duplicates')
    $out.Add((ConvertTo-ProfileCsvLine (& $head @('Row', 'Same as row'))))
    foreach ($t in @($Profile.tables)) { foreach ($d in @($t.duplicateExamples)) { $out.Add((ConvertTo-ProfileCsvLine (& $lead $t @("$($d.row)", "$($d.sameAs)")))) } }
    ($out -join "`n") + "`n"
}

function Save-DataProfile {
    <# Makes the profile of one data file and writes it as Runbooks/Exports/NAME-profile-STAMP.md and
       .xlsx (a number added when that name is taken). Returns @{ source; markdown; xlsx (project-
       relative); markdownFull; xlsxFull; rows; notable }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Source, [datetime]$Now = (Get-Date))
    $root = $ProjectRoot.TrimEnd('\')
    $p = Get-DataProfile $root $Source -Now $Now
    $stem = ([IO.Path]::GetFileNameWithoutExtension($p.source).ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $stem) { $stem = 'data' }
    $base = Get-LayoutPath Exports "$stem-profile-$($Now.ToString('yyyyMMdd-HHmm'))"
    $k = 2; $try = $base
    while ((Test-Path -LiteralPath (Join-Path $root "$try.md".Replace('/', '\'))) -or (Test-Path -LiteralPath (Join-Path $root "$try.xlsx".Replace('/', '\')))) { $try = "$base-$k"; $k++ }
    $md = Join-Path $root "$try.md".Replace('/', '\')
    $xl = Join-Path $root "$try.xlsx".Replace('/', '\')
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $md)
    [IO.File]::WriteAllText($md, (Format-DataProfileReport $p), (New-Object Text.UTF8Encoding($false)))
    Write-XlsxFile $xl (ConvertTo-DataProfileCsv $p)
    $rows = 0; foreach ($t in @($p.tables)) { $rows += [int]$t.rows }
    Write-CCBLog info dataprofile 'Data profile saved' @{ source = $p.source; file = "$try.md" }
    [pscustomobject]@{ source = $p.source; markdown = "$try.md"; xlsx = "$try.xlsx"; markdownFull = $md; xlsxFull = $xl; rows = $rows; notable = @(Get-ProfileNotes $p).Count }
}

Export-ModuleMember -Function Get-DataProfileSources, Get-DataProfile, Format-DataProfileReport, ConvertTo-DataProfileCsv, Save-DataProfile, Get-TableProfile
