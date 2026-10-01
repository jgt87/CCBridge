# Carries out action blocks inside one project folder: read, search, write/edit files
# (with backups for undo) and run commands.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')
Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Read-TextFile([string]$Path) {
    <# Returns text with LF line endings plus how to write it back (BOM, CRLF). #>
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    [pscustomobject]@{ Text = $text.Replace("`r`n", "`n"); Bom = $bom; Crlf = $text.Contains("`r`n") }
}

function Write-TextFile([string]$Path, [string]$Text, [bool]$Bom = $false, [bool]$Crlf = $false) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $t = $Text.Replace("`r`n", "`n")
    if ($Crlf) { $t = $t.Replace("`n", "`r`n") }
    [IO.File]::WriteAllText($Path, $t, $(if ($Bom) { New-Object Text.UTF8Encoding($true) } else { $script:Utf8NoBom }))
}

function Test-BinaryFile([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4096
        $n = $fs.Read($buf, 0, $buf.Length)
        for ($k = 0; $k -lt $n; $k++) { if ($buf[$k] -eq 0) { return $true } }
        $false
    } finally { $fs.Dispose() }
}

# Copilot's web page sends < and > in our prompts as &lt; and &gt;, so Copilot sometimes copies
# those entities into code. Markup files may contain entities on purpose and are left alone.
$script:MarkupExtensions = @('.html', '.htm', '.xhtml', '.xml', '.svg', '.xaml', '.vue', '.jsx', '.tsx', '.md', '.markdown', '.resx', '.config', '.csproj', '.props', '.targets')

function Test-MarkupFile([string]$Path) { $script:MarkupExtensions -contains [IO.Path]::GetExtension($Path).ToLowerInvariant() }

function ConvertFrom-AngleEntities([string]$Text) { $Text.Replace('&lt;', '<').Replace('&gt;', '>') }

function Repair-CodeText([string]$Path, [string]$Text) {
    if (Test-MarkupFile $Path) { return $Text }
    ConvertFrom-AngleEntities $Text
}
# --- Checkpoints (undo) --------------------------------------------------------------

function New-Checkpoint {
    <# Starts a checkpoint: before the first change to a file, its old content is copied here. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Label = '')
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $dir = Join-Path (Get-ProjectStateDir $ProjectRoot) "backups\$id"
    $null = New-Item -ItemType Directory -Path $dir -Force
    [pscustomobject]@{ Id = $id; Dir = $dir; Label = $Label; Files = @{} }   # Files: rel -> 'existed' | 'new'
}

function Save-CheckpointFile($Checkpoint, [string]$ProjectRoot, [string]$FullPath) {
    $rel = ConvertTo-RelativePath $ProjectRoot $FullPath
    if ($Checkpoint.Files.ContainsKey($rel)) { return }
    if (Test-Path $FullPath) {
        $dest = Join-Path $Checkpoint.Dir ($rel.Replace('/', '\'))
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
        Copy-Item -LiteralPath $FullPath -Destination $dest
        $Checkpoint.Files[$rel] = 'existed'
    } else {
        $Checkpoint.Files[$rel] = 'new'
    }
    $Checkpoint.Files | ConvertTo-Json | Set-Content (Join-Path $Checkpoint.Dir 'manifest.json') -Encoding UTF8
}

function Undo-LastCheckpoint {
    <# Restores the files of the newest checkpoint that has changes, then removes it. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $base = Join-Path (Get-ProjectStateDir $ProjectRoot) 'backups'
    if (-not (Test-Path $base)) { return @() }
    foreach ($cp in Get-ChildItem -Directory $base | Sort-Object Name -Descending) {
        $manifest = Join-Path $cp.FullName 'manifest.json'
        if (-not (Test-Path $manifest)) { Remove-Item $cp.FullName -Recurse -Force; continue }
        $files = Get-Content $manifest -Raw | ConvertFrom-Json
        $restored = @()
        foreach ($p in $files.PSObject.Properties) {
            $full = Resolve-ProjectPath $ProjectRoot $p.Name
            if ($p.Value -eq 'new') { if (Test-Path $full) { Remove-Item -LiteralPath $full -Force } }
            else { Copy-Item -LiteralPath (Join-Path $cp.FullName ($p.Name.Replace('/', '\'))) -Destination $full -Force }
            $restored += $p.Name
        }
        Remove-Item $cp.FullName -Recurse -Force
        return $restored
    }
    @()
}

# --- Actions -------------------------------------------------------------------------

function Invoke-ReadAction {
    param([string]$ProjectRoot, [string[]]$Paths, [int]$MaxCharsPerFile = 40000)
    foreach ($p in $Paths) {
        try {
            $full = Resolve-ProjectPath $ProjectRoot $p
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { "### $p`n(file not found)"; continue }
            if (Test-BinaryFile $full) { "### $p`n(binary file, $((Get-Item -LiteralPath $full).Length) bytes - not shown)"; continue }
            $t = (Read-TextFile $full).Text
            $note = ''
            if ($t.Length -gt $MaxCharsPerFile) { $note = "`n(truncated: showing $MaxCharsPerFile of $($t.Length) characters)"; $t = $t.Substring(0, $MaxCharsPerFile) }
            $fence = '````'
            "### $p`n$fence`n$t`n$fence$note"
        } catch { "### $p`n(error: $($_.Exception.Message))" }
    }
}

function ConvertTo-GlobRegex([string]$Glob) {
    $g = $Glob.Trim().Replace('\', '/').TrimStart('/')
    $re = [regex]::Escape($g).Replace('\*\*/', '(.*/)?').Replace('\*\*', '.*').Replace('\*', '[^/]*').Replace('\?', '[^/]')
    if (-not $g.Contains('/')) { $re = '(.*/)?' + $re }
    "^$re$"
}

function Invoke-GlobAction {
    param([string]$ProjectRoot, [string]$Pattern)
    $re = ConvertTo-GlobRegex $Pattern
    $hits = @(Get-ProjectFiles $ProjectRoot | Where-Object { $_.path -match $re })
    if (-not $hits.Count) { return "(no files match $Pattern)" }
    ($hits | Select-Object -First 300 | ForEach-Object { "$($_.path) ($($_.size) B)" }) -join "`n"
}

function Invoke-GrepAction {
    param([string]$ProjectRoot, [string]$Pattern, [string]$FileGlob, [int]$MaxHits = 100)
    $files = Get-ProjectFiles $ProjectRoot
    if ($FileGlob) { $re = ConvertTo-GlobRegex $FileGlob; $files = $files | Where-Object { $_.path -match $re } }
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        if ($f.size -gt 2MB) { continue }
        $full = Resolve-ProjectPath $ProjectRoot $f.path
        if (Test-BinaryFile $full) { continue }
        $n = 0
        foreach ($line in (Read-TextFile $full).Text.Split("`n")) {
            $n++
            if ($line -match $Pattern) {
                $hits.Add("$($f.path):$n`: $($line.Trim())")
                if ($hits.Count -ge $MaxHits) { return ($hits -join "`n") + "`n(stopped at $MaxHits matches)" }
            }
        }
    }
    if (-not $hits.Count) { return "(no matches for $Pattern)" }
    $hits -join "`n"
}

function Assert-Writable([string]$ProjectRoot, [string]$Path) {
    <# Returns the full path, or throws when the path is user source data (read-only). #>
    $full = Resolve-ProjectPath $ProjectRoot $Path
    if (Test-InSource $ProjectRoot $full) {
        throw "$Path is in source/, which holds the user's source data and is read-only. Leave it unchanged and write your own working file elsewhere in the project (for example work/$([IO.Path]::GetFileName($full)))."
    }
    $full
}

function Get-WritePreview {
    <# Old and new content for the approval diff of a write action. #>
    param([string]$ProjectRoot, [string]$Path, [string]$Content)
    $full = Resolve-ProjectPath $ProjectRoot $Path
    $old = if (Test-Path -LiteralPath $full -PathType Leaf) { (Read-TextFile $full).Text } else { $null }
    [pscustomobject]@{ path = (ConvertTo-RelativePath $ProjectRoot $full); exists = ($null -ne $old); old = $old; new = (Repair-CodeText $full $Content) }
}

function Invoke-WriteAction {
    param([string]$ProjectRoot, [string]$Path, [string]$Content, $Checkpoint)
    $full = Assert-Writable $ProjectRoot $Path
    $bom = $false; $crlf = $false
    if (Test-Path -LiteralPath $full -PathType Leaf) { $info = Read-TextFile $full; $bom = $info.Bom; $crlf = $info.Crlf }
    $Content = Repair-CodeText $full $Content
    if ($Checkpoint) { Save-CheckpointFile $Checkpoint $ProjectRoot $full }
    if (-not $Content.EndsWith("`n")) { $Content += "`n" }
    Write-TextFile $full $Content $bom $crlf
    $lines = $Content.Split("`n").Length - 1
    "wrote $(ConvertTo-RelativePath $ProjectRoot $full) ($lines lines)"
}

function Find-EditTarget([string]$Text, [string]$Search) {
    <# Index of the single exact match of $Search; falls back to ignoring trailing whitespace per line. #>
    $i = $Text.IndexOf($Search, [StringComparison]::Ordinal)
    if ($i -ge 0) {
        if ($Text.IndexOf($Search, $i + 1, [StringComparison]::Ordinal) -ge 0) { return @{ error = 'SEARCH text matches more than once; include more surrounding lines' } }
        return @{ start = $i; length = $Search.Length }
    }
    $pattern = '(?m)' + (($Search.Split("`n") | ForEach-Object { [regex]::Escape($_.TrimEnd()) + '[ \t]*' }) -join '\n')
    $ms = [regex]::Matches($Text, $pattern)
    if ($ms.Count -eq 1) { return @{ start = $ms[0].Index; length = $ms[0].Length } }
    if ($ms.Count -gt 1) { return @{ error = 'SEARCH text matches more than once; include more surrounding lines' } }
    @{ error = 'SEARCH text not found in the file; read the file again and copy the lines exactly' }
}

function Get-EditResult {
    <# Applies SEARCH/REPLACE pairs in memory. All pairs must apply, or nothing is written. #>
    param([string]$ProjectRoot, [string]$Path, $Edits)
    try { $full = Assert-Writable $ProjectRoot $Path } catch { return [pscustomobject]@{ ok = $false; error = $_.Exception.Message } }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return [pscustomobject]@{ ok = $false; error = "file not found: $Path (use write to create it)" } }
    if (-not $Edits -or -not @($Edits).Count) { return [pscustomobject]@{ ok = $false; error = 'edit block has no SEARCH/REPLACE pairs' } }
    $info = Read-TextFile $full
    $text = $info.Text
    $n = 0
    foreach ($e in $Edits) {
        $n++
        $search = $e.search.Replace("`r`n", "`n")
        $replace = Repair-CodeText $full $e.replace.Replace("`r`n", "`n")
        $hit = Find-EditTarget $text $search
        if ($hit.error -and $search -match '&lt;|&gt;') { $hit = Find-EditTarget $text (ConvertFrom-AngleEntities $search) }
        if ($hit.error) { return [pscustomobject]@{ ok = $false; error = "pair $n`: $($hit.error)" } }
        $text = $text.Substring(0, $hit.start) + $replace + $text.Substring($hit.start + $hit.length)
    }
    [pscustomobject]@{ ok = $true; full = $full; old = $info.Text; new = $text; bom = $info.Bom; crlf = $info.Crlf; pairs = $n }
}

function Invoke-EditAction {
    param([string]$ProjectRoot, [string]$Path, $Edits, $Checkpoint)
    $r = Get-EditResult $ProjectRoot $Path $Edits
    if (-not $r.ok) { throw $r.error }
    if ($Checkpoint) { Save-CheckpointFile $Checkpoint $ProjectRoot $r.full }
    Write-TextFile $r.full $r.new $r.bom $r.crlf
    "edited $(ConvertTo-RelativePath $ProjectRoot $r.full) ($($r.pairs) change(s))"
}

# --- Human in the loop -----------------------------------------------------------------
# Commands that could act on Microsoft 365 data (mail, Teams, calendar, files, Graph) or delete
# data never run without a person approving them; headless callers (MCP) cannot run them at all.

$script:M365CommandPatterns = @(
    @{ re = 'Send-MailMessage|System\.Net\.Mail|SmtpClient|\bsmtp\b|mailto:'; why = 'sends email' },
    @{ re = 'Outlook\.Application|Microsoft\.Office\.Interop\.Outlook|\boutlook(\.exe)?\s+/'; why = 'controls Outlook' },
    @{ re = 'graph\.microsoft\.com|Connect-MgGraph|Microsoft\.Graph|\b[A-Za-z]+-Mg[A-Za-z]+'; why = 'uses Microsoft Graph' },
    @{ re = 'MicrosoftTeams|Connect-MicrosoftTeams|\bteams\.microsoft\.com|\bTeams\.exe'; why = 'uses Microsoft Teams' },
    @{ re = 'ExchangeOnline|Connect-ExchangeOnline|outlook\.office(365)?\.com'; why = 'uses Exchange / Outlook online' },
    @{ re = 'Connect-PnPOnline|\bPnP\.PowerShell|\.sharepoint\.com|Connect-SPOService'; why = 'uses SharePoint / OneDrive online' },
    @{ re = 'login\.microsoftonline\.com|Get-AzAccessToken|az\s+account\s+get-access-token'; why = 'obtains Microsoft 365 access tokens' }
)
$script:DestructiveCommandPatterns = @(
    @{ re = '(^|[\s;&|(])(del|erase|rd|rmdir)(\s|$)'; why = 'deletes files' },
    @{ re = 'Remove-Item|\b(rm|rmdir)\s+-|\bri\s|Clear-Content|Clear-RecycleBin'; why = 'deletes files' },
    @{ re = '\bRemove-[A-Za-z]+'; why = 'removes data' },
    @{ re = 'robocopy\b.*\s/(MIR|PURGE)\b'; why = 'mirrors with deletion' },
    @{ re = 'Format-Volume|\bformat\s+[a-z]:|diskpart|cipher\s+/w'; why = 'wipes a disk' },
    @{ re = '\bgit\s+(clean\s+-[a-z]*f|reset\s+--hard|push\s+.*--force)'; why = 'discards data in git' }
)

function Get-CommandRisk {
    <# Returns @{ m365 = bool; destructive = bool; reasons = string[] } for a shell command. #>
    param([string]$Command)
    $reasons = New-Object System.Collections.Generic.List[string]
    $m365 = $false; $destructive = $false
    foreach ($p in $script:M365CommandPatterns) { if ($Command -match $p.re) { $m365 = $true; if (-not $reasons.Contains($p.why)) { $reasons.Add($p.why) } } }
    foreach ($p in $script:DestructiveCommandPatterns) { if ($Command -match $p.re) { $destructive = $true; if (-not $reasons.Contains($p.why)) { $reasons.Add($p.why) } } }
    if ($m365 -or $destructive) { Write-CCBLog info exec 'Risky command detected' @{ command = $Command; reasons = @($reasons) } }
    @{ m365 = $m365; destructive = $destructive; reasons = @($reasons) }
}

function Invoke-RunAction {
    <# Runs a command with cmd.exe in the project folder. Output is trimmed to head + tail. #>
    param([string]$ProjectRoot, [string]$Command, [int]$TimeoutSec = 120, [int]$MaxChars = 8000, [scriptblock]$CancelCheck)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:ComSpec"
    $psi.Arguments = '/d /s /c "' + $Command + ' 2>&1"'
    $psi.WorkingDirectory = $ProjectRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    # Wait in short steps so a Stop from the user ends the command (and its children) at once.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $timedOut = $false; $cancelled = $false
    while (-not $p.WaitForExit(250)) {
        if ($CancelCheck -and (& $CancelCheck)) { $cancelled = $true; break }
        if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
    }
    if ($timedOut -or $cancelled) { cmd.exe /c "taskkill /PID $($p.Id) /T /F >nul 2>&1"; $p.WaitForExit(5000) | Out-Null }
    $text = ($out.Result + $err.Result).Replace("`r`n", "`n").TrimEnd()
    Write-CCBLog verbose exec "run finished" @{ command = $Command; exitCode = $(if ($timedOut -or $cancelled) { $null } else { $p.ExitCode }); timedOut = $timedOut; cancelled = $cancelled; outputChars = $text.Length }
    if ($text.Length -gt $MaxChars) {
        $head = [int]($MaxChars * 0.25)
        $text = $text.Substring(0, $head) + "`n... ($($text.Length - $MaxChars) characters omitted) ...`n" + $text.Substring($text.Length - ($MaxChars - $head))
    }
    [pscustomobject]@{ exitCode = $(if ($timedOut -or $cancelled) { $null } else { $p.ExitCode }); timedOut = $timedOut; cancelled = $cancelled; output = $text }
}

Export-ModuleMember -Function Get-CommandRisk, Assert-Writable, Read-TextFile, New-Checkpoint, Undo-LastCheckpoint, Invoke-ReadAction, Invoke-GlobAction, Invoke-GrepAction,
    Get-WritePreview, Invoke-WriteAction, Get-EditResult, Invoke-EditAction, Invoke-RunAction
