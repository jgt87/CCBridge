# Data files made ready for Copilot: a CSV, TSV or Excel file in the project (and a JSON file in
# Source/) is converted to data/NAME.json, rows as objects with typed values (numbers, true/false,
# ISO dates), plus a data/NAME.js copy for pages opened from disk. Copilot is told the columns and
# uses these files instead of writing its own parser. Fixed rules only: the delimiter is the most
# common one in the header line, the encoding is UTF-8 when the bytes are valid UTF-8 (else
# Windows-1252), a column is a number, a date or true/false only when every value in it is.
# A converted file is made again when its source changes, unless someone changed it since.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName Microsoft.VisualBasic
foreach ($m in 'Log', 'Workspace', 'Executor', 'Office', 'DataMirror') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:SkipDir = '(?i)(^|/)(\.streamhub|\.git|node_modules|dist|build|out|coverage|vendor|\.venv|venv|Logs|styles/kit)(/|$)'
$script:MaxBytes = 25MB
$script:MaxRows = 200000
$script:Missing = '^(|null|NULL|N/A|n/a|NA|#N/A)$'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:ManifestRel = '.streamhub/data-imports.json'

function Read-DataText([byte[]]$Bytes) {
    <# Text of a data file: a BOM decides; else UTF-8 when the bytes are valid UTF-8, else Windows-1252. #>
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return @{ text = [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3); encoding = 'UTF-8 with BOM' } }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return @{ text = [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2); encoding = 'UTF-16' } }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return @{ text = [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2); encoding = 'UTF-16' } }
    try { @{ text = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes); encoding = 'UTF-8' } }
    catch { @{ text = [Text.Encoding]::GetEncoding(1252).GetString($Bytes); encoding = 'Windows-1252' } }
}

function Get-CsvDelimiter([string]$Text, [string]$Ext = '.csv') {
    <# Tab for .tsv; else the most common of , ; tab | in the first line, outside quotes (comma when none). #>
    if ($Ext -ieq '.tsv') { return "`t" }
    $line = ($Text -split "`n", 2)[0]
    $bare = [regex]::Replace($line, '"[^"]*"', '')
    $best = ','; $most = 0
    foreach ($d in ',', ';', "`t", '|') {
        $n = $bare.Split([char]$d).Count - 1
        if ($n -gt $most) { $best = $d; $most = $n }
    }
    $best
}

function Read-CsvRows([string]$Text, [string]$Delimiter) {
    <# The rows of a CSV text (quoted fields, "" inside quotes, line breaks inside quotes; blank lines skipped). #>
    $p = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser((New-Object IO.StringReader($Text)))
    try {
        $p.TextFieldType = 'Delimited'
        $p.SetDelimiters($Delimiter)
        $p.HasFieldsEnclosedInQuotes = $true
        $p.TrimWhiteSpace = $false
        $rows = New-Object System.Collections.Generic.List[object]
        while (-not $p.EndOfData) {
            try { $f = $p.ReadFields() } catch { throw "line $($p.ErrorLineNumber) is not valid CSV (a quote that is not closed?)" }
            if ($null -ne $f) { $rows.Add([string[]]$f) }
        }
        $rows.ToArray()
    } finally { $p.Close() }
}

function Get-ColumnNames([string[]]$Header, [int]$Width) {
    # Header names, trimmed; empty ones "Column N", repeated ones "NAME 2".
    $seen = @{}
    for ($i = 0; $i -lt $Width; $i++) {
        $n = if ($i -lt $Header.Count) { "$($Header[$i])".Trim() } else { '' }
        if (-not $n) { $n = "Column $($i + 1)" }
        $base = $n; $k = 2
        while ($seen.ContainsKey($n.ToLowerInvariant())) { $n = "$base $k"; $k++ }
        $seen[$n.ToLowerInvariant()] = $true
        $n
    }
}

function Get-ColumnType([string[]]$Values, [string]$Delimiter = ',') {
    <# The type of a column from all its values (missing ones left out): @{ type = number | boolean |
       date | text; decimal ('.' or ','); order ('iso', 'dmy', 'mdy'); note }. #>
    $vals = @($Values | Where-Object { $_ -notmatch $script:Missing })
    if (-not $vals.Count) { return @{ type = 'text' } }
    $dot = $true; $comma = $true; $bool = $true; $iso = $true; $dmy = $true; $dayFirst = $false; $monthFirst = $false; $dots = $true
    foreach ($v in $vals) {
        if ($dot -and $v -notmatch '^[-+]?(\d+|\d{1,3}(,\d{3})+)(\.\d+)?([eE][-+]?\d+)?$') { $dot = $false }
        if ($comma -and $v -notmatch '^[-+]?(\d+|\d{1,3}(\.\d{3})+)(,\d+)?$') { $comma = $false }
        if ($v -match '^[-+]?0\d') { $dot = $false; $comma = $false }   # 007, 0612: codes, not numbers
        if ($bool -and $v -notmatch '^(?i:true|false)$') { $bool = $false }
        if ($iso -and $v -notmatch '^\d{4}-\d{1,2}-\d{1,2}([T ]\d{1,2}:\d{2}(:\d{2})?)?$') { $iso = $false }
        if ($dmy) {
            $m = [regex]::Match($v, '^(\d{1,2})([/.-])(\d{1,2})\2(\d{4})( \d{1,2}:\d{2}(:\d{2})?)?$')
            if (-not $m.Success) { $dmy = $false }
            else {
                if ([int]$m.Groups[1].Value -gt 12) { $dayFirst = $true }
                if ([int]$m.Groups[3].Value -gt 12) { $monthFirst = $true }
                if ($m.Groups[2].Value -ne '.') { $dots = $false }
            }
        }
        if (-not ($dot -or $comma -or $bool -or $iso -or $dmy)) { break }
    }
    if ($dot -and $comma) { if ($Delimiter -eq ';') { $dot = $false } else { $comma = $false } }   # 1,5 / 1.234 alone: by the file's habit
    if ($dot) { return @{ type = 'number'; decimal = '.' } }
    if ($comma) { return @{ type = 'number'; decimal = ',' } }
    if ($bool) { return @{ type = 'boolean' } }
    if ($iso) { return @{ type = 'date'; order = 'iso' } }
    if ($dmy) {
        if ($dayFirst -and $monthFirst) { return @{ type = 'text' } }
        if ($dayFirst -or (-not $monthFirst -and $dots)) { return @{ type = 'date'; order = 'dmy' } }
        if ($monthFirst) { return @{ type = 'date'; order = 'mdy' } }
        return @{ type = 'text'; note = 'dates where day and month cannot be told apart (all parts 12 or less): kept as text' }
    }
    @{ type = 'text' }
}

function ConvertTo-TypedJson([string]$Value, $Type) {
    <# One value as JSON text, by its column's type. #>
    if ($Value -match $script:Missing) { return 'null' }
    switch ($Type.type) {
        'number' {
            $s = if ($Type.decimal -eq ',') { $Value.Replace('.', '').Replace(',', '.') } else { $Value.Replace(',', '') }
            $d = [double]::Parse($s, [Globalization.NumberStyles]::Float, $script:Inv)
            if ($d -eq [Math]::Floor($d) -and [Math]::Abs($d) -lt 1e15) { return ([int64]$d).ToString($script:Inv) }
            return $d.ToString('R', $script:Inv)
        }
        'boolean' { return $Value.ToLowerInvariant() }
        'date' {
            if ($Type.order -eq 'iso') {
                $m = [regex]::Match($Value, '^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2}))?)?$')
                $y = [int]$m.Groups[1].Value; $mo = [int]$m.Groups[2].Value; $da = [int]$m.Groups[3].Value
            } else {
                $m = [regex]::Match($Value, '^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})(?: (\d{1,2}):(\d{2})(?::(\d{2}))?)?$')
                $y = [int]$m.Groups[3].Value
                if ($Type.order -eq 'dmy') { $da = [int]$m.Groups[1].Value; $mo = [int]$m.Groups[2].Value } else { $mo = [int]$m.Groups[1].Value; $da = [int]$m.Groups[2].Value }
            }
            $out = '{0:0000}-{1:00}-{2:00}' -f $y, $mo, $da
            if ($m.Groups[4].Success) { $out += 'T{0:00}:{1}:{2}' -f [int]$m.Groups[4].Value, $m.Groups[5].Value, $(if ($m.Groups[6].Success) { $m.Groups[6].Value } else { '00' }) }
            return ConvertTo-JsonString $out
        }
    }
    ConvertTo-JsonString $Value
}

function ConvertTo-JsonString([string]$Text) {
    $sb = New-Object Text.StringBuilder ($Text.Length + 2)
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        switch ([int]$ch) {
            34 { [void]$sb.Append('\"') } 92 { [void]$sb.Append('\\') } 10 { [void]$sb.Append('\n') } 13 { [void]$sb.Append('\r') } 9 { [void]$sb.Append('\t') }
            default { if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) } else { [void]$sb.Append($ch) } }
        }
    }
    $sb.Append('"').ToString()
}

function ConvertTo-DataTable {
    <# Rows (first = header) as typed records: @{ columns = @(@{ name; type }); json (an array of
       objects, one per line); rows; notes }. #>
    param([object[]]$Rows, [string]$Delimiter = ',', [string]$Indent = '')
    $rows = @($Rows)
    if (-not $rows.Count) { return @{ columns = @(); json = '[]'; rows = 0; notes = @() } }
    $width = 0; foreach ($r in $rows) { if ($r.Count -gt $width) { $width = $r.Count } }
    $names = @(Get-ColumnNames ([string[]]$rows[0]) $width)
    $types = @(); $notes = @()
    for ($c = 0; $c -lt $width; $c++) {
        $vals = New-Object System.Collections.Generic.List[string]
        for ($i = 1; $i -lt $rows.Count; $i++) { $vals.Add($(if ($c -lt $rows[$i].Count) { "$($rows[$i][$c])".Trim() } else { '' })) }
        $t = Get-ColumnType $vals.ToArray() $Delimiter
        if ($t.note) { $notes += "column $($names[$c]): $($t.note)" }
        $types += , $t
    }
    $keys = @($names | ForEach-Object { ConvertTo-JsonString $_ })
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('[')
    for ($i = 1; $i -lt $rows.Count; $i++) {
        [void]$sb.Append($(if ($i -gt 1) { ",`n$Indent  {" } else { "`n$Indent  {" }))
        for ($c = 0; $c -lt $width; $c++) {
            $v = if ($c -lt $rows[$i].Count) { "$($rows[$i][$c])".Trim() } else { '' }
            if ($c) { [void]$sb.Append(', ') }
            [void]$sb.Append($keys[$c]).Append(': ').Append((ConvertTo-TypedJson $v $types[$c]))
        }
        [void]$sb.Append('}')
    }
    [void]$sb.Append($(if ($rows.Count -gt 1) { "`n$Indent]" } else { ']' }))
    $cols = @(for ($c = 0; $c -lt $width; $c++) { @{ name = $names[$c]; type = $types[$c].type } })
    @{ columns = $cols; json = $sb.ToString(); rows = $rows.Count - 1; notes = $notes }
}

function ConvertFrom-DataFile {
    <# A CSV, TSV, Excel or JSON file as JSON text: @{ json; sheets = @(@{ name; rows; columns });
       encoding; notes }. A workbook with one sheet with data is a list; with more, an object with a
       list per sheet. Throws for a file it cannot read. #>
    param([Parameter(Mandatory)][string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $notes = @()
    if ($ext -in '.xlsx', '.xlsm') {
        $sheets = @(Read-XlsxSheets $Path $script:MaxRows | Where-Object { $_.rows.Count -and $_.state -notin 'hidden', 'veryHidden' })
        if (-not $sheets.Count) { throw 'the workbook has no visible sheet with data' }
        $out = @(); $parts = @(); $one = $null
        foreach ($s in $sheets) {
            $t = ConvertTo-DataTable $s.rows ',' $(if ($sheets.Count -gt 1) { '  ' } else { '' })
            if (-not $one) { $one = $t.json }
            if ($s.total -gt $s.rows.Count) { $notes += "sheet $($s.name): only the first $($script:MaxRows) rows" }
            $notes += @($t.notes | ForEach-Object { "sheet $($s.name), $_" })
            $out += @{ name = $s.name; rows = $t.rows; columns = $t.columns }
            $parts += "  $(ConvertTo-JsonString $s.name): $($t.json)"
        }
        $json = if ($sheets.Count -eq 1) { $one } else { "{`n" + ($parts -join ",`n") + "`n}" }
        return @{ json = $json; sheets = $out; encoding = ''; notes = $notes }
    }
    $read = Read-DataText ([IO.File]::ReadAllBytes($Path))
    if ($ext -eq '.json') {
        try { $null = $read.text | ConvertFrom-Json } catch { throw 'not valid JSON' }
        return @{ json = $read.text.Trim(); sheets = @(); encoding = $read.encoding; notes = @() }
    }
    $delim = Get-CsvDelimiter $read.text $ext
    $rows = @(Read-CsvRows $read.text $delim)
    if (-not $rows.Count) { throw 'the file is empty' }
    if ($rows.Count -gt $script:MaxRows + 1) { $rows = $rows[0..$script:MaxRows]; $notes += "only the first $($script:MaxRows) rows" }
    $t = ConvertTo-DataTable $rows $delim
    $dn = switch ($delim) { ',' { 'comma' } ';' { 'semicolon' } "`t" { 'tab' } '|' { 'bar' } }
    @{ json = $t.json; sheets = @(@{ name = ''; rows = $t.rows; columns = $t.columns }); encoding = $read.encoding; delimiter = $dn; notes = @($notes + $t.notes) }
}

function Get-DataGlobalName([string]$Stem) {
    # sales-2024 -> sales2024Data (the global a page reads).
    $words = @($Stem -split '[^A-Za-z0-9]+' | Where-Object { $_ })
    if (-not $words.Count) { $words = @('page') }
    $name = $words[0].Substring(0, 1).ToLowerInvariant() + $words[0].Substring(1)
    for ($k = 1; $k -lt $words.Count; $k++) { $name += $words[$k].Substring(0, 1).ToUpperInvariant() + $words[$k].Substring(1) }
    if ($name -match '^\d') { $name = "data$name" }
    $name + 'Data'
}

function Get-DataOutputStem([string]$Rel) {
    $s = ([IO.Path]::GetFileNameWithoutExtension($Rel).ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($s) { $s } else { 'data' }
}

function Get-DataImportSources([string]$ProjectRoot) {
    <# Files to convert: CSV, TSV and Excel files anywhere but build output and StreamHub's folders,
       and JSON files in Source/ (which a page cannot load from there). #>
    $root = $ProjectRoot.TrimEnd('\')
    @(Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.csv', '*.tsv', '*.xlsx', '*.xlsm', '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/'); full = $_.FullName; size = $_.Length; stamp = "$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } } |
        Where-Object { $_.rel -match '(?i)\.(csv|tsv|xlsx|xlsm|json)$' -and $_.rel -notmatch $script:SkipDir -and $_.rel -notmatch '(^|/)~\$' -and ($_.rel -notmatch '(?i)\.json$' -or $_.rel -match '(?i)^Source/') } |
        Sort-Object { $_.rel.Length }, rel)
}

function Read-DataImportManifest([string]$ProjectRoot) {
    $file = Join-Path $ProjectRoot $script:ManifestRel.Replace('/', '\')
    $items = @{}
    if (Test-Path -LiteralPath $file) {
        try { $j = [IO.File]::ReadAllText($file) | ConvertFrom-Json; foreach ($it in @($j.items)) { if ($it.output) { $items["$($it.output)"] = $it } } } catch { }
    }
    $items
}

function Save-DataImportManifest([string]$ProjectRoot, $Items) {
    $file = Join-Path $ProjectRoot $script:ManifestRel.Replace('/', '\')
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $file)
    $list = @($Items.Keys | Sort-Object | ForEach-Object { $Items[$_] })
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject @{ version = 1; items = $list } -Depth 8), (New-Object Text.UTF8Encoding($false)))
}

function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n", "`n"))))).Replace('-', '') } finally { $sha.Dispose() }
}

function Update-DataImports {
    <# Converts new and changed data files (Get-DataImportSources) to data/NAME.json, and for a project
       opened from disk ($JsCopy) adds data/NAME.js (a data copy, DataMirror). Never overwrites a file
       it did not write or one changed since. Earlier versions go into one change set. Returns
       @{ items = @(@{ source; output; js; status (created, updated, failed, too-large, edited, taken); note; old; new }); checkpoint }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [bool]$JsCopy = $true, $Checkpoint = $null, [string]$AppRoot = '')
    $root = $ProjectRoot.TrimEnd('\')
    $man = Read-DataImportManifest $root
    $results = New-Object System.Collections.Generic.List[object]
    $cp = $Checkpoint
    $taken = @{}; $changed = $false
    $sources = @(Get-DataImportSources $root)
    $present = @{}; foreach ($s in $sources) { $present[$s.rel] = $true }
    # A source that is gone: its converted file stays (it is still data), without a source to follow.
    foreach ($k in @($man.Keys)) { if (-not $present.ContainsKey("$($man[$k].source)")) { $man.Remove($k); $changed = $true } }
    $bySource = @{}; foreach ($k in $man.Keys) { $bySource["$($man[$k].source)"] = $k }
    foreach ($s in $sources) {
        $out = if ($bySource.ContainsKey($s.rel)) { $bySource[$s.rel] } else {
            $stem = Get-DataOutputStem $s.rel
            $o = "data/$stem.json"
            if ($taken.ContainsKey($o) -or ($man.ContainsKey($o) -and "$($man[$o].source)" -ne $s.rel)) {
                $dir = Split-Path (Split-Path $s.rel) -Leaf
                $o = "data/$(Get-DataOutputStem $dir)-$stem.json"
            }
            $o
        }
        if ($out -ieq $s.rel -or $taken.ContainsKey($out)) { continue }
        $taken[$out] = $true
        $prev = $man[$out]
        $outFull = Join-Path $root $out.Replace('/', '\')
        $exists = Test-Path -LiteralPath $outFull -PathType Leaf
        if ($prev -and "$($prev.stamp)" -eq $s.stamp -and ($exists -or $prev.status)) { continue }   # unchanged (or already reported)
        $entry = [ordered]@{ output = $out; source = $s.rel; stamp = $s.stamp }
        if ($exists -and -not $prev) {
            # Someone else's file with that name (often Copilot's own conversion): left alone.
            $results.Add([pscustomobject]@{ source = $s.rel; output = $out; status = 'taken'; note = '' }); continue
        }
        $old = if ($exists) { [IO.File]::ReadAllText($outFull) } else { $null }
        if ($exists -and $prev.hash -and (Get-TextHash $old) -ne "$($prev.hash)") {
            if (-not $prev.edited) { $prev | Add-Member -Force edited $true; $prev.stamp = $s.stamp; $changed = $true; $results.Add([pscustomobject]@{ source = $s.rel; output = $out; status = 'edited'; note = '' }) }
            continue
        }
        if ($s.size -gt $script:MaxBytes) {
            $entry.status = 'too-large'; $man[$out] = [pscustomobject]$entry; $changed = $true
            $results.Add([pscustomobject]@{ source = $s.rel; output = $out; status = 'too-large'; note = "$([Math]::Round($s.size / 1MB)) MB" }); continue
        }
        try { $conv = ConvertFrom-DataFile $s.full }
        catch {
            $entry.status = 'failed'; $man[$out] = [pscustomobject]$entry; $changed = $true
            $results.Add([pscustomobject]@{ source = $s.rel; output = $out; status = 'failed'; note = "$($_.Exception.Message)" }); continue
        }
        $text = $conv.json + "`n"
        if (-not $cp) { $cp = New-Checkpoint $root 'Data files converted for Copilot' }
        Save-CheckpointFile $cp $root $outFull
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $outFull)
        [IO.File]::WriteAllText($outFull, $text, (New-Object Text.UTF8Encoding($false)))
        # The data copy for pages opened from disk: made once, then kept up to date from the JSON.
        $jsRel = $out -replace '\.json$', '.js'
        $jsFull = Join-Path $root $jsRel.Replace('/', '\')
        $global = Get-DataGlobalName ([IO.Path]::GetFileNameWithoutExtension($out))
        $js = $null
        $jsExists = Test-Path -LiteralPath $jsFull -PathType Leaf
        $w = if ($jsExists) { try { Read-DataWrapper ([IO.File]::ReadAllText($jsFull)) } catch { $null } } else { $null }
        if (($JsCopy -and -not $jsExists) -or ($w -and $w.source -eq $out)) {
            $decl = if ($w) { $w.decl } else { 'window.' }; $name = if ($w) { $w.name } else { $global }
            Save-CheckpointFile $cp $root $jsFull
            [IO.File]::WriteAllText($jsFull, (Get-MirrorHeader $out) + "`n$decl$name = $($conv.json);`n", (New-Object Text.UTF8Encoding($false)))
            $global = $name
            $js = $jsRel
        } elseif ($w -and $w.source -ne $out) { $js = $null } elseif ($jsExists -and $prev -and $prev.js) { $js = "$($prev.js)"; $global = "$($prev.global)" }
        $entry.hash = Get-TextHash $text
        $entry.js = $js; $entry.global = $(if ($js) { $global } else { $null })
        $entry.encoding = $conv.encoding; $entry.delimiter = $conv.delimiter
        $entry.sheets = @($conv.sheets | ForEach-Object { [ordered]@{ name = $_.name; rows = $_.rows; columns = @($_.columns | ForEach-Object { [ordered]@{ name = $_.name; type = $_.type } }) } })
        $entry.notes = @($conv.notes)
        $man[$out] = [pscustomobject]$entry; $changed = $true
        $results.Add([pscustomobject]@{ source = $s.rel; output = $out; js = $js; status = $(if ($prev) { 'updated' } else { 'created' }); note = (@($conv.notes) -join '; '); old = $old; new = $text })
    }
    # The data tools (grouping, totals, sorting, dates) next to the converted files, once.
    $made = @($results | Where-Object { $_.status -in 'created', 'updated' })
    if ($made.Count -and $AppRoot) {
        $tools = Join-Path $root 'data\data-tools.js'
        $from = Join-Path $AppRoot 'templates\data\data-tools.js'
        if (-not (Test-Path -LiteralPath $tools) -and (Test-Path -LiteralPath $from)) {
            if (-not $cp) { $cp = New-Checkpoint $root 'Data files converted for Copilot' }
            Save-CheckpointFile $cp $root $tools
            Copy-Item -LiteralPath $from -Destination $tools
            $results.Add([pscustomobject]@{ source = ''; output = 'data/data-tools.js'; status = 'tools'; note = ''; old = $null; new = [IO.File]::ReadAllText($from) })
        }
    }
    if ($changed) { Save-DataImportManifest $root $man }
    if ($results.Count) { Write-CCBLog info dataimport 'Data files converted' @{ made = @($results | Where-Object { $_.status -in 'created', 'updated' }).Count; problems = @($results | Where-Object { $_.status -in 'failed', 'too-large' }).Count } }
    [pscustomobject]@{ items = $results.ToArray(); checkpoint = $cp }
}

function Format-DataImportNotes($Result) {
    <# Chat lines for what Update-DataImports did. 'taken' says nothing (the project has its own file). #>
    foreach ($r in @($Result.items)) {
        switch ($r.status) {
            'created' { "$($r.output) made from $($r.source)$(if ($r.js) { " (and $($r.js) for web pages)" }): Copilot uses it instead of parsing the file itself.$(if ($r.note) { " Note: $($r.note)." })" }
            'updated' { "$($r.output) made again: $($r.source) changed.$(if ($r.note) { " Note: $($r.note)." })" }
            'failed' { "$($r.source) could not be converted to $($r.output): $($r.note)." }
            'too-large' { "$($r.source) is too large to convert ($($r.note); at most $($script:MaxBytes / 1MB) MB)." }
            'tools' { "data/data-tools.js added: helpers for the converted data (rows per sheet, filter, sort, group, totals, months, number and date formats), so pages do not write their own." }
            'edited' { "$($r.output) was changed after it was made from $($r.source), so it is no longer made again from it." }
        }
    }
}

function Format-DataImportContext {
    <# The project-context lines for the converted files: where they are, the global of the copy,
       rows and columns with types. Empty when there are none. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [int]$MaxColumns = 40)
    $man = Read-DataImportManifest $ProjectRoot.TrimEnd('\')
    $lines = foreach ($k in @($man.Keys | Sort-Object)) {
        $it = $man[$k]
        if ($it.status -or $it.edited -or -not (Test-Path -LiteralPath (Join-Path $ProjectRoot $k.Replace('/', '\')))) { continue }
        $where = $k
        if ($it.js) { $where += ' (in a web page: <script src="' + $it.js + '"></script> sets window.' + $it.global + ')' }
        $desc = foreach ($s in @($it.sheets)) {
            $cols = @($s.columns | Select-Object -First $MaxColumns | ForEach-Object { "$($_.name) ($($_.type))" })
            $more = @($s.columns).Count - $cols.Count
            $head = if ($s.name -and @($it.sheets).Count -gt 1) { 'sheet "' + $s.name + '": ' } else { '' }
            $head + "$($s.rows) rows; columns: $($cols -join ', ')" + $(if ($more -gt 0) { " and $more more" } else { '' })
        }
        $shape = if (@($it.sheets).Count -gt 1) { 'an object with one list of rows per sheet' } elseif (@($it.sheets).Count) { 'a list of rows' } else { 'the same JSON' }
        "- $where from $($it.source): $shape$(if ($desc) { '; ' + (@($desc) -join '; ') })"
    }
    if (-not @($lines).Count) { return '' }
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'data\data-tools.js')) { $lines = @($lines) + "- data/data-tools.js (window.DataTools; its first comment lists the functions): DataTools.rows(data, sheet), where, sortBy, unique, sum, avg, min, max, count, groupBy, summarize, byMonth, toDate, formatNumber, formatDate, percent. Use these for filtering, totals and grouping instead of writing your own." }
    "Data files ready to use (the helper program converted them; numbers, dates as yyyy-MM-dd and true/false are typed, empty cells are null). Read the data from these instead of parsing the source file, and never write a CSV or Excel parser for them; change the source file, not these, since they are made again when it changes:`n" + (@($lines) -join "`n")
}

Export-ModuleMember -Function Read-DataText, Get-CsvDelimiter, Read-CsvRows, Get-ColumnType, ConvertTo-DataTable, ConvertFrom-DataFile, Get-DataGlobalName, Get-DataImportSources, Update-DataImports, Format-DataImportNotes, Format-DataImportContext
