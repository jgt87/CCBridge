<#
  UI kit for PowerShell window apps with Windows Forms, written by the helper program from
  styles/kit/tokens.css: do not edit (change the colours in tokens.css). After building the form:
    . (Join-Path $root 'styles\kit\winforms\KitTheme.ps1')
    Set-KitFormStyle $form
    $okButton.Tag = 'primary'   # the main action, before Set-KitFormStyle
  Colours, the font and flat buttons for the form and every control on it. Dot-sourced, it shares the
  app's script scope: the app never defines Get-KitColor or Set-KitFormStyle, and never uses a variable
  name starting with __kit.
#>
$script:__kitColors = @{
    Bg = '{{bg}}'; Surface = '{{surface}}'; Surface2 = '{{surface-2}}'; Text = '{{text}}'; Muted = '{{text-muted}}'
    Border = '{{border}}'; BorderStrong = '{{border-strong}}'; Accent = '{{accent}}'; AccentHover = '{{accent-hover}}'; OnAccent = '{{on-accent}}'
    Font = '{{font}}'
}

function Get-KitColor([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }

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
            }
            '^(Label|CheckBox|RadioButton|GroupBox)$' { $c.ForeColor = Get-KitColor $script:__kitColors.Text }
            '^(Panel|TabPage|FlowLayoutPanel|TableLayoutPanel)$' { $c.BackColor = Get-KitColor $script:__kitColors.Surface }
        }
        foreach ($child in $c.Controls) { & $apply $child }
    }
    & $apply $Control
}
