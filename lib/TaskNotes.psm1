# What Copilot writes down for the helper program to keep and check (fixed rules on its text):
#   - "Done when:" lines: the checks a task must pass, taken from the request at its start, which
#     Copilot answers MET / NOT MET at "done" (with the screenshot), kept in the task report.
#   - "Data notes:" lines: what the project's converted data means (rows, keys, how files join,
#     values to watch), asked once per data file and again when its data changed, saved in
#     .streamhub/data-notes.json and sent with every later task.
# StreamHub has no model of its own: these only read and store what Copilot wrote. A Done when line
# about a file ('PATH contains TEXT', 'PATH exists' and their negations) is checked by the helper
# program itself (Test-DoneWhenCheck), so Copilot does not grade its own work there.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')

function Read-NoteBlock([AllowEmptyString()][string]$Text, [string]$Heading, [int]$Max = 12) {
    <# The list under a heading line ("Done when:", "Data notes:"), outside code blocks: the "- " or
       "1. " lines that follow it, without their marks, up to $Max. Empty when there is none. #>
    $lines = "$Text".Replace("`r`n", "`n").Split("`n")
    $out = New-Object System.Collections.Generic.List[string]
    $inCode = $false; $inBlock = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*(```|~~~)') { $inCode = -not $inCode; if ($inBlock) { break }; continue }
        if ($inCode) { continue }
        if (-not $inBlock) {
            if ($l -match ('^[\s>*_#]*' + [regex]::Escape($Heading) + '[\s*_]*:?[\s*_]*$')) { $inBlock = $true }
            continue
        }
        if ($l -match '^\s*([-*+]|\d+[.)])\s+(.+)$') {
            $item = ($Matches[2] -replace '^\[[ xX]\]\s*', '' -replace '\*\*', '').Trim()
            if ($item) { $out.Add($item) }
            if ($out.Count -ge $Max) { break }
            continue
        }
        if (-not $l.Trim()) { if ($out.Count) { break } else { continue } }
        if ($out.Count -and $l -match '^\s{2,}\S') { $out[$out.Count - 1] += ' ' + $l.Trim(); continue }   # a wrapped item
        break
    }
    $out.ToArray()
}

# --- Done when -------------------------------------------------------------------------------

function Get-DoneWhenAsk {
    # The line that goes with a build or change request: the checks, before any file is written.
    "Before you change files, write a line 'Done when:' and under it 2 to 5 checks taken from this request that someone could confirm on the page or in the files (for example: '- the page shows a chart of ITEMS per GROUP'), each a '- ' line. Where a check is about a file, write it as 'PATH contains ""TEXT""', 'PATH does not contain ""TEXT""', 'PATH exists' or 'PATH does not exist' (PATH relative to the project, TEXT in quotes exactly as it will be in the file): the helper program checks those itself. You will be asked about each one at the end. Then go on with the work in the same reply (action blocks): the list alone does not finish the reply."
}

function Read-DoneWhen([AllowEmptyString()][string]$Text) {
    # The checks Copilot listed under "Done when:" (at most 6), or nothing.
    @(Read-NoteBlock $Text 'Done when' 6)
}

function New-AcceptanceAsk([string[]]$Checks, $Helper = @()) {
    <# The question at "done": each check as MET or NOT MET, fixing what is not met first. $Helper:
       results of the checks the helper program made itself (Test-DoneWhenCheck); the ones not met
       are named to be fixed, the met ones are not asked. '' when there is nothing to ask. #>
    $own = @(@($Helper) | Where-Object { $_ } | ForEach-Object { "$($_.check)" })
    $ask = @(@($Checks) | Where-Object { "$_".Trim() -and $own -notcontains "$_" })
    $failed = @(@($Helper) | Where-Object { $_ -and $_.met -eq $false })
    $parts = New-Object System.Collections.Generic.List[string]
    if ($failed.Count) {
        $parts.Add("The helper program checked these 'Done when' lines in the files itself, and they are NOT MET:`n" + ((@($failed) | ForEach-Object { "- $($_.check) ($($_.note))" }) -join "`n") + "`nFix them now with action blocks.")
    }
    if ($ask.Count) {
        $list = (@($ask) | ForEach-Object { "- $_" }) -join "`n"
        $parts.Add("Check each 'Done when' line you wrote at the start against the files and the page as they are now (the screenshot, if one is attached):`n$list`nAnswer each on its own line as 'MET: CHECK' or 'NOT MET: CHECK - why'. If one is not met, fix it now with action blocks and answer again after the fix; then send done.")
    } elseif ($failed.Count) { $parts.Add('Then send done.') }
    $parts -join "`n`n"
}

function Test-DoneWhenCheck {
    <# A Done when line the helper program can check in the files itself: 'PATH exists', 'PATH does
       not exist', 'PATH contains "TEXT"', 'PATH does not contain "TEXT"' (TEXT in quotes or backticks;
       PATH may be too; 'the file PATH' and includes/does not include as well). @{ check; met; note;
       by = 'helper' }, or $null for any other line. PATH must stay inside the project
       (Resolve-ProjectPath). -Literal (a test run's 'expect:') takes an unquoted TEXT as the text. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [AllowEmptyString()][string]$Check, [switch]$Literal)
    $m = [regex]::Match("$Check".Trim(), '^(?i)(?:the\s+file\s+)?[`"'']?(?<path>[\w.\-/\\]*[\w\-]\.[A-Za-z0-9]{1,8}|[\w.\-]+(?:[/\\][\w.\-]+)+)[`"'']?\s+(?<op>exists|does\s+not\s+exist|contains|does\s+not\s+contain|includes|does\s+not\s+include)\b\s*(?<text>.*)$')
    if (-not $m.Success) { return $null }
    $op = ($m.Groups['op'].Value -replace '\s+', ' ').ToLowerInvariant()
    $negate = $op -like 'does not *'
    $wantText = $op -match 'contain|include'
    $text = $m.Groups['text'].Value.Trim().TrimEnd('.').Trim()
    # The text must be quoted (or in backticks): 'README.md contains a usage section' is a judgement
    # for Copilot, not a text to look for.
    $quoted = $text.Length -ge 3 -and (($text[0] -eq '`' -and $text[-1] -eq '`') -or ($text[0] -eq '"' -and $text[-1] -eq '"') -or ($text[0] -eq "'" -and $text[-1] -eq "'"))
    if ($wantText -and -not $quoted -and -not $Literal) { return $null }
    if ($quoted) { $text = $text.Substring(1, $text.Length - 2) }
    if (-not $wantText -and $text) { return $null }   # 'PATH exists and ...': more than the helper can tell
    $text = $text.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&amp;', '&')
    $path = $m.Groups['path'].Value.Replace('\', '/')
    $full = try { Resolve-ProjectPath $ProjectRoot $path } catch { $null }
    if (-not $full) { return @{ check = $Check; met = $false; note = "$path is outside the project"; by = 'helper' } }
    $exists = Test-Path -LiteralPath $full -PathType Leaf
    if (-not $wantText) {
        $met = if ($negate) { -not $exists } else { $exists }
        return @{ check = $Check; met = $met; note = $(if ($met) { '' } elseif ($negate) { "$path is still there" } else { "$path does not exist" }); by = 'helper' }
    }
    if (-not $exists) { return @{ check = $Check; met = [bool]$negate; note = $(if ($negate) { '' } else { "$path does not exist" }); by = 'helper' } }
    $content = try { [IO.File]::ReadAllText($full) } catch { $null }
    if ($null -eq $content) { return @{ check = $Check; met = $false; note = "$path could not be read"; by = 'helper' } }
    $has = $content.Contains($text)
    $met = if ($negate) { -not $has } else { $has }
    @{ check = $Check; met = $met; note = $(if ($met) { '' } elseif ($negate) { "$path still contains it" } else { "$path does not contain that text" }); by = 'helper' }
}

function Get-HelperChecks([string]$ProjectRoot, [string[]]$Checks) {
    # The results of the Done when lines the helper program can check itself (others left out).
    @(foreach ($c in @($Checks)) { $r = Test-DoneWhenCheck $ProjectRoot "$c"; if ($r) { $r } })
}

function Merge-AcceptanceResults([string]$ProjectRoot, [string[]]$Checks, $Answers) {
    <# Every check in order: the helper program's own result where it can check the line (checked
       again now, so a fix made after the question counts), else Copilot's answer (or not answered). #>
    @(foreach ($c in @($Checks)) {
        $h = Test-DoneWhenCheck $ProjectRoot "$c"
        if ($h) { $h; continue }
        $a = @(@($Answers) | Where-Object { $_ -and "$($_.check)" -eq "$c" }) | Select-Object -First 1
        if ($a) { $a } else { @{ check = $c; met = $null; note = '' } }
    })
}

function Read-AcceptanceAnswers([AllowEmptyString()][string]$Text, [string[]]$Checks) {
    <# The MET / NOT MET lines of a reply, matched to the checks (by the check's text, else in order).
       @(@{ check; met; note }) for every check; met is $null for a check the reply did not answer. A check
       answered twice (NOT MET, then MET after the fix in the same reply) takes the last answer. #>
    $answers = @(foreach ($l in "$Text".Replace("`r`n", "`n").Split("`n")) {
        $m = [regex]::Match($l, '^[\s>*_\-]*(NOT\s+MET|MET)\s*[:\-]\s*\**\s*(.+?)\s*$')
        if ($m.Success) { @{ met = ($m.Groups[1].Value -notmatch '(?i)^NOT'); text = $m.Groups[2].Value } }
    })
    $used = @{}
    $i = 0
    foreach ($c in @($Checks)) {
        $hit = $null
        $key = ($c -replace '[^\w ]', '').Trim().ToLowerInvariant()
        for ($k = $answers.Count - 1; $k -ge 0; $k--) {   # the last answer to a check wins: a reply may say NOT MET, fix it, then say MET
            if ($used[$k]) { continue }
            $a = ($answers[$k].text -replace '[^\w ]', '').Trim().ToLowerInvariant()
            if ($key -and ($a.StartsWith($key.Substring(0, [Math]::Min(30, $key.Length))))) { $hit = $k; break }
        }
        if ($null -eq $hit -and $i -lt $answers.Count -and -not $used[$i]) { $hit = $i }   # in order
        if ($null -ne $hit) {
            $used[$hit] = $true
            $note = ''
            if ($answers[$hit].text -match '\s[-:]\s(.+)$' -and -not $answers[$hit].met) { $note = $Matches[1].Trim() }
            @{ check = $c; met = $answers[$hit].met; note = $note }
        } else { @{ check = $c; met = $null; note = '' } }
        $i++
    }
}

function Format-AcceptanceReport($Results) {
    # The task report's lines for the checks.
    @(foreach ($r in @($Results)) {
        $state = if ($null -eq $r.met) { 'not answered' } elseif ($r.met) { 'MET' } else { "NOT MET$(if ($r.note) { " ($($r.note))" })" }
        "- $($r.check): $state$(if ($r.by -eq 'helper') { ' (checked by StreamHub in the files)' })"
    })
}

# --- Tie-breakers: what the fixed rules cannot tell from the words alone ------------------------

function Get-RequestTypeAsk {
    "The helper program cannot tell from the words alone whether this request changes how existing parts look, adds or changes what the app does, or both. Before you change files, write one line: 'Request type: look', 'Request type: feature' or 'Request type: both'. The LOOK ASKED FOR rules apply only with look or both, and then only to the parts whose look the request names. Then go on with the work in the same reply."
}

function Read-RequestType([AllowEmptyString()][string]$Text) {
    # 'look', 'feature' or 'both' from a 'Request type:' line outside code blocks; '' when there is none.
    $inCode = $false
    foreach ($l in "$Text".Replace("`r`n", "`n").Split("`n")) {
        if ($l -match '^\s*(```|~~~)') { $inCode = -not $inCode; continue }
        if ($inCode) { continue }
        $m = [regex]::Match($l, '(?i)^[\s>*_#-]*request\s+type[\s*_]*:[\s*_]*(look|feature|both)\b')
        if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    }
    ''
}

function Get-ScopeAsk([string]$Preference) {
    # The project chose to clarify or plan big requests first (setup question bigtask); this one is near the line.
    $then = if ($Preference -eq 'clarify') { 'asks you its questions first and then has you plan' } else { 'has you write a plan for the person to approve first' }
    "This project starts big requests with a plan, and this one is close to that size. Decide first: if it is too big to build well in one go (several separate parts or pages, or more than about ten files to write), reply with only the line 'Scope: plan' and no action blocks; the helper program then $then. Otherwise start your reply with the line 'Scope: build' and do the work."
}

function Read-ScopeDecision([AllowEmptyString()][string]$Text) {
    # 'plan' or 'build' from a 'Scope:' line outside code blocks; '' when there is none.
    $inCode = $false
    foreach ($l in "$Text".Replace("`r`n", "`n").Split("`n")) {
        if ($l -match '^\s*(```|~~~)') { $inCode = -not $inCode; continue }
        if ($inCode) { continue }
        $m = [regex]::Match($l, '(?i)^[\s>*_#-]*scope[\s*_]*:[\s*_]*(plan|build)\b')
        if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    }
    ''
}

function Get-NotesGoAhead {
    # After a reply with only the notes asked for first: carry out the task now.
    "Noted. Now carry out the task: read what you still need or write the files, with action blocks. Do not repeat the lists above."
}

# --- Plan coverage: what the plan names and placeholder code, before done ----------------------

$script:CodeExt = '(?i)\.(m?js|cjs|jsx|tsx?|vue|svelte|py|ps1|psm1|cs|java|kt|go|php|rb)$'
$script:PlanPathPattern = '(?<![\w/.:-])((?:[\w.-]+/)*[\w-][\w.-]*\.(?:html?|css|m?js|cjs|jsx|tsx?|vue|svelte|py|ps1|psm1|cs|json|md|csv|xaml))(?![\w-])'

function Get-PlanFiles([AllowEmptyString()][string]$Text) {
    <# The files a plan or step list says to create or change: path-like names with an extension, not
       on lines about removing, deleting or temporary files, not web addresses, not under Work/, Source/
       or the helper program's folders. #>
    $out = New-Object System.Collections.Generic.List[string]
    $skipSection = $false
    foreach ($l in "$Text".Split("`n")) {
        # A heading starts a section; one about removing or temporary files is skipped as a whole.
        if ($l -match '^\s*(#+\s*)?[A-Z][A-Z /&-]{3,}:?\s*$' -or $l -match '^\s*#+\s') { $skipSection = $l -match '(?i)\b(remove|delete|clean ?up|temporary|discovery|obsolete)\b' }
        if ($skipSection -or $l -match '(?i)\b(remove|delete|deleted|temporary|scratch|clean ?up|obsolete|if created)\b' -or $l -match '(?i)https?://') { continue }
        foreach ($m in [regex]::Matches($l, $script:PlanPathPattern)) {
            $p = $m.Groups[1].Value -replace '^\./', ''   # ./x only: a leading dot is part of the name (.streamhub/)
            if ($p -match '(?i)^(Work|Source|\.streamhub|node_modules|styles/kit|dist|build)/' -or $p -match '^\d' -or $p -notmatch '[A-Za-z]') { continue }
            if (-not $out.Contains($p)) { $out.Add($p) }
        }
    }
    $out.ToArray()
}

function Find-StubCode {
    <# Placeholder code in a code file's text that the old text did not have: functions with an empty
       body or one that only throws "not implemented" or passes, and TODO / FIXME / placeholder markers.
       Returns short descriptions ("function loadData has an empty body"), at most 5. #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    if ($Rel -notmatch $script:CodeExt -or $Rel -match '(?i)(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.|\.Tests\.ps1$') { return @() }
    $find = {
        param([string]$t)
        $hits = New-Object System.Collections.Generic.List[string]
        $named = '(?:function\s+([\w$]+)\s*\([^)]*\)|(?:const|let|var)\s+([\w$]+)\s*=\s*(?:async\s*)?(?:function\s*)?\([^)]*\)\s*(?:=>)?|^\s*(?:async\s+)?([\w$]+)\s*\([^)]*\))'
        if ($Rel -match '(?i)\.(m?js|cjs|jsx|tsx?|vue|svelte|cs|java|kt|go|php)$') {
            foreach ($m in [regex]::Matches($t, "(?m)$named\s*\{\s*(?://[^\n]*\s*|/\*[\s\S]*?\*/\s*)*\}")) {
                $n = @($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) | Where-Object { $_ } | Select-Object -First 1
                if ($n -and $n -notmatch '^(if|for|while|switch|catch|function|noop|nothing)$') { $hits.Add("function $n has an empty body") }
            }
            foreach ($m in [regex]::Matches($t, '(?i)throw\s+new\s+\w*Error\(\s*[''"`][^''"`]*(not (yet )?implemented|todo|implement (me|this|later))')) { $hits.Add("code that throws 'not implemented'") }
        }
        if ($Rel -match '(?i)\.py$') {
            foreach ($m in [regex]::Matches($t, '(?m)^\s*def\s+(\w+)\s*\([^)]*\)[^:]*:\s*\n(?:\s*(?:#[^\n]*|"{3}[\s\S]*?"{3})\s*\n)*\s*(pass|\.\.\.|raise\s+NotImplementedError\b)')) { $hits.Add("function $($m.Groups[1].Value) only does $($m.Groups[2].Value)") }
        }
        if ($Rel -match '(?i)\.psm?1$') {
            foreach ($m in [regex]::Matches($t, '(?im)^\s*function\s+([\w-]+)\s*(?:\([^)]*\))?\s*\{\s*(?:#[^\n]*\s*)*\}')) { $hits.Add("function $($m.Groups[1].Value) has an empty body") }
            foreach ($m in [regex]::Matches($t, '(?i)throw\s+[''"][^''"]*not (yet )?implemented')) { $hits.Add("code that throws 'not implemented'") }
        }
        foreach ($m in [regex]::Matches($t, '(?im)(//|#|/\*|<!--|\*)\s*(TODO|FIXME|XXX)\b[:\s]*([^\n]{0,60})')) { $hits.Add("a $($m.Groups[2].Value.ToUpperInvariant()) marker: $($m.Groups[3].Value.Trim())") }
        foreach ($m in [regex]::Matches($t, '(?im)(//|#|/\*|<!--)[^\n]*\b(placeholder (logic|implementation|function|code)|stub(bed)? (function|implementation|code)|implement (this )?later|not (yet )?implemented)\b')) { $hits.Add("a placeholder note: $($m.Value.Trim())") }
        $hits.ToArray()
    }
    $before = @(& $find "$Old")
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($h in @(& $find "$New")) {
        $n = @($before | Where-Object { $_ -eq $h }).Count
        if ($n) { $before = @($before | Where-Object { $_ -ne $h } ) + @(@($before | Where-Object { $_ -eq $h }) | Select-Object -Skip 1); continue }
        if (-not $out.Contains($h)) { $out.Add($h) }
    }
    # A new code file with (almost) nothing in it: at most one line of real code (lines of only
    # brackets and punctuation, comments and 'use strict' do not count), so a short real function is fine.
    if (-not "$Old".Trim()) {
        $code = @("$New".Split("`n") | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^(//|#|/\*|\*|<!--|"use strict"|''use strict'')' -and $_.Trim() -notmatch '^[\s{}()\[\];,]*$' })
        if ($code.Count -le 1 -and $Rel -match '(?i)\.(m?js|cjs|jsx|tsx?|py|ps1|psm1)$') { $out.Insert(0, "the file has only $($code.Count) line(s) of code") }
    }
    @($out | Select-Object -First 5)
}

function Get-PlanCoverage {
    <# Before done: what the approved plan or Copilot's own steps name that the project does not have,
       and placeholder code the task added (Find-StubCode against the task's backups). $Files: rel ->
       'new' | 'existed' (the task's change set); $BackupDir: the checkpoint folder (old texts).
       Returns @{ missing = @(paths); stubs = @("PATH: what") }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, $Files, [string]$BackupDir = '', [AllowEmptyString()][string]$PlanText = '')
    $missing = @(foreach ($p in @(Get-PlanFiles $PlanText)) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $p.Replace('/', '\')))) { $p }
    })
    $stubs = New-Object System.Collections.Generic.List[string]
    foreach ($rel in @($Files.Keys)) {
        $r = "$rel".Replace('\', '/')
        if ($r -notmatch $script:CodeExt) { continue }
        $full = Join-Path $ProjectRoot $r.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Get-Item -LiteralPath $full).Length -gt 2MB) { continue }
        $old = ''
        if ($Files[$rel] -eq 'existed' -and $BackupDir) { $bk = Join-Path $BackupDir $r.Replace('/', '\'); if (Test-Path -LiteralPath $bk) { $old = [IO.File]::ReadAllText($bk) } }
        foreach ($h in @(Find-StubCode $r $old ([IO.File]::ReadAllText($full)))) { $stubs.Add("${r}: $h") }
    }
    @{ missing = @($missing); stubs = $stubs.ToArray() }
}

function Format-PlanCoverage($Coverage) {
    # The message to Copilot for what the coverage check found ('' when nothing).
    $parts = New-Object System.Collections.Generic.List[string]
    if (@($Coverage.missing).Count) { $parts.Add("The plan names these files, and the project does not have them:`n" + ((@($Coverage.missing) | Select-Object -First 12 | ForEach-Object { "- $_" }) -join "`n")) }
    if (@($Coverage.stubs).Count) { $parts.Add("These parts are placeholders, not the working code the task needs:`n" + ((@($Coverage.stubs) | Select-Object -First 12 | ForEach-Object { "- $_" }) -join "`n")) }
    if (-not $parts.Count) { return '' }
    "Before finishing, the helper program compared what was built with the plan.`n" + ($parts -join "`n") + "`nBuild them now, with working code. If one is not needed (the plan changed, or it is done elsewhere), say which and why in your summary, then send done again."
}

# --- Open items in the project's to-do list ----------------------------------------------------

function Test-TaskListFile([string]$Path) {
    # A to-do or plan list of the project (TODO.md, TO-DO.md, TASKS.md, PLAN.md in any folder; not the
    # helper program's own .streamhub/PLAN.md): Copilot changes these without the person's approval.
    $p = "$Path".Replace('\', '/').TrimStart('/')
    [bool]($p -notmatch '(?i)^\.streamhub/' -and $p -match '(?i)(^|/)(TODO|TO-DO|TASKS|PLAN)\.md$')
}

function Get-OpenTodoItems([string]$ProjectRoot) {
    <# The project's to-do lists (TODO.md, TASKS.md, PLAN.md at the root or in docs/; not StreamHub's
       own .streamhub/PLAN.md) with the '- [ ]' items still open, outside code blocks:
       @(@{ file; items = @(text) }) for the files that have any. #>
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($dir in '', 'docs') {
        $base = if ($dir) { Join-Path $ProjectRoot $dir } else { $ProjectRoot }
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $base -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(TODO|TO-DO|TASKS|PLAN)\.md$' })) {
            $open = New-Object System.Collections.Generic.List[string]; $fence = $false
            foreach ($l in ([IO.File]::ReadAllText($f.FullName) -split "`r?`n")) {
                if ($l -match '^\s*(```|~~~)') { $fence = -not $fence; continue }
                if (-not $fence -and $l -match '^\s*(?:[-*+]|\d+[.)])\s*\[ \]\s*(\S.*)$') { $open.Add($Matches[1].Trim()) }
            }
            if ($open.Count) { $out.Add(@{ file = $(if ($dir) { "$dir/$($f.Name)" } else { $f.Name }); items = $open.ToArray() }) }
        }
    }
    $out.ToArray()
}

function Get-UnmetChecksContinue($NotMet) {
    # The message the Continue button sends for Done when checks Copilot answered NOT MET.
    $lines = @(foreach ($c in @($NotMet)) { "- $($c.check)$(if ($c.note) { " (you said: $($c.note))" })" })
    "These checks you set for this task are not met yet:`n" + ($lines -join "`n") + "`nMake them met now. If one cannot be met here, say why in one line and what would make it possible, and leave it out."
}

function Get-OpenTodoContinue($Open) {
    # The message the Continue button sends for open to-do items.
    $parts = @(foreach ($o in @($Open)) { "$($o.file): " + ((@($o.items) | Select-Object -First 12 | ForEach-Object { "- $_" }) -join "`n") })
    "Continue with the items still open in the to-do list:`n" + ($parts -join "`n") + "`nDo them now and tick each one off ([x]) in the file when it is done. If one is not needed, tick it off and say why in your summary."
}

# --- Data notes ------------------------------------------------------------------------------

function Get-DataNotesPath([string]$ProjectRoot) { Join-Path $ProjectRoot '.streamhub\data-notes.json' }

function Read-DataNotes([string]$ProjectRoot) {
    # @{ files = @{ 'data/x.json' = hash }; notes = @(lines); written } or $null.
    $f = Get-DataNotesPath $ProjectRoot
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json
        $files = @{}; foreach ($p in @($j.files.PSObject.Properties)) { $files[$p.Name] = "$($p.Value)" }
        @{ files = $files; notes = @($j.notes | ForEach-Object { "$_" }); written = "$($j.written)" }
    } catch { $null }
}

function Get-DataNotesNeeded([string]$ProjectRoot, $Manifest) {
    <# The converted data files (data/NAME.json from the import manifest) that have no notes yet, or
       whose data changed since the notes were written (the manifest's hash). #>
    $have = Read-DataNotes $ProjectRoot
    @(foreach ($k in @($Manifest.Keys | Sort-Object)) {
        $h = "$($Manifest[$k].hash)"
        if (-not $h) { continue }   # not converted (failed, or a file a script owns)
        if (-not $have -or $have.files[$k] -ne $h) { $k }
    })
}

function Get-DataNotesAsk([string[]]$Files) {
    "The helper program keeps short notes about the project's data so later tasks need not read it again. In this reply, add a line 'Data notes:' and under it, as '- ' lines (at most 12 in all): for $($Files -join ', '): what one row is, the key column(s), how the files join (which columns match), and values to watch for (empty cells, codes, units, totals mixed with rows). Only what you saw in the data."
}

function Save-DataNotes([string]$ProjectRoot, $Manifest, [string[]]$Files, [string[]]$Notes) {
    # Keeps the notes with the hash of each file they describe (merged with notes of other files).
    $have = Read-DataNotes $ProjectRoot
    $known = if ($have) { $have.files } else { @{} }   # not $files: the same variable as the parameter $Files
    foreach ($k in $Files) { $known[$k] = "$($Manifest[$k].hash)" }
    $o = [ordered]@{ written = (Get-Date).ToString('s'); files = $known; notes = @($Notes) }
    $f = Get-DataNotesPath $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $f)
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $o -Depth 4), (New-Object Text.UTF8Encoding($false)))
}

function Format-DataNotes([string]$ProjectRoot) {
    # The project-context lines: the notes Copilot wrote about the data ('' when there are none).
    $have = Read-DataNotes $ProjectRoot
    if (-not $have -or -not @($have.notes).Count) { return '' }
    "Data notes (what you wrote about this data earlier; read the data again only for what they do not cover):`n" + ((@($have.notes) | ForEach-Object { "- $_" }) -join "`n")
}

Export-ModuleMember -Function Read-NoteBlock, Get-DoneWhenAsk, Read-DoneWhen, New-AcceptanceAsk, Test-DoneWhenCheck, Get-HelperChecks, Merge-AcceptanceResults, Read-AcceptanceAnswers, Format-AcceptanceReport, Get-DataNotesPath, Read-DataNotes, Get-DataNotesNeeded, Get-DataNotesAsk, Save-DataNotes, Format-DataNotes, Get-RequestTypeAsk, Read-RequestType, Get-ScopeAsk, Read-ScopeDecision, Get-NotesGoAhead, Get-OpenTodoItems, Get-OpenTodoContinue, Get-PlanFiles, Find-StubCode, Get-PlanCoverage, Format-PlanCoverage, Test-TaskListFile, Get-UnmetChecksContinue
