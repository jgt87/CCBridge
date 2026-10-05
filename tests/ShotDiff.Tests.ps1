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
