# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests\DataProfile.Tests.ps1
# The data profile report: for one converted data file, a page and a workbook for the person.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# Project state (backups of the data conversion) goes to a temporary folder, deleted below.
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\DataImport.psm1') -Force
Import-Module (Join-Path $root 'lib\Office.psm1') -Force
Import-Module (Join-Path $root 'lib\DataProfile.psm1') -Force

Describe 'Data profile report' {
    $proj = Join-Path $env:TEMP ('ccb-profile-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'Source')
    # A Dutch-style CSV: semicolons, decimal commas, day-month-year dates, codes with leading zeros,
    # one amount far outside the rest, a score column with one word among the numbers, a mostly
    # empty note column and one row repeated exactly.
    $lines = @('Code;Name;Amount;Date;Score;Note')
    $names = 'Ann', 'Bob', 'Ann', 'Cas', 'Ann', 'Bob', 'Dirk', 'Ann', 'Eva', 'Bob', 'Ann', 'Cas', 'Ann', 'Bob', 'Eva', 'Ann', 'Bob', 'Cas', 'Ann', 'Bob'
    for ($i = 1; $i -le 20; $i++) {
        $amount = if ($i -eq 7) { '9999,00' } else { '{0},50' -f (10 + $i) }
        $score = if ($i -eq 12) { 'unknown' } else { "$(50 + $i)" }
        $note = if ($i -le 3) { 'checked' } else { '' }
        $lines += ('{0:000};{1};{2};{3:00}-03-2024;{4};{5}' -f $i, $names[$i - 1], $amount, ($i + 9), $score, $note)
    }
    $lines += $lines[-1]
    [IO.File]::WriteAllText((Join-Path $proj 'Source\sales.csv'), (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    # A workbook with two sheets: ISO dates, decimals and a code column with leading zeros.
    $wb = "### Orders`nOrder,Placed,Total`n0101,2024-01-05,12.5`n0102,2024-02-11,13.25`n0103,2024-03-02,`n### Staff`nName,Team`nAnn,Blue`nBob,Blue`n"
    Write-XlsxFile (Join-Path $proj 'Source\book.xlsx') $wb
    $null = Update-DataImports -ProjectRoot $proj -JsCopy $false

    It 'lists the converted data files as the sources to choose from' {
        $s = @(Get-DataProfileSources $proj)
        (@($s | ForEach-Object { $_.source }) -join ',') | Should Be 'Source/book.xlsx,Source/sales.csv'
        $csv = $s | Where-Object { $_.source -eq 'Source/sales.csv' }
        $csv.rows | Should Be 21
        $csv.columns | Should Be 6
        ($s | Where-Object { $_.source -eq 'Source/book.xlsx' }).sheets | Should Be 2
    }

    $p = Get-DataProfile $proj 'Source/sales.csv' -Now ([datetime]'2026-10-25 14:03')
    $t = @($p.tables)[0]
    $col = { param($n) @($t.columns | Where-Object { $_.name -eq $n })[0] }

    It 'reads the file the way the data import does' {
        $p.kind | Should Be 'CSV'
        $p.delimiter | Should Be 'semicolon'
        $t.rows | Should Be 21
        @($t.columns).Count | Should Be 6
        (& $col 'Code').type | Should Be 'text'
        (& $col 'Amount').typeLabel | Should Be 'number (decimal comma)'
        (& $col 'Date').typeLabel | Should Be 'date (day-month-year)'
        (& $col 'Date').min | Should Be '2024-03-10'
        (& $col 'Date').max | Should Be '2024-03-29'
    }

    It 'counts empty and distinct values and names the most common ones of a text column' {
        $n = & $col 'Note'
        $n.empty | Should Be 18
        $n.emptyPct | Should Be 85.7
        $nm = & $col 'Name'
        $nm.distinct | Should Be 5
        @($nm.top)[0].value | Should Be 'Ann'
        @($nm.top)[0].count | Should Be 8
        (& $col 'Code').top.Count | Should Be 5
    }

    It 'gives examples of values far outside the rest, by the profile''s own rule' {
        $a = & $col 'Amount'
        $a.outliers | Should Be 1
        @($a.outlierExamples).Count | Should Be 1
        @($a.outlierExamples)[0].row | Should Be 7
        @($a.outlierExamples)[0].value | Should Be '9999,00'
        $a.middleFrom | Should Be '16.5'
        $a.middleTo | Should Be '27.5'
    }

    It 'gives examples of text among numbers, and the duplicate rows with the row they repeat' {
        $s = & $col 'Score'
        $s.notNumbers | Should Be 1
        @($s.mixedExamples)[0].row | Should Be 12
        @($s.mixedExamples)[0].value | Should Be 'unknown'
        $t.duplicates | Should Be 1
        @($t.duplicateExamples)[0].row | Should Be 21
        @($t.duplicateExamples)[0].sameAs | Should Be 20
    }

    It 'writes a report with the notable points first' {
        $md = Format-DataProfileReport $p
        $md | Should Match '(?m)^# Data profile: Source/sales\.csv$'
        $md | Should Match 'CSV, semicolon separated, UTF-8'
        $md.IndexOf('## Notable points') | Should BeLessThan $md.IndexOf('## Columns')
        $md | Should Match '- 1 duplicate row\(s\)'
        $md | Should Match '- Note is empty in 86% of rows'
        $md | Should Match '- Amount has 1 value\(s\) far outside the rest'
        $md | Should Match '\| Amount \| 7 \| 9999,00 \| 16\.5 to 27\.5 \|'
        $md | Should Match '\| Score \| 12 \| unknown \|'
        $md | Should Match '\| 21 \| 20 \|'
        $md | Should Match '\| Name \| text \| 0 \(0%\) \| 5 \|  \|  \| Ann \(8\), Bob \(7\)'
    }

    It 'writes the same as workbook text with one sheet per section' {
        $txt = ConvertTo-DataProfileCsv $p
        $sheets = @(Split-XlsxSheets $txt)
        (@($sheets | ForEach-Object { $_.name }) -join '|') | Should Be 'Summary|Notable points|Columns|Most common|Far outside|Mixed values|Duplicates'
        $cols = @(Read-CsvTable ($sheets | Where-Object { $_.name -eq 'Columns' }).csv)
        $cols.Count | Should Be 7
        (@($cols[1]) -join '|') | Should Be 'Code|text|0|0|20|||0|0'
    }

    It 'profiles every sheet of a workbook, leading zeros kept as codes' {
        $w = Get-DataProfile $proj 'Source/book.xlsx'
        @($w.tables).Count | Should Be 2
        $o = @($w.tables)[0]
        $o.name | Should Be 'Orders'
        @($o.columns)[0].type | Should Be 'text'
        @($o.columns)[1].min | Should Be '2024-01-05'
        @($o.columns)[2].empty | Should Be 1
        $md = Format-DataProfileReport $w
        $md | Should Match '(?m)^## Sheet Orders$'
        $md | Should Match '(?m)^### Columns$'
        $md | Should Match '- sheet Orders: Total is empty in 33% of rows'
        (@(Split-XlsxSheets (ConvertTo-DataProfileCsv $w))[2].csv -split "`n")[0] | Should Be '"Sheet","Column","Type","Empty","Empty %","Distinct","Lowest","Highest","Far outside","Not numbers"'
    }

    It 'saves the page and the workbook in Runbooks/Exports, never over an earlier one' {
        $now = [datetime]'2026-10-25 14:03'
        $r = Save-DataProfile $proj 'Source/sales.csv' -Now $now
        $r.markdown | Should Be 'Runbooks/Exports/sales-profile-20261025-1403.md'
        $r.xlsx | Should Be 'Runbooks/Exports/sales-profile-20261025-1403.xlsx'
        Test-Path -LiteralPath $r.markdownFull | Should Be $true
        Test-OwnXlsx $r.xlsxFull | Should Be $true
        $read = @(Read-XlsxSheets $r.xlsxFull)
        $read.Count | Should Be 7
        (@($read | Where-Object { $_.name -eq 'Far outside' })[0].rows[1] -join '|') | Should Be 'Amount|7|9999,00|16.5|27.5'
        $again = Save-DataProfile $proj 'Source/sales.csv' -Now $now
        $again.markdown | Should Be 'Runbooks/Exports/sales-profile-20261025-1403-2.md'
    }

    It 'refuses a file that is not one of the converted data files' {
        { Get-DataProfile $proj 'Source/other.csv' } | Should Throw 'not one of the project'
        { Get-DataProfile $proj '..\outside.csv' } | Should Throw 'not one of the project'
    }

    It 'profiles 10,000 rows quickly enough to run in the request' {
        $big = New-Object System.Collections.Generic.List[string]
        $big.Add('Id,Region,Amount,Day,Flag,Code')
        $regions = 'North', 'South', 'East', 'West'
        for ($i = 1; $i -le 10000; $i++) { $big.Add(('{0},{1},{2}.{3},2024-{4:00}-{5:00},{6},{7:00000}' -f $i, $regions[$i % 4], ($i % 500), ($i % 100), (1 + $i % 12), (1 + $i % 28), $(if ($i % 2) { 'true' } else { 'false' }), ($i % 777))) }
        [IO.File]::WriteAllText((Join-Path $proj 'Source\big.csv'), ($big -join "`n"))
        $null = Update-DataImports -ProjectRoot $proj -JsCopy $false
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $b = Get-DataProfile $proj 'Source/big.csv'
        $null = ConvertTo-DataProfileCsv $b
        $null = Format-DataProfileReport $b
        $watch.Stop()
        Write-Host "    10,000 rows x 6 columns profiled in $([Math]::Round($watch.Elapsed.TotalSeconds, 2)) s"
        @($b.tables)[0].rows | Should Be 10000
        $watch.Elapsed.TotalSeconds | Should BeLessThan 15
    }

    Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_STATE_ROOT = $null
