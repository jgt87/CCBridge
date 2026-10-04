<#
  Which code-block labels Copilot's page shows as something else (for example a Chart.js chart
  with "Invalid JSON", or a "not fully supported" note) instead of plain code. For each label it
  sends one short message in a new chat asking Copilot to repeat a small code block with that label,
  then reads what the page shows for that reply. The reply text itself is not affected: StreamHub
  reads the raw text, not the page. Report: C:\temp\StreamHub-render-test-<time>.txt (labels and
  what the page showed; no other content). Uses one Copilot message per label.
#>
param([string]$Labels = 'read,text read,plaintext read,text,plaintext,(none)', [string]$OutRoot = 'C:\temp')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Log', 'Config', 'Cdp', 'CopilotBridge') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$cfg = Get-CCBridgeConfig harness $root
Initialize-CCBLog -Level info -Config $cfg
$list = @($Labels.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$null = New-Item -ItemType Directory -Force -Path $OutRoot
$out = Join-Path $OutRoot ('StreamHub-render-test-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt')
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$t) { Write-Host $t; $lines.Add($t) }

# What the page shows for the last reply: a chart, an "Invalid JSON" box, a "not supported" note,
# and the label above its code block.
$probe = @'
(() => {
  const reply = [...document.querySelectorAll('[data-testid="lastChatMessage"]')].pop();
  if (!reply) return JSON.stringify({ found: false });
  const text = reply.innerText || '';
  const note = (text.match(/[^\n]*(isn.t fully supported|not supported)[^\n]*/i) || [''])[0].slice(0, 120);
  return JSON.stringify({ found: true, chart: /chart\.?js/i.test(text) || !!reply.querySelector('canvas'), invalid: /invalid json/i.test(text), note,
    head: text.split('\n').map(s => s.trim()).filter(Boolean).slice(0, 2).join(' / ').slice(0, 80) });
})()
'@

Say "StreamHub render test, $((Get-Date).ToString('yyyy-MM-dd HH:mm')). Labels: $($list -join ', ')"
$bridge = Connect-Copilot -Port ([int]$cfg.cdpPort)
try {
    New-CopilotChat $bridge
    foreach ($l in $list) {
        $fence = if ($l -eq '(none)') { '```' } else { '```' + $l }
        $prompt = "Repeat the following code block exactly as it is, including its label, with no other words before or after it:`n`n$fence`nindex.html:10-30`nstyles.css:outline`n``````"
        $r = Send-CopilotPrompt $bridge $prompt
        Start-Sleep -Seconds 3
        $p = (Invoke-CdpEval $bridge.Session $probe) | ConvertFrom-Json
        $how = if (-not $p.found) { 'reply not found on the page' }
            elseif ($p.chart -or $p.invalid) { "SHOWN AS A CHART$(if ($p.invalid) { ' (Invalid JSON)' })" }
            elseif ($p.note) { "code block with a note: $($p.note)" }
            else { 'plain code block' }
        Say ("  {0,-10} {1}   [reply: {2}; page starts: {3}]" -f $l, $how, $r.Result, $p.head)
    }
} finally { Disconnect-Copilot $bridge }
[IO.File]::WriteAllLines($out, $lines)
Write-Host ''
Write-Host "Saved: $out" -ForegroundColor Green
