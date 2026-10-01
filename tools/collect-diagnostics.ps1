<#
.SYNOPSIS
  Packs CCBridge diagnostics into a zip on the desktop, to hand to whoever helps you test:
  recent logs (masked for user name, paths and email addresses), an environment summary,
  settings, and a check of the Copilot page selectors if Edge with Copilot is open.
.PARAMETER Days
  How many days of logs to include (default 2).
.PARAMETER IncludeReplies
  Also include the raw Copilot reply frames. These contain the full text of Copilot's answers
  (which can include Microsoft 365 data); only add them when asked and after a look.
#>
param([int]$Days = 2, [switch]$IncludeReplies, [switch]$NoOpen)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Log.psm1')
Import-Module (Join-Path $root 'lib\Cdp.psm1')

$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$stage = Join-Path $env:TEMP "ccbridge-diagnostics-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
$null = New-Item -ItemType Directory -Path $stage

# 1. Environment and settings (no personal data; paths masked).
$envInfo = Get-CCBridgeEnvironment $root
$envInfo.logLevel = [string](Get-CCBridgeConfig harness $root).logLevel
$envInfo.collected = (Get-Date).ToString('s')
$envInfo.edgeDebugPortOpen = Test-CdpEndpoint ([int](Get-CCBridgeConfig harness $root).cdpPort)
[IO.File]::WriteAllText((Join-Path $stage 'environment.json'), (Protect-LogText ($envInfo | ConvertTo-Json -Depth 6)))
foreach ($f in Get-ChildItem (Join-Path $root 'config') -Filter '*.json') {
    [IO.File]::WriteAllText((Join-Path $stage "config-$($f.Name)"), (Protect-LogText ([IO.File]::ReadAllText($f.FullName))))
}

# 2. Copilot page check: does each selector still find its element?
if ($envInfo.edgeDebugPortOpen) {
    try {
        $port = [int](Get-CCBridgeConfig harness $root).cdpPort
        $sel = Get-CCBridgeConfig selectors $root
        $target = Get-CdpPageTarget -Port $port -UrlLike '*m365.cloud.microsoft*'
        $s = Connect-Cdp $target.webSocketDebuggerUrl
        $checks = [ordered]@{ pageHost = ([uri]$target.url).Host }
        foreach ($name in 'editor', 'sendButton', 'stopButton') {
            $q = $sel.$name | ConvertTo-Json -Compress
            $checks[$name] = Invoke-CdpEval $s "(() => { const e = document.querySelector($q); return e ? (e.__lexicalEditor ? 'found (lexical)' : 'found') : 'missing'; })()"
        }
        if ($sel.workIq.toggle) {
            $q = $sel.workIq.toggle | ConvertTo-Json -Compress
            $a = $sel.workIq.stateAttribute | ConvertTo-Json -Compress
            $checks.workIqToggle = Invoke-CdpEval $s "(() => { const e = document.querySelector($q); return e ? ('found, ' + $a + '=' + e.getAttribute($a)) : 'missing'; })()"
        } else { $checks.workIqToggle = 'not configured' }
        Disconnect-Cdp $s
        [IO.File]::WriteAllText((Join-Path $stage 'page-check.json'), ($checks | ConvertTo-Json))
    } catch {
        [IO.File]::WriteAllText((Join-Path $stage 'page-check.json'), (@{ error = (Protect-LogText $_.Exception.Message) } | ConvertTo-Json))
    }
}

# 3. Logs (already masked when written).
$logDir = Get-CCBLogDir
$logs = @(Get-ChildItem $logDir -Filter 'ccbridge-*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge (Get-Date).Date.AddDays(1 - $Days) })
if ($logs.Count) { $null = New-Item -ItemType Directory -Path (Join-Path $stage 'logs'); $logs | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage 'logs') } }

# 4. Optional: raw reply frames (contain Copilot's full answers).
if ($IncludeReplies) {
    $rep = Join-Path $env:LOCALAPPDATA 'CCBridge\replies'
    if (Test-Path $rep) { Copy-Item -LiteralPath $rep -Destination (Join-Path $stage 'replies') -Recurse }
}

[IO.File]::WriteAllText((Join-Path $stage 'README.txt'), @"
CCBridge diagnostics $stamp
environment.json  versions, PowerShell, Edge, settings (no personal data)
config-*.json     settings files, including your *.local.json overrides
page-check.json   whether CCBridge's selectors still find Copilot's controls (only if Edge with Copilot was open)
logs\             diagnostic logs; user name, profile/OneDrive paths and email addresses are masked
$(if ($IncludeReplies) { 'replies\          RAW COPILOT REPLIES - full answer text, may contain Microsoft 365 data' })
Log level when collected: $($envInfo.logLevel). For detailed logs, turn on verbose logging, reproduce the problem, then collect again.
"@)

$desktop = [Environment]::GetFolderPath('Desktop')
$zip = Join-Path $desktop "CCBridge-diagnostics-$stamp.zip"
if (Test-Path $zip) { [IO.File]::Delete($zip) }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$fs = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
$archive = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in Get-ChildItem $stage -Recurse -File) {
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $f.FullName.Substring($stage.Length + 1).Replace('\', '/'))
    }
} finally { $archive.Dispose(); $fs.Dispose() }
[IO.Directory]::Delete($stage, $true)
Write-CCBLog info diag 'Diagnostics collected' @{ logs = $logs.Count; replies = [bool]$IncludeReplies }
if (-not $NoOpen) { Start-Process explorer.exe "/select,`"$zip`"" }
$zip
