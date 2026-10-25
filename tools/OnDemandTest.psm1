# Pure helpers of tools\ondemand-test.ps1 (the live test of StreamHub's on-demand features): the
# approval rule, the setup-card answer, file snapshots and their difference, the checks on the files
# the features write, what Copilot did in a step, and the report. Nothing here talks to the app, so
# tests\OnDemandTest.Tests.ps1 covers it without a running StreamHub.

$ErrorActionPreference = 'Stop'

$script:OverviewMarker = '<!-- streamhub:project-overview'
$script:Placeholder = '^\s*TO BE WRITTEN:'
# A colour value in tokens.css: hex, rgb(a), hsl(a), color-mix() or a var() of another token.
$script:ColourValue = '^\s*(#[0-9A-Fa-f]{3,8}|rgba?\([^)]*\)|hsla?\([^)]*\)|color-mix\(.+\)|var\(--[\w-]+\))\s*$'
$script:Declaration = '(--[A-Za-z0-9_-]+)\s*:\s*([^;{}]+);'

function Get-AsList($Value) {
    <# A JSON value as a list: $null gives nothing, one object gives itself, an array its items.
       Wrap the call in @() (a function hands a one-item array on as the item). #>
    if ($null -eq $Value) { return }
    foreach ($v in @($Value)) { if ($null -ne $v) { $v } }
}

function Get-ActionPath([string]$Target) {
    <# The project path of a write or edit target: no line range (PATH:10-20, PATH:outline), no
       quotes, forward slashes, no leading ./ or /. #>
    $p = "$Target".Trim().Trim('"', "'").Replace('\', '/')
    $p = $p -replace ':(\d+(-\d+)?|outline)$', ''
    $p = $p -replace '^\./', ''
    $p.TrimStart('/')
}

function Test-PathPattern([string]$Path, [string[]]$Patterns) {
    <# Whether a project path matches one of the wildcard patterns (case-insensitive, forward slashes). #>
    $p = Get-ActionPath $Path
    foreach ($pat in @($Patterns | Where-Object { $_ })) {
        if ($p -like ("$pat".Replace('\', '/'))) { return $true }
    }
    $false
}

function Get-ApprovalDecision {
    <# What the test answers to an approval card (an 'action' event with status 'awaiting'): only a
       write or edit of a file the step expects is approved; everything else is denied, and a run
       command, a delete, a Microsoft 365 action or a web read never is. Returns
       @{ decision = 'approve'|'reject'; action; path; reason }. #>
    param([Parameter(Mandatory)]$Card, [string[]]$Expected = @())
    $action = "$($Card.action)".Trim().ToLowerInvariant()
    $target = "$($Card.target)"
    $path = ''
    if ($action -in 'write', 'edit') {
        $path = if ($Card.preview -and "$($Card.preview.path)") { Get-ActionPath "$($Card.preview.path)" } else { Get-ActionPath $target }
        if ($path -and (Test-PathPattern $path $Expected)) {
            return @{ decision = 'approve'; action = $action; path = $path; reason = "the $action of $path this step expects" }
        }
        $want = if (@($Expected | Where-Object { $_ }).Count) { (@($Expected | Where-Object { $_ }) -join ', ') } else { 'no file' }
        return @{ decision = 'reject'; action = $action; path = $path; reason = "$action of $path, but this step only expects changes to $want" }
    }
    $why = switch -Regex ($action) {
        '^run$' { 'the test never approves a run command'; break }
        '^(delete|remove|move)$' { 'the test never approves deleting or moving files'; break }
        '^web$' { 'the test never approves a web read'; break }
        '^sql$' { 'the test never approves a database query'; break }
        default { "the test never approves a $action action" }
    }
    @{ decision = 'reject'; action = $action; path = (Get-ActionPath $target); reason = "$action $target`: $why" }
}

function Get-SetupAutoAnswer {
    <# The answer the test gives a project setup card ('setup-choice' event), the way the card starts:
       the first choice of every question, but never one that holds the request back or plans first
       (wait, project, plan, clarify), and nothing ticked for a multi choice. Returns
       @{ build ('' when the card did not ask); answers (id -> value) }. #>
    param([Parameter(Mandatory)]$Card)
    $hold = @('wait', 'project', 'plan', 'clarify')
    $build = ''; $answers = @{}
    foreach ($q in @(Get-AsList $Card.choices)) {
        $opts = @(Get-AsList $q.options | ForEach-Object { "$($_.value)" })
        $pick = ''
        if (-not [bool]$q.multi) {
            $pick = @($opts | Where-Object { $hold -notcontains $_ }) | Select-Object -First 1
            if (-not $pick -and $opts.Count) { $pick = $opts[0] }
        }
        if ("$($q.id)" -eq 'build') { $build = "$pick" } else { $answers["$($q.id)"] = "$pick" }
    }
    @{ build = $build; answers = $answers }
}

function Get-TextHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') } finally { $sha.Dispose() }
}

function Read-FileBytes([string]$Path) {
    # The file's bytes, opened with shared read and write (OneDrive or the app may hold it open).
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        $buf = New-Object byte[] $fs.Length
        $read = 0
        while ($read -lt $buf.Length) { $n = $fs.Read($buf, $read, $buf.Length - $read); if ($n -le 0) { break }; $read += $n }
        , $buf
    } finally { $fs.Dispose() }
}

function New-FileSnapshot {
    <# Every file under $Root as rel path (forward slashes) -> @{ size; hash }, without the folders in
       $Skip (prefixes such as '.streamhub/'). Links are not followed. #>
    param([Parameter(Mandatory)][string]$Root, [string[]]$Skip = @('.streamhub/'))
    $base = $Root.TrimEnd('\')
    $snap = @{}
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($base)
    while ($stack.Count) {
        $dir = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            $rel = $item.FullName.Substring($base.Length + 1).Replace('\', '/')
            $skipIt = $false
            foreach ($s in $Skip) { if ($s -and ($rel + '/').StartsWith($s, [StringComparison]::OrdinalIgnoreCase)) { $skipIt = $true; break } }
            if ($skipIt) { continue }
            if ($item.PSIsContainer) {
                if ("$($item.LinkType)" -in 'Junction', 'SymbolicLink') { continue }
                $stack.Push($item.FullName)
                continue
            }
            $hash = try { Get-TextHash (Read-FileBytes $item.FullName) } catch { 'unreadable' }
            $snap[$rel] = @{ size = [int64]$item.Length; hash = $hash }
        }
    }
    $snap
}

function Compare-FileSnapshot {
    <# What changed between two snapshots: @{ added; removed; changed } (sorted rel paths). #>
    param([Parameter(Mandatory)][hashtable]$Before, [Parameter(Mandatory)][hashtable]$After)
    $added = @($After.Keys | Where-Object { -not $Before.ContainsKey($_) } | Sort-Object)
    $removed = @($Before.Keys | Where-Object { -not $After.ContainsKey($_) } | Sort-Object)
    $changed = @($After.Keys | Where-Object { $Before.ContainsKey($_) -and $Before[$_].hash -ne $After[$_].hash } | Sort-Object)
    @{ added = $added; removed = $removed; changed = $changed }
}

function Split-ChangedPaths {
    <# The paths of a snapshot difference in three groups: expected (match $Expected), ignored (match
       $Ignore: what StreamHub itself writes) and other (everything else). #>
    param([Parameter(Mandatory)][hashtable]$Diff, [string[]]$Expected = @(), [string[]]$Ignore = @())
    $all = @(@($Diff.added) + @($Diff.removed) + @($Diff.changed) | Where-Object { $_ } | Sort-Object -Unique)
    $exp = @(); $ign = @(); $oth = @()
    foreach ($p in $all) {
        if (Test-PathPattern $p $Expected) { $exp += $p }
        elseif (Test-PathPattern $p $Ignore) { $ign += $p }
        else { $oth += $p }
    }
    @{ expected = $exp; ignored = $ign; other = $oth }
}

function Get-OverviewFactsPart([AllowEmptyString()][string]$Text) {
    <# The facts part of a project overview: from its '## Facts' heading line to the end, or $null. #>
    $m = [regex]::Match("$Text", '(?m)^## Facts[ \t]*\r?$')
    if (-not $m.Success) { return $null }
    $Text.Substring($m.Index)
}

function Test-OverviewResult {
    <# The overview after Copilot's edit against the text StreamHub wrote: @{ marker (first line is the
       StreamHub marker); placeholders (lines still to be written); factsSame (the facts part is
       byte-identical); reason (what differs, '' when all is well) }. #>
    param([AllowEmptyString()][string]$Written, [AllowEmptyString()][string]$Final)
    $first = (("$Final" -split "`n", 2)[0]).TrimStart([char]0xFEFF).Trim()
    $marker = $first.StartsWith($script:OverviewMarker)
    $left = @(("$Final" -split "`r?`n") | Where-Object { $_ -match $script:Placeholder } | ForEach-Object { $_.Trim() })
    $a = Get-OverviewFactsPart $Written; $b = Get-OverviewFactsPart $Final
    $same = ($null -ne $a) -and ($null -ne $b) -and [string]::Equals($a, $b, [StringComparison]::Ordinal)
    $why = @()
    if (-not $marker) { $why += 'the first line is no longer the StreamHub marker' }
    if ($left.Count) { $why += "$($left.Count) placeholder line(s) left: $($left -join '; ')" }
    if ($null -eq $a) { $why += 'the text StreamHub wrote has no Facts part' }
    elseif ($null -eq $b) { $why += 'the Facts heading is gone' }
    elseif (-not $same) {
        $al = $a -split "`r?`n"; $bl = $b -split "`r?`n"
        $n = [Math]::Min($al.Count, $bl.Count); $at = $n
        for ($i = 0; $i -lt $n; $i++) { if (-not [string]::Equals($al[$i], $bl[$i], [StringComparison]::Ordinal)) { $at = $i; break } }
        $lineEnds = [string]::Equals(($a -replace "`r`n", "`n"), ($b -replace "`r`n", "`n"), [StringComparison]::Ordinal)
        $why += $(if ($lineEnds) { 'the Facts part differs only in its line endings' } else { "the Facts part differs from line $($at + 1) of it on" })
    }
    @{ marker = $marker; placeholders = $left; factsSame = $same; reason = ($why -join '; ') }
}

function Get-TokenDeclarations([AllowEmptyString()][string]$Css) {
    # name#occurrence -> value of every --token declaration, in order (a token in the light and the
    # dark block counts twice).
    $out = [ordered]@{}
    $seen = @{}
    foreach ($m in [regex]::Matches("$Css", $script:Declaration)) {
        $n = $m.Groups[1].Value
        $seen[$n] = 1 + [int]$seen[$n]
        $out["$n#$($seen[$n])"] = $m.Groups[2].Value.Trim()
    }
    $out
}

function Test-TokensColourOnly {
    <# Whether a theme changed tokens.css only in colour values: every declaration whose value changed
       or that was added holds a colour, none was removed, and the rest of the file (selectors,
       comments, sizes) is the same. Returns @{ ok; changed; added; problems }. #>
    param([AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    $o = Get-TokenDeclarations $Old; $n = Get-TokenDeclarations $New
    $problems = New-Object System.Collections.Generic.List[string]
    $changed = 0; $added = 0
    foreach ($k in $n.Keys) {
        $name = $k.Split('#')[0]
        if (-not $o.Contains($k)) {
            $added++
            if ($n[$k] -notmatch $script:ColourValue) { $problems.Add("$name was added with a value that is not a colour ($($n[$k]))") }
            continue
        }
        if ($o[$k] -ceq $n[$k]) { continue }
        $changed++
        if ($n[$k] -notmatch $script:ColourValue) { $problems.Add("$name changed to a value that is not a colour ($($n[$k]))") }
        elseif ($o[$k] -notmatch $script:ColourValue) { $problems.Add("$name was not a colour before ($($o[$k]))") }
    }
    foreach ($k in $o.Keys) { if (-not $n.Contains($k)) { $problems.Add("$($k.Split('#')[0]) was removed") } }
    $strip = { param($t) ((([regex]::Replace("$t", $script:Declaration, '')) -split "`r?`n") | Where-Object { $_.Trim() }) -join "`n" }
    if (-not [string]::Equals((& $strip $Old), (& $strip $New), [StringComparison]::Ordinal)) { $problems.Add('more than token values changed (selectors, comments or other lines differ)') }
    if (-not ($changed + $added)) { $problems.Add('no colour token changed') }
    @{ ok = ($problems.Count -eq 0); changed = $changed; added = $added; problems = $problems.ToArray() }
}

function Get-MdSection([AllowEmptyString()][string]$Text, [string]$Heading) {
    <# The body under a Markdown heading (any level) up to the next heading, trimmed; $null when the
       heading is not there. #>
    $lines = "$Text" -split "`r?`n"
    $out = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($null -eq $out) {
            if ($lines[$i] -match ('^#{1,6}\s+' + [regex]::Escape($Heading) + '\s*$')) { $out = New-Object System.Collections.Generic.List[string] }
            continue
        }
        if ($lines[$i] -match '^#{1,6}\s') { break }
        $out.Add($lines[$i])
    }
    if ($null -eq $out) { return $null }
    ($out -join "`n").Trim()
}

function Test-PageReportText {
    <# The findings a full page check of the fixture page must contain: the low-contrast note (by its
       text), a raw date and a number without thousands separators. Returns the problems. #>
    param([AllowEmptyString()][string]$Text, [string]$NoteText)
    $problems = New-Object System.Collections.Generic.List[string]
    # The heading carries a count: "## Contrast (WCAG AA) (2)".
    $h = [regex]::Match("$Text", '(?m)^## (Contrast \(WCAG AA\)[^\r\n]*?)[ \t]*\r?$')
    $body = if ($h.Success) { Get-MdSection $Text $h.Groups[1].Value } else { $null }
    if (-not $h.Success) { $problems.Add('no Contrast section') }
    elseif ($NoteText -and "$body" -notlike "*$NoteText*") { $problems.Add("the Contrast section does not name the low-contrast note ('$NoteText')") }
    if ("$Text" -notmatch '(?m)^## Dates\b') { $problems.Add('no Dates section (the raw ISO date)') }
    if ("$Text" -notmatch '(?m)^## Numbers\b') { $problems.Add('no Numbers section (the number without thousands separators)') }
    $problems.ToArray()
}

function Test-DataProfileReport([AllowEmptyString()][string]$Text) {
    <# The profile of the fixture data must report its outlier, its mixed values and its duplicate row.
       Returns the problems. #>
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($h in 'Values far outside the rest', 'Numbers mixed with text', 'Duplicate rows') {
        $b = Get-MdSection $Text $h
        if ($null -eq $b) { $problems.Add("no '$h' section") }
        elseif ($b.StartsWith('None.')) { $problems.Add("'$h' says None.") }
    }
    $problems.ToArray()
}

function Test-PackageEntries([string[]]$Entries) {
    <# The entries of a sharing zip: never StreamHub's records, a .env or Source/ (not asked for),
       always README-SHARING.md at the root. Returns the problems. #>
    $problems = New-Object System.Collections.Generic.List[string]
    $list = @($Entries | Where-Object { $_ } | ForEach-Object { "$_".Replace('\', '/') })
    $own = @($list | Where-Object { $_ -like '.streamhub/*' })
    if ($own.Count) { $problems.Add("holds .streamhub/ ($($own.Count) entries)") }
    if (@($list | Where-Object { ($_ -split '/')[-1] -eq '.env' }).Count) { $problems.Add('holds the .env file') }
    $src = @($list | Where-Object { $_ -like 'Source/*' })
    if ($src.Count) { $problems.Add("holds Source/ ($($src.Count) entries) though it was not asked for") }
    if ($list -notcontains 'README-SHARING.md') { $problems.Add('has no README-SHARING.md at its root') }
    $problems.ToArray()
}

function Test-TidyItems {
    <# The tidy-up list against what it must and must never list (paths, any kind). Returns the problems. #>
    param($Items, [string[]]$MustList = @(), [string[]]$NeverList = @())
    $paths = @(Get-AsList $Items | ForEach-Object { "$($_.path)".Replace('\', '/') })
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($m in $MustList) { if (-not @($paths | Where-Object { $_ -ieq $m }).Count) { $problems.Add("$m is not listed") } }
    foreach ($n in $NeverList) { if (@($paths | Where-Object { $_ -ieq $n }).Count) { $problems.Add("$n is listed, and must never be") } }
    $problems.ToArray()
}

function Test-QueueSettled {
    <# The queue entries of the open project that came after a step started ($Known: the ids there
       before): @{ entries; pending (queued, running or awaiting); settled (at least one and none pending) }. #>
    param($Entries, [string[]]$Known = @(), [string]$ProjectRoot = '')
    $root = "$ProjectRoot".TrimEnd('\')
    $mine = @(Get-AsList $Entries | Where-Object {
            $Known -notcontains "$($_.id)" -and (-not $root -or "$($_.projectRoot)".TrimEnd('\') -ieq $root) })
    $pending = @($mine | Where-Object { "$($_.status)" -in 'queued', 'running', 'awaiting' })
    @{ entries = $mine; pending = $pending.Count; settled = ($mine.Count -gt 0 -and $pending.Count -eq 0) }
}

function Limit-Line([AllowEmptyString()][string]$Text, [int]$Max = 200) {
    # One line of at most $Max characters.
    $t = ("$Text" -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    $t
}

function Get-CopilotStepRecord {
    <# What Copilot did in one step, from the app's events: rounds, the actions it used (counted per
       kind; StreamHub's own cards left out), whether it ended with done, the first 200 characters of
       the done summary, and the status, refusal and error lines StreamHub showed. No reply text. #>
    param($Events)
    $list = @(Get-AsList $Events)
    $replies = @($list | Where-Object { "$($_.type)" -eq 'assistant' })
    $rounds = 0
    foreach ($r in $replies) { if ($r.round -and [int]$r.round -gt $rounds) { $rounds = [int]$r.round } }
    if ($rounds -lt $replies.Count) { $rounds = $replies.Count }
    $actions = [ordered]@{}; $seen = @{}
    foreach ($e in @($list | Where-Object { "$($_.type)" -eq 'action' -and "$($_.by)" -ne 'streamhub' })) {
        if ($seen.ContainsKey("$($e.id)")) { continue }
        $seen["$($e.id)"] = 1
        $a = "$($e.action)"; if (-not $a) { $a = '?' }
        $actions[$a] = 1 + [int]$actions[$a]
    }
    $done = @($list | Where-Object { "$($_.type)" -eq 'done' })
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($e in $list) {
        switch ("$($e.type)") {
            'status' { $lines.Add('status: ' + (Limit-Line "$($e.text)")) }
            'error' { $lines.Add('error: ' + (Limit-Line "$($e.text)")) }
            'human-required' { $lines.Add('human required: ' + (Limit-Line "$($e.text)")) }
            'action-result' { if ($e.ok -eq $false -and "$($e.status)" -ne 'rejected') { $lines.Add('refused or failed: ' + (Limit-Line "$($e.summary)")) } }
        }
    }
    $kinds = @($list | Where-Object { "$($_.type)" -eq 'kind' } | ForEach-Object { "$($_.taskKind)" } | Where-Object { $_ } | Select-Object -Unique)
    @{
        rounds = $rounds; actions = $actions; done = [bool]$done.Count
        summary = $(if ($done.Count) { Limit-Line "$($done[-1].text)" } else { '' })
        lines = $lines.ToArray(); kinds = $kinds
    }
}

function Resolve-OnlySteps {
    <# The steps -Only picks (names separated by commas or given as a list), checked against the known
       names; all of them when -Only is empty. Throws on an unknown name. #>
    param([string[]]$All, [string[]]$Only = @())
    $want = @($Only | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $want.Count) { return $All }
    $bad = @($want | Where-Object { $All -notcontains $_ })
    if ($bad.Count) { throw "Unknown step(s): $($bad -join ', '). Known steps: $($All -join ', ')." }
    @($All | Where-Object { $want -contains $_ })
}

function ConvertTo-MdCell([AllowEmptyString()][string]$Text) {
    (("$Text" -replace '\r?\n', ' ') -replace '\|', '\|').Trim()
}

function Format-OnDemandReport {
    <# The report as Markdown. $Info: @{ when; version; project; copilotRan (bool); checks =
       @(@{ step; check; result PASS|FAIL|SKIP; reason }); steps = @(@{ name; seconds; copilot =
       record or $null; approvals = @(lines) }) }. #>
    param([Parameter(Mandatory)][hashtable]$Info)
    $checks = @(Get-AsList $Info.checks)
    $pass = @($checks | Where-Object { $_.result -eq 'PASS' }).Count
    $fail = @($checks | Where-Object { $_.result -eq 'FAIL' }).Count
    $skip = @($checks | Where-Object { $_.result -eq 'SKIP' }).Count
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('# StreamHub on-demand features: live test')
    $out.Add('')
    $out.Add("- When: $($Info.when)")
    $out.Add("- StreamHub version: $($Info.version)")
    $out.Add("- Test project: $($Info.project)")
    $out.Add("- Copilot steps: $(if ($Info.copilotRan) { 'run' } else { 'not run (-SkipCopilot or not selected)' })")
    $out.Add("- Result: $pass passed, $fail failed, $skip skipped")
    $out.Add('')
    $out.Add('## Checks')
    $out.Add('')
    $out.Add('| Step | Check | Result | Reason |')
    $out.Add('|---|---|---|---|')
    foreach ($c in $checks) { $out.Add("| $(ConvertTo-MdCell $c.step) | $(ConvertTo-MdCell $c.check) | $($c.result) | $(ConvertTo-MdCell $c.reason) |") }
    $withCopilot = @(Get-AsList $Info.steps | Where-Object { $_.copilot })
    if ($withCopilot.Count) {
        $out.Add('')
        $out.Add('## Copilot behaviour')
        foreach ($s in $withCopilot) {
            $r = $s.copilot
            $out.Add('')
            $out.Add("### $($s.name)")
            $out.Add('')
            $out.Add("- Duration: $([int]$s.seconds) s; rounds: $($r.rounds); task kind: $(if (@($r.kinds).Count) { @($r.kinds) -join ', ' } else { '-' })")
            $acts = @(foreach ($k in $r.actions.Keys) { "$k $($r.actions[$k])" })
            $out.Add("- Actions: $(if ($acts.Count) { $acts -join ', ' } else { 'none' })")
            $out.Add("- Ended with done: $(if ($r.done) { 'yes' } else { 'no' })$(if ($r.summary) { "; summary: $($r.summary)" })")
            foreach ($a in @(Get-AsList $s.approvals)) { $out.Add("- Approval: $a") }
            foreach ($l in @(Get-AsList $r.lines)) { $out.Add("- StreamHub said: $l") }
        }
    }
    $out.Add('')
    $out.Add('## Timings')
    $out.Add('')
    $out.Add('| Step | Seconds |')
    $out.Add('|---|---|')
    foreach ($s in @(Get-AsList $Info.steps)) { $out.Add("| $(ConvertTo-MdCell $s.name) | $([int]$s.seconds) |") }
    ($out -join "`r`n") + "`r`n"
}

# --- PowerPoint decks (Apply a PowerPoint template) ------------------------------------------------
# A minimal copy of the XML-string deck builder in tests\PptxRetheme.Tests.ps1 (no charts, links or
# sections): enough for a template with its own theme, a logo on the master and a start and an end
# slide, and a content deck with a title, a bullets, a table and a free-heading slide.

$script:PX = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'
$script:PRB = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:PCT = 'application/vnd.openxmlformats-officedocument.presentationml'
$script:PGrp = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
$script:PPng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

function Get-OdtXfrm($R) { if ($R) { "<a:xfrm><a:off x=""$($R[0])"" y=""$($R[1])""/><a:ext cx=""$($R[2])"" cy=""$($R[3])""/></a:xfrm>" } else { '' } }

function New-OdtSpXml {
    <# A shape: a placeholder ($Ph, '<p:ph .../>'), a text box (-TextBox) or a plain shape; $Paras
       several paragraphs (bullets), $Size a run size in hundredths of a point. #>
    param([int]$Id, [string]$Text = '', [string]$Ph = '', $Rect = $null, [string[]]$Paras = @(), [int]$Size = 0, [switch]$TextBox)
    $tb = if ($TextBox) { ' txBox="1"' } else { '' }
    $geom = if ($Rect -and -not $Ph) { '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' } else { '' }
    $sz = if ($Size) { " sz=""$Size""" } else { '' }
    $list = if ($Paras.Count) { $Paras } elseif ($Text) { @($Text) } else { @() }
    $p = if ($list.Count) { (@($list | ForEach-Object { "<a:p><a:r><a:rPr lang=""en-US""$sz/><a:t>$_</a:t></a:r></a:p>" }) -join '') } else { '<a:p><a:endParaRPr lang="en-US"/></a:p>' }
    "<p:sp><p:nvSpPr><p:cNvPr id=""$Id"" name=""Shape $Id""/><p:cNvSpPr$tb/><p:nvPr>$Ph</p:nvPr></p:nvSpPr><p:spPr>$(Get-OdtXfrm $Rect)$geom</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>$p</p:txBody></p:sp>"
}

function New-OdtPicXml([int]$Id, [string]$Rid, $Rect) {
    "<p:pic><p:nvPicPr><p:cNvPr id=""$Id"" name=""Logo $Id""/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=""$Rid""/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>$(Get-OdtXfrm $Rect)<a:prstGeom prst=""rect""><a:avLst/></a:prstGeom></p:spPr></p:pic>"
}

function New-OdtTableXml([int]$Id, $Rect, [string[]]$Cells) {
    $cell = { param($t) "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=""en-US""/><a:t>$t</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>" }
    $rows = ''
    for ($i = 0; $i + 1 -lt $Cells.Count; $i += 2) { $rows += "<a:tr h=""370840"">$(& $cell $Cells[$i])$(& $cell $Cells[$i + 1])</a:tr>" }
    $w = [long]($Rect[2] / 2)
    "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=""$Id"" name=""Table $Id""/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=""1""/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x=""$($Rect[0])"" y=""$($Rect[1])""/><a:ext cx=""$($Rect[2])"" cy=""$($Rect[3])""/></p:xfrm><a:graphic><a:graphicData uri=""http://schemas.openxmlformats.org/drawingml/2006/table""><a:tbl><a:tblPr firstRow=""1"" bandRow=""1""><a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId></a:tblPr><a:tblGrid><a:gridCol w=""$w""/><a:gridCol w=""$w""/></a:tblGrid>$rows</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
}

function New-OdtThemeXml([string]$Accent1, [string]$Major, [string]$Minor) {
    $acc = @($Accent1, 'C0504D', '9BBB59', '8064A2', '4BACC6', 'F79646')
    $c = ''; for ($i = 0; $i -lt 6; $i++) { $c += "<a:accent$($i + 1)><a:srgbClr val=""$($acc[$i])""/></a:accent$($i + 1)>" }
    $f3 = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' * 3
    $l3 = '<a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>' * 3
    $e3 = '<a:effectStyle><a:effectLst/></a:effectStyle>' * 3
    "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><a:theme xmlns:a=""http://schemas.openxmlformats.org/drawingml/2006/main"" name=""T""><a:themeElements><a:clrScheme name=""C""><a:dk1><a:sysClr val=""windowText"" lastClr=""000000""/></a:dk1><a:lt1><a:sysClr val=""window"" lastClr=""FFFFFF""/></a:lt1><a:dk2><a:srgbClr val=""1F497D""/></a:dk2><a:lt2><a:srgbClr val=""EEECE1""/></a:lt2>$c<a:hlink><a:srgbClr val=""0000FF""/></a:hlink><a:folHlink><a:srgbClr val=""800080""/></a:folHlink></a:clrScheme><a:fontScheme name=""F""><a:majorFont><a:latin typeface=""$Major""/><a:ea typeface=""""/><a:cs typeface=""""/></a:majorFont><a:minorFont><a:latin typeface=""$Minor""/><a:ea typeface=""""/><a:cs typeface=""""/></a:minorFont></a:fontScheme><a:fmtScheme name=""S""><a:fillStyleLst>$f3</a:fillStyleLst><a:lnStyleLst>$l3</a:lnStyleLst><a:effectStyleLst>$e3</a:effectStyleLst><a:bgFillStyleLst>$f3</a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
}

function Add-OdtPart($Pkg, [string]$Uri, [string]$Type, $Content) {
    $p = $Pkg.CreatePart((New-Object Uri($Uri, [UriKind]::Relative)), $Type, [IO.Packaging.CompressionOption]::Normal)
    $bytes = if ($Content -is [byte[]]) { $Content } else { [Text.Encoding]::UTF8.GetBytes([string]$Content) }
    $s = $p.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
    $p
}

function Set-OdtPartText($Part, [string]$Text) {
    $s = $Part.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); try { $b = [Text.Encoding]::UTF8.GetBytes($Text); $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
}

function Add-OdtRel($From, $To, [string]$Kind, [string]$Id) {
    $null = $From.CreateRelationship([IO.Packaging.PackUriHelper]::GetRelativeUri($From.Uri, $To.Uri), [IO.Packaging.TargetMode]::Internal, "$script:PRB/$Kind", $Id)
}

function Get-OdtLayouts([switch]$Corporate) {
    <# Layouts with their placeholders: Office's standard set, or a corporate set with other names. #>
    if ($Corporate) {
        $T = @(609600, 300000, 10972800, 900000); $B = @(609600, 1400000, 10972800, 4700000)
        return @(
            @{ name = 'Cover'; type = 'title'; ph = @(@{ type = 'ctrTitle'; rect = @(609600, 2000000, 10972800, 1400000) }, @{ type = 'subTitle'; idx = '10'; rect = @(609600, 3600000, 10972800, 800000) }) },
            @{ name = 'Title and text'; type = 'obj'; ph = @(@{ type = 'title'; rect = $T }, @{ idx = '13'; rect = $B }) },
            @{ name = 'Title only'; type = 'titleOnly'; ph = @(@{ type = 'title'; rect = $T }) },
            @{ name = 'Empty'; type = 'blank'; ph = @() }
        )
    }
    $T = @(457200, 274638, 8229600, 1143000); $B = @(457200, 1600200, 8229600, 4525963)
    @(
        @{ name = 'Title Slide'; type = 'title'; ph = @(@{ type = 'ctrTitle'; rect = @(685800, 2130425, 7772400, 1470025) }, @{ type = 'subTitle'; idx = '1'; rect = @(1371600, 3886200, 6400800, 1752600) }) },
        @{ name = 'Title and Content'; type = 'obj'; ph = @(@{ type = 'title'; rect = $T }, @{ idx = '1'; rect = $B }) },
        @{ name = 'Title Only'; type = 'titleOnly'; ph = @(@{ type = 'title'; rect = $T }) },
        @{ name = 'Blank'; type = 'blank'; ph = @() }
    )
}

function New-OdtDeck {
    <# A .pptx from XML strings. Slides: @(@{ layout = N (1-based); shapes = XML; pics = @{ rId = bytes } }).
       -Logo puts a small picture on the master. Returns the path. #>
    param([Parameter(Mandatory)][string]$Path, $Layouts, $Slides = @(), [long[]]$Size = @(9144000, 6858000),
        [string]$Accent1 = '4F81BD', [string]$Major = 'Calibri Light', [string]$Minor = 'Calibri', [switch]$Logo)
    Add-Type -AssemblyName WindowsBase
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $pkg = [IO.Packaging.Package]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite)
    try {
        $pres = Add-OdtPart $pkg '/ppt/presentation.xml' "$script:PCT.presentation.main+xml" 'x'
        $null = $pkg.CreateRelationship((New-Object Uri('ppt/presentation.xml', [UriKind]::Relative)), [IO.Packaging.TargetMode]::Internal, "$script:PRB/officeDocument", 'rId1')
        $theme = Add-OdtPart $pkg '/ppt/theme/theme1.xml' 'application/vnd.openxmlformats-officedocument.theme+xml' (New-OdtThemeXml $Accent1 $Major $Minor)
        $master = Add-OdtPart $pkg '/ppt/slideMasters/slideMaster1.xml' "$script:PCT.slideMaster+xml" 'x'
        Add-OdtRel $pres $master 'slideMaster' 'rIdM'; Add-OdtRel $pres $theme 'theme' 'rIdT'; Add-OdtRel $master $theme 'theme' 'rIdT'
        $lids = ''; $lparts = @(); $n = 0
        foreach ($l in @($Layouts)) {
            $n++; $sps = ''; $id = 2
            foreach ($ph in @($l.ph)) {
                $t = if ($ph.type) { " type=""$($ph.type)""" } else { '' }; $i = if ($ph.idx) { " idx=""$($ph.idx)""" } else { '' }
                $sps += New-OdtSpXml -Id $id -Ph "<p:ph$t$i/>" -Rect $ph.rect; $id++
            }
            $ta = if ($l.type) { " type=""$($l.type)""" } else { '' }
            $lp = Add-OdtPart $pkg "/ppt/slideLayouts/slideLayout$n.xml" "$script:PCT.slideLayout+xml" "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:sldLayout $script:PX$ta preserve=""1""><p:cSld name=""$($l.name)""><p:spTree>$script:PGrp$sps</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
            Add-OdtRel $lp $master 'slideMaster' 'rId1'; Add-OdtRel $master $lp 'slideLayout' "rIdL$n"
            $lids += "<p:sldLayoutId id=""$(2147483648 + $n)"" r:id=""rIdL$n""/>"; $lparts += $lp
        }
        $mph = (New-OdtSpXml -Id 2 -Ph '<p:ph type="title"/>' -Rect @(457200, 274638, 8229600, 1143000)) + (New-OdtSpXml -Id 3 -Ph '<p:ph type="body" idx="1"/>' -Rect @(457200, 1600200, 8229600, 4525963))
        if ($Logo) {
            Add-OdtRel $master (Add-OdtPart $pkg '/ppt/media/logo1.png' 'image/png' ([Convert]::FromBase64String($script:PPng))) 'image' 'rIdLogo'
            $mph += New-OdtPicXml 9 'rIdLogo' @(100000, 100000, 600000, 300000)
        }
        Set-OdtPartText $master "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:sldMaster $script:PX><p:cSld><p:spTree>$script:PGrp$mph</p:spTree></p:cSld><p:clrMap bg1=""lt1"" tx1=""dk1"" bg2=""lt2"" tx2=""dk2"" accent1=""accent1"" accent2=""accent2"" accent3=""accent3"" accent4=""accent4"" accent5=""accent5"" accent6=""accent6"" hlink=""hlink"" folHlink=""folHlink""/><p:sldLayoutIdLst>$lids</p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>"
        $sids = ''; $n = 0; $media = 0
        foreach ($sl in @($Slides)) {
            $n++
            $sp = Add-OdtPart $pkg "/ppt/slides/slide$n.xml" "$script:PCT.slide+xml" 'x'
            Add-OdtRel $sp $lparts[[int]$sl.layout - 1] 'slideLayout' 'rId1'
            if ($sl.pics) { foreach ($k in $sl.pics.Keys) { $media++; Add-OdtRel $sp (Add-OdtPart $pkg "/ppt/media/image$media.png" 'image/png' ([byte[]]$sl.pics[$k])) 'image' $k } }
            Set-OdtPartText $sp "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:sld $script:PX><p:cSld><p:spTree>$script:PGrp$($sl.shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            $null = $pres.CreateRelationship([IO.Packaging.PackUriHelper]::GetRelativeUri($pres.Uri, $sp.Uri), [IO.Packaging.TargetMode]::Internal, "$script:PRB/slide", "rIdS$n")
            $sids += "<p:sldId id=""$(255 + $n)"" r:id=""rIdS$n""/>"
        }
        Add-OdtRel $pres (Add-OdtPart $pkg '/ppt/tableStyles.xml' "$script:PCT.tableStyles+xml" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>') 'tableStyles' 'rIdTS'
        Add-OdtRel $pres (Add-OdtPart $pkg '/ppt/presProps.xml' "$script:PCT.presProps+xml" "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:presentationPr $script:PX/>") 'presProps' 'rIdPP'
        Add-OdtRel $pres (Add-OdtPart $pkg '/ppt/viewProps.xml' "$script:PCT.viewProps+xml" "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:viewPr $script:PX/>") 'viewProps' 'rIdVP'
        Set-OdtPartText $pres "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?><p:presentation $script:PX><p:sldMasterIdLst><p:sldMasterId id=""2147483648"" r:id=""rIdM""/></p:sldMasterIdLst><p:sldIdLst>$sids</p:sldIdLst><p:sldSz cx=""$($Size[0])"" cy=""$($Size[1])""/><p:notesSz cx=""6858000"" cy=""9144000""/></p:presentation>"
    } finally { $pkg.Close() }
    $Path
}

function New-OdtTestDecks {
    <# The two decks of the PowerPoint step: $TemplatePath (16:9, accent 0E7C86, Georgia/Verdana, a logo on
       the master, a start and an end slide) and $ContentPath (4:3, Office layouts: a title slide, a bullets
       slide, a table slide and a slide whose heading is a free text box). Invented text only. #>
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][string]$ContentPath)
    $tpl = @(
        @{ layout = 1; shapes = (New-OdtSpXml -Id 2 -Ph '<p:ph type="ctrTitle"/>' -Text 'Template start') }
        @{ layout = 4; shapes = (New-OdtSpXml -Id 2 -Text 'Thank you' -Rect @(1000000, 3000000, 6000000, 800000) -TextBox) }
    )
    $null = New-OdtDeck -Path $TemplatePath -Layouts (Get-OdtLayouts -Corporate) -Slides $tpl -Size @(12192000, 6858000) -Accent1 '0E7C86' -Major 'Georgia' -Minor 'Verdana' -Logo
    $content = @(
        @{ layout = 1; shapes = (New-OdtSpXml -Id 2 -Ph '<p:ph type="ctrTitle"/>' -Text 'Regional revenue') + (New-OdtSpXml -Id 3 -Ph '<p:ph type="subTitle" idx="1"/>' -Text 'Test deck') }
        @{ layout = 2; shapes = (New-OdtSpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'Highlights') + (New-OdtSpXml -Id 3 -Ph '<p:ph idx="1"/>' -Paras @('North leads', 'South grows', 'East is steady')) }
        @{ layout = 3; shapes = (New-OdtSpXml -Id 2 -Ph '<p:ph type="title"/>' -Text 'Revenue per region') + (New-OdtTableXml 4 @(457200, 1828800, 5486400, 1112520) @('Region', 'Revenue', 'North', '1,234,567', 'South', '845,200')) }
        @{ layout = 4; shapes = (New-OdtSpXml -Id 2 -Text 'Next steps' -Rect @(457200, 457200, 6000000, 900000) -Size 3600 -TextBox) + (New-OdtSpXml -Id 3 -Text 'Review the figures in March.' -Rect @(457200, 2000000, 6000000, 600000) -TextBox) }
    )
    $null = New-OdtDeck -Path $ContentPath -Layouts (Get-OdtLayouts) -Slides $content
    @{ templateSlides = $tpl.Count; contentSlides = $content.Count; freeHeadingSlide = 4 }
}

function Test-PptxPackage {
    <# A deck as PowerPoint would see it: it opens with System.IO.Packaging, every internal relationship
       points at a part that is there, every r: attribute in a part names one of its relationships, and
       the slide ids are unique (256 or more). Returns @{ problems; slides (count) }. #>
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName WindowsBase
    $problems = New-Object System.Collections.Generic.List[string]
    $slides = 0
    $pkg = $null
    try { $pkg = [IO.Packaging.Package]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }
    catch { return @{ problems = @("does not open as a package: $($_.Exception.Message)"); slides = 0 } }
    try {
        $root = New-Object Uri('/', [UriKind]::Relative)
        foreach ($r in @($pkg.GetRelationships())) {
            if ("$($r.TargetMode)" -ne 'Internal') { continue }
            $u = [IO.Packaging.PackUriHelper]::ResolvePartUri($root, $r.TargetUri)
            if (-not $pkg.PartExists($u)) { $problems.Add("package relationship $($r.Id) points at a missing $u") }
        }
        foreach ($p in @($pkg.GetParts())) {
            if ("$($p.Uri)" -match '\.rels$') { continue }
            $ids = @{}
            foreach ($r in @($p.GetRelationships())) {
                $ids[$r.Id] = 1
                if ("$($r.TargetMode)" -ne 'Internal') { continue }
                $u = [IO.Packaging.PackUriHelper]::ResolvePartUri($p.Uri, $r.TargetUri)
                if (-not $pkg.PartExists($u)) { $problems.Add("$($p.Uri): relationship $($r.Id) points at a missing $u") }
            }
            if ("$($p.ContentType)" -notmatch 'xml$') { continue }
            $s = $p.GetStream([IO.FileMode]::Open, [IO.FileAccess]::Read)
            $x = New-Object Xml.XmlDocument
            try { $x.Load($s) } catch { $problems.Add("$($p.Uri): not valid XML"); continue } finally { $s.Dispose() }
            foreach ($a in @($x.SelectNodes("//@*[namespace-uri()='$script:PRB']"))) {
                if ($a.Value -and -not $ids.ContainsKey($a.Value)) { $problems.Add("$($p.Uri): r:$($a.LocalName)=$($a.Value) has no relationship") }
            }
            if ("$($p.ContentType)" -like '*presentation.main+xml' -or "$($p.ContentType)" -like '*template.main+xml') {
                $sids = @($x.SelectNodes("//*[local-name()='sldId']") | ForEach-Object { $_.GetAttribute('id') })
                $slides = $sids.Count
                if ($sids.Count -ne @($sids | Select-Object -Unique).Count) { $problems.Add('slide ids repeat') }
                if (@($sids | Where-Object { [long]$_ -lt 256 }).Count) { $problems.Add('a slide id is below 256') }
            }
        }
    } finally { $pkg.Close() }
    @{ problems = $problems.ToArray(); slides = $slides }
}

function Test-PptxPlan {
    <# The plan StreamHub proposes (a 'pptx-plan' card's pptx): every content slide has a layout the
       template has, and the slide whose heading is a free text box is marked "check" (sure false) or
       has that box as its title (heading > 0). Returns the problems. #>
    param([Parameter(Mandatory)]$Plan, [int]$ContentSlides, [int]$FreeHeadingSlide = 0)
    $problems = New-Object System.Collections.Generic.List[string]
    $layouts = @(Get-AsList $Plan.layouts | ForEach-Object { "$_" })
    $slides = @(Get-AsList $Plan.slides)
    if ($slides.Count -ne $ContentSlides) { $problems.Add("the plan has $($slides.Count) slide(s), the content deck $ContentSlides") }
    foreach ($s in $slides) {
        if (-not "$($s.layout)") { $problems.Add("slide $($s.index) has no layout") }
        elseif ($layouts -notcontains "$($s.layout)") { $problems.Add("slide $($s.index) gets '$($s.layout)', which the template does not have") }
    }
    if ($FreeHeadingSlide) {
        $f = @($slides | Where-Object { [int]$_.index -eq $FreeHeadingSlide }) | Select-Object -First 1
        if (-not $f) { $problems.Add("slide $FreeHeadingSlide is not in the plan") }
        elseif ($f.sure -ne $false -and [int]$f.heading -le 0) { $problems.Add("slide $FreeHeadingSlide (heading in a free text box) is neither marked to check nor converted to a title") }
    }
    $problems.ToArray()
}

function New-PptxApplyChoices {
    <# The apply request's choices from a plan, as the card builds them (buildApplyRequest): the layout
       and title box per slide, the start and end slides, the template's styles. #>
    param([Parameter(Mandatory)]$Plan)
    $layouts = @{}; $titles = @{}
    foreach ($s in @(Get-AsList $Plan.slides)) { $layouts["$($s.index)"] = "$($s.layout)"; $titles["$($s.index)"] = [int]$s.heading }
    @{ layouts = $layouts; titles = $titles; start = [int]$Plan.start; end = [int]$Plan.end; templateStyles = $true; keepBackgrounds = $false }
}

function Test-PptxAskPlan {
    <# The card StreamHub made from Copilot's answer: marked as Copilot's, only known layouts and slide
       numbers, and at least one slide taken from the answer. Returns the problems. #>
    param([Parameter(Mandatory)]$Plan, [int]$ContentSlides)
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not [bool]$Plan.copilot) { $problems.Add('the card is not marked as filled from Copilot''s answer') }
    $layouts = @(Get-AsList $Plan.layouts | ForEach-Object { "$_" })
    $slides = @(Get-AsList $Plan.slides)
    foreach ($s in $slides) {
        if ([int]$s.index -lt 1 -or [int]$s.index -gt $ContentSlides) { $problems.Add("slide number $($s.index) is not in the content deck") }
        if ($layouts -notcontains "$($s.layout)") { $problems.Add("slide $($s.index) names an unknown layout '$($s.layout)'") }
    }
    if (-not @($slides | Where-Object { "$($_.why)" -eq 'Copilot' }).Count) { $problems.Add('no slide took its layout from Copilot''s answer') }
    foreach ($e in @(Get-AsList $Plan.errors)) { $problems.Add("refused from the answer: $e") }
    $problems.ToArray()
}

Export-ModuleMember -Function Get-AsList, Get-ActionPath, Test-PathPattern, Get-ApprovalDecision, Get-SetupAutoAnswer, Get-TextHash, Read-FileBytes,
    New-FileSnapshot, Compare-FileSnapshot, Split-ChangedPaths, Get-OverviewFactsPart, Test-OverviewResult, Get-TokenDeclarations, Test-TokensColourOnly,
    Get-MdSection, Test-PageReportText, Test-DataProfileReport, Test-PackageEntries, Test-TidyItems, Test-QueueSettled, Limit-Line, Get-CopilotStepRecord,
    Resolve-OnlySteps, Format-OnDemandReport, New-OdtDeck, New-OdtTestDecks, Test-PptxPackage, Test-PptxPlan, New-PptxApplyChoices, Test-PptxAskPlan
