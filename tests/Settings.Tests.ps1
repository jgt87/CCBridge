# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# Settings that are a switch, a list of commands, or shown only (ports).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Config.psm1') -Force

Describe 'Settings: switches, command lists and shown-only values' {
    $app = Join-Path $env:TEMP ('ccb-settings-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $app 'config')
    Copy-Item (Join-Path $root 'config\harness.json') (Join-Path $app 'config\harness.json')
    $get = { param($k) @(Get-CCBridgeSettings $app) | Where-Object key -eq $k }

    It 'turns a switch off and on (also from the words off and on)' {
        $null = Set-CCBridgeSetting saveReplyFrames 'off' $app
        (& $get 'saveReplyFrames').value | Should Be $false
        $null = Set-CCBridgeSetting saveReplyFrames $true $app
        (& $get 'saveReplyFrames').value | Should Be $true
        $null = Set-CCBridgeSetting chatHistory $false $app
        (Get-CCBridgeConfig harness $app).chatHistory | Should Be $false
    }

    It 'takes a response mode read from Copilot''s picker, and refuses other unknown values' {
        $null = Set-CCBridgeSetting responseMode 'pick:GPT > GPT-6.1 Sol' $app
        (Get-CCBridgeConfig harness $app).responseMode | Should Be 'pick:GPT > GPT-6.1 Sol'
        { Set-CCBridgeSetting responseMode 'fastest' $app } | Should Throw 'must be one of'
        $null = Set-CCBridgeSetting responseMode 'deep' $app
    }

    It 'keeps commands as command starts and saves them as exact patterns' {
        $null = Set-CCBridgeSetting autoApproveCommands "npm test`n`ngit status`nnpm test" $app
        (& $get 'autoApproveCommands').value -join '|' | Should Be 'npm test|git status'
        $p = @((Get-CCBridgeConfig harness $app).autoApproveCommands)
        'npm test --watch' -match $p[0] | Should Be $true
        'npm testing' -match $p[0] | Should Be $false
        # A second command chained on with ; does not ride along: it asks as usual.
        'git status; Remove-Item x' -match $p[1] | Should Be $false
        'git status --short' -match $p[1] | Should Be $true
    }

    It 'shows the ports but does not let them be changed' {
        (& $get 'port').type | Should Be 'info'
        { Set-CCBridgeSetting port 9000 $app } | Should Throw
    }

    It 'resets everything except the ports' {
        Set-CCBridgeLocalSetting harness port 8790 $app
        $null = Set-CCBridgeSetting startMode 'plan' $app
        $changed = @(Reset-CCBridgeSettings $app)
        $changed -contains 'startMode' | Should Be $true
        (Get-CCBridgeConfig harness $app).port | Should Be 8790
        @(Get-CCBridgeSettings $app | Where-Object custom).Count | Should Be 0
    }

    [IO.Directory]::Delete($app, $true)
}
