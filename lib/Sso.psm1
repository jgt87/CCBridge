# Single sign-on with the Windows work account in StreamHub's own Edge profile, so Copilot signs in
# by itself after a restart. Nothing is stored by StreamHub: Edge uses the work account Windows
# already holds (a device sign-in token, "PRT"). Only StreamHub's profile is changed (Edge's switch
# "Allow single sign-on for work or school sites using this profile", on Edge's own settings page);
# Edge policies and the normal Edge profile are never touched. Used by Settings > Sign-in
# (Server.psm1, /api/sso) and by sso-setup.cmd.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Cdp', 'Prereq', 'Config', 'CopilotBridge') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }
$script:MsaTenant = '9188040d-6c67-4c5b-b112-36a304b66dad'   # the tenant of personal Microsoft accounts

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
    <# Where StreamHub's Copilot tab is: 'chat' (signed in), 'sign-in page' (Microsoft's), 'other page'
       (a web page on another site, such as an organisation's own sign-in page: Get-OtherPageHost
       names it), 'no tab' or 'edge not running'. Only the tab addresses are looked at. $Pages is for tests. #>
    param([int]$Port = 9333, $Pages)
    if (-not $PSBoundParameters.ContainsKey('Pages')) {
        if (-not (Test-CdpEndpoint $Port)) { return 'edge not running' }
        $Pages = @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list") | Where-Object { $_.type -eq 'page' })
    }
    $urls = @($Pages | ForEach-Object { "$($_.url)" })
    if (@($urls | Where-Object { $_ -match '^(?i)https://(login\.microsoftonline\.com|login\.live\.com|login\.microsoft\.com|login\.windows\.net)/' }).Count) { return 'sign-in page' }
    $sel = try { Get-CCBridgeConfig selectors (Split-Path -Parent $PSScriptRoot) } catch { $null }
    $onCopilot = @($urls | Where-Object { if ($sel) { Test-CopilotUrl $_ $sel } else { $_ -match '^(?i)https://([a-z0-9-]+\.)*(microsoft365\.com|m365\.cloud\.microsoft|office\.com)/' } })
    if ($onCopilot.Count) { return 'chat' }
    if (Get-OtherPageHost -Pages $Pages) { return 'other page' }
    'no tab'
}

function Get-OtherPageHost {
    <# The site of a web page in StreamHub's Edge that is neither Copilot, Microsoft's sign-in nor the
       app itself: where Copilot's tab went instead (often the organisation's sign-in page). Host only. #>
    param([int]$Port = 9333, $Pages)
    if (-not $PSBoundParameters.ContainsKey('Pages')) {
        if (-not (Test-CdpEndpoint $Port)) { return $null }
        $Pages = @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list") | Where-Object { $_.type -eq 'page' })
    }
    foreach ($p in @($Pages)) {
        $u = $null; try { $u = [Uri]"$($p.url)" } catch { continue }
        if ($u.Scheme -notin 'http', 'https' -or $u.Host -match '^(localhost|127\.0\.0\.1|\[::1\])$') { continue }
        if ($u.Host -match '(?i)(^|\.)(microsoft365\.com|m365\.cloud\.microsoft|office\.com)$') { continue }
        return $u.Host
    }
    $null
}

function Get-TabAddresses([int]$Port = 9333) {
    # Where StreamHub's Edge tabs are: site and path only (no query, no ids), for the setup log.
    if (-not (Test-CdpEndpoint $Port)) { return @() }
    @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list") | Where-Object { $_.type -eq 'page' } | ForEach-Object {
        try { $u = [Uri]"$($_.url)"; if ($u.Scheme -in 'http', 'https') { "$($u.Host)$(($u.AbsolutePath -replace '/[0-9a-fA-F-]{16,}', '/*'))" } else { "$($u.Scheme):$($u.AbsolutePath)" } } catch { '?' }
    })
}

function Test-ProfileSsoAuto {
    <# Whether Edge turned single sign-on for work sites on by itself for StreamHub's profile:
       Preferences edge.profile_sso_info.aad_sso_algo_state = 2 ("intelligent enablement" for a
       single profile on a work PC; 1 = off). Read only. #>
    param([string]$ProfileDir = (Join-Path $env:LOCALAPPDATA 'CCBridge\edge-profile'))
    try { $p = [IO.File]::ReadAllText((Join-Path $ProfileDir 'Default\Preferences')) | ConvertFrom-Json } catch { return $false }
    "$($p.edge.profile_sso_info.aad_sso_algo_state)" -eq '2'
}

function Get-ProfileAccount {
    <# Which account StreamHub's Edge profile is signed in with: 'work' (work or school account),
       'personal' (Microsoft account), 'none' or 'unknown'. Only the account type is read. #>
    param([string]$ProfileDir = (Join-Path $env:LOCALAPPDATA 'CCBridge\edge-profile'))
    try { $j = [IO.File]::ReadAllText((Join-Path $ProfileDir 'Local State')) | ConvertFrom-Json } catch { return 'unknown' }
    $d = $j.profile.info_cache.Default
    if (-not $d) { return 'unknown' }
    $type = "$($d.edge_account_type)"
    $tenant = "$($d.edge_account_tenant_id)"
    if ($type -eq '2' -or ($tenant -and $tenant -ne $script:MsaTenant -and $type -ne '1' -and $type -ne '0')) { return 'work' }
    if ($type -eq '1') { return 'personal' }
    if ($type -in '', '0') { return 'none' }
    'unknown'
}

function Open-BackgroundTab([int]$Port, [string]$Url) {
    # A tab that does not take focus from the tab the person is looking at. When the page never shows
    # up in Edge's debug list (an edge:// page a policy keeps from debugging, a slow start), the tab
    # that was made is closed again before the error goes up: a settings tab must never stay open.
    $ver = Invoke-RestMethod "http://127.0.0.1:$Port/json/version"
    $browser = Connect-Cdp $ver.webSocketDebuggerUrl
    $targetId = $null
    try {
        $t = Invoke-Cdp $browser 'Target.createTarget' @{ url = $Url; background = $true }
        $targetId = $t.targetId
        $page = $null
        for ($i = 0; $i -lt 20 -and -not $page; $i++) {
            $page = @((Invoke-RestMethod "http://127.0.0.1:$Port/json/list") | Where-Object { $_.id -eq $targetId }) | Select-Object -First 1
            if (-not $page) { Start-Sleep -Milliseconds 150 }
        }
        if (-not $page) { throw "Edge did not open $Url" }
        [pscustomobject]@{ Browser = $browser; TargetId = $targetId; Session = (Connect-Cdp $page.webSocketDebuggerUrl) }
    } catch {
        if ($targetId) { try { $null = Invoke-Cdp $browser 'Target.closeTarget' @{ targetId = $targetId } } catch { } }
        Disconnect-Cdp $browser
        throw
    }
}

function Close-BackgroundTab($Tab) {
    # The browser-level close first; when that fails, the page closes itself (Page.close), so the
    # tab is gone either way.
    if (-not $Tab) { return }
    $closed = $false
    try { $null = Invoke-Cdp $Tab.Browser 'Target.closeTarget' @{ targetId = $Tab.TargetId }; $closed = $true } catch { }
    if (-not $closed -and $Tab.Session) { try { $null = Invoke-Cdp $Tab.Session 'Page.close' @{} } catch { } }
    try { Disconnect-Cdp $Tab.Session } catch { }
    try { Disconnect-Cdp $Tab.Browser } catch { }
}

function Get-PageSwitches($Session, [int]$WaitSec = 10) {
    $list = @()
    $deadline = (Get-Date).AddSeconds($WaitSec)
    do {
        Start-Sleep -Milliseconds 500
        # Assigned first: in 5.1 a JSON list arrives as one object inside a pipeline or @().
        try { $parsed = ConvertFrom-Json "$(Invoke-CdpEval $Session $script:FindJs)"; $list = @(foreach ($x in $parsed) { $x }) } catch { $list = @() }
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
    $st = [ordered]@{ workAccount = $work; join = $join; profileSso = 'unknown'; switchLabel = ''; profileAccount = (Get-ProfileAccount); copilot = (Get-CopilotSignInState $Port); copilotHost = (Get-OtherPageHost $Port); checkedAt = (Get-Date).ToString('s') }
    if (-not $work) { $st.profileSso = 'unavailable'; return $st }
    if (-not (Test-CdpEndpoint $Port)) { $st.profileSso = 'edge-not-running'; return $st }
    if ($NoPage) { return $st }
    $tab = Open-BackgroundTab $Port $script:SettingsUrl
    try {
        $sw = Select-SsoSwitch (Get-PageSwitches $tab.Session)
        # Edge offers the switch only for profiles without a work account; signed in with one, work
        # sites already sign in with it.
        if (-not $sw) { $st.profileSso = $(if (Test-ProfileSsoAuto) { 'on-auto' } elseif ($st.profileAccount -eq 'work') { 'signed-in-work' } else { 'not-found' }) }
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
            elseif ($k -match '(?i)sso|single_sign|aad|implicit_signin|edge_account_type$' -and $k -notmatch '(?i)arbitration_experiences' -and ($q.Value -is [bool] -or $q.Value -is [int] -or $q.Value -is [long] -or "$($q.Value)" -match '^[A-Za-z]{1,20}$')) { $out[$k] = "$($q.Value)" }
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
    $account = Get-ProfileAccount $ProfileDir
    $log.Add("StreamHub's Edge profile is signed in with: $(switch ($account) { 'work' { 'a work or school account' } 'personal' { 'a personal Microsoft account' } 'none' { 'no account' } default { 'unknown' } })")
    $log.Add('Edge tabs (site and path): ' + ((@(Get-TabAddresses $Port)) -join ', '))
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
            $sw = Select-SsoSwitch $all
            # Every switch on Edge's profile page; only the one labelled for single sign-on counts.
            foreach ($w in $all) {
                $what = $(if ($sw -and $w.i -eq $sw.i) { ' (the single sign-on switch)' } else { ' (another setting, not single sign-on)' })
                $log.Add("  switch on the page: [$(if ($w.on) { 'on' } else { 'off' })$(if ($w.disabled) { ', managed or disabled' })] $(if ("$($w.label)".Trim()) { $w.label } else { '(no label)' })$what")
            }
            if (-not $sw -and (Test-ProfileSsoAuto $ProfileDir)) { $result = 'already on'; $log.Add('Already on: Edge turned single sign-on for work sites on by itself for this profile (edge.profile_sso_info.aad_sso_algo_state = 2), so there is no switch to change. If Copilot still asks to sign in after a restart, sign in once and choose "Stay signed in".') }
            elseif (-not $sw -and $account -eq 'work') { $result = 'signed-in-work'; $log.Add('No switch needed: the profile is signed in with a work account, so Edge signs work sites in with it already. If Copilot still asks to sign in after a restart, choose "Stay signed in" once.') }
            elseif (-not $sw) { $result = 'not-found'; $log.Add("The single sign-on switch is not on Edge's profile page ($(@($all).Count) switch(es) found; Edge shows it only for a profile that is not signed in with a work account).") }
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

Export-ModuleMember -Function Select-SsoSwitch, Get-CopilotSignInState, Get-OtherPageHost, Test-ProfileSsoAuto, Get-ProfileAccount, Get-TabAddresses, Get-SsoStatus, Set-ProfileSso, Invoke-SsoSetup, Open-SsoSettingsPage
