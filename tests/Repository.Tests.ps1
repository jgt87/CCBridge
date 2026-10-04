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
