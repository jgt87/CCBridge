# Code review: fixed rules around Copilot's review (it has no judgement of its own).
#   Get-ReviewFiles   which files are reviewed (code and config; no build output, data or binaries)
#   New-ReviewBatches files split into messages that fit, with line numbers; large files in parts
#   Test-ReviewOutput the JSON Copilot sends back (findings + summary)
#   Test-ReviewQuote  a finding counts as verified only when the lines it quotes are in the file;
#                     its line number is corrected to where they are
#   Format-ReviewReport / Save-Review  reviews/review-<date>.md and .json in the project
#   New-ReviewFixTasks the coding tasks for the findings the user picks

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')
Import-Module (Join-Path $PSScriptRoot 'Executor.psm1')

$script:ReviewExt = '(?i)\.(ps1|psm1|psd1|py|pyw|js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte|html?|css|scss|less|json|cs|java|kt|go|rs|rb|php|sh|bash|cmd|bat|sql|ya?ml|toml|ini|xml|c|cpp|h|hpp|swift|dart|lua|r)$'
$script:ReviewSkipPath = '(?i)(^|/)(source|reviews|evidence|exports|fetch|runbooks|node_modules|dist|build|out|bin|obj|coverage|vendor|\.git|\.next|\.venv|venv|__pycache__)/|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|poetry\.lock)$|\.min\.(js|css)$|\.map$'
$script:Severity = @{ high = 0; medium = 1; low = 2 }

function Get-ReviewFiles {
    <# Files to review: code and configuration under the project, without build output, lock files,
       minified files, StreamHub's own folders (reviews, exports, fetch, runbooks), read-only
       source/ data and binaries. Larger than $MaxBytes is skipped as probably generated.
       Returns @{ files; skipped }. With $Paths only those files and folders are taken. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths, [int]$MaxBytes = 300000)
    $all = @(Get-ProjectFiles $ProjectRoot)
    $want = @($Paths | Where-Object { $_ } | ForEach-Object { $_.Trim().Replace('\', '/').Trim('/') })
    $files = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($f in $all) {
        $p = $f.path
        if ($want.Count -and -not @($want | Where-Object { $p -eq $_ -or $p.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
        if ($p -notmatch $script:ReviewExt -or $p -match $script:ReviewSkipPath) { continue }
        if ([int64]$f.size -gt $MaxBytes) { $skipped.Add("$p (too large, probably generated)"); continue }
        $files.Add($p)
    }
    @{ files = $files.ToArray(); skipped = $skipped.ToArray() }
}

function Format-NumberedLines([string[]]$Lines, [int]$From) {
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $Lines.Count; $i++) { [void]$sb.Append(('{0,5}| ' -f ($From + $i))).Append($Lines[$i]).Append("`n") }
    $sb.ToString()
}

function New-ReviewBatches {
    <# Files grouped into messages of at most $Budget characters, with line numbers. A file larger
       than the budget is split into consecutive line ranges. Returns a list of
       @{ index; files = @('path', ...); text }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Files, [int]$Budget = 40000)
    $batches = New-Object System.Collections.Generic.List[object]
    $cur = New-Object Text.StringBuilder
    $curFiles = New-Object System.Collections.Generic.List[string]
    $flush = {
        if ($cur.Length) { $batches.Add(@{ index = $batches.Count + 1; files = @($curFiles | Select-Object -Unique); text = $cur.ToString() }); [void]$cur.Clear(); $curFiles.Clear() }
    }
    foreach ($rel in $Files) {
        $full = Resolve-ProjectPath $ProjectRoot $rel
        $text = (Read-TextFile $full).Text.Replace("`r`n", "`n")
        $lines = $text.TrimEnd("`n").Split("`n")
        $n = $lines.Count
        $numbered = Format-NumberedLines $lines 1
        $block = "=== FILE $rel (lines 1-$n of $n) ===`n$numbered"
        if ($block.Length -le $Budget) {
            if ($cur.Length + $block.Length -gt $Budget) { & $flush }
            [void]$cur.Append($block).Append("`n"); $curFiles.Add($rel)
            continue
        }
        # Larger than one message: parts of about the budget each, cut at whole lines.
        & $flush
        $start = 0
        while ($start -lt $n) {
            $size = 0; $end = $start
            while ($end -lt $n -and ($size + $lines[$end].Length + 8) -le ($Budget - 200)) { $size += $lines[$end].Length + 8; $end++ }
            if ($end -eq $start) { $end = $start + 1 }
            $part = Format-NumberedLines $lines[$start..($end - 1)] ($start + 1)
            $batches.Add(@{ index = $batches.Count + 1; files = @($rel); text = "=== FILE $rel (lines $($start + 1)-$end of $n) ===`n$part" })
            $start = $end
        }
    }
    & $flush
    $batches.ToArray()
}

function Test-ReviewOutput {
    <# Copilot's review JSON: {"findings": [...], "summary": "..."}. Returns @{ ok; errors; findings;
       summary; dropped }. Findings without a file and title are dropped; severity is high, medium
       or low (anything else becomes low). #>
    param([AllowEmptyString()][string]$Json)
    if (-not "$Json".Trim()) { return @{ ok = $false; errors = @('the reply contains no JSON code block'); findings = @(); dropped = 0 } }
    try { $data = $Json | ConvertFrom-Json } catch { return @{ ok = $false; errors = @("the JSON does not parse: $($_.Exception.Message.Split("`n")[0])"); findings = @(); dropped = 0 } }
    if ($data -isnot [pscustomobject] -or -not $data.PSObject.Properties['findings']) { return @{ ok = $false; errors = @('the top-level key "findings" is missing'); findings = @(); dropped = 0 } }
    $out = New-Object System.Collections.Generic.List[object]
    $dropped = 0
    foreach ($f in @($data.findings | Where-Object { $null -ne $_ })) {
        if (-not "$($f.title)".Trim()) { $dropped++; continue }
        $sev = "$($f.severity)".ToLowerInvariant().Trim()
        if (-not $script:Severity.ContainsKey($sev)) { $sev = if ($sev -match 'crit|block|major|error') { 'high' } elseif ($sev -match 'warn|moder') { 'medium' } else { 'low' } }
        $line = 0; [void][int]::TryParse("$($f.line)", [ref]$line)
        $out.Add(@{ file = "$($f.file)".Trim().Replace('\', '/').TrimStart('/'); line = $line; severity = $sev; category = "$($f.category)".ToLowerInvariant().Trim()
            title = "$($f.title)".Trim(); detail = "$($f.detail)".Trim(); quote = "$($f.quote)"; suggestion = "$($f.suggestion)".Trim() })
    }
    @{ ok = $true; errors = @(); findings = $out.ToArray(); summary = "$($data.summary)".Trim(); dropped = $dropped }
}

function Test-ReviewQuote {
    <# Verifies a finding: the lines it quotes must be in the file (indentation and line-number
       prefixes ignored). Sets status 'verified' with the real line, 'general' for a finding without
       a file or quote from the whole-project pass, or 'unverified' with the reason. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][hashtable]$Finding, [switch]$AllowGeneral)
    $q = @("$($Finding.quote)".Replace("`r`n", "`n").Split("`n") | ForEach-Object { ($_ -replace '^\s*\d+\s*\|\s?', '').Trim() } | Where-Object { $_ })
    if (-not $Finding.file -or -not $q.Count) {
        if ($AllowGeneral -and -not $q.Count) { $Finding.status = 'general'; return $Finding }
        $Finding.status = 'unverified'; $Finding.reason = 'no file or no quoted lines'; return $Finding
    }
    $full = try { Resolve-ProjectPath $ProjectRoot $Finding.file } catch { $null }
    if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { $Finding.status = 'unverified'; $Finding.reason = "file $($Finding.file) not found"; return $Finding }
    $lines = @((Read-TextFile $full).Text.Replace("`r`n", "`n").Split("`n") | ForEach-Object { $_.Trim() })
    $hits = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -le $lines.Count - $q.Count; $i++) {
        $ok = $true; $j = 0; $k = $i
        while ($j -lt $q.Count -and $k -lt $lines.Count) {
            if (-not $lines[$k]) { $k++; continue }   # blank lines in the file may be left out of the quote
            if ($lines[$k] -ne $q[$j]) { $ok = $false; break }
            $j++; $k++
        }
        if ($ok -and $j -eq $q.Count) { $hits.Add($i + 1) }
    }
    if (-not $hits.Count) { $Finding.status = 'unverified'; $Finding.reason = 'the quoted lines are not in the file'; return $Finding }
    $want = [int]$Finding.line
    $best = $hits | Sort-Object { [Math]::Abs($_ - $want) } | Select-Object -First 1
    if ($want -and $best -ne $want) { $Finding.reportedLine = $want }
    $Finding.line = $best
    $Finding.status = 'verified'
    $Finding
}

function Format-ReviewReport {
    <# The review as Markdown: summary, then findings by severity, unverified ones last. #>
    param([Parameter(Mandatory)]$Review)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("# Code review $($Review.created.Replace('T', ' '))").AppendLine()
    [void]$sb.AppendLine("Scope: $($Review.scopeText). Files reviewed: $(@($Review.files).Count). Copilot messages: $($Review.messages). Focus: $(@($Review.focus) -join ', ').").AppendLine()
    $ok = @($Review.findings | Where-Object { $_.status -ne 'unverified' })
    $bad = @($Review.findings | Where-Object { $_.status -eq 'unverified' })
    [void]$sb.AppendLine("Findings: $($ok.Count) ($(@($ok | Where-Object severity -eq 'high').Count) high, $(@($ok | Where-Object severity -eq 'medium').Count) medium, $(@($ok | Where-Object severity -eq 'low').Count) low)$(if ($bad.Count) { "; $($bad.Count) unverified (the quoted code is not in the file)" }).").AppendLine()
    if ($Review.overall) { [void]$sb.AppendLine('## Summary').AppendLine().AppendLine($Review.overall).AppendLine() }
    foreach ($sev in 'high', 'medium', 'low') {
        $list = @($ok | Where-Object severity -eq $sev)
        if (-not $list.Count) { continue }
        [void]$sb.AppendLine("## $($sev.Substring(0,1).ToUpper())$($sev.Substring(1))").AppendLine()
        foreach ($f in $list) { [void]$sb.Append((Format-ReviewFinding $f)) }
    }
    if ($bad.Count) {
        [void]$sb.AppendLine('## Unverified').AppendLine().AppendLine('Copilot quoted code that is not in the file; these may be mistaken.').AppendLine()
        foreach ($f in $bad) { [void]$sb.Append((Format-ReviewFinding $f)) }
    }
    if (@($Review.skipped).Count) { [void]$sb.AppendLine('## Not reviewed').AppendLine(); foreach ($s in $Review.skipped) { [void]$sb.AppendLine("- $s") } }
    $sb.ToString()
}

function Format-ReviewFinding($F) {
    $where = if ($F.file) { "``$($F.file)$(if ($F.line) { ":$($F.line)" })``" } else { 'whole project' }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("- [ ] **$($F.title)** - $where$(if ($F.category) { " ($($F.category))" }) [$($F.id)]")
    if ($F.detail) { [void]$sb.AppendLine("  $($F.detail)") }
    if ($F.suggestion) { [void]$sb.AppendLine("  Suggestion: $($F.suggestion)") }
    if ($F.quote) { [void]$sb.AppendLine('  ```').AppendLine(("  " + ("$($F.quote)".TrimEnd() -replace "`n", "`n  "))).AppendLine('  ```') }
    [void]$sb.AppendLine()
    $sb.ToString()
}

function Get-SortedFindings($Findings) {
    <# High first, then by file and line; ids f1, f2, ... in that order. #>
    $i = 0
    foreach ($f in @($Findings | Sort-Object @{ Expression = { if ($_.status -eq 'unverified') { 1 } else { 0 } } }, @{ Expression = { $script:Severity[$_.severity] } }, @{ Expression = { $_.file } }, @{ Expression = { [int]$_.line } })) {
        $i++; $f.id = "f$i"; $f
    }
}

function Save-Review {
    <# Writes reviews/review-<stamp>.md and .json in the project. Returns the two relative paths. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Review)
    $dir = Join-Path $ProjectRoot 'reviews'
    $null = New-Item -ItemType Directory -Force -Path $dir
    $md = "reviews/$($Review.id).md"; $json = "reviews/$($Review.id).json"
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Resolve-ProjectPath $ProjectRoot $md), (Format-ReviewReport $Review), $enc)
    [IO.File]::WriteAllText((Resolve-ProjectPath $ProjectRoot $json), (ConvertTo-Json -InputObject $Review -Depth 6), $enc)
    @{ md = $md; json = $json }
}

function Get-Reviews {
    <# The project's reviews, newest first: id, created, scope, counts, report path. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $dir = Join-Path $ProjectRoot 'reviews'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'review-*.json' -File | Sort-Object Name -Descending)) {
        try {
            $r = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
            $ok = @($r.findings | Where-Object { $_.status -ne 'unverified' })
            [pscustomobject]@{ id = $r.id; created = $r.created; scopeText = $r.scopeText; files = @($r.files).Count; messages = $r.messages
                high = @($ok | Where-Object severity -eq 'high').Count; medium = @($ok | Where-Object severity -eq 'medium').Count; low = @($ok | Where-Object severity -eq 'low').Count
                unverified = @($r.findings).Count - $ok.Count; report = "reviews/$($r.id).md" }
        } catch { }
    }
}

function New-ReviewFixTasks {
    <# Coding tasks for the chosen findings: grouped by file, at most $PerTask findings each. Every
       task says what is wrong, where, the current code and the suggested fix, and that a finding
       whose code is already right is skipped (and said so). Returns @{ title; text } per task. #>
    param([Parameter(Mandatory)]$Findings, [int]$PerTask = 6)
    $groups = @($Findings | Group-Object { if ($_.file) { $_.file } else { '(project)' } })
    foreach ($g in $groups) {
        $items = @($g.Group)
        for ($s = 0; $s -lt $items.Count; $s += $PerTask) {
            $part = @($items[$s..([Math]::Min($items.Count, $s + $PerTask) - 1)])
            $sb = New-Object Text.StringBuilder
            [void]$sb.AppendLine('Fix these findings from a code review. For each one: read the code around the line, make the fix with edit blocks, and keep the rest of the code as it is. If a finding turns out to be wrong or already fixed, leave the code and say why in the done summary.').AppendLine()
            $n = 0
            foreach ($f in $part) {
                $n++
                $where = if ($f.file) { "$($f.file)$(if ($f.line) { ":$($f.line)" })" } else { 'the project' }
                [void]$sb.AppendLine("$n. $where - $($f.title) ($($f.severity)$(if ($f.category) { ", $($f.category)" }))")
                if ($f.detail) { [void]$sb.AppendLine("   Problem: $($f.detail)") }
                if ($f.suggestion) { [void]$sb.AppendLine("   Suggested fix: $($f.suggestion)") }
                if ($f.quote) { [void]$sb.AppendLine('   Current code:').AppendLine('   ```').AppendLine(('   ' + ("$($f.quote)".TrimEnd() -replace "`n", "`n   "))).AppendLine('   ```') }
            }
            @{ title = "Fix review findings: $($g.Name) ($($part.Count))"; text = $sb.ToString().TrimEnd(); ids = @($part | ForEach-Object { $_.id }) }
        }
    }
}

Export-ModuleMember -Function Get-ReviewFiles, New-ReviewBatches, Test-ReviewOutput, Test-ReviewQuote, Format-ReviewReport, Get-SortedFindings, Save-Review, Get-Reviews, New-ReviewFixTasks
