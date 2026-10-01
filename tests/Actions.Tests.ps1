# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force

$fence3 = '```'
$fence4 = '````'

Describe 'Get-ActionBlocks' {
    It 'finds actions among prose and ignores ordinary code blocks' {
        $reply = @"
Let me look first.

${fence3}read
src/a.py
README.md
${fence3}

${fence3}python
print('not an action')
${fence3}
"@
        $a = @(Get-ActionBlocks $reply)
        $a.Count | Should Be 1
        $a[0].type | Should Be 'read'
        (Get-ActionPaths $a[0]) -join ',' | Should Be 'src/a.py,README.md'
    }

    It 'keeps inner ``` fences inside a four-backtick write block' {
        $reply = "${fence4}write docs/notes.md`n# Notes`n${fence3}bash`necho hi`n${fence3}`nend`n${fence4}"
        $a = @(Get-ActionBlocks $reply)
        $a.Count | Should Be 1
        $a[0].arg | Should Be 'docs/notes.md'
        $a[0].body | Should Be "# Notes`n${fence3}bash`necho hi`n${fence3}`nend"
    }

    It 'accepts write:path and parses several SEARCH/REPLACE pairs' {
        $reply = @"
${fence3}edit:src/app.py
<<<<<<< SEARCH
x = 1
=======
x = 2
>>>>>>> REPLACE
<<<<<<< SEARCH
def f(a):
    return a[0]
=======
def f(a):
    return a[-1]
>>>>>>> REPLACE
${fence3}
"@
        $a = @(Get-ActionBlocks $reply)
        $a[0].type | Should Be 'edit'
        $a[0].arg | Should Be 'src/app.py'
        $a[0].edits.Count | Should Be 2
        $a[0].edits[1].search | Should Be "def f(a):`n    return a[0]"
        $a[0].edits[1].replace | Should Be "def f(a):`n    return a[-1]"
    }

    It 'returns every action of a reply as a separate item (todo + write + run)' {
        $reply = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\multi-action-reply.md'))
        $a = @(Get-ActionBlocks $reply)
        $a.Count | Should Be 3
        ($a | ForEach-Object type) -join ',' | Should Be 'todo,write,run'
        $a[1].arg | Should Be 'hello.ps1'
        (Get-TodoItems $a[0].body).Count | Should Be 2
    }

    It 'keeps ``` fences inside SEARCH/REPLACE sections of a three-backtick edit block' {
        $reply = "${fence3}edit AGENTS.md`n<<<<<<< SEARCH`nShow total:`n=======`nAdd with a category:`n`n${fence3}powershell`n.\expenses.ps1 add 1 x --category food`n${fence3}`n`nShow total:`n>>>>>>> REPLACE`n${fence3}`n`n${fence3}run`necho after`n${fence3}"
        $a = @(Get-ActionBlocks $reply)
        ($a | ForEach-Object type) -join ',' | Should Be 'edit,run'
        $a[0].edits.Count | Should Be 1
        $a[0].edits[0].replace | Should Match ([regex]::Escape("${fence3}powershell`n.\expenses.ps1 add 1 x --category food`n${fence3}"))
    }

    It 'parses todo checklists' {
        $items = Get-TodoItems "- [x] scaffold`n- [ ] build`nnot an item"
        $items.Count | Should Be 2
        $items[0].done | Should Be $true
        $items[1].text | Should Be 'build'
    }
}

Describe 'Executor' {
    $proj = Join-Path $env:TEMP ('ccb-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $proj | Out-Null

    It 'refuses paths outside the project' {
        { Resolve-ProjectPath $proj '..\evil.txt' } | Should Throw
        { Resolve-ProjectPath $proj 'C:\Windows\x.txt' } | Should Throw
        Resolve-ProjectPath $proj 'src/ok.txt' | Should Be (Join-Path $proj 'src\ok.txt')
    }

    It 'writes a new file and records it in a checkpoint' {
        $cp = New-Checkpoint $proj
        Invoke-WriteAction $proj 'src/app.py' "def f(a):`n    return a[0]`n" $cp | Should Match 'wrote src/app.py'
        $cp.Files['src/app.py'] | Should Be 'new'
        (Get-Content (Join-Path $proj 'src\app.py') -Raw) | Should Match 'return a\[0\]'
    }

    It 'edits an existing CRLF file and keeps CRLF' {
        [IO.File]::WriteAllText((Join-Path $proj 'win.txt'), "one`r`ntwo`r`nthree`r`n")
        $cp = New-Checkpoint $proj
        Invoke-EditAction $proj 'win.txt' @(@{ search = "two"; replace = "TWO" }) $cp | Should Match 'edited win.txt'
        [IO.File]::ReadAllText((Join-Path $proj 'win.txt')) | Should BeExactly "one`r`nTWO`r`nthree`r`n"
    }

    It 'rejects an ambiguous or missing SEARCH and writes nothing' {
        [IO.File]::WriteAllText((Join-Path $proj 'dup.txt'), "a`na`n")
        (Get-EditResult $proj 'dup.txt' @(@{ search = 'a'; replace = 'b' })).error | Should Match 'more than once'
        (Get-EditResult $proj 'dup.txt' @(@{ search = 'zzz'; replace = 'b' })).error | Should Match 'not found'
        [IO.File]::ReadAllText((Join-Path $proj 'dup.txt')) | Should BeExactly "a`na`n"
    }

    It 'undoes the last checkpoint (restores edits, deletes new files)' {
        Undo-LastCheckpoint $proj | Should Be 'win.txt'
        [IO.File]::ReadAllText((Join-Path $proj 'win.txt')) | Should BeExactly "one`r`ntwo`r`nthree`r`n"
        Undo-LastCheckpoint $proj | Should Be 'src/app.py'
        Test-Path (Join-Path $proj 'src\app.py') | Should Be $false
    }

    It 'globs, greps and runs commands' {
        Invoke-WriteAction $proj 'lib/x.ps1' "Write-Output 'needle'`n" $null | Out-Null
        Invoke-GlobAction $proj '**/*.ps1' | Should Match 'lib/x.ps1'
        Invoke-GrepAction $proj 'needle' '*.ps1' | Should Match 'lib/x.ps1:1:'
        $r = Invoke-RunAction $proj 'echo hello && exit /b 3'
        $r.output | Should Be 'hello'
        $r.exitCode | Should Be 3
    }

    It 'matches a SEARCH that Copilot wrote with &lt; &gt; entities and writes real angle brackets' {
        [IO.File]::WriteAllText((Join-Path $proj 'cli.ps1'), "Write-Host ""Commands: add <amount> <description>, list""`n")
        $edits = @(@{ search = 'Write-Host "Commands: add &lt;amount&gt; &lt;description&gt;, list"'; replace = 'Write-Host "Commands: add &lt;amount&gt; &lt;description&gt; [--category &lt;name&gt;], list"' })
        Invoke-EditAction $proj 'cli.ps1' $edits $null | Should Match 'edited cli.ps1'
        [IO.File]::ReadAllText((Join-Path $proj 'cli.ps1')) | Should BeExactly "Write-Host ""Commands: add <amount> <description> [--category <name>], list""`n"
    }

    It 'decodes entities in written code but leaves markup files alone' {
        Invoke-WriteAction $proj 'gen.ps1' 'if ($a -lt 1) { "x &lt; y" }' $null | Out-Null
        [IO.File]::ReadAllText((Join-Path $proj 'gen.ps1')) | Should BeExactly "if (`$a -lt 1) { ""x < y"" }`n"
        Invoke-WriteAction $proj 'page.html' '<p>a &lt; b</p>' $null | Out-Null
        [IO.File]::ReadAllText((Join-Path $proj 'page.html')) | Should BeExactly "<p>a &lt; b</p>`n"
    }

    It 'keeps source/ read-only: refuses write and edit, restores changes made by commands' {
        $ms = New-Object IO.MemoryStream (,[Text.Encoding]::UTF8.GetBytes("id,amount`n1,10`n"))
        Save-SourceFile $proj 'bank.csv' $ms | Should Be 'source/bank.csv'
        $ms2 = New-Object IO.MemoryStream (,[Text.Encoding]::UTF8.GetBytes("other`n"))
        Save-SourceFile $proj 'bank.csv' $ms2 | Should Be 'source/bank (2).csv'   # never overwrites

        { Invoke-WriteAction $proj 'source/bank.csv' 'x' $null } | Should Throw
        (Get-EditResult $proj 'source/bank.csv' @(@{ search = '1,10'; replace = '1,99' })).error | Should Match 'read-only'

        # A command deletes one file, changes another and drops a new file into source/.
        $r = Invoke-RunAction $proj 'del /f /q "source\bank.csv" && attrib -r "source\bank (2).csv" && echo changed> "source\bank (2).csv" && echo new> "source\extra.txt"'
        $fixed = @(Restore-SourceData $proj)
        $fixed.Count | Should Be 3
        [IO.File]::ReadAllText((Join-Path $proj 'source\bank.csv')) | Should BeExactly "id,amount`n1,10`n"
        [IO.File]::ReadAllText((Join-Path $proj 'source\bank (2).csv')) | Should BeExactly "other`n"
        Test-Path (Join-Path $proj 'source\extra.txt') | Should Be $false
        Test-Path (Join-Path $proj 'work\extra.txt') | Should Be $true
        (New-Object IO.FileInfo (Join-Path $proj 'source\bank.csv')).IsReadOnly | Should Be $true
        @(Restore-SourceData $proj).Count | Should Be 0
        Get-ChildItem (Join-Path $proj 'source') -File | ForEach-Object { $_.IsReadOnly = $false }
    }

    It 'stops a running command at once when cancelled, including its child processes' {
        $start = Get-Date
        $flag = @{ stop = $false }
        $timer = New-Object Timers.Timer 1000
        $timer.AutoReset = $false
        Register-ObjectEvent $timer Elapsed -Action { $Event.MessageData.stop = $true } -MessageData $flag | Out-Null
        $timer.Start()
        $r = Invoke-RunAction $proj 'ping -n 30 127.0.0.1' -TimeoutSec 60 -CancelCheck ({ $flag.stop }.GetNewClosure())
        $elapsed = ((Get-Date) - $start).TotalSeconds
        $r.cancelled | Should Be $true
        $r.exitCode | Should Be $null
        $elapsed -lt 8 | Should Be $true
        @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -match '-n 30 127\.0\.0\.1' }).Count | Should Be 0
        Get-EventSubscriber | Unregister-Event
    }

    It 'reads files with a four-backtick fence' {
        (Invoke-ReadAction $proj @('lib/x.ps1')) | Should Match "(?s)### lib/x.ps1\n${fence4}\nWrite-Output 'needle'"
    }

    Remove-Item $proj -Recurse -Force
    Remove-Item (Get-ProjectStateDir $proj) -Recurse -Force -ErrorAction SilentlyContinue
}
