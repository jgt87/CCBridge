# Run commands and PowerShell files from Copilot: [Type\]:: put back (Copilot's page escapes brackets
# that look like a Markdown link definition), and scripts packed into one powershell -Command line are
# not run but written as a script file. The command below is the shape a real failing one had.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Repair-EscapedTypeName' {
    It 'puts escaped .NET type names before :: back, and leaves everything else alone' {
        Repair-EscapedTypeName '$n = [regex\]::Match($f.Name, ''day-(\d{2})'')' | Should Be '$n = [regex]::Match($f.Name, ''day-(\d{2})'')'
        Repair-EscapedTypeName '\[IO.File]::ReadAllText($p)' | Should Be '[IO.File]::ReadAllText($p)'
        Repair-EscapedTypeName '[System.Text.RegularExpressions.Regex\]::Escape($s)' | Should Be '[System.Text.RegularExpressions.Regex]::Escape($s)'
        Repair-EscapedTypeName '[regex]::Match($a, ''x'')' | Should Be '[regex]::Match($a, ''x'')'
        Repair-EscapedTypeName '$t -match ''\[note\]'' -and $u -match ''a\]b''' | Should Be '$t -match ''\[note\]'' -and $u -match ''a\]b'''
        Repair-EscapedTypeName '' | Should Be ''
    }
    It 'is applied to PowerShell files and run commands' {
        Repair-CodeText 'Scripts\fix.ps1' 'Write-Host ([math\]::Round(1.5))' | Should Be 'Write-Host ([math]::Round(1.5))'
        Repair-CodeText 'notes.md' 'Use [regex\]:: in text' | Should Be 'Use [regex\]:: in text'
        Repair-RunCommand 'powershell -Command "[regex\]::Escape(''a'') 2&gt;nul"' | Should Be 'powershell -Command "[regex]::Escape(''a'') 2>nul"'
    }
}

Describe 'Scripts packed into one powershell -Command line' {
    $long = 'powershell -NoProfile -ExecutionPolicy Bypass -Command "$files = Get-ChildItem ''Runbooks/day-*.runbook.md''; foreach($f in $files){ $n = [regex\]::Match($f.Name,''day-(\d{2})'').Groups[1].Value; $c = Get-Content $f.FullName -Raw; $c = $c -replace ''Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday'',''day ''+$n; $c = $c -replace ''(output: Runbooks/Exports/)[^\r\n]+'',''$1day-''+$n+''.json''; Set-Content $f.FullName $c }; Write-Host done"'
    It 'recognises them, and leaves short commands and script files alone' {
        Test-LongPowerShellCommand $long | Should Match 'PowerShell command line of \d+ characters'
        Test-LongPowerShellCommand 'powershell -NoProfile -Command "Get-Date"' | Should BeNullOrEmpty
        Test-LongPowerShellCommand 'powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/fix-runbooks.ps1' | Should BeNullOrEmpty
        Test-LongPowerShellCommand ('npm run build ' + ('x' * 400)) | Should BeNullOrEmpty
    }
    It 'are not run; Copilot is asked for a script file instead' {
        $p = Join-Path $env:TEMP ('ccb-runrep-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $r = & (Get-Module Agent) { param($st, $cmd) Invoke-AgentAction $st ([pscustomobject]@{ type = 'run'; arg = ''; body = $cmd }) 'a1' $null 0 } $s $long
        $r.ok | Should Be $false
        $r.output | Should Match 'Work/NAME\.ps1 for a one-off job'
        $r.output | Should Match 'Scripts/NAME\.ps1 if it is worth keeping'
        $r.output | Should Match '-File Work/NAME\.ps1'
        @($s.Events | Where-Object { $_.type -eq 'action' -and $_.status -eq 'skipped' }).Count | Should Be 1
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Describe 'Quotes cmd.exe ends early (\" inside a quoted argument)' {
    It 'finds a | & < or > that cmd would take as its own' {
        # Seen: a regex with | inside powershell -Command "...": cmd ran 'fetch\' as a command.
        $seen = 'powershell -NoProfile -Command "$t = Get-Content -Raw ''Work\app.js''; [regex]::Matches($t, \"fetch\(|axios\") | ForEach-Object { $_.Value }"'
        Get-CmdQuoteBreak $seen | Should Match 'reaches cmd as a pipe'
        Get-CmdQuoteBreak 'python -c "print(\"a|b\")"' | Should Match 'as a pipe'
        Get-CmdQuoteBreak 'node -e "console.log(\"a > b\")"' | Should Match 'as a redirection'
    }
    It 'leaves commands whose quotes cmd reads the same way alone' {
        Get-CmdQuoteBreak 'powershell -NoProfile -Command "Get-ChildItem | Select-Object Name"' | Should BeNullOrEmpty
        Get-CmdQuoteBreak 'node -e "console.log(\"a\")" && echo ok' | Should BeNullOrEmpty
        Get-CmdQuoteBreak 'git log --oneline | findstr fix' | Should BeNullOrEmpty
        Get-CmdQuoteBreak 'python -c "print(\"done\")"' | Should BeNullOrEmpty
    }
}

Describe 'Web pages read by a command go to the web action' {
    It 'finds commands and scripts that read a public page, script or JSON themselves' {
        Get-WebDownloadCommand 'curl.exe -L --max-time 30 -sS https://items.example.com/ -o Work\items-home.html' | Should Match 'reads https://items\.example\.com/ from the internet'
        Get-WebDownloadCommand 'powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing https://items.example.com/app.js -OutFile Work\app.js"' | Should Match 'items\.example\.com/app\.js'
        Get-WebDownloadCommand 'powershell -NoProfile -Command "irm https://api.example.com/v1/items"' | Should Match 'api\.example\.com'
        Get-WebDownloadCommand 'python -c "import urllib.request; print(urllib.request.urlopen(''https://items.example.com/'').read())"' | Should Not BeNullOrEmpty
        $p = Join-Path $env:TEMP ('ccb-webdl-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p 'Work') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'Work\get.ps1'), '$r = Invoke-WebRequest -UseBasicParsing "https://items.example.com/data"; $r.Content')
        Get-WebDownloadCommand 'powershell -NoProfile -ExecutionPolicy Bypass -File Work\get.ps1' $p | Should Match '^the script Work\\get\.ps1 reads https://items\.example\.com/data'
        Remove-Item $p -Recurse -Force
    }
    It 'leaves local servers, binary downloads, package managers and other commands alone' {
        Get-WebDownloadCommand 'curl -s http://localhost:5173/' | Should BeNullOrEmpty
        Get-WebDownloadCommand 'curl -sS http://127.0.0.1:8080/api/items' | Should BeNullOrEmpty
        Get-WebDownloadCommand 'curl -L -o Work\tool.zip https://downloads.example.com/tool-1.2.zip' | Should BeNullOrEmpty
        Get-WebDownloadCommand 'npm install --no-fund --no-audit' | Should BeNullOrEmpty
        Get-WebDownloadCommand 'git log --oneline' | Should BeNullOrEmpty
        Get-WebDownloadCommand 'node --test tests/*.test.js' | Should BeNullOrEmpty
    }
    It 'is not run; Copilot is pointed to ACTION web and ACTION web source' {
        $p = Join-Path $env:TEMP ('ccb-webdl2-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $r = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'run'; arg = ''; body = 'curl.exe -sS https://items.example.com/ -o Work\home.html' }) 'a1' $null 0 } $s
        $r.ok | Should Be $false
        $r.summary | Should Be 'run skipped (web page read by a command)'
        $r.output | Should Match 'ACTION web source'
        Remove-Item $p -Recurse -Force
    }
}

Describe 'Working folders a command writes into' {
    It 'are made before the command runs' {
        $p = Join-Path $env:TEMP ('ccb-workdir-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $s.Config.autoApproveCommands = @('^echo(\s|$)')
        $r = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'run'; arg = ''; body = 'echo made> Work\out.txt' }) 'a1' $null 0 } $s
        $r.ok | Should Be $true
        (Test-Path -LiteralPath (Join-Path $p 'Work\out.txt')) | Should Be $true
        Remove-Item $p -Recurse -Force
    }
}

Describe 'A type name the chat removed in front of ::' {
    It 'is found in PowerShell, and ordinary colons are left alone' {
        Find-RemovedTypeName '$m = :Match($t, "x")' | Should Be '$m = :Match($t, "x")'
        Find-RemovedTypeName "foreach (`$f in `$files) { `$n = :Escape(`$f.Name) }" | Should Not BeNullOrEmpty
        Find-RemovedTypeName '$m = [regex]::Match($t, "x")' | Should BeNullOrEmpty
        Find-RemovedTypeName '$p = Join-Path C:	emp x; $script:Count = 1' | Should BeNullOrEmpty
        Find-RemovedTypeName ':outer foreach ($x in $y) { break outer }' | Should BeNullOrEmpty
        Find-RemovedTypeName '"{0:N2}" -f $x; Write-Host "at: (now)"' | Should BeNullOrEmpty
        Find-RemovedTypeName "if (`$name -match 'day-(\d{2})') { `$Matches[1] }" | Should BeNullOrEmpty
    }
    It 'stops a PowerShell command or file change before it runs or is written' {
        $p = Join-Path $env:TEMP ('ccb-rmtype-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $r = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'run'; arg = ''; body = 'powershell -NoProfile -Command "$m = :Match(''day-01'',''\d+''); $m.Value"' }) 'a1' $null 0 } $s
        $r.ok | Should Be $false
        $r.output | Should Match "\(\[regex\]'PATTERN'\)\.Match\(TEXT\)"
        $w = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'write'; arg = 'Work/fix.ps1'; body = '$n = :Match($name, "x").Value'; content = '$n = :Match($name, "x").Value'; closed = $true }) 'a2' $null 0 } $s
        $w.ok | Should Be $false
        Test-Path (Join-Path $p 'Work\fix.ps1') | Should Be $false
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Describe 'Where scripts go' {
    Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
    It 'tells Copilot: one-off scripts in Work/, scripts to keep in Scripts/, run with -File' {
        Get-PromptPart $root 'rules:folders' | Should Match 'Helper scripts to keep go in Scripts/, one-off scripts in Work/'
        Get-PromptPart $root 'rules:environment' | Should Match 'one-off in Work/, kept in Scripts/\) run with powershell -NoProfile -ExecutionPolicy Bypass -File'
        Get-PromptPart $root 'rules:web' | Should Match 'text block, not ```html'
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
