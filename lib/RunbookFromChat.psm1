# Save a request as a runbook: on the person's request (command menu), the last request of this
# project's chat goes to Copilot again, wrapped in a fixed text that asks for a runbook doing it
# again (Runbooks/NAME.runbook.md under the usual runbook rules), not for the answer itself.
# Fixed rules only: which message is the last request, whether it can become a runbook (not plain
# chat, not about runbooks itself), the proposed name, and the text sent.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Prompts', 'Runbook') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

# Texts the app's cards send for the person (plan build, continue, change the plan...): not a request
# of their own. The same list as the test runs' "Save this chat as a test run" (Server).
$script:CardText = '^(Build this now|Continue and make the change now|Change the plan|You stopped before|Continue with the items still open)'
# Polite openings left out of the proposed name.
$script:PoliteStart = '(?i)^\s*(please|pls|can you|could you|would you|will you|i want you to|i would like you to|kun je|kunt u|wil je|wilt u|graag)\s+'

function Get-LastChatRequest {
    <# The person's last request in the chat events (oldest first, as Agent Read-ChatHistory or
       $State.Events give them): the last 'user' event after the last 'history-cleared' or 'project'
       event, leaving out the cards' own texts. Returns @{ text; kind (the 'kind' event's taskKind
       that followed it, '' when none); agent; at } or $null. #>
    param($Events)
    $list = @($Events | Where-Object { $_ })
    $start = 0
    for ($i = 0; $i -lt $list.Count; $i++) { if ("$($list[$i].type)" -in 'history-cleared', 'project') { $start = $i + 1 } }
    for ($i = $list.Count - 1; $i -ge $start; $i--) {
        $e = $list[$i]
        $text = "$($e.text)".Trim()
        if ("$($e.type)" -ne 'user' -or -not $text -or $text -match $script:CardText) { continue }
        $kind = ''
        for ($j = $i + 1; $j -lt $list.Count; $j++) {
            if ("$($list[$j].type)" -eq 'user') { break }
            if ("$($list[$j].type)" -eq 'kind') { $kind = "$($list[$j].taskKind)"; break }
        }
        return [pscustomobject]@{ text = $text; kind = $kind; agent = "$($e.agent)"; at = "$($e.at)" }
    }
    $null
}

function Test-RunbookFromChatAllowed {
    <# Whether the last request can be saved as a runbook: @{ ok; reason (none, runbook, chat); message }.
       - none: no earlier request in this project's chat.
       - runbook: the request was about runbooks itself: it ran one (its kind event says runbook), or
         Prompts Get-PromptModules sends the runbook rules for its words (runbook, draaiboek), or it
         names a .runbook.md file.
       - chat: it went to Copilot as plain chat: the kind event says chat (without one, Prompts
         Get-TaskKind on the text with the project's traits and paths), unless it asks for online
         information or opens Microsoft 365 links (Get-PromptModules: rules:websources or
         rules:m365links), which a runbook can repeat. #>
    param($Request, [string[]]$Traits = @(), [string[]]$Paths = @())
    if (-not $Request -or -not "$($Request.text)".Trim()) {
        return [pscustomobject]@{ ok = $false; reason = 'none'; message = 'There is no earlier request in this project''s chat to save as a runbook. Ask for it once in the chat first, then save it as a runbook.' }
    }
    $text = "$($Request.text)"
    $mods = @(Get-PromptModules $text @{ Paths = @(); Traits = @() })
    if ("$($Request.kind)" -eq 'runbook' -or $mods -contains 'rules:runbook' -or $text -match '(?i)\.runbook\.md\b') {
        return [pscustomobject]@{ ok = $false; reason = 'runbook'; message = 'The last request was about a runbook itself, so there is nothing new to save as a runbook. Ask for the data or result you want in the chat first, then save that request as a runbook.' }
    }
    $kind = if ("$($Request.kind)") { "$($Request.kind)" } else { Get-TaskKind $text -Traits $Traits -Paths $Paths }
    $online = $mods -contains 'rules:websources' -or $mods -contains 'rules:m365links'
    if ($kind -eq 'chat' -and -not $online) {
        return [pscustomobject]@{ ok = $false; reason = 'chat'; message = 'The last request was plain chat (it went to Copilot as typed, without work on data or files), so it cannot be repeated as a runbook. Ask for the data or result you want, then save that request as a runbook.' }
    }
    [pscustomobject]@{ ok = $true; reason = ''; message = '' }
}

function Get-RunbookFromChatName {
    <# The proposed runbook name for a request: its first six words (a polite opening left out) as
       Runbook Get-RunbookSlug makes a name, at most 40 characters at a word break; "saved-request"
       when nothing is left; -2, -3 ... when the project has a runbook of that name. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Request, [string[]]$Existing = @())
    $words = @(("$Request" -replace $script:PoliteStart, '' -replace '[^\p{L}\p{Nd}]+', ' ').Trim() -split '\s+' | Where-Object { $_ } | Select-Object -First 6)
    $slug = Get-RunbookSlug ($words -join ' ')
    if ($slug.Length -gt 40) { $cut = $slug.Substring(0, 40); $at = $cut.LastIndexOf('-'); $slug = if ($at -gt 10) { $cut.Substring(0, $at) } else { $cut.Trim('-') } }
    if (-not $slug) { $slug = 'saved-request' }
    $name = $slug; $k = 2
    while (@($Existing | Where-Object { "$_" -ieq $name }).Count) { $name = "$slug-$k"; $k++ }
    $name
}

function Get-RunbookFromChatRequest {
    <# The request sent to Copilot to save an earlier request as a runbook (a fixed text): the earlier
       request quoted, the proposed file Runbooks/NAME.runbook.md, what a runbook is for here, and that
       it only writes the file (no run, no answer now). It starts with "Write a runbook", so Runbook
       Get-RunbookRunRequest never takes it as a request to run one, Prompts Get-TaskIntent reads it
       as a change, and Get-PromptModules sends the runbook rules with the template. #>
    param([Parameter(Mandatory)][string]$Request, [string]$Name = '', [string[]]$Existing = @())
    if (-not $Name) { $Name = Get-RunbookFromChatName $Request $Existing }
    # Between --- lines, not as a > quote: Copilot's page writes < and > in a message as entities.
    @(
        'Write a runbook that does this earlier request of mine again each time it runs (the request is between the --- lines):'
        '---'
        "$Request".Trim().Replace("`r`n", "`n")
        '---'
        ''
        "Save it as Runbooks/$Name.runbook.md (rename it only when another lowercase name says better what it exports). A runbook here is a saved, repeatable request: I run it later from the app, in a chain or on a schedule, each time in a fresh chat; it is read-only and its answer is saved as JSON in Runbooks/Exports/. Start from the runbook template: fill in the header (title, output: Runbooks/Exports/$Name.json, itemsKey, required, requiredItemFields) and the sections so every run gives the same kind of result, with placeholders such as {{today}} or {{weekStart}} instead of fixed dates, and the header lines sources and sites when it needs websites."
        ''
        'Only write the runbook file with a write block. Do not run the runbook now and do not answer the earlier request itself.'
    ) -join "`n"
}

Export-ModuleMember -Function Get-LastChatRequest, Test-RunbookFromChatAllowed, Get-RunbookFromChatName, Get-RunbookFromChatRequest
