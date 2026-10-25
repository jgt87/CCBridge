# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests\RunbookFromChat.Tests.ps1
# Save a request as a runbook: the last request of the chat, whether it can become a runbook, and
# the fixed text that asks Copilot to write one (routed as a request to create a runbook).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
Import-Module (Join-Path $root 'lib\Runbook.psm1') -Force
Import-Module (Join-Path $root 'lib\RunbookFromChat.psm1') -Force

function New-Ev([string]$Type, [hashtable]$Data = @{}) { $Data.type = $Type; [pscustomobject]$Data }

Describe 'The last request of the chat' {
    It 'is the last user message, with the kind it was sent as' {
        $ev = @(
            (New-Ev 'user' @{ text = 'first request' }), (New-Ev 'kind' @{ taskKind = 'project' }),
            (New-Ev 'user' @{ text = 'List my meetings for next week with their organisers'; at = '2026-10-25T10:00:00' }), (New-Ev 'kind' @{ taskKind = 'assistant' }),
            (New-Ev 'assistant' @{ text = 'Here they are' }), (New-Ev 'status' @{ text = 'done' })
        )
        $r = Get-LastChatRequest $ev
        $r.text | Should Be 'List my meetings for next week with their organisers'
        $r.kind | Should Be 'assistant'
        $r.at | Should Be '2026-10-25T10:00:00'
    }

    It 'reads saved events and live ones alike (objects or hashtables)' {
        $ev = @(@{ type = 'user'; text = 'Summarise the sales file'; seq = 3 }, @{ type = 'kind'; taskKind = 'project'; seq = 4 })
        (Get-LastChatRequest $ev).kind | Should Be 'project'
    }

    It 'leaves out the texts the cards send and starts after a cleared history or another project' {
        $ev = @((New-Ev 'user' @{ text = 'Make a report of my mail' }), (New-Ev 'user' @{ text = "Build this now`nRequest: x" }), (New-Ev 'user' @{ text = '   ' }))
        (Get-LastChatRequest $ev).text | Should Be 'Make a report of my mail'
        $null -eq (Get-LastChatRequest @((New-Ev 'user' @{ text = 'old' }), (New-Ev 'history-cleared'))) | Should Be $true
        $null -eq (Get-LastChatRequest @((New-Ev 'user' @{ text = 'old' }), (New-Ev 'project' @{ name = 'B' }))) | Should Be $true
        $null -eq (Get-LastChatRequest @()) | Should Be $true
        (Get-LastChatRequest @((New-Ev 'user' @{ text = 'a question' }))).kind | Should Be ''
    }
}

Describe 'Whether the last request can be saved as a runbook' {
    It 'refuses when there is none' {
        $r = Test-RunbookFromChatAllowed $null
        $r.ok | Should Be $false
        $r.reason | Should Be 'none'
        $r.message | Should Match 'no earlier request'
    }

    It 'refuses a request about runbooks itself (the runbook rules'' words, a run, a runbook file)' {
        (Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'Change the meetings runbook to include Teams'; kind = 'project' })).reason | Should Be 'runbook'
        (Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'Pas het draaiboek aan'; kind = '' })).reason | Should Be 'runbook'
        (Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'meetings'; kind = 'runbook' })).reason | Should Be 'runbook'
        (Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'Open Runbooks/meetings.runbook.md'; kind = 'project' })).reason | Should Be 'runbook'
    }

    It 'refuses plain chat, by the kind it was sent as or else by Get-TaskKind' {
        $r = Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'Hello, how are you today?'; kind = 'chat' })
        $r.reason | Should Be 'chat'
        $r.message | Should Match 'plain chat'
        (Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'Tell me a joke'; kind = '' })).reason | Should Be 'chat'
    }

    It 'allows chat that asks for online information, and work on data, mail or files' {
        (Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'What are the latest release notes of PowerShell online'; kind = 'chat' })).ok | Should Be $true
        (Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'List my meetings for next week'; kind = 'assistant' })).ok | Should Be $true
        (Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'Summarise the emails from Ann this week'; kind = '' })).ok | Should Be $true
        (Test-RunbookFromChatAllowed ([pscustomobject]@{ text = 'Make a summary of the sales file'; kind = '' })).ok | Should Be $true
    }
}

Describe 'The request that asks Copilot for the runbook' {
    $earlier = 'Please list my meetings for next week with their organisers and the agenda'
    $text = Get-RunbookFromChatRequest $earlier -Existing @('weekly-mail')

    It 'proposes a name from the request''s first words, unique among the project''s runbooks' {
        Get-RunbookFromChatName $earlier | Should Be 'list-my-meetings-for-next-week'
        Get-RunbookFromChatName $earlier -Existing @('list-my-meetings-for-next-week') | Should Be 'list-my-meetings-for-next-week-2'
        Get-RunbookFromChatName 'Kun je de omzetcijfers per regio samenvatten' | Should Be 'de-omzetcijfers-per-regio-samenvatten'
        Get-RunbookFromChatName '???' | Should Be 'saved-request'
        (Get-RunbookFromChatName 'Summarise internationalisation-requirements documentation-overview accessibility-guidelines thoroughly').Length | Should Not BeGreaterThan 40
    }

    It 'quotes the earlier request, names the file and says not to run it now' {
        $text | Should Match '(?m)^Write a runbook that does this earlier request'
        $text | Should Match ("(?m)^---`n" + [regex]::Escape($earlier) + "`n---$")
        $text | Should Match 'Runbooks/list-my-meetings-for-next-week\.runbook\.md'
        $text | Should Match 'output: Runbooks/Exports/list-my-meetings-for-next-week\.json'
        $text | Should Match 'Do not run the runbook now'
        $text | Should Not Match 'CCBridge'
        $text | Should Not Match '(?m)^>'
    }

    It 'is never taken as a request to run a runbook, even when it names one' {
        $books = @(
            [pscustomobject]@{ name = 'list-my-meetings-for-next-week'; title = 'Meetings next week'; path = 'Runbooks/list-my-meetings-for-next-week.runbook.md' },
            [pscustomobject]@{ name = 'meetings'; title = 'Meetings'; path = 'Runbooks/meetings.runbook.md' }
        )
        $null -eq (Get-RunbookRunRequest $text $books) | Should Be $true
        $null -eq (Get-RunbookRunRequest (Get-RunbookFromChatRequest 'run the export of my mail') $books) | Should Be $true
    }

    It 'gets the runbook rules and is read as a request to change files' {
        $ctx = @{ Paths = @('index.html', 'Runbooks/weekly-mail.runbook.md'); Traits = @('code', 'web') }
        @(Get-PromptModules $text $ctx) -contains 'rules:runbook' | Should Be $true
        @(Get-PromptModules (Get-RunbookFromChatRequest 'Summarise the sales file') @{ Paths = @(); Traits = @() }) -contains 'rules:runbook' | Should Be $true
        Get-TaskIntent $text | Should Be 'change'
        Get-TaskIntent (Get-RunbookFromChatRequest 'What changed in my inbox today?') | Should Be 'change'
        Get-TaskKind $text | Should Not Be 'chat'
    }
}
