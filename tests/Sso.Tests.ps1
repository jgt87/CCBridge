# Single sign-on in StreamHub's Edge profile: which switch is the right one, and where the Copilot tab is.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Sso.psm1') -Force

Describe 'Select-SsoSwitch' {
    $sw = { param($i, $label, $on = $false, $disabled = $false) [pscustomobject]@{ i = $i; label = $label; on = $on; disabled = $disabled } }
    It 'picks the work or school switch, also in Dutch and German' {
        (Select-SsoSwitch @((& $sw 0 'Show profile picker'), (& $sw 1 'Allow single sign-on for work or school sites using this profile'))).i | Should Be 1
        (Select-SsoSwitch @((& $sw 3 'Eenmalige aanmelding toestaan voor werk- of schoolsites met dit profiel'))).i | Should Be 3
        (Select-SsoSwitch @((& $sw 4 'Einmaliges Anmelden fuer Arbeits- oder Schulwebsites mit diesem Profil zulassen'))).i | Should Be 4
    }
    It 'never takes the personal Microsoft account switch' {
        Select-SsoSwitch @((& $sw 0 'Allow single sign-on for personal sites using this profile with your Microsoft account')) | Should BeNullOrEmpty
    }
    It 'gives nothing when the switch is not there' {
        Select-SsoSwitch @() | Should BeNullOrEmpty
        Select-SsoSwitch @((& $sw 0 '')) | Should BeNullOrEmpty
    }
}

Describe 'Single sign-on that Edge turned on itself, and the profile account' {
    $dir = Join-Path $env:TEMP ('ccb-sso-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory (Join-Path $dir 'Default') -Force | Out-Null
    It 'reads aad_sso_algo_state 2 as on, 1 as off' {
        [IO.File]::WriteAllText((Join-Path $dir 'Default\Preferences'), '{ "edge": { "profile_sso_info": { "aad_sso_algo_state": 2, "aad_sso_state_reached_by": 3 } } }')
        Test-ProfileSsoAuto $dir | Should Be $true
        [IO.File]::WriteAllText((Join-Path $dir 'Default\Preferences'), '{ "edge": { "profile_sso_info": { "aad_sso_algo_state": 1 } } }')
        Test-ProfileSsoAuto $dir | Should Be $false
        Test-ProfileSsoAuto (Join-Path $dir 'missing') | Should Be $false
    }
    It 'tells a work account from a personal one or none' {
        $ls = Join-Path $dir 'Local State'
        [IO.File]::WriteAllText($ls, '{ "profile": { "info_cache": { "Default": { "edge_account_type": 1, "edge_account_tenant_id": "9188040d-6c67-4c5b-b112-36a304b66dad" } } } }')
        Get-ProfileAccount $dir | Should Be 'personal'
        [IO.File]::WriteAllText($ls, '{ "profile": { "info_cache": { "Default": { "edge_account_type": 2, "edge_account_tenant_id": "11111111-2222-3333-4444-555555555555" } } } }')
        Get-ProfileAccount $dir | Should Be 'work'
        [IO.File]::WriteAllText($ls, '{ "profile": { "info_cache": { "Default": { "edge_account_type": 0 } } } }')
        Get-ProfileAccount $dir | Should Be 'none'
    }
    Remove-Item $dir -Recurse -Force
}

Describe 'Get-CopilotSignInState' {
    $page = { param($url) [pscustomobject]@{ type = 'page'; url = $url } }
    It 'tells a signed-in chat from a sign-in page' {
        Get-CopilotSignInState -Pages @((& $page 'https://m365.cloud.microsoft/chat?x=1')) | Should Be 'chat'
        Get-CopilotSignInState -Pages @((& $page 'https://login.microsoftonline.com/common/oauth2/authorize?x')) | Should Be 'sign-in page'
        Get-CopilotSignInState -Pages @((& $page 'http://localhost:8765/'), (& $page 'about:blank')) | Should Be 'no tab'
        # Copilot's tab on another site (an organisation's own sign-in page): said, with the site.
        $other = @((& $page 'http://localhost:8765/'), (& $page 'https://sso.example.org/app/signin?x=1'))
        Get-CopilotSignInState -Pages $other | Should Be 'other page'
        Get-OtherPageHost -Pages $other | Should Be 'sso.example.org'
        Get-OtherPageHost -Pages @((& $page 'https://m365.cloud.microsoft/chat')) | Should Be $null
    }
    It 'counts a sign-in page first, even when a chat tab is also open' {
        Get-CopilotSignInState -Pages @((& $page 'https://www.microsoft365.com/chat'), (& $page 'https://login.live.com/x')) | Should Be 'sign-in page'
    }
}

Describe 'A hidden settings tab never stays open' {
    It 'closes the tab it made when the page never shows in the debug list, and reports the failure' {
        $global:ssoCalls = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName Sso Invoke-RestMethod { param($Uri) if ("$Uri" -match 'version') { [pscustomobject]@{ webSocketDebuggerUrl = 'ws://x' } } else { @() } }
        Mock -ModuleName Sso Connect-Cdp { [pscustomobject]@{ NextId = 0 } }
        Mock -ModuleName Sso Disconnect-Cdp { }
        Mock -ModuleName Sso Start-Sleep { }
        Mock -ModuleName Sso Invoke-Cdp { param($Session, $Method, $Params) $global:ssoCalls.Add($Method); if ($Method -eq 'Target.createTarget') { [pscustomobject]@{ targetId = 'T1' } } }
        { & (Get-Module Sso) { Open-BackgroundTab 9333 'edge://settings/x' } } | Should Throw 'did not open'
        ($global:ssoCalls -join ',') | Should Be 'Target.createTarget,Target.closeTarget'
    }
    It 'closes the page itself when the browser-level close fails' {
        $global:ssoCalls = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName Sso Disconnect-Cdp { }
        Mock -ModuleName Sso Invoke-Cdp { param($Session, $Method, $Params) $global:ssoCalls.Add($Method); if ($Method -eq 'Target.closeTarget') { throw 'gone' } }
        & (Get-Module Sso) { param($t) Close-BackgroundTab $t } ([pscustomobject]@{ Browser = 1; Session = 2; TargetId = 'T1' })
        ($global:ssoCalls -join ',') | Should Be 'Target.closeTarget,Page.close'
        Remove-Variable -Name ssoCalls -Scope Global
    }
}
