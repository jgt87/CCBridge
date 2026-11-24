# The data and projects folders after the rename (lib/AppPaths.psm1): the one-time move from the old
# name (CCBridge, pre-rename) at start, in temporary folders only (never this computer's real ones).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\AppPaths.psm1') -Force

function New-TestBase {
    $b = Join-Path $env:TEMP ('shm-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $b 'local'), (Join-Path $b 'od')
    @{ Base = $b; Local = (Join-Path $b 'local'); Od = (Join-Path $b 'od') }
}
function Invoke-TestMigration($T, $Processes = @(), [string]$Folder = 'StreamHub') {
    Invoke-AppDataMigration -AppRoot $root -LocalAppData $T.Local -OneDriveRoot $T.Od -ProjectsFolder $Folder -Processes $Processes
}
function Write-TestFile([string]$Path, [string]$Text) {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

Describe 'Moving the data folder from the old name' {
    It 'moves the old folder when it is the only one, with everything in it' {
        $t = New-TestBase
        try {
            Write-TestFile (Join-Path $t.Local 'CCBridge\edge-profile\Default\Preferences') '{"x":1}'
            Write-TestFile (Join-Path $t.Local 'CCBridge\queue.json') '[]'
            $r = Invoke-TestMigration $t
            $r.Data | Should Be 'moved'
            Test-Path (Join-Path $t.Local 'CCBridge') | Should Be $false
            [IO.File]::ReadAllText((Join-Path $t.Local 'StreamHub\edge-profile\Default\Preferences')) | Should Be '{"x":1}'
            $r.DataDir | Should Be (Join-Path $t.Local 'StreamHub')
            Get-AppDataDir -Base $t.Local | Should Be (Join-Path $t.Local 'StreamHub')
            ($r.Messages -join "`n") | Should Match 'Data folder: moved'
        } finally { Remove-Item $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'uses the new folder when both exist, leaves the old one untouched and says so' {
        $t = New-TestBase
        try {
            Write-TestFile (Join-Path $t.Local 'CCBridge\queue.json') 'old'
            Write-TestFile (Join-Path $t.Local 'StreamHub\queue.json') 'new'
            $r = Invoke-TestMigration $t
            $r.Data | Should Be 'both'
            [IO.File]::ReadAllText((Join-Path $t.Local 'CCBridge\queue.json')) | Should Be 'old'
            [IO.File]::ReadAllText((Join-Path $t.Local 'StreamHub\queue.json')) | Should Be 'new'
            Get-AppDataDir -Base $t.Local | Should Be (Join-Path $t.Local 'StreamHub')
            ($r.Messages -join "`n") | Should Match 'not merged'
        } finally { Remove-Item $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps using the old folder, whole, when a file in it is open, and moves it at the next start' {
        $t = New-TestBase
        $f = Join-Path $t.Local 'CCBridge\logs\x.log'
        Write-TestFile $f 'line'
        $fs = [IO.File]::Open($f, 'Open', 'ReadWrite', 'None')
        try {
            $r = Invoke-TestMigration $t
            $r.Data | Should Be 'failed'
            Test-MigrationPending $r | Should Be $true
            Test-Path (Join-Path $t.Local 'StreamHub') | Should Be $false
            Get-AppDataDir -Base $t.Local | Should Be (Join-Path $t.Local 'CCBridge')
            ($r.Messages -join "`n") | Should Match 'stays in use'
        } finally { $fs.Dispose() }
        try {
            [IO.File]::ReadAllText($f) | Should Be 'line'   # no data lost
            (Invoke-TestMigration $t).Data | Should Be 'moved'
            [IO.File]::ReadAllText((Join-Path $t.Local 'StreamHub\logs\x.log')) | Should Be 'line'
        } finally { Remove-Item $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'does not try while the app''s Edge or another StreamHub uses the old folder' {
        $t = New-TestBase
        try {
            Write-TestFile (Join-Path $t.Local 'CCBridge\queue.json') '[]'
            $edge = [pscustomobject]@{ ProcessId = 4242; Name = 'msedge.exe'; CommandLine = "msedge.exe --user-data-dir=`"$(Join-Path $t.Local 'CCBridge\edge-profile')`""; ExecutablePath = 'C:\Edge\msedge.exe' }
            $r = Invoke-TestMigration $t @($edge)
            $r.Data | Should Be 'busy'
            ($r.Messages -join "`n") | Should Match 'msedge\.exe \(process 4242'
            Test-Path (Join-Path $t.Local 'CCBridge\queue.json') | Should Be $true
            $old = [pscustomobject]@{ ProcessId = 4343; Name = 'powershell.exe'; CommandLine = 'powershell.exe -File "C:\Apps\CCBridge\ccbridge.ps1"'; ExecutablePath = '' }   # pre-rename start script
            (Invoke-TestMigration $t @($old)).Data | Should Be 'busy'
            # A folder that only starts with the same name is not "inside".
            $other = [pscustomobject]@{ ProcessId = 4444; Name = 'x.exe'; CommandLine = "x.exe $(Join-Path $t.Local 'CCBridge2\y')"; ExecutablePath = '' }
            (Invoke-TestMigration $t @($other)).Data | Should Be 'moved'
        } finally { Remove-Item $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Moving the projects folder and the paths recorded for it' {
    It 'renames the projects folder, the project state folders and the paths in the data files' {
        $t = New-TestBase
        try {
            $oldProj = Join-Path $t.Od 'CCBridge'
            $newProj = Join-Path $t.Od 'StreamHub'
            Write-TestFile (Join-Path $oldProj 'budget\AGENTS.md') '# budget'
            $oldState = Join-Path $t.Local ('CCBridge\projects\' + (Get-ProjectStateName (Join-Path $oldProj 'budget')))
            Write-TestFile (Join-Path $oldState 'chat-history.jsonl') ('{"text":"opened ' + (Join-Path $oldProj 'budget').Replace('\', '\\') + '"}')
            Write-TestFile (Join-Path $t.Local 'CCBridge\last-project.txt') (Join-Path $oldProj 'budget')
            $q = @{ projectRoot = (Join-Path $oldProj 'budget'); other = (Join-Path $t.Od 'CCBridge2\x'); tool = (Join-Path $t.Local 'CCBridge\tools\node\node.cmd') } | ConvertTo-Json -Compress
            Write-TestFile (Join-Path $t.Local 'CCBridge\queue.json') $q
            Write-TestFile (Join-Path $t.Local 'CCBridge\issue-index.json') ('{"root":"' + (Join-Path $oldProj 'budget').Replace('\', '/') + '"}')
            Write-TestFile (Join-Path $t.Local 'CCBridge\logs\ccbridge-20260101.log') 'old log'   # pre-rename log name

            $r = Invoke-TestMigration $t
            $r.Data | Should Be 'moved'
            $r.Projects | Should Be 'moved'
            Test-Path $oldProj | Should Be $false
            Test-Path (Join-Path $newProj 'budget\AGENTS.md') | Should Be $true
            $r.ProjectsDir | Should Be $newProj

            $data = Join-Path $t.Local 'StreamHub'
            $newState = Join-Path $data ('projects\' + (Get-ProjectStateName (Join-Path $newProj 'budget')))
            Test-Path (Join-Path $newState 'chat-history.jsonl') | Should Be $true
            [IO.File]::ReadAllText((Join-Path $newState 'chat-history.jsonl')) | Should Match ([regex]::Escape((Join-Path $newProj 'budget').Replace('\', '\\')))
            [IO.File]::ReadAllText((Join-Path $data 'last-project.txt')) | Should Be (Join-Path $newProj 'budget')
            $qj = [IO.File]::ReadAllText((Join-Path $data 'queue.json')) | ConvertFrom-Json
            $qj.projectRoot | Should Be (Join-Path $newProj 'budget')
            $qj.other | Should Be (Join-Path $t.Od 'CCBridge2\x')   # another folder whose name only starts the same
            $qj.tool | Should Be (Join-Path $data 'tools\node\node.cmd')
            [IO.File]::ReadAllText((Join-Path $data 'issue-index.json')) | Should Match ([regex]::Escape((Join-Path $newProj 'budget').Replace('\', '/')))
            Test-Path (Join-Path $data 'logs\streamhub-20260101.log') | Should Be $true
            Test-Path (Join-Path $data 'logs\ccbridge-20260101.log') | Should Be $false
        } finally { Remove-Item $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'does nothing at the second start' {
        $t = New-TestBase
        try {
            Write-TestFile (Join-Path $t.Od 'CCBridge\p\a.txt') 'a'
            Write-TestFile (Join-Path $t.Local 'CCBridge\last-project.txt') (Join-Path $t.Od 'CCBridge\p')
            $null = Invoke-TestMigration $t
            $file = Join-Path $t.Local 'StreamHub\last-project.txt'
            $stamp = [IO.File]::GetLastWriteTimeUtc($file)
            $r = Invoke-TestMigration $t
            $r.Data | Should Be 'current'
            $r.Projects | Should Be 'current'
            @($r.Messages).Count | Should Be 0
            @($r.Changed).Count | Should Be 0
            [IO.File]::GetLastWriteTimeUtc($file) | Should Be $stamp
        } finally { Remove-Item $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps using the old projects folder while it is in use, and leaves a projects folder of another name alone' {
        $t = New-TestBase
        try {
            $f = Join-Path $t.Od 'CCBridge\p\open.txt'
            Write-TestFile $f 'x'
            $fs = [IO.File]::Open($f, 'Open', 'ReadWrite', 'None')
            try { (Invoke-TestMigration $t).Projects | Should Be 'failed' } finally { $fs.Dispose() }
            Resolve-ProjectsDir -OneDriveRoot $t.Od | Should Be (Join-Path $t.Od 'CCBridge')
            (Invoke-TestMigration $t -Folder 'Work').Projects | Should Be 'none'
            Test-Path (Join-Path $t.Od 'CCBridge\p\open.txt') | Should Be $true
            Resolve-ProjectsDir -OneDriveRoot $t.Od -FolderName 'Work' | Should Be (Join-Path $t.Od 'Work')
        } finally { Remove-Item $t.Base -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test runs and the real folders' {
    It 'never moves this computer''s folders from a test (no temporary folders named)' {
        $r = Invoke-AppDataMigration -AppRoot $root
        $r.Data | Should Be 'skipped'
        $r.Projects | Should Be 'skipped'
    }
    It 'names a project''s state folder as the workspace always did (folder name and path hash)' {
        Get-ProjectStateName 'C:\OneDrive\StreamHub\My budget' | Should Match '^My_budget-[0-9a-f]{12}$'
        Get-ProjectStateName 'C:\OneDrive\StreamHub\A' | Should Be (Get-ProjectStateName 'c:\onedrive\streamhub\a')
    }
}
