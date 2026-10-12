# SharePoint links and publishing for SharePoint HTML pages, with the person's own sign-in. The
# SharePoint side is a stand-in here ($Run): the scripts StreamHub would run in the tab, and what
# SharePoint answers. Made-up addresses and ids.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\SharePointLink.psm1') -Force

Describe 'Links to SharePoint files and lists' {
    It 'makes the shares key the way SharePoint documents it' {
        ConvertTo-SharesToken 'https://onedrive.live.com/redir?resid=1231244193912!12&authKey=1201919!12921!1' | Should Be 'u!aHR0cHM6Ly9vbmVkcml2ZS5saXZlLmNvbS9yZWRpcj9yZXNpZD0xMjMxMjQ0MTkzOTEyITEyJmF1dGhLZXk9MTIwMTkxOSExMjkyMSEx'
        Test-SharePointLink 'https://contoso.sharepoint.com/:x:/s/Team/EabcD?e=1' | Should Be $true
        Test-SharePointLink 'https://contoso-my.sharepoint.com/personal/a_b/Documents/x.csv' | Should Be $true
        Test-SharePointLink 'https://example.com/x.csv' | Should Be $false
        Get-SiteFromLink 'https://contoso.sharepoint.com/sites/Team/SitePages/Home.aspx' | Should Be 'https://contoso.sharepoint.com/sites/Team'
    }
    It 'resolves a file link to the drive and item id a LiveData manifest needs' {
        $seen = @{}
        $run = { param($h, $js) $seen.host = $h; $seen.js = $js; '{"id":"01ITEM","name":"tickets.csv","size":120,"driveId":"b!DRIVE"}' }.GetNewClosure()
        $s = Resolve-SharePointSource 'https://contoso.sharepoint.com/:x:/s/Team/EabcD?e=1' -Run $run
        $s.kind | Should Be 'file'
        $s.spItemUrl | Should Be 'https://contoso.sharepoint.com/_api/v2.0/drives/b!DRIVE/items/01ITEM'
        $s.fileName | Should Be 'tickets.csv'
        $seen.host | Should Be 'https://contoso.sharepoint.com'
        $seen.js | Should Match '/_api/v2\.0/shares/u!'
        { Resolve-SharePointSource 'https://contoso.sharepoint.com/:x:/s/Team/Eab' -Run { '{"error":"404 Not Found"}' } } | Should Throw 'could not resolve the file (404 Not Found)'
        { Resolve-SharePointSource 'https://example.com/a.csv' -Run { '' } } | Should Throw 'not a SharePoint'
    }
    It 'resolves a list link to its site and list id' {
        $run = { param($h, $js) if ($js -notmatch "GetList\((\\u0027|')/sites/Team/Lists/Orders(\\u0027|')\)") { throw 'wrong list' }; '{"id":"11111111-2222-3333-4444-555555555555","title":"Orders"}' }
        $s = Resolve-SharePointSource 'https://contoso.sharepoint.com/sites/Team/Lists/Orders/AllItems.aspx' -Run $run
        $s.kind | Should Be 'list'
        $s.webUrl | Should Be 'https://contoso.sharepoint.com/sites/Team'
        $s.listId | Should Be '11111111-2222-3333-4444-555555555555'
        $s.spItemUrl | Should Be 'list:https://contoso.sharepoint.com/sites/Team/11111111-2222-3333-4444-555555555555'
    }
    It 'keeps the linked sources per project and gives Copilot the exact manifest entries' {
        $p = Join-Path $env:TEMP ('ccb-spl-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        try {
            Format-SharePointLinksContext $p | Should Be ''
            $null = Add-SharePointLink $p ([pscustomobject]@{ kind = 'file'; spItemUrl = 'https://h/_api/v2.0/drives/D/items/I'; fileName = 'a.csv'; label = 'a.csv' })
            $null = Add-SharePointLink $p ([pscustomobject]@{ kind = 'list'; spItemUrl = 'list:https://h/sites/x/L'; webUrl = 'https://h/sites/x'; listId = 'L'; label = 'Orders'; fileName = '' })
            $null = Add-SharePointLink $p ([pscustomobject]@{ kind = 'file'; spItemUrl = 'https://h/_api/v2.0/drives/D/items/I'; fileName = 'a.csv'; label = 'a.csv' })
            @((Get-SharePointLinks $p).sources).Count | Should Be 2
            $c = Format-SharePointLinksContext $p
            $c | Should Match 'put exactly these entries in the LiveData manifest'
            $c | Should Match ([regex]::Escape('{"spItemUrl":"https://h/_api/v2.0/drives/D/items/I","fileName":"a.csv"}'))
            $c | Should Match ([regex]::Escape('"kind":"list","spItemUrl":"list:https://h/sites/x/L","webUrl":"https://h/sites/x","listId":"L"'))
            $null = Remove-SharePointLink $p 'list:https://h/sites/x/L'
            @((Get-SharePointLinks $p).sources).Count | Should Be 1
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Publishing a page to Site Pages' {
    It 'looks first, without uploading' {
        $run = { param($h, $js, $chunks) if ($js -match 'Files/add') { throw 'uploaded on a look' }; '{"exists":true}' }
        $r = Publish-SharePointPage -Site 'https://contoso.sharepoint.com/sites/Team/SitePages/Home.aspx' -FileName 'tickets.html' -WhatIf -Run $run
        $r.target | Should Be 'https://contoso.sharepoint.com/sites/Team/SitePages/tickets.html'
        $r.exists | Should Be $true
    }
    It 'uploads in parts, and replaces a page of the same name only when asked' {
        $seen = @{}
        $run = { param($h, $js, $chunks) $seen.js = $js; $seen.chunks = @($chunks).Count; '{"url":"/sites/Team/SitePages/tickets.html","replaced":false}' }.GetNewClosure()
        $html = '<!doctype html>' + ('x' * 900000)
        $r = Publish-SharePointPage -Site 'https://contoso.sharepoint.com/sites/Team' -FileName 'tickets.html' -Html $html -Run $run
        $r.target | Should Be 'https://contoso.sharepoint.com/sites/Team/SitePages/tickets.html'
        $seen.chunks | Should Be 3
        $seen.js | Should Match "GetFolderByServerRelativeUrl\((\\u0027|')/sites/Team/SitePages(\\u0027|')\)/Files/add\(url=(\\u0027|')tickets\.html(\\u0027|'),overwrite=false\)"
        $seen.js | Should Match 'X-RequestDigest'
        { Publish-SharePointPage -Site 'https://contoso.sharepoint.com/sites/Team' -FileName 'tickets.html' -Html 'x' -Run { '{"error":"exists"}' } } | Should Throw 'confirm replacing it'
        { Publish-SharePointPage -Site 'https://contoso.sharepoint.com/sites/Team' -FileName '../x.html' -Html 'x' -Run { '' } } | Should Throw 'plain .html file name'
        { Publish-SharePointPage -Site 'https://example.com/sites/Team' -FileName 'a.html' -Html 'x' -Run { '' } } | Should Throw 'must be a SharePoint address'
        { Publish-SharePointPage -Site 'https://contoso.sharepoint.com/sites/Team' -FileName 'a.html' -Html ('x' * (10MB + 1)) -Run { '' } } | Should Throw 'at most 10 MB'
    }
}
