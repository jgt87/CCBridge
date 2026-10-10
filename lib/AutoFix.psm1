# Mechanical fixes for problems that only have one right answer and cannot change what the code
# does: typographic quotes used as code quotes, non-breaking and zero-width spaces in code, HTML
# entities in code, mixed line endings, // comments in CSS, a single % in a batch for loop; and,
# anywhere in a file, text broken by a wrong encoding, and a page without its charset line. The code
# fixes only in code (strings and comments are left as they are, via Lint's Get-CodeMask). Whether they are
# applied follows the enforcement setting (CheckPolicy Get-Enforcement): light fixes silently,
# standard fixes and tells Copilot, strict leaves them to Copilot. Non-ASCII written as [char].

$ErrorActionPreference = 'Stop'
foreach ($m in 'Lint') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

function Set-At([string]$Text, [int[]]$Indexes, [string]$With) {
    # Replaces the single characters at these positions (from the end, so positions stay right).
    $sb = New-Object Text.StringBuilder $Text
    foreach ($i in @($Indexes | Sort-Object -Descending)) { [void]$sb.Remove($i, 1); if ($With) { [void]$sb.Insert($i, $With) } }
    $sb.ToString()
}

function Repair-MechanicalIssues {
    <# The text with the mechanical problems fixed, and what was fixed: @{ text; fixes }. #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    $fixes = New-Object System.Collections.Generic.List[string]
    $t = $Text
    # A whole tag written escaped inside JavaScript (.js, or a page's <script>): the tag itself.
    $esc = @(Find-EscapedScriptTags $Path $t)
    if ($esc.Count) {
        $sb = New-Object Text.StringBuilder $t
        foreach ($e in @($esc | Sort-Object { $_.index } -Descending)) {
            $tag = $e.text -replace '^&lt;', '<' -replace '&gt;$', '>' -replace '&quot;', '"' -replace '&#39;', "'" -replace '&amp;', '&'
            [void]$sb.Remove($e.index, $e.length); [void]$sb.Insert($e.index, $tag)
        }
        $t = $sb.ToString()
        $fixes.Add("$($esc.Count) HTML tag(s) that were written escaped in a script written as tags")
    }
    $mask = Get-CodeMask $Path $t
    if ($null -ne $mask -and $mask.Length -eq $t.Length) {
        # Typographic quotes in code (not in strings or comments): straight quotes.
        $dq = @(); $sq = @()
        for ($i = 0; $i -lt $mask.Length; $i++) {
            $c = [int]$mask[$i]
            if ($c -eq 0x201C -or $c -eq 0x201D) { $dq += $i } elseif ($c -eq 0x2018 -or $c -eq 0x2019) { $sq += $i }
        }
        # Not in files that mix markup with code (JSX, Vue, Svelte): the mask does not know their text,
        # and a typographic quote or a non-breaking space in the text is content, not a mistake.
        $mixed = $Path -match '(?i)\.(jsx|tsx|vue|svelte)$'
        if (($dq.Count -or $sq.Count) -and -not $mixed) {
            $t = Set-At $t $dq '"'; $t = Set-At $t $sq "'"
            $fixes.Add("$($dq.Count + $sq.Count) typographic quote(s) in code made straight")
            $mask = Get-CodeMask $Path $t
        }
        # Non-breaking spaces become spaces; zero-width characters go (not a BOM at the very start).
        $nb = @(); $zw = @()
        for ($i = 0; $i -lt $mask.Length; $i++) {
            $c = [int]$mask[$i]
            if ($c -eq 0x00A0) { $nb += $i } elseif ($c -in 0x200B, 0x200C, 0x200D, 0x2060 -or ($c -eq 0xFEFF -and $i -gt 0)) { $zw += $i }
        }
        if ($mixed) { $nb = @() }
        if ($nb.Count) { $t = Set-At $t $nb ' '; $fixes.Add("$($nb.Count) non-breaking space(s) in code made normal spaces") }
        if ($zw.Count) { $t = Set-At $t $zw ''; $fixes.Add("$($zw.Count) zero-width character(s) in code removed") }
        if ($nb.Count -or $zw.Count) { $mask = Get-CodeMask $Path $t }
        # HTML entities in code (not in JSX/markup text, where they are allowed).
        if ($Path -notmatch '(?i)\.(jsx|tsx|vue|svelte)$') {
            $ents = [regex]::Matches($mask, '&amp;&amp;|&quot;|&#39;|&lt;|&gt;|&amp;')
            if ($ents.Count) {
                $map = @{ '&amp;&amp;' = '&&'; '&quot;' = '"'; '&#39;' = "'"; '&lt;' = '<'; '&gt;' = '>'; '&amp;' = '&' }
                $sb = New-Object Text.StringBuilder $t
                foreach ($e in @($ents | Sort-Object Index -Descending)) { [void]$sb.Remove($e.Index, $e.Length); [void]$sb.Insert($e.Index, $map[$e.Value]) }
                $t = $sb.ToString()
                $fixes.Add("$($ents.Count) HTML entit$(if ($ents.Count -eq 1) { 'y' } else { 'ies' }) in code written as the character")
                $mask = Get-CodeMask $Path $t
            }
        }
        # CSS: a // line comment becomes /* ... */.
        if ($Path -match '(?i)\.css$') {
            # Not after ( : url(//host/x) is an address without a scheme, not a comment.
            $cm = @([regex]::Matches($mask, '(?m)(?<![:\w/(])//([^\n\r]*)'))
            if ($cm.Count) {
                $sb = New-Object Text.StringBuilder $t
                foreach ($m in @($cm | Sort-Object Index -Descending)) {
                    $body = $t.Substring($m.Index + 2, $m.Length - 2).Trim()
                    [void]$sb.Remove($m.Index, $m.Length); [void]$sb.Insert($m.Index, "/* $body */")
                }
                $t = $sb.ToString()
                $fixes.Add("$($cm.Count) // comment(s) in CSS made /* */")
            }
        }
    }
    # Batch: a for loop variable needs %% in a file.
    if ($Path -match '(?i)\.(cmd|bat)$') {
        $n = 0
        $t = [regex]::Replace($t, '(?im)^(?!\s*(rem\b|::))([^\r\n]*\bfor\b[^\r\n]*?\s)%([a-z])(\s+in\b[^\r\n]*)(?=\r?$)', [Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $script:n++
            $v = $m.Groups[3].Value
            $m.Groups[2].Value + '%%' + $v + ([regex]::Replace($m.Groups[4].Value, "(?<!%)%$v\b", "%%$v"))
        })
        if ($script:n) { $fixes.Add("$script:n batch for loop(s) given %%"); $script:n = 0 }
    }
    # Text broken by a wrong encoding (UTF-8 read as Windows-1252): the real characters, also in
    # strings and markup, where it shows. Not in the blocks the helper program fills in a page.
    $filled = @(if ($Path -match '(?i)\.html?$') { [regex]::Matches($t, '(?is)<(script|style)\b[^>]*\bdata-streamhub\s*=[^>]*>.*?</\1\s*>') })
    $bad = @(Find-BrokenEncoding $t | Where-Object { $b = $_; -not @($filled | Where-Object { $b.index -ge $_.Index -and $b.index -lt $_.Index + $_.Length }).Count })
    if ($bad.Count) {
        $sb = New-Object Text.StringBuilder $t
        foreach ($b in @($bad | Sort-Object index -Descending)) { [void]$sb.Remove($b.index, $b.length); [void]$sb.Insert($b.index, $b.fixed) }
        $t = $sb.ToString()
        $fixes.Add("$($bad.Count) broken character sequence(s) (UTF-8 read as Windows-1252, such as '$($bad[0].text)') written as the real characters")
    }
    # Tags written with stand-ins ([[LT]] for <, [[GT]] for >) or a page escaped as a whole: the tags.
    if ($Path -match '(?i)\.(html?|xhtml|svg)$') {
        $n = ([regex]::Matches($t, '(\[\[|\{\{|__)(LT|GT)(\]\]|\}\}|__)')).Count
        if ($n) {
            $t = [regex]::Replace($t, '(\[\[|\{\{|__)LT(\]\]|\}\}|__)', '<')
            $t = [regex]::Replace($t, '(\[\[|\{\{|__)GT(\]\]|\}\}|__)', '>')
            $fixes.Add("$n stand-in(s) for < and > (such as [[LT]]) written as the characters")
        } elseif ($t -match '(?im)^\s*&lt;(!doctype|html|head|body|main|div|section|header|script|style|table)\b' -and $t -notmatch '<(!doctype|[a-zA-Z][\w-]*)[\s>/]') {
            $t = $t.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&#39;', "'").Replace('&amp;', '&')
            $fixes.Add('the escaped page (&lt;html&gt;...) written as tags')
        }
    }
    # Markup shown as text: a tag written with &lt; and &gt; in a page's (SVG's, XAML's, Vue's,
    # Svelte's) own text becomes the tag, as does code written with entities in JSX/TSX; a tag that
    # lost its < gets it back, one that lost its > is closed; a </script> with no <script> before it
    # gets one before the code lines above it.
    if ($Path -match '(?i)\.(html?|xhtml|svg|xaml|vue|svelte|jsx|tsx)$') {
        $leaks = @(Find-LeakedMarkup $Path $t)
        $ents = @($leaks | Where-Object { $_.kind -in 'entity', 'entity-code' })
        if ($ents.Count) {
            $sb = New-Object Text.StringBuilder $t
            foreach ($e in @($ents | Sort-Object { $_.index } -Descending)) {
                $tag = if ($e.kind -eq 'entity-code') { $e.text.Replace('&lt;', '<').Replace('&gt;', '>') } else { $e.text -replace '^&lt;', '<' -replace '&gt;$', '>' -replace '&quot;', '"' -replace '&#39;', "'" -replace '&amp;', '&' }
                [void]$sb.Remove($e.index, $e.length); [void]$sb.Insert($e.index, $tag)
            }
            $t = $sb.ToString()
            $fixes.Add($(if ($Path -match '(?i)\.(jsx|tsx)$') { "$($ents.Count) piece(s) of code written with &lt; and &gt; written with < and >" } else { "$($ents.Count) tag(s) written with &lt; and &gt; in the page's text (shown as text) written as tags" }))
        }
        # A tag that lost its <: the < back, from the end of the file so earlier indexes hold.
        $broken = @($leaks | Where-Object { $_.kind -eq 'broken-tag' } | Sort-Object { $_.index } -Descending)
        if ($broken.Count) {
            foreach ($b in $broken) { $t = $t.Insert($b.index, '<') }
            $fixes.Add("$($broken.Count) tag(s) that had lost their < (such as $($broken[-1].text.Substring(0, [Math]::Min(20, $broken[-1].text.Length)))) written whole")
            $leaks = @(Find-LeakedMarkup $Path $t)
        }
        # A tag that lost its > (the browser read the next text or tag as its attributes): closed where
        # its attributes end, from the end of the file so earlier indexes hold.
        $lost = @($leaks | Where-Object { $_.kind -eq 'lost-end' } | Sort-Object { $_.index } -Descending)
        if ($lost.Count) {
            foreach ($l in $lost) { $t = $t.Insert($l.index, '>') }
            $fixes.Add("$($lost.Count) tag(s) that had lost their > (such as $($lost[-1].text.Substring(0, [Math]::Min(30, $lost[-1].text.Length)))) closed")
            $leaks = @(Find-LeakedMarkup $Path $t)
        }
        $strays = @($leaks | Where-Object { $_.kind -eq 'stray-close' } | Sort-Object { $_.index } -Descending)
        $put = 0
        foreach ($s in $strays) {
            # The code above the stray </script>: lines up to the previous tag line, when at least one of
            # them is code (a ; { } = or call), get <script> in front.
            $before = $t.Substring(0, $s.index)
            $lines = $before.Replace("`r`n", "`n").Split("`n")
            $start = $lines.Length - 1; $code = $false
            for ($i = $lines.Length - 2; $i -ge 0; $i--) {
                if ($lines[$i] -match '<[a-zA-Z/!]') { break }
                if ($lines[$i] -match '[;{}=]|\w\(') { $code = $true }
                $start = $i
            }
            if (-not $code -or $start -ge $lines.Length - 1) { continue }
            $nl = if ($t.Contains("`r`n")) { "`r`n" } else { "`n" }
            $indent = [regex]::Match($lines[$lines.Length - 1], '^[ \t]*').Value
            $at = 0
            for ($i = 0; $i -lt $start; $i++) { $at += $lines[$i].Length + $nl.Length }
            $t = $t.Insert($at, "$indent<script>$nl")
            $put++
        }
        if ($put) { $fixes.Add("$put <script> tag(s) put before code that stood on the page as text (its </script> had no opening tag)") }
    }
    # A web page without a charset: <meta charset="utf-8"> first in <head>, so Edge reads the page
    # and its scripts as UTF-8 when it is opened from disk.
    if ($Path -match '(?i)\.html?$') {
        $top = if ($t.Length -gt 1024) { $t.Substring(0, 1024) } else { $t }
        $head = [regex]::Match($t, '(?i)<head(\s[^>]*)?>')
        if ($head.Success -and $top -notmatch '(?i)<meta\b[^>]*\bcharset\s*=') {
            $nl = if ($t.Contains("`r`n")) { "`r`n" } else { "`n" }
            $indent = [regex]::Match($t.Substring($head.Index + $head.Length), '\A\r?\n([ \t]*)').Groups[1].Value
            $t = $t.Insert($head.Index + $head.Length, $nl + $indent + '<meta charset="utf-8">')
            $fixes.Add('<meta charset="utf-8"> added at the top of <head>')
        }
    }
    # Mixed line endings: the kind most lines have.
    $crlf = ([regex]::Matches($t, "`r`n")).Count; $lf = ([regex]::Matches($t, '(?<!\r)\n')).Count
    if ($crlf -and $lf) {
        $t = $t.Replace("`r`n", "`n")
        if ($crlf -ge $lf) { $t = $t.Replace("`n", "`r`n") }
        $fixes.Add("line endings made all $(if ($crlf -ge $lf) { 'CRLF' } else { 'LF' })")
    }
    [pscustomobject]@{ text = $t; fixes = $fixes.ToArray() }
}

Export-ModuleMember -Function Repair-MechanicalIssues
