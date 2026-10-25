# New decks from Copilot's content (on request only). Copilot cannot save a file into the project: a
# deck it makes lives in its own workspace. So it writes a deck outline instead, Work/NAME.deck.json
# (per slide a layout kind from Retheme's set or an exact template layout name; title, subtitle,
# bullets with levels, two columns, notes, a table, a project picture), which Test-DeckOutlineFile
# checks before the file is written, and StreamHub builds the deck on a template the person picks:
# New-PptxFromOutline, a port of the content-to-layouts part of Retheme's pptx_generator.py on
# System.IO.Packaging (no Office). Text that would not fit its placeholder is shrunk to at most 60% and
# then flagged, as Retheme does. Also the fixed rules for a file Copilot names in its own workspace
# (sandbox:/mnt/data/NAME), which the app offers to ask Copilot to save to OneDrive.
# ASCII only (Windows PowerShell 5.1).

foreach ($m in 'PptxLayoutMatch', 'PptxRetheme') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

$script:NsP = 'http://schemas.openxmlformats.org/presentationml/2006/main'
$script:NsA = 'http://schemas.openxmlformats.org/drawingml/2006/main'
$script:NsRel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:RelBase = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:CtSlide = 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml'
$script:CtNotes = 'application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml'
$script:Xmlns = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'
# Retheme's layout kinds (generator.py LAYOUT_TYPE_ALIASES): the template layout purposes to try, in order.
$script:LayoutKinds = [ordered]@{
    title = @('Title Slide'); section_header = @('Section Header'); content = @('Title and Content', 'General Content')
    two_content = @('Two Content', 'Comparison'); comparison = @('Comparison', 'Two Content'); title_only = @('Title Only')
    blank = @('Blank'); quote = @('Quote', 'Section Header'); agenda = @('Agenda / Table of Contents', 'Title and Content')
    closing = @('Closing Slide', 'Title Slide'); picture = @('Picture Layout', 'Picture with Caption')
}
$script:SlideKeys = @('layout', 'title', 'subtitle', 'bullets', 'left', 'right', 'notes', 'table', 'picture')
$script:PictureTypes = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.bmp' = 'image/bmp' }
$script:MaxSlides = 80
$script:MaxRows = 30
$script:MaxCols = 12
$script:MinScale = 0.6   # text is shrunk to at most 60% of the layout's size, then flagged (Retheme)
$script:DefaultTableStyle = '{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}'

# --------------------------------------------------------------------------- the outline

function Get-DeckProps($Obj) {
    if ($Obj -is [hashtable]) { return @($Obj.Keys | ForEach-Object { "$_" }) }
    @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-DeckValue($Obj, [string]$Name) {
    # The comma keeps a list a list: output would unroll a one-item list into its item (and an empty one into nothing).
    if ($Obj -is [hashtable]) { return , $Obj[$Name] }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { , $p.Value } else { $null }
}

function Test-DeckScalar($V) { ($null -eq $V) -or ($V -is [string]) -or ($V -is [ValueType]) }

function Test-DeckBullets($Items, [string]$Where, $Problems, [int]$Depth = 0) {
    # A list of strings or { "text": "...", "level": 0-4 } / { "text": "...", "children": [...] }.
    if ($Items -isnot [array] -and $Items -isnot [Collections.IList]) { $Problems.Add("$Where must be a list of strings"); return }
    if ($Depth -gt 4) { $Problems.Add("$Where goes deeper than 5 levels"); return }
    $i = 0
    foreach ($b in @($Items)) {
        $i++
        if ($b -is [string]) { continue }
        if ($null -eq $b -or (Test-DeckScalar $b)) { $Problems.Add("$Where item $i must be a string or an object with ""text"""); continue }
        $keys = @(Get-DeckProps $b)
        $bad = @($keys | Where-Object { $_ -notin 'text', 'level', 'children' })
        if ($bad.Count) { $Problems.Add("$Where item ${i}: unknown field(s) $($bad -join ', ') (use text, level, children)") }
        if ((Get-DeckValue $b 'text') -isnot [string]) { $Problems.Add("$Where item ${i}: ""text"" must be a string") }
        $lv = Get-DeckValue $b 'level'
        if ($null -ne $lv) {
            $whole = ($lv -is [int] -or $lv -is [long]) -and [long]$lv -ge 0 -and [long]$lv -le 4
            if (-not $whole) { $Problems.Add("$Where item ${i}: ""level"" must be a whole number from 0 to 4") }
        }
        $ch = Get-DeckValue $b 'children'
        if ($null -ne $ch) { Test-DeckBullets $ch "$Where item $i children" $Problems ($Depth + 1) }
    }
}

function Get-DeckTableRows($Table) {
    # The table's rows: a list of rows, or { "rows": [...] }.
    if ($null -eq $Table) { return $null }
    if ($Table -is [array] -or $Table -is [Collections.IList]) { return , @($Table) }
    if (-not (Test-DeckScalar $Table) -and @(Get-DeckProps $Table) -contains 'rows') { $v = Get-DeckValue $Table 'rows'; return , @($v) }
    $null
}

function Test-DeckTable($Table, [string]$Where, $Problems) {
    $rows = Get-DeckTableRows $Table
    if ($null -eq $rows) { $Problems.Add("$Where must be a list of rows (each a list of cells) or { ""rows"": [...] }"); return }
    if ($Table -isnot [array] -and @(Get-DeckProps $Table | Where-Object { $_ -ne 'rows' }).Count) { $Problems.Add("$Where takes only ""rows""") }
    if (-not $rows.Count) { $Problems.Add("$Where has no rows"); return }
    if ($rows.Count -gt $script:MaxRows) { $Problems.Add("$Where has $($rows.Count) rows; at most $($script:MaxRows) fit on a slide: split it over more slides") }
    $cols = -1; $r = 0
    foreach ($row in $rows) {
        $r++
        if ($row -isnot [array] -and $row -isnot [Collections.IList]) { $Problems.Add("$Where row $r must be a list of cells"); continue }
        $n = @($row).Count
        if ($cols -lt 0) { $cols = $n } elseif ($n -ne $cols) { $Problems.Add("$Where row $r has $n cells and row 1 has ${cols}: every row needs the same number of cells") }
        if (@($row | Where-Object { -not (Test-DeckScalar $_) }).Count) { $Problems.Add("$Where row ${r}: cells must be text or numbers") }
    }
    if ($cols -gt $script:MaxCols) { $Problems.Add("$Where has $cols columns; at most $($script:MaxCols) fit on a slide") }
    if ($cols -eq 0) { $Problems.Add("$Where has rows without cells") }
}

function Test-DeckOutlineFile {
    <# What is wrong with a deck outline the way Copilot wrote it, as sentences sent back word for word;
       @() when it is right or the path is not a deck outline (*.deck.json). With ProjectRoot, a slide's
       picture must be a file in the project. #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text, [string]$ProjectRoot = '')
    $rel = $Path.Replace('\', '/').TrimStart('/')
    if ($rel -notmatch '(?i)\.deck\.json$') { return @() }
    $p = New-Object Collections.Generic.List[string]
    $name = ($rel -split '/')[-1]
    if ($rel -notmatch '(?i)^Work/[^/]+\.deck\.json$') { $p.Add("a deck outline is one file in Work/: write it as Work/$name") }
    if ($name -notmatch '^[A-Za-z0-9][\w-]*\.deck\.json$') { $p.Add("the outline's name may hold only letters, digits, - and _ (like Work/quarterly-review.deck.json)") }
    $d = $null
    try { $d = ConvertFrom-Json -InputObject $Text } catch { $p.Add("the outline is not valid JSON ($($_.Exception.Message -replace '\s+', ' '))"); return $p.ToArray() }
    if ($null -eq $d -or (Test-DeckScalar $d) -or $d -is [array]) { $p.Add('the outline must be one JSON object: { "title": "...", "slides": [ ... ] }'); return $p.ToArray() }
    $bad = @(Get-DeckProps $d | Where-Object { $_ -notin 'title', 'slides' })
    if ($bad.Count) { $p.Add("unknown top-level field(s) $($bad -join ', '): the outline has only title and slides") }
    $t = Get-DeckValue $d 'title'; if ($null -ne $t -and $t -isnot [string]) { $p.Add('"title" must be a string') }
    $slides = Get-DeckValue $d 'slides'
    if ($null -eq $slides -or ($slides -isnot [array] -and $slides -isnot [Collections.IList]) -or -not @($slides).Count) { $p.Add('"slides" must be a list with at least one slide'); return $p.ToArray() }
    if (@($slides).Count -gt $script:MaxSlides) { $p.Add("the outline has $(@($slides).Count) slides; at most $($script:MaxSlides)") }
    $i = 0
    foreach ($s in @($slides)) {
        $i++; $w = "slide $i"
        if ($null -eq $s -or (Test-DeckScalar $s) -or $s -is [array]) { $p.Add("$w must be an object"); continue }
        $keys = @(Get-DeckProps $s)
        foreach ($k in $keys) {
            if ($k -in $script:SlideKeys) { continue }
            if ($k -match '^(chart|charts|graph)$') { $p.Add("${w}: charts are not built yet; give the numbers as a ""table"" (a list of rows) instead") }
            else { $p.Add("${w}: unknown field ""$k"" (use $($script:SlideKeys -join ', '))") }
        }
        $lay = Get-DeckValue $s 'layout'
        if ($lay -isnot [string] -or -not $lay.Trim()) { $p.Add("${w}: ""layout"" is required: one of $($script:LayoutKinds.Keys -join ', '), or a layout name of the template") }
        foreach ($k in 'title', 'subtitle', 'notes') { $v = Get-DeckValue $s $k; if ($null -ne $v -and $v -isnot [string]) { $p.Add("${w}: ""$k"" must be a string") } }
        foreach ($k in 'bullets', 'left', 'right') { $v = Get-DeckValue $s $k; if ($null -ne $v) { Test-DeckBullets $v "${w} ""$k""" $p } }
        $tb = Get-DeckValue $s 'table'; if ($null -ne $tb) { Test-DeckTable $tb "${w} ""table""" $p }
        $pic = Get-DeckValue $s 'picture'
        if ($null -ne $pic) {
            if ($pic -isnot [string] -or -not $pic.Trim()) { $p.Add("${w}: ""picture"" must be the path of an image in the project") }
            else {
                $pr = $pic.Trim().Replace('\', '/')
                $ext = [IO.Path]::GetExtension($pr).ToLowerInvariant()
                if (-not $script:PictureTypes.ContainsKey($ext)) { $p.Add("${w}: the picture must be a $($script:PictureTypes.Keys -join ', ') file") }
                elseif ($pr -match '(^|/)\.\.(/|$)' -or $pr -match '^[A-Za-z]:|^/') { $p.Add("${w}: the picture must be a path inside the project, like Assets/NAME.png") }
                elseif ($ProjectRoot -and -not (Test-Path -LiteralPath (Join-Path $ProjectRoot $pr.Replace('/', '\')) -PathType Leaf)) { $p.Add("${w}: the project has no file $pr") }
            }
        }
    }
    $p.ToArray()
}

function Read-DeckOutline([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    ConvertFrom-Json -InputObject $text
}

function Get-DeckOutlines {
    # The project's deck outlines (*.deck.json, not in build output or StreamHub's folder), newest first.
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = $ProjectRoot.TrimEnd('\')
    @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.deck.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.Substring($root.Length) -notmatch '\\(node_modules|\.git|\.streamhub|dist|build)\\' } |
        Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') })
}

function Get-PptxDeckName {
    # Runbooks/Exports/NAME-yyyyMMdd-HHmm.pptx after the outline Work/NAME.deck.json; -2, -3... when taken.
    param([Parameter(Mandatory)][string]$Outline, [datetime]$Now = (Get-Date), [string]$ProjectRoot = '')
    $n = ([IO.Path]::GetFileName($Outline) -replace '(?i)\.deck\.json$', '') -replace '[^\w.-]+', '-'
    $base = "Runbooks/Exports/$n-$($Now.ToString('yyyyMMdd-HHmm'))"
    $name = "$base.pptx"; $i = 1
    while ($ProjectRoot -and (Test-Path -LiteralPath (Join-Path $ProjectRoot $name.Replace('/', '\')))) { $i++; $name = "$base-$i.pptx" }
    $name
}

function Get-DeckParagraphs($Items, [int]$Level = 0) {
    # Bullets (strings, { text, level }, { text, children }) -> @(@{ text; level }) (Retheme's _flatten).
    foreach ($b in @($Items)) {
        if ($null -eq $b) { continue }
        if ($b -is [string] -or (Test-DeckScalar $b)) { @{ text = "$b"; level = [Math]::Min(4, $Level) }; continue }
        $lv = Get-DeckValue $b 'level'
        $own = if ($null -ne $lv) { [int]$lv } else { $Level }
        @{ text = "$(Get-DeckValue $b 'text')"; level = [Math]::Min(4, $own) }
        $ch = Get-DeckValue $b 'children'
        if ($null -ne $ch) { Get-DeckParagraphs $ch ($own + 1) }
    }
}

# --------------------------------------------------------------------------- choosing layouts and places

function Select-DeckLayout {
    <# The template layout for an outline slide: the exact layout name, else the kind's purposes in order
       (Retheme's _find_layout), else a purpose that holds the word, else the layout whose placeholders
       hold the slide best (flagged). Returns @{ layout; note }. #>
    param([Parameter(Mandatory)]$Layouts, [string]$Want, [string[]]$Kinds = @())
    $all = @(); $seen = @{}
    foreach ($l in @($Layouts)) { $k = $l.name.ToLowerInvariant(); if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; $all += $l } }
    if (-not $all.Count) { throw 'The template has no slide layouts.' }
    $w = "$Want".Trim()
    $hit = @($all | Where-Object { $_.name.Trim() -ieq $w })[0]
    if ($hit) { return @{ layout = $hit; note = '' } }
    $key = $w.ToLowerInvariant().Replace(' ', '_').Replace('-', '_')
    if ($script:LayoutKinds.Contains($key)) {
        foreach ($pu in $script:LayoutKinds[$key]) { $hit = @($all | Where-Object { $_.purpose -eq $pu })[0]; if ($hit) { return @{ layout = $hit; note = '' } } }
    }
    $words = $w.ToLowerInvariant().Replace('_', ' ')
    if ($words) { $hit = @($all | Where-Object { $_.purpose.ToLowerInvariant().Contains($words) })[0]; if ($hit) { return @{ layout = $hit; note = '' } } }
    $best = $null; $score = [int]::MinValue
    foreach ($l in $all) { $f = Get-PptxSlotFit $Kinds $l.slots; if ($f.score -gt $score) { $best = $l; $score = $f.score } }
    @{ layout = $best; note = "no layout of the template matches ""$w"", so it is on ""$($best.name)""" }
}

function Get-DeckSlots($Layout) {
    # The layout's placeholders to fill, footers left out; content slots left to right, then top to bottom.
    $s = @($Layout.slots | Where-Object { $_.kind -ne 'footer' -and $_.kind -notin 'sldNum' })
    @($s | Sort-Object @{ Expression = { if ($_.rect) { $_.rect.x } else { 0 } } }, @{ Expression = { if ($_.rect) { $_.rect.y } else { 0 } } })
}

function Get-DeckFreeArea($Slots, $Size) {
    # Where text or a picture goes on a slide whose layout has no place for it: under the title.
    $top = [long]($Size.cy * 0.08)
    $t = @($Slots | Where-Object { $_.kind -eq 'title' -and $_.rect })[0]
    if ($t) { $top = $t.rect.y + $t.rect.cy + [long]($Size.cy * 0.02) }
    @{ x = [long]($Size.cx * 0.06); y = $top; cx = [long]($Size.cx * 0.88); cy = [long]([Math]::Max($Size.cy * 0.2, $Size.cy * 0.92 - $top)) }
}

function Get-DeckTextScale {
    <# How much text must shrink to fit a box (1 = not at all), estimated from its length: half an em
       per character, 1.2 lines per size, a quarter line between paragraphs. Shrinks in steps to at most
       60%; overflow = it still does not fit there. #>
    param($Paras, $Rect, [int]$Size)
    if (-not $Rect -or -not $Size) { return @{ scale = 1.0; overflow = $false } }
    $wPt = ($Rect.cx - 182880) / 12700.0; $hPt = ($Rect.cy - 91440) / 12700.0
    for ($s = 1.0; $s -ge $script:MinScale - 0.001; $s -= 0.05) {
        $pt = $Size / 100.0 * $s
        $need = 0.0
        foreach ($p in @($Paras)) {
            $avail = [Math]::Max(20, $wPt - 28.8 * [int]$p.level)
            $cpl = [Math]::Max(1, [Math]::Floor($avail / ($pt * 0.5)))
            $lines = [Math]::Max(1, [Math]::Ceiling("$($p.text)".Length / $cpl))
            $need += $lines * $pt * 1.2 + $pt * 0.25
        }
        if ($need -le $hPt) { return @{ scale = [Math]::Round($s, 2); overflow = $false } }
    }
    @{ scale = $script:MinScale; overflow = $true }
}

function Read-DeckTextSizes($Package) {
    <# The text size (hundredths of a point) of each layout placeholder: its own list style, else the
       master's placeholder of the same type, else the master's title or body style; by layout uri, then
       "type|idx". #>
    $out = @{}
    $pres = Get-PptxPresentationPart $Package
    foreach ($mrel in @($pres.GetRelationships() | Where-Object { (Get-PptxRelKind $_) -eq 'slideMaster' })) {
        $master = $Package.GetPart((Get-PptxRelTarget $pres $mrel))
        $mx = Read-PptxPartXml $master; $mns = Get-PptxNs $mx
        $sz = { param($n) if ($n -and $n.HasAttribute('sz')) { [int]$n.GetAttribute('sz') } else { 0 } }
        $mTitle = & $sz $mx.SelectSingleNode('/p:sldMaster/p:txStyles/p:titleStyle/a:lvl1pPr/a:defRPr', $mns); if (-not $mTitle) { $mTitle = 4400 }
        $mBody = & $sz $mx.SelectSingleNode('/p:sldMaster/p:txStyles/p:bodyStyle/a:lvl1pPr/a:defRPr', $mns); if (-not $mBody) { $mBody = 2800 }
        $mph = @{}
        foreach ($sp in @(Get-PptxTreeItems $mx.SelectSingleNode('/p:sldMaster/p:cSld/p:spTree', $mns) $mns)) {
            $ph = Get-PptxPh $sp $mns; if (-not $ph -or $ph.kind -notin 'title', 'content') { continue }   # not the footers
            $v = & $sz $sp.SelectSingleNode('p:txBody/a:lstStyle/a:lvl1pPr/a:defRPr', $mns)
            if ($v) { $mph[$(if ($ph.kind -eq 'title') { 'title' } else { 'body' })] = $v }
        }
        foreach ($lrel in @($master.GetRelationships() | Where-Object { (Get-PptxRelKind $_) -eq 'slideLayout' })) {
            $lp = $Package.GetPart((Get-PptxRelTarget $master $lrel))
            $lx = Read-PptxPartXml $lp; $lns = Get-PptxNs $lx
            $map = @{}
            foreach ($sp in @(Get-PptxTreeItems $lx.SelectSingleNode('/p:sldLayout/p:cSld/p:spTree', $lns) $lns)) {
                $ph = Get-PptxPh $sp $lns; if (-not $ph) { continue }
                $v = & $sz $sp.SelectSingleNode('p:txBody/a:lstStyle/a:lvl1pPr/a:defRPr', $lns)
                $kind = if ($ph.kind -eq 'title') { 'title' } else { 'body' }
                if (-not $v) { $v = if ($mph.ContainsKey($kind)) { $mph[$kind] } elseif ($kind -eq 'title') { $mTitle } elseif ($ph.kind -eq 'subtitle') { [int]($mBody * 0.86) } else { $mBody } }
                $map["$($ph.type)|$($ph.idx)"] = $v
            }
            $out["$($lp.Uri)"] = $map
        }
    }
    $out
}

# --------------------------------------------------------------------------- slide XML

function ConvertTo-DeckXmlText([string]$Text) {
    # Text for XML: escaped, without the control characters XML cannot hold.
    [Security.SecurityElement]::Escape(($Text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''))
}

function New-DeckParasXml($Paras, [int]$Size = 0) {
    $sz = if ($Size) { " sz=""$Size""" } else { '' }
    $out = foreach ($p in @($Paras)) {
        $lvl = if ([int]$p.level -gt 0) { "<a:pPr lvl=""$([int]$p.level)""/>" } else { '' }
        $t = "$($p.text)"
        if (-not $t) { "<a:p>$lvl<a:endParaRPr lang=""en-US""$sz/></a:p>"; continue }
        $runs = (@($t -split "`r?`n") | ForEach-Object { "<a:r><a:rPr lang=""en-US""$sz dirty=""0""/><a:t>$(ConvertTo-DeckXmlText $_)</a:t></a:r>" }) -join '<a:br><a:rPr lang="en-US"/></a:br>'
        "<a:p>$lvl$runs</a:p>"
    }
    if (-not @($out).Count) { return '<a:p><a:endParaRPr lang="en-US"/></a:p>' }
    $out -join ''
}

function Get-DeckAutofit($Fit) {
    if ($Fit.scale -ge 0.999) { return '' }
    $ln = if ($Fit.scale -lt 0.9) { ' lnSpcReduction="10000"' } else { '' }
    "<a:normAutofit fontScale=""$([int]($Fit.scale * 100000))""$ln/>"
}

function Get-DeckPhXml($Slot) {
    $t = if ($Slot.type) { " type=""$($Slot.type)""" } else { '' }; $i = if ($Slot.idx) { " idx=""$($Slot.idx)""" } else { '' }
    "<p:ph$t$i/>"
}

function Get-DeckXfrmXml($Rect, [string]$Ns = 'a') {
    "<${Ns}:xfrm><a:off x=""$([long]$Rect.x)"" y=""$([long]$Rect.y)""/><a:ext cx=""$([long]$Rect.cx)"" cy=""$([long]$Rect.cy)""/></${Ns}:xfrm>"
}

function New-DeckTextXml {
    <# A text placeholder (Slot) or, without one, a free text box (Rect, explicit Size) with the
       paragraphs, shrunk to fit when needed. Returns @{ xml; overflow; scale }. #>
    param([int]$Id, [string]$Name, $Slot, $Rect, $Paras, [int]$Size, [switch]$Free)
    $fit = Get-DeckTextScale $Paras $Rect $Size
    if ($Free) {
        $xml = "<p:sp><p:nvSpPr><p:cNvPr id=""$Id"" name=""$Name""/><p:cNvSpPr txBox=""1""/><p:nvPr/></p:nvSpPr><p:spPr>$(Get-DeckXfrmXml $Rect)<a:prstGeom prst=""rect""><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=""square"" rtlCol=""0"">$(Get-DeckAutofit $fit)</a:bodyPr><a:lstStyle/>$(New-DeckParasXml $Paras $Size)</p:txBody></p:sp>"
    } else {
        $xml = "<p:sp><p:nvSpPr><p:cNvPr id=""$Id"" name=""$Name""/><p:cNvSpPr><a:spLocks noGrp=""1""/></p:cNvSpPr><p:nvPr>$(Get-DeckPhXml $Slot)</p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr>$(Get-DeckAutofit $fit)</a:bodyPr><a:lstStyle/>$(New-DeckParasXml $Paras)</p:txBody></p:sp>"
    }
    @{ xml = $xml; overflow = $fit.overflow; scale = $fit.scale }
}

function New-DeckTableXml {
    <# A table on the place of a slot (or free), the first row as its header, in the template's default
       table style; row height and text size shrink to fit (at most to 60%). Returns @{ xml; overflow }. #>
    param([int]$Id, $Rows, $Rect, $Slot, [string]$StyleId)
    $rows = @($Rows); $cols = [Math]::Max(1, @($rows[0]).Count)
    $size = 1400; $rowH = 370840
    $avail = [double]$Rect.cy
    $scale = [Math]::Min(1.0, $avail / ($rows.Count * $rowH))
    $overflow = $scale -lt $script:MinScale
    $scale = [Math]::Max($script:MinScale, $scale)
    $rowH = [long]($rowH * $scale); $size = [int]([Math]::Round($size * $scale / 100) * 100); if ($size -lt 800) { $size = 800 }
    $colW = [long]([Math]::Floor($Rect.cx / $cols))
    $grid = (@(1..$cols) | ForEach-Object { "<a:gridCol w=""$colW""/>" }) -join ''
    $trs = foreach ($row in $rows) {
        $cells = foreach ($c in @($row)) { "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>$(New-DeckParasXml @(@{ text = "$c"; level = 0 }) $size)</a:txBody><a:tcPr/></a:tc>" }
        "<a:tr h=""$rowH"">$($cells -join '')</a:tr>"
    }
    $ph = if ($Slot) { Get-DeckPhXml $Slot } else { '' }
    $h = [long]($rowH * $rows.Count)
    $xml = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=""$Id"" name=""Table $Id""/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=""1""/></p:cNvGraphicFramePr><p:nvPr>$ph</p:nvPr></p:nvGraphicFramePr><p:xfrm><a:off x=""$([long]$Rect.x)"" y=""$([long]$Rect.y)""/><a:ext cx=""$($colW * $cols)"" cy=""$h""/></p:xfrm><a:graphic><a:graphicData uri=""http://schemas.openxmlformats.org/drawingml/2006/table""><a:tbl><a:tblPr firstRow=""1"" bandRow=""1""><a:tableStyleId>$StyleId</a:tableStyleId></a:tblPr><a:tblGrid>$grid</a:tblGrid>$($trs -join '')</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    @{ xml = $xml; overflow = $overflow }
}

function Get-DeckPictureRect($Path, $Rect) {
    # The picture's place inside Rect: as large as fits with its own proportions, centred.
    $img = [Drawing.Image]::FromFile($Path)
    try { $w = [double]$img.Width; $h = [double]$img.Height } finally { $img.Dispose() }
    $f = [Math]::Min($Rect.cx / $w, $Rect.cy / $h)
    $cx = [long]($w * $f); $cy = [long]($h * $f)
    @{ x = [long]($Rect.x + ($Rect.cx - $cx) / 2); y = [long]($Rect.y + ($Rect.cy - $cy) / 2); cx = $cx; cy = $cy }
}

function New-DeckPictureXml([int]$Id, [string]$Rid, $Rect, [string]$Name) {
    "<p:pic><p:nvPicPr><p:cNvPr id=""$Id"" name=""Picture $Id"" descr=""$(ConvertTo-DeckXmlText $Name)""/><p:cNvPicPr><a:picLocks noChangeAspect=""1""/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=""$Rid""/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>$(Get-DeckXfrmXml $Rect)<a:prstGeom prst=""rect""><a:avLst/></a:prstGeom></p:spPr></p:pic>"
}

function Get-DeckSlideKinds($Spec) {
    # The placeholder kinds an outline slide needs, for choosing a layout when its name is unknown.
    $k = New-Object Collections.Generic.List[string]
    if ($null -ne (Get-DeckValue $Spec 'title')) { $k.Add('title') }
    if ($null -ne (Get-DeckValue $Spec 'subtitle')) { $k.Add('subtitle') }
    foreach ($n in 'bullets', 'left', 'right', 'table', 'picture') { if ($null -ne (Get-DeckValue $Spec $n)) { $k.Add('content') } }
    $k.ToArray()
}

function New-DeckSlideShapes {
    <# The shapes of one outline slide on its layout (Retheme's take(): title, subtitle, body, the two
       columns, then table and picture), each in a placeholder of the layout, else in a free box under
       the title (said in a note). Returns @{ xml; notes; pictures = @(@{ rid; path }) }. #>
    param($Spec, $Layout, $Sizes, $Size, [int]$Index, [string]$ProjectRoot, [string]$TableStyle)
    $free = New-Object Collections.ArrayList
    foreach ($s in @(Get-DeckSlots $Layout)) { $null = $free.Add($s) }
    $take = {
        param([string[]]$kinds)
        foreach ($k in $kinds) { for ($i = 0; $i -lt $free.Count; $i++) { if ($free[$i].kind -eq $k) { $s = $free[$i]; $free.RemoveAt($i); return $s } } }
        $null
    }
    $sizeOf = { param($slot, [int]$fallback) $v = $Sizes["$($slot.type)|$($slot.idx)"]; if ($v) { [int]$v } else { $fallback } }
    $shapes = New-Object Collections.Generic.List[string]; $notes = New-Object Collections.Generic.List[string]; $pics = New-Object Collections.Generic.List[object]
    $leftover = New-Object Collections.Generic.List[object]
    $id = 2
    $place = {
        param([string]$what, $slot, $paras, [int]$fallback, [string]$label)
        if ($slot) {
            $r = New-DeckTextXml -Id $script:DeckId -Name "$label $($script:DeckId)" -Slot $slot -Rect $slot.rect -Paras $paras -Size (& $sizeOf $slot $fallback)
            $shapes.Add($r.xml); $script:DeckId++
            if ($r.overflow) { $notes.Add("slide ${Index}: the $what does not fit its place even at 60% of the template's size; shorten it.") }
            elseif ($r.scale -lt 1) { $notes.Add("slide ${Index}: the $what was shrunk to $([int]($r.scale * 100))% to fit.") }
        } else { $leftover.Add(@{ what = $what; paras = $paras; size = $fallback }) }
    }
    $script:DeckId = $id
    $title = Get-DeckValue $Spec 'title'
    if ($null -ne $title) { & $place 'title' (& $take @('title')) @(@{ text = "$title"; level = 0 }) 4400 'Title' }
    $sub = Get-DeckValue $Spec 'subtitle'
    if ($null -ne $sub) {
        # A subtitle slot, else a text (body) slot, else the smallest content slot.
        $slot = & $take @('subtitle')
        if (-not $slot) { $b = @($free | Where-Object { $_.kind -eq 'content' -and $_.type -eq 'body' })[0]; if (-not $b) { $b = @($free | Where-Object { $_.kind -eq 'content' -and $_.rect } | Sort-Object { $_.rect.cx * [double]$_.rect.cy })[0] }; if ($b) { $free.Remove($b); $slot = $b } }
        & $place 'subtitle' $slot @(@{ text = "$sub"; level = 0 }) 2400 'Subtitle'
    }
    # The text and the columns take the largest content slots (a comparison layout's small header
    # boxes stay free), left and right in the order the slots stand on the slide.
    $bodies = @(foreach ($k in 'bullets', 'left', 'right') { $v = Get-DeckValue $Spec $k; if ($null -ne $v) { @{ key = $k; value = $v } } })
    $big = @($free | Where-Object { $_.kind -eq 'content' } | Sort-Object @{ Expression = { if ($_.rect) { $_.rect.cx * [double]$_.rect.cy } else { 0 } }; Descending = $true } | Select-Object -First $bodies.Count)
    $big = @($big | Sort-Object @{ Expression = { if ($_.rect) { $_.rect.x } else { 0 } } }, @{ Expression = { if ($_.rect) { $_.rect.y } else { 0 } } })
    for ($b = 0; $b -lt $bodies.Count; $b++) {
        $slot = if ($b -lt $big.Count) { $big[$b] } else { $null }
        if ($slot) { $free.Remove($slot) }
        $k = $bodies[$b].key
        & $place $(if ($k -eq 'bullets') { 'text' } else { "$k column" }) $slot @(Get-DeckParagraphs $bodies[$b].value) 2800 'Content'
    }
    $rows = Get-DeckTableRows (Get-DeckValue $Spec 'table')
    $tableSlot = $null
    if ($null -ne $rows) { $tableSlot = & $take @('tbl', 'content'); if (-not $tableSlot) { $leftover.Add(@{ what = 'table'; rows = $rows }) } }
    $pic = Get-DeckValue $Spec 'picture'
    $picSlot = $null
    if ($null -ne $pic) { $picSlot = & $take @('pic', 'content'); if (-not $picSlot) { $leftover.Add(@{ what = 'picture'; path = "$pic" }) } }
    # What has no placeholder goes under the title, the free area shared top to bottom.
    $area = Get-DeckFreeArea @($Layout.slots) $Size
    $n = $leftover.Count; $k = 0
    foreach ($l in $leftover) {
        $h = [long]($area.cy / [Math]::Max(1, $n))
        $rect = @{ x = $area.x; y = $area.y + $k * $h; cx = $area.cx; cy = [long]($h * 0.95) }; $k++
        $notes.Add("slide ${Index}: the layout ""$($Layout.name)"" has no place for the $($l.what); it is in a box under the title.")
        if ($l.what -eq 'table') { $tableSlot = @{ rect = $rect; free = $true } }
        elseif ($l.what -eq 'picture') { $picSlot = @{ rect = $rect; free = $true } }
        else {
            $r = New-DeckTextXml -Id $script:DeckId -Name "TextBox $($script:DeckId)" -Rect $rect -Paras $l.paras -Size $(if ($l.what -eq 'title') { 3200 } else { 1800 }) -Free
            $shapes.Add($r.xml); $script:DeckId++
            if ($r.overflow) { $notes.Add("slide ${Index}: the $($l.what) does not fit its box even at 60%; shorten it.") }
        }
    }
    if ($tableSlot) {
        $t = New-DeckTableXml -Id $script:DeckId -Rows $rows -Rect $tableSlot.rect -Slot $(if ($tableSlot.free) { $null } else { $tableSlot }) -StyleId $TableStyle
        $shapes.Add($t.xml); $script:DeckId++
        if ($t.overflow) { $notes.Add("slide ${Index}: the table has too many rows for its place even at 60%; split it over two slides.") }
    }
    if ($picSlot) {
        $full = Join-Path $ProjectRoot ("$pic".Trim().Replace('/', '\'))
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $rid = "rIdPic$($script:DeckId)"
            $shapes.Add((New-DeckPictureXml $script:DeckId $rid (Get-DeckPictureRect $full $picSlot.rect) ([IO.Path]::GetFileName($full)))); $script:DeckId++
            $pics.Add(@{ rid = $rid; path = $full })
        } else { $notes.Add("slide ${Index}: the picture $pic is not in the project; it was left out.") }
    }
    @{ xml = ($shapes -join ''); notes = $notes.ToArray(); pictures = $pics.ToArray() }
}

function Add-DeckNotes($Ctx, $Slide, $NotesMaster, [string]$Text) {
    # Speaker notes: a notes page tied to the slide and the template's notes master.
    $uri = Get-PptxFreeUri $Ctx '/ppt/notesSlides/notesSlide1.xml'
    $np = $Ctx.dst.CreatePart($uri, $script:CtNotes, [IO.Packaging.CompressionOption]::Normal)
    $paras = New-DeckParasXml @(@("$Text" -split "`r?`n") | ForEach-Object { @{ text = $_; level = 0 } })
    $x = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:notes $script:Xmlns><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=""1"" name=""""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id=""2"" name=""Slide Image Placeholder 1""/><p:cNvSpPr><a:spLocks noGrp=""1"" noRot=""1"" noChangeAspect=""1""/></p:cNvSpPr><p:nvPr><p:ph type=""sldImg""/></p:nvPr></p:nvSpPr><p:spPr/></p:sp><p:sp><p:nvSpPr><p:cNvPr id=""3"" name=""Notes Placeholder 2""/><p:cNvSpPr><a:spLocks noGrp=""1""/></p:cNvSpPr><p:nvPr><p:ph type=""body"" idx=""1""/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>$paras</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"
    Write-DeckPart $np $x
    $null = New-PptxRel $np $NotesMaster "$script:RelBase/notesMaster" 'rId1'
    $null = New-PptxRel $np $Slide "$script:RelBase/slide" 'rId2'
    $null = New-PptxRel $Slide $np "$script:RelBase/notesSlide" ''
}

function Write-DeckPart($Part, [string]$Xml) {
    $b = (New-Object Text.UTF8Encoding($false)).GetBytes($Xml)
    $s = $Part.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write)
    try { $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
}

function Remove-DeckTemplateSlides($Ctx, $Pres, [Xml.XmlDocument]$PresXml, $Ns) {
    # Every slide of the template goes, with its notes; the slide list is left empty.
    $lst = $PresXml.SelectSingleNode('/p:presentation/p:sldIdLst', $Ns)
    if (-not $lst) { $lst = $PresXml.CreateElement('p', 'sldIdLst', $script:NsP); $null = $PresXml.DocumentElement.InsertBefore($lst, $PresXml.SelectSingleNode('/p:presentation/p:sldSz', $Ns)) }
    foreach ($el in @($lst.SelectNodes('p:sldId', $Ns))) {
        $rid = $el.GetAttribute('id', $script:NsRel)
        $part = $Ctx.dst.GetPart((Get-PptxRelTarget $Pres $Pres.GetRelationship($rid)))
        $np = Get-PptxRelatedPart $Ctx.dst $part 'notesSlide'; if ($np) { $Ctx.dst.DeletePart($np.Uri) }
        $Ctx.dst.DeletePart($part.Uri); $Pres.DeleteRelationship($rid); $null = $lst.RemoveChild($el)
    }
    , $lst
}

function New-PptxFromOutline {
    <# Builds OutPath from a deck outline on the template: every slide on its layout (Select-DeckLayout),
       its text in the layout's placeholders, a table in the template's default table style, a project
       picture, speaker notes on the template's notes page. The template's own slides are left out; the
       template and the outline are never changed. Returns @{ slides; warnings }. #>
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][string]$OutlinePath, [Parameter(Mandatory)][string]$OutPath, [string]$ProjectRoot = '')
    $text = [IO.File]::ReadAllText($OutlinePath)
    $problems = @(Test-DeckOutlineFile ('Work/' + [IO.Path]::GetFileName($OutlinePath)) $text $ProjectRoot | Where-Object { $_ -notmatch 'one file in Work/|name may hold' })
    if ($problems.Count) { throw "The outline cannot be built: $($problems -join '; ')." }
    $outline = ConvertFrom-Json -InputObject $text
    $tInfo = Read-PptxDeck $TemplatePath
    $warn = New-Object Collections.Generic.List[string]
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('streamhub-deck-' + [guid]::NewGuid().ToString('N') + '.pptx')
    $fs = [IO.File]::Open($TemplatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $o = [IO.File]::Create($tmp); try { $fs.CopyTo($o) } finally { $o.Dispose() } } finally { $fs.Dispose() }
    $count = 0
    try {
        Repair-PptxMainType $tmp
        $dst = [IO.Packaging.Package]::Open($tmp, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
        try {
            $ctx = @{ dst = $dst; next = @{} }
            $pres = Get-PptxPresentationPart $dst; $px = Read-PptxPartXml $pres; $ns = Get-PptxNs $px
            $sizes = Read-DeckTextSizes $dst
            $ts = Get-PptxRelatedPart $dst $pres 'tableStyles'
            $style = if ($ts) { "$((Read-PptxPartXml $ts).DocumentElement.GetAttribute('def'))" } else { '' }
            if (-not $style) { $style = $script:DefaultTableStyle }
            $lst = Remove-DeckTemplateSlides $ctx $pres $px $ns
            $notesMaster = Get-PptxRelatedPart $dst $pres 'notesMaster'
            $nextId = 256; $media = 0
            foreach ($spec in @($outline.slides)) {
                $count++
                $pick = Select-DeckLayout $tInfo.layouts "$(Get-DeckValue $spec 'layout')" @(Get-DeckSlideKinds $spec)
                if ($pick.note) { $warn.Add("slide ${count}: $($pick.note).") }
                $lay = $pick.layout
                $built = New-DeckSlideShapes $spec $lay $sizes[$lay.uri] $tInfo.size $count $ProjectRoot $style
                foreach ($n in @($built.notes)) { $warn.Add($n) }
                $x = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:sld $script:Xmlns><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=""1"" name=""""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=""0"" y=""0""/><a:ext cx=""0"" cy=""0""/><a:chOff x=""0"" y=""0""/><a:chExt cx=""0"" cy=""0""/></a:xfrm></p:grpSpPr>$($built.xml)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
                $part = $dst.CreatePart((Get-PptxFreeUri $ctx '/ppt/slides/slide1.xml'), $script:CtSlide, [IO.Packaging.CompressionOption]::Normal)
                Write-DeckPart $part $x
                $null = New-PptxRel $part ($dst.GetPart((New-Object Uri($lay.uri, [UriKind]::Relative)))) "$script:RelBase/slideLayout" 'rId1'
                foreach ($p in @($built.pictures)) {
                    $media++
                    $ext = [IO.Path]::GetExtension($p.path).ToLowerInvariant()
                    $mp = $dst.CreatePart((Get-PptxFreeUri $ctx "/ppt/media/image1$ext"), $script:PictureTypes[$ext], [IO.Packaging.CompressionOption]::NotCompressed)
                    $bytes = [IO.File]::ReadAllBytes($p.path)
                    $s = $mp.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
                    $null = New-PptxRel $part $mp "$script:RelBase/image" $p.rid
                }
                $nt = Get-DeckValue $spec 'notes'
                if ($nt) { if ($notesMaster) { Add-DeckNotes $ctx $part $notesMaster "$nt" } else { $warn.Add("slide ${count}: the template has no notes page, so its speaker notes were left out.") } }
                $rel = New-PptxRel $pres $part "$script:RelBase/slide" ''
                $el = $px.CreateElement('p', 'sldId', $script:NsP); $el.SetAttribute('id', [string]$nextId); $nextId++
                $a = $px.CreateAttribute('r', 'id', $script:NsRel); $a.Value = $rel.Id; $null = $el.Attributes.Append($a)
                $null = $lst.AppendChild($el)
            }
            $null = Remove-PptxSlideLists $px $ns
            Write-PptxPartXml $pres $px
            Remove-PptxDanglingRels $dst
            $null = Remove-PptxOrphanParts $dst
        } finally { $dst.Close() }
        $dir = Split-Path -Parent $OutPath
        if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir }
        Move-Item -LiteralPath $tmp -Destination $OutPath -Force
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    @{ slides = $count; warnings = $warn.ToArray() }
}

# --------------------------------------------------------------------------- files in Copilot's own workspace

function Get-SandboxFiles {
    <# The files a reply names in Copilot's own workspace (sandbox:/mnt/data/NAME or
       sandbox://mnt/data/NAME), as file names, once each. Such a file is not in the project. #>
    param([AllowEmptyString()][string]$Text)
    $out = New-Object Collections.Generic.List[string]
    foreach ($m in [regex]::Matches("$Text", '(?i)sandbox:/{1,2}mnt/data/([^\s)\]"''<>`]+)')) {
        $n = [Uri]::UnescapeDataString($m.Groups[1].Value).TrimEnd('.', ',', ';', ':', '!', '?')
        $n = ($n -split '/')[-1]
        if ($n -and (Test-SandboxFileName $n) -and -not $out.Contains($n)) { $out.Add($n) }
    }
    $out.ToArray()
}

function Test-SandboxFileName([string]$Name) {
    # A plain file name with a type: no folders, quotes or control characters.
    ($Name.Length -le 120) -and ($Name -match '^[\w .()+-]+\.[A-Za-z0-9]{1,6}$') -and ($Name -notmatch '^\.')
}

function Get-SandboxSaveRequest {
    # The fixed request the "Ask Copilot to save it to OneDrive" button sends, in the same chat.
    param([Parameter(Mandatory)][string]$Name)
    "You made the file $Name in this chat (sandbox:/mnt/data/$Name). Save that file, unchanged, to my OneDrive and reply with the link to the saved file (a OneDrive or SharePoint link). If you need my confirmation for that, ask me in your reply."
}

function Get-ReplyLinks {
    # The https addresses in a reply (Markdown links and bare ones), once each.
    param([AllowEmptyString()][string]$Text)
    $out = New-Object Collections.Generic.List[string]
    foreach ($m in [regex]::Matches("$Text", 'https://[^\s)\]"''<>`]+')) {
        $u = $m.Value.TrimEnd('.', ',', ';', ':', '!', '?')
        if (-not $out.Contains($u)) { $out.Add($u) }
    }
    $out.ToArray()
}

Export-ModuleMember -Function Test-DeckOutlineFile, Read-DeckOutline, Get-DeckOutlines, Get-PptxDeckName, Get-DeckParagraphs, Select-DeckLayout, Get-DeckTextScale, Read-DeckTextSizes, New-DeckSlideShapes, New-PptxFromOutline, Get-SandboxFiles, Test-SandboxFileName, Get-SandboxSaveRequest, Get-ReplyLinks
