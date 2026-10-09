# The project's own build and check tools after a task (lib/ToolChecks.psm1), and data globals a page
# uses that nothing defines (Lint Find-DataGlobalIssues).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Lint', 'ToolChecks', 'CheckPolicy') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
function New-TempProject { $p = Join-Path $env:TEMP ('ccb-tools-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p -Force | Out-Null; $p }
function Add-File($p, $rel, $text) { $full = Join-Path $p $rel; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, $text) }

Describe 'Which tools check a task' {
    It 'uses the project''s own TypeScript compiler for changed TypeScript, and nothing for other files' {
        $p = New-TempProject
        try {
            Add-File $p 'tsconfig.json' '{}'
            Add-File $p 'node_modules\.bin\tsc.cmd' '@echo off'
            Add-File $p 'src\app.ts' 'let a: number = 1;'
            $c = @(Get-ToolChecks $p @('src/app.ts'))
            $c.Count | Should Be 1
            $c[0].kind | Should Be 'tsc'
            $c[0].command | Should Match '^node_modules\\\.bin\\tsc\.cmd --noEmit'
            @(Get-ToolChecks $p @('index.html', 'css/app.css')).Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'leaves a language out when its tool or project file is missing' {
        $p = New-TempProject
        try {
            Add-File $p 'src\app.ts' 'let a = 1;'   # no tsconfig, no compiler
            Add-File $p 'main.go' 'package main'    # no go.mod
            @(Get-ToolChecks $p @('src/app.ts', 'main.go') | Where-Object { $_.kind -in 'tsc', 'go' }).Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Reading what the tools report' {
    It 'takes the errors in each tool''s own form' {
        @(Get-ToolCheckErrors 'tsc' "src/app.ts(3,7): error TS2322: Type 'string' is not assignable to type 'number'.`nFound 1 error." 2) | Should Be "src/app.ts:3: TS2322 Type 'string' is not assignable to type 'number'."
        @(Get-ToolCheckErrors 'dotnet' "  Program.cs(12,9): error CS0103: The name 'x' does not exist in the current context [C:\p\App.csproj]`n  Program.cs(12,9): error CS0103: The name 'x' does not exist in the current context [C:\p\App.csproj]" 1) | Should Be "Program.cs:12: CS0103 The name 'x' does not exist in the current context"
        @(Get-ToolCheckErrors 'go' "# app`n./main.go:7:2: fmt.Printf format %d has arg s of wrong type string" 1) | Should Be './main.go:7:2: fmt.Printf format %d has arg s of wrong type string'
        @(Get-ToolCheckErrors 'javac' "App.java:4: error: ';' expected`n        int a = 1`n                 ^`n1 error" 1) | Should Be "App.java:4: ';' expected"
        @(Get-ToolCheckErrors 'pssa' "Scripts/Run.ps1:12: The variable 'x' is assigned but never used. (PSUseDeclaredVarsMoreThanAssignments)" 0).Count | Should Be 1
        @(Get-ToolCheckErrors 'tsc' '' 0).Count | Should Be 0
    }
    It 'shows the last lines of a failed run whose errors it does not recognise' {
        @(Get-ToolCheckErrors 'go' "go: cannot find main module" 1) | Should Be 'go: cannot find main module'
    }
}

Describe 'Data globals a page uses' {
    It 'reports a data name nothing defines, with the names the data files do define' {
        $p = New-TempProject
        try {
            Add-File $p 'data\sales.js' "// Generated from data/sales.json`nwindow.salesData = [{`"a`":1}];"
            Add-File $p 'data\people.js' "window.peopleData = [];"
            $page = "<html><body><div id=`"c`"></div>`n<script src=`"data/sales.js`"></script>`n<script>`nconst rows = window.saleData || [];`n</script></body></html>"
            Find-DataGlobalIssues $p 'index.html' $page | Should Match 'line 4: uses saleData, which no script or data file in the project defines.*salesData'
            Find-DataGlobalIssues $p 'index.html' ($page.Replace('saleData', 'salesData')) | Should BeNullOrEmpty
            Find-DataGlobalIssues $p 'js/app.js' "function draw(chartData) { return chartData.length; }`nconst filteredData = [];" | Should BeNullOrEmpty
            Find-DataGlobalIssues $p 'js/app.js' "// copilotData is not used here`nconst s = 'otherData';" | Should BeNullOrEmpty
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'checks nothing in a project without converted data files' {
        $p = New-TempProject
        try { Find-DataGlobalIssues $p 'js/app.js' 'const x = window.salesData;' | Should BeNullOrEmpty } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Phone width' {
    It 'is a likely problem, not a broken page' {
        Get-CheckLevel 'index.html at phone width (375 px) the page scrolls sideways by 120 px: table (640 px wide)' 'script' | Should Be 'warning'
        Get-CheckLevel 'index.html chart ''Sales'' shows nothing (no chart drawn and no empty state)' 'script' | Should Be 'error'
    }
}
