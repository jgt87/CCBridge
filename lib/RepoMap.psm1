# A compact map of the project's code for the first message of a chat: per file its functions,
# classes, ids and headings with line numbers, so Copilot can read just the part it needs instead
# of searching first. Fixed rules, within a character budget (setting repoMapChars): files the
# message names first, then the files the chat works on, then files many others use (import
# index), then the rest; a big project gets a more selective map, never a bigger one.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace', 'Executor', 'Imports', 'ChatScope') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:CodeExt = '(?i)\.(ps1|psm1|py|[cm]?[jt]sx?|vue|svelte|html?|cs|java|go|rb|php)$'
$script:Skip = '(?i)(^|/)(\.streamhub|\.git|Source|node_modules|dist|build|out|coverage|vendor|\.venv|venv|__pycache__)(/|$)|\.min\.js$'

function Get-RepoMapRanking {
    <# Code files in the order the map takes them, each @{ path; score; users }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Text, [string[]]$ChatFiles)
    $files = @(Get-ProjectFiles $ProjectRoot | Where-Object { $_.path -match $script:CodeExt -and $_.path -notmatch $script:Skip -and [int64]$_.size -lt 300KB })
    if (-not $files.Count) { return @() }
    $ix = try { Read-ImportIndex $ProjectRoot } catch { @{ files = @{} } }
    $users = @{}
    foreach ($k in @($ix.files.Keys)) { foreach ($r in @($ix.files[$k].refs)) { if ($r.target) { $users["$($r.target)"] = 1 + [int]$users["$($r.target)"] } } }
    $named = @{}; foreach ($n in @(Get-NamedFiles $Text @($files | ForEach-Object { $_.path }))) { $named[$n] = $true }
    $chat = @{}; foreach ($c in @($ChatFiles)) { $chat["$c".Replace('\', '/')] = $true }
    @($files | ForEach-Object {
        $p = $_.path
        $u = [int]$users[$p]
        $score = (3 * $u) + $(if ($named.ContainsKey($p)) { 1000 } else { 0 }) + $(if ($chat.ContainsKey($p)) { 500 } else { 0 }) -
            $(if ($p -match '(?i)(^|/)(tests?|__tests__|spec)/|[._-](tests?|spec)\.') { 2 } else { 0 }) - (($p -split '/').Count * 0.1)
        [pscustomobject]@{ path = $p; score = $score; users = $u }
    } | Sort-Object @{ Expression = 'score'; Descending = $true }, path)
}

function Get-RepoMap {
    <# The map as text, at most $MaxChars characters; '' when there is nothing to map or the budget
       is 0. One line per file: "path (used by N): Name 12, Other 40, ...". #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Text, [string[]]$ChatFiles, [int]$MaxChars = 4000)
    if ($MaxChars -le 0) { return '' }
    $sb = New-Object Text.StringBuilder
    $left = 0; $read = 0
    foreach ($f in @(Get-RepoMapRanking $ProjectRoot $Text $ChatFiles)) {
        if ($sb.Length -ge $MaxChars -or $read -ge 120) { $left++; continue }
        $read++
        $outline = @(try { Get-FileOutline (Read-TextFile (Join-Path $ProjectRoot $f.path.Replace('/', '\'))).Text $f.path 40 } catch { @() })
        # "12  function Read-Hooks" -> "Read-Hooks 12": the name and where it starts.
        $parts = @($outline | ForEach-Object {
            if ("$_" -match '^\s*(\d+)\s+(.+)$') {
                $what = $Matches[2] -replace '^(?i)(export\s+)?(default\s+)?(async\s+)?(function|class|def|const|let|var)\s+', '' -replace '\s*[({=:].*$', ''
                if ($what -and $what -notmatch '^<(head|body)>$') { "$($what.Trim()) $($Matches[1])" }
            }
        } | Where-Object { $_ } | Select-Object -Unique)
        if (-not $parts.Count) { $left++; continue }
        $line = "$($f.path)$(if ($f.users) { " (used by $($f.users))" }): $($parts -join ', ')"
        if ($line.Length -gt 400) { $line = $line.Substring(0, 396) + ' ...' }   # one big file does not take the whole map
        $room = $MaxChars - $sb.Length
        if ($line.Length -gt $room) {
            if ($room -lt 80) { $left++; continue }
            $line = $line.Substring(0, $room - 4) + ' ...'
        }
        [void]$sb.AppendLine($line)
    }
    if (-not $sb.Length) { return '' }
    $more = if ($left) { "`n($left more code file(s) not in this map; the file list above has them all.)" } else { '' }
    "Code map (functions, classes, ids and headings with their line numbers; read just the lines you need with PATH:START-END):`n" + $sb.ToString().TrimEnd() + $more
}

Export-ModuleMember -Function Get-RepoMapRanking, Get-RepoMap
