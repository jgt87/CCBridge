# PowerPoint decks for "Apply a PowerPoint template" (PptxRetheme.psm1): reading a deck's slides and
# layouts with System.IO.Packaging (WindowsBase, part of Windows; no Office), and the fixed rules that
# propose a template layout per content slide: the same layout name, the same layout type, the same
# purpose (from the type or the name, after Retheme's infer_purpose), then the layout whose
# placeholders fit the slide best. Where the rules are not sure the slide is marked "check" for the
# person. On request Copilot can propose the mapping instead: New-PptxMappingAsk sends only the
# structure (shape kinds, placeholders, text boxes with their place and first 60 characters), and
# Read-PptxMappingAnswer checks its JSON (unknown layout names and shape ids are refused).
# ASCII only (Windows PowerShell 5.1).

Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

$script:NsP = 'http://schemas.openxmlformats.org/presentationml/2006/main'
$script:NsA = 'http://schemas.openxmlformats.org/drawingml/2006/main'
$script:NsRel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:NsMc = 'http://schemas.openxmlformats.org/markup-compatibility/2006'
$script:OfficeDocType = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument'
$script:HeadingMinSize = 2000   # runs of 20 pt or more in a plain text box count as a heading (Retheme)
$script:LabelKind = @{ picture = 'pic'; table = 'tbl'; diagram = 'dgm'; chart = 'chart' }

# p:sldLayout/@type -> purpose (Retheme's LAYOUT_TYPE_PURPOSE). 'cust' and no type fall back to the name.
$script:TypePurpose = @{
    title = 'Title Slide'; tx = 'Title and Content'; obj = 'Title and Content'; twoObj = 'Two Content'
    twoTxTwoObj = 'Comparison'; secHead = 'Section Header'; titleOnly = 'Title Only'; blank = 'Blank'
    objTx = 'Content with Caption'; picTx = 'Picture with Caption'; vertTx = 'Vertical Text'
    vertTitleAndTx = 'Vertical Title and Text'; objOnly = 'Title and Content'; txAndObj = 'Two Content'
    objAndTx = 'Two Content'; twoColTx = 'Two Content'
}

# Layout names -> purpose, English and Dutch, the more specific first ("Title Only" before "Title").
$script:NameHints = @(
    @('title only|alleen titel|titel alleen|heading only', 'Title Only'),
    @('section|chapter|divider|hoofdstuk|sectiekop|tussenblad|sectie', 'Section Header'),
    @('comparison|vergelijk', 'Comparison'),
    @('\btwo\b|\b2\s*(content|column|col)|twee|\b2\s*kolom', 'Two Content'),
    @('(picture|photo|image|afbeelding|foto).*(caption|bijschrift)', 'Picture with Caption'),
    @('caption|bijschrift', 'Content with Caption'),
    @('photo|picture|image|foto|afbeelding|beeld', 'Picture Layout'),
    @('agenda|\btoc\b|table of contents|\bcontents\b|inhoudsopgave', 'Agenda / Table of Contents'),
    @('quote|citaat', 'Quote'),
    @('thank|closing|\bend\b|afsluit|bedankt|einde|contact', 'Closing Slide'),
    @('blank|empty|leeg', 'Blank'),
    @('title slide|titeldia|cover|voorblad|front|opening|title page|titelpagina|^title$|^titel$', 'Title Slide'),
    @('title and|titel en|content|object|text|tekst|inhoud|bullet', 'Title and Content')
)

# Purposes that can stand in for each other when the template has no layout of the slide's own purpose.
$script:PurposeAlias = @{
    'Title Slide' = @('Closing Slide', 'Section Header'); 'Closing Slide' = @('Title Slide', 'Section Header')
    'Title and Content' = @('General Content', 'Agenda / Table of Contents', 'Content with Caption')
    'General Content' = @('Title and Content'); 'Agenda / Table of Contents' = @('Title and Content')
    'Two Content' = @('Comparison'); 'Comparison' = @('Two Content')
    'Picture Layout' = @('Picture with Caption', 'Content with Caption'); 'Picture with Caption' = @('Picture Layout', 'Content with Caption')
    'Content with Caption' = @('Picture with Caption', 'Two Content'); 'Quote' = @('Section Header', 'Title Only')
    'Section Header' = @('Title Slide', 'Title Only'); 'Title Only' = @('Section Header')
}

# --------------------------------------------------------------------------- package helpers

function Open-PptxPackage {
    <# A deck read into memory and opened read-only, so a deck open in PowerPoint or a OneDrive file
       is never locked or changed. Close it with .Close(). #>
    param([Parameter(Mandatory)][string]$Path)
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms) } finally { $fs.Dispose() }
    $ms.Position = 0
    [IO.Packaging.Package]::Open($ms, [IO.FileMode]::Open, [IO.FileAccess]::Read)
}

function Get-PptxNs {
    # The comma: a namespace manager is enumerable and would unroll on return.
    param([Parameter(Mandatory)][Xml.XmlDocument]$Xml)
    $n = New-Object Xml.XmlNamespaceManager $Xml.NameTable
    $n.AddNamespace('p', $script:NsP); $n.AddNamespace('a', $script:NsA); $n.AddNamespace('r', $script:NsRel); $n.AddNamespace('mc', $script:NsMc)
    return , $n
}

function Read-PptxPartXml($Part) {
    $s = $Part.GetStream([IO.FileMode]::Open, [IO.FileAccess]::Read)
    try { $x = New-Object Xml.XmlDocument; $x.PreserveWhitespace = $true; $x.Load($s); return , $x } finally { $s.Dispose() }
}

function Write-PptxPartXml($Part, [Xml.XmlDocument]$Xml) {
    $s = $Part.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write)
    try { $Xml.Save($s) } finally { $s.Dispose() }
}

function Get-PptxRelTarget($Part, $Rel) {
    # The part URI a relationship points to (internal relationships only).
    [IO.Packaging.PackUriHelper]::ResolvePartUri($Part.Uri, $Rel.TargetUri)
}

function Get-PptxRelKind($Rel) { ("$($Rel.RelationshipType)" -split '/')[-1] }

function Get-PptxRelatedPart($Package, $Part, [string]$Kind) {
    # The first internal part of a relationship kind (slideLayout, theme, notesSlide...), or $null.
    foreach ($rel in $Part.GetRelationships()) {
        if ($rel.TargetMode -ne [IO.Packaging.TargetMode]::Internal -or (Get-PptxRelKind $rel) -ne $Kind) { continue }
        $u = Get-PptxRelTarget $Part $rel
        if ($Package.PartExists($u)) { return $Package.GetPart($u) }
    }
    $null
}

function Get-PptxPresentationPart($Package) {
    $rel = @($Package.GetRelationshipsByType($script:OfficeDocType))[0]
    if (-not $rel) { throw 'This file is not a PowerPoint deck (no presentation part).' }
    $Package.GetPart([IO.Packaging.PackUriHelper]::ResolvePartUri((New-Object Uri('/', [UriKind]::Relative)), $rel.TargetUri))
}

function Get-PptxShapeXfrm($Shape, $Ns) {
    # The transform of a shape tree item: spPr (sp, pic, cxnSp), grpSpPr (group), p:xfrm (graphic frame).
    switch ($Shape.LocalName) {
        'graphicFrame' { return $Shape.SelectSingleNode('p:xfrm', $Ns) }
        'grpSp' { return $Shape.SelectSingleNode('p:grpSpPr/a:xfrm', $Ns) }
        default { return $Shape.SelectSingleNode('p:spPr/a:xfrm', $Ns) }
    }
}

function Get-PptxRect($Xfrm) {
    if (-not $Xfrm) { return $null }
    $off = $Xfrm.SelectSingleNode("*[local-name()='off']"); $ext = $Xfrm.SelectSingleNode("*[local-name()='ext']")
    if (-not $off -or -not $ext) { return $null }
    @{ x = [long]$off.GetAttribute('x'); y = [long]$off.GetAttribute('y'); cx = [long]$ext.GetAttribute('cx'); cy = [long]$ext.GetAttribute('cy') }
}

function Get-PptxPhKind([string]$Type) {
    # Placeholder type -> the kind slots are matched by. No type means obj (content).
    if ($Type -in 'title', 'ctrTitle') { return 'title' }
    if ($Type -eq 'subTitle') { return 'subtitle' }
    if ($Type -in 'dt', 'ftr', 'sldNum', 'hdr') { return 'footer' }
    if ($Type -in 'pic', 'chart', 'tbl', 'dgm', 'media', 'clipArt') { return $Type }
    'content'
}

function Get-PptxPh($Shape, $Ns) {
    # @{ el; type; idx; kind } of a shape's placeholder, or $null for a free shape.
    $ph = $Shape.SelectSingleNode('./*/p:nvPr/p:ph', $Ns)
    if (-not $ph) { return $null }
    $t = $ph.GetAttribute('type')
    @{ el = $ph; type = $t; idx = $ph.GetAttribute('idx'); kind = (Get-PptxPhKind $t) }
}

function Get-PptxText($Node, $Ns) {
    if (-not $Node) { return '' }
    $parts = foreach ($t in $Node.SelectNodes('.//a:t', $Ns)) { $t.InnerText }
    (($parts -join ' ') -replace '\s+', ' ').Trim()
}

function Get-PptxTreeItems($SpTree, $Ns) {
    # The shape tree's top-level items, with an mc:AlternateContent read as its first choice.
    foreach ($c in $SpTree.ChildNodes) {
        if ($c.NodeType -ne [Xml.XmlNodeType]::Element) { continue }
        if ($c.LocalName -in 'sp', 'pic', 'grpSp', 'graphicFrame', 'cxnSp', 'contentPart') { $c; continue }
        if ($c.LocalName -eq 'AlternateContent') {
            $first = $c.SelectSingleNode('mc:Choice/*|mc:Fallback/*', $Ns)
            if ($first) { $first }
        }
    }
}

function Get-LayoutPurpose {
    <# The purpose of a layout from its type, else its name (Retheme's infer_purpose, the name hints in a
       safer order and with Dutch names). #>
    param([string]$Type, [string]$Name)
    if ($Type -and $script:TypePurpose.ContainsKey($Type)) { return $script:TypePurpose[$Type] }
    $low = "$Name".ToLowerInvariant().Trim()
    foreach ($h in $script:NameHints) { if ($low -match $h[0]) { return $h[1] } }
    'General Content'
}

# --------------------------------------------------------------------------- reading a deck

function Get-PptxSlotRect($Slot, $MasterSlots) {
    # A layout placeholder's place, else the master's of the same type (title, body, footers).
    if ($Slot.rect) { return $Slot.rect }
    $want = if ($Slot.kind -eq 'title') { 'title' } elseif ($Slot.kind -eq 'footer') { $Slot.type } else { 'body' }
    foreach ($m in $MasterSlots) {
        $mt = if ($m.kind -eq 'title') { 'title' } elseif ($m.kind -eq 'footer') { $m.type } else { 'body' }
        if ($mt -eq $want -and $m.rect) { return $m.rect }
    }
    $null
}

function Read-PptxSlots($Xml, $Ns) {
    $out = New-Object Collections.Generic.List[object]
    foreach ($sp in @(Get-PptxTreeItems $Xml.SelectSingleNode('/*/p:cSld/p:spTree', $Ns) $Ns)) {
        $ph = Get-PptxPh $sp $Ns
        if (-not $ph) { continue }
        $out.Add(@{ kind = $ph.kind; type = $ph.type; idx = $ph.idx; rect = (Get-PptxRect (Get-PptxShapeXfrm $sp $Ns)) })
    }
    $out.ToArray()
}

function Read-PptxLayouts {
    <# Every layout of every master, in the masters' order: @{ name; type; purpose; uri; master;
       slots = @(@{ kind; type; idx; rect }) } with each slot's place resolved through the master. #>
    param([Parameter(Mandatory)]$Package)
    $pres = Get-PptxPresentationPart $Package
    $px = Read-PptxPartXml $pres; $pns = Get-PptxNs $px
    $out = New-Object Collections.Generic.List[object]
    $mi = 0
    foreach ($mid in @($px.SelectNodes('/p:presentation/p:sldMasterIdLst/p:sldMasterId', $pns))) {
        $mi++
        $mpart = $Package.GetPart((Get-PptxRelTarget $pres $pres.GetRelationship($mid.GetAttribute('id', $script:NsRel))))
        $mx = Read-PptxPartXml $mpart; $mns = Get-PptxNs $mx
        $mslots = @(Read-PptxSlots $mx $mns)
        foreach ($lid in @($mx.SelectNodes('/p:sldMaster/p:sldLayoutIdLst/p:sldLayoutId', $mns))) {
            $lpart = $Package.GetPart((Get-PptxRelTarget $mpart $mpart.GetRelationship($lid.GetAttribute('id', $script:NsRel))))
            $lx = Read-PptxPartXml $lpart; $lns = Get-PptxNs $lx
            $slots = @(foreach ($s in @(Read-PptxSlots $lx $lns)) { $s.rect = Get-PptxSlotRect $s $mslots; $s })
            $type = $lx.DocumentElement.GetAttribute('type')
            $name = "$($lx.SelectSingleNode('/p:sldLayout/p:cSld', $lns).GetAttribute('name'))"
            $out.Add(@{ name = $name; type = $type; purpose = (Get-LayoutPurpose $type $name); uri = "$($lpart.Uri)"; master = $mi; slots = $slots })
        }
    }
    $out.ToArray()
}

function Test-PptxColouredFill($Shape, $Ns) {
    # A shape with a solid fill that reads as a coloured surface (Retheme _sp_fill_is_colored).
    $fill = $Shape.SelectSingleNode('p:spPr/a:solidFill', $Ns)
    if (-not $fill) { return $false }
    # A fill that is (nearly) see-through is no surface: generated decks give every text box one.
    $alpha = $fill.SelectSingleNode('*/a:alpha', $Ns)
    if ($alpha -and [int]$alpha.GetAttribute('val') -lt 20000) { return $false }
    $srgb = $fill.SelectSingleNode('a:srgbClr', $Ns)
    if ($srgb) {
        $v = $srgb.GetAttribute('val')
        if ($v.Length -ne 6) { return $false }
        $c = [Drawing.Color]::FromArgb([Convert]::ToInt32($v, 16))
        return ($c.GetBrightness() -lt 0.92)
    }
    $sc = $fill.SelectSingleNode('a:schemeClr', $Ns)
    [bool]($sc -and $sc.GetAttribute('val') -notin 'bg1', 'lt1')
}

function Test-PptxRectsMeet($A, $B) {
    -not ($A.x + $A.cx -le $B.x -or $B.x + $B.cx -le $A.x -or $A.y + $A.cy -le $B.y -or $B.y + $B.cy -le $A.y)
}

function Find-PptxHeadings {
    <# Plain text boxes (top level, no placeholder) with a run of 20 pt or more that are not on a
       coloured shape: @(@{ id; size; y; text }), largest first, then topmost (Retheme's primary
       heading). Text on a coloured shape belongs to that shape and is never a slide title. #>
    param([Parameter(Mandatory)][Xml.XmlDocument]$Xml, [Parameter(Mandatory)]$Ns)
    $tree = $Xml.SelectSingleNode('/p:sld/p:cSld/p:spTree', $Ns)
    if (-not $tree) { return @() }
    $items = @(Get-PptxTreeItems $tree $Ns | Where-Object { $_.LocalName -eq 'sp' })
    $coloured = @(foreach ($sp in $items) { if (Test-PptxColouredFill $sp $Ns) { $r = Get-PptxRect (Get-PptxShapeXfrm $sp $Ns); if ($r) { @{ sp = $sp; rect = $r } } } })
    $found = foreach ($sp in $items) {
        if (Get-PptxPh $sp $Ns) { continue }
        $text = Get-PptxText $sp $Ns
        if (-not $text) { continue }
        $max = 0
        foreach ($rp in $sp.SelectNodes('.//a:rPr[@sz]', $Ns)) { $v = [int]$rp.GetAttribute('sz'); if ($v -gt $max) { $max = $v } }
        if ($max -lt $script:HeadingMinSize) { continue }
        if (Test-PptxColouredFill $sp $Ns) { continue }
        $rect = Get-PptxRect (Get-PptxShapeXfrm $sp $Ns)
        if ($rect -and @($coloured | Where-Object { -not [object]::ReferenceEquals($_.sp, $sp) -and (Test-PptxRectsMeet $rect $_.rect) }).Count) { continue }
        @{ id = [int]$sp.SelectSingleNode('p:nvSpPr/p:cNvPr', $Ns).GetAttribute('id'); size = $max; y = $(if ($rect) { $rect.y } else { [long]::MaxValue }); text = $text }
    }
    @($found | Sort-Object @{ Expression = { $_.size }; Descending = $true }, @{ Expression = { $_.y } })
}

function Get-PptxShapeLabel($Shape, $Ph, $Ns) {
    # A shape's kind in plain words, for the card and for Copilot.
    if ($Ph) { return "$($Ph.kind) placeholder" }
    switch ($Shape.LocalName) {
        'pic' { return 'picture' }
        'grpSp' { return 'group' }
        'cxnSp' { return 'line' }
        'contentPart' { return 'ink' }
        'graphicFrame' {
            $uri = "$($Shape.SelectSingleNode('a:graphic/a:graphicData', $Ns).GetAttribute('uri'))"
            if ($uri -match '/table$') { return 'table' }
            if ($uri -match 'chart') { return 'chart' }
            if ($uri -match 'diagram') { return 'diagram' }
            return 'object'
        }
    }
    if ($Shape.SelectSingleNode('p:nvSpPr/p:cNvSpPr[@txBox="1"]', $Ns) -or ((Get-PptxText $Shape $Ns) -and -not $Shape.SelectSingleNode('p:spPr/a:solidFill|p:spPr/a:gradFill|p:spPr/a:blipFill', $Ns))) { return 'text box' }
    'shape'
}

function Get-PptxUsedKind($Shape, $Ph, $Ns) {
    # The kind a used placeholder needs a slot for: its own, or for a picture, table, chart or SmartArt in it, that.
    if ($Shape.LocalName -notin 'pic', 'graphicFrame') { return $Ph.kind }
    $k = $script:LabelKind[(Get-PptxShapeLabel $Shape $null $Ns)]
    if ($k) { $k } else { 'content' }
}

function Read-PptxSlideShape($Shape, $Ns, $Layout, $Size) {
    <# One top-level shape: the slot kind it needs when it is a used placeholder, its text when it is the
       title placeholder, and its box for the card and Copilot (id, kind, place in % of the slide, the
       first 60 characters). Footers have no box. #>
    $ph = Get-PptxPh $Shape $Ns
    $text = Get-PptxText $Shape $Ns
    $used = $text -or ($Shape.LocalName -ne 'sp')
    $out = @{ kind = ''; title = ''; box = $null }
    if ($ph -and $ph.kind -eq 'footer') { return $out }
    if ($ph -and $used) { $out.kind = Get-PptxUsedKind $Shape $ph $Ns; if ($ph.kind -eq 'title') { $out.title = $text } }
    $rect = Get-PptxRect (Get-PptxShapeXfrm $Shape $Ns)
    if (-not $rect -and $ph -and $Layout) {
        $slot = @($Layout.slots | Where-Object { ($ph.idx -and $_.idx -eq $ph.idx) -or (-not $ph.idx -and $_.kind -eq $ph.kind) })[0]
        if ($slot) { $rect = $slot.rect }
    }
    $pct = if ($rect -and $Size.cx -and $Size.cy) { @{ x = [int](100 * $rect.x / $Size.cx); y = [int](100 * $rect.y / $Size.cy); w = [int](100 * $rect.cx / $Size.cx); h = [int](100 * $rect.cy / $Size.cy) } } else { $null }
    $cnv = $Shape.SelectSingleNode('./*/p:cNvPr', $Ns)
    $out.box = @{ id = $(if ($cnv) { [int]$cnv.GetAttribute('id') } else { 0 }); kind = (Get-PptxShapeLabel $Shape $ph $Ns); free = (-not $ph); at = $pct; text = $(if ($text.Length -gt 60) { $text.Substring(0, 60) } else { $text }) }
    $out
}

function Read-PptxSlide($Package, $Part, [int]$Index, $LayoutsByUri, $Size) {
    # One slide: its layout, purpose, used placeholder kinds, heading boxes and shapes (in % of the slide).
    $x = Read-PptxPartXml $Part; $ns = Get-PptxNs $x
    $lay = Get-PptxRelatedPart $Package $Part 'slideLayout'
    $li = if ($lay) { $LayoutsByUri["$($lay.Uri)"] } else { $null }
    $kinds = New-Object Collections.Generic.List[string]
    $boxes = New-Object Collections.Generic.List[object]
    $titleText = ''
    foreach ($sp in @(Get-PptxTreeItems $x.SelectSingleNode('/p:sld/p:cSld/p:spTree', $ns) $ns)) {
        $r = Read-PptxSlideShape $sp $ns $li $Size
        if ($r.kind) { $kinds.Add($r.kind) }
        if ($r.title -and -not $titleText) { $titleText = $r.title }
        if ($r.box) { $boxes.Add($r.box) }
    }
    $heads = @(Find-PptxHeadings $x $ns)
    $hasTitle = $kinds -contains 'title'
    $type = if ($li) { $li.type } else { '' }; $lname = if ($li) { $li.name } else { '' }
    $purpose = Get-LayoutPurpose $type $lname
    # A slide that uses no placeholder at all (a deck of free text boxes) is what its shapes are, whatever
    # its layout is called: a heading box makes it a title-only slide, else it is blank.
    $free = -not $kinds.Count
    if ($free) { $purpose = if ($heads.Count) { 'Title Only' } else { 'Blank' } }
    if (-not $titleText) { $titleText = if ($heads.Count) { $heads[0].text } else { (@($boxes | Where-Object { $_.text }) | Select-Object -First 1).text } }
    @{
        index = $Index; uri = "$($Part.Uri)"; layoutName = $lname; layoutType = $type; purpose = $purpose; free = $free
        kinds = $kinds.ToArray(); hasTitle = $hasTitle
        heading = $(if (-not $hasTitle -and $heads.Count) { $heads[0].id } else { 0 }); headings = $(if ($hasTitle) { 0 } else { $heads.Count })
        title = "$titleText"; boxes = $boxes.ToArray()
        notes = [bool](Get-PptxRelatedPart $Package $Part 'notesSlide'); hidden = ($x.DocumentElement.GetAttribute('show') -eq '0')
    }
}

function Read-PptxDeck {
    <# A deck's slide size, layouts and slides (Read-PptxSlide), and whether it has a notes master. #>
    param([Parameter(Mandatory)][string]$Path)
    $pkg = Open-PptxPackage $Path
    try {
        $pres = Get-PptxPresentationPart $pkg
        $px = Read-PptxPartXml $pres; $pns = Get-PptxNs $px
        $sz = $px.SelectSingleNode('/p:presentation/p:sldSz', $pns)
        $size = @{ cx = $(if ($sz) { [long]$sz.GetAttribute('cx') } else { 9144000 }); cy = $(if ($sz) { [long]$sz.GetAttribute('cy') } else { 6858000 }) }
        $layouts = @(Read-PptxLayouts $pkg)
        $byUri = @{}; foreach ($l in $layouts) { $byUri[$l.uri] = $l }
        $slides = New-Object Collections.Generic.List[object]
        $i = 0
        foreach ($sid in @($px.SelectNodes('/p:presentation/p:sldIdLst/p:sldId', $pns))) {
            $i++
            $part = $pkg.GetPart((Get-PptxRelTarget $pres $pres.GetRelationship($sid.GetAttribute('id', $script:NsRel))))
            $slides.Add((Read-PptxSlide $pkg $part $i $byUri $size))
        }
        @{ path = $Path; size = $size; layouts = $layouts; slides = $slides.ToArray(); notesMaster = [bool](Get-PptxRelatedPart $pkg $pres 'notesMaster') }
    } finally { $pkg.Close() }
}

# --------------------------------------------------------------------------- choosing a layout

function Get-PptxSlotFit {
    <# How well a layout's placeholders hold a slide's used kinds: each kind takes a slot of its own kind,
       else (all but titles) a content slot, else a subtitle slot. Returns @{ score; fits; missing; extra }. #>
    param([string[]]$Kinds, $Slots)
    $free = @{}
    foreach ($s in @($Slots)) { if ($s.kind -eq 'footer') { continue }; $free[$s.kind] = 1 + [int]$free[$s.kind] }
    $covered = 0; $missing = 0
    foreach ($k in @($Kinds)) {
        $take = $null
        foreach ($c in @($k) + $(if ($k -ne 'title') { @('content', 'subtitle') } else { @() })) { if ([int]$free[$c] -gt 0) { $take = $c; break } }
        if ($take) { $free[$take] = [int]$free[$take] - 1; $covered++ } else { $missing++ }
    }
    $extra = 0; foreach ($v in $free.Values) { $extra += [int]$v }
    @{ score = ($covered * 10 - $missing * 12 - $extra * 3); fits = ($missing -eq 0); missing = $missing; extra = $extra }
}

function Select-PptxBestFit($Kinds, $Candidates) {
    # The candidate with the best fit (the first on a tie) and whether another one ties with it.
    $best = $null; $bestFit = $null; $tie = $false
    foreach ($c in @($Candidates)) {
        $f = Get-PptxSlotFit $Kinds $c.slots
        if (-not $best -or $f.score -gt $bestFit.score) { $best = $c; $bestFit = $f; $tie = $false }
        elseif ($f.score -eq $bestFit.score -and $c.name -ne $best.name) { $tie = $true }
    }
    @{ layout = $best; fit = $bestFit; tie = $tie }
}

function Select-PptxLayout {
    <# The template layout for one content slide (Read-PptxSlide) by fixed rules, first that applies:
       the same layout name, the same layout type, the same purpose, a purpose that can stand in, then
       the closest placeholders. Returns @{ layout; sure; why }: sure is false where the person should
       look (several layouts fit as well, the slide does not fit, several heading boxes). #>
    param([Parameter(Mandatory)]$Slide, [Parameter(Mandatory)]$Layouts)
    $kinds = @($Slide.kinds)
    if ($Slide.heading -and $kinds -notcontains 'title') { $kinds = @('title') + $kinds }
    $named = @{}; $all = @(foreach ($l in @($Layouts)) { if (-not $named.ContainsKey($l.name.ToLowerInvariant())) { $named[$l.name.ToLowerInvariant()] = 1; $l } })
    $doubt = ($Slide.headings -gt 1)
    # A slide of free shapes only: its layout's name and type say nothing about it.
    $own = -not $Slide.free
    $steps = @(
        @{ c = @($all | Where-Object { $own -and $Slide.layoutName -and $_.name.Trim() -eq "$($Slide.layoutName)".Trim() }); why = 'same layout name'; sure = $true },
        @{ c = @($all | Where-Object { $own -and $Slide.layoutType -and $Slide.layoutType -ne 'cust' -and $_.type -eq $Slide.layoutType }); why = 'same layout type'; sure = $true },
        @{ c = @($all | Where-Object { $Slide.purpose -ne 'General Content' -and $_.purpose -eq $Slide.purpose }); why = "same purpose: $($Slide.purpose)"; sure = $true },
        @{ c = @($all | Where-Object { $_.purpose -in @($script:PurposeAlias[$Slide.purpose]) }); why = "nearest purpose to $($Slide.purpose)"; sure = $false },
        @{ c = $all; why = 'closest placeholders'; sure = $false }
    )
    foreach ($s in $steps) {
        if (-not $s.c.Count) { continue }
        $b = Select-PptxBestFit $kinds $s.c
        # A name, type or purpose match that cannot hold the slide's content is no answer: go on.
        if ($s.sure -and -not $b.fit.fits) { continue }
        return @{ layout = $b.layout.name; sure = ($s.sure -and $b.fit.fits -and -not $b.tie -and -not $doubt); why = $s.why }
    }
    @{ layout = ''; sure = $false; why = 'the template has no layouts' }
}

# --------------------------------------------------------------------------- the decks of a project

function Get-PptxDecks {
    <# The PowerPoint files of a project (not lock files, build output or StreamHub's own folders):
       templates are .pptx and .potx, content decks .pptx; newest first, with a suggested pair. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = $ProjectRoot.TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.pptx, *.potx -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '~$*' -and $_.FullName.Substring($root.Length) -notmatch '\\(node_modules|\.git|\.streamhub|dist|build)\\' } |
        Sort-Object LastWriteTime -Descending)
    $rel = { param($f) $f.FullName.Substring($root.Length + 1).Replace('\', '/') }
    $templates = @($files | ForEach-Object { & $rel $_ })
    $contents = @($files | Where-Object { $_.Extension -eq '.pptx' } | ForEach-Object { & $rel $_ })
    $tpl = @($templates | Where-Object { $_ -match '\.potx$' }) + @($templates | Where-Object { $_ -match '(?i)template|sjabloon|huisstijl|brand|master' })
    $template = if ($tpl.Count) { $tpl[0] } elseif ($templates.Count) { $templates[-1] } else { '' }
    $content = @($contents | Where-Object { $_ -ne $template -and $_ -notmatch '-branded-' })[0]
    @{ templates = $templates; contents = $contents; template = $template; content = "$content" }
}

# --------------------------------------------------------------------------- asking Copilot

function Format-PptxSlotKinds($Slots) {
    $k = @($Slots | Where-Object { $_.kind -ne 'footer' } | ForEach-Object { $_.kind })
    if ($k.Count) { $k -join ', ' } else { 'no placeholders' }
}

function New-PptxMappingAsk {
    <# The message that asks Copilot which template layout each content slide should use, and which
       plain text box is the slide's title. Only the structure goes: shape kinds, placeholders, the
       place and size of each shape in % of the slide, and the first 60 characters of its text. #>
    param([Parameter(Mandatory)]$Content, [Parameter(Mandatory)]$Template)
    $sb = New-Object Text.StringBuilder
    $null = $sb.AppendLine('The helper program is putting the slides of a deck onto the slide layouts of a template. For each slide below, choose the template layout it should get, and, when the slide''s title is a plain text box (not a title placeholder), the id of that box.')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('Template layouts (name: placeholders):')
    $seen = @{}
    foreach ($l in @($Template.layouts)) {
        if ($seen.ContainsKey($l.name)) { continue }; $seen[$l.name] = 1
        $null = $sb.AppendLine("- ""$($l.name)"": $(Format-PptxSlotKinds $l.slots)")
    }
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('Slides (each shape: id, kind, place x,y and size w x h in % of the slide, the start of its text):')
    foreach ($s in @($Content.slides)) {
        $null = $sb.AppendLine("Slide $($s.index) (now on layout ""$($s.layoutName)""):")
        foreach ($b in @($s.boxes)) {
            $at = if ($b.at) { " at $($b.at.x),$($b.at.y) size $($b.at.w)x$($b.at.h)" } else { '' }
            $t = if ($b.text) { ': "' + ($b.text -replace '["\\]', "'") + '"' } else { '' }
            $null = $sb.AppendLine("  - id $($b.id), $($b.kind)$at$t")
        }
        if (-not @($s.boxes).Count) { $null = $sb.AppendLine('  - (empty)') }
    }
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('Answer with one ```json block and nothing else, in this form:')
    $null = $sb.AppendLine('{"slides": [{"slide": 1, "layout": "LAYOUT NAME", "title": ID_OR_NULL}]}')
    $null = $sb.AppendLine('Give every slide. Use only the layout names listed above, written exactly as there. "title" is the id of a text box from that slide that is its title, or null when the slide has a title placeholder or no title.')
    $sb.ToString().TrimEnd()
}

function Get-PptxJsonText([string]$Text) {
    # The JSON of a reply: the first ```json block, else the first code block or reply that is JSON.
    $m = [regex]::Match("$Text", '(?s)```+\s*json\s*\n(.*?)\n\s*```+')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    foreach ($b in [regex]::Matches("$Text", '(?s)```+[^\n]*\n(.*?)\n\s*```+')) { $c = $b.Groups[1].Value.Trim(); if ($c -match '^[\[{]') { return $c } }
    $t = "$Text".Trim(); if ($t -match '^[\[{]') { return $t }
    ''
}

function Read-PptxMappingAnswer {
    <# Copilot's mapping, checked: every slide number must be in the deck, every layout name one of the
       template's (case may differ; the template's spelling is kept) and every title id a plain text
       box of that slide. What fails is left out and named in errors. Returns @{ ok; map; errors } with
       map = @{ "N" = @{ layout; title } } (title 0 = none). #>
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)]$Content, [Parameter(Mandatory)]$Template)
    $errors = New-Object Collections.Generic.List[string]
    $map = @{}
    $json = Get-PptxJsonText $Text
    if (-not $json) { return @{ ok = $false; map = $map; errors = @('the answer has no JSON') } }
    try { $data = $json | ConvertFrom-Json } catch { return @{ ok = $false; map = $map; errors = @('the JSON does not parse') } }
    $items = @(if ($data -is [array]) { $data } else { $data.slides }) | Where-Object { $null -ne $_ }
    $names = @{}; foreach ($l in @($Template.layouts)) { if (-not $names.ContainsKey($l.name.ToLowerInvariant())) { $names[$l.name.ToLowerInvariant()] = $l.name } }
    $count = @($Content.slides).Count
    foreach ($it in $items) {
        $n = 0
        if (-not [int]::TryParse("$($it.slide)", [ref]$n) -or $n -lt 1 -or $n -gt $count) { $errors.Add("there is no slide $($it.slide)"); continue }
        $want = "$($it.layout)".Trim()
        if (-not $names.ContainsKey($want.ToLowerInvariant())) { $errors.Add("slide ${n}: the template has no layout named ""$want"""); continue }
        $title = 0
        if ($null -ne $it.title -and "$($it.title)".Trim() -and "$($it.title)" -ne 'null') {
            $slide = @($Content.slides)[$n - 1]
            $ids = @($slide.boxes | Where-Object { $_.free -and $_.text } | ForEach-Object { [int]$_.id })
            if (-not [int]::TryParse("$($it.title)", [ref]$title) -or $ids -notcontains $title) { $errors.Add("slide ${n}: no text box with id $($it.title)"); $title = 0 }
        }
        $map["$n"] = @{ layout = $names[$want.ToLowerInvariant()]; title = $title }
    }
    for ($i = 1; $i -le $count; $i++) { if (-not $map.ContainsKey("$i")) { $errors.Add("no layout for slide $i") } }
    @{ ok = ($map.Count -gt 0); map = $map; errors = $errors.ToArray() }
}

Export-ModuleMember -Function Open-PptxPackage, Get-PptxNs, Read-PptxPartXml, Write-PptxPartXml, Get-PptxRelTarget, Get-PptxRelKind, Get-PptxRelatedPart, Get-PptxPresentationPart, Get-PptxShapeXfrm, Get-PptxRect, Get-PptxPhKind, Get-PptxPh, Get-PptxText, Get-PptxTreeItems, Get-LayoutPurpose, Get-PptxSlotRect, Read-PptxLayouts, Find-PptxHeadings, Read-PptxDeck, Get-PptxSlotFit, Select-PptxLayout, Get-PptxDecks, New-PptxMappingAsk, Get-PptxJsonText, Read-PptxMappingAnswer
