# Mechanical fixes (lib/AutoFix.psm1) and rolling back a fix that made a file worse (Agent.psm1).
# Non-ASCII characters are made with [char] so this file stays ASCII.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_ISSUE_INDEX = Join-Path $env:TEMP ('ccb-app-index-' + [guid]::NewGuid().ToString('N') + '.json')
Import-Module (Join-Path $root 'lib\AutoFix.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$lq = [char]0x201C; $rq = [char]0x201D; $nbsp = [char]0x00A0; $zw = [char]0x200B

Describe 'Repair-MechanicalIssues' {
    It 'fixes what has one right answer, in code only, and leaves strings and comments alone' {
        $r = Repair-MechanicalIssues 'a.js' "const s = ${lq}hi${rq};`nconst t = 'say ${lq}hi${rq}';`n"
        $r.text | Should Be "const s = `"hi`";`nconst t = 'say ${lq}hi${rq}';`n"
        $r.fixes[0] | Should Match '2 typographic quote'
        (Repair-MechanicalIssues 'a.py' "x =${nbsp}1$zw`n").text | Should Be "x = 1`n"
        (Repair-MechanicalIssues 'a.js' "if (a &amp;&amp; b) { go(); }`n").text | Should Be "if (a && b) { go(); }`n"
        (Repair-MechanicalIssues 'a.tsx' "const t = <p>Fish &amp; chips</p>;`n").fixes.Count | Should Be 0
        (Repair-MechanicalIssues 'a.css' "// header`nh1 { color: red; }`n").text | Should Be "/* header */`nh1 { color: red; }`n"
        (Repair-MechanicalIssues 'a.css' "body { background: url(https://example.org/a.png); }`n").fixes.Count | Should Be 0
        (Repair-MechanicalIssues 'a.cmd' "@echo off`r`nfor %f in (*.txt) do echo %f`r`n").text | Should Be "@echo off`r`nfor %%f in (*.txt) do echo %%f`r`n"
        (Repair-MechanicalIssues 'a.js' "a();`r`nb();`nc();`r`n").text | Should Be "a();`r`nb();`r`nc();`r`n"
        (Repair-MechanicalIssues 'a.js' "const a = 1;`n").fixes.Count | Should Be 0
    }
}

Describe 'Rolling back a fix that made a file worse (Copilot mocked)' {
    $p = Join-Path $env:TEMP ('ccb-rollback-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    $config = Get-CCBridgeConfig harness $root
    $config.pageCheck = 'off'                                   # no Edge in the tests
    Mock -ModuleName Agent Start-NewChat { }
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, [string]$Message)
        $global:ccbSent += , $Message
        $reply = $global:ccbReplies[$global:ccbSent.Count - 1]
        [pscustomobject]@{ Result = 'Success'; Text = $reply; Agent = ''; IsPlan = $false; Uncertain = 0; References = @(); ProposedActions = @(); ActionClaims = @() }
    }
    $fence = '````'
    It 'rolls the file back, and the next message has a wider read of the code around the problem' {
        $global:ccbSent = @()
        $global:ccbReplies = @(
            "${fence}text`nACTION write app.js`nfunction a() {`n  return 1;`n$fence",                                     # 1. broken: { never closed
            "${fence}text`nACTION write app.js`nconst a = 1;`nconst a = 2;`nfunction b() {`n  return 1;`n$fence",           # 2. a 'fix' that adds an error
            ("${fence}text`nACTION write app.js`nfunction a() {`n  return 1;`n}`n$fence`n" + '```text' + "`nACTION done`nFixed.`n" + '```')   # 3. right (in parentheses: the comma binds before +)
        )
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Write app.js with a function a that returns 1'
        $global:ccbSent.Count | Should Be 3
        $global:ccbSent[2] | Should Match '### Rolled back: app\.js'
        $global:ccbSent[2] | Should Match 'declared a second time'
        $global:ccbSent[2] | Should Match 'Before you fix it again, understand the context'
        $global:ccbSent[2] | Should Match 'function a\(\) \{'                     # the wider read: the code as it was
        @($s.Events | Where-Object { $_.type -eq 'action' -and $_.action -eq 'restore' -and $_.by -eq 'streamhub' }).Count | Should Be 1
        ([IO.File]::ReadAllText((Join-Path $p 'app.js'))).Replace("`r`n", "`n") | Should Be "function a() {`n  return 1;`n}`n"
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $env:CCBRIDGE_ISSUE_INDEX -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_ISSUE_INDEX = $null
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
