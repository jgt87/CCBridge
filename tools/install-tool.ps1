# Installs one optional tool for the current user (started by StreamHub's Settings > This computer,
# or by check.cmd -Install NAME). The result goes to %LOCALAPPDATA%\CCBridge\tool-install-NAME.json.
param([Parameter(Mandatory)][ValidateSet('python', 'pytest', 'node', 'dotnet', 'git')][string]$Name)
$ErrorActionPreference = 'Stop'
# Windows PowerShell's own module paths: a process started from PowerShell 7 passes on its paths,
# and 5.1 would then load 7's modules (Get-FileHash and others go missing).
$env:PSModulePath = (@([Environment]::GetEnvironmentVariable('PSModulePath', 'User'), [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine'), (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules')) | Where-Object { $_ }) -join ';'
$lib = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
Import-Module (Join-Path $lib 'ToolInstall.psm1') -Force
try {
    Set-ToolInstallStatus $Name 'running' "Installing $Name for your user..."
    $msg = Install-OptionalTool $Name
    Set-ToolInstallStatus $Name 'done' $msg
    Write-Host $msg
} catch {
    $why = $_.Exception.Message.Split("`n")[0]
    if ($why -like 'PENDING: *') {
        # In use now: it runs at StreamHub's next start (Start-PendingToolInstalls).
        Set-ToolInstallStatus $Name 'pending' $why.Substring(9)
        Write-Host $why.Substring(9)
        exit 0
    }
    Set-ToolInstallStatus $Name 'failed' "Not installed: $why. StreamHub works without it."
    Write-Host "Not installed: $why" -ForegroundColor Yellow
    exit 1
}
