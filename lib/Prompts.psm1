# Builds what is sent to Copilot. The prompt is as small as the request allows:
#   chat       plain text only (greetings, general questions)
#   assistant  short assistant role + read-only Microsoft 365 rule + how to save a file + location
#   project    short role + compact action description + rules + project context
#   coding     same as project with a developer role
#   mixed      coding plus the Microsoft 365 rule (code that works with mail/calendar/chats)
# Parts already sent in the current chat are not repeated; a later request only adds what it needs.

$ErrorActionPreference = 'Stop'

# Signals for the kind of task (English and common Dutch words).
$script:CodingPattern = '(?i)\b(code|coding|codebase|script|scripts|program|programming|programma|function|functie|class|method|bug|bugs|debug|refactor|compile|build|builds|unit tests?|tests?|api|endpoint|database|sql|html|css|javascript|typescript|python|powershell|c#|java|react|vue|node|npm|dotnet|\.net|app|apps|application|applicatie|repo|repository|git|commit|module|library|package|deploy|cli|component|frontend|backend|server|json|yaml|regex|dashboard|website|webpage|implement|implementeer)\b|\.(ps1|psm1|py|js|ts|tsx|jsx|cs|java|go|rs|html|css|json|ya?ml|sql|sh|cmd|bat)\b'
$script:M365Pattern = '(?i)\b(e-?mails?|mails?|mailbox|inbox|outlook|meetings?|calendar|agenda|appointments?|invit(e|es|ation|ations)|teams|chats?|channels?|onedrive|sharepoint|follow-?ups?|minutes|vergadering(en)?|afspra(ak|ken)|uitnodiging(en)?|berichten|notulen)\b'
$script:ProjectPattern = '(?i)\b(files?|folders?|project|documents?|notes|csv|excel|xlsx|spreadsheet|data|report|readme|summary|summaries|bestand(en)?|map|rapport|samenvatting|source)\b|(^|\s)@[\w.]'

function Get-TaskKind {
    <# 'chat', 'assistant', 'project', 'coding' or 'mixed'. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $coding = $Text -match $script:CodingPattern
    $m365 = $Text -match $script:M365Pattern
    $project = $Text -match $script:ProjectPattern
    if ($coding -and $m365) { return 'mixed' }
    if ($coding) { return 'coding' }
    if ($m365) { return 'assistant' }   # also when the result goes into a file: the assistant can save one
    if ($project) { return 'project' }
    'chat'
}

function Get-PromptParts {
    <# Ordered part ids a kind of task needs. #>
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        'assistant' { @('role:assistant', 'm365', 'save', 'location') }
        'project'   { @('role:project', 'actions', 'rules', 'project') }
        'coding'    { @('role:coding', 'actions', 'rules', 'project') }
        'mixed'     { @('role:coding', 'actions', 'rules', 'm365', 'project') }
        default     { @() }
    }
}

function Read-PromptPart([string]$AppRoot, [string]$Name) {
    ([IO.File]::ReadAllText((Join-Path $AppRoot "prompts\$Name"))).Trim()
}

function Get-PromptPart {
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Id, $Context)
    switch -Regex ($Id) {
        '^role:(.+)$' { return Read-PromptPart $AppRoot "roles\$($Matches[1]).md" }
        '^actions$'   { return Read-PromptPart $AppRoot 'actions.md' }
        '^rules$'     { return Read-PromptPart $AppRoot 'rules.md' }
        '^m365$'      { return Read-PromptPart $AppRoot 'm365.md' }
        '^save$'      { return Read-PromptPart $AppRoot 'save.md' }
        '^location$'  { return [string]$Context.Location }
        '^project$'   { return [string]$Context.Full }
    }
    throw "Unknown prompt part '$Id'"
}

function New-PromptMessage {
    <#
    .SYNOPSIS The text to send for one request: the parts this kind of task needs that the chat has
              not had yet, then the request. A plain chat message is sent as it is.
    .PARAMETER Sent  HashSet of part ids already sent in this chat; updated with the parts added here.
    .PARAMETER Context  @{ Location = '...'; Full = '...' } describing the project folder.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$Kind,
        [AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory)]$Sent,
        $Context = @{ Location = ''; Full = '' },
        [string]$Summary
    )
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($id in Get-PromptParts $Kind) {
        if ($Sent.Contains($id)) { continue }
        $part = Get-PromptPart $AppRoot $id $Context
        if ($part) { $out.Add($part) }
        [void]$Sent.Add($id)
    }
    if ($Summary) { $out.Add("Summary of the previous chat:`n$Summary") }
    if (-not $out.Count) { return $Text }
    $body = $out -join "`n`n"
    if ($Text) { $body += "`n`nRequest: $Text" }
    $body
}

Export-ModuleMember -Function Get-TaskKind, Get-PromptParts, Get-PromptPart, New-PromptMessage
