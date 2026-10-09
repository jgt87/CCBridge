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
    [switch]$NoCheck,
    [ValidateSet('off', 'info', 'verbose', 'trace')][string]$LogLevel
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
# Update before anything is loaded (GitHub; skipped offline, for local edits or "autoUpdate": false).
if (-not $NoUpdate) { & (Join-Path $root 'tools\update.ps1') }
# Is the app folder the release as shipped (manifest.json)? An update that stopped halfway leaves
# files missing or of another version: repair it once (the same version again), else say so in the app.
$installProblem = ''
try {
    Import-Module (Join-Path $root 'lib\Update.psm1') -Force
    $integrity = Test-InstallIntegrity $root
    $installProblem = Format-InstallProblem $integrity
    if ($installProblem) {
        Write-Host $installProblem -ForegroundColor Yellow
        if (-not $NoUpdate) {
            Write-Host 'Repairing it: installing the same version again...'
            & (Join-Path $root 'tools\update.ps1') -Repair
            $installProblem = Format-InstallProblem (Test-InstallIntegrity $root)
            if (-not $installProblem) { Write-Host 'Repaired.' }
        }
    }
} catch { Write-Host "The install check did not run: $($_.Exception.Message)" }

# What this computer has, every start (quick and read-only; check.cmd also tests GitHub and Copilot).
if (-not $NoCheck) {
    Import-Module (Join-Path $root 'lib\Prereq.psm1') -Force
# Shortcuts from before the rename are called StreamHub from now on (also after an automatic update).
try { foreach ($s in @(Rename-AppShortcuts)) { Write-Host "Renamed the shortcut to $s" } } catch { }
    Import-Module (Join-Path $root 'lib\Config.psm1') -Force
    $cfgCheck = Get-CCBridgeConfig harness $root
    $checkPort = if ($Port) { $Port } elseif ($cfgCheck.port) { [int]$cfgCheck.port } else { 8765 }
    $checks = Get-PrereqChecks -WebPort $checkPort -CdpPort ([int]$cfgCheck.cdpPort) -Tools   # the optional tools too (no network): Node.js and npm, Python, .NET, Git
    # Safe repairs (a busy port, OneDrive sign-in); a port given with -Port is kept.
    $checks = @(Repair-PrereqChecks $checks -AppRoot $root -KeepWebPort:([bool]$Port) -WebPort $checkPort -CdpPort ([int]$cfgCheck.cdpPort))
    $checksOk = Write-PrereqReport $checks
    Write-Host ''
    if (-not $checksOk) {
        Write-Host 'StreamHub cannot start until the FAIL items above are fixed (check.cmd tests again).' -ForegroundColor Red
        exit 1
    }
}

if ($Ping) {
    Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force
    Import-Module (Join-Path $root 'lib\Config.psm1')
    Import-Module (Join-Path $root 'lib\Log.psm1')
    Initialize-CCBLog -Level $LogLevel -Config (Get-CCBridgeConfig harness $root) -Build (Format-CCBBuild (Get-CCBridgeBuild $root)) -Role 'ping'
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
# Tools installed for this user from Settings > This computer (Node.js, .NET SDK...) are found by commands.
try { Import-Module (Join-Path $root 'lib\ToolInstall.psm1') -Force; Add-ToolPaths } catch { }
# An update that had to wait because the tool was in use (Node.js running) runs now, before StreamHub uses it.
try { foreach ($n in @(Start-PendingToolInstalls -AppRoot $root)) { Write-Host "Installing the pending update of $n in the background." } } catch { }
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
$config = Get-CCBridgeConfig harness $root
if ($Port) { $config.port = $Port }
$url = "http://localhost:$($config.port)/"

# A CCBridge that is still running would keep serving its old version (it holds the code in
# memory), also right after an update. Stop it, so this start always serves the current files.
# The web server runs through Windows' HTTP service, so the port belongs to "System": the
# instance is found by the process id it recorded and by its command line instead.
$pidFile = Join-Path $env:LOCALAPPDATA 'CCBridge\server.pid'
$stopped = @()
try {
    if (Test-Path $pidFile) {
        $rec = ([IO.File]::ReadAllText($pidFile)).Trim().Split('|')
        $old = Get-Process -Id ([int]$rec[0]) -ErrorAction SilentlyContinue
        if ($old -and $old.Id -ne $PID -and $old.ProcessName -match '^powershell' -and $old.StartTime.Ticks -eq [long]$rec[1]) {
            Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue; $stopped += $old.Id
        }
    }
} catch { }
try {
    # Other web-app instances (not the MCP server, not one-off -Ping runs).
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
        Where-Object { $_.ProcessId -ne $PID -and $stopped -notcontains $_.ProcessId -and $_.CommandLine -match 'ccbridge\.ps1' -and $_.CommandLine -notmatch '-Ping\b' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $stopped += $_.ProcessId }
} catch { }
if ($stopped.Count) {
    Write-Host "Stopped the StreamHub that was already running (process $($stopped -join ', ')), so this version starts."
    # Wait until the port is free again.
    $until = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 300
        $busy = $true
        try { $null = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2 } catch { $busy = [bool]$_.Exception.Response }
    } while ($busy -and (Get-Date) -lt $until)
}

# Still answering (for example another user's instance)? Then just open it instead of failing on the busy port.
try {
    $page = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 3
    # StreamHub's page carries its session-token tag (the title changed over versions).
    if ($page.Content -match 'name="ccb-token"|<title>(CCBridge|StreamHub)') {
        Write-Host "StreamHub is already running at $url - opening it."
        if (-not $NoBrowser) { Start-Process $url }
        return
    }
    throw "Port $($config.port) is used by another program. Start StreamHub on another port: ccbridge.ps1 -Port 8766"
} catch [System.Net.WebException] {
    # No response at all: nothing is listening, so start normally.
    if ($_.Exception.Response) { throw "Port $($config.port) is used by another program. Start StreamHub on another port: ccbridge.ps1 -Port 8766" }
}
Import-Module (Join-Path $root 'lib\Log.psm1')
Initialize-CCBLog -Level $LogLevel -Config $config -Build (Format-CCBBuild (Get-CCBridgeBuild $root)) -Role 'web app'
$state = New-AgentState -Config $config -AppRoot $root
$state.LogLevel = Get-CCBLogLevel
$state.Version = Get-CCBridgeVersion $root
$state.Build = Get-CCBridgeBuild $root
$state.InstallProblem = $installProblem   # shown as a banner in the app
# The queue survives restarts and updates (the MCP server's own engine does not save one).
$state.QueueFile = Join-Path $env:LOCALAPPDATA 'CCBridge\queue.json'
$null = Restore-AgentQueue $state
$state.SaveHistory = ($config.chatHistory -ne $false -and "$($config.chatHistory)" -ne 'off')   # the chat is kept per project and comes back after a restart
if ("$($config.startMode)" -in 'ask', 'auto', 'plan') { $state.Mode = "$($config.startMode)" }   # Settings > Mode at start
$state.ScheduleFile = Join-Path $env:LOCALAPPDATA 'CCBridge\schedules.json'
$null = Restore-Schedules $state
$state.PauseFile = Join-Path $env:LOCALAPPDATA 'CCBridge\queue-pause.json'
Restore-QueuePause $state
# Recorded so the next start can stop this instance (see above).
try {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $pidFile)
    [IO.File]::WriteAllText($pidFile, "$PID|$((Get-Process -Id $PID).StartTime.Ticks)")
} catch { }
Start-CCBridgeServer -State $state -NoBrowser:$NoBrowser
