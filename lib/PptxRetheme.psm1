# Apply a PowerPoint template to a content deck (on request only, from the command menu): every slide of
# the content deck is copied whole onto a layout of the template (a port of Retheme's whole-slide copy):
# pictures byte for byte, charts with their workbooks and style parts, tables, SmartArt, embedded
# objects, tags, hyperlinks and speaker notes. Each part keeps its relationship ids, so slide XML needs
# no rewrite. Placeholders take the layout's place (their own position removed, idx and type of the
# layout's placeholder of the same kind); a heading in a plain text box becomes the layout's title;
# direct formatting equal to the content deck's theme colours and fonts becomes the template's, other
# direct formatting stays unless "use the template's text styles" is on (then fonts and colours in
# placeholders go). A different slide size scales the free shapes uniformly and centres them. Between the
# template's chosen start and end slide; the template and the content deck are never changed.
# The layout per slide is proposed by PptxLayoutMatch.psm1 (Get-PptxRethemePlan).
# ASCII only (Windows PowerShell 5.1).

Import-Module (Join-Path $PSScriptRoot 'PptxLayoutMatch.psm1')
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.Drawing

$script:NsP = 'http://schemas.openxmlformats.org/presentationml/2006/main'
$script:NsA = 'http://schemas.openxmlformats.org/drawingml/2006/main'
$script:NsRel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:RelBase = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:ThemeSlots = @('dk1', 'lt1', 'dk2', 'lt2', 'accent1', 'accent2', 'accent3', 'accent4', 'accent5', 'accent6')
# Relationships a copied part never takes along: wired by the caller (layout, notes) or left out
# (comments need the deck's author list; masters belong to the template).
$script:SkipRelKinds = @('slideLayout', 'slideMaster', 'notesMaster', 'notesSlide', 'handoutMaster', 'comments', 'commentAuthors', 'authors')
$script:LinkElements = @('hlinkClick', 'hlinkHover', 'hlinkMouseOver')

# --------------------------------------------------------------------------- the plan

function Format-PptxSize($Size) { '{0:0.##} x {1:0.##} in' -f ($Size.cx / 914400), ($Size.cy / 914400) }

function Get-PptxScale($From, $To) {
    # Uniform factor and offsets that fit a slide of size From onto To, centred: @{ f; ox; oy }.
    # [double] both: an exact long division gives an int, and Min(int, double) would round the double.
    $f = [Math]::Min([double]$To.cx / [double]$From.cx, [double]$To.cy / [double]$From.cy)
    @{ f = $f; ox = [long][Math]::Round(($To.cx - $From.cx * $f) / 2); oy = [long][Math]::Round(($To.cy - $From.cy * $f) / 2) }
}

function Get-PptxRethemePlan {
    <# What applying TemplatePath to ContentPath would do, for the card: per content slide the proposed
       template layout (sure or "check"), the template's slides for start and end (first and last by
       default), the template's layout names, and notes on slide size and speaker notes. #>
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][string]$ContentPath, [string]$Template = '', [string]$Content = '')
    $t = Read-PptxDeck $TemplatePath
    $c = Read-PptxDeck $ContentPath
    $names = New-Object Collections.Generic.List[string]
    foreach ($l in @($t.layouts)) { if (-not $names.Contains($l.name)) { $names.Add($l.name) } }
    $slides = @(foreach ($s in @($c.slides)) {
            $pick = Select-PptxLayout $s $t.layouts
            @{ index = $s.index; title = $s.title; layout = $pick.layout; sure = $pick.sure; why = $pick.why; heading = $s.heading; hidden = $s.hidden; notes = $s.notes; from = $s.layoutName }
        })
    $notes = New-Object Collections.Generic.List[string]
    if ($t.size.cx -ne $c.size.cx -or $t.size.cy -ne $c.size.cy) {
        $sc = Get-PptxScale $c.size $t.size
        $notes.Add("The content deck is $(Format-PptxSize $c.size) and the template $(Format-PptxSize $t.size): shapes outside placeholders are scaled by $('{0:0.##}' -f $sc.f) and centred.")
    }
    if (-not $t.notesMaster -and @($c.slides | Where-Object { $_.notes }).Count) { $notes.Add('The template has no notes page, so the speaker notes keep the content deck''s notes page.') }
    $count = @($t.slides).Count
    @{
        template = $Template; content = $Content; layouts = $names.ToArray(); slides = $slides
        templateSlides = @(foreach ($s in @($t.slides)) { @{ index = $s.index; title = $s.title } })
        start = $(if ($count -ge 1) { 1 } else { 0 }); end = $(if ($count -ge 2) { $count } else { 0 })
        notes = $notes.ToArray()
    }
}

function Merge-PptxMapping {
    <# Copilot's checked mapping (Read-PptxMappingAnswer) into a plan: those slides take its layout and
       title box and are no longer marked "check"; the rest keep the rule's choice. #>
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Answer)
    foreach ($s in @($Plan.slides)) {
        $m = $Answer.map["$($s.index)"]
        if (-not $m) { continue }
        $s.layout = $m.layout; $s.sure = $true; $s.why = 'Copilot'
        if ($m.title) { $s.heading = $m.title }
    }
    $Plan.copilot = $true; $Plan.errors = @($Answer.errors)
    $Plan
}

function ConvertTo-PptxChoices {
    <# The card's choices as they arrive from JSON (objects) into the hashtables Invoke-PptxRetheme
       takes: @{ layouts = @{ "N" = name }; titles = @{ "N" = id }; start; end; templateStyles;
       keepBackgrounds }. Fields it does not know are kept as they are, for later steps. #>
    param($Choices)
    $out = @{}
    if (-not $Choices) { return $out }
    $props = if ($Choices -is [hashtable]) { $Choices.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = $_.Value } } } else { $Choices.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } } }
    foreach ($p in @($props)) {
        $v = $p.Value
        if ($p.Name -in 'layouts', 'titles') {
            $h = @{}
            $pairs = if ($v -is [hashtable]) { $v.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = $_.Value } } } elseif ($v) { $v.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } } } else { @() }
            foreach ($q in @($pairs)) { if ("$($q.Name)" -match '^\d+$') { $h["$($q.Name)"] = $(if ($p.Name -eq 'titles') { [int]$q.Value } else { "$($q.Value)" }) } }
            $out[$p.Name] = $h
        } elseif ($p.Name -in 'start', 'end') { $out[$p.Name] = [int]$v }
        elseif ($p.Name -in 'templateStyles', 'keepBackgrounds') { $out[$p.Name] = [bool]$v }
        else { $out[$p.Name] = $v }
    }
    $out
}

function Get-PptxBrandedName {
    # Runbooks/Exports/NAME-branded-yyyyMMdd-HHmm.pptx; with ProjectRoot -2, -3... when that file is there.
    param([Parameter(Mandatory)][string]$Content, [datetime]$Now = (Get-Date), [string]$ProjectRoot = '')
    $base = "Runbooks/Exports/$([IO.Path]::GetFileNameWithoutExtension($Content) -replace '[^\w.-]+', '-')-branded-$($Now.ToString('yyyyMMdd-HHmm'))"
    $name = "$base.pptx"; $n = 1
    while ($ProjectRoot -and (Test-Path -LiteralPath (Join-Path $ProjectRoot $name.Replace('/', '\')))) { $n++; $name = "$base-$n.pptx" }
    $name
}

# --------------------------------------------------------------------------- package work

function Read-PptxPartBytes($Part) {
    $s = $Part.GetStream([IO.FileMode]::Open, [IO.FileAccess]::Read)
    try { $ms = New-Object IO.MemoryStream; $s.CopyTo($ms); return , $ms.ToArray() } finally { $s.Dispose() }
}

function Get-PptxFreeUri($Ctx, [string]$Want) {
    # /ppt/media/image3.png -> the first free /ppt/media/imageN.png (a cursor per name, Retheme's allocator).
    $m = [regex]::Match($Want, '^(.*?)(\d*)(\.[^./]+)$')
    $prefix = $m.Groups[1].Value; $ext = $m.Groups[3].Value; $key = "$prefix|$ext".ToLowerInvariant()
    $n = if ($Ctx.next.ContainsKey($key)) { $Ctx.next[$key] } else { 1 }
    while ($Ctx.dst.PartExists((New-Object Uri("$prefix$n$ext", [UriKind]::Relative)))) { $n++ }
    $Ctx.next[$key] = $n + 1
    New-Object Uri("$prefix$n$ext", [UriKind]::Relative)
}

function New-PptxRel($From, $ToPart, [string]$Type, [string]$Id) {
    $rel = [IO.Packaging.PackUriHelper]::GetRelativeUri($From.Uri, $ToPart.Uri)
    if ($Id) { $From.CreateRelationship($rel, [IO.Packaging.TargetMode]::Internal, $Type, $Id) } else { $From.CreateRelationship($rel, [IO.Packaging.TargetMode]::Internal, $Type) }
}

function Copy-PptxPartTree {
    <# A part of the content deck and everything it points to, into the output, with the same
       relationship ids. A part copied before is reused, and identical binaries (one picture on three
       slides) are stored once. Links to other slides are kept in Ctx.links for later (the target slide
       may not be copied yet); the kinds in SkipRelKinds and Skip are not followed. #>
    param($Ctx, $SrcPart, [string[]]$Skip = @())
    $key = "$($SrcPart.Uri)"
    if ($Ctx.cloned.ContainsKey($key)) { return $Ctx.cloned[$key] }
    $bytes = Read-PptxPartBytes $SrcPart
    $isXml = "$($SrcPart.ContentType)" -match 'xml$'
    $hash = $null
    if (-not $isXml) {
        $sha = [Security.Cryptography.SHA1]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
        if ($Ctx.byHash.ContainsKey($hash)) { $Ctx.cloned[$key] = $Ctx.byHash[$hash]; return $Ctx.byHash[$hash] }
    }
    $new = $Ctx.dst.CreatePart((Get-PptxFreeUri $Ctx $key), $SrcPart.ContentType, [IO.Packaging.CompressionOption]::Normal)
    $o = $new.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write)
    try { $o.Write($bytes, 0, $bytes.Length) } finally { $o.Dispose() }
    $Ctx.cloned[$key] = $new
    if ($hash) { $Ctx.byHash[$hash] = $new }
    if ($isXml) { $Ctx.created.Add($new) }
    foreach ($rel in @($SrcPart.GetRelationships())) {
        if ($rel.TargetMode -eq [IO.Packaging.TargetMode]::External) { $null = $new.CreateRelationship($rel.TargetUri, $rel.TargetMode, $rel.RelationshipType, $rel.Id); continue }
        $kind = Get-PptxRelKind $rel
        if ($kind -in $script:SkipRelKinds -or $kind -in $Skip) { continue }
        $target = Get-PptxRelTarget $SrcPart $rel
        if ($kind -eq 'slide') { $Ctx.links.Add(@{ part = $new; id = $rel.Id; type = $rel.RelationshipType; target = "$target" }); continue }
        if (-not $Ctx.src.PartExists($target)) { continue }
        $child = Copy-PptxPartTree $Ctx ($Ctx.src.GetPart($target))
        $null = New-PptxRel $new $child $rel.RelationshipType $rel.Id
    }
    $new
}

function Remove-PptxBrokenRefs($Part, [Xml.XmlDocument]$Xml) {
    # Relationship ids the XML names that the part no longer has: a hyperlink element goes, any other
    # attribute is dropped, so PowerPoint never meets a dangling r:id.
    $ids = @{}; foreach ($r in @($Part.GetRelationships())) { $ids[$r.Id] = 1 }
    $n = 0
    foreach ($a in @($Xml.SelectNodes("//@*[namespace-uri()='$script:NsRel']"))) {
        if (-not $a.Value -or $ids.ContainsKey($a.Value)) { continue }
        $el = $a.OwnerElement
        if ($el.LocalName -in $script:LinkElements) { $null = $el.ParentNode.RemoveChild($el) } else { $null = $el.Attributes.Remove($a) }
        $n++
    }
    $n
}

function Remove-PptxDanglingRels($Package) {
    # Relationships to parts that are gone (a template slide removed), with their uses in the XML.
    foreach ($part in @($Package.GetParts())) {
        if ("$($part.Uri)" -match '\.rels$') { continue }
        $gone = @(foreach ($rel in @($part.GetRelationships())) {
                if ($rel.TargetMode -ne [IO.Packaging.TargetMode]::Internal) { continue }
                if (-not $Package.PartExists((Get-PptxRelTarget $part $rel))) { $rel.Id }
            })
        if (-not $gone.Count) { continue }
        foreach ($id in $gone) { $part.DeleteRelationship($id) }
        if ("$($part.ContentType)" -match 'xml$') { $x = Read-PptxPartXml $part; if (Remove-PptxBrokenRefs $part $x) { Write-PptxPartXml $part $x } }
    }
}

function Remove-PptxOrphanParts($Package) {
    # Parts nothing points to any more (the removed template slides' pictures and notes): deleted, so
    # the output carries no dead weight. Returns how many.
    $seen = @{}
    $queue = New-Object Collections.Generic.Queue[object]
    foreach ($rel in @($Package.GetRelationships())) {
        if ($rel.TargetMode -ne [IO.Packaging.TargetMode]::Internal) { continue }
        $u = [IO.Packaging.PackUriHelper]::ResolvePartUri((New-Object Uri('/', [UriKind]::Relative)), $rel.TargetUri)
        if ($Package.PartExists($u)) { $queue.Enqueue($Package.GetPart($u)) }
    }
    while ($queue.Count) {
        $p = $queue.Dequeue(); $k = "$($p.Uri)".ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = 1
        foreach ($rel in @($p.GetRelationships())) {
            if ($rel.TargetMode -ne [IO.Packaging.TargetMode]::Internal) { continue }
            $u = Get-PptxRelTarget $p $rel
            if ($Package.PartExists($u)) { $queue.Enqueue($Package.GetPart($u)) }
        }
    }
    $n = 0
    foreach ($p in @($Package.GetParts())) {
        $u = "$($p.Uri)"
        if ($u -match '\.rels$' -or $seen.ContainsKey($u.ToLowerInvariant())) { continue }
        $Package.DeletePart($p.Uri); $n++
    }
    $n
}

function Repair-PptxMainType([string]$Path) {
    # A .potx (or .ppsx) template saved as a .pptx: the main part's content type becomes a presentation's.
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $e = $zip.GetEntry('[Content_Types].xml')
        if (-not $e) { return }
        $r = New-Object IO.StreamReader($e.Open()); try { $text = $r.ReadToEnd() } finally { $r.Dispose() }
        $fixed = $text -replace 'presentationml\.(template|slideshow)\.main\+xml', 'presentationml.presentation.main+xml'
        if ($fixed -eq $text) { return }
        $e.Delete()
        $w = New-Object IO.StreamWriter(($zip.CreateEntry('[Content_Types].xml')).Open(), (New-Object Text.UTF8Encoding($false)))
        try { $w.Write($fixed) } finally { $w.Dispose() }
    } finally { $zip.Dispose(); $fs.Dispose() }
}

# --------------------------------------------------------------------------- themes and restyling

function Read-PptxThemes($Package) {
    # One @{ colors = @{ slot = HEX }; fonts = @{ major; minor } } per slide master, in order.
    $pres = Get-PptxPresentationPart $Package
    $px = Read-PptxPartXml $pres; $pns = Get-PptxNs $px
    foreach ($mid in @($px.SelectNodes('/p:presentation/p:sldMasterIdLst/p:sldMasterId', $pns))) {
        $m = $Package.GetPart((Get-PptxRelTarget $pres $pres.GetRelationship($mid.GetAttribute('id', $script:NsRel))))
        $t = Get-PptxRelatedPart $Package $m 'theme'
        $colors = @{}; $fonts = @{}
        if ($t) {
            $tx = Read-PptxPartXml $t; $tns = Get-PptxNs $tx
            foreach ($slot in $script:ThemeSlots) {
                $el = $tx.SelectSingleNode("//a:clrScheme/a:$slot", $tns)
                if (-not $el) { continue }
                $srgb = $el.SelectSingleNode('a:srgbClr', $tns); $sys = $el.SelectSingleNode('a:sysClr', $tns)
                $v = if ($srgb) { $srgb.GetAttribute('val') } elseif ($sys) { $sys.GetAttribute('lastClr') } else { '' }
                if ($v) { $colors[$slot] = $v.ToUpperInvariant() }
            }
            foreach ($k in 'major', 'minor') { $f = $tx.SelectSingleNode("//a:fontScheme/a:${k}Font/a:latin", $tns); if ($f -and $f.GetAttribute('typeface')) { $fonts[$k] = $f.GetAttribute('typeface') } }
        }
        @{ colors = $colors; fonts = $fonts }
    }
}

function Get-PptxThemeMaps {
    <# Retheme's maps: every content master's theme colour and font, by slot, to the template's (first
       master). The first source master wins when two give the same colour. #>
    param($SourceThemes, $TemplateTheme)
    $colors = @{}; $fonts = @{}
    foreach ($st in @($SourceThemes)) {
        foreach ($slot in $script:ThemeSlots) {
            $a = $st.colors[$slot]; $b = $TemplateTheme.colors[$slot]
            if ($a -and $b -and -not $colors.ContainsKey($a)) { $colors[$a] = $b }
        }
        foreach ($k in 'major', 'minor') {
            $a = $st.fonts[$k]; $b = $TemplateTheme.fonts[$k]
            if ($a -and $b -and -not $fonts.ContainsKey($a)) { $fonts[$a] = $b }
        }
    }
    @{ colors = $colors; fonts = $fonts }
}

function Set-PptxRestyle {
    <# Direct formatting equal to the content deck's theme becomes the template's, in place: srgbClr
       values and latin/ea/cs typefaces. Positions are never touched. Returns how many changed. #>
    param([Parameter(Mandatory)]$Node, [hashtable]$Colors = @{}, [hashtable]$Fonts = @{})
    $n = 0
    foreach ($el in @($Node.SelectNodes(".//*[local-name()='srgbClr' and namespace-uri()='$script:NsA']"))) {
        $v = $el.GetAttribute('val').ToUpperInvariant()
        if ($Colors.ContainsKey($v) -and $Colors[$v] -ne $v) { $el.SetAttribute('val', $Colors[$v]); $n++ }
    }
    if ($Fonts.Count) {
        foreach ($el in @($Node.SelectNodes(".//*[(local-name()='latin' or local-name()='ea' or local-name()='cs') and namespace-uri()='$script:NsA']"))) {
            $f = $el.GetAttribute('typeface')
            if ($Fonts.ContainsKey($f) -and $Fonts[$f] -ne $f) { $el.SetAttribute('typeface', $Fonts[$f]); $n++ }
        }
    }
    $n
}

function Remove-PptxRunStyle($Node, $Ns, [switch]$Size, [switch]$FontsAndColours) {
    # Direct run formatting in a shape: sizes (and autofit shrinking), or typefaces and fills.
    foreach ($rp in @($Node.SelectNodes('.//a:rPr|.//a:endParaRPr|.//a:defRPr', $Ns))) {
        if ($Size -and $rp.HasAttribute('sz')) { $rp.RemoveAttribute('sz') }
        if ($FontsAndColours) { foreach ($c in @($rp.SelectNodes('a:latin|a:ea|a:cs|a:solidFill|a:gradFill|a:pattFill', $Ns))) { $null = $rp.RemoveChild($c) } }
    }
    if ($Size) { foreach ($af in @($Node.SelectNodes('.//a:normAutofit', $Ns))) { $af.RemoveAttribute('fontScale'); $af.RemoveAttribute('lnSpcReduction') } }
}

# --------------------------------------------------------------------------- one slide

function Set-PptxXfrm($Shape, $Ns, $Rect) {
    # Gives a shape this place and size, making its transform when it has none.
    $xf = Get-PptxShapeXfrm $Shape $Ns
    $doc = $Shape.OwnerDocument
    if (-not $xf) {
        $pr = $Shape.SelectSingleNode('p:spPr|p:grpSpPr', $Ns)
        if (-not $pr) { return }
        $xf = $doc.CreateElement('a', 'xfrm', $script:NsA)
        $null = $pr.PrependChild($xf)
    }
    $off = $xf.SelectSingleNode('a:off', $Ns); $ext = $xf.SelectSingleNode('a:ext', $Ns)
    if (-not $off) { $off = $doc.CreateElement('a', 'off', $script:NsA); $null = $xf.PrependChild($off) }
    if (-not $ext) { $ext = $doc.CreateElement('a', 'ext', $script:NsA); $null = $xf.InsertAfter($ext, $off) }
    $off.SetAttribute('x', [string]$Rect.x); $off.SetAttribute('y', [string]$Rect.y)
    $ext.SetAttribute('cx', [string]$Rect.cx); $ext.SetAttribute('cy', [string]$Rect.cy)
}

function Move-PptxShape($Shape, $Ns, $Scale) {
    # One free shape onto the new slide: place and size scaled and centred; a table's columns and rows
    # and, when the slide gets smaller, the text sizes scale with it. A group's own child space stays.
    $rect = Get-PptxRect (Get-PptxShapeXfrm $Shape $Ns)
    if ($rect) {
        Set-PptxXfrm $Shape $Ns @{ x = [long][Math]::Round($rect.x * $Scale.f + $Scale.ox); y = [long][Math]::Round($rect.y * $Scale.f + $Scale.oy); cx = [long][Math]::Round($rect.cx * $Scale.f); cy = [long][Math]::Round($rect.cy * $Scale.f) }
    }
    if ([Math]::Abs($Scale.f - 1) -lt 0.001) { return }
    foreach ($g in @($Shape.SelectNodes('.//a:tbl/a:tblGrid/a:gridCol[@w]', $Ns))) { $g.SetAttribute('w', [string][long][Math]::Round([long]$g.GetAttribute('w') * $Scale.f)) }
    foreach ($tr in @($Shape.SelectNodes('.//a:tbl/a:tr[@h]', $Ns))) { $tr.SetAttribute('h', [string][long][Math]::Round([long]$tr.GetAttribute('h') * $Scale.f)) }
    if ($Scale.f -lt 0.98) {
        foreach ($rp in @($Shape.SelectNodes('.//a:rPr[@sz]|.//a:endParaRPr[@sz]|.//a:defRPr[@sz]', $Ns))) { $rp.SetAttribute('sz', [string][Math]::Max(100, [int][Math]::Round([int]$rp.GetAttribute('sz') * $Scale.f))) }
    }
}

function Remove-PptxTreeItem($Shape) {
    # A shape tree item, with the mc:AlternateContent that holds it.
    $target = $Shape
    if ($Shape.ParentNode -and $Shape.ParentNode.LocalName -in 'Choice', 'Fallback') { $target = $Shape.ParentNode.ParentNode }
    $null = $target.ParentNode.RemoveChild($target)
}

function ConvertTo-PptxTitle($Shape, $Ns) {
    <# A heading in a plain text box becomes the slide's title placeholder: no own place, fill, box
       settings or run size, font, colour or alignment, so the layout's title style applies. #>
    $doc = $Shape.OwnerDocument
    $nvPr = $Shape.SelectSingleNode('p:nvSpPr/p:nvPr', $Ns)
    $ph = $doc.CreateElement('p', 'ph', $script:NsP); $ph.SetAttribute('type', 'title')
    $null = $nvPr.PrependChild($ph)
    $cnv = $Shape.SelectSingleNode('p:nvSpPr/p:cNvSpPr', $Ns); if ($cnv) { $cnv.RemoveAttribute('txBox') }
    $sppr = $Shape.SelectSingleNode('p:spPr', $Ns); if ($sppr) { $sppr.RemoveAll() }
    $style = $Shape.SelectSingleNode('p:style', $Ns); if ($style) { $null = $Shape.RemoveChild($style) }
    $body = $Shape.SelectSingleNode('p:txBody/a:bodyPr', $Ns); if ($body) { $body.RemoveAll() }
    foreach ($p in @($Shape.SelectNodes('.//a:pPr[@algn]', $Ns))) { $p.RemoveAttribute('algn') }
    Remove-PptxRunStyle $Shape $Ns -Size -FontsAndColours
}

function Set-PptxFreeShape($Shape, $Ph, $SourceSlots, $Ns) {
    # A placeholder the new layout has no place for becomes a free shape where it was: its own place,
    # else its old layout's placeholder of the same idx or kind (in the content deck's coordinates).
    if (-not (Get-PptxRect (Get-PptxShapeXfrm $Shape $Ns))) {
        $slot = @($SourceSlots | Where-Object { $Ph.idx -and $_.idx -eq $Ph.idx })[0]
        if (-not $slot) { $slot = @($SourceSlots | Where-Object { $_.kind -eq $Ph.kind })[0] }
        if ($slot -and $slot.rect) { Set-PptxXfrm $Shape $Ns $slot.rect }
    }
    $null = $Ph.el.ParentNode.RemoveChild($Ph.el)
}

function Get-PptxSlot($Free, [string[]]$Kinds) {
    # Takes the first remaining layout slot of the first kind that has one.
    foreach ($k in $Kinds) {
        for ($i = 0; $i -lt $Free.Count; $i++) { if ($Free[$i].kind -eq $k) { $s = $Free[$i]; $Free.RemoveAt($i); return $s } }
    }
    $null
}

function Set-PptxSlotPh($Ph, $Slot) {
    if ($Slot.type) { $Ph.el.SetAttribute('type', $Slot.type) } else { $Ph.el.RemoveAttribute('type') }
    if ($Slot.idx) { $Ph.el.SetAttribute('idx', $Slot.idx) } else { $Ph.el.RemoveAttribute('idx') }
    $Ph.el.RemoveAttribute('sz'); $Ph.el.RemoveAttribute('orient')
}

function Get-PptxFillBrightness($Fill, $Ns, $Colors) {
    # The brightness (0-1) of a solidFill, a theme colour read through the content theme; -1 when unknown.
    if (-not $Fill) { return -1 }
    $v = ''
    $srgb = $Fill.SelectSingleNode('a:srgbClr', $Ns); $sc = $Fill.SelectSingleNode('a:schemeClr', $Ns)
    if ($srgb) { $v = $srgb.GetAttribute('val') }
    elseif ($sc) { $slot = @{ bg1 = 'lt1'; tx1 = 'dk1'; bg2 = 'lt2'; tx2 = 'dk2' }[$sc.GetAttribute('val')]; if (-not $slot) { $slot = $sc.GetAttribute('val') }; $v = "$($Colors[$slot])" }
    if ($v.Length -ne 6) { return -1 }
    ([Drawing.Color]::FromArgb([Convert]::ToInt32($v, 16))).GetBrightness()
}

function Remove-PptxOwnBackground {
    <# The content deck's own light background, so the template's shows: a p:bg override with a light
       solid fill, and full-slide shapes without text at the bottom of the tree with a light fill (generated
       decks paint their background that way). A dark one stays, since its text is light. Returns
       'removed', 'kept' or ''. #>
    param([Xml.XmlDocument]$Xml, $Ns, $Size, $Colors)
    $result = ''
    $bg = $Xml.SelectSingleNode('/p:sld/p:cSld/p:bg', $Ns)
    if ($bg) {
        $b = Get-PptxFillBrightness $bg.SelectSingleNode('p:bgPr/a:solidFill', $Ns) $Ns $Colors
        if ($b -ge 0.85) { $null = $bg.ParentNode.RemoveChild($bg); $result = 'removed' } else { $result = 'kept' }
    }
    if (-not $Size) { return $result }
    foreach ($sp in @(Get-PptxTreeItems $Xml.SelectSingleNode('/p:sld/p:cSld/p:spTree', $Ns) $Ns)) {
        if ($sp.LocalName -ne 'sp' -or (Get-PptxPh $sp $Ns) -or (Get-PptxText $sp $Ns)) { break }
        $r = Get-PptxRect (Get-PptxShapeXfrm $sp $Ns)
        if (-not $r -or $r.x -gt 0.03 * $Size.cx -or $r.y -gt 0.03 * $Size.cy -or $r.cx -lt 0.95 * $Size.cx -or $r.cy -lt 0.95 * $Size.cy) { break }
        $b = Get-PptxFillBrightness $sp.SelectSingleNode('p:spPr/a:solidFill', $Ns) $Ns $Colors
        if ($b -lt 0.85) { $result = 'kept'; break }
        Remove-PptxTreeItem $sp; $result = 'removed'
    }
    $result
}

function Set-PptxHeadingTitle($Tree, $Ns, $Slots, [int]$Heading) {
    # The heading text box becomes the title, when the slide has no title of its own and the layout has one.
    if (-not $Heading -or -not @($Slots | Where-Object { $_.kind -eq 'title' }).Count) { return }
    $items = @(Get-PptxTreeItems $Tree $Ns)
    foreach ($it in $items) { $p = Get-PptxPh $it $Ns; if ($p -and $p.kind -eq 'title' -and (Get-PptxText $it $Ns)) { return } }
    foreach ($it in $items) {
        if ($it.LocalName -ne 'sp' -or (Get-PptxPh $it $Ns)) { continue }
        if ([int]$it.SelectSingleNode('p:nvSpPr/p:cNvPr', $Ns).GetAttribute('id') -eq $Heading) { ConvertTo-PptxTitle $it $Ns; return }
    }
}

function Set-PptxSlotted($Shape, $Ph, $Slot, $Ns) {
    # A placeholder in its layout slot: idx and type of the slot; no own place (a chart frame, which must
    # keep a transform, takes the slot's).
    Set-PptxSlotPh $Ph $Slot
    if ($Shape.LocalName -eq 'graphicFrame') { if ($Slot.rect) { Set-PptxXfrm $Shape $Ns $Slot.rect }; return }
    $xf = Get-PptxShapeXfrm $Shape $Ns
    if ($xf) { $null = $xf.ParentNode.RemoveChild($xf) }
}

function Set-PptxPlaceholders($Tree, $Ns, $Slots, $SourceSlots, $Index) {
    <# Every placeholder onto the new layout: footers by their own type (else dropped: the template has
       its own); pictures and tables stay where they are, as free shapes; text, charts and SmartArt take
       a slot of their own kind first, then a content or subtitle slot. One without a slot is dropped when
       empty and kept where it was when not. Returns the notes for the person. #>
    $free = New-Object Collections.ArrayList
    foreach ($s in $Slots) { if ($s.kind -ne 'footer') { $null = $free.Add($s) } }
    $waiting = New-Object Collections.Generic.List[object]
    foreach ($sp in @(Get-PptxTreeItems $Tree $Ns)) {
        $ph = Get-PptxPh $sp $Ns
        if (-not $ph) { continue }
        if ($ph.kind -eq 'footer') {
            $slot = @($Slots | Where-Object { $_.kind -eq 'footer' -and $_.type -eq $ph.type })[0]
            if ($slot) { Set-PptxSlotted $sp $ph $slot $Ns } else { Remove-PptxTreeItem $sp }
            continue
        }
        $frameUri = if ($sp.LocalName -eq 'graphicFrame') { "$($sp.SelectSingleNode('a:graphic/a:graphicData', $Ns).GetAttribute('uri'))" } else { '' }
        if ($sp.LocalName -eq 'pic' -or ($sp.LocalName -eq 'graphicFrame' -and $frameUri -notmatch 'chart|diagram')) { Set-PptxFreeShape $sp $ph $SourceSlots $Ns; continue }
        $waiting.Add(@{ sp = $sp; ph = $ph; used = [bool]((Get-PptxText $sp $Ns) -or $sp.LocalName -eq 'graphicFrame') })
    }
    foreach ($w in $waiting) { $w.slot = Get-PptxSlot $free @($w.ph.kind) }
    foreach ($w in @($waiting | Where-Object { -not $_.slot -and $_.ph.kind -ne 'title' })) { $w.slot = Get-PptxSlot $free @('content', 'subtitle') }
    foreach ($w in $waiting) {
        if ($w.slot) { Set-PptxSlotted $w.sp $w.ph $w.slot $Ns }
        elseif (-not $w.used) { Remove-PptxTreeItem $w.sp }
        else {
            Set-PptxFreeShape $w.sp $w.ph $SourceSlots $Ns
            "slide ${Index}: the layout has no place for its $($w.ph.kind) text; it stays where it was, as a text box."
        }
    }
}

function Move-PptxFreeShapes($Tree, $Ns, $Scale) {
    # Every top-level item without a placeholder (both sides of an mc:AlternateContent) onto the new size.
    foreach ($c in @($Tree.ChildNodes)) {
        if ($c.NodeType -ne [Xml.XmlNodeType]::Element -or $c.LocalName -in 'nvGrpSpPr', 'grpSpPr', 'extLst') { continue }
        $shapes = if ($c.LocalName -eq 'AlternateContent') { @($c.SelectNodes('mc:Choice/*|mc:Fallback/*', $Ns)) } else { @($c) }
        foreach ($sh in $shapes) { if (-not (Get-PptxPh $sh $Ns)) { Move-PptxShape $sh $Ns $Scale } }
    }
}

function Set-PptxPlaceholderStyle($Tree, $Ns, [bool]$TemplateStyles) {
    # Titles take the template's sizes (Retheme's default); the option takes fonts and colours away too.
    foreach ($sp in @(Get-PptxTreeItems $Tree $Ns)) {
        $ph = Get-PptxPh $sp $Ns
        if (-not $ph -or $sp.LocalName -ne 'sp') { continue }
        if ($ph.kind -in 'title', 'subtitle') { Remove-PptxRunStyle $sp $Ns -Size }
        if ($TemplateStyles) { Remove-PptxRunStyle $sp $Ns -FontsAndColours }
    }
}

function Convert-PptxSlideXml {
    <# One copied slide made at home on its new layout. Opt: slots (the new layout's), sourceSlots (the
       old layout's, for places), heading (id of the text box to make the title, 0 none), scale
       (Get-PptxScale or $null), colors / fonts (Get-PptxThemeMaps), templateStyles, keepBackgrounds, size and
       sourceColors (the content deck's slide size and theme, for its own background), index. Returns the
       notes for the person. #>
    param([Parameter(Mandatory)][Xml.XmlDocument]$Xml, [Parameter(Mandatory)][hashtable]$Opt)
    $ns = Get-PptxNs $Xml
    $notes = New-Object Collections.Generic.List[string]
    $tree = $Xml.SelectSingleNode('/p:sld/p:cSld/p:spTree', $ns)
    if (-not $Opt.keepBackgrounds -and (Remove-PptxOwnBackground $Xml $ns $Opt.size $Opt.sourceColors) -eq 'kept') { $notes.Add("slide $($Opt.index) keeps its own dark background.") }
    Set-PptxHeadingTitle $tree $ns @($Opt.slots) ([int]$Opt.heading)
    foreach ($n in @(Set-PptxPlaceholders $tree $ns @($Opt.slots) @($Opt.sourceSlots) $Opt.index)) { $notes.Add($n) }
    if ($Opt.scale -and ([Math]::Abs($Opt.scale.f - 1) -ge 0.001 -or $Opt.scale.ox -or $Opt.scale.oy)) { Move-PptxFreeShapes $tree $ns $Opt.scale }
    Set-PptxPlaceholderStyle $tree $ns ([bool]$Opt.templateStyles)
    $null = Set-PptxRestyle $Xml $Opt.colors $Opt.fonts
    $notes.ToArray()
}

# --------------------------------------------------------------------------- the whole deck

function Resolve-PptxEnds([int]$Start, [int]$End, [int]$Count) {
    # -1 = the template's first (start) or last (end) slide, 0 = none; one slide is never used twice.
    $s = if ($Start -lt 0) { [Math]::Min(1, $Count) } else { $Start }
    $e = if ($End -lt 0) { $(if ($Count -ge 2) { $Count } else { 0 }) } else { $End }
    foreach ($v in $s, $e) { if ($v -gt $Count) { throw "The template has no slide $v." } }
    if ($e -eq $s) { $e = 0 }
    @{ start = $s; end = $e }
}

function Add-PptxNotesMaster($Ctx, $DstPres, [Xml.XmlDocument]$PresXml, $Ns) {
    # The content deck's notes master (with its theme) for a template that has none.
    $sPres = Get-PptxPresentationPart $Ctx.src
    $snm = Get-PptxRelatedPart $Ctx.src $sPres 'notesMaster'
    if (-not $snm) { return $null }
    $nm = Copy-PptxPartTree $Ctx $snm
    $rel = New-PptxRel $DstPres $nm "$script:RelBase/notesMaster" ''
    $lst = $PresXml.CreateElement('p', 'notesMasterIdLst', $script:NsP)
    $id = $PresXml.CreateElement('p', 'notesMasterId', $script:NsP)
    $a = $PresXml.CreateAttribute('r', 'id', $script:NsRel); $a.Value = $rel.Id; $null = $id.Attributes.Append($a)
    $null = $lst.AppendChild($id)
    $null = $PresXml.DocumentElement.InsertAfter($lst, $PresXml.SelectSingleNode('/p:presentation/p:sldMasterIdLst', $Ns))
    $nm
}

function Copy-PptxNotes($Ctx, $SrcSlide, $NewSlide, $NotesMaster, $Maps) {
    # A slide's speaker notes: its notes part copied, tied to the new slide and the output's notes master.
    $sn = Get-PptxRelatedPart $Ctx.src $SrcSlide 'notesSlide'
    if (-not $sn -or -not $NotesMaster) { return $false }
    $nn = Copy-PptxPartTree $Ctx $sn @('slide')
    foreach ($rel in @($sn.GetRelationships())) {
        $kind = Get-PptxRelKind $rel
        if ($kind -eq 'notesMaster') { $null = New-PptxRel $nn $NotesMaster $rel.RelationshipType $rel.Id }
        elseif ($kind -eq 'slide' -and $rel.TargetMode -eq [IO.Packaging.TargetMode]::Internal) { $null = New-PptxRel $nn $NewSlide $rel.RelationshipType $rel.Id }
    }
    $null = New-PptxRel $NewSlide $nn "$script:RelBase/notesSlide" ''
    $x = Read-PptxPartXml $nn
    $null = Set-PptxRestyle $x $Maps.colors $Maps.fonts; $null = Remove-PptxBrokenRefs $nn $x
    Write-PptxPartXml $nn $x
    $true
}

function Read-PptxTableStyles($Package) {
    # The table styles a deck defines: @(@{ id; name; default }) (built-in styles are not listed).
    $part = Get-PptxRelatedPart $Package (Get-PptxPresentationPart $Package) 'tableStyles'
    if (-not $part) { return @() }
    $x = Read-PptxPartXml $part; $ns = Get-PptxNs $x
    $def = $x.DocumentElement.GetAttribute('def')
    @(foreach ($s in @($x.SelectNodes('/a:tblStyleLst/a:tblStyle', $ns))) { @{ id = $s.GetAttribute('styleId'); name = $s.GetAttribute('styleName'); default = ($s.GetAttribute('styleId') -eq $def) } })
}

function Merge-PptxTableStyles($Ctx, $DstPres, $Maps) {
    # Table styles the content deck defines and the template does not (a table stores only the style's
    # id), restyled to the template. Returns how many.
    $st = Get-PptxRelatedPart $Ctx.src (Get-PptxPresentationPart $Ctx.src) 'tableStyles'
    $dt = Get-PptxRelatedPart $Ctx.dst $DstPres 'tableStyles'
    if (-not $st -or -not $dt) { return 0 }
    $sx = Read-PptxPartXml $st; $dx = Read-PptxPartXml $dt
    $have = @{}; foreach ($s in @(Read-PptxTableStyles $Ctx.dst)) { $have[$s.id] = 1 }
    $n = 0
    foreach ($s in @($sx.SelectNodes('/a:tblStyleLst/a:tblStyle', (Get-PptxNs $sx)))) {
        if ($have.ContainsKey($s.GetAttribute('styleId'))) { continue }
        $node = $dx.ImportNode($s, $true)
        $null = Set-PptxRestyle $node $Maps.colors $Maps.fonts
        $null = $dx.DocumentElement.AppendChild($node); $n++
    }
    if ($n) { Write-PptxPartXml $dt $dx }
    $n
}

function Remove-PptxSlideLists([Xml.XmlDocument]$PresXml, $Ns) {
    # Sections and custom shows name slides by id; the template's would point at removed slides.
    $n = 0
    foreach ($ext in @($PresXml.SelectNodes('/p:presentation/p:extLst/p:ext', $Ns))) {
        if ($ext.SelectSingleNode("*[local-name()='sectionLst']")) { $null = $ext.ParentNode.RemoveChild($ext); $n++ }
    }
    $el = $PresXml.SelectSingleNode('/p:presentation/p:extLst', $Ns); if ($el -and -not $el.HasChildNodes) { $null = $el.ParentNode.RemoveChild($el) }
    $cs = $PresXml.SelectSingleNode('/p:presentation/p:custShowLst', $Ns); if ($cs) { $null = $cs.ParentNode.RemoveChild($cs); $n++ }
    $n
}

function Get-PptxLayoutChoice($Content, $Template, [hashtable]$Layouts) {
    # The template layout per content slide number: the person's choice, else the rules'. An unknown name stops.
    $byName = @{}; foreach ($l in @($Template.layouts)) { $k = $l.name.ToLowerInvariant(); if (-not $byName.ContainsKey($k)) { $byName[$k] = $l } }
    if (-not $byName.Count) { throw 'The template has no slide layouts.' }
    $choice = @{}
    foreach ($s in @($Content.slides)) {
        $want = "$($Layouts["$($s.index)"])"
        $name = if ($want) { $want } else { (Select-PptxLayout $s $Template.layouts).layout }
        if (-not $byName.ContainsKey($name.ToLowerInvariant())) { throw "The template has no layout named ""$name""." }
        $choice[$s.index] = $byName[$name.ToLowerInvariant()]
    }
    $choice
}

function Remove-PptxTemplateSlides($Job) {
    # The template's slides but the chosen start and end go, with their notes; Job gets startEl, endEl
    # and the next free slide id.
    $lst = $Job.presXml.SelectSingleNode('/p:presentation/p:sldIdLst', $Job.ns)
    if (-not $lst) { $lst = $Job.presXml.CreateElement('p', 'sldIdLst', $script:NsP); $null = $Job.presXml.DocumentElement.InsertBefore($lst, $Job.presXml.SelectSingleNode('/p:presentation/p:sldSz', $Job.ns)) }
    $Job.list = $lst
    $i = 0
    foreach ($el in @($lst.SelectNodes('p:sldId', $Job.ns))) {
        $i++
        if ($i -eq $Job.ends.start) { $Job.startEl = $el; continue }
        if ($i -eq $Job.ends.end) { $Job.endEl = $el; continue }
        $rid = $el.GetAttribute('id', $script:NsRel)
        $part = $Job.ctx.dst.GetPart((Get-PptxRelTarget $Job.pres $Job.pres.GetRelationship($rid)))
        $np = Get-PptxRelatedPart $Job.ctx.dst $part 'notesSlide'; if ($np) { $Job.ctx.dst.DeletePart($np.Uri) }
        $Job.ctx.dst.DeletePart($part.Uri); $Job.pres.DeleteRelationship($rid); $null = $lst.RemoveChild($el)
    }
    $Job.nextId = 256; foreach ($el in @($lst.SelectNodes('p:sldId', $Job.ns))) { $Job.nextId = [Math]::Max($Job.nextId, 1 + [long]$el.GetAttribute('id')) }
}

function Copy-PptxContentSlide($Job, $SrcPart, [int]$Index) {
    # One content slide copied onto its layout, made at home there (Convert-PptxSlideXml), with its notes;
    # its new slide id element goes to Job.newEls.
    $dst = $Job.ctx.dst
    $info = @($Job.content.slides)[$Index - 1]
    $lay = $Job.choice[$Index]
    $new = Copy-PptxPartTree $Job.ctx $SrcPart
    $sLayRel = @($SrcPart.GetRelationships() | Where-Object { (Get-PptxRelKind $_) -eq 'slideLayout' })[0]
    $null = New-PptxRel $new ($dst.GetPart((New-Object Uri($lay.uri, [UriKind]::Relative)))) "$script:RelBase/slideLayout" $(if ($sLayRel) { $sLayRel.Id } else { '' })
    $srcLay = if ($sLayRel) { $Job.srcLayouts["$(Get-PptxRelTarget $SrcPart $sLayRel)"] } else { $null }
    $titles = $Job.choices.titles
    $opt = @{
        slots = $lay.slots; sourceSlots = $(if ($srcLay) { $srcLay.slots } else { @() }); index = $Index
        heading = $(if ($titles -and $titles.ContainsKey("$Index")) { [int]$titles["$Index"] } else { [int]$info.heading })
        scale = $Job.scale; colors = $Job.maps.colors; fonts = $Job.maps.fonts; size = $Job.content.size; sourceColors = $Job.sourceColors
        templateStyles = [bool]$Job.choices.templateStyles; keepBackgrounds = [bool]$Job.choices.keepBackgrounds
    }
    $x = Read-PptxPartXml $new
    foreach ($n in @(Convert-PptxSlideXml $x $opt)) { $Job.warn.Add($n) }
    # Per-element choices (PptxChoices.psm1) on the slide as it is on its new layout.
    if ($Job.onSlide) { foreach ($n in @(& $Job.onSlide $Job $x $Index $new)) { if ($n) { $Job.warn.Add("$n") } } }
    $null = Remove-PptxBrokenRefs $new $x
    Write-PptxPartXml $new $x
    if (Copy-PptxNotes $Job.ctx $SrcPart $new $Job.notesMaster $Job.maps) { $Job.kept++ }
    $Job.newBySrc["$($SrcPart.Uri)"] = $new
    $rel = New-PptxRel $Job.pres $new "$script:RelBase/slide" ''
    $el = $Job.presXml.CreateElement('p', 'sldId', $script:NsP); $el.SetAttribute('id', [string]$Job.nextId); $Job.nextId++
    $a = $Job.presXml.CreateAttribute('r', 'id', $script:NsRel); $a.Value = $rel.Id; $null = $el.Attributes.Append($a)
    $Job.newEls.Add($el)
}

function Connect-PptxSlideLinks($Job) {
    # Links from one slide to another point at the copy; a link to a slide outside the deck goes.
    $fix = @{}
    foreach ($l in $Job.ctx.links) {
        if ($Job.newBySrc.ContainsKey($l.target)) { $null = New-PptxRel $l.part $Job.newBySrc[$l.target] $l.type $l.id } else { $fix["$($l.part.Uri)"] = $l.part }
    }
    foreach ($p in $fix.Values) { $x = Read-PptxPartXml $p; if (Remove-PptxBrokenRefs $p $x) { Write-PptxPartXml $p $x }; $Job.warn.Add('A link to a slide outside the deck was removed.') }
}

function Complete-PptxDeck($Job) {
    # Charts, SmartArt and other copied XML follow the template's theme too (not the slides and notes,
    # done already, nor a copied notes theme); table styles come along; the slide list becomes start,
    # content, end; and what no longer belongs (sections, dangling links, orphan parts) goes.
    foreach ($p in $Job.ctx.created) {
        if ("$($p.ContentType)" -match 'slide\+xml|notesSlide|theme|notesMaster') { continue }
        $x = Read-PptxPartXml $p
        if (Set-PptxRestyle $x $Job.maps.colors $Job.maps.fonts) { Write-PptxPartXml $p $x }
    }
    $styles = Merge-PptxTableStyles $Job.ctx $Job.pres $Job.maps
    if ($styles) { $Job.warn.Add("$styles table style(s) came along from the content deck.") }
    foreach ($el in @($Job.list.SelectNodes('p:sldId', $Job.ns))) { $null = $Job.list.RemoveChild($el) }
    # Not @($el): an XML element is enumerable, and @() would give its children.
    if ($Job.startEl) { $null = $Job.list.AppendChild($Job.startEl) }
    foreach ($el in $Job.newEls) { $null = $Job.list.AppendChild($el) }
    if ($Job.endEl) { $null = $Job.list.AppendChild($Job.endEl) }
    if (Remove-PptxSlideLists $Job.presXml $Job.ns) { $Job.warn.Add('The template''s sections and custom shows were left out.') }
    Write-PptxPartXml $Job.pres $Job.presXml
    Remove-PptxDanglingRels $Job.ctx.dst
    $null = Remove-PptxOrphanParts $Job.ctx.dst
}

function Add-PptxSummary($Job) {
    # The closing notes for the person: slide size, speaker notes.
    $s = $Job.scale
    if ($s -and [Math]::Abs($s.f - 1) -ge 0.001) { $Job.warn.Add("The slide size differs: shapes outside placeholders were scaled by $('{0:0.##}' -f $s.f) and centred.") }
    elseif ($s) { $Job.warn.Add('The slide size differs: shapes outside placeholders were centred.') }
    if ($Job.kept) { $Job.warn.Add("$($Job.kept) slide(s) kept their speaker notes.") }
    if (-not $Job.notesMaster -and $Job.hasNotes) { $Job.warn.Add('The speaker notes were left out: neither deck has a notes page.') }
}

function Invoke-PptxRetheme {
    <# Writes OutPath: the template with only its start and end slides and every content slide between
       them. Choices (ConvertTo-PptxChoices; all optional): layouts @{ "N" = layout name } (a slide not
       named gets the rules' choice), titles @{ "N" = text box id } (0 none; not named: the rules'
       heading), start / end (template slide numbers; -1 or missing = its first / last, 0 = none),
       templateStyles, keepBackgrounds. Per-element choices go in the same object; OnSlide
       ($Job, slide XML, index, part) runs on each copied slide after it is made at home on its layout,
       OnDeck ($Job) once the deck is complete; both return notes for the person (PptxChoices.psm1).
       Returns @{ slides; notes; warnings; start; end }. #>
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][string]$ContentPath, [Parameter(Mandatory)][string]$OutPath, [hashtable]$Choices = @{}, [scriptblock]$OnSlide = $null, [scriptblock]$OnDeck = $null)
    $tInfo = Read-PptxDeck $TemplatePath
    $cInfo = Read-PptxDeck $ContentPath
    $layouts = if ($Choices.layouts) { $Choices.layouts } else { @{} }
    $job = @{
        choices = $Choices; content = $cInfo; choice = (Get-PptxLayoutChoice $cInfo $tInfo $layouts)
        ends = (Resolve-PptxEnds $(if ($Choices.ContainsKey('start')) { [int]$Choices.start } else { -1 }) $(if ($Choices.ContainsKey('end')) { [int]$Choices.end } else { -1 }) @($tInfo.slides).Count)
        srcLayouts = @{}; warn = (New-Object Collections.Generic.List[string]); kept = 0; newBySrc = @{}; newEls = (New-Object Collections.Generic.List[object])
        scale = $(if ($tInfo.size.cx -ne $cInfo.size.cx -or $tInfo.size.cy -ne $cInfo.size.cy) { Get-PptxScale $cInfo.size $tInfo.size } else { $null })
        hasNotes = [bool]@($cInfo.slides | Where-Object { $_.notes }).Count
        onSlide = $OnSlide
    }
    foreach ($l in @($cInfo.layouts)) { $job.srcLayouts[$l.uri] = $l }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('streamhub-pptx-' + [guid]::NewGuid().ToString('N') + '.pptx')
    $fs = [IO.File]::Open($TemplatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $out = [IO.File]::Create($tmp); try { $fs.CopyTo($out) } finally { $out.Dispose() } } finally { $fs.Dispose() }
    $count = 0
    try {
        Repair-PptxMainType $tmp
        $dst = [IO.Packaging.Package]::Open($tmp, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
        $src = Open-PptxPackage $ContentPath
        try {
            $job.ctx = @{ src = $src; dst = $dst; cloned = @{}; byHash = @{}; next = @{}; created = (New-Object Collections.Generic.List[object]); links = (New-Object Collections.Generic.List[object]) }
            $job.pres = Get-PptxPresentationPart $dst; $job.presXml = Read-PptxPartXml $job.pres; $job.ns = Get-PptxNs $job.presXml
            $srcThemes = @(Read-PptxThemes $src)
            $job.maps = Get-PptxThemeMaps $srcThemes @(Read-PptxThemes $dst)[0]
            $job.sourceColors = if ($srcThemes.Count) { $srcThemes[0].colors } else { @{} }
            Remove-PptxTemplateSlides $job
            $job.notesMaster = Get-PptxRelatedPart $dst $job.pres 'notesMaster'
            if (-not $job.notesMaster -and $job.hasNotes) {
                $job.notesMaster = Add-PptxNotesMaster $job.ctx $job.pres $job.presXml $job.ns
                if ($job.notesMaster) { $job.warn.Add('The template has no notes page, so the speaker notes keep the content deck''s notes page.') }
            }
            $sPres = Get-PptxPresentationPart $src; $sx = Read-PptxPartXml $sPres
            foreach ($sid in @($sx.SelectNodes('/p:presentation/p:sldIdLst/p:sldId', (Get-PptxNs $sx)))) {
                $count++
                Copy-PptxContentSlide $job ($src.GetPart((Get-PptxRelTarget $sPres $sPres.GetRelationship($sid.GetAttribute('id', $script:NsRel))))) $count
            }
            Connect-PptxSlideLinks $job
            Complete-PptxDeck $job
            if ($OnDeck) { foreach ($n in @(& $OnDeck $job)) { if ($n) { $job.warn.Add("$n") } } }
            Add-PptxSummary $job
        } finally { $src.Close(); $dst.Close() }
        $dir = Split-Path -Parent $OutPath
        if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir }
        Move-Item -LiteralPath $tmp -Destination $OutPath -Force
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    @{ slides = $count; notes = $job.kept; warnings = $job.warn.ToArray(); start = $job.ends.start; end = $job.ends.end }
}

Export-ModuleMember -Function Get-PptxScale, Get-PptxRethemePlan, Merge-PptxMapping, ConvertTo-PptxChoices, Get-PptxBrandedName, Copy-PptxPartTree, Remove-PptxBrokenRefs, Remove-PptxOrphanParts, Remove-PptxDanglingRels, Remove-PptxSlideLists, New-PptxRel, Get-PptxFreeUri, Repair-PptxMainType, Read-PptxThemes, Get-PptxThemeMaps, Set-PptxRestyle, Read-PptxTableStyles, Move-PptxShape, ConvertTo-PptxTitle, Convert-PptxSlideXml, Resolve-PptxEnds, Get-PptxLayoutChoice, Invoke-PptxRetheme
