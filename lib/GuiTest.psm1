# The start test of a PowerShell window app (WPF or Windows Forms) after a task that changed it: the
# script runs with STREAMHUB_GUI_TEST set (the app then shows its window without doing work), StreamHub
# waits for the window, takes a picture of it (PrintWindow, also when it is behind other windows) and
# closes it. Errors at start and a window that never opens go back to Copilot. A script that works with
# Microsoft 365 or deletes files is not started (Executor Get-CommandRisk on its text).

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Executor', 'Config') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:WinApi = $null
function Initialize-WinApi {
    if ($script:WinApi) { return }
    if (-not ('CcbWindowShot' -as [type])) {
        Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class CcbWindowShot {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    public static string Title(IntPtr h) { var s = new System.Text.StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
    public static bool Save(IntPtr h, string path) {
        RECT r; if (!GetWindowRect(h, out r)) return false;
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w < 10 || ht < 10) return false;
        // The visible frame, without the invisible border Windows draws the shadow in.
        RECT f; if (DwmGetWindowAttribute(h, 9, out f, Marshal.SizeOf(typeof(RECT))) != 0) f = r;
        var crop = new Rectangle(Math.Max(0, f.Left - r.Left), Math.Max(0, f.Top - r.Top), Math.Min(w, f.Right - f.Left), Math.Min(ht, f.Bottom - f.Top));
        using (var bmp = new Bitmap(w, ht)) {
            using (var g = Graphics.FromImage(bmp)) { IntPtr dc = g.GetHdc(); try { PrintWindow(h, dc, 2); } finally { g.ReleaseHdc(dc); } }
            if (crop.Width < 10 || crop.Height < 10 || crop.Right > w || crop.Bottom > ht) crop = new Rectangle(0, 0, w, ht);
            using (var part = bmp.Clone(crop, bmp.PixelFormat)) part.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        return true;
    }
}
'@
    }
    $script:WinApi = $true
}

function Find-GuiScripts {
    <# The window app scripts a task changed (or whose .xaml it changed): PowerShell scripts that open a
       window (ShowDialog, Application Run, XamlReader). At most two. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Changed)
    $root = $ProjectRoot.TrimEnd('\')
    $paths = @($Changed | ForEach-Object { "$_".Replace('\', '/') })
    $out = New-Object System.Collections.Generic.List[string]
    # A window app: it opens a window itself (WPF or Windows Forms), or through the kit's helpers.
    $isGui = { param($t) ($t -match '(?i)\.ShowDialog\(|\]::Run\(|XamlReader' -and $t -match '(?i)PresentationFramework|System\.Windows\.Forms') -or $t -match '(?i)\bShow-KitWindow\b' }
    foreach ($p in $paths) {
        # Never the helper program's own files (the kit's helpers in styles/kit/, its scripts).
        if ($p -notmatch '(?i)\.ps1$' -or $p -match '(?i)\.Tests\.ps1$|^Scripts/(Build-App|Refresh-Data)\.ps1$|^styles/kit/|^\.streamhub/') { continue }
        $full = Join-Path $root $p.Replace('/', '\')
        if ((Test-Path -LiteralPath $full) -and (& $isGui ([IO.File]::ReadAllText($full))) -and -not $out.Contains($p)) { $out.Add($p) }
    }
    $xaml = @($paths | Where-Object { $_ -match '(?i)\.xaml$' -and $_ -notmatch '(?i)^styles/kit/' } | ForEach-Object { Split-Path $_ -Leaf })
    if ($xaml.Count) {
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.streamhub|Source)\\|\\styles\\kit\\' } | Select-Object -First 200)) {
            $t = try { [IO.File]::ReadAllText($f.FullName) } catch { '' }
            $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
            if ((& $isGui $t) -and @($xaml | Where-Object { $t.Contains($_) }).Count -and -not $out.Contains($rel)) { $out.Add($rel) }
        }
    }
    @($out | Select-Object -First 2)
}

function Get-ProcessTreeIds([int]$RootId) {
    # The process and its children (an app that starts itself again, for example with -STA).
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId)
    $ids = New-Object System.Collections.Generic.List[int]; $ids.Add($RootId)
    for ($i = 0; $i -lt $ids.Count; $i++) { foreach ($c in $all) { if ([int]$c.ParentProcessId -eq $ids[$i] -and -not $ids.Contains([int]$c.ProcessId)) { $ids.Add([int]$c.ProcessId) } } }
    $ids.ToArray()
}

function Test-GuiLauncher {
    <# The app's launcher: a .cmd in the project that starts the script with -STA and without a console.
       '' when it is right, else what is missing. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Script)
    $name = Split-Path $Script -Leaf
    $cmds = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Include *.cmd, *.bat -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.streamhub|Source)\\' } |
        Where-Object { $(try { [IO.File]::ReadAllText($_.FullName) } catch { '' }) -match [regex]::Escape($name) })
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    if (-not $cmds.Count) { return "no launcher: add $base.cmd next to $name with powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"%~dp0$name`", so a double click opens the window without a console" }
    $t = [IO.File]::ReadAllText($cmds[0].FullName)
    $missing = @(if ($t -notmatch '(?i)-STA\b') { '-STA' }; if ($t -notmatch '(?i)-WindowStyle\s+Hidden|-w\s+hidden') { '-WindowStyle Hidden' })
    if ($missing.Count) { return "the launcher $($cmds[0].Name) starts $name without $($missing -join ' and '): add it, so the window works and no console shows" }
    ''
}

function Read-GuiTestSteps {
    <# The steps of NAME.guitest next to the script: click NAME, type NAME = TEXT, select NAME = ITEM,
       expect NAME = TEXT (or expect TEXT), wait MS. Lines starting with # are notes. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $steps = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $n++
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $m = [regex]::Match($l, '^(?i)(click|type|select|expect|wait)\s+(.*)$')
        if (-not $m.Success) { $steps.Add([pscustomobject]@{ line = $n; kind = 'bad'; target = $l; value = '' }); continue }
        $kind = $m.Groups[1].Value.ToLowerInvariant(); $rest = $m.Groups[2].Value.Trim()
        $target = $rest; $value = ''
        $eq = $rest.IndexOf('=')
        if ($kind -in 'type', 'select', 'expect' -and $eq -gt 0) { $target = $rest.Substring(0, $eq).Trim(); $value = $rest.Substring($eq + 1).Trim() }
        elseif ($kind -eq 'expect') { $target = ''; $value = $rest }
        $steps.Add([pscustomobject]@{ line = $n; kind = $kind; target = $target; value = $value })
    }
    $steps.ToArray()
}

$script:UiaLoaded = $false
function Initialize-Uia {
    if ($script:UiaLoaded) { return }
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $script:UiaLoaded = $true
}

function Find-UiaElement($Window, [string]$Name) {
    # An element by its x:Name (AutomationId) or its visible text (Name).
    $A = [System.Windows.Automation.AutomationElement]
    $cond = New-Object System.Windows.Automation.OrCondition(
        (New-Object System.Windows.Automation.PropertyCondition($A::AutomationIdProperty, $Name)),
        (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $Name)))
    $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Get-UiaText($El) {
    # What an element shows: its value (fields), else its name (text, buttons).
    $vp = $null
    if ($El.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { return "$($vp.Current.Value)" }
    "$($El.Current.Name)"
}

function Invoke-GuiStep($Window, $Step) {
    # One step; '' when it worked, else what went wrong.
    switch ($Step.kind) {
        'bad' { return "line $($Step.line): '$($Step.target)' is not a step (click, type, select, expect, wait)" }
        'wait' { Start-Sleep -Milliseconds ([int]("0" + ($Step.target -replace '\D', ''))); return '' }
        'expect' {
            $want = $Step.value
            if ($Step.target) {
                $el = Find-UiaElement $Window $Step.target
                if (-not $el) { return "line $($Step.line): there is no element '$($Step.target)'" }
                $have = Get-UiaText $el
                if ($have -notlike "*$want*") {
                    # A table, list or panel has no text of its own: what is inside it counts.
                    foreach ($d in $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { if ((Get-UiaText $d) -like "*$want*") { return '' } }
                    return "line $($Step.line): '$($Step.target)' does not show '$want'$(if ($have) { " (it shows '$have')" })"
                }
                return ''
            }
            $all = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($e in $all) { if ((Get-UiaText $e) -like "*$want*") { return '' } }
            return "line $($Step.line): the window does not show '$want'"
        }
    }
    $el = Find-UiaElement $Window $Step.target
    if (-not $el) { return "line $($Step.line): there is no element '$($Step.target)'" }
    if (-not $el.Current.IsEnabled) { return "line $($Step.line): '$($Step.target)' cannot be used (it is disabled)" }
    $p = $null
    switch ($Step.kind) {
        'click' {
            if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return '' }
            if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle(); return '' }
            if ($el.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); return '' }
            return "line $($Step.line): '$($Step.target)' cannot be clicked"
        }
        'type' {
            if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { $p.SetValue($Step.value); return '' }
            return "line $($Step.line): '$($Step.target)' does not take text"
        }
        'select' {
            if ($el.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { try { $p.Expand() } catch { } ; Start-Sleep -Milliseconds 200 }
            $item = Find-UiaElement $el $Step.value
            if (-not $item) { return "line $($Step.line): '$($Step.target)' has no item '$($Step.value)'" }
            $sp = $null
            if ($item.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) { $sp.Select(); return '' }
            return "line $($Step.line): '$($Step.value)' cannot be selected"
        }
    }
    ''
}

function Get-GuiAccessIssues {
    <# What the window's controls miss (UI Automation): a name for screen readers, a click target of at
       least 24 x 24, a place inside the window at its starting size. At most 8 lines. #>
    param($Window)
    $out = New-Object System.Collections.Generic.List[string]
    $win = $Window.Current.BoundingRectangle
    $CT = [System.Windows.Automation.ControlType]
    $kinds = @($CT::Button, $CT::Edit, $CT::ComboBox, $CT::CheckBox, $CT::RadioButton, $CT::Slider, $CT::TabItem)
    $all = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        $c = $e.Current
        if ($kinds -notcontains $c.ControlType -or $c.IsOffscreen) { continue }
        # The parts WPF draws inside its own controls (scroll bar arrows, a combo box's drop button).
        if ($c.AutomationId -like 'PART_*') { continue }
        $what = "$($c.ControlType.ProgrammaticName -replace '^ControlType\.', '')" + $(if ($c.AutomationId) { " $($c.AutomationId)" } elseif ($c.Name) { " '$($c.Name)'" } else { '' })
        if (-not $c.Name -and $c.ControlType -in $CT::Button, $CT::Edit, $CT::ComboBox, $CT::Slider) { $out.Add("$what has no name for screen readers: give it visible text, AutomationProperties.Name or a Label with Target") }
        $r = $c.BoundingRectangle
        if ($r.Width -gt 0 -and $c.ControlType -ne $CT::Edit -and ($r.Width -lt 24 -or $r.Height -lt 24)) { $out.Add("$what is $([int]$r.Width) x $([int]$r.Height); a click target needs at least 24 x 24") }
        if ($r.Width -gt 0 -and ($r.Right -gt $win.Right + 2 -or $r.Bottom -gt $win.Bottom + 2)) { $out.Add("$what is cut off at the window's starting size: make the window larger (Width, Height) or let the content wrap or scroll") }
        if ($out.Count -ge 8) { break }
    }
    @($out | Select-Object -Unique)
}

function Get-GuiLayoutIssues {
    <# How the open window's controls line up, measured (UI Automation): controls on one line that are not
       centred with each other, have different heights or touch or overlap, and controls above each other
       whose left edges are a few pixels apart (meant to line up, but do not). Controls inside tables,
       lists, menus and toolbars are left out. At most 6 lines. #>
    param([Parameter(Mandatory)]$Window)
    $CT = [System.Windows.Automation.ControlType]
    $kinds = @($CT::Button, $CT::Edit, $CT::ComboBox, $CT::CheckBox, $CT::RadioButton)
    $boxes = @($CT::Button, $CT::Edit, $CT::ComboBox)
    $all = @($Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
    $holders = @($all | Where-Object { $_.Current.ControlType -in $CT::DataGrid, $CT::Table, $CT::List, $CT::Tree, $CT::Menu, $CT::MenuBar, $CT::ToolBar, $CT::StatusBar } | ForEach-Object { $_.Current.BoundingRectangle })
    $items = foreach ($e in $all) {
        $c = $e.Current
        if ($kinds -notcontains $c.ControlType -or $c.IsOffscreen -or $c.AutomationId -like 'PART_*') { continue }
        $r = $c.BoundingRectangle
        if ($r.Width -le 0 -or $r.Height -le 0) { continue }
        if (@($holders | Where-Object { $_.Contains($r) }).Count) { continue }
        $name = "$($c.ControlType.ProgrammaticName -replace '^ControlType\.', '')" + $(if ($c.AutomationId) { " $($c.AutomationId)" } elseif ($c.Name) { " '$($c.Name)'" } else { '' })
        [pscustomobject]@{ name = $name; box = ($boxes -contains $c.ControlType); field = ($c.ControlType -in $CT::Edit, $CT::ComboBox); w = $r.Width; l = $r.Left; t = $r.Top; r = $r.Right; b = $r.Bottom; h = $r.Height; mid = $r.Top + $r.Height / 2 }
    }
    $items = @($items | Sort-Object l)
    $out = New-Object System.Collections.Generic.List[string]
    $offLine = @{}
    for ($i = 0; $i -lt $items.Count; $i++) {
        for ($j = $i + 1; $j -lt $items.Count; $j++) {
            if ($out.Count -ge 6) { break }
            $a = $items[$i]; $b = $items[$j]
            $overlapY = [Math]::Min($a.b, $b.b) - [Math]::Max($a.t, $b.t)
            if ($overlapY -gt [Math]::Min($a.h, $b.h) / 2) {
                # One line: the nearest neighbour on the right only.
                $between = @($items | Where-Object { $_.l -ge $a.r - 2 -and $_.r -le $b.l + 2 -and $_ -ne $a -and $_ -ne $b -and ([Math]::Min($_.b, $a.b) - [Math]::Max($_.t, $a.t)) -gt 0 })
                if ($between.Count) { continue }
                $gap = $b.l - $a.r
                if ($gap -lt 0 -and $b.l -lt $a.r - 2) { $out.Add("$($b.name) overlaps $($a.name): give each its own place in the row (StackPanel Tag=`"row`" spaces them)") }
                elseif ($gap -lt 4) { $out.Add("$($a.name) touches $($b.name) with no gap between them: put them in a StackPanel Tag=`"row`" (8 apart) or give a Margin") }
                if ($a.box -and $b.box -and [Math]::Abs($a.h - $b.h) -gt 4) { $out.Add("$($a.name) is $([int]$a.h) px high and $($b.name) beside it $([int]$b.h) px: leave out the Height so both take the theme's height") }
                elseif ([Math]::Abs($a.mid - $b.mid) -gt 3) { $out.Add("$($b.name) is not centred in its row with $($a.name) ($([int][Math]::Abs($a.mid - $b.mid)) px off): VerticalAlignment=`"Center`", or a StackPanel Tag=`"row`"") }
            } else {
                $dl = [Math]::Abs($a.l - $b.l)
                $vgap = [Math]::Max($a.t, $b.t) - [Math]::Min($a.b, $b.b)
                if ($dl -ge 1 -and $dl -le 5 -and $vgap -lt 60 -and -not ($offLine[$a.name] -or $offLine[$b.name])) {
                    # Once per control: one control out of line with several others is one finding.
                    $offLine[$a.name] = $true; $offLine[$b.name] = $true
                    $out.Add("$($b.name) is out of line with $($a.name) $(if ($b.t -gt $a.t) { 'above' } else { 'below' }) it: their left edges are $([int][Math]::Round($dl)) px apart (same Margin, or the same Grid column)") }
                # Fields above each other in one column: one width (a clearly different width is a choice).
                $dw = [Math]::Abs($a.w - $b.w)
                if ($a.field -and $b.field -and $dl -le 5 -and $vgap -lt 60 -and $dw -ge 2 -and $dw -le [Math]::Max($a.w, $b.w) / 3) { $out.Add("$($a.name) and $($b.name) are above each other but $([int]$a.w) and $([int]$b.w) px wide: give fields in one column the same width (120, 240 or 360, or let them fill a Grid Tag=`"form`" column)") }
            }
        }
    }
    @($out | Select-Object -Unique -First 6)
}

function Expand-XamlLayout {
    <# Writes the layout of panels marked with a Tag into the XAML itself, so the window lines up however
       it is loaded (the same values as KitWpf Set-KitLayout): StackPanel Tag="row" (horizontal, left,
       controls 8 apart and centred), Tag="actions" (the same at the right), Grid Tag="form" without
       definitions (an Auto and a star column, a row per label and field). -Heights also gives buttons,
       single-line fields, drop-downs and date pickers one height (32), for a window without the kit's
       theme. Only attributes that are missing are added and the rest of the text stays as it is, so a
       second run changes nothing. Returns @{ text; changes (what was added, per panel) }. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Xaml, [switch]$Heights)
    $none = @{ text = $Xaml; changes = @() }
    if ($Xaml -notmatch '\bTag\s*=\s*"(row|actions|form)"' -and -not $Heights) { return $none }
    Add-Type -AssemblyName System.Xml.Linq
    try { $doc = [System.Xml.Linq.XDocument]::Parse($Xaml, [System.Xml.Linq.LoadOptions]::SetLineInfo) } catch { return $none }
    $lineStarts = New-Object System.Collections.Generic.List[int]
    $lineStarts.Add(0)
    for ($i = 0; $i -lt $Xaml.Length; $i++) { if ($Xaml[$i] -eq "`n") { $lineStarts.Add($i + 1) } }
    $inserts = @{}   # position -> text to insert there
    $add = { param([int]$pos, [string]$text) if ($inserts.ContainsKey($pos)) { $inserts[$pos] += $text } else { $inserts[$pos] = $text } }
    # Where an element's start tag ends: before "/>" or ">" (quotes respected).
    $tagEnd = {
        param($el)
        $li = [System.Xml.IXmlLineInfo]$el
        $i = $lineStarts[$li.LineNumber - 1] + $li.LinePosition - 1
        $q = [char]0
        for (; $i -lt $Xaml.Length; $i++) {
            $c = $Xaml[$i]
            if ($q -ne [char]0) { if ($c -eq $q) { $q = [char]0 }; continue }
            if ($c -eq '"' -or $c -eq "'") { $q = $c; continue }
            if ($c -eq '>') { return @{ attr = $(if ($Xaml[$i - 1] -eq '/') { $i - 1 } else { $i }); body = $i + 1; closed = ($Xaml[$i - 1] -eq '/') } }
        }
        $null
    }
    $has = { param($el, [string]$name) @($el.Attributes() | Where-Object { $_.Name.LocalName -eq $name }).Count -gt 0 }
    $put = {
        param($el, [string]$name, [string]$value)
        if (& $has $el $name) { return $false }
        $e = & $tagEnd $el
        if (-not $e) { return $false }
        & $add $e.attr " $name=`"$value`""
        $true
    }
    $kids = { param($el) @($el.Elements() | Where-Object { $_.Name.LocalName -notmatch '\.' }) }
    $changes = New-Object System.Collections.Generic.List[string]
    foreach ($el in @($doc.Descendants())) {
        $kind = $el.Name.LocalName
        $tag = @($el.Attributes() | Where-Object { $_.Name.LocalName -eq 'Tag' } | ForEach-Object { $_.Value })
        $line = ([System.Xml.IXmlLineInfo]$el).LineNumber
        if ($kind -eq 'StackPanel' -and $tag -and $tag[0] -in 'row', 'actions') {
            $row = $tag[0] -eq 'row'
            $n = 0
            $n += [int](& $put $el 'Orientation' 'Horizontal')
            $n += [int](& $put $el 'HorizontalAlignment' $(if ($row) { 'Left' } else { 'Right' }))
            $n += [int](& $put $el 'Margin' $(if ($row) { '0,0,0,12' } else { '0,12,0,0' }))
            $ks = & $kids $el
            for ($i = 0; $i -lt $ks.Count; $i++) {
                if ($row -and $i -lt $ks.Count - 1) { $n += [int](& $put $ks[$i] 'Margin' '0,0,8,0') }
                if (-not $row -and $i -gt 0) { $n += [int](& $put $ks[$i] 'Margin' '8,0,0,0') }
                $n += [int](& $put $ks[$i] 'VerticalAlignment' 'Center')
            }
            if ($n) { $changes.Add("line ${line}: the $($tag[0]) panel lined up ($n value(s))") }
        } elseif ($kind -eq 'Grid' -and $tag -and $tag[0] -eq 'form' -and -not @($el.Elements() | Where-Object { $_.Name.LocalName -match '^Grid\.(Row|Column)Definitions$' }).Count) {
            $e = & $tagEnd $el
            $ks = & $kids $el
            if (-not $e -or $e.closed -or -not $ks.Count) { continue }
            # The definitions go first inside the grid, indented like its first child.
            $first = [System.Xml.IXmlLineInfo]$ks[0]
            $ls = $lineStarts[$first.LineNumber - 1]
            $indent = [regex]::Match($Xaml.Substring($ls), '^[ \t]*').Value
            $nl = if ($Xaml.Contains("`r`n")) { "`r`n" } else { "`n" }
            $rows = [int][Math]::Ceiling($ks.Count / 2)
            $defs = $nl + $indent + '<Grid.ColumnDefinitions>' + $nl + $indent + '  <ColumnDefinition Width="Auto"/>' + $nl + $indent + '  <ColumnDefinition Width="*"/>' + $nl + $indent + '</Grid.ColumnDefinitions>' +
                $nl + $indent + '<Grid.RowDefinitions>' + $nl + ((1..$rows | ForEach-Object { $indent + '  <RowDefinition Height="Auto"/>' }) -join $nl) + $nl + $indent + '</Grid.RowDefinitions>'
            & $add $e.body $defs
            # A multi-line field fills its row and its label sits at the top; one line: both centred.
            $multi = { param($f) $f -and $f.Name.LocalName -eq 'TextBox' -and @($f.Attributes() | Where-Object { ($_.Name.LocalName -eq 'AcceptsReturn' -and $_.Value -eq 'True') -or ($_.Name.LocalName -eq 'TextWrapping' -and $_.Value -eq 'Wrap') }).Count }
            for ($i = 0; $i -lt $ks.Count; $i++) {
                $null = & $put $ks[$i] 'Grid.Row' ([string][int][Math]::Floor($i / 2))
                $null = & $put $ks[$i] 'Grid.Column' ([string]($i % 2))
                $null = & $put $ks[$i] 'Margin' $(if ($i % 2 -eq 0) { '0,0,12,8' } else { '0,0,0,8' })
                $field = if ($i % 2 -eq 0) { if ($i + 1 -lt $ks.Count) { $ks[$i + 1] } else { $null } } else { $ks[$i] }
                if (& $multi $field) { if ($i % 2 -eq 0) { $null = & $put $ks[$i] 'VerticalAlignment' 'Top' } }
                else { $null = & $put $ks[$i] 'VerticalAlignment' 'Center' }
            }
            $changes.Add("line ${line}: the form laid out in a label column and a field column ($rows row(s))")
        }
    }
    if ($Heights) {
        $n = 0
        foreach ($el in @($doc.Descendants())) {
            $kind = $el.Name.LocalName
            if ($kind -notin 'Button', 'TextBox', 'PasswordBox', 'ComboBox', 'DatePicker' -or (& $has $el 'Height') -or (& $has $el 'Style')) { continue }
            if ($kind -eq 'TextBox' -and @($el.Attributes() | Where-Object { ($_.Name.LocalName -eq 'AcceptsReturn' -and $_.Value -eq 'True') -or ($_.Name.LocalName -eq 'TextWrapping' -and $_.Value -eq 'Wrap') }).Count) { continue }
            $n += [int](& $put $el 'MinHeight' '32')
            if ($kind -ne 'Button') { $null = & $put $el 'VerticalContentAlignment' 'Center' }
        }
        if ($n) { $changes.Add("one height (32) for $n button(s) and field(s)") }
    }
    if (-not $inserts.Count) { return $none }
    $sb = New-Object System.Text.StringBuilder $Xaml
    foreach ($pos in @($inserts.Keys | Sort-Object -Descending)) { $null = $sb.Insert($pos, $inserts[$pos]) }
    @{ text = $sb.ToString(); changes = $changes.ToArray() }
}

function Get-ProcessWindows([int[]]$Ids) {
    # The top-level windows of these processes (UI Automation elements).
    $A = [System.Windows.Automation.AutomationElement]
    @($A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $Ids -contains $_.Current.ProcessId })
}

function Hide-LocalPaths([string]$Text, [string]$ProjectRoot) {
    <# What the start test reports goes to cards, the chat history and Copilot: paths inside the project
       become relative, and the profile folder, OneDrive, account and computer names are masked (Log
       Protect-LogText), so no report holds who ran it or on which machine. #>
    if (-not $Text) { return $Text }
    if ($ProjectRoot) {
        $r = $ProjectRoot.TrimEnd('\')
        $Text = [regex]::Replace($Text, [regex]::Escape($r) + '\\', '', 'IgnoreCase')
        $Text = [regex]::Replace($Text, [regex]::Escape($r), '.', 'IgnoreCase')
    }
    Protect-LogText $Text
}

function Test-PsGuiApp {
    <# Starts the window app, waits for its window, checks its controls (names, sizes, cut off), runs the
       steps of its NAME.guitest, saves a picture of it ($ShotPath) and closes it. Returns @{ opened; title;
       shot; errors; access; layout (how the controls line up); steps (what went wrong); ranSteps; exitCode; skipped }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Script, [string]$ShotPath = '', [int]$WaitSec = 20, $Steps = $null)
    $full = Join-Path $ProjectRoot $Script.Replace('/', '\')
    $text = [IO.File]::ReadAllText($full)
    $risk = Get-CommandRisk $text
    $none = @{ opened = $false; title = ''; shot = ''; errors = @(); access = @(); layout = @(); steps = @(); ranSteps = 0; exitCode = $null }
    if ($risk.m365 -or $risk.destructive) { return [pscustomobject]($none + @{ skipped = 'the script works with Microsoft 365 or deletes files, so StreamHub does not start it by itself' }) }
    if ((Get-ScriptLanguageMode $ProjectRoot) -eq 'ConstrainedLanguage') { return [pscustomobject]($none + @{ skipped = 'scripts from this folder run in Constrained Language Mode (a company policy), where a window app cannot run' }) }
    if ($null -eq $Steps) { $Steps = @(Read-GuiTestSteps (Join-Path (Split-Path $full) ([IO.Path]::GetFileNameWithoutExtension($full) + '.guitest'))) }
    Initialize-WinApi
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$full`""
    $psi.WorkingDirectory = Split-Path $full
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true
    $psi.EnvironmentVariables['STREAMHUB_GUI_TEST'] = '1'
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync(); $outTask = $p.StandardOutput.ReadToEndAsync()
    $hwnd = [IntPtr]::Zero; $title = ''; $shot = ''; $access = @(); $layout = @(); $ranSteps = 0
    $stepErrors = New-Object System.Collections.Generic.List[string]
    $until = (Get-Date).AddSeconds($WaitSec)
    # The app, or what it started (a script that starts itself again with -STA and ends): the window
    # is waited for while any process of the tree runs, and the whole tree is ended at the end.
    $treeAlive = { @(Get-ProcessTreeIds $p.Id | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -gt 0 }
    try {
        while ((Get-Date) -lt $until -and $hwnd -eq [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 300
            foreach ($id in @(Get-ProcessTreeIds $p.Id)) {
                $q = Get-Process -Id $id -ErrorAction SilentlyContinue
                if ($q -and $q.MainWindowHandle -ne [IntPtr]::Zero) { $hwnd = $q.MainWindowHandle; break }
            }
            if ($hwnd -eq [IntPtr]::Zero -and -not (& $treeAlive)) { break }
        }
        if ($hwnd -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 1200   # let the window draw itself
            $title = [CcbWindowShot]::Title($hwnd)
            Initialize-Uia
            $winEl = try { [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) } catch { $null }
            if ($winEl) { $access = @(try { Get-GuiAccessIssues $winEl } catch { }); $layout = @(try { Get-GuiLayoutIssues $winEl } catch { }) }
            # The steps of NAME.guitest, one by one; a crash or a message box after a step is a problem too.
            foreach ($st in @($Steps)) {
                if (-not $winEl -or -not (& $treeAlive)) { break }
                $ranSteps++
                $bad = try { Invoke-GuiStep $winEl $st } catch { "line $($st.line): $($st.kind) $($st.target) failed: $($_.Exception.Message)" }
                if ($bad) { $stepErrors.Add($bad) }
                Start-Sleep -Milliseconds 500
                if (-not (& $treeAlive)) { $stepErrors.Add("line $($st.line): the app closed after this step$(if ($p.HasExited) { " (exit code $($p.ExitCode))" })"); break }
                # Message boxes only: dialog windows of the app (class #32770) and windows the main window
                # owns (UI Automation lists those inside it). A second window a step opened on purpose
                # (settings, details) stays open for the steps after it.
                $owned = @($winEl.FindAll([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window))))
                $dialogs = @(Get-ProcessWindows (Get-ProcessTreeIds $p.Id) | Where-Object { $_.Current.ClassName -eq '#32770' })
                foreach ($w in @($dialogs + $owned)) {
                    if ($w.Current.NativeWindowHandle -eq [int]$hwnd) { continue }
                    $txt = (@($w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Where-Object { $_ } | Select-Object -Unique) -join ' ').Trim()
                    if ($txt -match '(?i)error|exception|failed|could not|cannot|went wrong|fout|mislukt') { $stepErrors.Add("line $($st.line): after this step a message said: $($txt.Substring(0, [Math]::Min(300, $txt.Length)))") }
                    $wp = $null; if ($w.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp)) { try { $wp.Close() } catch { } }
                }
            }
            if ($ShotPath) { $null = New-Item -ItemType Directory -Force -Path (Split-Path $ShotPath); if ([CcbWindowShot]::Save($hwnd, $ShotPath)) { $shot = $ShotPath } }
        }
    } finally {
        foreach ($id in @(Get-ProcessTreeIds $p.Id | Sort-Object -Descending)) {
            $q = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($q) { try { $null = $q.CloseMainWindow() } catch { } }
        }
        $null = $p.WaitForExit(3000)
        # Whatever is left of the tree (the parent may have ended long ago, its child still running).
        $left = @(Get-ProcessTreeIds $p.Id | Where-Object { $_ -ne $p.Id -or -not $p.HasExited } | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($left.Count) { Start-Sleep -Milliseconds 1500 }
        foreach ($id in $left) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    }
    $null = $errTask.Wait(3000); $null = $outTask.Wait(3000)
    $err = "$($errTask.Result)".Trim()
    $errors = @(if ($err) { ($err -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 12) })
    $code = if ($p.HasExited) { $p.ExitCode } else { $null }
    if ($hwnd -eq [IntPtr]::Zero -and -not $errors.Count) {
        $errors = @($(if ($p.HasExited) { "the script ended (exit code $code) without opening a window" } else { "no window opened within $WaitSec seconds" }))
        $out = "$($outTask.Result)".Trim()
        if ($out) { $errors += @($out -split "`r?`n" | Select-Object -Last 6) }
    }
    Write-CCBLog info guitest 'Window app start test' @{ script = $Script; opened = ($hwnd -ne [IntPtr]::Zero); errors = $errors.Count; steps = $ranSteps; stepErrors = $stepErrors.Count; access = @($access).Count; layout = @($layout).Count }
    $hide = { param($list) @(foreach ($x in @($list)) { Hide-LocalPaths "$x" $ProjectRoot }) }
    [pscustomobject]@{ opened = ($hwnd -ne [IntPtr]::Zero); title = (Hide-LocalPaths $title $ProjectRoot); shot = $shot; errors = @(& $hide $errors); access = @(& $hide $access); layout = @(& $hide $layout); steps = @(& $hide $stepErrors.ToArray()); ranSteps = $ranSteps; exitCode = $code; skipped = '' }
}

Export-ModuleMember -Function Find-GuiScripts, Test-PsGuiApp, Expand-XamlLayout, Hide-LocalPaths, Test-GuiLauncher, Read-GuiTestSteps, Get-GuiAccessIssues, Get-GuiLayoutIssues
