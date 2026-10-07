# "Open in a window": a command run in a real console window, where the person can watch it and
# answer its questions (commands StreamHub runs itself have no terminal, so prompts cannot be
# answered). The window runs a small batch file that changes to the project folder, runs the
# command, writes its exit code to a file and waits for a key. StreamHub only learns the exit code;
# the output stays in the window. Started by the person from a run card (Server /api/run/window).

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Executor') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

function Get-RunWindowDir { Join-Path $env:LOCALAPPDATA 'CCBridge\run-windows' }

function New-RunWindowBatch {
    <# The batch file's text: title, the command echoed, each line run in turn (stopping at the first
       failure, like a run here), the exit code written to $CodeFile, then a pause. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string]$CodeFile)
    $esc = { param($t) $t -replace '([&|<>^%])', '^$1' }
    $lines = @($Command.Replace("`r`n", "`n").Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('@echo off')
    [void]$sb.AppendLine('title StreamHub: ' + (& $esc ($lines[0].Substring(0, [Math]::Min(60, $lines[0].Length)))))
    [void]$sb.AppendLine('cd /d "' + $ProjectRoot + '"')
    [void]$sb.AppendLine('set "CCB_RC=0"')
    foreach ($l in $lines) {
        [void]$sb.AppendLine('echo ^> ' + (& $esc $l))
        # In a cmd of its own (same window, so prompts still work): an exit in the command ends that
        # cmd, not this batch, which still notes the code and waits.
        [void]$sb.AppendLine('cmd /d /s /c "' + $l + '"')
        [void]$sb.AppendLine('set "CCB_RC=%errorlevel%"')
        [void]$sb.AppendLine('if not "%CCB_RC%"=="0" goto ccb_done')
    }
    [void]$sb.AppendLine(':ccb_done')
    [void]$sb.AppendLine('>"' + $CodeFile + '" echo %CCB_RC%')
    [void]$sb.AppendLine('echo.')
    [void]$sb.AppendLine('echo Finished with exit code %CCB_RC%. StreamHub has noted it. Press a key to close this window.')
    [void]$sb.AppendLine('pause >nul')
    $sb.ToString()
}

function Start-RunWindow {
    <# Opens the console window for $Command in the project. Returns @{ id; pid; codeFile; batch;
       started } or throws when the command is not allowed (deleting or moving outside the project). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Command)
    if (-not $Command.Trim()) { throw 'No command to run' }
    $outside = Test-DeleteScope $ProjectRoot $Command
    if ($outside) { throw "Not run: $outside" }
    $dir = Get-RunWindowDir
    $null = New-Item -ItemType Directory -Force -Path $dir
    $id = 'win-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $codeFile = Join-Path $dir "$id.code"
    $batch = Join-Path $dir "$id.cmd"
    # Batch files are read in the console's code page: keep them to the characters it has.
    [IO.File]::WriteAllText($batch, (New-RunWindowBatch $ProjectRoot $Command $codeFile), [Text.Encoding]::Default)
    $p = Start-Process -FilePath "$env:ComSpec" -ArgumentList @('/d', '/c', "`"$batch`"") -WorkingDirectory $ProjectRoot -PassThru
    Write-CCBLog info exec 'Command opened in a window' @{ id = $id; command = $Command }
    @{ id = $id; pid = $p.Id; codeFile = $codeFile; batch = $batch; started = (Get-Date); command = $Command; process = $p }
}

function Get-RunWindowStatus($Window) {
    <# 'finished' with the exit code once the command wrote it (the window may still wait for a
       key), 'closed' when the window went away before that, else 'running'. #>
    if (Test-Path -LiteralPath $Window.codeFile) {
        $code = try { [int]([IO.File]::ReadAllText($Window.codeFile).Trim()) } catch { -1 }
        return @{ state = 'finished'; exitCode = $code }
    }
    $gone = try { $Window.process.HasExited } catch { $true }
    if ($gone) { return @{ state = 'closed'; exitCode = $null } }
    @{ state = 'running'; exitCode = $null }
}

function Remove-RunWindowFiles($Window) {
    foreach ($f in $Window.codeFile, $Window.batch) { try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } } catch { } }
}

Export-ModuleMember -Function Get-RunWindowDir, New-RunWindowBatch, Start-RunWindow, Get-RunWindowStatus, Remove-RunWindowFiles
