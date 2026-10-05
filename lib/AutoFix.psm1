# Mechanical fixes for problems that only have one right answer and cannot change what the code
# does: typographic quotes used as code quotes, non-breaking and zero-width spaces in code, HTML
# entities in code, mixed line endings, // comments in CSS, a single % in a batch for loop. Only in
# code (strings and comments are left as they are, via Lint's Get-CodeMask). Whether they are
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
    $mask = Get-CodeMask $Path $t
    if ($null -ne $mask -and $mask.Length -eq $t.Length) {
        # Typographic quotes in code (not in strings or comments): straight quotes.
        $dq = @(); $sq = @()
        for ($i = 0; $i -lt $mask.Length; $i++) {
            $c = [int]$mask[$i]
            if ($c -eq 0x201C -or $c -eq 0x201D) { $dq += $i } elseif ($c -eq 0x2018 -or $c -eq 0x2019) { $sq += $i }
        }
        if ($dq.Count -or $sq.Count) {
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
            $cm = @([regex]::Matches($mask, '(?m)(?<![:\w/])//([^\n\r]*)'))
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
