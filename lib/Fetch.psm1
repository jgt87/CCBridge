# Saved fetch prompts: prompts that are run on demand to get current data from Copilot (for example
# today's meetings), with the answer written to a markdown file in the project so it can be attached
# to later messages with @.
#   fetch/<name>.prompt.md   the prompt (plain text, editable)
#   fetch/<name>.md          the latest answer, with a short header (when, from which prompt)

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace', 'Executor') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:FetchDir = 'fetch'

function ConvertTo-FetchName {
    <# A file-safe name: lowercase letters, digits and dashes. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $slug = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).Trim('-') }
    if (-not $slug) { throw 'Give the fetch prompt a name (letters or digits).' }
    $slug
}

function Get-FetchedAt([string]$File) {
    <# When an answer file was fetched: from its header line, else the file time. #>
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    $head = @(Get-Content -LiteralPath $File -TotalCount 5 -Encoding UTF8)
    foreach ($line in $head) {
        if ($line -match '^_Fetched (\d{4}-\d{2}-\d{2} \d{2}:\d{2})') {
            try { return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } catch { }
        }
    }
    (Get-Item -LiteralPath $File).LastWriteTime
}

function Get-FetchPrompts {
    <# The project's saved fetch prompts with the state of their answer files. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $dir = Join-Path $ProjectRoot $script:FetchDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.prompt.md' -File | Sort-Object Name) {
        $name = $f.Name.Substring(0, $f.Name.Length - '.prompt.md'.Length)
        $out = Join-Path $dir "$name.md"
        $at = Get-FetchedAt $out
        [pscustomobject]@{
            name = $name
            prompt = ([IO.File]::ReadAllText($f.FullName)).Trim()
            promptPath = "$($script:FetchDir)/$name.prompt.md"
            output = "$($script:FetchDir)/$name.md"
            fetchedAt = $(if ($at) { $at.ToString('s') } else { $null })
            outputSize = $(if (Test-Path -LiteralPath $out) { (Get-Item -LiteralPath $out).Length } else { 0 })
        }
    }
}

function Save-FetchPrompt {
    <# Creates or replaces fetch/<name>.prompt.md. Returns the saved prompt. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyString()][string]$Prompt)
    if (-not $Prompt.Trim()) { throw 'The fetch prompt is empty.' }
    $slug = ConvertTo-FetchName $Name
    $full = Assert-Writable $ProjectRoot "$($script:FetchDir)/$slug.prompt.md"
    $dir = Split-Path $full
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    [IO.File]::WriteAllText($full, $Prompt.Trim().Replace("`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    Get-FetchPrompts $ProjectRoot | Where-Object name -eq $slug
}

function Format-FetchResult {
    <# The answer file: a title, when it was fetched and from which prompt, the answer, its sources.
       It is sent to Copilot when attached, so it does not name the helper program. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Reply, [datetime]$When = (Get-Date), $References = @())
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("# $Name").AppendLine()
    [void]$sb.AppendLine("_Fetched $($When.ToString('yyyy-MM-dd HH:mm')) (local time) with the prompt in ``$($script:FetchDir)/$Name.prompt.md``. Run it again for newer data._").AppendLine()
    [void]$sb.AppendLine($Reply.Trim())
    $refs = @($References | Where-Object { $_ -and ($_.title -or $_.url) })
    if ($refs.Count) {
        [void]$sb.AppendLine().AppendLine('## Sources').AppendLine()
        foreach ($r in $refs) {
            $t = if ($r.title) { $r.title } else { $r.url }
            [void]$sb.AppendLine($(if ($r.url) { "- [$t]($($r.url))" } else { "- $t" }))
        }
    }
    $sb.ToString().Replace("`r`n", "`n")
}

function Save-FetchResult {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Content)
    $full = Assert-Writable $ProjectRoot "$($script:FetchDir)/$Name.md"
    [IO.File]::WriteAllText($full, $Content, (New-Object Text.UTF8Encoding($false)))
    "$($script:FetchDir)/$Name.md"
}

Export-ModuleMember -Function ConvertTo-FetchName, Get-FetchPrompts, Save-FetchPrompt, Format-FetchResult, Save-FetchResult
