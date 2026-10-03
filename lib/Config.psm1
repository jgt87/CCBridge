# Settings: config\<name>.json ships with CCBridge; config\<name>.local.json holds this machine's
# overrides (for example the Work IQ selector) and is never touched by updates.

$ErrorActionPreference = 'Stop'

function Merge-JsonObject($Base, $Override) {
    foreach ($p in $Override.PSObject.Properties) {
        $current = $Base.PSObject.Properties[$p.Name]
        if ($current -and $current.Value -is [pscustomobject] -and $p.Value -is [pscustomobject]) {
            Merge-JsonObject $current.Value $p.Value
        } else {
            $Base | Add-Member -Force -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
}

function Get-CCBridgeConfig {
    <# Returns config\<Name>.json merged with config\<Name>.local.json (if present). #>
    param([Parameter(Mandatory)][ValidateSet('harness', 'selectors')][string]$Name, [string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $AppRoot 'config'
    $config = Get-Content (Join-Path $dir "$Name.json") -Raw | ConvertFrom-Json
    $local = Join-Path $dir "$Name.local.json"
    if (Test-Path $local) {
        $override = Get-Content $local -Raw | ConvertFrom-Json
        if ($override) { Merge-JsonObject $config $override }
    }
    $config
}

function Get-CCBridgeVersion([string]$AppRoot) {
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $v = Join-Path $AppRoot 'version.txt'
    if (Test-Path $v) { return ([IO.File]::ReadAllText($v)).Trim() }
    try { $sha = & git -C $AppRoot rev-parse --short HEAD 2>$null; if ($sha) { return "git-$sha" } } catch { }
    'dev'
}

function Get-CCBridgeBuild {
    <# Release version and commit, shown in the web app. A release copy has version.txt and
       commit.txt (written by build-release.ps1); a git copy uses its latest release tag and HEAD. #>
    param([string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $version = $null; $commit = $null
    $v = Join-Path $AppRoot 'version.txt'
    $c = Join-Path $AppRoot 'commit.txt'
    if (Test-Path $v) { $version = ([IO.File]::ReadAllText($v)).Trim() }
    if (Test-Path $c) { $commit = ([IO.File]::ReadAllText($c)).Trim() }
    if (Test-Path (Join-Path $AppRoot '.git')) {
        try {
            if (-not $version) { $version = (& git -C $AppRoot describe --tags --abbrev=0 2>$null | Select-Object -First 1) }
            if (-not $commit) { $commit = (& git -C $AppRoot rev-parse --short HEAD 2>$null | Select-Object -First 1) }
        } catch { }
    }
    [pscustomobject]@{ version = $(if ($version) { "$version" } else { 'dev' }); commit = $(if ($commit) { "$commit" } else { '' }) }
}

function Set-CCBridgeLocalSetting {
    <# Writes one setting into config\<Name>.local.json (kept across updates). #>
    param([Parameter(Mandatory)][ValidateSet('harness', 'selectors')][string]$Name, [Parameter(Mandatory)][string]$Key, $Value, [string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $file = Join-Path $AppRoot "config\$Name.local.json"
    $obj = if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    if (-not $obj) { $obj = [pscustomobject]@{} }
    $obj | Add-Member -Force -NotePropertyName $Key -NotePropertyValue $Value
    [IO.File]::WriteAllText($file, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

# Settings that can be changed in the web app: group, label, help, type, limits. Keys with a dot are
# fields of an object (pacing.beforeSendSec). Values are saved in config\harness.local.json.
$script:SettingDefs = @(
    @{ key = 'pacing.newChatSettleSec'; group = 'Pacing'; label = 'Pause after a new chat (s)'; help = 'Wait after a new Copilot chat is ready, before typing.'; type = 'number'; min = 0; max = 30 }
    @{ key = 'pacing.beforeSendSec'; group = 'Pacing'; label = 'Pause before Send (s)'; help = 'Wait between typing the prompt and pressing Send.'; type = 'number'; min = 0; max = 10 }
    @{ key = 'pacing.betweenPromptsSec'; group = 'Pacing'; label = 'Gap after a reply (s)'; help = 'Minimum time between Copilot''s last reply and the next prompt.'; type = 'number'; min = 0; max = 60 }
    @{ key = 'stallSec'; group = 'Waiting for Copilot'; label = 'Hang after (s)'; help = 'No sign of a reply for this long: stop it and report no answer.'; type = 'number'; min = 30; max = 600 }
    @{ key = 'replyTimeoutSec'; group = 'Waiting for Copilot'; label = 'Reply timeout (s)'; help = 'Longest wait for one reply.'; type = 'number'; min = 60; max = 1800 }
    @{ key = 'messagesPerChat'; group = 'Waiting for Copilot'; label = 'Messages per chat'; help = 'Copilot''s limit per chat when it does not report one; StreamHub continues in a new chat before it.'; type = 'number'; min = 5; max = 300 }
    @{ key = 'actionRetries'; group = 'Getting changes made'; label = 'Retries when Copilot only explains'; help = 'How often a task is sent again when Copilot describes the change instead of writing action blocks.'; type = 'number'; min = 0; max = 5 }
    @{ key = 'maxRounds'; group = 'Getting changes made'; label = 'Rounds per message'; help = 'Most back-and-forth rounds (read, edit, run) for one message.'; type = 'number'; min = 1; max = 50 }
    @{ key = 'commandTimeoutSec'; group = 'Getting changes made'; label = 'Command timeout (s)'; help = 'Longest time a run command may take.'; type = 'number'; min = 10; max = 3600 }
    @{ key = 'reviewAfterChanges'; group = 'Checks'; label = 'Review after changes'; help = 'Ask Copilot to review changed files for leftovers, dead code and broken references.'; type = 'select'; options = @('big', 'always', 'off') }
    @{ key = 'reviewMinLines'; group = 'Checks'; label = 'Big change from (lines)'; help = 'Changed lines from which a change counts as big.'; type = 'number'; min = 5; max = 1000 }
    @{ key = 'pageCheck'; group = 'Checks'; label = 'Page check'; help = 'After web files change, open the page in a browser tab and report JavaScript errors and files that fail to load.'; type = 'select'; options = @('on', 'off') }
    @{ key = 'evidence'; group = 'Checks'; label = 'Evidence per task'; help = 'After a task that changed files, save what was asked, what changed and which checks passed to evidence/ in the project.'; type = 'select'; options = @('on', 'off') }
    @{ key = 'issues.enabled'; group = 'Issues'; label = 'Issue detection'; help = 'Keep an index of problems in every project file (file checks, secrets, code health) and scan the changed files after each task.'; type = 'select'; options = @('on', 'off') }
    @{ key = 'issues.autoFix'; group = 'Issues'; label = 'Fix automatically'; help = 'Problems a task adds that StreamHub sends back to Copilot to fix, one file at a time: error (broken syntax, missing files, typos), secret (keys and passwords in code), health (functions that are too complex). The rest is only reported.'; type = 'select'; options = @('error', 'error,secret', 'error,secret,health', 'none') }
    @{ key = 'issues.maxAttempts'; group = 'Issues'; label = 'Fix attempts per file'; help = 'Fix tasks per file before its remaining problems are marked "gave up".'; type = 'number'; min = 1; max = 5 }
    @{ key = 'appWindow'; group = 'Copilot'; label = 'Open StreamHub'; help = 'copilot-tab: as a tab in the Copilot window, ready for Edge''s Split screen; side-by-side: its own window, with Copilot on the right half of the screen; browser: in your default browser. Applies at the next start.'; type = 'select'; options = @('copilot-tab', 'side-by-side', 'browser') }
    @{ key = 'responseMode'; group = 'Copilot'; label = 'Response mode'; help = 'Copilot''s Auto / Quick response / Think deeper picker: leave = as set on the page.'; type = 'select'; options = @('leave', 'auto', 'quick', 'deep') }
    @{ key = 'resultCharBudget'; group = 'Sizes'; label = 'Results per round (characters)'; help = 'Room for file contents and command output sent back to Copilot in one message.'; type = 'number'; min = 10000; max = 120000 }
    @{ key = 'promptCharBudget'; group = 'Sizes'; label = 'Prompt size (characters)'; help = 'Largest message sent to Copilot (its page accepts up to 128000).'; type = 'number'; min = 20000; max = 125000 }
)

function Get-SettingValue($Obj, [string]$Key) {
    $o = $Obj
    foreach ($part in $Key.Split('.')) { if ($null -eq $o) { return $null }; $o = $o.$part }
    $o
}

function Get-CCBridgeSettings {
    <# The adjustable settings with their current value, default and whether this machine changed it. #>
    param([string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $defaults = Get-Content (Join-Path $AppRoot 'config\harness.json') -Raw | ConvertFrom-Json
    $current = Get-CCBridgeConfig harness $AppRoot
    foreach ($d in $script:SettingDefs) {
        $def = Get-SettingValue $defaults $d.key; $cur = Get-SettingValue $current $d.key
        $o = [ordered]@{ key = $d.key; group = $d.group; label = $d.label; help = $d.help; type = $d.type; value = $cur; default = $def; custom = ("$cur" -ne "$def") }
        if ($d.type -eq 'number') { $o.min = $d.min; $o.max = $d.max } else { $o.options = $d.options }
        [pscustomobject]$o
    }
}

function Set-CCBridgeSetting {
    <# Validates and saves one adjustable setting in harness.local.json; $null resets it to the default.
       Returns the value now in effect. #>
    param([Parameter(Mandatory)][string]$Key, $Value, [string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $d = $script:SettingDefs | Where-Object { $_.key -eq $Key } | Select-Object -First 1
    if (-not $d) { throw "Unknown setting '$Key'." }
    if ($null -ne $Value -and "$Value" -ne '') {
        if ($d.type -eq 'number') {
            $n = 0.0
            if (-not [double]::TryParse("$Value", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { throw "$($d.label) must be a number." }
            if ($n -lt $d.min -or $n -gt $d.max) { throw "$($d.label) must be between $($d.min) and $($d.max)." }
            $Value = if ($n -eq [Math]::Floor($n)) { [int]$n } else { $n }
        } elseif ($d.options -notcontains "$Value") { throw "$($d.label) must be one of: $($d.options -join ', ')." }
    } else { $Value = $null }
    $file = Join-Path $AppRoot 'config\harness.local.json'
    $obj = if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json } else { $null }
    if (-not $obj) { $obj = [pscustomobject]@{} }
    $parts = $Key.Split('.')
    $parent = $obj
    if ($parts.Count -eq 2) {
        if (-not $obj.($parts[0])) { $obj | Add-Member -Force -NotePropertyName $parts[0] -NotePropertyValue ([pscustomobject]@{}) }
        $parent = $obj.($parts[0])
    }
    $leaf = $parts[-1]
    if ($null -eq $Value) { $parent.PSObject.Properties.Remove($leaf) }
    else { $parent | Add-Member -Force -NotePropertyName $leaf -NotePropertyValue $Value }
    if ($parts.Count -eq 2 -and -not @($parent.PSObject.Properties).Count) { $obj.PSObject.Properties.Remove($parts[0]) }
    [IO.File]::WriteAllText($file, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Get-SettingValue (Get-CCBridgeConfig harness $AppRoot) $Key
}

function Reset-CCBridgeSettings {
    <# Puts every adjustable setting back to the app default (removes them from harness.local.json;
       other local values, such as the ports, stay). Returns the keys that were changed. #>
    param([string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $changed = @(Get-CCBridgeSettings $AppRoot | Where-Object custom | ForEach-Object { $_.key })
    foreach ($d in $script:SettingDefs) { $null = Set-CCBridgeSetting $d.key $null $AppRoot }
    $changed
}

function Get-CCBridgeEnvironment {
    <# Facts that help diagnose a machine; no personal data. #>
    param([string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $harness = Get-CCBridgeConfig harness $AppRoot
    $sel = Get-CCBridgeConfig selectors $AppRoot
    [ordered]@{
        ccbridge = Get-CCBridgeVersion $AppRoot
        installKind = $(if (Test-Path (Join-Path $AppRoot '.git')) { 'git' } elseif (Test-Path (Join-Path $AppRoot 'version.txt')) { 'release' } else { 'copy' })
        powershell = $PSVersionTable.PSVersion.ToString()
        languageMode = $ExecutionContext.SessionState.LanguageMode.ToString()
        os = [Environment]::OSVersion.VersionString
        culture = (Get-Culture).Name
        edge = $(if ($edge) { (Get-Item $edge).VersionInfo.ProductVersion } else { 'not found' })
        oneDrive = [ordered]@{ commercial = [bool]$env:OneDriveCommercial; consumer = [bool]$env:OneDriveConsumer; oneDrive = [bool]$env:OneDrive
            used = $(if ($env:OneDriveCommercial -and (Test-Path $env:OneDriveCommercial)) { 'OneDriveCommercial' } elseif ($env:OneDrive -and (Test-Path $env:OneDrive)) { 'OneDrive' } elseif ($env:OneDriveConsumer -and (Test-Path $env:OneDriveConsumer)) { 'OneDriveConsumer' } else { 'none' }) }
        localOverrides = @(Get-ChildItem (Join-Path $AppRoot 'config') -Filter '*.local.json' -ErrorAction SilentlyContinue | ForEach-Object Name)
        settings = [ordered]@{ port = $harness.port; cdpPort = $harness.cdpPort; workIq = $harness.workIq; autoUpdate = $harness.autoUpdate; saveReplyFrames = $harness.saveReplyFrames; promptCharBudget = $harness.promptCharBudget; maxRounds = $harness.maxRounds }
        workIqToggleConfigured = [bool]$sel.workIq.toggle
    }
}

Export-ModuleMember -Function Get-CCBridgeConfig, Get-CCBridgeVersion, Get-CCBridgeBuild, Set-CCBridgeLocalSetting, Get-CCBridgeEnvironment, Get-CCBridgeSettings, Set-CCBridgeSetting, Reset-CCBridgeSettings
