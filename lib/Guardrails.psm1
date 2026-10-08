# Coding guardrails: fixed rules on what a change adds (never on what was already there).
#   Test-GeneratedPath   writes into build output, package folders, .git or lock files: refused
#                        (Assert-Writable, Executor)
#   Find-NewDependencies a new package (package.json, requirements, pyproject, .csproj) or a script
#                        or stylesheet from another site: a person approves, also in auto mode
#   Find-RiskyCode       eval, new Function, innerHTML from a variable, document.write,
#                        Invoke-Expression, shell=True, os.system, pickle, SQL built from strings:
#                        a person approves, also in auto mode
#   Find-ChangeSmells    debug leftovers (debugger, alert, .only, breakpoint) and swallowed errors
#                        (empty catch, except: pass): sent back to Copilot to fix
#   Find-UnignoredEnv    a new .env file that .gitignore does not cover: sent back to Copilot
# The approval and fix flows are in Agent.psm1 (Invoke-AgentAction, the round's file check).

$ErrorActionPreference = 'Stop'

$script:AlwaysGenerated = '(?i)(^|/)(node_modules|\.git|__pycache__|\.next|\.nuxt|\.svelte-kit|\.parcel-cache|\.turbo|dist|coverage)(/|$)'
$script:BuildDirs = '(?i)(^|/)(build|out|bin|obj|target)(/|$)'
$script:LockFiles = '(?i)(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Pipfile\.lock|composer\.lock|Cargo\.lock|packages\.lock\.json|Gemfile\.lock|bun\.lockb?)$'
$script:BuildMarkers = 'package.json', 'tsconfig.json', 'pyproject.toml', 'setup.py', 'Cargo.toml', 'go.mod', 'pom.xml', 'build.gradle', 'build.gradle.kts', 'Makefile'

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Contrast.psm1')

function Test-GeneratedPath {
    <# Why a project path must not be written by hand, or $null. build/, out/, bin/, obj/ and
       target/ count only in a project with a build tool (package.json, *.csproj, ...), since a
       plain project may keep its own files there. #>
    param([Parameter(Mandatory)][string]$Rel, [string]$ProjectRoot = '')
    $p = $Rel.Replace('\', '/').TrimStart('/')
    if ($p -match $script:LockFiles) { return "$p is a lock file that the package manager writes; change the dependency list (for example package.json) and let the package manager update it" }
    if ($p -match $script:AlwaysGenerated) { return "$p is in a folder that tools generate ($($Matches[2])/); hand edits there are lost or break the tools. Change the source files instead" }
    if ($p -match $script:BuildDirs -and $ProjectRoot) {
        $tool = @($script:BuildMarkers | Where-Object { Test-Path -LiteralPath (Join-Path $ProjectRoot $_) -PathType Leaf }).Count -gt 0 -or
            @(Get-ChildItem -LiteralPath $ProjectRoot -Filter '*.*proj' -File -ErrorAction SilentlyContinue).Count -gt 0
        if ($tool) { return "$p is in the build output folder ($($Matches[2])/), which the build writes; change the source files instead" }
    }
    $null
}

function Get-Multiset([string[]]$Items) {
    $h = @{}; foreach ($i in @($Items | Where-Object { $_ })) { $h[$i] = 1 + [int]$h[$i] }; $h
}

function Get-Added([string[]]$Old, [string[]]$New) {
    # Items of $New that $Old did not have (as many times as they were added).
    $o = Get-Multiset $Old
    foreach ($i in @($New | Where-Object { $_ })) { if ($o[$i]) { $o[$i]-- } else { $i } }
}

function Get-DependencyList([string]$Rel, [string]$Text) {
    # "kind name" for each dependency the file declares.
    $t = "$Text"
    if (-not $t.Trim()) { return }
    $leaf = [IO.Path]::GetFileName($Rel).ToLowerInvariant()
    if ($leaf -eq 'package.json') {
        try { $j = $t | ConvertFrom-Json } catch { return }
        foreach ($sec in 'dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies') {
            $d = $j.$sec
            if ($d -is [pscustomobject]) { foreach ($p in $d.PSObject.Properties) { "npm $($p.Name)@$($p.Value)" } }
        }
        return
    }
    if ($leaf -match '^requirements.*\.txt$') {
        foreach ($l in $t.Split("`n")) {
            $x = ($l -replace '#.*$', '').Trim()
            if ($x -and $x -notmatch '^-') { "pip $(($x -split '[\s;]')[0])" }
        }
        return
    }
    if ($leaf -eq 'pyproject.toml') {
        foreach ($m in [regex]::Matches($t, '(?s)\bdependencies\s*=\s*\[(.*?)\]')) { foreach ($q in [regex]::Matches($m.Groups[1].Value, '"([^"]+)"|''([^'']+)''')) { "pip $($q.Groups[1].Value)$($q.Groups[2].Value)" } }
        foreach ($m in [regex]::Matches($t, '(?ms)^\[tool\.poetry\.(?:group\.[\w-]+\.)?(?:dev-)?dependencies\]\s*\n(.*?)(?=^\[|\z)')) {
            foreach ($q in [regex]::Matches($m.Groups[1].Value, '(?m)^\s*([A-Za-z0-9_.-]+)\s*=\s*(.+)$')) { if ($q.Groups[1].Value -ne 'python') { "pip $($q.Groups[1].Value) $($q.Groups[2].Value.Trim())" } }
        }
        return
    }
    if ($leaf -match '\.(cs|fs|vb)proj$|^directory\.packages\.props$') {
        foreach ($m in [regex]::Matches($t, '(?i)<Package(?:Reference|Version)\s+Include\s*=\s*"([^"]+)"(?:[^>]*\bVersion\s*=\s*"([^"]+)")?')) { "nuget $($m.Groups[1].Value)$(if ($m.Groups[2].Value) { '@' + $m.Groups[2].Value })" }
        return
    }
    if ($Rel -match '(?i)\.(html?|m?js|cjs|jsx|tsx?|vue|svelte)$') {
        foreach ($m in [regex]::Matches($t, '(?i)<script\b[^>]*\bsrc\s*=\s*["''](https?:)?//([^"'']+)')) { "script https://$($m.Groups[2].Value)" }
        foreach ($m in [regex]::Matches($t, '(?i)<link\b[^>]*\bhref\s*=\s*["''](https?:)?//([^"'']+\.css[^"'']*)')) { "stylesheet https://$($m.Groups[2].Value)" }
        foreach ($m in [regex]::Matches($t, '(?i)\bimport\b[^;\n]*?["'']https?://([^"'']+)["'']')) { "module https://$($m.Groups[1].Value)" }
    }
}

function Get-DependencyName([string]$Dep) {
    # The package without its version: "npm @scope/name", "pip name", "nuget name"; URLs as they are.
    $kind, $rest = $Dep.Split(' ', 2)
    switch ($kind) {
        'npm' { return "npm $($rest -replace '(?<=.)@[^@/\s]*$', '')" }
        'nuget' { return "nuget $($rest -replace '@[^@\s]*$', '')" }
        'pip' { return "pip $((($rest -split '[<>=~!^\s\[;@]')[0]).ToLowerInvariant())" }
        default { return $Dep }
    }
}

function Find-NewDependencies {
    <# Dependencies a change adds: "npm name@version", "pip name", "nuget name@version",
       "script https://...", "stylesheet https://...", "module https://...". #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    $oldList = @(Get-DependencyList $Rel $Old)
    $newList = @(Get-DependencyList $Rel $New)
    # A version change of a package already there is not a new dependency.
    $names = @{}; foreach ($d in $oldList) { $names[(Get-DependencyName $d)] = $true }
    @(Get-Added $oldList $newList | Where-Object { -not $names.ContainsKey((Get-DependencyName $_)) })
}

$script:RiskRules = @(
    @{ ext = '(?i)\.(html?|m?js|cjs|jsx|tsx?|vue|svelte)$'; re = '\beval\s*\('; why = 'eval() runs text as code' }
    @{ ext = '(?i)\.(html?|m?js|cjs|jsx|tsx?|vue|svelte)$'; re = '\bnew\s+Function\s*\('; why = 'new Function() runs text as code' }
    @{ ext = '(?i)\.(html?|m?js|cjs|jsx|tsx?|vue|svelte)$'; re = '\.(?:inner|outer)HTML\s*\+?=(?!\s*[''"][^''"\n]*[''"]\s*;?\s*$)\s*[^\s\n][^\n]*'; why = 'innerHTML set from a variable can run injected HTML and scripts (use textContent, or build elements)' }
    @{ ext = '(?i)\.(html?|m?js|cjs|jsx|tsx?|vue|svelte)$'; re = '\binsertAdjacentHTML\s*\(|\bdocument\.write(?:ln)?\s*\('; why = 'insertAdjacentHTML / document.write insert raw HTML' }
    @{ ext = '(?i)\.(jsx|tsx)$'; re = 'dangerouslySetInnerHTML'; why = 'dangerouslySetInnerHTML inserts raw HTML' }
    @{ ext = '(?i)\.ps[md]?1$'; re = '(?i)^\s*([^''"#\n]*[;|{(=]\s*)?(Invoke-Expression|iex)(\s|$)'; why = 'Invoke-Expression runs text as a command' }
    @{ ext = '(?i)\.pyw?$'; re = '(?<![\w.])(eval|exec)\s*\('; why = 'eval()/exec() run text as code' }
    @{ ext = '(?i)\.pyw?$'; re = '\bshell\s*=\s*True\b'; why = 'shell=True passes the command through the shell (injection risk)' }
    @{ ext = '(?i)\.pyw?$'; re = '\bos\.(system|popen)\s*\('; why = 'os.system/os.popen run a shell command' }
    @{ ext = '(?i)\.pyw?$'; re = '\b(c?pickle|marshal)\.loads?\s*\('; why = 'unpickling data can run code' }
    @{ ext = '(?i)\.pyw?$'; re = '\byaml\.load\s*\((?![^)\n]*Loader\s*=\s*(yaml\.)?SafeLoader)'; why = 'yaml.load without SafeLoader can run code (use yaml.safe_load)' }
    @{ ext = '(?i)\.(pyw?|m?js|cjs|jsx|tsx?|php|cs|java|rb|go)$'; re = '(?i)(\.(execute|query|raw|exec|executemany)\s*\(|\bSqlCommand\s*\()\s*(f["'']|["''][^"''\n]*\b(select|insert|update|delete)\b[^"''\n]*["'']\s*(\+|%|\.format)|`[^`\n]*\b(select|insert|update|delete)\b[^`\n]*\$\{)'; why = 'SQL built from strings is open to SQL injection (use query parameters)' }
)

function Get-RiskHits([string]$Rel, [string]$Text) {
    # "why|line text" for each risky line, so the same line elsewhere still counts as the same.
    if (-not "$Text") { return }
    $lines = "$Text".Replace("`r`n", "`n").Split("`n")
    foreach ($r in $script:RiskRules) {
        if ($Rel -notmatch $r.ext) { continue }
        foreach ($l in $lines) { if ($l -match $r.re -and $l.Trim() -notmatch '^(//|#|\*|<!--)') { "$($r.why)|$($l.Trim())" } }
    }
}

function Find-RiskyCode {
    <# Risky constructs a change adds: "line N: WHY". Comment lines do not count. #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    $added = @(Get-Added @(Get-RiskHits $Rel $Old) @(Get-RiskHits $Rel $New))
    if (-not $added.Count) { return }
    $lines = "$New".Replace("`r`n", "`n").Split("`n")
    $used = @{}
    foreach ($a in $added) {
        $why, $text = $a.Split('|', 2)
        $n = 0
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq $text -and -not $used["$i|$why"]) { $n = $i + 1; $used["$i|$why"] = $true; break } }
        "line ${n}: $why"
    }
}

$script:SmellRules = @(
    @{ ext = '(?i)\.(m?js|cjs|jsx|tsx?|vue|svelte|html?)$'; re = '^\s*debugger\s*;?\s*$'; why = 'a debugger statement left in (it stops the page when developer tools are open)' }
    @{ ext = '(?i)\.(m?js|cjs|jsx|tsx?|vue|svelte|html?)$'; re = '(?<![\w.$])alert\s*\('; why = 'an alert() pop-up (debug leftover?); show messages in the page instead' }
    @{ ext = '(?i)\.(m?js|cjs|jsx|tsx?)$'; re = '\b(it|describe|test|context|suite)\.only\s*\(|\b(fit|fdescribe)\s*\('; why = 'a focused test (.only / fit) makes every other test skip' }
    @{ ext = '(?i)\.pyw?$'; re = '^\s*(breakpoint\(\)|import\s+i?pdb\b|(i?pdb)\.set_trace\(\))'; why = 'a debugger breakpoint left in' }
    @{ ext = '(?i)\.ps[md]?1$'; re = '(?i)^\s*(Wait-Debugger|Set-PSBreakpoint)\b'; why = 'a debugger breakpoint left in' }
    @{ ext = '(?i)\.(cs|vb)$'; re = '\bDebugger\.(Break|Launch)\s*\('; why = 'a debugger break left in' }
)

function Find-ChangeSmells {
    <# Debug leftovers and swallowed errors a change adds: "line N: WHY". Empty catch blocks and
       except-pass are counted per file (a comment inside the catch explains it and is fine). #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    $out = New-Object System.Collections.Generic.List[string]
    $newText = "$New".Replace("`r`n", "`n"); $oldText = "$Old".Replace("`r`n", "`n")
    $newLines = $newText.Split("`n")
    foreach ($r in $script:SmellRules) {
        if ($Rel -notmatch $r.ext) { continue }
        $hits = { param($t) foreach ($l in $t.Split("`n")) { if ($l -match $r.re -and $l.Trim() -notmatch '^(//|#)') { $l.Trim() } } }
        foreach ($a in @(Get-Added @(& $hits $oldText) @(& $hits $newText))) {
            $n = 0; for ($i = 0; $i -lt $newLines.Count; $i++) { if ($newLines[$i].Trim() -eq $a) { $n = $i + 1; break } }
            $out.Add("line ${n}: $($r.why)")
        }
    }
    # Swallowed errors: count before and after; report the added ones at their line.
    $swallow = $null
    if ($Rel -match '(?i)\.(m?js|cjs|jsx|tsx?|vue|svelte|cs|java|kt|php|ps[md]?1)$') { $swallow = '\bcatch\s*(\([^)]*\))?\s*\{\s*\}' }
    elseif ($Rel -match '(?i)\.pyw?$') { $swallow = '(?m)^[ \t]*except\b[^:\n]*:[ \t]*(\n[ \t]*)?pass\b|(?m)^[ \t]*except[ \t]*:' }
    if ($swallow) {
        $before = ([regex]::Matches($oldText, $swallow)).Count
        $ms = @([regex]::Matches($newText, $swallow))
        if ($ms.Count -gt $before) {
            foreach ($m in ($ms | Select-Object -Last ($ms.Count - $before))) {
                $n = ([regex]::Matches($newText.Substring(0, $m.Index), "`n")).Count + 1
                $out.Add("line ${n}: an error is caught and silently ignored (empty catch / except: pass / bare except); handle it, log it, or catch only the expected error, and add a comment if ignoring is really right")
            }
        }
    }
    $out.ToArray()
}

function Find-UnignoredEnv {
    <# .env files among $Paths that .gitignore does not cover, in a project that uses git or has a
       .gitignore: "PATH: ..." for each. .env.example / .env.sample / .env.template are meant to be shared. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths)
    $envs = @($Paths | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') } | Where-Object { [IO.Path]::GetFileName($_) -match '^\.env(\..+)?$' -and [IO.Path]::GetFileName($_) -notmatch '(?i)\.(example|sample|template|dist)$' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $ProjectRoot $_.Replace('/', '\')) -PathType Leaf })
    if (-not $envs.Count) { return }
    $gi = Join-Path $ProjectRoot '.gitignore'
    $usesGit = (Test-Path -LiteralPath (Join-Path $ProjectRoot '.git')) -or (Test-Path -LiteralPath $gi)
    if (-not $usesGit) { return }
    $rules = if (Test-Path -LiteralPath $gi) { @([IO.File]::ReadAllLines($gi) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) } else { @() }
    foreach ($e in $envs) {
        $leaf = [IO.Path]::GetFileName($e)
        $covered = $false
        foreach ($r in $rules) {
            if ($r.StartsWith('!')) { continue }
            $pat = $r.TrimStart('/')
            if (($pat -eq $e) -or ($pat -eq $leaf) -or ($pat.Contains('*') -and (($leaf -like $pat) -or ($e -like $pat)))) { $covered = $true; break }
        }
        if (-not $covered) { "${e}: holds settings and secrets but .gitignore does not exclude it, so it would end up in git; add the line $leaf (or .env*) to .gitignore" }
    }
}

# --- Second batch: personal paths, large files and inline data, HTML basics, helper scripts,
# --- and the reminders at "done" (tests, README).

$script:QualityCodeExt = '(?i)\.(m?js|cjs|jsx|tsx?|vue|svelte|html?|css|scss|py|pyw|ps[md]?1|cs|java|kt|go|rs|php|rb|sh|bash|cmd|bat|json|ya?ml|toml|ini|config|xml)$'
$script:TestPathPattern = '(?i)(^|/)(tests?|__tests__|specs?)/|[._-](test|spec)s?\.[a-z0-9]+$|(^|/)test_[^/]+\.py$|_test\.(py|go)$|\.Tests\.ps1$'

function Get-LineIndex([string]$Text, [int]$Index) { ([regex]::Matches($Text.Substring(0, [Math]::Min($Index, $Text.Length)), "`n")).Count + 1 }

function Find-AddedKeyed {
    # Hits as "key|line" from both texts; returns "line N: message" for the hits the new text added.
    param([scriptblock]$Hits, [string]$Old, [string]$New)
    $oldKeys = @(& $Hits $Old | ForEach-Object { $_.key })
    $o = Get-Multiset $oldKeys
    foreach ($h in @(& $Hits $New)) { if ($o[$h.key]) { $o[$h.key]-- } else { "line $($h.line): $($h.msg)" } }
}

function Find-PersonalPaths {
    <# Absolute paths into a user's own folders (C:\Users\NAME, /home/NAME, /Users/NAME) that a
       change adds to code or config: the code breaks on any other PC and shows the user name. #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    if ($Rel -notmatch $script:QualityCodeExt -or $Rel -match '(?i)(^|/)\.env') { return }
    $hits = {
        param($t)
        foreach ($m in [regex]::Matches("$t", '(?i)(?<![\w%$])([a-z]:[\\/]+Users[\\/]+(?!Public\b|Default\b|All Users\b)[^\\/\s"''`<>|]+|/(home|Users)/(?!runner\b|shared\b)[a-z][\w.-]*)')) {
            $v = $m.Value
            @{ key = $v.ToLowerInvariant(); line = (Get-LineIndex "$t" $m.Index); msg = "an absolute path into a user's folder ($v...): it breaks on any other PC and shows the user name. Use a path relative to the project, or an environment variable or setting" }
        }
    }
    Find-AddedKeyed $hits $Old $New
}

function Find-LargeCode {
    <# A code file that a change makes longer than $MaxLines (split it), and a block of inline data
       of more than $MaxDataLines lines (move it to a data file). Data folders, tests, JSON and
       generated files are not counted. #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New, [int]$MaxLines = 400, [int]$MaxDataLines = 120)
    if ($Rel -notmatch '(?i)\.(m?js|cjs|jsx|tsx?|vue|svelte|py|ps[md]?1|cs|java|kt|go|rs|php|rb)$' -or $Rel -match $script:TestPathPattern -or $Rel -match '(?i)(^|/)data/|\.min\.|\.d\.ts$') { return }
    $count = { param($t) if ("$t") { "$t".Replace("`r`n", "`n").TrimEnd("`n").Split("`n").Length } else { 0 } }
    $n = & $count $New; $o = & $count $Old
    if ($n -gt $MaxLines -and $o -le $MaxLines) { "the file now has $n lines (over $MaxLines): split it into smaller files with one part each, joined by imports" }
    $run = {
        param($t)
        $best = 0; $cur = 0
        foreach ($l in "$t".Replace("`r`n", "`n").Split("`n")) {
            $x = $l.Trim()
            if ($x -match '^([\[\]{}](,|;)?|["''][^"'']*["'']\s*:.*|[\w$]+\s*:\s*(["''\d\[{-]|true|false|null).*|-?\d+(\.\d+)?\s*,?|["''][^"'']*["'']\s*,?|\{.*\},?|\[.*\],?)$') { $cur++; if ($cur -gt $best) { $best = $cur } } else { $cur = 0 }
        }
        $best
    }
    $nb = & $run $New; $ob = & $run $Old
    if ($nb -gt $MaxDataLines -and $ob -le $MaxDataLines) { "the file holds a block of $nb lines of inline data: move the data to a file in data/ (a .json file, or a data module for pages opened from disk) and load it" }
}

function Find-HtmlBasics {
    <# Accessibility basics a change adds to markup: an image without alt text, a button without
       text or label, a form field without a label. #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    if ($Rel -notmatch '(?i)\.(html?|jsx|tsx|vue|svelte)$') { return }
    $hits = {
        param($t)
        $t = "$t"
        foreach ($m in [regex]::Matches($t, '(?is)<img\b((?:\{(?:[^{}]|\{[^{}]*\})*\}|=>|[^>{])*)>')) {
            if ($m.Groups[1].Value -notmatch '(?i)\balt\s*=' -and $m.Groups[1].Value -notmatch '\{\s*\.\.\.') { @{ key = 'img|' + ($m.Value -replace '\s+', ' '); line = (Get-LineIndex $t $m.Index); msg = 'an image without alt text (alt="what it shows", or alt="" when it is decoration)' } }
        }
        foreach ($m in [regex]::Matches($t, '(?is)<button\b((?:\{(?:[^{}]|\{[^{}]*\})*\}|=>|[^>{])*)>(.*?)</button>')) {
            $attrs = $m.Groups[1].Value
            $inner = ($m.Groups[2].Value -replace '(?s)<svg\b.*?</svg>', '' -replace '<[^>]+>', '').Trim()
            if (-not $inner -and $attrs -notmatch '(?i)\b(aria-label|aria-labelledby|title)\s*=' -and $attrs -notmatch '\{\s*\.\.\.') { @{ key = 'btn|' + ($m.Value -replace '\s+', ' '); line = (Get-LineIndex $t $m.Index); msg = 'a button without text or aria-label (screen readers announce it as just "button")' } }
        }
        $forIds = @{}; foreach ($l in [regex]::Matches($t, '(?i)\b(for|htmlFor)\s*=\s*\{?["'']([^"'']+)["'']')) { $forIds[$l.Groups[2].Value] = $true }
        foreach ($m in [regex]::Matches($t, '(?is)<(input|select|textarea)\b((?:\{(?:[^{}]|\{[^{}]*\})*\}|=>|[^>{])*)>')) {
            $attrs = $m.Groups[2].Value
            if ($m.Groups[1].Value -ieq 'input' -and $attrs -match '(?i)\btype\s*=\s*["'']?(hidden|submit|button|image|reset)\b') { continue }
            if ($attrs -match '(?i)\b(aria-label|aria-labelledby|title)\s*=' -or $attrs -match '\{\s*\.\.\.') { continue }
            $id = [regex]::Match($attrs, '(?i)\bid\s*=\s*\{?["'']([^"'']+)["'']').Groups[1].Value
            if ($id -and $forIds.ContainsKey($id)) { continue }
            $before = $t.Substring(0, $m.Index)
            $open = $before.LastIndexOf('<label', [StringComparison]::OrdinalIgnoreCase)
            if ($open -ge 0 -and $before.IndexOf('</label', $open, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }   # inside a <label>
            @{ key = 'field|' + ($m.Value -replace '\s+', ' '); line = (Get-LineIndex $t $m.Index); msg = "a form field ($($m.Groups[1].Value.ToLowerInvariant())) without a label (a <label for=...>, a wrapping <label>, or aria-label)" }
        }
    }
    Find-AddedKeyed $hits $Old $New
}

function Find-ScriptBasics {
    <# A new helper script in Scripts/ needs a short header (what it does, how to run it) and must
       stop on errors (PowerShell: $ErrorActionPreference = 'Stop'; shell: set -e). #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    if ("$Old".Trim() -or $Rel -notmatch '(?i)^Scripts/.+\.(ps1|py|sh|bash|cmd|bat|m?js)$') { return }
    $head = (@("$New".Replace("`r`n", "`n").Split("`n") | Select-Object -First 15) -join "`n")
    $hasHeader = switch -Regex ($Rel) {
        '(?i)\.ps1$' { $head -match '(?m)^\s*(<#|#\s*\S)' }
        '(?i)\.py$' { $head -match '(?m)^\s*("""|''''''|#\s*\S)' }
        '(?i)\.(sh|bash)$' { $head -match '(?m)^\s*#(?!!)\s*\S' }
        '(?i)\.(cmd|bat)$' { $head -match '(?im)^\s*(@?rem\s+\S|::\s*\S)' }
        default { $head -match '(?m)^\s*(//\s*\S|/\*)' }
    }
    if (-not $hasHeader) { 'a new helper script needs a short comment at the top: what it does and how to run it' }
    if ($Rel -match '(?i)\.ps1$' -and "$New" -notmatch '(?i)\$ErrorActionPreference\s*=\s*[''"]Stop[''"]') { "the script does not stop on errors: add `$ErrorActionPreference = 'Stop' near the top" }
    if ($Rel -match '(?i)\.(sh|bash)$' -and "$New" -notmatch '(?m)^\s*set\s+-[a-z]*e') { 'the script does not stop on errors: add set -e (or set -euo pipefail) near the top' }
}

# Chart libraries a page or package adds (a script tag, an import or require, a constructor, a package.json entry).
$script:ChartLibraryPattern = '(?i)(<script[^>]+src=["''][^"'']*(\bchart(\.umd)?(\.min)?\.js|apexcharts|echarts|plotly|highcharts|amcharts|billboard|\bc3(\.min)?\.js)|\bfrom\s+["''](chart\.js(/auto)?|apexcharts|react-apexcharts|echarts|echarts-for-react|recharts|plotly\.js[\w./-]*|react-plotly\.js|highcharts[\w./-]*|@nivo/[\w-]+|victory|@visx/[\w-]+|react-chartjs-2)["'']|\brequire\(\s*["''](chart\.js|apexcharts|echarts|recharts|plotly\.js[\w./-]*|highcharts)["'']\s*\)|\bnew\s+(Chart|ApexCharts)\s*\(|\becharts\.init\s*\(|\bPlotly\.(newPlot|react)\s*\(|\bHighcharts\.chart\s*\(|^\s*"(chart\.js|apexcharts|react-apexcharts|echarts|echarts-for-react|recharts|plotly\.js[\w-]*|react-plotly\.js|highcharts|@nivo/[\w-]+|victory|react-chartjs-2)"\s*:)'
# Colours written into markup: a style attribute, a colour attribute, or a CSS declaration in a <style> block or style object.
$script:MarkupColorPattern = '(?i)(\bstyle\s*=\s*["''{][^>]*?(#[0-9a-f]{3,8}\b|\brgba?\(|\bhsla?\()|\b(fill|stroke|color|bgcolor|background|stop-color)\s*=\s*["''{]\s*["'']?\s*(#[0-9a-f]{3,8}\b|rgba?\(|hsla?\()|\b(color|background(-color)?|fill|stroke|border(-[a-z]+)*|outline(-color)?|box-shadow|stop-color)\s*:\s*[^;{}]*?(#[0-9a-f]{3,8}\b|\brgba?\(|\bhsla?\())'
# Type, corners and shadows written into styles instead of the kit's tokens (font-family, font-size in px/rem/pt,
# box-shadow with sizes, border-radius other than 0, a circle or a pill).
$script:FontFamilyPattern = '(?i)\bfont-?family\s*:\s*(?!\s*["'']?\s*(var\(|inherit\b|initial\b|unset\b))\S'
$script:FontSizePattern = '(?i)\bfont-?size\s*:\s*["'']?\s*\d*\.?\d+\s*(px|rem|pt)\b'
$script:ShadowPattern = '(?i)\bbox-?shadow\s*:\s*(?!\s*["'']?\s*(var\(|none\b|inherit\b|initial\b|unset\b))[^;]*?\d+(px|rem)'
$script:RadiusPattern = '(?i)\bborder-?(top-?|bottom-?)?(left-?|right-?)?radius\s*:\s*(?!\s*["'']?\s*(var\(|0(px)?\s*($|[;"''}])|50%|100%|9{3,}px|inherit\b|initial\b|unset\b))[^;]*?\d*\.?\d+(px|rem|em)\b'
# An emoji (pictographs, symbols, dingbats, arrows) as the first content of a button, heading, label, link or option.
$script:EmojiIconPattern = '(?i)<(button|h[1-6]|label|th|a|summary|legend|option)\b[^>]*>[^<]*?([\uD83C-\uD83E][\uDC00-\uDFFF]|[\u2600-\u27BF]|[\u2B05-\u2B07\u2B50\u2B55])'
# Colours in scripts: a string that is only a colour (chart settings, canvas fills, inline styles).
$script:ScriptColorPattern = '(?i)["''`]\s*(#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})|rgba?\([^)]*\)|hsla?\([^)]*\))\s*["''`]'

function Find-UiSlop {
    <# Interface patterns that make a page look generated, on the lines a change adds to a style,
       page or script file: gradient text, thick coloured side stripes, decorative blur. With the UI
       kit in the project (-UseKit): hard-coded colours other than the kit's own tokens (CSS, inline
       styles and colour attributes in markup, colour strings in scripts) and a chart library (it
       brings its own colours; the kit has charts). The kit's own files are left alone. #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New, [switch]$UseKit)
    $isPackage = $Rel -match '(?i)(^|/)package\.json$'
    if ($Rel -notmatch '(?i)\.(css|scss|less|html?|jsx|tsx|vue|svelte|m?js|cjs|ts)$' -and -not $isPackage) { return }
    if ($Rel -match '(?i)(^|/)(styles/kit/(?!tokens\.css$)|\.streamhub/|node_modules/)') { return }
    # The UI kit's tokens: colour pairs this change pushed below their WCAG contrast minimum.
    if ($Rel -match '(?i)(^|/)tokens\.css$' -and (Test-CheckSwitch 'contrast')) {
        $before = @(Test-TokenContrast $Old)
        foreach ($c in @(Test-TokenContrast $New)) { if ($before -notcontains $c) { $c } }
    }
    $had = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($l in "$Old".Replace("`r`n", "`n").Split("`n")) { [void]$had.Add($l.Trim()) }
    $lines = "$New".Replace("`r`n", "`n").Split("`n")
    $found = @{}
    $tokensFile = $Rel -match '(?i)(^|/)tokens\.css$'
    $slop = Test-UiKitPart 'slopChecks'      # Settings > UI kit
    $a11y = Test-CheckSwitch 'contrast'      # readability and accessibility
    $kitCharts = $slop -and $UseKit -and (Test-UiKitPart 'charts')
    $isStyle = $Rel -match '(?i)\.(css|scss|less)$'
    $isMarkup = $Rel -match '(?i)\.(html?|jsx|tsx|vue|svelte)$'
    $isScript = $Rel -match '(?i)\.(m?js|cjs|ts|jsx|tsx|vue|svelte)$'
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $t = $lines[$i].Trim()
        if (-not $t -or $had.Contains($t)) { continue }
        $n = $i + 1
        if ($kitCharts -and -not $found.chartlib -and $t -match $script:ChartLibraryPattern) { $found.chartlib = "line ${n}: a chart library brings its own colours and look; draw the chart with the kit's charts (styles/kit/kit-charts.js: KitCharts.bar (also stacked), line, area, ring, gauge, heatmap, sparkline, barlist; in React the Chart part from styles/kit/react/), which use the kit's colours and can filter the page on a click" }
        if ($isPackage) { continue }
        if ($slop -and -not $found.grad -and $t -match '(?i)background-clip\s*:\s*text') { $found.grad = "line ${n}: gradient text (background-clip: text) looks generated; use one solid colour and show emphasis with weight or size" }
        if ($slop -and -not $found.stripe -and $t -match '(?i)border-(left|right)(-width)?\s*:\s*([3-9]|\d{2,})px') { $found.stripe = "line ${n}: a thick side stripe on a box looks generated; use a full 1px border, a background tint or an icon" }
        if ($a11y -and -not $found.focus -and $t -match '(?i)outline\s*:\s*(none|0)\b' -and "$New" -notmatch '(?i)focus-visible[^{]*\{[^}]*(outline|box-shadow|border)') { $found.focus = "line ${n}: the focus outline is removed without a replacement; keyboard users can no longer see where they are (add a :focus-visible style)" }
        if ($a11y -and -not $found.motion -and $t -match '(?i)(^|[\s;{])animation\s*:(?!\s*none)' -and "$New" -notmatch 'prefers-reduced-motion') { $found.motion = "line ${n}: an animation without a reduced-motion version; add @media (prefers-reduced-motion: reduce) to stop or shorten it" }
        if ($slop -and $UseKit -and -not $tokensFile -and -not $found.gradient -and $t -match '(?i)\b(linear|radial|conic)-gradient\(' -and $t -notmatch '(?i)background-clip\s*:\s*text') { $found.gradient = "line ${n}: a gradient other than the kit's own; use var(--kit-gradient) or a plain colour" }
        if ($slop -and -not $found.caps -and ($t -match '(?i)text-transform\s*:\s*uppercase' -or $t -cmatch '<(h[1-6]|th|label|button|legend|summary)\b[^>]*>\s*[A-Z][A-Z0-9&/ .-]{3,}\s*</')) { $found.caps = "line ${n}: a heading or label in capitals; write it in sentence case (Totals, not TOTALS) and leave out text-transform: uppercase" }
        if ($slop -and $UseKit -and -not $tokensFile -and ($isStyle -or $isMarkup)) {
            if (-not $found.font -and $t -match $script:FontFamilyPattern) { $found.font = "line ${n}: a font of your own; the kit's type is var(--kit-font) (var(--kit-font-mono) for code), already set on kit-page: leave font-family out or use the token" }
            if (-not $found.fontsize -and $t -match $script:FontSizePattern) { $found.fontsize = "line ${n}: a hard-coded font size; use the kit's steps var(--kit-text-xs), -sm, -md, -lg, -xl (or the classes kit-h1, kit-h2, kit-h3, kit-small)" }
            if (-not $found.shadow -and $t -notmatch 'var\(--kit-' -and $t -match $script:ShadowPattern) { $found.shadow = "line ${n}: a shadow of your own; use var(--kit-shadow), or none (the kit's surfaces have a 1px border instead)" }
            if (-not $found.radius -and $t -match $script:RadiusPattern) { $found.radius = "line ${n}: hard-coded rounded corners; use var(--kit-radius) or var(--kit-radius-lg) (999px for a pill)" }
        }
        if ($slop -and $isMarkup -and -not $found.emoji -and $t -match $script:EmojiIconPattern) {
            $found.emoji = if ($UseKit -and (Test-UiKitPart 'icons')) { "line ${n}: an emoji used as an icon (in a button, heading, label or link); use a kit icon, <span data-kit-icon=`"NAME`" aria-hidden=`"true`"></span> with a Lucide name, or leave it out" }
                else { "line ${n}: an emoji used as an icon (in a button, heading, label or link); emoji look different on every system and screen readers read out their names: use an SVG icon with aria-hidden=`"true`", or leave it out" }
        }
        if ($slop -and -not $found.blur -and $t -match '(?i)backdrop-filter\s*:\s*blur') { $found.blur = "line ${n}: a decorative blur (glass effect) looks generated; use a plain surface" }
        if ($slop -and $UseKit -and -not $tokensFile -and -not $found.color -and $isStyle -and $t -match '(?i)(#[0-9a-f]{3,8}\b|\brgba?\(|\bhsla?\()' -and $t -notmatch 'var\(--kit-') { $found.color = "line ${n}: a hard-coded colour; use a token from styles/kit/tokens.css (var(--kit-...)) so the page follows the kit" }
        if ($slop -and $UseKit -and -not $found.color -and -not $isStyle -and $t -notmatch 'var\(--kit-' -and (($isMarkup -and $t -match $script:MarkupColorPattern) -or ($isScript -and $t -match $script:ScriptColorPattern))) { $found.color = "line ${n}: a hard-coded colour; use a kit token instead: var(--kit-...) in styles, var(--kit-chart-1) to var(--kit-chart-6) in order for chart series (in canvas code read them with getComputedStyle(document.documentElement).getPropertyValue(`"--kit-chart-1`")), so the page follows the kit in light and dark" }
    }
    @($found.Values)
}

function Find-PageCopyScript {
    <# A helper script (Work/, Scripts/) that writes a whole page from a copy inside itself: running
       it again later undoes every change made to the page since (seen in the session review). #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    if ($Rel -notmatch '(?i)^(Work|Scripts)/.+\.(ps1|py|m?js|cjs|cmd|bat|sh)$') { return }
    $tagLines = @(("$New").Split("`n") | Where-Object { $_ -match '^\s*</?(html|head|body|div|section|header|main|nav|table|script|style|span|button|ul|li|h[1-6]|p|footer|form|label|input)\b' }).Count
    if ($tagLines -lt 25) { return }
    $target = [regex]::Match("$New", '(?i)(Set-Content|Out-File|WriteAllText|writeFileSync|writeFile|open\()[^\n]{0,160}?([\w./\\-]+\.html?)')
    if (-not $target.Success) { return }
    "this script writes a whole copy of $($target.Groups[2].Value) ($tagLines lines of markup inside it): running it again later undoes every change made to that page since. Change the page with edit blocks instead, and delete this script once it has done its job"
}

function Find-KitBypass {
    <# With the UI kit in the project: plain elements a change adds to markup without a kit class (a
       table, button, field, list box, text area or dialog), which drop out of the kit's look. One
       finding per kind of element; any kit- class counts (kit-btn, kit-tab, kit-chip ...). #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    if ($Rel -notmatch '(?i)\.(html?|jsx|tsx|vue|svelte)$' -or $Rel -match '(?i)(^|/)(styles/kit/|\.streamhub/|node_modules/)') { return }
    if (-not (Test-UiKitPart 'slopChecks')) { return }
    $hits = {
        param($t)
        foreach ($m in [regex]::Matches("$t", '(?s)<(table|button|input|select|textarea|dialog)\b((?:\{(?:[^{}]|\{[^{}]*\})*\}|=>|[^>{])*)>')) {
            $tag = $m.Groups[1].Value.ToLowerInvariant(); $attrs = $m.Groups[2].Value
            if ($attrs -match '\{\s*\.\.\.' -or $attrs -match '(?i)\bclass(Name)?\s*=[^>]*?\bkit-') { continue }
            if ($tag -eq 'input' -and $attrs -match '(?i)\btype\s*=\s*\{?\s*["'']?(hidden|checkbox|radio|range|color|file|submit|button|reset|image)\b') { continue }
            @{ key = $tag; line = (Get-LineIndex "$t" $m.Index); msg = $script:KitBypassHints[$tag] }
        }
    }
    $seen = @{}
    foreach ($f in @(Find-AddedKeyed $hits $Old $New)) {
        $k = $f -replace '^line \d+: ', ''
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $f }
    }
}
$script:KitBypassHints = @{
    table    = 'a table without the kit''s class: <table class="kit-table"> inside <div class="kit-table-wrap">, with data-kit-sort and data-kit-pages="N" (kit.js) for sorting and pages, and an empty-state row'
    button   = 'a button without a kit class: class="kit-btn" (kit-btn--primary for the one main action, kit-btn--ghost, kit-btn--danger, kit-btn--sm)'
    input    = 'a field without the kit''s class: class="kit-input", with a kit-label above it in a kit-field'
    select   = 'a list box without the kit''s class: class="kit-select", with a kit-label above it in a kit-field'
    textarea = 'a text area without the kit''s class: class="kit-textarea", with a kit-label above it in a kit-field'
    dialog   = 'a dialog without the kit''s class: <dialog class="kit-dialog"> with its buttons in kit-dialog__actions'
}

function Find-QualityIssues {
    <# The second batch, for the round's file check: what a change adds, as "line N: ..." or a
       whole-file note. #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New, [switch]$UseKit)
    @(Find-PersonalPaths $Rel $Old $New) + @(Find-LargeCode $Rel $Old $New) + @(Find-HtmlBasics $Rel $Old $New) + @(Find-ScriptBasics $Rel $Old $New) + @(Find-PageCopyScript $Rel $Old $New) + @(Find-UiSlop $Rel $Old $New -UseKit:$UseKit) + @(if ($UseKit) { Find-KitBypass $Rel $Old $New }) | Where-Object { $_ }
}

function Get-DoneReminders {
    <# One reminder when a task says done (sent once per task): code changed but no test, in a
       project that has tests; a new part in src/ or Scripts/ while README.md stayed the same.
       $Files: rel path -> 'new' or 'existed' (the task's change set). Returns '' when all is well. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, $Files, [string[]]$ProjectPaths)
    $changed = @($Files.Keys | ForEach-Object { "$_".Replace('\', '/') })
    if (-not $changed.Count) { return '' }
    if (-not $PSBoundParameters.ContainsKey('ProjectPaths')) { $ProjectPaths = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|dist|\.streamhub|source)\\' } | Select-Object -First 3000 | ForEach-Object { $_.FullName.Substring($ProjectRoot.TrimEnd('\').Length + 1).Replace('\', '/') }) }
    $notes = New-Object System.Collections.Generic.List[string]
    $code = @($changed | Where-Object { $_ -match '(?i)\.(m?js|cjs|jsx|tsx?|vue|svelte|py|ps[md]?1|cs|java|kt|go|rs|php|rb)$' -and $_ -notmatch $script:TestPathPattern -and $_ -notmatch '(?i)^(Scripts|Runbooks|History|Logs|docs)/' })
    $tests = @($changed | Where-Object { $_ -match $script:TestPathPattern })
    $hasTests = @($ProjectPaths | Where-Object { $_ -match $script:TestPathPattern }).Count -gt 0
    if ($code.Count -and -not $tests.Count -and $hasTests) {
        $notes.Add("You changed code ($(($code | Select-Object -First 4) -join ', ')) but no test, and this project has tests. Add or update a test for the change; if no test is needed, say why in your done block.")
    }
    $readme = @($ProjectPaths | Where-Object { $_ -match '(?i)^README\.md$' }) | Select-Object -First 1
    $newParts = @($changed | Where-Object { $Files[$_] -eq 'new' -and $_ -match '(?i)^(src|Scripts)/' -and $_ -notmatch $script:TestPathPattern })
    if ($readme -and $newParts.Count -and -not @($changed | Where-Object { $_ -match '(?i)^README\.md$' }).Count) {
        $notes.Add("You added $(($newParts | Select-Object -First 4) -join ', '), and README.md does not mention the change. Add a short line to README.md if users or developers need to know about it; if not, say so in your done block.")
    }
    # Every table and chart a page shows needs an empty state (design rules): the changed page files
    # show a table or draw a chart, and none of them has one. The kit's charts bring their own.
    $views = @($changed | Where-Object { $_ -match '(?i)\.(html?|jsx|tsx|vue|svelte|m?js)$' -and $_ -notmatch $script:TestPathPattern -and $_ -notmatch '(?i)(^|/)(styles/kit|node_modules|dist|build|\.streamhub)/' } | Select-Object -First 20)
    $texts = @(foreach ($v in $views) {
        $f = Join-Path $ProjectRoot $v.Replace('/', '\')
        if ((Test-Path -LiteralPath $f -PathType Leaf) -and (Get-Item -LiteralPath $f).Length -lt 1MB) { [pscustomobject]@{ rel = $v; text = [IO.File]::ReadAllText($f) } }
    })
    $shows = @($texts | Where-Object { $_.text -match '(?i)<table\b|\bkit-table\b|<canvas\b|createElement\(\s*["'']table|\.insertRow\(' })
    if ($shows.Count -and -not @($texts | Where-Object { $_.text -match '(?i)kit-empty|data-kit-empty|\bno (items|rows|results|data|records|matches|entries)\b|\bnothing (to show|here|found|yet)\b|\bempty[ -]?state\b' }).Count) {
        $how = if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'styles\kit\tokens.css')) { 'a <tr data-kit-empty> row with a kit-empty block (what is missing and the one next step; see the table section of .streamhub/ui-kit/kit-examples.html)' } else { 'a short message in its place that says what is missing and the one next step' }
        $notes.Add("$(($shows | Select-Object -First 3 | ForEach-Object { $_.rel }) -join ', ') shows a table or chart but has no empty state. Add $how for when there is nothing to show, and a loading and an error message if the data is loaded; if it can never be empty, say why in your done block.")
    }
    if (-not $notes.Count) { return '' }
    "Before finishing, one check:`n- " + ($notes -join "`n- ") + "`nThen send done again."
}

Export-ModuleMember -Function Find-KitBypass, Find-PageCopyScript, Find-UiSlop, Test-GeneratedPath, Find-NewDependencies, Find-RiskyCode, Find-ChangeSmells, Find-UnignoredEnv, Find-PersonalPaths, Find-LargeCode, Find-HtmlBasics, Find-ScriptBasics, Find-QualityIssues, Get-DoneReminders
