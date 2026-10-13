# Loops that cost a Copilot message per round without getting anywhere, beyond the same step
# failing the same way (Agent Register-StepFailure) and rounds that only look around (Agent
# Test-ExploreRound): a file going back to a version it had earlier in the task (a change made
# and undone again), and rounds that alternate between two sets of steps (A, B, A, B).
# Fixed rules on fingerprints and step keys; the turn says it once and stops at the second time.

$ErrorActionPreference = 'Stop'

function New-LoopWatch {
    @{ versions = @{}; rounds = New-Object System.Collections.Generic.List[string]; flips = 0; alternations = 0 }
}

function Add-LoopFileVersion {
    <# Records a version (fingerprint) of a file; returns $true when the file had this version earlier
       in the task and a different one since: the change went back. -Seed records the version
       before the task changed it (from the fingerprint taken at Copilot's read). #>
    param([Parameter(Mandatory)][hashtable]$Watch, [string]$Path, [string]$Fingerprint, [switch]$Seed)
    if (-not $Path -or -not $Fingerprint) { return $false }
    $k = "$Path".Replace('\', '/').ToLowerInvariant()
    if (-not $Watch.versions.ContainsKey($k)) { $Watch.versions[$k] = New-Object System.Collections.Generic.List[string] }
    $list = $Watch.versions[$k]
    if ($Seed) { if (-not $list.Count) { $list.Add($Fingerprint) }; return $false }
    if ($list.Count -and $list[$list.Count - 1] -eq $Fingerprint) { return $false }   # unchanged
    $back = $list.Contains($Fingerprint)
    $list.Add($Fingerprint)
    $back
}

function Get-RoundKey($Actions) {
    <# One key for a round's steps: type and argument of each, in order (line numbers kept: a read of
       other lines is another step). #>
    (@($Actions | Where-Object { $_ -and $_.type -ne 'done' } | ForEach-Object { "$($_.type) $($_.arg)".Trim().ToLowerInvariant() }) -join ' | ')
}

function Add-LoopRound {
    <# Records a round's key; returns $true when the last four rounds alternate A, B, A, B. #>
    param([Parameter(Mandatory)][hashtable]$Watch, [string]$Key)
    if (-not $Key) { return $false }
    $Watch.rounds.Add($Key)
    $r = $Watch.rounds; $n = $r.Count
    ($n -ge 4 -and $r[$n - 1] -eq $r[$n - 3] -and $r[$n - 2] -eq $r[$n - 4] -and $r[$n - 1] -ne $r[$n - 2])
}

function Get-LoopNote {
    <# What goes back to Copilot the first time. Kind 'flip' (with the paths) or 'alternate'. #>
    param([ValidateSet('flip', 'alternate')][string]$Kind, [string[]]$Paths)
    if ($Kind -eq 'flip') {
        "$($Paths -join ', ') $(if (@($Paths).Count -gt 1) { 'are' } else { 'is' }) back to a version $(if (@($Paths).Count -gt 1) { 'they' } else { 'it' }) had earlier in this task: a change was undone, or made again after it was undone. Do not switch between the two again. Decide which version is right, say why in one line, and build on it; if neither works, say what blocks you and finish with a done block that says so. The next time a change is undone, the helper program stops the task."
    } else {
        'Your last rounds alternate between the same two sets of steps without progress. Do not repeat them. Use what the earlier results already showed, make the change, or finish with a done block that says what blocks you. The next time this happens, the helper program stops the task.'
    }
}

Export-ModuleMember -Function New-LoopWatch, Add-LoopFileVersion, Get-RoundKey, Add-LoopRound, Get-LoopNote
