# The project's own tests after a change, without a "verify:" line in AGENTS.md: which test command
# the project has (Pester ships with Windows; pytest or unittest when Python is installed; npm test
# when package.json has a test script and npm is installed), and which tests belong to the files a
# task changed. Fixed rules on file names and contents; the agent loop runs the command and sends
# failures back to Copilot (Agent.psm1, after "done").

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:Skip = '(?i)(^|/)(\.streamhub|Source|node_modules|dist|build|out|\.venv|venv|__pycache__)(/|$)'

function Get-RealCommand([string]$Name) {
    # A command on PATH, but not Windows' "install from the Store" python.exe stub.
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
    if ($c) { $c.Source } else { $null }
}

function Get-RelatedTests {
    <# Test files that belong to the changed files: a test named after a changed file (Name.Tests.ps1,
       test_name.py, name_test.py, name.test.js), a test that mentions a changed file's name, or a
       changed test itself. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Tests, [string[]]$Changed)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($t in @($Tests)) {
        $tname = ($t -split '/')[-1]
        foreach ($c in @($Changed)) {
            if ($c -ieq $t) { $out.Add($t); break }
            $stem = [IO.Path]::GetFileNameWithoutExtension(($c -split '/')[-1])
            if ($stem.Length -lt 3) { continue }
            $named = $tname -match "^(?i)(test_)?$([regex]::Escape($stem))([._-](tests?|spec))?\.(ps1|py|[cm]?[jt]sx?)$"
            $text = ''
            if (-not $named) { try { $text = (Read-TextFile (Join-Path $ProjectRoot $t.Replace('/', '\'))).Text } catch { } }
            if ($named -or ($text -and $text -match "(?i)\b$([regex]::Escape(($c -split '/')[-1]))\b")) { $out.Add($t); break }
        }
    }
    @($out | Select-Object -Unique)
}

function Find-TestCommand {
    <# The test command for a change: @{ command; kind (pester, pytest, unittest, npm); tests; scope
       (related or all) }, or $null when the project has no tests for what changed. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Changed)
    $changed = @($Changed | ForEach-Object { "$_".Replace('\', '/') } | Where-Object { $_ -notmatch $script:Skip })
    if (-not $changed.Count) { return $null }
    $files = @(Get-ProjectFiles $ProjectRoot | ForEach-Object { $_.path } | Where-Object { $_ -notmatch $script:Skip })
    $quote = { param($list) (@($list) | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',' }

    # PowerShell: Pester (ships with Windows PowerShell 5.1).
    if (@($changed | Where-Object { $_ -match '(?i)\.ps[dm]?1$' }).Count) {
        $tests = @($files | Where-Object { $_ -match '(?i)\.Tests\.ps1$' })
        if ($tests.Count) {
            $rel = @(Get-RelatedTests $ProjectRoot $tests $changed)
            $run = if ($rel.Count) { $rel } else { $tests }
            return [pscustomobject]@{ kind = 'pester'; tests = $run; scope = $(if ($rel.Count) { 'related' } else { 'all' })
                command = "powershell -NoProfile -ExecutionPolicy Bypass -Command `"Invoke-Pester -Path $(& $quote $run) -EnableExit`"" }
        }
    }
    # Python: pytest when installed, else unittest.
    if (@($changed | Where-Object { $_ -match '(?i)\.py$' }).Count) {
        $tests = @($files | Where-Object { ($_ -split '/')[-1] -match '^(?i)(test_.*|.*_test)\.py$' })
        $py = Get-RealCommand 'python'
        if ($tests.Count -and $py) {
            $rel = @(Get-RelatedTests $ProjectRoot $tests $changed)
            $hasPytest = $false
            try { $null = & $py -c 'import pytest' 2>$null; $hasPytest = ($LASTEXITCODE -eq 0) } catch { }
            if ($hasPytest) {
                $run = if ($rel.Count) { $rel } else { $tests }
                $argText = (@($run) | ForEach-Object { '"' + $_ + '"' }) -join ' '
                return [pscustomobject]@{ kind = 'pytest'; tests = $run; scope = $(if ($rel.Count) { 'related' } else { 'all' }); command = "python -m pytest -q $argText" }
            }
            return [pscustomobject]@{ kind = 'unittest'; tests = $tests; scope = 'all'; command = 'python -m unittest discover -q' }
        }
    }
    # JavaScript / TypeScript: the project's npm test script.
    if (@($changed | Where-Object { $_ -match '(?i)\.([cm]?[jt]sx?|vue|svelte)$' }).Count -and $files -contains 'package.json') {
        $pkg = try { (Read-TextFile (Join-Path $ProjectRoot 'package.json')).Text | ConvertFrom-Json } catch { $null }
        $script = "$($pkg.scripts.test)"
        if ($script -and $script -notmatch 'no test specified' -and (Get-RealCommand 'npm') -and (Test-Path -LiteralPath (Join-Path $ProjectRoot 'node_modules'))) {
            return [pscustomobject]@{ kind = 'npm'; tests = @(); scope = 'all'; command = 'npm test --silent' }
        }
    }
    $null
}

Export-ModuleMember -Function Get-RealCommand, Get-RelatedTests, Find-TestCommand
