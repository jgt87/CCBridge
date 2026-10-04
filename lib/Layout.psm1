# The project folder layout, in one place: where each kind of file goes. The same rules are given to
# Copilot (prompts/rules/folders.md) and used by the app itself (fetch prompts, runbooks, their data).
#   src/              the project's own source code (new projects; an existing layout is kept)
#   Scripts/          helper scripts Copilot writes (setup, checks, data conversion, one-off tools)
#   Runbooks/         runbook definitions (NAME.runbook.md) and fetch prompts (NAME.prompt.md):
#                     everything that gets data from Microsoft 365 / Work IQ
#   Runbooks/Exports/ the data they produce (runbook JSON, fetch answers)
#   History/          earlier versions of that data (the newest stays in Runbooks/Exports)
#   Logs/             log files the project's own scripts write
#   source/           the user's source data, read-only
#   .streamhub/       the app's own records (issues, imports, schedules): never written by Copilot
# Also given to Copilot only: tests/, docs/, data/, generated dist/ build/ out/ (never edited), and
# for web projects (prompts/rules/web.md) public/, src/components|pages|styles|assets|lib|data/.
# Move-ProjectLayout moves a project from the layout before v0.1.50 (runbooks/, fetch/, exports/).

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:Layout = [ordered]@{
    Src = 'src'; Scripts = 'Scripts'; Runbooks = 'Runbooks'; Exports = 'Runbooks/Exports'
    History = 'History'; Logs = 'Logs'; Source = 'source'; State = '.streamhub'
}

function Get-ProjectLayout { $copy = [ordered]@{}; foreach ($k in $script:Layout.Keys) { $copy[$k] = $script:Layout[$k] }; $copy }

function Get-LayoutPath([Parameter(Mandatory)][string]$Kind, [string]$Name = '') {
    # A project-relative path in the layout, e.g. Get-LayoutPath Exports 'meetings.json'.
    $base = $script:Layout[$Kind]
    if (-not $base) { throw "Unknown layout folder '$Kind'." }
    if ($Name) { "$base/$Name" } else { $base }
}

function Move-LayoutItem([string]$From, [string]$To, $Moved, $Kept) {
    if (-not (Test-Path -LiteralPath $From -PathType Leaf)) { return }
    if (Test-Path -LiteralPath $To) { $Kept.Add($From); return }     # never overwrite: both stay, it is logged
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To)
    [IO.File]::Move($From, $To)
    $Moved.Add($To)
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
       into Runbooks/Exports/, and earlier versions into History/; runbook headers that point at
       exports/ are updated. Nothing is overwritten (a clash keeps both and is logged), and source/
       is never touched. Returns the paths moved to. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $moved = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]
    $p = { param($rel) Join-Path $ProjectRoot ($rel.Replace('/', '\')) }
    $runbooks = & $p $script:Layout.Runbooks
    $exports = & $p $script:Layout.Exports
    $history = & $p $script:Layout.History

    # runbooks/ (lowercase) becomes Runbooks/: on Windows the same folder, so only its name changes.
    $old = Join-Path $ProjectRoot 'runbooks'
    if ([IO.Directory]::Exists($old)) {
        $actual = (Get-Item -LiteralPath $old).Name
        if ($actual -ceq 'runbooks') {
            $tmp = Join-Path $ProjectRoot ('runbooks-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            [IO.Directory]::Move($old, $tmp); [IO.Directory]::Move($tmp, $runbooks)
        }
    }
    # fetch/: prompts to Runbooks/, answers to Runbooks/Exports/.
    $fetch = Join-Path $ProjectRoot 'fetch'
    if ([IO.Directory]::Exists($fetch)) {
        foreach ($f in Get-ChildItem -LiteralPath $fetch -File) {
            if ($f.Name -like '*.prompt.md') { Move-LayoutItem $f.FullName (Join-Path $runbooks $f.Name) $moved $kept }
            elseif ($f.Extension -eq '.md') { Move-LayoutItem $f.FullName (Join-Path $exports $f.Name) $moved $kept }
        }
        Remove-EmptyLayoutFolder $fetch
    }
    # exports/: earlier versions to History/, the rest to Runbooks/Exports/.
    $exp = Join-Path $ProjectRoot 'exports'
    if ([IO.Directory]::Exists($exp)) {
        $hist = Join-Path $exp 'history'
        if ([IO.Directory]::Exists($hist)) { foreach ($f in Get-ChildItem -LiteralPath $hist -File) { Move-LayoutItem $f.FullName (Join-Path $history $f.Name) $moved $kept } }
        foreach ($f in Get-ChildItem -LiteralPath $exp -File) { Move-LayoutItem $f.FullName (Join-Path $exports $f.Name) $moved $kept }
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
    if ($moved.Count -or $kept.Count) { Write-CCBLog info layout 'Project folders moved to the new layout' @{ project = $ProjectRoot; moved = $moved.Count; kept = @($kept) } }
    @($moved)
}

Export-ModuleMember -Function Get-ProjectLayout, Get-LayoutPath, Move-ProjectLayout
