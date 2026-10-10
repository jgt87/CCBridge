# Settings: config\<name>.json ships with CCBridge; config\<name>.local.json holds this machine's
# overrides (for example the Work IQ selector) and is never touched by updates.

$ErrorActionPreference = 'Stop'

function Merge-JsonObject($Base, $Override) {
    foreach ($p in $Override.PSObject.Properties) {
        $current = $Base.PSObject.Properties[$p.Name]
        if ($current -and $current.Value -is [pscustomobject] -and $p.Value -is [pscustomobject]) {
            Merge-JsonObject $current.Value $p.Value
        } else {
            $Base | Add-Member -Force -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
}

function Get-CCBridgeConfig {
    <# Returns config\<Name>.json merged with config\<Name>.local.json (if present). #>
    param([Parameter(Mandatory)][ValidateSet('harness', 'selectors')][string]$Name, [string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $AppRoot 'config'
    $config = Get-Content (Join-Path $dir "$Name.json") -Raw | ConvertFrom-Json
    $local = Join-Path $dir "$Name.local.json"
    if (Test-Path $local) {
        $override = Get-Content $local -Raw | ConvertFrom-Json
        if ($override) { Merge-JsonObject $config $override }
    }
    $config
}

function Get-CCBridgeVersion([string]$AppRoot) {
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $v = Join-Path $AppRoot 'version.txt'
    if (Test-Path $v) { return ([IO.File]::ReadAllText($v)).Trim() }
    try { $sha = & git -C $AppRoot rev-parse --short HEAD 2>$null; if ($sha) { return "git-$sha" } } catch { }
    'dev'
}

function Get-CCBridgeBuild {
    <# Release version and commit, shown in the web app. A release copy has version.txt and
       commit.txt (written by build-release.ps1); a git copy uses its latest release tag and HEAD. #>
    param([string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $version = $null; $commit = $null
    $v = Join-Path $AppRoot 'version.txt'
    $c = Join-Path $AppRoot 'commit.txt'
    if (Test-Path $v) { $version = ([IO.File]::ReadAllText($v)).Trim() }
    if (Test-Path $c) { $commit = ([IO.File]::ReadAllText($c)).Trim() }
    if (Test-Path (Join-Path $AppRoot '.git')) {
        try {
            if (-not $version) { $version = (& git -C $AppRoot describe --tags --abbrev=0 2>$null | Select-Object -First 1) }
            if (-not $commit) { $commit = (& git -C $AppRoot rev-parse --short HEAD 2>$null | Select-Object -First 1) }
        } catch { }
    }
    [pscustomobject]@{ version = $(if ($version) { "$version" } else { 'dev' }); commit = $(if ($commit) { "$commit" } else { '' }) }
}

function Set-CCBridgeLocalSetting {
    <# Writes one setting into config\<Name>.local.json (kept across updates). #>
    param([Parameter(Mandatory)][ValidateSet('harness', 'selectors')][string]$Name, [Parameter(Mandatory)][string]$Key, $Value, [string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $file = Join-Path $AppRoot "config\$Name.local.json"
    $obj = if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    if (-not $obj) { $obj = [pscustomobject]@{} }
    $obj | Add-Member -Force -NotePropertyName $Key -NotePropertyValue $Value
    [IO.File]::WriteAllText($file, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

# Settings that can be changed in the web app: group, label, help, type, limits. Keys with a dot are
# fields of an object (pacing.beforeSendSec). Values are saved in config\harness.local.json.
$script:SettingDefs = @(
    @{ key = 'signIn'; group = 'Sign-in'; label = 'How Copilot signs in'; help = 'single-sign-on: StreamHub''s Edge profile, with your Windows account when Edge offers it; private: Copilot opens in a private session where you sign in yourself, once per Edge start (single sign-on off). Applies at the next start. Set with Settings > Sign-in.'; type = 'select'; options = @('single-sign-on', 'private') }
    @{ key = 'startMode'; group = 'Copilot'; label = 'Mode at start'; help = 'The mode StreamHub starts in: ask (approve every change and command), auto (changes apply directly, commands still ask) or plan (read and discuss only). Applies at the next start.'; type = 'select'; options = @('ask', 'auto', 'plan') }
    @{ key = 'repoMapChars'; group = 'Copilot'; label = 'Code map size (characters)'; help = 'With the first message of a chat about the project: a map of the code (functions, classes, ids with line numbers), most relevant files first, so Copilot reads only what it needs. 4000 is about 1000 tokens; a big project gets a more selective map, not a bigger one. 0 = no map.'; type = 'number'; min = 0; max = 20000 }
    @{ key = 'newChatOnSwitch'; group = 'Copilot'; label = 'New chat for another part of the project'; help = 'When a message is about other files than the chat worked on so far (another folder or module, not connected through imports) and does not continue the earlier work, it starts a new Copilot chat, so the earlier context does not crowd it. Off: one chat until you start a new one.'; type = 'toggle' }
    @{ key = 'copilotTheme'; group = 'Copilot'; label = 'Copilot follows the app''s theme'; help = 'The Copilot window shows light or dark like StreamHub (Settings > This browser > Theme). Only the Copilot tab is told the theme; nothing changes in Edge or your Microsoft 365 account, and Copilot must be set to follow the system theme (its default). Off: Copilot follows Windows.'; type = 'toggle' }
    @{ key = 'responseOptionsDays'; group = 'Copilot'; label = 'Re-read response options (days)'; help = 'How often StreamHub reads what Copilot''s response picker offers (Advanced reasoning, models such as GPT-6.1 Sol), for the Response menu next to New chat. It reads them when it connects or is idle and the list is older than this. 0 = only with Read now below.'; type = 'number'; min = 0; max = 365 }
    @{ key = 'responseMode'; group = 'Copilot'; label = 'Response mode'; help = 'Sets Copilot''s response picker before each message: Auto, Quick response, Think deeper, or (in the menu next to New chat) any other option Copilot offers here, such as Advanced reasoning or a model. As set in Copilot: StreamHub does not touch the picker, so whatever you chose in the Copilot window is used. The menu next to New chat changes it per chat.'; type = 'select'; options = @('leave', 'auto', 'quick', 'deep') }
    @{ key = 'webRead'; group = 'Copilot'; label = 'Read web pages'; help = 'When Copilot asks to read a web page (the web action): named-sites reads pages on websites your message names at once and asks for others; always-ask asks every time; off never reads pages (Copilot still uses its own web search).'; type = 'select'; options = @('named-sites', 'always-ask', 'off') }
    @{ key = 'uiKit'; group = 'UI kit'; label = 'Use the UI kit'; help = 'When Copilot builds an interface: StreamHub keeps its UI kit in one central catalogue for every project in the projects folder (its .streamhub/ui-kit/, beside the projects; a project elsewhere gets its own .streamhub/ui-kit/) (colour and size tokens, ready-made components, scripts, an examples page) and tells Copilot to build from it and restyle through the tokens, instead of inventing new styles each time. styles/kit/ gets the tokens (the project''s own to change) and, after each change, only what the pages use: the rules of the kit classes in kit.css, and the kit scripts, React parts and icons a page refers to. Off: Copilot styles pages its own way. The parts below choose what the kit holds.'; type = 'toggle' }
    @{ key = 'uiKitColors'; group = 'UI kit'; label = 'Colours'; help = 'blue: the blue palette (blue and light blue accents, teal, green, light green, yellow, orange, magenta and violet with their variations, white, greys and black), with the light-blue-to-blue gradient. neutral: greys with a near-black accent and chart colours that stay apart for colour-blind readers. Both meet WCAG AA in light and dark. none: no colours are set for the project: the kit starts from the neutral values only so its parts show, and Copilot uses the colours the project or the request asks for (in tokens.css or its own CSS), without warnings about hard-coded colours or gradients; text still has to stay readable. A project keeps the colours it got; change its styles/kit/tokens.css to switch it.'; type = 'select'; options = @('blue', 'neutral', 'none') }
    @{ key = 'uiKitParts.interactive'; group = 'UI kit'; label = 'Interactive parts'; help = 'Hold to confirm, search with suggestions, a file drop zone, animated tabs, loading text, a composer and a command button (kit.js; adapted from kokonutui).'; type = 'toggle' }
    @{ key = 'uiKitParts.charts'; group = 'UI kit'; label = 'Charts'; help = 'Bar, line, area, ring, gauge, heatmap and sparkline charts drawn on the kit''s colours (kit-charts.js; design adapted from bklit-ui).'; type = 'toggle' }
    @{ key = 'uiKitParts.icons'; group = 'UI kit'; label = 'Icons'; help = 'Lucide icons (2,000+, ISC licence): data-kit-icon="NAME" on a page draws the icon in the text colour. A project gets the common ones, and any other icon it uses is added to styles/kit/kit-icons.js after each change; a name that does not exist is reported with close ones.'; type = 'toggle' }
    @{ key = 'uiKitDarkMode'; group = 'UI kit'; label = 'Dark mode in apps'; help = 'light-only: apps and dashboards StreamHub builds are light, without a dark mode or a light/dark switch, unless you ask for one (Copilot then adds them). follow-system: pages turn dark when the computer is set to dark. switch: they follow the computer and get a light/dark button in the header. A new project gets its tokens.css this way; a project keeps what it has.'; type = 'select'; options = @('light-only', 'follow-system', 'switch') }
    @{ key = 'uiKitParts.dashboard'; group = 'UI kit'; label = 'Dashboard parts'; help = 'A side panel for details, filters for several values and for a period, short confirmations (toasts), info tips, loading placeholders, trends on key figures, a table search box, a totals row and a fixed first column, and a "data as of" line (kit.css and kit.js). Off: Copilot is not told about them.'; type = 'toggle' }
    @{ key = 'uiKitParts.print'; group = 'UI kit'; label = 'Print styles'; help = 'Pages print cleanly: buttons, filters and other screen-only parts stay off paper, panels and charts are not split across pages, and the light theme is used. A print button is a kit-btn with data-kit-print.'; type = 'toggle' }
    @{ key = 'uiKitPrintOrientation'; group = 'UI kit'; label = 'Print page orientation'; help = 'The paper orientation when a page is printed or saved as PDF (with print styles on): auto leaves it to the print dialog.'; type = 'select'; options = @('auto', 'landscape', 'portrait') }
    @{ key = 'uiKitWeekStart'; group = 'UI kit'; label = 'First day of the week'; help = 'Where "This week" starts in the period filter.'; type = 'select'; options = @('monday', 'sunday') }
    @{ key = 'uiKitParts.extras'; group = 'UI kit'; label = 'More components'; help = 'A switch, a dropdown menu, an icon toolbar, avatars, breadcrumbs, a stepper, collapsible sections, a key and value list, a timeline, sliders, a tag input, a kanban board, a calendar month, a bento grid, changing loading text and a success check (kit.css and kit.js; the switch, menu, toolbar, avatars, bento grid and success check adapted from kokonutui). Off: Copilot is not told about them.'; type = 'toggle' }
    @{ key = 'uiKitParts.tailwind'; group = 'UI kit'; label = 'Tailwind CSS'; help = 'In a project that uses Tailwind CSS: the kit''s colours, sizes, corners and shadows as Tailwind names (bg-kit-accent, text-kit-muted, rounded-kit, p-kit-4 ...; styles/kit/tailwind/), Copilot uses kit classes for components and Tailwind only with those names, and the checks report Tailwind''s own colours, made-up values, gradient text and decorative blur. Projects without Tailwind are not touched.'; type = 'toggle' }
    @{ key = 'uiKitParts.sql'; group = 'UI kit'; label = 'SQL in the page'; help = 'SQLite in the page (sql.js, MIT, about 1.3 MB, copied into a project only when a page uses it): KitSql turns the data a page has into tables to query with SQL. Works also in a page opened from disk.'; type = 'toggle' }
    @{ key = 'uiKitParts.python'; group = 'UI kit'; label = 'Python in the page'; help = 'Python in the page (Pyodide, Mozilla Public License 2.0, about 13 MB, copied into a project only when a page uses it): KitPython runs Python code on the page''s data, with Python''s standard library. Works only when the page is served (Open app), not when it is opened from disk. Off by default because of its size.'; type = 'toggle' }
    @{ key = 'uiKitParts.data'; group = 'UI kit'; label = 'File readers'; help = 'Read a file a person picks or drops in the page itself: CSV, TSV, JSON, Excel, Word and PowerPoint, with typed table values (kit-data.js; nothing is uploaded).'; type = 'toggle' }
    @{ key = 'uiKitParts.pdf'; group = 'UI kit'; label = 'PDF reading (pdf.js)'; help = 'With the file readers: the text of PDF files too, through pdf.js 3.11 (Mozilla, Apache 2.0). About 1.4 MB, copied into a project only when one of its pages loads pdf.js (styles/kit/vendor/pdfjs/).'; type = 'toggle' }
    @{ key = 'uiKitParts.react'; group = 'UI kit'; label = 'React versions'; help = 'In a React project: the interactive parts and charts as React components (styles/kit/react/).'; type = 'toggle' }
    @{ key = 'uiKitParts.designRules'; group = 'UI kit'; label = 'Design rules for Copilot'; help = 'Short rules on hierarchy, feedback, states, dialogs, forms, tables and charts, motion and accessibility, sent with interface work (also without the kit). A request to review the design also gets the review steps.'; type = 'toggle' }
    @{ key = 'uiKitParts.slopChecks'; group = 'UI kit'; label = 'Checks for generated-looking interfaces'; help = 'Warnings when a change adds gradient text, thick coloured side stripes, decorative blur or (with the kit) hard-coded colours instead of tokens.'; type = 'toggle' }
    @{ key = 'pacing.newChatSettleSec'; group = 'Timing'; label = 'Pause after a new chat (s)'; help = 'Wait after a new Copilot chat is ready, before typing.'; type = 'number'; min = 0; max = 30 }
    @{ key = 'pacing.beforeSendSec'; group = 'Timing'; label = 'Pause before Send (s)'; help = 'Wait between typing the prompt and pressing Send.'; type = 'number'; min = 0; max = 10 }
    @{ key = 'pacing.betweenPromptsSec'; group = 'Timing'; label = 'Gap after a reply (s)'; help = 'Minimum time between Copilot''s last reply and the next prompt.'; type = 'number'; min = 0; max = 60 }
    @{ key = 'stallSec'; group = 'Timing'; label = 'Hang after (s)'; help = 'No sign of a reply for this long: stop it and report no answer.'; type = 'number'; min = 30; max = 600 }
    @{ key = 'replyTimeoutSec'; group = 'Timing'; label = 'Reply timeout (s)'; help = 'Longest wait for one reply.'; type = 'number'; min = 60; max = 1800 }
    @{ key = 'messagesPerChat'; group = 'Timing'; label = 'Messages per chat'; help = 'Copilot''s limit per chat when it does not report one; StreamHub continues in a new chat before it.'; type = 'number'; min = 5; max = 300 }
    @{ key = 'agentTimeoutSec'; group = 'Timing'; label = 'Agent timeout (s)'; help = 'Longest wait for one answer from Researcher or Analyst; they often work for several minutes.'; type = 'number'; min = 300; max = 7200 }
    @{ key = 'actionRetries'; group = 'Changes and commands'; label = 'Retries when Copilot only explains'; help = 'How often a task is sent again when Copilot describes the change instead of writing action blocks.'; type = 'number'; min = 0; max = 5 }
    @{ key = 'maxRounds'; group = 'Changes and commands'; label = 'Rounds per message'; help = 'Most back-and-forth rounds (read, edit, run) for one message. A message that still changes files goes on past it, up to three times this number, and stops after two rounds without a change.'; type = 'number'; min = 1; max = 50 }
    @{ key = 'commandTimeoutSec'; group = 'Changes and commands'; label = 'Command timeout (s)'; help = 'Longest time a run command may take.'; type = 'number'; min = 10; max = 3600 }
    @{ key = 'autoApproveCommands'; group = 'Changes and commands'; label = 'Commands that run without asking'; help = 'One per line: a command that starts with one of these runs without asking you, for example npm test. Commands that delete or move files, or touch Microsoft 365, always ask, whatever is listed here.'; type = 'commands' }
    @{ key = 'fileChangeCounts'; group = 'Changes and commands'; label = 'Line counts in the Files tab'; help = 'last-change: only the most recent change since the project was opened, so earlier counts and "new" tags disappear at the next change and nothing shows right after a start; session: lines added and removed since the project was opened (also after a restart).'; type = 'select'; options = @('last-change', 'session') }
    @{ key = 'dataCopies'; group = 'Changes and commands'; label = 'Data copies follow their JSON'; help = 'A .js file that only wraps a JSON file''s data (for pages opened from disk) is rewritten from that JSON after each task and when a project opens, and Copilot changes the JSON instead of the copy. Off: such files are ordinary files.'; type = 'toggle' }
    @{ key = 'dataImport'; group = 'Changes and commands'; label = 'Prepare data files for Copilot'; help = 'CSV, TSV and Excel files in the project (and JSON files in Source/) are converted to data/NAME.json with typed values (numbers, dates, true/false) and a data/NAME.js copy a web page loads with a script tag, plus data/data-tools.js with helpers for filtering, totals and grouping. Copilot gets the columns and builds on these instead of writing its own parser. Made again when the source changes; a converted file someone changed is left alone.'; type = 'toggle' }
    @{ key = 'protectedPaths'; group = 'Changes and commands'; label = 'Protected files'; help = 'One per line: a file (config/prod.json), a folder ending in / (docs/) or a pattern (*.env). Copilot cannot write or edit them, and when a command changes or deletes one, StreamHub puts it back, like Source/.'; type = 'list'; placeholder = 'none' }
    @{ key = 'hooks'; group = 'Changes and commands'; label = 'Run the project''s hooks'; help = 'Your own commands from .streamhub/hooks.json at fixed moments: after Copilot edits a file, before a task counts as done, after a task (Automation > Hooks). Off: none run, the file stays as it is.'; type = 'toggle' }
    @{ key = 'chainScripts'; group = 'Changes and commands'; label = 'Scripts in chains'; help = 'approve-once: a person approves a script from Scripts/ the first time a chain runs it and again after it changed; after that it also runs from a schedule without asking. always-ask: every run. off: chains run runbooks and fetch prompts only. Scripts that delete data or use Microsoft 365 always need a person, and deleting or moving outside the project is never allowed.'; type = 'select'; options = @('approve-once', 'always-ask', 'off') }
    @{ key = 'reviewAfterChanges'; group = 'Checks and issues'; label = 'Copilot checks its big changes'; help = 'Ask Copilot to review changed files for leftovers, dead code and broken references.'; type = 'select'; options = @('big', 'always', 'off') }
    @{ key = 'reviewMinLines'; group = 'Checks and issues'; label = 'Big change from (lines)'; help = 'Changed lines from which a change counts as big.'; type = 'number'; min = 5; max = 1000 }
    @{ key = 'pageCheck'; group = 'Checks and issues'; label = 'Page check'; help = 'After web files change, open the page in a browser tab and report JavaScript errors and files that fail to load.'; type = 'select'; options = @('on', 'off') }
    @{ key = 'webBuild'; group = 'Checks and issues'; label = 'Built-in builder for React and TypeScript'; help = 'On a computer without Node.js or npm (often a locked-down work computer): StreamHub builds React and TypeScript apps itself, in a hidden Edge tab (esbuild and TypeScript, shipped with StreamHub), after every change to src/, and sends the errors and type errors back to Copilot. The app then runs from dist/app.js, also opened from disk; Scripts/Build-App.ps1 builds it while StreamHub is closed. Projects that build with npm of their own are left to npm. Off: Copilot writes plain HTML, CSS and JavaScript there.'; type = 'toggle' }
    @{ key = 'autoTests'; group = 'Checks and issues'; label = 'Run the project''s tests'; help = 'After a task that changed code, and when AGENTS.md has no verify: line, run the project''s own tests for the changed files (Pester for PowerShell; pytest or unittest when Python is installed; npm test when package.json has a test script). A failure goes back to Copilot to fix, at most twice.'; type = 'toggle' }
    @{ key = 'pageScreenshot'; group = 'Checks and issues'; label = 'Show Copilot the changed page'; help = 'With the page check: a screenshot of the changed page goes to Copilot once per task, to compare with what was asked (saved in .streamhub/Screenshots). Costs one more Copilot message when nothing else needs fixing.'; type = 'toggle' }
    @{ key = 'enforcement'; group = 'Checks and issues'; label = 'Enforcement'; help = 'How strictly the checks hold Copilot to them. Light: only problems that break a file go back, done waits once, failing tests are shown only. Standard: problems that break a file hold up done (twice), likely mistakes are said once, failing tests go back twice. Strict: likely mistakes hold up done too (once), three tries for errors and tests; costs more Copilot messages.'; type = 'select'; options = @('light', 'standard', 'strict') }
    @{ key = 'checks.generated'; group = 'Checks and issues'; label = 'Check for chat-answer leftovers'; help = 'Curly quotes, odd spaces, citation markers or HTML entities in code, TypeScript in .js, imports in functions, Python 2 print, // in CSS and similar mistakes typical of generated code.'; type = 'toggle' }
    @{ key = 'checks.tools'; group = 'Checks and issues'; label = 'Syntax check with installed tools'; help = 'When the file checks find nothing: node --check for JavaScript and python -m py_compile for Python, when they are installed.'; type = 'toggle' }
    @{ key = 'checks.powershell7'; group = 'Checks and issues'; label = 'Warn about PowerShell 7 features'; help = 'Commands and parameters a PowerShell 5.1 script cannot use (ConvertFrom-Json -AsHashtable, ForEach-Object -Parallel...). Off when your scripts run in PowerShell 7.'; type = 'toggle' }
    @{ key = 'checks.quality'; group = 'Checks and issues'; label = 'Quality notes'; help = 'Debug leftovers, swallowed errors, personal paths, very long files and similar notes. Never block a task: Copilot is told once.'; type = 'toggle' }
    @{ key = 'checks.contrast'; group = 'UI kit'; label = 'Readability and accessibility'; help = 'WCAG checks with the page check: the contrast of the visible text of a changed page against its background, in light and in dark (4.5:1 for normal text, 3:1 for large text and the edges of fields), click targets of at least 24 x 24 px, and images and buttons without a name; plus the UI kit''s colour pairs when tokens.css changes. Failures go to Copilot with what to change.'; type = 'toggle' }
    @{ key = 'evidence'; group = 'Checks and issues'; label = 'Task report (evidence)'; help = 'After a task that changed files, a short report of what was asked, what changed and which checks passed, in .streamhub/Evidence/ of the project; the chat links to it.'; type = 'select'; options = @('on', 'off') }
    @{ key = 'issues.enabled'; group = 'Checks and issues'; label = 'Issue detection'; help = 'Keep an index of problems in every project file (file checks, secrets, code health) and scan the changed files after each task.'; type = 'select'; options = @('on', 'off') }
    @{ key = 'issues.autoFix'; group = 'Checks and issues'; label = 'Fix automatically'; help = 'Problems a task adds that StreamHub sends back to Copilot to fix, one file at a time: error (broken syntax, missing files, typos), secret (keys and passwords in code), health (functions that are too complex). The rest is only reported.'; type = 'select'; options = @('error', 'error,secret', 'error,secret,health', 'none') }
    @{ key = 'issues.maxAttempts'; group = 'Checks and issues'; label = 'Fix attempts per file'; help = 'Fix tasks per file before its remaining problems are marked "gave up". Each attempt goes further: 1 the problems; 2 Copilot finds the cause first, with the file as it is now, a map of open brackets and what the last attempt changed (Think deeper); 3 fresh eyes in a new chat, from the last version without the problem (Think deeper). Copilot''s diagnosis is kept with a problem it gave up on.'; type = 'number'; min = 1; max = 5 }
    @{ key = 'chatHistory'; group = 'Privacy and retention'; label = 'Keep chat history'; help = 'Keep each project''s conversation on this computer (not in OneDrive), so it is back after a restart.'; type = 'toggle' }
    @{ key = 'saveReplyFrames'; group = 'Privacy and retention'; label = 'Keep raw Copilot replies'; help = 'The raw data of the last 30 replies, for diagnostics (in %LOCALAPPDATA%\CCBridge\replies). They can contain Microsoft 365 data.'; type = 'toggle' }
    @{ key = 'retention.historyCount'; group = 'Privacy and retention'; label = 'Earlier runbook results: kept'; help = 'Earlier results of each runbook in .streamhub/History/, kept per runbook (the latest is in Runbooks/Exports/). 0 = no limit.'; type = 'number'; min = 0; max = 1000 }
    @{ key = 'retention.historyDays'; group = 'Privacy and retention'; label = 'Earlier runbook results: days kept'; help = 'Earlier results older than this are removed. 0 = no limit.'; type = 'number'; min = 0; max = 3650 }
    @{ key = 'retention.evidenceCount'; group = 'Privacy and retention'; label = 'Task reports: kept'; help = 'Task reports (evidence) in .streamhub/Evidence/: what was asked, what changed, which checks passed. 0 = no limit.'; type = 'number'; min = 0; max = 10000 }
    @{ key = 'retention.evidenceDays'; group = 'Privacy and retention'; label = 'Task reports: days kept'; help = 'Task reports older than this are removed. 0 = no limit.'; type = 'number'; min = 0; max = 3650 }
    @{ key = 'retention.reviewsCount'; group = 'Privacy and retention'; label = 'Code reviews: reports kept'; help = 'Code review reports in .streamhub/reviews/ (a .md and a .json each). 0 = no limit.'; type = 'number'; min = 0; max = 1000 }
    @{ key = 'retention.reviewsDays'; group = 'Privacy and retention'; label = 'Code reviews: days kept'; help = 'Reports older than this are removed. 0 = no limit.'; type = 'number'; min = 0; max = 3650 }
    @{ key = 'retention.chartsCount'; group = 'Privacy and retention'; label = 'Charts: kept per item'; help = 'Charts saved from Researcher and Analyst answers in Runbooks/Exports/ (NAME-chart-....png), kept per runbook, fetch prompt or agent; the charts of one answer count as one. 0 = no limit.'; type = 'number'; min = 0; max = 1000 }
    @{ key = 'retention.chartsDays'; group = 'Privacy and retention'; label = 'Charts: days kept'; help = 'Saved charts older than this are removed. 0 = no limit.'; type = 'number'; min = 0; max = 3650 }
    @{ key = 'retention.screenshotsCount'; group = 'Privacy and retention'; label = 'Page screenshots: kept'; help = 'Screenshots from the page check in .streamhub/Screenshots/ (with their layout and the close-up of the changes, which count as one). 0 = no limit.'; type = 'number'; min = 0; max = 10000 }
    @{ key = 'retention.screenshotsDays'; group = 'Privacy and retention'; label = 'Page screenshots: days kept'; help = 'Screenshots older than this are removed. 0 = no limit.'; type = 'number'; min = 0; max = 3650 }
    @{ key = 'retention.backupsCount'; group = 'Privacy and retention'; label = 'Undo: change sets kept'; help = 'Backups for Undo, on this computer (not in OneDrive); the newest change set always stays. Fewer means older steps can no longer be undone. 0 = no limit.'; type = 'number'; min = 0; max = 10000 }
    @{ key = 'retention.backupsDays'; group = 'Privacy and retention'; label = 'Undo: days kept'; help = 'Change sets older than this are removed (the newest always stays). 0 = no limit.'; type = 'number'; min = 0; max = 3650 }
    @{ key = 'retention.chatEvents'; group = 'Privacy and retention'; label = 'Chat history: events kept'; help = 'The most chat events kept per project on this computer; the oldest go first.'; type = 'number'; min = 100; max = 20000 }
    @{ key = 'appWindow'; group = 'App'; label = 'Open StreamHub'; help = 'copilot-tab: as a tab in the Copilot window, ready for Edge''s Split screen; side-by-side: its own window, with Copilot on the right half of the screen; browser: in your default browser. Applies at the next start.'; type = 'select'; options = @('copilot-tab', 'side-by-side', 'browser') }
    @{ key = 'autoUpdate'; group = 'App'; label = 'Update automatically'; help = 'Installs a new StreamHub release only when a new instance of the app starts (start.cmd or the shortcut); the app that is running now is never updated. update.cmd updates by hand at any time.'; type = 'toggle' }
    @{ key = 'port'; group = 'App'; label = 'Web app port'; help = 'Where StreamHub runs (http://localhost:PORT). Moved automatically when another program uses it.'; type = 'info' }
    @{ key = 'cdpPort'; group = 'App'; label = 'Edge port (for Copilot)'; help = 'How StreamHub talks to Copilot in Edge. Moved automatically when another program uses it.'; type = 'info' }
    @{ key = 'resultCharBudget'; group = 'App'; label = 'Results per round (characters)'; help = 'Room for file contents and command output sent back to Copilot in one message.'; type = 'number'; min = 10000; max = 120000 }
    @{ key = 'promptCharBudget'; group = 'App'; label = 'Prompt size (characters)'; help = 'Largest message sent to Copilot (its page accepts up to 128000).'; type = 'number'; min = 20000; max = 125000 }
)

function Get-SettingValue($Obj, [string]$Key) {
    $o = $Obj
    foreach ($part in $Key.Split('.')) { if ($null -eq $o) { return $null }; $o = $o.$part }
    $o
}

function ConvertTo-CommandPattern([string]$Start) {
    # "npm test" -> a pattern that matches that command and anything after it.
    '^' + [regex]::Escape($Start.Trim()) + '(\s|$)'
}

function ConvertFrom-CommandPattern([string]$Pattern) {
    # The plain command start back from a pattern made above; other patterns are shown as written.
    $m = [regex]::Match($Pattern, '^\^(.+)\(\\s\|\$\)$')
    if ($m.Success) { [regex]::Unescape($m.Groups[1].Value) } else { $Pattern }
}

function Get-CCBridgeSettings {
    <# The adjustable settings with their current value, default and whether this machine changed it. #>
    param([string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $defaults = Get-Content (Join-Path $AppRoot 'config\harness.json') -Raw | ConvertFrom-Json
    $current = Get-CCBridgeConfig harness $AppRoot
    foreach ($d in $script:SettingDefs) {
        $def = Get-SettingValue $defaults $d.key; $cur = Get-SettingValue $current $d.key
        if ($d.type -eq 'commands') {
            $cur = @(@($cur) | Where-Object { $_ } | ForEach-Object { ConvertFrom-CommandPattern "$_" })
            $def = @(@($def) | Where-Object { $_ } | ForEach-Object { ConvertFrom-CommandPattern "$_" })
        }
        if ($d.type -eq 'toggle') { $cur = $(if ($null -eq $cur) { $true } else { [bool]$cur }); $def = $(if ($null -eq $def) { $true } else { [bool]$def }) }
        $o = [ordered]@{ key = $d.key; group = $d.group; label = $d.label; help = $d.help; type = $d.type; value = $cur; default = $def; custom = ("$(@($cur) -join "`n")" -ne "$(@($def) -join "`n")") }
        if ($d.type -eq 'commands' -or $d.type -eq 'list') { $o.value = @(@($cur) | Where-Object { $_ }); $o.default = @(@($def) | Where-Object { $_ }) }
        if ($d.placeholder) { $o.placeholder = $d.placeholder }
        if ($d.type -eq 'info') { $o.custom = $false }
        if ($d.type -eq 'number') { $o.min = $d.min; $o.max = $d.max } elseif ($d.type -eq 'select') { $o.options = $d.options }
        [pscustomobject]$o
    }
}

function Set-CCBridgeSetting {
    <# Validates and saves one adjustable setting in harness.local.json; $null resets it to the default.
       Returns the value now in effect. #>
    param([Parameter(Mandatory)][string]$Key, $Value, [string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $d = $script:SettingDefs | Where-Object { $_.key -eq $Key } | Select-Object -First 1
    if (-not $d) { throw "Unknown setting '$Key'." }
    if ($d.type -eq 'info') { throw "$($d.label) is set by StreamHub itself." }
    if ($d.type -eq 'commands') {
        # A list of command starts (or text with one per line); empty = none run without asking.
        $starts = @(@($Value) | ForEach-Object { "$_" -split "`r?`n" } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $Value = if ($null -eq $Value) { $null } else { , @($starts | ForEach-Object { ConvertTo-CommandPattern $_ }) }
    } elseif ($d.type -eq 'list') {
        # Lines of text (or a list); empty = none.
        $items = @(@($Value) | ForEach-Object { "$_" -split "`r?`n" } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $Value = if ($null -eq $Value) { $null } else { , @($items) }
    } elseif ($d.type -eq 'toggle') {
        if ($null -ne $Value) { $Value = "$Value" -in 'true', 'on', '1' }   # as text: "off" -in $true would be true
    } elseif ($null -ne $Value -and "$Value" -ne '') {
        if ($d.type -eq 'number') {
            $n = 0.0
            if (-not [double]::TryParse("$Value", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { throw "$($d.label) must be a number." }
            if ($n -lt $d.min -or $n -gt $d.max) { throw "$($d.label) must be between $($d.min) and $($d.max)." }
            $Value = if ($n -eq [Math]::Floor($n)) { [int]$n } else { $n }
        } elseif ($d.options -notcontains "$Value" -and -not ($d.key -eq 'responseMode' -and "$Value" -match '^pick:\S.{0,150}$')) {
            # (The response mode also takes pick:PATH, an option read from Copilot's own picker.)
            throw "$($d.label) must be one of: $($d.options -join ', ')."
        }
    } else { $Value = $null }
    $file = Join-Path $AppRoot 'config\harness.local.json'
    $obj = if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json } else { $null }
    if (-not $obj) { $obj = [pscustomobject]@{} }
    $parts = $Key.Split('.')
    $parent = $obj
    if ($parts.Count -eq 2) {
        if (-not $obj.($parts[0])) { $obj | Add-Member -Force -NotePropertyName $parts[0] -NotePropertyValue ([pscustomobject]@{}) }
        $parent = $obj.($parts[0])
    }
    $leaf = $parts[-1]
    if ($null -eq $Value) { $parent.PSObject.Properties.Remove($leaf) }
    else { $parent | Add-Member -Force -NotePropertyName $leaf -NotePropertyValue $Value }
    if ($parts.Count -eq 2 -and -not @($parent.PSObject.Properties).Count) { $obj.PSObject.Properties.Remove($parts[0]) }
    [IO.File]::WriteAllText($file, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Get-SettingValue (Get-CCBridgeConfig harness $AppRoot) $Key
}

function Test-DataCopiesOn([string]$AppRoot) {
    <# Setting dataCopies (on unless turned off): data copies follow their JSON (DataMirror.psm1).
       Read from disk, so every runspace sees a change at once. #>
    try { $v = (Get-CCBridgeConfig harness $AppRoot).dataCopies; ($null -eq $v) -or [bool]$v } catch { $true }
}

function Test-DataImportOn([string]$AppRoot) {
    <# Setting dataImport (on unless turned off): data files are converted for Copilot (DataImport.psm1). #>
    try { $v = (Get-CCBridgeConfig harness $AppRoot).dataImport; ($null -eq $v) -or [bool]$v } catch { $true }
}

$script:ScriptLanguage = @{}
function Get-ScriptLanguageMode {
    <# The language mode a script in this project folder runs in: FullLanguage, or ConstrainedLanguage
       when the computer's policy (AppLocker, WDAC) limits scripts from user folders such as OneDrive;
       then Add-Type and XamlReader are blocked and a WPF window app cannot run. Found once per folder by
       running a one-line script from the project's .streamhub folder; '' when it cannot be found. #>
    param([string]$ProjectRoot)
    if (-not $ProjectRoot) { return '' }
    if ($script:ScriptLanguage.ContainsKey($ProjectRoot)) { return $script:ScriptLanguage[$ProjectRoot] }
    $mode = ''
    try {
        $dir = Join-Path $ProjectRoot '.streamhub'
        $null = New-Item -ItemType Directory -Force -Path $dir
        $probe = Join-Path $dir 'language-mode.ps1'
        [IO.File]::WriteAllText($probe, '$ExecutionContext.SessionState.LanguageMode')
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $mode = "$(& $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe 2>$null)".Trim()
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch { $mode = '' }
    $script:ScriptLanguage[$ProjectRoot] = $mode
    $mode
}

function Test-UiKitPart([string]$Name, [string]$AppRoot) {
    <# Setting uiKitParts.NAME (interactive, charts, icons, data, sql, python, dashboard, extras, print, tailwind, pdf, react, designRules, slopChecks): on unless turned
       off. Read from disk, so every runspace sees a change at once. #>
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    # Python in the page is off unless switched on (13 MB); the other parts are on unless switched off.
    $default = $Name -ne 'python'
    try { $p = (Get-CCBridgeConfig harness $AppRoot).uiKitParts; $v = if ($p) { $p.$Name } else { $null }; if ($null -eq $v) { $default } else { [bool]$v } } catch { $default }
}

function Test-UiKitOn([string]$AppRoot) {
    <# Setting uiKit (on unless turned off): interface work uses the UI kit (templates/ui-kit). Read
       from disk, so every runspace sees a change at once. #>
    try { $v = (Get-CCBridgeConfig harness $AppRoot).uiKit; ($null -eq $v) -or [bool]$v } catch { $true }
}

function Test-CheckSwitch([string]$Name, [string]$AppRoot) {
    <# Setting checks.NAME (generated, tools, powershell7, quality): on unless turned off. Read from
       disk, kept until the settings files change, so every runspace (and Lint) sees a change. #>
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $stamp = ''
    foreach ($f in 'harness.json', 'harness.local.json') { $p = Join-Path $AppRoot "config\$f"; if (Test-Path -LiteralPath $p) { $stamp += "$((Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks);" } }
    if ($script:CheckSwitchStamp -ne $stamp) {
        $script:CheckSwitches = try { (Get-CCBridgeConfig harness $AppRoot).checks } catch { $null }
        $script:CheckSwitchStamp = $stamp
    }
    $v = if ($script:CheckSwitches) { $script:CheckSwitches.$Name } else { $null }
    ($null -eq $v) -or ([bool]$v -and "$v" -ne 'off')
}

function Reset-CCBridgeSettings {
    <# Puts every adjustable setting back to the app default (removes them from harness.local.json;
       other local values, such as the ports, stay). Returns the keys that were changed. #>
    param([string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $changed = @(Get-CCBridgeSettings $AppRoot | Where-Object custom | ForEach-Object { $_.key })
    # Ports are set by StreamHub itself (moved away from other programs): a reset keeps them.
    foreach ($d in @($script:SettingDefs | Where-Object { $_.type -ne 'info' })) { $null = Set-CCBridgeSetting $d.key $null $AppRoot }
    $changed
}

function Get-CCBridgeEnvironment {
    <# Facts that help diagnose a machine; no personal data. #>
    param([string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $harness = Get-CCBridgeConfig harness $AppRoot
    $sel = Get-CCBridgeConfig selectors $AppRoot
    [ordered]@{
        ccbridge = Get-CCBridgeVersion $AppRoot
        installKind = $(if (Test-Path (Join-Path $AppRoot '.git')) { 'git' } elseif (Test-Path (Join-Path $AppRoot 'version.txt')) { 'release' } else { 'copy' })
        powershell = $PSVersionTable.PSVersion.ToString()
        languageMode = $ExecutionContext.SessionState.LanguageMode.ToString()
        os = [Environment]::OSVersion.VersionString
        culture = (Get-Culture).Name
        edge = $(if ($edge) { (Get-Item $edge).VersionInfo.ProductVersion } else { 'not found' })
        oneDrive = [ordered]@{ commercial = [bool]$env:OneDriveCommercial; consumer = [bool]$env:OneDriveConsumer; oneDrive = [bool]$env:OneDrive
            used = $(if ($env:OneDriveCommercial -and (Test-Path $env:OneDriveCommercial)) { 'OneDriveCommercial' } elseif ($env:OneDrive -and (Test-Path $env:OneDrive)) { 'OneDrive' } elseif ($env:OneDriveConsumer -and (Test-Path $env:OneDriveConsumer)) { 'OneDriveConsumer' } else { 'none' }) }
        localOverrides = @(Get-ChildItem (Join-Path $AppRoot 'config') -Filter '*.local.json' -ErrorAction SilentlyContinue | ForEach-Object Name)
        settings = [ordered]@{ port = $harness.port; cdpPort = $harness.cdpPort; workIq = $harness.workIq; autoUpdate = $harness.autoUpdate; saveReplyFrames = $harness.saveReplyFrames; promptCharBudget = $harness.promptCharBudget; maxRounds = $harness.maxRounds }
        workIqToggleConfigured = [bool]$sel.workIq.toggle
    }
}

Export-ModuleMember -Function Get-ScriptLanguageMode, Test-DataImportOn, Test-UiKitPart, Test-UiKitOn, Test-CheckSwitch, Test-DataCopiesOn, Get-CCBridgeConfig, Get-CCBridgeVersion, Get-CCBridgeBuild, Set-CCBridgeLocalSetting, Get-CCBridgeEnvironment, Get-CCBridgeSettings, Set-CCBridgeSetting, Reset-CCBridgeSettings
