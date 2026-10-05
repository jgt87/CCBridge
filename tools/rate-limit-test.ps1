<#
  Whether Copilot stops answering after a number of prompts sent back to back. Sends tiny made-up
  prompts ("reply with only the number N") one after another and records, per prompt, whether the
  answer was right, how long it took, and what came back instead (a refusal such as "Sorry, I wasn't
  able to respond to that", no answer, a limit message). Stops after -StopAfter failures in a row.
  No Microsoft 365 data is asked for or reported; Work IQ is left as it is.
  Uses up to -Count Copilot messages. Report: C:\temp\StreamHub-rate-limit-<time>.txt

  -Count 40        prompts at most
  -GapSec 0        seconds between a reply and the next prompt (0 = as fast as the page allows)
  -NewChatEvery 0  start a new chat every N prompts (0 = one chat; a chat has its own message cap)
  -StopAfter 3     failures in a row that end the test
#>
param([int]$Count = 40, [double]$GapSec = 0, [int]$NewChatEvery = 0, [int]$StopAfter = 3, [string]$OutRoot = 'C:\temp')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Log', 'Config', 'Cdp', 'CopilotBridge', 'Schedule') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$cfg = Get-CCBridgeConfig harness $root
Initialize-CCBLog -Level info -Config $cfg

$null = New-Item -ItemType Directory -Force -Path $OutRoot
$out = Join-Path $OutRoot ('StreamHub-rate-limit-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt')
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$t, [string]$Color = '') { if ($Color) { Write-Host $t -ForegroundColor $Color } else { Write-Host $t }; $lines.Add($t) }
function Get-Short([string]$Text) { $t = ($Text -replace '\s+', ' ').Trim(); if ($t.Length -gt 90) { $t.Substring(0, 87) + '...' } else { $t } }

Say "StreamHub rate limit test, $((Get-Date).ToString('yyyy-MM-dd HH:mm')): up to $Count prompts, gap $GapSec s, new chat every $(if ($NewChatEvery) { $NewChatEvery } else { 'never' }), stop after $StopAfter failures in a row"
Say ''
Say ' #   time      sec  result     answer'

$bridge = Connect-Copilot -Port ([int]$cfg.cdpPort)
# The test sets the gap itself; StreamHub's own pause between prompts would hide the limit.
if ($bridge.PSObject.Properties['Pacing'] -and $bridge.Pacing) { $bridge.Pacing['betweenPromptsSec'] = $GapSec; $bridge.Pacing['lateReplySec'] = 0 }
$ok = 0; $fails = 0; $inRow = 0; $firstFail = 0; $start = Get-Date
try {
    New-CopilotChat $bridge
    for ($i = 1; $i -le $Count; $i++) {
        if ($NewChatEvery -gt 0 -and $i -gt 1 -and (($i - 1) % $NewChatEvery) -eq 0) { New-CopilotChat $bridge; Say '     (new chat)' }
        $n = Get-Random -Minimum 100 -Maximum 999
        $t0 = Get-Date
        $kind = ''; $answer = ''
        try {
            $r = Send-CopilotPrompt $bridge "Reply with only the number $n and nothing else." -TimeoutSec 120 -StallSec 60
            $answer = "$($r.Text)"
            if ($r.Result -ne 'Success') { $kind = "$($r.Result)" }
            elseif ($answer -match "\b$n\b") { $kind = 'ok' }
            elseif ($answer -match '(?i)wasn.t able to respond|can.t respond|unable to respond|try again later|something went wrong') { $kind = 'refused' }
            elseif (Test-LimitText $answer) { $kind = 'limit' }
            else { $kind = 'wrong' }
            if ($r.Throttling -and $r.Throttling.maxNumUserMessagesInConversation) { $answer += "  [chat $($r.Throttling.numUserMessagesInConversation)/$($r.Throttling.maxNumUserMessagesInConversation)]" }
            if ($r.Metering) { $answer += "  [credits $($r.Metering.remainingAllowance)/$($r.Metering.totalAllowance)]" }
        } catch {
            $answer = $_.Exception.Message
            $kind = if (Test-LimitText $answer) { 'limit' } else { 'error' }
        }
        $sec = [int]((Get-Date) - $t0).TotalSeconds
        $row = ' {0,-3} {1}  {2,4}  {3,-9}  {4}' -f $i, $t0.ToString('HH:mm:ss'), $sec, $kind, (Get-Short $answer)
        if ($kind -eq 'ok') { $ok++; $inRow = 0; Say $row }
        else {
            $fails++; $inRow++; if (-not $firstFail) { $firstFail = $i }
            Say $row 'Yellow'
            if ($kind -eq 'limit') { Say '     Copilot reports its daily limit: stopping.' 'Yellow'; break }
            if ($inRow -ge $StopAfter) { Say "     $StopAfter failures in a row: stopping." 'Yellow'; break }
        }
    }
} finally { Disconnect-Copilot $bridge }

$mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
Say ''
Say "Sent $($ok + $fails) prompt(s) in $mins min: $ok answered, $fails failed."
if ($firstFail) { Say "First failure at prompt $firstFail; $(if ($ok -ge $firstFail) { 'Copilot answered again after it' } else { 'no right answer after it' })." 'Yellow' }
else { Say 'No failures: no limit was reached at this pace.' 'Green' }
Say 'Try it again with a gap (-GapSec 10) or new chats (-NewChatEvery 10) to see what avoids it.'
[IO.File]::WriteAllLines($out, $lines)
Write-Host ''
Write-Host "Saved: $out" -ForegroundColor Green
