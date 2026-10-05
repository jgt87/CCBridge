# When the checks change, the issue index scans every file again once (Issues $script:RulesVersion):
# results of the old rules are dropped, ignored issues and statuses are kept.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Issues.psm1') -Force

Describe 'An issue index from older rules' {
    $p = Join-Path $env:TEMP ('ccb-rules-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p '.streamhub') -Force | Out-Null
    $file = Join-Path $p '.streamhub\issues.json'
    $entry = '"files":{"data/example.js":{"size":10,"mtime":5,"issues":[{"id":"a","category":"error","message":"these lines repeat"}]}},"states":{"a":{"status":"open","attempts":0,"note":""}},"ignored":{"k":{"path":"x.js","category":"error","message":"m","text":"t","at":"now"}}'
    It 'forgets the per-file results, so every file is scanned again, and keeps what was ignored' {
        [IO.File]::WriteAllText($file, '{"version":1,"rules":1,' + $entry + '}')
        $ix = & (Get-Module Issues) { param($r) Read-IssueIndex $r } $p
        $ix.files.Count | Should Be 0
        $ix.ignored.ContainsKey('k') | Should Be $true
        $ix.states.ContainsKey('a') | Should Be $true
    }
    It 'keeps the results of the current rules' {
        $cur = & (Get-Module Issues) { $script:RulesVersion }
        [IO.File]::WriteAllText($file, '{"version":1,"rules":' + $cur + ',' + $entry + '}')
        $ix = & (Get-Module Issues) { param($r) Read-IssueIndex $r } $p
        $ix.files.Count | Should Be 1
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
