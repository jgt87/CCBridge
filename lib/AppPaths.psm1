# Where StreamHub keeps its own files, and the one-time move from the folders of its old name.
#   data folder      %LOCALAPPDATA%\StreamHub (Get-AppDataDir; every module builds its paths from it)
#   projects folder  <OneDrive>\StreamHub (Resolve-ProjectsDir; the name is harness.json projectsFolder)
# Releases before the rename (2026-11-24) used the name CCBridge for both. Invoke-AppDataMigration
# moves them once, at start, before anything opens files there. Until a move has worked (a file in
# use, the app's Edge still open), the old folder stays in use: Get-AppDataDir and Resolve-ProjectsDir
# return the old folder while it is the only one, so every part of the app reads and writes the same
# place. When both exist, the new one is used and the old one is left alone (never merged).
# This is the one module that names the old folders; other old-name lines carry "pre-rename".

$ErrorActionPreference = 'Stop'

$script:AppName = 'StreamHub'
$script:OldAppName = 'CCBridge'   # the name before the rename: only to find and move what it left behind

function Get-AppDataDir {
    <# StreamHub's data folder: %LOCALAPPDATA%\StreamHub, or the old %LOCALAPPDATA%\CCBridge while
       only that one exists (its move has not worked yet). Not created here. $Base is for tests. #>
    param([string]$Base = $env:LOCALAPPDATA)
    $new = Join-Path $Base $script:AppName
    if ([IO.Directory]::Exists($new)) { return $new }
    $old = Join-Path $Base $script:OldAppName
    if ([IO.Directory]::Exists($old)) { return $old }
    $new
}

function Get-AppDataPath([string]$Child) {
    <# A file or folder in the data folder: Get-AppDataPath 'queue.json'. #>
    Join-Path (Get-AppDataDir) $Child
}

function Resolve-ProjectsDir {
    <# The web app's projects folder in OneDrive: <OneDrive>\<FolderName>. For the default name
       (StreamHub), the old <OneDrive>\CCBridge while only that one exists. Not created here. #>
    param([Parameter(Mandatory)][string]$OneDriveRoot, [string]$FolderName = $script:AppName)
    if (-not $FolderName) { $FolderName = $script:AppName }
    $dir = Join-Path $OneDriveRoot $FolderName
    if ($FolderName -eq $script:AppName -and -not [IO.Directory]::Exists($dir)) {
        $old = Join-Path $OneDriveRoot $script:OldAppName
        if ([IO.Directory]::Exists($old)) { return $old }
    }
    $dir
}

function Get-ProjectStateName([string]$ProjectRoot) {
    <# The name of a project's state folder under <data folder>\projects: the folder name and a hash
       of the full path (so a project that moves gets another one; the migration renames them). #>
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectRoot.ToLowerInvariant())) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') })
    "$((Split-Path $ProjectRoot -Leaf) -replace '[^\w.-]', '_')-$hash"
}

function Get-DefaultOneDriveRoot {
    foreach ($p in $env:OneDriveCommercial, $env:OneDrive, $env:OneDriveConsumer) {
        if ($p -and [IO.Directory]::Exists($p)) { return ([IO.Path]::GetFullPath($p)).TrimEnd('\') }
    }
    ''
}

function Get-ConfiguredProjectsFolder([string]$AppRoot) {
    <# projectsFolder from config\harness.json and harness.local.json, read directly (this module
       runs before the others are loaded). #>
    $name = ''
    foreach ($f in 'harness.json', 'harness.local.json') {
        $p = Join-Path (Join-Path $AppRoot 'config') $f
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
            if ($j -and $j.PSObject.Properties['projectsFolder'] -and "$($j.projectsFolder)") { $name = "$($j.projectsFolder)" }
        } catch { }
    }
    if ($name) { $name } else { $script:AppName }
}

function Get-FolderUsers {
    <# Programs that would keep a folder from moving: another StreamHub (web app or MCP server, also
       of a release before the rename) and any process whose command line or program file is inside
       one of $Paths (the app's Edge with its profile there, a tool, a dev server in a project).
       $Processes (ProcessId, Name, CommandLine, ExecutablePath) is for tests. #>
    param([string[]]$Paths, $Processes = $null)
    if ($null -eq $Processes) {
        $Processes = @(try { Get-CimInstance Win32_Process -ErrorAction Stop } catch { })
    }
    $found = @()
    foreach ($p in @($Processes)) {
        if (-not $p -or [int]$p.ProcessId -eq $PID) { continue }
        $cl = "$($p.CommandLine) $($p.ExecutablePath)"
        $why = ''
        if ($cl -match '(?i)(^|[\\/ "])(streamhub|ccbridge)(-mcp)?\.ps1\b') { $why = 'StreamHub is running' }
        else {
            foreach ($x in @($Paths | Where-Object { $_ })) {
                if ([regex]::IsMatch($cl, [regex]::Escape($x) + '(?![\w.-])', 'IgnoreCase')) { $why = 'uses files there'; break }
            }
        }
        if ($why) { $found += "$($p.Name) (process $($p.ProcessId), $why)" }
    }
    $found
}

function Move-OldFolder {
    <# One folder from the old name to the new: 'current' (only the new one), 'none' (neither),
       'both' (the new one is used, the old one left as it is), 'moved', 'busy' (a program uses it:
       not tried) or 'failed' (the move did not work: the old folder stays, whole). Never copies:
       a rename on the same drive, which either happens whole or not at all. #>
    param([string]$Old, [string]$New, [string]$What, $Processes, [Collections.Generic.List[string]]$Messages)
    $hasOld = [IO.Directory]::Exists($Old); $hasNew = [IO.Directory]::Exists($New)
    if ($hasNew -and $hasOld) { $Messages.Add("$What`: both $New and the old $Old exist; using the new one, the old one is left as it is (not merged)."); return 'both' }
    if ($hasNew) { return 'current' }
    if (-not $hasOld) { return 'none' }
    $users = @(Get-FolderUsers -Paths @($Old) -Processes $Processes)
    if ($users.Count) {
        $Messages.Add("$What`: not moved from $Old to $New yet, in use by $(($users | Select-Object -First 3) -join '; '); the old folder stays in use, the move is tried again at the next start.")
        return 'busy'
    }
    try {
        [IO.Directory]::Move($Old, $New)
        $Messages.Add("$What`: moved $Old to $New.")
        'moved'
    } catch {
        $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        $Messages.Add("$What`: moving $Old to $New did not work ($msg); the old folder stays in use, the move is tried again at the next start.")
        'failed'
    }
}

function Update-MovedPathText {
    <# Text with every absolute path under one of the moved folders changed to the new place, as
       written plainly, JSON-escaped (\\) or with forward slashes. A longer name that only starts
       the same (CCBridge2) is left alone. #>
    param([string]$Text, [object[]]$Pairs)
    foreach ($pair in $Pairs) {
        $old = "$($pair[0])".TrimEnd('\'); $new = "$($pair[1])".TrimEnd('\')
        foreach ($form in @(@($old.Replace('\', '\\'), $new.Replace('\', '\\')), @($old, $new), @($old.Replace('\', '/'), $new.Replace('\', '/')))) {
            $Text = [regex]::Replace($Text, [regex]::Escape($form[0]) + '(?![\w.-])', $form[1].Replace('$', '$$'), 'IgnoreCase')
        }
    }
    $Text
}

function Update-MovedPathFiles {
    <# The data folder's own records that hold absolute paths (last-project.txt, queue.json, the issue
       index, schedules, each project's state files and chat history) point to the new places. Undo
       backups, vaults, logs and the Edge profiles are not touched. Returns the files changed. #>
    param([string]$DataDir, [object[]]$Pairs)
    $files = @(Get-ChildItem -LiteralPath $DataDir -File -ErrorAction SilentlyContinue)
    $projects = Join-Path $DataDir 'projects'
    if ([IO.Directory]::Exists($projects)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue)) { $files += @(Get-ChildItem -LiteralPath $d.FullName -File -ErrorAction SilentlyContinue) }
    }
    $changed = @()
    foreach ($f in @($files | Where-Object { $_.Extension -in '.json', '.jsonl', '.txt' -and $_.Length -lt 50MB })) {
        $tmp = $null
        try {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            $enc = New-Object Text.UTF8Encoding($bom)
            $start = if ($bom) { 3 } else { 0 }
            $text = [Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
            $out = Update-MovedPathText $text $Pairs
            if ($out -ceq $text) { continue }
            $tmp = $f.FullName + '.rename-tmp'
            [IO.File]::WriteAllText($tmp, $out, $enc)
            # [NullString]::Value: a plain $null reaches .NET as '' ("not of a legal form").
            [IO.File]::Replace($tmp, $f.FullName, [NullString]::Value)
            $changed += $f.FullName
        } catch { try { if ($tmp -and [IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } } catch { } }
    }
    $changed
}

function Rename-ProjectStateDirs {
    <# Each project's state folder (chat history, undo backups) is named after the project's full
       path; after the projects folder moved, it gets the name of the new path. #>
    param([string]$DataDir, [string]$OldProjects, [string]$NewProjects)
    $base = Join-Path $DataDir 'projects'
    if (-not [IO.Directory]::Exists($base) -or -not [IO.Directory]::Exists($NewProjects)) { return 0 }
    $n = 0
    foreach ($p in @(Get-ChildItem -LiteralPath $NewProjects -Directory -ErrorAction SilentlyContinue)) {
        $from = Join-Path $base (Get-ProjectStateName (Join-Path $OldProjects $p.Name))
        $to = Join-Path $base (Get-ProjectStateName (Join-Path $NewProjects $p.Name))
        if ([IO.Directory]::Exists($from) -and -not [IO.Directory]::Exists($to)) {
            try { [IO.Directory]::Move($from, $to); $n++ } catch { }
        }
    }
    $n
}

function Rename-OldLogFiles([string]$DataDir) {
    <# Log files of the old name (ccbridge-yyyyMMdd.log) get the new name, so the 14-day clean-up,
       the session report and Export diagnostics find them. #>
    $logs = Join-Path $DataDir 'logs'
    if (-not [IO.Directory]::Exists($logs)) { return 0 }
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $logs -File -Filter ($script:OldAppName.ToLowerInvariant() + '-*.log') -ErrorAction SilentlyContinue)) {
        $rest = $f.Name.Substring($script:OldAppName.Length)
        $to = Join-Path $logs ($script:AppName.ToLowerInvariant() + $rest)
        if ([IO.File]::Exists($to)) { $to = Join-Path $logs ($script:AppName.ToLowerInvariant() + [IO.Path]::GetFileNameWithoutExtension($rest) + '-before-rename.log') }
        if ([IO.File]::Exists($to)) { continue }
        try { [IO.File]::Move($f.FullName, $to); $n++ } catch { }
    }
    $n
}

function Invoke-AppDataMigration {
    <# The one-time move from the old name, at every start until it has worked (afterwards nothing
       to do): the data folder (%LOCALAPPDATA%\CCBridge -> StreamHub, with the Edge profile and its
       sign-in) and the projects folder (<OneDrive>\CCBridge -> StreamHub, a rename OneDrive syncs
       as one), then the paths recorded inside the data folder and the project state folders. A
       folder in use (another StreamHub, the app's Edge, a file open) is not moved this time.
       Returns @{ Data; Projects; DataDir; ProjectsDir; Messages; Changed } for the caller to log
       (this runs before the log is set up). $LocalAppData, $OneDriveRoot, $ProjectsFolder and
       $Processes are for tests ($OneDriveRoot '' skips the projects folder). #>
    param([string]$AppRoot = (Split-Path -Parent $PSScriptRoot), [string]$LocalAppData = $env:LOCALAPPDATA,
        [AllowNull()][string]$OneDriveRoot = $null, [string]$ProjectsFolder = '', $Processes = $null)
    # Test runs never move the person's real folders: STREAMHUB_NO_MIGRATE=1 (tools/run-tests.ps1 sets
    # it for every test process and the programs they start) or Pester loaded, unless a test names
    # its own temporary folders.
    if (-not $PSBoundParameters.ContainsKey('LocalAppData') -and ($env:STREAMHUB_NO_MIGRATE -eq '1' -or (Get-Module Pester))) {
        return [pscustomobject]@{ Data = 'skipped'; Projects = 'skipped'; DataDir = (Get-AppDataDir); ProjectsDir = ''; Messages = @(); Changed = @() }
    }
    $messages = New-Object Collections.Generic.List[string]
    # The process list is read only when a folder is still to be moved (Get-FolderUsers).
    $dataOld = Join-Path $LocalAppData $script:OldAppName
    $dataNew = Join-Path $LocalAppData $script:AppName
    $data = Move-OldFolder -Old $dataOld -New $dataNew -What 'Data folder' -Processes $Processes -Messages $messages

    if (-not $PSBoundParameters.ContainsKey('OneDriveRoot')) { $OneDriveRoot = Get-DefaultOneDriveRoot }
    if (-not $ProjectsFolder) { $ProjectsFolder = Get-ConfiguredProjectsFolder $AppRoot }
    $projects = 'none'; $projOld = ''; $projNew = ''
    if ($OneDriveRoot -and $ProjectsFolder -eq $script:AppName) {
        $projOld = Join-Path $OneDriveRoot $script:OldAppName
        $projNew = Join-Path $OneDriveRoot $script:AppName
        $projects = Move-OldFolder -Old $projOld -New $projNew -What 'Projects folder' -Processes $Processes -Messages $messages
    }

    $dataDir = Get-AppDataDir -Base $LocalAppData
    $changed = @()
    $pairs = @()
    if ($data -eq 'moved') { $pairs += , @($dataOld, $dataNew) }
    if ($projects -eq 'moved') { $pairs += , @($projOld, $projNew) }
    if ([IO.Directory]::Exists($dataDir)) {
        if ($projects -eq 'moved') {
            $n = Rename-ProjectStateDirs -DataDir $dataDir -OldProjects $projOld -NewProjects $projNew
            if ($n) { $messages.Add("Project state: $n project folder(s) renamed for the new projects folder.") }
        }
        if ($pairs.Count) {
            $changed = @(Update-MovedPathFiles -DataDir $dataDir -Pairs $pairs)
            if ($changed.Count) { $messages.Add("Paths to the new folders written in: $(($changed | ForEach-Object { $_.Substring($dataDir.Length + 1) }) -join ', ').") }
        }
        $logs = Rename-OldLogFiles $dataDir
        if ($logs) { $messages.Add("Log files: $logs renamed to the new name.") }
    }
    [pscustomobject]@{
        Data = $data; Projects = $projects; DataDir = $dataDir
        ProjectsDir = $(if ($OneDriveRoot) { Resolve-ProjectsDir -OneDriveRoot $OneDriveRoot -FolderName $ProjectsFolder } else { '' })
        Messages = $messages.ToArray(); Changed = $changed
    }
}

function Test-MigrationPending($Result) {
    <# True while a folder still has the old name because its move did not work this time. #>
    $Result -and (@('busy', 'failed') -contains $Result.Data -or @('busy', 'failed') -contains $Result.Projects)
}

Export-ModuleMember -Function Get-AppDataDir, Get-AppDataPath, Resolve-ProjectsDir, Get-ProjectStateName, Get-FolderUsers, Update-MovedPathText, Invoke-AppDataMigration, Test-MigrationPending
