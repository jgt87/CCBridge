# Checks what StreamHub needs on this computer, at the start, after installing and with check.cmd:
# Windows PowerShell 5.1 in full language mode, .NET Framework, Edge and its policies, a local web
# server, free ports, OneDrive, a writable data folder, and (optional) GitHub and Copilot reachable.
# Every check is quick and read-only. Status: OK, WARN (works, with a limitation) or FAIL (StreamHub
# cannot work until it is fixed).

$ErrorActionPreference = 'Stop'

function New-Check([string]$Name, [string]$Status, [string]$Detail, [string]$Hint = '') {
    [pscustomobject]@{ name = $Name; status = $Status; detail = $Detail; hint = $Hint }
}

function Get-EdgeExePath {
    foreach ($p in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $null
}

function Get-EdgePolicyValue([string]$Name) {
    foreach ($k in 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKCU:\SOFTWARE\Policies\Microsoft\Edge') {
        try { $v = (Get-ItemProperty -Path $k -Name $Name -ErrorAction Stop).$Name; if ($null -ne $v) { return [int]$v } } catch { }
    }
    $null
}

function Get-DotNetVersionText([int]$Release) {
    <# .NET Framework 4.x version from its Release number. #>
    $map = @(@(533320, '4.8.1'), @(528040, '4.8'), @(461808, '4.7.2'), @(461308, '4.7.1'), @(460798, '4.7'), @(394802, '4.6.2'), @(394254, '4.6.1'), @(393295, '4.6'), @(379893, '4.5.2'), @(378675, '4.5.1'), @(378389, '4.5'))
    foreach ($m in $map) { if ($Release -ge $m[0]) { return $m[1] } }
    'older than 4.5'
}

function Test-PortListening([int]$Port) {
    @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port }).Count -gt 0
}

function Invoke-SafeCheck([string]$Name, [scriptblock]$Body) {
    <# Runs one check; when the check itself breaks, a WARN for it instead of an error. #>
    try { & $Body }
    catch { New-Check $Name 'WARN' "could not check: $($_.Exception.Message.Split("`n")[0])" 'This check itself failed; StreamHub may still work.' }
}

function Get-PrereqChecks {
    <# The checks, in order. -Online adds GitHub and Copilot reachability (a few seconds at most).
       Each check runs in its own guard (Invoke-SafeCheck): one that breaks is a WARN, never fatal. #>
    param([int]$WebPort = 8765, [int]$CdpPort = 9333, [switch]$Online)
    $out = New-Object System.Collections.Generic.List[object]

    $out.Add((Invoke-SafeCheck 'Windows PowerShell' {
        $v = $PSVersionTable.PSVersion
        if ($PSVersionTable.PSEdition -eq 'Desktop' -and $v.Major -eq 5 -and $v.Minor -ge 1) { New-Check 'Windows PowerShell' 'OK' "$v" }
        elseif ($PSVersionTable.PSEdition -eq 'Core') { New-Check 'Windows PowerShell' 'WARN' "running in PowerShell $v" 'StreamHub is made for Windows PowerShell 5.1: start it with start.cmd.' }
        else { New-Check 'Windows PowerShell' 'FAIL' "$v" 'Windows PowerShell 5.1 is needed (part of Windows 10 and 11).' }
    }))

    $out.Add((Invoke-SafeCheck 'Language mode' {
        $mode = $ExecutionContext.SessionState.LanguageMode.ToString()
        if ($mode -eq 'FullLanguage') { New-Check 'Language mode' 'OK' $mode } else { New-Check 'Language mode' 'FAIL' $mode 'Constrained Language mode (AppLocker or WDAC) blocks StreamHub. Ask IT whether scripts may run in Full Language mode.' }
    }))

    $out.Add((Invoke-SafeCheck 'Execution policy' {
        # Group Policy sets it under Policies\...\PowerShell; read directly, because the cmdlet's
        # module may not load when Windows PowerShell is started from PowerShell 7.
        $gpo = @(foreach ($k in @(@('MachinePolicy', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'), @('UserPolicy', 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'))) {
            $p = try { (Get-ItemProperty -Path $k[1] -Name ExecutionPolicy -ErrorAction Stop).ExecutionPolicy } catch { $null }
            if ($p) { "$($k[0])=$p" }
        })
        if (-not $gpo.Count) { New-Check 'Execution policy' 'OK' 'not set by Group Policy (start.cmd bypasses it for StreamHub only)' }
        elseif ($gpo -match 'Unrestricted|Bypass|RemoteSigned') { New-Check 'Execution policy' 'OK' ($gpo -join ', ') }
        else { New-Check 'Execution policy' 'WARN' ($gpo -join ', ') 'Group Policy sets the execution policy; if StreamHub does not start, ask IT to allow it.' }
    }))

    $out.Add((Invoke-SafeCheck '.NET Framework' {
        $rel = try { [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release } catch { 0 }
        $dn = Get-DotNetVersionText $rel
        if ($rel -ge 461808) { New-Check '.NET Framework' 'OK' $dn }
        elseif ($rel -ge 378389) { New-Check '.NET Framework' 'WARN' $dn 'Windows Update brings .NET Framework 4.8; older versions may fail on secure connections.' }
        else { New-Check '.NET Framework' 'FAIL' $dn '.NET Framework 4.5 or newer is needed (Windows Update).' }
    }))

    $out.Add((Invoke-SafeCheck 'Microsoft Edge' {
        $edge = Get-EdgeExePath
        if ($edge) { New-Check 'Microsoft Edge' 'OK' "$((Get-Item -LiteralPath $edge).VersionInfo.ProductVersion)" }
        else { New-Check 'Microsoft Edge' 'FAIL' 'msedge.exe not found' 'StreamHub drives Copilot in Microsoft Edge; install or repair Edge.' }
    }))

    $out.Add((Invoke-SafeCheck 'Edge remote debugging' {
        $rd = Get-EdgePolicyValue 'RemoteDebuggingAllowed'
        $dt = Get-EdgePolicyValue 'DeveloperToolsAvailability'
        if ($rd -eq 0) { New-Check 'Edge remote debugging' 'FAIL' 'blocked by policy (RemoteDebuggingAllowed = 0)' 'StreamHub needs it to drive Copilot; ask IT to allow it.' }
        elseif ($dt -eq 2) { New-Check 'Edge remote debugging' 'FAIL' 'developer tools blocked by policy (DeveloperToolsAvailability = 2)' 'StreamHub needs them to drive Copilot; ask IT to allow them.' }
        else { New-Check 'Edge remote debugging' 'OK' 'allowed' }
    }))

    $out.Add((Invoke-SafeCheck 'Local web server' {
        try {
            $l = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0); $l.Start(); $free = ([Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop()
            $h = New-Object Net.HttpListener; $h.Prefixes.Add("http://localhost:$free/"); $h.Start(); $h.Stop(); $h.Close()
            New-Check 'Local web server' 'OK' 'HttpListener on localhost works'
        } catch { New-Check 'Local web server' 'FAIL' $_.Exception.Message.Split("`n")[0] 'Windows'' HTTP service (http.sys) is needed for the web app on localhost.' }
    }))

    $out.Add((Invoke-SafeCheck "Port $WebPort (web app)" {
        $pidFile = Join-Path $env:LOCALAPPDATA 'CCBridge\server.pid'
        $ours = $false
        if (Test-Path -LiteralPath $pidFile) { $id = ([IO.File]::ReadAllText($pidFile) -split '\|')[0]; $ours = [bool](Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue) }
        if (-not (Test-PortListening $WebPort)) { New-Check "Port $WebPort (web app)" 'OK' 'free' }
        elseif ($ours) { New-Check "Port $WebPort (web app)" 'OK' 'used by StreamHub, which is running (a new start replaces it)' }
        else { New-Check "Port $WebPort (web app)" 'WARN' 'in use by another program' "Set another port: ""port"" in config\harness.local.json, or start with -Port." }
    }))

    $out.Add((Invoke-SafeCheck "Port $CdpPort (Edge for Copilot)" {
        $cdpUp = Test-PortListening $CdpPort
        $isEdge = $false
        if ($cdpUp) { try { $isEdge = [bool](Invoke-RestMethod "http://127.0.0.1:$CdpPort/json/version" -TimeoutSec 2).Browser } catch { } }
        if (-not $cdpUp) { New-Check "Port $CdpPort (Edge for Copilot)" 'OK' 'free' }
        elseif ($isEdge) { New-Check "Port $CdpPort (Edge for Copilot)" 'OK' "StreamHub's Edge is already running" }
        else { New-Check "Port $CdpPort (Edge for Copilot)" 'WARN' 'in use by another program' 'Set another port: "cdpPort" in config\harness.local.json.' }
    }))

    $out.Add((Invoke-SafeCheck 'OneDrive' {
        if ($env:OneDriveCommercial -and (Test-Path -LiteralPath $env:OneDriveCommercial)) { New-Check 'OneDrive' 'OK' "work or school: $env:OneDriveCommercial" }
        elseif ($env:OneDrive -and (Test-Path -LiteralPath $env:OneDrive)) { New-Check 'OneDrive' 'OK' "$env:OneDrive" }
        else { New-Check 'OneDrive' 'WARN' 'not found' 'The web app keeps projects in OneDrive; sign in to OneDrive. (The MCP server works without it.)' }
    }))

    $out.Add((Invoke-SafeCheck 'Data folder' {
        try {
            $dataDir = Join-Path $env:LOCALAPPDATA 'CCBridge'
            $null = New-Item -ItemType Directory -Force -Path $dataDir
            $probe = Join-Path $dataDir ('.write-test-' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($probe, 'x'); [IO.File]::Delete($probe)
            New-Check 'Data folder' 'OK' $dataDir
        } catch { New-Check 'Data folder' 'FAIL' $_.Exception.Message.Split("`n")[0] "StreamHub keeps its state in %LOCALAPPDATA%\CCBridge; it must be writable." }
    }))

    if ($Online) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        foreach ($t in @(@('GitHub (updates)', 'https://api.github.com/repos/jgt87/CCBridge', 'Updates are skipped while GitHub cannot be reached; StreamHub still runs.'),
                         @('Copilot site', 'https://www.microsoft365.com/', 'Copilot must be reachable from this computer (proxy or firewall?).'))) {
            $out.Add((Invoke-SafeCheck $t[0] {
                try {
                    $null = Invoke-WebRequest $t[1] -Method Head -UseBasicParsing -TimeoutSec 5 -Headers @{ 'User-Agent' = 'StreamHub-check' }
                    New-Check $t[0] 'OK' 'reachable'
                } catch {
                    # Any HTTP answer means the site is reachable; only no answer at all is a problem.
                    if ($_.Exception.Response) { New-Check $t[0] 'OK' "reachable (HTTP $([int]$_.Exception.Response.StatusCode))" }
                    else { New-Check $t[0] 'WARN' $_.Exception.Message.Split("`n")[0] $t[2] }
                }
            }))
        }
    }
    $out.ToArray()
}
function Write-PrereqReport {
    <# Prints the checks as "[OK] name  detail" with the status word in colour, and the hint below
       anything that is not OK. Returns $true when nothing failed. #>
    param([Parameter(Mandatory)]$Checks, [string]$Title = 'System check')
    Write-Host $Title
    $w = [Math]::Max(10, (@($Checks | ForEach-Object { $_.name.Length }) | Measure-Object -Maximum).Maximum)
    foreach ($c in $Checks) {
        $color = switch ($c.status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
        Write-Host '  [' -NoNewline
        Write-Host $c.status -ForegroundColor $color -NoNewline
        Write-Host ']' -NoNewline
        Write-Host (' ' * (5 - $c.status.Length)) -NoNewline
        Write-Host $c.name.PadRight($w + 2) -NoNewline
        Write-Host $c.detail -ForegroundColor DarkGray
        if ($c.hint -and $c.status -ne 'OK') { Write-Host ((' ' * ($w + 11)) + $c.hint) -ForegroundColor $color }
    }
    -not @($Checks | Where-Object { $_.status -eq 'FAIL' }).Count
}

Export-ModuleMember -Function Get-PrereqChecks, Write-PrereqReport, Get-DotNetVersionText
