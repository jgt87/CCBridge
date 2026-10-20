# The app's file viewer and large files (Executor Get-FileViewText): a file within the limit comes
# whole, a larger one as its first part with a note, cut at a line end when it has lines.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

Describe 'Get-FileViewText' {
    $p = Join-Path $env:TEMP ('ccb-view-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    It 'gives a small file whole and a large one as its first lines with a note' {
        [IO.File]::WriteAllText((Join-Path $p 'small.js'), "const a = 1;`nconst b = 2;`n")
        $v = Get-FileViewText (Join-Path $p 'small.js')
        $v.truncated | Should Be $false
        $v.text | Should Be "const a = 1;`nconst b = 2;`n"
        $v.note | Should Be ''
        $lines = 1..5000 | ForEach-Object { '{"id": ' + $_ + ', "name": "' + ('x' * 60) + '"},' }
        [IO.File]::WriteAllText((Join-Path $p 'data.js'), ("window.rows = [`n" + ($lines -join "`n") + "`n];`n"))
        $v = Get-FileViewText (Join-Path $p 'data.js') -Limit 100KB -Cap 20KB
        $v.truncated | Should Be $true
        $v.text.Length | Should BeLessThan 20481
        $v.text.EndsWith("`n") | Should Be $true
        $v.note | Should Match '^Showing the first \d+ of 5003 lines \(\d+ KB of \d+ KB\): the file is larger than 100 KB'
    }
    It 'cuts a file that is one long line by size and says so' {
        [IO.File]::WriteAllText((Join-Path $p 'one.js'), ('window.rows = [' + (('{"a":1},' * 30000)) + '];'))
        $v = Get-FileViewText (Join-Path $p 'one.js') -Limit 100KB -Cap 20KB
        $v.truncated | Should Be $true
        $v.text.Length | Should Be 20480
        $v.note | Should Match 'on one line: the file is larger than'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Reads of folders and of files that are not there' {
    $p = Join-Path $env:TEMP ('ccb-readnf-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p 'js') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'js\app.js'), "var a = 1;`n")
    [IO.File]::WriteAllText((Join-Path $p 'data.csv'), "a,b`n1,2`n")
    It 'lists a folder instead of refusing it, and names what exists when a file is missing' {
        $root = (Invoke-ReadAction $p @('.')) -join "`n"
        $root | Should Match '^### \.\n\(a folder with 2 file\(s\)\)'
        $root | Should Match 'js/app\.js \(\d+ bytes\)'
        (Invoke-ReadAction $p @('js')) -join "`n" | Should Match '\(a folder with 1 file\(s\)\)\n```\njs/app\.js'
        $nf = (Invoke-ReadAction $p @('app.js')) -join "`n"
        $nf | Should Match '^### app\.js\n\(file not found: the project has no app\.js\. A file with that name is at: js/app\.js\. Create it with a write action if it should exist\.\)'
        (Invoke-ReadAction $p @('README.md')) -join "`n" | Should Match "The project's files: data\.csv, js/app\.js\."
        (Invoke-ReadAction $p @('README.md:outline')) -join "`n" | Should Match 'file not found: the project has no README\.md'
    }
    It 'lists a folder whose name starts with a dot, and one written with ./' {
        New-Item -ItemType Directory (Join-Path $p '.github\workflows') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $p '.github\workflows\ci.yml'), "on: push`n")
        (Invoke-ReadAction $p @('.github/workflows')) -join "`n" | Should Match '\(a folder with 1 file\(s\)\)\n```\n\.github/workflows/ci\.yml'
        (Invoke-ReadAction $p @('.github')) -join "`n" | Should Match '\(a folder with 1 file\(s\)\)'
        (Invoke-ReadAction $p @('./js/')) -join "`n" | Should Match '\(a folder with 1 file\(s\)\)\n```\njs/app\.js'
    }
    It 'says a project without files has none yet' {
        $q = Join-Path $env:TEMP ('ccb-readempty-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $q | Out-Null
        (Invoke-ReadAction $q @('.')) -join "`n" | Should Match 'the project has no files yet\. Create them with write actions'
        (Invoke-ReadAction $q @('index.html')) -join "`n" | Should Match "The project's files: none yet\."
        Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
