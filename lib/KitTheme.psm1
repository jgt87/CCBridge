# Theme from your colours (only on request: the command menu). The person gives an accent colour and,
# if they like, a second (brand) colour and a neutral tint; StreamHub derives the UI kit's colour
# tokens from them with fixed colour maths and writes them into the project's styles/kit/tokens.css
# (never the kit's template, never the shared catalogue).
#
# The maths, in HSL (hue, saturation, lightness), every step a plain rule:
# - Light. The accent keeps its hue and saturation and is darkened in 2% lightness steps until links
#   (on the page, on panels, on its own soft badge) and white button text read 4.5:1. Hover is 6%
#   darker. The soft badge colour is the accent's hue at 95% lightness. Titles and icons are the
#   accent. The second colour (default: the accent's hue at 50% lightness) is --kit-accent-2; the band
#   gradient runs from it, darkened until white text reads 4.5:1, to the accent.
# - Dark (only when the project's tokens.css has dark blocks). The accent's hue, lightened from 55%
#   until it reads 4.5:1 on the dark page, panels and soft badge and black button text reads 4.5:1 on
#   it; hover 8% lighter; the soft badge at 16% lightness.
# - Charts: six hues from the second colour (else the accent; blue for a grey one), turned by 0, 150,
#   270, 60, 210 and 330 degrees, so neighbours are 120 degrees or more apart (Contrast's neighbour rule asks 60); each
#   darkened (light) or lightened (dark) until it reads 3:1 on panels.
# - Neutral tint (optional): page, header rows, dividers, field edges and muted text get the tint's
#   hue at low saturation (12-15%), with field edges and muted text stepped until 3:1 / 4.5:1.
# Tokens built from the accent with var() or color-mix (the tints, the focus ring, the scrollbar on
# hover) follow by themselves; sizes, spacing, radii and fonts are left as they are. The finished file
# goes through Contrast Test-TokenContrast in light and dark before anything is written.

Import-Module (Join-Path $PSScriptRoot 'Contrast.psm1')
Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')   # Resolve-ProjectPath
Import-Module (Join-Path $PSScriptRoot 'Executor.psm1')    # New-Checkpoint, Save-CheckpointFile
Import-Module (Join-Path $PSScriptRoot 'UiKit.psm1')       # Get-TokenBlockSpans, Get-UiKitFolder

$script:ChartTurns = @(0, 150, 270, 60, 210, 330)
$script:ThemeFile = '.streamhub\kit-theme.json'

function ConvertTo-Hsl([string]$Css) {
    <# @{ h (0-360); s; l (0-1) } of a CSS colour, or $null. #>
    $c = ConvertFrom-CssColor $Css
    if ($null -eq $c) { return $null }
    $r = [double]$c.r / 255; $g = [double]$c.g / 255; $b = [double]$c.b / 255   # doubles: [Math]::Max of an int 0 and a double picks the int overload
    $max = [Math]::Max($r, [Math]::Max($g, $b)); $min = [Math]::Min($r, [Math]::Min($g, $b)); $d = $max - $min
    $l = ($max + $min) / 2
    if ($d -eq 0) { return @{ h = 0.0; s = 0.0; l = $l } }
    $s = $d / (1 - [Math]::Abs(2 * $l - 1))
    $h = if ($max -eq $r) { (($g - $b) / $d) % 6 } elseif ($max -eq $g) { ($b - $r) / $d + 2 } else { ($r - $g) / $d + 4 }
    $h = $h * 60; if ($h -lt 0) { $h += 360 }
    @{ h = $h; s = [Math]::Min(1.0, $s); l = $l }
}

function ConvertFrom-Hsl([double]$H, [double]$S, [double]$L) {
    <# '#rrggbb' of an HSL colour (hue turned into 0-360, saturation and lightness kept in 0-1). #>
    $H = (($H % 360) + 360) % 360; $S = [Math]::Max(0.0, [Math]::Min(1.0, $S)); $L = [Math]::Max(0.0, [Math]::Min(1.0, $L))
    $c = (1 - [Math]::Abs(2 * $L - 1)) * $S
    $x = $c * (1 - [Math]::Abs((($H / 60) % 2) - 1))
    $m = $L - $c / 2
    $rgb = switch ([int][Math]::Floor($H / 60)) { 0 { $c, $x, 0 } 1 { $x, $c, 0 } 2 { 0, $c, $x } 3 { 0, $x, $c } 4 { $x, 0, $c } default { $c, 0, $x } }
    '#' + (-join @($rgb | ForEach-Object { ([int][Math]::Round(([double]$_ + $m) * 255)).ToString('x2') }))
}

function Step-Lightness($Hsl, [double]$Delta, [scriptblock]$Ok) {
    <# The colour, or the first shade 2% (Delta) at a time darker or lighter for which $Ok passes:
       @{ hex; steps }, or $null when none up to black or white does. #>
    # $Ok runs in a child scope of this call, so it sees the caller's variables (no closure: a
    # closure would lose this module's private functions).
    $l = [double]$Hsl.l
    for ($i = 0; $i -le 60; $i++) {
        $hex = ConvertFrom-Hsl $Hsl.h $Hsl.s $l
        if (& $Ok $hex) { return @{ hex = $hex; steps = $i } }
        if (($Delta -lt 0 -and $l -le 0) -or ($Delta -gt 0 -and $l -ge 1)) { break }
        $l = [Math]::Max(0.0, [Math]::Min(1.0, $l + $Delta))
    }
    $null
}

function Test-Ratios([string]$Color, [string[]]$Others, [double]$Min) {
    # Whether $Color reads $Min:1 against every one of $Others.
    foreach ($o in $Others) { $r = Get-ContrastRatio $Color $o; if ($null -eq $r -or $r -lt $Min) { return $false } }
    $true
}

function Get-ThemeColor($Map, [string]$Name, [string]$Default) {
    # A token's value when it is a plain colour, else the default.
    $v = "$($Map[$Name])"
    if ($v -and (ConvertFrom-CssColor $v)) { $v } else { $Default }
}

function Get-NeutralTokens($Neutral, [string]$Surface, [bool]$Dark) {
    <# The neutral tokens from a tint (light or dark), with field edges and muted text stepped until
       they read. Returns an ordered map, or a string with the reason when they cannot. #>
    $s = [Math]::Min($Neutral.s, 0.12); $s2 = [Math]::Min($Neutral.s, 0.15)
    $o = [ordered]@{}
    if ($Dark) {
        $o['--kit-bg'] = ConvertFrom-Hsl $Neutral.h $s 0.04
        $o['--kit-surface'] = ConvertFrom-Hsl $Neutral.h $s 0.11
        $o['--kit-surface-2'] = ConvertFrom-Hsl $Neutral.h $s 0.16
        $o['--kit-border'] = ConvertFrom-Hsl $Neutral.h $s 0.25
        $start = 0.62; $delta = 0.02
    } else {
        $o['--kit-bg'] = ConvertFrom-Hsl $Neutral.h $s 0.965
        $o['--kit-surface-2'] = ConvertFrom-Hsl $Neutral.h $s 0.93
        $o['--kit-border'] = ConvertFrom-Hsl $Neutral.h $s 0.85
        $start = 0.40; $delta = -0.02
    }
    $surf = if ($Dark) { $o['--kit-surface'] } else { $Surface }
    $bg = $o['--kit-bg']; $s2c = $o['--kit-surface-2']
    $edge = Step-Lightness @{ h = $Neutral.h; s = $s2; l = $start } $delta { param($x) Test-Ratios $x @($surf, $bg) 3.0 }
    $muted = Step-Lightness @{ h = $Neutral.h; s = $s2; l = $start } $delta { param($x) Test-Ratios $x @($surf, $bg, $s2c) 4.5 }
    if (-not $edge -or -not $muted) { return "no shade of the neutral tint gives readable field edges and muted text$(if ($Dark) { ' in dark mode' })" }
    $o['--kit-border-strong'] = $edge.hex
    $o['--kit-text-muted'] = $muted.hex
    $o
}

function Get-ChartTokens($Base, [string]$Surface, [bool]$Dark) {
    <# Six chart colours from a base hue (turned by $script:ChartTurns), each stepped until it reads
       3:1 on panels. An ordered map, or a string with the reason. #>
    $o = [ordered]@{}
    $s = [Math]::Max(0.55, [Math]::Min([double]$Base.s, 0.8))
    for ($i = 0; $i -lt 6; $i++) {
        $start = if ($i -eq 0) { @{ h = $Base.h; s = [Math]::Max([double]$Base.s, 0.3); l = $(if ($Dark) { [Math]::Max([double]$Base.l, 0.6) } else { [Math]::Min([double]$Base.l, 0.5) }) } } else { @{ h = $Base.h + $script:ChartTurns[$i]; s = $s; l = $(if ($Dark) { 0.6 } else { 0.5 }) } }
        $c = Step-Lightness $start $(if ($Dark) { 0.02 } else { -0.02 }) { param($x) Test-Ratios $x @($Surface) 3.0 }
        if (-not $c) { return "chart colour $($i + 1) cannot read 3:1 on panels ($Surface)" }
        $o["--kit-chart-$($i + 1)"] = $c.hex
    }
    $o
}

function ConvertTo-ThemeTokens {
    <# The kit's colour tokens from the person's colours, against the project's tokens.css ($Css: its
       page and panel colours, and whether it has dark blocks). Returns
       @{ ok; error; light (ordered name -> value); dark (empty when the file is light only);
          adjusted (what was darkened or lightened to read); notes (failures the file had already,
          with tokens this theme does not set); colours = @{ accent; accent2; neutral } }. #>
    param([string]$Accent, [string]$Accent2 = '', [string]$Neutral = '', [AllowEmptyString()][string]$Css = '')
    $res = @{ ok = $false; error = ''; light = [ordered]@{}; dark = [ordered]@{}; adjusted = @(); notes = @(); colours = @{ accent = "$Accent".Trim(); accent2 = "$Accent2".Trim(); neutral = "$Neutral".Trim() } }
    $a = ConvertTo-Hsl "$Accent".Trim()
    if (-not $a) { $res.error = "The accent colour is missing or not a colour ('$Accent'): give it as #rrggbb."; return $res }
    $a2 = $null
    if ("$Accent2".Trim()) { $a2 = ConvertTo-Hsl "$Accent2".Trim(); if (-not $a2) { $res.error = "The second colour is not a colour ('$Accent2'): give it as #rrggbb, or leave it empty."; return $res } }
    $n = $null
    if ("$Neutral".Trim()) { $n = ConvertTo-Hsl "$Neutral".Trim(); if (-not $n) { $res.error = "The neutral tint is not a colour ('$Neutral'): give it as #rrggbb, or leave it empty."; return $res } }
    $blocks = Get-TokenBlocks $Css
    $adjusted = New-Object System.Collections.Generic.List[string]
    $given = (ConvertFrom-Hsl $a.h $a.s $a.l)

    # Light.
    $L = [ordered]@{}
    $surface = Get-ThemeColor $blocks.light '--kit-surface' '#ffffff'
    if ($n) {
        $nt = Get-NeutralTokens $n $surface $false
        if ($nt -is [string]) { $res.error = "The colours cannot be made readable: $nt."; return $res }
        foreach ($k in $nt.Keys) { $L[$k] = $nt[$k] }
    }
    $bg = if ($L.Contains('--kit-bg')) { $L['--kit-bg'] } else { Get-ThemeColor $blocks.light '--kit-bg' '#ffffff' }
    $soft = ConvertFrom-Hsl $a.h $a.s 0.95
    $acc = Step-Lightness $a -0.02 { param($x) (Test-Ratios $x @($bg, $surface, $soft) 4.5) -and (Test-Ratios '#ffffff' @($x) 4.5) }
    if (-not $acc) { $res.error = "The colours cannot be made readable: no shade of the accent reads 4.5:1 on the page ($bg) and under white button text."; return $res }
    if ($acc.steps) { $adjusted.Add("accent darkened from $given to $($acc.hex), so links and white button text read 4.5:1") }
    $ah = ConvertTo-Hsl $acc.hex
    $L['--kit-accent'] = $acc.hex
    $L['--kit-accent-hover'] = ConvertFrom-Hsl $ah.h $ah.s ([Math]::Max(0.0, $ah.l - 0.06))
    $L['--kit-accent-soft'] = $soft
    $L['--kit-on-accent'] = '#ffffff'
    # A grey accent (no hue) keeps a grey second colour; the charts then turn from blue (210 degrees).
    $second = if ($a2) { $a2 } elseif ($a.s -lt 0.08) { @{ h = $a.h; s = $a.s; l = 0.45 } } else { @{ h = $a.h; s = [Math]::Max($a.s, 0.6); l = 0.5 } }
    $chartBase = if ($second.s -lt 0.08) { @{ h = 210.0; s = 0.6; l = 0.5 } } else { $second }
    $L['--kit-accent-2'] = ConvertFrom-Hsl $second.h $second.s $second.l
    $from = Step-Lightness $second -0.02 { param($x) Test-Ratios '#ffffff' @($x) 4.5 }
    if (-not $from) { $res.error = 'The colours cannot be made readable: no shade of the second colour carries white text on the band header.'; return $res }
    if ($from.steps) { $adjusted.Add("band gradient's light end darkened from $($L['--kit-accent-2']) to $($from.hex), so white text reads 4.5:1 on it") }
    $L['--kit-gradient-from'] = $from.hex
    $L['--kit-gradient-to'] = $acc.hex
    $L['--kit-on-gradient'] = '#ffffff'
    $L['--kit-title'] = $acc.hex
    $L['--kit-icon'] = $acc.hex
    $charts = Get-ChartTokens $chartBase $surface $false
    if ($charts -is [string]) { $res.error = "The colours cannot be made readable: $charts."; return $res }
    foreach ($k in $charts.Keys) { $L[$k] = $charts[$k] }

    # Dark, only when the file has dark blocks (a light-only project stays light only).
    $D = [ordered]@{}
    if ($blocks.dark.Count) {
        $dsurface = Get-ThemeColor $blocks.dark '--kit-surface' '#1b1b1c'
        if ($n) {
            $nt = Get-NeutralTokens $n $dsurface $true
            if ($nt -is [string]) { $res.error = "The colours cannot be made readable: $nt."; return $res }
            foreach ($k in $nt.Keys) { $D[$k] = $nt[$k] }
            $dsurface = $D['--kit-surface']
        }
        $dbg = if ($D.Contains('--kit-bg')) { $D['--kit-bg'] } else { Get-ThemeColor $blocks.dark '--kit-bg' '#000000' }
        $dsoft = ConvertFrom-Hsl $a.h ([Math]::Min($a.s, 0.6)) 0.16
        $dacc = Step-Lightness @{ h = $a.h; s = $a.s; l = [Math]::Max($a.l, 0.55) } 0.02 { param($x) (Test-Ratios $x @($dbg, $dsurface, $dsoft) 4.5) -and (Test-Ratios '#000000' @($x) 4.5) }
        if (-not $dacc) { $res.error = "The colours cannot be made readable in dark mode: no shade of the accent reads 4.5:1 on the dark page ($dbg)."; return $res }
        if ($dacc.steps) { $adjusted.Add("dark mode: accent lightened to $($dacc.hex), so it reads 4.5:1 on the dark page and under black button text") }
        $dh = ConvertTo-Hsl $dacc.hex
        $D['--kit-accent'] = $dacc.hex
        $D['--kit-accent-hover'] = ConvertFrom-Hsl $dh.h $dh.s ([Math]::Min(1.0, $dh.l + 0.08))
        $D['--kit-accent-soft'] = $dsoft
        $D['--kit-on-accent'] = '#000000'
        $dcharts = Get-ChartTokens $chartBase $dsurface $true
        if ($dcharts -is [string]) { $res.error = "The colours cannot be made readable in dark mode: $dcharts."; return $res }
        foreach ($k in $dcharts.Keys) { $D[$k] = $dcharts[$k] }
    }
    $res.light = $L; $res.dark = $D; $res.adjusted = $adjusted.ToArray()

    # The whole file as it would be written, through the kit's own contrast check.
    $check = Test-ThemeTokens (Set-ThemeText $Css $res) $res
    if ($check.ours.Count) { $res.error = "The colours cannot be made readable: $($check.ours -join '; ')."; return $res }
    $res.notes = $check.others
    $res.ok = $true
    $res
}

function Test-ThemeTokens([AllowEmptyString()][string]$Css, $Theme) {
    <# Contrast Test-TokenContrast on a tokens file, split into the failures that involve a token the
       theme sets (ours: the theme cannot be used) and the rest (others: the file had them already).
       Returns @{ ok; ours; others }. #>
    $names = @(@($Theme.light.Keys) + @($Theme.dark.Keys) | Select-Object -Unique)
    $ours = New-Object System.Collections.Generic.List[string]; $others = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Test-TokenContrast $Css)) {
        if (-not $line) { continue }
        $mine = $false
        foreach ($k in $names) { if ($line.Contains("$k ")) { $mine = $true; break } }
        if ($mine) { $ours.Add($line) } else { $others.Add($line) }
    }
    @{ ok = ($ours.Count -eq 0); ours = $ours.ToArray(); others = $others.ToArray() }
}

function Set-ThemeText([AllowEmptyString()][string]$Css, $Theme) {
    <# The tokens file with the theme's values: in the light block the light values, in both dark blocks
       the dark ones; only the values change (names, spacing, comments and line breaks stay); a token a
       block lacks is added at its end. A block the file does not have is not added. #>
    $text = "$Css"
    foreach ($name in 'darkAttr', 'darkMedia', 'light') {   # from the end, so earlier indexes stay right
        $span = @(Get-TokenBlockSpans $text | Where-Object { $_.name -eq $name })
        if (-not $span.Count) { continue }
        $map = if ($name -eq 'light') { $Theme.light } else { $Theme.dark }
        if (-not $map -or -not $map.Count) { continue }
        $body = $text.Substring($span[0].open + 1, $span[0].close - $span[0].open - 1)
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($k in $map.Keys) {
            $re = '(?<=^|[\s;{])(' + [regex]::Escape($k) + ')(\s*:\s*)([^;]+);'
            $m = [regex]::Match($body, $re)
            if ($m.Success) { $body = $body.Substring(0, $m.Groups[3].Index) + $map[$k] + $body.Substring($m.Groups[3].Index + $m.Groups[3].Length) }
            else { $missing.Add($k) }
        }
        if ($missing.Count) {
            $indent = if ($name -eq 'darkMedia') { '    ' } else { '  ' }
            $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
            $body = $body.TrimEnd() + $eol + (@($missing | ForEach-Object { "$indent${_}: $($map[$_]);" }) -join $eol) + $eol
            if ($name -eq 'darkMedia') { $body += '  ' }
        }
        $text = $text.Substring(0, $span[0].open + 1) + $body + $text.Substring($span[0].close)
    }
    $text
}

function Set-ProjectThemeTokens {
    <# Writes the theme into the project's styles/kit/tokens.css: only those values change, the rest of
       the file stays byte for byte (its BOM and line breaks too). The earlier version goes into
       $Checkpoint (a new one, 'Theme from your colours', when none is given), so Undo brings it back.
       The colours given are kept in .streamhub/kit-theme.json (the card shows them next time).
       The token base (.streamhub/kit-tokens-base.css) is left alone on purpose: a later catalogue
       update (UiKit Update-KitTokens) only replaces a value that still equals the base's default, and
       the theme's values differ from it, so they stay the project's own.
       Returns @{ changed (bool); path; old; new; names (tokens whose value changed); checkpoint }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Theme, $Checkpoint = $null)
    if (-not $Theme.ok) { throw "The theme was not made: $($Theme.error)" }
    $rel = "$(Get-UiKitFolder)/tokens.css"
    $full = Resolve-ProjectPath $ProjectRoot $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "This project has no $rel yet: the UI kit comes in with the first page Copilot builds with it." }
    $bytes = [IO.File]::ReadAllBytes($full)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $skip = if ($bom) { 3 } else { 0 }
    $old = (New-Object Text.UTF8Encoding($false)).GetString($bytes, $skip, $bytes.Length - $skip)
    $new = Set-ThemeText $old $Theme
    $check = Test-ThemeTokens $new $Theme
    if (-not $check.ok) { throw "Not written: $($check.ours -join '; ')" }
    $out = @{ changed = $false; path = $rel; old = $old; new = $new; names = @(); checkpoint = $Checkpoint }
    if ($new -ceq $old) { return $out }
    $before = Get-TokenBlocks $old; $after = Get-TokenBlocks $new
    $out.names = @(foreach ($mode in 'light', 'dark') { foreach ($k in $after[$mode].Keys) { if ("$($before[$mode][$k])" -ne "$($after[$mode][$k])") { $k } } }) | Select-Object -Unique
    if (-not $out.checkpoint) { $out.checkpoint = New-Checkpoint $ProjectRoot 'Theme from your colours' }
    Save-CheckpointFile $out.checkpoint $ProjectRoot $full
    $enc = New-Object Text.UTF8Encoding($false)
    $body = $enc.GetBytes($new)
    if ($bom) { $body = [byte[]](@(0xEF, 0xBB, 0xBF) + $body) }
    [IO.File]::WriteAllBytes($full, $body)
    $out.changed = $true
    try {
        $tf = Join-Path $ProjectRoot $script:ThemeFile
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $tf)
        $saved = @{ accent = $Theme.colours.accent; accent2 = $Theme.colours.accent2; neutral = $Theme.colours.neutral; applied = (Get-Date).ToString('s') }
        [IO.File]::WriteAllText($tf, (ConvertTo-Json -InputObject $saved), $enc)
    } catch { }
    $out
}

function Get-ProjectThemeInputs([string]$ProjectRoot) {
    <# The colours the card starts with: the ones applied last (.streamhub/kit-theme.json), else the
       project's light accent and second colour. @{ accent; accent2; neutral; hasKit; dark }. #>
    $o = @{ accent = ''; accent2 = ''; neutral = ''; hasKit = $false; dark = $false }
    $tokens = Join-Path $ProjectRoot "$((Get-UiKitFolder).Replace('/', '\'))\tokens.css"
    if (Test-Path -LiteralPath $tokens -PathType Leaf) {
        $b = Get-TokenBlocks ([IO.File]::ReadAllText($tokens))
        $o.hasKit = $true; $o.dark = [bool]$b.dark.Count
        $o.accent = Get-ThemeColor $b.light '--kit-accent' ''
        $o.accent2 = Get-ThemeColor $b.light '--kit-accent-2' ''
    }
    $tf = Join-Path $ProjectRoot $script:ThemeFile
    if (Test-Path -LiteralPath $tf) {
        try { $j = [IO.File]::ReadAllText($tf) | ConvertFrom-Json; foreach ($k in 'accent', 'accent2', 'neutral') { if ($j.$k) { $o[$k] = "$($j.$k)" } } } catch { }
    }
    $o
}

function Get-ThemePreview {
    <# What the theme card shows before anything is written (Server /api/kit-theme/preview): the tokens
       derived for this project's tokens.css, what was adjusted, and the summary line. Nothing is
       written. @{ ok; error; light; dark; adjusted; notes; summary }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Accent, [string]$Accent2 = '', [string]$Neutral = '')
    $tokens = Join-Path $ProjectRoot "$((Get-UiKitFolder).Replace('/', '\'))\tokens.css"
    if (-not (Test-Path -LiteralPath $tokens -PathType Leaf)) { return @{ ok = $false; error = 'This project has no UI kit yet (styles/kit/tokens.css).'; light = @{}; dark = @{}; adjusted = @(); notes = @(); summary = '' } }
    $t = ConvertTo-ThemeTokens -Accent $Accent -Accent2 $Accent2 -Neutral $Neutral -Css ([IO.File]::ReadAllText($tokens))
    $plain = { param($m) $h = @{}; foreach ($k in $m.Keys) { $h[$k] = $m[$k] }; $h }
    @{ ok = [bool]$t.ok; error = "$($t.error)"; light = (& $plain $t.light); dark = (& $plain $t.dark); adjusted = @($t.adjusted); notes = @($t.notes); summary = $(if ($t.ok) { Format-ThemeSummary $t } else { '' }) }
}

function Format-ThemeSummary($Theme) {
    <# One line for the change card: what the colours became, what was adjusted to read, and what
       follows by itself. #>
    $L = $Theme.light
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("StreamHub set the UI kit's colours from yours: accent $($L['--kit-accent']) (hover $($L['--kit-accent-hover'])), second colour $($L['--kit-accent-2']), band $($L['--kit-gradient-from']) to $($L['--kit-gradient-to']), charts $((1..6 | ForEach-Object { $L["--kit-chart-$_"] }) -join ' ')")
    if ($L.Contains('--kit-bg')) { $parts.Add("neutrals tinted (page $($L['--kit-bg']), field edges $($L['--kit-border-strong']))") }
    if ($Theme.dark.Count) { $parts.Add("dark mode accent $($Theme.dark['--kit-accent'])") } else { $parts.Add('light only (the project has no dark mode)') }
    $s = ($parts -join '; ') + '.'
    if (@($Theme.adjusted).Count) { $s += ' Adjusted to read: ' + (@($Theme.adjusted) -join '; ') + '.' }
    $s += ' The accent tints, focus ring and scrollbar follow the accent; sizes and fonts are unchanged.'
    if (@($Theme.notes).Count) { $s += ' Already below the contrast minimum before (not changed by this theme): ' + (@($Theme.notes) -join '; ') + '.' }
    $s
}

Export-ModuleMember -Function ConvertTo-Hsl, ConvertFrom-Hsl, ConvertTo-ThemeTokens, Test-ThemeTokens, Set-ThemeText, Set-ProjectThemeTokens, Get-ProjectThemeInputs, Get-ThemePreview, Format-ThemeSummary
