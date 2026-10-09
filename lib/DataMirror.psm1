# Data copies: a .js file that only wraps a JSON file's data (window.calendarData = {...};), made
# because a page opened from disk cannot load JSON. The JSON is the one source of truth; the copy is
# rewritten from it whenever it differs, with a first line that says so. Copilot's edits to a copy
# are refused (Assert-Writable in Executor reads that line), so a fix always goes to the JSON or to
# the runbook or script that writes it. Only files that are nothing but such a wrapper are touched.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Workspace', 'Executor') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:SkipDir = '(?i)(^|/)(\.streamhub|\.git|node_modules|dist|build|out|coverage|vendor|Source|\.venv|venv)(/|$)'
$script:HeaderPattern = '^\s*//\s*Generated from (\S+) by the helper program'

function Get-MirrorHeader([string]$JsonRel) {
    "// Generated from $JsonRel by the helper program. Do not edit: change $JsonRel; this file is updated from it."
}

function Test-StrictJsonText([string]$Text) {
    # PowerShell 5.1's JSON reader also takes JavaScript ({a: 1}, 'x', comments, trailing commas).
    # With the double-quoted strings blanked, none of those may be left.
    $m = [regex]::Replace($Text, '"(?:[^"\\\n]|\\.)*"', '""')
    -not ($m -match "'" -or $m -match '[{,]\s*[A-Za-z_$][\w$]*\s*:' -or $m -match '//|/\*' -or $m -match ',\s*[}\]]' -or $m -match '=>|\bfunction\b|\bundefined\b')
}

function Read-DataWrapper {
    <# A JS text that is only "window.NAME = DATA;" (or var/let/const NAME = DATA;), after an optional
       comment header: @{ decl ('window.' or 'const ' ...); name; data (the literal's text); source
       (from a Generated-from header) }. $null for any other script. #>
    param([AllowEmptyString()][string]$Text)
    $t = "$Text".Replace("`r`n", "`n")
    $source = $null
    $hm = [regex]::Match($t, $script:HeaderPattern)
    if ($hm.Success) { $source = $hm.Groups[1].Value }
    # Leading line comments (a header) are allowed; nothing else around the one assignment.
    $body = [regex]::Replace($t, '\A(\s*//[^\n]*\n)*', '').Trim()
    $m = [regex]::Match($body, '^(?:(window\.)|(var|let|const)\s+)([A-Za-z_$][\w$]*)\s*=\s*([\[{][\s\S]*[\]}])\s*;?\s*$')
    if (-not $m.Success) { return $null }
    $data = $m.Groups[4].Value
    if (-not (Test-StrictJsonText $data)) { return $null }   # JSON data only, not any JavaScript object
    try { $null = $data | ConvertFrom-Json } catch { return $null }
    [pscustomobject]@{ decl = $(if ($m.Groups[1].Success) { 'window.' } else { $m.Groups[2].Value + ' ' }); name = $m.Groups[3].Value; data = $data; source = $source }
}

function ConvertTo-DataKey([string]$Json) {
    # Data in one canonical form, to compare a copy with its JSON regardless of layout.
    try { ConvertTo-Json -InputObject ($Json | ConvertFrom-Json) -Depth 60 -Compress } catch { $null }
}

function Find-DataMirrors {
    <# The data copies of a project: JS wrappers paired with their JSON (a Generated-from header,
       else the JSON with the same name: same folder first, then data/, then Runbooks/Exports/). #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = $ProjectRoot.TrimEnd('\')
    $all = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.js', '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/'); full = $_.FullName; size = $_.Length } } |
        Where-Object { $_.rel -notmatch $script:SkipDir -and $_.size -lt 5MB })
    $jsons = @($all | Where-Object { $_.rel -match '(?i)\.json$' })
    foreach ($js in @($all | Where-Object { $_.rel -match '(?i)\.js$' -and $_.rel -notmatch '(?i)\.min\.js$' })) {
        $w = try { Read-DataWrapper (Read-TextFile $js.full).Text } catch { $null }
        if (-not $w) { continue }
        $src = $null
        if ($w.source) { $src = $w.source }
        else {
            $stem = [IO.Path]::GetFileNameWithoutExtension($js.rel) -replace '(?i)\.data$', ''
            $dir = $(if ($js.rel.Contains('/')) { $js.rel.Substring(0, $js.rel.LastIndexOf('/')) } else { '' })
            $same = @($jsons | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.rel) -ieq $stem })
            # Only the places a data copy belongs with its JSON: the same folder, data/, Runbooks/Exports/.
            # A same-named JSON elsewhere is unrelated (a translation table src/i18n/en.js and locales/en.json).
            $pick = @($same | Where-Object { $(if ($_.rel.Contains('/')) { $_.rel.Substring(0, $_.rel.LastIndexOf('/')) } else { '' }) -ieq $dir }) +
                    @($same | Where-Object { $_.rel -match '(?i)^data/' }) + @($same | Where-Object { $_.rel -match '(?i)^Runbooks/Exports/' })
            if ($pick.Count) { $src = $pick[0].rel }
        }
        if ($src) { [pscustomobject]@{ js = $js.rel; json = $src; decl = $w.decl; name = $w.name; marked = [bool]$w.source } }
    }
}

function Update-DataMirrors {
    <# Rewrites every data copy whose data differs from its JSON (or that has no Generated-from line
       yet), from the JSON. Earlier versions go into one change set ($Checkpoint, or a new one), so
       Undo takes them back. Returns per copy: js, json, status (updated, marked, missing-source,
       invalid-source), whether the data differed and, when written, the old and new text; plus the checkpoint. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, $Checkpoint = $null)
    $root = $ProjectRoot.TrimEnd('\')
    $results = New-Object System.Collections.Generic.List[object]
    $cp = $Checkpoint
    foreach ($m in @(Find-DataMirrors $root)) {
        $jsFull = Join-Path $root $m.js.Replace('/', '\')
        $jsonFull = Join-Path $root $m.json.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $jsonFull -PathType Leaf)) { $results.Add([pscustomobject]@{ js = $m.js; json = $m.json; status = 'missing-source'; differed = $false }); continue }
        $jsonText = (Read-TextFile $jsonFull).Text.Trim()
        $key = ConvertTo-DataKey $jsonText
        if ($null -eq $key) { $results.Add([pscustomobject]@{ js = $m.js; json = $m.json; status = 'invalid-source'; differed = $false }); continue }
        $info = Read-TextFile $jsFull
        $w = Read-DataWrapper $info.Text
        $differs = (ConvertTo-DataKey $w.data) -ne $key
        if (-not $differs -and $m.marked) { continue }   # up to date and marked: nothing to do
        $text = (Get-MirrorHeader $m.json) + "`n" + "$($m.decl)$($m.name) = $jsonText;`n"
        if (-not $cp) { $cp = New-Checkpoint $root 'Data copies updated from their JSON' }
        Save-CheckpointFile $cp $root $jsFull
        Write-TextFile $jsFull $text $info.Bom $info.Crlf $info.Encoding
        $results.Add([pscustomobject]@{ js = $m.js; json = $m.json; status = $(if ($differs) { 'updated' } else { 'marked' }); differed = $differs; old = $info.Text; new = $text })
    }
    if ($results.Count) { Write-CCBLog info datamirror 'Data copies checked' @{ updated = @($results | Where-Object status -eq 'updated').Count; problems = @($results | Where-Object { $_.status -like '*-source' }).Count } }
    [pscustomobject]@{ items = $results.ToArray(); checkpoint = $cp }
}

function Format-DataMirrorNotes($Result) {
    <# Chat lines for what Update-DataMirrors did and what it could not do. #>
    foreach ($r in @($Result.items)) {
        switch ($r.status) {
            'updated' { "Data copy $($r.js) updated from $($r.json): its data differed. The JSON is the source; change the JSON (or the runbook or script that writes it), not the copy." }
            'marked' { "Data copy $($r.js) is now marked as generated from $($r.json); from now on it follows the JSON." }
            'missing-source' { "Data copy $($r.js) says it is generated from $($r.json), which no longer exists; it was left as it is." }
            'invalid-source' { "Data copy $($r.js) was not updated: $($r.json) is not valid JSON. Fix the JSON (or what writes it)." }
        }
    }
}

Export-ModuleMember -Function Get-MirrorHeader, Read-DataWrapper, Find-DataMirrors, Update-DataMirrors, Format-DataMirrorNotes
