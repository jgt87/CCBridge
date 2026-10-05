# Optional tools on request (Settings > This computer, check.cmd -Install NAME): installs or updates
# Python, pytest, Node.js, the .NET SDK or Git for the current user only, never with admin rights:
# winget with --scope user where it works, else the official package checked before use (Node.js
# zip by its SHA-256 from nodejs.org, the python.org installer and Microsoft's dotnet-install.ps1 by
# their Authenticode signature). When a computer's rules block it, the tool stays informational and
# StreamHub works without it. Each install runs in its own process (tools/install-tool.ps1) and
# reports in a status file, so the app stays responsive.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Prereq') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:Installable = [ordered]@{
    python = @{ label = 'Python'; winget = 'Python.Python.3.12' }
    pytest = @{ label = 'pytest (Python tests)'; winget = $null }
    node   = @{ label = 'Node.js'; winget = 'OpenJS.NodeJS.LTS' }
    dotnet = @{ label = '.NET SDK'; winget = $null }
    git    = @{ label = 'Git'; winget = 'Git.Git' }
}

function Get-ToolsDir { Join-Path $env:LOCALAPPDATA 'CCBridge\tools' }
function Get-ToolStatusFile([string]$Name) { Join-Path $env:LOCALAPPDATA "CCBridge\tool-install-$Name.json" }

function Add-ToolPaths {
    <# Puts StreamHub's own tools (node, dotnet) and the user's PATH from the registry (per-user
       installs change it for new programs only) in front of this process's PATH, so a tool
       installed a moment ago is found here and by the commands this process starts. #>
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in 'node', 'dotnet') { $p = Join-Path (Get-ToolsDir) $d; if (Test-Path -LiteralPath $p) { $dirs.Add($p) } }
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    foreach ($d in @("$user".Split(';') | Where-Object { $_.Trim() })) { $dirs.Add([Environment]::ExpandEnvironmentVariables($d.Trim())) }
    $now = @($env:Path.Split(';') | Where-Object { $_ })
    $add = @($dirs | Where-Object { $now -notcontains $_ } | Select-Object -Unique)
    if ($add.Count) { $env:Path = (($add + $now) -join ';') }
}

function Get-PythonVenv {
    <# The folder of the virtual environment when the python found first is one (often another
       program's), else $null. StreamHub never installs into it. #>
    $py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
    if (-not $py) { return $null }
    # No quotes in the Python code: Windows PowerShell 5.1 drops them when it starts a program.
    $out = @(try { & $py.Source -c 'import sys; print(int(sys.prefix != sys.base_prefix)); print(sys.prefix)' 2>$null } catch { })
    if ($out.Count -ge 2 -and "$($out[0])".Trim() -eq '1') { "$($out[1])".Trim() } else { $null }
}

function Get-VersionNumber([string]$Text) {
    # The first version number in a tool's text ("v24.14.1, npm 11" -> 24.14.1), or $null.
    $m = [regex]::Match("$Text", '(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $m.Success) { return $null }
    [version]("$($m.Groups[1].Value).$($m.Groups[2].Value).$(if ($m.Groups[3].Success) { $m.Groups[3].Value } else { '0' })")
}

function Get-LatestToolVersions {
    <# The newest release of each tool from its official source: Python (python.org), Node.js LTS
       (nodejs.org), .NET SDK LTS (Microsoft's release index), pytest (PyPI), Git (winget). Kept for
       12 hours in %LOCALAPPDATA%\CCBridge\tool-latest.json; a source that cannot be reached is left
       out (no update offer, never an error). -Force asks again. #>
    param([switch]$Force)
    $file = Join-Path $env:LOCALAPPDATA 'CCBridge\tool-latest.json'
    if (-not $Force -and (Test-Path -LiteralPath $file)) {
        try { $c = [IO.File]::ReadAllText($file) | ConvertFrom-Json; if (((Get-Date) - [datetime]$c.at).TotalHours -lt 12) { return $c.versions } } catch { }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
    $get = { param($u) Invoke-RestMethod $u -UseBasicParsing -TimeoutSec 10 -Headers @{ 'User-Agent' = 'StreamHub-tools' } }
    $v = [ordered]@{}
    try {
        # In parentheses: Windows PowerShell 5.1 hands over a JSON array as one object.
        $rel = @((& $get 'https://www.python.org/api/v2/downloads/release/?is_published=true&pre_release=false'))
        $best = @($rel | ForEach-Object { "$($_.name)" } | Where-Object { $_ -match '^Python 3\.\d+\.\d+$' } | ForEach-Object { [version]($_ -replace '^Python ', '') } | Sort-Object -Descending) | Select-Object -First 1
        if ($best) { $v.python = "$best" }
    } catch { Write-CCBLog verbose tools "python.org not reached: $($_.Exception.Message)" }
    try { $lts = @((& $get 'https://nodejs.org/dist/index.json')) | Where-Object { $_.lts } | Select-Object -First 1; if ($lts) { $v.node = "$($lts.version)" } } catch { Write-CCBLog verbose tools "nodejs.org not reached: $($_.Exception.Message)" }
    try {
        $idx = & $get 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json'
        $ch = @($idx.'releases-index' | Where-Object { $_.'release-type' -eq 'lts' -and $_.'support-phase' -eq 'active' } | Sort-Object { [version]$_.'channel-version' } -Descending) | Select-Object -First 1
        if ($ch) { $v.dotnet = "$($ch.'latest-sdk')" }
    } catch { Write-CCBLog verbose tools ".NET release index not reached: $($_.Exception.Message)" }
    try { $v.pytest = "$((& $get 'https://pypi.org/pypi/pytest/json').info.version)" } catch { Write-CCBLog verbose tools "PyPI not reached: $($_.Exception.Message)" }
    try {
        $w = Get-Command winget -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($w) {
            $show = & $w.Source show --id Git.Git --exact --accept-source-agreements --disable-interactivity 2>$null
            $line = @($show | Where-Object { $_ -match '^\s*Version:\s*(\S+)' }) | Select-Object -First 1
            if ($line -and $line -match '^\s*Version:\s*(\S+)') { $v.git = $Matches[1] }
        }
    } catch { Write-CCBLog verbose tools "winget did not answer for Git: $($_.Exception.Message)" }
    try { [IO.File]::WriteAllText($file, (@{ at = (Get-Date).ToString('s'); versions = $v } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false))) } catch { }
    [pscustomobject]$v
}

function Get-InstallableTools {
    <# The tools that can be installed on request, with what the check says now. #>
    Add-ToolPaths
    $checks = @(Get-OptionalToolChecks)
    # Pester ships with Windows; shown here, never installed (a newer major version changes how tests run).
    $pe = $checks | Where-Object name -eq 'Pester (PowerShell tests)'
    if ($pe) { [pscustomobject]@{ name = 'pester'; label = 'Pester (PowerShell tests)'; status = $pe.status; detail = $pe.detail; hint = "$($pe.hint)"; canInstall = $false; install = $null } }
    $py = $checks | Where-Object name -eq 'Python'
    $venv = Get-PythonVenv
    $latest = try { Get-LatestToolVersions } catch { $null }
    if ($py -and $venv) { $py | Add-Member -NotePropertyName detail -NotePropertyValue "$($py.detail); a virtual environment" -Force }
    foreach ($k in $script:Installable.Keys) {
        $t = $script:Installable[$k]
        $check = switch ($k) {
            'python' { $py }
            'pytest' {
                if ($py -and $py.status -ne 'INFO') {
                    $has = $py.detail -match '(pytest [\d.]+)'
                    [pscustomobject]@{ status = $(if ($has) { 'OK' } else { 'INFO' }); detail = $(if ($has) { $Matches[1] } else { 'not installed (tests run with unittest)' }); hint = $(if (-not $has -and $venv) { "The python found first is a virtual environment ($venv), often another program's; StreamHub does not install into it. Put a regular Python first on PATH to add pytest." } else { '' }) }
                } else { $null }
            }
            'node' { $checks | Where-Object name -eq 'Node.js' }
            'dotnet' { $checks | Where-Object name -eq '.NET SDK' }
            'git' { $checks | Where-Object name -eq 'Git' }
        }
        if (-not $check) { continue }   # pytest without Python
        $st = Get-ToolInstallStatus $k
        # A newer release than the one installed (the minimum versions only decide "too old").
        $newest = if ($latest) { "$($latest.$k)" } else { '' }
        $have = Get-VersionNumber $(if ($k -eq 'python') { ($check.detail -split ',')[0] } else { $check.detail })
        $want = Get-VersionNumber $newest
        $update = [bool]($check.status -ne 'INFO' -and $have -and $want -and $have -lt $want)
        $blocked = $venv -and $k -in 'python', 'pytest'
        $hint = "$($check.hint)"
        if ($update -and $blocked) { $hint = "Newer: $newest. The python found first is a virtual environment ($venv), often another program's; StreamHub does not update it." }
        [pscustomobject]@{ name = $k; label = $t.label; status = $check.status; detail = $check.detail; hint = $hint
            latest = $(if ($newest) { $newest } else { $null }); update = $update
            canInstall = (($check.status -ne 'OK' -or $update) -and -not ($blocked -and ($k -eq 'pytest' -or $update))); install = $st }
    }
}

function Get-PendingToolFile { Join-Path $env:LOCALAPPDATA 'CCBridge\tool-install-pending.json' }

function Test-FolderInUse([string]$Folder) {
    <# Whether a program runs from this folder or its main program is locked (cannot be replaced now). #>
    if (-not (Test-Path -LiteralPath $Folder)) { return $false }
    $full = [IO.Path]::GetFullPath($Folder).TrimEnd('\') + '\'
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = try { $p.Path } catch { $null }
        if ($path -and $path.StartsWith($full, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($exe in @(Get-ChildItem -LiteralPath $Folder -Filter *.exe -File -ErrorAction SilentlyContinue)) {
        try { $fs = [IO.File]::Open($exe.FullName, 'Open', 'ReadWrite', 'None'); $fs.Dispose() } catch { return $true }
    }
    $false
}

function Add-PendingToolInstall([string]$Name) {
    $f = Get-PendingToolFile
    $list = @(if (Test-Path -LiteralPath $f) { try { @(([IO.File]::ReadAllText($f) | ConvertFrom-Json)) } catch { @() } })
    if ($list -notcontains $Name) { $list += $Name }
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @($list) -Compress), (New-Object Text.UTF8Encoding($false)))
}

function Start-PendingToolInstalls {
    <# At StreamHub's start, before it uses the tools: installs that had to wait because the tool was
       in use (Node.js running) start now. Returns the names started. #>
    param([string]$AppRoot)
    $f = Get-PendingToolFile
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $list = @(try { @(([IO.File]::ReadAllText($f) | ConvertFrom-Json)) } catch { @() })
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    @(foreach ($n in $list) { if ($script:Installable.Contains("$n") -and (Start-ToolInstall "$n" $AppRoot)) { "$n" } })
}

function Get-ToolInstallStatus([string]$Name) {
    $f = Get-ToolStatusFile $Name
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $null }
}

function Set-ToolInstallStatus([string]$Name, [string]$State, [string]$Message) {
    $o = @{ state = $State; message = $Message; at = (Get-Date).ToString('s') }
    [IO.File]::WriteAllText((Get-ToolStatusFile $Name), ($o | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

function Start-ToolInstall {
    <# Starts tools/install-tool.ps1 for one tool in its own hidden process; its progress goes to
       the status file. Returns $false when an install of it is already running. #>
    param([Parameter(Mandatory)][ValidateScript({ $script:Installable.Contains($_) })][string]$Name, [string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $st = Get-ToolInstallStatus $Name
    if ($st -and $st.state -eq 'running' -and ((Get-Date) - [datetime]$st.at).TotalMinutes -lt 30) { return $false }
    Set-ToolInstallStatus $Name 'running' "Installing $($script:Installable[$Name].label) for your user..."
    $script = Join-Path $AppRoot 'tools\install-tool.ps1'
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-Name', $Name -WindowStyle Hidden
    $true
}

function Invoke-WebDownload([string]$Url, [string]$OutFile) {
    # Through the system proxy with the user's own sign-in, as a browser would.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
    Invoke-WebRequest $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600 -Headers @{ 'User-Agent' = 'StreamHub-tools' }
}

function Test-SignedBy([string]$Path, [string]$Signer) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    ($sig.Status -eq 'Valid') -and ("$($sig.SignerCertificate.Subject)" -match [regex]::Escape($Signer))
}

function Invoke-Winget([string]$Id, [switch]$Upgrade) {
    # winget for the current user only (install, or upgrade what winget installed); $false when
    # winget is not there or it did not succeed.
    $w = Get-Command winget -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $w -or -not $Id) { return $false }
    $verb = if ($Upgrade) { 'upgrade' } else { 'install' }
    $p = Start-Process $w.Source -ArgumentList $verb, '--id', $Id, '--exact', '--scope', 'user', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity' -Wait -PassThru -WindowStyle Hidden
    Write-CCBLog info tools "winget $verb $Id" @{ exit = $p.ExitCode }
    $p.ExitCode -eq 0
}

function Install-OptionalTool {
    <# Installs one tool for the current user (run by tools/install-tool.ps1). Returns a message;
       throws when it could not be installed. #>
    param([Parameter(Mandatory)][string]$Name)
    $t = $script:Installable[$Name]
    if (-not $t) { throw "Unknown tool '$Name'." }
    $dir = Get-ToolsDir; $null = New-Item -ItemType Directory -Force -Path $dir
    $latest = try { Get-LatestToolVersions } catch { $null }
    $newest = if ($latest) { "$($latest.$Name)" } else { '' }
    $before = if ($Name -eq 'pytest') { $null } else { Get-ToolVersion $Name }   # installed already: this is an update
    $tmp = Join-Path $env:TEMP ('streamhub-tool-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $tmp
    try {
        switch ($Name) {
            'python' {
                if (Get-PythonVenv) { throw "the python found first is a virtual environment, often another program's; StreamHub does not change it" }
                # The newest Python 3 (python.org), else 3.12.
                $ver = if ($newest -match '^3\.\d+\.\d+$') { $newest } else { '3.12.7' }
                $minor = ($ver -split '\.')[0..1] -join '.'
                if (-not (Invoke-Winget "Python.Python.$minor")) {
                    # The python.org installer, per user and quiet, after checking who signed it.
                    $exe = Join-Path $tmp "python-$ver-amd64.exe"
                    Invoke-WebDownload "https://www.python.org/ftp/python/$ver/python-$ver-amd64.exe" $exe
                    if (-not (Test-SignedBy $exe 'Python Software Foundation')) { throw 'the downloaded Python installer is not signed by the Python Software Foundation' }
                    $p = Start-Process $exe -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_test=0', 'Include_launcher=0' -Wait -PassThru
                    if ($p.ExitCode -ne 0) { throw "the Python installer stopped with code $($p.ExitCode) (blocked on this computer?)" }
                }
            }
            'pytest' {
                Add-ToolPaths
                $py = Get-ToolVersion 'python'
                if (-not $py) { throw 'Python is not installed' }
                $venv = Get-PythonVenv
                if ($venv) { throw "the python found first is a virtual environment ($venv), often another program's; StreamHub does not install into it" }
                $out = & python -m pip install --user --upgrade --quiet pytest 2>&1
                if ($LASTEXITCODE -ne 0) { throw "pip could not install pytest: $("$out".Split("`n")[-1])" }
            }
            'node' {
                if (-not (Invoke-Winget $t.winget -Upgrade:([bool]$before))) {
                    # The official zip of the newest LTS release, checked against nodejs.org's SHA-256 list.
                    $index = Join-Path $tmp 'index.json'
                    Invoke-WebDownload 'https://nodejs.org/dist/index.json' $index
                    $releases = @(([IO.File]::ReadAllText($index) | ConvertFrom-Json))   # in parentheses: 5.1 hands over a JSON array as one object
                    $lts = $releases | Where-Object { $_.lts } | Select-Object -First 1
                    if (-not $lts) { throw 'nodejs.org did not list an LTS release' }
                    $pkg = "node-$($lts.version)-win-x64"
                    $zip = Join-Path $tmp "$pkg.zip"; $sums = Join-Path $tmp 'SHASUMS256.txt'
                    Invoke-WebDownload "https://nodejs.org/dist/$($lts.version)/$pkg.zip" $zip
                    Invoke-WebDownload "https://nodejs.org/dist/$($lts.version)/SHASUMS256.txt" $sums
                    $want = ([IO.File]::ReadAllLines($sums) | Where-Object { $_ -match " $([regex]::Escape("$pkg.zip"))$" } | Select-Object -First 1) -replace '\s.*$', ''
                    # .NET directly: the Get-FileHash cmdlet is missing when the module paths are another PowerShell's.
                    $sha = [Security.Cryptography.SHA256]::Create(); $fs = [IO.File]::OpenRead($zip)
                    try { $have = ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '') } finally { $fs.Dispose(); $sha.Dispose() }
                    if (-not $want -or $have -ne $want.ToUpperInvariant()) { throw 'the Node.js download does not match the checksum nodejs.org publishes' }
                    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
                    $target = Join-Path $dir 'node'
                    # In use (StreamHub or another program runs node): replacing it now would fail or
                    # break that program, so the update runs at StreamHub's next start instead.
                    if (Test-FolderInUse $target) { Add-PendingToolInstall 'node'; throw 'PENDING: Node.js is in use right now, so it cannot be replaced; the update runs the next time StreamHub starts.' }
                    if (Test-Path -LiteralPath $target) { [IO.Directory]::Delete($target, $true) }
                    Move-Item -LiteralPath (Join-Path $tmp $pkg) -Destination $target
                }
            }
            'dotnet' {
                # Microsoft's own install script, into StreamHub's tools folder, after checking its signature.
                $ps1 = Join-Path $tmp 'dotnet-install.ps1'
                Invoke-WebDownload 'https://dot.net/v1/dotnet-install.ps1' $ps1
                if (-not (Test-SignedBy $ps1 'Microsoft Corporation')) { throw 'the downloaded dotnet-install.ps1 is not signed by Microsoft' }
                & $ps1 -Channel LTS -InstallDir (Join-Path $dir 'dotnet') -NoPath | Out-Null
            }
            'git' {
                if (-not (Invoke-Winget $t.winget -Upgrade:([bool]$before))) { throw $(if ($before) { 'winget could not update Git for your user: it is installed for all users, so it updates with its own installer or winget as an administrator' } else { 'winget could not install Git for your user here; install it from https://git-scm.com/download/win if your computer allows it' }) }
            }
        }
    } finally { try { [IO.Directory]::Delete($tmp, $true) } catch { } }
    # Installed is not enough: it must also run here (a computer's rules can block programs).
    Add-ToolPaths
    $exe = switch ($Name) { 'pytest' { $null } default { $Name } }
    if ($exe) {
        $v = Get-ToolVersion $exe
        if (-not $v -or $v -match 'version unknown') { throw "$($t.label) was installed but does not run on this computer (blocked by its rules?)" }
        if ($before -and (Get-VersionNumber $v) -le (Get-VersionNumber $before)) { throw "$($t.label) $newest was installed for your user, but $before is still found first on this computer (an install for all users comes first on PATH)" }
        return "$($t.label) $(if ($before) { "updated for your user: $before -> $v" } else { "installed for your user: $v" })"
    }
    "$($t.label) installed for your user"
}

Export-ModuleMember -Function Test-FolderInUse, Add-PendingToolInstall, Start-PendingToolInstalls, Get-VersionNumber, Get-LatestToolVersions, Get-ToolsDir, Add-ToolPaths, Get-InstallableTools, Get-ToolInstallStatus, Set-ToolInstallStatus, Start-ToolInstall, Install-OptionalTool
