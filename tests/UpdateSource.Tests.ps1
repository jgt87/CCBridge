# Where updates come from after the rename (lib/Update.psm1): a GitHub request that fails is tried
# once more on the repository's old name (jgt87/CCBridge, pre-rename), and a release zip of either
# name is taken. No network: the requests are script blocks that record what they were asked.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Update.psm1') -Force

Describe 'The repository and its old name' {
    It 'is jgt87/StreamHub, and knows the same address on the old name' {
        Get-ReleaseRepo | Should Be 'jgt87/StreamHub'
        Get-OldRepoUrl 'https://api.github.com/repos/jgt87/StreamHub/releases/latest' | Should Be 'https://api.github.com/repos/jgt87/CCBridge/releases/latest'   # pre-rename
        Get-OldRepoUrl 'https://raw.githubusercontent.com/jgt87/StreamHub/main/install.ps1' | Should Be 'https://raw.githubusercontent.com/jgt87/CCBridge/main/install.ps1'   # pre-rename
        Get-OldRepoUrl 'https://github.com/jgt87/StreamHub/releases/download/v1.0.0/StreamHub-v1.0.0.zip' | Should Be 'https://github.com/jgt87/CCBridge/releases/download/v1.0.0/StreamHub-v1.0.0.zip'   # pre-rename
        Get-OldRepoUrl 'https://api.github.com/repos/jgt87/StreamHubX/releases' | Should Be ''
        Get-OldRepoUrl 'https://example.com/file.zip' | Should Be ''
    }
    It 'asks the new repository first and stops there when it answers' {
        $asked = New-Object Collections.Generic.List[string]
        $r = Invoke-WithRepoFallback -Url 'https://api.github.com/repos/jgt87/StreamHub/releases/latest' -Request { param($u) $asked.Add($u); @{ tag_name = 'v1.0.0' } }.GetNewClosure()
        $r.tag_name | Should Be 'v1.0.0'
        $asked.Count | Should Be 1
    }
    It 'tries the old name once when the new repository fails (not found, no network)' {
        $asked = New-Object Collections.Generic.List[string]
        $notes = New-Object Collections.Generic.List[string]
        $r = Invoke-WithRepoFallback -Url 'https://api.github.com/repos/jgt87/StreamHub/releases/latest' -OnFallback { param($why) $notes.Add($why) }.GetNewClosure() -Request {
            param($u) $asked.Add($u); if ($u -match 'StreamHub') { throw '(404) Not Found' }; @{ tag_name = 'v0.1.170' }
        }.GetNewClosure()
        $r.tag_name | Should Be 'v0.1.170'
        $asked.Count | Should Be 2
        $asked[1] | Should Be 'https://api.github.com/repos/jgt87/CCBridge/releases/latest'   # pre-rename
        $notes[0] | Should Match '404'
    }
    It 'gives up after the old name fails too, with that error' {
        $count = New-Object Collections.Generic.List[int]
        $request = { param($u) $count.Add(1); throw "no network for $u" }.GetNewClosure()
        $err = ''
        try { $null = Invoke-WithRepoFallback -Url 'https://api.github.com/repos/jgt87/StreamHub/releases/latest' -Request $request } catch { $err = $_.Exception.Message }
        $err | Should Be 'no network for https://api.github.com/repos/jgt87/CCBridge/releases/latest'   # pre-rename
        $count.Count | Should Be 2
        { Invoke-WithRepoFallback -Url 'https://example.com/x' -Request { param($u) throw 'down' } } | Should Throw 'down'
    }
}

Describe 'The release zip of either name' {
    It 'takes the StreamHub zip, and in a release from before the rename the old one' {
        $new = [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'SHA256SUMS' }, [pscustomobject]@{ name = 'CCBridge-v1.0.0.zip' }, [pscustomobject]@{ name = 'StreamHub-v1.0.0.zip' }) }   # pre-rename copy beside the new zip
        (Select-ReleaseAsset $new).name | Should Be 'StreamHub-v1.0.0.zip'
        $old = [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'CCBridge-v0.1.170.zip' }) }   # pre-rename asset name
        (Select-ReleaseAsset $old).name | Should Be 'CCBridge-v0.1.170.zip'   # pre-rename asset name
        Select-ReleaseAsset ([pscustomobject]@{ assets = @([pscustomobject]@{ name = 'notes.md' }) }) | Should BeNullOrEmpty
    }
    It 'is published under both names, so an install from before the rename still finds it' {
        $b = [IO.File]::ReadAllText((Join-Path $root 'tools\build-release.ps1'))
        $b | Should Match '"StreamHub-\$Version\.zip"'
        $b | Should Match '"CCBridge-\$Version\.zip"'   # pre-rename asset name
        $b | Should Match "'release', 'create', \`$Version, \`$zip, \`$oldZip, \`$sums"
    }
    It 'is chosen the same way by the installer, which runs on its own' {
        $i = [IO.File]::ReadAllText((Join-Path $root 'tools\install-main.ps1'))
        $i | Should Match "'StreamHub-\*\.zip'"
        $i | Should Match "'CCBridge-\*\.zip'"   # pre-rename asset name
        $i | Should Match 'jgt87/CCBridge'      # pre-rename repository name as the fallback
        [IO.File]::ReadAllText((Join-Path $root 'install.ps1')) | Should Match 'catch \{ Invoke-WebRequest ''https://raw\.githubusercontent\.com/jgt87/CCBridge/main/tools/install-main\.ps1'''   # pre-rename
    }
}
