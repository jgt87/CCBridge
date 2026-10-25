# Test decks for the PowerPoint template tests (PptxRetheme, PptxChoices, PptxDeck): decks built from XML
# strings with System.IO.Packaging, and readers for the output. Dot-sourced; no PowerPoint is needed.

# ------------------------------------------------------------------------------- deck builder

$script:XP = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'
$script:RB = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:CT = 'application/vnd.openxmlformats-officedocument.presentationml'
$script:Grp = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
$script:Png1 = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')

function New-TestPng([int]$Seed) {
    # A distinct small PNG per seed (a 1x1 picture plus a trailing comment chunk is still a valid PNG to
    # the package; only the bytes need to differ).
    $b = New-Object Collections.Generic.List[byte]; $b.AddRange($script:Png1); $b.AddRange([byte[]](0, 0, 0, 0, 0x74, 0x45, 0x58, 0x74, [byte]$Seed, 1, 2, 3)); $b.ToArray()
}

function New-TestXlsx([int]$Seed) {
    # The smallest workbook Excel and PowerPoint accept: a chart's embedded data must be a real one.
    $files = [ordered]@{
        '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
        '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
        'xl/workbook.xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>'
        'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
        'xl/worksheets/sheet1.xml' = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><worksheet xmlns=""http://schemas.openxmlformats.org/spreadsheetml/2006/main""><sheetData><row r=""2""><c r=""B2""><v>1</v></c></row><row r=""3""><c r=""B3""><v>$Seed</v></c></row></sheetData></worksheet>"
    }
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    try { foreach ($k in $files.Keys) { $w = New-Object IO.StreamWriter($zip.CreateEntry($k).Open()); try { $w.Write($files[$k]) } finally { $w.Dispose() } } } finally { $zip.Dispose() }
    , $ms.ToArray()
}

function Get-Xfrm($R) { if ($R) { "<a:xfrm><a:off x=""$($R[0])"" y=""$($R[1])""/><a:ext cx=""$($R[2])"" cy=""$($R[3])""/></a:xfrm>" } else { '' } }

function New-SpXml {
    param([int]$Id, [string]$Text = '', [string]$Ph = '', $Rect = $null, [string]$RunAttr = '', [string]$RunXml = '', [string]$Fill = '', [switch]$TextBox, [string]$Inner = '')
    $tb = if ($TextBox) { ' txBox="1"' } else { '' }
    $fillXml = if ($Fill) { "<a:solidFill><a:srgbClr val=""$Fill""/></a:solidFill>" } else { '' }
    $geom = if ($Rect -and -not $Ph) { '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' } else { '' }
    $paras = if ($Inner) { $Inner } elseif ($Text) { "<a:p><a:r><a:rPr lang=""en-US"" $RunAttr>$RunXml</a:rPr><a:t>$Text</a:t></a:r></a:p>" } else { '<a:p><a:endParaRPr lang="en-US"/></a:p>' }
    "<p:sp><p:nvSpPr><p:cNvPr id=""$Id"" name=""Shape $Id""/><p:cNvSpPr$tb/><p:nvPr>$Ph</p:nvPr></p:nvSpPr><p:spPr>$(Get-Xfrm $Rect)$geom$fillXml</p:spPr><p:txBody><a:bodyPr wrap=""none""><a:spAutoFit/></a:bodyPr><a:lstStyle/>$paras</p:txBody></p:sp>"
}

function New-PicXml([int]$Id, [string]$Rid, $Rect, [string]$Ph = '') {
    "<p:pic><p:nvPicPr><p:cNvPr id=""$Id"" name=""Picture $Id""/><p:cNvPicPr/><p:nvPr>$Ph</p:nvPr></p:nvPicPr><p:blipFill><a:blip r:embed=""$Rid""/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>$(Get-Xfrm $Rect)<a:prstGeom prst=""rect""><a:avLst/></a:prstGeom></p:spPr></p:pic>"
}

function New-TableXml([int]$Id, $Rect, [string]$Style = '{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}', [string[]]$Cells = @('Region', 'Sales', 'EMEA', '42')) {
    $row = { param($a, $b) "<a:tr h=""370840""><a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=""en-US"" sz=""1800""/><a:t>$a</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc><a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=""en-US""/><a:t>$b</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc></a:tr>" }
    "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=""$Id"" name=""Table $Id""/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=""1""/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x=""$($Rect[0])"" y=""$($Rect[1])""/><a:ext cx=""$($Rect[2])"" cy=""$($Rect[3])""/></p:xfrm><a:graphic><a:graphicData uri=""http://schemas.openxmlformats.org/drawingml/2006/table""><a:tbl><a:tblPr firstRow=""1"" bandRow=""1""><a:tableStyleId>$Style</a:tableStyleId></a:tblPr><a:tblGrid><a:gridCol w=""$([long]($Rect[2] / 2))""/><a:gridCol w=""$([long]($Rect[2] / 2))""/></a:tblGrid>$(& $row $Cells[0] $Cells[1])$(& $row $Cells[2] $Cells[3])</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
}

function New-ChartFrameXml([int]$Id, [string]$Rid, $Rect, [string]$Ph = '') {
    "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=""$Id"" name=""Chart $Id""/><p:cNvGraphicFramePr/><p:nvPr>$Ph</p:nvPr></p:nvGraphicFramePr><p:xfrm><a:off x=""$($Rect[0])"" y=""$($Rect[1])""/><a:ext cx=""$($Rect[2])"" cy=""$($Rect[3])""/></p:xfrm><a:graphic><a:graphicData uri=""http://schemas.openxmlformats.org/drawingml/2006/chart""><c:chart xmlns:c=""http://schemas.openxmlformats.org/drawingml/2006/chart"" r:id=""$Rid""/></a:graphicData></a:graphic></p:graphicFrame>"
}

$script:ChartXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:chart><c:plotArea><c:layout/><c:barChart><c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/><c:ser><c:idx val="0"/><c:order val="0"/><c:spPr><a:solidFill><a:srgbClr val="4F81BD"/></a:solidFill></c:spPr><c:val><c:numRef><c:f>Sheet1!$B$2:$B$3</c:f><c:numCache><c:formatCode>General</c:formatCode><c:ptCount val="2"/><c:pt idx="0"><c:v>1</c:v></c:pt><c:pt idx="1"><c:v>2</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser><c:axId val="1"/><c:axId val="2"/></c:barChart><c:catAx><c:axId val="1"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/><c:crossAx val="2"/></c:catAx><c:valAx><c:axId val="2"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/><c:crossAx val="1"/></c:valAx></c:plotArea></c:chart><c:externalData r:id="rId1"><c:autoUpdate val="0"/></c:externalData></c:chartSpace>'

function New-ThemeXml([string]$Accent1 = '4F81BD', [string]$Major = 'Calibri Light', [string]$Minor = 'Calibri', [string]$Lt2 = 'EEECE1') {
    $acc = @($Accent1, 'C0504D', '9BBB59', '8064A2', '4BACC6', 'F79646')
    $c = ''; for ($i = 0; $i -lt 6; $i++) { $c += "<a:accent$($i + 1)><a:srgbClr val=""$($acc[$i])""/></a:accent$($i + 1)>" }
    $f3 = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' * 3
    $l3 = '<a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>' * 3
    $e3 = '<a:effectStyle><a:effectLst/></a:effectStyle>' * 3
    "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><a:theme xmlns:a=""http://schemas.openxmlformats.org/drawingml/2006/main"" name=""T""><a:themeElements><a:clrScheme name=""C""><a:dk1><a:sysClr val=""windowText"" lastClr=""000000""/></a:dk1><a:lt1><a:sysClr val=""window"" lastClr=""FFFFFF""/></a:lt1><a:dk2><a:srgbClr val=""1F497D""/></a:dk2><a:lt2><a:srgbClr val=""$Lt2""/></a:lt2>$c<a:hlink><a:srgbClr val=""0000FF""/></a:hlink><a:folHlink><a:srgbClr val=""800080""/></a:folHlink></a:clrScheme><a:fontScheme name=""F""><a:majorFont><a:latin typeface=""$Major""/><a:ea typeface=""""/><a:cs typeface=""""/></a:majorFont><a:minorFont><a:latin typeface=""$Minor""/><a:ea typeface=""""/><a:cs typeface=""""/></a:minorFont></a:fontScheme><a:fmtScheme name=""S""><a:fillStyleLst>$f3</a:fillStyleLst><a:lnStyleLst>$l3</a:lnStyleLst><a:effectStyleLst>$e3</a:effectStyleLst><a:bgFillStyleLst>$f3</a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
}

function Get-PhXml($Ph) {
    $t = if ($Ph.type) { " type=""$($Ph.type)""" } else { '' }; $i = if ($Ph.idx) { " idx=""$($Ph.idx)""" } else { '' }
    "<p:ph$t$i/>"
}

# Standard Office layouts (with types) and a corporate set without types, as real templates have.
function Get-OfficeLayouts {
    $T = @(457200, 274638, 8229600, 1143000); $B = @(457200, 1600200, 8229600, 4525963)
    @(
        @{ name = 'Title Slide'; type = 'title'; ph = @(@{ type = 'ctrTitle'; rect = @(685800, 2130425, 7772400, 1470025) }, @{ type = 'subTitle'; idx = '1'; rect = @(1371600, 3886200, 6400800, 1752600) }) },
        @{ name = 'Title and Content'; type = 'obj'; ph = @(@{ type = 'title'; rect = $T }, @{ idx = '1'; rect = $B }, @{ type = 'ftr'; idx = '11'; rect = @(3124200, 6356350, 2895600, 365125) }) },
        @{ name = 'Section Header'; type = 'secHead'; ph = @(@{ type = 'title'; rect = $T }, @{ type = 'body'; idx = '1'; rect = $B }) },
        @{ name = 'Two Content'; type = 'twoObj'; ph = @(@{ type = 'title'; rect = $T }, @{ idx = '1'; sz = 'half'; rect = @(457200, 1600200, 4038600, 4525963) }, @{ idx = '2'; rect = @(4648200, 1600200, 4038600, 4525963) }) },
        @{ name = 'Title Only'; type = 'titleOnly'; ph = @(@{ type = 'title'; rect = $T }) },
        @{ name = 'Blank'; type = 'blank'; ph = @() }
    )
}

function Get-CorporateLayouts {
    $T = @(609600, 300000, 10972800, 900000); $B = @(609600, 1400000, 10972800, 4700000)
    @(
        @{ name = 'Cover'; ph = @(@{ type = 'ctrTitle'; rect = @(609600, 2000000, 10972800, 1400000) }, @{ type = 'subTitle'; idx = '10'; rect = @(609600, 3600000, 10972800, 800000) }) },
        @{ name = 'Titel en inhoud'; ph = @(@{ type = 'title'; rect = $T }, @{ idx = '13'; rect = $B }) },
        @{ name = 'Hoofdstuk'; ph = @(@{ type = 'title'; rect = @(609600, 2500000, 10972800, 1200000) }) },
        @{ name = 'Twee kolommen'; ph = @(@{ type = 'title'; rect = $T }, @{ idx = '14'; rect = @(609600, 1400000, 5300000, 4700000) }, @{ idx = '15'; rect = @(6282400, 1400000, 5300000, 4700000) }) },
        @{ name = 'Alleen titel'; ph = @(@{ type = 'title'; rect = $T }) },
        @{ name = 'Leeg'; ph = @() }
    )
}

function Add-TestPart($Pkg, [string]$Uri, [string]$Type, $Content) {
    $p = $Pkg.CreatePart((New-Object Uri($Uri, [UriKind]::Relative)), $Type, [IO.Packaging.CompressionOption]::Normal)
    $bytes = if ($Content -is [byte[]]) { $Content } else { [Text.Encoding]::UTF8.GetBytes([string]$Content) }
    $s = $p.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
    $p
}

function Add-TestRel($From, $To, [string]$Kind, [string]$Id) {
    $type = if ($Kind -match '^http') { $Kind } else { "$script:RB/$Kind" }
    $null = $From.CreateRelationship([IO.Packaging.PackUriHelper]::GetRelativeUri($From.Uri, $To.Uri), [IO.Packaging.TargetMode]::Internal, $type, $Id)
}

function New-TestDeck {
    <# A deck from XML strings. Slides: @{ layout = N; shapes = XML; notes = TEXT; pics = @{ rId = bytes };
       charts = @('rId'); links = @{ rId = slide number }; ext = @{ rId = URL }; show = '0' }. #>
    param([Parameter(Mandatory)][string]$Path, $Layouts = (Get-OfficeLayouts), $Slides = @(), [long[]]$Size = @(9144000, 6858000),
        [string]$Accent1 = '4F81BD', [string]$Major = 'Calibri Light', [string]$Minor = 'Calibri', [switch]$NotesMaster, [string]$TableStyles = '', [switch]$Sections)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $pkg = [IO.Packaging.Package]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite)
    try {
        $pres = Add-TestPart $pkg '/ppt/presentation.xml' "$script:CT.presentation.main+xml" 'x'
        $null = $pkg.CreateRelationship((New-Object Uri('ppt/presentation.xml', [UriKind]::Relative)), [IO.Packaging.TargetMode]::Internal, "$script:RB/officeDocument", 'rId1')
        $theme = Add-TestPart $pkg '/ppt/theme/theme1.xml' 'application/vnd.openxmlformats-officedocument.theme+xml' (New-ThemeXml $Accent1 $Major $Minor)
        $master = Add-TestPart $pkg '/ppt/slideMasters/slideMaster1.xml' "$script:CT.slideMaster+xml" 'x'
        Add-TestRel $pres $master 'slideMaster' 'rIdM'; Add-TestRel $pres $theme 'theme' 'rIdT'; Add-TestRel $master $theme 'theme' 'rIdT'
        $lids = ''; $lparts = @(); $n = 0
        foreach ($l in @($Layouts)) {
            $n++
            $sps = ''; $id = 2
            foreach ($ph in @($l.ph)) { $sps += New-SpXml -Id $id -Ph (Get-PhXml $ph) -Rect $ph.rect; $id++ }
            $ta = if ($l.type) { " type=""$($l.type)""" } else { '' }
            $lp = Add-TestPart $pkg "/ppt/slideLayouts/slideLayout$n.xml" "$script:CT.slideLayout+xml" "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:sldLayout $script:XP$ta preserve=""1""><p:cSld name=""$($l.name)""><p:spTree>$script:Grp$sps</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
            Add-TestRel $lp $master 'slideMaster' 'rId1'; Add-TestRel $master $lp 'slideLayout' "rIdL$n"
            $lids += "<p:sldLayoutId id=""$(2147483648 + $n)"" r:id=""rIdL$n""/>"; $lparts += $lp
        }
        $mph = (New-SpXml -Id 2 -Ph '<p:ph type="title"/>' -Rect @(457200, 274638, 8229600, 1143000)) + (New-SpXml -Id 3 -Ph '<p:ph type="body" idx="1"/>' -Rect @(457200, 1600200, 8229600, 4525963)) + (New-SpXml -Id 4 -Ph '<p:ph type="dt" idx="10"/>' -Rect @(457200, 6356350, 2133600, 365125))
        $mx = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:sldMaster $script:XP><p:cSld><p:spTree>$script:Grp$mph</p:spTree></p:cSld><p:clrMap bg1=""lt1"" tx1=""dk1"" bg2=""lt2"" tx2=""dk2"" accent1=""accent1"" accent2=""accent2"" accent3=""accent3"" accent4=""accent4"" accent5=""accent5"" accent6=""accent6"" hlink=""hlink"" folHlink=""folHlink""/><p:sldLayoutIdLst>$lids</p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>"
        $s = $master.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); try { $b = [Text.Encoding]::UTF8.GetBytes($mx); $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
        $nm = $null; $nml = ''
        if ($NotesMaster) {
            $nt = Add-TestPart $pkg '/ppt/theme/theme2.xml' 'application/vnd.openxmlformats-officedocument.theme+xml' (New-ThemeXml)
            $nm = Add-TestPart $pkg '/ppt/notesMasters/notesMaster1.xml' "$script:CT.notesMaster+xml" "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:notesMaster $script:XP><p:cSld><p:spTree>$script:Grp$(New-SpXml -Id 2 -Ph '<p:ph type="sldImg" idx="2"/>' -Rect @(1143000, 685800, 4572000, 3429000))$(New-SpXml -Id 3 -Ph '<p:ph type="body" idx="3"/>' -Rect @(685800, 4343400, 5486400, 4114800))</p:spTree></p:cSld><p:clrMap bg1=""lt1"" tx1=""dk1"" bg2=""lt2"" tx2=""dk2"" accent1=""accent1"" accent2=""accent2"" accent3=""accent3"" accent4=""accent4"" accent5=""accent5"" accent6=""accent6"" hlink=""hlink"" folHlink=""folHlink""/></p:notesMaster>"
            Add-TestRel $nm $nt 'theme' 'rId1'; Add-TestRel $pres $nm 'notesMaster' 'rIdN'
            $nml = '<p:notesMasterIdLst><p:notesMasterId r:id="rIdN"/></p:notesMasterIdLst>'
        }
        $sids = ''; $sparts = @(); $n = 0
        foreach ($sl in @($Slides)) { $n++; $sparts += Add-TestPart $pkg "/ppt/slides/slide$n.xml" "$script:CT.slide+xml" 'x' }
        $n = 0; $media = 0; $charts = 0
        foreach ($sl in @($Slides)) {
            $n++; $sp = $sparts[$n - 1]
            Add-TestRel $sp $lparts[[int]$sl.layout - 1] 'slideLayout' 'rId1'
            if ($sl.pics) { foreach ($k in $sl.pics.Keys) { $media++; Add-TestRel $sp (Add-TestPart $pkg "/ppt/media/image$media.png" 'image/png' ([byte[]]$sl.pics[$k])) 'image' $k } }
            foreach ($k in @($sl.charts | Where-Object { $_ })) {
                $charts++
                $cp = Add-TestPart $pkg "/ppt/charts/chart$charts.xml" 'application/vnd.openxmlformats-officedocument.drawingml.chart+xml' $script:ChartXml
                Add-TestRel $cp (Add-TestPart $pkg "/ppt/embeddings/Microsoft_Excel_Worksheet$charts.xlsx" 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' (New-TestXlsx $charts)) 'package' 'rId1'
                Add-TestRel $sp $cp 'chart' $k
            }
            if ($sl.links) { foreach ($k in $sl.links.Keys) { Add-TestRel $sp $sparts[[int]$sl.links[$k] - 1] 'slide' $k } }
            if ($sl.ext) { foreach ($k in $sl.ext.Keys) { $null = $sp.CreateRelationship((New-Object Uri($sl.ext[$k])), [IO.Packaging.TargetMode]::External, "$script:RB/hyperlink", $k) } }
            if ($sl.notes) {
                $np = Add-TestPart $pkg "/ppt/notesSlides/notesSlide$n.xml" "$script:CT.notesSlide+xml" "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:notes $script:XP><p:cSld><p:spTree>$script:Grp$(New-SpXml -Id 2 -Ph '<p:ph type="sldImg"/>')$(New-SpXml -Id 3 -Ph '<p:ph type="body" idx="1"/>' -Text $sl.notes)</p:spTree></p:cSld></p:notes>"
                if ($nm) { Add-TestRel $np $nm 'notesMaster' 'rId1' }
                Add-TestRel $np $sp 'slide' 'rId2'; Add-TestRel $sp $np 'notesSlide' 'rIdNotes'
            }
            $show = if ($sl.show) { " show=""$($sl.show)""" } else { '' }
            $x = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:sld $script:XP$show><p:cSld><p:spTree>$script:Grp$($sl.shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            $s = $sp.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); try { $b = [Text.Encoding]::UTF8.GetBytes($x); $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
            $null = $pres.CreateRelationship([IO.Packaging.PackUriHelper]::GetRelativeUri($pres.Uri, $sp.Uri), [IO.Packaging.TargetMode]::Internal, "$script:RB/slide", "rIdS$n")
            $sids += "<p:sldId id=""$(255 + $n)"" r:id=""rIdS$n""/>"
        }
        $ts = if ($TableStyles) { $TableStyles } else { '<a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>' }
        Add-TestRel $pres (Add-TestPart $pkg '/ppt/tableStyles.xml' "$script:CT.tableStyles+xml" "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>$ts") 'tableStyles' 'rIdTS'
        Add-TestRel $pres (Add-TestPart $pkg '/ppt/presProps.xml' "$script:CT.presProps+xml" "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:presentationPr $script:XP/>") 'presProps' 'rIdPP'
        Add-TestRel $pres (Add-TestPart $pkg '/ppt/viewProps.xml' "$script:CT.viewProps+xml" "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:viewPr $script:XP/>") 'viewProps' 'rIdVP'
        $sec = if ($Sections) { '<p:extLst><p:ext uri="{521415D9-36F7-43E2-AB2F-B90AF26B5E84}"><p14:sectionLst xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main"><p14:section name="One" id="{11111111-1111-1111-1111-111111111111}"><p14:sldIdLst><p14:sldId id="257"/></p14:sldIdLst></p14:section></p14:sectionLst></p:ext></p:extLst>' } else { '' }
        $px = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:presentation $script:XP><p:sldMasterIdLst><p:sldMasterId id=""2147483648"" r:id=""rIdM""/></p:sldMasterIdLst>$nml<p:sldIdLst>$sids</p:sldIdLst><p:sldSz cx=""$($Size[0])"" cy=""$($Size[1])""/><p:notesSz cx=""6858000"" cy=""9144000""/>$sec</p:presentation>"
        $s = $pres.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); try { $b = [Text.Encoding]::UTF8.GetBytes($px); $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
    } finally { $pkg.Close() }
    $Path
}

# ------------------------------------------------------------------------------- reading the output

function Read-OutXml([string]$Path, [string]$Uri) {
    $pkg = Open-PptxPackage $Path
    try { $x = Read-PptxPartXml ($pkg.GetPart((New-Object Uri($Uri, [UriKind]::Relative)))); return , $x } finally { $pkg.Close() }
}

function Get-OutSlides([string]$Path) {
    # Each slide in order: @{ uri; xml; layout (name); rels (kind -> target) }.
    $pkg = Open-PptxPackage $Path
    try {
        $pres = Get-PptxPresentationPart $pkg; $px = Read-PptxPartXml $pres; $ns = Get-PptxNs $px
        foreach ($sid in @($px.SelectNodes('/p:presentation/p:sldIdLst/p:sldId', $ns))) {
            $part = $pkg.GetPart((Get-PptxRelTarget $pres $pres.GetRelationship($sid.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'))))
            $lay = Get-PptxRelatedPart $pkg $part 'slideLayout'
            $lx = Read-PptxPartXml $lay
            $notes = Get-PptxRelatedPart $pkg $part 'notesSlide'
            @{ uri = "$($part.Uri)"; xml = (Read-PptxPartXml $part); layout = $lx.DocumentElement.SelectSingleNode("*[local-name()='cSld']").GetAttribute('name'); id = $sid.GetAttribute('id')
                notes = $(if ($notes) { (Read-PptxPartXml $notes).DocumentElement.InnerText } else { '' }); text = '' }
        }
    } finally { $pkg.Close() }
}

function Get-PackageProblems([string]$Path) {
    <# What would make PowerPoint repair a file: duplicate entries, relationships to missing parts,
       r:ids the part does not have, parts nothing points to, slide ids that repeat. #>
    $problems = New-Object Collections.Generic.List[string]
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try { $names = @($zip.Entries | ForEach-Object { $_.FullName.ToLowerInvariant() }); if ($names.Count -ne @($names | Select-Object -Unique).Count) { $problems.Add('duplicate zip entries') } } finally { $zip.Dispose() }
    $pkg = Open-PptxPackage $Path
    try {
        $reach = @{}; $queue = New-Object Collections.Generic.Queue[object]
        foreach ($r in @($pkg.GetRelationships())) { if ($r.TargetMode -eq 'Internal') { $u = [IO.Packaging.PackUriHelper]::ResolvePartUri((New-Object Uri('/', [UriKind]::Relative)), $r.TargetUri); if ($pkg.PartExists($u)) { $queue.Enqueue($pkg.GetPart($u)) } else { $problems.Add("package rel to missing $u") } } }
        while ($queue.Count) {
            $p = $queue.Dequeue(); $k = "$($p.Uri)".ToLowerInvariant(); if ($reach.ContainsKey($k)) { continue }; $reach[$k] = 1
            $ids = @{}
            foreach ($r in @($p.GetRelationships())) {
                $ids[$r.Id] = 1
                if ($r.TargetMode -ne 'Internal') { continue }
                $u = Get-PptxRelTarget $p $r
                if ($pkg.PartExists($u)) { $queue.Enqueue($pkg.GetPart($u)) } else { $problems.Add("$($p.Uri) -> missing $u") }
            }
            if ("$($p.ContentType)" -match 'xml$') {
                $x = Read-PptxPartXml $p
                foreach ($a in @($x.SelectNodes("//@*[namespace-uri()='http://schemas.openxmlformats.org/officeDocument/2006/relationships']"))) { if ($a.Value -and -not $ids.ContainsKey($a.Value)) { $problems.Add("$($p.Uri): r:$($a.LocalName)=$($a.Value) has no relationship") } }
            }
        }
        foreach ($p in @($pkg.GetParts())) { if ("$($p.Uri)" -notmatch '\.rels$' -and -not $reach.ContainsKey("$($p.Uri)".ToLowerInvariant())) { $problems.Add("orphan $($p.Uri)") } }
        $px = Read-PptxPartXml (Get-PptxPresentationPart $pkg)
        $ids = @($px.SelectNodes("//*[local-name()='sldId' and namespace-uri()='http://schemas.openxmlformats.org/presentationml/2006/main']") | ForEach-Object { $_.GetAttribute('id') })
        if ($ids.Count -ne @($ids | Select-Object -Unique).Count) { $problems.Add('slide ids repeat') }
        if (@($ids | Where-Object { [long]$_ -lt 256 }).Count) { $problems.Add('slide id below 256') }
    } finally { $pkg.Close() }
    $problems.ToArray()
}

function Get-FileHashText([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) } finally { $sha.Dispose() }
}

function Get-ShapeById($Xml, [int]$Id) {
    $Xml.SelectSingleNode("//*[local-name()='cNvPr' and @id='$Id']").ParentNode.ParentNode
}
