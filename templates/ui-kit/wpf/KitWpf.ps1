<#
  Helpers for PowerShell window apps (WPF, Windows PowerShell 5.1, nothing to install), written by the
  helper program: do not edit (a newer version replaces this file). Dot-source it at the top of the app:
    . (Join-Path $PSScriptRoot 'styles\kit\wpf\KitWpf.ps1')      # the path from the app to this file
    $ui = New-KitWindow -Path (Join-Path $PSScriptRoot 'MainWindow.xaml')
    $ui.Refresh.Add_Click({ ... })                                # every x:Name of the window, by name
    Show-KitWindow $ui
  With the UI kit's theme (KitTheme.xaml next to this file) the window takes the kit's look; without it,
  the Windows look. Every helper works in both cases.

  Window       New-KitWindow -Path FILE | -Xaml TEXT  -> $ui (.Window plus every named element)
               Show-KitWindow $ui                       shows it; an error in a handler shows a message
  Layout       panels marked with a Tag are lined up by New-KitWindow (Set-KitLayout $ui.Window again
               after adding controls in code): a StackPanel Tag="row" puts its controls side by side,
               left, centred on one line, 8 apart; Tag="actions" the same at the right (the main action
               last); a Grid Tag="form" without Row/ColumnDefinitions takes its children as label, field,
               label, field: labels in one column, fields in a second that fills the width; without the
               kit's theme it also gives buttons, fields and lists one height (32)
  Messages     Show-KitMessage TEXT [-Title] [-Kind info|warn|error|question] -> OK / Yes / No / Cancel
               Set-KitStatus $ui.Status TEXT [-Tone ok|warn|error]   a status line in the window
  Files        Select-KitFile [-Filter 'CSV files|*.csv'] [-Save] [-Name]   -> path or $null
               Select-KitFolder [-Title]                                    -> path or $null
  Data         Import-KitData PATH (CSV, TSV, JSON) -> rows;  Export-KitCsv ROWS PATH (opens in Excel)
               Set-KitGrid $ui.Grid ROWS;  Set-KitGridFilter $ui.Grid TEXT (rows with all the words)
  Charts       Set-KitBars $ui.Chart ITEMS -Label NAME -Value NAME   a bar list in a StackPanel, kit colours
  Work         Start-KitWork { work } -Arguments @{ } -OnDone { param($result) } [-OnProgress { param($pct, $text) }]
               runs in the background so the window stays responsive; inside: Send-KitProgress PCT TEXT
               Set-KitBusy $ui $true|$false [-Text]   wait cursor, the window disabled, a status text
  Other        Add-KitShortcut $ui.Window 'Ctrl+S' { }; New-KitTimer SECONDS { } (on the window's thread)
               Get-KitSettings NAME / Save-KitSettings NAME OBJECT (JSON in %APPDATA%\NAME)
               Use-KitSingleInstance NAME (returns $false when the app is already open)
               Test-KitGuiTest   $true while the helper program only checks that the window opens
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:KitHere = $PSScriptRoot
$script:KitTheme = Join-Path $PSScriptRoot 'KitTheme.xaml'

function Get-KitApp {
    # The WPF application of this PowerShell session, with the kit's theme in its resources when the
    # project has one (the window needs the theme while it is read).
    $app = [Windows.Application]::Current
    if (-not $app) { $app = New-Object Windows.Application; $app.ShutdownMode = 'OnExplicitShutdown' }
    if ((Test-Path -LiteralPath $script:KitTheme) -and -not $app.Properties['KitTheme']) {
        $app.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText($script:KitTheme)))
        $app.Properties['KitTheme'] = $true
    }
    $app
}

function Test-KitGuiTest { [bool]$env:STREAMHUB_GUI_TEST }

function Set-KitLayout {
    <# Lines up the panels marked with a Tag (row, actions, form; see the header). Only what the window
       does not set itself: a Margin, alignment or Orientation written in the XAML stays. #>
    param([Parameter(Mandatory)]$Root)
    $unset = [Windows.DependencyProperty]::UnsetValue
    $FE = [Windows.FrameworkElement]
    $set = { param($el, $prop, $value) if ($el.ReadLocalValue($prop) -eq $unset) { $el.SetValue($prop, $value) } }
    # Without the kit's theme, Windows draws buttons, fields and lists in different heights: one height.
    $themed = [bool]$Root.TryFindResource('KitPrimaryButton')
    $inputs = [Windows.Controls.Button], [Windows.Controls.TextBox], [Windows.Controls.PasswordBox], [Windows.Controls.ComboBox], [Windows.Controls.DatePicker]
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count) {
        $el = $queue.Dequeue()
        if (-not $themed -and @($inputs | Where-Object { $el -is $_ }).Count -and -not ($el -is [Windows.Controls.TextBox] -and $el.AcceptsReturn)) {
            & $set $el $FE::MinHeightProperty ([double]32)
            if ($el -is [Windows.Controls.Control]) { & $set $el ([Windows.Controls.Control]::VerticalContentAlignmentProperty) ([Windows.VerticalAlignment]::Center) }
        }
        $tag = if ($el -is [Windows.FrameworkElement]) { "$($el.Tag)" } else { '' }
        if ($el -is [Windows.Controls.StackPanel] -and $tag -in 'row', 'actions') {
            & $set $el ([Windows.Controls.StackPanel]::OrientationProperty) ([Windows.Controls.Orientation]::Horizontal)
            & $set $el $FE::HorizontalAlignmentProperty $(if ($tag -eq 'row') { [Windows.HorizontalAlignment]::Left } else { [Windows.HorizontalAlignment]::Right })
            & $set $el $FE::MarginProperty $(if ($tag -eq 'row') { [Windows.Thickness]::new(0, 0, 0, 12) } else { [Windows.Thickness]::new(0, 12, 0, 0) })
            $kids = @($el.Children)
            for ($i = 0; $i -lt $kids.Count; $i++) {
                $k = $kids[$i]
                if ($k -isnot [Windows.FrameworkElement]) { continue }
                $gap = if ($tag -eq 'row') { [Windows.Thickness]::new(0, 0, $(if ($i -lt $kids.Count - 1) { 8 } else { 0 }), 0) } else { [Windows.Thickness]::new($(if ($i -gt 0) { 8 } else { 0 }), 0, 0, 0) }
                & $set $k $FE::MarginProperty $gap
                & $set $k $FE::VerticalAlignmentProperty ([Windows.VerticalAlignment]::Center)
            }
        } elseif ($el -is [Windows.Controls.Grid] -and $tag -eq 'form' -and -not $el.RowDefinitions.Count -and -not $el.ColumnDefinitions.Count) {
            $auto = New-Object Windows.Controls.ColumnDefinition; $auto.Width = [Windows.GridLength]::Auto
            $fill = New-Object Windows.Controls.ColumnDefinition; $fill.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
            $el.ColumnDefinitions.Add($auto); $el.ColumnDefinitions.Add($fill)
            $kids = @($el.Children)
            for ($i = 0; $i -lt $kids.Count; $i++) {
                if ($i % 2 -eq 0) { $r = New-Object Windows.Controls.RowDefinition; $r.Height = [Windows.GridLength]::Auto; $el.RowDefinitions.Add($r) }
                $k = $kids[$i]
                if ($k -isnot [Windows.FrameworkElement]) { continue }
                [Windows.Controls.Grid]::SetRow($k, [int][Math]::Floor($i / 2))
                [Windows.Controls.Grid]::SetColumn($k, $i % 2)
                & $set $k $FE::MarginProperty $(if ($i % 2 -eq 0) { [Windows.Thickness]::new(0, 0, 12, 8) } else { [Windows.Thickness]::new(0, 0, 0, 8) })
                # A multi-line field fills its row and its label sits at the top; one line: both centred.
                $field = if ($i % 2 -eq 0) { if ($i + 1 -lt $kids.Count) { $kids[$i + 1] } else { $null } } else { $k }
                $multi = $field -is [Windows.Controls.TextBox] -and ($field.AcceptsReturn -or $field.TextWrapping -eq 'Wrap')
                if ($multi) { if ($i % 2 -eq 0) { & $set $k $FE::VerticalAlignmentProperty ([Windows.VerticalAlignment]::Top) } }
                else { & $set $k $FE::VerticalAlignmentProperty ([Windows.VerticalAlignment]::Center) }
            }
        }
        foreach ($c in [Windows.LogicalTreeHelper]::GetChildren($el)) { if ($c -is [Windows.DependencyObject]) { $queue.Enqueue($c) } }
    }
}

function New-KitWindow {
    <# Reads the window (a .xaml file or text; no x:Class, no event attributes) and returns $ui with
       .Window and every element that has an x:Name. #>
    param([string]$Path, [string]$Xaml)
    $null = Get-KitApp
    if ($Path) { $Xaml = [IO.File]::ReadAllText($Path) }
    try { $window = [Windows.Markup.XamlReader]::Parse($Xaml) }
    catch {
        $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        throw "The window$(if ($Path) { " ($(Split-Path $Path -Leaf))" }) could not be read: $why"
    }
    Set-KitLayout $window
    $ui = [ordered]@{ Window = $window }
    foreach ($m in [regex]::Matches($Xaml, '\bx:Name\s*=\s*"([^"]+)"')) {
        $el = $window.FindName($m.Groups[1].Value)
        if ($el) { $ui[$m.Groups[1].Value] = $el }
    }
    [pscustomobject]$ui
}

function Show-KitWindow {
    <# Shows the window and waits until it is closed. An error in an event handler shows a message
       instead of ending the app silently. #>
    param([Parameter(Mandatory)]$Ui)
    $app = Get-KitApp
    $app.add_DispatcherUnhandledException({
        param($s, $e)
        $e.Handled = $true
        [Windows.MessageBox]::Show("Something went wrong: $($e.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
    })
    $null = $Ui.Window.ShowDialog()
}

function Show-KitMessage {
    param([Parameter(Mandatory)][string]$Text, [string]$Title = 'Message', [ValidateSet('info', 'warn', 'error', 'question')][string]$Kind = 'info')
    $icon = @{ info = 'Information'; warn = 'Warning'; error = 'Error'; question = 'Question' }[$Kind]
    $buttons = if ($Kind -eq 'question') { 'YesNoCancel' } else { 'OK' }
    "$([Windows.MessageBox]::Show($Text, $Title, $buttons, $icon))"
}

function Set-KitStatus {
    # A status line (a TextBlock) with a colour by meaning from the kit's theme when it is there.
    param([Parameter(Mandatory)]$Target, [string]$Text, [ValidateSet('', 'ok', 'warn', 'error')][string]$Tone = '')
    $Target.Text = $Text
    $key = @{ '' = 'KitTextMuted'; ok = 'KitOk'; warn = 'KitWarn'; error = 'KitError' }[$Tone]
    $brush = (Get-KitApp).TryFindResource($key)
    if ($brush) { $Target.Foreground = $brush }
}

function Select-KitFile {
    param([string]$Filter = 'All files|*.*', [string]$Title = '', [switch]$Save, [string]$Name = '')
    $d = if ($Save) { New-Object Microsoft.Win32.SaveFileDialog } else { New-Object Microsoft.Win32.OpenFileDialog }
    $d.Filter = $Filter
    if ($Title) { $d.Title = $Title }
    if ($Name) { $d.FileName = $Name }
    if ($d.ShowDialog()) { $d.FileName } else { $null }
}

function Select-KitFolder {
    param([string]$Title = 'Choose a folder')
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = $Title
    if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath } else { $null }
}

function Import-KitData {
    # Rows from a CSV, TSV or JSON file (UTF-8; a BOM is fine). Numbers stay text: convert where needed.
    param([Parameter(Mandatory)][string]$Path)
    switch -Regex ($Path) {
        '(?i)\.json$' { $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json; return @($j) }
        '(?i)\.(tsv|tab)$' { return @(Import-Csv -LiteralPath $Path -Delimiter "`t" -Encoding UTF8) }
        default {
            $first = (Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8)
            $delim = if (("$first".Split(';').Count) -gt ("$first".Split(',').Count)) { ';' } else { ',' }
            return @(Import-Csv -LiteralPath $Path -Delimiter $delim -Encoding UTF8)
        }
    }
}

function Export-KitCsv {
    # Rows to a CSV file that Excel opens with the right characters (UTF-8 with a BOM).
    param([Parameter(Mandatory)]$Rows, [Parameter(Mandatory)][string]$Path)
    $text = @($Rows) | ConvertTo-Csv -NoTypeInformation
    [IO.File]::WriteAllLines($Path, [string[]]$text, (New-Object Text.UTF8Encoding($true)))
}

function Set-KitGrid {
    <# A DataGrid's rows (objects; columns from their properties, sortable by a click on the header).
       Columns whose values are all numbers (also text such as "4210" from a CSV) become numbers, so they
       sort as numbers, and are right-aligned; every cell is centred in its row. #>
    param([Parameter(Mandatory)]$Grid, $Rows)
    $rows = @($Rows)
    $numeric = @{}
    if ($rows.Count) {
        foreach ($p in $rows[0].PSObject.Properties.Name) {
            $vals = @($rows | ForEach-Object { "$($_.$p)".Trim() } | Where-Object { $_ })
            $numeric[$p] = $vals.Count -gt 0 -and -not @($vals | Where-Object { $_ -notmatch '^-?\d+([.,]\d+)?$' }).Count
        }
        $rows = @(foreach ($r in $rows) {
            $o = [ordered]@{}
            foreach ($p in $r.PSObject.Properties.Name) {
                $v = $r.$p
                if ($numeric[$p] -and "$v".Trim()) { $v = [double]("$v".Trim().Replace(',', '.')) }
                $o[$p] = $v
            }
            [pscustomobject]$o
        })
    }
    $list = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($r in $rows) { $list.Add($r) }
    if (-not $Grid.Tag) {
        $Grid.add_AutoGeneratingColumn({
            param($s, $e)
            $style = New-Object Windows.Style([Windows.Controls.TextBlock])
            $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TextBlock]::VerticalAlignmentProperty, [Windows.VerticalAlignment]::Center)))
            $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TextBlock]::MarginProperty, (New-Object Windows.Thickness(8, 0, 8, 0)))))
            # PowerShell objects give every column the type object: look at the values themselves.
            $vals = @(@($s.ItemsSource) | ForEach-Object { $_.($e.PropertyName) } | Where-Object { $null -ne $_ })
            if ($vals.Count -and -not @($vals | Where-Object { $_ -isnot [double] -and $_ -isnot [int] -and $_ -isnot [long] -and $_ -isnot [decimal] }).Count) {
                $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TextBlock]::TextAlignmentProperty, [Windows.TextAlignment]::Right)))
                $e.Column.Binding.StringFormat = 'N0'
                if (@($s.ItemsSource | Where-Object { $_.($e.PropertyName) % 1 -ne 0 }).Count) { $e.Column.Binding.StringFormat = 'N2' }
            }
            $e.Column.ElementStyle = $style
        })
    }
    $Grid.ItemsSource = $list
    $Grid.Tag = $list
}

function Set-KitGridFilter {
    # Shows only the rows that hold all the words (any column); an empty text shows all.
    param([Parameter(Mandatory)]$Grid, [string]$Text)
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView($Grid.ItemsSource)
    if (-not $view) { return }
    $words = @("$Text".ToLowerInvariant().Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    if (-not $words.Count) { $view.Filter = $null; return }
    $view.Filter = [Predicate[object]]{
        param($row)
        $t = (@($row.PSObject.Properties | ForEach-Object { "$($_.Value)" }) -join ' ').ToLowerInvariant()
        foreach ($w in $words) { if (-not $t.Contains($w)) { return $false } }
        $true
    }.GetNewClosure()
}

function Set-KitBars {
    <# A bar list in a StackPanel: a label, a bar in a track (round at both ends) and the value per row,
       in the kit's chart colours (the first colour, or one colour per row with -Colors). #>
    param([Parameter(Mandatory)]$Panel, $Items, [string]$Label = 'Label', [string]$Value = 'Value', [switch]$Colors)
    $Panel.Children.Clear()
    $app = Get-KitApp
    $rows = @($Items)
    $max = [double](@($rows | ForEach-Object { [double]$_.$Value }) + 0 | Measure-Object -Maximum).Maximum
    if ($max -le 0) { $max = 1 }
    $track = $app.TryFindResource('KitSurface2'); if (-not $track) { $track = [Windows.Media.Brushes]::Gainsboro }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $grid = New-Object Windows.Controls.Grid
        $grid.Margin = '0,3'
        foreach ($w in @('150', '*', '70')) { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; $grid.ColumnDefinitions.Add($c) }
        $t = New-Object Windows.Controls.TextBlock; $t.Text = "$($r.$Label)"; $t.TextTrimming = 'CharacterEllipsis'; $t.VerticalAlignment = 'Center'
        $bg = New-Object Windows.Controls.Border; $bg.Height = 12; $bg.CornerRadius = 6; $bg.Background = $track; $bg.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($bg, 1)
        $fill = New-Object Windows.Controls.Border; $fill.Height = 12; $fill.CornerRadius = 6; $fill.HorizontalAlignment = 'Left'
        $brush = $app.TryFindResource($(if ($Colors) { 'KitChart' + (($i % 6) + 1) } else { 'KitChart1' })); if (-not $brush) { $brush = [Windows.Media.Brushes]::SteelBlue }
        $fill.Background = $brush
        $share = [double]$r.$Value / $max
        $bg.Child = $fill
        $bg.add_SizeChanged({ param($s, $e) $s.Child.Width = [Math]::Max(0, $e.NewSize.Width * $share) }.GetNewClosure())
        $v = New-Object Windows.Controls.TextBlock; $v.Text = ('{0:N0}' -f [double]$r.$Value); $v.TextAlignment = 'Right'; $v.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($v, 2)
        foreach ($el in $t, $bg, $v) { $null = $grid.Children.Add($el) }
        $null = $Panel.Children.Add($grid)
    }
}

function Start-KitWork {
    <# Runs a script block in the background (its own runspace), so the window keeps responding.
       -OnDone gets its result (or an error record) on the window's thread; inside the work,
       Send-KitProgress PCT TEXT calls -OnProgress on the window's thread. #>
    param([Parameter(Mandatory)][scriptblock]$Work, [hashtable]$Arguments = @{}, [scriptblock]$OnDone = {}, [scriptblock]$OnProgress = {})
    $dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $progress = { param($pct, $text) $dispatcher.Invoke([action]{ & $OnProgress $pct $text }) }.GetNewClosure()
    $rs.SessionStateProxy.SetVariable('KitProgress', $progress)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $null = $ps.AddScript('function Send-KitProgress($Pct, $Text) { & $KitProgress $Pct $Text }').AddStatement()
    $null = $ps.AddScript($Work.ToString())
    foreach ($k in $Arguments.Keys) { $null = $ps.AddParameter($k, $Arguments[$k]) }
    $handle = $ps.BeginInvoke()
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $result = try { $ps.EndInvoke($handle) } catch { $_ }
        if ($ps.Streams.Error.Count -and -not $result) { $result = $ps.Streams.Error[0] }
        $ps.Dispose(); $rs.Dispose()
        & $OnDone $result
    }.GetNewClosure())
    $timer.Start()
}

function Set-KitBusy {
    param([Parameter(Mandatory)]$Ui, [bool]$Busy, [string]$Text = 'Working...')
    $Ui.Window.Cursor = if ($Busy) { [Windows.Input.Cursors]::Wait } else { $null }
    $Ui.Window.IsEnabled = -not $Busy
    if ($Ui.PSObject.Properties['Status']) { Set-KitStatus $Ui.Status $(if ($Busy) { $Text } else { '' }) }
}

function Add-KitShortcut {
    # A keyboard shortcut for the window, such as 'Ctrl+S' or 'F5'.
    param([Parameter(Mandatory)]$Window, [Parameter(Mandatory)][string]$Keys, [Parameter(Mandatory)][scriptblock]$Action)
    $gesture = (New-Object Windows.Input.KeyGestureConverter).ConvertFromString($Keys)
    $cmd = New-Object Windows.Input.RoutedCommand
    $null = $Window.InputBindings.Add((New-Object Windows.Input.KeyBinding($cmd, $gesture)))
    $null = $Window.CommandBindings.Add((New-Object Windows.Input.CommandBinding($cmd, { & $Action }.GetNewClosure())))
}

function New-KitTimer {
    # Runs the action every SECONDS on the window's thread; returns the timer (.Stop() ends it).
    param([Parameter(Mandatory)][double]$Seconds, [Parameter(Mandatory)][scriptblock]$Action)
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds($Seconds)
    $t.add_Tick($Action)
    $t.Start()
    $t
}

function Get-KitSettings {
    param([Parameter(Mandatory)][string]$Name)
    $f = Join-Path $env:APPDATA "$Name\settings.json"
    if (Test-Path -LiteralPath $f) { try { return Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    [pscustomobject]@{}
}

function Save-KitSettings {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Settings)
    $dir = Join-Path $env:APPDATA $Name
    $null = New-Item -ItemType Directory -Force -Path $dir
    [IO.File]::WriteAllText((Join-Path $dir 'settings.json'), ($Settings | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

function Use-KitSingleInstance {
    # $true for the first copy of the app; $false when it is already open (then show a message and stop).
    param([Parameter(Mandatory)][string]$Name)
    $created = $false
    $script:KitMutex = New-Object Threading.Mutex($true, "Local\$Name", [ref]$created)
    $created
}
