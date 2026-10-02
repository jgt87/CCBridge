# Runbooks: repeatable, read-only exports of Microsoft 365 data (via Copilot with Work IQ) to JSON.
#   templates\runbooks\*.runbook.md    ready-made runbooks shipped with the app
#   runbooks\<name>.runbook.md         the project's runbooks (header + instructions for Copilot)
#   <output> (e.g. exports\<name>.json) the latest valid result, plus exports\history\<name>-<stamp>.json
# The header (between --- lines) is read here: title, output, itemsKey, required, requiredItemFields;
# other header lines become {{placeholders}}. HTML comments are notes for the person and not sent.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace', 'Executor', 'Fetch') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:RunbookDir = 'runbooks'
$script:Reserved = @('title', 'output', 'itemsKey', 'required', 'requiredItemFields')

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
       - In runbooks/: the name is runbooks/NAME.runbook.md with NAME lowercase words joined by -,
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
    if ($p -notmatch '^runbooks/[^/]+$' -or $name -notmatch '\.runbook\.md$') {
        $looks = $isMd -and (($name -match '(?i)runbook') -or ($Text -match '(?s)^\s*---\s*\n.*?\boutput\s*:'))
        if ($AboutRunbooks -and $looks) { return @("runbooks are saved as runbooks/NAME.runbook.md (NAME: lowercase words joined with -), not as $p; write it to runbooks/$slug.runbook.md") }
        return @()
    }
    $problems = New-Object System.Collections.Generic.List[string]
    $stem = $name.Substring(0, $name.Length - '.runbook.md'.Length)
    if ($stem -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { $problems.Add("the name must be lowercase words joined with -, for example runbooks/$slug.runbook.md") }
    if (-not $rb.meta.Count) { $problems.Add('the file must start with the header block between --- lines (title, output, itemsKey, required, requiredItemFields) as in the template') }
    else {
        if (-not "$($rb.meta.title)".Trim()) { $problems.Add('the header needs a title: line') }
        $out = "$($rb.meta.output)".Trim()
        if (-not $out) { $problems.Add("the header needs an output: line, for example output: exports/$stem.json") }
        elseif ($out -notmatch '(?i)\.json$') { $problems.Add("output must be a .json file, for example exports/$stem.json") }
        elseif ([IO.Path]::IsPathRooted($out) -or $out -match '(^|[\\/])\.\.([\\/]|$)') { $problems.Add("output must be a path inside the project, for example exports/$stem.json") }
    }
    if (-not $rb.body) { $problems.Add('the runbook has no instructions below the header') }
    elseif ($rb.body -notmatch '```+\s*json') { $problems.Add('the Output section must show the JSON shape in a ```json block') }
    $problems.ToArray()
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
        $out = if ($rb.meta.output) { $rb.meta.output } else { "exports/$name.json" }
        $outFull = try { Resolve-ProjectPath $ProjectRoot $out } catch { $null }
        $last = if ($outFull -and (Test-Path -LiteralPath $outFull)) { (Get-Item -LiteralPath $outFull).LastWriteTime.ToString('s') } else { $null }
        [pscustomobject]@{ name = $name; title = $(if ($rb.meta.title) { $rb.meta.title } else { $name }); path = "$($script:RunbookDir)/$($f.Name)"; output = $out; lastRun = $last }
    }
}

function New-RunbookFromTemplate {
    <# Copies a template into runbooks/<name>.runbook.md, with its output set to exports/<name>.json. #>
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][string]$Name)
    $src = Join-Path $AppRoot "templates\runbooks\$Template.runbook.md"
    if (-not (Test-Path -LiteralPath $src)) { throw "There is no runbook template '$Template'." }
    $slug = ConvertTo-FetchName $Name
    $full = Assert-Writable $ProjectRoot "$($script:RunbookDir)/$slug.runbook.md"
    if (Test-Path -LiteralPath $full) { throw "A runbook named '$slug' already exists." }
    $text = [IO.File]::ReadAllText($src).Replace("`r`n", "`n")
    $text = [regex]::Replace($text, '(?m)^output:\s*.*$', "output: exports/$slug.json", 1)
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
    <# Writes the validated JSON to the runbook's output file and a dated copy to exports/history. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Output, [Parameter(Mandatory)][string]$Json)
    $enc = New-Object Text.UTF8Encoding($false)
    $full = Assert-Writable $ProjectRoot $Output
    $dir = Split-Path $full; if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    [IO.File]::WriteAllText($full, $Json.Trim() + "`n", $enc)
    $hist = "exports/history/$Name-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
    $hfull = Assert-Writable $ProjectRoot $hist
    $hdir = Split-Path $hfull; if (-not (Test-Path -LiteralPath $hdir)) { $null = New-Item -ItemType Directory -Path $hdir }
    [IO.File]::WriteAllText($hfull, $Json.Trim() + "`n", $enc)
    @{ output = $Output; history = $hist }
}

Export-ModuleMember -Function Get-RunbookSlug, Test-RunbookFile, Read-Runbook, Resolve-RunbookText, Get-RunbookTemplates, Get-Runbooks, New-RunbookFromTemplate, Get-JsonFromReply, Test-RunbookOutput, Save-RunbookOutput
