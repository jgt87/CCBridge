# Runbooks: repeatable, read-only exports of Microsoft 365 data (via Copilot with Work IQ) to JSON.
#   templates\runbooks\*.runbook.md    ready-made runbooks shipped with the app
#   Runbooks\<name>.runbook.md         the project's runbooks (header + instructions for Copilot)
#   <output> (e.g. Runbooks\Exports\<name>.json) the latest valid result, plus .streamhub\History\<name>-<stamp>.json
#   (the folders come from Layout.psm1)
# The header (between --- lines) is read here: title, output, itemsKey, required, requiredItemFields;
# other header lines become {{placeholders}}. HTML comments are notes for the person and not sent.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace', 'Executor', 'Fetch', 'Layout') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:RunbookDir = Get-LayoutPath Runbooks
$script:ExportDir = Get-LayoutPath Exports
$script:Reserved = @('title', 'output', 'itemsKey', 'required', 'requiredItemFields', 'sources', 'sites', 'pages', 'agent', 'files')

function Read-Runbook {
    <# Splits a runbook into its header (ordered key/value pairs) and its instructions (comments removed). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $t = $Text.Replace("`r`n", "`n")
    $meta = [ordered]@{}
    $body = $t
    $m = [regex]::Match($t, '(?s)^\s*---\n(.*?)\n---\n?')
    if ($m.Success) {
        foreach ($line in $m.Groups[1].Value.Split("`n")) {
            $kv = [regex]::Match($line, '^\s*([A-Za-z][\w-]*)\s*:\s*(.*?)\s*$')
            if ($kv.Success) { $meta[$kv.Groups[1].Value] = $kv.Groups[2].Value }
        }
        $body = $t.Substring($m.Length)
    }
    $body = [regex]::Replace($body, '(?s)<!--.*?-->\n?', '').Trim()
    @{ meta = $meta; body = $body }
}

function Get-RunbookSlug([string]$Text) {
    <# "Meetings next week" -> "meetings-next-week"; empty when nothing usable is left. #>
    $s = ("$Text".ToLowerInvariant() -replace '\.runbook\.md$|\.md$', '' -replace '[^a-z0-9]+', '-').Trim('-')
    $s = ($s -replace '(^|-)runbook(-|$)', '$1$2' -replace '-{2,}', '-').Trim('-')
    if ($s.Length -gt 50) { $s = $s.Substring(0, 50).Trim('-') }
    $s
}

function Test-RunbookFile {
    <# Rules for a runbook file Copilot writes; returns the problems (none = fine).
       - In Runbooks/: the name is Runbooks/NAME.runbook.md with NAME lowercase words joined by -,
         the header has title and output (a .json path inside the project), and there are
         instructions with the JSON shape in a ```json block.
       - Elsewhere: when the request is about runbooks ($AboutRunbooks) and the file looks like a
         runbook (a .md file with "runbook" in its name, or a header with output:), it is in the
         wrong place; the problem names the right path. #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text, [bool]$AboutRunbooks = $false)
    $p = $Path.Trim().Replace('\', '/') -replace '^\./', ''
    $name = ($p -split '/')[-1]
    $rb = Read-Runbook "$Text"
    $slug = Get-RunbookSlug $(if ($rb.meta.title) { $rb.meta.title } else { $name })
    if (-not $slug) { $slug = 'NAME' }
    $isMd = $name -match '(?i)\.md$'
    $rd = $script:RunbookDir; $ed = $script:ExportDir
    if ($p -notmatch "(?i)^$([regex]::Escape($rd))/[^/]+$" -or $name -notmatch '\.runbook\.md$') {
        $looks = $isMd -and (($name -match '(?i)runbook') -or ($Text -match '(?s)^\s*---\s*\n.*?\boutput\s*:'))
        if ($AboutRunbooks -and $looks) { return @("runbooks are saved as $rd/NAME.runbook.md (NAME: lowercase words joined with -), not as $p; write it to $rd/$slug.runbook.md") }
        return @()
    }
    $problems = New-Object System.Collections.Generic.List[string]
    $stem = $name.Substring(0, $name.Length - '.runbook.md'.Length)
    if ($stem -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { $problems.Add("the name must be lowercase words joined with -, for example $rd/$slug.runbook.md") }
    if (-not $rb.meta.Count) { $problems.Add('the file must start with the header block between --- lines (title, output, itemsKey, required, requiredItemFields) as in the template') }
    else {
        if (-not "$($rb.meta.title)".Trim()) { $problems.Add('the header needs a title: line') }
        $out = "$($rb.meta.output)".Trim()
        if (-not $out) { $problems.Add("the header needs an output: line, for example output: $ed/$stem.json") }
        elseif ($out -notmatch '(?i)\.json$') { $problems.Add("output must be a .json file, for example $ed/$stem.json") }
        elseif ([IO.Path]::IsPathRooted($out) -or $out -match '(^|[\\/])\.\.([\\/]|$)') { $problems.Add("output must be a path inside the project, for example $ed/$stem.json") }
        elseif ($out -notmatch "(?i)^$([regex]::Escape($ed))/") { $problems.Add("the data goes in $ed/: write output: $ed/$stem.json") }
    }
    if (-not $rb.body) { $problems.Add('the runbook has no instructions below the header') }
    elseif ($rb.body -notmatch '```+\s*json') { $problems.Add('the Output section must show the JSON shape in a ```json block') }
    $problems.ToArray()
}

function Get-RunbookRunRequest {
    <# Whether a chat message asks to run a runbook, and which one. Naming a runbook is enough: its
       name, title or path (@Runbooks/NAME.runbook.md). Without a specific runbook, the word runbook
       (draaiboek) with a run word (run, execute, start, draai, voer uit) runs the only runbook, or
       asks which one. Not when the message creates or changes a runbook, asks about one, or reports
       a problem with one (incorrect, wrong, should, instead...): those go to Copilot. A named runbook
       runs only from a short message (8 words at most) or one with a run word, so a longer message
       that mentions a runbook while describing something else never starts it: when such a message
       names exactly one runbook and says nothing about changing it, @{ name; ask = $true } lets the
       person choose (run it, or send the message to Copilot).
       Returns $null (not a run request) or @{ name } or @{ ambiguous = $true; names }. #>
    param([AllowEmptyString()][string]$Text, $Runbooks)
    if (-not "$Text".Trim()) { return $null }
    if ($Text -match '(?i)\b(create|make|write|new|add|build|edit|change|update|fix|rename|improve|delete|remove|maak|schrijf|nieuwe?|wijzig|verander|pas|verwijder)\b') { return $null }
    if ($Text -match '(?i)\b(what|why|how|explain|describe|show|open|view|look|read|which|wat|waarom|hoe|leg|toon|bekijk|welke)\b|\?\s*$') { return $null }
    # Feedback about a runbook (it is wrong, it should do something else) is a change request.
    if ($Text -match '(?i)\b(incorrect(ly)?|wrong|should(n.?t)?|must|instead|rather|mistakes?|errors?|broken|bugs?|problems?|issues?|missing|not right|onjuist|fout(ief)?|klopt niet|moet|moeten|zou|zouden|in plaats van)\b') { return $null }
    $runWord = $Text -match '(?i)\b(run|re-?run|execute|start|launch|perform|draai|uitvoeren|voer)\b'
    $short = @($Text.Trim() -split '\s+').Count -le 8
    $list = @($Runbooks | Where-Object { $_ })
    $low = $Text.ToLowerInvariant()
    $hits = @($list | Where-Object {
        $low.Contains("$($_.name)".ToLowerInvariant()) -or ($_.title -and $low.Contains("$($_.title)".ToLowerInvariant())) -or $low.Contains("$($_.path)".ToLowerInvariant()) -or
        $low.Contains(("$($_.name)" -replace '-', ' ').ToLowerInvariant())
    })
    # The longest name wins when one name contains another (meetings / meetings-next-week).
    if ($hits.Count -gt 1) { $hits = @($hits | Sort-Object { "$($_.name)".Length } -Descending | Select-Object -First 1) }
    if ($hits.Count -eq 1) { if ($runWord -or $short) { return @{ name = $hits[0].name } } else { return @{ name = $hits[0].name; ask = $true } } }
    $mentions = $Text -match '(?i)\b(runbooks?|draaiboek(en)?)\b|\.runbook\.md'
    if (-not ($mentions -and $runWord)) { return $null }
    if ($list.Count -eq 1) { return @{ name = $list[0].name } }
    @{ ambiguous = $true; names = @($list | ForEach-Object { $_.name }) }
}
function Get-TimeZoneText {
    $tz = [TimeZoneInfo]::Local
    $off = $tz.GetUtcOffset((Get-Date))
    "$($tz.Id), currently UTC$(if ($off -lt [TimeSpan]::Zero) { '-' } else { '+' })$($off.Duration().ToString('hh\:mm'))"
}

function Resolve-RunbookText {
    <# Fills in {{today}}, {{now}}, {{weekStart}}, {{weekEnd}}, {{monthStart}}, {{monthEnd}},
       {{today+Nd}} / {{today-Nd}}, {{timezone}} and the header's own keys (for example {{topic}}). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, $Meta = @{}, [datetime]$Now = (Get-Date))
    $d = $Now.Date
    $monday = $d.AddDays(-(([int]$d.DayOfWeek + 6) % 7))
    $values = @{
        today = $d.ToString('yyyy-MM-dd'); now = $Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
        weekStart = $monday.ToString('yyyy-MM-dd'); weekEnd = $monday.AddDays(6).ToString('yyyy-MM-dd')
        monthStart = (Get-Date -Year $d.Year -Month $d.Month -Day 1).ToString('yyyy-MM-dd')
        monthEnd = (Get-Date -Year $d.Year -Month $d.Month -Day 1).AddMonths(1).AddDays(-1).ToString('yyyy-MM-dd')
        timezone = (Get-TimeZoneText)
    }
    foreach ($k in $Meta.Keys) { if ($script:Reserved -notcontains $k) { $values[$k] = "$($Meta[$k])" } }
    [regex]::Replace($Text, '\{\{\s*([A-Za-z]\w*(?:-[A-Za-z]\w*)*)\s*(?:([+-])\s*(\d+)\s*d)?\s*\}\}', {
        param($m)
        $key = $m.Groups[1].Value
        if ($m.Groups[2].Success -and $key -eq 'today') {
            $n = [int]$m.Groups[3].Value; if ($m.Groups[2].Value -eq '-') { $n = -$n }
            return $d.AddDays($n).ToString('yyyy-MM-dd')
        }
        if ($values.ContainsKey($key)) { return $values[$key] }
        $m.Value
    })
}

function Get-RunbookTemplates {
    param([Parameter(Mandatory)][string]$AppRoot)
    foreach ($f in Get-ChildItem (Join-Path $AppRoot 'templates\runbooks') -Filter '*.runbook.md' -ErrorAction SilentlyContinue | Sort-Object Name) {
        $rb = Read-Runbook ([IO.File]::ReadAllText($f.FullName))
        [pscustomobject]@{ id = $f.Name.Substring(0, $f.Name.Length - '.runbook.md'.Length); title = $(if ($rb.meta.title) { $rb.meta.title } else { $f.Name }) }
    }
}

function Get-Runbooks {
    <# The project's runbooks with their output file and when it was last written. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $dir = Join-Path $ProjectRoot $script:RunbookDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.runbook.md' -File | Sort-Object Name) {
        $name = $f.Name.Substring(0, $f.Name.Length - '.runbook.md'.Length)
        $rb = Read-Runbook ([IO.File]::ReadAllText($f.FullName))
        $out = if ($rb.meta.output) { $rb.meta.output } else { "$($script:ExportDir)/$name.json" }
        $outFull = try { Resolve-ProjectPath $ProjectRoot $out } catch { $null }
        $last = if ($outFull -and (Test-Path -LiteralPath $outFull)) { (Get-Item -LiteralPath $outFull).LastWriteTime.ToString('s') } else { $null }
        [pscustomobject]@{ name = $name; title = $(if ($rb.meta.title) { $rb.meta.title } else { $name }); path = "$($script:RunbookDir)/$($f.Name)"; output = $out; lastRun = $last }
    }
}

function New-RunbookFromTemplate {
    <# Copies a template into Runbooks/<name>.runbook.md, with its output set to Runbooks/Exports/<name>.json. #>
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][string]$Name)
    $src = Join-Path $AppRoot "templates\runbooks\$Template.runbook.md"
    if (-not (Test-Path -LiteralPath $src)) { throw "There is no runbook template '$Template'." }
    $slug = ConvertTo-FetchName $Name
    $full = Assert-Writable $ProjectRoot "$($script:RunbookDir)/$slug.runbook.md"
    if (Test-Path -LiteralPath $full) { throw "A runbook named '$slug' already exists." }
    $text = [IO.File]::ReadAllText($src).Replace("`r`n", "`n")
    $text = [regex]::Replace($text, '(?m)^output:\s*.*$', "output: $($script:ExportDir)/$slug.json", 1)
    $dir = Split-Path $full
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    [IO.File]::WriteAllText($full, $text, (New-Object Text.UTF8Encoding($false)))
    Get-Runbooks $ProjectRoot | Where-Object name -eq $slug
}

function Get-JsonFromReply {
    <# The JSON in a reply: the first ```json block, else the first code block or reply that is a JSON object or array. #>
    param([AllowEmptyString()][string]$Text)
    $m = [regex]::Match($Text, '(?s)```+\s*json\s*\n(.*?)\n\s*```+')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    foreach ($b in [regex]::Matches($Text, '(?s)```+[^\n]*\n(.*?)\n\s*```+')) { $c = $b.Groups[1].Value.Trim(); if ($c -match '^[\[{]') { return $c } }
    $t = $Text.Trim(); if ($t -match '^[\[{]') { return $t }
    $null
}

function Test-RunbookOutput {
    <# Checks the JSON against the runbook header: it parses, has the required keys, the list
       (itemsKey) is a list, and every item has the required fields (null is allowed: "unknown").
       Returns @{ ok; errors; count; truncated }. #>
    param([AllowEmptyString()][string]$Json, $Meta = @{})
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not "$Json".Trim()) { return @{ ok = $false; errors = @('the reply contains no JSON code block'); count = 0 } }
    try { $data = $Json | ConvertFrom-Json } catch { return @{ ok = $false; errors = @("the JSON does not parse: $($_.Exception.Message.Split("`n")[0])"); count = 0 } }
    $names = if ($data -is [pscustomobject]) { @($data.PSObject.Properties.Name) } else { @() }
    $split = { param($s) @("$s".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    foreach ($k in & $split $Meta.required) { if ($names -notcontains $k) { $errors.Add("the top-level key ""$k"" is missing") } }
    $count = 0
    if ($Meta.itemsKey) {
        $items = $data.($Meta.itemsKey)
        if ($names -contains $Meta.itemsKey -and $null -ne $items -and $items -isnot [array] -and $items -isnot [pscustomobject]) { $errors.Add("""$($Meta.itemsKey)"" must be a list") }
        $items = @($items | Where-Object { $null -ne $_ })
        $count = $items.Count
        $fields = & $split $Meta.requiredItemFields
        for ($i = 0; $i -lt $items.Count -and $errors.Count -lt 12; $i++) {
            $have = @($items[$i].PSObject.Properties.Name)
            $missing = @($fields | Where-Object { $have -notcontains $_ })
            if ($missing.Count) { $errors.Add("$($Meta.itemsKey)[$i] is missing: $($missing -join ', ')") }
        }
    }
    @{ ok = (-not $errors.Count); errors = @($errors); count = $count; truncated = [bool]$data.truncated }
}

function Save-RunbookOutput {
    <# Writes the validated JSON to the runbook's output file and a dated copy to .streamhub/History/. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Output, [Parameter(Mandatory)][string]$Json)
    $enc = New-Object Text.UTF8Encoding($false)
    $full = Assert-Writable $ProjectRoot $Output
    $dir = Split-Path $full; if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    [IO.File]::WriteAllText($full, $Json.Trim() + "`n", $enc)
    $hist = Get-LayoutPath History "$Name-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
    $hfull = Resolve-ProjectPath $ProjectRoot $hist   # StreamHub's own record (in .streamhub/)
    $hdir = Split-Path $hfull; if (-not (Test-Path -LiteralPath $hdir)) { $null = New-Item -ItemType Directory -Path $hdir }
    [IO.File]::WriteAllText($hfull, $Json.Trim() + "`n", $enc)
    @{ output = $Output; history = $hist }
}

Export-ModuleMember -Function Get-RunbookRunRequest, Get-RunbookSlug, Test-RunbookFile, Read-Runbook, Resolve-RunbookText, Get-RunbookTemplates, Get-Runbooks, New-RunbookFromTemplate, Get-JsonFromReply, Test-RunbookOutput, Save-RunbookOutput
