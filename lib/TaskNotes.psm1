# What Copilot writes down for the helper program to keep and check (fixed rules on its text):
#   - "Done when:" lines: the checks a task must pass, taken from the request at its start, which
#     Copilot answers MET / NOT MET at "done" (with the screenshot), kept in the task report.
#   - "Data notes:" lines: what the project's converted data means (rows, keys, how files join,
#     values to watch), asked once per data file and again when its data changed, saved in
#     .streamhub/data-notes.json and sent with every later task.
# StreamHub has no model of its own: these only read and store what Copilot wrote.

$ErrorActionPreference = 'Stop'

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
    "Before you change files, write a line 'Done when:' and under it 2 to 5 checks taken from this request that someone could confirm on the page or in the files (for example: '- the page shows a chart of ITEMS per GROUP'), each a '- ' line. You will be asked about each one at the end. Then go on with the work in the same reply (action blocks): the list alone does not finish the reply."
}

function Read-DoneWhen([AllowEmptyString()][string]$Text) {
    # The checks Copilot listed under "Done when:" (at most 6), or nothing.
    @(Read-NoteBlock $Text 'Done when' 6)
}

function New-AcceptanceAsk([string[]]$Checks) {
    # The question at "done": each check as MET or NOT MET, fixing what is not met first.
    $list = (@($Checks) | ForEach-Object { "- $_" }) -join "`n"
    "Check each 'Done when' line you wrote at the start against the files and the page as they are now (the screenshot, if one is attached):`n$list`nAnswer each on its own line as 'MET: CHECK' or 'NOT MET: CHECK - why'. If one is not met, fix it now with action blocks and answer again after the fix; then send done."
}

function Read-AcceptanceAnswers([AllowEmptyString()][string]$Text, [string[]]$Checks) {
    <# The MET / NOT MET lines of a reply, matched to the checks (by the check's text, else in order).
       @(@{ check; met; note }) for every check; met is $null for a check the reply did not answer. #>
    $answers = @(foreach ($l in "$Text".Replace("`r`n", "`n").Split("`n")) {
        $m = [regex]::Match($l, '^[\s>*_\-]*(NOT\s+MET|MET)\s*[:\-]\s*\**\s*(.+?)\s*$')
        if ($m.Success) { @{ met = ($m.Groups[1].Value -notmatch '(?i)^NOT'); text = $m.Groups[2].Value } }
    })
    $used = @{}
    $i = 0
    foreach ($c in @($Checks)) {
        $hit = $null
        $key = ($c -replace '[^\w ]', '').Trim().ToLowerInvariant()
        for ($k = 0; $k -lt $answers.Count; $k++) {
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
        "- $($r.check): $state"
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

Export-ModuleMember -Function Read-NoteBlock, Get-DoneWhenAsk, Read-DoneWhen, New-AcceptanceAsk, Read-AcceptanceAnswers, Format-AcceptanceReport, Get-DataNotesPath, Read-DataNotes, Get-DataNotesNeeded, Get-DataNotesAsk, Save-DataNotes, Format-DataNotes, Get-RequestTypeAsk, Read-RequestType, Get-ScopeAsk, Read-ScopeDecision, Get-NotesGoAhead
