# WCAG contrast (2.x, level AA): the ratio between two colours from their relative luminance.
# Text needs 4.5:1 (3:1 when large: 24px, or 18.66px bold); the borders of fields and buttons and
# other interface parts need 3:1. Used on the UI kit's tokens (Test-TokenContrast) and, through
# lib/contrast-check.js, on real pages during the page check.

function ConvertFrom-CssColor([string]$Value) {
    <# @{ r; g; b; a } (0-255, alpha 0-1) from #rgb, #rgba, #rrggbb, #rrggbbaa, rgb() or rgba(), else $null. #>
    $v = "$Value".Trim().ToLowerInvariant()
    if ($v -match '^#([0-9a-f]{3,4})$') {
        $h = $Matches[1]
        $c = @(0..($h.Length - 1) | ForEach-Object { [Convert]::ToInt32("$($h[$_])$($h[$_])", 16) })
        return @{ r = $c[0]; g = $c[1]; b = $c[2]; a = $(if ($c.Count -eq 4) { $c[3] / 255 } else { 1.0 }) }
    }
    if ($v -match '^#([0-9a-f]{6})([0-9a-f]{2})?$') {
        $h = $Matches[1]
        $a = if ($Matches[2]) { [Convert]::ToInt32($Matches[2], 16) / 255 } else { 1.0 }
        return @{ r = [Convert]::ToInt32($h.Substring(0, 2), 16); g = [Convert]::ToInt32($h.Substring(2, 2), 16); b = [Convert]::ToInt32($h.Substring(4, 2), 16); a = $a }
    }
    if ($v -match '^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$') {
        $a = 1.0
        if ($Matches[4]) { $a = if ($Matches[4].EndsWith('%')) { [double]$Matches[4].TrimEnd('%') / 100 } else { [double]$Matches[4] } }
        return @{ r = [double]$Matches[1]; g = [double]$Matches[2]; b = [double]$Matches[3]; a = $a }
    }
    $null
}

function Get-RelativeLuminance($Color) {
    $ch = foreach ($x in @($Color.r, $Color.g, $Color.b)) {
        $s = [double]$x / 255
        if ($s -le 0.03928) { $s / 12.92 } else { [Math]::Pow(($s + 0.055) / 1.055, 2.4) }
    }
    0.2126 * $ch[0] + 0.7152 * $ch[1] + 0.0722 * $ch[2]
}

function Get-ContrastRatio($Foreground, $Background) {
    <# The WCAG ratio (1 to 21) of two colours (strings or ConvertFrom-CssColor results); a
       see-through foreground is mixed onto the background first. #>
    $f = if ($Foreground -is [string]) { ConvertFrom-CssColor $Foreground } else { $Foreground }
    $b = if ($Background -is [string]) { ConvertFrom-CssColor $Background } else { $Background }
    if (-not $f -or -not $b) { return $null }
    if ($f.a -lt 1) { $f = @{ r = $f.r * $f.a + $b.r * (1 - $f.a); g = $f.g * $f.a + $b.g * (1 - $f.a); b = $f.b * $f.a + $b.b * (1 - $f.a); a = 1.0 } }
    $l1 = Get-RelativeLuminance $f; $l2 = Get-RelativeLuminance $b
    [Math]::Round(([Math]::Max($l1, $l2) + 0.05) / ([Math]::Min($l1, $l2) + 0.05), 2)
}

# The kit's colour pairs that must stay readable: foreground token, background token, minimum, what.
$script:TokenPairs = @(
    @('--kit-text', '--kit-bg', 4.5, 'text on the page'),
    @('--kit-text', '--kit-surface', 4.5, 'text on panels'),
    @('--kit-text', '--kit-surface-2', 4.5, 'text on table headers and hover rows'),
    @('--kit-text-muted', '--kit-bg', 4.5, 'muted text on the page'),
    @('--kit-text-muted', '--kit-surface', 4.5, 'muted text on panels'),
    @('--kit-text-muted', '--kit-surface-2', 4.5, 'muted text on table headers'),
    @('--kit-on-accent', '--kit-accent', 4.5, 'primary button text'),
    @('--kit-on-accent', '--kit-accent-hover', 4.5, 'primary button text on hover'),
    @('--kit-accent', '--kit-bg', 4.5, 'links on the page'),
    @('--kit-accent', '--kit-surface', 4.5, 'links on panels'),
    @('--kit-accent', '--kit-accent-soft', 4.5, 'accent badges'),
    @('--kit-ok', '--kit-ok-soft', 4.5, 'ok badges'),
    @('--kit-warn', '--kit-warn-soft', 4.5, 'warning badges'),
    @('--kit-error', '--kit-error-soft', 4.5, 'error badges'),
    @('--kit-error', '--kit-surface', 4.5, 'danger buttons and error text'),
    @('--kit-border-strong', '--kit-surface', 3.0, 'borders of fields and buttons'),
    @('--kit-border-strong', '--kit-bg', 3.0, 'borders of fields and buttons on the page'),
    @('--kit-accent', '--kit-bg', 3.0, 'scrollbar handles on hover'),
    @('--kit-accent', '--kit-surface', 3.0, 'the focus and selected-tab marks'),
    @('--kit-title', '--kit-surface', 4.5, 'titles on panels'),
    @('--kit-title', '--kit-bg', 4.5, 'titles on the page'),
    @('--kit-icon', '--kit-surface', 3.0, 'icons on panels'),
    @('--kit-on-gradient', '--kit-gradient-from', 4.5, 'text on the band header (its light end)'),
    @('--kit-on-gradient', '--kit-gradient-to', 4.5, 'text on the band header (its dark end)'),
    @('--kit-chart-1', '--kit-surface', 3.0, 'chart colour 1 on panels'),
    @('--kit-chart-2', '--kit-surface', 3.0, 'chart colour 2 on panels'),
    @('--kit-chart-3', '--kit-surface', 3.0, 'chart colour 3 on panels'),
    @('--kit-chart-4', '--kit-surface', 3.0, 'chart colour 4 on panels'),
    @('--kit-chart-5', '--kit-surface', 3.0, 'chart colour 5 on panels'),
    @('--kit-chart-6', '--kit-surface', 3.0, 'chart colour 6 on panels')
)

function Get-TokenBlocks([AllowEmptyString()][string]$Css) {
    <# The --kit-* colour values of a tokens file: @{ light = @{ name = value }; dark = @{...} }. Dark
       is the light values with the dark block's on top (the last dark block wins). #>
    $light = @{}; $dark = @{}
    $strip = [regex]::Replace("$Css", '(?s)/\*.*?\*/', '')
    foreach ($m in [regex]::Matches($strip, '(?s)([^{}]+)\{([^{}]*)\}')) {
        $sel = $m.Groups[1].Value
        # Inside @media (prefers-color-scheme: dark) { ... }: the enclosing block's header says dark.
        $before = $strip.Substring(0, $m.Index)
        $open = $before.LastIndexOf('{'); $close = $before.LastIndexOf('}')
        $outer = ''
        if ($open -gt $close) { $from = [Math]::Max($before.LastIndexOf('}', $open), -1) + 1; $outer = $before.Substring($from, $open - $from) }
        $isDark = ($sel -match 'dark') -or ($outer -match 'prefers-color-scheme\s*:\s*dark')
        foreach ($d in [regex]::Matches($m.Groups[2].Value, '(--kit-[\w-]+)\s*:\s*([^;]+);')) {
            $target = if ($isDark) { $dark } else { $light }
            $target[$d.Groups[1].Value] = $d.Groups[2].Value.Trim()
        }
    }
    $merged = @{}; foreach ($k in $light.Keys) { $merged[$k] = $light[$k] }; foreach ($k in $dark.Keys) { $merged[$k] = $dark[$k] }
    @{ light = $light; dark = $(if ($dark.Count) { $merged } else { @{} }) }
}

function Test-TokenContrast([AllowEmptyString()][string]$Css) {
    <# The kit's colour pairs below their WCAG minimum, as lines; nothing when all pass. #>
    $blocks = Get-TokenBlocks $Css
    foreach ($mode in 'light', 'dark') {
        $t = $blocks[$mode]
        if (-not $t.Count) { continue }
        foreach ($p in $script:TokenPairs) {
            if (-not $t.ContainsKey($p[0]) -or -not $t.ContainsKey($p[1])) { continue }
            $r = Get-ContrastRatio $t[$p[0]] $t[$p[1]]
            if ($null -ne $r -and $r -lt $p[2]) { "contrast ($mode): $($p[3]) is $($r):1 ($($p[0]) $($t[$p[0]]) on $($p[1]) $($t[$p[1]])); WCAG AA needs $($p[2]):1" }
        }
        # Chart colours next to each other (a stacked bar, ring slices, a legend) must tell apart:
        # clearly lighter or darker (1.4:1), or a different hue (60 degrees or more).
        for ($i = 1; $i -lt 6; $i++) {
            $a = $t["--kit-chart-$i"]; $b = $t["--kit-chart-$($i + 1)"]
            if (-not $a -or -not $b) { continue }
            $r = Get-ContrastRatio $a $b
            $ha = Get-ColorHue $a; $hb = Get-ColorHue $b
            if ($null -eq $r -or $null -eq $ha -or $null -eq $hb) { continue }
            $dh = [Math]::Abs($ha - $hb); if ($dh -gt 180) { $dh = 360 - $dh }
            if ($r -lt 1.4 -and $dh -lt 60) { "chart colours ($mode): --kit-chart-$i $a and --kit-chart-$($i + 1) $b look alike ($($r):1, $([int]$dh) degrees of hue apart); neighbouring series need 1.4:1 or 60 degrees" }
        }
    }
}

function Get-ColorHue([string]$Css) {
    <# The hue (0-360) of a CSS colour, or $null for a grey (no hue) or a value that is not a colour. #>
    $c = ConvertFrom-CssColor $Css
    if ($null -eq $c) { return $null }
    $r = $c.r / 255; $g = $c.g / 255; $b = $c.b / 255
    $max = [Math]::Max($r, [Math]::Max($g, $b)); $min = [Math]::Min($r, [Math]::Min($g, $b)); $d = $max - $min
    if ($d -lt 0.08) { return $null }
    $h = if ($max -eq $r) { (($g - $b) / $d) % 6 } elseif ($max -eq $g) { ($b - $r) / $d + 2 } else { ($r - $g) / $d + 4 }
    $h = $h * 60; if ($h -lt 0) { $h += 360 }
    $h
}

function Get-ContrastScript {
    <# The page-side check (lib/contrast-check.js), run in the tab by the page check. #>
    [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'contrast-check.js'))
}

function Get-PageContentScript {
    <# The page-side check of what the page shows (lib/page-content-check.js): broken characters, bars
       that do not show their percentage, tables that cannot be sorted. Run by the page check. #>
    [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'page-content-check.js'))
}

function Get-NarrowScreenScript {
    <# The page check at phone width (lib/narrow-check.js): sideways scrolling and the parts that cause it. #>
    [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'narrow-check.js'))
}

Export-ModuleMember -Function ConvertFrom-CssColor, Get-RelativeLuminance, Get-ContrastRatio, Get-TokenBlocks, Test-TokenContrast, Get-ContrastScript, Get-PageContentScript, Get-NarrowScreenScript
