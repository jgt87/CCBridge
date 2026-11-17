# Pester 3.4 syntax: Should Be.
# lib/SyncedFiles.psm1: the web address of a file in a folder OneDrive syncs (personal OneDrive, a
# work OneDrive, a SharePoint / Teams library). Provider records are stand-ins passed in: the real
# registry is never read or written here. Made-up tenants and account ids only.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\SyncedFiles.psm1') -Force

$script:Personal = @{ path = 'C:\Users\someone\OneDrive'; url = 'https://d.docs.live.net/0123456789abcdef/' }
$script:Work = @{ path = 'C:\Users\someone\OneDrive - Contoso'; url = 'https://contoso-my.sharepoint.com/personal/someone_contoso_example/Documents' }
$script:Team = @{ path = 'C:\Users\someone\Contoso\Team Site - Shared Documents'; url = 'https://contoso.sharepoint.com/sites/Team/Shared Documents/' }

Describe 'Get-SyncedWebUrl' {
    $roots = @($script:Personal, $script:Work, $script:Team)
    It 'gives a personal OneDrive file its address under the account id' {
        Get-SyncedWebUrl -Path 'C:\Users\someone\OneDrive\CCBridge\Site\index.html' -Roots $roots | Should Be 'https://d.docs.live.net/0123456789abcdef/CCBridge/Site/index.html'
    }
    It 'gives a work OneDrive file its address' {
        Get-SyncedWebUrl -Path 'C:\Users\someone\OneDrive - Contoso\CCBridge\Report\Source\sales.xlsx' -Roots $roots | Should Be 'https://contoso-my.sharepoint.com/personal/someone_contoso_example/Documents/CCBridge/Report/Source/sales.xlsx'
    }
    It 'gives a SharePoint / Teams library file its address, the library''s own space escaped' {
        Get-SyncedWebUrl -Path 'C:\Users\someone\Contoso\Team Site - Shared Documents\Plans\Q3.docx' -Roots $roots | Should Be 'https://contoso.sharepoint.com/sites/Team/Shared%20Documents/Plans/Q3.docx'
    }
    It 'escapes spaces and special characters in each folder and file name' {
        $e = [string][char]0xE9   # e with an acute accent; this file stays ASCII
        Get-SyncedWebUrl -Path "C:\Users\someone\OneDrive\Q3 plans\Caf$e #1 & more%\a+b (v2).txt" -Roots $roots | Should Be 'https://d.docs.live.net/0123456789abcdef/Q3%20plans/Caf%C3%A9%20%231%20%26%20more%25/a%2Bb%20(v2).txt'   # Uri.EscapeDataString keeps ( and ), which are valid in an address
    }
    It 'never escapes an address twice when OneDrive recorded it escaped' {
        $escaped = @{ path = 'C:\Sync\Team'; url = 'https://contoso.sharepoint.com/sites/Team/Shared%20Documents' }
        Get-SyncedWebUrl -Path 'C:\Sync\Team\a b.txt' -Roots @($escaped) | Should Be 'https://contoso.sharepoint.com/sites/Team/Shared%20Documents/a%20b.txt'
    }
    It 'gives $null for a path outside every synced folder, a look-alike folder name, or the folder itself' {
        Get-SyncedWebUrl -Path 'C:\Projects\a.txt' -Roots $roots | Should Be $null
        Get-SyncedWebUrl -Path 'C:\Users\someone\OneDriveOld\a.txt' -Roots $roots | Should Be $null
        Get-SyncedWebUrl -Path 'C:\Users\someone\OneDrive' -Roots $roots | Should Be $null
        Get-SyncedWebUrl -Path 'C:\Users\someone\OneDrive\a.txt' -Roots @() | Should Be $null
    }
    It 'lets a longer synced folder inside another one win, in any order' {
        $outer = @{ path = 'C:\Sync'; url = 'https://d.docs.live.net/0123456789abcdef/' }
        $inner = @{ path = 'C:\Sync\Library'; url = 'https://contoso.sharepoint.com/sites/Lib/Docs' }
        Get-SyncedWebUrl -Path 'C:\Sync\Library\x.txt' -Roots @($outer, $inner) | Should Be 'https://contoso.sharepoint.com/sites/Lib/Docs/x.txt'
        Get-SyncedWebUrl -Path 'C:\Sync\Library\x.txt' -Roots @($inner, $outer) | Should Be 'https://contoso.sharepoint.com/sites/Lib/Docs/x.txt'
        Get-SyncedWebUrl -Path 'C:\Sync\Other\x.txt' -Roots @($inner, $outer) | Should Be 'https://d.docs.live.net/0123456789abcdef/Other/x.txt'
    }
    It 'matches drive and folders ignoring case, and keeps the file name''s own case' {
        Get-SyncedWebUrl -Path 'c:\USERS\SOMEONE\onedrive\Site\Index.HTML' -Roots $roots | Should Be 'https://d.docs.live.net/0123456789abcdef/Site/Index.HTML'
    }
    It 'matches a folder or file given by its 8.3 short name' {
        $d = Join-Path $env:TEMP ('ccb sync ' + [guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $d 'Long folder name\Sub')
            $f = Join-Path $d 'Long folder name\Sub\report file.txt'
            [IO.File]::WriteAllText($f, 'x')
            $fso = New-Object -ComObject Scripting.FileSystemObject
            $shortDir = $fso.GetFolder($d).ShortPath
            $shortFile = $fso.GetFile($f).ShortPath
            $url = 'https://contoso.sharepoint.com/sites/Team/Docs'
            $want = "$url/Long%20folder%20name/Sub/report%20file.txt"
            Get-SyncedWebUrl -Path $f -Roots @(@{ path = $shortDir; url = $url }) | Should Be $want
            Get-SyncedWebUrl -Path $shortFile -Roots @(@{ path = $d; url = $url }) | Should Be $want
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'ConvertTo-SyncRoots (provider records as the registry holds them)' {
    It 'adds the account id to personal OneDrive''s bare address and keeps a library''s full address' {
        $recs = @(
            [pscustomobject]@{ MountPoint = 'C:\Users\someone\OneDrive'; UrlNamespace = 'https://d.docs.live.net/' }
            [pscustomobject]@{ MountPoint = 'C:\Users\someone\Contoso\Team Site - Shared Documents\'; UrlNamespace = 'https://contoso.sharepoint.com/sites/Team/Shared Documents/' }
        )
        $r = @(ConvertTo-SyncRoots -Providers $recs -PersonalCid 'a1b2c3d4e5f60718')
        $r.Count | Should Be 2
        $r[0].path | Should Be 'C:\Users\someone\Contoso\Team Site - Shared Documents'   # longest first, no trailing \
        $r[0].url | Should Be 'https://contoso.sharepoint.com/sites/Team/Shared Documents/'
        $r[1].url | Should Be 'https://d.docs.live.net/a1b2c3d4e5f60718/'
        Get-SyncedWebUrl -Path 'C:\Users\someone\OneDrive\a.txt' -Roots $r | Should Be 'https://d.docs.live.net/a1b2c3d4e5f60718/a.txt'
    }
    It 'leaves out personal OneDrive without an account id, a record without a folder or an https address' {
        $recs = @(
            @{ MountPoint = 'C:\Users\someone\OneDrive'; UrlNamespace = 'https://d.docs.live.net/' }
            @{ MountPoint = ''; UrlNamespace = 'https://contoso.sharepoint.com/sites/A' }
            @{ MountPoint = 'C:\X'; UrlNamespace = 'http://contoso.sharepoint.com/sites/A' }
            [pscustomobject]@{ UrlNamespace = 'https://contoso.sharepoint.com/sites/B' }
        )
        @(ConvertTo-SyncRoots -Providers $recs).Count | Should Be 0
    }
}

Describe 'Resolve-SyncRootUrl and ConvertTo-SyncedUrl (pure)' {
    It 'resolves personal and work addresses as the sibling tool does' {
        Resolve-SyncRootUrl -Url 'https://d.docs.live.net/' -PersonalCid 'a1b2c3d4e5f60718' | Should Be 'https://d.docs.live.net/a1b2c3d4e5f60718/'
        Resolve-SyncRootUrl -Url 'https://d.docs.live.net/' | Should Be ''
        Resolve-SyncRootUrl -Url 'https://contoso-my.sharepoint.com/personal/x/Documents' -PersonalCid 'zz' | Should Be 'https://contoso-my.sharepoint.com/personal/x/Documents'
    }
    It 'adds a slash after a root address without a path' {
        ConvertTo-SyncedUrl -Root @{ path = 'C:\Sync\P'; url = 'https://contoso.sharepoint.com' } -Path 'C:\Sync\P\a.txt' | Should Be 'https://contoso.sharepoint.com/a.txt'
    }
}
