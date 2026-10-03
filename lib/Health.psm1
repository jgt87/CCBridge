# Code health without a model: measurements per function, as fixed rules.
#   ccn      cyclomatic complexity: 1 + decision points (if/elif, loops, case, catch, && || ??,
#            and/or, ?:)
#   nesting  deepest block level inside the function
#   lines    length; params: number of parameters
#   brain    long, complex and deeply nested at once
# Get-FunctionMetrics per language (PowerShell by its syntax tree; JS/TS, C-like and Python by
# scanning with strings and comments blanked). Get-HealthIssues reports functions that are clearly
# too much; Compare-Health finds functions a change made worse. No scores: findings only.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lint.psm1')

$script:Limits = @{ ccn = 10; ccnHigh = 20; nesting = 4; nestingHigh = 6; lines = 60; linesHigh = 120; params = 5 }
$script:MaskC = '/\*[\s\S]*?\*/|"(?:[^"\\\n]|\\.)*"|''(?:[^''\\\n]|\\.)*''|(?<![:\\])//[^\n]*'
$script:MaskPy = '"""[\s\S]*?"""|''''''[\s\S]*?''''''|"(?:[^"\\\n]|\\.)*"|''(?:[^''\\\n]|\\.)*''|#[^\n]*'

function Blank([string]$Text, [string]$Pattern) {
    [regex]::Replace($Text, $Pattern, [Text.RegularExpressions.MatchEvaluator] { param($m) [regex]::Replace($m.Value, '[^\n]', ' ') })
}
function LineOf([string]$Text, [int]$Index) { ([regex]::Matches($Text.Substring(0, [Math]::Min([Math]::Max(0, $Index), $Text.Length)), "`n")).Count + 1 }

function New-Metric([string]$Name, [int]$Line, [int]$End, [int]$Ccn, [int]$Nesting, [int]$Params) {
    $len = $End - $Line + 1
    $l = $script:Limits
    $brain = ($len -gt $l.lines -and $Ccn -gt $l.ccn -and $Nesting -ge $l.nesting)
    $pen = [Math]::Min(30, [Math]::Max(0, $Ccn - $l.ccn) * 1.5) + [Math]::Max(0, $Nesting - ($l.nesting - 1)) * 5 + [Math]::Max(0, $len - $l.lines) / 10 + [Math]::Max(0, $Params - $l.params) * 2 + $(if ($brain) { 10 } else { 0 })
    $flags = @()
    if ($Ccn -gt $l.ccnHigh) { $flags += 'very complex' } elseif ($Ccn -gt $l.ccn) { $flags += 'complex' }
    if ($Nesting -ge $l.nestingHigh) { $flags += 'very deeply nested' } elseif ($Nesting -ge $l.nesting) { $flags += 'deeply nested' }
    if ($len -gt $l.linesHigh) { $flags += 'very long' } elseif ($len -gt $l.lines) { $flags += 'long' }
    if ($Params -gt $l.params) { $flags += 'many parameters' }
    if ($brain) { $flags += 'brain method' }
    [pscustomobject]@{ name = $Name; line = $Line; endLine = $End; lines = $len; ccn = $Ccn; nesting = $Nesting; params = $Params; brain = $brain; penalty = [Math]::Round($pen, 1); flags = $flags }
}

# --- PowerShell: from the syntax tree -------------------------------------------------------
function Get-PsFunctionMetrics([string]$Text) {
    $tok = $null; $errs = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$errs)
    $T = [Management.Automation.Language.Ast]
    foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $own = {
            # The node belongs to this function, not to a function nested inside it.
            param($node)
            $p = $node.Parent
            while ($p -and $p -ne $fn) { if ($p -is [Management.Automation.Language.FunctionDefinitionAst]) { return $false }; $p = $p.Parent }
            $true
        }
        $nodes = @($fn.Body.FindAll({ param($n) $true }, $true) | Where-Object { & $own $_ })
        $ccn = 1
        $maxNest = 0
        foreach ($n in $nodes) {
            switch -Regex ($n.GetType().Name) {
                '^IfStatementAst$' { $ccn += $n.Clauses.Count }
                '^SwitchStatementAst$' { $ccn += $n.Clauses.Count }
                '^(ForStatementAst|ForEachStatementAst|WhileStatementAst|DoWhileStatementAst|DoUntilStatementAst|CatchClauseAst|TrapStatementAst)$' { $ccn++ }
                '^BinaryExpressionAst$' { if ("$($n.Operator)" -in 'And', 'Or') { $ccn++ } }
            }
            if ($n -is [Management.Automation.Language.StatementBlockAst]) {
                $d = 0; $p = $n.Parent
                while ($p -and $p -ne $fn) {
                    if ($p -is [Management.Automation.Language.IfStatementAst] -or $p -is [Management.Automation.Language.LoopStatementAst] -or $p -is [Management.Automation.Language.SwitchStatementAst] -or $p -is [Management.Automation.Language.TryStatementAst]) { $d++ }
                    $p = $p.Parent
                }
                if ($d -gt $maxNest) { $maxNest = $d }
            }
        }
        $params = if ($fn.Parameters) { $fn.Parameters.Count } elseif ($fn.Body.ParamBlock) { $fn.Body.ParamBlock.Parameters.Count } else { 0 }
        New-Metric $fn.Name $fn.Extent.StartLineNumber $fn.Extent.EndLineNumber $ccn $maxNest $params
    }
}

# --- Brace languages (JS/TS, C#, Java, Go, ...): from blanked text ---------------------------
function Get-MatchingBrace([string]$Masked, [int]$Open) {
    $d = 0
    for ($i = $Open; $i -lt $Masked.Length; $i++) {
        if ($Masked[$i] -eq '{') { $d++ } elseif ($Masked[$i] -eq '}') { $d--; if ($d -eq 0) { return $i } }
    }
    -1
}

function Get-BraceFunctionMetrics([string]$Text, [string]$Path) {
    $isJs = $Path -match '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte)$'
    $m = if ($isJs) { (& (Get-Module Lint) { param($t) Get-JsMask $t } $Text).masked } else { Blank $Text $script:MaskC }
    $starts = New-Object System.Collections.Generic.List[object]
    $patterns = @(
        '\bfunction\s*\*?\s*([\w$]*)\s*\(([^)]*)\)[^{;]*\{',
        '\b(?:const|let|var)\s+([\w$]+)\s*=\s*(?:async\s*)?(?:\(([^)]*)\)|([\w$]+))\s*(?::[^=;{]+)?=>\s*\{',
        '(?m)^[ \t]*(?:(?:public|private|protected|internal|static|async|override|virtual|abstract|readonly|final|sealed|export|get|set)\s+)*(?:[\w<>\[\],.?]+\s+)?([A-Za-z_$][\w$]*)\s*\(([^)]*)\)\s*(?::\s*[^{;=]+)?(?:throws[^{;]*)?\{',
        '(?m)^[ \t]*func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*\(([^)]*)\)[^{]*\{'
    )
    $taken = @{}
    foreach ($p in $patterns) {
        foreach ($x in [regex]::Matches($m, $p)) {
            $name = $x.Groups[1].Value
            if ($name -in 'if', 'for', 'while', 'switch', 'catch', 'with', 'return', 'function', 'else', 'do', 'try', 'using', 'lock', 'foreach', 'new', 'typeof', 'await', 'yield', 'throw', 'case') { continue }
            $open = $x.Index + $x.Length - 1
            if ($taken.ContainsKey($open)) { continue }
            $close = Get-MatchingBrace $m $open
            if ($close -lt 0) { continue }
            $taken[$open] = $true
            $args = if ($x.Groups[2].Success -and $x.Groups[2].Value.Trim()) { @($x.Groups[2].Value.Split(',') | Where-Object { $_.Trim() }).Count } elseif ($x.Groups[3].Success -and $x.Groups[3].Value) { 1 } else { 0 }
            $starts.Add(@{ name = $(if ($name) { $name } else { '(anonymous)' }); start = $x.Index; open = $open; close = $close; params = $args })
        }
    }
    foreach ($f in $starts) {
        # Code of functions nested inside this one does not count for it.
        $body = $m.Substring($f.open + 1, [Math]::Max(0, $f.close - $f.open - 1))
        foreach ($g in $starts) {
            if ($g.open -gt $f.open -and $g.close -lt $f.close) {
                $s = $g.start - $f.open - 1; $len = $g.close - $g.start + 1
                if ($s -ge 0 -and $s + $len -le $body.Length) { $body = $body.Substring(0, $s) + [regex]::Replace($body.Substring($s, $len), '[^\n]', ' ') + $body.Substring($s + $len) }
            }
        }
        $ccn = 1 + ([regex]::Matches($body, '\b(if|for|foreach|while|case|catch)\b')).Count + ([regex]::Matches($body, '&&|\|\||\?\?(?!=)')).Count + ([regex]::Matches($body, '\?(?![.?:\]>,)=])')).Count
        # Nesting: blocks after a control statement or a callback, not object literals.
        $depth = 0; $max = 0; $stack = New-Object System.Collections.Generic.Stack[bool]
        for ($i = 0; $i -lt $body.Length; $i++) {
            if ($body[$i] -eq '{') {
                $before = $body.Substring([Math]::Max(0, $i - 40), [Math]::Min(40, $i)).TrimEnd()
                $control = $before -match '(\)|\belse|\btry|\bfinally|\bdo|=>)$'
                $stack.Push($control); if ($control) { $depth++; if ($depth -gt $max) { $max = $depth } }
            } elseif ($body[$i] -eq '}' -and $stack.Count) { if ($stack.Pop()) { $depth-- } }
        }
        New-Metric $f.name (LineOf $m $f.start) (LineOf $m $f.close) $ccn $max $f.params
    }
}

# --- Python: from indentation ---------------------------------------------------------------
function Get-PyFunctionMetrics([string]$Text) {
    $m = Blank $Text $script:MaskPy
    $lines = $m.Split("`n")
    $ind = { param($l) ([regex]::Match($l, '^[ \t]*')).Value.Replace("`t", '    ').Length }
    $defs = @(for ($i = 0; $i -lt $lines.Length; $i++) { $d = [regex]::Match($lines[$i], '^([ \t]*)(?:async\s+)?def\s+(\w+)\s*\(([^)]*)'); if ($d.Success) { @{ i = $i; indent = (& $ind $lines[$i]); name = $d.Groups[2].Value; sig = $d.Groups[3].Value } } })
    foreach ($d in $defs) {
        $end = $d.i; $bodyIndent = $null
        for ($j = $d.i + 1; $j -lt $lines.Length; $j++) {
            if (-not $lines[$j].Trim()) { continue }
            $k = & $ind $lines[$j]
            if ($k -le $d.indent) { break }
            if ($null -eq $bodyIndent) { $bodyIndent = $k }
            $end = $j
        }
        if ($null -eq $bodyIndent) { continue }
        $unit = [Math]::Max(1, $bodyIndent - $d.indent)
        # Lines of nested defs belong to those.
        $skip = @{}
        foreach ($n in $defs) {
            if ($n.i -gt $d.i -and $n.i -le $end) {
                for ($j = $n.i; $j -le $end; $j++) { if ($j -gt $n.i -and $lines[$j].Trim() -and (& $ind $lines[$j]) -le $n.indent) { break }; $skip[$j] = $true }
            }
        }
        $ccn = 1; $max = 0
        for ($j = $d.i + 1; $j -le $end; $j++) {
            if ($skip[$j] -or -not $lines[$j].Trim()) { continue }
            $l = $lines[$j]
            $ccn += ([regex]::Matches($l, '\b(if|elif|for|while|except|case)\b')).Count + ([regex]::Matches($l, '\b(and|or)\b')).Count
            if ($l.Trim() -match '^(if|elif|else|for|while|try|except|finally|with|match|case)\b') {
                $lvl = [int][Math]::Floor(((& $ind $l) - $bodyIndent) / $unit) + 1
                if ($lvl -gt $max) { $max = $lvl }
            }
        }
        $params = @($d.sig.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notin 'self', 'cls', '*', '/' }).Count
        New-Metric $d.name ($d.i + 1) ($end + 1) $ccn $max $params
    }
}

function Get-FunctionMetrics {
    <# Measurements of every function in a file's text (empty for other file types). #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    $t = $Text.Replace("`r`n", "`n")
    switch -Regex ($Path) {
        '(?i)\.ps[m]?1$' { return @(Get-PsFunctionMetrics $t) }
        '(?i)\.pyw?$' { return @(Get-PyFunctionMetrics $t) }
        '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|cs|java|kt|go|rs|php|swift|dart|c|cc|cpp|h|hpp|scala)$' { return @(Get-BraceFunctionMetrics $t $Path) }
    }
    @()
}

function Get-HealthIssues {
    <# Functions that are clearly too much: very complex (CCN over 20), very deeply nested (6+
       levels), very long (over 120 lines), or a brain method (long, complex and deeply nested).
       Returns @{ line; message } per function (worst first). #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    foreach ($f in @(Get-FunctionMetrics $Path $Text | Where-Object { @($_.flags | Where-Object { $_ -match '^very|brain' }).Count } | Sort-Object penalty -Descending)) {
        $what = @($f.flags | Where-Object { $_ -match '^very|brain|many' }) -join ', '
        [pscustomobject]@{ line = $f.line; endLine = $f.endLine; name = $f.name; message = "function '$($f.name)' (lines $($f.line)-$($f.endLine)) is ${what}: CCN $($f.ccn), nesting $($f.nesting), $($f.lines) lines$(if ($f.params -gt 5) { ", $($f.params) parameters" })" }
    }
}
function Compare-Health {
    <# Functions a change made worse: newly over a "very" limit (or a brain method), or clearly more
       complex than before (+5 CCN or +2 nesting). Returns "name (file:line): what" texts. #>
    param([string]$Path, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    $before = @{}; foreach ($f in @(Get-FunctionMetrics $Path $Old)) { $before[$f.name] = $f }
    foreach ($f in @(Get-FunctionMetrics $Path $New)) {
        $b = $before[$f.name]
        $was = if ($b) { "was CCN $($b.ccn), nesting $($b.nesting), $($b.lines) lines" } else { 'new function' }
        $bad = @($f.flags | Where-Object { $_ -match '^very|brain' })
        $badBefore = if ($b) { @($b.flags | Where-Object { $_ -match '^very|brain' }) } else { @() }
        $newBad = @($bad | Where-Object { $badBefore -notcontains $_ })
        $worse = $b -and (($f.ccn - $b.ccn) -ge 5 -or ($f.nesting - $b.nesting) -ge 2) -and $bad.Count
        if ($newBad.Count -or $worse) { "$($f.name) ($($Path):$($f.line)): CCN $($f.ccn), nesting $($f.nesting), $($f.lines) lines - $(@($f.flags) -join ', ') ($was)" }
    }
}

Export-ModuleMember -Function Get-FunctionMetrics, Get-HealthIssues, Compare-Health
