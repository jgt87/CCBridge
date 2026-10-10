# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# Hard boundary: files may only be deleted or moved inside the project folder.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

$base = Join-Path $env:TEMP ('ccb-scope-' + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $base 'proj'
$outside = Join-Path $base 'outside'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'build'), (Join-Path $proj 'inner'), $outside
[IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'keep')
[IO.File]::WriteAllText((Join-Path $proj 'clean-ok.ps1'), "Remove-Item build -Recurse -Force`n")
[IO.File]::WriteAllText((Join-Path $proj 'clean-bad.ps1'), "Write-Host 'cleaning'`nRemove-Item ..\outside -Recurse -Force`n")
[IO.File]::WriteAllText((Join-Path $proj 'tidy.py'), "import shutil`nshutil.rmtree('C:/Users/someone/Documents')`n")
# A browser script: "remove" is a DOM method and "//" starts a comment; nothing in it touches files.
[IO.File]::WriteAllText((Join-Path $proj 'kit.js'), "// the kit`nfunction clear(el) { el.querySelectorAll('.old').forEach(n => n.remove()); }`nconst sep = '//'; const path = 'a/b';`nmove(1, 2);`n")
[IO.File]::WriteAllText((Join-Path $proj 'wipe.js'), "const fs = require('fs');`nfs.rmSync('../outside', { recursive: true });`n")
$null = New-Item -ItemType Junction -Path (Join-Path $proj 'link') -Target $outside
$null = New-Item -ItemType Junction -Path (Join-Path $proj 'innerlink') -Target (Join-Path $proj 'inner')

Describe 'Test-DeleteScope: allowed inside the project' {
    $ok = @(
        'npm run build',
        'del build\out.txt',
        'rd /s /q build',
        'del /f /q "build\my file.txt"',
        'Remove-Item -Recurse -Force build',
        'Get-ChildItem build -Filter *.tmp | Remove-Item -Force',
        'robocopy src dist /MIR /NFL',
        'move a.txt archive\a.txt',
        'git clean -fd',
        "rm -rf dist",
        "python -c ""import os; os.remove('build/x.txt')""",
        "Remove-Item ""$proj\build\x.txt""",
        'Remove-Item innerlink\x.txt',
        'powershell -File clean-ok.ps1',
        'node --check kit.js',
        'node kit.js'
    )
    foreach ($c in $ok) {
        It "allows: $c" { Test-DeleteScope $proj $c | Should BeNullOrEmpty }
    }
}

Describe 'Test-DeleteScope: refused outside the project' {
    $bad = @{
        'del ..\x.txt' = 'outside the project'
        'node wipe.js' = 'outside the project'
        'rd /s /q C:\Users' = 'outside the project'
        'move a.txt ..\a.txt' = 'outside the project'
        'robocopy src C:\backup /MIR' = 'outside the project'
        'Remove-Item $env:TEMP\x -Recurse' = 'variable'
        'del %TEMP%\x' = 'variable'
        'rm -rf ~' = 'variable'
        'rm -rf /' = 'outside the project'
        'rd /s /q .' = 'project folder itself'
        'cd .. && del x.txt' = 'changes folder'
        'git -C .. clean -fd' = 'outside the project|another folder'
        'Remove-Item -Recurse link\keep.txt' = 'link'
        'rd /s /q link' = 'link'
        "python -c ""import shutil; shutil.rmtree('C:/data')""" = 'outside the project'
        "python -c ""import os; os.remove(os.path.expanduser('~/x'))""" = 'environment'
        'powershell -enc SQBFAFgAIAAoAE4AZQB3AC0ATwBiAGoAZQBjAHQAIABOAGUAdAA=' = 'encoded'
        'powershell -File clean-bad.ps1' = 'clean-bad.ps1.*outside'
        'python tidy.py' = 'tidy.py.*outside'
    }
    foreach ($c in $bad.Keys) {
        It "refuses: $c" { Test-DeleteScope $proj $c | Should Match $bad[$c] }
    }
}

Describe 'Resolve-ProjectPath and links' {
    It 'refuses a path through a junction that leads outside' {
        { Resolve-ProjectPath $proj 'link\keep.txt' } | Should Throw 'link'
    }
    It 'allows a junction that stays inside the project' {
        Resolve-ProjectPath $proj 'innerlink\x.txt' | Should Be (Join-Path $proj 'innerlink\x.txt')
    }
    It 'left the outside folder alone' {
        Test-Path (Join-Path $outside 'keep.txt') | Should Be $true
    }
}

# Remove the junctions as links (cmd rmdir), never through them.
cmd /c "rmdir ""$proj\link"" >nul 2>&1"
cmd /c "rmdir ""$proj\innerlink"" >nul 2>&1"
cmd /c "rmdir /s /q ""$base"" >nul 2>&1"

Describe 'Test-DeleteScope: nothing hides a delete' {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Remove-Item C:\Users\x\Documents\y -Recurse'))
    It 'refuses every abbreviation of -EncodedCommand, and the risk check names it' {
        foreach ($sw in '-e', '-ec', '-en', '-enco', '-encoded', '-EncodedCommand') {
            Test-DeleteScope $proj "powershell -NoProfile $sw $b64" | Should Match 'encoded command'
            (Get-CommandRisk "powershell $sw $b64").destructive | Should Be $true
        }
        Test-DeleteScope $proj 'powershell -ExecutionPolicy Bypass -ErrorAction SilentlyContinue -File Scripts\x.ps1' | Should BeNullOrEmpty
    }
    It 'checks what a shell inside the command runs' {
        Test-DeleteScope $proj "cmd /c `"rd /s /q $outside`"" | Should Match 'outside the project'
        Test-DeleteScope $proj 'cmd /c "del ..\..\x.txt"' | Should Match 'outside the project'
        Test-DeleteScope $proj 'powershell -c "gci ..\.. | ri -Force"' | Should Match 'outside the project'
        Test-DeleteScope $proj 'powershell -Command "Remove-Item ..\..\other -Recurse -Force"' | Should Match 'outside|dot or space'
        Test-DeleteScope $proj 'bash -c "rm -rf ../../x"' | Should Match 'outside the project'
        Test-DeleteScope $proj 'cmd /c "rd /s /q build"' | Should BeNullOrEmpty
        Test-DeleteScope $proj 'powershell -Command "Remove-Item build -Recurse -Force"' | Should BeNullOrEmpty
        Test-DeleteScope $proj 'cmd /c "npm run build"' | Should BeNullOrEmpty
    }
    It 'refuses a name ending in a dot or space, which Windows reads differently' {
        Test-DeleteScope $proj 'del "build\x. "' | Should Match 'dot or space'
        Test-DeleteScope $proj 'del build\x.txt' | Should BeNullOrEmpty
    }
}
