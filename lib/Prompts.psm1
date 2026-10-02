# Builds the instructions sent to Copilot at the start of a chat. Copilot's role follows the kind
# of task: an expert developer for coding, a personal assistant for email/calendar/meetings/chats,
# a general assistant otherwise. The human-in-the-loop rules are part of every role.

$ErrorActionPreference = 'Stop'

# Signals for the kind of task (English and common Dutch words).
$script:CodingPattern = '(?i)\b(code|coding|codebase|script|scripts|program|programming|programma|function|functie|class|method|bug|bugs|debug|refactor|compile|build|builds|unit tests?|tests?|api|endpoint|database|sql|html|css|javascript|typescript|python|powershell|c#|java|react|vue|node|npm|dotnet|\.net|app|apps|application|applicatie|repo|repository|git|commit|module|library|package|deploy|cli|component|frontend|backend|server|json|yaml|regex|dashboard|website|webpage|implement|implementeer)\b|\.(ps1|psm1|py|js|ts|tsx|jsx|cs|java|go|rs|html|css|json|ya?ml|sql|sh|cmd|bat)\b'
$script:M365Pattern = '(?i)\b(e-?mails?|mails?|mailbox|inbox|outlook|meetings?|calendar|agenda|appointments?|invit(e|es|ation|ations)|teams|chats?|channels?|onedrive|sharepoint|follow-?ups?|minutes|vergadering(en)?|afspra(ak|ken)|uitnodiging(en)?|berichten|notulen)\b'

function Get-TaskKind {
    <# 'coding', 'assistant' (Microsoft 365 work, no coding), 'mixed' (both) or 'general'. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $coding = $Text -match $script:CodingPattern
    $m365 = $Text -match $script:M365Pattern
    if ($coding -and $m365) { 'mixed' } elseif ($coding) { 'coding' } elseif ($m365) { 'assistant' } else { 'general' }
}

function Read-PromptPart([string]$AppRoot, [string]$Name) {
    ([IO.File]::ReadAllText((Join-Path $AppRoot "prompts\$Name"))).Trim()
}

function Get-RoleText {
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Kind)
    $role = switch ($Kind) { 'assistant' { 'assistant' } 'general' { 'general' } default { 'coding' } }
    $text = Read-PromptPart $AppRoot "roles\$role.md"
    if ($Kind -eq 'mixed') { $text += ' This task also involves the user''s Microsoft 365 data (email, calendar, meetings or chats).' }
    $text
}

function Get-Instructions {
    <# Full instructions for the first message of a chat, for this kind of task. #>
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Kind)
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((Get-RoleText $AppRoot $Kind))
    $parts.Add((Read-PromptPart $AppRoot 'actions.md'))
    if ($Kind -eq 'assistant' -or $Kind -eq 'mixed') { $parts.Add((Read-PromptPart $AppRoot 'm365-data.md')) }
    $parts.Add((Read-PromptPart $AppRoot 'human-in-the-loop.md'))
    $parts.Add((Read-PromptPart $AppRoot 'rules.md'))
    $parts -join "`n`n"
}

function Get-RoleSwitch {
    <# Short preface when a later message in the same chat is a different kind of task. #>
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Kind)
    $text = "For this request: $(Get-RoleText $AppRoot $Kind)"
    if ($Kind -eq 'assistant' -or $Kind -eq 'mixed') { $text += "`n`n" + (Read-PromptPart $AppRoot 'm365-data.md') }
    $text + "`n`nThe action blocks and rules from the start of this chat still apply.`n`n"
}

Export-ModuleMember -Function Get-TaskKind, Get-Instructions, Get-RoleSwitch, Get-RoleText
