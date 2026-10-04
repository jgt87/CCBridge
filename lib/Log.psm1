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
    # "One or more errors occurred" and similar wrappers: add the inner causes.
    $inner = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.InnerException } else { $null }
    while ($inner) { $msg += " <- $($inner.Message)"; $inner = $inner.InnerException }
    $stack = if ($ErrorRecord.ScriptStackTrace) { ($ErrorRecord.ScriptStackTrace -split "`n" | Select-Object -First 6) -join ' | ' } else { '' }
    Write-CCBLog info $Component "ERROR $Context`: $msg" @{ stack = $stack }
}

function New-CCBErrorId {
    <# A short id that ties an error in the app to its lines in the log: E-HHmmss-xxxx. #>
    'E-' + (Get-Date).ToString('HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
}

# What went wrong, by the error text: a category code and what the person can do about it.
$script:ErrorHelp = @(
    @{ re = 'Lost the connection to the Copilot tab'; code = 'EDGE-LOST'; hint = 'Edge or its Copilot tab was closed, crashed or replaced (for example by a sign-in). StreamHub reconnects by itself; send your message again.' }
    @{ re = 'Could not connect to the Copilot tab|no page targets|could not connect to ws'; code = 'EDGE-CONNECT'; hint = 'StreamHub could not reach Edge. Close the Edge window StreamHub opened and start StreamHub again; if it keeps happening, run probe.cmd and send the report.' }
    @{ re = 'human-verification'; code = 'VERIFY'; hint = 'Copilot shows a "verify you are human" check: complete it in the Copilot window in Edge, then send your message again.' }
    @{ re = '(?i)sign-in|sign in|signed in'; code = 'SIGN-IN'; hint = 'Complete the sign-in in the Copilot window in Edge; StreamHub continues afterwards (or send your message again).' }
    @{ re = 'message box (did not appear|not found|never appeared)'; code = 'PAGE'; hint = 'Copilot''s page did not show its message box. Look at the Copilot window in Edge (the message names a screenshot). If Copilot''s page changed, run capture.cmd and send the result.' }
    @{ re = 'could not clear the Copilot message box|message box holds'; code = 'TYPING'; hint = 'Typing into Copilot failed. Click once into the Copilot window and send again; if it repeats, export diagnostics.' }
    @{ re = 'Send button never became clickable'; code = 'SEND'; hint = 'Copilot''s Send button did not respond. Check the Copilot window: a dialog or sign-in may be in the way.' }
    @{ re = '(?i)OutOfCredits|daily limit|usage limit'; code = 'CREDITS'; hint = 'Copilot''s daily limit is reached. The queue waits until it resets and then continues by itself; Resume now under Progress > Runs tries earlier.' }
    @{ re = '(?i)throttl'; code = 'THROTTLED'; hint = 'Copilot is limiting requests. Wait a minute and try again.' }
    @{ re = 'No complete reply within'; code = 'TIMEOUT'; hint = 'Copilot took longer than replyTimeoutSec. Raise it in config\harness.local.json, or split the task into smaller steps.' }
    @{ re = '(?i)NoAnswer|stopped without answering|finished without a reply|no usable answer'; code = 'NO-ANSWER'; hint = 'Copilot did not answer. Usually a source it needed was unavailable or the request was blocked. Try again, rephrase, or start a New chat.' }
    @{ re = 'SEARCH text|SEARCH/REPLACE|edit block|half open|does not contain them yet|matches \d+ places'; code = 'EDIT'; hint = 'An edit could not be applied safely and nothing was changed. Copilot gets the reason and usually corrects it in its next reply.' }
    @{ re = 'Source/|source data'; code = 'SOURCE-DATA'; hint = 'Files in Source/ are read-only. Ask for the result in another folder (for example Work/ or output/).' }
    @{ re = 'Open or create a project'; code = 'NO-PROJECT'; hint = 'Open or create a project first (Switch worktree).' }
    @{ re = 'still working on the previous message'; code = 'BUSY'; hint = 'Wait until the current task has finished, or press Stop.' }
    @{ re = '(?i)fetch prompt|Fetch '''; code = 'FETCH'; hint = 'The fetch did not complete; the previous answer file was kept. Try Refresh again later.' }
    @{ re = 'Pick (at least one|the date)|is not a time|message to schedule is empty|Which (fetch|runbook) should run|repeat must be|Unknown schedule'; code = 'SCHEDULE'; hint = 'Complete the schedule: what runs, the days and at least one time, or a date and time for a one-time run.' }
)

function Get-CCBErrorHelp([string]$Text) {
    <# @{ code; hint } for an error text (UNEXPECTED when it is not recognised). #>
    foreach ($h in $script:ErrorHelp) { if ($Text -match $h.re) { return @{ code = $h.code; hint = $h.hint } } }
    @{ code = 'UNEXPECTED'; hint = 'StreamHub did not expect this. Use Copy details (or Menu > Export diagnostics) and send it along with the error id.' }
}

function Get-CCBErrorDetail($ErrorRecord) {
    <# Message, inner causes and the first stack lines of an exception, masked like the log. #>
    if (-not $ErrorRecord) { return '' }
    $msg = if ($ErrorRecord.Exception) { "$($ErrorRecord.Exception.GetType().Name): $($ErrorRecord.Exception.Message)" } else { "$ErrorRecord" }
    $inner = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.InnerException } else { $null }
    while ($inner) { $msg += "`n  caused by $($inner.GetType().Name): $($inner.Message)"; $inner = $inner.InnerException }
    if ($ErrorRecord.ScriptStackTrace) { $msg += "`n" + (($ErrorRecord.ScriptStackTrace -split "`n" | Select-Object -First 8) -join "`n") }
    Protect-LogText $msg
}

Export-ModuleMember -Function New-CCBErrorId, Get-CCBErrorHelp, Get-CCBErrorDetail, Initialize-CCBLog, Set-CCBLogLevel, Get-CCBLogLevel, Get-CCBLogDir, Test-CCBLog, Write-CCBLog, Write-CCBLogError, Protect-LogText
