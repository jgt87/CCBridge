# What carries a task across a chat rollover (a Copilot chat that is nearly full of messages):
# Copilot writes a handoff under fixed headings (checked by a fixed rule, asked again once when
# most are missing), and the helper program adds what it knows itself instead of trusting
# Copilot's memory: the request, the mode, the files this task changed, the open to-do items,
# the Done when checks, an active fix and the outlines of the files changed.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Executor.psm1')

$script:HandoffHeadings = @('Objective', 'Requirements', 'Decisions', 'Done', 'Active', 'Blocked', 'Next steps', 'Relevant files')

function Get-HandoffAsk {
    <# The message that asks Copilot for the handoff. #>
    'This chat is nearly full, so a new chat continues this task. Write a handoff for it under exactly these headings, each on a line of its own followed by short lines: ' +
    (($script:HandoffHeadings | ForEach-Object { "${_}:" }) -join ' ') +
    " Requirements are what the user asked for that still applies; Done, Active and Blocked are the state of the work; Relevant files are the paths with what each is for. Keep exact paths, names and error texts; write none under a heading with nothing. At most 2500 characters. Do not use action blocks."
}

function Get-HandoffMissing([AllowEmptyString()][string]$Text) {
    <# The headings the handoff lacks (a heading line: optional # or **, the name, a colon). #>
    @($script:HandoffHeadings | Where-Object { $Text -notmatch ('(?im)^[ \t>#*_-]*' + [regex]::Escape($_) + '[*_]*\s*:') })
}

function Get-HandoffRetry([string[]]$Missing) {
    "Your handoff lacks these headings: $($Missing -join ', '). Write the whole handoff again under all the headings ($(($script:HandoffHeadings | ForEach-Object { "${_}:" }) -join ' ')). At most 2500 characters. Do not use action blocks."
}

function Get-HandoffOutlines {
    <# Outlines of the files the task changed (code and markup), at most $MaxFiles files and $MaxChars
       characters, one line per file: "path: Name 12, Other 40". #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths, [int]$MaxFiles = 6, [int]$MaxChars = 1500)
    $sb = New-Object Text.StringBuilder
    $n = 0
    foreach ($p in @($Paths | Where-Object { $_ } | Select-Object -Unique)) {
        if ($n -ge $MaxFiles -or $sb.Length -ge $MaxChars) { break }
        $rel = "$p".Replace('\', '/')
        if ($rel -match '(?i)^(Source|\.streamhub|node_modules|dist|data)/' -or $rel -notmatch '(?i)\.(ps1|psm1|py|[cm]?[jt]sx?|vue|svelte|html?|css|cs|java|go|rb|php|md)$') { continue }
        $full = Join-Path $ProjectRoot $rel.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Get-Item -LiteralPath $full).Length -gt 300KB) { continue }
        $entries = @(try { Get-OutlineEntries (Read-TextFile $full).Text $full } catch { @() })
        $parts = @($entries | Select-Object -First 25 | ForEach-Object { "$($_.name) $($_.line)" } | Select-Object -Unique)
        if (-not $parts.Count) { continue }
        $line = "${rel}: $($parts -join ', ')"
        if ($line.Length -gt 300) { $line = $line.Substring(0, 296) + ' ...' }
        [void]$sb.AppendLine($line); $n++
    }
    $sb.ToString().TrimEnd()
}

function Format-HandoffFacts {
    <# The facts block that goes with Copilot's handoff into the new chat. $Todos: items with done
       and text; $Acceptance: items with check, met, note; $IssueFix: the active fix (path, attempt). #>
    param([string]$Request, [string]$Mode, [string[]]$Changed, $Todos, [string[]]$DoneWhen, $Acceptance, $IssueFix, [string]$Outlines)
    $o = New-Object System.Collections.Generic.List[string]
    $o.Add('WHAT THE HELPER PROGRAM KEPT (facts it recorded itself; they win over the summary above where they differ):')
    if ("$Request".Trim()) {
        $q = $Request
        $o.Add("- The request of this task: $q")
    }
    if ($Mode -eq 'plan') { $o.Add('- Mode: plan only. Do not change files or run commands; plan.') }
    $ch = @($Changed | Where-Object { $_ } | ForEach-Object { "$_".Replace('\', '/') } | Select-Object -Unique)
    if ($ch.Count) { $o.Add("- Files this task changed so far ($($ch.Count)): $(($ch | Select-Object -First 30) -join ', ')$(if ($ch.Count -gt 30) { ', ...' })") }
    $open = @($Todos | Where-Object { $_ -and -not $_.done } | ForEach-Object { "$($_.text)" })
    $doneT = @($Todos | Where-Object { $_ -and $_.done }).Count
    if ($open.Count) { $o.Add("- Open to-do items ($doneT done): $($open -join '; ')") }
    $checks = @($DoneWhen | Where-Object { "$_".Trim() })
    if ($checks.Count) {
        $o.Add('- Done when (the checks you set for this task):')
        foreach ($c in $checks) {
            $a = @($Acceptance | Where-Object { $_ -and "$($_.check)" -eq "$c" } | Select-Object -First 1)
            $state = if (-not $a.Count) { 'not answered yet' } elseif ($a[0].met) { 'MET' } else { "NOT MET$(if ($a[0].note) { ": $($a[0].note)" })" }
            $o.Add("  - $c ($state)")
        }
    }
    if ($IssueFix -and $IssueFix.path) { $o.Add("- Fixing the problems in $($IssueFix.path) (attempt $([int]$IssueFix.attempt)).") }
    if ("$Outlines".Trim()) { $o.Add("- Outlines of the changed files (name and line; read a part before you edit it):`n$Outlines") }
    if ($o.Count -eq 1) { return '' }
    $o -join "`n"
}

Export-ModuleMember -Function Get-HandoffAsk, Get-HandoffMissing, Get-HandoffRetry, Get-HandoffOutlines, Format-HandoffFacts
