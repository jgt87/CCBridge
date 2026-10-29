# Four of Copilot's actions that work on the project as a whole (Agent Invoke-AgentActionCore runs
# them; prompts/actions-project.md and actions-run.md teach them):
# - move: files and folders moved or renamed inside the project, every file in the turn's change set
#   (Undo puts them back), and the paths other files use to reach them rewritten (Relink), so a move
#   needs no command, no delete check of a script and no fix round for broken links.
# - delete: files and folders removed inside the project, backed up in the change set first; never
#   through a link, never Source/, .streamhub/, protected or generated files.
# - refs: every place a name is used (whole words, comment lines left out, definitions marked), or
#   for a file, what loads or names it: what to check before a rename or a changed signature.
# - changes: what this message changed so far, per file as compact line changes, from the change set.
# All fixed rules on paths and text; the person approves move and delete as with any change.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Workspace', 'Executor', 'Relink', 'Imports') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:MaxFiles = 500
$script:MaxBytes = 200MB

function Get-ActionLines([string]$Arg, [string]$Body) {
    # The argument and the body lines of an action, trimmed, without empty lines and quotes around them.
    @(@("$Arg") + @("$Body".Replace("`r", '').Split("`n")) | ForEach-Object { $_.Trim().Trim('`', '"', "'").Trim() } | Where-Object { $_ })
}

function Get-MovePairs([string]$Arg, [string]$Body) {
    <# The moves an ACTION move block asks for: "FROM -> TO" per line (=> also), or FROM and TO on two
       lines. @(@{ from; to }); a lone path left at the end is returned with to = ''. #>
    $out = New-Object System.Collections.Generic.List[object]
    $pending = $null
    foreach ($l in (Get-ActionLines $Arg $Body)) {
        $m = [regex]::Match($l, '^(.+?)\s*(?:->|=>)\s*(.+)$')
        if ($m.Success) {
            if ($pending) { $out.Add(@{ from = $pending; to = '' }); $pending = $null }
            $out.Add(@{ from = $m.Groups[1].Value.Trim().Trim('`', '"', "'"); to = $m.Groups[2].Value.Trim().Trim('`', '"', "'") })
        } elseif ($pending) { $out.Add(@{ from = $pending; to = $l }); $pending = $null }
        else { $pending = $l }
    }
    if ($pending) { $out.Add(@{ from = $pending; to = '' }) }
    $out.ToArray()
}

function Get-DeletePaths([string]$Arg, [string]$Body) {
    # The paths an ACTION delete block names: one per line (the action line may hold the first).
    @(Get-ActionLines $Arg $Body | Select-Object -Unique)
}

function Get-TreeFiles([string]$Folder) {
    <# Every file under a folder, as full paths. Throws on a junction or symbolic link inside: moving
       or deleting through it would reach files outside the folder (Workspace Test-LinkPath). #>
    $files = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Folder)
    while ($stack.Count) {
        $d = $stack.Pop()
        foreach ($e in [IO.Directory]::GetFileSystemEntries($d)) {
            if (Test-LinkPath $e) { throw "it holds a link to another place ($(Split-Path $e -Leaf)), which is never followed" }
            if ([IO.Directory]::Exists($e)) { $stack.Push($e) } else { $files.Add($e) }
        }
    }
    $files.ToArray()
}

function Get-PlanFiles([string]$ProjectRoot, [string]$Full, [string]$What) {
    # The files a move or delete of $Full touches, within the limits: @{ files; bytes } or throws.
    if (Test-LinkPath $Full) { throw "$What is a link to another place; it is never moved or deleted through" }
    $files = if ([IO.Directory]::Exists($Full)) { @(Get-TreeFiles $Full) } else { @($Full) }
    $bytes = 0L
    foreach ($f in $files) { $bytes += (New-Object IO.FileInfo $f).Length }
    if ($files.Count -gt $script:MaxFiles) { throw "$What holds $($files.Count) files; at most $($script:MaxFiles) are moved or deleted in one step (each is backed up for Undo). Do it in parts, or ask the user" }
    if ($bytes -gt $script:MaxBytes) { throw "$What holds $([Math]::Round($bytes / 1MB)) MB; at most $([Math]::Round($script:MaxBytes / 1MB)) MB are moved or deleted in one step (each file is backed up for Undo). Ask the user to do it" }
    foreach ($f in $files) { $null = Assert-Writable $ProjectRoot (ConvertTo-RelativePath $ProjectRoot $f) }
    @{ files = $files; bytes = $bytes }
}

function Get-MovePlan {
    <# Checks the moves before anything happens: each source exists inside the project, Copilot may
       write it and the target (Assert-Writable: not Source/, .streamhub/, protected or generated), the
       target does not exist yet (nothing is overwritten; a case-only rename is allowed), a folder
       does not go into itself, and the limits hold. A target ending in / or naming an existing folder
       takes the source's name inside it. @{ moves = @(@{ from; to; folder; files = @(@{ src; dst }) });
       error = '' }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, $Pairs)
    $root = $ProjectRoot.TrimEnd('\')
    $moves = New-Object System.Collections.Generic.List[object]
    $taken = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not @($Pairs).Count) { return @{ moves = @(); error = 'name what to move: one FROM -> TO per line' } }
    foreach ($p in @($Pairs)) {
        try {
            if (-not "$($p.to)") { throw "$($p.from): no target; write FROM -> TO" }
            $src = Assert-Writable $root $p.from
            if ($src.TrimEnd('\') -eq $root) { throw 'the project folder itself cannot be moved' }
            if (-not (Test-Path -LiteralPath $src)) { throw "$($p.from) does not exist" }
            $toText = "$($p.to)"
            $dst = Resolve-ProjectPath $root $toText
            # -ne ignores case: a folder named in another case is the same folder (a case-only rename).
            if ($toText -match '[\\/]$' -or ([IO.Directory]::Exists($dst) -and $dst -ne $src)) { $dst = Join-Path $dst (Split-Path $src -Leaf) }
            $dst = $dst.TrimEnd('\')
            $caseOnly = $dst.Equals($src, [StringComparison]::OrdinalIgnoreCase)
            if ($caseOnly -and $dst -ceq $src) { throw "$($p.from) is already there" }
            if (-not $caseOnly -and (Test-Path -LiteralPath $dst)) { throw "$(ConvertTo-RelativePath $root $dst) already exists; nothing is overwritten: delete it first (ACTION delete) or choose another name" }
            $folder = [IO.Directory]::Exists($src)
            if ($folder -and $dst.StartsWith($src + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "$($p.from) cannot be moved into itself" }
            $null = Assert-Writable $root (ConvertTo-RelativePath $root $dst)
            $set = Get-PlanFiles $root $src $p.from
            $files = @(foreach ($f in $set.files) {
                $d = $dst + $f.Substring($src.Length)
                $dRel = ConvertTo-RelativePath $root $d
                if (-not $caseOnly) { $null = Assert-Writable $root $dRel }
                if (-not $taken.Add($dRel)) { throw "two moves go to $dRel" }
                @{ src = $f; dst = $d }
            })
            $moves.Add(@{ from = (ConvertTo-RelativePath $root $src); to = (ConvertTo-RelativePath $root $dst); folder = $folder; caseOnly = $caseOnly; files = $files })
        } catch { return @{ moves = @(); error = "$($_.Exception.Message)" } }
    }
    @{ moves = $moves.ToArray(); error = '' }
}

function Add-MoveRecords([string]$ProjectRoot, $Move, $Checkpoint, [hashtable]$Rec) {
    <# Before one move: its files into the change set (sources and targets), their old and new paths
       into $Rec, and where each came from on the change set (MovedFrom, through earlier moves in it),
       so the round's file check compares a moved file with its old text: a move adds no problems.
       Undo after a case-only rename puts the text back; the name keeps its new case. #>
    foreach ($f in @($Move.files)) {
        if ($Checkpoint) { Save-CheckpointFile $Checkpoint $ProjectRoot $f.src; if (-not $Move.caseOnly) { Save-CheckpointFile $Checkpoint $ProjectRoot $f.dst } }
        $oRel = ConvertTo-RelativePath $ProjectRoot $f.src; $nRel = ConvertTo-RelativePath $ProjectRoot $f.dst
        $Rec.oldPaths.Add($oRel); $Rec.newPaths.Add($nRel)
        if ($Move.caseOnly) { continue }
        $Rec.ownRefs.Add(@{ from = $oRel; to = $nRel })
        if (-not $Checkpoint) { continue }
        if (-not $Checkpoint.PSObject.Properties['MovedFrom']) { $Checkpoint | Add-Member -NotePropertyName MovedFrom -NotePropertyValue @{} }
        $Checkpoint.MovedFrom[$nRel] = $(if ($Checkpoint.MovedFrom[$oRel]) { $Checkpoint.MovedFrom[$oRel] } else { $oRel })
    }
}

function Move-PlanItem([string]$ProjectRoot, $Move) {
    # One checked move on disk: file by file, or for a case-only rename through a temporary name
    # (which Windows needs), a folder as a whole.
    if (-not $Move.caseOnly) {
        foreach ($f in @($Move.files)) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f.dst)
            [IO.File]::Move($f.src, $f.dst)
        }
        return
    }
    $srcFull = Join-Path $ProjectRoot $Move.from.Replace('/', '\')
    $dstFull = Join-Path $ProjectRoot $Move.to.Replace('/', '\')
    $tmp = "$srcFull.streamhub-move"
    if ($Move.folder) { [IO.Directory]::Move($srcFull, $tmp); [IO.Directory]::Move($tmp, $dstFull) }
    else { [IO.File]::Move($srcFull, $tmp); [IO.File]::Move($tmp, $dstFull) }
}

function Remove-EmptyTree([string]$ProjectRoot, [string]$Full, [bool]$Folder) {
    # After a move or delete: the empty folders left under a folder (deepest first), then the folder
    # and its empty parents; for a file, its empty parents. Never the project folder (Remove-EmptyFolders).
    if (-not $Folder) { Remove-EmptyFolders $ProjectRoot (Split-Path -Parent $Full); return }
    if ([IO.Directory]::Exists($Full)) { foreach ($d in @([IO.Directory]::GetDirectories($Full, '*', 'AllDirectories') | Sort-Object Length -Descending)) { Remove-EmptyFolders $ProjectRoot $d } }
    Remove-EmptyFolders $ProjectRoot $Full
}

function Invoke-MovePlan {
    <# Carries out a checked move plan: every source file and every target goes into the change set
       first (Undo puts them back), files move one by one, folders left empty go, then the paths other
       files use for them are rewritten (Relink Update-MovedReferences, also in the change set) and the
       import index learns the new places. @{ lines; newPaths; oldPaths; relinked = @(@{ path; count;
       old; new }); broken = what still points at an old place }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Plan, $Checkpoint)
    $root = $ProjectRoot.TrimEnd('\')
    $lines = New-Object System.Collections.Generic.List[string]
    $rec = @{ oldPaths = (New-Object System.Collections.Generic.List[string]); newPaths = (New-Object System.Collections.Generic.List[string]); ownRefs = (New-Object System.Collections.Generic.List[object]) }
    foreach ($mv in @($Plan.moves)) {
        Add-MoveRecords $root $mv $Checkpoint $rec
        Move-PlanItem $root $mv
        if (-not $mv.caseOnly) { Remove-EmptyTree $root (Join-Path $root $mv.from.Replace('/', '\')) $mv.folder }
        $lines.Add("moved $($mv.from) -> $($mv.to)$(if ($mv.folder) { " ($(@($mv.files).Count) file(s))" })")
    }
    $oldPaths = $rec.oldPaths; $newPaths = $rec.newPaths; $ownRefs = $rec.ownRefs
    $relinkMoves = @(foreach ($mv in @($Plan.moves)) { @{ from = $mv.from; to = $mv.to; folder = [bool]$mv.folder } })
    # The moved files' own relative paths first (they are new files of this change set), then the
    # paths in every other file that lead to what moved.
    $own = @(try { Update-MovedFileOwnRefs $root $relinkMoves $ownRefs.ToArray() } catch { Write-CCBLogError fileactions 'paths inside moved files' $_ })
    $re = try { Update-MovedReferences $root $relinkMoves -Checkpoint $Checkpoint } catch { Write-CCBLogError fileactions 'relink after a move' $_; $null }
    $relinked = @(@($own) + @(if ($re) { $re.files }) | Where-Object { $_ })
    $broken = @(try { Update-ImportsAfterRound $root @(@($oldPaths) + @($newPaths) + @($relinked | ForEach-Object { $_.path })) } catch { Write-CCBLogError fileactions 'import index after a move' $_ })
    Write-CCBLog info fileactions 'Moved' @{ moves = @($Plan.moves).Count; files = $newPaths.Count; relinked = $relinked.Count; broken = $broken.Count }
    @{ lines = $lines.ToArray(); newPaths = $newPaths.ToArray(); oldPaths = $oldPaths.ToArray(); relinked = $relinked; broken = $broken }
}

function Get-DeletePlan {
    <# Checks a delete before anything happens: each path exists inside the project, is not the
       project folder, and Copilot may write it and every file in it (Assert-Writable); no links;
       within the limits. @{ items = @(@{ rel; folder; files }); files; bytes; error = '' }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths)
    $root = $ProjectRoot.TrimEnd('\')
    if (-not @($Paths).Count) { return @{ items = @(); files = 0; bytes = 0; error = 'name what to delete: one path per line' } }
    $items = New-Object System.Collections.Generic.List[object]
    $count = 0; $bytes = 0L
    try {
        foreach ($p in @($Paths)) {
            $full = (Assert-Writable $root $p).TrimEnd('\')
            if ($full -eq $root) { throw 'the project folder itself cannot be deleted' }
            if (-not (Test-Path -LiteralPath $full)) { throw "$p does not exist" }
            $set = Get-PlanFiles $root $full $p
            $count += @($set.files).Count; $bytes += $set.bytes
            if ($count -gt $script:MaxFiles) { throw "these paths hold $count files; at most $($script:MaxFiles) are deleted in one step" }
            $items.Add(@{ rel = (ConvertTo-RelativePath $root $full); folder = [IO.Directory]::Exists($full); files = @($set.files) })
        }
    } catch { return @{ items = @(); files = 0; bytes = 0; error = "$($_.Exception.Message)" } }
    @{ items = $items.ToArray(); files = $count; bytes = $bytes; error = '' }
}

function Invoke-DeletePlan {
    <# Carries out a checked delete: each file into the change set first (Undo brings it back), then
       removed; folders left empty go too. Never Remove-Item -Recurse, which follows junctions in 5.1.
       @{ lines; oldPaths; broken = what still uses a deleted file }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Plan, $Checkpoint)
    $root = $ProjectRoot.TrimEnd('\')
    $lines = New-Object System.Collections.Generic.List[string]
    $oldPaths = New-Object System.Collections.Generic.List[string]
    foreach ($it in @($Plan.items)) {
        foreach ($f in @($it.files)) {
            if ($Checkpoint) { Save-CheckpointFile $Checkpoint $root $f }
            $attr = [IO.File]::GetAttributes($f)
            if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($f, ($attr -band (-bnot [IO.FileAttributes]::ReadOnly))) }
            [IO.File]::Delete($f)
            $oldPaths.Add((ConvertTo-RelativePath $root $f))
        }
        Remove-EmptyTree $root (Join-Path $root $it.rel.Replace('/', '\')) $it.folder
        $lines.Add("deleted $($it.rel)$(if ($it.folder) { " ($(@($it.files).Count) file(s))" })")
    }
    $broken = @(try { Update-ImportsAfterRound $root @($oldPaths) } catch { Write-CCBLogError fileactions 'import index after a delete' $_ })
    Write-CCBLog info fileactions 'Deleted' @{ items = @($Plan.items).Count; files = $oldPaths.Count; broken = $broken.Count }
    @{ lines = $lines.ToArray(); oldPaths = $oldPaths.ToArray(); broken = $broken }
}

$script:CommentStart = @{
    '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte|cs|java|kt|go|rs|php|swift|dart|c|cpp|h|hpp)$' = '^(//|/\*|\*)'
    '(?i)\.(ps1|psm1|pyw?)$' = '^(#|<#)'
    '(?i)\.(css|scss|less)$' = '^(/\*|\*|//)'
    '(?i)\.(html?|xhtml)$' = '^<!--'
}

function Get-UsesInFile([string]$ProjectRoot, [string]$Rel, [string]$Pattern, [string]$Definition) {
    # The lines of one file that use a name ("PATH:LINE  text", the defining ones marked), comment
    # lines left out by the file type's comment start ($script:CommentStart).
    $comment = $null
    foreach ($k in $script:CommentStart.Keys) { if ($Rel -match $k) { $comment = $script:CommentStart[$k]; break } }
    $text = try { (Read-TextFile (Resolve-ProjectPath $ProjectRoot $Rel)).Text } catch { return }
    if ($text -notmatch $Pattern) { return }
    $lines = $text.Replace("`r`n", "`n").Split("`n")
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -notmatch $Pattern) { continue }
        $t = $lines[$i].Trim()
        if ($comment -and $t -match $comment) { continue }
        if ($t.Length -gt 140) { $t = $t.Substring(0, 137) + '...' }
        "${Rel}:$($i + 1)  $t$(if ($lines[$i] -match $Definition) { '   [definition]' })"
    }
}

function Find-SymbolUses {
    <# Every place the project uses a name: whole words in code, page and style files (a CSS class
       or HTML id counts with its - as part of the name), comment lines left out, the defining lines
       marked. For a project file instead of a name: the files that load it (import index) and the
       files that name it. Text for Copilot, at most $Max places plus the total. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Name, [int]$Max = 60)
    $n = $Name.Trim().Trim('`', '"', "'")
    if ($n -match '[\\/]|\.\w{1,6}$') {
        $full = try { Resolve-ProjectPath $ProjectRoot $n } catch { $null }
        if ($full -and (Test-Path -LiteralPath $full -PathType Leaf)) { return Find-FileUses $ProjectRoot (ConvertTo-RelativePath $ProjectRoot $full) $Max }
    }
    $n = $n.TrimStart('.', '#')
    if ($n -notmatch '^[\w$-]{2,80}$') { return "refs: give one name (letters, digits, _ - $), such as a function, class, CSS class or id, or a project file's path" }
    $e = [regex]::Escape($n)
    $rules = Get-DefinitionRules $e
    $word = "(?<![\w$])$e(?![\w$])"
    $dashWord = "(?<![\w$-])$e(?![\w$-])"
    $hits = New-Object System.Collections.Generic.List[string]
    $total = 0
    $fileCount = 0
    foreach ($f in @(Get-ProjectFiles $ProjectRoot)) {
        $rule = $rules | Where-Object { $f.path -match $_.ext } | Select-Object -First 1
        if (-not $rule -or [int64]$f.size -gt 1MB -or $f.path -match '(?i)^(source|node_modules|dist|build|\.streamhub)/') { continue }
        $pat = if ($f.path -match '(?i)\.(css|scss|less|html?|xhtml)$') { $dashWord } else { $word }
        $found = @(Get-UsesInFile $ProjectRoot $f.path $pat $rule.re)
        if (-not $found.Count) { continue }
        $total += $found.Count; $fileCount++
        foreach ($h in $found) { if ($hits.Count -lt $Max) { $hits.Add($h) } }
    }
    if (-not $total) { return "refs ${n}: no uses found in the project's code, pages or styles (comment lines are left out; grep finds it in other files)" }
    $more = if ($total -gt $hits.Count) { "`n($($total - $hits.Count) more not shown; grep with a file pattern narrows it)" } else { '' }
    "refs ${n}: $total place(s) in $fileCount file(s), comment lines left out. Change every one of them when you rename it or change what it takes or returns:`n" + ($hits -join "`n") + $more
}

function Find-FileUses([string]$ProjectRoot, [string]$Rel, [int]$Max = 60) {
    # What loads a file (import index) and which other files name it.
    $users = @(try { Get-ImportUsers $ProjectRoot $Rel $null $Max } catch { @() })
    $leaf = Get-PathLeaf $Rel
    $seen = @{}; foreach ($u in $users) { $seen["$($u.path)"] = $true }
    $named = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ProjectFiles $ProjectRoot)) {
        if ($named.Count + $users.Count -ge $Max) { break }
        if ($f.path -eq $Rel -or $seen.ContainsKey($f.path) -or [int64]$f.size -gt 1MB -or $f.path -match '(?i)^(source|node_modules|dist|build|\.streamhub)/') { continue }
        if ($f.path -notmatch '(?i)\.(html?|xhtml|[cm]?[jt]sx?|vue|svelte|css|scss|less|json|md|ps[dm]?1|py|cmd|bat|ya?ml|xml|xaml)$') { continue }
        $text = try { (Read-TextFile (Resolve-ProjectPath $ProjectRoot $f.path)).Text } catch { continue }
        $i = $text.IndexOf($leaf, [StringComparison]::OrdinalIgnoreCase)
        if ($i -lt 0) { continue }
        $line = ([regex]::Matches($text.Substring(0, $i), "`n")).Count + 1
        $t = $text.Replace("`r`n", "`n").Split("`n")[$line - 1].Trim()
        if ($t.Length -gt 140) { $t = $t.Substring(0, 137) + '...' }
        $named.Add("$($f.path):$line  $t")
    }
    if (-not $users.Count -and -not $named.Count) { return "refs ${Rel}: no other file loads or names it" }
    $out = "refs ${Rel}:"
    if ($users.Count) { $out += "`nLoaded or used by (file:line):`n" + (@($users | ForEach-Object { "$($_.path):$($_.line)  ($($_.what))" }) -join "`n") }
    if ($named.Count) { $out += "`nNamed in:`n" + ($named -join "`n") }
    $out
}

function Get-FileChange([string]$ProjectRoot, $Checkpoint, [string]$Rel) {
    <# One file of the change set: @{ line ("- PATH: created|edited|deleted, +A -R"); old; new; diff
       (whether its changed lines can be shown) }, or $null for a file made and removed again. #>
    $full = Join-Path $ProjectRoot $Rel.Replace('/', '\')
    $backup = Join-Path $Checkpoint.Dir $Rel.Replace('/', '\')
    $created = $Checkpoint.Files[$Rel] -eq 'new'
    $exists = Test-Path -LiteralPath $full -PathType Leaf
    if ($created -and -not $exists) { return $null }
    $what = if ($created) { 'created' } elseif (-not $exists) { 'deleted' } else { 'edited' }
    $binary = ($exists -and -not (Test-TextReadable $full)) -or (-not $created -and (Test-Path -LiteralPath $backup) -and -not (Test-TextReadable $backup))
    if ($binary) { return @{ line = "- ${Rel}: $what (not text)"; diff = $false } }
    $old = if ($created) { '' } else { try { (Read-TextFile $backup).Text } catch { '' } }
    $new = if ($exists) { try { (Read-TextFile $full).Text } catch { '' } } else { '' }
    if ($old -ceq $new) { return @{ line = "- ${Rel}: back as it was"; diff = $false } }
    $m = Measure-LineChanges $old $new
    @{ line = "- ${Rel}: $what, +$($m.added) -$($m.removed)"; old = $old; new = $new; diff = $exists }
}

function Format-TaskChanges {
    <# What this message changed so far, from its change set: per file created, edited or deleted with
       line counts, then the changed lines (Format-LineChange) within $Budget characters, the files
       Copilot changed most recently last. With $Path only that file, in more detail. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, $Checkpoint, [string]$Path = '', [int]$Budget = 12000)
    $none = 'No file has changed in this message yet.'
    if (-not $Checkpoint -or -not @($Checkpoint.Files.Keys).Count) { return $none }
    $want = "$Path".Trim().Trim('`', '"', "'").Replace('\', '/').TrimStart('/')
    $rels = @($Checkpoint.Files.Keys | Sort-Object)
    if ($want) {
        $rels = @($rels | Where-Object { $_ -ieq $want -or $_.StartsWith("$($want.TrimEnd('/'))/", [StringComparison]::OrdinalIgnoreCase) })
        if (-not $rels.Count) { return "$want has not changed in this message. Changed so far: $((@($Checkpoint.Files.Keys | Sort-Object)) -join ', ')." }
    }
    $root = $ProjectRoot.TrimEnd('\')
    $head = New-Object System.Collections.Generic.List[string]
    $body = New-Object System.Collections.Generic.List[string]
    $used = 0
    foreach ($rel in $rels) {
        $c = Get-FileChange $root $Checkpoint $rel
        if (-not $c) { continue }
        $head.Add($c.line)
        if (-not $c.diff) { continue }
        $diff = Format-LineChange $c.old $c.new $(if ($want) { 300 } else { 60 })
        $block = "### $rel`n$diff"
        if ($used + $block.Length -gt $Budget) { $body.Add("### $rel`n(not shown: the budget is used; ACTION changes $rel shows it)"); continue }
        $body.Add($block); $used += $block.Length
    }
    "Changed in this message so far ($($head.Count) file(s); lines prefixed - are gone, + are new):`n" + ($head -join "`n") + $(if ($body.Count) { "`n`n" + ($body -join "`n`n") })
}

Export-ModuleMember -Function Get-MovePairs, Get-DeletePaths, Get-MovePlan, Invoke-MovePlan, Get-DeletePlan, Invoke-DeletePlan, Find-SymbolUses, Find-FileUses, Format-TaskChanges
