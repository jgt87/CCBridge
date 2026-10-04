# Builds what is sent to Copilot. The prompt is as small as the request allows:
#   chat       plain text only (greetings, general questions)
#   assistant  short assistant role + read-only Microsoft 365 rule + how to save a file + location
#   project    short role + compact action description + rules + project context
#   coding     same as project with a developer role
#   mixed      coding plus the Microsoft 365 rule (code that works with mail/calendar/chats)
# Work on files also gets case-specific modules (Get-PromptModules): the run action when commands
# are allowed, and rules for web apps, moving code, Python, PowerShell and read-only source data.
# Parts already sent in the current chat are not repeated; a later request only adds what it needs.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WebFetch.psm1')

# Signals for the kind of task (English and common Dutch words).
$script:CodingPattern = '(?i)\b(code|coding|codebase|script|scripts|program|programming|programma|function|functie|class|method|bug|bugs|debug|refactor|compile|build|builds|unit tests?|tests?|api|endpoint|database|sql|html|css|javascript|typescript|python|powershell|c#|java|react|vue|node|npm|dotnet|\.net|app|apps|application|applicatie|repo|repository|git|commit|module|library|package|deploy|cli|component|frontend|backend|server|json|yaml|regex|dashboard|website|webpage|implement|implementeer)\b|\.(ps1|psm1|py|js|ts|tsx|jsx|cs|java|go|rs|html|css|json|ya?ml|sql|sh|cmd|bat)\b'
$script:M365Pattern = '(?i)\b(e-?mails?|mails?|mailbox|inbox|outlook|meetings?|calendar|agenda|appointments?|invit(e|es|ation|ations)|teams|chats?|channels?|onedrive|sharepoint|follow-?ups?|minutes|vergadering(en)?|afspra(ak|ken)|uitnodiging(en)?|berichten|notulen)\b'
$script:ProjectPattern = '(?i)\b(files?|folders?|project|documents?|notes|csv|excel|xlsx|spreadsheet|data|report|readme|summary|summaries|bestand(en)?|map|rapport|samenvatting|source)\b|(^|\s)@[\w.]'

# Case-specific rule modules: request words, or what the project contains (Context.Traits).
$script:WebPattern = '(?i)\b(html|css|scss|website|web ?app|web ?page|landing page|frontend|front-end|react|vue|svelte|angular|tsx|jsx|javascript|typescript|component|stylesheet|dashboard|webpagina)\b|\bCORS\b|file://|origin ''null'''
$script:MovePattern = '(?i)\b(move|moving|split|extract|separate|refactor|offload|reorgani[sz]e|restructure|verplaats|splits|scheid|herstructureer)\b'
$script:PythonPattern = '(?i)\b(python|pip|django|flask|pandas|pytest)\b|\.pyw?\b'
$script:PowerShellPattern = '(?i)\b(powershell|pester|cmdlets?)\b|\.ps[md]?1\b'
$script:RunbookPattern = '(?i)\b(runbooks?|draaiboek(en)?)\b'
# Requests that build or change code get the code quality rules (rules/quality.md), once per chat.
$script:BuildPattern = '(?i)\b(build\s+(a|an|me|the|new|it)|create|add|implement|make|write|develop|extend|refactor|rewrite|clean ?up|improve|feature|component|module|function|class|page|app|tool|script|bouw|maak|voeg|schrijf|verbeter)\b'
# Requests for online information (with Get-NamedSites: a website or address in the request).
$script:WebLookupPattern = '(?i)\b(online|on the (web|internet)|internet|websites?|web ?pages?|web ?sites?|look (it |this |that )?up|latest (version|release)s?|release notes|documentation|docs (for|of)|price ?lists?|pricing|exchange rates?|news (about|on)|wikipedia)\b|https?://|\bwww\.'

# In a project with code, these make a request work on the code even without a coding word
# (English and Dutch): asking for a change, naming a part of an app, reporting an error, or asking
# how or why the code does something.
$script:ChangePattern = '(?i)\b(add|change|make|fix|update|remove|delete|rename|move|create|build|improve|implement|replace|refactor|rewrite|convert|split|extract|clean ?up|tidy|restyle|style|center|centre|align|resize|hide|show|enable|disable|translate|optimi[sz]e|speed up|set up|configure|connect|integrate|support|allow|prevent|validate|sort|filter|redesign|polish|voeg|maak|verander|wijzig|pas .{0,20} aan|verwijder|hernoem|verplaats|bouw|verbeter|vervang|zet|toon|verberg|repareer|herstel)\b'
$script:AppPartPattern = '(?i)\b(button|buttons|page|pages|header|footer|menu|navbar|nav ?bar|sidebar|side ?panel|layout|styles?|styling|colou?rs?|fonts?|forms?|input|inputs|fields?|table|tables|chart|charts|graph|modal|popup|dialog|toggle|dark mode|light mode|theme|icons?|images?|logo|links?|scroll|responsive|mobile|screen|view|tabs?|cards?|grid|columns?|rows?|animation|hover|click|clicks|clicking|clicked|login|search bar|dropdown|knop|knoppen|kleur|lettertype|pagina|scherm|tabel|grafiek|formulier|menu)\b'
$script:ProblemPattern = '(?i)\b(error|errors|exception|crash|crashes|crashing|broken|bug|doesn.?t work|does not work|not working|isn.?t working|fails|failing|stack ?trace|undefined|null|NaN|404|500|wrong|incorrect|slow|freezes|does nothing|nothing happens|doet niets|gebeurt niets|werkt niet|kapot|foutmelding|fout)\b'
$script:CodeQuestionPattern = '(?i)\b(why|how does|how do|how is|what does|where is|where are|which file|explain|waarom|hoe werkt|wat doet|waar staat|leg uit)\b'
$script:CodeFileExt = '(?i)\.(ps1|psm1|psd1|py|pyw|js|mjs|cjs|jsx|ts|mts|tsx|vue|svelte|html?|css|scss|less|cs|java|kt|go|rs|rb|php|sh|cmd|bat|sql|c|cpp|h|hpp|swift|dart|lua)$'

function Test-NamesProjectFile {
    <# Whether the text names one of the project's files (as name.ext or its name without the
       extension, at least 4 characters, e.g. "the navbar" for components/Navbar.tsx). #>
    param([string]$Text, [string[]]$Paths)
    if (-not $Text -or -not $Paths) { return $false }
    $words = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches($Text, '[\w.-]{4,}')) { [void]$words.Add($m.Value.Trim('.', '-')) }
    foreach ($p in $Paths) {
        $name = ($p -split '/')[-1]
        $stem = [IO.Path]::GetFileNameWithoutExtension($name)
        if ($words.Contains($name) -or ($stem.Length -ge 4 -and $stem -notmatch '^(index|main|readme|agents|package|config|style|styles|utils?|app|test|tests)$' -and $words.Contains($stem))) { return $true }
    }
    $false
}

function Get-ProjectTraits {
    <# What a project contains, from its file paths: code (any source file), web, python,
       powershell, source. #>
    param([string[]]$Paths)
    $t = New-Object System.Collections.Generic.List[string]
    if (@($Paths | Where-Object { $_ -match $script:CodeFileExt -and $_ -notmatch '(?i)^source/' }).Count) { $t.Add('code') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.(html?|css|scss|less|jsx?|mjs|tsx?|vue|svelte)$|(^|/)package\.json$' }).Count) { $t.Add('web') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.pyw?$|(^|/)requirements\.txt$|(^|/)pyproject\.toml$' }).Count) { $t.Add('python') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.ps[md]?1$' }).Count) { $t.Add('powershell') }
    if (@($Paths | Where-Object { $_ -match '(?i)^source/' }).Count) { $t.Add('source') }
    $t.ToArray()
}

function Get-PromptModules {
    <# Case-specific parts for work on files, in order. 'actions:run' unless commands are off
       (trait 'nocommands'); 'rules:*' when the request or the project calls for them. #>
    param([AllowEmptyString()][string]$Text, $Context)
    $traits = @($Context.Traits)
    $web = ($traits -contains 'web') -or ($Text -match $script:WebPattern)
    $ids = New-Object System.Collections.Generic.List[string]
    if ($traits -notcontains 'nocommands') { $ids.Add('actions:run') }
    $ids.Add('rules:folders')   # where each kind of file goes (Layout.psm1)
    # find and remember: only useful once the project has files.
    if (@($Context.Paths | Where-Object { $_ }).Count -or $traits -contains 'code') { $ids.Add('actions:project') }
    if ($web) { $ids.Add('rules:web') }
    if ($web -or ($Text -match $script:MovePattern)) { $ids.Add('rules:moving') }
    if (($traits -contains 'python') -or ($Text -match $script:PythonPattern)) { $ids.Add('rules:python') }
    if (($traits -contains 'powershell') -or ($Text -match $script:PowerShellPattern)) { $ids.Add('rules:powershell') }
    if ($traits -contains 'source') { $ids.Add('rules:source') }
    if ($Text -match $script:BuildPattern) { $ids.Add('rules:quality') }
    if ($Text -match $script:RunbookPattern) { $ids.Add('rules:runbook') }
    # Online information: how to use web sources, and the web action for the exact text of a page.
    if ($Text -match $script:WebLookupPattern -or @(Get-NamedSites $Text).Count) { $ids.Add('rules:websources'); $ids.Add('actions:web') }
    $ids.ToArray()
}

function Get-TaskKind {
    <# 'chat', 'assistant', 'project', 'coding' or 'mixed'. With the project's traits and file paths,
       a request in a project with code also counts as coding when it asks for a change, names a
       part of an app, reports a problem, asks how or why something works, or names a project file;
       a request naming a project file is at least project work. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string[]]$Traits = @(), [string[]]$Paths = @())
    $coding = $Text -match $script:CodingPattern
    $m365 = $Text -match $script:M365Pattern
    $project = ($Text -match $script:ProjectPattern) -or (Test-NamesProjectFile $Text $Paths)
    if (-not $coding -and -not $m365 -and $Traits -contains 'code' -and $Text.Trim()) {
        $coding = ($Text -match $script:ChangePattern) -or ($Text -match $script:AppPartPattern) -or ($Text -match $script:ProblemPattern) -or ($Text -match $script:CodeQuestionPattern) -or (Test-NamesProjectFile $Text $Paths)
    }
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
        'fetch'     { @('fetch') }                                  # saved fetch prompt: the answer becomes a file
        'fetch-m365' { @('role:assistant', 'm365', 'fetch') }
        'runbook'   { @('role:assistant', 'm365', 'runbook') }   # data runbook: JSON export, read-only
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
        '^rules:runbook$' {
            # With the blank template, in a four-backtick fence (the template has ```json blocks).
            $tpl = Join-Path $AppRoot 'templates\runbooks\blank.runbook.md'
            $part = Read-PromptPart $AppRoot 'rules\runbook.md'
            $fence = '````'
            if (Test-Path -LiteralPath $tpl) { $part += "`n`nRUNBOOK TEMPLATE`n$fence`n" + ([IO.File]::ReadAllText($tpl).Replace("`r`n", "`n").Trim()) + "`n$fence" }
            return $part
        }
        '^rules:(.+)$' { return Read-PromptPart $AppRoot "rules\$($Matches[1]).md" }
        '^actions:run$' { return Read-PromptPart $AppRoot 'actions-run.md' }
        '^actions:project$' { return Read-PromptPart $AppRoot 'actions-project.md' }
        '^actions:web$' { return Read-PromptPart $AppRoot 'actions-web.md' }
        '^m365$'      { return Read-PromptPart $AppRoot 'm365.md' }
        '^save$'      { return Read-PromptPart $AppRoot 'save.md' }
        '^fetch$'     { return Read-PromptPart $AppRoot 'fetch.md' }
        '^retry$'     { return Read-PromptPart $AppRoot 'retry.md' }
        '^review$'    { return Read-PromptPart $AppRoot 'review.md' }
        '^review-(code|cross)$' { return Read-PromptPart $AppRoot "review-$($Matches[1]).md" }
        '^runbook$'   { return Read-PromptPart $AppRoot 'runbook.md' }
        '^clarify$'   { return Read-PromptPart $AppRoot 'clarify.md' }
        '^plan-first$' { return Read-PromptPart $AppRoot 'plan-first.md' }
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
    # Base parts, with the case-specific modules after the part they belong to (the run action
    # after the actions, rule modules after the rules). A follow-up that needs a module the chat
    # has not had yet gets just that module.
    $ids = New-Object System.Collections.Generic.List[string]
    $modules = if ($Kind -in 'project', 'coding', 'mixed') { @(Get-PromptModules $Text $Context) } else { @() }
    foreach ($id in Get-PromptParts $Kind) {
        $ids.Add($id)
        if ($id -eq 'actions') { foreach ($m in $modules) { if ($m -like 'actions:*') { $ids.Add($m) } } }
        if ($id -eq 'rules') { foreach ($m in $modules) { if ($m -like 'rules:*') { $ids.Add($m) } } }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $baseAdded = $false
    foreach ($id in $ids) {
        if ($Sent.Contains($id)) { continue }
        $part = Get-PromptPart $AppRoot $id $Context
        if ($part) { $out.Add($part); if ($id -notmatch ':' -or $id -like 'role:*') { $baseAdded = $true } }
        [void]$Sent.Add($id)
    }
    if ($Summary) { $out.Add("Summary of the previous chat:`n$Summary"); $baseAdded = $true }
    if ($out.Count -and -not $baseAdded -and $Text) {
        # Only new modules: the follow-up as usual, with those rules and the reminder.
        return "$($out -join "`n`n")`n`nRequest: $Text`n`n$(Read-PromptPart $AppRoot 'reminder.md')"
    }
    if (-not $out.Count) {
        # A follow-up in a chat that already has the instructions: a one-line reminder for work on
        # files, because Copilot tends to explain instead of act once the instructions are far back.
        if ($Text -and $Kind -in 'coding', 'project', 'mixed') { return "$Text`n`n$(Read-PromptPart $AppRoot 'reminder.md')" }
        return $Text
    }
    $body = $out -join "`n`n"
    if ($Text) { $body += "`n`nRequest: $Text" }
    $body
}

Export-ModuleMember -Function Test-NamesProjectFile, Get-TaskKind, Get-PromptParts, Get-PromptPart, Get-PromptModules, Get-ProjectTraits, New-PromptMessage
