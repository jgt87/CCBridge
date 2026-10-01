# Diagnostic log: %LOCALAPPDATA%\CCBridge\logs\ccbridge-yyyyMMdd.log (14 days kept).
# Levels: off < info (default) < verbose < trace. Only 'trace' records prompt/reply text; every
# line is masked for user name, profile/OneDrive paths, email addresses and GUIDs, so logs can be shared.
# Several processes (web app, MCP server) and runspaces append to the same file under a mutex.

$script:Levels = @{ off = 0; info = 1; verbose = 2; trace = 3 }
$script:Level = 1
$script:Dir = Join-Path $env:LOCALAPPDATA 'CCBridge\logs'
$script:Masks = $null

function Get-CCBLogDir { $script:Dir }
function Get-CCBLogLevel { ($script:Levels.GetEnumerator() | Where-Object { $_.Value -eq $script:Level } | Select-Object -First 1).Key }

function Set-CCBLogLevel([string]$Level) {
    $l = if ($Level) { $Level.ToLowerInvariant() } else { 'info' }
    if (-not $script:Levels.ContainsKey($l)) { $l = 'info' }
    $script:Level = $script:Levels[$l]
}

function Initialize-CCBLog {
    <# Level precedence: explicit -Level, then $env:CCBRIDGE_LOG, then the config value, then info. #>
    param([string]$Level, $Config)
    $chosen = if ($Level) { $Level } elseif ($env:CCBRIDGE_LOG) { $env:CCBRIDGE_LOG } elseif ($Config -and $Config.PSObject.Properties['logLevel']) { [string]$Config.logLevel } else { 'info' }
    Set-CCBLogLevel $chosen
    if ($script:Level -gt 0 -and -not (Test-Path $script:Dir)) { $null = New-Item -ItemType Directory -Force -Path $script:Dir }
    # Old logs: keep 14 days.
    try { Get-ChildItem $script:Dir -Filter 'ccbridge-*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | ForEach-Object { [IO.File]::Delete($_.FullName) } } catch { }
}

function Test-CCBLog([string]$Level) { $script:Level -ge $script:Levels[$Level] -and $script:Level -gt 0 }

function Protect-LogText([string]$Text) {
    <# Masks personal details so a log can be handed to someone else. #>
    if (-not $Text) { return $Text }
    if (-not $script:Masks) {
        $m = New-Object System.Collections.Generic.List[object]
        foreach ($pair in @(@($env:OneDriveCommercial, '%OneDrive%'), @($env:OneDrive, '%OneDrive%'), @($env:USERPROFILE, '%USERPROFILE%'), @($env:USERNAME, '%USERNAME%'), @($env:COMPUTERNAME, '%COMPUTERNAME%'))) {
            if ($pair[0] -and $pair[0].Length -ge 3) { $m.Add(@([regex]::Escape($pair[0]), $pair[1])) }
        }
        $script:Masks = $m
    }
    foreach ($m in $script:Masks) { $Text = [regex]::Replace($Text, $m[0], $m[1], 'IgnoreCase') }
    $Text = [regex]::Replace($Text, '[\w.+-]+@[\w-]+(\.[\w-]+)+', '<email>')
    # Conversation, message and user IDs are not needed to diagnose and can identify a person.
    [regex]::Replace($Text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<id>')
}

function Write-CCBLog {
    <# Write-CCBLog verbose bridge 'Sent prompt' @{ chars = 123 } #>
    param(
        [Parameter(Mandatory)][ValidateSet('info', 'verbose', 'trace')][string]$Level,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Message,
        $Data
    )
    if (-not (Test-CCBLog $Level)) { return }
    try {
        $line = '{0} [{1,5}] {2,-7} {3,-8} {4}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $PID, $Level.ToUpperInvariant(), $Component, $Message
        if ($null -ne $Data) { $line += ' ' + (ConvertTo-Json -InputObject $Data -Depth 6 -Compress) }
        $line = Protect-LogText $line
        $file = Join-Path $script:Dir ('ccbridge-' + (Get-Date).ToString('yyyyMMdd') + '.log')
        $mutex = New-Object Threading.Mutex($false, 'Local\CCBridgeLog')
        $owned = $false
        try {
            try { $owned = $mutex.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $owned = $true }
            [IO.File]::AppendAllText($file, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
        } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    } catch { }   # logging must never break CCBridge
}

function Write-CCBLogError {
    <# Logs an exception (message + PowerShell stack) at info level. #>
    param([Parameter(Mandatory)][string]$Component, [Parameter(Mandatory)][string]$Context, $ErrorRecord)
    $msg = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { "$ErrorRecord" }
    $stack = if ($ErrorRecord.ScriptStackTrace) { ($ErrorRecord.ScriptStackTrace -split "`n" | Select-Object -First 6) -join ' | ' } else { '' }
    Write-CCBLog info $Component "ERROR $Context`: $msg" @{ stack = $stack }
}

Export-ModuleMember -Function Initialize-CCBLog, Set-CCBLogLevel, Get-CCBLogLevel, Get-CCBLogDir, Test-CCBLog, Write-CCBLog, Write-CCBLogError, Protect-LogText
