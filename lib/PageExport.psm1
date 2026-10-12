# A project page as a report: a PDF (Edge prints the page, with the UI kit's print styles) or a
# PowerPoint deck (each chart and the row of key figures captured as a picture on its own slide, with
# the heading above it as the slide title). The page opens in a tab of StreamHub's Edge at a fixed
# window size, from the address the page check uses, so the data loads as it does there. The files
# go to Runbooks/Exports/ (Layout Exports). Write-ExportScript writes Scripts/Export-Page.ps1, which
# prints the PDF with Edge alone, for a schedule or a chain while StreamHub is closed.
# ASCII only (Windows PowerShell 5.1).

Import-Module (Join-Path $PSScriptRoot 'Cdp.psm1')
Add-Type -AssemblyName System.IO.Compression

$script:FindParts = @'
(() => {
  const seen = new Set(), out = [];
  const heading = (el) => {
    const box = el.closest('.kit-panel, section, figure, article, .card') || el.parentElement;
    const h = box && box.querySelector('.kit-panel__title, h1, h2, h3, h4, figcaption, .kit-chart__title');
    return ((h && h.textContent) || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
  };
  const add = (el, title) => {
    if (!el || seen.has(el)) return;
    for (const s of seen) if (s.contains(el) || el.contains(s)) return;
    const r = el.getBoundingClientRect();
    if (r.width < 120 || r.height < 60) return;
    seen.add(el);
    out.push({ title: title || heading(el), x: r.left + window.scrollX, y: r.top + window.scrollY, width: r.width, height: r.height });
  };
  const figs = document.querySelector('.kit-figures');
  if (figs) add(figs, 'Key figures');
  document.querySelectorAll('[data-kit-chart], .kit-chart, .kit-barlist, canvas, svg').forEach((el) => {
    const host = el.closest('[data-kit-chart], .kit-chart, .kit-barlist') || el;
    if (host.closest('.kit-figures')) return;
    add(host);
  });
  return JSON.stringify(out.slice(0, 40).map((p, i) => ({ ...p, title: p.title || ('Chart ' + (i + 1)) })));
})()
'@

function Open-PageTab {
    # A tab on $Url at 1400 x 900, after the page and its charts are drawn: @{ Session; Close }.
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Url, [int]$SettleMs = 2500)
    $target = Invoke-RestMethod -Method Put "http://127.0.0.1:$Port/json/new?about:blank"
    $s = Connect-Cdp $target.webSocketDebuggerUrl
    $close = { try { Disconnect-Cdp $s } catch { }; try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/close/$($target.id)" } catch { } }.GetNewClosure()
    try {
        $null = Invoke-Cdp $s 'Emulation.setDeviceMetricsOverride' @{ width = 1400; height = 900; deviceScaleFactor = 1; mobile = $false }
        # Reports are light, whatever the computer's theme (a slide or page in dark mode prints badly).
        $null = Invoke-Cdp $s 'Emulation.setEmulatedMedia' @{ features = @(@{ name = 'prefers-color-scheme'; value = 'light' }) }
        $null = Invoke-Cdp $s 'Page.navigate' @{ url = $Url }
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 250
            $st = try { (Invoke-Cdp $s 'Runtime.evaluate' @{ expression = 'document.readyState'; returnByValue = $true }).result.value } catch { '' }
            if ($st -eq 'complete') { break }
        }
        Start-Sleep -Milliseconds $SettleMs   # charts animate in and data loads after the page
        @{ Session = $s; Close = $close }
    } catch { & $close; throw }
}

function Export-PagePdf {
    <# The page as a PDF (landscape A4 unless the page sets its own @page size, backgrounds printed).
       Returns the bytes. #>
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Url)
    $tab = Open-PageTab $Port $Url
    try {
        $r = Invoke-Cdp $tab.Session 'Page.printToPDF' @{ landscape = $true; printBackground = $true; preferCSSPageSize = $true; marginTop = 0.4; marginBottom = 0.4; marginLeft = 0.4; marginRight = 0.4 } -TimeoutMs 120000
        , [Convert]::FromBase64String($r.data)
    } finally { & $tab.Close }
}

function Get-PageParts {
    # The charts and figures on the page as pictures: @(@{ title; png (bytes); width; height }).
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Url)
    $tab = Open-PageTab $Port $Url
    try {
        $boxes = @(("$((Invoke-Cdp $tab.Session 'Runtime.evaluate' @{ expression = $script:FindParts; returnByValue = $true }).result.value)" | ConvertFrom-Json) | ForEach-Object { $_ })
        @(foreach ($b in $boxes) {
            $clip = @{ x = [double]$b.x; y = [double]$b.y; width = [double]$b.width; height = [double]$b.height; scale = 2 }
            $shot = Invoke-Cdp $tab.Session 'Page.captureScreenshot' @{ format = 'png'; clip = $clip; captureBeyondViewport = $true } -TimeoutMs 60000
            @{ title = "$($b.title)"; png = [Convert]::FromBase64String($shot.data); width = [double]$b.width; height = [double]$b.height }
        })
    } finally { & $tab.Close }
}

function ConvertTo-XmlEsc([string]$Text) { [Security.SecurityElement]::Escape($Text) }

function ConvertTo-PptxBytes {
    <# A PowerPoint deck (.pptx bytes): a title slide, then one slide per picture with its title,
       the picture fitted below it (16:9 slides). $Parts: @(@{ title; png; width; height }). #>
    param([string]$Title = 'Report', $Parts = @(), [string]$Subtitle = '')
    $P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
    $A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
    $R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $PR = 'http://schemas.openxmlformats.org/package/2006/relationships'
    $RT = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $cx = 12192000; $cy = 6858000
    $text = {
        param([int]$id, [string]$name, [long]$x, [long]$y, [long]$w, [long]$h, [string]$t, [int]$size, [bool]$bold)
        "<p:sp><p:nvSpPr><p:cNvPr id=`"$id`" name=`"$name`"/><p:cNvSpPr txBox=`"1`"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=`"$x`" y=`"$y`"/><a:ext cx=`"$w`" cy=`"$h`"/></a:xfrm><a:prstGeom prst=`"rect`"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr wrap=`"square`"/><a:lstStyle/><a:p><a:r><a:rPr lang=`"en-US`" sz=`"$size`"$(if ($bold) { ' b="1"' })/><a:t>$(ConvertTo-XmlEsc $t)</a:t></a:r></a:p></p:txBody></p:sp>"
    }
    $tree = { param($inner) "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=`"1`" name=`"`"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=`"0`" y=`"0`"/><a:ext cx=`"0`" cy=`"0`"/><a:chOff x=`"0`" y=`"0`"/><a:chExt cx=`"0`" cy=`"0`"/></a:xfrm></p:grpSpPr>$inner</p:spTree></p:cSld>" }
    $files = [ordered]@{}
    $slides = New-Object System.Collections.Generic.List[string]
    # The title slide.
    $slides.Add("<p:sld xmlns:a=`"$A`" xmlns:r=`"$R`" xmlns:p=`"$P`">$(& $tree ((& $text 2 'Title' 685800 2286000 10820400 1143000 $Title 4000 $true) + $(if ($Subtitle) { & $text 3 'Subtitle' 685800 3505200 10820400 685800 $Subtitle 2000 $false })))<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
    $i = 0
    foreach ($part in @($Parts)) {
        $i++
        $maxW = 11277600; $maxH = 5257800; $top = 1219200
        $w = [double]$part.width; $h = [double]$part.height
        $scale = [Math]::Min($maxW / [Math]::Max(1, $w), $maxH / [Math]::Max(1, $h))
        $pw = [long]($w * $scale); $ph = [long]($h * $scale)
        $px = [long](($cx - $pw) / 2)
        $pic = "<p:pic><p:nvPicPr><p:cNvPr id=`"3`" name=`"Picture $i`"/><p:cNvPicPr><a:picLocks noChangeAspect=`"1`"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=`"rId2`"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=`"$px`" y=`"$top`"/><a:ext cx=`"$pw`" cy=`"$ph`"/></a:xfrm><a:prstGeom prst=`"rect`"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
        $slides.Add("<p:sld xmlns:a=`"$A`" xmlns:r=`"$R`" xmlns:p=`"$P`">$(& $tree ((& $text 2 'Title' 457200 304800 11277600 762000 "$($part.title)" 2800 $true) + $pic))<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
        $files["ppt/media/image$i.png"] = $part.png
    }
    $n = $slides.Count
    $ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
    for ($k = 1; $k -le $n; $k++) { $ct += "<Override PartName=`"/ppt/slides/slide$k.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.presentationml.slide+xml`"/>" }
    $files['[Content_Types].xml'] = $ct + '</Types>'
    $files['_rels/.rels'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"$PR`"><Relationship Id=`"rId1`" Type=`"$RT/officeDocument`" Target=`"ppt/presentation.xml`"/><Relationship Id=`"rId2`" Type=`"$RT/extended-properties`" Target=`"docProps/app.xml`"/></Relationships>"
    $files['docProps/app.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>StreamHub</Application></Properties>'
    $ids = (1..$n | ForEach-Object { "<p:sldId id=`"$(255 + $_)`" r:id=`"rId$($_ + 1)`"/>" }) -join ''
    $files['ppt/presentation.xml'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><p:presentation xmlns:a=`"$A`" xmlns:r=`"$R`" xmlns:p=`"$P`"><p:sldMasterIdLst><p:sldMasterId id=`"2147483648`" r:id=`"rId1`"/></p:sldMasterIdLst><p:sldIdLst>$ids</p:sldIdLst><p:sldSz cx=`"$cx`" cy=`"$cy`"/><p:notesSz cx=`"6858000`" cy=`"9144000`"/></p:presentation>"
    $rels = (1..$n | ForEach-Object { "<Relationship Id=`"rId$($_ + 1)`" Type=`"$RT/slide`" Target=`"slides/slide$_.xml`"/>" }) -join ''
    $files['ppt/_rels/presentation.xml.rels'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"$PR`"><Relationship Id=`"rId1`" Type=`"$RT/slideMaster`" Target=`"slideMasters/slideMaster1.xml`"/>$rels<Relationship Id=`"rId$($n + 2)`" Type=`"$RT/theme`" Target=`"theme/theme1.xml`"/></Relationships>"
    $files['ppt/slideMasters/slideMaster1.xml'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><p:sldMaster xmlns:a=`"$A`" xmlns:r=`"$R`" xmlns:p=`"$P`">$(& $tree '')<p:clrMap bg1=`"lt1`" tx1=`"dk1`" bg2=`"lt2`" tx2=`"dk2`" accent1=`"accent1`" accent2=`"accent2`" accent3=`"accent3`" accent4=`"accent4`" accent5=`"accent5`" accent6=`"accent6`" hlink=`"hlink`" folHlink=`"folHlink`"/><p:sldLayoutIdLst><p:sldLayoutId id=`"2147483649`" r:id=`"rId1`"/></p:sldLayoutIdLst></p:sldMaster>"
    $files['ppt/slideMasters/_rels/slideMaster1.xml.rels'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"$PR`"><Relationship Id=`"rId1`" Type=`"$RT/slideLayout`" Target=`"../slideLayouts/slideLayout1.xml`"/><Relationship Id=`"rId2`" Type=`"$RT/theme`" Target=`"../theme/theme1.xml`"/></Relationships>"
    $files['ppt/slideLayouts/slideLayout1.xml'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><p:sldLayout xmlns:a=`"$A`" xmlns:r=`"$R`" xmlns:p=`"$P`" type=`"blank`" preserve=`"1`">$(& $tree '')<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
    $files['ppt/slideLayouts/_rels/slideLayout1.xml.rels'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"$PR`"><Relationship Id=`"rId1`" Type=`"$RT/slideMaster`" Target=`"../slideMasters/slideMaster1.xml`"/></Relationships>"
    $clr = { param($n, $v) "<a:$n><a:srgbClr val=`"$v`"/></a:$n>" }
    $fill = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
    $ln = '<a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
    $files['ppt/theme/theme1.xml'] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><a:theme xmlns:a=`"$A`" name=`"StreamHub`"><a:themeElements><a:clrScheme name=`"StreamHub`"><a:dk1><a:sysClr val=`"windowText`" lastClr=`"000000`"/></a:dk1><a:lt1><a:sysClr val=`"window`" lastClr=`"FFFFFF`"/></a:lt1>$(& $clr 'dk2' '1F2937')$(& $clr 'lt2' 'F3F4F6')$(& $clr 'accent1' '2563EB')$(& $clr 'accent2' '0EA5E9')$(& $clr 'accent3' '10B981')$(& $clr 'accent4' 'F59E0B')$(& $clr 'accent5' 'EF4444')$(& $clr 'accent6' '8B5CF6')$(& $clr 'hlink' '2563EB')$(& $clr 'folHlink' '7C3AED')</a:clrScheme><a:fontScheme name=`"StreamHub`"><a:majorFont><a:latin typeface=`"Arial`"/><a:ea typeface=`"`"/><a:cs typeface=`"`"/></a:majorFont><a:minorFont><a:latin typeface=`"Arial`"/><a:ea typeface=`"`"/><a:cs typeface=`"`"/></a:minorFont></a:fontScheme><a:fmtScheme name=`"StreamHub`"><a:fillStyleLst>$fill$fill$fill</a:fillStyleLst><a:lnStyleLst>$ln$ln$ln</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>$fill$fill$fill</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
    for ($k = 1; $k -le $n; $k++) {
        $files["ppt/slides/slide$k.xml"] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>" + $slides[$k - 1]
        $img = if ($k -gt 1) { "<Relationship Id=`"rId2`" Type=`"$RT/image`" Target=`"../media/image$($k - 1).png`"/>" } else { '' }
        $files["ppt/slides/_rels/slide$k.xml.rels"] = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"$PR`"><Relationship Id=`"rId1`" Type=`"$RT/slideLayout`" Target=`"../slideLayouts/slideLayout1.xml`"/>$img</Relationships>"
    }
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    $utf8 = New-Object Text.UTF8Encoding($false)
    try {
        # [Content_Types].xml first, as Office writes it.
        foreach ($k in @('[Content_Types].xml') + @($files.Keys | Where-Object { $_ -ne '[Content_Types].xml' })) {
            $e = $zip.CreateEntry($k, [IO.Compression.CompressionLevel]::Optimal)
            $st = $e.Open()
            try { $b = if ($files[$k] -is [byte[]]) { $files[$k] } else { $utf8.GetBytes([string]$files[$k]) }; $st.Write($b, 0, $b.Length) } finally { $st.Dispose() }
        }
    } finally { $zip.Dispose() }
    , $ms.ToArray()
}

function Get-ExportName([string]$Page, [string]$Ext, [datetime]$Now = (Get-Date)) {
    # Runbooks/Exports/PAGE-yyyyMMdd-HHmm.EXT
    "Runbooks/Exports/$([IO.Path]::GetFileNameWithoutExtension($Page) -replace '[^\w.-]+', '-')-$($Now.ToString('yyyyMMdd-HHmm')).$Ext"
}

function Write-ExportScript {
    <# Scripts/Export-Page.ps1: the PDF of a page with Edge alone (headless print), for a schedule or a
       chain while StreamHub is closed. Returns the project-relative path. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $rel = 'Scripts/Export-Page.ps1'
    $text = @'
<#
  Saves a page of this project as a PDF in Runbooks/Exports/, with Edge (nothing to install).
  Written by the helper program (StreamHub); run it yourself or from a chain or schedule:
    powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/Export-Page.ps1 index.html
#>
param([string]$Page = 'index.html')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root $Page
if (-not (Test-Path -LiteralPath $src)) { throw "No page $Page in the project." }
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge was not found.' }
$out = Join-Path $root ('Runbooks\Exports\' + [IO.Path]::GetFileNameWithoutExtension($Page) + '-' + (Get-Date).ToString('yyyyMMdd-HHmm') + '.pdf')
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out)
$profile = Join-Path $env:TEMP ('export-page-' + [guid]::NewGuid().ToString('N'))
$url = 'file:///' + (Resolve-Path -LiteralPath $src).Path.Replace('\', '/')
$p = Start-Process -FilePath $edge -ArgumentList @('--headless=new', '--disable-gpu', "--user-data-dir=$profile", '--no-pdf-header-footer', '--virtual-time-budget=5000', "--print-to-pdf=$out", $url) -PassThru -WindowStyle Hidden
$p.WaitForExit(120000) | Out-Null
Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $out)) { throw 'Edge did not save the PDF.' }
Write-Output "Saved $out"
'@
    $full = Join-Path $ProjectRoot $rel.Replace('/', '\')
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
    [IO.File]::WriteAllText($full, $text, (New-Object Text.UTF8Encoding($false)))
    $rel
}

Export-ModuleMember -Function Open-PageTab, Export-PagePdf, Get-PageParts, ConvertTo-PptxBytes, Get-ExportName, Write-ExportScript
