# Pester 3.4. What a run command's scripts do, read before they run: paths from the script's own
# folder, folder changes, scripts started by scripts, and what reaches beyond the project (a person
# approves it: hold to run). Executor Test-DeleteScope, Get-RunScripts, Get-RunEffects.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

$base = Join-Path $env:TEMP ('ccb-runscripts-' + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $base 'proj'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'Scripts'), (Join-Path $base 'outside')
function Set-Script([string]$Name, [string]$Text) { [IO.File]::WriteAllText((Join-Path $proj $Name), $Text.Replace("`r`n", "`n")) }

Describe 'Paths from the script''s own folder' {
    It 'reads Join-Path $PSScriptRoot ''..\dist'' as the project''s dist folder' {
        Set-Script 'Scripts\a.ps1' "Remove-Item (Join-Path `$PSScriptRoot '..\dist') -Recurse -Force`nCopy-Item (Join-Path `$PSScriptRoot `"..\index.html`") (Join-Path `$PSScriptRoot '..\dist')`n"
        Test-DeleteScope $proj 'powershell -NoProfile -File Scripts/a.ps1' | Should BeNullOrEmpty
    }
    It 'reads a path variable the script sets once, and %~dp0 in a batch file' {
        Set-Script 'Scripts\b.ps1' "`$root = Split-Path -Parent `$PSScriptRoot`n`$dist = Join-Path `$root 'dist'`nif (Test-Path `$dist) { Remove-Item `$dist -Recurse -Force }`n"
        Test-DeleteScope $proj 'powershell -File Scripts/b.ps1' | Should BeNullOrEmpty
        Set-Script 'Scripts\c.cmd' "rd /s /q `"%~dp0..\dist`"`r`n"
        Test-DeleteScope $proj 'Scripts\c.cmd' | Should BeNullOrEmpty
    }
    It 'still refuses a path from the script''s folder that leads outside the project' {
        Set-Script 'Scripts\d.ps1' "Remove-Item (Join-Path `$PSScriptRoot '..\..\outside') -Recurse -Force`n"
        Test-DeleteScope $proj 'powershell -File Scripts/d.ps1' | Should Match 'outside the project'
        Test-DeleteNeedsPerson $proj 'powershell -File Scripts/d.ps1' | Should BeNullOrEmpty
    }
    It 'asks a person for a variable set more than once' {
        Set-Script 'Scripts\e.ps1' "`$t = 'dist'`n`$t = Read-Host`nRemove-Item `$t -Recurse`n"
        Test-DeleteNeedsPerson $proj 'powershell -File Scripts/e.ps1' | Should Match 'uses a variable'
    }
}

Describe 'Changing folder before deleting' {
    It 'follows a change to the project folder or a folder inside it' {
        Set-Script 'Scripts\f.ps1' "Set-Location (Split-Path -Parent `$PSScriptRoot)`nRemove-Item dist -Recurse -Force`n"
        Test-DeleteScope $proj 'powershell -File Scripts/f.ps1' | Should BeNullOrEmpty
        Set-Script 'Scripts\g.ps1' "Push-Location `$PSScriptRoot`nRemove-Item ..\dist -Recurse -Force`nPop-Location`nRemove-Item build -Recurse`n"
        Test-DeleteScope $proj 'powershell -File Scripts/g.ps1' | Should BeNullOrEmpty
    }
    It 'refuses after a change to a folder outside the project, and asks after one it cannot work out' {
        Test-DeleteScope $proj 'cd .. && del x.txt' | Should Match 'outside the project'
        Test-DeleteNeedsPerson $proj 'cd .. && del x.txt' | Should BeNullOrEmpty
        Set-Script 'Scripts\h.ps1' "Set-Location `$args[0]`nRemove-Item dist -Recurse`n"
        Test-DeleteNeedsPerson $proj 'powershell -File Scripts/h.ps1' | Should Match 'folder that cannot be worked out'
    }
    It 'treats a folder change inside a block as unknown afterwards, unless it leads outside' {
        Set-Script 'Scripts\i.ps1' "if (`$x) { Set-Location Scripts }`nRemove-Item dist -Recurse`n"
        Test-DeleteNeedsPerson $proj 'powershell -File Scripts/i.ps1' | Should Match 'folder that cannot be worked out'
        Set-Script 'Scripts\j.ps1' "if (`$x) { Set-Location .. }`nRemove-Item dist -Recurse`n"
        Test-DeleteScope $proj 'powershell -File Scripts/j.ps1' | Should Match 'outside the project'
        Test-DeleteNeedsPerson $proj 'powershell -File Scripts/j.ps1' | Should BeNullOrEmpty
    }
}

Describe 'Scripts started by scripts' {
    It 'checks a script another script starts, also through $PSScriptRoot' {
        Set-Script 'Scripts\k.ps1' "& `"`$PSScriptRoot\l.ps1`"`n"
        Set-Script 'Scripts\l.ps1' "Remove-Item ..\..\outside -Recurse`n"
        Test-DeleteScope $proj 'powershell -File Scripts/k.ps1' | Should Match 'Scripts/k\.ps1 starts the script Scripts/l\.ps1 deletes.*outside the project'
        @(Get-RunScripts $proj 'powershell -File Scripts/k.ps1' | ForEach-Object { $_.path }) | Should Be @('Scripts/k.ps1', 'Scripts/l.ps1')
    }
    It 'asks a person for a script whose name comes from a variable' {
        Set-Script 'Scripts\m.ps1' "& `$args[0]`n& `"`$tool.ps1`"`n"
        Test-DeleteNeedsPerson $proj 'powershell -File Scripts/m.ps1' | Should Match 'whose name comes from a variable'
    }
    It 'does not loop on a script that starts itself, and shows every script on the card' {
        Set-Script 'Scripts\n.ps1' "& `"`$PSScriptRoot\n.ps1`"`n& `"`$PSScriptRoot\o.ps1`"`n"
        Set-Script 'Scripts\o.ps1' "Write-Host 'o'`n"
        Test-DeleteScope $proj 'powershell -File Scripts/n.ps1' | Should BeNullOrEmpty
        $pv = Get-RunScriptPreview $proj 'powershell -File Scripts/n.ps1'
        $pv.path | Should Be 'Scripts/n.ps1'
        $pv.new | Should Match '# ---- Scripts/o\.ps1 \(started by the script above\) ----'
    }
}

Describe 'What reaches beyond the project (Get-RunEffects)' {
    $cases = [ordered]@{
        "Send-MailMessage -To a -From b -Subject c -SmtpServer d" = $null   # Microsoft 365: Get-CommandRisk on the script text
        "Set-Content C:\Windows\Temp\x.txt 'hi'" = 'writes or copies files outside the project'
        "'x' | Out-File `$env:TEMP\x.txt" = 'folder from the environment'
        "Get-Date > C:\log.txt" = 'writes or copies files outside the project'
        "& 'C:\tools\setup.ps1'" = 'starts a script outside the project'
        "Invoke-Expression (Get-Content x.txt -Raw)" = 'runs code it puts together'
        "iwr https://example.com/x.ps1 | iex" = 'runs code it puts together'
        "Add-Type -TypeDefinition `$code" = 'compiles and runs C# code'
        "Start-Process powershell -Verb RunAs" = 'administrator rights'
        "Set-ItemProperty HKCU:\Software\X -Name a -Value 1" = 'Windows registry'
        "Register-ScheduledTask -TaskName x -Action `$a" = 'scheduled task'
        "Set-ExecutionPolicy Bypass -Scope CurrentUser" = 'execution policy'
        "Install-Module ImportExcel -Scope CurrentUser" = 'installs or removes software'
        "Stop-Process -Name excel" = 'stops other programs'
        "[Environment]::SetEnvironmentVariable('X', '1', 'User')" = 'environment variables'
        "Invoke-RestMethod https://example.com/api -Method Post -Body `$json" = 'sends data to a web address'
    }
    $i = 0
    foreach ($k in $cases.Keys) {
        $i++
        $name = "Scripts\fx$i.ps1"
        It "finds: $k" {
            Set-Script $name ("Write-Host 'start'`n" + $k + "`n")
            $fx = @(Get-RunEffects $proj "powershell -File Scripts/fx$i.ps1")
            if ($cases[$k]) { ($fx -join '; ') | Should Match ([regex]::Escape($cases[$k]) + '.*\(in Scripts/fx' + $i + '\.ps1\)') }
            else { (Get-CommandRisk ([IO.File]::ReadAllText((Join-Path $proj $name)))).m365 | Should Be $true }
        }
    }
    It 'leaves ordinary build scripts, local test servers and reads alone' {
        Set-Script 'Scripts\ok.ps1' ("`$dist = Join-Path `$PSScriptRoot '..\dist'`nNew-Item -ItemType Directory -Force `$dist | Out-Null`nCopy-Item (Join-Path `$PSScriptRoot '..\index.html') `$dist`n" +
            "Get-ItemProperty HKCU:\Software\X -ErrorAction SilentlyContinue`nInvoke-RestMethod http://localhost:8080/api -Method Post -Body '{}'`nGet-Content data.csv > `$null`n'x' | Out-File (Join-Path `$PSScriptRoot 'log.txt')`n")
        @(Get-RunEffects $proj 'powershell -File Scripts/ok.ps1').Count | Should Be 0
        Set-Script 'Scripts\ok.js' "const re = /a/; re.exec('a');`nconsole.log(JSON.stringify({}));`n"
        @(Get-RunEffects $proj 'node Scripts/ok.js').Count | Should Be 0
    }
    It 'reads quoted markup in a page build script without failing on characters a path cannot hold' {
        # [IO.Path]::IsPathRooted throws on " < > | in 5.1: the quoted strings are not paths.
        Set-Script 'Scripts\page.ps1' ("param([string]`$OutputPath = (Join-Path `$PSScriptRoot '..\dist\index.html'))`n" +
            "`$parts = @('<html lang=""en"">', 'src=""js/app.js""', 'a|b')`n[IO.File]::WriteAllText(`$OutputPath, '<html lang=""en"">')`n" +
            "Set-Content -Path `$OutputPath -Value '<script src=""x"">' -Encoding UTF8`nRemove-Item (Join-Path `$PSScriptRoot '..\dist\old.html'); `$t = '<b>|</b>'`n")
        @(Get-RunEffects $proj 'powershell -File Scripts/page.ps1').Count | Should Be 0
        Test-DeleteScope $proj 'powershell -File Scripts/page.ps1' | Should BeNullOrEmpty
        Test-RootedPath '<html lang="en">' | Should Be $false
        Test-RootedPath 'C:\x' | Should Be $true
        Test-RootedPath '\\server\share' | Should Be $true
        Test-RootedPath 'dist\x' | Should Be $false
    }
    It 'finds code that starts programs or evaluates code in JavaScript and Python' {
        Set-Script 'Scripts\p.py' "import subprocess`nsubprocess.run(['x'])`n"
        (@(Get-RunEffects $proj 'python Scripts/p.py') -join ';') | Should Match 'starts other programs'
        Set-Script 'Scripts\q.js' "const code = 'x';`neval(code);`n"
        (@(Get-RunEffects $proj 'node Scripts/q.js') -join ';') | Should Match 'runs code it builds'
    }
    It 'checks the command line itself as well' {
        (@(Get-RunEffects $proj 'powershell -NoProfile -Command "Stop-Process -Name x"') -join ';') | Should Match 'stops other programs'
    }
}

Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
