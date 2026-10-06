# Data files made ready for Copilot (lib/DataImport.psm1): CSV, TSV and Excel files (and JSON in
# Source/) converted to data/NAME.json with typed values plus a data/NAME.js copy and data-tools.js.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\DataImport.psm1') -Force
Import-Module (Join-Path $root 'lib\DataMirror.psm1') -Force
Add-Type -AssemblyName System.IO.Compression

function New-TestProject {
    $p = Join-Path $env:TEMP ('ccb-di-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory (Join-Path $p 'Source') -Force | Out-Null
    $p
}

function New-TestZip([string]$Path, [hashtable]$Parts) {
    $fs = [IO.File]::Create($Path)
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($k in $Parts.Keys) {
            $w = New-Object IO.StreamWriter($zip.CreateEntry($k).Open())
            try { $w.Write($Parts[$k]) } finally { $w.Dispose() }
        }
    } finally { $zip.Dispose(); $fs.Dispose() }
}

Describe 'Column types' {
    It 'types a column only when every value fits' {
        (Get-ColumnType @('1', '2.5', '', '-3')).type | Should Be 'number'
        (Get-ColumnType @('1', 'x')).type | Should Be 'text'
        (Get-ColumnType @('007', '12')).type | Should Be 'text'
        (Get-ColumnType @('TRUE', 'false', 'N/A')).type | Should Be 'boolean'
        (Get-ColumnType @('2024-01-31', '2024-2-1')).type | Should Be 'date'
    }
    It 'reads decimal commas when the file uses semicolons, and day or month first only when it is clear' {
        $t = Get-ColumnType @('1,5', '1.234,75') ';'
        $t.type | Should Be 'number'; $t.decimal | Should Be ','
        (Get-ColumnType @('1,234') ',').decimal | Should Be '.'
        (Get-ColumnType @('31/01/2024', '01/02/2024')).order | Should Be 'dmy'
        (Get-ColumnType @('12/31/2024', '01/02/2024')).order | Should Be 'mdy'
        (Get-ColumnType @('01.02.2024')).order | Should Be 'dmy'
        $t = Get-ColumnType @('01/02/2024', '03/04/2024')
        $t.type | Should Be 'text'; $t.note | Should Match 'cannot be told apart'
        (Get-ColumnType @('31/01/2024', '12/31/2024')).type | Should Be 'text'
    }
}

Describe 'CSV text' {
    It 'finds the delimiter outside quotes and decodes Windows-1252 and UTF-8 with BOM' {
        Get-CsvDelimiter "a;b;c`n1;2;3" | Should Be ';'
        Get-CsvDelimiter "`"x;y`",b`n1,2" | Should Be ','
        Get-CsvDelimiter "a,b" '.tsv' | Should Be "`t"
        (Read-DataText ([byte[]](0x63, 0x61, 0x66, 0xE9))).text | Should Be "caf$([char]0xE9)"
        (Read-DataText ([byte[]](0x63, 0x61, 0x66, 0xE9))).encoding | Should Be 'Windows-1252'
        (Read-DataText ([byte[]](0xEF, 0xBB, 0xBF, 0x61))).text | Should Be 'a'
    }
    It 'reads quoted fields with quotes and line breaks inside, and one header-only row' {
        $rows = @(Read-CsvRows "Name,Note`n`"A `"`"big`"`" one`",`"line 1`nline 2`"`n`nB,x`n" ',')
        $rows.Count | Should Be 3
        $rows[1][0] | Should Be 'A "big" one'
        $rows[1][1] | Should Be "line 1`nline 2"
        @(Read-CsvRows "Only,Header" ',').Count | Should Be 1
    }
    It 'writes typed JSON rows with named, unique columns' {
        $t = ConvertTo-DataTable @(, [string[]]@('Date', '', 'Date', 'Amount')) ','
        $t.rows | Should Be 0
        $t.json | Should Be '[]'
        $t = ConvertTo-DataTable @([string[]]@('Date', '', 'Date', 'Amount'), [string[]]@('2024-01-31', 'x', 'y', '1,234.5'), [string[]]@('2024-02-01', 'a\b', "q`"t", '')) ','
        ($t.columns | ForEach-Object { $_.name }) -join '|' | Should Be 'Date|Column 2|Date 2|Amount'
        $data = $t.json | ConvertFrom-Json
        $data[0].Amount | Should Be 1234.5
        $data[1].Amount | Should Be $null
        $data[1].'Column 2' | Should Be 'a\b'
        $data[1].'Date 2' | Should Be 'q"t'
    }
}

Describe 'Converting the files of a project' {
    $p = New-TestProject
    $csv = "Datum;Regio;Bedrag;Code;Actief`r`n31-01-2024;Noord;1.250,50;007;true`r`n01-02-2024;`"Zuid; west`";3,5;012;FALSE`r`n"
    [IO.File]::WriteAllBytes((Join-Path $p 'Source\Sales Q1.csv'), [Text.Encoding]::GetEncoding(1252).GetBytes($csv))
    [IO.File]::WriteAllText((Join-Path $p 'Source\config.json'), '{ "a": [1, 2] }')
    New-Item -ItemType Directory (Join-Path $p 'node_modules\x') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'node_modules\x\skip.csv'), "a`n1")
    [IO.File]::WriteAllText((Join-Path $p 'other.json'), '{}')
    $r = Update-DataImports $p -AppRoot $root

    It 'converts CSV files and JSON in Source/, nothing in build folders or other JSON' {
        (@($r.items | ForEach-Object { "$($_.status):$($_.output)" }) | Sort-Object) -join ',' | Should Be 'created:data/config.json,created:data/sales-q1.json,tools:data/data-tools.js'
        $rows = [IO.File]::ReadAllText((Join-Path $p 'data\sales-q1.json')) | ConvertFrom-Json
        $rows[0].Datum | Should Be '2024-01-31'
        $rows[0].Bedrag | Should Be 1250.5
        $rows[0].Code | Should Be '007'
        $rows[1].Actief | Should Be $false
        $rows[1].Regio | Should Be 'Zuid; west'
    }
    It 'adds a data copy for web pages that the data copies keep up to date, and the data tools' {
        $js = [IO.File]::ReadAllText((Join-Path $p 'data\sales-q1.js'))
        $js | Should Match '^// Generated from data/sales-q1\.json by the helper program'
        $js | Should Match 'window\.salesQ1Data = \['
        (Read-DataWrapper $js).source | Should Be 'data/sales-q1.json'
        Test-Path (Join-Path $p 'data\data-tools.js') | Should Be $true
    }
    It 'tells Copilot where the data is and its columns' {
        $c = Format-DataImportContext $p
        $c | Should Match 'never write a CSV or Excel parser'
        $c | Should Match '(?m)^- data/sales-q1\.json \(in a web page: <script src="data/sales-q1\.js"></script> sets window\.salesQ1Data\) from Source/Sales Q1\.csv: a list of rows; 2 rows; columns: Datum \(date\), Regio \(text\), Bedrag \(number\), Code \(text\), Actief \(boolean\)'
        $c | Should Match 'DataTools\.rows'
    }
    It 'does nothing when nothing changed, and converts again when the source changes' {
        @((Update-DataImports $p -AppRoot $root).items).Count | Should Be 0
        $f = Join-Path $p 'Source\Sales Q1.csv'
        [IO.File]::WriteAllText($f, "Datum;Bedrag`r`n31-01-2024;2,5`r`n")
        (Get-Item $f).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(1)
        $again = Update-DataImports $p -AppRoot $root
        @($again.items | ForEach-Object { $_.status }) -join ',' | Should Be 'updated'
        ([IO.File]::ReadAllText((Join-Path $p 'data\sales-q1.js'))) | Should Match '"Bedrag": 2\.5'
    }
    It 'leaves a converted file someone changed alone, and says so once' {
        [IO.File]::WriteAllText((Join-Path $p 'data\sales-q1.json'), '[]')
        $f = Join-Path $p 'Source\Sales Q1.csv'
        [IO.File]::WriteAllText($f, "Datum;Bedrag`r`n31-01-2024;3`r`n")
        (Get-Item $f).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(2)
        $e = Update-DataImports $p -AppRoot $root
        @($e.items | ForEach-Object { $_.status }) -join ',' | Should Be 'edited'
        [IO.File]::ReadAllText((Join-Path $p 'data\sales-q1.json')) | Should Be '[]'
        @(Format-DataImportNotes $e)[0] | Should Match 'no longer made again'
        (Get-Item $f).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(3)
        @((Update-DataImports $p -AppRoot $root).items).Count | Should Be 0
        Format-DataImportContext $p | Should Not Match 'sales-q1'
    }
    It 'never overwrites a file it did not write' {
        [IO.File]::WriteAllText((Join-Path $p 'data\orders.json'), '[1]')
        [IO.File]::WriteAllText((Join-Path $p 'Source\orders.csv'), "a`n1")
        $t = Update-DataImports $p -AppRoot $root
        @($t.items | ForEach-Object { $_.status }) -join ',' | Should Be 'taken'
        [IO.File]::ReadAllText((Join-Path $p 'data\orders.json')) | Should Be '[1]'
    }
    It 'reports a file it cannot read' {
        [IO.File]::WriteAllText((Join-Path $p 'Source\broken.csv'), "a,b`n`"open,1`n")
        $b = Update-DataImports $p -AppRoot $root
        @($b.items | Where-Object { $_.status -eq 'failed' }).Count | Should Be 1
        @(Format-DataImportNotes $b) -join ' ' | Should Match 'could not be converted'
        @((Update-DataImports $p -AppRoot $root).items | Where-Object { $_.status -ne 'taken' }).Count | Should Be 0
    }
    It 'makes no data copy when data copies are off' {
        $q = New-TestProject
        [IO.File]::WriteAllText((Join-Path $q 'Source\a.csv'), "x`n1")
        $null = Update-DataImports $q -JsCopy $false -AppRoot $root
        Test-Path (Join-Path $q 'data\a.json') | Should Be $true
        Test-Path (Join-Path $q 'data\a.js') | Should Be $false
        Format-DataImportContext $q | Should Not Match 'script src'
        Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Excel workbooks' {
    It 'converts sheets with dates, numbers and true/false; several sheets become one object' {
        $p = New-TestProject
        $S = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'; $R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
        New-TestZip (Join-Path $p 'Source\Book.xlsx') @{
            'xl/workbook.xml' = "<workbook xmlns=`"$S`" xmlns:r=`"$R`"><sheets><sheet name=`"Sales`" sheetId=`"1`" r:id=`"rId1`"/><sheet name=`"Hidden`" sheetId=`"2`" state=`"hidden`" r:id=`"rId2`"/><sheet name=`"Notes`" sheetId=`"3`" r:id=`"rId3`"/></sheets></workbook>"
            'xl/_rels/workbook.xml.rels' = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="x" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="x" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="x" Target="worksheets/sheet3.xml"/></Relationships>'
            'xl/sharedStrings.xml' = "<sst xmlns=`"$S`"><si><t>Date</t></si><si><t>Amount</t></si><si><t>Paid</t></si></sst>"
            'xl/styles.xml' = "<styleSheet xmlns=`"$S`"><numFmts><numFmt numFmtId=`"164`" formatCode=`"dd/mm/yyyy`"/></numFmts><cellXfs><xf numFmtId=`"0`"/><xf numFmtId=`"14`"/><xf numFmtId=`"164`"/></cellXfs></styleSheet>"
            'xl/worksheets/sheet1.xml' = "<worksheet xmlns=`"$S`"><sheetData><row r=`"1`"><c r=`"A1`" t=`"s`"><v>0</v></c><c r=`"B1`" t=`"s`"><v>1</v></c><c r=`"C1`" t=`"s`"><v>2</v></c></row><row r=`"2`"><c r=`"A2`" s=`"1`"><v>45322</v></c><c r=`"B2`"><v>1250.5</v></c><c r=`"C2`" t=`"b`"><v>1</v></c></row><row r=`"3`"><c r=`"A3`" s=`"2`"><v>45323.5</v></c><c r=`"C3`" t=`"b`"><v>0</v></c></row></sheetData></worksheet>"
            'xl/worksheets/sheet2.xml' = "<worksheet xmlns=`"$S`"><sheetData><row r=`"1`"><c r=`"A1`" t=`"inlineStr`"><is><t>x</t></is></c></row></sheetData></worksheet>"
            'xl/worksheets/sheet3.xml' = "<worksheet xmlns=`"$S`"><sheetData><row r=`"1`"><c r=`"A1`" t=`"inlineStr`"><is><t>Note</t></is></c></row><row r=`"2`"><c r=`"A2`" t=`"inlineStr`"><is><t>Hi</t></is></c></row></sheetData></worksheet>"
        }
        $r = Update-DataImports $p -AppRoot $root
        @($r.items | Where-Object { $_.status -eq 'created' }).Count | Should Be 1
        $d = [IO.File]::ReadAllText((Join-Path $p 'data\book.json')) | ConvertFrom-Json
        @($d.PSObject.Properties.Name) -join ',' | Should Be 'Sales,Notes'
        $d.Sales[0].Date | Should Be '2024-01-31'
        $d.Sales[1].Date | Should Be '2024-02-01T12:00:00'
        $d.Sales[0].Amount | Should Be 1250.5
        $d.Sales[0].Paid | Should Be $true
        $d.Sales[1].Amount | Should Be $null
        $d.Notes[0].Note | Should Be 'Hi'
        Format-DataImportContext $p | Should Match 'an object with one list of rows per sheet; sheet "Sales": 2 rows; columns: Date \(date\), Amount \(number\), Paid \(boolean\)'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
