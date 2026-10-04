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

Describe 'Get-CopilotSignInState' {
    $page = { param($url) [pscustomobject]@{ type = 'page'; url = $url } }
    It 'tells a signed-in chat from a sign-in page' {
        Get-CopilotSignInState -Pages @((& $page 'https://m365.cloud.microsoft/chat?x=1')) | Should Be 'chat'
        Get-CopilotSignInState -Pages @((& $page 'https://login.microsoftonline.com/common/oauth2/authorize?x')) | Should Be 'sign-in page'
        Get-CopilotSignInState -Pages @((& $page 'http://localhost:8765/'), (& $page 'about:blank')) | Should Be 'no tab'
    }
    It 'counts a sign-in page first, even when a chat tab is also open' {
        Get-CopilotSignInState -Pages @((& $page 'https://www.microsoft365.com/chat'), (& $page 'https://login.live.com/x')) | Should Be 'sign-in page'
    }
}
