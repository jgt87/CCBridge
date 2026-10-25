# Choices for deck elements without brand formatting (lib/PptxChoices.psm1): colour helpers, the
# template's look and the UI kit's look, finding unformatted tables, text boxes, shapes, charts and
# headings, ranked options that stay readable, applying the chosen looks in the same write as the
# template, and the one-element question for Copilot. Decks are built with tests/PptxTestDecks.ps1.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\lib\Contrast.psm1') -Force
Import-Module (Join-Path $here '..\lib\PptxLayoutMatch.psm1') -Force
Import-Module (Join-Path $here '..\lib\PptxRetheme.psm1') -Force
Import-Module (Join-Path $here '..\lib\PptxChoices.psm1') -Force
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('pptx-choices-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $script:Tmp

. (Join-Path $here 'PptxTestDecks.ps1')

# ------------------------------------------------------------------------------- fixtures

$script:NsA = 'http://schemas.openxmlformats.org/drawingml/2006/main'
$script:KitStyleId = '{7D3C1A52-4B8E-4F2A-9C61-2E5B0F8D7A13}'
$script:AccentStyle = '{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}'
$script:PlainStyle = '{2D5ABB26-0587-4C30-8999-92F81FD0307C}'

$script:Tokens = @{
    surface = '#ffffff'; 'surface-2' = '#f4f5f7'; border = '#d0d5dd'; text = '#1f2328'; 'text-muted' = '#57606a'
    accent = '#0b5cad'; 'accent-soft' = 'rgb(230, 240, 250)'
    'chart-1' = '#2E7BCF'; 'chart-2' = '#E8743B'; 'chart-3' = '#19A979'; 'chart-4' = '#ED4A7B'; 'chart-5' = '#945ECF'; 'chart-6' = '#13A4B4'
    font = '"Segoe UI", Arial, sans-serif'; radius = '6px'; 'radius-lg' = '12px'
}

function Set-TestPartText([string]$Path, [string]$Uri, [string]$Text) {
    # Rewrites one part of a built deck (a chart whose series colours were typed by hand).
    $pkg = [IO.Packaging.Package]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
    try {
        $p = $pkg.GetPart((New-Object Uri($Uri, [UriKind]::Relative)))
        $b = [Text.Encoding]::UTF8.GetBytes($Text)
        $s = $p.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); try { $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
    } finally { $pkg.Close() }
}

function Get-OutChartColours([string]$Path) {
    # Per chart part of a deck: the srgbClr values its series fills hold.
    $pkg = Open-PptxPackage $Path
    try {
        foreach ($p in @($pkg.GetParts())) {
            if ("$($p.ContentType)" -notmatch 'drawingml\.chart\+xml') { continue }
            $x = Read-PptxPartXml $p
            , @($x.SelectNodes("//*[local-name()='ser']/*[local-name()='spPr']//*[local-name()='srgbClr']") | ForEach-Object { $_.GetAttribute('val').ToUpperInvariant() })
        }
    } finally { $pkg.Close() }
}

function Get-TestOptionReadable($Option, $Look) {
    # Whether the text an offered option draws reads on its background (WCAG AA), as the module decides it.
    $a = $Option.apply
    if ($a.text) { return (Test-PptxReadable "$($a.text.color)" $Look.bg ($a.text.size / 100) ([bool]$a.text.bold)) }
    if ($a.textColor) { return (Test-PptxReadable "$($a.textColor)" "$($a.fill)" 12 ([bool]$a.bold)) }
    if ($a.fillScheme) { return (Test-PptxReadable 'FFFFFF' "$($a.fill)" 12 $false) }
    if ($a.shape) { return (Test-PptxReadable 'FFFFFF' "$($a.shape.fill)" 12 $false) }
    $true
}

# The template: accent 1 dark blue, its own fonts, a filled rounded box on its last slide.
$script:TplPath = Join-Path $script:Tmp 'brand.pptx'
$tplBox = (New-SpXml -Id 3 -Rect @(457200, 457200, 4572000, 914400) -Fill '10069F').Replace('prst="rect"', 'prst="roundRect"')
$null = New-TestDeck -Path $script:TplPath -Slides @(
    @{ layout = 1; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="ctrTitle"/>' -Text 'TEMPLATE START') },
    @{ layout = 6; shapes = $tplBox }
) -Accent1 '10069F' -Major 'Georgia' -Minor 'Verdana'

# The content deck (Office theme: accent 1 4F81BD, light 2 EEECE1).
$white = '<a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill>'
$s1 = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'Overview') +
    (New-SpXml -Id 3 -Text 'SECRET-BODY-TEXT' -Rect @(457200, 1600200, 4000000, 500000) -RunAttr 'sz="1400"' -TextBox) +
    (New-SpXml -Id 4 -Text 'Own font box' -Rect @(457200, 2300000, 4000000, 500000) -RunAttr 'sz="1400"' -RunXml '<a:latin typeface="Comic Sans MS"/>' -TextBox) +
    (New-TableXml 5 @(457200, 3000000, 3657600, 741680) -Style '') +
    (New-TableXml 6 @(4572000, 3000000, 3657600, 741680) -Style $script:AccentStyle)
$s2 = (New-SpXml -Id 2 -Text 'Free Heading' -Rect @(457200, 300000, 6000000, 800000) -RunAttr 'sz="3200"' -TextBox) +
    (New-SpXml -Id 3 -Text 'GO-SHAPE' -Rect @(457200, 1600000, 1828800, 914400) -RunAttr 'sz="1200"' -RunXml $white -Fill '00C000') +
    (New-SpXml -Id 4 -Text 'theme typed' -Rect @(2500000, 1600000, 1828800, 914400) -RunAttr 'sz="1200"' -Fill '4F81BD') +
    (New-SpXml -Id 5 -Text 'scheme fill' -Rect @(4600000, 1600000, 1828800, 914400) -RunAttr 'sz="1200"' -Fill 'ABCDEF').Replace('<a:srgbClr val="ABCDEF"/>', '<a:schemeClr val="accent2"/>') +
    (New-SpXml -Id 6 -Text 'near brand' -Rect @(6700000, 1600000, 1828800, 914400) -RunAttr 'sz="1200"' -Fill '11079F') +
    (New-SpXml -Id 7 -Text 'PALE-SHAPE' -Rect @(457200, 3000000, 1828800, 914400) -RunAttr 'sz="1200"' -RunXml $white -Fill 'FFFF66') +
    (New-TableXml 8 @(2743200, 3000000, 3657600, 741680) -Style $script:PlainStyle)
$s3 = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'Charts') +
    (New-ChartFrameXml 3 'rId3' @(457200, 1600200, 3657600, 2743200)) +
    (New-ChartFrameXml 4 'rId4' @(4572000, 1600200, 3657600, 2743200))
$script:ContentPath = Join-Path $script:Tmp 'content.pptx'
$null = New-TestDeck -Path $script:ContentPath -Slides @(
    @{ layout = 2; shapes = $s1 },
    @{ layout = 6; shapes = $s2 },
    @{ layout = 5; shapes = $s3; charts = @('rId3', 'rId4') }
)
# The first chart's series colour typed by hand (no theme colour); the second keeps the theme's accent 1.
Set-TestPartText $script:ContentPath '/ppt/charts/chart1.xml' ($script:ChartXml.Replace('val="4F81BD"', 'val="AA3377"'))

# ------------------------------------------------------------------------------- tests

Describe 'Colour helpers' {
    It 'turns CSS and DrawingML colours into RRGGBB, and nothing for a clear or unknown one' {
        ConvertTo-PptxHex '#abc' | Should Be 'AABBCC'
        ConvertTo-PptxHex '#1e2761' | Should Be '1E2761'
        ConvertTo-PptxHex '1e2761' | Should Be '1E2761'
        ConvertTo-PptxHex 'rgb(255, 0, 0)' | Should Be 'FF0000'
        ConvertTo-PptxHex 'rgba(0, 0, 0, 0.5)' | Should Be ''
        ConvertTo-PptxHex 'banana' | Should Be ''
        ConvertTo-PptxHex '' | Should Be ''
    }

    It 'measures the RGB distance, and a large one for a value that is not a colour' {
        Get-PptxColourDistance 'FFFFFF' 'FFFFFF' | Should Be 0
        Get-PptxColourDistance '000000' 'FFFFFF' | Should Be 441.7
        Get-PptxColourDistance '10069F' '11079F' | Should Be 1.4
        Get-PptxColourDistance 'FFF' 'FFFFFF' | Should Be 999
    }

    It 'applies lumMod and lumOff as PowerPoint draws tints and shades' {
        Set-PptxLuminance 'FF0000' 1 0 | Should Be 'FF0000'
        Set-PptxLuminance 'FF0000' 0.5 0 | Should Be '800000'
        Set-PptxLuminance 'FFFFFF' 0.5 0 | Should Be '808080'
        Set-PptxLuminance 'FF0000' 1 0.5 | Should Be 'FFFFFF'
        Set-PptxLuminance '000000' 0.2 0.8 | Should Be 'CCCCCC'
    }

    It 'resolves typed, scheme, system and preset colours, through the theme and its colour map' {
        $colors = @{ dk1 = '000000'; lt1 = 'FFFFFF'; dk2 = '1F497D'; lt2 = 'EEECE1'; accent1 = '10069F' }
        $read = {
            param($inner)
            $d = New-Object Xml.XmlDocument
            $d.LoadXml("<a:solidFill xmlns:a=""$script:NsA"">$inner</a:solidFill>")
            Resolve-PptxColour $d.DocumentElement $colors
        }
        & $read '<a:srgbClr val="abcdef"/>' | Should Be 'ABCDEF'
        & $read '<a:schemeClr val="accent1"/>' | Should Be '10069F'
        & $read '<a:schemeClr val="bg1"/>' | Should Be 'FFFFFF'
        & $read '<a:schemeClr val="tx1"/>' | Should Be '000000'
        & $read '<a:schemeClr val="tx2"/>' | Should Be '1F497D'
        & $read '<a:schemeClr val="bg1"><a:lumMod val="50000"/></a:schemeClr>' | Should Be '808080'
        & $read '<a:sysClr val="windowText" lastClr="111111"/>' | Should Be '111111'
        & $read '<a:prstClr val="white"/>' | Should Be 'FFFFFF'
        & $read '<a:schemeClr val="accent6"/>' | Should Be ''
        & $read '<a:noFill/>' | Should Be ''
        Resolve-PptxColour $null $colors | Should Be ''
    }

    It 'judges text by WCAG AA: 4.5:1, or 3:1 for large text' {
        Test-PptxReadable '767676' 'FFFFFF' 12 $false | Should Be $true
        Test-PptxReadable '777777' 'FFFFFF' 12 $false | Should Be $false
        Test-PptxReadable '777777' 'FFFFFF' 18 $false | Should Be $true
        Test-PptxReadable '777777' 'FFFFFF' 14 $true | Should Be $true
        Test-PptxReadable '777777' 'FFFFFF' 14 $false | Should Be $false
        Test-PptxReadable 'FFFFFF' 'FFFF66' 30 $true | Should Be $false
    }
}

Describe 'The template''s look and the UI kit''s look' {
    $look = Read-PptxTemplateLook $script:TplPath -KitTokens $script:Tokens

    It 'reads the theme colours, fonts, slide size and background' {
        $look.colors.accent1 | Should Be '10069F'
        $look.colors.lt1 | Should Be 'FFFFFF'
        $look.fonts.major | Should Be 'Georgia'
        $look.fonts.minor | Should Be 'Verdana'
        $look.bg | Should Be 'FFFFFF'
        $look.size.cx | Should Be 9144000
    }

    It 'reads the text styles with the theme fonts' {
        $look.text.title.font | Should Be 'Georgia'
        $look.text.title.size | Should Be 4400
        $look.text.body1.font | Should Be 'Verdana'
        $look.text.body1.size | Should Be 2800
        $look.text.subtitle.size | Should Be 2400
        $look.text.body2.size | Should BeLessThan 2800
    }

    It 'offers the template''s default accent table style in its own colours' {
        @($look.tables).Count | Should Be 1
        $look.tables[0].id | Should Be $script:AccentStyle
        $look.tables[0].isDefault | Should Be $true
        $look.tables[0].look.headerFill | Should Be '10069F'
        $look.tables[0].look.headerText | Should Be 'FFFFFF'
        # Tinted rows, not white or black (a rounding [Math]::Max once made every tint white).
        $look.tables[0].look.bodyFill | Should Be (Set-PptxLuminance '10069F' 0.2 0.8)
        $look.tables[0].look.bodyFill | Should Not Be 'FFFFFF'
        $look.tables[0].look.band | Should Not Be 'FFFFFF'
        $look.tables[0].look.band | Should Not Be $look.tables[0].look.bodyFill
    }

    It 'finds the filled shapes the template uses, but not its placeholders' {
        @($look.shapes).Count | Should Be 1
        $look.shapes[0].prst | Should Be 'roundRect'
        $look.shapes[0].fill | Should Be '10069F'
    }

    It 'turns kit tokens into DrawingML values' {
        $k = Get-PptxKitLook $script:Tokens
        $k.colors.surface | Should Be 'FFFFFF'
        $k.colors['surface-2'] | Should Be 'F4F5F7'
        $k.colors['accent-soft'] | Should Be 'E6F0FA'
        $k.font | Should Be 'Segoe UI'
        $k.radius | Should Be 6
        $k.radiusLg | Should Be 12
        @($k.palette).Count | Should Be 6
        $k.palette[0] | Should Be '2E7BCF'
        $look.kit.font | Should Be 'Segoe UI'
    }

    It 'gives no kit look without tokens, and defaults for missing font and radii' {
        (Get-PptxKitLook @{}).Count | Should Be 0
        $k = Get-PptxKitLook @{ surface = '#fff' }
        $k.font | Should Be 'Arial'
        $k.radius | Should Be 6
        $k.radiusLg | Should Be 10
        @($k.palette).Count | Should Be 0
        (Read-PptxTemplateLook $script:TplPath).kit.Count | Should Be 0
    }
}

Describe 'Finding elements without brand formatting' {
    $look = Read-PptxTemplateLook $script:TplPath -KitTokens $script:Tokens
    $plan = Get-PptxRethemePlan $script:TplPath $script:ContentPath
    $found = Get-PptxElementChoices $script:ContentPath $look $plan
    $by = @{}; foreach ($e in @($found.elements)) { $by[$e.key] = $e }

    It 'lists exactly the unformatted elements, per kind' {
        @($by.Keys | Sort-Object) -join ',' | Should Be '1:3,1:5,2:2,2:3,2:7,2:8,3:3'
        $by['1:3'].kind | Should Be 'textbox'
        $by['1:5'].kind | Should Be 'table'
        $by['2:8'].kind | Should Be 'table'
        $by['2:2'].kind | Should Be 'heading'
        $by['2:3'].kind | Should Be 'shape'
        $by['2:7'].kind | Should Be 'shape'
        $by['3:3'].kind | Should Be 'chart'
    }

    It 'leaves out what already follows the theme or the brand' {
        # own font, accent table style, typed theme colour, scheme fill, near a template colour, theme chart
        foreach ($k in '1:4', '1:6', '2:4', '2:5', '2:6', '3:4') { $by.ContainsKey($k) | Should Be $false }
    }

    It 'describes each element for the card' {
        $by['1:5'].label | Should Match 'no style'
        $by['2:8'].label | Should Match 'plain style'
        $by['2:3'].label | Should Match '#00C000'
        $by['3:3'].label | Should Match '1 series'
        $by['1:3'].text | Should Be 'SECRET-BODY-TEXT'
        $by['2:3'].box.w | Should Be 144
    }

    It 'ranks the template''s options first and Keep as it is last, for every element' {
        foreach ($e in @($found.elements)) {
            $e.options[0].group | Should Be 'template'
            $e.options[-1].id | Should Be 'keep'
            @($e.options | Where-Object { $_.group -eq 'keep' }).Count | Should Be 1
            @($e.all).Count | Should Be @($e.options).Count
            foreach ($o in @($e.options)) { { $o.drawing | ConvertFrom-Json } | Should Not Throw }
        }
    }

    It 'puts the template before the UI kit for tables and charts' {
        foreach ($k in '1:5', '3:3') {
            $ids = @($by[$k].options | ForEach-Object { $_.group })
            $lastTpl = [array]::LastIndexOf([object[]]$ids, 'template'); $firstKit = [array]::IndexOf([object[]]$ids, 'kit')
            $firstKit | Should BeGreaterThan $lastTpl
        }
        $by['1:5'].options[0].id | Should Be "tblstyle:$script:AccentStyle"
        @($by['1:5'].options | Where-Object { $_.id -eq 'kit-table' }).Count | Should Be 1
        $by['3:3'].options[0].id | Should Be 'chart:accents'
        @($by['3:3'].options | Where-Object { $_.id -eq 'chart:kit' }).Count | Should Be 1
    }

    It 'orders a text box''s template styles by how near they are in size' {
        $tpl = @($by['1:3'].all | Where-Object { $_.group -eq 'template' })
        $tpl.Count | Should Be 4
        for ($i = 1; $i -lt $tpl.Count; $i++) { $tpl[$i].sizeDiff | Should Not BeLessThan $tpl[$i - 1].sizeDiff }
        $tpl[-1].id | Should Be 'text:title'
    }

    It 'offers the title placeholder first for the heading the core makes the title' {
        $by['2:2'].default | Should Be 'title-placeholder'
        $by['2:2'].options[0].id | Should Be 'title-placeholder'
        $noPlan = Get-PptxElementChoices $script:ContentPath $look
        $h = @($noPlan.elements | Where-Object { $_.key -eq '2:2' })[0]
        $h.default | Should Be 'keep'
        @($h.options | Where-Object { $_.id -eq 'title-placeholder' }).Count | Should Be 0
    }

    It 'offers only options whose text reads' {
        foreach ($e in @($found.elements)) { foreach ($o in @($e.all)) { if ($o.id -ne 'keep') { Get-TestOptionReadable $o $look | Should Be $true } } }
    }

    It 'leaves out template colours white text would not read on, but keeps readable ones' {
        $pale = $by['2:7']
        @($pale.options | Where-Object { $_.id -like 'theme:*' }).Count | Should Be 0
        @($pale.options | Where-Object { $_.id -eq 'tplshape:1' }).Count | Should Be 1
        @($pale.options | Where-Object { $_.id -eq 'kit-panel' }).Count | Should Be 1
        @($by['2:3'].options | Where-Object { $_.id -eq 'theme:dk2' }).Count | Should Be 1
    }

    It 'leaves out a template text style that would not read on the slide' {
        $pale = Read-PptxTemplateLook $script:TplPath
        $pale.text.subtitle.color = 'FAFAFA'
        $f = Get-PptxElementChoices $script:ContentPath $pale
        $t = @($f.elements | Where-Object { $_.key -eq '1:3' })[0]
        @($t.options | Where-Object { $_.id -eq 'text:subtitle' }).Count | Should Be 0
        @($t.options | Where-Object { $_.id -eq 'text:body1' }).Count | Should Be 1
    }

    It 'offers no kit options without kit tokens' {
        $f = Get-PptxElementChoices $script:ContentPath (Read-PptxTemplateLook $script:TplPath) $plan
        foreach ($e in @($f.elements)) { @($e.options | Where-Object { $_.group -eq 'kit' }).Count | Should Be 0 }
        # Kit tokens without chart colours: kit tables and shapes, but no kit chart colours.
        $noCharts = @{}; foreach ($k in $script:Tokens.Keys) { if ($k -notlike 'chart-*') { $noCharts[$k] = $script:Tokens[$k] } }
        $f2 = Get-PptxElementChoices $script:ContentPath (Read-PptxTemplateLook $script:TplPath -KitTokens $noCharts) $plan
        $c = @($f2.elements | Where-Object { $_.kind -eq 'chart' })[0]
        @($c.options | Where-Object { $_.id -eq 'chart:kit' }).Count | Should Be 0
        @(@($f2.elements | Where-Object { $_.kind -eq 'table' })[0].options | Where-Object { $_.id -eq 'kit-table' }).Count | Should Be 1
    }

    It 'finds nothing in a deck whose elements are all formatted' {
        $clean = Join-Path $script:Tmp 'clean.pptx'
        $null = New-TestDeck -Path $clean -Slides @(@{ layout = 2; shapes = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'Title') + (New-TableXml 3 @(457200, 1600200, 3657600, 741680)) + (New-SpXml -Id 4 -Text 'x' -Rect @(457200, 3000000, 900000, 400000) -RunAttr 'sz="1200"' -Fill '4F81BD') })
        @((Get-PptxElementChoices $clean $look).elements).Count | Should Be 0
    }
}

Describe 'Choices on the plan' {
    $plan = Get-PptxRethemePlan $script:TplPath $script:ContentPath
    $r = Add-PptxElementChoices -Plan $plan -TemplatePath $script:TplPath -ContentPath $script:ContentPath -KitTokens $script:Tokens

    It 'puts each slide''s elements on the slide, without apply data' {
        $by = @{}; foreach ($s in @($r.slides)) { $by[$s.index] = $s }
        @($by[1].elements).Count | Should Be 2
        @($by[2].elements).Count | Should Be 4
        @($by[3].elements).Count | Should Be 1
        foreach ($s in @($r.slides)) { foreach ($e in @($s.elements)) { $e.ContainsKey('all') | Should Be $false; $e.options[0].ContainsKey('apply') | Should Be $false } }
    }

    It 'sums up the kinds with the options every element of a kind offers' {
        $k = @{}; foreach ($x in @($r.kinds)) { $k[$x.kind] = $x }
        $k.table.count | Should Be 2
        $k.shape.count | Should Be 2
        $k.chart.count | Should Be 1
        $k.ContainsKey('textbox') | Should Be $true
        @($k.table.options | ForEach-Object { $_.id }) -contains 'kit-table' | Should Be $true
        @($k.shape.options | ForEach-Object { $_.id }) -contains 'keep' | Should Be $true
        @($k.shape.options | ForEach-Object { $_.id }) -contains 'theme:dk2' | Should Be $false
    }

    It 'names the fonts the previews use' {
        @($r.fonts) -join ',' | Should Be 'Georgia,Verdana,Segoe UI'
    }
}

Describe 'Applying the chosen looks' {
    $out = Join-Path $script:Tmp 'branded.pptx'
    $tplHash = Get-FileHashText $script:TplPath; $conHash = Get-FileHashText $script:ContentPath
    $choices = @{ kinds = @{ table = 'kit-table'; chart = 'chart:kit'; textbox = 'text:body1' }; elements = @{ '2:3' = 'kit-panel'; '2:7' = 'tplshape:1' } }
    $r = Invoke-PptxRethemeChoices -TemplatePath $script:TplPath -ContentPath $script:ContentPath -OutPath $out -Choices $choices -KitTokens $script:Tokens
    $slides = @(Get-OutSlides $out)
    $find = { param($marker) @($slides | Where-Object { $_.xml.OuterXml -match $marker })[0].xml }

    It 'leaves the template and the content deck as they were, and writes a sound package' {
        Get-FileHashText $script:TplPath | Should Be $tplHash
        Get-FileHashText $script:ContentPath | Should Be $conHash
        Test-Path -LiteralPath $out | Should Be $true
        @(Get-PackageProblems $out) | Should BeNullOrEmpty
        @($r.warnings | Where-Object { $_ -match 'took the look chosen' }).Count | Should Be 1
        @($r.warnings | Where-Object { $_ -match 'was not found' }).Count | Should Be 0
    }

    It 'gives unstyled tables the kit table style and adds it to the deck once' {
        $x = & $find 'SECRET-BODY-TEXT'
        (Get-ShapeById $x 5).SelectSingleNode(".//*[local-name()='tableStyleId']").InnerText | Should Be $script:KitStyleId
        (Get-ShapeById $x 6).SelectSingleNode(".//*[local-name()='tableStyleId']").InnerText | Should Be $script:AccentStyle
        $x2 = & $find 'GO-SHAPE'
        (Get-ShapeById $x2 8).SelectSingleNode(".//*[local-name()='tableStyleId']").InnerText | Should Be $script:KitStyleId
        $ts = Read-OutXml $out '/ppt/tableStyles.xml'
        @($ts.SelectNodes("//*[local-name()='tblStyle' and @styleId='$script:KitStyleId']")).Count | Should Be 1
        $ts.SelectSingleNode("//*[local-name()='tblStyle']/*[local-name()='firstRow']//*[local-name()='fill']//*[local-name()='srgbClr']").GetAttribute('val') | Should Be 'F4F5F7'
    }

    It 'sets the text box in the template''s body style' {
        $sp = Get-ShapeById (& $find 'SECRET-BODY-TEXT') 3
        $rp = $sp.SelectSingleNode(".//*[local-name()='r']/*[local-name()='rPr']")
        $rp.GetAttribute('sz') | Should Be '2800'
        $rp.SelectSingleNode("*[local-name()='latin']").GetAttribute('typeface') | Should Be '+mn-lt'
        Get-ShapeById (& $find 'SECRET-BODY-TEXT') 4 | Should Not BeNullOrEmpty
    }

    It 'draws the shapes in the chosen kit and template looks' {
        $x = & $find 'GO-SHAPE'
        $kit = Get-ShapeById $x 3
        $kit.SelectSingleNode(".//*[local-name()='prstGeom']").GetAttribute('prst') | Should Be 'roundRect'
        $kit.SelectSingleNode("*[local-name()='spPr']/*[local-name()='solidFill']/*[local-name()='srgbClr']").GetAttribute('val') | Should Be 'FFFFFF'
        $kit.SelectSingleNode(".//*[local-name()='r']/*[local-name()='rPr']/*[local-name()='solidFill']/*[local-name()='srgbClr']").GetAttribute('val') | Should Be '1F2328'
        $tpl = Get-ShapeById $x 7
        $tpl.SelectSingleNode(".//*[local-name()='prstGeom']").GetAttribute('prst') | Should Be 'roundRect'
        $tpl.SelectSingleNode("*[local-name()='spPr']/*[local-name()='solidFill']/*[local-name()='srgbClr']").GetAttribute('val') | Should Be '10069F'
    }

    It 'colours the typed chart''s series with the kit''s chart colours and leaves the other chart alone' {
        $charts = @(Get-OutChartColours $out)
        $charts.Count | Should Be 2
        @($charts | Where-Object { @($_) -contains '2E7BCF' }).Count | Should Be 1
        @($charts | Where-Object { @($_) -contains 'AA3377' }).Count | Should Be 0
    }

    It 'moves the heading into the title placeholder by default' {
        $x = & $find 'Free Heading'
        $title = $x.SelectSingleNode("//*[local-name()='ph' and @type='title']")
        $title | Should Not BeNullOrEmpty
        (Get-PptxText $title.ParentNode.ParentNode.ParentNode (Get-PptxNs $x)) | Should Match 'Free Heading'
    }

    It 'keeps everything as it was with no choices but the defaults turned off' {
        $out2 = Join-Path $script:Tmp 'kept.pptx'
        $r2 = Invoke-PptxRethemeChoices -TemplatePath $script:TplPath -ContentPath $script:ContentPath -OutPath $out2 -Choices @{ kinds = @{ heading = 'keep' } } -KitTokens $script:Tokens
        @($r2.warnings | Where-Object { $_ -match 'took the look chosen' }).Count | Should Be 0
        $ts = Read-OutXml $out2 '/ppt/tableStyles.xml'
        @($ts.SelectNodes("//*[local-name()='tblStyle' and @styleId='$script:KitStyleId']")).Count | Should Be 0
        @(Get-PackageProblems $out2) | Should BeNullOrEmpty
    }
}

Describe 'Asking Copilot about one element' {
    $look = Read-PptxTemplateLook $script:TplPath -KitTokens $script:Tokens
    $found = Get-PptxElementChoices $script:ContentPath $look
    $box = @($found.elements | Where-Object { $_.key -eq '1:3' })[0]
    $shape = @($found.elements | Where-Object { $_.key -eq '2:3' })[0]

    It 'sends only the element''s structure, never its slide text' {
        foreach ($e in $box, $shape) {
            $ask = New-PptxElementAsk $e $look
            $ask | Should Not Match 'SECRET-BODY-TEXT'
            $ask | Should Not Match 'GO-SHAPE'
            $ask | Should Not Match 'CCBridge'
            $ask | Should Match '```json'
            foreach ($o in @($e.all)) { $ask.Contains("- $($o.id): ") | Should Be $true }
        }
        $s = New-PptxElementAsk $shape $look
        $s | Should Match 'shape of 144 x 72 pt, filled with #00C000'
        $s | Should Match 'Georgia \(headings\), Verdana \(body\)'
        $s | Should Match 'accent1 #10069F'
    }

    It 'accepts a pick that is one of the options' {
        $a = Read-PptxElementAnswer ("Here:`n" + '```json' + "`n" + '{"option": "kit-panel", "why": " Calm and readable. "}' + "`n" + '```') $shape
        $a.ok | Should Be $true
        $a.option | Should Be 'kit-panel'
        $a.label | Should Be 'UI kit panel'
        $a.why | Should Be 'Calm and readable.'
        (Read-PptxElementAnswer '{"option":"keep"}' $shape).ok | Should Be $true
    }

    It 'refuses an unknown option, broken JSON and an answer without JSON' {
        $u = Read-PptxElementAnswer ('```json' + "`n" + '{"option": "text:huge"}' + "`n" + '```') $shape
        $u.ok | Should Be $false
        $u.error | Should Match 'text:huge'
        $b = Read-PptxElementAnswer ('```json' + "`n" + '{"option": kit-panel' + "`n" + '```') $shape
        $b.ok | Should Be $false
        $b.error | Should Match 'does not parse'
        (Read-PptxElementAnswer 'I would pick the panel.' $shape).error | Should Match 'no JSON'
        (Read-PptxElementAnswer '' $shape).ok | Should Be $false
    }
}

Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
