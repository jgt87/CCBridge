# Copilot's role follows the kind of task.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force

Describe 'Get-TaskKind' {
    It 'recognises coding tasks' {
        foreach ($t in @('Fix the bug in src/app.py', 'Add Pester tests and run the build', 'Create a PowerShell script that renames files',
                         'Refactor the React component', 'Why does expenses.ps1 fail?', 'Maak een functie die de totalen berekent')) {
            Get-TaskKind $t | Should Be 'coding'
        }
    }

    It 'recognises Microsoft 365 work without coding as an assistant task' {
        foreach ($t in @('Summarise my emails from today', 'What meetings do I have tomorrow?', 'Prepare an agenda for the Teams meeting with Anna',
                         'List the follow-ups from my chats this week', 'Welke vergaderingen heb ik morgen?', 'Zet mijn afspraken van vandaag op een rij')) {
            Get-TaskKind $t | Should Be 'assistant'
        }
    }

    It 'recognises tasks that need both' {
        Get-TaskKind 'Build a dashboard from the meetings in my calendar' | Should Be 'mixed'
        Get-TaskKind 'Write a script that exports my Outlook emails to CSV' | Should Be 'mixed'
    }

    It 'falls back to general' {
        Get-TaskKind 'Explain the difference between a lease and a loan' | Should Be 'general'
        Get-TaskKind '' | Should Be 'general'
    }
}

Describe 'Get-Instructions' {
    It 'gives each kind its role, with the human-in-the-loop rules always included' {
        $coding = Get-Instructions $root 'coding'
        $assistant = Get-Instructions $root 'assistant'
        $mixed = Get-Instructions $root 'mixed'
        $general = Get-Instructions $root 'general'
        $coding | Should Match '^You are an expert software developer'
        $assistant | Should Match '^You are the user''s personal assistant'
        $mixed | Should Match '^You are an expert software developer.*Microsoft 365 data'
        $general | Should Match '^You are a knowledgeable assistant'
        foreach ($i in $coding, $assistant, $mixed, $general) {
            $i | Should Match 'HUMAN IN THE LOOP'
            $i | Should Match 'ACTION BLOCKS are fenced'
            $i | Should Match 'RULES'
            $i | Should Not Match 'CCBridge'
        }
        $assistant | Should MatchExactly 'MICROSOFT 365 DATA'
        $mixed | Should MatchExactly 'MICROSOFT 365 DATA'
        $coding | Should Not MatchExactly 'MICROSOFT 365 DATA'
        $general | Should Not MatchExactly 'MICROSOFT 365 DATA'
    }

    It 'builds a short role switch for a different kind later in the chat' {
        $s = Get-RoleSwitch $root 'assistant'
        $s | Should Match '^For this request: You are the user''s personal assistant'
        $s | Should MatchExactly 'MICROSOFT 365 DATA'
        $s | Should Match 'still apply'
        $s | Should Not Match 'CCBridge'
    }
}
