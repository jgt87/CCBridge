# The Copilot tab follows the app's theme (setting copilotTheme): Set-CopilotTheme (CopilotBridge)
# and when the worker applies it (Agent Update-CopilotTheme). The browser connection is mocked.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Set-CopilotTheme' {
    Mock -ModuleName CopilotBridge Invoke-Cdp { param($Session, $Method, $Params) $global:ccbCdp += , @{ method = $Method; params = $Params } }
    $bridge = [pscustomobject]@{ Session = [pscustomobject]@{ Lost = $false } }
    It 'tells the tab which theme the system prefers, and clears it for system' {
        $global:ccbCdp = @()
        Set-CopilotTheme $bridge 'dark'
        Set-CopilotTheme $bridge 'light'
        Set-CopilotTheme $bridge 'system'
        $global:ccbCdp.Count | Should Be 3
        $global:ccbCdp[0].method | Should Be 'Emulation.setEmulatedMedia'
        @($global:ccbCdp[0].params.features)[0].name | Should Be 'prefers-color-scheme'
        @($global:ccbCdp[0].params.features)[0].value | Should Be 'dark'
        @($global:ccbCdp[1].params.features)[0].value | Should Be 'light'
        @($global:ccbCdp[2].params.features).Count | Should Be 0
        ($global:ccbCdp[2].params | ConvertTo-Json -Compress) | Should Be '{"features":[]}'
        ($global:ccbCdp[0].params | ConvertTo-Json -Compress -Depth 4) | Should Be '{"features":[{"value":"dark","name":"prefers-color-scheme"}]}'
        { Set-CopilotTheme $bridge 'blue' } | Should Throw
    }
}

Describe 'Update-CopilotTheme (the worker applies the app''s theme once per connection)' {
    Mock -ModuleName Agent Set-CopilotTheme { param($Bridge, $Theme) $global:ccbThemes += , $Theme }
    Mock -ModuleName Agent Disconnect-Copilot { }
    $config = Get-CCBridgeConfig harness $root
    $setBridge = { param($b) & (Get-Module Agent) { param($x) $script:Bridge = $x } $b }

    It 'does nothing before the app said which theme it shows, or without a connection' {
        $global:ccbThemes = @()
        $s = New-AgentState -Config $config -AppRoot $root
        & $setBridge ([pscustomobject]@{ Session = [pscustomobject]@{ Lost = $false } })
        Update-CopilotTheme $s
        $s.CopilotTheme = 'dark'
        & $setBridge $null
        Update-CopilotTheme $s
        $global:ccbThemes.Count | Should Be 0
    }
    It 'applies a new choice once, and again only when it changes or after a new connection' {
        $global:ccbThemes = @()
        $s = New-AgentState -Config $config -AppRoot $root
        & $setBridge ([pscustomobject]@{ Session = [pscustomobject]@{ Lost = $false } })
        $s.CopilotTheme = 'dark'
        Update-CopilotTheme $s
        Update-CopilotTheme $s
        $s.CopilotTheme = 'light'
        Update-CopilotTheme $s
        $global:ccbThemes -join ',' | Should Be 'dark,light'
        & (Get-Module Agent) { param($st) Reset-Bridge $st } $s   # the connection ends: so does the override
        $s.CopilotThemeApplied | Should BeNullOrEmpty
        & $setBridge ([pscustomobject]@{ Session = [pscustomobject]@{ Lost = $false } })
        Update-CopilotTheme $s
        $global:ccbThemes -join ',' | Should Be 'dark,light,light'
    }
    It 'gives the tab back to Windows when the setting is off' {
        $global:ccbThemes = @()
        $s = New-AgentState -Config $config -AppRoot $root
        & $setBridge ([pscustomobject]@{ Session = [pscustomobject]@{ Lost = $false } })
        $s.CopilotTheme = 'dark'
        $s.Config.copilotTheme = $false
        Get-CopilotThemeWanted $s | Should Be 'system'
        Update-CopilotTheme $s
        $global:ccbThemes -join ',' | Should Be 'system'
        $s.Config.copilotTheme = $true
        Get-CopilotThemeWanted $s | Should Be 'dark'
    }
    & $setBridge $null
}
