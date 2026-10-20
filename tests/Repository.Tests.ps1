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
    It 'keeps PowerShell files ASCII-only and holds no backspace byte (a lost \b in a pattern)' {
        # 5.1 reads a BOM-less .ps1 as ANSI, so other characters change on the way; a 0x08 byte is a
        # regex \b that a shell or Python turned into a backspace (AGENTS.md). tools/scan-repo.ps1
        # reports the first; this test covers both for everything the repository tracks.
        $hits = foreach ($f in $files | Where-Object { $_.FullName -notmatch '\\(fixtures|vendor)\\' }) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            $i = [Array]::IndexOf($b, [byte]8)
            if ($i -ge 0) { "$($f.FullName.Substring($root.Length + 1)): a 0x08 byte at offset $i" }
            if ($f.Extension -match '(?i)^\.ps[md]?1$') { $j = [Array]::FindIndex($b, [Predicate[byte]]{ param($x) $x -gt 127 }); if ($j -ge 0) { "$($f.FullName.Substring($root.Length + 1)): a non-ASCII byte at offset $j" } }
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

Describe 'Commands Windows PowerShell 5.1 may not have' {
    It 'uses no command of the 5.1 Utility script module in the app, tools and launchers' {
        # Windows PowerShell 5.1 started from PowerShell 7 loads 7's modules, which lack these (the
        # release build and the install check at every start stopped on Get-FileHash). Use .NET:
        # Update Get-FileHashShared, or the parser for a .psd1 (Executor Test-ProjectConsistency).
        $names = 'Get-FileHash', 'Import-PowerShellDataFile', 'New-TemporaryFile', 'Format-Hex', 'ConvertFrom-SddlString'
        $files = @(Get-ChildItem (Join-Path $root 'lib'), (Join-Path $root 'tools'), (Join-Path $root 'mcp') -Recurse -File -Include *.ps1, *.psm1) + @(Get-ChildItem $root -File -Filter *.ps1)
        $hits = foreach ($f in $files) {
            $n = 0
            foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
                $n++
                $code = ($line -split '#', 2)[0]
                foreach ($c in $names) { if ($code -match "(?i)(^|[\s(;|])$c\b") { "$($f.FullName.Substring($root.Length + 1)):${n}: $c" } }
            }
        }
        @($hits) -join "`n" | Should BeNullOrEmpty
    }
}
