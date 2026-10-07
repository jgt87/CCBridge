# Before/after screenshots of a page: whether anything changed, how much, and where. A fixed rule
# on pixels (StreamHub has no model of its own to judge a picture): it cannot say a change is right,
# only that the page shows no change at all, which is what a claimed-but-missing visual change
# looks like. Each changed area is named by where it is and by the page parts it is in (the layout
# the page check records with each screenshot, lib/page-layout.js), and New-ShotCrop draws the
# areas before and after side by side for Copilot.

Add-Type -AssemblyName System.Drawing

function Get-ShotBitmap([string]$Path) {
    # A copy in memory, so the file is not kept open.
    $img = [Drawing.Image]::FromFile($Path)
    try { New-Object Drawing.Bitmap $img } finally { $img.Dispose() }
}

function Get-PixelHash([Drawing.Bitmap]$Bmp) {
    $rect = New-Object Drawing.Rectangle 0, 0, $Bmp.Width, $Bmp.Height
    $data = $Bmp.LockBits($rect, [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $bytes = New-Object byte[] ($data.Stride * $Bmp.Height)
        [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    } finally { $Bmp.UnlockBits($data) }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}

function Get-SmallCopy([Drawing.Bitmap]$Bmp, [int]$W, [int]$H) {
    $small = New-Object Drawing.Bitmap $W, $H
    $g = [Drawing.Graphics]::FromImage($small)
    try {
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $g.DrawImage($Bmp, 0, 0, $W, $H)
    } finally { $g.Dispose() }
    $small
}

function Get-ChangedRegions {
    <# The separate changed areas on the small copy's grid of changed cells ($Grid, row by row): cells
       up to two apart count as one area (a changed line of text is one area, not a word each). The
       largest four, in page pixels, each with its share of the page (pct). #>
    param([bool[]]$Grid, [int]$W, [int]$H, [double]$Fx, [double]$Fy)
    $label = New-Object 'bool[]' ($W * $H)
    $found = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $Grid.Length; $i++) {
        if (-not $Grid[$i] -or $label[$i]) { continue }
        $label[$i] = $true
        $stack = New-Object Collections.Generic.Stack[int]; $stack.Push($i)
        $n = 0; $x0 = $W; $y0 = $H; $x1 = -1; $y1 = -1
        while ($stack.Count) {
            $c = $stack.Pop(); $cx = $c % $W; $cy = [int][Math]::Floor($c / $W)
            $n++
            if ($cx -lt $x0) { $x0 = $cx }; if ($cx -gt $x1) { $x1 = $cx }
            if ($cy -lt $y0) { $y0 = $cy }; if ($cy -gt $y1) { $y1 = $cy }
            for ($dy = -2; $dy -le 2; $dy++) {
                $ny = $cy + $dy; if ($ny -lt 0 -or $ny -ge $H) { continue }
                for ($dx = -2; $dx -le 2; $dx++) {
                    $nx = $cx + $dx; if ($nx -lt 0 -or $nx -ge $W) { continue }
                    $j = $ny * $W + $nx
                    if ($Grid[$j] -and -not $label[$j]) { $label[$j] = $true; $stack.Push($j) }
                }
            }
        }
        $found.Add(@{ n = $n; x = [int]($x0 * $Fx); y = [int]($y0 * $Fy); w = [int](($x1 - $x0 + 1) * $Fx); h = [int](($y1 - $y0 + 1) * $Fy); pct = [Math]::Round(100.0 * $n / ($W * $H), 1) })
    }
    @($found | Sort-Object { $_.n } -Descending | Select-Object -First 4 | ForEach-Object { $_.Remove('n'); $_ })
}

function Get-ShotPosition($Region, [int]$Width = 1280, [int]$Height = 800) {
    <# Where an area sits in the screenshot, in words: "top left", "middle", "bottom right"... #>
    $cx = ($Region.x + $Region.w / 2) / $Width; $cy = ($Region.y + $Region.h / 2) / $Height
    $v = if ($cy -lt 1 / 3) { 'top' } elseif ($cy -gt 2 / 3) { 'bottom' } else { 'middle' }
    $h = if ($cx -lt 1 / 3) { 'left' } elseif ($cx -gt 2 / 3) { 'right' } else { '' }
    if ($Region.w -ge $Width * 0.8) { $h = '' }   # across the page
    if ($Region.h -ge $Height * 0.8) { return $(if ($h) { "$h side" } else { 'whole page' }) }
    (@($v, $h) | Where-Object { $_ }) -join ' '
}

function Format-PartName($Part) {
    $t = "$($Part.text)"
    if ($Part.heading) { return "heading '$t'" }
    if ($t) { "$($Part.name) '$t'" } else { "$($Part.name)" }
}

function Find-RegionParts {
    <# The page parts (Get-PageLayoutScript's list) a changed area belongs to: the smallest part that
       holds it (not the page itself) and up to three named parts inside it, headings first. #>
    param($Region, $Layout, [int]$Width = 1280, [int]$Height = 800)
    $parts = @($Layout | Where-Object { $_ -and [int]$_.w -gt 0 -and [int]$_.h -gt 0 })
    if (-not $parts.Count) { return @{ within = $null; inside = @() } }
    $rA = [double][Math]::Max(1, $Region.w * $Region.h)
    $overlap = {
        param($p)
        $ix = [Math]::Max(0, [Math]::Min($Region.x + $Region.w, [int]$p.x + [int]$p.w) - [Math]::Max($Region.x, [int]$p.x))
        $iy = [Math]::Max(0, [Math]::Min($Region.y + $Region.h, [int]$p.y + [int]$p.h) - [Math]::Max($Region.y, [int]$p.y))
        [double]($ix * $iy)
    }
    $within = @($parts | Where-Object { ([int]$_.w * [int]$_.h) -lt 0.9 * $Width * $Height -and (& $overlap $_) -ge 0.9 * $rA } |
        Sort-Object { [int]$_.w * [int]$_.h } | Select-Object -First 1)
    $inside = @($parts | Where-Object {
            $pa = [double]([int]$_.w * [int]$_.h)
            (& $overlap $_) -ge 0.8 * $pa -and $pa -lt 0.9 * $rA -and ($_.heading -or "$($_.text)" -or "$($_.name)" -match '#')
        } | Sort-Object @{ e = { [bool]$_.heading }; Descending = $true }, @{ e = { [int]$_.w * [int]$_.h }; Descending = $true } | Select-Object -First 3)
    @{ within = $(if ($within.Count) { $within[0] } else { $null }); inside = $inside }
}

function Get-PageLayoutScript {
    <# The page-side script (lib/page-layout.js) the page check runs after a screenshot. #>
    [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'page-layout.js'))
}

function New-ShotCrop {
    <# One image of the changed areas: for each (at most two) the area before on the left and after on
       the right, with some room around it, so Copilot sees the change close up. Returns $OutPath, or
       '' when there is nothing to show. #>
    param([Parameter(Mandatory)][string]$Before, [Parameter(Mandatory)][string]$After, $Regions, [Parameter(Mandatory)][string]$OutPath)
    $list = @($Regions | Where-Object { $_ } | Select-Object -First 2)
    if (-not $list.Count) { return '' }
    $a = Get-ShotBitmap $Before; $b = Get-ShotBitmap $After
    try {
        $pad = 24; $gap = 12; $head = 22; $maxW = 610; $maxH = 360
        $rows = @(foreach ($r in $list) {
            $x = [Math]::Max(0, $r.x - $pad); $y = [Math]::Max(0, $r.y - $pad)
            $w = [Math]::Min($b.Width, $r.x + $r.w + $pad) - $x; $h = [Math]::Min($b.Height, $r.y + $r.h + $pad) - $y
            if ($w -lt 1 -or $h -lt 1) { continue }
            $scale = [Math]::Min(1.0, [Math]::Min($maxW / $w, $maxH / $h))
            @{ x = [int]$x; y = [int]$y; sw = [int]$w; sh = [int]$h; w = [int][Math]::Max(1, $w * $scale); h = [int][Math]::Max(1, $h * $scale) }
        })
        if (-not $rows.Count) { return '' }
        $cellW = [int](($rows | ForEach-Object { $_.w } | Measure-Object -Maximum).Maximum)
        $totalW = $cellW * 2 + $gap * 3
        $totalH = [int]($gap + (($rows | ForEach-Object { $head + $_.h + $gap } | Measure-Object -Sum).Sum))
        $out = New-Object Drawing.Bitmap $totalW, $totalH
        $g = [Drawing.Graphics]::FromImage($out)
        $font = New-Object Drawing.Font 'Segoe UI', 9
        try {
            $g.Clear([Drawing.Color]::FromArgb(236, 236, 236))
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $top = $gap; $i = 0
            foreach ($row in $rows) {
                $i++
                $g.DrawString("Area $i - before", $font, [Drawing.Brushes]::DimGray, [single]$gap, [single]($top + 3))
                $g.DrawString("Area $i - after", $font, [Drawing.Brushes]::DimGray, [single]($gap * 2 + $cellW), [single]($top + 3))
                $y = $top + $head
                foreach ($side in @(@{ img = $a; x = $gap }, @{ img = $b; x = $gap * 2 + $cellW })) {
                    # A before screenshot of another size: crop what it has.
                    $sw = [Math]::Min($row.sw, $side.img.Width - $row.x); $sh = [Math]::Min($row.sh, $side.img.Height - $row.y)
                    if ($sw -lt 1 -or $sh -lt 1) { continue }
                    $dst = New-Object Drawing.Rectangle $side.x, $y, ([int]($row.w * $sw / $row.sw)), ([int]($row.h * $sh / $row.sh))
                    $g.DrawImage($side.img, $dst, (New-Object Drawing.Rectangle $row.x, $row.y, $sw, $sh), [Drawing.GraphicsUnit]::Pixel)
                    $g.DrawRectangle([Drawing.Pens]::Silver, $dst)
                }
                $top = $y + $row.h + $gap
            }
        } finally { $font.Dispose(); $g.Dispose() }
        $out.Save($OutPath, [Drawing.Imaging.ImageFormat]::Png); $out.Dispose()
        $OutPath
    } finally { $a.Dispose(); $b.Dispose() }
}

function Compare-Screenshots {
    <# Compares two screenshots of a page. Returns @{ same (pixel for pixel); changedPct (share of the
       page that looks different, on a 128x80 copy); area (all changes together, in page pixels:
       x, y, w, h); regions (the separate changed areas, Get-ChangedRegions) }. #>
    param([Parameter(Mandatory)][string]$Before, [Parameter(Mandatory)][string]$After)
    $a = Get-ShotBitmap $Before; $b = Get-ShotBitmap $After
    try {
        if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) {
            $all = @{ x = 0; y = 0; w = $b.Width; h = $b.Height; pct = 100.0 }
            return @{ same = $false; changedPct = 100.0; area = $all; regions = @($all) }
        }
        if ((Get-PixelHash $a) -eq (Get-PixelHash $b)) { return @{ same = $true; changedPct = 0.0; area = $null; regions = @() } }
        $W = 128; $H = 80
        $sa = Get-SmallCopy $a $W $H; $sb = Get-SmallCopy $b $W $H
        try {
            $n = 0; $x0 = $W; $y0 = $H; $x1 = -1; $y1 = -1
            $grid = New-Object 'bool[]' ($W * $H)   # changed cells, row by row (flat: 5.1 parses 2-D indexes badly)
            for ($y = 0; $y -lt $H; $y++) {
                for ($x = 0; $x -lt $W; $x++) {
                    $p = $sa.GetPixel($x, $y); $q = $sb.GetPixel($x, $y)
                    if ([Math]::Abs($p.R - $q.R) -gt 6 -or [Math]::Abs($p.G - $q.G) -gt 6 -or [Math]::Abs($p.B - $q.B) -gt 6) {
                        $n++; $grid[$y * $W + $x] = $true
                        if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x }
                        if ($y -lt $y0) { $y0 = $y }; if ($y -gt $y1) { $y1 = $y }
                    }
                }
            }
        } finally { $sa.Dispose(); $sb.Dispose() }
        $fx = $a.Width / $W; $fy = $a.Height / $H
        # Differs, but too little to show on the small copy: a very small change.
        if ($n -eq 0) { return @{ same = $false; changedPct = 0.0; area = $null; regions = @() } }
        @{ same = $false; changedPct = [Math]::Round(100.0 * $n / ($W * $H), 1)
           area = @{ x = [int]($x0 * $fx); y = [int]($y0 * $fy); w = [int](($x1 - $x0 + 1) * $fx); h = [int](($y1 - $y0 + 1) * $fy) }
           regions = @(Get-ChangedRegions $grid $W $H $fx $fy) }
    } finally { $a.Dispose(); $b.Dispose() }
}

function Format-ShotComparison([string]$Page, $Result, $Layout = $null) {
    <# One line for Copilot (and the user) about a before/after pair: each changed area with where it
       is and, with the page's layout (Get-PageLayoutScript), which parts of the page it is in. #>
    if ($Result.same) { return "$Page looks exactly the same as before your changes (pixel for pixel)" }
    if (-not $Result.area) { return "$Page changed only very slightly compared with before your changes (a few pixels)" }
    $regions = @($Result.regions | Where-Object { $_ })
    if (-not $regions.Count) { $regions = @($Result.area) }
    $i = 0
    $areas = @(foreach ($r in $regions) {
        $i++
        $num = if ($regions.Count -gt 1) { [string]$i + ') ' } else { '' }
        $t = $num + (Get-ShotPosition $r) + " (x $($r.x)-$($r.x + $r.w), y $($r.y)-$($r.y + $r.h))"
        if ($Layout) {
            $f = Find-RegionParts $r $Layout
            $bits = @()
            if ($f.within) { $bits += "in $(Format-PartName $f.within)" }
            if (@($f.inside).Count) { $bits += 'around ' + (@($f.inside | ForEach-Object { Format-PartName $_ }) -join ', ') }
            if ($bits.Count) { $t += ': ' + ($bits -join ', ') }
        }
        $t
    })
    $where = if ($areas.Count -gt 1) { "in $($areas.Count) areas: $($areas -join '; ')" } else { "in one area, $($areas[0])" }
    "$Page changed compared with before your changes: about $($Result.changedPct)% of the page, $where (the screenshot is 1280 x 800)"
}

Export-ModuleMember -Function Compare-Screenshots, Format-ShotComparison, Get-ChangedRegions, Get-ShotPosition, Find-RegionParts, Format-PartName, Get-PageLayoutScript, New-ShotCrop
