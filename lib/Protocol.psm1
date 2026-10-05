# Parses CCBridge action blocks out of Copilot's markdown replies.

$ErrorActionPreference = 'Stop'

$script:ActionTypes = @('read', 'glob', 'grep', 'find', 'web', 'screenshot', 'write', 'edit', 'run', 'runbook', 'remember', 'todo', 'dispute', 'done')
$script:PlainInfo = @('', 'text', 'txt', 'plaintext', 'plain', 'none')

function Get-ActionBlocks {
    <#
    .SYNOPSIS Returns the action blocks in a reply, in order.
    .OUTPUTS  [pscustomobject] type, arg, body, (edit) edits = @(@{search; replace})
    A fence closes on a line with the same fence character repeated at least as often,
    so four-backtick write blocks can contain ordinary ``` fences.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = $Text.Replace("`r`n", "`n").Split("`n")
    $actions = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $lines.Length) {
        $m = [regex]::Match($lines[$i], '^\s{0,3}(`{3,}|~{3,})\s*([A-Za-z]*)(?:[:\s]\s*(.*))?$')
        if (-not $m.Success) { $i++; continue }
        $fence = $m.Groups[1].Value
        $type = $m.Groups[2].Value.ToLowerInvariant()
        $arg = $m.Groups[3].Value.Trim()
        $closeRe = '^\s{0,3}' + [regex]::Escape($fence[0]) + '{' + $fence.Length + ',}\s*$'
        $body = New-Object System.Collections.Generic.List[string]
        $j = $i + 1
        # The action is the block's first line: "ACTION read", "ACTION write PATH" in a ```text block
        # (the form Copilot is taught: a label other than text draws as a chart on some tenants).
        # Older form, still accepted: the action name as the label (```read). Copilot also sometimes
        # leaves the label empty (or "text") and writes the bare action name as the first line.
        if ($script:PlainInfo -contains $type -and -not $arg -and $j -lt $lines.Length) {
            $first = [regex]::Match($lines[$j], '^\s*ACTION\s+(read|glob|grep|find|web|screenshot|write|edit|run|runbook|remember|todo|dispute|done)\b[:\s]*(.*)$', 'IgnoreCase')
            if (-not $first.Success) { $first = [regex]::Match($lines[$j], '^\s*(read|glob|grep|web|write|edit|run|todo|done)\b[:\s]*(.*)$') }
            if ($first.Success) { $type = $first.Groups[1].Value.ToLowerInvariant(); $arg = $first.Groups[2].Value.Trim(); $j++ }
        }
        # In an edit block, code fences inside a SEARCH/REPLACE section are file content
        # (e.g. a markdown example), not the end of the block.
        $inPair = $false; $newStyle = $false
        while ($j -lt $lines.Length) {
            $line = $lines[$j]
            if ($type -eq 'edit') {
                if ($line.Trim() -cmatch '^#{7} SEARCH(?:\s+(?:line\s*\d+|all))?$') { $newStyle = $true }
                $marker = Get-EditMarker $line -NewOnly:$newStyle
                if ($marker -eq 'search') { $inPair = $true }
                elseif ($marker -eq 'replace') { $inPair = $false }
            }
            if ($line -match $closeRe) {
                if (-not $inPair) { break }
                # Inside a pair a fence is file content, unless no REPLACE marker follows before the
                # next action block (Copilot left out the last one): then it closes the block.
                $replaceAhead = $false
                for ($k = $j + 1; $k -lt $lines.Length; $k++) {
                    if ((Get-EditMarker $lines[$k] -NewOnly:$newStyle) -eq 'replace') { $replaceAhead = $true; break }
                    if ($lines[$k] -match '^\s{0,3}(`{3,}|~{3,})\s*[A-Za-z]+') { break }
                }
                if (-not $replaceAhead) { break }
            }
            $body.Add($line); $j++
        }
        $closed = $j -lt $lines.Length
        $i = $j + 1
        if ($script:ActionTypes -notcontains $type) { continue }

        $action = [pscustomobject]@{ type = $type; arg = $arg; body = ($body -join "`n"); closed = $closed; edits = @() }
        if ($type -eq 'edit') { $action.edits = @(Get-EditPairs $action.body) }
        $actions.Add($action)
    }
    # Callers wrap the result in @(); returning the array unrolled keeps one level of nesting.
    $actions.ToArray()
}

function Get-EditMarker([string]$Line, [switch]$NewOnly) {
    <# 'search', 'divider', 'replace' (the end of a pair) or $null. Copilot is taught
       ####### SEARCH / ####### REPLACE / ####### END: whole lines no language uses, without the
       < > that the chat can damage. Still accepted: <<<<<<< SEARCH / ======= / >>>>>>> REPLACE,
       indented markers, &lt; / &gt;, and markers damaged on the way. #>
    $t = $Line.Trim()
    if ($t -cmatch '^#{7} SEARCH(?:\s+(?:line\s*\d+|all))?$') { return 'search' }
    if ($t -cmatch '^#{7} REPLACE$') { return 'divider' }
    if ($t -cmatch '^#{7} END$') { return 'replace' }
    # In a block written with the new markers, an old-looking line (======= in a reStructuredText
    # heading or a merge conflict) is file content.
    if ($NewOnly) { return $null }
    if ($t -match '^(?:<|&lt;){5,9} ?SEARCH\b') { return 'search' }
    # The start marker damaged on the way (its < can be taken for a tag and cut): "SEARCH" or
    # "EARCH" alone, with what is left of the arrows. Upper case only, so file text is not taken for it.
    if ($t -cmatch '^(?:[<>/]|&lt;|&gt;)*\s*S?EARCH(?:\s+(?:line\s*\d+|all))?$') { return 'search' }
    if ($t -match '^(?:>|&gt;){5,9} ?REPLACE\b') { return 'replace' }
    # The end marker damaged on the way (some tenants filter text near HTML tags): "</EPLACE",
    # "REPLACE" alone, or only the arrows. Upper case only, so file text is not taken for it.
    if ($t -cmatch '^(?:[<>/]|&lt;|&gt;)*\s*R?EPLACE$' -or $t -match '^(?:>|&gt;){3,9}$') { return 'replace' }
    if ($t -match '^={5,9}$') { return 'divider' }
    $null
}

function Get-EditPairs([string]$Body) {
    <# SEARCH/REPLACE pairs of an edit block. The closing REPLACE marker of a pair may be missing
       when the next pair or the end of the block follows. A block whose SEARCH marker was lost on
       the way, with exactly one ======= line, is one pair: the lines before it are the SEARCH. #>
    $all = "$Body".Replace("`r`n", "`n").Split("`n")
    $newStyle = [bool](@($all | Where-Object { $_.Trim() -cmatch '^#{7} SEARCH(?:\s+(?:line\s*\d+|all))?$' }).Count)
    $markers = @($all | ForEach-Object { Get-EditMarker $_ -NewOnly:$newStyle })
    if (-not @($markers | Where-Object { $_ -eq 'search' }).Count -and @($markers | Where-Object { $_ -eq 'divider' }).Count -eq 1) {
        $d = [array]::IndexOf($markers, 'divider')
        $before = @(if ($d -gt 0) { $all[0..($d - 1)] })
        $after = @(for ($k = $d + 1; $k -lt $all.Length; $k++) { if ($markers[$k] -eq 'replace') { break }; $all[$k] })
        # Leading and trailing blank lines are not part of the code the edit is about.
        while ($before.Count -and -not $before[0].Trim()) { $before = @($before | Select-Object -Skip 1) }
        while ($after.Count -and -not $after[-1].Trim()) { $after = @($after | Select-Object -First ($after.Count - 1)) }
        if ($before.Count) { return @(@{ search = ($before -join "`n"); replace = ($after -join "`n"); markerLost = $true }) }
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    $state = 'outside'; $search = $null; $replace = $null; $hint = @{}
    foreach ($line in $Body.Replace("`r`n", "`n").Split("`n")) {
        $marker = Get-EditMarker $line -NewOnly:$newStyle
        if ($marker -eq 'search') {
            if ($state -eq 'replace') { $pairs.Add((New-EditPair $search $replace $hint)) }
            $state = 'search'; $search = New-Object System.Collections.Generic.List[string]; $replace = New-Object System.Collections.Generic.List[string]
            # Which match is meant when the SEARCH text is in the file more than once.
            $hint = @{}
            $hm = [regex]::Match($line, '(?i)SEARCH\s+(?:line\s*(\d+)|(all))\b')
            if ($hm.Success) { if ($hm.Groups[1].Success) { $hint.line = [int]$hm.Groups[1].Value } else { $hint.all = $true } }
            continue
        }
        if ($marker -eq 'divider' -and $state -eq 'search') { $state = 'replace'; continue }
        if ($marker -eq 'replace' -and $state -eq 'replace') { $pairs.Add((New-EditPair $search $replace $hint)); $state = 'outside'; continue }
        if ($state -eq 'search') { $search.Add($line) }
        elseif ($state -eq 'replace') { $replace.Add($line) }
    }
    if ($state -eq 'replace') { $pairs.Add((New-EditPair $search $replace $hint)) }
    $pairs.ToArray()
}

function New-EditPair($Search, $Replace, $Hint) {
    $p = @{ search = ($Search -join "`n"); replace = ($Replace -join "`n") }
    if ($Hint -and $Hint.line) { $p.line = $Hint.line }
    if ($Hint -and $Hint.all) { $p.all = $true }
    $p
}

function Get-ActionPaths($Action) {
    <# Paths named by a read action: the info-string argument and/or one per body line. #>
    $paths = @()
    if ($Action.arg) { $paths += $Action.arg }
    $paths += $Action.body.Split("`n") | ForEach-Object { $_.Trim().TrimStart('-', '*', ' ').Trim('`') } | Where-Object { $_ }
    @($paths | Select-Object -Unique)
}

function Get-TodoItems([string]$Body) {
    @($Body.Split("`n") | ForEach-Object {
        $m = [regex]::Match($_, '^\s*[-*]\s*\[([ xX])\]\s*(.+)$')
        if ($m.Success) { [pscustomobject]@{ done = ($m.Groups[1].Value -ne ' '); text = $m.Groups[2].Value.Trim() } }
    })
}

function Get-ScreenshotSteps([AllowEmptyString()][string]$Body) {
    <# The steps of a screenshot action, one per line: "click CSS-SELECTOR", "click text=LABEL"
       (a button, link or tab by its visible text) or "wait MILLISECONDS". At most 5 steps. #>
    @(foreach ($l in "$Body".Replace("`r`n", "`n").Split("`n")) {
        $t = $l.Trim().TrimStart('-', '*').Trim()
        if ($t -match '^(?i)click\s+(.+)$') { @{ kind = 'click'; target = $Matches[1].Trim().Trim('`') } }
        elseif ($t -match '^(?i)wait\s+(\d{1,5})\s*(?:ms)?$') { @{ kind = 'wait'; ms = [Math]::Min(5000, [int]$Matches[1]) } }
    }) | Select-Object -First 5
}

function Test-ProposalText([AllowEmptyString()][string]$Text) {
    <# Whether a reply (its done summary or last text) proposes work instead of doing it: a heading
       line such as "Proposed Month view:" or "Suggested approach:", or words such as "I propose",
       "Would you like me to implement", "Voorstel", together with a list of at least 3 points.
       A fixed text rule (CCBridge has no language model). #>
    $t = ($Text -replace '(?s)`{3,}.*?`{3,}', '')
    if (-not $t.Trim()) { return $false }
    $items = [regex]::Matches($t, '(?m)^\s*(?:[-*+]|\d+[.)])\s+\S').Count
    if ($items -lt 3) { return $false }
    $heading = $t -match '(?im)^[\s#*_>]*(?:proposed|proposal|suggested|suggestion|recommended|plan for|voorgesteld|voorstel)\b[^\n]{0,80}:[\s*_]*$'
    $words = $t -match '(?i)\b(?:I (?:would |could )?(?:propose|suggest|recommend)|my (?:proposal|suggestion|recommendation)|(?:would you like|do you want|want) me to (?:implement|build|add|make|create|apply|go ahead)|shall I (?:implement|build|add|make|create|apply|go ahead)|ik stel voor|mijn voorstel|zal ik (?:dit |het )?(?:bouwen|toevoegen|maken|aanpassen|doorvoeren))\b'
    [bool]($heading -or $words)
}

function Test-UnfinishedText([AllowEmptyString()][string]$Text) {
    <# Whether a reply that changed nothing says, in the first person, work it still has to do
       before the change ("Need to inspect the CSS before making the change", "I will update",
       "requires checking ... first"). A fixed text rule; the code blocks are left out. #>
    $t = ($Text -replace '(?s)`{3,}.*?`{3,}', '')
    if (-not $t.Trim()) { return $false }
    [bool]($t -match '(?im)^\s*(?:I\s+)?(?:still\s+)?need to (?:inspect|check|read|look|review|see|examine|find|open|verify|update|change|edit|add|make|confirm)\b' -or
        $t -match '(?i)\bI(?:''ll| will| still need to| need to| have to| must) (?:first |now |next )?(?:inspect|check|read|look|review|examine|update|change|edit|add|make|apply|implement|fix)\b' -or
        $t -match '(?i)\bbefore (?:making|applying|doing) (?:the|this|these|that|any) (?:change|changes|edit|edits|fix)\b' -or
        $t -match '(?i)\brequires? (?:checking|inspecting|reading|looking at|reviewing)\b[^.]{0,120}\bfirst\b' -or
        $t -match '(?i)\b(?:ik moet|moet ik)\b[^.]{0,80}\b(?:controleren|bekijken|nakijken|lezen|aanpassen|wijzigen|toevoegen)\b')
}

function Get-NextSteps {
    <# Suggested follow-ups in a reply, as prompts the user can send: the list under a heading such as
       "Next steps", "Remaining steps", "Follow-ups", "What's next" or "Volgende stappen", and
       sentences like "The next step is to ...". Fixed patterns (CCBridge has no language model);
       code blocks are skipped. At most $Max, each at most 300 characters. #>
    param([AllowEmptyString()][string]$Text, [int]$Max = 5)
    $steps = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$s)
        $s = ($s -replace '^\s*(\*\*|__)|(\*\*|__)\s*$', '').Trim().TrimEnd(':').Trim()
        if ($s.Length -lt 6) { return }
        if ($s.Length -gt 300) { $s = $s.Substring(0, 297) + '...' }
        $s = $s.Substring(0, 1).ToUpperInvariant() + $s.Substring(1)
        if (-not ($steps | Where-Object { $_ -eq $s })) { $steps.Add($s) }
    }
    $heading = '(?i)^\s*(#{1,6}\s*)?(\*\*|__)?\s*(next steps?|remaining steps|remaining work|follow[- ]?ups?( steps)?|what''s next|what is next|suggested next steps|volgende stappen|vervolgstappen)\b[^\n]{0,40}$'
    $item = '^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?(.+)$'
    $inFence = $false; $inList = $false; $listStarted = $false
    foreach ($line in $Text.Replace("`r`n", "`n").Split("`n")) {
        if ($line -match '^\s{0,3}(`{3,}|~{3,})') { $inFence = -not $inFence; if ($inList -and $listStarted) { $inList = $false }; continue }
        if ($inFence) { continue }
        if ($line -match $heading) { $inList = $true; $listStarted = $false; continue }
        if ($inList) {
            $m = [regex]::Match($line, $item)
            if ($m.Success) { & $add $m.Groups[1].Value; $listStarted = $true; continue }
            if (-not $line.Trim()) { continue }
            # Text right under the heading (no list): one step.
            if (-not $listStarted) { & $add $line; $listStarted = $true; continue }
            $inList = $false
        }
    }
    # "The next step is to populate styles.css ..." (also outside a heading)
    $flat = [regex]::Replace($Text, '(?s)```.*?```', ' ')
    foreach ($m in [regex]::Matches($flat, '(?i)\b(?:the\s+)?next step\s+(?:is|would be|will be|should be)\s*:?\s*(?:to\s+)?([^\n]{8,240}?)(?:\.(?:\s|$)|\n|$)')) { & $add $m.Groups[1].Value }
    @($steps | Select-Object -First $Max)
}

Export-ModuleMember -Function Test-UnfinishedText, Get-ScreenshotSteps, Test-ProposalText, Get-ActionBlocks, Get-ActionPaths, Get-TodoItems, Get-NextSteps
