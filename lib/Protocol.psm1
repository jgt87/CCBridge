# Parses CCBridge action blocks out of Copilot's markdown replies.

$ErrorActionPreference = 'Stop'

$script:ActionTypes = @('read', 'glob', 'grep', 'write', 'edit', 'run', 'todo', 'done')
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
        # Copilot sometimes leaves the info string empty (or "text") and writes the action as the
        # first line of the block: "read index.html". Take the action from that line.
        if ($script:PlainInfo -contains $type -and -not $arg -and $j -lt $lines.Length) {
            $first = [regex]::Match($lines[$j], '^\s*(read|glob|grep|write|edit|run|todo|done)\b[:\s]*(.*)$')
            if ($first.Success) { $type = $first.Groups[1].Value.ToLowerInvariant(); $arg = $first.Groups[2].Value.Trim(); $j++ }
        }
        # In an edit block, code fences inside a SEARCH/REPLACE section are file content
        # (e.g. a markdown example), not the end of the block.
        $inPair = $false
        while ($j -lt $lines.Length) {
            $line = $lines[$j]
            if ($type -eq 'edit') {
                $marker = Get-EditMarker $line
                if ($marker -eq 'search') { $inPair = $true }
                elseif ($marker -eq 'replace') { $inPair = $false }
            }
            if ($line -match $closeRe) {
                if (-not $inPair) { break }
                # Inside a pair a fence is file content, unless no REPLACE marker follows before the
                # next action block (Copilot left out the last one): then it closes the block.
                $replaceAhead = $false
                for ($k = $j + 1; $k -lt $lines.Length; $k++) {
                    if ((Get-EditMarker $lines[$k]) -eq 'replace') { $replaceAhead = $true; break }
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

function Get-EditMarker([string]$Line) {
    <# 'search', 'divider', 'replace' or $null. Tolerates what Copilot sometimes sends: indented
       markers, and markers written as &lt; / &gt; (the page shows our < and > to Copilot that way). #>
    $t = $Line.Trim()
    if ($t -match '^(?:<|&lt;){5,9} ?SEARCH\b') { return 'search' }
    if ($t -match '^(?:>|&gt;){5,9} ?REPLACE\b') { return 'replace' }
    if ($t -match '^={5,9}$') { return 'divider' }
    $null
}

function Get-EditPairs([string]$Body) {
    <# SEARCH/REPLACE pairs of an edit block. The closing REPLACE marker of a pair may be missing
       when the next pair or the end of the block follows. #>
    $pairs = New-Object System.Collections.Generic.List[object]
    $state = 'outside'; $search = $null; $replace = $null
    foreach ($line in $Body.Replace("`r`n", "`n").Split("`n")) {
        $marker = Get-EditMarker $line
        if ($marker -eq 'search') {
            if ($state -eq 'replace') { $pairs.Add(@{ search = ($search -join "`n"); replace = ($replace -join "`n") }) }
            $state = 'search'; $search = New-Object System.Collections.Generic.List[string]; $replace = New-Object System.Collections.Generic.List[string]
            continue
        }
        if ($marker -eq 'divider' -and $state -eq 'search') { $state = 'replace'; continue }
        if ($marker -eq 'replace' -and $state -eq 'replace') { $pairs.Add(@{ search = ($search -join "`n"); replace = ($replace -join "`n") }); $state = 'outside'; continue }
        if ($state -eq 'search') { $search.Add($line) }
        elseif ($state -eq 'replace') { $replace.Add($line) }
    }
    if ($state -eq 'replace') { $pairs.Add(@{ search = ($search -join "`n"); replace = ($replace -join "`n") }) }
    $pairs.ToArray()
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

Export-ModuleMember -Function Get-ActionBlocks, Get-ActionPaths, Get-TodoItems
