# Choices for what a content deck leaves unformatted, when a PowerPoint template is applied (on request
# only, from the template card). After the core (PptxRetheme.psm1) has moved the slides onto the
# template's layouts, some elements still carry no brand formatting: a table without a style, a text box
# in the deck's default font and colour, a shape filled with a hand-typed colour close to no template
# colour, a chart whose series colours were typed by hand, a heading in a free text box. For each one
# StreamHub offers ranked options (the template's own styles first, then the UI kit's look, and always
# "Keep as it is"), leaves out any option whose text would not read (Contrast.psm1, WCAG AA), and
# describes a small drawing of each option for the card's preview (SVG in the app). The person chooses
# per element or per kind; the choice is applied in the same write as the template (Invoke-PptxRetheme
# OnSlide / OnDeck). Fixed rules on the deck's XML; nothing is sent anywhere unless the person presses
# Ask Copilot on one element, and then only that element's structure (New-PptxElementAsk).
# ASCII only (Windows PowerShell 5.1).

foreach ($m in 'PptxLayoutMatch', 'PptxRetheme', 'Contrast') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }
Add-Type -AssemblyName WindowsBase

$script:NsA = 'http://schemas.openxmlformats.org/drawingml/2006/main'
$script:NsC = 'http://schemas.openxmlformats.org/drawingml/2006/chart'
$script:NsRel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:EmuPerPt = 12700
# Table styles that are no formatting at all: none, "No Style, No Grid", "No Style, Table Grid".
$script:PlainTableStyles = @('{2D5ABB26-0587-4C30-8999-92F81FD0307C}', '{5940675A-B579-460E-94D1-54222C63F5DA}')
# PowerPoint's built-in "Medium Style 2 - Accent N": drawn in the template's own accent colours.
$script:AccentTableStyles = @{
    '{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}' = 1; '{21E4AEA4-8DFA-4A89-87EB-49C32662AFE8}' = 2; '{F5AB1C69-6EDB-4FF4-983F-18BD219EF322}' = 3
    '{00A15C55-8517-42AA-B614-E9B94910E393}' = 4; '{7DF18680-E054-41AD-8BC1-D1AEF772440D}' = 5; '{93296810-A885-4BE3-A3E7-6D5BEEA58F35}' = 6
}
$script:AccentTableStyle = '{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}'
# The UI kit's table look, added to the output deck's table styles when a table takes it.
$script:KitTableStyleId = '{7D3C1A52-4B8E-4F2A-9C61-2E5B0F8D7A13}'
$script:SchemeSlot = @{ bg1 = 'lt1'; tx1 = 'dk1'; bg2 = 'lt2'; tx2 = 'dk2' }
$script:KindNames = @{ table = 'table'; textbox = 'text box'; shape = 'shape'; chart = 'chart'; heading = 'heading' }
$script:ShapeColourSlots = @('accent1', 'accent2', 'accent3', 'accent4', 'accent5', 'accent6', 'dk2', 'lt2')
$script:NearColour = 40      # a fill this close (RGB distance) to a template colour counts as on-brand
$script:HeadingSize = 2000   # 20 pt, as PptxLayoutMatch's headings

# --------------------------------------------------------------------------- colours

function ConvertTo-PptxHex([string]$Value) {
    # 'RRGGBB' from a CSS colour (#rgb, #rrggbb, rgb()) or a DrawingML hex value; '' when not opaque or unknown.
    $v = "$Value".Trim()
    if ($v -match '^[0-9A-Fa-f]{6}$') { return $v.ToUpperInvariant() }
    $c = ConvertFrom-CssColor $v
    if (-not $c -or $c.a -lt 1) { return '' }
    '{0:X2}{1:X2}{2:X2}' -f [int]$c.r, [int]$c.g, [int]$c.b
}

function Get-PptxColourDistance([string]$A, [string]$B) {
    if ($A.Length -ne 6 -or $B.Length -ne 6) { return 999 }
    $d = 0.0
    for ($i = 0; $i -lt 6; $i += 2) { $d += [Math]::Pow([Convert]::ToInt32($A.Substring($i, 2), 16) - [Convert]::ToInt32($B.Substring($i, 2), 16), 2) }
    [Math]::Round([Math]::Sqrt($d), 1)
}

function Get-PptxContrast([string]$Fore, [string]$Back) {
    # The WCAG ratio of two 'RRGGBB' colours, or 21 when one is unknown (nothing to judge).
    if ($Fore.Length -ne 6 -or $Back.Length -ne 6) { return 21 }
    [double](Get-ContrastRatio "#$Fore" "#$Back")
}

function Set-PptxLuminance([string]$Hex, [double]$Mod = 1, [double]$Off = 0) {
    # DrawingML lumMod / lumOff on a colour (HSL lightness), as PowerPoint draws theme tints and shades.
    $r = [Convert]::ToInt32($Hex.Substring(0, 2), 16) / 255.0; $g = [Convert]::ToInt32($Hex.Substring(2, 2), 16) / 255.0; $b = [Convert]::ToInt32($Hex.Substring(4, 2), 16) / 255.0
    $max = [Math]::Max($r, [Math]::Max($g, $b)); $min = [Math]::Min($r, [Math]::Min($g, $b))
    $l = ($max + $min) / 2; $h = 0.0; $s = 0.0
    if ($max -ne $min) {
        $d = $max - $min
        $s = if ($l -gt 0.5) { $d / (2 - $max - $min) } else { $d / ($max + $min) }
        $h = if ($max -eq $r) { (($g - $b) / $d) + $(if ($g -lt $b) { 6 } else { 0 }) } elseif ($max -eq $g) { (($b - $r) / $d) + 2 } else { (($r - $g) / $d) + 4 }
        $h = $h / 6
    }
    # [double] first: with an int first argument [Math]::Max/Min take the integer overload and round.
    $l = [Math]::Min([double]1, [Math]::Max([double]0, $l * $Mod + $Off))
    $hue = {
        param($p, $q, $t)
        if ($t -lt 0) { $t += 1 }; if ($t -gt 1) { $t -= 1 }
        if ($t -lt 1 / 6) { return $p + ($q - $p) * 6 * $t }
        if ($t -lt 1 / 2) { return $q }
        if ($t -lt 2 / 3) { return $p + ($q - $p) * (2 / 3 - $t) * 6 }
        $p
    }
    if ($s -eq 0) { $r = $g = $b = $l } else {
        $q = if ($l -lt 0.5) { $l * (1 + $s) } else { $l + $s - $l * $s }
        $p = 2 * $l - $q
        $r = & $hue $p $q ($h + 1 / 3); $g = & $hue $p $q $h; $b = & $hue $p $q ($h - 1 / 3)
    }
    '{0:X2}{1:X2}{2:X2}' -f [int][Math]::Round($r * 255), [int][Math]::Round($g * 255), [int][Math]::Round($b * 255)
}

function Resolve-PptxColour($Parent, $Colors) {
    <# The colour a fill or text style element holds ('RRGGBB'): its srgbClr, a scheme colour through the
       theme (bg1/tx1/bg2/tx2 by the usual colour map), sysClr's last colour; lumMod and lumOff applied.
       '' when it holds none. #>
    if (-not $Parent) { return '' }
    $el = $Parent.SelectSingleNode("*[local-name()='srgbClr' or local-name()='schemeClr' or local-name()='sysClr' or local-name()='prstClr']")
    if (-not $el) { return '' }
    $hex = ''
    switch ($el.LocalName) {
        'srgbClr' { $hex = $el.GetAttribute('val') }
        'sysClr' { $hex = $el.GetAttribute('lastClr') }
        'prstClr' { $hex = "$(@{ black = '000000'; white = 'FFFFFF' }[$el.GetAttribute('val')])" }
        'schemeClr' { $v = $el.GetAttribute('val'); $slot = if ($script:SchemeSlot.ContainsKey($v)) { $script:SchemeSlot[$v] } else { $v }; $hex = "$($Colors[$slot])" }
    }
    if ("$hex".Length -ne 6) { return '' }
    $mod = $el.SelectSingleNode("*[local-name()='lumMod']"); $off = $el.SelectSingleNode("*[local-name()='lumOff']")
    if ($mod -or $off) { $hex = Set-PptxLuminance $hex $(if ($mod) { [int]$mod.GetAttribute('val') / 100000.0 } else { 1 }) $(if ($off) { [int]$off.GetAttribute('val') / 100000.0 } else { 0 }) }
    $hex.ToUpperInvariant()
}

function Get-PptxSchemeName($Parent) {
    # The scheme colour name a fill holds without modifiers (accent1, tx1...), else ''.
    if (-not $Parent) { return '' }
    $el = $Parent.SelectSingleNode("*[local-name()='schemeClr']")
    if ($el -and -not $el.HasChildNodes) { return $el.GetAttribute('val') }
    ''
}

# --------------------------------------------------------------------------- the template's look

function Get-PptxFontName([string]$Typeface, $Fonts) {
    if ($Typeface -eq '+mj-lt') { return "$($Fonts.major)" }
    if ($Typeface -eq '+mn-lt') { return "$($Fonts.minor)" }
    $Typeface
}

function Merge-PptxRunLook($Base, $Level, $Colors, $Fonts) {
    # A text style level (a:lvlNpPr) over a run look @{ size; bold; color; scheme; font; fontRef }.
    $out = @{}; foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
    if (-not $Level) { return $out }
    $d = $Level.SelectSingleNode("*[local-name()='defRPr']")
    if (-not $d) { return $out }
    if ($d.HasAttribute('sz')) { $out.size = [int]$d.GetAttribute('sz') }
    if ($d.HasAttribute('b')) { $out.bold = ($d.GetAttribute('b') -in '1', 'true') }
    $fill = $d.SelectSingleNode("*[local-name()='solidFill']")
    if ($fill) { $c = Resolve-PptxColour $fill $Colors; if ($c) { $out.color = $c; $out.scheme = Get-PptxSchemeName $fill } }
    $lat = $d.SelectSingleNode("*[local-name()='latin']")
    if ($lat -and $lat.GetAttribute('typeface')) { $out.fontRef = $lat.GetAttribute('typeface'); $out.font = Get-PptxFontName $out.fontRef $Fonts }
    $out
}

function Read-PptxTableStyleLook($Style, $Colors) {
    # The colours a table style draws with: header fill and text, body fill and text, band fill, lines.
    $pick = { param($part, $path) $n = $Style.SelectSingleNode("*[local-name()='$part']/$path"); if ($n) { Resolve-PptxColour $n $Colors } else { '' } }
    $txt = { param($part) $n = $Style.SelectSingleNode("*[local-name()='$part']/*[local-name()='tcTxStyle']"); if ($n) { Resolve-PptxColour $n $Colors } else { '' } }
    $fill = "*[local-name()='tcStyle']/*[local-name()='fill']/*[local-name()='solidFill']"
    $hb = $Style.SelectSingleNode("*[local-name()='firstRow']/*[local-name()='tcTxStyle']")
    @{
        headerFill = (& $pick 'firstRow' $fill); headerText = (& $txt 'firstRow'); headerBold = [bool]($hb -and $hb.GetAttribute('b') -eq 'on')
        bodyFill = (& $pick 'wholeTbl' $fill); text = (& $txt 'wholeTbl'); band = (& $pick 'band1H' $fill)
        line = (& $pick 'wholeTbl' "*[local-name()='tcStyle']/*[local-name()='tcBdr']/*[local-name()='insideH']/*[local-name()='ln']/*[local-name()='solidFill']")
    }
}

function Get-PptxAccentTableLook([int]$Accent, $Colors) {
    # PowerPoint's Medium Style 2 in one accent: a filled header with light text, tinted rows.
    $a = "$($Colors["accent$Accent"])"; if ($a.Length -ne 6) { $a = '4472C4' }
    $lt = "$($Colors.lt1)"; if ($lt.Length -ne 6) { $lt = 'FFFFFF' }
    $dk = "$($Colors.dk1)"; if ($dk.Length -ne 6) { $dk = '000000' }
    @{ headerFill = $a; headerText = $lt; headerBold = $true; bodyFill = (Set-PptxLuminance $a 0.2 0.8); text = $dk; band = (Set-PptxLuminance $a 0.4 0.6); line = $lt }
}

function Read-PptxTemplateShapes($Package, $Colors, $Size) {
    <# The plain filled shapes the template itself uses (on its master, layouts and slides): geometry,
       fill, line. Placeholders, pictures, full-slide backgrounds and specks are left out; at most four,
       largest first, one per geometry and colours. #>
    $parts = @(foreach ($p in @($Package.GetParts())) { if ("$($p.ContentType)" -match 'slideMaster\+xml|slideLayout\+xml|slide\+xml') { $p } })
    $seen = @{}; $found = New-Object Collections.Generic.List[object]
    $area = [double]$Size.cx * [double]$Size.cy
    foreach ($part in $parts) {
        $x = Read-PptxPartXml $part; $ns = Get-PptxNs $x
        $tree = $x.SelectSingleNode('/*/p:cSld/p:spTree', $ns)
        if (-not $tree) { continue }
        foreach ($sp in @(Get-PptxTreeItems $tree $ns)) {
            if ($sp.LocalName -ne 'sp' -or (Get-PptxPh $sp $ns)) { continue }
            $geom = $sp.SelectSingleNode('p:spPr/a:prstGeom', $ns); $fill = $sp.SelectSingleNode('p:spPr/a:solidFill', $ns)
            $r = Get-PptxRect (Get-PptxShapeXfrm $sp $ns)
            if (-not $geom -or -not $fill -or -not $r -or -not $r.cx -or -not $r.cy) { continue }
            $f = $r.cx * [double]$r.cy / $area
            if ($f -lt 0.005 -or ($r.cx -ge 0.9 * $Size.cx -and $r.cy -ge 0.9 * $Size.cy)) { continue }
            $hex = Resolve-PptxColour $fill $Colors
            if (-not $hex) { continue }
            $lnFill = $sp.SelectSingleNode('p:spPr/a:ln/a:solidFill', $ns); $ln = $sp.SelectSingleNode('p:spPr/a:ln', $ns)
            $line = if ($lnFill) { Resolve-PptxColour $lnFill $Colors } else { '' }
            $noLine = [bool]($ln -and $ln.SelectSingleNode('a:noFill', $ns))
            $prst = $geom.GetAttribute('prst')
            $key = "$prst|$hex|$line"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = 1
            $adj = @(foreach ($gd in @($geom.SelectNodes('a:avLst/a:gd', $ns))) { @{ name = $gd.GetAttribute('name'); fmla = $gd.GetAttribute('fmla') } })
            $found.Add(@{ prst = $prst; adj = $adj; fill = $hex; scheme = (Get-PptxSchemeName $fill); line = $line; lineScheme = (Get-PptxSchemeName $lnFill); noLine = $noLine
                    lineW = $(if ($ln -and $ln.HasAttribute('w')) { [int]$ln.GetAttribute('w') } else { 12700 }); ratio = ($r.cx / [double]$r.cy); area = $f })
        }
    }
    @($found | Sort-Object @{ Expression = { $_.area }; Descending = $true } | Select-Object -First 4)
}

function Get-PptxKitLook([hashtable]$Tokens) {
    <# The UI kit's tokens as DrawingML values: colours 'RRGGBB', the font's first family, radii in px.
       Tokens: name (without --kit-) -> CSS value (UiKit Get-TokenValues). @{} without tokens. #>
    if (-not $Tokens -or -not $Tokens.Count) { return @{} }
    $c = @{}
    foreach ($k in 'surface', 'surface-2', 'border', 'text', 'text-muted', 'accent', 'accent-soft', 'chart-1', 'chart-2', 'chart-3', 'chart-4', 'chart-5', 'chart-6') { $c[$k] = ConvertTo-PptxHex "$($Tokens[$k])" }
    $px = { param($v, $d) $m = [regex]::Match("$v", '^\s*([\d.]+)px'); if ($m.Success) { [double]$m.Groups[1].Value } else { $d } }
    $font = (("$($Tokens['font'])" -split ',')[0]).Trim().Trim('"', "'")
    @{ colors = $c; font = $(if ($font) { $font } else { 'Arial' }); radius = (& $px $Tokens['radius'] 6); radiusLg = (& $px $Tokens['radius-lg'] 10)
        palette = @(foreach ($i in 1..6) { $v = $c["chart-$i"]; if ($v) { $v } }) }
}

function Read-PptxTemplateLook {
    <# What the template's own styles look like, for the choices and their previews: theme colours and
       fonts, the slide background, the text styles (title from a title-and-content layout, subtitle
       from the title slide layout, body levels 1 and 2 from the master), its table styles with their
       colours, the filled shapes it uses, and (with Tokens) the UI kit's look. #>
    param([Parameter(Mandatory)][string]$Path, [hashtable]$KitTokens = @{})
    $pkg = Open-PptxPackage $Path
    try {
        $theme = @(Read-PptxThemes $pkg)[0]
        $colors = @{ dk1 = '000000'; lt1 = 'FFFFFF'; dk2 = '44546A'; lt2 = 'E7E6E6' }
        $fonts = @{ major = 'Calibri Light'; minor = 'Calibri' }
        if ($theme) { foreach ($k in $theme.colors.Keys) { $colors[$k] = $theme.colors[$k] }; foreach ($k in $theme.fonts.Keys) { $fonts[$k] = $theme.fonts[$k] } }
        $pres = Get-PptxPresentationPart $pkg
        $px = Read-PptxPartXml $pres; $pns = Get-PptxNs $px
        $sz = $px.SelectSingleNode('/p:presentation/p:sldSz', $pns)
        $size = @{ cx = $(if ($sz) { [long]$sz.GetAttribute('cx') } else { 9144000 }); cy = $(if ($sz) { [long]$sz.GetAttribute('cy') } else { 6858000 }) }
        $master = Get-PptxRelatedPart $pkg $pres 'slideMaster'
        $mx = Read-PptxPartXml $master; $mns = Get-PptxNs $mx
        $bg = ''
        $bgFill = $mx.SelectSingleNode('/p:sldMaster/p:cSld/p:bg/p:bgPr/a:solidFill', $mns)
        $bgRef = $mx.SelectSingleNode('/p:sldMaster/p:cSld/p:bg/p:bgRef', $mns)
        if ($bgFill) { $bg = Resolve-PptxColour $bgFill $colors } elseif ($bgRef) { $bg = Resolve-PptxColour $bgRef $colors }
        if (-not $bg) { $bg = $colors.lt1 }
        $tx = $mx.SelectSingleNode('/p:sldMaster/p:txStyles', $mns)
        $lvl = { param($style, $n) if ($tx) { $tx.SelectSingleNode("p:$style/a:lvl${n}pPr", $mns) } else { $null } }
        $text = @{
            title = (Merge-PptxRunLook @{ size = 4400; bold = $false; color = $colors.dk1; scheme = 'tx1'; font = $fonts.major; fontRef = '+mj-lt' } (& $lvl 'titleStyle' 1) $colors $fonts)
            body1 = (Merge-PptxRunLook @{ size = 2800; bold = $false; color = $colors.dk1; scheme = 'tx1'; font = $fonts.minor; fontRef = '+mn-lt' } (& $lvl 'bodyStyle' 1) $colors $fonts)
        }
        $text.body2 = Merge-PptxRunLook (Merge-PptxRunLook $text.body1 $null $colors $fonts) (& $lvl 'bodyStyle' 2) $colors $fonts
        if (-not (& $lvl 'bodyStyle' 2)) { $text.body2.size = [int]($text.body1.size * 0.86) }
        $text.subtitle = Merge-PptxRunLook $text.body1 $null $colors $fonts; $text.subtitle.size = 2400
        # Layout overrides: the title of a title-and-content layout, the subtitle of the title slide layout.
        $layouts = @(Read-PptxLayouts $pkg)
        $pickLayout = { param([string[]]$purposes) foreach ($pu in $purposes) { $l = @($layouts | Where-Object { $_.purpose -eq $pu })[0]; if ($l) { return $l } }; $null }
        foreach ($want in @(@('title', @('Title and Content', 'Title Only', 'Section Header'), 'title|ctrTitle'), @('subtitle', @('Title Slide'), 'subTitle'))) {
            $l = & $pickLayout $want[1]
            if (-not $l) { continue }
            $lx = Read-PptxPartXml ($pkg.GetPart((New-Object Uri($l.uri, [UriKind]::Relative)))); $lns = Get-PptxNs $lx
            foreach ($sp in @(Get-PptxTreeItems $lx.SelectSingleNode('/p:sldLayout/p:cSld/p:spTree', $lns) $lns)) {
                $ph = Get-PptxPh $sp $lns
                if (-not $ph -or $ph.type -notmatch "^($($want[2]))$") { continue }
                $text[$want[0]] = Merge-PptxRunLook $text[$want[0]] $sp.SelectSingleNode('p:txBody/a:lstStyle/a:lvl1pPr', $lns) $colors $fonts
                break
            }
        }
        # Table styles: the custom ones, the template's default, else PowerPoint's accent style in its colours.
        $tables = New-Object Collections.Generic.List[object]
        $tsPart = Get-PptxRelatedPart $pkg $pres 'tableStyles'
        $def = ''
        if ($tsPart) {
            $tsx = Read-PptxPartXml $tsPart; $def = $tsx.DocumentElement.GetAttribute('def')
            foreach ($s in @($tsx.SelectNodes("/*[local-name()='tblStyleLst']/*[local-name()='tblStyle']"))) {
                $tables.Add(@{ id = $s.GetAttribute('styleId'); name = $s.GetAttribute('styleName'); look = (Read-PptxTableStyleLook $s $colors); isDefault = ($s.GetAttribute('styleId') -eq $def) })
            }
        }
        if ($def -and $def -notin $script:PlainTableStyles -and -not @($tables | Where-Object { $_.id -eq $def }).Count) {
            $acc = if ($script:AccentTableStyles.ContainsKey($def)) { $script:AccentTableStyles[$def] } else { 1 }
            $tables.Add(@{ id = $def; name = 'the template''s default table style'; look = (Get-PptxAccentTableLook $acc $colors); isDefault = $true })
        }
        if (-not $tables.Count) { $tables.Add(@{ id = $script:AccentTableStyle; name = 'accent table in the template''s colours'; look = (Get-PptxAccentTableLook 1 $colors); isDefault = $true }) }
        @{
            colors = $colors; fonts = $fonts; bg = $bg.ToUpperInvariant(); size = $size; text = $text
            tables = @($tables | Sort-Object @{ Expression = { -not $_.isDefault } }); shapes = @(Read-PptxTemplateShapes $pkg $colors $size)
            kit = (Get-PptxKitLook $KitTokens)
        }
    } finally { $pkg.Close() }
}

# --------------------------------------------------------------------------- previews

function New-PptxDrawing([double]$W, [double]$H, [string]$Bg, $Items) {
    # A preview the app draws as SVG: a box of W x H points on the slide background, with items
    # (rect / roundRect / ellipse / text) in points. Sent as a JSON string, so the event stays shallow.
    # A List of hashtables cannot go through @() in 5.1 ("Argument types do not match").
    $list = if ($Items -is [Collections.Generic.List[object]]) { $Items.ToArray() } else { @($Items) }
    ConvertTo-Json -Compress -Depth 8 -InputObject @{ w = [Math]::Round($W, 1); h = [Math]::Round($H, 1); bg = $Bg; items = $list }
}

function New-PptxRun([string]$Text, $Look) {
    @{ text = $Text; font = "$($Look.font)"; size = [Math]::Round([double]$Look.size / 100, 1); bold = [bool]$Look.bold; color = "$($Look.color)" }
}

function Get-PptxShapeKind([string]$Prst) {
    if ($Prst -match '^(ellipse|circle)$') { return 'ellipse' }
    if ($Prst -match '^(roundRect|round\w*Rect)$') { return 'roundRect' }
    'rect'
}

function New-PptxBoxItem($Box, $Fill, $Line, [double]$LineW, [string]$Prst, [double]$Radius, $Runs) {
    @{ type = (Get-PptxShapeKind $Prst); x = 0; y = 0; w = $Box.w; h = $Box.h; fill = "$Fill"; line = "$Line"; lineW = $LineW; radius = $Radius; runs = @($Runs) }
}

function New-PptxTableDrawing($Look, [string]$Bg, $Font) {
    # Three rows of three cells in the style's colours.
    $items = New-Object Collections.Generic.List[object]
    $cw = 52; $rh = 22
    for ($r = 0; $r -lt 3; $r++) {
        $fill = if ($r -eq 0) { $Look.headerFill } elseif ($r -eq 2 -and $Look.band) { $Look.band } else { $Look.bodyFill }
        $col = if ($r -eq 0) { $Look.headerText } else { $Look.text }
        if (-not $col) { $col = '000000' }
        for ($c = 0; $c -lt 3; $c++) {
            $t = if ($r -eq 0) { @('Name', 'Q1', 'Q2')[$c] } else { @('Item', '12', '34')[$c] }
            $items.Add(@{ type = 'rect'; x = 4 + $c * $cw; y = 4 + $r * $rh; w = $cw; h = $rh; fill = "$fill"; line = "$($Look.line)"; lineW = 0.75; radius = 0; runs = @(@{ text = $t; font = "$Font"; size = 9; bold = [bool]($r -eq 0 -and $Look.headerBold); color = "$col" }) })
        }
    }
    New-PptxDrawing 164 74 $Bg $items
}

function New-PptxChartDrawing($Palette, [string]$Bg) {
    # Three groups of bars, one colour per series.
    $items = New-Object Collections.Generic.List[object]
    $n = [Math]::Max(1, [Math]::Min(4, @($Palette).Count))
    $hs = @(0.55, 0.8, 0.4, 0.65)
    for ($g = 0; $g -lt 3; $g++) {
        for ($s = 0; $s -lt $n; $s++) {
            $h = 60 * $hs[($s + $g) % 4]
            $items.Add(@{ type = 'rect'; x = 10 + $g * 50 + $s * (40 / $n); y = 70 - $h; w = (40 / $n) - 2; h = $h; fill = "$(@($Palette)[$s])"; line = ''; lineW = 0; radius = 0; runs = @() })
        }
    }
    $items.Add(@{ type = 'rect'; x = 6; y = 70; w = 152; h = 0.75; fill = '808080'; line = ''; lineW = 0; radius = 0; runs = @() })
    New-PptxDrawing 164 78 $Bg $items
}

# --------------------------------------------------------------------------- finding what is not formatted

function Get-PptxRunsLook($Shape, $Ns) {
    # How a shape's text looks now: the largest run size, whether every run is default (no font or
    # typed colour of its own), the first run's colour element and font.
    $max = 0; $own = $false; $firstFill = $null; $font = ''
    foreach ($rp in @($Shape.SelectNodes('.//a:r/a:rPr|.//a:fld/a:rPr|.//a:lstStyle//a:defRPr', $Ns))) {
        if ($rp.HasAttribute('sz')) { $v = [int]$rp.GetAttribute('sz'); if ($v -gt $max) { $max = $v } }
        $lat = $rp.SelectSingleNode('a:latin', $Ns)
        if ($lat -and $lat.GetAttribute('typeface') -and $lat.GetAttribute('typeface') -notmatch '^\+m[jn]-') { $own = $true; if (-not $font) { $font = $lat.GetAttribute('typeface') } }
        $f = $rp.SelectSingleNode('a:solidFill', $Ns)
        if ($f) { if (-not $firstFill) { $firstFill = $f }; if ($f.SelectSingleNode('a:srgbClr', $Ns)) { $own = $true } }
    }
    @{ max = $max; own = $own; fill = $firstFill; font = $font }
}

function Get-PptxTextColour($Shape, $Ns, $Runs, $Maps, $Colors) {
    # The colour the shape's text will have on the template: its own (a typed one through the theme
    # map, a scheme one through the template's theme), else its style's font colour, else dark 1.
    if ($Runs.fill) {
        $srgb = $Runs.fill.SelectSingleNode('a:srgbClr', $Ns)
        if ($srgb) { $v = $srgb.GetAttribute('val').ToUpperInvariant(); if ($Maps.colors.ContainsKey($v)) { return $Maps.colors[$v] }; return $v }
        $c = Resolve-PptxColour $Runs.fill $Colors; if ($c) { return $c }
    }
    $fr = $Shape.SelectSingleNode('p:style/a:fontRef', $Ns)
    if ($fr) { $c = Resolve-PptxColour $fr $Colors; if ($c) { return $c } }
    "$($Colors.dk1)"
}

function Test-PptxLargeText([double]$SizePt, [bool]$Bold) { ($SizePt -ge 18) -or ($Bold -and $SizePt -ge 14) }

function Test-PptxReadable([string]$Text, [string]$Back, [double]$SizePt, [bool]$Bold) {
    # WCAG AA: 4.5:1, or 3:1 for large text (18 pt, or 14 pt bold).
    $need = if (Test-PptxLargeText $SizePt $Bold) { 3 } else { 4.5 }
    (Get-PptxContrast $Text $Back) -ge $need
}

function Get-PptxBox($Shape, $Ns, $Emu) {
    $r = Get-PptxRect (Get-PptxShapeXfrm $Shape $Ns)
    if (-not $r) { return @{ w = 200; h = 60 } }
    @{ w = [Math]::Max([double]20, [Math]::Round($r.cx / $Emu, 1)); h = [Math]::Max([double]12, [Math]::Round($r.cy / $Emu, 1)) }
}

function Get-PptxShortText([string]$Text) { if ($Text.Length -gt 40) { $Text.Substring(0, 39) + '...' } else { $Text } }

function Add-PptxOption($List, [string]$Id, [string]$Label, [string]$Group, [string]$Drawing, $Apply, [double]$KindMatch = 0, [double]$SizeDiff = 0, [double]$ColourDist = 0) {
    $List.Add(@{ id = $Id; label = $Label; group = $Group; drawing = $Drawing; apply = $Apply; kindMatch = $KindMatch; sizeDiff = $SizeDiff; colourDist = $ColourDist })
}

function Select-PptxRanked($Options) {
    # Same kind first, then size and role, then the nearest colour; Keep as it is always last.
    @($Options | Sort-Object @{ Expression = { $_.group -eq 'keep' } }, @{ Expression = { $_.kindMatch }; Descending = $true }, @{ Expression = { $_.sizeDiff } }, @{ Expression = { $_.colourDist } })
}

function Get-PptxTextOptions($El, $Look, $Text, [string]$Back, [switch]$Heading) {
    # A text box or a heading: the template's text styles, nearest in size first (a heading: the title first).
    $out = New-Object Collections.Generic.List[object]
    $cur = if ($El.size) { [double]$El.size } else { 1800 }
    $body = ($El.paras -ge 2 -or $Text.Length -gt 80)
    $styles = @(@('title', 'the template''s title style'), @('subtitle', 'the template''s subtitle style'), @('body1', 'the template''s body text'), @('body2', 'the template''s body text, level 2'))
    foreach ($s in $styles) {
        $l = $Look.text[$s[0]]
        if (-not (Test-PptxReadable "$($l.color)" $Back ($l.size / 100) ([bool]$l.bold))) { continue }
        $role = if ($Heading) { [double]($s[0] -ne 'title') } elseif ($body) { [double]($s[0] -notlike 'body*') } else { 0 }
        $diff = [Math]::Abs($l.size - $cur) / [Math]::Max($l.size, $cur) + $role
        $label = ($s[1].Substring(0, 1).ToUpperInvariant() + $s[1].Substring(1))
        Add-PptxOption $out "text:$($s[0])" $label 'template' (New-PptxDrawing $El.box.w $El.box.h $Back @(@{ type = 'text'; x = 0; y = 0; w = $El.box.w; h = $El.box.h; fill = ''; line = ''; lineW = 0; radius = 0; runs = @(New-PptxRun $Text $l) })) @{ text = $l } 1 $diff 0
    }
    $out
}

function Get-PptxShapeOptions($El, $Look, $Text, [string]$TextColour, [double]$TextPt, [bool]$TextBold) {
    # A shape filled with a typed colour: the template's nearest theme colours (the shape kept), the
    # shapes the template uses, and the UI kit's panel, notice and badge.
    $out = New-Object Collections.Generic.List[object]
    $runs = { param($col) if ($Text) { @(@{ text = $Text; font = "$($Look.fonts.minor)"; size = [Math]::Max([double]6, $TextPt); bold = $TextBold; color = "$col" }) } else { @() } }
    $ok = { param($fill, $col) (-not $Text) -or (Test-PptxReadable $col $fill $TextPt $TextBold) }
    $near = @(foreach ($slot in $script:ShapeColourSlots) { $v = "$($Look.colors[$slot])"; if ($v.Length -eq 6) { @{ slot = $slot; hex = $v; d = (Get-PptxColourDistance $El.fill $v) } } })
    foreach ($n in @($near | Sort-Object { $_.d } | Select-Object -First 3)) {
        if (-not (& $ok $n.hex $TextColour)) { continue }
        Add-PptxOption $out "theme:$($n.slot)" "Template colour $($n.slot)" 'template' (New-PptxDrawing $El.box.w $El.box.h $Look.bg @(New-PptxBoxItem $El.box $n.hex $El.line 0.75 $El.prst 0 (& $runs $TextColour))) @{ fillScheme = $n.slot; fill = $n.hex } 1 0 $n.d
    }
    $i = 0
    foreach ($s in @($Look.shapes)) {
        $i++
        if (-not (& $ok $s.fill $TextColour)) { continue }
        $ratio = $El.box.w / [Math]::Max([double]1, $El.box.h)
        $label = if ($s.prst -match '(?i)callout') { 'Template callout' } elseif ($s.ratio -ge 5 -or $s.ratio -le 0.2) { 'Template band' } elseif ($s.prst -match '^round') { 'Template rounded box' } else { "Template shape ($($s.prst))" }
        $radius = if ($s.prst -eq 'roundRect') { [Math]::Min($El.box.w, $El.box.h) * 0.1667 } else { 0 }
        Add-PptxOption $out "tplshape:$i" $label 'template' (New-PptxDrawing $El.box.w $El.box.h $Look.bg @(New-PptxBoxItem $El.box $s.fill $(if ($s.noLine) { '' } else { $s.line }) ($s.lineW / $script:EmuPerPt) $s.prst $radius (& $runs $TextColour))) @{ shape = $s } ([double]($s.prst -eq $El.prst)) ([Math]::Min(1, [Math]::Abs([Math]::Log([Math]::Max(0.01, $s.ratio) / [Math]::Max(0.01, $ratio))) / 3)) (Get-PptxColourDistance $El.fill $s.fill)
    }
    $k = $Look.kit
    if ($k -and $k.colors) {
        $kc = $k.colors
        $kits = @(
            @('kit-panel', 'UI kit panel', $kc.surface, $kc.border, $k.radiusLg, $kc.text, $false),
            @('kit-notice', 'UI kit notice', $kc['surface-2'], $kc.border, $k.radius, $kc.text, $false),
            @('kit-badge', 'UI kit badge', $kc['surface-2'], '', 999, $kc['text-muted'], $true))
        foreach ($kd in $kits) {
            if (-not $kd[2] -or -not (& $ok $kd[2] $kd[5])) { continue }
            $rpt = [Math]::Min([Math]::Min($El.box.w, $El.box.h) / 2, $kd[4] * 0.75)
            $kr = if ($Text) { @(@{ text = $Text; font = "$($k.font)"; size = [Math]::Max([double]6, $TextPt); bold = [bool]$kd[6]; color = "$($kd[5])" }) } else { @() }
            Add-PptxOption $out $kd[0] $kd[1] 'kit' (New-PptxDrawing $El.box.w $El.box.h $Look.bg @(@{ type = 'roundRect'; x = 0; y = 0; w = $El.box.w; h = $El.box.h; fill = "$($kd[2])"; line = "$($kd[3])"; lineW = 0.75; radius = $rpt; runs = $kr })) @{ fill = $kd[2]; line = $kd[3]; radiusPx = $kd[4]; textColor = $kd[5]; bold = $kd[6]; font = $k.font } ([double]($El.prst -eq 'roundRect')) 0.5 (Get-PptxColourDistance $El.fill $kd[2])
        }
    }
    $out
}

function Get-PptxTableOptions($Look) {
    $out = New-Object Collections.Generic.List[object]
    $i = 0
    foreach ($t in @($Look.tables)) {
        $i++
        $name = if ($t.name) { $t.name } else { 'a template table style' }
        Add-PptxOption $out "tblstyle:$($t.id)" ('Template: ' + $name) 'template' (New-PptxTableDrawing $t.look $Look.bg $Look.fonts.minor) @{ styleId = $t.id } 1 ($i / 100) 0
    }
    $k = $Look.kit
    if ($k -and $k.colors -and $k.colors.surface) {
        $kl = @{ headerFill = $k.colors['surface-2']; headerText = $k.colors['text-muted']; headerBold = $true; bodyFill = $k.colors.surface; text = $k.colors.text; band = ''; line = $k.colors.border }
        Add-PptxOption $out 'kit-table' 'UI kit table' 'kit' (New-PptxTableDrawing $kl $Look.bg $k.font) @{ styleId = $script:KitTableStyleId; kit = $kl } 0 0 0
    }
    $out
}

function Get-PptxChartOptions($Look, [int]$Series) {
    $out = New-Object Collections.Generic.List[object]
    $acc = @(foreach ($i in 1..6) { $v = "$($Look.colors["accent$i"])"; if ($v.Length -eq 6) { $v } })
    if ($acc.Count) { Add-PptxOption $out 'chart:accents' 'The template''s accent colours, in order' 'template' (New-PptxChartDrawing @($acc | Select-Object -First ([Math]::Max(1, $Series))) $Look.bg) @{ palette = 'accents' } 1 0 0 }
    $k = $Look.kit
    # @($null).Count is 1: a look without kit tokens has no palette and offers no kit chart colours.
    if ($k -and @($k.palette | Where-Object { $_ }).Count) { Add-PptxOption $out 'chart:kit' 'The UI kit''s chart colours' 'kit' (New-PptxChartDrawing @($k.palette | Select-Object -First ([Math]::Max(1, $Series))) $Look.bg) @{ palette = 'kit'; colors = @($k.palette) } 0 0 0 }
    $out
}

function Get-PptxChartPart($Package, $SlidePart, $Frame, $Ns) {
    $c = $Frame.SelectSingleNode(".//*[local-name()='chart' and namespace-uri()='$script:NsC']")
    if (-not $c) { return $null }
    $rid = $c.GetAttribute('id', $script:NsRel)
    if (-not $rid -or -not $SlidePart.RelationshipExists($rid)) { return $null }
    $u = Get-PptxRelTarget $SlidePart ($SlidePart.GetRelationship($rid))
    if ($Package.PartExists($u)) { $Package.GetPart($u) } else { $null }
}

function Get-PptxTypedSeries($ChartXml, $Maps) {
    # Series (and points) whose colour was typed by hand: an srgbClr that is not one of the deck's theme colours.
    $n = 0; $typed = $false
    foreach ($ser in @($ChartXml.SelectNodes("//*[local-name()='ser']"))) {
        $n++
        foreach ($s in @($ser.SelectNodes(".//*[local-name()='spPr']//*[local-name()='srgbClr']"))) { if (-not $Maps.colors.ContainsKey($s.GetAttribute('val').ToUpperInvariant())) { $typed = $true } }
    }
    @{ series = $n; typed = $typed }
}

function New-PptxElement([int]$Slide, $Shape, $Ns, [string]$Kind, [string]$Text, $Box) {
    $id = [int]$Shape.SelectSingleNode('./*/p:cNvPr', $Ns).GetAttribute('id')
    @{ key = "${Slide}:$id"; slide = $Slide; id = $id; kind = $Kind; text = (Get-PptxShortText $Text); box = $Box; options = @(); default = 'keep' }
}

function Get-PptxFrameElement($Package, $Part, $Sp, $Ns, [int]$Index, $Look, $Maps) {
    # A table without a style, or a chart with hand-typed series colours.
    $uri = "$($Sp.SelectSingleNode('a:graphic/a:graphicData', $Ns).GetAttribute('uri'))"
    if ($uri -match '/table$') {
        $sid = "$($Sp.SelectSingleNode('a:graphic/a:graphicData/a:tbl/a:tblPr/a:tableStyleId', $Ns).InnerText)".Trim()
        if ($sid -and $sid -notin $script:PlainTableStyles) { return $null }
        $el = New-PptxElement $Index $Sp $Ns 'table' '' (Get-PptxBox $Sp $Ns $script:EmuPerPt)
        $el.label = "Table ($(@($Sp.SelectNodes('.//a:tr', $Ns)).Count) x $(@($Sp.SelectNodes('.//a:gridCol', $Ns)).Count))$(if ($sid) { ', plain style' } else { ', no style' })"
        $el.all = @(Get-PptxTableOptions $Look)
        return $el
    }
    if ($uri -match 'chart') {
        $cp = Get-PptxChartPart $Package $Part $Sp $Ns
        if (-not $cp) { return $null }
        $t = Get-PptxTypedSeries (Read-PptxPartXml $cp) $Maps
        if (-not $t.typed) { return $null }
        $el = New-PptxElement $Index $Sp $Ns 'chart' '' (Get-PptxBox $Sp $Ns $script:EmuPerPt)
        $el.label = "Chart with typed series colours ($($t.series) series)"
        $el.all = @(Get-PptxChartOptions $Look $t.series)
        return $el
    }
    $null
}

function Get-PptxShapeElement($Sp, $Ns, [int]$Index, $Look, $Maps, [bool]$IsHeading, [int]$PlanHeading) {
    # A free shape: a hand-typed fill close to no template colour, a heading box, or a text box in the default look.
    $text = Get-PptxText $Sp $Ns
    $runs = Get-PptxRunsLook $Sp $Ns
    $box = Get-PptxBox $Sp $Ns $script:EmuPerPt
    $fill = $Sp.SelectSingleNode('p:spPr/a:solidFill', $Ns)
    $alpha = if ($fill) { $fill.SelectSingleNode('*/a:alpha', $Ns) } else { $null }
    $opaque = $fill -and -not ($alpha -and [int]$alpha.GetAttribute('val') -lt 20000)
    $size = if ($runs.max) { $runs.max } else { 1800 }
    $tc = Get-PptxTextColour $Sp $Ns $runs $Maps $Look.colors
    if ($opaque) {
        $srgb = $fill.SelectSingleNode('a:srgbClr', $Ns)
        if (-not $srgb) { return $null }   # a theme colour follows the template by itself
        $hex = $srgb.GetAttribute('val').ToUpperInvariant()
        if ($Maps.colors.ContainsKey($hex)) { return $null }
        $min = 999; foreach ($v in $Look.colors.Values) { $d = Get-PptxColourDistance $hex "$v"; if ($d -lt $min) { $min = $d } }
        if ($min -le $script:NearColour) { return $null }
        $el = New-PptxElement $Index $Sp $Ns 'shape' $text $box
        $geom = $Sp.SelectSingleNode('p:spPr/a:prstGeom', $Ns)
        $el.fill = $hex; $el.prst = $(if ($geom) { $geom.GetAttribute('prst') } else { 'rect' }); $el.line = (Resolve-PptxColour $Sp.SelectSingleNode('p:spPr/a:ln/a:solidFill', $Ns) $Look.colors)
        $el.label = "Shape filled with #$hex$(if ($text) { ': ' + $el.text })"
        $bold = [bool]$Sp.SelectSingleNode('.//a:rPr[@b="1"]', $Ns)
        $el.all = @(Get-PptxShapeOptions $el $Look $el.text $tc ($size / 100) $bold)
        $el.keep = New-PptxDrawing $box.w $box.h $Look.bg @(New-PptxBoxItem $box $hex $el.line 0.75 $el.prst 0 $(if ($text) { @(@{ text = $el.text; font = "$($Look.fonts.minor)"; size = $size / 100; bold = $bold; color = $tc }) } else { @() }))
        return $el
    }
    if (-not $text) { return $null }
    $paras = @($Sp.SelectNodes('p:txBody/a:p', $Ns) | Where-Object { $_.InnerText.Trim() }).Count
    $curLook = @{ size = $size; bold = [bool]$Sp.SelectSingleNode('.//a:rPr[@b="1"]', $Ns); color = $tc; font = $(if ($runs.font) { $runs.font } else { $Look.fonts.minor }) }
    if ($IsHeading) {
        $el = New-PptxElement $Index $Sp $Ns 'heading' $text $box
        $el.size = $size; $el.paras = $paras
        $el.label = "Heading in a text box: $($el.text)"
        $opts = New-Object Collections.Generic.List[object]
        if ($el.id -eq $PlanHeading) {
            Add-PptxOption $opts 'title-placeholder' 'Move it into the title placeholder' 'template' (New-PptxDrawing $box.w $box.h $Look.bg @(@{ type = 'text'; x = 0; y = 0; w = $box.w; h = $box.h; fill = ''; line = ''; lineW = 0; radius = 0; runs = @(New-PptxRun $el.text $Look.text.title) })) @{} 2 0 0
            $el.default = 'title-placeholder'
        }
        foreach ($o in @(Get-PptxTextOptions $el $Look $el.text $Look.bg -Heading)) { if ($o.id -eq 'text:title') { $o.label = 'The template''s title style, where it is' }; $opts.Add($o) }
        $el.all = $opts.ToArray()
    } else {
        if ($runs.own) { return $null }
        $el = New-PptxElement $Index $Sp $Ns 'textbox' $text $box
        $el.size = $size; $el.paras = $paras
        $el.label = "Text box in the deck's default look: $($el.text)"
        $el.all = @(Get-PptxTextOptions $el $Look $el.text $Look.bg)
    }
    $el.keep = New-PptxDrawing $box.w $box.h $Look.bg @(@{ type = 'text'; x = 0; y = 0; w = $box.w; h = $box.h; fill = ''; line = ''; lineW = 0; radius = 0; runs = @(New-PptxRun $el.text $curLook) })
    $el
}

function Complete-PptxElement($El, $Look) {
    # Ranked options with Keep as it is last; what the card shows (no apply data).
    $opts = New-Object Collections.Generic.List[object]
    foreach ($o in @(Select-PptxRanked @($El.all))) { $opts.Add($o) }
    $keepDraw = if ($El.keep) { $El.keep } elseif ($El.kind -eq 'table') { New-PptxTableDrawing @{ headerFill = ''; headerText = '000000'; headerBold = $false; bodyFill = ''; text = '000000'; band = ''; line = '808080' } $Look.bg $Look.fonts.minor } else { New-PptxDrawing $El.box.w $El.box.h $Look.bg @() }
    Add-PptxOption $opts 'keep' 'Keep as it is' 'keep' $keepDraw @{} 0 0 0
    $El.all = $opts.ToArray()
    $El.options = @(foreach ($o in $opts) { @{ id = $o.id; label = $o.label; group = $o.group; drawing = $o.drawing } })
    $El
}

function Get-PptxElementChoices {
    <# Every element of the content deck that carries no brand formatting once it is on the template,
       with its ranked options: @{ elements = @(@{ key "N:id"; slide; id; kind; label; text; box;
       options = @(@{ id; label; group; drawing }); default; all (with apply data) }) }. A deck whose
       elements are all formatted gives none. Plan (Get-PptxRethemePlan) names the heading box the
       core makes the title. #>
    param([Parameter(Mandatory)][string]$ContentPath, [Parameter(Mandatory)]$Look, $Plan = $null)
    $pkg = Open-PptxPackage $ContentPath
    $out = New-Object Collections.Generic.List[object]
    try {
        $maps = Get-PptxThemeMaps @(Read-PptxThemes $pkg) @{ colors = $Look.colors; fonts = $Look.fonts }
        $pres = Get-PptxPresentationPart $pkg; $px = Read-PptxPartXml $pres; $pns = Get-PptxNs $px
        $i = 0
        foreach ($sid in @($px.SelectNodes('/p:presentation/p:sldIdLst/p:sldId', $pns))) {
            $i++
            $part = $pkg.GetPart((Get-PptxRelTarget $pres $pres.GetRelationship($sid.GetAttribute('id', $script:NsRel))))
            $x = Read-PptxPartXml $part; $ns = Get-PptxNs $x
            $heads = @(Find-PptxHeadings $x $ns | ForEach-Object { $_.id })
            $ps = if ($Plan) { @($Plan.slides | Where-Object { $_.index -eq $i })[0] } else { $null }
            $planHead = if ($ps) { [int]$ps.heading } else { 0 }
            foreach ($sp in @(Get-PptxTreeItems $x.SelectSingleNode('/p:sld/p:cSld/p:spTree', $ns) $ns)) {
                if (Get-PptxPh $sp $ns) { continue }
                $el = $null
                if ($sp.LocalName -eq 'graphicFrame') { $el = Get-PptxFrameElement $pkg $part $sp $ns $i $Look $maps }
                elseif ($sp.LocalName -eq 'sp') {
                    $id = [int]$sp.SelectSingleNode('p:nvSpPr/p:cNvPr', $ns).GetAttribute('id')
                    $el = Get-PptxShapeElement $sp $ns $i $Look $maps ($heads -contains $id) $planHead
                }
                if ($el) { $out.Add((Complete-PptxElement $el $Look)) }
            }
        }
    } finally { $pkg.Close() }
    @{ elements = $out.ToArray() }
}

function Get-PptxKindSummary($Elements) {
    # Per kind: how many elements and the options every one of them offers (for "all tables: ...").
    $out = New-Object Collections.Generic.List[object]
    foreach ($k in 'table', 'textbox', 'shape', 'chart', 'heading') {
        $els = @($Elements | Where-Object { $_.kind -eq $k })
        if (-not $els.Count) { continue }
        $common = New-Object Collections.Generic.List[object]
        foreach ($o in @($els[0].options)) {
            $everywhere = $true
            foreach ($e in $els) { if (-not @($e.options | Where-Object { $_.id -eq $o.id }).Count) { $everywhere = $false; break } }
            if ($everywhere) { $common.Add(@{ id = $o.id; label = $o.label }) }
        }
        $out.Add(@{ kind = $k; label = $script:KindNames[$k]; count = $els.Count; options = $common.ToArray() })
    }
    $out.ToArray()
}

function Add-PptxElementChoices {
    <# The plan step's elements: each slide of the plan gets elements = @(...) (without apply data), the
       plan gets kinds (Get-PptxKindSummary) and fonts (the typefaces the previews use, for the app's
       font check). Returns the plan. #>
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][string]$ContentPath, [hashtable]$KitTokens = @{})
    $look = Read-PptxTemplateLook $TemplatePath -KitTokens $KitTokens
    $found = Get-PptxElementChoices $ContentPath $look $Plan
    $view = @(foreach ($e in @($found.elements)) { @{ key = $e.key; slide = $e.slide; id = $e.id; kind = $e.kind; label = $e.label; options = @($e.options); default = $e.default } })
    foreach ($s in @($Plan.slides)) { $s.elements = @($view | Where-Object { $_.slide -eq $s.index }) }
    $Plan.kinds = @(Get-PptxKindSummary $view)
    $fonts = New-Object Collections.Generic.List[string]
    foreach ($f in @($look.fonts.major, $look.fonts.minor, $look.kit.font)) { if ($f -and -not $fonts.Contains("$f")) { $fonts.Add("$f") } }
    $Plan.fonts = $fonts.ToArray()
    $Plan
}

# --------------------------------------------------------------------------- applying the choices

function ConvertTo-PptxMap($Value) {
    # A JSON object or hashtable as a hashtable of strings.
    $h = @{}
    if (-not $Value) { return $h }
    if ($Value -is [hashtable]) { foreach ($k in $Value.Keys) { $h["$k"] = "$($Value[$k])" }; return $h }
    foreach ($p in @($Value.PSObject.Properties)) { $h["$($p.Name)"] = "$($p.Value)" }
    $h
}

function Resolve-PptxElementChoices {
    <# Which option each element takes: its own choice, else its kind's, when that option is offered
       for it; else its default. Returns @{ bySlide = @{ "N" = @(@{ id; kind; option }) }; titles =
       @{ "N" = 0 } for heading boxes that stay out of the title; count }. #>
    param([Parameter(Mandatory)]$Found, $Elements, $Kinds)
    $el = ConvertTo-PptxMap $Elements; $kd = ConvertTo-PptxMap $Kinds
    $by = @{}; $titles = @{}; $n = 0
    foreach ($e in @($Found.elements)) {
        $want = if ($el.ContainsKey($e.key)) { $el[$e.key] } elseif ($kd.ContainsKey($e.kind)) { $kd[$e.kind] } else { $e.default }
        $opt = @($e.all | Where-Object { $_.id -eq $want })[0]
        if (-not $opt) { $opt = @($e.all | Where-Object { $_.id -eq $e.default })[0] }
        if ($e.kind -eq 'heading' -and $e.default -eq 'title-placeholder' -and $opt.id -ne 'title-placeholder') { $titles["$($e.slide)"] = 0 }
        if ($opt.id -in 'keep', 'title-placeholder') { continue }
        if (-not $by.ContainsKey("$($e.slide)")) { $by["$($e.slide)"] = New-Object Collections.Generic.List[object] }
        $by["$($e.slide)"].Add(@{ id = $e.id; kind = $e.kind; option = $opt }); $n++
    }
    @{ bySlide = $by; titles = $titles; count = $n }
}

function Set-PptxChild($Parent, $Child, [string[]]$Before) {
    # Inserts Child before the first existing child named in Before (schema order), else at the end.
    foreach ($c in @($Parent.ChildNodes)) { if ($c.NodeType -eq [Xml.XmlNodeType]::Element -and $c.LocalName -in $Before) { $null = $Parent.InsertBefore($Child, $c); return } }
    $null = $Parent.AppendChild($Child)
}

function New-PptxColourFill([Xml.XmlDocument]$Doc, [string]$Hex, [string]$Scheme = '') {
    $f = $Doc.CreateElement('a', 'solidFill', $script:NsA)
    if ($Scheme) { $c = $Doc.CreateElement('a', 'schemeClr', $script:NsA) } else { $c = $Doc.CreateElement('a', 'srgbClr', $script:NsA) }
    $c.SetAttribute('val', $(if ($Scheme) { $Scheme } else { $Hex }))
    $null = $f.AppendChild($c)
    $f
}

$script:RunFillNames = @('noFill', 'solidFill', 'gradFill', 'blipFill', 'pattFill', 'grpFill')
$script:RunAfterFill = @('effectLst', 'effectDag', 'highlight', 'uLnTx', 'uLn', 'uFillTx', 'uFill', 'latin', 'ea', 'cs', 'sym', 'hlinkClick', 'hlinkMouseOver', 'rtl', 'extLst')
$script:RunAfterLatin = @('ea', 'cs', 'sym', 'hlinkClick', 'hlinkMouseOver', 'rtl', 'extLst')

function Set-PptxRunLook($Shape, $Ns, $Look, [switch]$ColourOnly) {
    <# Every run of a shape in a text look: size, bold, colour (a scheme colour when the style has one,
       so it follows the template), and typeface (a theme reference when the style has one). #>
    $doc = $Shape.OwnerDocument
    foreach ($r in @($Shape.SelectNodes('.//a:r|.//a:fld', $Ns))) {
        if (-not $r.SelectSingleNode('a:rPr', $Ns)) { $rp = $doc.CreateElement('a', 'rPr', $script:NsA); $null = $r.PrependChild($rp) }
    }
    foreach ($rp in @($Shape.SelectNodes('.//a:r/a:rPr|.//a:fld/a:rPr|.//a:p/a:endParaRPr', $Ns))) {
        if (-not $ColourOnly) {
            if ($Look.size) { $rp.SetAttribute('sz', [string][int]$Look.size) }
            $rp.SetAttribute('b', $(if ($Look.bold) { '1' } else { '0' }))
        }
        foreach ($c in @($rp.ChildNodes)) { if ($c.NodeType -eq [Xml.XmlNodeType]::Element -and $c.LocalName -in $script:RunFillNames) { $null = $rp.RemoveChild($c) } }
        if ($Look.color -or $Look.scheme) {
            $f = New-PptxColourFill $doc "$($Look.color)" "$($Look.scheme)"
            Set-PptxChild $rp $f $script:RunAfterFill
        }
        $font = if ($Look.fontRef) { "$($Look.fontRef)" } else { "$($Look.font)" }
        if (-not $ColourOnly -and $font) {
            $lat = $rp.SelectSingleNode('a:latin', $Ns)
            if (-not $lat) { $lat = $doc.CreateElement('a', 'latin', $script:NsA); Set-PptxChild $rp $lat $script:RunAfterLatin }
            $lat.SetAttribute('typeface', $font)
        }
    }
    foreach ($af in @($Shape.SelectNodes('.//a:normAutofit', $Ns))) { $af.RemoveAttribute('fontScale'); $af.RemoveAttribute('lnSpcReduction') }
}

$script:SpPrGeom = @('noFill', 'solidFill', 'gradFill', 'blipFill', 'pattFill', 'grpFill', 'ln', 'effectLst', 'effectDag', 'scene3d', 'sp3d', 'extLst')
$script:SpPrAfterFill = @('ln', 'effectLst', 'effectDag', 'scene3d', 'sp3d', 'extLst')
$script:SpPrAfterLine = @('effectLst', 'effectDag', 'scene3d', 'sp3d', 'extLst')

function Set-PptxShapeLook($Shape, $Ns, $Apply, $Look) {
    <# A shape in an option's look: a theme colour (the shape kept), a template shape (its geometry,
       fill and line), or a UI kit style (fill, line, corner radius as roundRect's adj, text colour). #>
    $doc = $Shape.OwnerDocument
    $sppr = $Shape.SelectSingleNode('p:spPr', $Ns)
    if (-not $sppr) { return }
    $geom = $null; $fill = $null; $line = $null; $lineW = 9525; $noLine = $false
    if ($Apply.fillScheme) { $fill = New-PptxColourFill $doc $Apply.fill $Apply.fillScheme }
    elseif ($Apply.shape) {
        $s = $Apply.shape
        $fill = New-PptxColourFill $doc $s.fill $s.scheme
        $geom = @{ prst = $s.prst; adj = @($s.adj) }
        if ($s.noLine) { $noLine = $true } elseif ($s.line) { $line = New-PptxColourFill $doc $s.line $s.lineScheme; $lineW = $s.lineW }
    } else {
        $fill = New-PptxColourFill $doc $Apply.fill
        $r = Get-PptxRect (Get-PptxShapeXfrm $Shape $Ns)
        $minEmu = if ($r) { [Math]::Max(1, [Math]::Min($r.cx, $r.cy)) } else { 914400 }
        $adj = [int][Math]::Min(50000, [Math]::Round(100000.0 * $Apply.radiusPx * 9525 / $minEmu))
        $geom = @{ prst = 'roundRect'; adj = @(@{ name = 'adj'; fmla = "val $adj" }) }
        if ($Apply.line) { $line = New-PptxColourFill $doc $Apply.line; $lineW = 9525 } else { $noLine = $true }
    }
    if ($geom) {
        foreach ($g in @($sppr.SelectNodes('a:prstGeom|a:custGeom', $Ns))) { $null = $sppr.RemoveChild($g) }
        $pg = $doc.CreateElement('a', 'prstGeom', $script:NsA); $pg.SetAttribute('prst', $geom.prst)
        $av = $doc.CreateElement('a', 'avLst', $script:NsA); $null = $pg.AppendChild($av)
        foreach ($a in @($geom.adj)) { if ($a.name) { $gd = $doc.CreateElement('a', 'gd', $script:NsA); $gd.SetAttribute('name', $a.name); $gd.SetAttribute('fmla', $a.fmla); $null = $av.AppendChild($gd) } }
        Set-PptxChild $sppr $pg $script:SpPrGeom
    }
    foreach ($c in @($sppr.ChildNodes)) { if ($c.NodeType -eq [Xml.XmlNodeType]::Element -and $c.LocalName -in $script:RunFillNames) { $null = $sppr.RemoveChild($c) } }
    Set-PptxChild $sppr $fill $script:SpPrAfterFill
    if ($line -or $noLine) {
        $old = $sppr.SelectSingleNode('a:ln', $Ns); if ($old) { $null = $sppr.RemoveChild($old) }
        $ln = $doc.CreateElement('a', 'ln', $script:NsA)
        if ($noLine) { $null = $ln.AppendChild($doc.CreateElement('a', 'noFill', $script:NsA)) } else { $ln.SetAttribute('w', [string][int]$lineW); $null = $ln.AppendChild($line) }
        Set-PptxChild $sppr $ln $script:SpPrAfterLine
    }
    if ($Apply.textColor) { Set-PptxRunLook $Shape $Ns @{ color = $Apply.textColor; font = $Apply.font; bold = $Apply.bold } -ColourOnly }
}

function Set-PptxTableStyle($Frame, $Ns, [string]$StyleId) {
    $tbl = $Frame.SelectSingleNode('a:graphic/a:graphicData/a:tbl', $Ns)
    if (-not $tbl) { return }
    $doc = $Frame.OwnerDocument
    $pr = $tbl.SelectSingleNode('a:tblPr', $Ns)
    if (-not $pr) { $pr = $doc.CreateElement('a', 'tblPr', $script:NsA); $null = $tbl.PrependChild($pr) }
    if (-not $pr.HasAttribute('firstRow')) { $pr.SetAttribute('firstRow', '1') }
    if (-not $pr.HasAttribute('bandRow')) { $pr.SetAttribute('bandRow', '1') }
    $id = $pr.SelectSingleNode('a:tableStyleId', $Ns)
    if (-not $id) { $id = $doc.CreateElement('a', 'tableStyleId', $script:NsA); $null = $pr.AppendChild($id) }
    $id.InnerText = $StyleId
}

function Set-PptxSlideChoices($Job, [Xml.XmlDocument]$Xml, [int]$Index, $Part) {
    <# OnSlide: this slide's chosen options on its elements (found by shape id). Charts are noted for
       Complete-PptxChoices; a table that takes the kit's look marks the kit style as needed. #>
    $list = $Job.choices.resolved.bySlide["$Index"]
    if (-not $list) { return }
    $ns = Get-PptxNs $Xml
    $byId = @{}
    foreach ($sp in @(Get-PptxTreeItems $Xml.SelectSingleNode('/p:sld/p:cSld/p:spTree', $ns) $ns)) { $c = $sp.SelectSingleNode('./*/p:cNvPr', $ns); if ($c) { $byId[[int]$c.GetAttribute('id')] = $sp } }
    if (-not $Job.ContainsKey('choiceDone')) { $Job.choiceDone = 0; $Job.chartEdits = New-Object Collections.Generic.List[object] }
    foreach ($c in $list) {
        $sp = $byId[[int]$c.id]
        if (-not $sp) { "slide ${Index}: the $($script:KindNames[$c.kind]) chosen on the card was not found; it stays as it was."; continue }
        $a = $c.option.apply
        switch ($c.kind) {
            'table' { Set-PptxTableStyle $sp $ns $a.styleId; if ($a.kit) { $Job.kitTable = $a.kit } }
            'chart' {
                $cf = $sp.SelectSingleNode(".//*[local-name()='chart' and namespace-uri()='$script:NsC']")
                $rid = if ($cf) { $cf.GetAttribute('id', $script:NsRel) } else { '' }
                if ($rid -and $Part.RelationshipExists($rid)) { $Job.chartEdits.Add(@{ uri = (Get-PptxRelTarget $Part ($Part.GetRelationship($rid))); apply = $a }) }
            }
            'shape' { Set-PptxShapeLook $sp $ns $a $Job.choices.look }
            default { if ($a.text) { Set-PptxRunLook $sp $ns $a.text } }
        }
        $Job.choiceDone++
    }
}

function Set-PptxChartColours([Xml.XmlDocument]$Xml, $Apply) {
    # Each series (and each point of a pie) in the palette's colours in order: the template's accents as
    # scheme colours (they follow its theme), the kit's as typed colours.
    $n = 0
    $pal = @($Apply.colors)
    $fill = {
        param($spPr, [int]$i)
        $doc = $spPr.OwnerDocument
        $f = if ($Apply.palette -eq 'accents') { New-PptxColourFill $doc '' "accent$(($i % 6) + 1)" } else { New-PptxColourFill $doc "$($pal[$i % [Math]::Max(1, $pal.Count)])" }
        $ln = $spPr.SelectSingleNode("*[local-name()='ln']")
        $isLine = $spPr.ParentNode.ParentNode.LocalName -in 'lineChart', 'scatterChart', 'radarChart'
        if ($isLine) {
            if (-not $ln) { $ln = $doc.CreateElement('a', 'ln', $script:NsA); $null = $spPr.AppendChild($ln) }
            foreach ($c in @($ln.ChildNodes)) { if ($c.LocalName -in $script:RunFillNames) { $null = $ln.RemoveChild($c) } }
            $null = $ln.PrependChild($f)
            return
        }
        foreach ($c in @($spPr.ChildNodes)) { if ($c.NodeType -eq [Xml.XmlNodeType]::Element -and $c.LocalName -in $script:RunFillNames) { $null = $spPr.RemoveChild($c) } }
        Set-PptxChild $spPr $f $script:SpPrAfterFill
    }
    foreach ($ser in @($Xml.SelectNodes("//*[local-name()='ser' and namespace-uri()='$script:NsC']"))) {
        $spPr = $ser.SelectSingleNode("*[local-name()='spPr']")
        if (-not $spPr) {
            $spPr = $Xml.CreateElement('c', 'spPr', $script:NsC)
            $after = $ser.SelectSingleNode("*[local-name()='tx']"); if (-not $after) { $after = $ser.SelectSingleNode("*[local-name()='order']") }
            if ($after) { $null = $ser.InsertAfter($spPr, $after) } else { $null = $ser.PrependChild($spPr) }
        }
        & $fill $spPr $n
        foreach ($dpt in @($ser.SelectNodes("*[local-name()='dPt']"))) {
            $dsp = $dpt.SelectSingleNode("*[local-name()='spPr']")
            $ix = $dpt.SelectSingleNode("*[local-name()='idx']")
            if ($dsp -and $ix) { & $fill $dsp ([int]$ix.GetAttribute('val')) }
        }
        $n++
    }
    $n
}

function Add-PptxKitTableStyle($Package, $Kit) {
    # The UI kit's table look as a table style of the deck (once): header row in surface-2 with muted
    # bold text, body on the surface, lines under each row in the border colour.
    $pres = Get-PptxPresentationPart $Package
    $part = Get-PptxRelatedPart $Package $pres 'tableStyles'
    if (-not $part) { return $false }
    $x = Read-PptxPartXml $part
    if ($x.SelectSingleNode("//*[local-name()='tblStyle' and @styleId='$script:KitTableStyleId']")) { return $true }
    $none = '<a:ln><a:noFill/></a:ln>'
    $rule = "<a:ln w=""12700""><a:solidFill><a:srgbClr val=""$($Kit.line)""/></a:solidFill></a:ln>"
    $txt = { param($c, $b) "<a:tcTxStyle$(if ($b) { ' b="on"' })><a:fontRef idx=""minor""><a:prstClr val=""black""/></a:fontRef><a:srgbClr val=""$c""/></a:tcTxStyle>" }
    $xml = "<a:tblStyle xmlns:a=""$script:NsA"" styleId=""$script:KitTableStyleId"" styleName=""UI kit table""><a:wholeTbl>$(& $txt $Kit.text $false)<a:tcStyle><a:tcBdr><a:left>$none</a:left><a:right>$none</a:right><a:top>$none</a:top><a:bottom>$rule</a:bottom><a:insideH>$rule</a:insideH><a:insideV>$none</a:insideV></a:tcBdr><a:fill><a:solidFill><a:srgbClr val=""$($Kit.bodyFill)""/></a:solidFill></a:fill></a:tcStyle></a:wholeTbl><a:firstRow>$(& $txt $Kit.headerText $true)<a:tcStyle><a:tcBdr/><a:fill><a:solidFill><a:srgbClr val=""$($Kit.headerFill)""/></a:solidFill></a:fill></a:tcStyle></a:firstRow></a:tblStyle>"
    $frag = New-Object Xml.XmlDocument; $frag.LoadXml($xml)
    $null = $x.DocumentElement.AppendChild($x.ImportNode($frag.DocumentElement, $true))
    Write-PptxPartXml $part $x
    $true
}

function Complete-PptxChoices($Job) {
    # OnDeck: the charts' series colours, the kit table style when a table took it, and one note.
    $notes = New-Object Collections.Generic.List[string]
    $dst = $Job.ctx.dst
    foreach ($e in $(if ($Job.chartEdits) { $Job.chartEdits.ToArray() } else { @() })) {
        if (-not $dst.PartExists($e.uri)) { continue }
        $p = $dst.GetPart($e.uri); $x = Read-PptxPartXml $p
        if (Set-PptxChartColours $x $e.apply) { Write-PptxPartXml $p $x }
    }
    if ($Job.kitTable -and -not (Add-PptxKitTableStyle $dst $Job.kitTable)) { $notes.Add('The template has no table styles part, so the UI kit table look could not be added; those tables keep the template''s default style.') }
    if ($Job.choiceDone) { $notes.Add("$($Job.choiceDone) element(s) took the look chosen on the card.") }
    $notes.ToArray()
}

$script:OnSlide = { param($Job, $Xml, $Index, $Part) Set-PptxSlideChoices $Job $Xml $Index $Part }
$script:OnDeck = { param($Job) Complete-PptxChoices $Job }

function Invoke-PptxRethemeChoices {
    <# Invoke-PptxRetheme with the per-element choices (Choices.elements = @{ "N:id" = option };
       Choices.kinds = @{ kind = option }), applied in the same write. The elements are found again
       here with the same rules as the plan, so a choice the deck no longer offers is left out. #>
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][string]$ContentPath, [Parameter(Mandatory)][string]$OutPath, [hashtable]$Choices = @{}, [hashtable]$KitTokens = @{})
    $look = Read-PptxTemplateLook $TemplatePath -KitTokens $KitTokens
    $plan = Get-PptxRethemePlan $TemplatePath $ContentPath
    $found = Get-PptxElementChoices $ContentPath $look $plan
    $res = Resolve-PptxElementChoices $found $Choices.elements $Choices.kinds
    if ($res.titles.Count) {
        $t = if ($Choices.titles -is [hashtable]) { $Choices.titles } else { @{} }
        foreach ($k in $res.titles.Keys) { $t[$k] = 0 }
        $Choices.titles = $t
    }
    $Choices.resolved = $res; $Choices.look = $look
    Invoke-PptxRetheme -TemplatePath $TemplatePath -ContentPath $ContentPath -OutPath $OutPath -Choices $Choices -OnSlide $script:OnSlide -OnDeck $script:OnDeck
}

# --------------------------------------------------------------------------- asking Copilot about one element

function New-PptxElementAsk {
    <# On request only (the element's Ask Copilot): which option suits one element. Only its structure
       goes: kind, size and place, current fill and text size, and the options with their colours,
       fonts and sizes; no slide text. #>
    param([Parameter(Mandatory)]$Element, [Parameter(Mandatory)]$Look)
    $sb = New-Object Text.StringBuilder
    $null = $sb.AppendLine("The helper program is putting a deck onto a company template. One element on slide $($Element.slide) has no brand formatting: a $($script:KindNames[$Element.kind]) of $([int]$Element.box.w) x $([int]$Element.box.h) pt$(if ($Element.fill) { ", filled with #$($Element.fill)" }).")
    $null = $sb.AppendLine("The template's fonts: $($Look.fonts.major) (headings), $($Look.fonts.minor) (body); its colours: $((@('accent1', 'accent2', 'accent3', 'dk1', 'lt1') | ForEach-Object { "$_ #$($Look.colors[$_])" }) -join ', '); its slide background #$($Look.bg).")
    $null = $sb.AppendLine('Options:')
    foreach ($o in @($Element.all)) {
        $a = $o.apply; $facts = @()
        if ($a.text) { $facts += "$($a.text.font) $([int]($a.text.size / 100)) pt$(if ($a.text.bold) { ' bold' }), #$($a.text.color)" }
        if ($a.fill) { $facts += "fill #$($a.fill)" }
        if ($a.shape) { $facts += "$($a.shape.prst) filled #$($a.shape.fill)" }
        if ($a.styleId) { $facts += 'table style' }
        $null = $sb.AppendLine("- $($o.id): $($o.label)$(if ($facts.Count) { ' (' + ($facts -join '; ') + ')' })")
    }
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('Answer with one ```json block and nothing else: {"option": "ID", "why": "one short sentence"}. Use one of the ids above exactly as written.')
    $sb.ToString().TrimEnd()
}

function Read-PptxElementAnswer {
    # Copilot's pick, checked against the element's options: @{ ok; option; label; why; error }.
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)]$Element)
    $json = Get-PptxJsonText $Text
    if (-not $json) { return @{ ok = $false; error = 'the answer has no JSON' } }
    try { $d = $json | ConvertFrom-Json } catch { return @{ ok = $false; error = 'the JSON does not parse' } }
    $id = "$($d.option)".Trim()
    $o = @($Element.all | Where-Object { $_.id -eq $id })[0]
    if (-not $o) { return @{ ok = $false; error = """$id"" is not one of the options" } }
    @{ ok = $true; option = $o.id; label = $o.label; why = "$($d.why)".Trim() }
}

Export-ModuleMember -Function ConvertTo-PptxHex, Get-PptxColourDistance, Set-PptxLuminance, Resolve-PptxColour, Read-PptxTemplateLook, Get-PptxKitLook, Get-PptxElementChoices, Get-PptxKindSummary, Add-PptxElementChoices, Resolve-PptxElementChoices, Set-PptxRunLook, Set-PptxShapeLook, Set-PptxTableStyle, Set-PptxChartColours, Invoke-PptxRethemeChoices, New-PptxElementAsk, Read-PptxElementAnswer, Test-PptxReadable
