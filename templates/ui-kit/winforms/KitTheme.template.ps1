<#
  UI kit for PowerShell window apps with Windows Forms, written by the helper program from
  styles/kit/tokens.css: do not edit (change the colours in tokens.css). After building the form:
    . (Join-Path $root 'styles\kit\winforms\KitTheme.ps1')
    Set-KitFormStyle $form
    $okButton.Tag = 'primary'   # the main action, before Set-KitFormStyle
    Set-KitToolTipStyle $toolTip   # a ToolTip is not on the form: give it the kit's colours this way
  Colours, the font and flat buttons for the form and every control on it (tabs, trees, lists, menus,
  context menus, status bars, progress bars and track bars included). Dot-sourced, it shares the app's
  script scope: the app never defines Get-KitColor, Set-KitFormStyle, Set-KitStripStyle or
  Set-KitToolTipStyle, and never uses a variable name starting with __kit.
#>
$script:__kitColors = @{
    Bg = '{{bg}}'; Surface = '{{surface}}'; Surface2 = '{{surface-2}}'; Text = '{{text}}'; Muted = '{{text-muted}}'
    Border = '{{border}}'; BorderStrong = '{{border-strong}}'; Accent = '{{accent}}'; AccentHover = '{{accent-hover}}'; OnAccent = '{{on-accent}}'
    AccentSoft = '{{accent-soft}}'; Ok = '{{ok}}'; Warn = '{{warn}}'; Error = '{{error}}'
    Font = '{{font}}'
}

function Get-KitColor([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }

function Set-KitStripStyle {
    <# A menu, context menu, tool or status bar and every item in it (their items are not in Controls). #>
    param([Parameter(Mandatory)][System.Windows.Forms.ToolStrip]$Strip, [string]$Back = 'Surface', [string]$Fore = 'Text')
    $Strip.RenderMode = 'System'
    $Strip.BackColor = Get-KitColor $script:__kitColors[$Back]
    $Strip.ForeColor = Get-KitColor $script:__kitColors[$Fore]
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($i in $Strip.Items) { $items.Add($i) }
    for ($n = 0; $n -lt $items.Count; $n++) {
        $i = $items[$n]
        $i.ForeColor = Get-KitColor $script:__kitColors[$Fore]
        if ($i -is [System.Windows.Forms.ToolStripDropDownItem] -and $i.HasDropDownItems) {
            $i.DropDown.BackColor = Get-KitColor $script:__kitColors.Surface
            foreach ($d in $i.DropDownItems) { $items.Add($d) }
        }
    }
}

function Set-KitToolTipStyle {
    <# A ToolTip in the kit's colours: the surface with the text colour, like the kit's tooltip bubble. #>
    param([Parameter(Mandatory)][System.Windows.Forms.ToolTip]$Tip)
    $Tip.BackColor = Get-KitColor $script:__kitColors.Surface
    $Tip.ForeColor = Get-KitColor $script:__kitColors.Text
}

function Set-KitFormStyle {
    <# The kit's look for a form and all its controls; a button with Tag 'primary' gets the accent. #>
    param([Parameter(Mandatory)][System.Windows.Forms.Control]$Control)
    $font = New-Object System.Drawing.Font($script:__kitColors.Font, 10)
    $apply = {
        param($c)
        $c.Font = $font
        switch -Regex ($c.GetType().Name) {
            '^Form$' { $c.BackColor = Get-KitColor $script:__kitColors.Bg; $c.ForeColor = Get-KitColor $script:__kitColors.Text }
            '^Button$' {
                $c.FlatStyle = 'Flat'; $c.Cursor = [System.Windows.Forms.Cursors]::Hand
                if ("$($c.Tag)" -eq 'primary') {
                    $c.BackColor = Get-KitColor $script:__kitColors.Accent; $c.ForeColor = Get-KitColor $script:__kitColors.OnAccent
                    $c.FlatAppearance.BorderColor = Get-KitColor $script:__kitColors.Accent; $c.FlatAppearance.MouseOverBackColor = Get-KitColor $script:__kitColors.AccentHover
                } else {
                    $c.BackColor = Get-KitColor $script:__kitColors.Surface; $c.ForeColor = Get-KitColor $script:__kitColors.Text
                    $c.FlatAppearance.BorderColor = Get-KitColor $script:__kitColors.BorderStrong; $c.FlatAppearance.MouseOverBackColor = Get-KitColor $script:__kitColors.Surface2
                }
                if ($c.Height -lt 32) { $c.Height = 32 }
            }
            '^(TextBox|ComboBox|ListBox|NumericUpDown)$' { $c.BackColor = Get-KitColor $script:__kitColors.Surface; $c.ForeColor = Get-KitColor $script:__kitColors.Text }
            '^DataGridView$' {
                $c.BackgroundColor = Get-KitColor $script:__kitColors.Surface; $c.BorderStyle = 'FixedSingle'; $c.GridColor = Get-KitColor $script:__kitColors.Border
                $c.EnableHeadersVisualStyles = $false
                $c.ColumnHeadersDefaultCellStyle.BackColor = Get-KitColor $script:__kitColors.Surface2; $c.ColumnHeadersDefaultCellStyle.ForeColor = Get-KitColor $script:__kitColors.Text
                $c.AlternatingRowsDefaultCellStyle.BackColor = Get-KitColor $script:__kitColors.Bg; $c.RowHeadersVisible = $false
                # A picked row: the accent's soft colour with the text colour, as in the kit's tables.
                $c.DefaultCellStyle.SelectionBackColor = Get-KitColor $script:__kitColors.AccentSoft; $c.DefaultCellStyle.SelectionForeColor = Get-KitColor $script:__kitColors.Text
            }
            '^(Label|CheckBox|RadioButton|GroupBox)$' { $c.ForeColor = Get-KitColor $script:__kitColors.Text }
            '^(Panel|TabPage|FlowLayoutPanel|TableLayoutPanel)$' { $c.BackColor = Get-KitColor $script:__kitColors.Surface }
            '^(TreeView|ListView)$' {
                $c.BackColor = Get-KitColor $script:__kitColors.Surface; $c.ForeColor = Get-KitColor $script:__kitColors.Text; $c.BorderStyle = 'FixedSingle'
                if ($c -is [System.Windows.Forms.TreeView]) { $c.LineColor = Get-KitColor $script:__kitColors.Border }
            }
            '^TabControl$' {
                # Tabs as in the kit: the text colour on the surface, the open tab in semibold over a 2px accent line.
                $c.DrawMode = 'OwnerDrawFixed'
                $c.add_DrawItem({
                    param($s, $e)
                    $tab = $s.TabPages[$e.Index]
                    $on = ($e.Index -eq $s.SelectedIndex)
                    $back = New-Object System.Drawing.SolidBrush (Get-KitColor $script:__kitColors.Surface)
                    $e.Graphics.FillRectangle($back, $e.Bounds); $back.Dispose()
                    $f = if ($on) { New-Object System.Drawing.Font($s.Font, [System.Drawing.FontStyle]::Bold) } else { $s.Font }
                    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $tab.Text, $f, $e.Bounds, (Get-KitColor $script:__kitColors.Text), [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter')
                    if ($on) {
                        $line = New-Object System.Drawing.SolidBrush (Get-KitColor $script:__kitColors.Accent)
                        $e.Graphics.FillRectangle($line, $e.Bounds.X, ($e.Bounds.Bottom - 2), $e.Bounds.Width, 2); $line.Dispose(); $f.Dispose()
                    }
                })
            }
            '^ProgressBar$' { $c.ForeColor = Get-KitColor $script:__kitColors.Accent; $c.BackColor = Get-KitColor $script:__kitColors.Surface2 }
            '^TrackBar$' { $c.BackColor = if ($c.Parent) { $c.Parent.BackColor } else { Get-KitColor $script:__kitColors.Bg } }
            '^(MenuStrip|ToolStrip)$' { Set-KitStripStyle $c }
            '^StatusStrip$' { Set-KitStripStyle $c -Back 'Surface2' -Fore 'Muted' }
        }
        if ($c.ContextMenuStrip) { Set-KitStripStyle $c.ContextMenuStrip }
        foreach ($child in $c.Controls) { & $apply $child }
    }
    & $apply $Control
}
