# Issue detection: what the file checks (Lint), secret scan and code-health limits (Health) find in
# every file, kept up to date incrementally (only files whose size or time changed are scanned
# again), with a status per issue: open, fixing, fixed (gone), gave up, ignored.
# Two levels:
#   - the details per project, inside its work tree: <project>\.streamhub\issues.json
#   - the app index, one summary per project: %LOCALAPPDATA%\CCBridge\issue-index.json, filled by
#     importing each project's details (Import-ProjectIssues) after every update.
# The cycle: index, change, scan the changed files, queue fixes, apply, scan again (Agent.psm1).
# A machine-wide mutex keeps the background indexer and the worker from writing at the same time.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace', 'Executor', 'Lint', 'Health') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:IssueExt = '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte|cs|java|kt|kts|go|rs|php|swift|dart|scala|c|cc|cpp|h|hpp|py|pyw|ps1|psm1|psd1|css|scss|less|json|jsonc|ya?ml|toml|sh|bash|cmd|bat|sql|html?|xml|csproj|config|xaml|svg|md|markdown|csv|tsv)$'
$script:IssueSkip = '(?i)(^|/)(source|\.streamhub|node_modules|dist|build|out|bin|obj|coverage|vendor|\.git|\.venv|venv|__pycache__|evidence|reviews|exports|History|Logs|Runbooks/Exports)/|\.min\.(js|css)$|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$'
$script:Order = @{ error = 0; secret = 1; health = 2 }

function Get-IssueIndexPath([string]$ProjectRoot) { Join-Path $ProjectRoot '.streamhub\issues.json' }

function Get-AppIssueIndexPath {
    if ($env:CCBRIDGE_ISSUE_INDEX) { return $env:CCBRIDGE_ISSUE_INDEX }   # tests
    Join-Path $env:LOCALAPPDATA 'CCBridge\issue-index.json'
}

function Use-IssueLock([scriptblock]$Body) {
    $mx = New-Object Threading.Mutex($false, 'Local\CCBridgeIssueIndex')
    $got = $false
    try { $got = $mx.WaitOne(60000) } catch [Threading.AbandonedMutexException] { $got = $true }
    try { & $Body } finally { if ($got) { $mx.ReleaseMutex() }; $mx.Dispose() }
}

function Read-IssueIndex([string]$ProjectRoot) {
    $p = Get-IssueIndexPath $ProjectRoot
    $ix = @{ version = 1; updated = $null; files = @{}; states = @{}; ignored = @{} }
    if (Test-Path -LiteralPath $p) {
        try {
            $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
            $ix.updated = $j.updated
            foreach ($f in @($j.files.PSObject.Properties)) { $ix.files[$f.Name] = @{ size = [int64]$f.Value.size; mtime = [int64]$f.Value.mtime; issues = @($f.Value.issues | Where-Object { $_ }) } }
            foreach ($s in @($j.states.PSObject.Properties)) { $ix.states[$s.Name] = @{ status = "$($s.Value.status)"; attempts = [int]$s.Value.attempts; note = "$($s.Value.note)" } }
            if ($j.ignored) { foreach ($g in @($j.ignored.PSObject.Properties)) { $ix.ignored[$g.Name] = @{ path = "$($g.Value.path)"; category = "$($g.Value.category)"; message = "$($g.Value.message)"; text = "$($g.Value.text)"; at = "$($g.Value.at)" } } }
        } catch { }
    }
    $ix
}

function Write-JsonFile([string]$Path, $Value) {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path)
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Value -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}

function Save-IssueIndex([string]$ProjectRoot, $Index) {
    $Index.updated = (Get-Date).ToString('s')
    Write-JsonFile (Get-IssueIndexPath $ProjectRoot) $Index
}

function Get-IssueSummary([string]$ProjectRoot, $Index) {
    # Counts of a project's details, for the app index.
    $s = @{ name = (Split-Path $ProjectRoot -Leaf); root = $ProjectRoot; updated = $Index.updated; files = $Index.files.Count
            open = @{ error = 0; secret = 0; health = 0 }; fixing = 0; gaveUp = 0; ignored = 0 }
    foreach ($fl in $Index.files.Values) {
        foreach ($i in @($fl.issues)) {
            switch ("$($Index.states[$i.id].status)") {
                'ignored' { $s.ignored++ } 'fixing' { $s.fixing++ } 'gave up' { $s.gaveUp++ }
                default { $s.open[$i.category]++ }
            }
        }
    }
    $s
}

function Read-AppIssueIndex {
    $p = Get-AppIssueIndexPath
    $ix = @{ updated = $null; projects = @{} }
    if (Test-Path -LiteralPath $p) {
        try {
            $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
            $ix.updated = $j.updated
            foreach ($pr in @($j.projects.PSObject.Properties)) {
                $v = $pr.Value
                $ix.projects[$pr.Name] = @{ name = "$($v.name)"; root = "$($v.root)"; updated = $v.updated; files = [int]$v.files; fixing = [int]$v.fixing; gaveUp = [int]$v.gaveUp; ignored = [int]$v.ignored
                    open = @{ error = [int]$v.open.error; secret = [int]$v.open.secret; health = [int]$v.open.health } }
            }
        } catch { }
    }
    $ix
}

function Import-ProjectIssues {
    <# Reads a project's details (<project>\.streamhub\issues.json) into the app index. A project
       whose folder or details are gone is dropped from the app index. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    Use-IssueLock {
        $app = Read-AppIssueIndex
        $key = $ProjectRoot.TrimEnd('\').ToLowerInvariant()
        if (Test-Path -LiteralPath (Get-IssueIndexPath $ProjectRoot)) { $app.projects[$key] = Get-IssueSummary $ProjectRoot.TrimEnd('\') (Read-IssueIndex $ProjectRoot) }
        else { $app.projects.Remove($key) }
        $app.updated = (Get-Date).ToString('s')
        Write-JsonFile (Get-AppIssueIndexPath) $app
        $app.projects[$key]
    }
}

function Get-AppIssueIndex {
    <# The app index: one summary per project, re-imported from each project's details when those
       changed (also when another program or machine changed them). Drops projects that are gone. #>
    param([string[]]$AlsoProjects)
    $app = Use-IssueLock { Read-AppIssueIndex }
    $roots = @($app.projects.Values | ForEach-Object { $_.root }) + @($AlsoProjects | Where-Object { $_ })
    foreach ($r in @($roots | Select-Object -Unique)) {
        $d = Get-IssueIndexPath $r
        $e = $app.projects[$r.TrimEnd('\').ToLowerInvariant()]
        $seen = [datetime]::MinValue; if ($e) { $null = [datetime]::TryParse("$($e.updated)", [ref]$seen) }
        $stale = -not $e -or -not (Test-Path -LiteralPath $d) -or ((Get-Item -LiteralPath $d).LastWriteTime -gt $seen.AddSeconds(2))
        if ($stale) { $null = Import-ProjectIssues $r }
    }
    $app = Use-IssueLock { Read-AppIssueIndex }
    @($app.projects.Values | Sort-Object name)
}

function Get-IssueId([string]$Category, [string]$Path, [string]$Message, [int]$Occurrence) {
    # Stable across line moves: numbers in the message do not count.
    $key = "$Category|$Path|$($Message -replace '\d+', '#')|$Occurrence"
    $sha = [Security.Cryptography.SHA1]::Create()
    try { (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function ConvertTo-IgnoreText([string]$Text) {
    # A code line as it is compared for ignoring: no line-number prefix, spacing collapsed.
    (("$Text" -replace '^\s*\d+\s*\|\s?', '').Trim() -replace '\s+', ' ')
}

function Get-IgnoreKey([string]$Path, [string]$Category, [string]$Message, [string]$LineText) {
    <# What an ignored finding is: the file, the check, its message (numbers left out) and the code
       line it is about. Not the line number or how often the message occurs, so an ignore holds
       when lines move or other findings come and go. #>
    "$Category|$("$Path".Replace('\', '/').ToLowerInvariant())|$("$Message" -replace '\d+', '#')|$(ConvertTo-IgnoreText $LineText)"
}

function Get-IssueLineText([string]$ProjectRoot, [string]$Path, [int]$Line) {
    if ($Line -le 0) { return '' }
    try {
        $lines = (Read-TextFile (Resolve-ProjectPath $ProjectRoot $Path)).Text.Replace("`r`n", "`n").Split("`n")
        if ($Line -le $lines.Count) { return $lines[$Line - 1].Trim() }
    } catch { }
    ''
}

function Get-IssueIgnore([string]$ProjectRoot, [string]$Path, $Issue) {
    <# @{ key; entry } for one issue: the entry is what the ignore list keeps. Issues indexed before
       the line text was kept take it from the file. #>
    $has = $(if ($Issue -is [hashtable]) { $Issue.ContainsKey('text') } else { [bool]$Issue.PSObject.Properties['text'] })
    $text = ConvertTo-IgnoreText $(if ($has) { "$($Issue.text)" } else { Get-IssueLineText $ProjectRoot $Path ([int]$Issue.line) })
    @{ key = (Get-IgnoreKey $Path $Issue.category $Issue.message $text)
       entry = @{ path = $Path; category = "$($Issue.category)"; message = "$($Issue.message)"; text = $text; at = (Get-Date).ToString('s') } }
}

function Get-FileIssues {
    <# Every issue in one file: errors (file checks, missing local files, unknown PowerShell commands),
       secrets, and code-health limits. Returns @{ id; line; category; message }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text, [bool]$Crlf = $false)
    $t = $Text.Replace("`r`n", "`n")
    $raw = New-Object System.Collections.Generic.List[object]
    $split = {
        param($cat, $s)
        $m = [regex]::Match("$s", '^line (\d+): (.*)$')
        if ($m.Success) { $raw.Add(@{ category = $cat; line = [int]$m.Groups[1].Value; message = $m.Groups[2].Value }) } elseif ($s) { $raw.Add(@{ category = $cat; line = 0; message = "$s" }) }
    }
    foreach ($s in @(Test-FileContent $Path $Text $Crlf) + @(Test-LocalReferences $t $Path $ProjectRoot) + @(if ($Path -match '(?i)\.ps[md]?1$') { Test-PsCommands $t $ProjectRoot })) { & $split 'error' $s }
    # Not in documents and tests: test files hold fake keys on purpose.
    if ($Path -notmatch '(?i)\.(md|markdown)$|(^|/)(tests?|__tests__|fixtures|spec)/|[._-](tests?|spec)\.') { foreach ($s in @(Find-Secrets $t)) { & $split 'secret' $s } }
    foreach ($h in @(Get-HealthIssues $Path $t)) { $raw.Add(@{ category = 'health'; line = $h.line; message = $h.message }) }
    $seen = @{}
    $lines = $t.Split("`n")
    foreach ($r in $raw) {
        $k = "$($r.category)|$($r.message -replace '\d+', '#')"; $seen[$k] = 1 + [int]$seen[$k]
        $lineText = $(if ($r.line -gt 0 -and $r.line -le $lines.Count) { $lines[$r.line - 1].Trim() } else { '' })
        if ($lineText.Length -gt 300) { $lineText = $lineText.Substring(0, 300) }
        [pscustomobject]@{ id = (Get-IssueId $r.category $Path $r.message $seen[$k]); line = $r.line; category = $r.category; message = $r.message; text = $lineText }
    }
}

function Get-IssueCandidates([string]$ProjectRoot) {
    @(Get-ProjectFiles $ProjectRoot | Where-Object { $_.path -match $script:IssueExt -and $_.path -notmatch $script:IssueSkip -and [int64]$_.size -lt 512KB })
}

function Update-IssueIndex {
    <# Scans what changed: all candidate files (or only -Paths), skipping files whose size and time
       are unchanged (unless -Force). Removes files that are gone and states of issues that are gone.
       -Progress (a synchronized hashtable) gets done / total while it runs. Returns a summary. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths, $Progress, [switch]$Force)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ix = Use-IssueLock { Read-IssueIndex $ProjectRoot }
    $all = -not $Paths
    $list = if ($all) { @(Get-IssueCandidates $ProjectRoot | ForEach-Object { $_.path }) } else { @($Paths | ForEach-Object { $_.Replace('\', '/') } | Select-Object -Unique) }
    if ($Progress) { $Progress.total = $list.Count; $Progress.done = 0 }
    $scanned = 0; $results = @{}; $gone = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $list) {
        if ($Progress) { $Progress.done = [int]$Progress.done + 1; $Progress.current = $rel }
        $full = try { Resolve-ProjectPath $ProjectRoot $rel } catch { $null }
        if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf) -or $rel -notmatch $script:IssueExt -or $rel -match $script:IssueSkip) { $gone.Add($rel); continue }
        $fi = Get-Item -LiteralPath $full
        $old = $ix.files[$rel]
        if (-not $Force -and $old -and $old.size -eq $fi.Length -and $old.mtime -eq $fi.LastWriteTimeUtc.Ticks) { continue }
        if ($fi.Length -ge 512KB -or (Test-BinaryFile $full)) { $gone.Add($rel); continue }
        $info = Read-TextFile $full
        $issues = @(try { Get-FileIssues $ProjectRoot $rel $info.Text $info.Crlf } catch { [pscustomobject]@{ id = (Get-IssueId 'error' $rel 'could not be checked' 1); line = 0; category = 'error'; message = "could not be checked: $($_.Exception.Message.Split("`n")[0])" } })
        $results[$rel] = @{ size = $fi.Length; mtime = $fi.LastWriteTimeUtc.Ticks; issues = $issues }
        $scanned++
    }
    Use-IssueLock {
        $ix = Read-IssueIndex $ProjectRoot   # again, inside the lock: another writer may have saved meanwhile
        # Ignores from before the ignore list (a state only): kept by what they are about.
        foreach ($p in @($ix.files.Keys)) { foreach ($i in @($ix.files[$p].issues)) {
            if ($ix.states[$i.id].status -eq 'ignored') { $g = Get-IssueIgnore $ProjectRoot $p $i; if (-not $ix.ignored.ContainsKey($g.key)) { $ix.ignored[$g.key] = $g.entry } }
        } }
        foreach ($k in $results.Keys) { $ix.files[$k] = $results[$k] }
        foreach ($g in $gone) { $ix.files.Remove($g) }
        if ($all) { $keep = @{}; foreach ($p in $list) { $keep[$p] = $true }; foreach ($k in @($ix.files.Keys)) { if (-not $keep.ContainsKey($k)) { $ix.files.Remove($k) } } }
        $live = @{}; foreach ($f in $ix.files.Values) { foreach ($i in @($f.issues)) { $live[$i.id] = $true } }
        foreach ($k in @($ix.states.Keys)) { if (-not $live.ContainsKey($k)) { $ix.states.Remove($k) } }
        # An ignored finding stays ignored when it is found again, under whatever id it has now.
        foreach ($p in @($ix.files.Keys)) { foreach ($i in @($ix.files[$p].issues)) {
            if ($ix.ignored.ContainsKey((Get-IssueIgnore $ProjectRoot $p $i).key) -and $ix.states[$i.id].status -ne 'ignored') { $ix.states[$i.id] = @{ status = 'ignored'; attempts = 0; note = '' } }
        } }
        Save-IssueIndex $ProjectRoot $ix
        $null = Import-ProjectIssues $ProjectRoot
        $counts = @{ error = 0; secret = 0; health = 0 }
        foreach ($f in $ix.files.Values) { foreach ($i in @($f.issues)) { if ($ix.states[$i.id].status -ne 'ignored') { $counts[$i.category]++ } } }
        @{ files = $ix.files.Count; scanned = $scanned; counts = $counts; ms = $sw.ElapsedMilliseconds; updated = $ix.updated }
    }
}

function Get-IssueReport {
    <# Every issue with its file and status (open by default), errors first, then by file and line. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $ix = Use-IssueLock { Read-IssueIndex $ProjectRoot }
    $out = foreach ($p in $ix.files.Keys) {
        foreach ($i in @($ix.files[$p].issues)) {
            $st = $ix.states[$i.id]
            [pscustomobject]@{ id = $i.id; path = $p; line = [int]$i.line; category = $i.category; message = $i.message; status = $(if ($st) { $st.status } else { 'open' }); attempts = $(if ($st) { [int]$st.attempts } else { 0 }); note = $(if ($st) { $st.note } else { '' }) }
        }
    }
    @($out | Sort-Object @{ Expression = { $script:Order[$_.category] } }, path, line)
}

function Set-IssueState {
    <# Records an issue's status (open, fixing, gave up, ignored) and attempts. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string[]]$Ids, [Parameter(Mandatory)][string]$Status, [int]$Attempts = -1, [string]$Note = '')
    Use-IssueLock {
        $ix = Read-IssueIndex $ProjectRoot
        foreach ($id in $Ids) {
            # Ignoring is remembered by what the finding is about; showing it again forgets that.
            foreach ($p in @($ix.files.Keys)) { foreach ($i in @($ix.files[$p].issues | Where-Object { $_.id -eq $id })) {
                $g = Get-IssueIgnore $ProjectRoot $p $i
                if ($Status -eq 'ignored') { $ix.ignored[$g.key] = $g.entry }
                elseif ($Status -eq 'open') { $ix.ignored.Remove($g.key) }
            } }
            $st = if ($ix.states[$id]) { $ix.states[$id] } else { @{ status = 'open'; attempts = 0; note = '' } }
            $st.status = $Status
            if ($Attempts -ge 0) { $st.attempts = $Attempts }
            if ($Note) { $st.note = $Note }
            $ix.states[$id] = $st
        }
        Save-IssueIndex $ProjectRoot $ix
    }
    $null = Import-ProjectIssues $ProjectRoot
}

function Get-IgnoredFindings([string]$ProjectRoot) {
    <# Everything the user ignored, in Issues or in a code review: path, category, message, text. #>
    $ix = Use-IssueLock { Read-IssueIndex $ProjectRoot }
    @($ix.ignored.Values | ForEach-Object { [pscustomobject]$_ })
}

function Set-IgnoredCheck {
    <# Ignores (or with -Undo shows again) a finding of the round's file check, by the same rules as
       Code health > Issues: file, category (error for the file checks, so Issues hides it too;
       check for the other notes), message without numbers and the code line. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Path, [string]$Category = 'error', [string]$Message, [string]$LineText = '', [switch]$Undo)
    $msg = "$Message" -replace '^\s*line \d+:\s*', ''
    $key = Get-IgnoreKey $Path $Category $msg $LineText
    Use-IssueLock {
        $ix = Read-IssueIndex $ProjectRoot
        if ($Undo) { $ix.ignored.Remove($key) } else { $ix.ignored[$key] = @{ path = $Path.Replace('\', '/'); category = $Category; message = $msg; text = (ConvertTo-IgnoreText $LineText); at = (Get-Date).ToString('s') } }
        Save-IssueIndex $ProjectRoot $ix
    }
}

function Test-CheckIgnored {
    <# Whether a finding of the round's check is on the ignore list (as error or as check). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Path, [string]$Message, [string]$LineText = '', $Ignored = $null)
    $list = if ($Ignored) { $Ignored } else { (Use-IssueLock { Read-IssueIndex $ProjectRoot }).ignored }
    $msg = "$Message" -replace '^\s*line \d+:\s*', ''
    foreach ($c in 'error', 'check') { if ($list.ContainsKey((Get-IgnoreKey $Path $c $msg $LineText))) { return $true } }
    $false
}

function Set-IgnoredFinding {
    <# Ignores (or with -Undo shows again) a code review finding: by its file and the first line it
       quotes, so a later review that reports the same line again leaves it out. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Path, [string]$Title, [string]$Quote, [switch]$Undo)
    $text = ConvertTo-IgnoreText (@("$Quote".Replace("`r`n", "`n").Split("`n") | Where-Object { (ConvertTo-IgnoreText $_) }) | Select-Object -First 1)
    if (-not $text) { throw 'This finding quotes no code, so it cannot be recognised in a later review.' }
    $key = Get-IgnoreKey $Path 'review' '' $text
    Use-IssueLock {
        $ix = Read-IssueIndex $ProjectRoot
        if ($Undo) { $ix.ignored.Remove($key) } else { $ix.ignored[$key] = @{ path = $Path.Replace('\', '/'); category = 'review'; message = $Title; text = $text; at = (Get-Date).ToString('s') } }
        Save-IssueIndex $ProjectRoot $ix
    }
}

function Test-RecognisableLine([string]$Text) {
    # Only a line with real content identifies a finding in a review ("}" or "end" could be anywhere).
    ("$Text".Length -ge 8) -and ("$Text" -match '[A-Za-z]')
}

function Test-IgnoredFinding {
    <# True when a code review finding is about a line the user ignored before (in Issues or in a
       review): the same file, and one of the lines it quotes is that line. #>
    param($Ignored, $Finding)
    if (-not $Finding.file) { return $false }
    $file = "$($Finding.file)".Replace('\', '/').ToLowerInvariant()
    $quoted = @("$($Finding.quote)".Replace("`r`n", "`n").Split("`n") | ForEach-Object { ConvertTo-IgnoreText $_ } | Where-Object { $_ })
    if (-not $quoted.Count) { return $false }
    foreach ($g in @($Ignored)) {
        if ((Test-RecognisableLine $g.text) -and "$($g.path)".ToLowerInvariant() -eq $file -and $quoted -contains $g.text) { return $true }
    }
    $false
}

function Format-IgnoredForReview($Ignored, [string[]]$Files) {
    <# The ignored findings in these files, for the review message: Copilot leaves them out. #>
    $want = @{}; foreach ($f in $Files) { $want["$f".Replace('\', '/').ToLowerInvariant()] = $true }
    $list = @(@($Ignored) | Where-Object { (Test-RecognisableLine $_.text) -and $want.ContainsKey("$($_.path)".ToLowerInvariant()) } | Select-Object -First 40)
    if (-not $list.Count) { return '' }
    $lines = $list | ForEach-Object { $t = "$($_.text)"; if ($t.Length -gt 160) { $t = $t.Substring(0, 157) + '...' }; "- $($_.path), the line ``$t``$(if ($_.message) { ": $($_.message)" })" }
    "`n`nThe user checked these and accepted them; do not report them again:`n" + ($lines -join "`n")
}

function New-FixMessage {
    <# The task for Copilot to fix one file's issues: what and where, and how far to go. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Issues, [int]$Attempt = 1)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("Fix these problems in $Path. The helper program's checks found them$(if ($Attempt -gt 1) { ', and they are still there after the previous attempt' }).")
    [void]$sb.AppendLine('For each one: read the lines around it first, fix the cause with edit blocks, and change nothing else in the file. If a problem is not real, leave the code as it is and say why in the done summary.')
    [void]$sb.AppendLine()
    $n = 0
    foreach ($i in @($Issues)) {
        $n++
        $how = switch ($i.category) {
            'health' { ' - split it into smaller functions with clear names; keep its behaviour exactly the same and update the code that calls it' }
            'secret' { ' - move the secret out of the code (read it from an environment variable or a settings file that is not shared) and leave a placeholder' }
            default { '' }
        }
        [void]$sb.AppendLine("$n. $(if ($i.line) { "line $($i.line): " })$($i.message)$how")
    }
    $sb.ToString().TrimEnd()
}

Export-ModuleMember -Function Set-IgnoredCheck, Test-CheckIgnored, Get-IgnoredFindings, Set-IgnoredFinding, Test-IgnoredFinding, Format-IgnoredForReview, Get-IgnoreKey, Get-FileIssues, Get-IssueCandidates, Update-IssueIndex, Get-IssueReport, Set-IssueState, New-FixMessage, Get-IssueIndexPath, Read-IssueIndex, Import-ProjectIssues, Get-AppIssueIndex, Get-AppIssueIndexPath
