# Built-in builder (lib/WebBuild.psm1), SQL and Python in the page (kit parts sql, python), and
# PowerShell window apps: the WPF theme (UiKit Get-WpfThemeText, Update-KitWpf), the checks (Lint
# Find-PsGuiIssues) and the rule (Prompts rules:psgui). Edge and WPF are not started here.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'UiKit', 'Lint', 'Prompts', 'WebBuild', 'GuiTest', 'CheckPolicy') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
function New-TempProject { $p = Join-Path $env:TEMP ('ccb-wapp-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p -Force | Out-Null; $p }
function Add-File($p, $rel, $text) { $full = Join-Path $p $rel; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, $text) }

Describe 'The built-in builder' {
    It 'builds a project with an entry in src/ that does not build with npm itself' {
        $p = New-TempProject
        try {
            Get-WebBuildEntry $p | Should BeNullOrEmpty
            Add-File $p 'src\main.tsx' 'export {};'
            Get-WebBuildEntry $p | Should Be 'src/main.tsx'
            Test-WebBuildProject $p | Should Be $true
            Add-File $p 'package.json' '{ "scripts": { "build": "vite build" } }'
            Test-WebBuildProject $p | Should Be $true    # no node_modules: npm cannot build it here
            New-Item -ItemType Directory (Join-Path $p 'node_modules') | Out-Null
            Test-WebBuildProject $p | Should Be $false   # the project builds with npm of its own
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'gives the builder the text files of src/ and images as base64' {
        $p = New-TempProject
        try {
            Add-File $p 'src\main.tsx' 'import "./a.css";'
            Add-File $p 'src\a.css' '.a{}'
            [IO.File]::WriteAllBytes((Join-Path $p 'src\logo.png'), [byte[]](137, 80, 78, 71))
            Add-File $p 'README.md' 'not part of the app'
            $in = Get-WebBuildInput $p
            @($in.files.Keys | Sort-Object) -join ',' | Should Be 'src/a.css,src/logo.png,src/main.tsx'
            $in.binary['src/logo.png'] | Should Be $true
            $in.files['src/logo.png'] | Should Be 'iVBORw=='
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'ships the builder files, and writes a build script for when StreamHub is closed' {
        foreach ($f in 'build.html', 'build.js', 'esbuild.js', 'esbuild-wasm.js', 'typescript.js', 'vendor.js', 'LICENSE-esbuild.md', 'LICENSE-typescript.txt', 'LICENSE-react.txt') { Test-Path (Join-Path $root "templates\build\$f") | Should Be $true }
        $p = New-TempProject
        try {
            Write-BuildScript $p $root | Should Be 'Scripts/Build-App.ps1'
            [IO.File]::ReadAllText((Join-Path $p 'Scripts\Build-App.ps1')) | Should Match 'Invoke-WebBuild -ProjectRoot \$project'
            Write-BuildScript $p $root | Should Be ''
        } finally { Remove-Item $p -Recurse -Force }
        Format-WebBuildProblems ([pscustomobject]@{ errors = @(@{ file = 'src/a.ts'; line = 3; text = 'Cannot find ./b' }); typeErrors = @(@{ file = 'src/a.ts'; line = 5; text = 'TS2322 bad' }) }) | Should Be @('src/a.ts:3: Cannot find ./b', 'src/a.ts:5: TS2322 bad')
    }
    It 'tells Copilot to use it when npm is missing' {
        Mock -ModuleName Prompts Test-ToolInstalled { $false }
        (& (Get-Module Prompts) { param($r) Read-PromptPart $r 'rules\react.md' } $root) | Should Match 'the helper program builds React and TypeScript apps itself'
    }
}

Describe 'SQL and Python in the page' {
    It 'has both parts, SQL on and Python off by default, with their rule lines' {
        foreach ($f in 'kit-sql.js', 'kit-python.js', 'vendor\sqljs\sql-asm.js', 'vendor\pyodide\pyodide.js', 'vendor\pyodide\pyodide.asm.wasm') { Test-Path (Join-Path $root "templates\ui-kit\$f") | Should Be $true }
        Mock -ModuleName Config Get-CCBridgeConfig { [pscustomobject]@{ uiKitParts = [pscustomobject]@{} } }
        Test-UiKitPart 'sql' $root | Should Be $true
        Test-UiKitPart 'python' $root | Should Be $false
        $rule = [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\uikit.md'))
        $rule | Should Match '- SQL in the page:'
        $rule | Should Match '- Python in the page:.*only when the page is served'
    }
}

Describe 'PowerShell window apps' {
    It 'writes the kit''s WPF theme with the project''s colours, only in a project with a window app' {
        $p = New-TempProject
        try {
            Add-File $p 'Scripts\Report.ps1' 'Get-ChildItem'
            @(Update-KitWpf $p $root).Count | Should Be 0
            Add-File $p 'App.ps1' "Add-Type -AssemblyName PresentationFramework`n`$w = [Windows.Markup.XamlReader]::Parse(`$x)"
            Add-File $p 'styles\kit\tokens.css' ":root {`n  --kit-accent: #123456;`n  --kit-font: Verdana, sans-serif;`n  --kit-radius: 4px;`n}"
            @(Update-KitWpf $p $root) -contains 'styles/kit/wpf/KitTheme.xaml' | Should Be $true
            $t = [IO.File]::ReadAllText((Join-Path $p 'styles\kit\wpf\KitTheme.xaml'))
            $t | Should Match 'x:Key="KitAccent" Color="#123456"'
            $t | Should Match '<FontFamily x:Key="KitFont">Verdana</FontFamily>'
            $t | Should Match 'CornerRadius="4"'
            $t | Should Not Match '\{\{'
            ([xml]$t).ResourceDictionary | Should Not BeNullOrEmpty
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'has no style for every TextBlock (it would colour button text)' {
        [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\wpf\KitTheme.template.xaml')) | Should Not Match '<Style TargetType="TextBlock">'
    }
    It 'reports what stops a window app from opening or breaks its look' {
        Find-PsGuiIssues '' 'MainWindow.xaml' '<Window x:Class="App.Main" xmlns="x"/>' | Should Match 'x:Class'
        Find-PsGuiIssues '' 'MainWindow.xaml' "<Window xmlns=`"x`">`n<Button x:Name=`"Go`" Click=`"OnGo`"/></Window>" | Should Match "line 2: the event attribute Click=.*Add_Click"
        Find-PsGuiIssues '' 'MainWindow.xaml' '<Window xmlns="x"><Window.Resources><Style TargetType="TextBlock"><Setter Property="Foreground" Value="Red"/></Style></Window.Resources></Window>' | Should Match 'style for every TextBlock'
        Find-PsGuiIssues '' 'MainWindow.xaml' '<Window xmlns="x"><Window.Resources><Style TargetType="TextBlock" x:Key="Note"><Setter Property="Foreground" Value="Gray"/></Style></Window.Resources></Window>' | Should BeNullOrEmpty
        Find-PsGuiIssues '' 'App.ps1' "`$w = [Windows.Markup.XamlReader]::Parse(`$x)" | Should Match 'Add-Type -AssemblyName PresentationFramework'
        Find-PsGuiIssues '' 'App.ps1' "Add-Type -AssemblyName System.Drawing`n[System.Windows.Forms.MessageBox]::Show('x')" | Should Match 'Add-Type -AssemblyName System.Windows.Forms'
        $late = "Add-Type -AssemblyName PresentationFramework`n`$window = [Windows.Markup.XamlReader]::Parse(`$xaml)`n`$window.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText('styles\kit\wpf\KitTheme.xaml')))"
        Find-PsGuiIssues '' 'App.ps1' $late | Should Match "line 3: the kit theme goes into the application's resources before the window is parsed"
        $good = "Add-Type -AssemblyName PresentationFramework`n`$app = [Windows.Application]::Current; if (-not `$app) { `$app = New-Object Windows.Application }`n`$app.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText('styles\kit\wpf\KitTheme.xaml')))`n`$window = [Windows.Markup.XamlReader]::Parse(`$xaml)"
        Find-PsGuiIssues '' 'App.ps1' $good | Should BeNullOrEmpty
    }
    It 'finds the window apps a task changed' {
        $p = New-TempProject
        try {
            Add-File $p 'App.ps1' "Add-Type -AssemblyName PresentationFramework`n`$xaml = [IO.File]::ReadAllText(`"`$PSScriptRoot\MainWindow.xaml`")`n`$w = [Windows.Markup.XamlReader]::Parse(`$xaml)`n`$null = `$w.ShowDialog()"
            Add-File $p 'MainWindow.xaml' '<Window xmlns="x"/>'
            Add-File $p 'Scripts\Report.ps1' 'Get-Date'
            @(Find-GuiScripts $p @('App.ps1')) | Should Be 'App.ps1'
            @(Find-GuiScripts $p @('MainWindow.xaml')) | Should Be 'App.ps1'
            @(Find-GuiScripts $p @('Scripts/Report.ps1')).Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'sends the window app rule when the request or the project asks for it' {
        @(Get-PromptModules 'Build a PowerShell app with a window to pick a file' @{ Traits = @('powershell'); Paths = @() }) -contains 'rules:psgui' | Should Be $true
        @(Get-PromptModules 'Add a button to the form' @{ Traits = @('powershell'); Paths = @('App.ps1', 'MainWindow.xaml') }) -contains 'rules:psgui' | Should Be $true
        @(Get-PromptModules 'Write a script that copies files' @{ Traits = @('powershell'); Paths = @() }) -contains 'rules:psgui' | Should Be $false
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue

Describe 'Window app helpers, tests and checks' {
    It 'writes the helpers for every window app, and the theme only with the UI kit' {
        $p = New-TempProject
        try {
            Add-File $p 'App.ps1' "Add-Type -AssemblyName PresentationFramework`n[System.Windows.Forms.MessageBox]::Show('x')"
            @(Update-KitWpf $p $root -NoTheme) | Should Be 'styles/kit/wpf/KitWpf.ps1'
            Test-Path (Join-Path $p 'styles\kit\wpf\KitTheme.xaml') | Should Be $false
            $w = @(Update-KitWpf $p $root)
            $w -contains 'styles/kit/wpf/KitTheme.xaml' | Should Be $true
            $w -contains 'styles/kit/winforms/KitTheme.ps1' | Should Be $true
            [IO.File]::ReadAllText((Join-Path $p 'styles\kit\winforms\KitTheme.ps1')) | Should Match "Accent = '#10069f'"
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'ships helpers that pass the file checks' {
        $t = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\wpf\KitWpf.ps1'))
        [regex]::IsMatch($t, '[^\x00-\x7F]') | Should Be $false
        @(Test-FileContent 'styles/kit/wpf/KitWpf.ps1' $t) | Should BeNullOrEmpty
        foreach ($f in 'New-KitWindow', 'Show-KitWindow', 'Set-KitGrid', 'Set-KitGridFilter', 'Set-KitBars', 'Start-KitWork', 'Select-KitFile', 'Import-KitData', 'Export-KitCsv', 'Add-KitShortcut', 'Use-KitSingleInstance') { $t | Should Match "function $f" }
    }
    It 'reads the steps of a window app test' {
        $p = New-TempProject
        try {
            Add-File $p 'App.guitest' "# the main flow`ntype Search = kor`nclick Load`nselect Country = Korea`nexpect Status = Done`nexpect 3 rows`nwait 200`njump around"
            $s = @(Read-GuiTestSteps (Join-Path $p 'App.guitest'))
            $s.Count | Should Be 7
            "$($s[0].kind)|$($s[0].target)|$($s[0].value)" | Should Be 'type|Search|kor'
            "$($s[2].kind)|$($s[2].target)|$($s[2].value)" | Should Be 'select|Country|Korea'
            "$($s[4].kind)|$($s[4].target)|$($s[4].value)" | Should Be 'expect||3 rows'
            $s[6].kind | Should Be 'bad'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'checks the launcher' {
        $p = New-TempProject
        try {
            Test-GuiLauncher $p 'App.ps1' | Should Match '^no launcher: add App\.cmd'
            Add-File $p 'App.cmd' 'powershell.exe -NoProfile -File "%~dp0App.ps1"'
            Test-GuiLauncher $p 'App.ps1' | Should Match 'without -STA and -WindowStyle Hidden'
            Add-File $p 'App.cmd' 'powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0App.ps1"'
            Test-GuiLauncher $p 'App.ps1' | Should Be ''
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'adapts the window app rule to the UI kit and to Constrained Language Mode' {
        $r = & (Get-Module Prompts) { param($a) Get-PromptPart $a 'rules:psgui' @{ Root = '' } } $root
        $r | Should Match 'KitWpf\.ps1'
        $r | Should Match '- The look comes from the UI kit'
        Mock -ModuleName Prompts Test-UiKitOn { $false }
        $r = & (Get-Module Prompts) { param($a) Get-PromptPart $a 'rules:psgui' @{ Root = '' } } $root
        $r | Should Not Match '- The look comes from the UI kit'
        Mock -ModuleName Prompts Get-ScriptLanguageMode { 'ConstrainedLanguage' }
        $r = & (Get-Module Prompts) { param($a) Get-PromptPart $a 'rules:psgui' @{ Root = 'C:\x' } } $root
        $r | Should Match 'Constrained Language Mode'
    }
}

Describe 'Window app reports without personal paths' {
    It 'makes project paths relative and masks the profile folder' {
        $p = Join-Path $env:USERPROFILE 'OneDrive\Apps\Viewer'
        $t = Hide-LocalPaths "At $p\App.ps1:76 char:52`nlog in $env:USERPROFILE\AppData\x.txt" $p
        $t | Should Match '^At App\.ps1:76 char:52'
        $t | Should Not Match ([regex]::Escape($env:USERPROFILE))
        if ($env:USERNAME.Length -ge 3) { $t | Should Not Match ([regex]::Escape($env:USERNAME)) }
    }
}

Describe 'Window app alignment' {
    $head = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">'
    It 'reports a fixed-width control that WPF would centre, and not one that is aligned or in a row' {
        $x = "$head`n<StackPanel>`n<ComboBox x:Name=`"Pick`" Width=`"240`"/>`n<ComboBox x:Name=`"Left`" Width=`"240`" HorizontalAlignment=`"Left`"/>`n<StackPanel Tag=`"row`"><TextBox Width=`"240`"/></StackPanel>`n</StackPanel></Window>"
        $r = @(Find-XamlLayoutIssues 'MainWindow.xaml' $x)
        $r.Count | Should Be 1
        $r[0] | Should Match '^line 3: the ComboBox Pick has a Width but no HorizontalAlignment, so it ends up centred'
    }
    It 'reports a star-sized grid column but not an Auto one' {
        $x = "$head<Grid><Grid.ColumnDefinitions><ColumnDefinition Width=`"*`"/><ColumnDefinition Width=`"Auto`"/></Grid.ColumnDefinitions>`n<Button x:Name=`"A`" Width=`"90`"/>`n<Button x:Name=`"B`" Grid.Column=`"1`" Width=`"90`"/></Grid></Window>"
        $r = @(Find-XamlLayoutIssues 'MainWindow.xaml' $x)
        $r.Count | Should Be 1
        $r[0] | Should Match 'Button A has a Width'
    }
    It 'reports controls placed by coordinates and controls with their own height' {
        $x = "$head<Grid>`n<Button Content=`"A`" Margin=`"120,45,0,0`" HorizontalAlignment=`"Left`" VerticalAlignment=`"Top`"/>`n<StackPanel Orientation=`"Horizontal`"><TextBox Height=`"44`"/><Button Height=`"24`"/></StackPanel></Grid></Window>"
        $r = @(Find-XamlLayoutIssues 'MainWindow.xaml' $x)
        ($r -join "`n") | Should Match 'line 2: a Button is placed by coordinates \(a large Margin'
        ($r -join "`n") | Should Match 'line 3: a TextBox has its own Height \(44\) and so do 1 more'
        @(Find-XamlLayoutIssues 'MainWindow.xaml' "$head<Canvas><Button Canvas.Left=`"10`"/></Canvas></Window>")[0] | Should Match 'on a Canvas'
    }
    It 'reads XAML in a script and leaves the kit''s own files alone' {
        $s = "Add-Type -AssemblyName PresentationFramework`n`$x = @'`n$head`n<StackPanel><TextBox x:Name=`"Q`" Width=`"200`"/></StackPanel></Window>`n'@`n[Windows.Markup.XamlReader]::Parse(`$x)"
        @(Find-XamlLayoutIssues 'App.ps1' $s)[0] | Should Match '^line 4: the TextBox Q'
        @(Find-XamlLayoutIssues 'styles/kit/wpf/X.xaml' "$head<StackPanel><TextBox Width=`"2`"/></StackPanel></Window>").Count | Should Be 0
    }
    It 'reports field widths off the scale once, and leaves widths on the scale and multi-line fields alone' {
        $x = "$head<StackPanel Tag=`"row`">`n<TextBox x:Name=`"A`" Width=`"200`"/>`n<ComboBox Width=`"140`"/><DatePicker Width=`"120`"/><Button Width=`"95`"/>`n<TextBox Width=`"240`" Height=`"90`" AcceptsReturn=`"True`"/></StackPanel></Window>"
        $r = @(Find-XamlLayoutIssues 'MainWindow.xaml' $x)
        $r.Count | Should Be 1
        $r[0] | Should Match '^line 2: field widths 200, 140 are off the width scale: use 120'
        Get-CheckLevel $r[0] 'lint' | Should Be 'warning'
    }
    It 'reports tagged panels in a window inside a script that loads it without the helpers' {
        $own = "Add-Type -AssemblyName PresentationFramework`n`$x = @'`n$head<StackPanel Tag=`"row`"><Button/></StackPanel></Window>`n'@`n`$w = [Windows.Markup.XamlReader]::Parse(`$x)"
        $r = @(Find-XamlLayoutIssues 'App.ps1' $own)
        $r[0] | Should Match '^line 5: the window inside this script marks panels with Tag=.*so nothing lines them up: move the window into MainWindow\.xaml'
        Get-CheckLevel $r[0] 'lint' | Should Be 'warning'
        @(Find-XamlLayoutIssues 'App.ps1' ($own + "`nSet-KitLayout `$w")).Count | Should Be 0
        # A window in its own .xaml file gets its layout written in, however the script loads it.
        @(Find-XamlLayoutIssues 'App.ps1' "Add-Type -AssemblyName PresentationFramework`n`$w = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path `$PSScriptRoot 'MainWindow.xaml')))").Count | Should Be 0
    }
    It 'writes the layout of tagged panels into the XAML, once' {
        $x = "$head`n<DockPanel>`n  <StackPanel Tag=`"row`">`n    <TextBox Width=`"240`"/>`n    <Button Content=`"Go`" Margin=`"2`"/>`n  </StackPanel>`n  <Grid Tag=`"form`">`n    <Label Content=`"Name`"/>`n    <TextBox/>`n    <Label Content=`"Notes`"/>`n    <TextBox AcceptsReturn=`"True`"/>`n  </Grid>`n  <StackPanel Tag=`"actions`"><Button Content=`"Cancel`"/><Button Content=`"Save`"/></StackPanel>`n</DockPanel></Window>"
        $r = Expand-XamlLayout $x -Heights
        @($r.changes).Count | Should Be 4
        $t = $r.text
        $t | Should Match '<StackPanel Tag="row" Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,0,0,12">'
        $t | Should Match '<TextBox Width="240" Margin="0,0,8,0" VerticalAlignment="Center" MinHeight="32" VerticalContentAlignment="Center"/>'
        $t | Should Match '<Button Content="Go" Margin="2" VerticalAlignment="Center" MinHeight="32"/>'
        $t | Should Match '(?s)<Grid Tag="form">\s*<Grid\.ColumnDefinitions>\s*<ColumnDefinition Width="Auto"/>\s*<ColumnDefinition Width="\*"/>'
        $t | Should Match '<Label Content="Notes" Grid\.Row="1" Grid\.Column="0" Margin="0,0,12,8" VerticalAlignment="Top"/>'
        $t | Should Match '<TextBox AcceptsReturn="True" Grid\.Row="1" Grid\.Column="1" Margin="0,0,0,8"/>'
        $t | Should Match '<Button Content="Save" Margin="8,0,0,0" VerticalAlignment="Center" MinHeight="32"/>'
        @((Expand-XamlLayout $t -Heights).changes).Count | Should Be 0
        $null = [Windows.Markup.XamlReader]::Parse($t)
        # With the kit's theme the heights come from the theme; nothing tagged, nothing to write.
        (Expand-XamlLayout $x).text | Should Not Match 'MinHeight'
        @((Expand-XamlLayout "$head<Grid/></Window>").changes).Count | Should Be 0
    }
    It 'marks the alignment findings as warnings' {
        Get-CheckLevel 'line 3: the ComboBox Pick has a Width but no HorizontalAlignment, so it ends up centred while the rest starts at the left' 'lint' | Should Be 'warning'
    }
    It 'lines up rows, action bars and forms marked with a Tag' {
        . (Join-Path $root 'templates\ui-kit\wpf\KitWpf.ps1')
        $w = [Windows.Markup.XamlReader]::Parse("$head<StackPanel>
<StackPanel x:Name=`"Row`" Tag=`"row`"><TextBox x:Name=`"R1`"/><Button x:Name=`"R2`" Margin=`"2`"/><Button x:Name=`"R3`"/></StackPanel>
<StackPanel x:Name=`"Bar`" Tag=`"actions`"><Button x:Name=`"A1`"/><Button x:Name=`"A2`"/></StackPanel>
<Grid x:Name=`"Form`" Tag=`"form`"><Label x:Name=`"L1`"/><TextBox x:Name=`"F1`"/><Label x:Name=`"L2`"/><TextBox x:Name=`"F2`"/></Grid>
</StackPanel></Window>")
        Set-KitLayout $w
        $f = { param($n) $w.FindName($n) }
        "$((& $f 'Row').Orientation) $((& $f 'Row').HorizontalAlignment)" | Should Be 'Horizontal Left'
        "$((& $f 'R1').Margin)|$((& $f 'R2').Margin)|$((& $f 'R3').Margin)" | Should Be '0,0,8,0|2,2,2,2|0,0,0,0'
        "$((& $f 'R1').VerticalAlignment)" | Should Be 'Center'
        # No kit theme here: buttons and fields get one height.
        "$((& $f 'R1').MinHeight)|$((& $f 'R3').MinHeight)" | Should Be '32|32'
        "$((& $f 'Bar').HorizontalAlignment)|$((& $f 'A1').Margin)|$((& $f 'A2').Margin)" | Should Be 'Right|0,0,0,0|8,0,0,0'
        (& $f 'Form').ColumnDefinitions.Count | Should Be 2
        "$([Windows.Controls.Grid]::GetRow((& $f 'F2'))),$([Windows.Controls.Grid]::GetColumn((& $f 'F2')))" | Should Be '1,1'
        "$([Windows.Controls.Grid]::GetColumn((& $f 'L2')))" | Should Be '0'
    }
}
