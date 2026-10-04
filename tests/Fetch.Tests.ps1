# Saved fetch prompts: prompt files, answer files and how a fetch is sent to Copilot.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Fetch.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force

function New-TempProject {
    $dir = Join-Path $env:TEMP ('ccb-fetch-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $dir
}

Describe 'ConvertTo-FetchName' {
    It 'makes a file-safe name' {
        ConvertTo-FetchName 'Meetings today!' | Should BeExactly 'meetings-today'
        ConvertTo-FetchName '  Open PRs / team A ' | Should BeExactly 'open-prs-team-a'
    }
    It 'refuses a name without letters or digits' {
        { ConvertTo-FetchName '***' } | Should Throw
    }
}

Describe 'Save-FetchPrompt and Get-FetchPrompts' {
    It 'saves a prompt file and lists it without an answer yet' {
        $p = New-TempProject
        $item = Save-FetchPrompt $p 'Meetings today' 'List my meetings for today with times and attendees.'
        $item.name | Should BeExactly 'meetings-today'
        $item.output | Should BeExactly 'Runbooks/Exports/meetings-today.md'
        $item.fetchedAt | Should BeNullOrEmpty
        Test-Path (Join-Path $p 'Runbooks\meetings-today.prompt.md') | Should Be $true
        @(Get-FetchPrompts $p).Count | Should Be 1
        Remove-Item $p -Recurse -Force
    }
    It 'refuses an empty prompt' {
        $p = New-TempProject
        { Save-FetchPrompt $p 'x' '   ' } | Should Throw
        Remove-Item $p -Recurse -Force
    }
}

Describe 'Format-FetchResult and Save-FetchResult' {
    It 'writes the answer with when it was fetched and its sources, and reads the time back' {
        $p = New-TempProject
        $null = Save-FetchPrompt $p 'meetings-today' 'List my meetings for today.'
        $when = [datetime]'2026-10-02 08:15'
        $refs = @([pscustomobject]@{ title = 'Weekly sync'; url = $null; kind = 'meeting' }, [pscustomobject]@{ title = 'Agenda'; url = 'https://example.com/a'; kind = 'file' })
        $content = Format-FetchResult -Name 'meetings-today' -Reply '- 09:00 Weekly sync' -When $when -References $refs
        $content | Should Match '^# meetings-today'
        $content | Should Match '_Fetched 2026-10-02 08:15'
        $content | Should Match '- \[Agenda\]\(https://example.com/a\)'
        $content | Should Not Match 'CCBridge'
        Save-FetchResult $p 'meetings-today' $content | Should BeExactly 'Runbooks/Exports/meetings-today.md'
        $item = Get-FetchPrompts $p | Select-Object -First 1
        $item.fetchedAt | Should BeExactly '2026-10-02T08:15:00'
        $item.outputSize -gt 0 | Should Be $true
        Remove-Item $p -Recurse -Force
    }
    It 'keeps the answer it replaces in .streamhub/History/' {
        $p = New-TempProject
        $null = Save-FetchResult $p 'today' 'first'
        $null = Save-FetchResult $p 'today' 'second'
        [IO.File]::ReadAllText((Join-Path $p 'Runbooks\Exports\today.md')) | Should BeExactly 'second'
        $old = @(Get-ChildItem (Join-Path $p '.streamhub\History') -Filter 'today-*.md')
        $old.Count | Should Be 1
        [IO.File]::ReadAllText($old[0].FullName) | Should BeExactly 'first'
        Remove-Item $p -Recurse -Force
    }
}

Describe 'Fetch prompts sent to Copilot' {
    It 'adds only the fetch note to a general fetch' {
        $m = New-PromptMessage -AppRoot $root -Kind 'fetch' -Text 'Latest PowerShell 7 version?' -Sent (New-Object 'System.Collections.Generic.HashSet[string]')
        $m | Should Match 'saved as a file'
        $m | Should Match 'Request: Latest PowerShell 7 version\?$'
        $m | Should Not Match 'SEARCH|CCBridge'
    }
    It 'adds the assistant role and the read-only rule to a Microsoft 365 fetch' {
        $m = New-PromptMessage -AppRoot $root -Kind 'fetch-m365' -Text 'My meetings today' -Sent (New-Object 'System.Collections.Generic.HashSet[string]')
        $m | Should Match 'personal assistant'
        $m | Should Match 'only to read it'
        $m | Should Match 'saved as a file'
    }
}
