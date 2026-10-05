# Office documents without Office: .docx, .pptx and .xlsx are zip files of XML, read here as
# Markdown text (Word: headings, lists, tables, bold/italic/code; PowerPoint: one section per slide
# with its notes; Excel: one table per sheet). A .docx can be written from Markdown (a minimal Open
# XML package that Word opens), so Copilot can make and change Word documents with the same write
# and edit actions it uses for code. A .docx made in Word is not rewritten (its formatting, images
# and comments would be lost); old binary formats (.doc, .ppt, .xls) are read by Copilot itself
# from an attachment. Non-ASCII characters are written as [char] so this file stays ASCII.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
$script:A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
$script:P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
$script:S = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$script:R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:PR = 'http://schemas.openxmlformats.org/package/2006/relationships'
$script:Maker = 'StreamHub'   # docProps/app.xml Application of documents written here

function Get-OfficeKind([string]$Path) {
    <# 'word', 'slides', 'sheet' (read as text here), 'old' (binary format) or 'pdf' (only Copilot
       can read those: they go to it as an attachment)
       or $null (not an Office document). #>
    switch -regex ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '^\.doc[xm]$' { return 'word' }
        '^\.pp[st][xm]$' { return 'slides' }
        '^\.xls[xm]$' { return 'sheet' }
        '^\.(doc|dot|ppt|pps|xls|xlt)$' { return 'old' }
        '^\.pdf$' { return 'pdf' }
        '^\.(png|jpe?g|gif|webp|bmp)$' { return 'image' }
    }
    $null
}

function Get-OfficeLabel([string]$Path) {
    switch (Get-OfficeKind $Path) { 'word' { 'Word document' } 'slides' { 'PowerPoint presentation' } 'sheet' { 'Excel workbook' } 'old' { 'Office document in the old binary format' } 'pdf' { 'PDF document' } 'image' { 'Image' } default { '' } }
}

function Open-OfficeZip([string]$Path) {
    # Shared read: the document may be open in Word or Excel at the same time.
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Read, $false) }
    catch { $fs.Dispose(); throw "not readable as an Office document (it may be password-protected or damaged)" }
}

function Get-ZipXml($Zip, [string]$Name) {
    $e = $Zip.GetEntry($Name)
    if (-not $e) { return $null }
    $sr = New-Object IO.StreamReader($e.Open())
    try { $x = New-Object Xml.XmlDocument; $x.XmlResolver = $null; $x.LoadXml($sr.ReadToEnd()); $x } finally { $sr.Dispose() }
}

function New-OfficeNs($Doc) {
    $ns = New-Object Xml.XmlNamespaceManager $Doc.NameTable
    foreach ($k in @{ w = $script:W; a = $script:A; p = $script:P; s = $script:S; r = $script:R; pr = $script:PR }.GetEnumerator()) { $ns.AddNamespace($k.Key, $k.Value) }
    , $ns   # the manager is enumerable: keep PowerShell from unrolling it
}

function Get-RelTargets($Zip, [string]$RelsName, [string]$BaseDir) {
    <# Relationship id -> part name (resolved against the folder of the part that owns the rels). #>
    $map = @{}
    $x = Get-ZipXml $Zip $RelsName
    if (-not $x) { return $map }
    foreach ($rel in $x.DocumentElement.ChildNodes) {
        if ($rel.LocalName -ne 'Relationship' -or $rel.GetAttribute('TargetMode') -eq 'External') { continue }
        $t = $rel.GetAttribute('Target')
        $full = if ($t.StartsWith('/')) { $t.TrimStart('/') } else {
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($seg in (($BaseDir.TrimEnd('/') + '/' + $t) -split '/')) {
                if ($seg -eq '..') { if ($parts.Count) { $parts.RemoveAt($parts.Count - 1) } }
                elseif ($seg -and $seg -ne '.') { $parts.Add($seg) }
            }
            $parts -join '/'
        }
        $map[$rel.GetAttribute('Id')] = @{ part = $full; type = $rel.GetAttribute('Type') }
    }
    $map
}

function ConvertTo-MdCell([string]$Text) { ($Text -replace '\s*\r?\n\s*', ' ' -replace '\|', '\|').Trim() }

function Format-MdTable($Rows) {
    <# Rows (arrays of cell text) as a Markdown table; the first row is the header. #>
    $rows = @($Rows)
    if (-not $rows.Count) { return '' }
    $width = ($rows | ForEach-Object { @($_).Count } | Measure-Object -Maximum).Maximum
    if ($width -lt 1) { return '' }
    $lines = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($row in $rows) {
        $cells = @(for ($c = 0; $c -lt $width; $c++) { if ($c -lt @($row).Count) { ConvertTo-MdCell "$(@($row)[$c])" } else { '' } })
        $lines.Add('| ' + ($cells -join ' | ') + ' |')
        if ($i -eq 0) { $lines.Add('|' + ((1..$width | ForEach-Object { ' --- ' }) -join '|') + '|') }
        $i++
    }
    $lines -join "`n"
}

# --- Word ----------------------------------------------------------------------------------

function Test-OnOff($Node, $Ns, [string]$Name) {
    $n = $Node.SelectSingleNode("w:rPr/w:$Name", $Ns)
    if (-not $n) { return $false }
    $v = $n.GetAttribute('val', $script:W)
    -not ($v -in 'false', '0', 'off', 'none')
}

function Get-DocxRunsText($Para, $Ns) {
    <# A paragraph's text with **bold**, *italic* and `code` marks (adjacent runs of the same kind joined). #>
    $parts = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Para.SelectNodes('.//w:r[not(ancestor::w:del)]', $Ns)) {
        $sb = New-Object Text.StringBuilder
        foreach ($c in $r.ChildNodes) {
            switch ($c.LocalName) { 't' { [void]$sb.Append($c.InnerText) } 'tab' { [void]$sb.Append("`t") } 'br' { [void]$sb.Append("`n") } 'cr' { [void]$sb.Append("`n") } 'noBreakHyphen' { [void]$sb.Append('-') } }
        }
        if (-not $sb.Length) { continue }
        $font = $r.SelectSingleNode('w:rPr/w:rFonts', $Ns)
        $code = $font -and ($font.GetAttribute('ascii', $script:W) -match '(?i)consolas|courier|mono')
        $kind = if ($code) { 'code' } else { "$(if (Test-OnOff $r $Ns 'b') { 'b' })$(if (Test-OnOff $r $Ns 'i') { 'i' })" }
        if ($parts.Count -and $parts[$parts.Count - 1].kind -eq $kind) { $parts[$parts.Count - 1].text += $sb.ToString() }
        else { $parts.Add([pscustomobject]@{ kind = $kind; text = $sb.ToString() }) }
    }
    $out = New-Object Text.StringBuilder
    foreach ($p in $parts) {
        $t = $p.text
        if (-not $t.Trim() -or -not $p.kind) { [void]$out.Append($t); continue }
        # Marks go around the words, not the spaces around them.
        $lead = $t.Substring(0, $t.Length - $t.TrimStart().Length); $trail = $t.Substring($t.TrimEnd().Length); $core = $t.Trim()
        $mark = switch ($p.kind) { 'code' { '`' } 'bi' { '***' } 'b' { '**' } 'i' { '*' } }
        [void]$out.Append($lead + $mark + $core + $mark + $trail)
    }
    $out.ToString()
}

function Get-DocxStyleNames($Zip) {
    <# styleId -> the style's own name, lower case ("heading 1"), which is the same in every language. #>
    $map = @{}
    $x = Get-ZipXml $Zip 'word/styles.xml'
    if (-not $x) { return $map }
    $ns = New-OfficeNs $x
    foreach ($s in $x.SelectNodes('//w:style', $ns)) {
        $n = $s.SelectSingleNode('w:name', $ns)
        if ($n) { $map[$s.GetAttribute('styleId', $script:W)] = $n.GetAttribute('val', $script:W).ToLowerInvariant() }
    }
    $map
}

function Get-DocxListFormats($Zip) {
    <# "numId/ilvl" -> numFmt (bullet, decimal, ...). #>
    $map = @{}
    $x = Get-ZipXml $Zip 'word/numbering.xml'
    if (-not $x) { return $map }
    $ns = New-OfficeNs $x
    $abs = @{}
    foreach ($a in $x.SelectNodes('//w:abstractNum', $ns)) {
        $lv = @{}
        foreach ($l in $a.SelectNodes('w:lvl', $ns)) { $f = $l.SelectSingleNode('w:numFmt', $ns); $lv[$l.GetAttribute('ilvl', $script:W)] = $(if ($f) { $f.GetAttribute('val', $script:W) } else { 'bullet' }) }
        $abs[$a.GetAttribute('abstractNumId', $script:W)] = $lv
    }
    foreach ($n in $x.SelectNodes('//w:num', $ns)) {
        $aid = $n.SelectSingleNode('w:abstractNumId', $ns)
        if (-not $aid) { continue }
        $lv = $abs[$aid.GetAttribute('val', $script:W)]
        if ($lv) { foreach ($k in $lv.Keys) { $map["$($n.GetAttribute('numId', $script:W))/$k"] = $lv[$k] } }
    }
    $map
}

function ConvertFrom-Docx($Zip) {
    $doc = Get-ZipXml $Zip 'word/document.xml'
    if (-not $doc) { throw 'no word/document.xml: not a Word document' }
    $ns = New-OfficeNs $doc
    $styles = Get-DocxStyleNames $Zip
    $lists = Get-DocxListFormats $Zip
    $blocks = New-Object System.Collections.Generic.List[object]   # @{ kind; text } kind: para, list, code, table
    $walk = $null
    $walk = {
        param($Parent)
        foreach ($el in $Parent.ChildNodes) {
            if ($el.LocalName -eq 'sdt') { $c = $el.SelectSingleNode('w:sdtContent', $ns); if ($c) { & $walk $c }; continue }
            if ($el.LocalName -eq 'tbl') {
                $rows = @(foreach ($tr in $el.SelectNodes('w:tr', $ns)) {
                    , @(foreach ($tc in $tr.SelectNodes('w:tc', $ns)) { (@($tc.SelectNodes('.//w:p', $ns) | ForEach-Object { Get-DocxRunsText $_ $ns }) -join ' ').Trim() })
                })
                if ($rows.Count) { $blocks.Add(@{ kind = 'table'; text = (Format-MdTable $rows) }) }
                continue
            }
            if ($el.LocalName -ne 'p') { continue }
            $sid = $el.SelectSingleNode('w:pPr/w:pStyle', $ns)
            $style = if ($sid) { "$($styles[$sid.GetAttribute('val', $script:W)])" } else { '' }
            if (-not $style -and $sid) { $style = $sid.GetAttribute('val', $script:W).ToLowerInvariant() }
            $text = Get-DocxRunsText $el $ns
            if ($style -match '^(code|html preformatted|source code|macro text|plain text)$') {
                $plain = (@($el.SelectNodes('.//w:t', $ns) | ForEach-Object { $_.InnerText }) -join '')
                $blocks.Add(@{ kind = 'code'; text = $plain }); continue
            }
            if (-not $text.Trim()) { continue }
            $num = $el.SelectSingleNode('w:pPr/w:numPr', $ns)
            if ($style -match '^heading ([1-6])$') { $blocks.Add(@{ kind = 'para'; text = ('#' * [int]$Matches[1]) + ' ' + $text.Trim() }); continue }
            if ($style -in 'title') { $blocks.Add(@{ kind = 'para'; text = '# ' + $text.Trim() }); continue }
            if ($num) {
                $il = $num.SelectSingleNode('w:ilvl', $ns); $ni = $num.SelectSingleNode('w:numId', $ns)
                $lvl = if ($il) { [int]$il.GetAttribute('val', $script:W) } else { 0 }
                $fmt = if ($ni) { $lists["$($ni.GetAttribute('val', $script:W))/$lvl"] } else { 'bullet' }
                $mark = if ($fmt -and $fmt -ne 'bullet' -and $fmt -ne 'none') { '1.' } else { '-' }
                $blocks.Add(@{ kind = 'list'; text = ('  ' * $lvl) + "$mark " + $text.Trim() }); continue
            }
            if ($style -match 'quote') { $blocks.Add(@{ kind = 'para'; text = '> ' + $text.Trim() }); continue }
            $blocks.Add(@{ kind = 'para'; text = $text.Trim() })
        }
    }
    & $walk ($doc.SelectSingleNode('/w:document/w:body', $ns))
    # Blocks are separated by a blank line, except list items and code lines that follow each other.
    $sb = New-Object Text.StringBuilder
    $prev = ''
    foreach ($b in $blocks) {
        if ($b.kind -eq 'code' -and $prev -ne 'code') { if ($sb.Length) { [void]$sb.Append("`n`n") }; [void]$sb.Append('```' + "`n") }
        elseif ($b.kind -ne 'code' -and $prev -eq 'code') { [void]$sb.Append("`n" + '```') }
        if ($b.kind -eq 'code') { if ($prev -eq 'code') { [void]$sb.Append("`n") }; [void]$sb.Append($b.text) }
        elseif ($b.kind -eq 'list' -and $prev -eq 'list') { [void]$sb.Append("`n" + $b.text) }
        else { if ($sb.Length) { [void]$sb.Append("`n`n") }; [void]$sb.Append($b.text) }
        $prev = $b.kind
    }
    if ($prev -eq 'code') { [void]$sb.Append("`n" + '```') }
    $images = @($Zip.Entries | Where-Object { $_.FullName -like 'word/media/*' }).Count
    $comments = 0
    $cx = Get-ZipXml $Zip 'word/comments.xml'
    if ($cx) { $comments = $cx.SelectNodes('//w:comment', (New-OfficeNs $cx)).Count }
    [pscustomobject]@{ text = $sb.ToString(); images = $images; comments = $comments }
}

# --- PowerPoint ----------------------------------------------------------------------------

function Get-ShapeLines($Root, $Ns) {
    <# Text of the shapes and tables on a slide, in order: titles as ### lines, other text as list items. #>
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($el in $Root.SelectNodes('.//p:sp | .//a:tbl', $Ns)) {
        if ($el.LocalName -eq 'tbl') {
            $rows = @(foreach ($tr in $el.SelectNodes('a:tr', $Ns)) { , @(foreach ($tc in $tr.SelectNodes('a:tc', $Ns)) { (@($tc.SelectNodes('.//a:t', $Ns) | ForEach-Object { $_.InnerText }) -join ' ').Trim() }) })
            if ($rows.Count) { $out.Add((Format-MdTable $rows)) }
            continue
        }
        $ph = $el.SelectSingleNode('p:nvSpPr/p:nvPr/p:ph', $Ns)
        $type = if ($ph) { $ph.GetAttribute('type') } else { '' }
        foreach ($para in $el.SelectNodes('p:txBody/a:p', $Ns)) {
            $t = (@($para.SelectNodes('.//a:t', $Ns) | ForEach-Object { $_.InnerText }) -join '').Trim()
            if (-not $t) { continue }
            if ($type -in 'title', 'ctrTitle') { $out.Add("### $t"); continue }
            $pp = $para.SelectSingleNode('a:pPr', $Ns)
            $lvl = if ($pp -and $pp.GetAttribute('lvl')) { [int]$pp.GetAttribute('lvl') } else { 0 }
            $out.Add(('  ' * $lvl) + "- $t")
        }
    }
    $out.ToArray()
}

function ConvertFrom-Pptx($Zip) {
    $pres = Get-ZipXml $Zip 'ppt/presentation.xml'
    if (-not $pres) { throw 'no ppt/presentation.xml: not a PowerPoint presentation' }
    $ns = New-OfficeNs $pres
    $rels = Get-RelTargets $Zip 'ppt/_rels/presentation.xml.rels' 'ppt'
    $slides = @(foreach ($id in $pres.SelectNodes('//p:sldIdLst/p:sldId', $ns)) { $t = $rels[$id.GetAttribute('id', $script:R)]; if ($t) { $t.part } })
    if (-not $slides.Count) {
        $slides = @($Zip.Entries | Where-Object { $_.FullName -match '^ppt/slides/slide(\d+)\.xml$' } | Sort-Object { [int]([regex]::Match($_.FullName, '\d+').Value) } | ForEach-Object { $_.FullName })
    }
    $sb = New-Object Text.StringBuilder
    $n = 0
    foreach ($part in $slides) {
        $n++
        $x = Get-ZipXml $Zip $part
        if (-not $x) { continue }
        $sns = New-OfficeNs $x
        if ($sb.Length) { [void]$sb.Append("`n`n") }
        $hidden = $x.DocumentElement.GetAttribute('show') -eq '0'
        [void]$sb.Append("## Slide $n$(if ($hidden) { ' (hidden)' })")
        $lines = @(Get-ShapeLines $x $sns)
        if ($lines.Count) { [void]$sb.Append("`n`n" + ($lines -join "`n")) }
        # Speaker notes, through the slide's own relationships.
        $dir = $part.Substring(0, $part.LastIndexOf('/'))
        $srels = Get-RelTargets $Zip "$dir/_rels/$($part.Substring($part.LastIndexOf('/') + 1)).rels" $dir
        $notes = @($srels.Values | Where-Object { $_.type -like '*/notesSlide' } | Select-Object -First 1)
        if ($notes.Count) {
            $nx = Get-ZipXml $Zip $notes[0].part
            if ($nx) {
                $nns = New-OfficeNs $nx
                $body = @(foreach ($sp in $nx.SelectNodes('//p:sp[p:nvSpPr/p:nvPr/p:ph[@type="body"]]', $nns)) { foreach ($para in $sp.SelectNodes('p:txBody/a:p', $nns)) { (@($para.SelectNodes('.//a:t', $nns) | ForEach-Object { $_.InnerText }) -join '').Trim() } }) | Where-Object { $_ }
                if ($body.Count) { [void]$sb.Append("`n`nNotes: " + ($body -join ' ')) }
            }
        }
    }
    [pscustomobject]@{ text = $sb.ToString(); slides = $n; images = @($Zip.Entries | Where-Object { $_.FullName -like 'ppt/media/*' }).Count }
}

# --- Excel ---------------------------------------------------------------------------------

function Get-ColumnIndex([string]$Ref) {
    $letters = [regex]::Match($Ref, '^[A-Za-z]+').Value.ToUpperInvariant()
    $n = 0
    foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int]$ch - 64) }
    $n - 1
}

function ConvertFrom-Xlsx($Zip, [int]$MaxRows = 500) {
    $wb = Get-ZipXml $Zip 'xl/workbook.xml'
    if (-not $wb) { throw 'no xl/workbook.xml: not an Excel workbook' }
    $ns = New-OfficeNs $wb
    $rels = Get-RelTargets $Zip 'xl/_rels/workbook.xml.rels' 'xl'
    $shared = New-Object System.Collections.Generic.List[string]
    $ssx = Get-ZipXml $Zip 'xl/sharedStrings.xml'
    if ($ssx) { $sns = New-OfficeNs $ssx; foreach ($si in $ssx.SelectNodes('//s:si', $sns)) { $shared.Add((@($si.SelectNodes('.//s:t[not(ancestor::s:rPh)]', $sns) | ForEach-Object { $_.InnerText }) -join '')) } }
    $sb = New-Object Text.StringBuilder
    $sheets = 0; $cut = 0
    foreach ($sh in $wb.SelectNodes('//s:sheets/s:sheet', $ns)) {
        $t = $rels[$sh.GetAttribute('id', $script:R)]
        if (-not $t) { continue }
        $x = Get-ZipXml $Zip $t.part
        if (-not $x) { continue }
        $sheets++
        $xns = New-OfficeNs $x
        $state = $sh.GetAttribute('state')
        if ($sb.Length) { [void]$sb.Append("`n`n") }
        [void]$sb.Append("## Sheet: $($sh.GetAttribute('name'))$(if ($state -and $state -ne 'visible') { " ($state)" })")
        $rows = New-Object System.Collections.Generic.List[object]
        $total = 0
        foreach ($row in $x.SelectNodes('//s:sheetData/s:row', $xns)) {
            $cells = @{}; $max = -1
            foreach ($c in $row.SelectNodes('s:c', $xns)) {
                $v = $c.SelectSingleNode('s:v', $xns)
                $val = switch ($c.GetAttribute('t')) {
                    's' { if ($v -and [int]$v.InnerText -lt $shared.Count) { $shared[[int]$v.InnerText] } else { '' } }
                    'inlineStr' { (@($c.SelectNodes('.//s:t', $xns) | ForEach-Object { $_.InnerText }) -join '') }
                    'b' { if ($v -and $v.InnerText -eq '1') { 'TRUE' } else { 'FALSE' } }
                    default { if ($v) { $v.InnerText } else { '' } }
                }
                if ("$val" -eq '') { continue }
                $i = if ($c.GetAttribute('r')) { Get-ColumnIndex $c.GetAttribute('r') } else { $max + 1 }
                $s = "$val"; if ($s.Length -gt 200) { $s = $s.Substring(0, 200) + '...' }
                $cells[$i] = $s; if ($i -gt $max) { $max = $i }
            }
            if ($max -lt 0) { continue }
            $total++
            if ($rows.Count -ge $MaxRows) { continue }
            $rows.Add(@(for ($k = 0; $k -le $max; $k++) { "$($cells[$k])" }))
        }
        if (-not $rows.Count) { [void]$sb.Append("`n`n(empty)"); continue }
        [void]$sb.Append("`n`n" + (Format-MdTable $rows.ToArray()))
        if ($total -gt $rows.Count) { $cut += $total - $rows.Count; [void]$sb.Append("`n`n($($total - $rows.Count) more rows not shown)") }
    }
    [pscustomobject]@{ text = $sb.ToString(); sheets = $sheets; cutRows = $cut }
}

function ConvertFrom-OfficeFile {
    <# A .docx/.pptx/.xlsx as Markdown text: @{ text; note } where note says what is not shown
       (images, comments, rows). Throws for other files or a damaged/protected document. #>
    param([Parameter(Mandatory)][string]$Path, [int]$MaxRows = 500)
    $kind = Get-OfficeKind $Path
    if ($kind -notin 'word', 'slides', 'sheet') { throw "$([IO.Path]::GetFileName($Path)) is not a document that can be read as text here" }
    $zip = Open-OfficeZip $Path
    try {
        switch ($kind) {
            'word' { $r = ConvertFrom-Docx $zip; $notes = @(); if ($r.images) { $notes += "$($r.images) image(s) not shown" }; if ($r.comments) { $notes += "$($r.comments) comment(s) not shown" } }
            'slides' { $r = ConvertFrom-Pptx $zip; $notes = @("$($r.slides) slide(s)"); if ($r.images) { $notes += "$($r.images) image(s) not shown" } }
            'sheet' { $r = ConvertFrom-Xlsx $zip $MaxRows; $notes = @("$($r.sheets) sheet(s), cell values as last calculated"); if ($r.cutRows) { $notes += "$($r.cutRows) row(s) left out" } }
        }
        [pscustomobject]@{ text = $r.text; note = ($notes -join ', ') }
    } finally { $zip.Dispose() }
}

function Test-OwnDocx([string]$Path) {
    <# Whether this .docx was written here (and not saved by Word since): only those are rewritten. #>
    try {
        $zip = Open-OfficeZip $Path
        try { $x = Get-ZipXml $zip 'docProps/app.xml'; $x -and ((@($x.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'Application' }) | Select-Object -First 1).InnerText -eq $script:Maker) }
        finally { $zip.Dispose() }
    } catch { $false }
}

# --- Writing a .docx from Markdown ---------------------------------------------------------

function ConvertTo-XmlText([string]$Text) { [Security.SecurityElement]::Escape($Text) }

function New-DocxRuns([string]$Text, [string]$Extra = '') {
    <# Runs for one line of Markdown text: **bold**, *italic*, ***both***, `code`, [text](link). #>
    $out = New-Object Text.StringBuilder
    $re = '(\*\*\*[^*]+\*\*\*|\*\*[^*]+\*\*|__[^_]+__|`[^`]+`|(?<![\w*])\*[^*\s][^*]*\*(?!\w)|(?<!\w)_[^_\s][^_]*_(?!\w)|\[[^\]]+\]\([^)\s]+\))'
    $pos = 0
    $add = {
        param([string]$t, [string]$props)
        if (-not $t) { return }
        $segs = $t -split "`t"
        for ($k = 0; $k -lt $segs.Count; $k++) {
            if ($k) { [void]$out.Append("<w:r>$(if ($props -or $Extra) { "<w:rPr>$Extra$props</w:rPr>" })<w:tab/></w:r>") }
            if ($segs[$k]) { [void]$out.Append("<w:r>$(if ($props -or $Extra) { "<w:rPr>$Extra$props</w:rPr>" })<w:t xml:space=`"preserve`">$(ConvertTo-XmlText $segs[$k])</w:t></w:r>") }
        }
    }
    foreach ($m in [regex]::Matches($Text, $re)) {
        & $add $Text.Substring($pos, $m.Index - $pos) ''
        $v = $m.Value
        if ($v.StartsWith('***')) { & $add $v.Substring(3, $v.Length - 6) '<w:b/><w:i/>' }
        elseif ($v.StartsWith('**') -or $v.StartsWith('__')) { & $add $v.Substring(2, $v.Length - 4) '<w:b/>' }
        elseif ($v.StartsWith('`')) { & $add $v.Substring(1, $v.Length - 2) '<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/>' }
        elseif ($v.StartsWith('[')) { $lm = [regex]::Match($v, '^\[([^\]]+)\]\(([^)\s]+)\)$'); & $add "$($lm.Groups[1].Value) ($($lm.Groups[2].Value))" '' }
        else { & $add $v.Substring(1, $v.Length - 2) '<w:i/>' }
        $pos = $m.Index + $m.Length
    }
    & $add $Text.Substring($pos) ''
    $out.ToString()
}

function ConvertTo-DocxXml([string]$Markdown) {
    <# word/document.xml body and the numbered lists it needs: @{ body; numbered } (numbered = how
       many numbered lists, each restarting at 1). #>
    $lines = $Markdown.Replace("`r`n", "`n").Split("`n")
    $body = New-Object Text.StringBuilder
    $para = New-Object System.Collections.Generic.List[string]
    $numbered = 0; $inNumbered = $false
    $flush = {
        if ($para.Count) { [void]$body.Append("<w:p>$(New-DocxRuns (($para | ForEach-Object { $_.Trim() }) -join ' '))</w:p>"); $para.Clear() }
    }
    $i = 0
    while ($i -lt $lines.Length) {
        $line = $lines[$i]
        if ($line -match '^\s*(```|~~~)') {
            & $flush; $inNumbered = $false
            $fence = $Matches[1]; $i++
            while ($i -lt $lines.Length -and $lines[$i] -notmatch "^\s*$([regex]::Escape($fence))\s*$") {
                $run = if ($lines[$i]) { '<w:r><w:t xml:space="preserve">' + (ConvertTo-XmlText $lines[$i]) + '</w:t></w:r>' } else { '' }
                [void]$body.Append('<w:p><w:pPr><w:pStyle w:val="Code"/></w:pPr>' + $run + '</w:p>')
                $i++
            }
            $i++; continue
        }
        if ($line -match '^\s*\|') {
            & $flush; $inNumbered = $false
            $rows = New-Object System.Collections.Generic.List[object]
            while ($i -lt $lines.Length -and $lines[$i] -match '^\s*\|') {
                $l = $lines[$i].Trim()
                if ($l -notmatch '^\|?[\s:|-]+\|?$' -or $l -notmatch '-') {
                    $l = $l.Trim('|')
                    $rows.Add(@([regex]::Split($l, '(?<!\\)\|') | ForEach-Object { $_.Trim().Replace('\|', '|') }))
                }
                $i++
            }
            if (-not $rows.Count) { continue }
            $cols = ($rows | ForEach-Object { @($_).Count } | Measure-Object -Maximum).Maximum
            $w = [int](9000 / [Math]::Max(1, $cols))
            [void]$body.Append('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/><w:tblLook w:val="0020" w:firstRow="1" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="1" w:noVBand="1"/></w:tblPr><w:tblGrid>')
            for ($c = 0; $c -lt $cols; $c++) { [void]$body.Append("<w:gridCol w:w=`"$w`"/>") }
            [void]$body.Append('</w:tblGrid>')
            $first = $true
            foreach ($row in $rows) {
                [void]$body.Append("<w:tr>$(if ($first) { '<w:trPr><w:tblHeader/></w:trPr>' })")
                for ($c = 0; $c -lt $cols; $c++) {
                    $cell = if ($c -lt @($row).Count) { "$(@($row)[$c])" } else { '' }
                    [void]$body.Append("<w:tc><w:tcPr><w:tcW w:w=`"$w`" w:type=`"dxa`"/></w:tcPr><w:p>$(New-DocxRuns $cell)</w:p></w:tc>")
                }
                [void]$body.Append('</w:tr>'); $first = $false
            }
            [void]$body.Append('</w:tbl><w:p/>')
            continue
        }
        if ($line -match '^(#{1,6})\s+(.*?)\s*#*\s*$') {
            & $flush; $inNumbered = $false
            [void]$body.Append("<w:p><w:pPr><w:pStyle w:val=`"Heading$($Matches[1].Length)`"/></w:pPr>$(New-DocxRuns $Matches[2])</w:p>")
            $i++; continue
        }
        if ($line -match '^(\s*)([-*+])\s+(.*)$' -and $line -notmatch '^\s*([-*_])(\s*\1){2,}\s*$') {
            & $flush; $inNumbered = $false
            $lvl = [Math]::Min(8, [int][Math]::Floor($Matches[1].Replace("`t", '  ').Length / 2))
            [void]$body.Append("<w:p><w:pPr><w:pStyle w:val=`"ListParagraph`"/><w:numPr><w:ilvl w:val=`"$lvl`"/><w:numId w:val=`"1`"/></w:numPr></w:pPr>$(New-DocxRuns $Matches[3])</w:p>")
            $i++; continue
        }
        if ($line -match '^(\s*)\d+[.)]\s+(.*)$') {
            & $flush
            if (-not $inNumbered) { $numbered++; $inNumbered = $true }
            $lvl = [Math]::Min(8, [int][Math]::Floor($Matches[1].Replace("`t", '  ').Length / 2))
            [void]$body.Append("<w:p><w:pPr><w:pStyle w:val=`"ListParagraph`"/><w:numPr><w:ilvl w:val=`"$lvl`"/><w:numId w:val=`"$($numbered + 1)`"/></w:numPr></w:pPr>$(New-DocxRuns $Matches[2])</w:p>")
            $i++; continue
        }
        if ($line -match '^\s*>\s?(.*)$') {
            & $flush; $inNumbered = $false
            [void]$body.Append("<w:p><w:pPr><w:pStyle w:val=`"Quote`"/></w:pPr>$(New-DocxRuns $Matches[1])</w:p>")
            $i++; continue
        }
        if ($line -match '^\s*([-*_])(\s*\1){2,}\s*$') { & $flush; $inNumbered = $false; [void]$body.Append('<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="999999"/></w:pBdr></w:pPr></w:p>'); $i++; continue }
        if (-not $line.Trim()) { & $flush; $i++; continue }   # a blank line ends a paragraph; a list goes on after one
        $inNumbered = $false
        $para.Add($line); $i++
    }
    & $flush
    @{ body = $body.ToString(); numbered = $numbered }
}

function Get-DocxStylesXml {
    $h = @{ 1 = 32; 2 = 28; 3 = 26; 4 = 24; 5 = 22; 6 = 22 }
    $heads = (1..6 | ForEach-Object { "<w:style w:type=`"paragraph`" w:styleId=`"Heading$_`"><w:name w:val=`"heading $_`"/><w:basedOn w:val=`"Normal`"/><w:next w:val=`"Normal`"/><w:uiPriority w:val=`"9`"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=`"240`" w:after=`"80`"/><w:outlineLvl w:val=`"$($_ - 1)`"/></w:pPr><w:rPr><w:b/><w:sz w:val=`"$($h[$_])`"/></w:rPr></w:style>" }) -join ''
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    "<w:styles xmlns:w=`"$script:W`">" +
    '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>' +
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>' + $heads +
    '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="40"/><w:contextualSpacing/></w:pPr></w:style>' +
    '<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="20"/></w:rPr></w:style>' +
    '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720"/></w:pPr><w:rPr><w:i/><w:color w:val="595959"/></w:rPr></w:style>' +
    '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:left w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:right w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/></w:tblBorders><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblStylePr w:type="firstRow"><w:rPr><w:b/></w:rPr><w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:tcPr></w:tblStylePr></w:style>' +
    '</w:styles>'
}

function Get-DocxNumberingXml([int]$Numbered) {
    $bullet = [string][char]0x2022
    $lv = { param([int]$k, [string]$fmt, [string]$text) "<w:lvl w:ilvl=`"$k`"><w:start w:val=`"1`"/><w:numFmt w:val=`"$fmt`"/><w:lvlText w:val=`"$text`"/><w:lvlJc w:val=`"left`"/><w:pPr><w:ind w:left=`"$(720 + 360 * $k)`" w:hanging=`"360`"/></w:pPr></w:lvl>" }
    $b = (0..8 | ForEach-Object { & $lv $_ 'bullet' $bullet }) -join ''
    $d = (0..8 | ForEach-Object { & $lv $_ $(if ($_ % 3 -eq 1) { 'lowerLetter' } elseif ($_ % 3 -eq 2) { 'lowerRoman' } else { 'decimal' }) "%$($_ + 1)." }) -join ''
    $nums = '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
    for ($k = 1; $k -le $Numbered; $k++) { $nums += "<w:num w:numId=`"$($k + 1)`"><w:abstractNumId w:val=`"1`"/><w:lvlOverride w:ilvl=`"0`"><w:startOverride w:val=`"1`"/></w:lvlOverride></w:num>" }
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    "<w:numbering xmlns:w=`"$script:W`"><w:abstractNum w:abstractNumId=`"0`"><w:multiLevelType w:val=`"hybridMultilevel`"/>$b</w:abstractNum><w:abstractNum w:abstractNumId=`"1`"><w:multiLevelType w:val=`"hybridMultilevel`"/>$d</w:abstractNum>$nums</w:numbering>"
}

function ConvertTo-DocxBytes {
    <# A Word document (.docx bytes) from Markdown: headings, paragraphs, bullet and numbered lists
       (nested by indentation), tables, code blocks, quotes, rules, **bold**, *italic*, `code`, links. #>
    param([AllowEmptyString()][string]$Markdown)
    $x = ConvertTo-DocxXml $Markdown
    $parts = [ordered]@{
        '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
        '_rels/.rels' = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"$script:PR`"><Relationship Id=`"rId1`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument`" Target=`"word/document.xml`"/><Relationship Id=`"rId2`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties`" Target=`"docProps/app.xml`"/></Relationships>"
        'docProps/app.xml' = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Properties xmlns=`"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties`"><Application>$script:Maker</Application></Properties>"
        'word/_rels/document.xml.rels' = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"$script:PR`"><Relationship Id=`"rId1`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles`" Target=`"styles.xml`"/><Relationship Id=`"rId2`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering`" Target=`"numbering.xml`"/></Relationships>"
        'word/document.xml' = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><w:document xmlns:w=`"$script:W`" xmlns:r=`"$script:R`"><w:body>$($x.body)<w:sectPr><w:pgSz w:w=`"11906`" w:h=`"16838`"/><w:pgMar w:top=`"1440`" w:right=`"1440`" w:bottom=`"1440`" w:left=`"1440`" w:header=`"708`" w:footer=`"708`" w:gutter=`"0`"/></w:sectPr></w:body></w:document>"
        'word/styles.xml' = (Get-DocxStylesXml)
        'word/numbering.xml' = (Get-DocxNumberingXml $x.numbered)
    }
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    $utf8 = New-Object Text.UTF8Encoding($false)
    try {
        foreach ($k in $parts.Keys) {
            $e = $zip.CreateEntry($k, [IO.Compression.CompressionLevel]::Optimal)
            $s = $e.Open(); try { $b = $utf8.GetBytes($parts[$k]); $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
        }
    } finally { $zip.Dispose() }
    , $ms.ToArray()
}

function Write-DocxFile([string]$Path, [string]$Markdown) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [IO.File]::WriteAllBytes($Path, (ConvertTo-DocxBytes $Markdown))
}

function Get-OfficeWriteRefusal([string]$Path, [bool]$Exists) {
    <# Why this Office file cannot be written here ($null when it can): only .docx is written, and an
       existing one only when it was written here (not made or saved in Word). #>
    $name = [IO.Path]::GetFileName($Path)
    $base = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $kind = Get-OfficeKind $Path
    if (-not $kind) { return $null }
    switch ($kind) {
        'word' {
            if ($ext -ne '.docx') { return "$name cannot be written here (macro documents are not written). Write a .docx instead." }
            if ($Exists -and -not (Test-OwnDocx $Path)) { return "$name was made or saved in Word; writing it from text would lose its formatting, images and comments. Leave it as it is and write the changed version as a new document (for example $base-new.docx), or tell the user what to change in Word." }
            return $null
        }
        'slides' { return "$name is a PowerPoint file, which cannot be written here. Write the slides as Markdown (one ## heading per slide) in a .md file, or as a .docx." }
        'sheet' { return "$name is an Excel workbook, which cannot be written here. Write the data as a .csv file (Excel opens it), or as a table in a .docx." }
        'old' { return "$name is in an old binary Office format, which cannot be written here. Write a .docx (from Markdown) or a .csv instead." }
        'image' { return "$name is an image, which cannot be written here. Describe the image to the user, or write an SVG (text) when a drawing is needed." }
        'pdf' { return "$name is a PDF, which cannot be written here. Write a .docx (from Markdown) or a .md file instead; the user can save it as PDF from Word." }
    }
    $null
}

Export-ModuleMember -Function Get-OfficeKind, Get-OfficeLabel, ConvertFrom-OfficeFile, Test-OwnDocx, ConvertTo-DocxBytes, Write-DocxFile, Get-OfficeWriteRefusal, Format-MdTable
