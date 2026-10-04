# The project folder layout, in one place: where each kind of file goes. The same rules are given to
# Copilot (prompts/rules/folders.md) and used by the app itself (fetch prompts, runbooks, their data).
#   src/              the project's own source code (new projects; an existing layout is kept)
#   Scripts/          helper scripts Copilot writes (setup, checks, data conversion, one-off tools)
#   Runbooks/         runbook definitions (NAME.runbook.md) and fetch prompts (NAME.prompt.md):
#                     everything that gets data from Microsoft 365 / Work IQ
#   Runbooks/Exports/ the data they produce (runbook JSON, fetch answers)
#   .streamhub/History/  earlier versions of that data (the newest stays in Runbooks/Exports)
#   Logs/             log files the project's own scripts write
#   Source/           the user's source data, read-only
#   .streamhub/       the app's own records (issues, imports, schedules, evidence, reviews,
#                     PLAN.md, History): never written by Copilot
# Also given to Copilot only: tests/, docs/, data/, generated dist/ build/ out/ (never edited), and
# for web projects (prompts/rules/web.md) public/, src/components|pages|styles|assets|lib|data/.
# Move-ProjectLayout moves a project from the layout before v0.1.50 (runbooks/, fetch/, exports/).

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:Layout = [ordered]@{
    Src = 'src'; Scripts = 'Scripts'; Runbooks = 'Runbooks'; Exports = 'Runbooks/Exports'
    History = '.streamhub/History'; Logs = 'Logs'; Source = 'Source'; Work = 'Work'; State = '.streamhub'
    # StreamHub's own records, not part of the project's code: all inside .streamhub/.
    Evidence = '.streamhub/Evidence'; Reviews = '.streamhub/Reviews'; Plan = '.streamhub/PLAN.md'
}

function Get-ProjectLayout { $copy = [ordered]@{}; foreach ($k in $script:Layout.Keys) { $copy[$k] = $script:Layout[$k] }; $copy }

function Get-LayoutPath([Parameter(Mandatory)][string]$Kind, [string]$Name = '') {
    # A project-relative path in the layout, e.g. Get-LayoutPath Exports 'meetings.json'.
    $base = $script:Layout[$Kind]
    if (-not $base) { throw "Unknown layout folder '$Kind'." }
    if ($Name) { "$base/$Name" } else { $base }
}

function Move-LayoutItem([string]$From, [string]$To, $Moved, $Kept, $Moves = $null, [string]$Root = '') {
    if (-not (Test-Path -LiteralPath $From -PathType Leaf)) { return }
    if (Test-Path -LiteralPath $To) { $Kept.Add($From); return }     # never overwrite: both stay, it is logged
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To)
    [IO.File]::Move($From, $To)
    $Moved.Add($To)
    # What moved, project-relative, so references in the project's code can follow (Relink.psm1).
    if ($null -ne $Moves -and $Root) {
        $rel = { param($f) $f.Substring($Root.TrimEnd('\').Length).TrimStart('\').Replace('\', '/') }
        [void]$Moves.Add([pscustomobject]@{ from = (& $rel $From); to = (& $rel $To); folder = $false })
    }
}

function Get-DiskName([string]$Path) {
    # The name of a file or folder as it is on disk (Get-Item returns the case that was asked for).
    $parent = Split-Path $Path -Parent; $leaf = Split-Path $Path -Leaf
    $hit = @([IO.Directory]::GetFileSystemEntries($parent, $leaf)) | Select-Object -First 1
    if ($hit) { [IO.Path]::GetFileName($hit) } else { $leaf }
}

function Remove-EmptyLayoutFolder([string]$Dir) {
    # A folder the move emptied (also its empty subfolders); OneDrive's read-only mark is cleared.
    if (-not [IO.Directory]::Exists($Dir)) { return }
    foreach ($sub in [IO.Directory]::GetDirectories($Dir)) { Remove-EmptyLayoutFolder $sub }
    if (@([IO.Directory]::GetFileSystemEntries($Dir)).Count) { return }
    try { (New-Object IO.DirectoryInfo $Dir).Attributes = 'Directory'; [IO.Directory]::Delete($Dir) } catch { }
}

function Move-ProjectLayout {
    <# Once per project, when it opens: moves fetch prompts and runbooks into Runbooks/, their data
       into Runbooks/Exports/, and earlier versions into .streamhub/History/; runbook headers that
       point at exports/ are updated. StreamHub's own records (History/, evidence/, reviews/,
       PLAN.md) move into .streamhub/. Nothing is overwritten (a clash keeps both and is logged), and Source/
       is never touched. Returns the paths moved to. $Moves (a list) gets every move as
       @{ from; to; folder } (project-relative), for Update-MovedReferences. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [System.Collections.IList]$Moves = $null)
    $moved = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]
    $p = { param($rel) Join-Path $ProjectRoot ($rel.Replace('/', '\')) }
    $runbooks = & $p $script:Layout.Runbooks
    $exports = & $p $script:Layout.Exports
    $history = & $p $script:Layout.History

    # runbooks/ (lowercase) becomes Runbooks/: on Windows the same folder, so only its name changes.
    $old = Join-Path $ProjectRoot 'runbooks'
    if ([IO.Directory]::Exists($old)) {
        $actual = Get-DiskName $old
        if ($actual -ceq 'runbooks') {
            $tmp = Join-Path $ProjectRoot ('runbooks-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            [IO.Directory]::Move($old, $tmp); [IO.Directory]::Move($tmp, $runbooks)
            if ($null -ne $Moves) { [void]$Moves.Add([pscustomobject]@{ from = 'runbooks'; to = $script:Layout.Runbooks; folder = $true }) }
        }
    }
    # fetch/: prompts to Runbooks/, answers to Runbooks/Exports/.
    $fetch = Join-Path $ProjectRoot 'fetch'
    if ([IO.Directory]::Exists($fetch)) {
        foreach ($f in Get-ChildItem -LiteralPath $fetch -File) {
            if ($f.Name -like '*.prompt.md') { Move-LayoutItem $f.FullName (Join-Path $runbooks $f.Name) $moved $kept $Moves $ProjectRoot }
            elseif ($f.Extension -eq '.md') { Move-LayoutItem $f.FullName (Join-Path $exports $f.Name) $moved $kept $Moves $ProjectRoot }
        }
        Remove-EmptyLayoutFolder $fetch
    }
    # exports/: earlier versions to History/, the rest to Runbooks/Exports/.
    $exp = Join-Path $ProjectRoot 'exports'
    if ([IO.Directory]::Exists($exp)) {
        $hist = Join-Path $exp 'history'
        if ([IO.Directory]::Exists($hist)) { foreach ($f in Get-ChildItem -LiteralPath $hist -File) { Move-LayoutItem $f.FullName (Join-Path $history $f.Name) $moved $kept $Moves $ProjectRoot } }
        foreach ($f in Get-ChildItem -LiteralPath $exp -File) { Move-LayoutItem $f.FullName (Join-Path $exports $f.Name) $moved $kept $Moves $ProjectRoot }
        Remove-EmptyLayoutFolder $exp
    }
    # Runbook headers: output: exports/X -> output: Runbooks/Exports/X.
    if ([IO.Directory]::Exists($runbooks)) {
        foreach ($f in Get-ChildItem -LiteralPath $runbooks -Filter '*.runbook.md' -File) {
            $t = [IO.File]::ReadAllText($f.FullName)
            $n = [regex]::Replace($t, '(?m)^(output:\s*)(\./)?exports/', "`$1$($script:Layout.Exports)/")
            if ($n -ne $t) { [IO.File]::WriteAllText($f.FullName, $n, (New-Object Text.UTF8Encoding($false))); $moved.Add("$($script:Layout.Runbooks)/$($f.Name) (output)") }
        }
    }
    # StreamHub's own folders start with a capital (src and conventional code folders such as tests,
    # docs and data stay as they are). On Windows a case-only rename goes through a temporary name.
    foreach ($n in 'Source', 'Scripts', 'Logs', 'Work', '.streamhub\Evidence', '.streamhub\Reviews', '.streamhub\History') {
        $want = Join-Path $ProjectRoot $n
        if (-not [IO.Directory]::Exists($want)) { continue }
        $actual = Get-DiskName $want
        $leaf = Split-Path $n -Leaf
        if ($actual -cne $leaf) {
            try {
                $tmp = "$want-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
                [IO.Directory]::Move($want, $tmp); [IO.Directory]::Move($tmp, $want)
                $moved.Add("$($n.Replace('\', '/'))/ (name)")
                if ($null -ne $Moves) {
                    $parent = Split-Path $n -Parent
                    $from = $(if ($parent) { "$parent\$actual" } else { $actual }).Replace('\', '/')
                    [void]$Moves.Add([pscustomobject]@{ from = $from; to = $n.Replace('\', '/'); folder = $true })
                }
            } catch { $kept.Add("$n (rename: $($_.Exception.Message))") }
        }
    }

    # StreamHub's own records move into .streamhub/: only files StreamHub made (by name or content),
    # so a project's own evidence/ or reviews/ folder keeps its files.
    $own = @(
        @{ from = 'History'; to = $script:Layout.History; match = '^.+-\d{8}-\d{6}\.(json|md)$' }
        @{ from = 'evidence'; to = $script:Layout.Evidence; match = '^task-\d{8}-\d{6}\.md$' }
        @{ from = 'reviews'; to = $script:Layout.Reviews; match = '^review-.+\.(md|json)$' }
    )
    foreach ($o in $own) {
        $dir = Join-Path $ProjectRoot $o.from
        if (-not [IO.Directory]::Exists($dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match $o.match }) { Move-LayoutItem $f.FullName (Join-Path (& $p $o.to) $f.Name) $moved $kept $Moves $ProjectRoot }
        Remove-EmptyLayoutFolder $dir
    }
    $plan = Join-Path $ProjectRoot 'PLAN.md'
    if ([IO.File]::Exists($plan) -and ([IO.File]::ReadAllText($plan) -match '<!-- plan:')) { Move-LayoutItem $plan (& $p $script:Layout.Plan) $moved $kept $Moves $ProjectRoot }

    if ($moved.Count -or $kept.Count) { Write-CCBLog info layout 'Project folders moved to the new layout' @{ project = $ProjectRoot; moved = $moved.Count; kept = @($kept) } }
    @($moved)
}

Export-ModuleMember -Function Get-ProjectLayout, Get-LayoutPath, Move-ProjectLayout
