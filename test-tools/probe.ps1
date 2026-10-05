<#
.SYNOPSIS
  CCBridge Phase 0 feasibility probe. Read-only apart from a throwaway Edge
  profile in %TEMP% that is deleted afterwards.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File probe.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipCdp,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
if (-not $ReportPath) { $ReportPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'probe-report.txt' }
$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Check, [string]$Status, [string]$Detail) {
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p
}

# --- PowerShell environment -------------------------------------------------
Add-Result 'PowerShell version' 'INFO' $PSVersionTable.PSVersion.ToString()

$mode = $ExecutionContext.SessionState.LanguageMode.ToString()
Add-Result 'Language mode' $(if ($mode -eq 'FullLanguage') { 'OK' } else { 'FAIL' }) $mode

$policies = (Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ', '
$gpoBlocked = (Get-ExecutionPolicy -Scope MachinePolicy) -ne 'Undefined' -or (Get-ExecutionPolicy -Scope UserPolicy) -ne 'Undefined'
Add-Result 'Execution policy' $(if ($gpoBlocked) { 'WARN' } else { 'OK' }) $policies

Add-Result '.NET Framework' 'INFO' ([System.Runtime.InteropServices.RuntimeEnvironment]::GetSystemVersion())

try {
    $null = New-Object System.Net.WebSockets.ClientWebSocket
    Add-Result 'ClientWebSocket' 'OK' 'available'
} catch { Add-Result 'ClientWebSocket' 'FAIL' $_.Exception.Message }

# --- Local web server ---------------------------------------------------------
try {
    $port = Get-FreePort
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()
    $pending = $listener.GetContextAsync()
    $client = New-Object System.Net.WebClient
    $download = $client.DownloadStringTaskAsync("http://localhost:$port/")
    if (-not $pending.Wait(5000)) { throw 'no request received within 5s' }
    $ctx = $pending.Result
    $bytes = [System.Text.Encoding]::UTF8.GetBytes('pong')
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
    if (-not $download.Wait(5000)) { throw 'no response within 5s' }
    $listener.Stop()
    Add-Result 'HttpListener localhost' $(if ($download.Result -eq 'pong') { 'OK' } else { 'FAIL' }) "port $port"
} catch { Add-Result 'HttpListener localhost' 'FAIL' $_.Exception.Message }

# --- Edge ---------------------------------------------------------------------
$edgeCandidates = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
)
$edge = $edgeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($edge) {
    Add-Result 'Edge' 'OK' "$edge ($((Get-Item $edge).VersionInfo.ProductVersion))"
} else {
    Add-Result 'Edge' 'FAIL' 'msedge.exe not found'
}

$policyKeys = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'
$remoteDebug = $null; $devTools = $null
foreach ($k in $policyKeys) {
    if (Test-Path $k) {
        $p = Get-ItemProperty $k
        if ($null -ne $p.RemoteDebuggingAllowed) { $remoteDebug = $p.RemoteDebuggingAllowed }
        if ($null -ne $p.DeveloperToolsAvailability) { $devTools = $p.DeveloperToolsAvailability }
    }
}
Add-Result 'Policy RemoteDebuggingAllowed' $(if ($remoteDebug -eq 0) { 'FAIL' } else { 'OK' }) $(if ($null -eq $remoteDebug) { 'not set (allowed)' } else { "$remoteDebug" })
# DeveloperToolsAvailability: 0/1 = allowed, 2 = blocked (also blocks remote debugging)
Add-Result 'Policy DeveloperToolsAvailability' $(if ($devTools -eq 2) { 'FAIL' } else { 'OK' }) $(if ($null -eq $devTools) { 'not set (allowed)' } else { "$devTools" })

# --- Live CDP test ------------------------------------------------------------
if ($edge -and -not $SkipCdp) {
    $profileDir = Join-Path $env:TEMP ("ccbridge-probe-" + [guid]::NewGuid().ToString('N'))
    $proc = $null
    try {
        $cdpPort = Get-FreePort
        $edgeArgs = "--headless=new --remote-debugging-port=$cdpPort --user-data-dir=`"$profileDir`" --no-first-run --no-default-browser-check about:blank"
        $proc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru
        $info = $null
        for ($i = 0; $i -lt 30 -and -not $info; $i++) {
            Start-Sleep -Milliseconds 500
            try { $info = Invoke-RestMethod "http://127.0.0.1:$cdpPort/json/version" -TimeoutSec 2 } catch { }
        }
        if (-not $info) { throw "no CDP endpoint on port $cdpPort after 15s" }

        # Round trip over the WebSocket: evaluate 1+1 in the blank page.
        $target = (Invoke-RestMethod "http://127.0.0.1:$cdpPort/json/list") | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.ConnectAsync([uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
        $msg = [Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Runtime.evaluate","params":{"expression":"1+1"}}')
        $ws.SendAsync((New-Object ArraySegment[byte] -ArgumentList @(, $msg)), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
        $buf = New-Object byte[] 4096
        $recv = $ws.ReceiveAsync((New-Object ArraySegment[byte] -ArgumentList @(, $buf)), [Threading.CancellationToken]::None)
        if (-not $recv.Wait(5000)) { throw 'no CDP reply within 5s' }
        $reply = [Text.Encoding]::UTF8.GetString($buf, 0, $recv.Result.Count) | ConvertFrom-Json
        $ws.Dispose()
        if ($reply.result.result.value -ne 2) { throw "unexpected CDP reply: $($reply | ConvertTo-Json -Compress -Depth 5)" }
        Add-Result 'CDP round trip' 'OK' "$($info.Browser), Runtime.evaluate(1+1)=2"
    } catch {
        Add-Result 'CDP round trip' 'FAIL' $_.Exception.Message
    } finally {
        # Edge child processes often exit on their own while the tree is being
        # killed; taskkill then reports errors that are harmless, so silence them
        # in cmd (PS 5.1 would turn native stderr into a terminating error).
        if ($proc -and -not $proc.HasExited) { cmd.exe /c "taskkill /PID $($proc.Id) /T /F >nul 2>&1" }
        Start-Sleep -Milliseconds 500
        Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} elseif ($SkipCdp) {
    Add-Result 'CDP round trip' 'SKIP' '-SkipCdp'
}

# --- Optional toolchain (informational) ---------------------------------------
foreach ($tool in 'git', 'dotnet', 'node', 'python') {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    Add-Result "Tool: $tool" 'INFO' $(if ($cmd) { $cmd.Source } else { 'not found' })
}
$csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework64\v4*\csc.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
Add-Result 'Tool: csc.exe (.NET Framework)' 'INFO' $(if ($csc) { $csc.FullName } else { 'not found' })

# --- Report -------------------------------------------------------------------
$table = $results | Format-Table -AutoSize -Wrap | Out-String -Width 200
$fails = @($results | Where-Object Status -eq 'FAIL').Count
$verdict = if ($fails -eq 0) { 'VERDICT: CDP approach is feasible on this machine.' }
           else { "VERDICT: $fails check(s) failed - see FAIL rows; manual relay mode may be required." }
$footer = @"
$verdict

Manual check still needed: open https://m365.cloud.microsoft/chat, paste a very long
text (e.g. 20,000 characters) and note where Copilot cuts it off or refuses it.
"@
$report = "CCBridge probe - $(Get-Date -Format s) - $env:COMPUTERNAME`r`n$table`r`n$footer"
$report
[IO.File]::WriteAllText($ReportPath, $report, (New-Object Text.UTF8Encoding($false)))
Write-Host "Report written to $ReportPath"
