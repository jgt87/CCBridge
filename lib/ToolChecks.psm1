# The project's own build and check tools after a task, when they are on this computer and the
# project has what they need (setting checks.tools): TypeScript (the project's tsc), C# (dotnet
# build), Go (go vet), Java (javac, for projects without Maven or Gradle) and PowerShell
# (PSScriptAnalyzer, when installed). Only for the languages a task changed; errors go back to
# Copilot like failing tests (Agent, done step). Nothing is installed.

$ErrorActionPreference = 'Stop'
foreach ($m in 'TestRunner') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

function Find-RootFile([string]$ProjectRoot, [string[]]$Patterns, [int]$Depth = 1) {
    # The first file matching one of the patterns at the project root or $Depth folders down.
    foreach ($p in $Patterns) {
        $hit = @(Get-ChildItem -LiteralPath $ProjectRoot -Filter $p -File -Recurse -Depth $Depth -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(node_modules|bin|obj|\.git|\.streamhub)\\' }) | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $null
}

function Get-ToolChecks {
    <# The checks that apply to a task's changed files: @{ name; command; kind } each. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Changed)
    $root = $ProjectRoot.TrimEnd('\')
    $paths = @($Changed | ForEach-Object { "$_".Replace('\', '/') } | Where-Object { $_ -notmatch '(?i)^(Source|node_modules|dist|build|\.streamhub)/' })
    $has = { param($re) @($paths | Where-Object { $_ -match $re }).Count -gt 0 }
    $out = New-Object System.Collections.Generic.List[object]
    # TypeScript: the project's own compiler and tsconfig.
    $tsc = Join-Path $root 'node_modules\.bin\tsc.cmd'
    if ((& $has '(?i)\.(ts|tsx|mts|cts)$') -and (Test-Path -LiteralPath (Join-Path $root 'tsconfig.json')) -and (Test-Path -LiteralPath $tsc)) {
        $out.Add(@{ name = 'TypeScript (tsc --noEmit)'; command = 'node_modules\.bin\tsc.cmd --noEmit --pretty false -p tsconfig.json'; kind = 'tsc' })
    }
    # C#: dotnet build of the project or solution.
    if ((& $has '(?i)\.(cs|csproj|razor|xaml)$') -and (Get-RealCommand 'dotnet')) {
        $proj = Find-RootFile $root @('*.sln', '*.csproj') 2
        if ($proj) { $out.Add(@{ name = 'C# (dotnet build)'; command = "dotnet build `"$($proj.Substring($root.Length + 1))`" --nologo -v q -clp:NoSummary"; kind = 'dotnet' }) }
    }
    # Go: go vet over the module.
    if ((& $has '(?i)\.go$') -and (Test-Path -LiteralPath (Join-Path $root 'go.mod')) -and (Get-RealCommand 'go')) {
        $out.Add(@{ name = 'Go (go vet)'; command = 'go vet ./...'; kind = 'go' })
    }
    # Java: javac on the changed files, for projects without a build tool (those build their own way).
    $java = @($paths | Where-Object { $_ -match '(?i)\.java$' -and (Test-Path -LiteralPath (Join-Path $root $_)) })
    if ($java.Count -and (Get-RealCommand 'javac') -and -not (Find-RootFile $root @('pom.xml', 'build.gradle', 'build.gradle.kts') 1)) {
        $tmp = Join-Path $env:TEMP 'ccb-javac'
        $out.Add(@{ name = 'Java (javac)'; command = "javac -d `"$tmp`" " + (($java | ForEach-Object { "`"$_`"" }) -join ' '); kind = 'javac' })
    }
    # PowerShell: PSScriptAnalyzer errors, when the module is installed.
    $ps = @($paths | Where-Object { $_ -match '(?i)\.ps[md]?1$' -and $_ -notmatch '(?i)\.Tests\.ps1$' -and (Test-Path -LiteralPath (Join-Path $root $_)) })
    if ($ps.Count -and (Test-ScriptAnalyzer)) {
        $list = ($ps | Select-Object -First 30 | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
        $cmd = "Import-Module PSScriptAnalyzer; foreach (`$f in @($list)) { Invoke-ScriptAnalyzer -Path `$f -Severity Error | ForEach-Object { '{0}:{1}: {2} ({3})' -f `$f, `$_.Line, `$_.Message, `$_.RuleName } }"
        $out.Add(@{ name = 'PowerShell (PSScriptAnalyzer)'; command = 'powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd)); kind = 'pssa' })
    }
    $out.ToArray()
}

$script:AnalyzerFound = $null
function Test-ScriptAnalyzer {
    # PSScriptAnalyzer installed for Windows PowerShell (looked up once).
    if ($null -eq $script:AnalyzerFound) { $script:AnalyzerFound = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer -ErrorAction SilentlyContinue) }
    $script:AnalyzerFound
}

function Get-ToolCheckErrors {
    <# The errors in a check's output, "FILE:LINE: message" (at most 15); none when it passed. #>
    param([Parameter(Mandatory)][string]$Kind, [AllowEmptyString()][string]$Output, [int]$ExitCode = 0)
    $lines = @("$Output".Replace("`r`n", "`n").Split("`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
    $errs = switch ($Kind) {
        'tsc'    { @($lines | Where-Object { $_ -match '\(\d+,\d+\): error TS\d+' } | ForEach-Object { $_ -replace '^(.+?)\((\d+),\d+\): error (TS\d+): ', '$1:$2: $3 ' }) }
        'dotnet' { @($lines | Where-Object { $_ -match ': error [A-Z]+\d+' } | ForEach-Object { ($_ -replace '^\s*(.+?)\((\d+),\d+\): error ([A-Z]+\d+): ', '$1:$2: $3 ') -replace '\s*\[[^\]]+\]$', '' } | Select-Object -Unique) }
        'go'     { @($lines | Where-Object { $_ -match '^\S+\.go:\d+(:\d+)?: ' }) }
        'javac'  { @($lines | Where-Object { $_ -match '^.+\.java:\d+: error: ' } | ForEach-Object { $_ -replace ': error: ', ': ' }) }
        'pssa'   { @($lines | Where-Object { $_ -match '^.+\.ps[md]?1:\d+: ' }) }
        default  { @() }
    }
    $errs = @($errs | Select-Object -First 15)
    # A failed run without lines in the known form: its last lines.
    if (-not $errs.Count -and $ExitCode -ne 0 -and $Kind -ne 'pssa') { $errs = @($lines | Select-Object -Last 8) }
    $errs
}

Export-ModuleMember -Function Get-ToolChecks, Get-ToolCheckErrors, Test-ScriptAnalyzer
