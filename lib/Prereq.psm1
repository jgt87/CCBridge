# Checks what StreamHub needs on this computer, at the start, after installing and with check.cmd:
# Windows PowerShell 5.1 in full language mode, .NET Framework, Edge and its policies, a local web
# server, free ports, OneDrive, a writable data folder, and (optional) GitHub and Copilot reachable.
# Every check is quick and read-only. Status: OK, WARN (works, with a limitation) or FAIL (StreamHub
# cannot work until it is fixed). A check can name where to get what is missing (link) and a safe
# repair (fix) that Repair-PrereqChecks carries out: only what needs no admin rights and is not a
# company policy (a busy port, OneDrive sign-in). Policies always stay "ask IT".

$ErrorActionPreference = 'Stop'

# Official pages to get what is missing (all from Microsoft).
$script:Links = @{
    powershell = 'https://www.microsoft.com/download/details.aspx?id=54616'
    dotnet     = 'https://dotnet.microsoft.com/download/dotnet-framework/net48'
    edge       = 'https://www.microsoft.com/edge/download'
    onedrive   = 'https://www.microsoft.com/microsoft-365/onedrive/download'
}

function Get-DeviceJoinStatus {
    <# Whether this PC can sign in to work sites with the Windows account: the yes/no fields of
       dsregcmd /status (nothing else is read; no ids or names). $Lines is for tests. #>
    param([string[]]$Lines)
    if (-not $PSBoundParameters.ContainsKey('Lines')) { $Lines = @(cmd /c "dsregcmd /status 2>nul") }
    $out = [ordered]@{}
    foreach ($k in 'AzureAdJoined', 'DomainJoined', 'WorkplaceJoined', 'EnterpriseJoined', 'AzureAdPrt') {
        $m = @($Lines | Select-String -Pattern "^\s*$k\s*:\s*(YES|NO)\s*$") | Select-Object -First 1
        $out[$k] = if ($m) { $m.Matches[0].Groups[1].Value } else { '?' }
    }
    $out
}

function Rename-AppShortcuts {
    <# Shortcuts made before the rename (CCBridge.lnk on the desktop and in the Start menu) become
       StreamHub.lnk. Only shortcuts that start StreamHub's own start.cmd are touched; when a
       StreamHub.lnk is already there, the old one is removed. Returns the new paths. $Folders and
       $Target are for tests. #>
    param([string[]]$Folders = @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop')), [string]$Target = '')
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in @($Folders | Where-Object { $_ })) {
        $old = Join-Path $dir 'CCBridge.lnk'
        if (-not (Test-Path -LiteralPath $old -PathType Leaf)) { continue }
        $points = "$($shell.CreateShortcut($old).TargetPath)"
        $ours = if ($Target) { $points -ieq $Target } else { $points -match '(?i)\\CCBridge\\start\.cmd$' }
        if (-not $ours) { continue }
        $new = Join-Path $dir 'StreamHub.lnk'
        if (Test-Path -LiteralPath $new) { [IO.File]::Delete($old) } else { [IO.File]::Move($old, $new) }
        $new
    }
}

function New-Check([string]$Name, [string]$Status, [string]$Detail, [string]$Hint = '', [string]$Link = '', [string]$Fix = '') {
    [pscustomobject]@{ name = $Name; status = $Status; detail = $Detail; hint = $Hint; link = $Link; fix = $Fix }
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

function Get-OneDriveExePath {
    foreach ($p in @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $null
}

function Test-StreamHubPort([int]$Port) {
    <# Whether StreamHub's web app answers on this port (its page carries the session-token tag). #>
    try { (Invoke-WebRequest "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 2).Content -match 'name="ccb-token"' } catch { $false }
}

function Find-FreePort([int]$From, [int]$To, [int[]]$Avoid = @()) {
    for ($p = $From; $p -le $To; $p++) { if ($Avoid -notcontains $p -and -not (Test-PortListening $p)) { return $p } }
    $null
}

function Test-PortListening([int]$Port) {
    @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port }).Count -gt 0
}

function Invoke-SafeCheck([string]$Name, [scriptblock]$Body) {
    <# Runs one check; when the check itself breaks, a WARN for it instead of an error. #>
    try { & $Body }
    catch { New-Check $Name 'WARN' "could not check: $($_.Exception.Message.Split("`n")[0])" 'This check itself failed; StreamHub may still work.' }
}

function Get-ToolVersion([string]$Exe, [string[]]$Arguments = @('--version')) {
    # The first line a tool prints for its version, or $null when it is not installed (the Store's
    # python.exe stub in WindowsApps does not count: it only offers to install Python).
    $c = Get-Command $Exe -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
    if (-not $c) { return $null }
    # Some tools print their version to stderr: under Stop that would be an error, not the version.
    $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = try { & $c.Source @Arguments 2>&1 | Select-Object -First 1 } catch { $null } } finally { $ErrorActionPreference = $saved }
    $line = "$out".Trim()
    if (-not $line) { return '(installed; version unknown)' }
    $line
}

function Test-NpmRegistry {
    <# Whether npm can download packages: its registry answers through Windows' proxy settings
       (5 seconds at most). 'reachable', 'blocked', or $null when npm is not installed. #>
    $reg = Get-ToolVersion 'npm' @('config', 'get', 'registry')
    if (-not $reg) { return $null }
    if ($reg -notmatch '^https?://') { $reg = 'https://registry.npmjs.org/' }
    try {
        $null = Invoke-WebRequest -Uri $reg -UseBasicParsing -Method Head -TimeoutSec 5
        'reachable'
    } catch {
        # A registry that answers with an error status is reachable; only no answer means blocked.
        if ($_.Exception.Response) { 'reachable' } else { 'blocked' }
    }
}

function Get-OptionalToolChecks {
    <# Optional tools StreamHub uses when they are there: Pester (ships with Windows) and Python,
       Node.js, the .NET SDK and Git for projects that need them. Never a failure: INFO when a tool
       is missing (with what it would add), WARN only for a version too old to work well.
       -Registry also asks npm's registry (starts npm and a network request: only for the system
       check, never for Settings, which refreshes this list every few seconds during an install). #>
    param([switch]$Registry)
    $out = New-Object System.Collections.Generic.List[object]
    $out.Add((Invoke-SafeCheck 'Pester (PowerShell tests)' {
        $m = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
        if ($m) { New-Check 'Pester (PowerShell tests)' 'OK' "$($m.Version)$(if ($m.Version.Major -eq 3) { ' (ships with Windows)' })" }
        else { New-Check 'Pester (PowerShell tests)' 'INFO' 'not installed' 'Optional: runs the tests of PowerShell projects after a change. Windows normally includes it.' }
    }))
    $out.Add((Invoke-SafeCheck 'Python' {
        $v = Get-ToolVersion 'python'
        if (-not $v) { return New-Check 'Python' 'INFO' 'not installed' 'Optional: only for Python projects (running scripts and their tests). StreamHub runs without it.' 'https://www.python.org/downloads/windows/' }
        # No quotes in the Python code: Windows PowerShell 5.1 drops them when it starts a program.
        $test = Get-ToolVersion 'python' @('-c', 'import pytest; print(pytest.__version__)')
        $pytest = if ("$test" -match '^\d+\.\d') { "pytest $test" } else { 'no pytest (tests run with unittest)' }
        $old = ($v -match '(\d+)\.(\d+)') -and ([int]$Matches[1] -lt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -lt 8))
        New-Check 'Python' $(if ($old) { 'WARN' } else { 'OK' }) "$v, $pytest" $(if ($old) { 'Python 3.8 or newer is recommended.' } else { '' }) $(if ($old) { 'https://www.python.org/downloads/windows/' } else { '' })
    }))
    $out.Add((Invoke-SafeCheck 'Node.js' {
        $v = Get-ToolVersion 'node'
        if (-not $v) { return New-Check 'Node.js' 'INFO' 'not installed' 'Optional: only for projects with a package.json (npm scripts and tests). StreamHub runs without it.' 'https://nodejs.org/' }
        $npm = Get-ToolVersion 'npm'
        $old = ($v -match 'v?(\d+)\.') -and [int]$Matches[1] -lt 18
        $reg = if ($npm -and $Registry) { Test-NpmRegistry } else { $null }
        $blocked = $reg -eq 'blocked'
        $hint = @($(if ($old) { 'Node.js 18 or newer is recommended.' }), $(if ($blocked) { 'npm cannot reach its package registry (network or proxy): npm install will not work, so React and other npm projects cannot be built; plain HTML and JavaScript still work.' })) | Where-Object { $_ }
        New-Check 'Node.js' $(if ($old -or $blocked) { 'WARN' } else { 'OK' }) "$v$(if ($npm) { ", npm $npm$(if ($reg) { ", registry $reg" })" } else { ', no npm' })" ($hint -join ' ') $(if ($old) { 'https://nodejs.org/' } else { '' })
    }))
    foreach ($t in @(@('.NET SDK', 'dotnet', 'Optional: only for C# and .NET projects. StreamHub itself uses the .NET Framework that ships with Windows.', 'https://dotnet.microsoft.com/download'),
                     @('Git', 'git', 'Optional: StreamHub has no Git features, but your own Git tools work next to it.', 'https://git-scm.com/download/win'))) {
        $out.Add((Invoke-SafeCheck $t[0] {
            $v = Get-ToolVersion $t[1]
            if ($v) { New-Check $t[0] 'OK' $v } else { New-Check $t[0] 'INFO' 'not installed' $t[2] $t[3] }
        }))
    }
    $out.ToArray()
}

function Get-PrereqChecks {
    <# The checks, in order. -Online adds GitHub and Copilot reachability (a few seconds at most).
       Each check runs in its own guard (Invoke-SafeCheck): one that breaks is a WARN, never fatal. #>
    param([int]$WebPort = 8765, [int]$CdpPort = 9333, [switch]$Online, [switch]$Tools)
    $out = New-Object System.Collections.Generic.List[object]

    $out.Add((Invoke-SafeCheck 'Windows PowerShell' {
        $v = $PSVersionTable.PSVersion
        if ($PSVersionTable.PSEdition -eq 'Desktop' -and $v.Major -eq 5 -and $v.Minor -ge 1) { New-Check 'Windows PowerShell' 'OK' "$v" }
        elseif ($PSVersionTable.PSEdition -eq 'Core') { New-Check 'Windows PowerShell' 'WARN' "running in PowerShell $v" 'StreamHub is made for Windows PowerShell 5.1: start it with start.cmd.' }
        else { New-Check 'Windows PowerShell' 'FAIL' "$v" 'Windows PowerShell 5.1 is needed (part of Windows 10 and 11; older Windows: install Windows Management Framework 5.1).' $script:Links.powershell }
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
        elseif ($rel -ge 378389) { New-Check '.NET Framework' 'WARN' $dn 'Windows Update brings .NET Framework 4.8 (or install it yourself); older versions may fail on secure connections.' $script:Links.dotnet }
        else { New-Check '.NET Framework' 'FAIL' $dn '.NET Framework 4.5 or newer is needed: run Windows Update, or install .NET Framework 4.8.' $script:Links.dotnet }
    }))

    $out.Add((Invoke-SafeCheck 'Microsoft Edge' {
        $edge = Get-EdgeExePath
        if ($edge) { New-Check 'Microsoft Edge' 'OK' "$((Get-Item -LiteralPath $edge).VersionInfo.ProductVersion)" }
        else { New-Check 'Microsoft Edge' 'FAIL' 'msedge.exe not found' 'StreamHub drives Copilot in Microsoft Edge; install or repair Edge (no admin rights needed).' $script:Links.edge }
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
        if (Test-Path -LiteralPath $pidFile) {
            $id = [int](([IO.File]::ReadAllText($pidFile) -split '\|')[0])
            # Ours only when StreamHub is running and this port answers with StreamHub's page (the
            # web server runs on Windows' HTTP service, so the port's owner shows as System).
            $ours = [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) -and (Test-StreamHubPort $WebPort)
        }
        if (-not (Test-PortListening $WebPort)) { New-Check "Port $WebPort (web app)" 'OK' 'free' }
        elseif ($ours) { New-Check "Port $WebPort (web app)" 'OK' 'used by StreamHub, which is running (a new start replaces it)' }
        else { New-Check "Port $WebPort (web app)" 'WARN' 'in use by another program' "Set another port: ""port"" in config\harness.local.json, or start with -Port." '' 'port' }
    }))

    $out.Add((Invoke-SafeCheck "Port $CdpPort (Edge for Copilot)" {
        $cdpUp = Test-PortListening $CdpPort
        $isEdge = $false
        if ($cdpUp) { try { $isEdge = [bool](Invoke-RestMethod "http://127.0.0.1:$CdpPort/json/version" -TimeoutSec 2).Browser } catch { } }
        if (-not $cdpUp) { New-Check "Port $CdpPort (Edge for Copilot)" 'OK' 'free' }
        elseif ($isEdge) { New-Check "Port $CdpPort (Edge for Copilot)" 'OK' "StreamHub's Edge is already running" }
        else { New-Check "Port $CdpPort (Edge for Copilot)" 'WARN' 'in use by another program' 'Set another port: "cdpPort" in config\harness.local.json.' '' 'cdpPort' }
    }))

    $out.Add((Invoke-SafeCheck 'OneDrive' {
        if ($env:OneDriveCommercial -and (Test-Path -LiteralPath $env:OneDriveCommercial)) { New-Check 'OneDrive' 'OK' "work or school: $env:OneDriveCommercial" }
        elseif ($env:OneDrive -and (Test-Path -LiteralPath $env:OneDrive)) { New-Check 'OneDrive' 'OK' "$env:OneDrive" }
        elseif (Get-OneDriveExePath) { New-Check 'OneDrive' 'WARN' 'not signed in' 'The web app keeps projects in OneDrive; sign in to OneDrive. (The MCP server works without it.)' '' 'onedrive' }
        else { New-Check 'OneDrive' 'WARN' 'not installed' 'The web app keeps projects in OneDrive; install OneDrive and sign in. (The MCP server works without it.)' $script:Links.onedrive }
    }))

    $out.Add((Invoke-SafeCheck 'Single sign-on' {
        $j = Get-DeviceJoinStatus
        if ($j['AzureAdPrt'] -eq 'YES') { New-Check 'Single sign-on' 'OK' 'work account on this PC' 'Run sso-setup.cmd once, so Copilot signs in by itself with your Windows account after a restart.' }
        else { New-Check 'Single sign-on' 'OK' 'no work account on this PC' 'Copilot keeps its sign-in in StreamHub''s Edge profile: sign in once and choose "Stay signed in".' }
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

    # Optional tools (Python, Node.js...): check.cmd and the installer show them; not at every start.
    if ($Tools) { foreach ($c in @(Get-OptionalToolChecks -Registry:$Online)) { $out.Add($c) } }

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
function Repair-PrereqChecks {
    <# Carries out the safe repairs the checks name and returns the checks as they are now:
       - port / cdpPort in use: a free port is picked and saved in config\harness.local.json
         (not when the port was given with -Port: -KeepWebPort);
       - OneDrive installed but not signed in: OneDrive is opened so you can sign in (-NoLaunch skips).
       Nothing that needs admin rights or changes a company policy is ever touched. #>
    param([Parameter(Mandatory)]$Checks, [string]$AppRoot, [switch]$KeepWebPort, [switch]$NoLaunch, [int]$WebPort = 8765, [int]$CdpPort = 9333)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
    foreach ($c in @($Checks)) {
        if ($c.status -eq 'OK' -or -not $c.fix) { $c; continue }
        try {
            switch ($c.fix) {
                'port' {
                    if ($KeepWebPort) { $c; break }
                    $free = Find-FreePort ($WebPort + 1) ($WebPort + 40) @($CdpPort)
                    if (-not $free) { $c; break }
                    Set-CCBridgeLocalSetting harness port $free $AppRoot
                    New-Check $c.name 'OK' "fixed: was in use by another program; StreamHub now uses port $free (saved in config\harness.local.json)"
                }
                'cdpPort' {
                    $free = Find-FreePort ($CdpPort + 1) ($CdpPort + 40) @($WebPort)
                    if (-not $free) { $c; break }
                    Set-CCBridgeLocalSetting harness cdpPort $free $AppRoot
                    New-Check $c.name 'OK' "fixed: was in use by another program; Edge for Copilot now uses port $free (saved in config\harness.local.json)"
                }
                'onedrive' {
                    $exe = Get-OneDriveExePath
                    if ($NoLaunch -or -not $exe) { $c; break }
                    Start-Process -FilePath $exe
                    New-Check $c.name 'WARN' 'not signed in; OneDrive was opened so you can sign in' 'Sign in to OneDrive, then start StreamHub again.'
                }
                default { $c }
            }
        } catch { New-Check $c.name $c.status $c.detail ("$($c.hint) (Could not fix this automatically: $($_.Exception.Message.Split("`n")[0]))") $c.link }
    }
}

function Write-PrereqReport {
    <# Prints the checks as "[OK] name  detail" with the status word in colour, and the hint below
       anything that is not OK. Returns $true when nothing failed. #>
    param([Parameter(Mandatory)]$Checks, [string]$Title = 'System check')
    Write-Host $Title
    $w = [Math]::Max(10, (@($Checks | ForEach-Object { $_.name.Length }) | Measure-Object -Maximum).Maximum)
    foreach ($c in $Checks) {
        $color = switch ($c.status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'INFO' { 'Cyan' } default { 'Red' } }
        Write-Host '  [' -NoNewline
        Write-Host $c.status -ForegroundColor $color -NoNewline
        Write-Host ']' -NoNewline
        Write-Host (' ' * (5 - $c.status.Length)) -NoNewline
        Write-Host $c.name.PadRight($w + 2) -NoNewline
        Write-Host $c.detail -ForegroundColor DarkGray
        if ($c.hint -and $c.status -ne 'OK') { Write-Host ((' ' * ($w + 11)) + $c.hint) -ForegroundColor $color }
        if ($c.link -and $c.status -ne 'OK') { Write-Host ((' ' * ($w + 11)) + "Download: $($c.link)") -ForegroundColor $color }
    }
    -not @($Checks | Where-Object { $_.status -eq 'FAIL' }).Count
}

Export-ModuleMember -Function Get-ToolVersion, Get-OptionalToolChecks, Rename-AppShortcuts, Get-DeviceJoinStatus, Get-PrereqChecks, Repair-PrereqChecks, Write-PrereqReport, Get-DotNetVersionText
