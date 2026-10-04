# After the project layout moved or renamed folders and files (Move-ProjectLayout), the project's
# own code and documents still point at the old places: <script src="scripts/app.js">,
# fetch('exports/meetings.json'), Import-Csv source\data.csv, [link](reviews/x.md). On Windows a
# wrong case still works, but a web server, Git or another system does not forgive it, and a moved
# file is gone everywhere. Update-MovedReferences finds every path in the project's text files,
# resolves it the way the code would (from the file's folder, or from the project root), and when it
# points into something that moved, rewrites it to the new place in the same style (./, ../, a
# leading /, backslashes). URLs, Source/ (read-only data) and StreamHub's own records are left
# alone. The rewrites are not an Undo step (undoing them alone would break the links again, as the
# move itself stays); the files' earlier versions are kept in StreamHub's local data folder.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Workspace', 'Executor') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:TextExt = '(?i)\.(html?|xhtml|js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte|css|scss|sass|less|json|jsonc|md|markdown|txt|py|ps1|psm1|psd1|cmd|bat|sh|ya?ml|toml|ini|cfg|conf|xml|svg|csv|sql|php|rb|cs|java|go|rs)$'
$script:SkipDir = '(?i)^(\.streamhub|\.git|node_modules|dist|build|out|coverage|vendor|\.venv|venv|__pycache__|source|Runbooks/Exports)(/|$)'
# A path with at least one folder separator, not preceded by a character that would make it part of
# a URL, a longer name or a property (://host/scripts/x, my-scripts/x, obj.scripts/x).
$script:PathToken = '(?<![\w.:@%$/\\-])((?:\.{1,2}[/\\])*[/\\]?(?:[\w.@-]*[\w@-][/\\])+[\w.@-]*)'

function ConvertTo-NormalPath([string]$Rel) {
    # 'a/./b/../c' -> 'a/c'; $null when it climbs out of the project.
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($seg in $Rel.Replace('\', '/').Split('/')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') { if (-not $out.Count) { return $null }; $out.RemoveAt($out.Count - 1); continue }
        $out.Add($seg)
    }
    $out -join '/'
}

function Get-RelativeRef([string]$FromDir, [string]$Target) {
    # The path from a folder (project-relative, '' = root) to a project-relative target.
    $a = @($FromDir.Split('/') | Where-Object { $_ }); $b = @($Target.Split('/') | Where-Object { $_ })
    $i = 0
    while ($i -lt $a.Count -and $i -lt ($b.Count - 1) -and $a[$i] -ieq $b[$i]) { $i++ }
    $up = @(for ($k = $i; $k -lt $a.Count; $k++) { '..' })
    (@($up) + @($b[$i..($b.Count - 1)])) -join '/'
}

function Get-MovedTarget([string]$Rel, $Moves) {
    # The new project-relative path of $Rel after the moves, or $null when it did not move. Folder
    # moves cover everything under the folder; a case-only rename counts only when the case differs.
    $cur = $Rel; $hit = $false
    foreach ($m in @($Moves)) {
        if ($m.folder) {
            if ($cur -ieq $m.from -or $cur.StartsWith("$($m.from)/", [StringComparison]::OrdinalIgnoreCase)) {
                $new = $m.to + $cur.Substring($m.from.Length)
                if ($new -cne $cur) { $cur = $new; $hit = $true }
            }
        } elseif ($cur -ieq $m.from) { $cur = $m.to; $hit = $true }
    }
    if ($hit) { $cur } else { $null }
}

function Update-TextReferences {
    <# The text with every path into a moved file or folder rewritten; @{ text; count }. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][AllowEmptyString()][string]$FileRel, $Moves, [string]$ProjectRoot)
    $dir = $(if ($FileRel.Contains('/')) { $FileRel.Substring(0, $FileRel.LastIndexOf('/')) } else { '' })
    $script:RelinkCount = 0
    $new = [regex]::Replace($Text, $script:PathToken, {
        param($m)
        $tok = $m.Groups[1].Value
        $back = $tok.Contains('\') -and -not $tok.Contains('/')
        $t = $tok.Replace('\', '/')
        $lead = ''
        if ($t.StartsWith('/')) { $lead = '/' }
        elseif ($t.StartsWith('./')) { $lead = './' }
        # How the code would resolve it: a leading / from the root; otherwise from the file's folder,
        # and when nothing moved there, from the project root (scripts run from the project folder).
        $bases = if ($lead -eq '/') { @('') } elseif ($t.StartsWith('../')) { @($dir) } else { @($dir, '') | Select-Object -Unique }
        foreach ($base in $bases) {
            $rel = ConvertTo-NormalPath $(if ($base) { "$base/$t" } else { $t })
            if (-not $rel) { continue }
            $trail = $(if ($t.EndsWith('/')) { '/' } else { '' })
            $target = Get-MovedTarget $rel.TrimEnd('/') $Moves
            if (-not $target) { continue }
            if ($ProjectRoot -and -not (Test-Path -LiteralPath (Join-Path $ProjectRoot $target.Replace('/', '\')))) { continue }   # only to places that exist now
            $out = if ($lead -eq '/') { "/$target" }
                elseif ($base -eq $dir -and $dir) { Get-RelativeRef $dir $target }
                else { $target }
            if ($lead -eq './' -and -not $out.StartsWith('.')) { $out = "./$out" }
            $out += $trail
            if ($back) { $out = $out.Replace('/', '\') }
            if ($out -cne $tok) { $script:RelinkCount++; return $out }
            return $tok
        }
        $tok
    })
    [pscustomobject]@{ text = $new; count = $script:RelinkCount }
}

function Update-MovedReferences {
    <# Rewrites references to moved files and folders in the project's text files (code, pages,
       styles, scripts, docs). Each file's earlier version is copied to relink-<time>\ in the
       project's local state folder first. Returns @{ files = @(@{ path; count }); backup }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, $Moves)
    $result = [pscustomobject]@{ files = @(); backup = $null }
    if (-not @($Moves).Count) { return $result }
    $root = $ProjectRoot.TrimEnd('\')
    $changed = New-Object System.Collections.Generic.List[object]
    $backup = Join-Path (Get-ProjectStateDir $root) ('relink-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
        if ($rel -match $script:SkipDir -or $rel -notmatch $script:TextExt -or $f.Length -gt 1MB) { continue }
        try {
            $info = Read-TextFile $f.FullName
            $r = Update-TextReferences $info.Text $rel $Moves $root
            if (-not $r.count -or $r.text -ceq $info.Text) { continue }
            $copy = Join-Path $backup $rel.Replace('/', '\')
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $copy)
            [IO.File]::Copy($f.FullName, $copy, $true)
            Write-TextFile $f.FullName $r.text $info.Bom $info.Crlf $info.Encoding
            $changed.Add([pscustomobject]@{ path = $rel; count = $r.count })
        } catch { Write-CCBLogError relink "Could not update references in $rel" $_ }
    }
    if ($changed.Count) { Write-CCBLog info relink 'References to moved folders updated' @{ files = $changed.Count; refs = ($changed | Measure-Object count -Sum).Sum } }
    $result.files = $changed.ToArray(); $result.backup = $(if ($changed.Count) { $backup } else { $null })
    $result
}

Export-ModuleMember -Function ConvertTo-NormalPath, Get-RelativeRef, Get-MovedTarget, Update-TextReferences, Update-MovedReferences
