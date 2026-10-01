# Diagnostic log: levels, masking of personal data, and the diagnostics bundle.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Log.psm1') -Force

Describe 'CCBridge log' {
    $today = Join-Path (Get-CCBLogDir) ('ccbridge-' + (Get-Date).ToString('yyyyMMdd') + '.log')
    $marker = 'pester-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    function Get-MarkerLines { if (Test-Path $today) { @(Get-Content $today | Where-Object { $_ -match $marker }) } else { @() } }

    It 'writes info, skips verbose at the default level' {
        Initialize-CCBLog -Level info
        Write-CCBLog info test "$marker info line"
        Write-CCBLog verbose test "$marker verbose line"
        (Get-MarkerLines | Where-Object { $_ -match 'info line' }).Count | Should Be 1
        (Get-MarkerLines | Where-Object { $_ -match 'verbose line' }).Count | Should Be 0
    }

    It 'writes verbose lines with data once verbose is on, but no content below trace' {
        Set-CCBLogLevel verbose
        Write-CCBLog verbose test "$marker verbose data" @{ chars = 42 }
        Write-CCBLog trace test "$marker trace content" @{ text = 'secret prompt' }
        (Get-MarkerLines | Where-Object { $_ -match 'verbose data \{"chars":42\}' }).Count | Should Be 1
        (Get-MarkerLines | Where-Object { $_ -match 'trace content' }).Count | Should Be 0
    }

    It 'masks user name, profile and OneDrive paths and email addresses' {
        Write-CCBLog info test "$marker path $env:USERPROFILE\Documents\x.txt onedrive $env:OneDrive\y.txt user $env:USERNAME mail anna.de.vries@contoso.com"
        $line = Get-MarkerLines | Where-Object { $_ -match ' path ' } | Select-Object -First 1
        $line | Should Match '%USERPROFILE%\\Documents'
        $line | Should Match '%OneDrive%\\y.txt'
        $line | Should Match '<email>'
        $line | Should Not Match ([regex]::Escape($env:USERNAME))
        $line | Should Not Match 'contoso'
    }

    It 'records errors with a PowerShell stack' {
        try { throw 'boom' } catch { Write-CCBLogError test "$marker failing step" $_ }
        (Get-MarkerLines | Where-Object { $_ -match 'ERROR .*failing step: boom' -and $_ -match '"stack"' }).Count | Should Be 1
    }

    It 'packs a diagnostics zip with environment, config and logs' {
        $zip = & (Join-Path $root 'tools\collect-diagnostics.ps1') -NoOpen
        Test-Path $zip | Should Be $true
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        $names = @($z.Entries | ForEach-Object FullName)
        $envJson = (New-Object IO.StreamReader(($z.Entries | Where-Object FullName -eq 'environment.json').Open())).ReadToEnd()
        $z.Dispose()
        ($names -contains 'environment.json') | Should Be $true
        ($names -contains 'config-harness.json') | Should Be $true
        @($names | Where-Object { $_ -like 'logs/*' }).Count -ge 1 | Should Be $true
        @($names | Where-Object { $_ -like 'replies/*' }).Count | Should Be 0
        $envJson | Should Not Match ([regex]::Escape($env:USERNAME))
        [IO.File]::Delete($zip)
    }

    Set-CCBLogLevel info
}
