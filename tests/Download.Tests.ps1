# Chain downloads (lib/Download.psm1, Chain.psm1, Agent Invoke-ChainDownload): a SharePoint or
# OneDrive file into the project through StreamHub's Edge. No network here: the Edge part is
# mocked; addresses, places, contents and the chain lines are checked.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Download.psm1') -Force
Import-Module (Join-Path $root 'lib\Chain.psm1') -Force

$site = 'https://contoso.sharepoint.com/sites/Team/Shared%20Documents/Sales%20Q1.csv'

function New-TestProject {
    $p = Join-Path $env:TEMP ('ccb-dlp-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory (Join-Path $p 'Source'), (Join-Path $p 'Runbooks') -Force | Out-Null
    $p
}

Describe 'Download step text and addresses' {
    It 'reads the link and the place' {
        $d = Read-DownloadStep "$site to Downloads/sales.csv"
        $d.url | Should Be $site
        $d.to | Should Be 'Downloads/sales.csv'
        (Read-DownloadStep "``$site``").to | Should Be ''
        (Read-DownloadStep "<$site> to `"Data\in.csv`"").to | Should Be 'Data/in.csv'
    }
    It 'takes SharePoint and OneDrive links over https only' {
        Test-DownloadAddress $site | Should BeNullOrEmpty
        Test-DownloadAddress 'https://contoso-my.sharepoint.com/personal/x/Documents/a.xlsx' | Should BeNullOrEmpty
        Test-DownloadAddress 'https://1drv.ms/x/s!abc' | Should BeNullOrEmpty
        Test-DownloadAddress 'http://contoso.sharepoint.com/a.csv' | Should Match 'https'
        Test-DownloadAddress 'https://example.com/a.csv' | Should Match 'not SharePoint or OneDrive'
        Test-DownloadAddress 'https://sharepoint.com.example.com/a.csv' | Should Match 'not SharePoint'
        Test-DownloadAddress 'not a link' | Should Match 'not a web address'
    }
    It 'asks SharePoint for the file itself, not its viewer' {
        Add-DownloadParam 'https://x.sharepoint.com/a.csv' | Should Be 'https://x.sharepoint.com/a.csv?download=1'
        Add-DownloadParam 'https://x.sharepoint.com/:x:/s/T/Eab?e=1' | Should Be 'https://x.sharepoint.com/:x:/s/T/Eab?e=1&download=1'
        Add-DownloadParam 'https://x.sharepoint.com/a.csv?download=1' | Should Be 'https://x.sharepoint.com/a.csv?download=1'
    }
}

Describe 'Where a download goes' {
    $p = New-TestProject
    It 'goes to Downloads/ with its own name by default, or where the step says' {
        (Get-DownloadTarget $p $site).rel | Should Be 'Downloads/Sales Q1.csv'
        (Get-DownloadTarget $p $site 'data/in/').rel | Should Be 'data/in/Sales Q1.csv'
        (Get-DownloadTarget $p $site 'Downloads/sales.csv').rel | Should Be 'Downloads/sales.csv'
    }
    It 'never goes into Source/, outside the project or to an unknown file type' {
        (Get-DownloadTarget $p $site 'Source/sales.csv').error | Should Match 'never changed by StreamHub'
        (Get-DownloadTarget $p $site '../x.csv').error | Should Match 'not a path inside the project'
        (Get-DownloadTarget $p $site 'Downloads/x.exe').error | Should Match 'not a data or document file'
        (Get-DownloadTarget $p 'https://x.sharepoint.com/:x:/s/T/Eab?e=1').error | Should Match 'does not show the file name'
        (Get-DownloadTarget $p 'https://x.sharepoint.com/:x:/s/T/Eab?e=1' 'Downloads/t.xlsx').rel | Should Be 'Downloads/t.xlsx'
    }
    It 'tells a web page from the file asked for' {
        $f = Join-Path $p 'got.bin'
        [IO.File]::WriteAllText($f, "<!DOCTYPE html><html><body>Sign in</body></html>")
        Test-DownloadContent $f 'Downloads/a.csv' | Should Match 'web page came back'
        Test-DownloadContent $f 'Downloads/a.xlsx' | Should Match 'not a \.xlsx file'
        [IO.File]::WriteAllText($f, "Date,Amount`n2024-01-31,5")
        Test-DownloadContent $f 'Downloads/a.csv' | Should BeNullOrEmpty
        [IO.File]::WriteAllText($f, '')
        Test-DownloadContent $f 'Downloads/a.csv' | Should Match 'empty'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Download steps in a chain' {
    $p = New-TestProject
    $chain = Join-Path $p 'Runbooks\refresh.chain.md'
    [IO.File]::WriteAllText($chain, "---`ntitle: Refresh`n---`n`n## Steps`n`n1. download: $site to Downloads/sales.csv`n")
    It 'reads a download line and checks it before the chain starts' {
        $s = @(Read-ChainSteps "1. download: $site to Downloads/sales.csv`n2. download: https://example.com/a.csv")
        $s[0].kind | Should Be 'download'
        $s[0].target | Should Be $site
        $s[0].args | Should Be 'Downloads/sales.csv'
        @(Test-ChainSteps $p $s) -join ' ' | Should Match 'step 2: example\.com is not SharePoint'
        @(Test-ChainSteps $p @($s[0])).Count | Should Be 0
    }
    It 'adds a download step, and moves and renumbers it like the others' {
        $null = Set-ChainSteps $p 'refresh' 'add' -Kind 'download' -Target $site -ArgText ''
        $t = [IO.File]::ReadAllText($chain)
        $t | Should Match ([regex]::Escape("2. download: $site to Downloads/Sales Q1.csv"))
        $null = Set-ChainSteps $p 'refresh' 'up' -Index 1
        [IO.File]::ReadAllText($chain) | Should Match ([regex]::Escape("1. download: $site to Downloads/Sales Q1.csv"))
        { Set-ChainSteps $p 'refresh' 'add' -Kind 'download' -Target $site -ArgText 'Source/x.csv' } | Should Throw 'never changed by StreamHub'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Running a download step' {
    Import-Module (Join-Path $root 'lib\Agent.psm1')
    Import-Module (Join-Path $root 'lib\Config.psm1')
    It 'needs a person to approve a link once, and is refused without one' {
        $p = New-TestProject
        $state = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $state.ProjectRoot = $p; $state.Headless = $true
        $r = & (Get-Module Agent) { param($s, $u) Invoke-ChainDownload $s @{ title = 'Refresh' } ([pscustomobject]@{ target = $u; args = 'Downloads/sales.csv' }) ([pscustomobject]@{ Value = $null }) } $state $site
        $r.ok | Should Be $false
        $r.why | Should Match 'needs a person'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'saves an approved download into the project as a change set, and reports a page instead of a file' {
        $p = New-TestProject
        Import-Module (Join-Path $root 'lib\Chain.psm1')
        Add-ApprovedScript $p "download: $site to Downloads/sales.csv" 'download'
        $state = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $state.ProjectRoot = $p
        Mock -ModuleName Agent Get-Bridge { $null }
        Mock -ModuleName Agent Invoke-EdgeDownload { $f = Join-Path $Folder 'g1'; [IO.File]::WriteAllText($f, "Date,Amount`n2024-01-31,5"); @{ path = $f; name = 'Sales Q1.csv' } }
        $box = [pscustomobject]@{ Value = $null }
        $r = & (Get-Module Agent) { param($s, $u, $b) Invoke-ChainDownload $s @{ title = 'Refresh' } ([pscustomobject]@{ target = $u; args = 'Downloads/sales.csv' }) $b } $state $site $box
        $r.ok | Should Be $true
        [IO.File]::ReadAllText((Join-Path $p 'Downloads\sales.csv')) | Should Match '2024-01-31,5'
        $box.Value.Files['Downloads/sales.csv'] | Should Be 'new'
        Mock -ModuleName Agent Invoke-EdgeDownload { $f = Join-Path $Folder 'g2'; [IO.File]::WriteAllText($f, '<!doctype html><html></html>'); @{ path = $f; name = 'x' } }
        $r = & (Get-Module Agent) { param($s, $u, $b) Invoke-ChainDownload $s @{ title = 'Refresh' } ([pscustomobject]@{ target = $u; args = 'Downloads/sales.csv' }) $b } $state $site $box
        $r.ok | Should Be $false
        $r.why | Should Match 'web page came back'
        [IO.File]::ReadAllText((Join-Path $p 'Downloads\sales.csv')) | Should Match '2024-01-31,5'   # the earlier file stays
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
