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
Import-Module (Join-Path $PSScriptRoot 'UiKit.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

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
$script:FixPattern = '(?i)\b(fix|fixes|fixing|repair|solve|debug|repareer|herstel|los .{0,20} op)\b'
$script:TestPattern = '(?i)\b(tests?|testing|unit ?tests?|pester|pytest|jest|vitest|spec|specs)\b'
$script:SecurityPattern = '(?i)\b(login|log ?in|sign ?in|auth|authentication|passwords?|tokens?|api ?keys?|secrets?|sql|query|queries|database|user input|forms?|uploads?|cookies?|sessions?|permissions?|encrypt|xss|injection|sanitize|wachtwoord)\b'
$script:JsPattern = '(?i)\b(javascript|typescript|node(\.?js)?|npm|react|vue|svelte|angular)\b|\.(m?js|cjs|jsx?|tsx?)\b'
$script:OfficePattern = '(?i)\b(word|powerpoint|excel)[ -]?(document|doc|file|bestand|presentation|presentatie|deck|workbook|sheet)s?\b|\b(docx?|pptx?|xlsx?|slide ?decks?|slides)\b|\.(docx?|pptx?|xlsx?|pdf)\b|\b(pdfs?|pdf[ -]?(file|document|bestand)s?)\b'
$script:DataPattern = '(?i)\b(csv|tsv|excel|xlsx|xls|spreadsheets?|data ?files?|import (the )?data|export (the )?data|parse|parsing|columns?|rows?)\b|\.(csv|tsv|xlsx?)\b'
$script:BigTaskPattern = '(?i)\b(build|create|make|develop)\s+(an?|the|my|me an?|me the)?\s*(new\s+)?(app|application|website|web ?site|tool|dashboard|portal|system|game)\b|\b(multiple|several|all the) (pages|screens|features|parts)\b|\bfrom scratch\b'
$script:ScriptPattern = '(?i)\b(scripts?|automat\w*|schedul\w*|chains?|cron|task scheduler|batch job)\b|scripts/'
$script:UiPattern = '(?i)\b(ui|ux|user interface|layout|screens?|responsive|accessib\w*|a11y|loading state|empty state|design)\b'
# A request to review the design of the interface (prompts/rules/designreview.md).
$script:DesignReviewPattern = '(?i)\b(design ?review|review (the |my |this |our )?(design|ui|interface|layout|pages?|screens?|dashboard)|(ontwerp|design) ?(review|beoordel\w*)|beoordeel (het |de )?(ontwerp|interface|pagina\w*))\b'
$script:HttpPattern = '(?i)\b(apis?|rest|endpoints?|http|https|fetch|invoke-restmethod|invoke-webrequest|webhooks?|requests?|rate limit)\b'
$script:CSharpPattern = '(?i)c#|\b(csharp|dotnet|\.net|asp\.net|blazor|wpf|winforms)\b|\.(cs|csproj|sln)\b'
$script:ReactPattern = '(?i)\b(react|jsx|tsx|use(State|Effect|Memo|Callback|Ref|Context)|next\.?js)\b'
$script:PrismaPattern = '(?i)\bprisma\b|schema\.prisma'
$script:PrivacyPattern = '(?i)\b(personal data|pii|privacy|gdpr|avg|customer data|employee data|e-?mail addresses|phone numbers|persoonsgegevens)\b'
$script:BatchPattern = '(?i)\b(batch ?(file|script)s?|cmd ?files?)\b|\.(cmd|bat)\b'
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
    if (@($Paths | Where-Object { $_ -match '(?i)\.(m?js|cjs|jsx?|tsx?)$' -and $_ -notmatch '(?i)(^|/)(node_modules|dist|build)/|\.min\.js$' }).Count) { $t.Add('javascript') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.(cmd|bat)$' }).Count) { $t.Add('batch') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.(csv|tsv|xlsx?)$' }).Count) { $t.Add('data') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.(cs|csproj|sln)$' }).Count) { $t.Add('csharp') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.(docx?|pptx?|xlsx?|docm|pptm|xlsm|pdf)$' }).Count) { $t.Add('office') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.(jsx|tsx)$' -and $_ -notmatch '(?i)(^|/)node_modules/' }).Count) { $t.Add('react') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.prisma$' -and $_ -notmatch '(?i)(^|/)node_modules/' }).Count) { $t.Add('prisma') }
    if (@($Paths | Where-Object { $_ -match '(?i)\.Tests\.ps1$|(^|/)test_[^/]+\.py$|_test\.py$|\.(test|spec)\.[cm]?[jt]sx?$|(^|/)(tests?|__tests__)/' }).Count) { $t.Add('tests') }
    $t.ToArray()
}

$script:ReactWithNpm = '- Building React here: use Vite with base: ''./'' in vite.config, so the built app (dist/index.html) also opens from a subfolder address; build with npm run build. Do not start a development server (npm run dev, vite, npm start): the user cannot run one. The user opens the built app from the helper program.'
$script:ReactWithoutNpm = '- This computer has no Node.js or npm, so a React app (or any npm package, bundler or build step) cannot be built here. Build the page with plain HTML, CSS and JavaScript instead, unless the user asks to install Node.js first.'

function Test-ToolInstalled([string]$Name) {
    <# A program on PATH (not the Store's WindowsApps stubs). #>
    [bool](Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1)
}

function Get-EnvironmentText {
    <# What this computer can run, so Copilot does not suggest tools that are not there. Looked up
       once per run of the helper program (the Store's python.exe stub does not count). #>
    # Looked up again when PATH changed (a tool installed from Settings > This computer).
    if ($script:EnvText -and $script:EnvPath -eq $env:Path) { return $script:EnvText }
    $script:EnvPath = $env:Path
    $tools = [ordered]@{ python = 'python'; node = 'node'; npm = 'npm'; dotnet = 'dotnet (.NET SDK)'; git = 'git' }
    $have = New-Object System.Collections.Generic.List[string]; $miss = New-Object System.Collections.Generic.List[string]
    foreach ($k in $tools.Keys) {
        $c = Get-Command $k -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
        if ($c) { $have.Add($tools[$k]) } else { $miss.Add($tools[$k]) }
    }
    $script:EnvText = "- This computer: Windows PowerShell 5.1 and Edge$(if ($have.Count) { "; also $($have -join ', ')" })." +
        $(if ($miss.Count) { " Not installed: $($miss -join ', '): do not use or suggest them, and do not install software." } else { '' })
    $script:EnvText
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
    $ids.Add('rules:environment')   # what this computer has installed (Get-EnvironmentText)
    # find and remember: only useful once the project has files.
    if (@($Context.Paths | Where-Object { $_ }).Count -or $traits -contains 'code') { $ids.Add('actions:project') }
    if ($web) { $ids.Add('rules:web') }
    if ($web -or ($Text -match $script:MovePattern)) { $ids.Add('rules:moving') }
    if (($traits -contains 'python') -or ($Text -match $script:PythonPattern)) { $ids.Add('rules:python') }
    if (($traits -contains 'powershell') -or ($Text -match $script:PowerShellPattern)) { $ids.Add('rules:powershell') }
    if ($traits -contains 'source') { $ids.Add('rules:source') }
    if ($Text -match $script:BuildPattern) { $ids.Add('rules:quality') }
    if (($Text -match $script:ProblemPattern) -or ($Text -match $script:FixPattern)) { $ids.Add('rules:debugging') }
    if (($traits -contains 'tests') -or ($Text -match $script:TestPattern)) { $ids.Add('rules:testing') }
    if (($Text -match $script:SecurityPattern) -or ($web -and $Text -match $script:BuildPattern)) { $ids.Add('rules:security') }
    if (($traits -contains 'javascript') -or ($Text -match $script:JsPattern)) { $ids.Add('rules:javascript') }
    if (($traits -contains 'batch') -or ($Text -match $script:BatchPattern)) { $ids.Add('rules:batch') }
    # A question about the code (how, why, where) that asks for no change: answer, do not edit.
    if ($Text -match $script:CodeQuestionPattern -and $Text -notmatch $script:ChangePattern -and $Text -notmatch $script:FixPattern) { $ids.Add('rules:questions') }
    if (($traits -contains 'data') -or ($traits -contains 'source') -or ($Text -match $script:DataPattern)) { $ids.Add('rules:data') }
    if (($traits -contains 'office') -or ($Text -match $script:OfficePattern)) { $ids.Add('rules:office') }
    if (($Text -match $script:BigTaskPattern) -or $Text.Length -gt 600) { $ids.Add('rules:bigtask') }
    if ($Text -match $script:ScriptPattern) { $ids.Add('rules:scripts') }
    $designReview = $Text -match $script:DesignReviewPattern
    if (($web -and ($Text -match $script:AppPartPattern -or $Text -match $script:BuildPattern)) -or ($Text -match $script:UiPattern) -or $designReview) {
        $ids.Add('rules:ui')
        if (Test-UiKitPart 'designRules' (Split-Path -Parent $PSScriptRoot)) { $ids.Add('rules:design') }   # how a good interface behaves (our own short rules)
        if ($designReview) { $ids.Add('rules:designreview') }
        # Build from the UI kit (setting uiKit; the agent adds the kit to the project when this goes out).
        if (Test-UiKitOn (Split-Path -Parent $PSScriptRoot)) { $ids.Add('rules:uikit') }
    }
    elseif ($web -and @($Context.Paths) -contains 'styles/kit/tokens.css' -and ($Text -match $script:ChangePattern -or $Text -match $script:FixPattern -or $Text -match $script:BuildPattern) -and (Test-UiKitOn (Split-Path -Parent $PSScriptRoot))) {
        # A project with the UI kit: any change to it may add interface, so the kit's rule goes too.
        $ids.Add('rules:uikit')
    }
    if ($Text -match $script:HttpPattern) { $ids.Add('rules:http') }
    if (($traits -contains 'csharp') -or ($Text -match $script:CSharpPattern)) { $ids.Add('rules:csharp') }
    if (($traits -contains 'react') -or ($Text -match $script:ReactPattern)) { $ids.Add('rules:react') }
    if (($traits -contains 'prisma') -or ($Text -match $script:PrismaPattern)) { $ids.Add('rules:prisma') }
    if (($traits -contains 'source') -or ($Text -match $script:PrivacyPattern)) { $ids.Add('rules:privacy') }
    # Runbook rules: for requests about runbooks, and for messages that name one of the project's runbooks.
    $namesRunbook = @($Context.Paths | Where-Object { "$_" -match '(?i)^Runbooks/([^/]+)\.runbook\.md$' -and $Text -match ('(?i)(^|[^\w-])' + [regex]::Escape($Matches[1]) + '($|[^\w-])') }).Count
    if ($Text -match $script:RunbookPattern -or $namesRunbook) { $ids.Add('rules:runbook') }
    # Online information: how to use web sources, and the web action for the exact text of a page.
    if ($Text -match $script:WebLookupPattern -or @(Get-NamedSites $Text).Count) { $ids.Add('rules:websources'); $ids.Add('actions:web') }
    if (@(Get-M365Links $Text).Count) { $ids.Add('rules:m365links') }
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
        'runbook-web' { @('role:research', 'runbook-web') }      # a runbook with sources: web (no Microsoft 365)
        default     { @() }
    }
}

function Read-PromptPart([string]$AppRoot, [string]$Name) {
    $t = ([IO.File]::ReadAllText((Join-Path $AppRoot "prompts\$Name"))).Trim()
    # Data copies turned off (setting dataCopies): no word about the helper program keeping them.
    if ($Name -eq 'rules\web.md' -and -not (Test-DataCopiesOn $AppRoot)) { $t = $t -replace '; when the data is also a \.json file[^)]*', ';' }
    # React needs Node.js and npm to build; without them a React setup cannot work here.
    if ($Name -eq 'rules\react.md') { $t += "`n" + $(if (Test-ToolInstalled 'npm') { $script:ReactWithNpm } else { $script:ReactWithoutNpm }) }
    $t
}

function Get-PromptPart {
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Id, $Context)
    switch -Regex ($Id) {
        '^role:(.+)$' { return Read-PromptPart $AppRoot "roles\$($Matches[1]).md" }
        '^actions$'   { return Read-PromptPart $AppRoot 'actions.md' }
        '^rules$'     { return Read-PromptPart $AppRoot 'rules.md' }
        '^rules:environment$' { return Get-EnvironmentText }
        '^rules:runbook$' {
            # With the blank template, in a four-backtick fence (the template has ```json blocks).
            $tpl = Join-Path $AppRoot 'templates\runbooks\blank.runbook.md'
            $part = Read-PromptPart $AppRoot 'rules\runbook.md'
            $fence = '````'
            if (Test-Path -LiteralPath $tpl) { $part += "`n`nRUNBOOK TEMPLATE`n$fence`n" + ([IO.File]::ReadAllText($tpl).Replace("`r`n", "`n").Trim()) + "`n$fence" }
            return $part
        }
        '^rules:uikit$' {
            # Only the kit parts that are switched on (Settings > UI kit).
            $lines = @((Read-PromptPart $AppRoot 'rules\uikit.md').Split("`n"))
            if (-not (Test-UiKitPart 'interactive' $AppRoot)) { $lines = @($lines | Where-Object { $_ -notlike '- Interactive parts*' }) }
            if (-not (Test-UiKitPart 'charts' $AppRoot)) {
                # No kit charts: no dashboard example either, and a chart library gets the kit's colours.
                $lines = @($lines | Where-Object { $_ -notlike '- Charts:*' -and $_ -notlike '- Dashboards:*' })
                $lines = @(foreach ($l in $lines) { if ($l -like '- Anything a page draws itself*') { $l -replace 'No chart library \(they bring their own colours\) and no colours of your own\.', 'A chart library gets these colours too, never its own palette.' } else { $l } })
            }
            if (-not (Test-UiKitPart 'icons' $AppRoot)) { $lines = @($lines | Where-Object { $_ -notlike '- Icons (Lucide*' }) }
            if (-not (Test-UiKitPart 'data' $AppRoot)) { $lines = @($lines | Where-Object { $_ -notlike '- Reading files*' }) }
            elseif (-not (Test-UiKitPart 'pdf' $AppRoot)) { $lines = @(foreach ($l in $lines) { if ($l -like '- Reading files*') { $l -replace ' PDF: .*', ' PDF files cannot be read in the page (pdf.js is switched off).' } else { $l } }) }
            $text = $lines -join "`n"
            $colors = Get-UiKitColors $AppRoot
            if ($colors -ne 'blue') { $text = $text -replace ' With the blue palette the named colours are[^.]*\.[^.]*\.', '' }
            if ($colors -eq 'none') {
                # Colours: None. No palette is set: Copilot uses the colours the project or the request asks for.
                $text = @(foreach ($l in $text.Split("`n")) {
                    if ($l -like '- Anything a page draws itself*') { continue }
                    if ($l -like '- Colours:*') { '- Colours: no colours are set for this project. The tokens in styles/kit/tokens.css are neutral starting values only: use the colours the project already has or the request asks for, set them in tokens.css (--kit-accent, --kit-chart-1...) or in your own CSS. Hard-coded colours and gradients are fine.' }
                    elseif ($l -like '- Restyle through the tokens*') { $l -replace 'do not hard-code colours, sizes or shadows', 'do not hard-code sizes or shadows' -replace 'Your own CSS uses the same tokens\. ', '' }
                    else { $l }
                }) -join "`n"
            }
            if (-not (Test-UiKitPart 'react' $AppRoot)) { $text = $text -replace ' In a React project use styles/kit/react/ instead:[^\n]*', '' -replace '; React: Chart from styles/kit/react/', '' -replace ' React: Icon from styles/kit/react/\.', '' -replace ' React: useFileData from styles/kit/react/\.', '' -replace ' and React parts come the same way', ' come the same way' -replace ', or an import from styles/kit/react/', '' }
            return $text
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
        '^runbook-web$' { return Read-PromptPart $AppRoot 'runbook-web.md' }
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

# --- Agent: auto (the agent picker next to Response) ---------------------------------------
# StreamHub picks one of Copilot's agents by fixed words, never by understanding the request.
# Kept narrow on purpose: an agent run takes minutes and may count against a monthly limit, so a
# request goes to an agent only when it clearly asks for what the agent is for.
$script:AutoCodeWork = '(?i)\b(code|script|function|component|button|page|app|website|dashboard|bug|error|compile|build|refactor|deploy|install|repo(sitory)?)\b|\.(ps1|psm1|py|js|ts|tsx|jsx|html?|css|cs|java|sql|cmd|bat)\b'
$script:AutoResearch = '(?i)\b(research|investigate|deep[ -]?dive|look into|find out (what|how|why|whether|which)|state of the art|market (analysis|research|overview|size|trends?)|competitors?|competitive (landscape|analysis)|industry trends?|best practices (for|in|on)|literature|with (sources|citations|references)|cite (your )?sources|onderzoek|zoek uit|marktanalyse|concurrent(en|ie))\b'
$script:AutoAnalysis = '(?i)\b(analy[sz]e|analysis|analyses|chart|charts|graph|plot|visuali[sz]e|trend|trends|statistics?|correlat\w*|forecast|regression|distribution|outliers?|pivot|average|median|breakdown|analyseer|grafiek|statistiek)\b'
$script:AutoDataFile = '(?i)[^\s''"()@/]+\.(csv|tsv|xlsx|xlsm|xls|json|parquet)\b'

function Get-AutoAgent {
    <# Which agent answers a message when the picker says Auto: @{ agent = researcher | analyst | '';
       why }. Analyst: analysis words and a data file attached or named (csv, xlsx, json...).
       Researcher: words that ask for research (research, investigate, competitors, market, with
       sources...) in a request of five words or more. Not for work on code or app parts (that stays
       with Copilot and the helper program's actions); plain chat otherwise. #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text -or -not $Text.Trim()) { return @{ agent = ''; why = '' } }
    if ($Text -match $script:AutoCodeWork -or $Text -match $script:FixPattern) { return @{ agent = ''; why = 'work on code or an app stays with Copilot' } }
    $data = [regex]::Match($Text, $script:AutoDataFile)
    $ana = [regex]::Match($Text, $script:AutoAnalysis)
    if ($data.Success -and $ana.Success) { return @{ agent = 'analyst'; why = "analysis ('$($ana.Value)') of a data file ($($data.Value))" } }
    $res = [regex]::Match($Text, $script:AutoResearch)
    if ($res.Success -and @($Text.Trim() -split '\s+').Count -ge 5) { return @{ agent = 'researcher'; why = "a request for research ('$($res.Value)')" } }
    @{ agent = ''; why = '' }
}

Export-ModuleMember -Function Test-ToolInstalled, Get-AutoAgent, Get-EnvironmentText, Test-NamesProjectFile, Get-TaskKind, Get-PromptParts, Get-PromptPart, Get-PromptModules, Get-ProjectTraits, New-PromptMessage
