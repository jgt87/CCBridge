# The send lock (CopilotBridge Use-CopilotLock): one StreamHub program talks to Copilot at a time.
# A wait for it is said with who holds it, logged, and ends on Stop, instead of a silent wait that
# looks like "waiting for the reply".
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $env:CCBRIDGE_STATE_ROOT -Force | Out-Null
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force

function Start-LockHolder([int]$Seconds) {
    # Another process holds the lock (like the MCP server would) and says who it is.
    $job = Start-Job -ArgumentList $env:CCBRIDGE_STATE_ROOT, $Seconds -ScriptBlock {
        param($dir, $sec)
        $m = New-Object Threading.Mutex($false, 'Local\CCBridgeCopilot')
        $null = $m.WaitOne()
        [IO.File]::WriteAllText((Join-Path $dir 'copilot-lock.json'), (@{ pid = $PID; who = 'the MCP server'; since = '09:21:00' } | ConvertTo-Json -Compress))
        Start-Sleep -Seconds $sec
        Remove-Item (Join-Path $dir 'copilot-lock.json') -Force
        $m.ReleaseMutex()
    }
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path (Join-Path $env:CCBRIDGE_STATE_ROOT 'copilot-lock.json')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $job
}

Describe 'Waiting for the send lock' {
    It 'names the program that holds it, then clears the line and runs' {
        $job = Start-LockHolder 3
        $lines = New-Object System.Collections.Generic.List[object]
        $r = & (Get-Module CopilotBridge) { param($l) Use-CopilotLock -OnWait { param($t) $l.Add($t) }.GetNewClosure() -Body { 'ran' } } $lines
        $r | Should Be 'ran'
        $lines[0] | Should Match '^waiting: the MCP server \(process \d+\) has been sending to Copilot since 09:21:00$'
        $lines[$lines.Count - 1] | Should Be $null
        $job | Wait-Job | Remove-Job
    }
    It 'stops waiting when the task is stopped' {
        $job = Start-LockHolder 6
        { & (Get-Module CopilotBridge) { Use-CopilotLock -CancelCheck { $true } -Body { 'ran' } } } | Should Throw 'Stopped while waiting'
        $job | Wait-Job | Remove-Job
    }
    It 'takes a free lock at once and says nothing' {
        $lines = New-Object System.Collections.Generic.List[object]
        & (Get-Module CopilotBridge) { param($l) Use-CopilotLock -OnWait { param($t) $l.Add($t) }.GetNewClosure() -Body { 'ran' } } $lines | Should Be 'ran'
        $lines.Count | Should Be 0
        Test-Path (Join-Path $env:CCBRIDGE_STATE_ROOT 'copilot-lock.json') | Should Be $false
    }
    It 'tells the StreamHub programs apart by their command line' {
        & (Get-Module CopilotBridge) {
            Get-LockHolderName 'powershell -File C:\x\mcp\ccbridge-mcp.ps1' | Should Be 'the MCP server'
            Get-LockHolderName 'powershell -File C:\x\tools\rate-limit-test.ps1' | Should Be 'the test tool rate-limit-test'
            Get-LockHolderName 'powershell -File C:\x\ccbridge.ps1' | Should Be 'another StreamHub window'
        }
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
