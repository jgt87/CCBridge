# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# The mistakes that commonly break each file type: every type has a correct sample (no problems)
# and its typical breakages (each must be found, at the right line). ASCII only.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force

function T([string]$s) { $s.Replace("`r`n", "`n") }
$bt = '```'

$good = @{
    'app.js' = T @'
// totals
function total(items) {
  const label = `Total: ${items.length}`;
  return items.reduce((a, b) => a + b.price, 0);
}
export const fmt = (x) => "$" + x.toFixed(2);
'@
    'app.tsx' = T @'
export function Hello({ name }: { name: string }) {
  return <p>Don't worry, {name}</p>;
}
'@
    'main.py' = T @'
import os


class Cart:
    def __init__(self):
        self.items = []

    def add(self, item,
            qty=1):
        if qty > 0:
            self.items.append((item, qty))
        else:
            raise ValueError("qty must be positive")


def main():
    """Entry point."""
    for x in [1, 2]:
        print(f"{x}")
'@
    'tool.ps1' = T @'
function Get-Total {
    param([int[]]$Values)
    $sum = 0
    foreach ($v in $Values) { $sum += $v }
    Write-Output $sum
}
Get-Total -Values 1, 2
'@
    'config.yml' = T @'
name: site
build:
  command: "npm run build"
  dirs: [src, public]
notes: |
  free text: anything here
  even: name:value
items:
  - id: 1
    title: one
  - id: 2
    title: two
'@
    'data.json' = T @'
{ "name": "x", "list": [1, 2, 3], "nested": { "ok": true } }
'@
    'index.html' = T @'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>T</title></head>
<body>
  <nav><a href="#main">Skip</a></nav>
  <main id="main">
    <ul><li>one<li>two</ul>
    <img src="a.png" alt="">
    <p>Text<br>more
  </main>
  <script>if (a < b) { x = "<div>"; }</script>
</body>
</html>
'@
    'site.css' = T @'
/* layout */
.card {
  padding: 4px;
  color: red
}
@media (max-width: 600px) {
  .card { padding: 2px; }
}
'@
    'app.csproj' = T @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>
'@
    'README.md' = (T @'
# Title

Some text.

FENCEpowershell
Get-Date
FENCE
'@).Replace('FENCE', $bt)
    'build.sh' = T @'
#!/bin/bash
if [ -f x ]; then
  echo "it's there"
fi
for f in *.txt; do
  case "$f" in
    a*) echo a ;;
  esac
done
'@
    'run.cmd' = (T @'
@echo off
if exist x (
  echo yes
) else (
  goto :done
)
call :sub
goto :eof
:sub
echo in sub
exit /b
:done
echo done
'@).Replace("`n", "`r`n")
    'query.sql' = T @'
-- report
SELECT name, COUNT(*) AS n
FROM users
WHERE note <> 'it''s ok' /* comment */
GROUP BY name;
'@
    'app.toml' = T @'
title = "App"

[server]
port = 8080
hosts = [
  "a",
  "b",
]

[[plugins]]
name = "x"
'@
    'people.csv' = T @'
name,city,note
Ann,Paris,"likes ""tea"", coffee"
Bob,Rome,
'@
}

Describe 'Correct files have no problems' {
    foreach ($k in $good.Keys) {
        It "$k" { @(Test-FileContent $k $good[$k] ($k -match '\.cmd$')) -join ' | ' | Should BeNullOrEmpty }
    }
}

$bad = @(
    # every code file
    @{ f = 'app.js'; t = "const a = 1;`n<<<<<<< SEARCH`nconst b = 2;"; e = 'line 2: leftover edit or merge marker' }
    @{ f = 'tool.ps1'; t = "Get-Date`n=======`n"; e = 'line 2: leftover edit or merge marker' }
    @{ f = 'app.js'; t = "${bt}javascript`nconst a = 1;`n$bt"; e = 'line 1: a ``` code-fence line in a code file' }
    # JavaScript / TypeScript / C-like
    @{ f = 'app.js'; t = "function a() {`n  return 1;`n"; e = "line 1: '\{' is never closed" }
    @{ f = 'app.js'; t = "const a = [1, 2);"; e = "line 1: '\)' does not match the '\[' opened at line 1" }
    @{ f = 'app.js'; t = "const a = 1;`n}`n"; e = "line 2: '\}' closes nothing" }
    @{ f = 'app.ts'; t = "const s = 'abc;`nconst t = 2;"; e = 'line 1: a string is never closed' }
    @{ f = 'app.js'; t = "const s = ``abc`nconst t = 2;"; e = 'a ` template string is never closed' }
    @{ f = 'app.js'; t = "/* start`nconst a = 1;"; e = 'line 1: a /\* comment is never closed' }
    @{ f = 'Program.cs'; t = "class A {`n  void M() {`n    Call(1;`n  }`n}"; e = "line 4: '\}' does not match the '\(' opened at line 3" }
    @{ f = 'app.js'; t = "function a() {}`nfunction b() {}`nfunction a() {}"; e = "line 3: function 'a' is defined a second time \(first at line 1\)" }
    # Python
    @{ f = 'main.py'; t = "def main()`n    print(1)"; e = "line 1: 'def main\(\)' needs a colon" }
    @{ f = 'main.py'; t = "if x == 1`n    y = 2`nelse:`n    y = 3"; e = "line 1: 'if x == 1' needs a colon" }
    @{ f = 'main.py'; t = "for i in range(3:`n    print(i)"; e = "line 1: '\(' is never closed" }
    @{ f = 'main.py'; t = "def f():`n    '''doc`n    return 1"; e = 'a triple-quoted string is never closed' }
    @{ f = 'main.py'; t = "x = 'abc`ny = 2"; e = 'line 1: a string is never closed' }
    @{ f = 'main.py'; t = "def f():`n    a = 1`n`tb = 2"; e = 'line 3: indented with tabs while line 2 uses spaces' }
    @{ f = 'main.py'; t = "def f():`n    return 1`n`n`ndef g():`n    return 2`n`n`ndef f():`n    return 3"; e = "line 9: function 'f' is defined a second time" }
    # PowerShell
    @{ f = 'tool.ps1'; t = "function A {`n  Write-Output 1`n"; e = 'line \d+: .*(brace|\})' }
    @{ f = 'tool.ps1'; t = "`$a = 'abc`nWrite-Output `$a"; e = 'line \d+: .*string' }
    @{ f = 'tool.ps1'; t = "function A { 1 }`nfunction A { 2 }"; e = "line 2: function 'A' is defined a second time" }
    # YAML
    @{ f = 'config.yml'; t = "build:`n`tcommand: x"; e = 'line 2: tabs in the indentation' }
    @{ f = 'config.yml'; t = "name: a`nversion: 1`nname: b"; e = "line 3: duplicate key 'name' \(also at line 1\)" }
    @{ f = 'config.yml'; t = "server:`n  port:8080"; e = "line 2: 'port:8080' has no space after the colon" }
    @{ f = 'config.yml'; t = "title: ""hello`nnext: 1"; e = 'line 1: a double-quoted value is never closed' }
    @{ f = 'config.yml'; t = "dirs: [src, public`nnext: 1"; e = "line 1: flow value: '\[' is never closed" }
    # JSON
    @{ f = 'data.json'; t = '{ "a": 1, }'; e = 'not valid JSON' }
    @{ f = 'data.json'; t = '{ "a": 1 // note' + "`n}"; e = 'not valid JSON' }
    # HTML
    @{ f = 'index.html'; t = "<div>`n  <section>`n  </div>"; e = 'line 2: <section> is not closed before </div> at line 3' }
    @{ f = 'index.html'; t = "<main>`n  <div>text`n</main>"; e = 'line 2: <div> is not closed before </main>' }
    @{ f = 'index.html'; t = "<div>ok</div>`n</span>"; e = 'line 2: </span> closes nothing' }
    @{ f = 'index.html'; t = "<body>`n<div id=""x""></div>`n<div id=""x""></div>`n</body>"; e = 'line 3: id "x" is used twice \(also at line 2\)' }
    @{ f = 'index.html'; t = "<a href=""#nowhere"">go</a>"; e = 'line 1: link to #nowhere, but no element has id "nowhere"' }
    @{ f = 'index.html'; t = "<p>a</p>`n<!-- note`n<p>b</p>"; e = 'line 2: an <!-- comment is never closed' }
    @{ f = 'index.html'; t = "<section>`n<p>a</p>"; e = 'line 1: <section> is never closed' }
    # CSS
    @{ f = 'site.css'; t = ".a {`n  color: red;`n"; e = "line 1: '\{' is never closed" }
    @{ f = 'site.css'; t = ".a {`n  color: red`n  margin: 0;`n}"; e = "line 2: missing ; at the end of 'color: red'" }
    @{ f = 'site.css'; t = "/* note`n.a { color: red; }"; e = 'line 1: a /\* comment is never closed' }
    # XML family
    @{ f = 'app.csproj'; t = '<Project><PropertyGroup></Project>'; e = 'not valid XML' }
    @{ f = 'web.config'; t = '<configuration><appSettings><add key="a" value="1"></appSettings></configuration>'; e = 'not valid XML' }
    # Markdown
    @{ f = 'README.md'; t = "# T`n`n${bt}js`nconst a = 1;`n"; e = 'line 3: a code block opened with ``` is never closed' }
    # Shell
    @{ f = 'build.sh'; t = "if [ -f x ]; then`r`n  echo hi`r`nfi`r`n"; e = 'Windows line endings \(CRLF\)' }
    @{ f = 'build.sh'; t = "if [ -f x ]; then`n  echo hi`n"; e = 'if/fi do not match: 1 if, 0 fi' }
    @{ f = 'build.sh'; t = "for f in *; do`n  echo `$f`n"; e = 'do/done do not match' }
    @{ f = 'build.sh'; t = "echo ""hello`n"; e = 'a quote is never closed' }
    # Batch
    @{ f = 'run.cmd'; t = "@echo off`ngoto :end`n"; e = 'LF line endings' }
    @{ f = 'run.cmd'; t = "@echo off`r`ngoto :finish`r`n:end`r`n"; e = 'line 2: label :finish does not exist' }
    @{ f = 'run.cmd'; t = "@echo off`r`nif exist x (`r`n  echo yes`r`n"; e = 'a \( block is never closed' }
    # SQL
    @{ f = 'query.sql'; t = "SELECT COUNT(* FROM t;"; e = "line 1: '\(' is never closed" }
    @{ f = 'query.sql'; t = "SELECT 'abc FROM t;"; e = 'line 1: a string is never closed' }
    # TOML
    @{ f = 'app.toml'; t = "[server`nport = 1"; e = "line 1: the table header '\[server' is not closed" }
    @{ f = 'app.toml'; t = "port = 1`nport = 2"; e = "line 2: duplicate key 'port'" }
    @{ f = 'app.toml'; t = "port 8080"; e = "line 1: 'port 8080' is not 'key = value'" }
    @{ f = 'app.toml'; t = "name = ""abc"; e = 'line 1: a string is never closed' }
    # CSV
    @{ f = 'people.csv'; t = "a,b,c`n1,2,3`n4,5"; e = 'line 3: 2 columns, the header has 3' }
    @{ f = 'people.csv'; t = "a,b`n""x,1"; e = 'line 2: a quoted field is never closed' }
)

Describe 'Typical breakages are found, with the line' {
    foreach ($c in $bad) {
        It "$($c.f): $($c.e)" {
            $crlf = $c.t.Contains("`r`n")
            (@(Test-FileContent $c.f $c.t $crlf) -join ' | ') | Should Match $c.e
        }
    }
}

Describe 'Repeated code and secrets' {
    It 'finds the same 8 lines twice' {
        $block = (1..8 | ForEach-Object { "  total += item$_.price * qty$_;" }) -join "`n"
        Test-Duplicates "function a() {`n$block`n}`nfunction b() {`n$block`n}" 'app.js' | Should Match 'line 12: these lines repeat lines 2-9'
    }
    It 'finds secrets, not placeholders' {
        @(Find-Secrets "key = '-----BEGIN RSA PRIVATE KEY-----'") -join '' | Should Match 'a private key'
        @(Find-Secrets 'aws = "AKIA1234567890ABCDEF"') -join '' | Should Match 'AWS access key'
        @(Find-Secrets 'Server=x;Database=y;Password=S3cretPass!;') -join '' | Should Match 'password in a connection string'
        @(Find-Secrets 'const apiKey = "sk_live_51HxAbCdEfGh";') -join '' | Should Match 'password, key or token'
        @(Find-Secrets 'const apiKey = "your-api-key-here";') -join '' | Should BeNullOrEmpty
        @(Find-Secrets 'Password=$env:DB_PASSWORD;') -join '' | Should BeNullOrEmpty
        @(Find-Secrets 'password = "<PASSWORD>"') -join '' | Should BeNullOrEmpty
    }
}

Describe 'PowerShell commands and local references' {
    $p = Join-Path $env:TEMP ('ccb-refs-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $p 'lib'), (Join-Path $p 'docs'), (Join-Path $p 'pkg')
    [IO.File]::WriteAllText((Join-Path $p 'lib\helpers.ps1'), "function Get-Helper { 1 }")
    [IO.File]::WriteAllText((Join-Path $p 'pkg\util.py'), 'x = 1')
    [IO.File]::WriteAllText((Join-Path $p 'docs\guide.md'), '# guide')
    It 'finds a misspelt cmdlet, not real or project commands' {
        @(Test-PsCommands "Get-ChildItem .`nGet-Helper`nGet-Chiditem ." $p) -join '' | Should Match "line 3: 'Get-Chiditem' is not a command"
        @(Test-PsCommands "Get-ChildItem .`nGet-Helper" $p).Count | Should Be 0
    }
    It 'leaves scripts alone that load a module this computer does not have' {
        @(Test-PsCommands "Import-Module Some.Missing.Module`nGet-Thing" $p).Count | Should Be 0
    }
    It 'finds dot-sourced scripts and module paths that do not exist' {
        @(Test-LocalReferences ". `$PSScriptRoot\helpers.ps1`n. `$PSScriptRoot\nope.ps1" 'lib/run.ps1' $p) -join '' | Should Match 'line 2: dot-sources nope\.ps1'
        @(Test-LocalReferences "Import-Module (Join-Path `$PSScriptRoot 'gone.psm1')" 'lib/run.ps1' $p) -join '' | Should Match 'refers to gone\.psm1'
    }
    It 'finds Python relative imports that do not exist' {
        @(Test-LocalReferences "from .util import x`nfrom .missing import y" 'pkg/main.py' $p) -join '' | Should Match 'line 2: imports \.missing'
    }
    It 'finds Markdown links to files that do not exist (not web links)' {
        @(Test-LocalReferences "[guide](docs/guide.md) [web](https://x.example) [bad](docs/none.md)" 'README.md' $p) -join '' | Should Match 'links to docs/none\.md'
        @(Test-LocalReferences "[guide](docs/guide.md)" 'README.md' $p).Count | Should Be 0
    }
    cmd /c "rmdir /s /q ""$p"" >nul 2>&1"
}

Describe 'Only problems a change adds are reported' {
    It 'does not report an existing problem again, only a new one' {
        $old = "function a() {`n  return 1;`n"            # already unclosed
        $new = "// note`nfunction a() {`n  return 1;`n"   # still the same problem, moved down
        @(Get-NewFileIssues 'app.js' $old $new).Count | Should Be 0
        @(Get-NewFileIssues 'app.js' '' $new).Count | Should Be 1
    }
}

Describe 'No false alarms on real-world code' {
    $tick = '`'
    $cases = @{
        'nested.ts' = 'const close = new RegExp(' + $tick + '^\\s{0,3}${fence[0] === "' + $tick + '" ? "' + $tick + '" : "~"}{${n},}' + $tick + ');'
        'regex.js' = "const q = s.replace(/[""']/g, '');`nconst ok = /\/\*/.test(x);"
        'arrow-regex.ts' = "const n = (s ?? '').split(/[\s,;]+/).filter((p) => /^https?:\/\//i.test(p)).length;`nfunction f(x) { return /a\/\/b/.test(x); }`nconst half = total / 2 / count;"
        'view.tsx' = "export const V = () => (`n  <div>`n    {a && <Sources refs={r} />}`n    <p>Don't stop</p>`n  </div>`n);"
        'tsconfig.json' = "{`n  // comment`n  ""compilerOptions"": { ""strict"": true, },`n}"
        'package-lock.json' = '{ "packages": { "": { "name": "x" } } }'
        'start.cmd' = "@echo off`ncd /d ""%~dp0""`npowershell -File x.ps1`npause"
        'edits.Tests.ps1' = "`$reply = @'`n<<<<<<< SEARCH`nold`n=======`nnew`n>>>>>>> REPLACE`n'@"
    }
    foreach ($k in $cases.Keys) {
        It "$k" { @(Test-FileContent $k $cases[$k]) -join ' | ' | Should BeNullOrEmpty }
    }
    It 'still finds a real unclosed template string and JSX bracket problem' {
        @(Test-FileContent 'a.ts' ('const s = ' + $tick + 'abc' + "`nconst t = 1;")) -join '' | Should Match 'template string is never closed'
        @(Test-FileContent 'v.tsx' "const V = () => (`n  <div>{a && <b /></div>`n);") -join '' | Should Match "does not match|never closed"
    }
}