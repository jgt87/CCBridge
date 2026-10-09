# File checks per type: the mistakes that commonly break each kind of file (missing characters,
# unclosed tags, brackets and strings, open code blocks, wrong line endings, duplicate keys).
# Fixed rules only, no tools to install. Test-FileContent returns "line N: problem" texts; the
# agent reports only problems a change added (Get-NewFileIssues compares with the file before).

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')   # Test-CheckSwitch: the check families can be turned off
Import-Module (Join-Path $PSScriptRoot 'OneFile.psm1')   # one-file pages: the helper program's blocks are not checked

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
    $depth = 0; $prev = [char]0; $prev2 = [char]0
    $n = $Text.Length
    for ($i = 0; $i -lt $n; $i++) {
        $ch = $Text[$i]; $nx = if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 }
        if ($ch -eq "`n") { $line++ }
        switch ($state) {
            'code' {
                if ($ch -eq '/' -and $nx -eq '/') { $state = 'line'; [void]$sb.Append(' '); continue }
                if ($ch -eq '/' -and $nx -eq '*') { $state = 'block'; $start = $line; [void]$sb.Append(' '); continue }
                # A / starts a regular expression after an operator or bracket, after => (an arrow
                # function's body) and after keywords such as return; elsewhere it divides.
                $regexStart = "$prev" -match '^[\x00(,=:\[!&|?{;+\-*%~^]$' -or ($prev -eq '>' -and $prev2 -eq '=')
                if (-not $regexStart -and $ch -eq '/' -and $nx -ne '/' -and $nx -ne '*' -and [char]::IsLetter($prev)) {
                    $k = $i - 1; while ($k -ge 0 -and [char]::IsWhiteSpace($Text[$k])) { $k-- }
                    $e = $k; while ($k -ge 0 -and [char]::IsLetter($Text[$k])) { $k-- }
                    $word = $Text.Substring($k + 1, $e - $k)
                    $regexStart = $word -in 'return', 'typeof', 'case', 'in', 'of', 'void', 'delete', 'new', 'throw', 'yield', 'await', 'else', 'do'
                }
                if ($ch -eq '/' -and $regexStart) { $state = 'regex'; [void]$sb.Append(' '); continue }
                if ($ch -eq '"' -or $ch -eq "'") { $state = $ch; $start = $line; [void]$sb.Append(' '); continue }
                if ($ch -eq '`') { $state = 'tpl'; $start = $line; [void]$sb.Append(' '); continue }
                if ($stack.Count) {
                    if ($ch -eq '{') { $depth++ }
                    elseif ($ch -eq '}') { if ($depth -eq 0) { $depth = $stack.Pop(); $state = 'tpl'; [void]$sb.Append(' '); continue } else { $depth-- } }
                }
                [void]$sb.Append($ch); if (-not [char]::IsWhiteSpace($ch)) { $prev2 = $prev; $prev = $ch }
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
    # A tag whose start was lost on the way from the chat (<script src="PATH.js"></script> left as PATH.jsscript>).
    foreach ($lost in [regex]::Matches($m, '(?i)[\w.~/-]+\.(js|mjs|cjs|css|json)(script|link|style)>')) { "line $(LineAt $m $lost.Index): '$($lost.Value)' is what is left of a damaged <$($lost.Groups[2].Value.ToLowerInvariant())> tag; write the whole tag again" }
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

# Prisma schema (schema.prisma): blocks, fields, types, attributes and relations, by fixed rules.
# Prisma's own check (prisma validate) runs as well when the project has Prisma installed
# (Test-PrismaValidate); these rules need nothing installed.
$script:PrismaScalars = @('String', 'Boolean', 'Int', 'BigInt', 'Float', 'Decimal', 'DateTime', 'Json', 'Bytes', 'Unsupported')
$script:PrismaFieldAttrs = @('id', 'default', 'unique', 'relation', 'map', 'updatedAt', 'ignore', 'db', 'shardKey')
$script:PrismaBlockAttrs = @('id', 'unique', 'index', 'map', 'ignore', 'schema', 'fulltext', 'shardKey')
$script:PrismaProviders = @('postgresql', 'postgres', 'mysql', 'sqlite', 'sqlserver', 'mongodb', 'cockroachdb')

function Get-PrismaBlocks([string]$Text) {
    <# The top-level blocks of a schema: @{ kind; name; line; body = @(@{ n; text }) }, plus the
       lines outside any block that are not empty ("stray"). Comments and strings are blanked. #>
    $masked = Hide $Text '"(?:[^"\\\n]|\\.)*"|//[^\n]*'
    $lines = $masked.Split("`n"); $raw = $Text.Split("`n")
    $blocks = New-Object System.Collections.Generic.List[object]
    $stray = New-Object System.Collections.Generic.List[object]
    $cur = $null
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $t = $lines[$i].Trim(); $n = $i + 1
        if (-not $cur) {
            if (-not $t) { continue }
            $h = [regex]::Match($t, '^(datasource|generator|model|enum|view|type)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{\s*(\})?$')
            if ($h.Success) {
                $cur = @{ kind = $h.Groups[1].Value; name = $h.Groups[2].Value; line = $n; body = (New-Object System.Collections.Generic.List[object]); closed = $false }
                $blocks.Add($cur)
                if ($h.Groups[3].Success) { $cur.closed = $true; $cur = $null }
            } else { $stray.Add(@{ n = $n; text = $raw[$i].Trim() }) }
            continue
        }
        if ($t -eq '}') { $cur.closed = $true; $cur = $null; continue }
        if ($t) { $cur.body.Add(@{ n = $n; text = $t; raw = $raw[$i].Trim() }) }
    }
    @{ blocks = $blocks.ToArray(); stray = $stray.ToArray() }
}

function New-OrdinalMap { New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal) }

function Test-Prisma([string]$Text) {
    <# Problems in a Prisma schema: "line N: problem". Names are case-sensitive in Prisma, so they
       are compared exactly. #>
    $masked = Hide $Text '"(?:[^"\\\n]|\\.)*"|//[^\n]*'
    $b = Test-Brackets $masked
    if ($b) { return $b }   # the rest needs whole blocks
    $q = Find-Leftover (Hide $Text '"(?:[^"\\\n]|\\.)*"|//[^\n]*') '"' 'a string is never closed'
    if ($q) { return $q }
    $p = Get-PrismaBlocks $Text
    foreach ($s in $p.stray) { "line $($s.n): '$($s.text)' is not part of a block (blocks are datasource, generator, model, enum, view and type, written as KIND NAME { ... })" }
    $names = New-OrdinalMap
    foreach ($blk in $p.blocks) {
        if (-not $blk.closed) { "line $($blk.line): $($blk.kind) $($blk.name) is never closed with } on its own line"; continue }
        if ($blk.kind -in 'model', 'enum', 'view', 'type') {
            if ($names.ContainsKey($blk.name)) { "line $($blk.line): $($blk.name) is defined twice (also at line $($names[$blk.name]))" } else { $names[$blk.name] = $blk.line }
        }
    }
    $models = New-OrdinalMap; $enums = New-OrdinalMap
    foreach ($blk in $p.blocks) {
        # The first definition counts (a second one is reported above).
        if ($blk.kind -in 'model', 'view', 'type') { if (-not $models.ContainsKey($blk.name)) { $models[$blk.name] = $blk } }
        elseif ($blk.kind -eq 'enum') { if (-not $enums.ContainsKey($blk.name)) { $enums[$blk.name] = $blk } }
    }
    foreach ($blk in $p.blocks) {
        switch ($blk.kind) {
            { $_ -in 'datasource', 'generator' } {
                $keys = @{}
                foreach ($l in $blk.body) {
                    $kv = [regex]::Match($l.raw, '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\S')   # the line as written: its string value is blanked in .text
                    if (-not $kv.Success) { "line $($l.n): '$($l.raw)' is not 'key = value' in $($blk.kind) $($blk.name)"; continue }
                    $keys[$kv.Groups[1].Value] = $l
                }
                if ($blk.kind -eq 'datasource') {
                    if (-not $keys.ContainsKey('provider')) { "line $($blk.line): datasource $($blk.name) has no provider" }
                    else {
                        $pv = [regex]::Match($keys['provider'].raw, '=\s*"([^"]*)"')
                        if ($pv.Success -and $script:PrismaProviders -cnotcontains $pv.Groups[1].Value) { "line $($keys['provider'].n): '$($pv.Groups[1].Value)' is not a database Prisma knows ($($script:PrismaProviders -join ', '))" }
                    }
                } elseif (-not $keys.ContainsKey('provider')) { "line $($blk.line): generator $($blk.name) has no provider" }
            }
            'enum' {
                $vals = New-OrdinalMap
                foreach ($l in $blk.body) {
                    if ($l.text -match '^@@') { continue }
                    $v = [regex]::Match($l.text, '^([A-Za-z][A-Za-z0-9_]*)(\s+@.*)?$')
                    if (-not $v.Success) { "line $($l.n): '$($l.raw)' is not an enum value"; continue }
                    if ($vals.ContainsKey($v.Groups[1].Value)) { "line $($l.n): enum $($blk.name) has $($v.Groups[1].Value) twice" } else { $vals[$v.Groups[1].Value] = 1 }
                }
            }
            { $_ -in 'model', 'view', 'type' } {
                $fields = New-OrdinalMap; $unique = $false
                $relations = New-Object System.Collections.Generic.List[object]
                foreach ($l in $blk.body) {
                    if ($l.text -match '^@@') {
                        $ba = [regex]::Match($l.text, '^@@([A-Za-z]+)')
                        if ($script:PrismaBlockAttrs -cnotcontains $ba.Groups[1].Value) { "line $($l.n): @@$($ba.Groups[1].Value) is not a Prisma block attribute ($(@($script:PrismaBlockAttrs | ForEach-Object { "@@$_" }) -join ', '))" }
                        if ($ba.Groups[1].Value -in 'id', 'unique') { $unique = $true }
                        continue
                    }
                    $f = [regex]::Match($l.text, '^([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z_][A-Za-z0-9_]*)(\([^)]*\))?(\[\])?(\?)?(\s+.*)?$')
                    if (-not $f.Success) { "line $($l.n): '$($l.raw)' is not a field (name Type, then attributes such as @id or @default(...))"; continue }
                    $fname = $f.Groups[1].Value; $ftype = $f.Groups[2].Value; $attrs = $f.Groups[6].Value
                    if ($fields.ContainsKey($fname)) { "line $($l.n): $($blk.name) has the field $fname twice (also at line $($fields[$fname]))" } else { $fields[$fname] = $l.n }
                    if ($f.Groups[4].Success -and $f.Groups[5].Success) { "line $($l.n): $fname is an optional list ($ftype[]?); Prisma has no optional lists, use $ftype[]" }
                    if ($script:PrismaScalars -cnotcontains $ftype -and -not $models.ContainsKey($ftype) -and -not $enums.ContainsKey($ftype)) {
                        $close = @(@($script:PrismaScalars) + @($models.Keys) + @($enums.Keys) | Where-Object { $_.Length -ge 3 -and $_.Substring(0, 3) -ieq $ftype.Substring(0, [Math]::Min(3, $ftype.Length)) } | Select-Object -First 2)
                        "line $($l.n): $fname has the type $ftype, which is not a Prisma type, model or enum in this schema$(if ($close.Count) { " (did you mean $($close -join ' or ')?)" })"
                    }
                    foreach ($am in [regex]::Matches($attrs, '(?<![@\w])@([A-Za-z]+)')) {
                        if ($script:PrismaFieldAttrs -cnotcontains $am.Groups[1].Value) { "line $($l.n): @$($am.Groups[1].Value) is not a Prisma field attribute" }
                    }
                    if ($attrs -match '(?<![@\w])@(id|unique)\b') { $unique = $true }
                    if ($models.ContainsKey($ftype) -and $blk.kind -eq 'model') { $relations.Add(@{ n = $l.n; field = $fname; target = $ftype; attrs = $attrs }) }
                }
                if ($blk.kind -eq 'model' -and -not $unique -and $blk.body.Count) { "line $($blk.line): model $($blk.name) has no @id, @@id, @unique or @@unique; Prisma needs one to tell its rows apart" }
                foreach ($r in $relations) {
                    $target = $models[$r.target]
                    $rel = [regex]::Match($r.attrs, '@relation\(([^)]*\[[^\]]*\][^)]*|[^)]*)\)')
                    if ($rel.Success) {
                        $fm = [regex]::Match($rel.Groups[1].Value, 'fields\s*:\s*\[([^\]]*)\]')
                        $rm = [regex]::Match($rel.Groups[1].Value, 'references\s*:\s*\[([^\]]*)\]')
                        $own = @(if ($fm.Success) { $fm.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
                        $refs = @(if ($rm.Success) { $rm.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
                        foreach ($x in $own) { if (-not $fields.ContainsKey($x)) { "line $($r.n): @relation fields: [$x] names a field that $($blk.name) does not have" } }
                        $targetFields = @($target.body | ForEach-Object { ([regex]::Match($_.text, '^([A-Za-z_][A-Za-z0-9_]*)\s')).Groups[1].Value })
                        foreach ($x in $refs) { if ($targetFields -cnotcontains $x) { "line $($r.n): @relation references: [$x] names a field that $($r.target) does not have" } }
                        if ($fm.Success -xor $rm.Success) { "line $($r.n): @relation needs both fields: [...] and references: [...]" }
                        elseif ($own.Count -ne $refs.Count) { "line $($r.n): @relation has $($own.Count) field(s) but $($refs.Count) reference(s)" }
                    }
                    if ($r.target -ne $blk.name) {
                        $back = @($target.body | Where-Object { $_.text -cmatch ('^[A-Za-z_][A-Za-z0-9_]*\s+' + [regex]::Escape($blk.name) + '(\[\])?\??(\s|$)') })
                        if (-not $back.Count) { "line $($r.n): the relation $($r.field) to $($r.target) has no field pointing back in $($r.target) (add a field of type $($blk.name) or $($blk.name)[] there)" }
                    }
                }
            }
        }
    }
}

function Test-PrismaEnv([string]$Text, [string]$Path, [string]$ProjectRoot) {
    <# A schema's datasource against the project: env("NAME") must be set in a .env file (next to the
       schema or at the project root) or in Windows' environment, and a datasource needs a url unless
       a prisma.config file holds it. Only names are read from .env, never the values. #>
    if (-not $ProjectRoot) { return }
    $schemaDir = Split-Path (Join-Path $ProjectRoot $Path.Replace('/', '\'))
    $names = @{}
    foreach ($dir in @($schemaDir, (Split-Path $schemaDir), $ProjectRoot) | Select-Object -Unique) {
        $f = Join-Path $dir '.env'
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        foreach ($l in [IO.File]::ReadAllLines($f)) { $m = [regex]::Match($l, '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*='); if ($m.Success) { $names[$m.Groups[1].Value] = $true } }
    }
    $hasConfig = @(Get-ChildItem -LiteralPath $ProjectRoot -Filter 'prisma.config.*' -File -ErrorAction SilentlyContinue).Count -gt 0
    $p = Get-PrismaBlocks $Text
    foreach ($blk in @($p.blocks | Where-Object { $_.kind -eq 'datasource' })) {
        $url = @($blk.body | Where-Object { $_.raw -match '^url\s*=' })
        if (-not $url.Count -and -not $hasConfig) { "line $($blk.line): datasource $($blk.name) has no url (url = env(`"DATABASE_URL`") with DATABASE_URL in .env)" }
        foreach ($l in $blk.body) {
            foreach ($m in [regex]::Matches($l.raw, 'env\(\s*"([^"]+)"\s*\)')) {
                $n = $m.Groups[1].Value
                if (-not $names.ContainsKey($n) -and -not [Environment]::GetEnvironmentVariable($n)) {
                    "line $($l.n): env(`"$n`") is not set: add $n=... to the project's .env file (Prisma reads it from there)"
                }
            }
        }
    }
}

function Find-PrismaCli([string]$ProjectRoot, [string]$Path) {
    # The project's own Prisma (node_modules\.bin\prisma.cmd), from the schema's folder up to the
    # project root; never npx, which could download it.
    $dir = Split-Path (Join-Path $ProjectRoot $Path.Replace('/', '\'))
    $root = $ProjectRoot.TrimEnd('\')
    while ($dir -and $dir.Length -ge $root.Length) {
        $exe = Join-Path $dir 'node_modules\.bin\prisma.cmd'
        if (Test-Path -LiteralPath $exe -PathType Leaf) { return @{ exe = $exe; dir = $dir } }
        $dir = Split-Path -Parent $dir
    }
    $null
}

function ConvertFrom-PrismaValidate([string]$Output, [string]$Path) {
    <# "line N: prisma says: ..." from prisma validate's output: each "error: ..." with the line of
       its "-->  FILE:LINE". Messages about Prisma itself (its engines missing) are not schema problems. #>
    if ($Output -match '(?i)Failed to fetch|engine|ENOENT|Cannot find module|not recognized') { if ($Output -notmatch '(?m)^error: ') { return } }
    $lines = $Output.Replace("`r`n", "`n").Split("`n")
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $m = [regex]::Match($lines[$i], '^error:\s*(.+)$')
        if (-not $m.Success) { continue }
        $at = ''
        for ($k = $i + 1; $k -lt [Math]::Min($lines.Length, $i + 4); $k++) { $lm = [regex]::Match($lines[$k], '-->\s+.*?:(\d+)\s*$'); if ($lm.Success) { $at = $lm.Groups[1].Value; break } }
        "$(if ($at) { "line ${at}: " })prisma says: $($m.Groups[1].Value.Trim())"
    }
}

function Test-PrismaValidate([string]$ProjectRoot, [string]$Path) {
    <# prisma validate on the schema as it is on disk, when the project has Prisma installed
       (setting checks.tools). Offline, asks nothing; at most 60 seconds. #>
    if (-not $ProjectRoot -or -not (Test-CheckSwitch 'tools')) { return }
    $cli = Find-PrismaCli $ProjectRoot $Path
    if (-not $cli) { return }
    $full = Join-Path $ProjectRoot $Path.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:ComSpec"
    $psi.Arguments = '/d /s /c ""' + $cli.exe + '" validate --schema "' + $full + '" 2>&1"'
    $psi.WorkingDirectory = $cli.dir
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardInput = $true; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['NO_COLOR'] = '1'
    try {
        $proc = [Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Close()
        $read = $proc.StandardOutput.ReadToEndAsync()
        if (-not $proc.WaitForExit(60000)) { try { $proc.Kill() } catch { }; return }
        $out = $read.Result
        if ($proc.ExitCode -eq 0) { return }
        ConvertFrom-PrismaValidate $out $Path
    } catch { }
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

$script:CodeExt = '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte|cs|java|kt|kts|go|rs|php|swift|dart|scala|c|cc|cpp|h|hpp|py|pyw|ps1|psm1|psd1|css|scss|less|json|ya?ml|toml|ini|sh|bash|cmd|bat|sql|html?|xml|csproj|config|xaml|svg|prisma)$'
# Program code where a repeated block or a second definition is a mistake (not data or markup).
$script:ProgramExt = '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|cs|java|kt|go|rs|php|swift|dart|c|cc|cpp|h|hpp|py|pyw|ps1|psm1|sh|bash)$'

# A line that is only data: "key": value, a quoted or numeric entry, true/false/null, or brackets
# (JSON records, object and array literals, tables), optionally with a window.NAME = / const NAME =
# start. Used to leave repeated data out of the duplicate check.
$script:DataLine = '^(?:(?:window\.|(?:var|let|const)\s+)?[\w$.]+\s*=\s*)?(?:[\[\]{}(),;\s]|(?:"[^"]*"|''[^'']*''|[\w$]+)\s*:|"[^"]*"|''[^'']*''|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:true|false|null|undefined|None|True|False)\b)*$'

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
        $part = @($code[$i..($i + 7)] | ForEach-Object { $_.t })
        # Data repeats by nature (JSON records in a data copy, object and array literals, tables):
        # 8 lines that are all data are no sign of code added twice.
        if (@($part | Where-Object { $_ -notmatch $script:DataLine }).Count -eq 0) { continue }
        $key = $part -join "`n"
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


function Get-CodeMask {
    <# The text with strings and comments blanked (same length, line breaks kept) for the file's
       language, so a rule or a fix touches code only. $null for files without a known mask. #>
    param([string]$Path, [string]$Text)
    if ($Path -match '(?i)\.(m?js|cjs|jsx|ts|mts|cts|tsx)$') { return (Get-JsMask $Text).masked }
    if ($Path -match '(?i)\.pyw?$') { return Hide $Text $script:MaskPython }
    if ($Path -match '(?i)\.ps[md]?1$') { return Hide $Text '@''[\s\S]*?\n''@|@"[\s\S]*?\n"@|"(?:[^"`\n]|`.)*"|''[^''\n]*''|<#[\s\S]*?#>|#[^\n]*' }
    if ($Path -match '(?i)\.(css|scss|less)$') { return Hide $Text $script:MaskCss }
    $null
}

function Find-GeneratedCodeIssues {
    <# Mistakes typical of generated code that break a file, beyond its syntax rules: characters a
       chat answer brings along (typographic quotes, non-breaking and zero-width spaces, citation
       markers, HTML entities, a chat sentence as the first line, a whole file of escaped line
       breaks), and per language what the code is not allowed to be (TypeScript in .js, imports in
       functions, ES modules mixed with CommonJS, Python 2 print, PowerShell 7 in a 5.1 script,
       // comments and SCSS in CSS, single % in a batch for loop). Only outside strings and comments
       where the language allows that to be told apart. Non-ASCII characters are written as \u. #>
    param([string]$Path, [string]$Text)
    if ($Path -notmatch $script:CodeExt -or $Path -match '(?i)\.(md|markdown|txt|html?|xml|svg|json|jsonc|ya?ml|toml|csv|tsv)$') { return }
    if (-not (Test-CheckSwitch 'generated')) { return }   # setting checks.generated
    $js = $Path -match '(?i)\.(m?js|cjs|jsx|ts|mts|cts|tsx)$'
    $py = $Path -match '(?i)\.pyw?$'
    $ps = $Path -match '(?i)\.ps[md]?1$'
    $masked = if ($js) { (Get-JsMask $Text).masked } elseif ($py) { Hide $Text $script:MaskPython } elseif ($ps) { Hide $Text '@''[\s\S]*?\n''@|@"[\s\S]*?\n"@|"(?:[^"`\n]|`.)*"|''[^''\n]*''|<#[\s\S]*?#>|#[^\n]*' } elseif ($Path -match '(?i)\.(css|scss|less)$') { Hide $Text $script:MaskCss } else { $Text }
    $first = { param($m, $msg) if ($m.Success) { "line $(LineAt $Text $m.Index): $msg" } }

    # What a chat answer brings along.
    & $first ([regex]::Match($masked, '[=(,\[:+]\s*[\u201C\u201D\u2018\u2019]|[\u201C\u201D\u2018\u2019]\s*[);,\]]')) 'typographic quotes (curly quotes) used as code quotes: write straight quotes " and '''
    & $first ([regex]::Match($masked, '[\u00A0\u200B\u200C\u200D\u2060]|(?!\A)\uFEFF')) 'a non-breaking or zero-width space in the code (from a chat answer): replace it with a normal space or remove it'
    # In the code itself: a marker inside a string or a comment does not break anything.
    & $first ([regex]::Match($masked, '\u3010[^\u3011\n]{0,40}\u2020|:contentReference\[oaicite|\bturn\d+(search|view|file)\d+\b|\[\d{1,2}\]\(https?://')) 'a citation marker from the chat answer is in the code: remove it'
    if ($Path -notmatch '(?i)\.(jsx|tsx|vue|svelte)$') { & $first ([regex]::Match($masked, '&amp;&amp;|&quot;|&#39;|&amp;(?=\s)|\s&lt;=?\s|\s&gt;=?\s')) 'HTML entities in the code (&amp; &quot; &lt;): write the characters themselves' }
    $lead = [regex]::Match($Text, '\A\s*([^\n]*)')
    if ($lead.Groups[1].Value -match '^(Here is|Here''s|Below is|Sure[,!]|Certainly|Of course|I''ve|I have|The (updated|following|corrected|complete) )') { 'line 1: the file starts with a sentence from the chat answer instead of code' }
    $lines = $Text.Split("`n").Count
    if ($lines -le 2 -and $Text.Length -gt 200 -and ([regex]::Matches($Text, '\\n')).Count -ge 5) { 'the whole file is on one line with \n written out: write real line breaks' }

    if ($js) {
        if ($Path -match '(?i)\.(m?js|cjs|jsx)$') {
            & $first ([regex]::Match($masked, '(?m)^\s*(export\s+)?(interface|type)\s+[A-Za-z_]\w*\s*(<[^>\n]*>)?\s*[={]|\bfunction\s*\w*\s*\([^)\n]*\w\s*:\s*(string|number|boolean|any|unknown|void)\b|\)\s*:\s*(string|number|boolean|any|unknown|void|Promise<)|\sas\s+(const|string|number|any|unknown)\b|(?m)^\s*(private|public|protected|readonly)\s+\w')) 'TypeScript syntax in a JavaScript file: remove the types, or make it a .ts file'
        }
        & $first ([regex]::Match($masked, '(?m)^[ \t]+import\s+(?:[\w*{][^;\n]*\sfrom\s|["''])')) 'an import inside a block or function: imports go at the top level of the file (or use await import())'
        if ($masked -match '(?m)^\s*(import\s+[\w*{]|export\s+(default|const|function|class|\{))' -and $masked -match '\bmodule\.exports\b|(?m)^\s*exports\.\w+\s*=') { 'the file mixes ES modules (import/export) with CommonJS (module.exports): use one of the two' }
        $defaults = [regex]::Matches($masked, '(?m)^\s*export\s+default\b')
        if ($defaults.Count -gt 1) { "line $(LineAt $Text $defaults[1].Index): a second export default (a file has one)" }
        $seen = @{}
        foreach ($d in [regex]::Matches($masked, '(?m)^(?:export\s+)?(?:const|let|class)\s+([A-Za-z_$][\w$]*)')) {
            $n = $d.Groups[1].Value
            if ($seen.ContainsKey($n)) { "line $(LineAt $Text $d.Index): '$n' is declared a second time at the top level (line $($seen[$n])): JavaScript stops with a SyntaxError"; break }
            $seen[$n] = LineAt $Text $d.Index
        }
    }
    if ($py) {
        # On the code with comments blanked (not strings: print 'x' is the statement to find).
        & $first ([regex]::Match((Hide $Text '#[^\n]*'), '(?m)^\s*print[ \t]+(?![=(])\S')) 'Python 2 print statement: write print(...)'
        & $first ([regex]::Match($Text, '(?m)\b[rRbB]?[fF]"[^"\n]*\{[^}"\n]*"[^"\n]*"[^}\n]*\}')) 'the same quotes inside an f-string expression only work from Python 3.12: use the other quote type inside the braces'
    }
    if ($ps -and (Test-CheckSwitch 'powershell7') -and $Text -notmatch '(?im)^\s*#requires\s+.*(-version\s+[6-9]|-psedition\s+core)') {
        # Command names only when the script does not define a function of that name itself.
        $own = @([regex]::Matches($Text, '(?im)^\s*function\s+([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
        $names = @('Join-String', 'Get-Error', 'Test-Json', 'ConvertFrom-Markdown', 'Get-Uptime' | Where-Object { $own -notcontains $_ })
        $cmd = if ($names.Count) { '|\b(' + ($names -join '|') + ')\b' } else { '' }
        $m7 = [regex]::Match($masked, '(?i)ConvertFrom-Json\b[^\n|;]*-AsHashtable|ForEach-Object\s+[^\n|;]*-Parallel\b' + $cmd + '|Invoke-(RestMethod|WebRequest)\b[^\n|;]*-(SkipCertificateCheck|Authentication|StatusCodeVariable|ResponseHeadersVariable)\b|Get-Content\b[^\n|;]*-AsByteStream')
        & $first $m7 'PowerShell 7 only (Windows PowerShell 5.1 does not have it): use a 5.1 way, or add #Requires -Version 7'
    }
    if ($Path -match '(?i)\.css$') {
        & $first ([regex]::Match($masked, '(?m)(?<![:\w/])//[^\n]*')) '// is not a comment in CSS (the next rule is skipped): use /* */'
        & $first ([regex]::Match($masked, '(?m)^\s*\$[\w-]+\s*:|@(mixin|include|extend)\b')) 'SCSS syntax ($variables, @mixin, @include) in a .css file: use CSS variables (--name) or make it .scss'
    }
    if ($Path -match '(?i)\.(cmd|bat)$') {
        & $first ([regex]::Match($Text, '(?im)^(?!\s*(rem\b|::)).*\bfor\b[^\n]*?\s%[a-z]\s+in\b')) 'a for loop variable in a batch file needs %% (%%i, not %i)'
        if ($Text -match '![A-Za-z_]\w*!' -and $Text -notmatch '(?i)enabledelayedexpansion') { & $first ([regex]::Match($Text, '![A-Za-z_]\w*!')) '!name! needs setlocal enabledelayedexpansion' }
    }
}

function Find-LanguagePitfalls {
    <# Mistakes that pass a syntax check but break at run time, seen in real work: control characters
       where a backslash was lost (\t, \v in a path or string), mixed line endings, and Windows
       PowerShell 5.1 traps (a program's arguments losing their inner double quotes, stderr becoming
       an error under ErrorActionPreference Stop, a JSON array arriving as one object, a parameter
       overwritten by a variable that differs only in case, automatic variables used as names), and
       a member declared twice in a TypeScript interface. #>
    param([string]$Path, [string]$Text, [bool]$Mixed = $false)   # $Mixed: the original text has both CRLF and LF
    if ($Path -notmatch $script:CodeExt -or $Path -match '(?i)\.(md|markdown|txt|csv|tsv)$') { return }
    if (-not (Test-CheckSwitch 'generated')) { return }
    $first = { param($m, $msg) if ($m.Success) { "line $(LineAt $Text $m.Index): $msg" } }
    # A control character (not tab or line break) in code: almost always a lost backslash.
    & $first ([regex]::Match($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F]')) 'a control character in the file (often a backslash that got lost, like \v or \f in a path): write the backslash again'
    # A tab right after a backslash path part inside quotes: \t was read as a tab.
    & $first ([regex]::Match($Text, '(?m)[A-Za-z]:\\[^''"\n]*\t[^''"\n]*[''"]')) 'a tab inside a Windows path (\t was read as a tab): write \\t, or use / or a raw string'
    if ($Mixed) { 'the file mixes CRLF and LF line endings: use one kind' }

    if ($Path -match '(?i)\.ps[md]?1$') {
        $tok = $null; $errs = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$errs)
        if (@($errs).Count) { return }   # the syntax check reports it already
        # Inner double quotes in an argument to a program: Windows PowerShell 5.1 drops them.
        foreach ($c in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))) {
            # Named programs only (cmd /c "..." is the safe way to pass quotes, so cmd is left alone).
            $name = "$($c.GetCommandName())"
            if ($name -notmatch '(?i)^(python|py|node|npm|npx|dotnet|git|powershell|pwsh|java|curl)(\.exe)?$') { continue }
            foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
                $s = $e.Extent.Text
                if (($s.StartsWith("'") -and $s.Contains('"')) -or ($s.StartsWith('"') -and $s -match '`"')) {
                    "line $($e.Extent.StartLineNumber): this argument to $name holds double quotes, which Windows PowerShell 5.1 drops when it starts a program: avoid inner double quotes (pass a file, or use single quotes inside)"
                    break
                }
            }
        }
        # Stop on errors plus a program's output captured with 2>&1: its stderr becomes an error.
        if ($Text -match '(?im)^\s*\$ErrorActionPreference\s*=\s*[''"]?Stop') {
            # Not when the preference is lowered on that line or just before it.
            foreach ($m in [regex]::Matches($Text, '(?m)^[^#\n]*&\s*(\$[\w.]+|[''"][^''"\n]+\.exe[''"]|\w+\.exe)[^\n#]*2>&1')) {
                $start = [Math]::Max(0, $Text.LastIndexOf("`n", [Math]::Max(0, $m.Index - 1)))
                $start = [Math]::Max(0, $Text.LastIndexOf("`n", [Math]::Max(0, $start - 1)))
                $context = $Text.Substring($start, $m.Index + $m.Length - $start)
                if ($context -match '(?i)\$ErrorActionPreference\s*=\s*[''"]?(Continue|SilentlyContinue)') { continue }
                "line $(LineAt $Text $m.Index): with `$ErrorActionPreference = Stop a program writing to stderr stops the script here: run it through cmd /c `"... 2>&1`" or lower the preference around it"
                break
            }
        }
        # Text files without -Encoding: 5.1 writes ANSI (Set-Content, Add-Content, Export-Csv) or
        # UTF-16 (Out-File), and reads a UTF-8 file without a BOM as ANSI (Get-Content, Import-Csv),
        # so an en dash or an accented letter comes out broken. Reads only in a script that writes a
        # page, script, style or data file (a build script); not when the script sets a default.
        # Scripts only for reads (a module or a test is no build script); tests not at all.
        if ($Path -notmatch '(?i)\.Tests\.ps1$' -and $Text -notmatch '(?i)\$PSDefaultParameterValues\s*\[\s*[''"]\*:Encoding') {
            $writesWeb = $Path -match '(?i)\.ps1$' -and $Text -match '(?i)\b(Set-Content|Out-File|Add-Content|WriteAllText|WriteAllLines|Export-Csv)\b' -and $Text -match '(?i)\.(html?|js|css|csv)\b'
            foreach ($c in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and "$($n.GetCommandName())" -match '(?i)^(Get-Content|Set-Content|Add-Content|Out-File|Export-Csv|Import-Csv)$' }, $true))) {
                $name = "$($c.GetCommandName())"
                if (@($c.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '(?i)^(En|AsByte)' }).Count) { continue }
                $reads = $name -match '(?i)^(Get-Content|Import-Csv)$'
                if ($reads -and -not $writesWeb) { continue }
                if ($name -ieq 'Get-Content' -and @($c.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '(?i)^(TotalCount|Head|First|Tail)$' }).Count) { continue }
                $what = if ($reads) { 'reads a UTF-8 file without a BOM as ANSI' } elseif ($name -ieq 'Out-File') { 'writes UTF-16' } else { 'writes ANSI' }
                "line $($c.Extent.StartLineNumber): $name without -Encoding: Windows PowerShell 5.1 $what, so characters like an en dash or an accented letter come out broken (shown as text like '14" + [char]0xE2 + [char]0x20AC + [char]0x201C + "27'): add -Encoding UTF8"
                break
            }
        }
        # String.Replace with a text and a single character: no such overload, it fails at run time.
        & $first ([regex]::Match($Text, '(?i)\.Replace\(\s*(''[^''\n]{2,}''|"[^"\n]{2,}")\s*,\s*\[char\]|\.Replace\(\s*\[char\][^,\n]+,\s*(''[^''\n]{2,}''|"[^"\n]{2,}")')) 'String.Replace takes two texts or two single characters, not a text and a [char] (Windows PowerShell stops there with "Cannot convert argument"): write [string][char]60, or the character itself'
        # A JSON array from ConvertFrom-Json is one object in 5.1 unless the call is in parentheses.
        & $first ([regex]::Match($Text, '@\((?!\()[^()\n]*\|\s*ConvertFrom-Json\s*\)\s*\|')) 'in Windows PowerShell 5.1 a JSON array arrives as one object here: put the call in parentheses, @((... | ConvertFrom-Json)) | ...'
        # A parameter overwritten by a variable that only differs in case (names ignore case).
        foreach ($fn in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            $params = @()
            if ($fn.Parameters) { $params += @($fn.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
            if ($fn.Body.ParamBlock) { $params += @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
            if (-not $params.Count) { continue }
            # All of the function's parameter names, so the new name does not collide with another one.
            $taken = ", not one of the parameters of $($fn.Name): " + (@($params | ForEach-Object { '$' + $_ }) -join ', ')
            foreach ($a in @($fn.Body.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true))) {
                if ($a.Left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
                $v = $a.Left.VariablePath.UserPath
                # Reworking the parameter itself ($changed = @($Changed | ...)) is deliberate; an
                # unrelated value that lands on it is the mistake.
                $hit = @($params | Where-Object { $_ -ieq $v -and $_ -cne $v -and $a.Right.Extent.Text -notmatch ('(?i)\$' + [regex]::Escape($_) + '\b') })
                if ($hit.Count) { "line $($a.Extent.StartLineNumber): `$$v overwrites the parameter `$$($hit[0]) (variable names ignore case): use another name$taken"; break }
            }
            # The same for a foreach loop variable: foreach ($to in ...) changes the parameter $To.
            $loop = @($fn.Body.FindAll({ param($n) $n -is [Management.Automation.Language.ForEachStatementAst] }, $true) | Where-Object {
                    $lv = $_.Variable.VariablePath.UserPath; @($params | Where-Object { $_ -ieq $lv -and $_ -cne $lv }).Count }) | Select-Object -First 1
            if ($loop) { $lv = $loop.Variable.VariablePath.UserPath; "line $($loop.Extent.StartLineNumber): the loop variable `$$lv overwrites the parameter `$$(@($params | Where-Object { $_ -ieq $lv })[0]) (variable names ignore case): use another name$taken" }
        }
        # $Matches after a -match whose result nobody checks (a statement of its own, or $null = ...):
        # when it does not match, $Matches still holds the previous match (in a switch -Regex the
        # switch's own), so the code goes on with old values.
        $loose = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.BinaryExpressionAst] -and "$($n.Operator)" -match '^(I|C)?Match$' -and
                    $n.Parent -is [Management.Automation.Language.CommandExpressionAst] -and (
                        ($n.Parent.Parent -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent.Left.Extent.Text -ieq '$null') -or
                        ($n.Parent.Parent -is [Management.Automation.Language.PipelineAst] -and @($n.Parent.Parent.PipelineElements).Count -eq 1 -and
                         ($n.Parent.Parent.Parent -is [Management.Automation.Language.StatementBlockAst] -or $n.Parent.Parent.Parent -is [Management.Automation.Language.NamedBlockAst]))) }, $true))
        foreach ($lm in $loose) {
            $stmt = $lm.Parent.Parent
            $block = $stmt.Parent
            $read = @($block.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ieq 'Matches' -and $n.Extent.StartOffset -gt $stmt.Extent.EndOffset }, $true)) | Select-Object -First 1
            if ($read) { "line $($read.Extent.StartLineNumber): `$Matches after the -match on line $($lm.Extent.StartLineNumber), whose result is not checked: when it does not match, `$Matches still holds an older match. Use if (TEXT -match 'PATTERN') { ... } or ([regex]'PATTERN').Match(TEXT)"; break }
        }
        # return , $list keeps a list as one item; @(Name ...) around the call then makes a list inside a list.
        $commaFns = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object {
                @($_.Body.FindAll({ param($n) (($n -is [Management.Automation.Language.UnaryExpressionAst] -and "$($n.TokenKind)" -eq 'Comma') -or ($n -is [Management.Automation.Language.ArrayLiteralAst] -and $n.Extent.Text -match '^,')) -and ($n.Parent.Parent -is [Management.Automation.Language.PipelineAst]) -and (($n.Parent.Parent.Parent -is [Management.Automation.Language.ReturnStatementAst]) -or ($n.Parent.Parent.Parent -is [Management.Automation.Language.NamedBlockAst])) }, $true)).Count
            } | ForEach-Object { $_.Name })
        if ($commaFns.Count) {
            $wrapped = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ArrayExpressionAst] }, $true) | Where-Object {
                    $st = @($_.SubExpression.Statements)
                    $st.Count -eq 1 -and $st[0] -is [Management.Automation.Language.PipelineAst] -and $st[0].PipelineElements.Count -ge 1 -and
                    $st[0].PipelineElements[0] -is [Management.Automation.Language.CommandAst] -and $commaFns -contains $st[0].PipelineElements[0].GetCommandName()
                }) | Select-Object -First 1
            if ($wrapped) { $fnName = @($wrapped.SubExpression.Statements)[0].PipelineElements[0].GetCommandName(); "line $($wrapped.Extent.StartLineNumber): $fnName returns its list with a leading comma (one item), so @($fnName ...) here gives a list inside a list: return the list plainly, or drop the @()" }
        }
        # .Count on what may be a single [pscustomobject] (one CSV row, one JSON object, one Select-Object
        # result): Windows PowerShell 5.1 gives such an object no .Count.
        $made = '(?i)\b(Import-Csv|ConvertFrom-Csv|ConvertFrom-Json|Invoke-RestMethod|Select-Object\s+(?!-(First|Last|Skip|Unique|ExpandProperty|Index)\b)[-\w])|\[pscustomobject\]'
        $counted = $null
        foreach ($a in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Right -is [Management.Automation.Language.PipelineAst] }, $true))) {
            $head = @($a.Right.PipelineElements)[0]
            if ($head -is [Management.Automation.Language.CommandExpressionAst] -and $head.Expression -is [Management.Automation.Language.ArrayExpressionAst]) { continue }   # @(...) already
            if ($a.Right.Extent.Text -notmatch $made -or $a.Right.Extent.Text -match '^\s*\[pscustomobject\]\s*@\{') { continue }   # one object made on purpose
            $v = $a.Left.VariablePath.UserPath
            $scope = $a.Parent; while ($scope -and $scope -isnot [Management.Automation.Language.ScriptBlockAst]) { $scope = $scope.Parent }
            if (-not $scope) { continue }
            $use = @($scope.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $n.Expression.VariablePath.UserPath -ieq $v -and "$($n.Member)" -ieq 'Count' -and $n.Extent.StartOffset -gt $a.Extent.EndOffset }, $true)) | Select-Object -First 1
            if ($use) { $counted = @{ line = $use.Extent.StartLineNumber; v = $v; at = $a.Extent.StartLineNumber }; break }
        }
        if ($counted) { "line $($counted.line): `$$($counted.v).Count is empty in Windows PowerShell 5.1 when line $($counted.at) gives one object (one row or item has no .Count): assign @(...) there" }
        # A function named like a built-in cmdlet replaces it for the whole script (and for whoever imports it).
        if (-not $script:BuiltinCmdlets) {
            $script:BuiltinCmdlets = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            try { foreach ($c in @(Get-Command -CommandType Cmdlet -Module Microsoft.PowerShell.* -ErrorAction SilentlyContinue)) { [void]$script:BuiltinCmdlets.Add($c.Name) } } catch { }
        }
        $shadow = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $script:BuiltinCmdlets.Contains($_.Name) }) | Select-Object -First 1
        if ($shadow) { "line $($shadow.Extent.StartLineNumber): the function $($shadow.Name) has the same name as the built-in cmdlet and replaces it: use another name" }
        # a, b + c is (a, b) + c: the comma binds before + (an item meant as one string becomes several).
        $plus = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'Plus' -and $n.Left -is [Management.Automation.Language.ArrayLiteralAst] }, $true)) | Select-Object -First 1
        if ($plus) { "line $($plus.Extent.StartLineNumber): in a, b + c the comma binds first, so this adds to the whole list (a, b) instead of to the last item: put the last item in parentheses, a, (b + c)" }
        # Automatic variables used as names.
        $auto = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -match '^(?i)(args|input|matches|host|error|pid|home|this|PSItem|_)$' }, $true)) | Select-Object -First 1
        if ($auto) { "line $($auto.Extent.StartLineNumber): `$$($auto.Left.VariablePath.UserPath) is an automatic variable PowerShell sets itself: use another name" }
    }
    if ($Path -match '(?i)\.(ts|tsx|mts|cts)$') {
        # A member declared twice in one interface or object type.
        $masked = (Get-JsMask $Text).masked
        foreach ($blk in [regex]::Matches($masked, '(?:interface\s+\w+[^{]*|type\s+\w+\s*=\s*)\{([^{}]*)\}')) {
            $seen = @{}
            foreach ($mem in [regex]::Matches($blk.Groups[1].Value, '(?m)^\s*(?:readonly\s+)?([A-Za-z_$][\w$]*)\??\s*:')) {
                $n = $mem.Groups[1].Value
                if ($seen.ContainsKey($n)) { "line $(LineAt $Text ($blk.Groups[1].Index + $mem.Index)): '$n' is declared twice in this type: TypeScript reports a duplicate identifier"; break }
                $seen[$n] = $true
            }
        }
    }
}

function Get-RealTool([string]$Name) {
    # A tool on PATH (not the Store's python.exe stub), looked up once.
    if (-not $script:Tools) { $script:Tools = @{} }
    if (-not $script:Tools.ContainsKey($Name)) {
        $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
        $script:Tools[$Name] = if ($c) { $c.Source } else { '' }
    }
    $script:Tools[$Name]
}

function Test-ToolSyntax {
    <# The language's own syntax check, when its tool is installed: node --check for JavaScript,
       python -m py_compile for Python. "line N: ..." texts; nothing when the tool is missing. #>
    param([string]$Path, [AllowEmptyString()][string]$Text)
    $kind = if ($Path -match '(?i)\.(m?js|cjs)$') { 'node' } elseif ($Path -match '(?i)\.py$') { 'python' } else { return }
    if (-not (Test-CheckSwitch 'tools')) { return }   # setting checks.tools
    $exe = Get-RealTool $kind
    if (-not $exe) { return }
    $dir = Join-Path $env:TEMP ('streamhub-check-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $dir
    $file = Join-Path $dir ([IO.Path]::GetFileName($Path))
    try {
        [IO.File]::WriteAllText($file, $Text, (New-Object Text.UTF8Encoding($false)))
        # Through cmd /c: with ErrorActionPreference Stop, a program's stderr would become an error here.
        $args2 = if ($kind -eq 'node') { "--check `"$file`"" } else { "-m py_compile `"$file`"" }
        $out = cmd /c "`"$exe`" $args2 2>&1"
        if ($LASTEXITCODE -eq 0) { return }
        $all = (@($out) | ForEach-Object { "$_" }) -join "`n"
        if ($kind -eq 'node' -and $all -match 'Cannot use import statement|import\.meta|Unexpected token .?export') { return }   # a module read as CommonJS: not a syntax error
        $line = if ($all -match ':(\d+)\r?\n' -or $all -match 'line (\d+)') { $Matches[1] } else { '' }
        $msg = @($all.Split("`n") | Where-Object { $_ -match '(SyntaxError|IndentationError|TabError)' }) | Select-Object -First 1
        if (-not $msg) { $msg = @($all.Split("`n") | Where-Object { $_.Trim() }) | Select-Object -Last 1 }
        $msg = "$msg".Trim() -replace [regex]::Escape($file), $Path
        "$(if ($line) { "line ${line}: " })$kind says: $msg"
    } catch { } finally { try { [IO.Directory]::Delete($dir, $true) } catch { } }
}

# Text that was UTF-8 but was read as Windows-1252 somewhere ("14\u00e2\u20ac\u201c27 days" for an en
# dash, \u00c3\u00a9 for e acute): a UTF-8 lead byte as a Latin-1 letter, then its continuation
# bytes as Windows-1252 characters. A sequence counts only when its bytes are valid UTF-8 again.
$script:MojibakeTail = '[\u0080-\u00BF\u0152\u0153\u0160\u0161\u0178\u017D\u017E\u0192\u02C6\u02DC\u2013\u2014\u2018-\u201A\u201C-\u201E\u2020-\u2022\u2026\u2030\u2039\u203A\u20AC\u2122]'
$script:MojibakeSeq = "[\u00C2-\u00DF]$($script:MojibakeTail)|[\u00E0-\u00EF]$($script:MojibakeTail){2}|[\u00F0-\u00F4]$($script:MojibakeTail){3}"
$script:Cp1252 = [Text.Encoding]::GetEncoding(1252, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
$script:StrictUtf8 = New-Object Text.UTF8Encoding($false, $true)

function ConvertFrom-Mojibake([string]$Text) {
    <# The text the sequence was before it was read as Windows-1252, or $null when it is not such a
       sequence (bytes that are not valid UTF-8, or a two-byte character outside Latin, Greek and
       Cyrillic, which real text next to a symbol can produce). #>
    try { $s = $script:StrictUtf8.GetString($script:Cp1252.GetBytes($Text)) } catch { return $null }
    if ($s.Length -eq 1 -and $Text.Length -eq 2) {
        $c = [int]$s[0]
        if (-not (($c -ge 0xA0 -and $c -le 0x17F) -or ($c -ge 0x370 -and $c -le 0x4FF))) { return $null }
    }
    $s
}

function Find-BrokenEncoding {
    <# Broken characters in a text file: @{ index; length; text; fixed } per sequence (runs of them
       together, e.g. a word of accented letters). #>
    param([string]$Text)
    foreach ($m in [regex]::Matches($Text, "(?:$($script:MojibakeSeq))+")) {
        $fixed = ConvertFrom-Mojibake $m.Value
        if ($null -ne $fixed) { [pscustomobject]@{ index = $m.Index; length = $m.Length; text = $m.Value; fixed = $fixed } }
    }
}

# Tags written with a stand-in for < or > (a workaround a chat answer sometimes invents) or escaped:
# the browser shows them as text.
$script:StandInPattern = '(\[\[|\{\{|__)(LT|GT)(\]\]|\}\}|__)'
$script:EscapedPagePattern = '(?im)^\s*&lt;(!doctype|html|head|body|main|div|section|header|script|style|table)\b'

function Find-PlaceholderMarkup {
    <# A page (or markup a script writes) whose tags are stand-ins ([[LT]] and [[GT]] around a tag name) or escaped
       (&lt;html&gt; with no real tag in the file): "line N: ..." or nothing. #>
    param([string]$Path, [string]$Text)
    # A script that writes a page with stand-ins for its tags (a generator kept next to the page): the
    # page drifts from it and every change goes through the stand-ins.
    if ($Path -match '(?i)\.(ps[md]?1|py|m?js|cjs|ts|rb|php|cmd|bat|sh)$') {
        if ($Path -match '(?i)\.Tests\.ps1$|(^|[\\/])test_[^\\/]+\.py$|\.(test|spec)\.[cm]?[jt]s$') { return }   # tests hold such text on purpose
        $g = [regex]::Match($Text, '(\[\[|\{\{|__)LT(\]\]|\}\}|__)/?[!a-zA-Z]')
        if ($g.Success) { return "line $(LineAt $Text $g.Index): this script writes markup with the stand-in $($g.Groups[1].Value)LT$($g.Groups[2].Value) for <: write the page itself with a write or edit action (the helper program keeps < and > as they are) and delete this script, so the page and its generator cannot drift apart" }
        return
    }
    if ($Path -notmatch '(?i)\.(html?|xhtml|svg|xml|vue|svelte)$') { return }
    $m = [regex]::Match($Text, $script:StandInPattern)
    if ($m.Success) { return "line $(LineAt $Text $m.Index): the page's tags are written with the stand-in $($m.Value) instead of < or >, so the browser shows them as text: write < and > themselves in a write action (the helper program keeps them as they are), never through a script that swaps stand-ins" }
    $e = [regex]::Match($Text, $script:EscapedPagePattern)
    if ($e.Success -and $Text -notmatch '<(!doctype|[a-zA-Z][\w-]*)[\s>/]') { return "line $(LineAt $Text $e.Index): the page's tags are escaped ($($e.Value.Trim())...), so the browser shows them as text: write the tags themselves" }
}

function Test-TextEncoding {
    <# File problems with characters: text broken by a wrong encoding (any text file), and a web
       page without <meta charset="utf-8"> in its first 1024 bytes (Edge then reads a page opened
       from disk, and the scripts it loads, as Windows-1252). #>
    param([string]$Path, [string]$Text)
    if ($Path -notmatch '(?i)\.(html?|xhtml|m?js|cjs|jsx|tsx?|vue|svelte|css|scss|less|json|jsonc|csv|tsv|md|markdown|txt|xml|svg|ya?ml|py|ps[md]?1|cs|java|go|php|rb|sql)$') { return }
    $hits = @(Find-BrokenEncoding $Text)
    if ($hits.Count) {
        $h = $hits[0]
        $more = if ($hits.Count -gt 1) { " ($($hits.Count) places)" } else { '' }
        "line $(LineAt $Text $h.index): broken characters '$($h.text)' (UTF-8 text that was read as Windows-1252), which should be '$($h.fixed)'$more; write the real characters and keep the file UTF-8"
    }
    if ($Path -match '(?i)\.html?$' -and $Text -match '(?i)<(!doctype\s+html|html[\s>]|head[\s>])') {
        $head = if ($Text.Length -gt 1024) { $Text.Substring(0, 1024) } else { $Text }
        $cs = [regex]::Match($head, '(?i)<meta\b[^>]*\bcharset\s*=\s*["'']?([\w-]+)')
        if (-not $cs.Success) { 'the page has no <meta charset="utf-8"> at the top of <head>: opened from disk, Edge reads it and its scripts as Windows-1252 and shows characters like an en dash as broken text; put it first in <head>' }
        elseif ($cs.Groups[1].Value -notmatch '(?i)^utf-?8$') { "line $(LineAt $Text $cs.Index): the page says charset=$($cs.Groups[1].Value), but its files are UTF-8: write <meta charset=""utf-8"">" }
    }
}

function Test-FileContent {
    <# The problems in a file's text, by its type: "line N: problem" (or a whole-file problem).
       Also for every code file: leftover edit or merge markers and ``` fence lines. #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text, [bool]$Crlf = $false)
    # A one-file page: the UI kit and data blocks the helper program writes are not the page's own code.
    if ($Path -match '(?i)\.html?$') { $Text = Hide-GeneratedBlocks $Text }
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
        '(?i)\.prisma$' { & $add (Test-Prisma $t); break }
        '(?i)\.(csv|tsv)$' { & $add (Test-Csv $t $Path); break }
    }
    # A whole tag written escaped inside JavaScript (a .js file or a page's <script>): the page shows it as text.
    $esc = @(Find-EscapedScriptTags $Path $t)
    if ($esc.Count) { & $add "line $(LineAt $t $esc[0].index): $($esc.Count) HTML tag(s) written escaped in a script ($($esc[0].text.Substring(0, [Math]::Min(40, $esc[0].text.Length)))): in JavaScript that stays text, so the page shows the tag instead of making it; write < and >" }
    & $add (Test-Duplicates $t $Path)
    & $add (Test-TextEncoding $Path $t)
    & $add (Find-PlaceholderMarkup $Path $t)
    & $add (Find-GeneratedCodeIssues $Path $t)
    & $add (Find-LanguagePitfalls $Path $t ($Text.Contains("`r`n") -and [regex]::IsMatch($Text, '(?<!\r)\n')))
    $issues.ToArray()
}

$script:LibVarPrefix = '^(tw|bs|chakra|mantine|radix|ion|mdc|md|fa|swiper|plyr|toastify|rdp|rt|ag|mui|joy|spectrum|sl|fui|p|pf|amplify)-'
$script:CssDefsCache = @{ root = ''; at = [datetime]::MinValue; names = $null }

function Get-ProjectCssVarNames([string]$ProjectRoot) {
    <# Every custom property the project defines (--name: in stylesheets and pages, setProperty and
       style objects in code); cached for 15 seconds. #>
    $c = $script:CssDefsCache
    if ($c.root -eq $ProjectRoot -and $c.names -and ((Get-Date) - $c.at).TotalSeconds -lt 15) { return $c.names }
    $names = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Include *.css, *.scss, *.less, *.html, *.htm, *.js, *.mjs, *.jsx, *.ts, *.tsx, *.vue, *.svelte -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build|\.git|\.streamhub)\\' -and $_.Length -lt 2MB } | Select-Object -First 3000)) {
        $t = try { [IO.File]::ReadAllText($f.FullName) } catch { '' }
        if ($t -notmatch '--') { continue }
        foreach ($m in [regex]::Matches($t, '(?<![\w-])--([A-Za-z0-9_-]+)\s*:|setProperty\(\s*[''"`]--([A-Za-z0-9_-]+)|[''"`]--([A-Za-z0-9_-]+)[''"`]\s*[:\]]')) {
            foreach ($g in 1..3) { if ($m.Groups[$g].Success) { [void]$names.Add($m.Groups[$g].Value) } }
        }
    }
    $script:CssDefsCache = @{ root = $ProjectRoot; at = (Get-Date); names = $names }
    , $names
}

function Find-UndefinedCssVars([string]$Text, [string]$Path, [string]$ProjectRoot) {
    <# var(--name) without a fallback where nothing in the project defines --name: it has no value.
       Names of common libraries (--tw-, --bs-, ...) and pages that load stylesheets from the web are
       left out (those define their own). "line N: ..." texts. #>
    if (-not $ProjectRoot -or $Path -notmatch '(?i)\.(css|scss|less|html?)$') { return }
    if ($Path -match '(?i)\.html?$' -and $Text -match '(?i)<link\b[^>]*href\s*=\s*["''](https?:)?//') { return }
    $uses = [regex]::Matches($Text, 'var\(\s*--([A-Za-z0-9_-]+)\s*\)')
    if (-not $uses.Count) { return }
    $defs = Get-ProjectCssVarNames $ProjectRoot
    $local = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in [regex]::Matches($Text, '(?<![\w-])--([A-Za-z0-9_-]+)\s*:')) { [void]$local.Add($m.Groups[1].Value) }
    $said = @{}
    foreach ($u in $uses) {
        $n = $u.Groups[1].Value
        if ($said.ContainsKey($n) -or $defs.Contains($n) -or $local.Contains($n) -or $n -match $script:LibVarPrefix) { continue }
        $said[$n] = $true
        $like = @($defs | Where-Object { $_ -ne $n -and ($_.Replace('-', '') -eq $n.Replace('-', '') -or ($n.Length -ge 6 -and $_.StartsWith($n.Substring(0, [Math]::Min($n.Length, $n.Length - 2))))) } | Select-Object -First 2)
        "line $(LineAt $Text $u.Index): var(--$n) is not defined anywhere in the project (no --${n}: in a stylesheet), so it has no value$(if ($like.Count) { "; did you mean --$($like -join ' or --')?" } else { ': define it, or fix the name' })"
    }
}

$script:EscapedTag = '&lt;(/?[A-Za-z][\w-]*(?:\s(?:[^&<>\n]|&quot;|&#39;|&amp;)*?)?/?)&gt;'

function Find-EscapedScriptTags([string]$Path, [string]$Text) {
    <# A whole HTML tag written escaped (&lt;span class=&quot;x&quot;&gt;) in JavaScript: in a script
       it stays text, so the page shows the tag instead of making it (seen when markup is damaged on
       the way). In .js files and in the <script> blocks of pages. @(@{ index; length; text }). #>
    $spans = @()
    if ($Path -match '(?i)\.(m?js|cjs)$') { $spans = @(@{ start = 0; text = $Text }) }
    elseif ($Path -match '(?i)\.html?$') {
        $spans = @(foreach ($m in [regex]::Matches($Text, '(?is)<script\b(?![^>]*\btype\s*=\s*["'']?(text/(template|html|x-template)|application/json))[^>]*>(.*?)</script>')) { @{ start = $m.Groups[3].Index; text = $m.Groups[3].Value } })
    } else { return }
    foreach ($s in $spans) {
        foreach ($m in [regex]::Matches($s.text, $script:EscapedTag)) { @{ index = $s.start + $m.Index; length = $m.Length; text = $m.Value } }
    }
}

function Get-BracketMask([string]$Path, [string]$Text) {
    # The text with strings and comments blanked for bracket counting, by file type; $null for types
    # where brackets are not counted this way.
    switch -Regex ($Path) {
        '(?i)\.(m?js|cjs|jsx|ts|mts|cts|tsx)$' { return (Get-JsMask $Text).masked }
        '(?i)\.(cs|java|kt|kts|go|rs|php|swift|dart|scala|c|cc|cpp|h|hpp|vue|svelte)$' { return Hide $Text $script:MaskCLike }
        '(?i)\.(css|scss|less)$' { return Hide $Text $script:MaskCss }
        '(?i)\.pyw?$' { return Hide $Text $script:MaskPython }
        '(?i)\.jsonc?$' { return Hide $Text '"(?:[^"\\\n]|\\.)*"|//[^\n]*|/\*[\s\S]*?\*/' }
        '(?i)\.prisma$' { return Hide $Text '"(?:[^"\\\n]|\\.)*"|//[^\n]*' }
    }
    $null
}

function Get-OpenBlocks {
    <# The brackets still open at the end of line $Line (outermost first): @(@{ ch; line; text }),
       where text is the line that opened it. A bracket that closes the wrong kind still closes the
       innermost one, as a reader would assume. Empty for file types without bracket counting. #>
    param([string]$Path, [AllowEmptyString()][string]$Text, [int]$Line)
    $t = "$Text".Replace("`r`n", "`n")
    $masked = Get-BracketMask $Path $t
    if ($null -eq $masked) { return @() }
    $raw = $t.Split("`n")
    $stack = New-Object System.Collections.Generic.List[object]
    $n = 1
    foreach ($ch in $masked.ToCharArray()) {
        if ($ch -eq "`n") { $n++; if ($n -gt $Line) { break }; continue }
        if ($ch -eq '(' -or $ch -eq '[' -or $ch -eq '{') { $stack.Add(@{ ch = [string]$ch; line = $n; text = $raw[$n - 1].Trim() }); continue }
        if (($ch -eq ')' -or $ch -eq ']' -or $ch -eq '}') -and $stack.Count) { $stack.RemoveAt($stack.Count - 1) }
    }
    $stack.ToArray()
}

function Format-OpenBlocks {
    <# The bracket map for Copilot: which blocks are still open at a line and where they start
       ("" when none or for file types without bracket counting). #>
    param([string]$Path, [AllowEmptyString()][string]$Text, [int]$Line)
    $open = @(Get-OpenBlocks $Path $Text $Line)
    if (-not $open.Count) { return '' }
    $rows = foreach ($o in $open) { $s = $o.text; if ($s.Length -gt 90) { $s = $s.Substring(0, 87) + '...' }; "- line $($o.line) '$($o.ch)': $s" }
    "Brackets still open at the end of line $Line in $Path (outermost first; each must be closed after it, in reverse order):`n" + ($rows -join "`n")
}

$script:DataGlobalsCache = @{ root = ''; at = [datetime]::MinValue; names = $null }

function Get-ProjectDataGlobals([string]$ProjectRoot) {
    <# The global names the project's scripts define (window.NAME = ..., and var/let/const/function
       NAME at the start of a line in a classic script), with the data files in data/ marked. Cached
       for 15 seconds. @{ all = HashSet; data = list }. #>
    $c = $script:DataGlobalsCache
    if ($c.root -eq $ProjectRoot -and $c.names -and ((Get-Date) - $c.at).TotalSeconds -lt 15) { return $c.names }
    $all = New-Object 'System.Collections.Generic.HashSet[string]'
    $data = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Include *.js, *.mjs, *.html, *.htm -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.streamhub|dist|build|Source)\\' -and $_.Length -lt 50MB } | Select-Object -First 500)
    foreach ($f in $files) {
        $isData = $f.FullName -match '\\data\\[^\\]+\.js$'
        $t = try { if ($isData) { $r = New-Object IO.StreamReader($f.FullName); try { $b = New-Object char[] 4000; $n = $r.Read($b, 0, 4000); New-Object string($b, 0, $n) } finally { $r.Dispose() } } elseif ($f.Length -lt 2MB) { [IO.File]::ReadAllText($f.FullName) } else { '' } } catch { '' }
        foreach ($m in [regex]::Matches($t, '(?m)(?:\bwindow\.([A-Za-z_$][\w$]*)\s*=(?!=)|^\s*(?:var|let|const|function|class)\s+([A-Za-z_$][\w$]*))')) {
            $n = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            [void]$all.Add($n)
            if ($isData -and $m.Groups[1].Success -and -not $data.Contains($n)) { $data.Add($n) }
        }
    }
    $names = @{ all = $all; data = $data }
    $script:DataGlobalsCache = @{ root = $ProjectRoot; at = (Get-Date); names = $names }
    $names
}

function Find-DataGlobalIssues {
    <# A page or script that uses a data global (a name ending in Data, like the ones the helper
       program writes in data/*.js) that nothing in the project defines: the page loads but stays
       empty. "line N: ..." with the names the data files do define. #>
    param([string]$ProjectRoot, [string]$Path, [string]$Text)
    if (-not $ProjectRoot -or $Path -notmatch '(?i)\.(html?|m?js|jsx)$' -or $Path -match '(?i)(^|/)(data|node_modules|dist|build|styles/kit)/') { return }
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'data'))) { return }
    $g = Get-ProjectDataGlobals $ProjectRoot
    if (-not $g.data.Count) { return }
    # The script parts only, with strings and comments blanked.
    $code = if ($Path -match '(?i)\.html?$') {
        $sb = New-Object Text.StringBuilder (' ' * $Text.Length)
        foreach ($s in [regex]::Matches($Text, '(?is)(<script\b(?![^>]*\bsrc\s*=)[^>]*>)(.*?)</script>')) {
            $body = $s.Groups[2]; $masked = (Get-JsMask $body.Value).masked
            [void]$sb.Remove($body.Index, $body.Length); [void]$sb.Insert($body.Index, $masked)
        }
        $sb.ToString()
    } else { (Get-JsMask $Text).masked }
    foreach ($m in [regex]::Matches($code, '(?<![\w$.])(?:window\.)?([a-z][A-Za-z0-9_$]*Data)\b(?!\s*:)')) {
        $n = $m.Groups[1].Value
        if ($g.all.Contains($n)) { continue }
        if ($code -match ('(?<![\w$.])(var|let|const|function|class)\s+' + [regex]::Escape($n) + '\b|[(,]\s*' + [regex]::Escape($n) + '\s*[,)=]|\b' + [regex]::Escape($n) + '\s*=>')) { continue }   # its own variable or parameter
        return "line $(LineAt $Text $m.Index): uses $n, which no script or data file in the project defines, so the page has no data there; the data files define: $(@($g.data | Select-Object -First 8) -join ', ')"
    }
}

# XAML that PowerShell loads with XamlReader cannot have a code-behind class or event attributes.
$script:XamlEventPattern = '\s(Click|Loaded|Unloaded|Checked|Unchecked|SelectionChanged|TextChanged|MouseDown|MouseUp|MouseDoubleClick|KeyDown|KeyUp|Closing|Closed|ValueChanged|DropDownClosed|LostFocus|GotFocus)\s*=\s*"'

function Find-PsGuiIssues {
    <# Mistakes that stop a PowerShell window app (WPF loaded with XamlReader) from opening: x:Class or an
       event attribute in its XAML (a .xaml file in a project without a C# project, or XAML in a script),
       WPF or Windows Forms types used without Add-Type loading them first. "line N: ..." or nothing. #>
    param([string]$ProjectRoot, [string]$Path, [string]$Text)
    $xaml = $null; $offset = 0
    if ($Path -match '(?i)\.xaml$') {
        if ($Path -match '(?i)^styles/kit/') { return }
        if ($ProjectRoot -and @(Get-ChildItem -LiteralPath $ProjectRoot -Filter *.csproj -Recurse -Depth 2 -File -ErrorAction SilentlyContinue).Count) { return }   # a C# app has code-behind
        $xaml = $Text
    } elseif ($Path -match '(?i)\.ps[md]?1$' -and $Text -match 'XamlReader') {
        $h = [regex]::Match($Text, '(?s)@[''"]\s*\r?\n(\s*<(Window|UserControl|Page|Grid|StackPanel)\b.*?)\r?\n[''"]@')
        if ($h.Success) { $xaml = $h.Groups[1].Value; $offset = $h.Groups[1].Index }
    }
    if ($null -ne $xaml) {
        $c = [regex]::Match($xaml, '\sx:Class\s*=')
        if ($c.Success) { return "line $(LineAt $Text ($offset + $c.Index)): x:Class in XAML that PowerShell loads with XamlReader stops the window from opening: remove it" }
        $e = [regex]::Match($xaml, $script:XamlEventPattern)
        if ($e.Success) { $ev = $e.Groups[1].Value; return ("line $(LineAt $Text ($offset + $e.Index)): the event attribute " + $ev + '="..." stops XamlReader from loading the window: give the element an x:Name, then connect the event in PowerShell ($window.FindName(''NAME'').Add_' + $ev + '({ ... }))') }
    }
    if ($null -ne $xaml) {
        # A style for every TextBlock that sets a colour also colours the text inside buttons (white
        # text on the primary button turns black).
        $tb = [regex]::Match($xaml, '(?s)<Style\b(?![^>]*\bx:Key\s*=)[^>]*\bTargetType\s*=\s*"(\{x:Type\s+)?TextBlock\}?"[^>]*>((?:(?!</Style>).)*?)Property\s*=\s*"Foreground"')
        if ($tb.Success) { return "line $(LineAt $Text ($offset + $tb.Index)): a style for every TextBlock that sets Foreground also colours the text inside buttons and other controls: remove it (the window's Foreground reaches all text), or give it an x:Key and use it where it is meant" }
    }
    if ($Path -match '(?i)\.ps[md]?1$' -and $Text -match '(?i)KitTheme\.xaml') {
        # The kit theme must be in the application's resources before the window is parsed: a window
        # that uses its styles (StaticResource KitPrimaryButton) does not open otherwise.
        $late = [regex]::Match($Text, '(?i)\$\w+\.Resources\.MergedDictionaries\.Add\(')
        $app = $Text -match '(?i)\[(System\.)?Windows\.Application\]::Current|New-Object\s+(System\.)?Windows\.Application|\$app\w*\.Resources\.MergedDictionaries\.Add'
        if (-not $app -and $late.Success) { return "line $(LineAt $Text $late.Index): the kit theme goes into the application's resources before the window is parsed, not into the window afterwards (a window that uses its styles does not open): `$app = [Windows.Application]::Current; if (-not `$app) { `$app = New-Object Windows.Application }; `$app.Resources.MergedDictionaries.Add(`$theme); then parse the window" }
    }
    if ($Path -match '(?i)\.ps[md]?1$') {
        $wpf = [regex]::Match($Text, '\[(System\.)?Windows\.(Markup\.XamlReader|Window\b|MessageBox\b|Controls\.)')
        if ($wpf.Success -and $Text -notmatch '(?i)Add-Type\s+(-AssemblyName\s+)?[^\n]*PresentationFramework') { return "line $(LineAt $Text $wpf.Index): WPF is used before it is loaded: put Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase at the top of the script" }
        $wf = [regex]::Match($Text, '\[System\.Windows\.Forms\.')
        if ($wf.Success -and $Text -notmatch '(?i)Add-Type\s+(-AssemblyName\s+)?[^\n]*System\.Windows\.Forms|LoadWithPartialName\(\s*[''"]System\.Windows\.Forms') { return "line $(LineAt $Text $wf.Index): Windows Forms is used before it is loaded: put Add-Type -AssemblyName System.Windows.Forms at the top of the script" }
    }
}

$script:FieldWidths = 120, 240, 360
$script:XamlControls = 'Button', 'ToggleButton', 'TextBox', 'PasswordBox', 'ComboBox', 'DatePicker', 'ProgressBar', 'Slider', 'ListBox', 'CheckBox', 'RadioButton'

function Find-XamlLayoutIssues {
    <# Alignment mistakes in the XAML of a PowerShell window app (a .xaml file, or XAML in a script's
       here-string), warnings: a control with a Width but no HorizontalAlignment where it gets the whole
       width (it ends up centred while the rest starts at the left), controls placed by coordinates (on
       a Canvas, or by a large Margin with Left/Top alignment: designer-style XAML that does not adapt),
       buttons and single-line fields with their own Height, and field widths off the scale 120/240/360. "line N: ..." each, at most 4. #>
    param([string]$Path, [string]$Text, [string]$ProjectRoot = '')
    $xaml = $null; $offset = 0
    $tagged = '\bTag\s*=\s*"(row|actions|form)"'
    if ($Path -match '(?i)\.ps[md]?1$' -and $Path -notmatch '(?i)^styles/kit/' -and $Text -match 'XamlReader' -and $Text -notmatch '(?i)\b(New-KitWindow|Set-KitLayout)\b') {
        # The helper program writes the layout of tagged panels into .xaml files (GuiTest Expand-XamlLayout);
        # a window written inside the script only lines up when the helpers load it.
        if ($Text -match $tagged) {
            $at = [regex]::Match($Text, 'XamlReader')
            return "line $(LineAt $Text $at.Index): the window inside this script marks panels with Tag=`"row`", `"actions`" or `"form`", but the script loads it with XamlReader itself, so nothing lines them up: move the window into MainWindow.xaml (the helper program then writes the layout into it), or load it with New-KitWindow"
        }
    }
    if ($Path -match '(?i)\.xaml$') {
        if ($Path -match '(?i)^styles/kit/') { return }
        $xaml = $Text
    } elseif ($Path -match '(?i)\.ps[md]?1$' -and $Text -match 'XamlReader') {
        $h = [regex]::Match($Text, '(?s)@[''"]\s*\r?\n(\s*<(Window|UserControl|Page|Grid|StackPanel|DockPanel)\b.*?)\r?\n[''"]@')
        if ($h.Success) { $xaml = $h.Groups[1].Value; $offset = $h.Groups[1].Index }
    }
    if (-not $xaml -or $xaml -notmatch '<(Window|UserControl|Page)\b|xmlns=') { return }
    Add-Type -AssemblyName System.Xml.Linq
    try { $doc = [System.Xml.Linq.XDocument]::Parse($xaml, [System.Xml.Linq.LoadOptions]::SetLineInfo) } catch { return }   # the file check reports broken XML
    $first = LineAt $Text $offset
    $attr = { param($el, [string]$name) $a = @($el.Attributes() | Where-Object { $_.Name.LocalName -eq $name }); if ($a.Count) { $a[0].Value } else { '' } }
    $label = { param($el) $n = & $attr $el 'Name'; if ($n) { "the $($el.Name.LocalName) $n" } else { "a $($el.Name.LocalName)" } }
    $at = { param($el) $first + ([System.Xml.IXmlLineInfo]$el).LineNumber - 1 }
    $out = New-Object System.Collections.Generic.List[string]
    $heights = New-Object System.Collections.Generic.List[object]
    $widths = New-Object System.Collections.Generic.List[object]
    $placed = $false
    foreach ($el in $doc.Descendants()) {
        if ($out.Count -ge 4) { break }
        $kind = $el.Name.LocalName
        $parent = $el.Parent
        $pk = if ($parent) { $parent.Name.LocalName } else { '' }
        if ($script:XamlControls -contains $kind) {
            $width = & $attr $el 'Width'
            if ($width -match '^\d' -and -not (& $attr $el 'HorizontalAlignment') -and $parent) {
                # Where a fixed-width control is given the whole width, WPF centres it.
                $wide = switch ($pk) {
                    'StackPanel' { (& $attr $parent 'Orientation') -ne 'Horizontal' -and (& $attr $parent 'Tag') -notin 'row', 'actions' }
                    'DockPanel' { (& $attr $el 'DockPanel.Dock') -notin 'Left', 'Right' }
                    'Grid' {
                        $cols = @($parent.Elements() | Where-Object { $_.Name.LocalName -eq 'Grid.ColumnDefinitions' } | ForEach-Object { $_.Elements() })
                        $ci = 0; [void][int]::TryParse((& $attr $el 'Grid.Column'), [ref]$ci)
                        (& $attr $parent 'Tag') -ne 'form' -and (-not $cols.Count -or ($ci -lt $cols.Count -and (& $attr $cols[$ci] 'Width') -notmatch '^(Auto|\d+(\.\d+)?)$'))
                    }
                    { $_ -in 'Border', 'ScrollViewer', 'GroupBox', 'Expander', 'TabItem', 'Window' } { $true }
                    default { $false }
                }
                if ($wide) { $out.Add("line $(& $at $el): $(& $label $el) has a Width but no HorizontalAlignment, so it ends up centred while the rest starts at the left: add HorizontalAlignment=`"Left`", or put it in a StackPanel Tag=`"row`"") }
            }
            if (-not $placed) {
                $m = (& $attr $el 'Margin') -split ','
                $big = $m.Count -ge 2 -and ([double]::TryParse($m[0], [ref]$null)) -and ([double]$m[0] -ge 40 -or [double]$m[1] -ge 40)
                if ($pk -eq 'Canvas' -or ($big -and (& $attr $el 'HorizontalAlignment') -eq 'Left' -and (& $attr $el 'VerticalAlignment') -eq 'Top')) {
                    $placed = $true
                    $out.Add("line $(& $at $el): $(& $label $el) is placed by coordinates ($(if ($pk -eq 'Canvas') { 'on a Canvas' } else { 'a large Margin with Left/Top' })), so nothing lines up or adapts to the window size: lay the window out with Grid, DockPanel and StackPanel Tag=`"row`" / Tag=`"actions`" / Grid Tag=`"form`"")
                }
            }
        }
        if ($kind -in 'Button', 'TextBox', 'PasswordBox', 'ComboBox', 'DatePicker' -and (& $attr $el 'Height') -match '^\d' -and -not ($kind -eq 'TextBox' -and ((& $attr $el 'AcceptsReturn') -eq 'True' -or (& $attr $el 'TextWrapping') -eq 'Wrap'))) {
            $heights.Add(@((& $at $el), (& $label $el), (& $attr $el 'Height')))
        }
        if ($kind -in 'TextBox', 'PasswordBox', 'ComboBox', 'DatePicker' -and (& $attr $el 'Width') -match '^\d+(\.\d+)?$' -and $script:FieldWidths -notcontains [double](& $attr $el 'Width')) {
            $widths.Add(@((& $at $el), (& $label $el), (& $attr $el 'Width')))
        }
    }
    # Sizes, once each: fields and buttons in one height, field widths from one scale.
    if ($heights.Count -and $out.Count -lt 4) {
        $h = $heights[0]
        $out.Add("line $($h[0]): $($h[1]) has its own Height ($($h[2]))$(if ($heights.Count -gt 1) { " and so do $($heights.Count - 1) more" }): leave it out so buttons, fields and lists share one height (32)")
    }
    if ($widths.Count -and $out.Count -lt 4) {
        $w = $widths[0]
        $out.Add("line $($w[0]): field widths $(@($widths | ForEach-Object { $_[2] } | Select-Object -Unique) -join ', ') are off the width scale: use 120 (a number, a date, a short choice), 240 (a name, a search, a choice) or 360 (long text), or let the fields fill a Grid Tag=`"form`" column, so fields of the same kind are the same width")
    }
    @($out)
}

function Get-NewFileIssues {
    <# Problems a change added: those in the new text that the old text did not have (compared
       without line numbers, so an existing problem that only moved is not reported again). #>
    param([string]$Path, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New, [bool]$Crlf = $false, [string]$ProjectRoot = '')
    $all = {
        param($text)
        @(Test-FileContent $Path $text $Crlf) + @(Test-LocalReferences $text.Replace("`r`n", "`n") $Path $ProjectRoot) +
            @(if ($Path -match '(?i)\.ps[md]?1$') { Test-PsCommands $text $ProjectRoot }) +
            @(if ($Path -match '(?i)\.prisma$') { Test-PrismaEnv $text.Replace("`r`n", "`n") $Path $ProjectRoot }) +
            @(Find-UndefinedCssVars $text.Replace("`r`n", "`n") $Path $ProjectRoot) +
            @(Find-DataGlobalIssues $ProjectRoot $Path $text.Replace("`r`n", "`n")) +
            @(Find-PsGuiIssues $ProjectRoot $Path $text.Replace("`r`n", "`n")) +
            @(Find-XamlLayoutIssues $Path $text.Replace("`r`n", "`n") $ProjectRoot) | Where-Object { $_ }
    }
    # The fixed rules; when they find nothing, the language's own syntax check (node, python, when
    # installed) for what they cannot see (one problem is not reported twice).
    $after = @(& $all $New)
    $tool = @(if (-not $after.Count) { Test-ToolSyntax $Path "$New".Replace("`r`n", "`n") })
    # A Prisma schema: prisma validate on the file as saved (the new text), when the project has Prisma.
    if (-not $after.Count -and $Path -match '(?i)\.prisma$') { $tool += @(Test-PrismaValidate $ProjectRoot $Path) }
    $after = @(@($after) + $tool | Where-Object { $_ })
    if (-not $after.Count) { return }
    $before = @{}
    if ("$Old") { foreach ($i in @(& $all $Old)) { $k = $i -replace '\d+', '#'; $before[$k] = 1 + [int]$before[$k] } }
    if ($tool.Count -and "$Old") { foreach ($i in @(Test-ToolSyntax $Path "$Old".Replace("`r`n", "`n"))) { $k = $i -replace '\d+', '#'; $before[$k] = 1 + [int]$before[$k] } }
    foreach ($i in $after) {
        $k = $i -replace '\d+', '#'
        if ($before[$k]) { $before[$k]--; continue }
        $i
    }
}

Export-ModuleMember -Function Find-PsGuiIssues, Find-XamlLayoutIssues, Get-ProjectDataGlobals, Find-DataGlobalIssues, Find-PlaceholderMarkup, Find-BrokenEncoding, ConvertFrom-Mojibake, Test-TextEncoding, Find-EscapedScriptTags, Find-UndefinedCssVars, Get-OpenBlocks, Format-OpenBlocks, Test-Prisma, Test-PrismaEnv, Test-PrismaValidate, ConvertFrom-PrismaValidate, Find-PrismaCli, Get-CodeMask, Find-LanguagePitfalls, Find-GeneratedCodeIssues, Test-ToolSyntax, Test-FileContent, Get-NewFileIssues, Test-Brackets, Find-Secrets, Test-Duplicates, Test-PsCommands, Test-LocalReferences
