# When a new Copilot chat should start because the work moves to another part of the project.
# A long chat about one module carries its context into the next request; when the next request is
# about a different module, that context only costs room and can mislead Copilot. Fixed rules on
# file names, no language model: a chat is "about" the areas of the files it read or changed (and
# the files its messages named), widened with the files those import or are used by. A new message
# that names files only in other areas, and does not continue the earlier work, starts a new chat.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace', 'Imports') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

# Words that continue the earlier work ("also add...", "fix it", "again"): never a switch.
$script:Continue = '(?i)^\s*(also|and|now|then|next|again|still|same|that|this|it|those|these|plus|ok|okay|yes|no|but)\b|\b(as well|as before|same (file|page|module|component)|previous|above|you just|just now|again|still|undo|revert|fix it|that change|this change|the change)\b'
# Folders whose sub folders are separate parts of an app (src/calendar, packages/api, ...).
$script:Container = '^(?i)(src|app|apps|lib|libs|packages|modules|components|pages|features|services|server|client|api)$'

function Get-FileArea([string]$Path) {
    <# The part of the project a file belongs to: its folder, two levels deep under folders that
       hold an app's parts (src/calendar), one level otherwise (Scripts, docs); '(root)' for files
       in the project folder itself. #>
    $parts = @("$Path".Replace('\', '/').Trim('/').Split('/') | Where-Object { $_ })
    if ($parts.Count -le 1) { return '(root)' }
    $dirs = @($parts[0..($parts.Count - 2)])
    if ($dirs[0] -match $script:Container -and $dirs.Count -ge 2) { return "$($dirs[0])/$($dirs[1])" }
    $dirs[0]
}

function Get-NamedFiles {
    <# Project files a message names: @path, a path, a file name (name.ext), or a file's name without
       its extension (4+ characters, not a generic one like index or utils), or a folder with its
       slash (src/calendar/). #>
    param([string]$Text, [string[]]$Paths)
    if (-not $Text -or -not $Paths) { return @() }
    $t = $Text.Replace('\', '/')
    $words = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches($t, '[\w./-]{3,}')) { [void]$words.Add($m.Value.Trim('.', '-', '/', '@')) }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Paths) {
        $name = ($p -split '/')[-1]
        $stem = [IO.Path]::GetFileNameWithoutExtension($name)
        $dir = $(if ($p.Contains('/')) { $p.Substring(0, $p.LastIndexOf('/')) } else { '' })
        $hit = $words.Contains($p) -or $words.Contains($name) -or
            ($stem.Length -ge 4 -and $stem -notmatch '^(?i)(index|main|readme|agents|package|config|style|styles|utils?|helpers?|app|test|tests|types|data)$' -and $words.Contains($stem)) -or
            ($dir -and $t -match "(?i)(^|[\s@(])$([regex]::Escape($dir))/(\s|$|[.,;:)])")
        if ($hit) { $out.Add($p) }
    }
    @($out | Select-Object -Unique)
}

function Get-RelatedFiles {
    <# The files connected to these through the import index: what they import, and who imports
       them or uses their ids, functions or hooks (one step). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths, $Index)
    $ix = if ($Index) { $Index } else { Read-ImportIndex $ProjectRoot }
    $out = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($Paths)) {
        [void]$out.Add($p)
        $e = $ix.files[$p]
        if ($e) { foreach ($r in @($e.refs)) { if ($r.target) { [void]$out.Add("$($r.target)") } } }
        foreach ($u in @(Get-ImportUsers $ProjectRoot $p -Index $ix -Max 50)) { [void]$out.Add("$($u.path)") }
    }
    @($out)
}

function Test-ChatSwitch {
    <# Whether the next message should start a new Copilot chat because it is about another part of
       the project. $ChatFiles: what this chat read, changed or named. Returns @{ switch; reason;
       from (areas of the chat); to (areas of the message); named (files) }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Text, [string[]]$ChatFiles, [string[]]$ProjectFiles, $Index)
    $no = { param($why) [pscustomobject]@{ switch = $false; reason = $why; from = @(); to = @(); named = @() } }
    if (-not @($ChatFiles).Count) { return & $no 'the chat has not worked on files yet' }
    if ("$Text" -match $script:Continue) { return & $no 'the message continues the earlier work' }
    $files = if ($ProjectFiles) { @($ProjectFiles) } else { @(Get-ProjectFiles $ProjectRoot | ForEach-Object { $_.path }) }
    $named = @(Get-NamedFiles $Text $files)
    if (-not $named.Count) { return & $no 'the message names no project file or folder' }
    $related = @(Get-RelatedFiles $ProjectRoot @($ChatFiles) $Index)
    $chatAreas = @($related | ForEach-Object { Get-FileArea $_ } | Select-Object -Unique)
    $newAreas = @($named | ForEach-Object { Get-FileArea $_ } | Select-Object -Unique)
    $relSet = @{}; foreach ($r in $related) { $relSet[$r.ToLowerInvariant()] = $true }
    foreach ($n in $named) {
        if ($relSet.ContainsKey($n.ToLowerInvariant())) { return & $no "the message is about $n, which this chat already works with" }
        if ($chatAreas -contains (Get-FileArea $n)) { return & $no "the message is about $(Get-FileArea $n), which this chat already works in" }
    }
    [pscustomobject]@{ switch = $true; reason = 'the message is about another part of the project'; from = @($chatAreas | Select-Object -First 4); to = $newAreas; named = $named }
}

Export-ModuleMember -Function Get-FileArea, Get-NamedFiles, Get-RelatedFiles, Test-ChatSwitch
