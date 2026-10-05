# Before/after screenshots of a page: whether anything changed, how much, and where. A fixed rule
# on pixels (StreamHub has no model of its own to judge a picture): it cannot say a change is right,
# only that the page shows no change at all, which is what a claimed-but-missing visual change
# looks like.

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

function Compare-Screenshots {
    <# Compares two screenshots of a page. Returns @{ same (pixel for pixel); changedPct (share of the
       page that looks different, on a 128x80 copy); area (where, in page pixels: x, y, w, h) }. #>
    param([Parameter(Mandatory)][string]$Before, [Parameter(Mandatory)][string]$After)
    $a = Get-ShotBitmap $Before; $b = Get-ShotBitmap $After
    try {
        if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) {
            return @{ same = $false; changedPct = 100.0; area = @{ x = 0; y = 0; w = $b.Width; h = $b.Height } }
        }
        if ((Get-PixelHash $a) -eq (Get-PixelHash $b)) { return @{ same = $true; changedPct = 0.0; area = $null } }
        $W = 128; $H = 80
        $sa = Get-SmallCopy $a $W $H; $sb = Get-SmallCopy $b $W $H
        try {
            $n = 0; $x0 = $W; $y0 = $H; $x1 = -1; $y1 = -1
            for ($y = 0; $y -lt $H; $y++) {
                for ($x = 0; $x -lt $W; $x++) {
                    $p = $sa.GetPixel($x, $y); $q = $sb.GetPixel($x, $y)
                    if ([Math]::Abs($p.R - $q.R) -gt 6 -or [Math]::Abs($p.G - $q.G) -gt 6 -or [Math]::Abs($p.B - $q.B) -gt 6) {
                        $n++
                        if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x }
                        if ($y -lt $y0) { $y0 = $y }; if ($y -gt $y1) { $y1 = $y }
                    }
                }
            }
        } finally { $sa.Dispose(); $sb.Dispose() }
        $fx = $a.Width / $W; $fy = $a.Height / $H
        # Differs, but too little to show on the small copy: a very small change.
        if ($n -eq 0) { return @{ same = $false; changedPct = 0.0; area = $null } }
        @{ same = $false; changedPct = [Math]::Round(100.0 * $n / ($W * $H), 1)
           area = @{ x = [int]($x0 * $fx); y = [int]($y0 * $fy); w = [int](($x1 - $x0 + 1) * $fx); h = [int](($y1 - $y0 + 1) * $fy) } }
    } finally { $a.Dispose(); $b.Dispose() }
}

function Format-ShotComparison([string]$Page, $Result) {
    <# One line for Copilot (and the user) about a before/after pair. #>
    if ($Result.same) { return "$Page looks exactly the same as before your changes (pixel for pixel)" }
    if (-not $Result.area) { return "$Page changed only very slightly compared with before your changes (a few pixels)" }
    $ar = $Result.area
    "$Page changed compared with before your changes: about $($Result.changedPct)% of the page, in the area from x $($ar.x), y $($ar.y) to x $($ar.x + $ar.w), y $($ar.y + $ar.h) (the screenshot is 1280 x 800)"
}

Export-ModuleMember -Function Compare-Screenshots, Format-ShotComparison
