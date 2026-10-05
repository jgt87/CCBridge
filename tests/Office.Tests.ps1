# Office files (lib/Office.psm1): .docx/.pptx/.xlsx read as Markdown, .docx written from Markdown,
# and the write rules (only .docx, an existing one only when written here).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Office.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
Add-Type -AssemblyName System.IO.Compression

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

$p = Join-Path $env:TEMP ('ccb-office-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $p | Out-Null
$rels = 'http://schemas.openxmlformats.org/package/2006/relationships'
$rId = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

Describe 'Word documents written from Markdown and read back' {
    $md = "# Plan`n`nIntro with **bold**, *italic* and ``code``.`n`n## Steps`n`n1. First`n2. Second`n  - nested`n`n| Name | Value |`n| --- | --- |`n| x | 1 |`n`n" + '```' + "`nline 1`n  line 2`n" + '```' + "`n`n> A quote"
    $f = Join-Path $p 'plan.docx'
    Write-DocxFile $f $md
    It 'writes a real Word package that reads back as the same Markdown' {
        $r = ConvertFrom-OfficeFile $f
        $r.text | Should Match '(?m)^# Plan$'
        $r.text | Should Match ([regex]::Escape('Intro with **bold**, *italic* and `code`.'))
        $r.text | Should Match '(?m)^1\. First\n1\. Second\n  - nested$'
        $r.text | Should Match ([regex]::Escape("| Name | Value |`n| --- | --- |`n| x | 1 |"))
        $r.text | Should Match ([regex]::Escape('```' + "`nline 1`n  line 2`n" + '```'))
        $r.text | Should Match '(?m)^> A quote$'
        Test-OwnDocx $f | Should Be $true
    }
    It 'is text for the read, write and edit actions' {
        $info = Read-TextFile $f
        $info.Encoding | Should Be 'office'
        (Invoke-ReadAction $p @('plan.docx')) -join "`n" | Should Match 'Word document shown as Markdown text; write or edit this text to change it'
        $null = Invoke-EditAction $p 'plan.docx' @(@{ search = '1. First'; replace = '1. First, checked' }) $null
        (ConvertFrom-OfficeFile $f).text | Should Match '1\. First, checked'
    }
}

Describe 'PowerPoint and Excel files read as text' {
    It 'reads slides in their order, with titles, bullets and notes' {
        $f = Join-Path $p 'deck.pptx'
        $a = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="' + $rId + '"'
        $slide = { param($title, $body) "<p:sld $a><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id=`"1`" name=`"t`"/><p:cNvSpPr/><p:nvPr><p:ph type=`"title`"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>$title</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id=`"2`" name=`"b`"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:txBody><a:p><a:r><a:t>$body</a:t></a:r></a:p><a:p><a:pPr lvl=`"1`"/><a:r><a:t>Detail</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>" }
        New-TestZip $f @{
            'ppt/presentation.xml' = "<p:presentation $a><p:sldIdLst><p:sldId id=`"256`" r:id=`"rId2`"/><p:sldId id=`"257`" r:id=`"rId1`"/></p:sldIdLst></p:presentation>"
            'ppt/_rels/presentation.xml.rels' = "<Relationships xmlns=`"$rels`"><Relationship Id=`"rId1`" Type=`"$rId/slide`" Target=`"slides/slide1.xml`"/><Relationship Id=`"rId2`" Type=`"$rId/slide`" Target=`"slides/slide2.xml`"/></Relationships>"
            'ppt/slides/slide1.xml' = (& $slide 'Second title' 'Second body')
            'ppt/slides/slide2.xml' = (& $slide 'First title' 'First body')
            'ppt/slides/_rels/slide2.xml.rels' = "<Relationships xmlns=`"$rels`"><Relationship Id=`"rId9`" Type=`"$rId/notesSlide`" Target=`"../notesSlides/notesSlide1.xml`"/></Relationships>"
            'ppt/notesSlides/notesSlide1.xml' = "<p:notes $a><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id=`"1`" name=`"n`"/><p:cNvSpPr/><p:nvPr><p:ph type=`"body`"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Say hello</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>"
        }
        $t = (ConvertFrom-OfficeFile $f).text
        $t | Should Match "## Slide 1`n`n### First title`n- First body`n  - Detail`n`nNotes: Say hello"
        $t | Should Match "## Slide 2`n`n### Second title"
    }
    It 'reads every sheet as a table, with shared strings, booleans and gaps' {
        $f = Join-Path $p 'data.xlsx'
        $s = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="' + $rId + '"'
        New-TestZip $f @{
            'xl/workbook.xml' = "<workbook $s><sheets><sheet name=`"Sales`" sheetId=`"1`" r:id=`"rId1`"/></sheets></workbook>"
            'xl/_rels/workbook.xml.rels' = "<Relationships xmlns=`"$rels`"><Relationship Id=`"rId1`" Type=`"$rId/worksheet`" Target=`"worksheets/sheet1.xml`"/></Relationships>"
            'xl/sharedStrings.xml' = "<sst $s><si><t>Region</t></si><si><t>Total</t></si><si><r><t>No</t></r><r><t>rth</t></r></si></sst>"
            'xl/worksheets/sheet1.xml' = "<worksheet $s><sheetData><row r=`"1`"><c r=`"A1`" t=`"s`"><v>0</v></c><c r=`"C1`" t=`"s`"><v>1</v></c></row><row r=`"2`"><c r=`"A2`" t=`"s`"><v>2</v></c><c r=`"B2`" t=`"b`"><v>1</v></c><c r=`"C2`"><v>42.5</v></c></row></sheetData></worksheet>"
        }
        $t = (ConvertFrom-OfficeFile $f).text
        $t | Should Match ([regex]::Escape("## Sheet: Sales`n`n| Region |  | Total |`n| --- | --- | --- |`n| North | TRUE | 42.5 |"))
    }
}

Describe 'Which Office files are written' {
    It 'writes only .docx, and an existing one only when it was written here' {
        Get-OfficeWriteRefusal (Join-Path $p 'new.docx') $false | Should BeNullOrEmpty
        Get-OfficeWriteRefusal (Join-Path $p 'deck.pptx') $true | Should Match 'Markdown'
        Get-OfficeWriteRefusal (Join-Path $p 'data.xlsx') $true | Should Match '\.csv'
        Get-OfficeWriteRefusal (Join-Path $p 'old.doc') $false | Should Match 'old binary'
        $word = Join-Path $p 'fromword.docx'
        New-TestZip $word @{
            'word/document.xml' = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Made in Word</w:t></w:r></w:p></w:body></w:document>'
            'docProps/app.xml' = '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Microsoft Office Word</Application></Properties>'
        }
        (ConvertFrom-OfficeFile $word).text | Should Be 'Made in Word'
        { Assert-Writable $p 'fromword.docx' } | Should Throw 'new document'
        (Invoke-ReadAction $p @('fromword.docx')) -join "`n" | Should Match 'made in Word: not rewritten here'
    }
    It 'sends an old binary file to Copilot instead of reading it' {
        [IO.File]::WriteAllBytes((Join-Path $p 'old.doc'), [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0))
        (Invoke-ReadAction $p @('old.doc')) -join "`n" | Should Match 'attaches the file'
    }
    It 'sends the Office rules when a request or the project calls for them' {
        @(Get-PromptModules 'Summarise the report in Docs/report.docx' @{ Traits = @(); Paths = @() }) -contains 'rules:office' | Should Be $true
        @(Get-PromptModules 'Make a Word document with the meeting notes' @{ Traits = @(); Paths = @() }) -contains 'rules:office' | Should Be $true
        @(Get-PromptModules 'Fix the button' @{ Traits = @('office'); Paths = @() }) -contains 'rules:office' | Should Be $true
        @(Get-PromptModules 'Fix the button' @{ Traits = @(); Paths = @() }) -contains 'rules:office' | Should Be $false
    }
}

Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue

Describe 'Outlines of XML and YAML files' {
    It 'lists the first levels with line numbers, names and ids' {
        $xml = "<?xml version=`"1.0`"?>`n<Project Sdk=`"Microsoft.NET.Sdk`">`n  <PropertyGroup>`n    <TargetFramework>net8.0</TargetFramework>`n  </PropertyGroup>`n  <ItemGroup>`n    <PackageReference Include=`"Newtonsoft.Json`" />`n  </ItemGroup>`n</Project>"
        $o = @(Get-FileOutline $xml 'app.csproj')
        $o[0] | Should Be '2  <Project>'
        $o -join "`n" | Should Match '7      <PackageReference Include="Newtonsoft.Json">'
        @(Get-FileOutline '<a><b>' 'broken.xml').Count | Should Be 2   # up to where it breaks
        $yaml = "name: build`non:`n  push:`n    branches: [main]`njobs:`n  test:`n    runs-on: windows-latest"
        (@(Get-FileOutline $yaml 'ci.yml') -join '|') | Should Be '1  name|2  on|3    push|5  jobs|6    test'
    }
}
