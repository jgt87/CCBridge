# New decks from a deck outline Copilot writes (lib/PptxDeck.psm1): the outline check, listing and
# naming, choosing template layouts, shrinking text, building the .pptx on a template (opened again and
# read part by part), and the fixed rules for a file in Copilot's own workspace. The templates are built
# here from XML strings (tests/PptxTestDecks.ps1); no PowerPoint is needed.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\lib\PptxLayoutMatch.psm1') -Force
Import-Module (Join-Path $here '..\lib\PptxRetheme.psm1') -Force
Import-Module (Join-Path $here '..\lib\PptxDeck.psm1') -Force
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('pptx-deck-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $script:Tmp

. (Join-Path $here 'PptxTestDecks.ps1')

function Get-Problems([string]$Json, [string]$Path = 'Work/test.deck.json', [string]$Root = '') {
    @(Test-DeckOutlineFile $Path $Json $Root)
}

function Get-OneSlide([string]$SlideJson) {
    Get-Problems ('{"title": "T", "slides": [' + $SlideJson + ']}')
}

function Get-DeckExample {
    # The example outline of prompts/rules/deck.md, as Copilot is shown it.
    $md = [IO.File]::ReadAllText((Join-Path $here '..\prompts\rules\deck.md'))
    $m = [regex]::Match($md, '(?s)```json\s*(.*?)```')
    $m.Groups[1].Value
}

function Get-SlideTexts($Xml) {
    @($Xml.SelectNodes("//*[local-name()='t']") | ForEach-Object { $_.InnerText })
}

# ------------------------------------------------------------------------------- the outline check

Describe 'Test-DeckOutlineFile accepts good outlines' {
    It 'accepts the example in prompts/rules/deck.md' {
        $json = Get-DeckExample
        $json | Should Match '"slides"'
        (Get-Problems $json 'Work/topic-review.deck.json').Count | Should Be 0
    }

    It 'accepts one slide, one bullet, one-row children and a one-row table (lists of one stay lists)' {
        (Get-OneSlide '{"layout": "content", "title": "A", "bullets": ["only"]}').Count | Should Be 0
        (Get-OneSlide '{"layout": "content", "bullets": [{"text": "a", "children": ["b"]}]}').Count | Should Be 0
        (Get-OneSlide '{"layout": "content", "table": [["H1", "H2"]]}').Count | Should Be 0
        (Get-OneSlide '{"layout": "content", "table": {"rows": [["H1", 2]]}}').Count | Should Be 0
        (Get-OneSlide '{"layout": "content", "table": {"rows": [["H1", 2], ["a", 3]]}}').Count | Should Be 0
    }

    It 'accepts levels, both columns, notes and an exact template layout name' {
        $s = '{"layout": "Twee kolommen", "title": "X", "left": [{"text": "a", "level": 0}, {"text": "b", "level": 4}], "right": ["c"], "notes": "say this"}'
        (Get-OneSlide $s).Count | Should Be 0
    }

    It 'ignores files that are not deck outlines' {
        (Get-Problems 'not json at all' 'Work/notes.json').Count | Should Be 0
        (Get-Problems 'not json' 'src/app.js').Count | Should Be 0
    }
}

Describe 'Test-DeckOutlineFile refuses bad outlines' {
    It 'wants one file in Work/ with a plain name' {
        $ok = '{"slides": [{"layout": "title"}]}'
        (Get-Problems $ok 'docs/a.deck.json') -join ' ' | Should Match 'one file in Work/: write it as Work/a\.deck\.json'
        (Get-Problems $ok 'Work/sub/a.deck.json') -join ' ' | Should Match 'one file in Work/'
        (Get-Problems $ok 'Work/My Deck.deck.json') -join ' ' | Should Match 'only letters, digits'
        (Get-Problems $ok 'Work\good-name.deck.json').Count | Should Be 0
    }

    It 'refuses text that is not JSON or not one object' {
        (Get-Problems '{"slides": [') -join ' ' | Should Match 'not valid JSON'
        (Get-Problems '[{"layout": "title"}]') -join ' ' | Should Match 'must be one JSON object'
        (Get-Problems '"just text"') -join ' ' | Should Match 'must be one JSON object'
    }

    It 'refuses unknown top-level fields and a title that is not text' {
        $p = Get-Problems '{"title": 5, "theme": "dark", "slides": [{"layout": "title"}]}'
        $p -join ' ' | Should Match 'unknown top-level field\(s\) theme'
        $p -join ' ' | Should Match '"title" must be a string'
    }

    It 'refuses missing, empty and too many slides' {
        (Get-Problems '{"title": "T"}') -join ' ' | Should Match '"slides" must be a list with at least one slide'
        (Get-Problems '{"slides": []}') -join ' ' | Should Match 'at least one slide'
        (Get-Problems '{"slides": {"layout": "title"}}') -join ' ' | Should Match 'must be a list'
        $many = '{"slides": [' + ((@(1..81) | ForEach-Object { '{"layout": "title"}' }) -join ',') + ']}'
        (Get-Problems $many) -join ' ' | Should Match '81 slides; at most 80'
    }

    It 'refuses slides that are not objects, unknown fields and charts' {
        (Get-Problems '{"slides": ["title"]}') -join ' ' | Should Match 'slide 1 must be an object'
        (Get-OneSlide '{"layout": "content", "foo": 1}') -join ' ' | Should Match 'slide 1: unknown field "foo"'
        (Get-OneSlide '{"layout": "content", "chart": {}}') -join ' ' | Should Match 'charts are not built yet'
    }

    It 'requires a layout as text' {
        (Get-OneSlide '{"title": "A"}') -join ' ' | Should Match '"layout" is required'
        (Get-OneSlide '{"layout": 3}') -join ' ' | Should Match '"layout" is required'
        (Get-OneSlide '{"layout": "  "}') -join ' ' | Should Match '"layout" is required'
    }

    It 'refuses texts of the wrong type' {
        $p = Get-OneSlide '{"layout": "content", "title": 1, "subtitle": ["x"], "notes": {"a": 1}}'
        $p -join ' ' | Should Match '"title" must be a string'
        $p -join ' ' | Should Match '"subtitle" must be a string'
        $p -join ' ' | Should Match '"notes" must be a string'
    }

    It 'refuses bullets that are not a list or hold the wrong items' {
        (Get-OneSlide '{"layout": "content", "bullets": "one line"}') -join ' ' | Should Match '"bullets" must be a list of strings'
        (Get-OneSlide '{"layout": "content", "left": [5]}') -join ' ' | Should Match '"left" item 1 must be a string or an object'
        (Get-OneSlide '{"layout": "content", "right": [{"txt": "a"}]}') -join ' ' | Should Match 'unknown field\(s\) txt'
        (Get-OneSlide '{"layout": "content", "right": [{"txt": "a"}]}') -join ' ' | Should Match '"text" must be a string'
        (Get-OneSlide '{"layout": "content", "bullets": [{"text": "a", "level": 7}]}') -join ' ' | Should Match '"level" must be a whole number from 0 to 4'
        (Get-OneSlide '{"layout": "content", "bullets": [{"text": "a", "level": 1.5}]}') -join ' ' | Should Match '"level" must be a whole number'
        (Get-OneSlide '{"layout": "content", "bullets": [{"text": "a", "children": "b"}]}') -join ' ' | Should Match 'item 1 children must be a list'
    }

    It 'refuses bullets nested deeper than five levels' {
        $deep = '"x"'
        for ($i = 0; $i -lt 6; $i++) { $deep = '{"text": "n", "children": [' + $deep + ']}' }
        (Get-OneSlide ('{"layout": "content", "bullets": [' + $deep + ']}')) -join ' ' | Should Match 'deeper than 5 levels'
    }

    It 'refuses tables whose rows are not lists of cells' {
        (Get-OneSlide '{"layout": "content", "table": ["a", "b"]}') -join ' ' | Should Match 'row 1 must be a list of cells'
        (Get-OneSlide '{"layout": "content", "table": "a,b"}') -join ' ' | Should Match 'must be a list of rows'
        (Get-OneSlide '{"layout": "content", "table": [["a", "b"], ["c"]]}') -join ' ' | Should Match 'row 2 has 1 cells and row 1 has 2'
        (Get-OneSlide '{"layout": "content", "table": [["a", {"b": 1}]]}') -join ' ' | Should Match 'cells must be text or numbers'
        (Get-OneSlide '{"layout": "content", "table": {"rows": [["a"]], "style": "x"}}') -join ' ' | Should Match 'takes only "rows"'
        (Get-OneSlide '{"layout": "content", "table": []}') -join ' ' | Should Match 'has no rows'
        (Get-OneSlide '{"layout": "content", "table": [[]]}') -join ' ' | Should Match 'rows without cells'
    }

    It 'refuses tables too large for a slide' {
        $rows = (@(1..31) | ForEach-Object { '["a", "b"]' }) -join ','
        (Get-OneSlide ('{"layout": "content", "table": [' + $rows + ']}')) -join ' ' | Should Match '31 rows; at most 30'
        $cells = (@(1..13) | ForEach-Object { '"c"' }) -join ','
        (Get-OneSlide ('{"layout": "content", "table": [[' + $cells + ']]}')) -join ' ' | Should Match '13 columns; at most 12'
    }

    It 'refuses a picture outside the project, of another type or missing' {
        $root = Join-Path $script:Tmp 'picproj'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'Assets')
        [IO.File]::WriteAllBytes((Join-Path $root 'Assets\logo.png'), $script:Png1)
        $pic = { param($p) Get-Problems ('{"slides": [{"layout": "picture", "picture": "' + $p + '"}]}') 'Work/a.deck.json' $root }
        (& $pic '../outside.png') -join ' ' | Should Match 'a path inside the project'
        (& $pic 'Assets/../../x.png') -join ' ' | Should Match 'a path inside the project'
        (& $pic 'C:/x.png') -join ' ' | Should Match 'a path inside the project'
        (& $pic '/x.png') -join ' ' | Should Match 'a path inside the project'
        (& $pic 'Assets/logo.svg') -join ' ' | Should Match 'the picture must be a'
        (& $pic 'Assets/none.png') -join ' ' | Should Match 'the project has no file Assets/none\.png'
        (& $pic 'Assets/logo.png').Count | Should Be 0
        (Get-OneSlide '{"layout": "picture", "picture": 3}') -join ' ' | Should Match '"picture" must be the path'
        # Without a project root only the path's form is checked.
        (Get-OneSlide '{"layout": "picture", "picture": "Assets/none.png"}').Count | Should Be 0
    }
}

# ------------------------------------------------------------------------------- reading, listing, naming

Describe 'Read-DeckOutline and Get-DeckOutlines' {
    $root = Join-Path $script:Tmp 'listproj'
    $files = @('Work\a.deck.json', 'Work\b.json', 'Work\c.deck.json.bak', 'dist\d.deck.json', 'node_modules\x\e.deck.json', '.streamhub\f.deck.json', 'build\h.deck.json', 'sub\g.deck.json')
    foreach ($f in $files) {
        $full = Join-Path $root $f
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
        [IO.File]::WriteAllText($full, '{"title": "From ' + $f.Replace('\', '/') + '", "slides": [{"layout": "title"}]}')
    }
    (Get-Item -LiteralPath (Join-Path $root 'Work\a.deck.json')).LastWriteTime = (Get-Date).AddHours(-2)
    (Get-Item -LiteralPath (Join-Path $root 'sub\g.deck.json')).LastWriteTime = (Get-Date).AddHours(-1)

    It 'lists only .deck.json files outside build output and the helper folder, newest first' {
        $list = @(Get-DeckOutlines $root)
        $list.Count | Should Be 2
        $list[0] | Should Be 'sub/g.deck.json'
        $list[1] | Should Be 'Work/a.deck.json'
    }

    It 'gives an empty list for a project without outlines' {
        $empty = Join-Path $script:Tmp 'emptyproj'
        $null = New-Item -ItemType Directory -Force -Path $empty
        @(Get-DeckOutlines $empty).Count | Should Be 0
        @(Get-DeckOutlines ($empty + '\')).Count | Should Be 0
    }

    It 'reads an outline as objects' {
        $o = Read-DeckOutline (Join-Path $root 'Work\a.deck.json')
        $o.title | Should Be 'From Work/a.deck.json'
        @($o.slides).Count | Should Be 1
        @($o.slides)[0].layout | Should Be 'title'
    }
}

Describe 'Get-PptxDeckName' {
    $now = Get-Date -Year 2026 -Month 3 -Day 4 -Hour 5 -Minute 6 -Second 0

    It 'names the deck after the outline in Runbooks/Exports with the time' {
        Get-PptxDeckName 'Work/quarterly-review.deck.json' -Now $now | Should Be 'Runbooks/Exports/quarterly-review-20260304-0506.pptx'
        Get-PptxDeckName 'Work\Q1.DECK.JSON' -Now $now | Should Be 'Runbooks/Exports/Q1-20260304-0506.pptx'
        Get-PptxDeckName 'Work/my deck!.deck.json' -Now $now | Should Be 'Runbooks/Exports/my-deck--20260304-0506.pptx'
    }

    It 'numbers the name when the file is taken' {
        $root = Join-Path $script:Tmp 'nameproj'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'Runbooks\Exports')
        Get-PptxDeckName 'Work/r.deck.json' -Now $now -ProjectRoot $root | Should Be 'Runbooks/Exports/r-20260304-0506.pptx'
        [IO.File]::WriteAllText((Join-Path $root 'Runbooks\Exports\r-20260304-0506.pptx'), 'x')
        Get-PptxDeckName 'Work/r.deck.json' -Now $now -ProjectRoot $root | Should Be 'Runbooks/Exports/r-20260304-0506-2.pptx'
        [IO.File]::WriteAllText((Join-Path $root 'Runbooks\Exports\r-20260304-0506-2.pptx'), 'x')
        Get-PptxDeckName 'Work/r.deck.json' -Now $now -ProjectRoot $root | Should Be 'Runbooks/Exports/r-20260304-0506-3.pptx'
    }
}

Describe 'Get-DeckParagraphs' {
    It 'flattens strings, levels and children into paragraphs with levels' {
        $o = ConvertFrom-Json '{"b": ["one", {"text": "two", "children": ["two-a", {"text": "two-b", "children": ["deep"]}]}, {"text": "lvl", "level": 3}, {"text": "max", "level": 4, "children": ["below"]}]}'
        $p = @(Get-DeckParagraphs $o.b)
        ($p | ForEach-Object { "$($_.level):$($_.text)" }) -join '|' | Should Be '0:one|0:two|1:two-a|1:two-b|2:deep|3:lvl|4:max|4:below'
    }
}

# ------------------------------------------------------------------------------- layouts and text sizes

Describe 'Select-DeckLayout' {
    $office = Join-Path $script:Tmp 'office-layouts.pptx'
    $null = New-TestDeck -Path $office
    $corp = Join-Path $script:Tmp 'corp-layouts.pptx'
    $null = New-TestDeck -Path $corp -Layouts (Get-CorporateLayouts) -Size @(12192000, 6858000)
    $ol = (Read-PptxDeck $office).layouts
    $cl = (Read-PptxDeck $corp).layouts

    It 'picks Office layouts by kind' {
        (Select-DeckLayout $ol 'title').layout.name | Should Be 'Title Slide'
        (Select-DeckLayout $ol 'content').layout.name | Should Be 'Title and Content'
        (Select-DeckLayout $ol 'section_header').layout.name | Should Be 'Section Header'
        (Select-DeckLayout $ol 'two_content').layout.name | Should Be 'Two Content'
        (Select-DeckLayout $ol 'comparison').layout.name | Should Be 'Two Content'
        (Select-DeckLayout $ol 'title_only').layout.name | Should Be 'Title Only'
        (Select-DeckLayout $ol 'blank').layout.name | Should Be 'Blank'
        (Select-DeckLayout $ol 'closing').layout.name | Should Be 'Title Slide'
        (Select-DeckLayout $ol 'quote').layout.name | Should Be 'Section Header'
        (Select-DeckLayout $ol 'agenda').layout.name | Should Be 'Title and Content'
        (Select-DeckLayout $ol 'Section Header').note | Should Be ''
        (Select-DeckLayout $ol 'two-content').layout.name | Should Be 'Two Content'
    }

    It 'picks the untyped Dutch layouts of a corporate template by kind' {
        (Select-DeckLayout $cl 'title').layout.name | Should Be 'Cover'
        (Select-DeckLayout $cl 'content').layout.name | Should Be 'Titel en inhoud'
        (Select-DeckLayout $cl 'section_header').layout.name | Should Be 'Hoofdstuk'
        (Select-DeckLayout $cl 'two_content').layout.name | Should Be 'Twee kolommen'
        (Select-DeckLayout $cl 'title_only').layout.name | Should Be 'Alleen titel'
        (Select-DeckLayout $cl 'blank').layout.name | Should Be 'Leeg'
    }

    It 'takes an exact layout name first, whatever its case' {
        $r = Select-DeckLayout $cl 'twee KOLOMMEN'
        $r.layout.name | Should Be 'Twee kolommen'
        $r.note | Should Be ''
        (Select-DeckLayout $ol ' Blank ').layout.name | Should Be 'Blank'
    }

    It 'falls back to the closest placeholders with a note for an unknown name' {
        $r = Select-DeckLayout $ol 'Fancy Brand Slide' @('title', 'content', 'content')
        $r.layout.name | Should Be 'Two Content'
        $r.note | Should Match 'no layout of the template matches "Fancy Brand Slide", so it is on "Two Content"'
        (Select-DeckLayout $ol 'Unknown' @('title')).layout.name | Should Be 'Title Only'
    }

    It 'refuses a template without layouts' {
        { Select-DeckLayout @() 'content' } | Should Throw 'no slide layouts'
    }
}

Describe 'Get-DeckTextScale' {
    $rect = @{ x = 457200; y = 1600200; cx = 8229600; cy = 4525963 }
    $short = { param([int]$n) @(1..$n | ForEach-Object { @{ text = "Point $_"; level = 0 } }) }

    It 'leaves text that fits at full size' {
        $f = Get-DeckTextScale (& $short 3) $rect 2800
        $f.scale | Should Be 1
        $f.overflow | Should Be $false
    }

    It 'shrinks text that is a little too long, in 5% steps' {
        $f = Get-DeckTextScale (& $short 9) $rect 2800
        $f.scale | Should Be 0.95
        $f.overflow | Should Be $false
    }

    It 'stops at 60% and flags what still does not fit' {
        $f = Get-DeckTextScale (& $short 40) $rect 2800
        $f.scale | Should Be 0.6
        $f.overflow | Should Be $true
    }

    It 'counts long lines and deeper levels as more room' {
        $long = @(1..4 | ForEach-Object { @{ text = ('word ' * 40); level = 0 } })
        (Get-DeckTextScale $long $rect 2800).scale | Should BeLessThan 1
    }

    It 'leaves text alone without a place or a size' {
        (Get-DeckTextScale (& $short 40) $null 2800).scale | Should Be 1
        (Get-DeckTextScale (& $short 40) $rect 0).overflow | Should Be $false
    }
}

# ------------------------------------------------------------------------------- building a deck

Describe 'New-PptxFromOutline' {
    $proj = Join-Path $script:Tmp 'buildproj'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'Work'), (Join-Path $proj 'Assets')
    [IO.File]::WriteAllBytes((Join-Path $proj 'Assets\chart.png'), $script:Png1)

    $tpl = Join-Path $script:Tmp 'brand.pptx'
    $tplSlides = @(
        @{ layout = 1; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="ctrTitle"/>' -Text 'TEMPLATE START'); notes = 'template note'; pics = @{ rId5 = (New-TestPng 200) } },
        @{ layout = 2; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'TEMPLATE MIDDLE') + (New-PicXml 5 'rId5' @(100, 100, 200, 200)); pics = @{ rId5 = (New-TestPng 201) } }
    )
    $null = New-TestDeck -Path $tpl -Slides $tplSlides -NotesMaster
    $tplHash = Get-FileHashText $tpl

    $outline = @'
{"title": "Review", "slides": [
  {"layout": "title", "title": "QUARTER REVIEW", "subtitle": "TEAM - MAY"},
  {"layout": "content", "title": "KEY POINTS", "bullets": ["POINT ONE", {"text": "POINT TWO", "children": ["DETAIL A", {"text": "DETAIL B", "children": ["DEEPER"]}]}], "notes": "SAY THIS FIRST\nTHEN THIS"},
  {"layout": "content", "title": "NUMBERS", "table": [["ITEM", "VALUE"], ["APPLES", 12], ["PEARS", "7 & 8 <ok>"]]},
  {"layout": "two_content", "title": "COMPARE", "left": ["LEFT ONE"], "right": ["RIGHT ONE"]},
  {"layout": "title_only", "title": "PICTURE", "picture": "Assets/chart.png"},
  {"layout": "Not In Template", "title": "ODD ONE"}
]}
'@
    $outlinePath = Join-Path $proj 'Work\review.deck.json'
    [IO.File]::WriteAllText($outlinePath, $outline)
    $outlineHash = Get-FileHashText $outlinePath
    $out = Join-Path $proj 'Runbooks\Exports\review.pptx'
    $result = New-PptxFromOutline -TemplatePath $tpl -OutlinePath $outlinePath -OutPath $out -ProjectRoot $proj
    $slides = @(Get-OutSlides $out)

    It 'writes the deck with one slide per outline slide and leaves template and outline unchanged' {
        Test-Path -LiteralPath $out | Should Be $true
        $result.slides | Should Be 6
        $slides.Count | Should Be 6
        Get-FileHashText $tpl | Should Be $tplHash
        Get-FileHashText $outlinePath | Should Be $outlineHash
    }

    It 'makes a package PowerPoint opens without repair' {
        @(Get-PackageProblems $out) -join '; ' | Should Be ''
        $zip = [IO.Compression.ZipFile]::OpenRead($out)
        try { $names = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
        @($names | Where-Object { $_ -match '^ppt/slides/slide\d+\.xml$' }).Count | Should Be 6
    }

    It 'leaves the template slides, their notes and pictures out' {
        $all = ($slides | ForEach-Object { (Get-SlideTexts $_.xml) -join ' ' }) -join ' '
        $all | Should Not Match 'TEMPLATE'
        ($slides | ForEach-Object { $_.notes }) -join ' ' | Should Not Match 'template note'
        $zip = [IO.Compression.ZipFile]::OpenRead($out)
        try { $media = @($zip.Entries | Where-Object { $_.FullName -match '^ppt/media/' }) } finally { $zip.Dispose() }
        $media.Count | Should Be 1
    }

    It 'puts each slide on its layout with its title' {
        ($slides | ForEach-Object { $_.layout }) -join '|' | Should Be 'Title Slide|Title and Content|Title and Content|Two Content|Title Only|Title Only'
        (Get-SlideTexts $slides[0].xml) -join '|' | Should Be 'QUARTER REVIEW|TEAM - MAY'
        @(Get-SlideTexts $slides[1].xml)[0] | Should Be 'KEY POINTS'
        @(Get-SlideTexts $slides[5].xml)[0] | Should Be 'ODD ONE'
        $ids = @($slides | ForEach-Object { [int]$_.id })
        $ids[0] | Should Be 256
    }

    It 'fills the title and subtitle placeholders' {
        $x = $slides[0].xml
        $x.SelectSingleNode("//*[local-name()='ph' and @type='ctrTitle']") | Should Not BeNullOrEmpty
        $x.SelectSingleNode("//*[local-name()='ph' and @type='subTitle']") | Should Not BeNullOrEmpty
    }

    It 'writes bullets as paragraphs with their levels' {
        $paras = @($slides[1].xml.SelectNodes("//*[local-name()='sp'][.//*[local-name()='ph' and @idx='1']]//*[local-name()='p']"))
        $got = @($paras | ForEach-Object {
                $pPr = $_.SelectSingleNode("*[local-name()='pPr']")
                $lv = if ($pPr) { $pPr.GetAttribute('lvl') } else { '0' }
                "${lv}:$($_.InnerText)"
            })
        $got -join '|' | Should Be '0:POINT ONE|0:POINT TWO|1:DETAIL A|1:DETAIL B|2:DEEPER'
    }

    It 'adds speaker notes on the template notes page, line by line' {
        $slides[1].notes | Should Match 'SAY THIS FIRST'
        $slides[1].notes | Should Match 'THEN THIS'
        $slides[0].notes | Should Be ''
    }

    It 'builds a table with every row and cell, escaped, in the template table style' {
        $x = $slides[2].xml
        $tbl = $x.SelectSingleNode("//*[local-name()='tbl']")
        $tbl | Should Not BeNullOrEmpty
        @($tbl.SelectNodes("*[local-name()='tr']")).Count | Should Be 3
        @($tbl.SelectNodes("*[local-name()='tblGrid']/*[local-name()='gridCol']")).Count | Should Be 2
        $cells = @($tbl.SelectNodes(".//*[local-name()='tc']") | ForEach-Object { $_.InnerText })
        $cells -join '|' | Should Be 'ITEM|VALUE|APPLES|12|PEARS|7 & 8 <ok>'
        $tbl.SelectSingleNode(".//*[local-name()='tableStyleId']").InnerText | Should Be '{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}'
        $tbl.SelectSingleNode("*[local-name()='tblPr']").GetAttribute('firstRow') | Should Be '1'
    }

    It 'puts the two columns left and right in the layout placeholders' {
        $x = $slides[3].xml
        ($x.SelectSingleNode("//*[local-name()='sp'][.//*[local-name()='ph' and @idx='1']]")).InnerText | Should Be 'LEFT ONE'
        ($x.SelectSingleNode("//*[local-name()='sp'][.//*[local-name()='ph' and @idx='2']]")).InnerText | Should Be 'RIGHT ONE'
    }

    It 'adds the project picture in a box under the title when the layout has no place for it' {
        $x = $slides[4].xml
        $pic = $x.SelectSingleNode("//*[local-name()='pic']")
        $pic | Should Not BeNullOrEmpty
        $pic.SelectSingleNode(".//*[local-name()='cNvPr']").GetAttribute('descr') | Should Be 'chart.png'
        ($result.warnings -join ' ') | Should Match 'slide 5: the layout "Title Only" has no place for the picture'
    }

    It 'says when a layout name is not in the template' {
        ($result.warnings -join ' ') | Should Match 'slide 6: no layout of the template matches "Not In Template"'
    }

    It 'refuses an outline that is not right and writes nothing' {
        $bad = Join-Path $proj 'Work\bad.deck.json'
        [IO.File]::WriteAllText($bad, '{"slides": [{"title": "no layout"}]}')
        $badOut = Join-Path $proj 'Runbooks\Exports\bad.pptx'
        { New-PptxFromOutline -TemplatePath $tpl -OutlinePath $bad -OutPath $badOut -ProjectRoot $proj } | Should Throw 'The outline cannot be built'
        Test-Path -LiteralPath $badOut | Should Be $false
    }

    It 'flags text that does not fit and leaves notes out without a notes page' {
        $plain = Join-Path $script:Tmp 'plain.pptx'
        $null = New-TestDeck -Path $plain
        $many = (@(1..40) | ForEach-Object { '"A RATHER LONG POINT THAT TAKES A WHOLE LINE OF ROOM ' + $_ + '"' }) -join ','
        $o = Join-Path $proj 'Work\long.deck.json'
        [IO.File]::WriteAllText($o, '{"slides": [{"layout": "content", "title": "LONG", "bullets": [' + $many + '], "notes": "N"}]}')
        $lo = Join-Path $proj 'Runbooks\Exports\long.pptx'
        $r = New-PptxFromOutline -TemplatePath $plain -OutlinePath $o -OutPath $lo -ProjectRoot $proj
        $r.slides | Should Be 1
        ($r.warnings -join ' ') | Should Match 'slide 1: the text does not fit its place even at 60%'
        ($r.warnings -join ' ') | Should Match 'no notes page'
        $x = @(Get-OutSlides $lo)[0].xml
        $x.SelectSingleNode("//*[local-name()='normAutofit']").GetAttribute('fontScale') | Should Be '60000'
        @(Get-PackageProblems $lo) -join '; ' | Should Be ''
    }

    It 'builds a one-slide outline on the Dutch corporate template' {
        $corp = Join-Path $script:Tmp 'corp.pptx'
        $null = New-TestDeck -Path $corp -Layouts (Get-CorporateLayouts) -Size @(12192000, 6858000) -NotesMaster
        $o = Join-Path $proj 'Work\one.deck.json'
        [IO.File]::WriteAllText($o, '{"slides": [{"layout": "two_content", "title": "TWEE", "left": ["L"], "right": ["R"]}]}')
        $co = Join-Path $proj 'Runbooks\Exports\one.pptx'
        $r = New-PptxFromOutline -TemplatePath $corp -OutlinePath $o -OutPath $co -ProjectRoot $proj
        $r.slides | Should Be 1
        $s = @(Get-OutSlides $co)
        $s[0].layout | Should Be 'Twee kolommen'
        ($s[0].xml.SelectSingleNode("//*[local-name()='sp'][.//*[local-name()='ph' and @idx='14']]")).InnerText | Should Be 'L'
        ($s[0].xml.SelectSingleNode("//*[local-name()='sp'][.//*[local-name()='ph' and @idx='15']]")).InnerText | Should Be 'R'
        @(Get-PackageProblems $co) -join '; ' | Should Be ''
    }
}

# ------------------------------------------------------------------------------- Copilot's own workspace

Describe 'Files in Copilot''s own workspace' {
    It 'finds the files a reply names, once each, as file names' {
        $t = 'Here it is: [deck](sandbox:/mnt/data/Quarterly%20Review.pptx). Also sandbox://mnt/data/report.xlsx, and again sandbox:/mnt/data/report.xlsx; see sandbox:/mnt/data/sub/notes.csv'
        (@(Get-SandboxFiles $t)) -join '|' | Should Be 'Quarterly Review.pptx|report.xlsx|notes.csv'
    }

    It 'finds nothing in a reply without such files' {
        @(Get-SandboxFiles 'No files here, only https://contoso.sharepoint.com/a.pptx').Count | Should Be 0
        @(Get-SandboxFiles '').Count | Should Be 0
        @(Get-SandboxFiles 'sandbox:/mnt/data/noextension').Count | Should Be 0
    }

    It 'accepts plain file names with a type and refuses the rest' {
        Test-SandboxFileName 'deck.pptx' | Should Be $true
        Test-SandboxFileName 'Quarterly Review (v2).pptx' | Should Be $true
        Test-SandboxFileName 'a_b-c+d.xlsx' | Should Be $true
        Test-SandboxFileName 'noextension' | Should Be $false
        Test-SandboxFileName '.hidden.txt' | Should Be $false
        Test-SandboxFileName 'sub/file.txt' | Should Be $false
        Test-SandboxFileName '..\file.txt' | Should Be $false
        Test-SandboxFileName 'a"b.txt' | Should Be $false
        Test-SandboxFileName "a`tb.txt" | Should Be $false
        Test-SandboxFileName 'x.toolongext' | Should Be $false
        Test-SandboxFileName (('a' * 116) + '.pptx') | Should Be $false
        Test-SandboxFileName (('a' * 115) + '.pptx') | Should Be $true
    }

    It 'asks Copilot to save the file unchanged to OneDrive and reply with a link, never naming the helper program' {
        $r = Get-SandboxSaveRequest 'deck.pptx'
        $r | Should Match 'deck\.pptx'
        $r | Should Match 'sandbox:/mnt/data/deck\.pptx'
        $r | Should Match 'unchanged'
        $r | Should Match 'OneDrive'
        $r | Should Match 'link'
        $r | Should Not Match '(?i)ccbridge'
        $r | Should Not Match '(?i)streamhub'
    }

    It 'takes the OneDrive and SharePoint links from a reply, once each, without trailing punctuation' {
        $t = 'Saved: [Review.pptx](https://contoso.sharepoint.com/:p:/r/sites/team/Doc.pptx?d=1&web=1). Copy: https://contoso-my.sharepoint.com/personal/a_b/Documents/Review.pptx, short https://1drv.ms/p/s!AbC. Again https://contoso.sharepoint.com/:p:/r/sites/team/Doc.pptx?d=1&web=1 and not http://plain.example/x'
        $links = @(Get-ReplyLinks $t)
        $links.Count | Should Be 3
        $links[0] | Should Be 'https://contoso.sharepoint.com/:p:/r/sites/team/Doc.pptx?d=1&web=1'
        $links[1] | Should Be 'https://contoso-my.sharepoint.com/personal/a_b/Documents/Review.pptx'
        $links[2] | Should Be 'https://1drv.ms/p/s!AbC'
        @(Get-ReplyLinks '').Count | Should Be 0
    }
}

Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
