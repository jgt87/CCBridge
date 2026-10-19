# What StreamHub is doing now, for the waiting card in the app: the phase and since when, the task's
# start, rounds, actions and changed files, the last sign of life (Copilot's reply data, its page
# showing it is still at work, any step), and the last steps with their times. Kept in $State.Work by
# the worker (Agent.psm1), sent with the app state (Server Get-StateSnapshot), never saved.
# Plain values only: the server reads it from another thread, so lists are replaced, never changed.

$script:MaxSteps = 15

function Get-Stamp { (Get-Date).ToString('s') }

function Start-WorkStatus {
    <# A task starts: a fresh status. -Kind is the task kind (chat, runbook, chain...). #>
    param($State, [string]$Kind = '', [string]$Label = '')
    $now = Get-Stamp
    $State.Work = @{ kind = $Kind; startedAt = $now; phase = $(if ($Label) { $Label } else { 'Starting' }); phaseAt = $now; lastSignAt = $now; lastDataAt = ''
        round = 0; actions = 0; changed = @(); steps = @(); ids = @{}; waitSec = 0; stallSec = 0 }
    if ($Label) { Add-WorkStep $State $Label }
}

function Stop-WorkStatus($State) { $State.Work = $null }

function Add-WorkStep {
    <# One line in the card's activity log (the newest $script:MaxSteps), also a sign of life. #>
    param($State, [string]$Text)
    $w = $State.Work
    if (-not $w -or -not $Text) { return }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt 140) { $t = $t.Substring(0, 137) + '...' }
    $now = Get-Stamp
    $last = @($w.steps) | Select-Object -Last 1
    if ($last -and $last.text -eq $t) { $w.lastSignAt = $now; return }
    $w.steps = @(@($w.steps) + @{ at = $now; text = $t } | Select-Object -Last $script:MaxSteps)
    $w.lastSignAt = $now
}

function Set-WorkPhase {
    <# What StreamHub is doing now (the card's status line); -Step also logs it. #>
    param($State, [string]$Phase, [switch]$Step)
    $w = $State.Work
    if (-not $w -or -not $Phase) { return }
    if ($w.phase -ne $Phase) { $w.phase = $Phase; $w.phaseAt = Get-Stamp }
    $w.lastSignAt = Get-Stamp
    if ($Step) { Add-WorkStep $State $Phase }
}

function Set-WorkWait {
    <# How long StreamHub waits for Copilot now: without any sign ($StallSec) and in all ($WaitSec). #>
    param($State, [int]$WaitSec, [int]$StallSec)
    if ($State.Work) { $State.Work.waitSec = $WaitSec; $State.Work.stallSec = $StallSec }
}

function Set-WorkSign {
    <# A sign of life: -Data for reply data from Copilot (the reply grows), else the page shows it at work. #>
    param($State, [switch]$Data)
    $w = $State.Work
    if (-not $w) { return }
    $now = Get-Stamp
    $w.lastSignAt = $now
    if ($Data) { $w.lastDataAt = $now }
}

function Set-WorkRound($State, [int]$Round) {
    if (-not $State.Work) { return }
    $State.Work.round = $Round
    if ($Round -gt 1) { Add-WorkStep $State "Round $Round" }
}

$script:ActionVerbs = @{ read = 'Read'; write = 'Write'; edit = 'Edit'; run = 'Run'; glob = 'Find files'; grep = 'Search'; find = 'Find'; web = 'Web'; sql = 'Query'; remember = 'Remember'; screenshot = 'Screenshot'; runbook = 'Runbook'; dispute = 'Dispute'; todo = 'To-do'; done = 'Done' }

function Update-WorkFromEvent {
    <# The activity log and counts from the chat's events (Agent Add-AgentEvent): a new action, its
       result, Copilot's reply, the end. Restored events (an earlier chat shown again) are skipped. #>
    param($State, [string]$Type, [hashtable]$Data)
    $w = $State.Work
    if (-not $w -or $Data.restored) { return }
    switch ($Type) {
        'action' {
            $id = "$($Data.id)"
            if (-not $id) { return }
            $verb = if ($script:ActionVerbs.ContainsKey("$($Data.action)")) { $script:ActionVerbs["$($Data.action)"] } else { "$($Data.action)" }
            if (-not $w.ids.ContainsKey($id)) {
                $ids = @{} + $w.ids; $ids[$id] = @{ action = "$($Data.action)"; target = "$($Data.target)" }; $w.ids = $ids
                if ("$($Data.by)" -ne 'streamhub') { $w.actions = [int]$w.actions + 1 }
                Add-WorkStep $State "$verb $($Data.target)".Trim()
            }
            if ("$($Data.status)" -eq 'awaiting') { Set-WorkPhase $State "Waiting for your approval: $verb $($Data.target)".Trim() -Step }
            elseif ("$($Data.status)" -eq 'running' -and "$($Data.action)" -eq 'run') { Set-WorkPhase $State "Running $($Data.target)".Trim() }
        }
        'action-result' {
            $a = $w.ids["$($Data.id)"]
            if (-not $a) { return }
            $ok = $Data.ok -ne $false -and "$($Data.status)" -notin 'failed', 'rejected', 'skipped', 'error'
            if ($ok -and $a.action -in 'write', 'edit' -and $a.target -and @($w.changed) -notcontains $a.target) { $w.changed = @(@($w.changed) + $a.target) }
            if (-not $ok) { Add-WorkStep $State "$(if ("$($Data.status)" -eq 'rejected') { 'Rejected' } else { 'Failed' }): $($script:ActionVerbs[$a.action]) $($a.target)".Trim() }
            elseif ($a.action -eq 'run') { Add-WorkStep $State "Finished $($a.target)" }
        }
        'assistant' { Add-WorkStep $State 'Copilot replied' }
        'done' { Set-WorkPhase $State 'Finishing: checks after Copilot said done' -Step }
        'human-required' { Set-WorkPhase $State 'Waiting for you: a step needs a person' -Step }
        'error' { Add-WorkStep $State "Error: $($Data.text)" }
    }
}

function Get-WorkView {
    <# The status as the app gets it, or $null with no task running. The phase is StreamHub's own work
       when it has some ($State.Activity: page check, tests, indexing...), else the worker's phase. #>
    param($State)
    $w = $State.Work
    if (-not $w) { return $null }
    $phase = "$($w.phase)"; $phaseAt = "$($w.phaseAt)"
    if ($State.Activity -and "$($State.Activity.label)") { $phase = "$($State.Activity.label)" }
    @{ kind = "$($w.kind)"; startedAt = "$($w.startedAt)"; phase = $phase; phaseAt = $phaseAt; lastSignAt = "$($w.lastSignAt)"; lastDataAt = "$($w.lastDataAt)"
       round = [int]$w.round; actions = [int]$w.actions; changed = @($w.changed).Count; waitSec = [int]$w.waitSec; stallSec = [int]$w.stallSec
       steps = @(@($w.steps) | ForEach-Object { @{ at = "$($_.at)"; text = "$($_.text)" } }) }
}

Export-ModuleMember -Function Start-WorkStatus, Stop-WorkStatus, Add-WorkStep, Set-WorkPhase, Set-WorkWait, Set-WorkSign, Set-WorkRound, Update-WorkFromEvent, Get-WorkView
