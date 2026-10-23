# Optional tools on request (lib/ToolInstall.psm1). Nothing real is downloaded or installed: the
# downloads and winget are replaced, and the tools folder is a temporary one.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\ToolInstall.psm1') -Force
Import-Module (Join-Path $root 'lib\Prereq.psm1')

Describe 'Install-OptionalTool' {
    $realLocal = $env:LOCALAPPDATA
    $fake = Join-Path $env:TEMP ('ccb-local-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $fake 'CCBridge') | Out-Null

    # A fake Node.js release: a zip with node.cmd that prints a version, and its SHA-256 list.
    $src = Join-Path $env:TEMP ('ccb-node-' + [guid]::NewGuid().ToString('N'))
    $name = 'node-v22.0.0-win-x64'
    New-Item -ItemType Directory -Force -Path (Join-Path $src $name) | Out-Null
    [IO.File]::WriteAllText((Join-Path $src "$name\node.cmd"), "@echo v22.0.0`r`n")
    Compress-Archive -Path (Join-Path $src $name) -DestinationPath (Join-Path $src "$name.zip")
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes((Join-Path $src "$name.zip")))).Replace('-', '').ToLowerInvariant()

    It 'installs Node.js from the official zip after checking its checksum, and refuses a wrong one' {
        $env:LOCALAPPDATA = $fake
        try {
            Mock -ModuleName ToolInstall Invoke-Winget { $false }
            Mock -ModuleName ToolInstall Invoke-WebDownload {
                switch -Regex ($Url) {
                    'index\.json$' { [IO.File]::WriteAllText($OutFile, '[{"version":"v23.0.0","lts":false},{"version":"v22.0.0","lts":"Jod"}]') }
                    'SHASUMS256' { [IO.File]::WriteAllText($OutFile, "$global:ccbSum  $global:ccbZip`n") }
                    '\.zip$' { Copy-Item (Join-Path $global:ccbSrc "$global:ccbZip") $OutFile }
                }
            }
            $global:ccbSrc = $src; $global:ccbZip = "$name.zip"
            Mock -ModuleName ToolInstall Get-LatestToolVersions { [pscustomobject]@{ node = 'v22.0.0' } }
            # Node.js runs once it is unpacked in the tools folder (before that: not installed).
            Mock -ModuleName ToolInstall Get-ToolVersion { if ($Exe -eq 'node' -and (Test-Path (Join-Path $env:LOCALAPPDATA 'CCBridge\tools\node\node.cmd'))) { 'v22.0.0' } }
            $global:ccbSum = ('0' * 64)
            { Install-OptionalTool 'node' } | Should Throw 'does not match the checksum'
            $global:ccbSum = $hash
            Install-OptionalTool 'node' | Should Be 'Node.js installed for your user: v22.0.0'
            Test-Path (Join-Path $fake 'CCBridge\tools\node\node.cmd') | Should Be $true
            # Installed but blocked from running (a computer's rules): said, not counted as installed.
            Mock -ModuleName ToolInstall Get-ToolVersion { $null }
            Remove-Item (Join-Path $fake 'CCBridge\tools\node') -Recurse -Force
            { Install-OptionalTool 'node' } | Should Throw 'does not run on this computer'
            # winget for Git, nothing else: when winget cannot, the tool stays informational.
            { Install-OptionalTool 'git' } | Should Throw 'winget could not install Git'
        } finally { $env:LOCALAPPDATA = $realLocal }
    }
    It 'keeps the state of an install in a status file for the app' {
        $env:LOCALAPPDATA = $fake
        try {
            Set-ToolInstallStatus 'python' 'failed' 'Not installed: blocked. StreamHub works without it.'
            (Get-ToolInstallStatus 'python').state | Should Be 'failed'
            Get-ToolInstallStatus 'dotnet' | Should Be $null
        } finally { $env:LOCALAPPDATA = $realLocal }
    }
    Remove-Item $fake, $src -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Minimum versions: a copy the person installed is never overruled' {
    It 'knows the minimum of each tool and what is below it' {
        Test-BelowToolMinimum 'node' 'v16.20.2' | Should Be $true
        Test-BelowToolMinimum 'node' 'v18.0.0' | Should Be $false
        Test-BelowToolMinimum 'node' 'v25.1.0' | Should Be $false
        Test-BelowToolMinimum 'python' 'Python 3.7.9' | Should Be $true
        Test-BelowToolMinimum 'python' 'Python 3.13.1' | Should Be $false
        Test-BelowToolMinimum 'dotnet' '5.0.408' | Should Be $true
        Test-BelowToolMinimum 'git' 'git version 1.0.0' | Should Be $false      # no minimum: StreamHub does not use Git
        Test-BelowToolMinimum 'node' '(installed; version unknown)' | Should Be $false
    }

    It 'puts its own copy in front only when no usable newer copy is there' {
        Mock -ModuleName ToolInstall Get-ExeVersion { switch -Regex ($Path) { 'own' { [version]'22.0.0' } 'new' { [version]'25.1.0' } 'old' { [version]'20.5.0' } 'ancient' { [version]'16.0.0' } default { $null } } }
        Test-OwnCopyFirst 'node' 'C:\own\node.exe' @() | Should Be $true                      # none other
        Test-OwnCopyFirst 'node' 'C:\own\node.exe' @('C:\new\node.exe') | Should Be $false    # theirs is newer: theirs first
        Test-OwnCopyFirst 'node' 'C:\own\node.exe' @('C:\old\node.exe') | Should Be $true     # theirs is older than StreamHub's
        Test-OwnCopyFirst 'node' 'C:\own\node.exe' @('C:\ancient\node.exe') | Should Be $true # theirs is below the minimum
        Test-OwnCopyFirst 'node' 'C:\own\node.exe' @('C:\unknown\node.exe') | Should Be $false # unknown version: theirs stays first
        Test-OwnCopyFirst 'node' 'C:\own\node.exe' @('C:\new\node.exe', 'C:\ancient\node.exe') | Should Be $false   # the first one found counts
    }

    It 'does not install over a copy the person installed at or above the minimum' {
        Mock -ModuleName ToolInstall Get-ToolVersion { if ($Exe -eq 'node') { 'v25.1.0' } }
        Mock -ModuleName ToolInstall Test-OwnInstall { $false }
        Mock -ModuleName ToolInstall Get-LatestToolVersions { [pscustomobject]@{ node = 'v24.0.0' } }
        Mock -ModuleName ToolInstall Invoke-WebDownload { throw 'nothing may be downloaded' }
        Mock -ModuleName ToolInstall Invoke-Winget { throw 'winget may not run' }
        Install-OptionalTool 'node' | Should Match 'v25\.1\.0 is installed already .*uses it as it is'
    }

    It 'offers an update only for its own copy or one below the minimum' {
        Mock -ModuleName ToolInstall Add-ToolPaths { }
        Mock -ModuleName ToolInstall Get-PythonVenv { $null }
        Mock -ModuleName ToolInstall Get-ToolInstallStatus { $null }
        Mock -ModuleName ToolInstall Get-LatestToolVersions { [pscustomobject]@{ node = 'v24.0.0' } }
        Mock -ModuleName ToolInstall Get-OptionalToolChecks { [pscustomobject]@{ name = 'Node.js'; status = 'OK'; detail = $global:ccbNode; hint = '' } }
        $node = { @(Get-InstallableTools) | Where-Object name -eq 'node' }
        # The person's own Node.js 22 (older than the newest, above the minimum): no update offered.
        $global:ccbNode = 'v22.1.0, npm 10'
        Mock -ModuleName ToolInstall Test-OwnInstall { $false }
        (& $node).update | Should Be $false
        (& $node).canInstall | Should Be $false
        # StreamHub's own copy: the update is offered.
        Mock -ModuleName ToolInstall Test-OwnInstall { $true }
        (& $node).update | Should Be $true
        # Below the minimum, whoever installed it: offered.
        Mock -ModuleName ToolInstall Test-OwnInstall { $false }
        $global:ccbNode = 'v16.20.2, npm 8'
        (& $node).update | Should Be $true
    }
}

Describe 'An update of a tool that is in use waits for the next start' {
    It 'sees a folder whose program is locked as in use' {
        $d = Join-Path $env:TEMP ('ccb-inuse-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
        $exe = Join-Path $d 'tool.exe'; [IO.File]::WriteAllBytes($exe, [byte[]](1, 2, 3))
        Test-FolderInUse $d | Should Be $false
        $lock = [IO.File]::Open($exe, 'Open', 'Read', 'Read')
        try { Test-FolderInUse $d | Should Be $true } finally { $lock.Dispose() }
        Test-FolderInUse (Join-Path $d 'missing') | Should Be $false
        Remove-Item $d -Recurse -Force
    }
    It 'records the pending update and starts it at the next start, once' {
        $saved = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $env:TEMP ('ccb-lad-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $env:LOCALAPPDATA 'CCBridge') -Force | Out-Null
        try {
            Mock -ModuleName ToolInstall Start-ToolInstall { $global:ccbStarted += , $Name; $true }
            $global:ccbStarted = @()
            Add-PendingToolInstall 'node'
            Add-PendingToolInstall 'node'
            @(Start-PendingToolInstalls) -join ',' | Should Be 'node'
            $global:ccbStarted -join ',' | Should Be 'node'
            @(Start-PendingToolInstalls).Count | Should Be 0   # started once, then gone
        } finally { Remove-Item $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue; $env:LOCALAPPDATA = $saved }
    }
}
