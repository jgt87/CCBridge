# Commands that need a terminal to ask questions (Executor Get-InteractiveNote, Agent
# Get-StepFailureInfo RUN-INTERACTIVE): StreamHub runs commands without one, so the card and Copilot
# get that cause instead of the generic "a tool is missing" reasons.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$prisma = @'
Environment variables loaded from .env
Prisma schema loaded from prisma\schema.prisma
Datasource "db": SQLite database "app.db" at "file:../data/app.db"

Error: Prisma Migrate has detected that the environment is non-interactive, which is not supported.

`prisma migrate dev` is an interactive command designed to create new migrations and evolve the database in development.
'@

Describe 'Commands that need a terminal' {
    It 'recognises a tool that refuses to run without a terminal, and says what to do instead' {
        $n = Get-InteractiveNote $prisma
        $n | Should Match 'needs an interactive terminal to ask questions'
        $n | Should Match 'form the tool offers for scripts'
        $n | Should Match 'exact command to run in their own terminal'
        Get-InteractiveNote "Traceback (most recent call last):`nEOFError: EOF when reading a line" | Should Not BeNullOrEmpty
        Get-InteractiveNote 'Error: stdin is not a tty' | Should Not BeNullOrEmpty
    }
    It 'says nothing for other failures' {
        Get-InteractiveNote "npm error code ETIMEDOUT" | Should BeNullOrEmpty
        Get-InteractiveNote "'prisma' is not recognized as an internal or external command" | Should BeNullOrEmpty
    }
    It 'gives the card the terminal reason instead of the generic ones' {
        $why = & (Get-Module Agent) { param($o) Get-StepFailureInfo 'run' "ran: exit code 1 exit code 1`n$o`n$(Get-InteractiveNote $o)" } $prisma
        $why.code | Should Be 'RUN-INTERACTIVE'
        $why.reasons[0] | Should Match 'StreamHub runs commands without a terminal'
        (& (Get-Module Agent) { Get-StepFailureInfo 'run' 'ran: exit code 1 some other error' }).code | Should Be 'RUN-FAILED'
    }
    It 'tells Copilot up front that commands cannot answer prompts' {
        [IO.File]::ReadAllText((Join-Path $root 'prompts\actions-run.md')) | Should Match 'no terminal: use non-interactive forms'
    }
}
