<#
.SYNOPSIS
  CCBridge - local coding harness that uses M365 Copilot Chat (in Edge) as its model.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File ccbridge.ps1
  Starts the web interface on http://localhost:8765/.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File ccbridge.ps1 -Ping "say hi" -NewChat
  Sends one prompt to Copilot and prints the reply.
.EXAMPLE
  start.cmd -LogLevel verbose
  Detailed diagnostic log in %LOCALAPPDATA%\CCBridge\logs (export with diagnostics.cmd).
#>
[CmdletBinding()]
param(
    [string]$Ping,
    [switch]$NewChat,
    [switch]$NoBrowser,
    [int]$Port,
    [switch]$NoUpdate,
    [ValidateSet('off', 'info', 'verbose', 'trace')][string]$LogLevel
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
# Update before anything is loaded (GitHub; skipped offline, for local edits or "autoUpdate": false).
if (-not $NoUpdate) { & (Join-Path $root 'tools\update.ps1') }

if ($Ping) {
    Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force
    Import-Module (Join-Path $root 'lib\Config.psm1')
    Import-Module (Join-Path $root 'lib\Log.psm1')
    Initialize-CCBLog -Level $LogLevel -Config (Get-CCBridgeConfig harness $root)
    $bridge = Connect-Copilot
    try {
        if ($NewChat) { New-CopilotChat $bridge }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Send-CopilotPrompt $bridge $Ping -OnProgress { param($t) Write-Host -NoNewline "`r  receiving... $($t.Length) chars" }
        Write-Host ''
        if (-not $r.SentMatches) { Write-Warning "Copilot received different text than was sent: $($r.SentText)" }
        if ($r.Uncertain) { Write-Warning "$($r.Uncertain) part(s) of the reply had to be repaired after Copilot's link filter." }
        Write-Host ("[{0}, {1:N1}s, conversation {2}]" -f $r.Result, $sw.Elapsed.TotalSeconds, $r.ConversationId)
        $r.Text
    } finally {
        Disconnect-Copilot $bridge
    }
    return
}

Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Server.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
$config = Get-CCBridgeConfig harness $root
if ($Port) { $config.port = $Port }
# Already running? Then just open it instead of failing on the busy port.
$url = "http://localhost:$($config.port)/"
try {
    $page = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 3
    if ($page.Content -match '<title>CCBridge</title>') {
        Write-Host "CCBridge is already running at $url - opening it."
        if (-not $NoBrowser) { Start-Process $url }
        return
    }
    throw "Port $($config.port) is used by another program. Start CCBridge on another port: ccbridge.ps1 -Port 8766"
} catch [System.Net.WebException] {
    # No response at all: nothing is listening, so start normally.
    if ($_.Exception.Response) { throw "Port $($config.port) is used by another program. Start CCBridge on another port: ccbridge.ps1 -Port 8766" }
}
Import-Module (Join-Path $root 'lib\Log.psm1')
Initialize-CCBLog -Level $LogLevel -Config $config
$state = New-AgentState -Config $config -AppRoot $root
$state.LogLevel = Get-CCBLogLevel
$state.Version = Get-CCBridgeVersion $root
Start-CCBridgeServer -State $state -NoBrowser:$NoBrowser
