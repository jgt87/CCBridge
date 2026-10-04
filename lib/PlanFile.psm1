# .streamhub/PLAN.md in the project collects every decision of the clarify-first flow: per request a
# section ("## <date> - <request>", newest at the bottom) with the request, Copilot's questions,
# the user's answers, each plan version, the changes asked for, the approval and the result.
# StreamHub writes it as the steps happen; Copilot only reads it. A request's section is found by
# its marker line <!-- plan:ID -->.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')

$script:PlanFileName = '.streamhub\PLAN.md'   # StreamHub's own record (Layout: Plan)
$script:PlanHeader = "# PLAN`n`nEvery request made with Clarify first: Copilot's questions, the answers, each version of the plan, the changes asked for, the approval and the result. Newest at the bottom.`n"

function Get-PlanSlug([string]$Text) {
    $s = ("$Text".ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).Trim('-') }
    if (-not $s) { $s = 'task' }
    $s
}

function Test-PlanId([string]$Id) { "$Id" -match '^[a-z0-9][a-z0-9-]{0,80}$' }

function Get-PlanText([string]$ProjectRoot) {
    $full = Join-Path $ProjectRoot $script:PlanFileName
    if (Test-Path -LiteralPath $full) { return [IO.File]::ReadAllText($full).Replace("`r`n", "`n") }
    ''
}

function Set-PlanText([string]$ProjectRoot, [string]$Text) {
    $full = Join-Path $ProjectRoot $script:PlanFileName
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
    [IO.File]::WriteAllText($full, $Text.TrimEnd("`n") + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Get-PlanBlock([string]$Text, [string]$PlanId) {
    <# Where a request's section is: @{ start (its ## line); end (next ## line or the end) }. #>
    $m = [regex]::Match($Text, "(?m)^<!-- plan:$([regex]::Escape($PlanId)) -->$")
    if (-not $m.Success) { return $null }
    $head = $Text.LastIndexOf("`n## ", $m.Index)
    $start = if ($head -ge 0) { $head + 1 } else { 0 }
    $next = [regex]::Match($Text.Substring($m.Index), '(?m)^## ')
    @{ start = $start; end = $(if ($next.Success) { $m.Index + $next.Index } else { $Text.Length }) }
}

function New-PlanEntry {
    <# Adds a request's section to PLAN.md (made when missing). Returns its id. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Request, [datetime]$Now = (Get-Date))
    $text = Get-PlanText $ProjectRoot
    if (-not $text.Trim()) { $text = $script:PlanHeader }
    $id = "$($Now.ToString('yyyyMMdd-HHmm'))-$(Get-PlanSlug $Request)"; $base = $id; $n = 2
    while ($text -match "(?m)^<!-- plan:$([regex]::Escape($id)) -->$") { $id = "$base-$n"; $n++ }
    $title = ($Request -replace '\s+', ' ').Trim(); if ($title.Length -gt 90) { $title = $title.Substring(0, 87) + '...' }
    $text = $text.TrimEnd("`n") + "`n`n## $($Now.ToString('yyyy-MM-dd HH:mm')) - $title`n<!-- plan:$id -->`n`nStatus: questions`n`n### Request`n`n$($Request.Trim())`n"
    Set-PlanText $ProjectRoot $text
    $id
}

function Add-PlanSection {
    <# Adds "### HEADING" with BODY at the end of a request's section, and sets its status. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$PlanId, [Parameter(Mandatory)][string]$Heading, [AllowEmptyString()][string]$Body, [string]$Status)
    if (-not (Test-PlanId $PlanId)) { throw "Not a plan id: $PlanId" }
    $text = Get-PlanText $ProjectRoot
    $b = Get-PlanBlock $text $PlanId
    if (-not $b) { throw "PLAN.md has no section for $PlanId" }
    $block = $text.Substring($b.start, $b.end - $b.start).TrimEnd("`n")
    if ($Status) { $block = [regex]::Replace($block, '(?m)^Status: .*$', "Status: $Status", 1) }
    $block += "`n`n### $Heading`n" + $(if ("$Body".Trim()) { "`n$($Body.Trim())`n" } else { '' })
    $after = $text.Substring($b.end)
    Set-PlanText $ProjectRoot ($text.Substring(0, $b.start) + $block + $(if ($after) { "`n`n" + $after.TrimStart("`n") } else { '' }))
}

function Get-PlanVersionCount {
    param([string]$ProjectRoot, [string]$PlanId)
    $text = Get-PlanText $ProjectRoot
    $b = if (Test-PlanId $PlanId) { Get-PlanBlock $text $PlanId } else { $null }
    if (-not $b) { return 0 }
    ([regex]::Matches($text.Substring($b.start, $b.end - $b.start), '(?m)^### Plan \(version \d+\)')).Count
}

function Format-PlanQuestions($Questions, [string]$Summary) {
    $lines = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($q in @($Questions)) {
        $i++
        $lines.Add("$i. $($q.question)")
        if (@($q.options).Count) { $lines.Add("   Suggested answers: " + (@($q.options) -join ' / ')) }
    }
    if ($Summary) { $lines.Add(''); $lines.Add("Copilot understood: $Summary") }
    $lines -join "`n"
}

function Format-PlanAnswers($Answers) {
    <# "1. QUESTION`n   Answer: ANSWER" for each answer (an empty answer: no preference). #>
    $i = 0
    (@($Answers) | ForEach-Object { $i++; "$i. $($_.question)`n   Answer: $(if ("$($_.answer)".Trim()) { "$($_.answer)".Trim() } else { '(no preference)' })" }) -join "`n"
}

Export-ModuleMember -Function Get-PlanSlug, Test-PlanId, New-PlanEntry, Add-PlanSection, Get-PlanVersionCount, Format-PlanQuestions, Format-PlanAnswers
