# A new Copilot chat when the work moves to another part of the project (lib/ChatScope.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\ChatScope.psm1') -Force
Import-Module (Join-Path $root 'lib\Imports.psm1') -Force

function Add-File($p, $rel, $text) { $full = Join-Path $p $rel; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, $text) }
function New-ScopeProject {
    $p = Join-Path $env:TEMP ('ccb-scope-' + [guid]::NewGuid().ToString('N'))
    Add-File $p 'src/calendar/CalendarView.js' "import { formatDay } from '../shared/dates.js';`nexport function CalendarView() { return formatDay(1); }`n"
    Add-File $p 'src/calendar/calendar.css' ".day { color: grey; }`n"
    Add-File $p 'src/shared/dates.js' "export function formatDay(d) { return 'day ' + d; }`n"
    Add-File $p 'src/expenses/ExpenseList.js' "export function ExpenseList() { return []; }`n"
    Add-File $p 'Scripts/export-week.ps1' "Get-Date`n"
    Add-File $p 'index.html' '<script type="module" src="src/calendar/CalendarView.js"></script>'
    $null = Update-ImportIndex $p
    $p
}

Describe 'Get-FileArea' {
    It 'groups files by the part of the project they belong to' {
        Get-FileArea 'src/calendar/components/Day.tsx' | Should Be 'src/calendar'
        Get-FileArea 'Scripts/export.ps1' | Should Be 'Scripts'
        Get-FileArea 'index.html' | Should Be '(root)'
        Get-FileArea 'docs/guide/setup.md' | Should Be 'docs'
    }
}

Describe 'Get-NamedFiles' {
    It 'finds files a message names by path, name, name without extension, or folder' {
        $files = @('src/calendar/CalendarView.js', 'src/expenses/ExpenseList.js', 'src/shared/utils.js', 'index.html')
        Get-NamedFiles 'Add a total row to ExpenseList' $files | Should Be 'src/expenses/ExpenseList.js'
        Get-NamedFiles 'Look at @src/calendar/CalendarView.js please' $files | Should Be 'src/calendar/CalendarView.js'
        @(Get-NamedFiles 'Tidy up src/expenses/ a bit' $files) | Should Be @('src/expenses/ExpenseList.js')
        @(Get-NamedFiles 'Clean up the utils' $files).Count | Should Be 0   # generic names do not count
        @(Get-NamedFiles 'Make it faster' $files).Count | Should Be 0
    }
}

Describe 'Test-ChatSwitch' {
    It 'starts a new chat when the message is about another part, not when it stays or continues' {
        $p = New-ScopeProject
        try {
            $chat = @('src/calendar/CalendarView.js', 'src/calendar/calendar.css')
            $r = Test-ChatSwitch $p 'Add a total row to ExpenseList' $chat
            $r.switch | Should Be $true
            $r.to | Should Be 'src/expenses'
            @($r.from) -contains 'src/calendar' | Should Be $true
            # Same part of the project, or a file connected through imports: the same chat.
            (Test-ChatSwitch $p 'Make the calendar.css days bold' $chat).switch | Should Be $false
            (Test-ChatSwitch $p 'Change the format in dates.js' $chat).switch | Should Be $false
            # A follow-up keeps the chat even when it names other files.
            (Test-ChatSwitch $p 'Also add a total row to ExpenseList' $chat).switch | Should Be $false
            (Test-ChatSwitch $p 'Now fix it in ExpenseList too' $chat).switch | Should Be $false
            # Nothing named, or nothing worked on yet: no decision to make.
            (Test-ChatSwitch $p 'Make the header blue' $chat).switch | Should Be $false
            (Test-ChatSwitch $p 'Add a total row to ExpenseList' @()).switch | Should Be $false
            # A script in another folder is another part.
            (Test-ChatSwitch $p 'Update export-week.ps1 to include Friday' $chat).switch | Should Be $true
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
