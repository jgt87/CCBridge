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

function New-Metric([string]$Name, [int]$Line, [int]$End, [int]$Ccn, [int]$Nesting, [int]$Params, [int]$OwnLines = 0) {
    # $OwnLines: the function's own lines, without the functions nested in it (measured on their own).
    $len = if ($OwnLines -gt 0) { $OwnLines } else { $End - $Line + 1 }
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
function Get-PsScriptBlockName($Node) {
    # '$name' for a script block assigned to a variable ($check = { ... }), a function in all but
    # name; '' for one passed to a command (Where-Object { ... }), which belongs to its function.
    if ($Node -isnot [Management.Automation.Language.ScriptBlockExpressionAst]) { return '' }
    $p = $Node.Parent
    if ($p -isnot [Management.Automation.Language.CommandExpressionAst]) { return '' }
    if ($p.Parent -is [Management.Automation.Language.PipelineAst] -and $p.Parent.PipelineElements.Count -eq 1) { $p = $p.Parent }
    $a = $p.Parent
    if ($a -isnot [Management.Automation.Language.AssignmentStatementAst] -or $a.Right -ne $p -or $a.Left -isnot [Management.Automation.Language.VariableExpressionAst]) { return '' }
    '$' + $a.Left.VariablePath.UserPath
}

function Get-PsFunctionMetrics([string]$Text) {
    $tok = $null; $errs = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$errs)
    # Units: functions and script blocks assigned to a variable; each is measured on its own.
    $units = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -or (Get-PsScriptBlockName $n) }, $true))
    $unitSet = New-Object 'System.Collections.Generic.HashSet[object]'
    foreach ($u in $units) { [void]$unitSet.Add($u) }
    foreach ($fn in $units) {
        $isFunction = $fn -is [Management.Automation.Language.FunctionDefinitionAst]
        $block = if ($isFunction) { $fn.Body } else { $fn.ScriptBlock }
        $own = {
            # The node belongs to this unit, not to a unit nested inside it.
            param($node)
            $p = $node.Parent
            while ($p -and $p -ne $fn) { if ($unitSet.Contains($p)) { return $false }; $p = $p.Parent }
            $true
        }
        $nodes = @($block.FindAll({ param($n) $true }, $true) | Where-Object { & $own $_ })
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
        $params = if ($isFunction -and $fn.Parameters) { $fn.Parameters.Count } elseif ($block.ParamBlock) { $block.ParamBlock.Parameters.Count } else { 0 }
        $start = $fn.Extent.StartLineNumber; $end = $fn.Extent.EndLineNumber
        $nested = @{}
        foreach ($u in $units) {
            if ($u -eq $fn -or $u.Extent.StartOffset -lt $fn.Extent.StartOffset -or $u.Extent.EndOffset -gt $fn.Extent.EndOffset) { continue }
            for ($l = $u.Extent.StartLineNumber; $l -le $u.Extent.EndLineNumber; $l++) { if ($l -gt $start -and $l -lt $end) { $nested[$l] = $true } }
        }
        $ownLines = if ($nested.Count) { $end - $start + 1 - $nested.Count } else { 0 }
        New-Metric $(if ($isFunction) { $fn.Name } else { Get-PsScriptBlockName $fn }) $start $end $ccn $maxNest $params $ownLines
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
        # An arrow with a block body bound to a name in another way: an object property, a class
        # field, an assignment (this.x = ...). Arrows passed as arguments stay with their function.
        '(?<![\w$])([\w$]+)\s*(?::|(?<![=!<>])=(?![=>]))\s*(?:async\s*)?(?:\(([^)]*)\)|([\w$]+))\s*(?::[^=;{]+)?=>\s*\{',
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
            $paramCount = if ($x.Groups[2].Success -and $x.Groups[2].Value.Trim()) { @($x.Groups[2].Value.Split(',') | Where-Object { $_.Trim() }).Count } elseif ($x.Groups[3].Success -and $x.Groups[3].Value) { 1 } else { 0 }
            $starts.Add(@{ name = $name; start = $x.Index; open = $open; close = $close; params = $paramCount; line = (LineOf $m $x.Index); end = (LineOf $m $close) })
        }
    }
    foreach ($f in $starts) {
        # Code of functions nested inside this one does not count for it.
        $body = $m.Substring($f.open + 1, [Math]::Max(0, $f.close - $f.open - 1))
        $nested = @{}
        foreach ($g in $starts) {
            if ($g.open -gt $f.open -and $g.close -lt $f.close) {
                $s = $g.start - $f.open - 1; $len = $g.close - $g.start + 1
                if ($s -ge 0 -and $s + $len -le $body.Length) { $body = $body.Substring(0, $s) + [regex]::Replace($body.Substring($s, $len), '[^\n]', ' ') + $body.Substring($s + $len) }
                for ($l = $g.line; $l -le $g.end; $l++) { if ($l -gt $f.line -and $l -lt $f.end) { $nested[$l] = $true } }
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
        # A file-level wrapper, (function () { ... })() or ;(function () { ... }()), holds the file's
        # functions: it is measured by its own statements, not by everything inside it.
        # Any other function is measured without the lines of the functions nested in it.
        $ownLines = if ($nested.Count) { $f.end - $f.line + 1 - $nested.Count } else { 0 }
        if (-not $f.name -and $m.Substring(0, $f.start) -match '^[\s(!;]*$' -and $m.Substring($f.close + 1) -match '^\s*\)?\s*(\((this|window|globalThis|self)?\)|\.call\([^)]*\))\s*\)?\s*;?\s*$') {
            $ownLines = [Math]::Max(1, @($body.Split("`n") | Where-Object { $_.Trim() }).Count)
        }
        New-Metric $(if ($f.name) { $f.name } else { '(anonymous)' }) $f.line $f.end $ccn $max $f.params $ownLines
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
        # Without the lines of nested defs, which are measured on their own.
        $ownLines = if ($skip.Count) { $end - $d.i + 1 - $skip.Count } else { 0 }
        New-Metric $d.name ($d.i + 1) ($end + 1) $ccn $max $params $ownLines
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
    # Keyed by name and its occurrence: anonymous functions (and methods of the same name) are
    # matched first to first, second to second, not all to the last one.
    $keyOf = { param($list) $seen = @{}; foreach ($f in $list) { $seen[$f.name] = 1 + [int]$seen[$f.name]; @{ key = "$($f.name)#$($seen[$f.name])"; f = $f } } }
    $before = @{}; foreach ($x in @(& $keyOf @(Get-FunctionMetrics $Path $Old))) { $before[$x.key] = $x.f }
    foreach ($x in @(& $keyOf @(Get-FunctionMetrics $Path $New))) {
        $f = $x.f
        $b = $before[$x.key]
        $was = if ($b) { "was CCN $($b.ccn), nesting $($b.nesting), $($b.lines) lines" } else { 'new function' }
        $bad = @($f.flags | Where-Object { $_ -match '^very|brain' })
        $badBefore = if ($b) { @($b.flags | Where-Object { $_ -match '^very|brain' }) } else { @() }
        $newBad = @($bad | Where-Object { $badBefore -notcontains $_ })
        $worse = $b -and (($f.ccn - $b.ccn) -ge 5 -or ($f.nesting - $b.nesting) -ge 2) -and $bad.Count
        if ($newBad.Count -or $worse) { "$($f.name) ($($Path):$($f.line)): CCN $($f.ccn), nesting $($f.nesting), $($f.lines) lines - $(@($f.flags) -join ', ') ($was)" }
    }
}

Export-ModuleMember -Function Get-FunctionMetrics, Get-HealthIssues, Compare-Health
