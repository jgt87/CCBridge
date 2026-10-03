# File checks per type: the mistakes that commonly break each kind of file (missing characters,
# unclosed tags, brackets and strings, open code blocks, wrong line endings, duplicate keys).
# Fixed rules only, no tools to install. Test-FileContent returns "line N: problem" texts; the
# agent reports only problems a change added (Get-NewFileIssues compares with the file before).

$ErrorActionPreference = 'Stop'

function Hide([string]$Text, [string]$Pattern) {
    # Each match becomes spaces, line breaks kept (so line numbers stay right).
    [regex]::Replace($Text, $Pattern, [Text.RegularExpressions.MatchEvaluator] { param($m) [regex]::Replace($m.Value, '[^\n]', ' ') })
}

function LineAt([string]$Text, [int]$Index) { ([regex]::Matches($Text.Substring(0, [Math]::Min([Math]::Max(0, $Index), $Text.Length)), "`n")).Count + 1 }

# What to blank before looking at brackets: strings and comments per language family.
$script:MaskCLike = '/\*[\s\S]*?\*/|`(?:[^`\\]|\\[\s\S])*`|"(?:[^"\\\n]|\\.)*"|''(?:[^''\\\n]|\\.)*''|(?<![:\\])//[^\n]*'
$script:MaskPython = '"""[\s\S]*?"""|''''''[\s\S]*?''''''|"(?:[^"\\\n]|\\.)*"|''(?:[^''\\\n]|\\.)*''|#[^\n]*'
$script:MaskCss = '/\*[\s\S]*?\*/|"(?:[^"\\\n]|\\.)*"|''(?:[^''\\\n]|\\.)*'''
$script:MaskSql = '/\*[\s\S]*?\*/|--[^\n]*|''(?:[^'']|'''')*''|"[^"\n]*"'
$script:MaskShell = '"(?:[^"\\]|\\[\s\S])*"|''[^'']*''|(?<![\w$#{])#[^\n]*'

function Test-Brackets([string]$Masked) {
    <# The first place where ( ) [ ] { } stop matching, or $null. #>
    $stack = New-Object System.Collections.Generic.Stack[object]
    $open = @{ ')' = '('; ']' = '['; '}' = '{' }
    $line = 1
    foreach ($ch in $Masked.ToCharArray()) {
        if ($ch -eq "`n") { $line++; continue }
        if ($ch -eq '(' -or $ch -eq '[' -or $ch -eq '{') { $stack.Push(@($ch, $line)); continue }
        if ($open.ContainsKey([string]$ch)) {
            if (-not $stack.Count) { return "line ${line}: '$ch' closes nothing" }
            $top = $stack.Pop()
            if ($top[0] -ne $open[[string]$ch]) { return "line ${line}: '$ch' does not match the '$($top[0])' opened at line $($top[1])" }
        }
    }
    if ($stack.Count) { $top = @($stack.ToArray())[0]; return "line $($top[1]): '$($top[0])' is never closed" }
    $null
}

function Find-Leftover([string]$Masked, [string]$Pattern, [string]$What) {
    # After strings and comments are blanked, a quote or comment start that is left was never closed.
    $m = [regex]::Match($Masked, $Pattern)
    if ($m.Success) { "line $(LineAt $Masked $m.Index): $What" }
}

function Get-JsMask([string]$Text) {
    <# Walks through JavaScript/TypeScript: blanks strings, template text and comments (keeping
       template ${...} expressions as code, also nested), skips regular-expression literals, and
       notes what is never closed. Returns @{ masked; issues }. #>
    $sb = New-Object Text.StringBuilder $Text.Length
    $issues = New-Object System.Collections.Generic.List[string]
    $state = 'code'; $start = 0; $line = 1; $stack = New-Object System.Collections.Generic.Stack[int]   # brace depth per open ${
    $depth = 0; $prev = [char]0
    $n = $Text.Length
    for ($i = 0; $i -lt $n; $i++) {
        $ch = $Text[$i]; $nx = if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 }
        if ($ch -eq "`n") { $line++ }
        switch ($state) {
            'code' {
                if ($ch -eq '/' -and $nx -eq '/') { $state = 'line'; [void]$sb.Append(' '); continue }
                if ($ch -eq '/' -and $nx -eq '*') { $state = 'block'; $start = $line; [void]$sb.Append(' '); continue }
                if ($ch -eq '/' -and "$prev" -match '^[\x00(,=:\[!&|?{;+\-*%~^]$') { $state = 'regex'; [void]$sb.Append(' '); continue }
                if ($ch -eq '"' -or $ch -eq "'") { $state = $ch; $start = $line; [void]$sb.Append(' '); continue }
                if ($ch -eq '`') { $state = 'tpl'; $start = $line; [void]$sb.Append(' '); continue }
                if ($stack.Count) {
                    if ($ch -eq '{') { $depth++ }
                    elseif ($ch -eq '}') { if ($depth -eq 0) { $depth = $stack.Pop(); $state = 'tpl'; [void]$sb.Append(' '); continue } else { $depth-- } }
                }
                [void]$sb.Append($ch); if (-not [char]::IsWhiteSpace($ch)) { $prev = $ch }
            }
            'line' { if ($ch -eq "`n") { $state = 'code'; [void]$sb.Append($ch) } else { [void]$sb.Append(' ') } }
            'block' { if ($ch -eq '*' -and $nx -eq '/') { $state = 'code'; [void]$sb.Append('  '); $i++ } else { [void]$sb.Append($(if ($ch -eq "`n") { $ch } else { ' ' })) } }
            'regex' {
                if ($ch -eq '\') { [void]$sb.Append('  '); $i++ }
                elseif ($ch -eq '[') { $state = 'regexclass'; [void]$sb.Append(' ') }
                elseif ($ch -eq '/' -or $ch -eq "`n") { $state = 'code'; $prev = 'a'; [void]$sb.Append($(if ($ch -eq "`n") { $ch } else { ' ' })) }
                else { [void]$sb.Append(' ') }
            }
            'regexclass' {
                if ($ch -eq '\') { [void]$sb.Append('  '); $i++ }
                elseif ($ch -eq ']') { $state = 'regex'; [void]$sb.Append(' ') }
                elseif ($ch -eq "`n") { $state = 'code'; [void]$sb.Append($ch) }
                else { [void]$sb.Append(' ') }
            }
            'tpl' {
                if ($ch -eq '\') { [void]$sb.Append($(if ($nx -eq "`n") { " `n" } else { '  ' })); if ($nx -eq "`n") { $line++ }; $i++ }
                elseif ($ch -eq '`') { $state = 'code'; $prev = 'a'; [void]$sb.Append(' ') }
                elseif ($ch -eq '$' -and $nx -eq '{') { $stack.Push($depth); $depth = 0; $state = 'code'; $prev = '('; [void]$sb.Append('  '); $i++ }
                else { [void]$sb.Append($(if ($ch -eq "`n") { $ch } else { ' ' })) }
            }
            default {   # inside '...' or "..."
                if ($ch -eq '\') { [void]$sb.Append('  '); $i++ }
                elseif ($ch -eq $state) { $state = 'code'; $prev = 'a'; [void]$sb.Append(' ') }
                elseif ($ch -eq "`n") { if (-not $issues.Count) { $issues.Add("line ${start}: a string is never closed (its quote has no partner on that line)") }; $state = 'code'; [void]$sb.Append($ch) }
                else { [void]$sb.Append(' ') }
            }
        }
    }
    if ($state -eq 'block') { $issues.Add("line ${start}: a /* comment is never closed") }
    if ($state -eq 'tpl') { $issues.Add("line ${start}: a `` template string is never closed") }
    if ($state -eq '"' -or $state -eq "'") { $issues.Add("line ${start}: a string is never closed (its quote has no partner on that line)") }
    @{ masked = $sb.ToString(); issues = $issues.ToArray() }
}

function Test-CLike([string]$Text, [string]$Path) {
    if ($Path -match '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte)$') {
        $s = Get-JsMask $Text
        # JSX text may hold apostrophes ("Don't"): there an unclosed quote is not reported.
        if ($Path -notmatch '(?i)\.(jsx|tsx|vue|svelte)$') { $s.issues } else { @($s.issues | Where-Object { $_ -notmatch 'string is never closed' }) }
        Test-Brackets $s.masked
        return
    }
    $m = Hide $Text $script:MaskCLike
    Find-Leftover $m '/\*' 'a /* comment is never closed'
    Find-Leftover $m '["'']' 'a string is never closed (its quote has no partner on that line)'
    Test-Brackets $m
}

function Test-Python([string]$Text) {
    # Closed triple-quoted strings and comments first: a """ or ''' left after that is never closed
    # (checked before single quotes, which would read two of its quotes as an empty string).
    $tq = Hide $Text '"""[\s\S]*?"""|''''''[\s\S]*?''''''|#[^\n]*'
    $open = [regex]::Match($tq, '"""|''''''')
    if ($open.Success) { "line $(LineAt $tq $open.Index): a triple-quoted string is never closed"; return }
    $m = Hide $Text $script:MaskPython
    Find-Leftover $m '["'']' 'a string is never closed (its quote has no partner on that line)'
    $b = Test-Brackets $m
    if ($b) { $b }
    # A block statement needs a colon at the end of its (logical) line.
    $lines = $m.Split("`n"); $depth = 0; $i = 0
    while ($i -lt $lines.Length) {
        $start = $i; $logical = $lines[$i]
        $depth += ([regex]::Matches($lines[$i], '[(\[{]')).Count - ([regex]::Matches($lines[$i], '[)\]}]')).Count
        while (($depth -gt 0 -or $logical.TrimEnd().EndsWith('\')) -and $i + 1 -lt $lines.Length) {
            $i++; $logical += ' ' + $lines[$i]
            $depth += ([regex]::Matches($lines[$i], '[(\[{]')).Count - ([regex]::Matches($lines[$i], '[)\]}]')).Count
        }
        $t = $logical.Trim()
        if ($t -match '^(async\s+)?(def|class|if|elif|else|for|while|try|except|finally|with)\b' -and $t -notmatch ':\s*\S' -and -not $t.EndsWith(':')) {
            "line $($start + 1): '$(($Text.Split("`n")[$start]).Trim())' needs a colon at the end"
        }
        $i++; if ($depth -lt 0) { $depth = 0 }
    }
    if ([regex]::IsMatch($Text, '(?m)^( +\t|\t+ )')) { "line $(LineAt $Text ([regex]::Match($Text, '(?m)^( +\t|\t+ )').Index)): indentation mixes tabs and spaces" }
    elseif ([regex]::IsMatch($Text, '(?m)^\t+\S') -and [regex]::IsMatch($Text, '(?m)^ +\S')) {
        $tabLine = LineAt $Text ([regex]::Match($Text, '(?m)^\t+\S').Index); $spaceLine = LineAt $Text ([regex]::Match($Text, '(?m)^ +\S').Index)
        "line $([Math]::Max($tabLine, $spaceLine)): indented with $(if ($tabLine -gt $spaceLine) { 'tabs' } else { 'spaces' }) while line $([Math]::Min($tabLine, $spaceLine)) uses $(if ($tabLine -gt $spaceLine) { 'spaces' } else { 'tabs' }): Python stops with a TabError"
    }
}

function Test-PowerShell([string]$Text) {
    $tok = $null; $errs = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$errs)
    foreach ($e in @($errs) | Select-Object -First 3) { "line $($e.Extent.StartLineNumber): $($e.Message)" }
}

function Test-Yaml([string]$Text) {
    $lines = $Text.Split("`n")
    $levels = @{}   # indent -> @{ key = line }
    $blockIndent = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]; $n = $i + 1
        if ($l -match '^( *)\t') { "line ${n}: tabs in the indentation (YAML allows only spaces)"; continue }
        $indent = ([regex]::Match($l, '^ *')).Value.Length
        if (-not $l.Trim() -or $l.Trim().StartsWith('#')) { continue }
        if ($blockIndent -ge 0) { if ($indent -gt $blockIndent) { continue } else { $blockIndent = -1 } }   # inside a | or > block
        if ($l -match '^---|^\.\.\.') { $levels = @{}; continue }
        $item = [regex]::Match($l, '^( *)- +')
        $keyIndent = if ($item.Success) { $item.Length } else { $indent }
        foreach ($k in @($levels.Keys)) { if ($k -gt $indent) { $levels.Remove($k) } }
        if ($item.Success) { $levels[$keyIndent] = @{} }
        $km = [regex]::Match($l, '^ *(?:- +)?("[^"]+"|''[^'']+''|[^\s#''"\[\]{},][^:#]*?):(\s|$)')
        if ($km.Success) {
            $key = $km.Groups[1].Value.Trim()
            if (-not $levels.ContainsKey($keyIndent)) { $levels[$keyIndent] = @{} }
            if ($levels[$keyIndent].ContainsKey($key)) { "line ${n}: duplicate key '$key' (also at line $($levels[$keyIndent][$key]))" }
            else { $levels[$keyIndent][$key] = $n }
            $value = $l.Substring($km.Index + $km.Length).Trim()
            if ($value -match '^[|>][+-]?\d*\s*(#.*)?$') { $blockIndent = $indent }
            if ($value -match '^"' -and $value -notmatch '^"(?:[^"\\]|\\.)*"') { "line ${n}: a double-quoted value is never closed" }
            if ($value -match "^'" -and $value -notmatch "^'(?:[^']|'')*'") { "line ${n}: a single-quoted value is never closed" }
            if ($value -match '^[\[{]') { $b = Test-Brackets (Hide $value '"(?:[^"\\]|\\.)*"|''(?:[^'']|'''')*''|\s#.*$'); if ($b) { "line ${n}: flow value: $($b -replace '^line \d+: ', '')" } }
        } elseif ($l -match '^ *(?:- +)?[A-Za-z_][\w.-]*:[^\s/:]' -and $l -notmatch '^ *(?:- +)?\w+://') {
            "line ${n}: '$($l.Trim())' has no space after the colon, so YAML reads it as text, not as a key"
        }
    }
}

function Test-Json([string]$Text, [string]$Path = '') {
    # tsconfig, jsconfig, VS Code settings and .jsonc may hold comments and trailing commas (JSONC).
    if ($Path -match '(?i)(^|/)(tsconfig[^/]*|jsconfig[^/]*|\.vscode/[^/]+|devcontainer|\.eslintrc|settings|launch|tasks|extensions)\.json$|\.jsonc$') {
        $Text = Hide $Text '"(?:[^"\\\n]|\\.)*"|//[^\n]*|/\*[\s\S]*?\*/' | ForEach-Object { $_ }   # blank strings to find comments
        return   # comments and trailing commas are allowed; the brackets still have to match
    }
    try {
        Add-Type -AssemblyName System.Web.Extensions
        $s = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $s.MaxJsonLength = [int]::MaxValue; $s.RecursionLimit = 1000
        $null = $s.DeserializeObject($Text)
    } catch { "not valid JSON: $($_.Exception.InnerException.Message, $_.Exception.Message | Where-Object { $_ } | Select-Object -First 1)" }
}

$script:VoidTags = 'area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr|!doctype'
$script:OptionalClose = 'html|head|body|p|li|dt|dd|tr|td|th|thead|tbody|tfoot|option|optgroup|colgroup|caption|rb|rt|rtc|rp'

function Test-Html([string]$Text) {
    $c = [regex]::Match($Text, '<!--(?![\s\S]*?-->)')
    if ($c.Success) { "line $(LineAt $Text $c.Index): an <!-- comment is never closed"; return }
    $m = Hide $Text '<!--[\s\S]*?-->'
    # Script and style contents are code, not tags.
    $m = [regex]::Replace($m, '(?is)(<(script|style)\b[^>]*>)(.*?)(</\2\s*>)', [Text.RegularExpressions.MatchEvaluator] { param($x) $x.Groups[1].Value + [regex]::Replace($x.Groups[3].Value, '[^\n]', ' ') + $x.Groups[4].Value })
    $stack = New-Object System.Collections.Generic.List[object]
    $first = $null
    foreach ($t in [regex]::Matches($m, '<(/?)([A-Za-z!][\w:.-]*)((?:"[^"]*"|''[^'']*''|[^''">])*)>')) {
        $name = $t.Groups[2].Value.ToLowerInvariant(); $line = LineAt $m $t.Index
        if ($name -match "^($script:VoidTags)$" -or $name -match "^($script:OptionalClose)$" -or $t.Groups[3].Value.TrimEnd().EndsWith('/')) { continue }
        if (-not $t.Groups[1].Value) { $stack.Add(@($name, $line)); continue }
        $at = -1; for ($k = $stack.Count - 1; $k -ge 0; $k--) { if ($stack[$k][0] -eq $name) { $at = $k; break } }
        if ($at -lt 0) { if (-not $first) { $first = "line ${line}: </$name> closes nothing" }; continue }
        if ($at -lt $stack.Count - 1 -and -not $first) { $first = "line $($stack[$stack.Count - 1][1]): <$($stack[$stack.Count - 1][0])> is not closed before </$name> at line $line" }
        $stack.RemoveRange($at, $stack.Count - $at)
    }
    if ($first) { $first } elseif ($stack.Count) { "line $($stack[$stack.Count - 1][1]): <$($stack[$stack.Count - 1][0])> is never closed" }
    $ids = @{}
    foreach ($idm in [regex]::Matches($m, '(?i)\sid\s*=\s*["'']([^"''{}$]+)["'']')) {
        $v = $idm.Groups[1].Value; $line = LineAt $m $idm.Index
        if ($ids.ContainsKey($v)) { "line ${line}: id ""$v"" is used twice (also at line $($ids[$v]))" } else { $ids[$v] = $line }
    }
    $nameAnchors = @{}; foreach ($nm in [regex]::Matches($m, '(?i)<a\s[^>]*\sname\s*=\s*["'']([^"'']+)["'']')) { $nameAnchors[$nm.Groups[1].Value] = $true }
    foreach ($hm in [regex]::Matches($m, '(?i)\shref\s*=\s*["'']#([^"''{}$\s]+)["'']')) {
        $v = $hm.Groups[1].Value
        if (-not $ids.ContainsKey($v) -and -not $nameAnchors.ContainsKey($v) -and $v -ne 'top') { "line $(LineAt $m $hm.Index): link to #$v, but no element has id ""$v""" }
    }
}

function Test-Css([string]$Text) {
    $m = Hide $Text $script:MaskCss
    Find-Leftover $m '/\*' 'a /* comment is never closed'
    Test-Brackets $m
    $lines = $m.Split("`n")
    $decl = '^\s*[-\w$@]+\s*:\s*[^;{}]+$'
    for ($i = 0; $i -lt $lines.Length - 1; $i++) {
        if ($lines[$i] -match $decl -and $lines[$i] -notmatch '[,(]\s*$') {
            $j = $i + 1; while ($j -lt $lines.Length -and -not $lines[$j].Trim()) { $j++ }
            if ($j -lt $lines.Length -and $lines[$j] -match '^\s*[-\w$@]+\s*:\s*[^{]') { "line $($i + 1): missing ; at the end of '$($Text.Split("`n")[$i].Trim())'" }
        }
    }
}

function Test-Xml([string]$Text) {
    try { $x = New-Object Xml.XmlDocument; $x.XmlResolver = $null; $x.LoadXml($Text) } catch { "not valid XML: $($_.Exception.InnerException.Message, $_.Exception.Message | Where-Object { $_ } | Select-Object -First 1)" }
}

function Test-Markdown([string]$Text) {
    $open = $null; $lines = $Text.Split("`n")
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $f = [regex]::Match($lines[$i], '^\s{0,3}(`{3,}|~{3,})')
        if (-not $f.Success) { continue }
        if (-not $open) { $open = @($f.Groups[1].Value, ($i + 1)) }
        elseif ($f.Groups[1].Value[0] -eq $open[0][0] -and $f.Groups[1].Value.Length -ge $open[0].Length -and $lines[$i].Trim() -match '^(`+|~+)$') { $open = $null }
    }
    if ($open) { "line $($open[1]): a code block opened with $($open[0]) is never closed" }
}

function Test-Shell([string]$Text, [bool]$HasCrlf) {
    if ($HasCrlf) { 'Windows line endings (CRLF): bash fails on them; use LF' }
    $m = Hide $Text $script:MaskShell
    Find-Leftover $m '["'']' 'a quote is never closed'
    foreach ($p in @(@('if', 'fi'), @('case', 'esac'), @('do', 'done'))) {
        $a = ([regex]::Matches($m, "(?m)(^|[;&|(]|\s)$($p[0])(\s|$)")).Count
        $z = ([regex]::Matches($m, "(?m)(^|[;&|]|\s)$($p[1])(\s|;|$|\))")).Count
        if ($a -ne $z) { "$($p[0])/$($p[1]) do not match: $a $($p[0]), $z $($p[1])" }
    }
}

function Test-Batch([string]$Text, [bool]$HasLfOnly) {
    # LF only breaks batch files that jump to labels (goto, call :label).
    if ($HasLfOnly -and $Text -match '(?im)^\s*:[A-Za-z_]|\b(goto|call)\s+:') { 'LF line endings: batch files need CRLF (labels and goto can fail otherwise)' }
    $lines = $Text.Split("`n")
    $labels = @{}
    foreach ($l in $lines) { $lm = [regex]::Match($l, '^\s*:([A-Za-z_][\w.-]*)'); if ($lm.Success) { $labels[$lm.Groups[1].Value.ToLowerInvariant()] = $true } }
    $depth = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        if ($l -match '(?i)^\s*(rem\b|::)') { continue }
        foreach ($g in [regex]::Matches($l, '(?i)\b(?:goto|call)\s+:?([A-Za-z_][\w.-]*)')) {
            $name = $g.Groups[1].Value.ToLowerInvariant()
            $isCall = $g.Value -match '(?i)^call\s+:'
            if ($name -eq 'eof' -or ($g.Value -match '(?i)^call' -and -not $isCall)) { continue }
            if (-not $labels.ContainsKey($name)) { "line $($i + 1): label :$name does not exist" }
        }
        $s = Hide $l '"[^"]*"'
        $depth += ([regex]::Matches($s, '\(')).Count - ([regex]::Matches($s, '\)')).Count
        if ($depth -lt 0) { "line $($i + 1): ')' closes nothing"; $depth = 0 }
    }
    if ($depth -gt 0) { 'a ( block is never closed with )' }
}

function Test-Sql([string]$Text) {
    $m = Hide $Text $script:MaskSql
    Find-Leftover $m '/\*' 'a /* comment is never closed'
    Find-Leftover $m '''' 'a string is never closed'
    Test-Brackets $m
}

function Test-Toml([string]$Text) {
    $lines = $Text.Split("`n"); $depth = 0; $keys = @{}; $table = ''
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $n = $i + 1
        $m = Hide $lines[$i] '"""[\s\S]*?"""|"(?:[^"\\]|\\.)*"|''[^'']*''|#.*$'
        if ($m -match '["'']') { "line ${n}: a string is never closed" }
        $t = $m.Trim()
        if ($depth -gt 0) { $depth += ([regex]::Matches($t, '\[')).Count - ([regex]::Matches($t, '\]')).Count; continue }
        if (-not $t) { continue }
        if ($t.StartsWith('[')) {
            if ($t -notmatch '^\[\[?[^\[\]]+\]\]?$') { "line ${n}: the table header '$($lines[$i].Trim())' is not closed with ]" } else { $table = $t; $keys = @{} }
            continue
        }
        $kv = [regex]::Match($t, '^([A-Za-z0-9_.-]+|"[^"]*"|''[^'']*'')\s*=\s*(.*)$')
        if (-not $kv.Success) { "line ${n}: '$($lines[$i].Trim())' is not 'key = value'"; continue }
        $k = $kv.Groups[1].Value
        if ($keys.ContainsKey($k)) { "line ${n}: duplicate key '$k'$(if ($table) { " in $table" }) (also at line $($keys[$k]))" } else { $keys[$k] = $n }
        $depth = ([regex]::Matches($kv.Groups[2].Value, '\[')).Count - ([regex]::Matches($kv.Groups[2].Value, '\]')).Count
        if ($depth -lt 0) { $depth = 0 }
    }
}

function Test-Csv([string]$Text, [string]$Path) {
    $lines = @($Text.TrimEnd("`n").Split("`n"))
    if ($lines.Count -lt 2) { return }
    $d = if ($Path -match '(?i)\.tsv$') { "`t" } elseif (([regex]::Matches($lines[0], ';')).Count -gt ([regex]::Matches($lines[0], ',')).Count) { ';' } else { ',' }
    $count = { param($l) $x = [regex]::Replace($l, '"(?:[^"]|"")*"', 'q'); ([regex]::Matches($x, [regex]::Escape($d))).Count + 1 }
    $want = & $count $lines[0]
    for ($i = 1; $i -lt $lines.Length; $i++) {
        if (-not $lines[$i].Trim()) { continue }
        if (([regex]::Matches($lines[$i], '"')).Count % 2) { return "line $($i + 1): a quoted field is never closed" }
        $got = & $count $lines[$i]
        if ($got -ne $want) { return "line $($i + 1): $got columns, the header has $want" }
    }
}

$script:CodeExt = '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte|cs|java|kt|kts|go|rs|php|swift|dart|scala|c|cc|cpp|h|hpp|py|pyw|ps1|psm1|psd1|css|scss|less|json|ya?ml|toml|ini|sh|bash|cmd|bat|sql|html?|xml|csproj|config|xaml|svg)$'
# Program code where a repeated block or a second definition is a mistake (not data or markup).
$script:ProgramExt = '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|cs|java|kt|go|rs|php|swift|dart|c|cc|cpp|h|hpp|py|pyw|ps1|psm1|sh|bash)$'

function Test-Duplicates([string]$Text, [string]$Path) {
    <# A function defined twice in one file, or the same 8+ code lines twice: usually code that was
       added again instead of replaced. #>
    if ($Path -notmatch $script:ProgramExt) { return }
    $re = switch -Regex ($Path) {
        '(?i)\.ps[md]?1$' { '(?im)^\s*function\s+([\w-]+)' }
        '(?i)\.pyw?$' { '(?m)^(?:async\s+)?def\s+(\w+)' }   # top level only: methods of different classes may share names
        '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx)$' { '(?m)^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([\w$]+)' }
        default { $null }
    }
    if ($re) {
        $seen = @{}
        foreach ($d in [regex]::Matches($Text, $re)) {
            $name = $d.Groups[1].Value; $line = LineAt $Text $d.Index
            if ($seen.ContainsKey($name)) { "line ${line}: function '$name' is defined a second time (first at line $($seen[$name]))"; break }
            $seen[$name] = $line
        }
    }
    # The same 8 code lines twice (blank lines and lone brackets do not count). Not for JSX/TSX,
    # where repeated markup is normal.
    if ($Path -match '(?i)\.(jsx|tsx)$') { return }
    $lines = $Text.Split("`n")
    $code = @(for ($i = 0; $i -lt $lines.Length; $i++) { $t = $lines[$i].Trim(); if ($t.Length -gt 3 -and $t -notmatch '^[\s{}()\[\];,]*$') { @{ t = $t; n = $i + 1 } } })
    $win = @{}
    for ($i = 0; $i + 8 -le $code.Count; $i++) {
        $key = ($code[$i..($i + 7)] | ForEach-Object { $_.t }) -join "`n"
        if ($win.ContainsKey($key)) {
            $j = $win[$key]   # where the same 8 lines were first
            if ($i - $j -ge 8) { return "line $($code[$i].n): these lines repeat lines $($code[$j].n)-$($code[$j + 7].n) (code added again instead of replaced?)" }
        } else { $win[$key] = $i }
    }
}

# Secrets that must not end up in project files. Placeholders (your-key, xxx, <...>, ${...}) are fine.
$script:SecretRules = @(
    @{ what = 'a private key'; re = '-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----' }
    @{ what = 'an AWS access key'; re = '\bAKIA[0-9A-Z]{16}\b' }
    @{ what = 'a GitHub token'; re = '\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b' }
    @{ what = 'a Slack token'; re = '\bxox[baprs]-[A-Za-z0-9-]{10,}' }
    @{ what = 'an Azure storage key'; re = 'AccountKey=[A-Za-z0-9+/=]{40,}' }
    @{ what = 'a JSON web token'; re = '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' }
    @{ what = 'a password in a connection string'; re = '(?i)\b(?:password|pwd)\s*=\s*(?!\s*["'']?\s*(?:\$|\{|<|%|\*|your|xxx|changeme|placeholder|example)[^;"'']*)[^;"''\s]{6,}' }
    @{ what = 'a password, key or token in the code'; re = '(?i)\b(?:password|passwd|pwd|secret|client_?secret|api_?key|apikey|access_?token|auth_?token)\b["'']?\s*[:=]\s*["''](?!\s*(?:\$|\{|<|%|\*|your|xxx|changeme|placeholder|example|test|dummy|\.\.\.))[^"''\s]{8,}["'']' }
)

function Find-Secrets([string]$Text) {
    <# "line N: what" for each secret-like value. #>
    foreach ($r in $script:SecretRules) {
        foreach ($m in [regex]::Matches("$Text", $r.re)) { "line $(LineAt $Text $m.Index): $($r.what)" }
    }
}

$script:CommandCache = @{}
$script:ProjectFunctions = @{}   # project root -> @{ at; names }

function Get-ProjectFunctionNames([string]$ProjectRoot) {
    # Function names defined in the project's .ps1/.psm1 files, cached for 60 seconds per project.
    # (Get-ChildItem -LiteralPath with -Include finds nothing in PowerShell 5.1: filter by extension.)
    $c = $script:ProjectFunctions[$ProjectRoot]
    if ($c -and ((Get-Date) - $c.at).TotalSeconds -lt 60) { return $c.names }
    $names = @{}
    $files = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.psm?1$' -and $_.Length -lt 1MB -and $_.FullName -notmatch '\\(node_modules|\.git|\.streamhub)\\' } | Select-Object -First 500)
    foreach ($pf in $files) {
        foreach ($fm in [regex]::Matches([IO.File]::ReadAllText($pf.FullName), '(?im)^\s*function\s+(?:global:|script:)?([\w-]+)')) { $names[$fm.Groups[1].Value.ToLowerInvariant()] = $true }
    }
    $script:ProjectFunctions[$ProjectRoot] = @{ at = Get-Date; names = $names }
    $names
}
function Test-PsCommands([string]$Text, [string]$ProjectRoot) {
    <# PowerShell commands (Verb-Noun) that exist neither on this computer nor in the project: usually
       a typo. Skipped for a script that loads a module this computer does not have. #>
    $tok = $null; $errs = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$errs)
    if (@($errs).Count) { return }
    foreach ($mod in [regex]::Matches($Text, '(?im)^\s*(?:Import-Module|#Requires\s+-Modules?)\s+["'']?([\w.]+)')) {
        $name = $mod.Groups[1].Value
        if ($name -notmatch '\.psm?1$' -and -not (Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue)) { return }
    }
    $known = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $known[$f.Name.ToLowerInvariant()] = $true }
    if ($ProjectRoot -and (Test-Path -LiteralPath $ProjectRoot)) {
        foreach ($k in (Get-ProjectFunctionNames $ProjectRoot).Keys) { $known[$k] = $true }
    }
    $reported = @{}
    foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name -or $name -notmatch '^[A-Za-z]+-[A-Za-z][\w]*$') { continue }
        $k = $name.ToLowerInvariant()
        if ($known.ContainsKey($k) -or $reported.ContainsKey($k)) { continue }
        if (-not $script:CommandCache.ContainsKey($k)) { $script:CommandCache[$k] = [bool](Get-Command -Name $name -ErrorAction SilentlyContinue) }
        if (-not $script:CommandCache[$k]) { $reported[$k] = $true; "line $($c.Extent.StartLineNumber): '$name' is not a command on this computer or in the project (a typo?)" }
    }
}

function Test-LocalReferences([string]$Text, [string]$Path, [string]$ProjectRoot) {
    <# Files a script or document points to that do not exist: dot-sourced scripts and module
       paths (PowerShell), relative imports (Python), relative links (Markdown). #>
    if (-not $ProjectRoot) { return }
    $dir = Split-Path -Parent (Join-Path $ProjectRoot ($Path.Replace('/', '\')))
    $exists = { param($rel) $p = [IO.Path]::GetFullPath((Join-Path $dir ($rel.Replace('/', '\')))); Test-Path -LiteralPath $p }
    switch -Regex ($Path) {
        '(?i)\.ps[md]?1$' {
            foreach ($m in [regex]::Matches($Text, '(?im)^\s*\.\s+["'']?(?:\$PSScriptRoot[\\/])?((?:\.{1,2}[\\/])?[\w .\\/-]+\.ps1)["'']?')) {
                if (-not (& $exists $m.Groups[1].Value)) { "line $(LineAt $Text $m.Index): dot-sources $($m.Groups[1].Value), which does not exist" }
            }
            foreach ($m in [regex]::Matches($Text, '(?i)Join-Path\s+\$PSScriptRoot\s+["'']([^"''$]+\.(?:ps1|psm1|psd1))["'']')) {
                if (-not (& $exists $m.Groups[1].Value)) { "line $(LineAt $Text $m.Index): refers to $($m.Groups[1].Value), which does not exist" }
            }
            break
        }
        '(?i)\.pyw?$' {
            foreach ($m in [regex]::Matches($Text, '(?m)^\s*from\s+\.(\w+)\s+import\b')) {
                $mod = $m.Groups[1].Value
                if (-not (& $exists "$mod.py") -and -not (& $exists "$mod\__init__.py")) { "line $(LineAt $Text $m.Index): imports .$mod, but $mod.py does not exist next to this file" }
            }
            foreach ($m in [regex]::Matches($Text, '(?m)^\s*from\s+\.\s+import\s+(\w+)')) {
                $mod = $m.Groups[1].Value
                if (-not (& $exists "$mod.py") -and -not (& $exists "$mod\__init__.py") -and -not (& $exists '__init__.py')) { "line $(LineAt $Text $m.Index): imports $mod from this folder, but $mod.py does not exist" }
            }
            break
        }
        '(?i)\.(md|markdown)$' {
            $m2 = Hide $Text '(?ms)^\s{0,3}(`{3,}|~{3,}).*?^\s{0,3}\1|`[^`\n]*`'   # not inside code
            foreach ($m in [regex]::Matches($m2, '\[[^\]]*\]\(([^)\s#?]+)')) {
                $target = [uri]::UnescapeDataString($m.Groups[1].Value)
                if ($target -match '^(?i)([a-z][a-z0-9+.-]*:|//|/)') { continue }
                if (-not (& $exists $target)) { "line $(LineAt $Text $m.Index): links to $target, which does not exist" }
            }
            break
        }
    }
}


function Test-FileContent {
    <# The problems in a file's text, by its type: "line N: problem" (or a whole-file problem).
       Also for every code file: leftover edit or merge markers and ``` fence lines. #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text, [bool]$Crlf = $false)
    $t = $Text.Replace("`r`n", "`n")
    $issues = New-Object System.Collections.Generic.List[string]
    $add = { param($x) foreach ($y in @($x)) { if ($y) { $issues.Add([string]$y) } } }
    if ($Path -match $script:CodeExt) {
        # Markers inside strings (a PowerShell here-string, a test) are text, not damage.
        $noStrings = if ($Path -match '(?i)\.ps[md]?1$') { Hide $t '@''[\s\S]*?\n''@|@"[\s\S]*?\n"@' } elseif ($Path -match '(?i)\.pyw?$') { Hide $t '"""[\s\S]*?"""|''''''[\s\S]*?''''''' } else { $t }
        $mk = [regex]::Match($noStrings, '(?m)^(<{7}( SEARCH|\s.*)?|>{7}( REPLACE|\s.*)?|={7})\s*$')
        if ($mk.Success) { & $add "line $(LineAt $t $mk.Index): leftover edit or merge marker '$($mk.Value.Trim())'" }
        if ($Path -notmatch '(?i)\.(html?|xml|svg)$') {
            $fc = [regex]::Match($t, '(?m)^\s{0,3}```')
            if ($fc.Success) { & $add ("line $(LineAt $t $fc.Index): a " + '```' + ' code-fence line in a code file (left over from a chat answer?)') }
        }
    }
    $hasCrlf = $Crlf -or $Text.Contains("`r`n")
    switch -Regex ($Path) {
        '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte|cs|java|kt|kts|go|rs|php|swift|dart|scala|c|cc|cpp|h|hpp)$' { & $add (Test-CLike $t $Path); break }
        '(?i)\.pyw?$' { & $add (Test-Python $t); break }
        '(?i)\.ps[md]?1$' { & $add (Test-PowerShell $t); break }
        '(?i)\.ya?ml$' { & $add (Test-Yaml $t); break }
        '(?i)\.jsonc?$' { & $add (Test-Json $t $Path); if ($Path -match '(?i)(^|/)(tsconfig|jsconfig|\.vscode/|devcontainer|\.eslintrc|settings|launch|tasks|extensions)|\.jsonc$') { & $add (Test-Brackets (Hide $t '"(?:[^"\\\n]|\\.)*"|//[^\n]*|/\*[\s\S]*?\*/')) }; break }
        '(?i)\.html?$' { & $add (Test-Html $t); break }
        '(?i)\.(css|scss|less)$' { & $add (Test-Css $t); break }
        '(?i)\.(xml|csproj|vbproj|fsproj|props|targets|config|xaml|svg|resx|nuspec|plist)$' { & $add (Test-Xml $Text.Trim()); break }
        '(?i)\.(md|markdown)$' { & $add (Test-Markdown $t); break }
        '(?i)\.(sh|bash)$' { & $add (Test-Shell $t $hasCrlf); break }
        '(?i)\.(cmd|bat)$' { & $add (Test-Batch $t (-not $hasCrlf -and $t.Contains("`n"))); break }
        '(?i)\.sql$' { & $add (Test-Sql $t); break }
        '(?i)\.toml$' { & $add (Test-Toml $t); break }
        '(?i)\.(csv|tsv)$' { & $add (Test-Csv $t $Path); break }
    }
    & $add (Test-Duplicates $t $Path)
    $issues.ToArray()
}

function Get-NewFileIssues {
    <# Problems a change added: those in the new text that the old text did not have (compared
       without line numbers, so an existing problem that only moved is not reported again). #>
    param([string]$Path, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New, [bool]$Crlf = $false, [string]$ProjectRoot = '')
    $all = {
        param($text)
        @(Test-FileContent $Path $text $Crlf) + @(Test-LocalReferences $text.Replace("`r`n", "`n") $Path $ProjectRoot) +
            @(if ($Path -match '(?i)\.ps[md]?1$') { Test-PsCommands $text $ProjectRoot }) | Where-Object { $_ }
    }
    $after = @(& $all $New)
    if (-not $after.Count) { return }
    $before = @{}
    if ("$Old") { foreach ($i in @(& $all $Old)) { $k = $i -replace '\d+', '#'; $before[$k] = 1 + [int]$before[$k] } }
    foreach ($i in $after) {
        $k = $i -replace '\d+', '#'
        if ($before[$k]) { $before[$k]--; continue }
        $i
    }
}

Export-ModuleMember -Function Test-FileContent, Get-NewFileIssues, Test-Brackets, Find-Secrets, Test-Duplicates, Test-PsCommands, Test-LocalReferences
