# The app refers to no GitHub repository but its own (jgt87/CCBridge): in the source, the docs and
# the built interface. package-lock.json is written by npm (funding links of packages) and is not
# shipped; the build itself removes such links from the bundled libraries (ui-src/vite.config.ts).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Describe 'References to other repositories' {
    It 'has no links to other GitHub repositories' {
        $skip = '\\(node_modules|\.git|dist|temp|\.repowise)\\|\\package-lock\.json$|\.(zip|png|jpe?g|gif|ico|woff2?|ttf)$'
        $other = '(?i)https?://(www\.)?(github\.com|raw\.githubusercontent\.com|gist\.github\.com)/(?!jgt87/CCBridge\b)[\w.\-/]+'
        $hits = foreach ($f in Get-ChildItem $root -Recurse -File -Force | Where-Object { $_.FullName -notmatch $skip -and $_.Length -lt 5MB }) {
            $t = [IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($t, $other)) { "$($f.FullName.Substring($root.Length + 1)): $($m.Value)" }
        }
        @($hits) -join "`n" | Should BeNullOrEmpty
    }
}

# The app works for any person on any machine: no file may hold a real user folder, the account or
# computer name of whoever runs these tests, or a path into someone's profile (outside tests/, where
# invented names show what a check catches). Paths come from $env:, $PSScriptRoot or the settings.
Describe 'User and machine independence' {
    $skip = '\\(node_modules|\.git|dist|temp|\.repowise|\.streamhub)\\|\\package-lock\.json$|\.(zip|png|jpe?g|gif|ico|woff2?|ttf|wasm)$'
    # What the repository holds or would take in (tracked and new, not ignored): local reports and
    # settings of this machine are ignored and never published.
    $listed = @(Push-Location $root; try { git ls-files -co --exclude-standard 2>$null } finally { Pop-Location })
    $all = if ($listed.Count) { @($listed | ForEach-Object { Get-Item -LiteralPath (Join-Path $root $_) -Force -ErrorAction SilentlyContinue }) } else { @(Get-ChildItem $root -Recurse -File -Force) }
    $files = @($all | Where-Object { $_ -and $_.FullName -notmatch $skip -and $_.Length -lt 5MB })
    It 'holds no name or folder of the person running the tests' {
        $own = @(@($env:USERPROFILE, $env:OneDrive, $env:OneDriveCommercial) | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }) +
            @(@($env:USERNAME, $env:COMPUTERNAME) | Where-Object { $_ -and $_.Length -ge 4 } | ForEach-Object { '\b' + [regex]::Escape($_) + '\b' })
        $pattern = '(?i)' + ($own -join '|')
        $hits = foreach ($f in $files) {
            $t = [IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($t, $pattern)) { "$($f.FullName.Substring($root.Length + 1)): $($m.Value)" }
        }
        @($hits) -join "`n" | Should BeNullOrEmpty
    }
    It 'refers to no profile folder outside the tests' {
        $profilePath = '(?i)\b[a-z]:[\\/]{1,2}users[\\/]{1,2}(?!(public|default|name|user|username|you|me)\b)[a-z][\w.-]*'
        $hits = foreach ($f in $files | Where-Object { $_.FullName -notmatch '\\tests\\' }) {
            $t = [IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($t, $profilePath)) { "$($f.FullName.Substring($root.Length + 1)): $($m.Value)" }
        }
        @($hits) -join "`n" | Should BeNullOrEmpty
    }
}
