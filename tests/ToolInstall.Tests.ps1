# Optional tools on request (lib/ToolInstall.psm1). Nothing real is downloaded or installed: the
# downloads and winget are replaced, and the tools folder is a temporary one.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\ToolInstall.psm1') -Force

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
    $hash = (Get-FileHash (Join-Path $src "$name.zip") -Algorithm SHA256).Hash.ToLowerInvariant()

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
