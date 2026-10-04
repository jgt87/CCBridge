# Agents with project files, and agents in runbooks and fetch prompts (Agent.psm1, Fetch.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Fetch.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force

function New-AgentProject {
    $p = Join-Path $env:TEMP ('ccb-agf-' + [guid]::NewGuid().ToString('N'))
    foreach ($f in 'Source\sales.csv', 'data\costs.csv', '.streamhub\issues.json') {
        $full = Join-Path $p $f; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, 'month,units')
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'Runbooks') | Out-Null
    $p
}

Describe 'Attachments for agents' {
    It 'attaches @path project files and names them in the text' {
        $p = New-AgentProject
        try {
            $a = Get-AgentAttachments $p 'Use @Source/sales.csv and @data\costs.csv, not @missing.csv or @.streamhub/issues.json. Mail me@example.com'
            @($a.names) -join '|' | Should Be 'Source/sales.csv|data/costs.csv'
            @($a.files).Count | Should Be 2
            $a.text | Should Match '`sales\.csv` \(attached\) and `costs\.csv` \(attached\)'
            $a.text | Should Match '@missing\.csv'                # not a project file: left as typed
            $a.text | Should Match '@\.streamhub/issues\.json'
            $a.text | Should Match 'me@example\.com'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'refuses StreamHub records and missing files' {
        $p = New-AgentProject
        try {
            { Resolve-AgentFiles $p @('.streamhub/issues.json') } | Should Throw
            { Resolve-AgentFiles $p @('nope.csv') } | Should Throw
            @(Resolve-AgentFiles $p @('Source/sales.csv', 'Source/sales.csv')).Count | Should Be 1
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'reads the agent and files header lines' {
        $s = Get-AgentSpec @{ agent = 'Analyst'; files = 'Source/sales.csv, data/costs.csv' }
        $s.agent | Should BeExactly 'Analyst'
        @($s.files).Count | Should Be 2
        (Get-AgentSpec @{ agent = 'someone' }).agent | Should Be ''
        (Get-AgentSpec $null).agent | Should Be ''
    }
}

Describe 'Fetch prompts with an agent' {
    It 'reads and keeps the agent and files lines' {
        $p = New-AgentProject
        try {
            $null = Save-FetchPrompt $p 'sales' 'Monthly revenue please.' -Agent analyst -Files 'Source/sales.csv'
            $it = Get-FetchPrompts $p | Where-Object name -eq 'sales'
            $it.agent | Should Be 'analyst'
            $it.files | Should Be 'Source/sales.csv'
            # Saved again from a form that does not send them: they stay.
            $null = Save-FetchPrompt $p 'sales' 'Monthly revenue, please.' -Sources web
            $it = Get-FetchPrompts $p | Where-Object name -eq 'sales'
            $it.agent | Should Be 'analyst'
            $it.sources | Should Be 'web'
            { Save-FetchPrompt $p 'x' 'y' -Agent 'boss' } | Should Throw
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Runbooks and fetch prompts with an agent (Copilot mocked)' {
    $config = Get-CCBridgeConfig harness $root
    Mock -ModuleName Agent Start-NewChat { }
    Mock -ModuleName Agent Save-AgentCharts { @() }
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, [string]$Message, [string]$Agent, [switch]$Long, [string[]]$Files)
        $global:ccbAgentSent += , @{ text = $Message; agent = $Agent; long = [bool]$Long; files = @($Files) }
        $n = $global:ccbAgentSent.Count
        if ($global:ccbPlanFirst -and $n -eq 1) { return [pscustomobject]@{ Result = 'Success'; Text = 'My plan. Which period?'; Agent = 'Researcher'; IsPlan = $true; References = @() } }
        [pscustomobject]@{ Result = 'Success'; Text = "``````json`n{""items"":[{""name"":""a""}]}`n``````"; Agent = $global:ccbAgentName; IsPlan = $false; References = @() }
    }

    It 'sends a runbook to its agent with its files, and answers a research plan with go ahead' {
        $p = New-AgentProject
        try {
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\gens.runbook.md'), "---`ntitle: Generators`noutput: Runbooks/Exports/gens.json`nitemsKey: items`nagent: researcher`nfiles: Source/sales.csv`n---`nList generators as JSON.")
            $global:ccbAgentSent = @(); $global:ccbPlanFirst = $true; $global:ccbAgentName = 'Researcher'
            $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p
            Invoke-RunbookJob $s 'gens'
            $global:ccbAgentSent[0].agent | Should Be 'Researcher'
            $global:ccbAgentSent[0].long | Should Be $true
            @($global:ccbAgentSent[0].files)[0] | Should Match 'sales\.csv$'
            $global:ccbAgentSent[1].agent | Should Be ''                         # the go-ahead stays in the agent's chat
            $global:ccbAgentSent[1].text | Should Match '^Proceed with your plan'
            $global:ccbAgentSent[1].long | Should Be $true
            Test-Path (Join-Path $p 'Runbooks\Exports\gens.json') | Should Be $true
            (@($s.Events | Where-Object type -eq 'runbook')).Count | Should Be 1
            # The header lines are not placeholders in the text sent.
            $global:ccbAgentSent[0].text | Should Not Match 'Source/sales\.csv'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'sends a fetch prompt to Analyst and notes when Copilot answered itself' {
        $p = New-AgentProject
        try {
            $null = Save-FetchPrompt $p 'sales' 'Monthly revenue please.' -Agent analyst -Files 'Source/sales.csv'
            $global:ccbAgentSent = @(); $global:ccbPlanFirst = $false; $global:ccbAgentName = ''
            $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p
            Invoke-FetchJob $s 'sales'
            $global:ccbAgentSent[0].agent | Should Be 'Analyst'
            @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match 'came from Copilot itself, not from Analyst' }).Count | Should Be 1
            (@($s.Events | Where-Object type -eq 'fetch')).Count | Should Be 1
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'runs a runbook without an agent as before' {
        $p = New-AgentProject
        try {
            [IO.File]::WriteAllText((Join-Path $p 'Runbooks\plain.runbook.md'), "---`ntitle: Plain`noutput: Runbooks/Exports/plain.json`nitemsKey: items`n---`nList as JSON.")
            $global:ccbAgentSent = @(); $global:ccbPlanFirst = $false; $global:ccbAgentName = ''
            $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p
            Invoke-RunbookJob $s 'plain'
            $global:ccbAgentSent[0].agent | Should Be ''
            $global:ccbAgentSent[0].long | Should Be $false
            @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match 'came from' }).Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
