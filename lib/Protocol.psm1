# Parses CCBridge action blocks out of Copilot's markdown replies.

$ErrorActionPreference = 'Stop'

$script:ActionTypes = @('read', 'glob', 'grep', 'write', 'edit', 'run', 'todo', 'done')

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
        $m = [regex]::Match($lines[$i], '^\s{0,3}(`{3,}|~{3,})\s*([A-Za-z]+)(?:[:\s]\s*(.*))?$')
        if (-not $m.Success) { $i++; continue }
        $fence = $m.Groups[1].Value
        $type = $m.Groups[2].Value.ToLowerInvariant()
        $arg = $m.Groups[3].Value.Trim()
        $closeRe = '^\s{0,3}' + [regex]::Escape($fence[0]) + '{' + $fence.Length + ',}\s*$'
        $body = New-Object System.Collections.Generic.List[string]
        $j = $i + 1
        # In an edit block, code fences inside a SEARCH/REPLACE section are file content
        # (e.g. a markdown example), not the end of the block.
        $inPair = $false
        while ($j -lt $lines.Length) {
            $line = $lines[$j]
            if ($type -eq 'edit') {
                if ($line -match '^<{5,9} ?SEARCH') { $inPair = $true }
                elseif ($line -match '^>{5,9} ?REPLACE') { $inPair = $false }
            }
            if (-not $inPair -and $line -match $closeRe) { break }
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

function Get-EditPairs([string]$Body) {
    $re = '(?s)<{5,9} ?SEARCH[^\n]*\n(.*?)\n?={5,9}[^\n]*\n(.*?)\n?>{5,9} ?REPLACE'
    foreach ($m in [regex]::Matches($Body, $re)) {
        @{ search = $m.Groups[1].Value; replace = $m.Groups[2].Value }
    }
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
