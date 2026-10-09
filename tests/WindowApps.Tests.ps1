# Built-in builder (lib/WebBuild.psm1), SQL and Python in the page (kit parts sql, python), and
# PowerShell window apps: the WPF theme (UiKit Get-WpfThemeText, Update-KitWpf), the checks (Lint
# Find-PsGuiIssues) and the rule (Prompts rules:psgui). Edge and WPF are not started here.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'UiKit', 'Lint', 'Prompts', 'WebBuild', 'GuiTest') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
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
            @(Update-KitWpf $p $root) | Should Be 'styles/kit/wpf/KitTheme.xaml'
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
