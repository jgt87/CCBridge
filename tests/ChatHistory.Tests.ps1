# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# The chat is kept per project (in the project's state folder) and comes back after a restart.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# Project state (backups, chat history) of the test projects goes to a temporary folder, deleted below.
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Chat history' {
    $config = Get-CCBridgeConfig harness $root
    $proj = Join-Path $env:TEMP ('ccb-history-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path $proj

    It 'saves the events of a session in the project''s state folder, not in the project' {
        $s = New-AgentState -Config $config -AppRoot $root
        $s.SaveHistory = $true; $s.ProjectRoot = $proj
        Add-AgentEvent $s 'project' @{ name = 'x'; path = $proj }
        Add-AgentEvent $s 'user' @{ text = 'Add a total row' }
        Add-AgentEvent $s 'assistant' @{ text = 'Done: the total row is added.' }
        Add-AgentEvent $s 'action' @{ id = 'a1'; action = 'edit'; target = 'app.js'; status = 'awaiting'; preview = @{ path = 'app.js'; exists = $true; old = 'a'; new = 'b' } }
        $file = Get-ChatHistoryPath $proj
        $file | Should Not Match ([regex]::Escape($proj))
        $lines = @([IO.File]::ReadAllLines($file))
        $lines.Count | Should Be 3          # the project marker itself is not saved
        $lines[0] | Should Match '"type":"user"'
    }

    It 'brings the conversation back after a restart, with an approval that can no longer be given marked interrupted' {
        $r = New-AgentState -Config $config -AppRoot $root
        $r.SaveHistory = $true; $r.ProjectRoot = $proj
        Restore-ChatHistory $r $proj | Should Be 3
        $ev = @($r.Events)
        @($ev | Where-Object { $_.type -eq 'user' })[0].text | Should Be 'Add a total row'
        @($ev | Where-Object { $_.type -eq 'action' })[0].preview.new | Should Be 'b'
        @($ev | Where-Object { $_.type -eq 'action-result' -and $_.id -eq 'a1' })[0].status | Should Be 'interrupted'
        @($ev | Where-Object { $_.type -eq 'status' })[-1].text | Should Match 'does not remember'
        # Restored events are not written again.
        @([IO.File]::ReadAllLines((Get-ChatHistoryPath $proj))).Count | Should Be 3
    }

    It 'keeps a very large change without its file contents' {
        $s = New-AgentState -Config $config -AppRoot $root
        $s.SaveHistory = $true; $s.ProjectRoot = $proj
        $big = 'x' * 300000
        Add-AgentEvent $s 'action' @{ id = 'a2'; action = 'write'; target = 'big.txt'; status = 'ok'; preview = @{ path = 'big.txt'; exists = $false; old = $null; new = $big } }
        $last = @([IO.File]::ReadAllLines((Get-ChatHistoryPath $proj)))[-1]
        $last.Length -lt 10000 | Should Be $true
        $last | Should Match 'too large to keep'
    }

    It 'shows the date of events from an earlier day' {
        $file = Get-ChatHistoryPath $proj
        [IO.File]::WriteAllText($file, '{"type":"user","text":"Old one","time":"09:15:00","at":"2026-09-30T09:15:00","seq":1}' + "`n")
        $r = New-AgentState -Config $config -AppRoot $root
        $null = Restore-ChatHistory $r $proj
        @($r.Events | Where-Object { $_.type -eq 'user' })[0].time | Should Be '2026-09-30 09:15'
    }

    It 'skips damaged lines and trims an older, longer history to 1500' {
        $file = Get-ChatHistoryPath $proj
        $lines = @('not json') + @(1..4100 | ForEach-Object { '{"type":"user","text":"m' + $_ + '","time":"10:00:00"}' })
        [IO.File]::WriteAllText($file, ($lines -join "`n") + "`n")
        $events = @(Read-ChatHistory $proj)
        $events.Count | Should Be 1500
        $events[-1].text | Should Be 'm4100'
        @([IO.File]::ReadAllLines($file)).Count | Should Be 1500
    }

    It 'never keeps more than 1500 events: the oldest go as new ones come' {
        $file = Get-ChatHistoryPath $proj
        [IO.File]::WriteAllText($file, (@(1..1500 | ForEach-Object { '{"type":"user","text":"m' + $_ + '","time":"10:00:00"}' }) -join "`n") + "`n")
        Reset-ChatHistoryCount $file
        $s = New-AgentState -Config $config -AppRoot $root
        $s.SaveHistory = $true; $s.ProjectRoot = $proj
        Add-AgentEvent $s 'user' @{ text = 'newest' }
        Add-AgentEvent $s 'user' @{ text = 'newest 2' }
        $kept = @([IO.File]::ReadAllLines($file))
        $kept.Count | Should Be 1500
        $kept[0] | Should Match '"m3"'
        $kept[-1] | Should Match 'newest 2'
    }

    It 'starts the Files tab counts at the oldest restored event, a minute before it' {
        $s = New-AgentState -Config $config -AppRoot $root
        Add-AgentEvent $s 'project' @{ name = 'x'; path = $proj }
        $mark = $s.Seq
        Add-AgentEvent $s 'user' @{ text = 'old'; restored = $true; time = '09:15:00'; at = '2026-09-30T09:15:00' }
        Get-ChangeCountStart $s $mark '20261004-100000-000' | Should Be '20260930-091400-000'
        # Nothing restored: the counts start now.
        Get-ChangeCountStart $s $s.Seq '20261004-100000-000' | Should Be '20261004-100000-000'
    }
    It 'saves nothing without SaveHistory (the MCP server''s own engine)' {
        $p2 = "$proj-2"; $null = New-Item -ItemType Directory -Force -Path $p2
        $s = New-AgentState -Config $config -AppRoot $root
        $s.ProjectRoot = $p2
        Add-AgentEvent $s 'user' @{ text = 'hi' }
        Test-Path (Get-ChatHistoryPath $p2) | Should Be $false
        Remove-Item -LiteralPath $p2 -Recurse -Force
    }

    Remove-Item -LiteralPath (Split-Path (Get-ChatHistoryPath $proj)) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $proj -Recurse -Force
}

if ($env:CCBRIDGE_STATE_ROOT -and (Test-Path -LiteralPath $env:CCBRIDGE_STATE_ROOT)) { [IO.Directory]::Delete($env:CCBRIDGE_STATE_ROOT, $true) }
$env:CCBRIDGE_STATE_ROOT = $null