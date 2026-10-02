<#
.SYNOPSIS
  Records how Microsoft 365 Copilot Chat exposes the Work IQ toggle and source references,
  so CCBridge can drive them. Run it on a machine with a Microsoft 365 Copilot licence.
.DESCRIPTION
  Keeps only UI control labels/states, request field names, option names and enum-like values.
  Message text, names, IDs, subjects, URLs and tokens are not recorded. Review the report
  (capture-report.json) before sharing it.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Cdp.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force
$sel = Get-CCBridgeConfig selectors $root
$port = 9333
$report = [ordered]@{ captured = (Get-Date).ToString('s'); edge = $null; snapshots = [ordered]@{}; request = $null; reply = $null }

function Pause-ForUser([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan; [void](Read-Host 'Press Enter to continue') }

$null = Start-CdpEdge -Port $port -Url $sel.chatUrl
$target = Get-CopilotTarget -Port $port -Selectors $sel
$s = Connect-Cdp $target.webSocketDebuggerUrl
$report.edge = (Invoke-RestMethod "http://127.0.0.1:$port/json/version").Browser
$null = Invoke-Cdp $s 'Network.enable'

# Controls that could be the Work/Web switch, mode pickers or source/reference pickers.
# Only labels and states are kept, never free text from the conversation.
$controlsJs = @'
(() => {
  const all = []; const walk = (r) => { for (const e of r.querySelectorAll('*')) { all.push(e); if (e.shadowRoot) walk(e.shadowRoot); } }; walk(document);
  const interesting = /work|iq|web|ground|source|scope|mode|search|tab|toggle|switch|reference|attach|plus|mention|context/i;
  const pick = (e) => {
    const a = (n) => e.getAttribute(n);
    const label = (a('aria-label') || '') + ' ' + (a('title') || '') + ' ' + (a('data-testid') || '') + ' ' + (e.id || '');
    const stateful = ['aria-checked','aria-pressed','aria-selected','aria-expanded'].some(n => e.hasAttribute(n));
    const role = a('role') || '';
    const isControl = e.matches('button, [role=tab], [role=switch], [role=radio], [role=menuitemradio], [role=option], input[type=checkbox], input[type=radio]');
    if (!isControl) return null;
    const text = (e.innerText || '').trim().replace(/\s+/g, ' ');
    if (!(stateful || /tab|switch|radio|option/.test(role) || interesting.test(label + ' ' + text))) return null;
    if (/account|profile|avatar|persona/i.test(label)) return null;
    return { tag: e.tagName.toLowerCase(), role, id: e.id || undefined, testid: a('data-testid') || undefined,
      aria: (a('aria-label') || '').slice(0, 60) || undefined, title: (a('title') || '').slice(0, 60) || undefined,
      text: text.length <= 30 ? text : undefined,
      checked: a('aria-checked') || undefined, pressed: a('aria-pressed') || undefined, selected: a('aria-selected') || undefined,
      cls: (typeof e.className === 'string' ? e.className : '').split(/\s+/).filter(c => /^(fui-|fai-|ms-|fx-)/.test(c)).slice(0, 4).join(' ') || undefined };
  };
  return JSON.stringify(all.map(pick).filter(Boolean).slice(0, 200));
})()
'@
function Get-Controls { (Invoke-CdpEval $s $controlsJs) | ConvertFrom-Json }

Write-Host 'CCBridge capture for Microsoft 365 Copilot (Work IQ toggle and sources)' -ForegroundColor White
Write-Host 'An Edge window with Copilot Chat is open. Sign in there with your WORK account if asked.'

Pause-ForUser '1/4  Turn Work IQ ON, with an empty chat.'
$report.snapshots.workIqOn = @(Get-Controls)

Pause-ForUser '2/4  Turn Work IQ OFF.'
$report.snapshots.workIqOff = @(Get-Controls)

Pause-ForUser '3/4  Turn Work IQ ON again. Click into the message box and type a single "/" (do not send). Leave the picker that opens visible.'
$report.snapshots.slashPicker = @(Get-Controls)

Write-Host ''
Write-Host '4/4  Now, with Work IQ ON, clear the message box and SEND this question yourself:' -ForegroundColor Cyan
Write-Host '     What is the subject of my most recent email, and which files did I work on recently? Answer briefly.' -ForegroundColor Yellow
Write-Host '     Waiting for Copilot''s answer (up to 4 minutes)...'

function Get-Shape($Value, [int]$Depth = 0) {
    # Field names and types only; enum-like short strings are kept, everything else is replaced.
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 4) { return '...' }
    if ($Value -is [string]) {
        if ($Value.Length -le 40 -and $Value -match '^[A-Za-z][A-Za-z0-9_.-]*$') { return $Value }
        return "<string $($Value.Length)>"
    }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return $Value.GetType().Name }
    if ($Value -is [array]) { return @($Value | Select-Object -First 3 | ForEach-Object { Get-Shape $_ ($Depth + 1) }) }
    $o = [ordered]@{}
    foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = Get-Shape $p.Value ($Depth + 1) }
    $o
}

$deadline = (Get-Date).AddMinutes(4)
while ((Get-Date) -lt $deadline -and -not $report.reply) {
    $m = Receive-CdpEvent $s 500
    if (-not $m) { continue }
    $dir = if ($m.method -eq 'Network.webSocketFrameSent') { 'out' } elseif ($m.method -eq 'Network.webSocketFrameReceived') { 'in' } else { continue }
    foreach ($part in $m.params.response.payloadData.Split([char]0x1e)) {
        if (-not $part.Trim()) { continue }
        try { $rec = $part | ConvertFrom-Json } catch { continue }
        if ($dir -eq 'out' -and $rec.target -eq 'chat' -or ($dir -eq 'out' -and $rec.arguments -and $rec.arguments[0].message)) {
            $arg = $rec.arguments[0]
            $report.request = [ordered]@{
                target = $rec.target
                fields = @($arg.PSObject.Properties.Name)
                optionsSets = @($arg.optionsSets)
                allowedMessageTypes = @($arg.allowedMessageTypes)
                plugins = Get-Shape $arg.plugins
                tone = $arg.tone; source = $arg.source
                messageFields = @($arg.message.PSObject.Properties.Name)
                messageShape = Get-Shape ($arg.message | Select-Object * -ExcludeProperty text)
                groundingLike = Get-Shape ($arg | Select-Object ($arg.PSObject.Properties.Name | Where-Object { $_ -match 'ground|work|iq|web|scope|enterprise|search|context|source' }))
            }
        }
        if ($dir -eq 'in' -and $rec.type -eq 2) {
            $bot = @($rec.item.messages | Where-Object { $_.author -eq 'bot' -and -not $_.messageType }) | Select-Object -Last 1
            $report.reply = [ordered]@{
                result = $rec.item.result.value
                messageTypes = @($rec.item.messages | ForEach-Object { "$($_.author):$($_.messageType):$($_.contentOrigin)" })
                botFields = @($bot.PSObject.Properties.Name)
                sourceAttributionCount = @($bot.sourceAttributions).Count
                sourceAttributionShape = Get-Shape (@($bot.sourceAttributions) | Select-Object -First 2)
                referencesShape = Get-Shape (@($bot.references) | Select-Object -First 2)
                hasCitationMarkers = [bool]($bot.text -match '\[\^?\d+\^?\]')
            }
        }
    }
}
Disconnect-Cdp $s

$out = Join-Path $root 'capture-report.json'
[IO.File]::WriteAllText($out, ($report | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
Write-Host ''
if (-not $report.reply) { Write-Host 'No Copilot answer was captured (step 4). The UI part of the report is still useful.' -ForegroundColor Yellow }
Write-Host "Report written to $out" -ForegroundColor Green
Write-Host 'Please look through it before sharing: it should contain only labels, field names and option names.'
