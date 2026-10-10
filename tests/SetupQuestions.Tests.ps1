# The setup questions StreamHub asks only when a request triggers them (ProjectSetup.psm1 registry):
# each has a trigger on the request and the project's files, the answer the request states itself,
# the choices, and the context line its answer puts into every task. Made-up requests and projects.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'ProjectSetup', 'Prompts') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

$none = @{ build = ''; answers = @{} }
$pages = @('index.html', 'js/app.js', 'styles/kit/tokens.css')
$ids = { param($q) @(@($q.questions) | ForEach-Object { $_.id }) -join ',' }

Describe 'Which questions a request triggers' {
    It 'asks the kind of app for a new app without a stack, saves one the request names, and skips it for a page' {
        & $ids (Get-SetupQuestions 'Build an app that tracks our licences' @() $none) | Should Be 'appkind,persist'
        $q = Get-SetupQuestions 'Build a React app that tracks our licences' @() $none
        $q.stated.appkind | Should Be 'react'
        (& $ids $q) | Should Be 'persist'
        (Get-SetupQuestions 'Build a PowerShell window app for the team planning' @() $none).stated.appkind | Should Be 'desktop'
        (Get-SetupQuestions 'Make a command-line script that renames files' @() $none).stated.appkind | Should Be 'script'
        & $ids (Get-SetupQuestions 'Build a dashboard of the sales' @('Source/sales.csv') $none) | Should Be 'build'
        Get-SetupQuestions 'Build an app that lists the licences' @('index.html') $none | Should BeNullOrEmpty   # a project with code: the kind is settled
    }
    It 'asks where entered data stays only for apps that take input, and reads an answer in the request' {
        & $ids (Get-SetupQuestions 'Build a page where we enter the weekly numbers' @('Source/x.csv') $none) | Should Be 'build,persist'
        (Get-SetupQuestions 'Build a form that saves to localStorage' @() $none).stated.persist | Should Be 'browser'
        (Get-SetupQuestions 'Build a view-only report of the numbers' @('Source/x.csv') $none).stated.persist | Should Be 'none'
        (Get-SetupQuestions 'Add a page where users can add records; they download it as a JSON file' $pages $none).statedTurn.Keys -contains 'addto' | Should Be $false
        & $ids (Get-SetupQuestions 'Show the totals per region' @('Source/x.csv') $none) | Should Be ''
    }
    It 'asks how Microsoft 365 data reaches the app only when the request names such data' {
        & $ids (Get-SetupQuestions 'Build a dashboard of my Outlook meetings per week' @() $none) | Should Be 'build,m365data'
        (Get-SetupQuestions 'Build a dashboard of the Teams messages, refreshed daily by a runbook' @() $none).stated.m365data | Should Be 'runbook'
        (Get-SetupQuestions 'Build a dashboard from the Excel export of SharePoint list items' @() $none).stated.m365data | Should Be 'file'
        & $ids (Get-SetupQuestions 'Build a dashboard of the sales file' @('Source/sales.csv') $none) | Should Be 'build'
    }
    It 'asks who opens it when sharing comes up, and how to build without data' {
        & $ids (Get-SetupQuestions 'Build a dashboard of the sales to share with my colleagues' @('Source/sales.csv') $none) | Should Be 'build,audience'
        (Get-SetupQuestions 'Build a dashboard I post on SharePoint for the team' @('Source/sales.csv') $none).stated.audience | Should Be 'shared'
        & $ids (Get-SetupQuestions 'Build a dashboard with charts of the sales per region' @() $none) | Should Be 'build,sampledata'
        (Get-SetupQuestions 'Build a dashboard with sample data of the sales' @() $none).stated.sampledata | Should Be 'sample'
        & $ids (Get-SetupQuestions 'Build a dashboard of my calendar' @() $none) | Should Be 'build,m365data'   # Microsoft 365 data, not sample data
    }
    It 'asks the language for a Dutch request, and the extras only with the kit and a table or report' {
        & $ids (Get-SetupQuestions 'Maak een overzicht van de verkoop per regio' @('Source/x.csv') $none) | Should Be 'build,language'
        (Get-SetupQuestions 'Maak een overzicht van de verkoop, in het Engels' @('Source/x.csv') $none).stated.language | Should Be 'en'
        & $ids (Get-SetupQuestions 'Build a report of the sales' @('Source/x.csv') $none -AppRoot $root) | Should Match '(^|,)extras(,|$)'
        $q = Get-SetupQuestions 'Build a report of the sales with an export to Excel and a print view' @('Source/x.csv') $none -AppRoot $root
        $q.stated.extras | Should Be 'export,print'
    }
    It 'asks about personal details only when the data has such columns' {
        $p = Join-Path $env:TEMP ('ccb-setupq-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p '.streamhub') -Force | Out-Null
        try {
            $man = @{ items = @(@{ output = 'data/staff.json'; source = 'Source/staff.csv'; sheets = @(@{ name = 'staff'; rows = 3; columns = @(@{ name = 'Name'; type = 'text' }, @{ name = 'Email'; type = 'text' }, @{ name = 'Date'; type = 'date' }) }) }) }
            [IO.File]::WriteAllText((Join-Path $p '.streamhub\data-imports.json'), (ConvertTo-Json $man -Depth 6))
            $q = Get-SetupQuestions 'Build a dashboard of the staff' @('Source/staff.csv') $none -ProjectRoot $p
            & $ids $q | Should Be 'build,personal,language'   # a date column asks the formats too
            (Get-SetupQuestions 'Build a dashboard of the staff with names masked' @('Source/staff.csv') $none -ProjectRoot $p).stated.personal | Should Be 'mask'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'asks per request about recurring work, a new page and a rebuild, never a saved answer again' {
        $q = Get-SetupQuestions 'Give me every Monday the open tickets per team' @() $none
        & $ids $q | Should Be 'recurring'
        @($q.questions)[0].scope | Should Be 'request'
        (Get-SetupQuestions 'Give me the open tickets once, not every week' @() $none).statedTurn.recurring | Should Be 'once'
        & $ids (Get-SetupQuestions 'Add a new page with the totals per team' $pages $none) | Should Be 'addto'
        (Get-SetupQuestions 'Add a new page with the totals into the existing app' $pages $none).statedTurn.addto | Should Be 'existing'
        & $ids (Get-SetupQuestions 'Start over from scratch with a cleaner layout' $pages $none) | Should Be 'rebuild'
        & $ids (Get-SetupQuestions 'Start over from scratch, keep the old version alongside' $pages $none) | Should Be ''
        # A saved project answer is not asked again; a request-scope one is.
        $saved = @{ build = 'single'; answers = @{ audience = 'me' } }
        Get-SetupQuestions 'Build a dashboard to share with colleagues' @('index.html', 'Source/x.csv') $saved | Should BeNullOrEmpty
        & $ids (Get-SetupQuestions 'Start over from scratch' $pages $saved) | Should Be 'rebuild'
    }
    It 'asks how to start a big request, at most six questions per card, and reads a wish in the request' {
        $big = 'Build a complete app for the team: ' + ('with many parts and details, ' * 40)
        Test-BigRequest $big | Should Be $true
        Test-BigRequest 'Build a dashboard' | Should Be $false
        Test-BigRequest 'Build me a whole application for the planning' | Should Be $true
        $q = Get-SetupQuestions ($big + ' to share with colleagues, where we enter the numbers, from my Outlook calendar, with tables') @() $none -AppRoot $root
        @($q.questions).Count | Should Be 6
        (& $ids $q) | Should Match '^appkind,'
        (Get-SetupQuestions 'Build me a whole application for the planning, ask me questions first' @() $none).stated.bigtask | Should Be 'clarify'
    }
}

Describe 'Saved answers, their labels and their context lines' {
    $p = Join-Path $env:TEMP ('ccb-setupa-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    It 'keeps answers in project.json, lists them with labels, forgets one, and names them to Copilot' {
        $null = Save-ProjectSetup $p @{ answers = @{ appkind = 'react'; extras = 'export,print'; audience = 'shared' } }
        $s = Get-ProjectSetup $p
        $s.answers.appkind | Should Be 'react'
        $s.answers.extras | Should Be 'export,print'
        $list = @(Get-SetupAnswerList $p)
        ($list | ForEach-Object { $_.id }) -join ',' | Should Be 'appkind,audience,extras'
        ($list | Where-Object id -eq 'extras').label | Should Be 'Extras for tables and reports: Export to CSV or Excel, A print view'
        Get-SetupAnswerLabel 'appkind' 'react' | Should Be 'What kind of app is this: React app'
        $ctx = Format-ProjectSetupContext $p
        $ctx | Should Match '- App kind: a React app'
        $ctx | Should Match '- Audience: colleagues open it from a SharePoint or OneDrive folder'
        $ctx | Should Match '- Extras the user wants: an export button per table \(KitData.toCsv/download\); a print view'
        $null = Save-ProjectSetup $p @{ answers = @{ audience = '' } }
        (Get-ProjectSetup $p).answers.ContainsKey('audience') | Should Be $false
        Format-ProjectSetupContext $p | Should Not Match 'Audience'
        # Request-scope answers come with the turn only, and a runbook wish goes before the request.
        $turn = Format-ProjectSetupContext $p @{ rebuild = 'alongside'; recurring = 'runbook' }
        $turn | Should Match '- Start over in a new folder v2/'
        $turn | Should Match 'wants this as a runbook'
        Get-SetupTextPrefix @{ recurring = 'runbook' } | Should Match '^Make this a runbook'
        Get-SetupTextPrefix @{ recurring = 'once' } | Should Be ''
        # The kind of app brings its rules.
        $ctx = @{ Traits = @(); Paths = @('index.html'); Build = ''; Live = $false; Answers = @{ appkind = 'react' } }
        @(& (Get-Module Prompts) { param($c) Get-PromptModules -Text 'Change the header' -Context $c } $ctx) -contains 'rules:react' | Should Be $true
        $ctx.Answers = @{ appkind = 'desktop' }
        @(& (Get-Module Prompts) { param($c) Get-PromptModules -Text 'Change the header' -Context $c } $ctx) -contains 'rules:psgui' | Should Be $true
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
