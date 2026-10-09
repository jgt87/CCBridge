# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# Encodings, line endings, file-type defaults and Copilot's text artifacts. ASCII only: special
# characters are written as [char] codes.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

$e_acute = [string][char]0x00E9   # e with an accent
$omega = [string][char]0x03A9      # not in the Windows code page
$zwsp = [string][char]0x200B; $nbsp = [string][char]0x00A0; $ldq = [string][char]0x201C; $rdq = [string][char]0x201D
$ansi = [Text.Encoding]::Default

function New-Dir { $p = Join-Path $env:TEMP ('ccb-enc-' + [guid]::NewGuid().ToString('N')); $null = New-Item -ItemType Directory -Path $p; $p }

Describe 'Reading and writing keep the file''s encoding' {
    $p = New-Dir
    It 'reads an ANSI file correctly and writes an edit back in ANSI' {
        $f = Join-Path $p 'menu.txt'
        [IO.File]::WriteAllBytes($f, $ansi.GetBytes("Caf$e_acute`r`nTea`r`n"))
        $i = Read-TextFile $f
        $i.Encoding | Should Be 'ansi'
        $i.Text | Should Be "Caf$e_acute`nTea`n"
        $i.Crlf | Should Be $true
        $null = Invoke-EditAction $p 'menu.txt' @(@{ search = 'Tea'; replace = 'Green tea' }) $null
        [IO.File]::ReadAllBytes($f) -join ',' | Should Be (($ansi.GetBytes("Caf$e_acute`r`nGreen tea`r`n")) -join ',')
    }
    It 'reads and keeps UTF-16 with its BOM (not treated as binary)' {
        $f = Join-Path $p 'data.txt'
        [IO.File]::WriteAllText($f, "one`r`ntwo`r`n", (New-Object Text.UnicodeEncoding($false, $true)))
        Test-BinaryFile $f | Should Be $false
        (Read-TextFile $f).Encoding | Should Be 'utf16le'
        $null = Invoke-EditAction $p 'data.txt' @(@{ search = 'two'; replace = 'three' }) $null
        $b = [IO.File]::ReadAllBytes($f)
        "$($b[0]),$($b[1])" | Should Be '255,254'
        (Read-TextFile $f).Text | Should Be "one`nthree`n"
    }
    It 'keeps a UTF-8 BOM' {
        $f = Join-Path $p 'x.ps1'
        [IO.File]::WriteAllText($f, "'a'`n", (New-Object Text.UTF8Encoding($true)))
        $null = Invoke-EditAction $p 'x.ps1' @(@{ search = "'a'"; replace = "'b'" }) $null
        (Read-TextFile $f).Encoding | Should Be 'utf8bom'
    }
    It 'uses the line ending most lines have' {
        $f = Join-Path $p 'mixed.txt'
        [IO.File]::WriteAllText($f, "a`r`nb`r`nc`n")
        (Read-TextFile $f).Crlf | Should Be $true
        [IO.File]::WriteAllText($f, "a`nb`nc`r`n")
        (Read-TextFile $f).Crlf | Should Be $false
    }
    cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
}

Describe 'New files get the format their type needs' {
    $p = New-Dir
    It 'PowerShell with non-ASCII gets a BOM, plain PowerShell does not' {
        (Get-NewFileFormat 'a.ps1' "Write-Host 'caf$e_acute'" $p).Bom | Should Be $true
        (Get-NewFileFormat 'a.psm1' "Write-Host 'cafe'" $p).Bom | Should Be $false
    }
    It 'batch files get CRLF and no BOM; CSV gets a BOM; JSON never' {
        $cmd = Get-NewFileFormat 'run.cmd' '@echo off' $p
        "$($cmd.Crlf) $($cmd.Bom)" | Should Be 'True False'
        (Get-NewFileFormat 'out.csv' 'a;b' $p).Bom | Should Be $true
        (Get-NewFileFormat 'data.json' "{ ""name"": ""caf$e_acute"" }" $p).Bom | Should Be $false
    }
    It 'writes a new PowerShell file with non-ASCII so Windows PowerShell 5.1 reads it right' {
        $null = Invoke-WriteAction $p 'hello.ps1' "Write-Host 'caf$e_acute'" $null
        $b = [IO.File]::ReadAllBytes((Join-Path $p 'hello.ps1'))
        "$($b[0]),$($b[1]),$($b[2])" | Should Be '239,187,191'
    }
    It 'follows the line endings most project files use' {
        [IO.File]::WriteAllText((Join-Path $p 'one.js'), "a`r`nb`r`n")
        [IO.File]::WriteAllText((Join-Path $p 'two.js'), "a`r`nb`r`n")
        (Get-NewFileFormat 'three.js' 'x' $p).Crlf | Should Be $true
    }
    cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
}

Describe 'Copilot''s text artifacts' {
    It 'removes invisible characters and odd spaces from code, not from prose' {
        Repair-CodeText 'app.js' "const a$zwsp =${nbsp}1;" | Should BeExactly 'const a = 1;'
        Repair-CodeText 'notes.md' "a$zwsp b${nbsp}c" | Should BeExactly "a$zwsp b${nbsp}c"
    }
    It 'reports what it found: removed characters and curly quotes by line' {
        $r = Find-CodeArtifacts 'app.js' "const a = 1;`nconst b = ${ldq}x${rdq};$zwsp`n"
        $r.removed | Should Be 1
        @($r.curlyLines) -join ',' | Should Be '2'
        (Find-CodeArtifacts 'page.md' "${ldq}quote${rdq}").curlyLines.Count | Should Be 0
    }
}

Describe 'Test-EncodingFit' {
    It 'keeps batch files ASCII' {
        Test-EncodingFit 'run.cmd' '' "echo caf$e_acute" 'utf8' | Should Match 'plain ASCII; line 1'
        Test-EncodingFit 'run.cmd' '' 'echo cafe' 'utf8' | Should BeNullOrEmpty
    }
    It 'refuses characters an ANSI file cannot hold' {
        Test-EncodingFit 'menu.txt' '' "caf$e_acute" 'ansi' | Should BeNullOrEmpty
        Test-EncodingFit 'menu.txt' '' "a`n$omega" 'ansi' | Should Match 'code page.*line 2'
    }
    It 'refuses a new replacement character (garbled text)' {
        Test-EncodingFit 'a.js' 'x' ("x" + [char]0xFFFD) 'utf8' | Should Match 'replacement character'
        Test-EncodingFit 'a.js' ("x" + [char]0xFFFD) ("y" + [char]0xFFFD) 'utf8' | Should BeNullOrEmpty
    }
}

Describe 'StreamHub''s own files' {
    It 'keeps all PowerShell files ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        # temp\ is git-ignored scratch space (test projects made with StreamHub), not StreamHub's own files.
        $scratch = Join-Path $root 'temp\'
        $bad = foreach ($f in @(Get-ChildItem $root -Recurse -Include *.ps1, *.psm1, *.psd1 -File | Where-Object { $_.FullName -notmatch '\\(node_modules|dist|\.git)\\' -and -not $_.FullName.StartsWith($scratch, [StringComparison]::OrdinalIgnoreCase) })) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            if (@($b | Where-Object { $_ -gt 127 }).Count) { $f.FullName.Substring($root.Length + 1) }
        }
        @($bad) -join ', ' | Should BeNullOrEmpty
    }
    It 'keeps the config JSON files free of a BOM' {
        $bad = foreach ($f in @(Get-ChildItem (Join-Path $root 'config') -Filter *.json -File)) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $f.Name }
        }
        @($bad) -join ', ' | Should BeNullOrEmpty
    }
}
