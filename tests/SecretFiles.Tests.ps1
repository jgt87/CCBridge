# Secret files (lib/SecretFiles.psm1): Copilot sees which keys are set, never the values; images go
# to Copilot as attachments; outlines for more languages (Executor Get-FileOutline).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\SecretFiles.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$p = Join-Path $env:TEMP ('ccb-secret-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $p | Out-Null

Describe 'Secret files' {
    $envText = "# database`nDB_HOST=localhost`nexport API_KEY=sk-live-123456`nEMPTY=`n"
    [IO.File]::WriteAllText((Join-Path $p '.env'), $envText)
    [IO.File]::WriteAllText((Join-Path $p '.env.example'), "API_KEY=YOUR_KEY`n")
    [IO.File]::WriteAllText((Join-Path $p '.npmrc'), "//registry.example.org/:_authToken=npm_SECRET`nregistry=https://registry.example.org/`n")
    [IO.File]::WriteAllText((Join-Path $p 'secrets.json'), "{ `"Db`": { `"Password`": `"hunter2`", `"Port`": 5432 } }")
    [IO.File]::WriteAllText((Join-Path $p 'server.pem'), "-----BEGIN PRIVATE KEY-----`nMIIEv`n-----END PRIVATE KEY-----`n")
    It 'knows which files hold secrets, and leaves example files alone' {
        Get-SecretFileKind '.env' | Should Be 'keyvalue'
        Get-SecretFileKind 'config/.env.production' | Should Be 'keyvalue'
        Get-SecretFileKind '.env.example' | Should BeNullOrEmpty
        Get-SecretFileKind 'secrets.json' | Should Be 'json'
        Get-SecretFileKind 'id_ed25519' | Should Be 'key'
        Get-SecretFileKind 'app.js' | Should BeNullOrEmpty
    }
    It 'shows the keys with the values hidden' {
        $t = (Invoke-ReadAction $p @('.env')) -join "`n"
        $t | Should Match 'DB_HOST=<hidden>'
        $t | Should Match 'export API_KEY=<hidden>'
        $t | Should Match '(?m)^EMPTY=$'
        $t | Should Match '# database'
        $t | Should Not Match 'sk-live|localhost'
        $t | Should Match 'values are shown as <hidden>'
        $n = (Invoke-ReadAction $p @('.npmrc')) -join "`n"
        $n | Should Match '//registry\.example\.org/:_authToken=<hidden>'
        $n | Should Not Match 'npm_SECRET'
        $j = (Invoke-ReadAction $p @('secrets.json')) -join "`n"
        $j | Should Match '"Password": "<hidden>"'
        $j | Should Not Match 'hunter2|5432'
        (Invoke-ReadAction $p @('server.pem')) -join "`n" | Should Not Match 'MIIEv'
        (Invoke-ReadAction $p @('.env.example')) -join "`n" | Should Match 'API_KEY=YOUR_KEY'
    }
    It 'never shows a value in search results, and never writes or attaches the file' {
        $g = Invoke-GrepAction $p 'API_KEY'
        $g | Should Match '\.env:3: export API_KEY=<hidden>'
        $g | Should Not Match 'sk-live'
        Invoke-GrepAction $p 'sk-live' | Should Match 'no matches'
        { Assert-Writable $p '.env' } | Should Throw 'holds secrets'
        { Assert-Writable $p '.env.example' } | Should Not Throw
        { Resolve-AgentFiles $p @('.env') } | Should Throw 'never attached'
        Import-Module (Join-Path $root 'lib\Review.psm1') -Force
        @((Get-ReviewFiles $p).files) -contains 'secrets.json' | Should Be $false
    }
}

Describe 'Images go to Copilot as an attachment' {
    [IO.File]::WriteAllBytes((Join-Path $p 'mockup.png'), [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0))
    It 'is attached by the read action and never written' {
        (Invoke-ReadAction $p @('mockup.png')) -join "`n" | Should Match 'Image, which cannot be read as text here'
        { Assert-Writable $p 'mockup.png' } | Should Throw 'image'
        $config = Get-CCBridgeConfig harness $root
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p
        $res = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'read'; arg = 'mockup.png'; body = '' }) 'a1' $null 0 } $s
        $res.attach[0] | Should Match 'mockup\.png$'
    }
}

Describe 'Outlines for more languages' {
    It 'C#: types and methods' {
        $cs = "namespace App`n{`n    public class OrderService`n    {`n        public async Task<Order> GetAsync(int id)`n        {`n            if (id < 0) { throw new ArgumentException(); }`n            return await repo.Find(id);`n        }`n        private void Log(string m) { }`n    }`n}"
        (@(Get-FileOutline $cs 'a.cs') -join '|') | Should Be '3    class OrderService|5      GetAsync()|10      Log()'
    }
    It 'Java, Kotlin and Go' {
        $java = "public class Main {`n    public static void main(String[] args) {`n        System.out.println(1);`n    }`n}"
        (@(Get-FileOutline $java 'Main.java') -join '|') | Should Be '1  class Main|2    main()'
        $kt = "data class User(val name: String)`nfun greet(u: User): String {`n    return u.name`n}"
        (@(Get-FileOutline $kt 'a.kt') -join '|') | Should Be '1  class User|2  greet()'
        $go = "package main`ntype Server struct {`n}`nfunc (s *Server) Start() error {`n}`nfunc main() {`n}"
        (@(Get-FileOutline $go 'main.go') -join '|') | Should Be '2  type Server struct|4  func (s *Server) Start|6  func main'
    }
    It 'SQL, INI/TOML and JSON' {
        $sql = "-- schema`nCREATE TABLE IF NOT EXISTS dbo.Orders (id int);`ncreate or replace view v_orders as select 1;`nSELECT 1;"
        (@(Get-FileOutline $sql 'db.sql') -join '|') | Should Be '2  CREATE TABLE dbo.Orders|3  CREATE VIEW v_orders'
        (@(Get-FileOutline "[server]`nport = 1`n[[bin]]`nname = 'x'" 'a.toml') -join '|') | Should Be '1  [server]|3  [[bin]]'
        $json = "{`n  `"name`": `"app`",`n  `"scripts`": {`n    `"build`": `"vite`",`n    `"deep`": { `"skip`": 1 }`n  },`n  `"list`": [ { `"no`": 1 } ]`n}"
        (@(Get-FileOutline $json 'package.json') -join '|') | Should Be '2  name|3  scripts|4    build|5    deep|7  list'
    }
}

Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue

Describe 'Secret values in command output' {
    $q = Join-Path $env:TEMP ('ccb-secret-run-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $q | Out-Null
    [IO.File]::WriteAllText((Join-Path $q '.env'), "API_KEY=sk-live-987654`nTOKEN=`"quoted-secret`"`n")
    It 'hides them when a command prints the file' {
        $r = Invoke-RunAction $q 'type .env' -TimeoutSec 30
        $r.output | Should Match 'API_KEY=<hidden>'
        $r.output | Should Not Match 'sk-live|quoted-secret'
    }
    Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue
}
