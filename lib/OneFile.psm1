<#
  One-file pages (project setup "one file", ProjectSetup.psm1): an HTML page that holds everything it
  needs. The helper program writes two kinds of blocks in it and keeps them up to date:
    <style data-streamhub="kit"></style> and <script data-streamhub="kit"></script>  - the UI kit's
      styles for the classes the page uses, and the kit scripts it uses;
    <script data-streamhub="data" data-source="SOURCE PATH"></script>  - the rows of a data file.
  Copilot writes them empty and never sees or edits their contents: reads, searches, file checks and
  reviews get the text with each block's lines blanked (Hide-GeneratedBlocks: same line numbers), and
  an edit that would change a block is refused (Find-BlockEdit). Text helpers only, no imports.
#>

$script:BlockPattern = '(?is)<(style|script)\b([^>]*?\bdata-streamhub\s*=\s*["''](kit|data)["''][^>]*)>(.*?)</\1\s*>'

function Test-OneFileText([AllowEmptyString()][string]$Text) {
    # Whether a page has a block the helper program writes.
    "$Text" -match '(?i)\bdata-streamhub\s*=\s*["''](kit|data)["'']'
}

function Get-GeneratedBlocks([AllowEmptyString()][string]$Text) {
    <# The blocks in a page, in order: @{ tag; kind (kit, data); source (data-source); global
       (data-global); start, length (the content); first, last (its lines, 1-based); content }. #>
    $t = "$Text"
    foreach ($m in [regex]::Matches($t, $script:BlockPattern)) {
        $attrs = $m.Groups[2].Value
        $c = $m.Groups[4]
        $first = ([regex]::Matches($t.Substring(0, $c.Index), "`n")).Count + 1
        [pscustomobject]@{
            tag = $m.Groups[1].Value.ToLowerInvariant(); kind = $m.Groups[3].Value.ToLowerInvariant()
            source = [regex]::Match($attrs, '(?i)\bdata-source\s*=\s*["'']([^"'']*)["'']').Groups[1].Value
            global = [regex]::Match($attrs, '(?i)\bdata-global\s*=\s*["'']([A-Za-z_$][\w$]*)["'']').Groups[1].Value
            start = $c.Index; length = $c.Length; first = $first; last = $first + ([regex]::Matches($c.Value, "`n")).Count
            content = $c.Value
        }
    }
}

function Get-BlockNote($Block) {
    # What Copilot sees instead of a block's contents.
    $what = if ($Block.kind -eq 'data') { "the rows of $($Block.source)$(if ($Block.global) { " as window.$($Block.global)" })" } else { "the UI kit's $(if ($Block.tag -eq 'style') { 'styles' } else { 'scripts' }) this page uses" }
    "/* ${what}: written by the helper program and kept up to date; not shown here, never edit these lines */"
}

function Hide-GeneratedBlocks([AllowEmptyString()][string]$Text) {
    <# The page with each generated block's contents replaced by a one-line note, keeping the number
       of lines (so line numbers in reads and edits stay right). Unchanged text without blocks. #>
    $t = "$Text"
    if (-not (Test-OneFileText $t)) { return $t }
    $blocks = @(Get-GeneratedBlocks $t)
    $sb = New-Object Text.StringBuilder
    $at = 0
    foreach ($b in $blocks) {
        [void]$sb.Append($t.Substring($at, $b.start - $at))
        if ($b.content.Trim()) {
            $breaks = ([regex]::Matches($b.content, "`n")).Count
            $lead = if ($b.content.StartsWith("`n")) { "`n"; $breaks-- } else { '' }
            [void]$sb.Append($lead + (Get-BlockNote $b) + ("`n" * [Math]::Max(0, $breaks)))
        } else { [void]$sb.Append($b.content) }
        $at = $b.start + $b.length
    }
    [void]$sb.Append($t.Substring($at))
    $sb.ToString()
}

function Find-BlockEdit([AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New) {
    <# Why an edit may not be applied: it changes, removes or adds to the contents of a block the
       helper program writes. '' when the blocks are as they were. #>
    if (-not (Test-OneFileText $Old)) { return '' }
    $o = @(Get-GeneratedBlocks $Old); $n = @(Get-GeneratedBlocks $New)
    foreach ($b in $o) {
        if (-not $b.content.Trim()) { continue }
        $same = @($n | Where-Object { $_.kind -eq $b.kind -and $_.tag -eq $b.tag -and $_.source -eq $b.source -and $_.content -ceq $b.content })
        if (-not $same.Count) {
            return "lines $($b.first)-$($b.last) are the helper program's $(if ($b.kind -eq 'data') { "data block for $($b.source)" } else { "UI kit $($b.tag) block" }) (data-streamhub=`"$($b.kind)`"): it writes them and keeps them up to date. Leave those lines and the block's tags out of your SEARCH and REPLACE; change the rest of the page"
        }
    }
    ''
}

function Find-OneFileLoads([AllowEmptyString()][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New) {
    <# A one-file page (it has a generated block) that a change makes load a project file: a link or
       script src, a fetch or an import of a local path. The page has to work as one file. #>
    if ($Rel -notmatch '(?i)\.html?$' -or -not (Test-OneFileText $New)) { return }
    $had = @{}
    foreach ($l in (Hide-GeneratedBlocks $Old).Split("`n")) { $had[$l.Trim()] = $true }
    $lines = (Hide-GeneratedBlocks $New).Split("`n")
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $t = $lines[$i].Trim()
        if (-not $t -or $had.ContainsKey($t)) { continue }
        $m = [regex]::Match($t, '(?i)(?:<(?:link|script)\b[^>]*\b(?:href|src)\s*=\s*["'']|\bfetch\(\s*["''`]|\bimport\s[^;]*?from\s*["''])(?!(?:https?:|data:|blob:|#|//))([^"''`]+)')
        if ($m.Success) { return "line $($i + 1): this page is one file (the project's build form), but it loads $($m.Groups[1].Value). Put what it needs in the page itself: your own styles and scripts in <style> and <script>, the UI kit in the data-streamhub=`"kit`" blocks, data in a data-streamhub=`"data`" block" }
    }
}

Export-ModuleMember -Function Test-OneFileText, Get-GeneratedBlocks, Get-BlockNote, Hide-GeneratedBlocks, Find-BlockEdit, Find-OneFileLoads
