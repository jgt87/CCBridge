# Commands made visible while they run (Executor Invoke-RunAction -OnProgress, Get-RunWaitState,
# Get-RunTail) and commands opened in a console window (lib/RunWindow.psm1; no window is opened here).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Executor', 'RunWindow') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'What a running command looks like' {
    It 'asks a question, waits without CPU, is quiet, or just runs' {
        Get-RunWaitState @('Building...', 'Do you want to continue? (y/N)') 4 $false | Should Be 'question'
        Get-RunWaitState @('? Enter a name for the new migration: ') 5 $false | Should Be 'question'
        Get-RunWaitState @('Press any key to continue . . .') 3 $false | Should Be 'question'
        Get-RunWaitState @('Do you want to continue? (y/N)') 1 $false | Should Be 'running'
        Get-RunWaitState @('compiling 12 files') 45 $true | Should Be 'stuck'
        Get-RunWaitState @('compiling 12 files') 45 $false | Should Be 'quiet'
        Get-RunWaitState @('compiling 12 files') 5 $true | Should Be 'running'
    }
    It 'shows the last version of a line a progress bar rewrites' {
        (@(Get-RunTail "start`n 10%`r 50%`r100%`ndone`n`n") -join '|') | Should Be 'start|100%|done'
        @(Get-RunTail ((1..50 | ForEach-Object { "line $_" }) -join "`n")).Count | Should Be 20
    }
}

Describe 'Output while a command runs' {
    It 'reports the output as it comes and still returns all of it' {
        $p = Join-Path $env:TEMP ('ccb-live-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $seen = New-Object Collections.Generic.List[object]
        $r = Invoke-RunAction $p "echo first & ping -n 3 127.0.0.1 >nul & echo second" -TimeoutSec 30 -OnProgress { param($pr) $seen.Add($pr) }
        $r.exitCode | Should Be 0
        $r.output | Should Match '(?s)first.*second'
        $seen.Count | Should BeGreaterThan 1
        @($seen | Where-Object { (@($_.lines) -join ' ') -match 'first' -and (@($_.lines) -join ' ') -notmatch 'second' }).Count | Should BeGreaterThan 0
        $seen[-1].state | Should Be 'running'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'A command in a console window' {
    It 'runs each line in the project, stops at the first failure, notes the exit code and waits for a key' {
        $b = New-RunWindowBatch 'C:\Proj\App' "npx prisma migrate dev`nnpm run build" 'C:\Temp\w.code'
        $b | Should Match '(?m)^cd /d "C:\\Proj\\App"'
        $b | Should Match '(?m)^cmd /d /s /c "npx prisma migrate dev"\r?$'
        $b | Should Match '(?m)^if not "%CCB_RC%"=="0" goto ccb_done'
        $b | Should Match '(?m)^>"C:\\Temp\\w\.code" echo %CCB_RC%'
        $b | Should Match '(?m)^pause >nul'
        $b | Should Match '(?m)^echo \^> npm run build'
    }
    It 'is running, finished with its code, or closed before the end' {
        $d = Join-Path $env:TEMP ('ccb-win-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
        $w = @{ codeFile = "$d\x.code"; batch = "$d\x.cmd"; process = [pscustomobject]@{ HasExited = $false } }
        (Get-RunWindowStatus $w).state | Should Be 'running'
        [IO.File]::WriteAllText("$d\x.code", "3`r`n")
        $s = Get-RunWindowStatus $w
        $s.state | Should Be 'finished'; $s.exitCode | Should Be 3
        Remove-Item "$d\x.code"
        $w.process = [pscustomobject]@{ HasExited = $true }
        (Get-RunWindowStatus $w).state | Should Be 'closed'
        Remove-Item $d -Recurse -Force
    }
    It 'refuses a command that deletes outside the project' {
        $p = Join-Path $env:TEMP ('ccb-win-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        { Start-RunWindow $p 'del /q ..\other\*.txt' } | Should Throw 'Not run'
        Remove-Item $p -Recurse -Force
    }
}
