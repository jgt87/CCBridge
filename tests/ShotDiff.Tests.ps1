# Before/after screenshots: same pixel for pixel, or how much changed and where (lib/ShotDiff.psm1).
# The images are drawn here; no browser is used.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\ShotDiff.psm1') -Force
Add-Type -AssemblyName System.Drawing

function New-TestShot([string]$Path, [scriptblock]$Draw) {
    $bmp = New-Object Drawing.Bitmap 1280, 800
    $g = [Drawing.Graphics]::FromImage($bmp)
    try { $g.Clear([Drawing.Color]::White); if ($Draw) { & $Draw $g } } finally { $g.Dispose() }
    $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

Describe 'Compare-Screenshots' {
    $d = Join-Path $env:TEMP ('ccb-shots-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
    $box = { param($g) $g.FillRectangle([Drawing.Brushes]::DarkRed, 600, 400, 200, 100) }
    New-TestShot "$d\a.png" $null
    New-TestShot "$d\b.png" $null
    New-TestShot "$d\c.png" $box
    New-TestShot "$d\e.png" { param($g) $g.FillRectangle([Drawing.Brushes]::Gray, 5, 5, 1, 1) }
    It 'finds two identical screenshots the same' {
        $r = Compare-Screenshots "$d\a.png" "$d\b.png"
        $r.same | Should Be $true
        Format-ShotComparison 'index.html' $r | Should Match 'exactly the same'
    }
    It 'says how much changed and where' {
        $r = Compare-Screenshots "$d\a.png" "$d\c.png"
        $r.same | Should Be $false
        $r.changedPct | Should BeGreaterThan 1
        $r.area.x | Should BeLessThan 620; ($r.area.x + $r.area.w) | Should BeGreaterThan 780
        $r.area.y | Should BeLessThan 420; ($r.area.y + $r.area.h) | Should BeGreaterThan 480
        Format-ShotComparison 'index.html' $r | Should Match 'changed compared with before'
    }
    It 'does not call a one-pixel change the same' {
        $r = Compare-Screenshots "$d\a.png" "$d\e.png"
        $r.same | Should Be $false
        Format-ShotComparison 'index.html' $r | Should Match 'very slightly|changed compared'
    }
    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Where a page changed' {
    $d = Join-Path $env:TEMP ('ccb-shots-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
    New-TestShot "$d\a.png" $null
    New-TestShot "$d\two.png" { param($g) $g.FillRectangle([Drawing.Brushes]::DarkRed, 40, 30, 300, 60); $g.FillRectangle([Drawing.Brushes]::Navy, 900, 650, 250, 100) }
    # Made-up page parts as page-layout.js records them.
    $layout = @(
        [pscustomobject]@{ name = 'header.site'; text = ''; heading = $false; x = 0; y = 0; w = 1280; h = 120 }
        [pscustomobject]@{ name = 'h1'; text = 'Monthly sales'; heading = $true; x = 40; y = 30; w = 300; h = 60 }
        [pscustomobject]@{ name = 'footer'; text = ''; heading = $false; x = 0; y = 620; w = 1280; h = 180 }
        [pscustomobject]@{ name = 'button#export'; text = 'Export'; heading = $false; x = 900; y = 650; w = 250; h = 100 }
    )
    It 'finds separate areas, each with its place on the page' {
        $r = Compare-Screenshots "$d\a.png" "$d\two.png"
        @($r.regions).Count | Should Be 2
        $pos = @($r.regions | ForEach-Object { Get-ShotPosition $_ }) | Sort-Object
        ($pos -join ',') | Should Be 'bottom right,top left'
    }
    It 'names the page parts of each area' {
        $r = Compare-Screenshots "$d\a.png" "$d\two.png"
        $t = Format-ShotComparison 'index.html' $r $layout
        $t | Should Match 'in 2 areas'
        $t | Should Match "top left \(x \d+-\d+, y \d+-\d+\): in header\.site, around heading 'Monthly sales'"
        $t | Should Match "bottom right \(x \d+-\d+, y \d+-\d+\): in footer, around button#export 'Export'"
        Format-ShotComparison 'index.html' $r | Should Not Match 'header'
    }
    It 'draws the areas before and after side by side' {
        $r = Compare-Screenshots "$d\a.png" "$d\two.png"
        $out = New-ShotCrop "$d\a.png" "$d\two.png" $r.regions "$d\crop.png"
        $out | Should Be "$d\crop.png"
        $img = [Drawing.Image]::FromFile("$d\crop.png")
        try { $img.Width | Should BeLessThan 1281; $img.Height | Should BeGreaterThan 150 } finally { $img.Dispose() }
        New-ShotCrop "$d\a.png" "$d\two.png" @() "$d\none.png" | Should Be ''
    }
    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
}
