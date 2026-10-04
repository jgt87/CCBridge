# Single sign-on with the Windows work account in StreamHub's own Edge profile, so Copilot signs in
# by itself after a restart. Nothing is stored by StreamHub: Edge uses the work account Windows
# already holds (a device sign-in token, "PRT"). Only StreamHub's profile is changed (Edge's switch
# "Allow single sign-on for work or school sites using this profile", on Edge's own settings page);
# Edge policies and the normal Edge profile are never touched. Used by Settings > Sign-in
# (Server.psm1, /api/sso) and by sso-setup.cmd.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Cdp', 'Prereq') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:SettingsUrl = 'edge://settings/profiles/multiProfileSettings'
# The switch's label in the languages seen so far (Edge's own text).
$script:SwitchPattern = '(?i)single sign-on for work|work or school sites|eenmalige aanmelding.*(werk|school)|einmaliges anmelden.*(arbeits|schul)|authentification unique.*(professionnel|scolaire)|\bSSO\b.*(work|werk|school|schul)'
$script:NotThisPattern = '(?i)microsoft account|microsoft-account|persoonlijk|personal|pers.nliche'
$script:FindJs = @'
(() => {
  const all = []; const walk = (r) => { for (const e of r.querySelectorAll('*')) { all.push(e); if (e.shadowRoot) walk(e.shadowRoot); } }; walk(document);
  const up = (n) => n.parentElement || (n.getRootNode && n.getRootNode().host) || null;
  const byId = (e, id) => { const r = e.getRootNode(); return (r.getElementById ? r.getElementById(id) : null) || document.getElementById(id); };
  const labelOf = (e) => {
    let t = e.getAttribute('aria-label') || '';
    const by = e.getAttribute('aria-labelledby');
    if (!t && by) t = by.split(' ').map(id => { const x = byId(e, id); return x ? (x.innerText || x.textContent || '') : ''; }).join(' ');
    if (!t && e.id) { const l = e.getRootNode().querySelector ? e.getRootNode().querySelector('label[for="' + e.id + '"]') : null; if (l) t = l.innerText || l.textContent || ''; }
    if (!t) { let p = up(e); for (let i = 0; i < 8 && p && !t.trim(); i++, p = up(p)) { const x = (p.innerText || p.textContent || '').trim(); if (x.length <= 400) t = x; else break; } }
    return t.replace(/\s+/g, ' ').trim().slice(0, 140);
  };
  const sw = all.filter(e => e.matches('[role=switch], input[type=checkbox]'));
  window.__ccbSwitches = sw;
  return JSON.stringify(sw.map((e, i) => ({ i, label: labelOf(e), on: e.getAttribute('aria-checked') === 'true' || e.checked === true,
    disabled: e.disabled === true || e.getAttribute('aria-disabled') === 'true' })));
})()
'@

function Select-SsoSwitch {
    <# The single sign-on switch among the switches on Edge's profile settings page (labels as Edge
       shows them); $null when it is not there. #>
    param($Switches)
    @($Switches | Where-Object { $_ -and "$($_.label)" -match $script:SwitchPattern -and "$($_.label)" -notmatch $script:NotThisPattern }) | Select-Object -First 1
}

function Get-CopilotSignInState {
    <# Where StreamHub's Copilot tab is: 'chat' (signed in), 'sign-in page', 'no tab' or 'edge not
       running'. Only the tab addresses are looked at. $Pages is for tests. #>
    param([int]$Port = 9333, $Pages)
    if (-not $PSBoundParameters.ContainsKey('Pages')) {
        if (-not (Test-CdpEndpoint $Port)) { return 'edge not running' }
        $Pages = @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list") | Where-Object { $_.type -eq 'page' })
    }
    $urls = @($Pages | ForEach-Object { "$($_.url)" })
    if (@($urls | Where-Object { $_ -match '^(?i)https://(login\.microsoftonline\.com|login\.live\.com|login\.microsoft\.com|login\.windows\.net)/' }).Count) { return 'sign-in page' }
    if (@($urls | Where-Object { $_ -match '^(?i)https://([a-z0-9-]+\.)?(microsoft365\.com|m365\.cloud\.microsoft|office\.com)/(chat|copilot|launch/copilot)' }).Count) { return 'chat' }
    'no tab'
}

function Open-BackgroundTab([int]$Port, [string]$Url) {
    # A tab that does not take focus from the tab the person is looking at.
    $ver = Invoke-RestMethod "http://127.0.0.1:$Port/json/version"
    $browser = Connect-Cdp $ver.webSocketDebuggerUrl
    try {
        $t = Invoke-Cdp $browser 'Target.createTarget' @{ url = $Url; background = $true }
        $page = $null
        for ($i = 0; $i -lt 20 -and -not $page; $i++) {
            $page = @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list") | Where-Object { $_.id -eq $t.targetId }) | Select-Object -First 1
            if (-not $page) { Start-Sleep -Milliseconds 150 }
        }
        if (-not $page) { throw "Edge did not open $Url" }
        [pscustomobject]@{ Browser = $browser; TargetId = $t.targetId; Session = (Connect-Cdp $page.webSocketDebuggerUrl) }
    } catch { Disconnect-Cdp $browser; throw }
}

function Close-BackgroundTab($Tab) {
    if (-not $Tab) { return }
    try { Disconnect-Cdp $Tab.Session } catch { }
    try { $null = Invoke-Cdp $Tab.Browser 'Target.closeTarget' @{ targetId = $Tab.TargetId } } catch { }
    try { Disconnect-Cdp $Tab.Browser } catch { }
}

function Get-PageSwitches($Session, [int]$WaitSec = 10) {
    $list = @()
    $deadline = (Get-Date).AddSeconds($WaitSec)
    do {
        Start-Sleep -Milliseconds 500
        try { $list = @((Invoke-CdpEval $Session $script:FindJs) | ConvertFrom-Json) } catch { $list = @() }
    } while (-not $list.Count -and (Get-Date) -lt $deadline)
    , $list
}

function Get-SsoStatus {
    <# The whole picture for Settings > Sign-in: work account on this PC, the profile switch
       (on, off, managed, not-found, unavailable = no work account, edge-not-running) and where
       the Copilot tab is. -NoPage skips opening Edge's settings page. #>
    param([int]$Port = 9333, [switch]$NoPage)
    $join = Get-DeviceJoinStatus
    $work = $join['AzureAdPrt'] -eq 'YES'
    $st = [ordered]@{ workAccount = $work; join = $join; profileSso = 'unknown'; switchLabel = ''; copilot = (Get-CopilotSignInState $Port); checkedAt = (Get-Date).ToString('s') }
    if (-not $work) { $st.profileSso = 'unavailable'; return $st }
    if (-not (Test-CdpEndpoint $Port)) { $st.profileSso = 'edge-not-running'; return $st }
    if ($NoPage) { return $st }
    $tab = Open-BackgroundTab $Port $script:SettingsUrl
    try {
        $sw = Select-SsoSwitch (Get-PageSwitches $tab.Session)
        if (-not $sw) { $st.profileSso = 'not-found' }
        else { $st.switchLabel = "$($sw.label)"; $st.profileSso = if ($sw.disabled) { 'managed' } elseif ($sw.on) { 'on' } else { 'off' } }
    } finally { Close-BackgroundTab $tab }
    $st
}

function Set-ProfileSso {
    <# Turns the profile switch on or off. Returns 'turned on', 'turned off', 'already on',
       'already off', 'managed', 'not-found', 'unavailable', 'edge-not-running' or 'did not stick'. #>
    param([int]$Port = 9333, [Parameter(Mandatory)][bool]$On)
    if ((Get-DeviceJoinStatus)['AzureAdPrt'] -ne 'YES') { return 'unavailable' }
    if (-not (Test-CdpEndpoint $Port)) { return 'edge-not-running' }
    $tab = Open-BackgroundTab $Port $script:SettingsUrl
    try {
        $sw = Select-SsoSwitch (Get-PageSwitches $tab.Session)
        if (-not $sw) { return 'not-found' }
        if ([bool]$sw.on -eq $On) { return $(if ($On) { 'already on' } else { 'already off' }) }
        if ($sw.disabled) { return 'managed' }
        $null = Invoke-CdpEval $tab.Session "(() => { const e = window.__ccbSwitches[$($sw.i)]; e.scrollIntoView({ block: 'center' }); e.click(); return true })()"
        Start-Sleep -Seconds 2
        $now = Select-SsoSwitch (Get-PageSwitches $tab.Session 4)
        $result = if ($now -and [bool]$now.on -eq $On) { if ($On) { 'turned on' } else { 'turned off' } } else { 'did not stick' }
        Write-CCBLog info sso "Single sign-on in StreamHub's Edge profile: $result"
        $result
    } finally { Close-BackgroundTab $tab }
}

function Get-SsoKeys([string]$ProfileDir) {
    # Edge's sign-in related settings in StreamHub's profile: names and simple values only.
    $out = [ordered]@{}
    $walk = {
        param($o, $p)
        if ($o -isnot [pscustomobject]) { return }
        foreach ($q in $o.PSObject.Properties) {
            $k = if ($p) { "$p.$($q.Name)" } else { $q.Name }
            if ($q.Value -is [pscustomobject]) { & $walk $q.Value $k }
            elseif ($k -match '(?i)sso|single_sign|aad|implicit_signin' -and ($q.Value -is [bool] -or $q.Value -is [int] -or $q.Value -is [long] -or "$($q.Value)" -match '^[A-Za-z]{1,20}$')) { $out[$k] = "$($q.Value)" }
        }
    }
    foreach ($f in @(@{ n = 'Local State'; p = (Join-Path $ProfileDir 'Local State') }, @{ n = 'Preferences'; p = (Join-Path $ProfileDir 'Default\Preferences') })) {
        try { $j = [IO.File]::ReadAllText($f.p) | ConvertFrom-Json; & $walk $j $f.n } catch { }
    }
    $out
}

function Invoke-SsoSetup {
    <# The full setup with a log: this PC, every switch on Edge's profile page, the change, and
       which of Edge's settings changed. Writes <OutRoot>\StreamHub-sso-<date>.txt (names and
       yes/no values only). $Confirm (scriptblock returning $true) asks before changing. #>
    param([int]$Port = 9333, [bool]$On = $true, [scriptblock]$Confirm, [string]$OutRoot = 'C:\temp',
        [string]$ProfileDir = (Join-Path $env:LOCALAPPDATA 'CCBridge\edge-profile'))
    $log = New-Object System.Collections.Generic.List[string]
    $log.Add("StreamHub single sign-on setup $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Names and yes/no values only.")
    $join = Get-DeviceJoinStatus
    $log.Add('This PC: ' + (($join.Keys | ForEach-Object { "$_=$($join[$_])" }) -join ', '))
    $result = 'unavailable'
    $before = Get-SsoKeys $ProfileDir
    if ($join['AzureAdPrt'] -ne 'YES') {
        $log.Add('No work account token on this PC (AzureAdPrt is not YES): Edge has nothing to sign in with. Sign in to Copilot once in StreamHub''s Edge window and choose "Stay signed in".')
    } elseif (-not (Test-CdpEndpoint $Port)) {
        $result = 'edge-not-running'; $log.Add('StreamHub''s Edge is not running; start StreamHub first.')
    } else {
        $tab = Open-BackgroundTab $Port $script:SettingsUrl
        try {
            $all = Get-PageSwitches $tab.Session
            foreach ($w in $all) { $log.Add("  switch: [$(if ($w.on) { 'on' } else { 'off' })$(if ($w.disabled) { ', managed or disabled' })] $($w.label)") }
            $sw = Select-SsoSwitch $all
            if (-not $sw) { $result = 'not-found'; $log.Add('The single sign-on switch is not on Edge''s profile page (Edge shows it only for a profile that is not signed in with a work account).') }
            elseif ([bool]$sw.on -eq $On) { $result = $(if ($On) { 'already on' } else { 'already off' }) }
            elseif ($sw.disabled) { $result = 'managed'; $log.Add('The switch is managed by your organisation (policy) and cannot be changed here.') }
            elseif ($Confirm -and -not (& $Confirm)) { $result = 'declined' }
            else {
                $null = Invoke-CdpEval $tab.Session "(() => { const e = window.__ccbSwitches[$($sw.i)]; e.scrollIntoView({ block: 'center' }); e.click(); return true })()"
                Start-Sleep -Seconds 2
                $now = Select-SsoSwitch (Get-PageSwitches $tab.Session 4)
                $result = if ($now -and [bool]$now.on -eq $On) { if ($On) { 'turned on' } else { 'turned off' } } else { 'did not stick' }
            }
        } finally { Close-BackgroundTab $tab }
    }
    Start-Sleep -Seconds 3   # Edge writes its settings files shortly after a change
    $after = Get-SsoKeys $ProfileDir
    $log.Add(''); $log.Add("Result: $result")
    $log.Add('Edge sign-in settings (file.key = before -> after):')
    foreach ($k in @(@($before.Keys) + @($after.Keys) | Select-Object -Unique | Sort-Object)) {
        $b = if ($before.Contains($k)) { $before[$k] } else { '-' }; $a = if ($after.Contains($k)) { $after[$k] } else { '-' }
        $log.Add("  $k = $b$(if ($a -ne $b) { " -> $a   CHANGED" })")
    }
    if ($result -in 'turned on', 'already on') { $log.Add(''); $log.Add('Next: restart StreamHub (closing its Edge window). On the next start Copilot should sign in by itself.') }
    $null = New-Item -ItemType Directory -Force -Path $OutRoot
    $file = Join-Path $OutRoot "StreamHub-sso-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    [IO.File]::WriteAllLines($file, [string[]]$log)
    Write-CCBLog info sso "Single sign-on setup: $result" @{ log = $file }
    [pscustomobject]@{ Result = $result; LogFile = $file; Lines = $log.ToArray() }
}

function Open-SsoSettingsPage([int]$Port = 9333) {
    # Edge's profile settings, in front, for the person to look at or change by hand.
    if (-not (Test-CdpEndpoint $Port)) { throw 'StreamHub''s Edge is not running.' }
    $t = Invoke-RestMethod -Method Put "http://127.0.0.1:$Port/json/new?$($script:SettingsUrl)"
    try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/activate/$($t.id)" } catch { }
    $true
}

Export-ModuleMember -Function Select-SsoSwitch, Get-CopilotSignInState, Get-SsoStatus, Set-ProfileSso, Invoke-SsoSetup, Open-SsoSettingsPage
