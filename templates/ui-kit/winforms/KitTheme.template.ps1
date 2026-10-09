<#
  UI kit for PowerShell window apps with Windows Forms, written by the helper program from
  styles/kit/tokens.css: do not edit (change the colours in tokens.css). After building the form:
    . (Join-Path $root 'styles\kit\winforms\KitTheme.ps1')
    Set-KitFormStyle $form
    $okButton.Tag = 'primary'   # the main action, before Set-KitFormStyle
  Colours, the font and flat buttons for the form and every control on it.
#>
$script:Kit = @{
    Bg = '{{bg}}'; Surface = '{{surface}}'; Surface2 = '{{surface-2}}'; Text = '{{text}}'; Muted = '{{text-muted}}'
    Border = '{{border}}'; BorderStrong = '{{border-strong}}'; Accent = '{{accent}}'; AccentHover = '{{accent-hover}}'; OnAccent = '{{on-accent}}'
    Font = '{{font}}'
}

function Get-KitColor([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }

function Set-KitFormStyle {
    <# The kit's look for a form and all its controls; a button with Tag 'primary' gets the accent. #>
    param([Parameter(Mandatory)][System.Windows.Forms.Control]$Control)
    $font = New-Object System.Drawing.Font($script:Kit.Font, 10)
    $apply = {
        param($c)
        $c.Font = $font
        switch -Regex ($c.GetType().Name) {
            '^Form$' { $c.BackColor = Get-KitColor $script:Kit.Bg; $c.ForeColor = Get-KitColor $script:Kit.Text }
            '^Button$' {
                $c.FlatStyle = 'Flat'; $c.Cursor = [System.Windows.Forms.Cursors]::Hand
                if ("$($c.Tag)" -eq 'primary') {
                    $c.BackColor = Get-KitColor $script:Kit.Accent; $c.ForeColor = Get-KitColor $script:Kit.OnAccent
                    $c.FlatAppearance.BorderColor = Get-KitColor $script:Kit.Accent; $c.FlatAppearance.MouseOverBackColor = Get-KitColor $script:Kit.AccentHover
                } else {
                    $c.BackColor = Get-KitColor $script:Kit.Surface; $c.ForeColor = Get-KitColor $script:Kit.Text
                    $c.FlatAppearance.BorderColor = Get-KitColor $script:Kit.BorderStrong; $c.FlatAppearance.MouseOverBackColor = Get-KitColor $script:Kit.Surface2
                }
                if ($c.Height -lt 32) { $c.Height = 32 }
            }
            '^(TextBox|ComboBox|ListBox|NumericUpDown)$' { $c.BackColor = Get-KitColor $script:Kit.Surface; $c.ForeColor = Get-KitColor $script:Kit.Text }
            '^DataGridView$' {
                $c.BackgroundColor = Get-KitColor $script:Kit.Surface; $c.BorderStyle = 'FixedSingle'; $c.GridColor = Get-KitColor $script:Kit.Border
                $c.EnableHeadersVisualStyles = $false
                $c.ColumnHeadersDefaultCellStyle.BackColor = Get-KitColor $script:Kit.Surface2; $c.ColumnHeadersDefaultCellStyle.ForeColor = Get-KitColor $script:Kit.Text
                $c.AlternatingRowsDefaultCellStyle.BackColor = Get-KitColor $script:Kit.Bg; $c.RowHeadersVisible = $false
            }
            '^(Label|CheckBox|RadioButton|GroupBox)$' { $c.ForeColor = Get-KitColor $script:Kit.Text }
            '^(Panel|TabPage|FlowLayoutPanel|TableLayoutPanel)$' { $c.BackColor = Get-KitColor $script:Kit.Surface }
        }
        foreach ($child in $c.Controls) { & $apply $child }
    }
    & $apply $Control
}
