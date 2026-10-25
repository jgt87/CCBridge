# Apply a PowerPoint template to a content deck (lib/PptxRetheme.psm1, lib/PptxLayoutMatch.psm1). The
# decks are built here from XML strings with System.IO.Packaging; no PowerPoint is needed. The cases
# follow Retheme's test_retheme.py and add slide sizes, start and end slides, notes, layouts without a
# type and Copilot's mapping.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\lib\PptxLayoutMatch.psm1') -Force
Import-Module (Join-Path $here '..\lib\PptxRetheme.psm1') -Force
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('pptx-retheme-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $script:Tmp

. (Join-Path $here 'PptxTestDecks.ps1')

# ------------------------------------------------------------------------------- fixtures

$script:TplPath = Join-Path $script:Tmp 'brand.pptx'
$tplSlides = @(
    @{ layout = 1; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="ctrTitle"/>' -Text 'TEMPLATE START'); notes = 'start note'; pics = @{ rId5 = (New-TestPng 200) }; },
    @{ layout = 2; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'TEMPLATE MIDDLE') + (New-PicXml 5 'rId5' @(100, 100, 200, 200)); pics = @{ rId5 = (New-TestPng 201) }; notes = 'middle note' },
    @{ layout = 6; shapes = (New-SpXml -Id 2 -Text 'TEMPLATE END' -Rect @(1000000, 1000000, 4000000, 600000) -TextBox) }
)
$null = New-TestDeck -Path $script:TplPath -Size @(12192000, 6858000) -Layouts (Get-CorporateLayouts) -Slides $tplSlides -Accent1 '10069F' -Major 'Verdana' -Minor 'Verdana' -NotesMaster -Sections

$script:PicBytes = New-TestPng 7
$script:ContentPath = Join-Path $script:Tmp 'content.pptx'
$cSlides = @(
    @{ layout = 1; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="ctrTitle"/>' -Text 'Quarterly results') + (New-SpXml -Id 3 -Ph '<p:ph type="subTitle" idx="1"/>' -Text 'Content deck') },
    @{ layout = 2; notes = 'REMEMBER-THIS-NOTE'; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'Highlights' -RunAttr 'sz="1300"') + (New-SpXml -Id 3 -Ph '<p:ph idx="1"/>' -Rect @(1, 2, 3, 4) -Text 'Revenue up' -RunXml '<a:solidFill><a:srgbClr val="FF0000"/></a:solidFill><a:latin typeface="Comic Sans MS"/>') + (New-SpXml -Id 4 -Text 'hardcoded style' -Rect @(914400, 4800000, 3657600, 500000) -RunXml '<a:solidFill><a:srgbClr val="4F81BD"/></a:solidFill><a:latin typeface="Calibri"/>' -TextBox) + (New-SpXml -Id 5 -Ph '<p:ph type="ftr" idx="11"/>' -Text 'old footer') },
    @{ layout = 5; charts = @('rId3'); pics = @{ rId2 = $script:PicBytes }; ext = @{ rId4 = 'https://example.com/report' }
        shapes = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'Rich content') + (New-PicXml 3 'rId2' @(457200, 1828800, 1828800, 1371600)) + (New-TableXml 4 @(2743200, 1828800, 2743200, 914400)) + (New-ChartFrameXml 5 'rId3' @(5943600, 1828800, 2743200, 2286000)) + (New-SpXml -Id 6 -Text 'Link' -Rect @(457200, 5000000, 1828800, 400000) -TextBox -Inner '<a:p><a:r><a:rPr lang="en-US"><a:hlinkClick r:id="rId4"/></a:rPr><a:t>Link</a:t></a:r></a:p>') },
    @{ layout = 3; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'Next steps') + (New-SpXml -Id 3 -Ph '<p:ph type="body" idx="1"/>') },
    @{ layout = 6; links = @{ rId7 = 2 }; shapes = (New-SpXml -Id 2 -Text 'Free Heading' -Rect @(2743200, 914400, 3657600, 914400) -RunAttr 'sz="3200"' -TextBox) + (New-SpXml -Id 3 -Text '42%' -Rect @(4572000, 3657600, 1828800, 1828800) -RunAttr 'sz="3000"' -RunXml '<a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill>' -Fill '1E2761') + (New-SpXml -Id 4 -Text 'Back to highlights' -Rect @(457200, 6000000, 2000000, 400000) -TextBox -Inner '<a:p><a:r><a:rPr lang="en-US"><a:hlinkClick r:id="rId7" action="ppaction://hlinksldjump"/></a:rPr><a:t>Back to highlights</a:t></a:r></a:p>') }
)
$null = New-TestDeck -Path $script:ContentPath -Slides $cSlides -NotesMaster

Describe 'Purposes and layout matching (fixed rules)' {
    It 'reads purposes from the type first, then from the name, English and Dutch' {
        Get-LayoutPurpose 'secHead' 'Whatever' | Should Be 'Section Header'
        Get-LayoutPurpose '' 'Title Only' | Should Be 'Title Only'
        Get-LayoutPurpose 'cust' 'Title and Content' | Should Be 'Title and Content'
        Get-LayoutPurpose '' 'Alleen titel' | Should Be 'Title Only'
        Get-LayoutPurpose '' 'Hoofdstuk' | Should Be 'Section Header'
        Get-LayoutPurpose '' 'Titel en inhoud' | Should Be 'Title and Content'
        Get-LayoutPurpose '' 'Agenda' | Should Be 'Agenda / Table of Contents'
        Get-LayoutPurpose '' 'Cover' | Should Be 'Title Slide'
        Get-LayoutPurpose '' 'Leeg' | Should Be 'Blank'
        Get-LayoutPurpose '' 'Twee kolommen' | Should Be 'Two Content'
        Get-LayoutPurpose '' 'Brand 7' | Should Be 'General Content'
    }

    It 'proposes corporate layouts without a type by purpose and placeholders' {
        $plan = Get-PptxRethemePlan $script:TplPath $script:ContentPath
        $by = @{}; foreach ($s in $plan.slides) { $by[$s.index] = $s }
        $by[1].layout | Should Be 'Cover'
        $by[2].layout | Should Be 'Titel en inhoud'
        $by[3].layout | Should Be 'Alleen titel'
        $by[4].layout | Should Be 'Hoofdstuk'
        $by[5].layout | Should Be 'Alleen titel'
        $by[5].heading | Should Be 2
        $by[1].sure | Should Be $true
    }

    It 'says "check" when two layouts fit as well' {
        $layouts = @(@{ name = 'A'; type = 'cust'; purpose = 'General Content'; slots = @(@{ kind = 'title' }, @{ kind = 'content' }) }, @{ name = 'B'; type = 'cust'; purpose = 'General Content'; slots = @(@{ kind = 'title' }, @{ kind = 'content' }) })
        $slide = @{ layoutName = 'X'; layoutType = 'cust'; purpose = 'General Content'; kinds = @('title', 'content'); heading = 0; headings = 0 }
        $r = Select-PptxLayout $slide $layouts
        $r.layout | Should Be 'A'
        $r.sure | Should Be $false
    }

    It 'prefers the same name, then the same type, and passes over a match that cannot hold the slide' {
        $layouts = @(
            @{ name = 'Title and Content'; type = 'obj'; purpose = 'Title and Content'; slots = @(@{ kind = 'title' }, @{ kind = 'content' }) },
            @{ name = 'Two Content'; type = 'twoObj'; purpose = 'Two Content'; slots = @(@{ kind = 'title' }, @{ kind = 'content' }, @{ kind = 'content' }) },
            @{ name = 'Title Only'; type = 'titleOnly'; purpose = 'Title Only'; slots = @(@{ kind = 'title' }) })
        (Select-PptxLayout @{ layoutName = 'Title Only'; layoutType = 'titleOnly'; purpose = 'Title Only'; kinds = @('title'); heading = 0; headings = 0 } $layouts).why | Should Be 'same layout name'
        (Select-PptxLayout @{ layoutName = 'Other'; layoutType = 'twoObj'; purpose = 'Two Content'; kinds = @('title', 'content', 'content'); heading = 0; headings = 0 } $layouts).layout | Should Be 'Two Content'
        $r = Select-PptxLayout @{ layoutName = 'Title Only'; layoutType = 'titleOnly'; purpose = 'Title Only'; kinds = @('title', 'content', 'content'); heading = 0; headings = 0 } $layouts
        $r.layout | Should Be 'Two Content'
        $r.sure | Should Be $false
    }

    It 'treats a blank slide with a heading box as title only, and several heading boxes as "check"' {
        $layouts = @(@{ name = 'Only title'; type = ''; purpose = 'Title Only'; slots = @(@{ kind = 'title' }) }, @{ name = 'Empty'; type = ''; purpose = 'Blank'; slots = @() })
        $one = Select-PptxLayout @{ layoutName = 'Blank'; layoutType = 'blank'; purpose = 'Title Only'; kinds = @(); heading = 4; headings = 1 } $layouts
        $one.layout | Should Be 'Only title'; $one.sure | Should Be $true
        (Select-PptxLayout @{ layoutName = 'Blank'; layoutType = 'blank'; purpose = 'Title Only'; kinds = @(); heading = 4; headings = 2 } $layouts).sure | Should Be $false
        (Select-PptxLayout @{ layoutName = 'Blank'; layoutType = 'blank'; purpose = 'Blank'; kinds = @(); heading = 0; headings = 0 } $layouts).layout | Should Be 'Empty'
    }

    It 'reads a slide of free text boxes by its shapes, whatever its layout says, and sees through a clear fill' {
        $deck = Join-Path $script:Tmp 'generated.pptx'
        $clear = (New-SpXml -Id 3 -Text 'Executive Snapshot' -Rect @(457200, 457200, 6000000, 600000) -RunAttr 'sz="2250"').Replace('<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>', '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="000000"><a:alpha val="0"/></a:srgbClr></a:solidFill>')
        $null = New-TestDeck -Path $deck -Slides @(@{ layout = 1; shapes = $clear })
        $s = @((Read-PptxDeck $deck).slides)[0]
        $s.purpose | Should Be 'Title Only'
        $s.heading | Should Be 3
        $pick = Select-PptxLayout $s (Get-OfficeLayouts | ForEach-Object { @{ name = $_.name; type = $_.type; purpose = (Get-LayoutPurpose $_.type $_.name); slots = @($_.ph | ForEach-Object { @{ kind = (Get-PptxPhKind $_.type) } }) } })
        $pick.layout | Should Be 'Title Only'
    }

    It 'never takes text on a coloured shape or in a group as the heading' {
        $deck = Read-PptxDeck $script:ContentPath
        @($deck.slides)[4].heading | Should Be 2
        @($deck.slides)[4].headings | Should Be 1
    }
}

Describe 'Applying a template: the whole slide comes along' {
    $out = Join-Path $script:Tmp 'branded.pptx'
    $tplHash = Get-FileHashText $script:TplPath; $conHash = Get-FileHashText $script:ContentPath
    $r = Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $script:ContentPath -OutPath $out
    $slides = @(Get-OutSlides $out)

    It 'writes a sound package: no missing targets, dangling ids, orphans or repeated slide ids' {
        @(Get-PackageProblems $out) | Should BeNullOrEmpty
    }

    It 'keeps the template''s first and last slide around the content slides, in order' {
        $slides.Count | Should Be 7
        $slides[0].xml.DocumentElement.InnerText | Should Match 'TEMPLATE START'
        $slides[6].xml.DocumentElement.InnerText | Should Match 'TEMPLATE END'
        $slides[1].xml.DocumentElement.InnerText | Should Match 'Quarterly results'
        $slides[2].xml.DocumentElement.InnerText | Should Match 'Highlights'
        ($slides | Where-Object { $_.xml.DocumentElement.InnerText -match 'TEMPLATE MIDDLE' }) | Should BeNullOrEmpty
        $r.slides | Should Be 5
    }

    It 'leaves out the removed template slide''s picture and notes' {
        $pkg = Open-PptxPackage $out
        try { $names = @($pkg.GetParts() | ForEach-Object { "$($_.Uri)" }) } finally { $pkg.Close() }
        $media = @($names | Where-Object { $_ -match '/media/' })
        $media.Count | Should Be 2   # the start slide's picture and the content picture
        @($names | Where-Object { $_ -match '/notesSlides/notesSlide\d+\.xml$' }).Count | Should Be 2
    }

    It 'puts every content slide on a template layout' {
        $slides[1].layout | Should Be 'Cover'
        $slides[2].layout | Should Be 'Titel en inhoud'
        $slides[3].layout | Should Be 'Alleen titel'
    }

    It 'keeps the picture byte for byte, the table, the chart with its workbook and the outside link' {
        $pkg = Open-PptxPackage $out
        try {
            $part = $pkg.GetPart((New-Object Uri($slides[3].uri, [UriKind]::Relative)))
            $pic = Get-PptxRelatedPart $pkg $part 'image'
            $s = $pic.GetStream(); $ms = New-Object IO.MemoryStream; $s.CopyTo($ms); $s.Dispose()
            [Convert]::ToBase64String($ms.ToArray()) | Should Be ([Convert]::ToBase64String($script:PicBytes))
            $chart = Get-PptxRelatedPart $pkg $part 'chart'
            $chart | Should Not BeNullOrEmpty
            (Get-PptxRelatedPart $pkg $chart 'package') | Should Not BeNullOrEmpty
            $ext = @($part.GetRelationships() | Where-Object { $_.TargetMode -eq 'External' })
            "$($ext[0].TargetUri)" | Should Be 'https://example.com/report'
        } finally { $pkg.Close() }
        $slides[3].xml.DocumentElement.InnerText | Should Match 'EMEA'
        $slides[3].xml.SelectSingleNode("//*[local-name()='hlinkClick']") | Should Not BeNullOrEmpty
    }

    It 'gives placeholders the layout''s place and idx' {
        $x = $slides[2].xml
        $body = Get-ShapeById $x 3
        $body.SelectSingleNode(".//*[local-name()='ph']").GetAttribute('idx') | Should Be '13'
        $body.SelectSingleNode("*[local-name()='spPr']/*[local-name()='xfrm']") | Should BeNullOrEmpty
        $sub = Get-ShapeById $slides[1].xml 3
        $sub.SelectSingleNode(".//*[local-name()='ph']").GetAttribute('idx') | Should Be '10'
    }

    It 'drops a footer the layout has no place for' {
        $slides[2].xml.DocumentElement.InnerText | Should Not Match 'old footer'
    }

    It 'maps direct formatting equal to the content theme to the template''s, and keeps other formatting' {
        $x = $slides[2].xml
        $box = Get-ShapeById $x 4
        $box.SelectSingleNode(".//*[local-name()='srgbClr']").GetAttribute('val') | Should Be '10069F'
        $box.SelectSingleNode(".//*[local-name()='latin']").GetAttribute('typeface') | Should Be 'Verdana'
        $box.SelectSingleNode(".//*[local-name()='off']").GetAttribute('x') | Should Be ([string][long](914400 + (12192000 - 9144000) / 2))
        $body = Get-ShapeById $x 3
        $body.SelectSingleNode(".//*[local-name()='srgbClr']").GetAttribute('val') | Should Be 'FF0000'
        $body.SelectSingleNode(".//*[local-name()='latin']").GetAttribute('typeface') | Should Be 'Comic Sans MS'
    }

    It 'lets titles take the template''s size' {
        $t = Get-ShapeById $slides[2].xml 2
        $t.SelectSingleNode(".//*[local-name()='rPr']").HasAttribute('sz') | Should Be $false
    }

    It 'turns the heading text box into the layout''s title and leaves text on a coloured shape alone' {
        $x = $slides[5].xml
        $h = Get-ShapeById $x 2
        $h.SelectSingleNode(".//*[local-name()='ph']").GetAttribute('type') | Should Be 'title'
        $h.SelectSingleNode("*[local-name()='spPr']/*[local-name()='xfrm']") | Should BeNullOrEmpty
        $h.SelectSingleNode(".//*[local-name()='rPr']").HasAttribute('sz') | Should Be $false
        $k = Get-ShapeById $x 3
        $k.SelectSingleNode(".//*[local-name()='ph']") | Should BeNullOrEmpty
        $k.SelectSingleNode(".//*[local-name()='rPr']/*[local-name()='solidFill']/*").GetAttribute('val') | Should Be 'FFFFFF'
    }

    It 'points a link to another slide at the copy of that slide' {
        $pkg = Open-PptxPackage $out
        try {
            $part = $pkg.GetPart((New-Object Uri($slides[5].uri, [UriKind]::Relative)))
            $rel = @($part.GetRelationships() | Where-Object { (Get-PptxRelKind $_) -eq 'slide' })[0]
            "$(Get-PptxRelTarget $part $rel)" | Should Be $slides[2].uri
        } finally { $pkg.Close() }
    }

    It 'carries speaker notes onto the template''s notes master' {
        $slides[2].notes | Should Match 'REMEMBER-THIS-NOTE'
        $r.notes | Should Be 1
    }

    It 'never changes the template or the content deck' {
        Get-FileHashText $script:TplPath | Should Be $tplHash
        Get-FileHashText $script:ContentPath | Should Be $conHash
    }

    It 'drops the template''s sections, which name its removed slides' {
        (Read-OutXml $out '/ppt/presentation.xml').OuterXml | Should Not Match 'sectionLst'
    }
}

Describe 'Applying a template: choices' {
    It 'uses the given layouts and title boxes, and no start or end slide when asked' {
        $out = Join-Path $script:Tmp 'chosen.pptx'
        $null = Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $script:ContentPath -OutPath $out -Choices @{ layouts = @{ '5' = 'Leeg' }; titles = @{ '5' = 0 }; start = 0; end = 0 }
        $slides = @(Get-OutSlides $out)
        $slides.Count | Should Be 5
        $slides[4].layout | Should Be 'Leeg'
        (Get-ShapeById $slides[4].xml 2).SelectSingleNode(".//*[local-name()='ph']") | Should BeNullOrEmpty
        @(Get-PackageProblems $out) | Should BeNullOrEmpty
    }

    It 'refuses a layout the template does not have' {
        { Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $script:ContentPath -OutPath (Join-Path $script:Tmp 'x.pptx') -Choices @{ layouts = @{ '1' = 'Nope' } } } | Should Throw 'no layout named'
    }

    It 'strips fonts and colours in placeholders with the template''s text styles, not in text boxes' {
        $out = Join-Path $script:Tmp 'styles.pptx'
        $null = Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $script:ContentPath -OutPath $out -Choices @{ templateStyles = $true }
        $x = (@(Get-OutSlides $out))[2].xml
        (Get-ShapeById $x 3).SelectSingleNode(".//*[local-name()='latin']") | Should BeNullOrEmpty
        (Get-ShapeById $x 3).SelectSingleNode(".//*[local-name()='solidFill']") | Should BeNullOrEmpty
        (Get-ShapeById $x 4).SelectSingleNode(".//*[local-name()='latin']") | Should Not BeNullOrEmpty
    }

    It 'reads the card''s choices from JSON and applies them as one object' {
        $json = '{"layouts":{"1":"Cover","5":"Leeg"},"titles":{"5":0,"x":3},"start":0,"end":3,"templateStyles":true,"keepBackgrounds":false,"later":"kept"}' | ConvertFrom-Json
        $c = ConvertTo-PptxChoices $json
        $c.layouts['5'] | Should Be 'Leeg'
        $c.titles.ContainsKey('x') | Should Be $false
        $c.titles['5'] | Should Be 0
        $c.start | Should Be 0
        $c.templateStyles | Should Be $true
        $c.later | Should Be 'kept'
        $out = Join-Path $script:Tmp 'json-choices.pptx'
        $r = Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $script:ContentPath -OutPath $out -Choices $c
        $s = @(Get-OutSlides $out)
        $s.Count | Should Be 6
        $s[4].layout | Should Be 'Leeg'
        $s[5].xml.DocumentElement.InnerText | Should Match 'TEMPLATE END'
        $r.start | Should Be 0
    }

    It 'resolves start and end: -1 first and last, 0 none, never one slide twice' {
        $e = Resolve-PptxEnds -1 -1 3; $e.start | Should Be 1; $e.end | Should Be 3
        $e = Resolve-PptxEnds -1 -1 1; $e.start | Should Be 1; $e.end | Should Be 0
        $e = Resolve-PptxEnds 2 2 3; $e.end | Should Be 0
        { Resolve-PptxEnds 4 0 3 } | Should Throw
    }
}

Describe 'Slide sizes' {
    It 'scales free shapes uniformly and centres them, with table grid and text sizes' {
        $wide = Join-Path $script:Tmp 'wide.pptx'
        $null = New-TestDeck -Path $wide -Size @(12192000, 6858000) -Slides @(@{ layout = 6; shapes = (New-SpXml -Id 2 -Text 'scale me' -Rect @(3657600, 1828800, 2743200, 914400) -RunAttr 'sz="1800"' -TextBox) + (New-TableXml 3 @(1000000, 3000000, 4000000, 800000)) })
        $narrow = Join-Path $script:Tmp 'narrow-tpl.pptx'
        $null = New-TestDeck -Path $narrow -Size @(9144000, 6858000) -Slides @(@{ layout = 1; shapes = '' })
        $out = Join-Path $script:Tmp 'fit.pptx'
        $r = Invoke-PptxRetheme -TemplatePath $narrow -ContentPath $wide -OutPath $out -Choices @{ start = 0; end = 0 }
        $x = (@(Get-OutSlides $out))[0].xml
        $f = 0.75; $oy = [long][Math]::Round((6858000 - 6858000 * $f) / 2)
        $off = (Get-ShapeById $x 2).SelectSingleNode(".//*[local-name()='off']")
        [long]$off.GetAttribute('x') | Should Be ([long][Math]::Round(3657600 * $f))
        [long]$off.GetAttribute('y') | Should Be ([long][Math]::Round(1828800 * $f + $oy))
        (Get-ShapeById $x 2).SelectSingleNode(".//*[local-name()='ext']").GetAttribute('cx') | Should Be ([string][long][Math]::Round(2743200 * $f))
        (Get-ShapeById $x 2).SelectSingleNode(".//*[local-name()='rPr']").GetAttribute('sz') | Should Be '1350'
        $x.SelectSingleNode("//*[local-name()='gridCol']").GetAttribute('w') | Should Be '1500000'
        @($r.warnings | Where-Object { $_ -match 'scaled by 0.75' }).Count | Should Be 1
    }

    It 'computes the scale for 4:3 onto 16:9 as a centring only' {
        $s = Get-PptxScale @{ cx = 9144000; cy = 6858000 } @{ cx = 12192000; cy = 6858000 }
        $s.f | Should Be 1
        $s.ox | Should Be 1524000
        $s.oy | Should Be 0
    }
}

Describe 'Notes, table styles and odd parts' {
    It 'brings the content deck''s notes master when the template has none' {
        $tpl = Join-Path $script:Tmp 'no-notes-tpl.pptx'
        $null = New-TestDeck -Path $tpl -Slides @(@{ layout = 1; shapes = '' })
        $out = Join-Path $script:Tmp 'notes.pptx'
        $r = Invoke-PptxRetheme -TemplatePath $tpl -ContentPath $script:ContentPath -OutPath $out
        (@(Get-OutSlides $out))[2].notes | Should Match 'REMEMBER-THIS-NOTE'
        (Read-OutXml $out '/ppt/presentation.xml').OuterXml | Should Match 'notesMasterIdLst'
        @($r.warnings | Where-Object { $_ -match 'notes page' }).Count | Should Be 1
        @(Get-PackageProblems $out) | Should BeNullOrEmpty
    }

    It 'merges a custom table style and restyles it' {
        $custom = '{11111111-2222-3333-4444-555555555555}'
        $styles = "<a:tblStyleLst xmlns:a=""http://schemas.openxmlformats.org/drawingml/2006/main"" def=""{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}""><a:tblStyle styleId=""$custom"" styleName=""Deck Custom""><a:wholeTbl><a:tcStyle><a:fill><a:solidFill><a:srgbClr val=""4F81BD""/></a:solidFill></a:fill></a:tcStyle></a:wholeTbl></a:tblStyle></a:tblStyleLst>"
        $deck = Join-Path $script:Tmp 'tabled.pptx'
        $null = New-TestDeck -Path $deck -TableStyles $styles -Slides @(@{ layout = 6; shapes = (New-TableXml 2 @(914400, 914400, 3657600, 1371600) $custom) })
        $out = Join-Path $script:Tmp 'tabled-out.pptx'
        $r = Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $deck -OutPath $out
        $ts = (Read-OutXml $out '/ppt/tableStyles.xml').OuterXml
        $ts | Should Match ([regex]::Escape($custom))
        $ts | Should Match '10069F'
        $ts | Should Not Match '4F81BD'
        @($r.warnings | Where-Object { $_ -match 'table style' }).Count | Should Be 1
    }

    It 'stores one picture used on several slides once, and distinct pictures under unique names' {
        $deck = Join-Path $script:Tmp 'many.pptx'
        $same = New-TestPng 50
        $sl = @(for ($i = 1; $i -le 6; $i++) { @{ layout = 6; pics = @{ rId2 = (New-TestPng $i); rId3 = $same }; shapes = (New-PicXml 2 'rId2' @(914400, 914400, 914400, 914400)) + (New-PicXml 3 'rId3' @(2914400, 914400, 914400, 914400)) } })
        $null = New-TestDeck -Path $deck -Slides $sl
        $out = Join-Path $script:Tmp 'many-out.pptx'
        $null = Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $deck -OutPath $out -Choices @{ start = 0; end = 0 }
        $pkg = Open-PptxPackage $out
        try { $media = @($pkg.GetParts() | Where-Object { "$($_.Uri)" -match '/media/' }) } finally { $pkg.Close() }
        $media.Count | Should Be 7
        @(Get-PackageProblems $out) | Should BeNullOrEmpty
    }

    It 'keeps a placeholder the layout has no place for as a text box where it was, and drops empty ones' {
        $deck = Join-Path $script:Tmp 'two.pptx'
        $null = New-TestDeck -Path $deck -Slides @(@{ layout = 4; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'Two sides') + (New-SpXml -Id 3 -Ph '<p:ph idx="1"/>' -Text 'Left') + (New-SpXml -Id 4 -Ph '<p:ph idx="2"/>' -Text 'Right') + (New-SpXml -Id 5 -Ph '<p:ph type="body" idx="7"/>') })
        $out = Join-Path $script:Tmp 'two-out.pptx'
        $r = Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $deck -OutPath $out -Choices @{ layouts = @{ '1' = 'Titel en inhoud' }; start = 0; end = 0 }
        $x = (@(Get-OutSlides $out))[0].xml
        (Get-ShapeById $x 3).SelectSingleNode(".//*[local-name()='ph']").GetAttribute('idx') | Should Be '13'
        $right = Get-ShapeById $x 4
        $right.SelectSingleNode(".//*[local-name()='ph']") | Should BeNullOrEmpty
        $right.SelectSingleNode(".//*[local-name()='off']").GetAttribute('x') | Should Be ([string](4648200 + 1524000))
        $x.SelectSingleNode("//*[local-name()='cNvPr' and @id='5']") | Should BeNullOrEmpty
        @($r.warnings | Where-Object { $_ -match 'no place' }).Count | Should Be 1
    }

    It 'drops a light full-slide background shape so the template''s shows, keeps a dark one, and keeps all on request' {
        $deck = Join-Path $script:Tmp 'painted.pptx'
        $full = @(0, 0, 9144000, 6858000)
        $null = New-TestDeck -Path $deck -Slides @(
            @{ layout = 6; shapes = (New-SpXml -Id 2 -Rect $full -Fill 'F7F3EA') + (New-SpXml -Id 3 -Text 'Light slide' -Rect @(457200, 457200, 6000000, 800000) -RunAttr 'sz="2800"' -TextBox) },
            @{ layout = 6; shapes = (New-SpXml -Id 2 -Rect $full -Fill '18212B') + (New-SpXml -Id 3 -Text 'Dark slide' -Rect @(457200, 457200, 6000000, 800000) -RunXml '<a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill>' -TextBox) })
        $out = Join-Path $script:Tmp 'painted-out.pptx'
        $r = Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $deck -OutPath $out -Choices @{ start = 0; end = 0 }
        $s = @(Get-OutSlides $out)
        $s[0].xml.SelectSingleNode("//*[local-name()='cNvPr' and @id='2']") | Should BeNullOrEmpty
        $s[1].xml.SelectSingleNode("//*[local-name()='cNvPr' and @id='2']") | Should Not BeNullOrEmpty
        @($r.warnings | Where-Object { $_ -match 'slide 2 keeps its own dark background' }).Count | Should Be 1
        $out2 = Join-Path $script:Tmp 'painted-kept.pptx'
        $null = Invoke-PptxRetheme -TemplatePath $script:TplPath -ContentPath $deck -OutPath $out2 -Choices @{ start = 0; end = 0; keepBackgrounds = $true }
        (@(Get-OutSlides $out2))[0].xml.SelectSingleNode("//*[local-name()='cNvPr' and @id='2']") | Should Not BeNullOrEmpty
    }

    It 'saves a .potx template as a presentation' {
        $potx = Join-Path $script:Tmp 'brand.potx'
        Copy-Item -LiteralPath $script:TplPath -Destination $potx -Force
        $zip = [IO.Compression.ZipFile]::Open($potx, 'Update')
        try {
            $e = $zip.GetEntry('[Content_Types].xml'); $rd = New-Object IO.StreamReader($e.Open()); $t = $rd.ReadToEnd(); $rd.Dispose(); $e.Delete()
            $w = New-Object IO.StreamWriter(($zip.CreateEntry('[Content_Types].xml')).Open()); $w.Write(($t -replace 'presentation\.main\+xml', 'template.main+xml')); $w.Dispose()
        } finally { $zip.Dispose() }
        $out = Join-Path $script:Tmp 'from-potx.pptx'
        $null = Invoke-PptxRetheme -TemplatePath $potx -ContentPath $script:ContentPath -OutPath $out
        $zip = [IO.Compression.ZipFile]::OpenRead($out)
        try { $rd = New-Object IO.StreamReader($zip.GetEntry('[Content_Types].xml').Open()); $ct = $rd.ReadToEnd(); $rd.Dispose() } finally { $zip.Dispose() }
        $ct | Should Match 'presentation\.main\+xml'
        $ct | Should Not Match 'template\.main'
    }
}

Describe 'Theme maps and restyling' {
    It 'maps every content master''s theme to the template''s, the first master winning' {
        $m = Get-PptxThemeMaps @(@{ colors = @{ accent1 = 'AAAAAA'; accent2 = '111111' }; fonts = @{ minor = 'Arial' } }, @{ colors = @{ accent1 = 'BBBBBB'; accent2 = 'CCCCCC' }; fonts = @{ minor = 'Georgia'; major = 'Cambria' } }) @{ colors = @{ accent1 = '10069F'; accent2 = '00A3E0' }; fonts = @{ minor = 'Verdana'; major = 'Verdana' } }
        $m.colors['AAAAAA'] | Should Be '10069F'
        $m.colors['BBBBBB'] | Should Be '10069F'
        $m.colors['CCCCCC'] | Should Be '00A3E0'
        $m.colors['111111'] | Should Be '00A3E0'
        $m.fonts['Arial'] | Should Be 'Verdana'
        $m.fonts['Cambria'] | Should Be 'Verdana'
    }

    It 'restyles only colours and fonts in the maps' {
        $x = New-Object Xml.XmlDocument
        $x.LoadXml('<a:solidFill xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:srgbClr val="4f81bd"/><a:latin typeface="Calibri"/><a:srgbClr val="FF0000"/></a:solidFill>')
        Set-PptxRestyle $x @{ '4F81BD' = '10069F' } @{ Calibri = 'Verdana' } | Should Be 2
        $x.OuterXml | Should Match '10069F'
        $x.OuterXml | Should Match 'FF0000'
        $x.OuterXml | Should Match 'Verdana'
    }

    It 'removes uses of relationship ids a part does not have' {
        $deck = Join-Path $script:Tmp 'refs.pptx'
        $null = New-TestDeck -Path $deck -Slides @(@{ layout = 6; shapes = '' })
        $pkg = [IO.Packaging.Package]::Open($deck, 'Open', 'ReadWrite')
        try {
            $part = $pkg.GetPart((New-Object Uri('/ppt/slides/slide1.xml', [UriKind]::Relative)))
            $x = New-Object Xml.XmlDocument
            $x.LoadXml('<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><a:rPr><a:hlinkClick r:id="rId9"/></a:rPr><a:blip r:embed="rId1"/><a:blip r:embed="rId8"/></p:sld>')
            Remove-PptxBrokenRefs $part $x | Should Be 2
            $x.OuterXml | Should Not Match 'hlinkClick'
            $x.OuterXml | Should Match 'r:embed="rId1"'
            $x.OuterXml | Should Not Match 'rId8'
        } finally { $pkg.Close() }
    }
}

Describe 'Asking Copilot for the mapping' {
    $content = Read-PptxDeck $script:ContentPath
    $template = Read-PptxDeck $script:TplPath

    It 'sends the structure only: layouts with their placeholders, shapes with id, place and 60 characters' {
        $ask = New-PptxMappingAsk $content $template
        $ask | Should Match '"Titel en inhoud": title, content'
        $ask | Should Match 'Slide 5 \(now on layout "Blank"\)'
        $ask | Should Match 'id 2, text box at 30,13 size 40x13: "Free Heading"'
        $ask | Should Match 'id 3, picture'
        $ask | Should Match '"slides"'
        $ask | Should Not Match 'CCBridge'
        $ask | Should Not Match 'StreamHub'
    }

    It 'cuts long text at 60 characters' {
        $deck = Join-Path $script:Tmp 'long.pptx'
        $null = New-TestDeck -Path $deck -Slides @(@{ layout = 6; shapes = (New-SpXml -Id 2 -Text ('x' * 100) -Rect @(0, 0, 100, 100) -TextBox) })
        $ask = New-PptxMappingAsk (Read-PptxDeck $deck) $template
        $ask | Should Match ('"' + ('x' * 60) + '"')
        $ask | Should Not Match ('x' * 61)
    }

    It 'takes a valid answer, with the template''s spelling of the layout' {
        $a = Read-PptxMappingAnswer ("Here:`n" + '```json' + "`n" + '{"slides":[{"slide":1,"layout":"cover","title":null},{"slide":5,"layout":"Alleen titel","title":2}]}' + "`n" + '```') $content $template
        $a.ok | Should Be $true
        $a.map['1'].layout | Should Be 'Cover'
        $a.map['5'].title | Should Be 2
        @($a.errors | Where-Object { $_ -match 'no layout for slide 2' }).Count | Should Be 1
    }

    It 'refuses unknown layouts, slides and shape ids' {
        $a = Read-PptxMappingAnswer '{"slides":[{"slide":1,"layout":"Made Up"},{"slide":9,"layout":"Cover"},{"slide":5,"layout":"Leeg","title":9},{"slide":2,"layout":"Leeg","title":99}]}' $content $template
        $a.map.ContainsKey('1') | Should Be $false
        $a.map['5'].title | Should Be 0
        $a.map['2'].title | Should Be 0
        $text = $a.errors -join ' | '
        $text | Should Match 'no layout named "Made Up"'
        $text | Should Match 'there is no slide 9'
        $text | Should Match 'slide 5: no text box with id 9'
        $text | Should Match 'slide 2: no text box with id 99'
    }

    It 'says so when the answer has no JSON' {
        $a = Read-PptxMappingAnswer 'I would use the cover.' $content $template
        $a.ok | Should Be $false
        $a.errors[0] | Should Match 'no JSON'
    }

    It 'merges the answer into the plan' {
        $plan = Get-PptxRethemePlan $script:TplPath $script:ContentPath
        $a = Read-PptxMappingAnswer '{"slides":[{"slide":2,"layout":"Leeg","title":null},{"slide":5,"layout":"Hoofdstuk","title":2}]}' $content $template
        $p = Merge-PptxMapping $plan $a
        (@($p.slides)[1]).layout | Should Be 'Leeg'
        (@($p.slides)[4]).layout | Should Be 'Hoofdstuk'
        (@($p.slides)[4]).why | Should Be 'Copilot'
        (@($p.slides)[0]).layout | Should Be 'Cover'
        $p.copilot | Should Be $true
    }
}

Describe 'The plan and the project''s decks' {
    It 'offers the template''s first and last slide as start and end, and notes a size difference' {
        $plan = Get-PptxRethemePlan $script:TplPath $script:ContentPath 'brand.pptx' 'content.pptx'
        $plan.start | Should Be 1
        $plan.end | Should Be 3
        @($plan.templateSlides).Count | Should Be 3
        (@($plan.templateSlides)[0]).title | Should Be 'TEMPLATE START'
        @($plan.layouts) -contains 'Hoofdstuk' | Should Be $true
        ($plan.notes -join ' ') | Should Match 'scaled by 1 and centred'
        $plan.template | Should Be 'brand.pptx'
    }

    It 'names the output after the content deck in Runbooks/Exports' {
        Get-PptxBrandedName 'Decks/Q3 review.pptx' ([datetime]'2026-10-25 14:05') | Should Be 'Runbooks/Exports/Q3-review-branded-20261025-1405.pptx'
        $proj = Join-Path $script:Tmp 'named'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'Runbooks\Exports')
        Set-Content -LiteralPath (Join-Path $proj 'Runbooks\Exports\talk-branded-20261025-1405.pptx') -Value 'x'
        Get-PptxBrandedName 'talk.pptx' ([datetime]'2026-10-25 14:05') $proj | Should Be 'Runbooks/Exports/talk-branded-20261025-1405-2.pptx'
    }

    It 'lists the project''s decks and suggests a pair' {
        $proj = Join-Path $script:Tmp 'proj'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'Decks'), (Join-Path $proj 'node_modules'), (Join-Path $proj 'Runbooks\Exports')
        Copy-Item $script:ContentPath (Join-Path $proj 'Decks\talk.pptx')
        Copy-Item $script:TplPath (Join-Path $proj 'House style.potx')
        Copy-Item $script:ContentPath (Join-Path $proj 'node_modules\x.pptx')
        Copy-Item $script:ContentPath (Join-Path $proj 'Runbooks\Exports\talk-branded-20260101-0000.pptx')
        Set-Content -LiteralPath (Join-Path $proj 'Decks\~$talk.pptx') -Value 'lock'
        $d = Get-PptxDecks $proj
        $d.template | Should Be 'House style.potx'
        $d.content | Should Be 'Decks/talk.pptx'
        @($d.templates).Count | Should Be 3
        @($d.contents) -contains 'House style.potx' | Should Be $false
        @($d.templates | Where-Object { $_ -match 'node_modules|~\$' }) | Should BeNullOrEmpty
    }
}

Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
