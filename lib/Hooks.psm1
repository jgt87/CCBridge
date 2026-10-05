# Hooks: the user's own commands at fixed moments of a task, from .streamhub/hooks.json in the
# project (Copilot cannot write there). afterEdit runs after Copilot writes or edits a matching file
# ({file} is that file), beforeDone when Copilot says done (a failure goes back to Copilot), afterTask
# when a task ends. Agent.psm1 runs them with the command rules (no deleting outside the project,
# Microsoft 365 or deleting commands never run) and asks a person once per version of the file.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace', 'Layout') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:Events = @('afterEdit', 'beforeDone', 'afterTask')

function Get-HooksPath([string]$ProjectRoot) { Join-Path $ProjectRoot '.streamhub\hooks.json' }

function Read-Hooks {
    <# The project's hooks: @{ exists; error; hooks = @( @{ event; run; match; name } ) }. A hook
       needs "run"; "match" (afterEdit) is a file pattern like *.ps1 or src/*.js (default: any file). #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $f = Get-HooksPath $ProjectRoot
    $out = @{ exists = (Test-Path -LiteralPath $f -PathType Leaf); error = $null; hooks = @() }
    if (-not $out.exists) { return $out }
    try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $out.error = "hooks.json is not valid JSON: $($_.Exception.Message.Split("`n")[0])"; return $out }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in $script:Events) {
        foreach ($h in @($j.$e | Where-Object { $_ })) {
            $run = "$(if ($h -is [string]) { $h } else { $h.run })".Trim()
            if (-not $run) { continue }
            $list.Add([pscustomobject]@{ event = $e; run = $run; match = "$(if ($h -isnot [string]) { $h.match })".Trim(); name = "$(if ($h -isnot [string]) { $h.name })".Trim() })
        }
    }
    foreach ($p in @($j.PSObject.Properties | Where-Object { $_.Name -notin $script:Events -and $_.Name -notmatch '^(_|\$)' })) {
        $out.error = "unknown hook moment '$($p.Name)' in hooks.json (use $($script:Events -join ', '))"
    }
    $out.hooks = $list.ToArray()
    $out
}

function Test-HookMatch($Hook, [string]$Path) {
    # afterEdit: the file matches the hook's pattern (a pattern without / matches the file name).
    if (-not $Hook.match) { return $true }
    $r = "$Path".Replace('\', '/')
    foreach ($m in @($Hook.match -split '[,;]' | ForEach-Object { $_.Trim().Replace('\', '/') } | Where-Object { $_ })) {
        if ($r -like $m -or ($m -notmatch '/' -and ($r -split '/')[-1] -like $m)) { return $true }
    }
    $false
}

function Get-HookCommand($Hook, [string]$Path = '') {
    # The command line: {file} becomes the (quoted) changed file.
    $cmd = $Hook.run
    if ($cmd -match '\{file\}') { $cmd = $cmd.Replace('{file}', $(if ($Path) { '"' + $Path.Replace('/', '\') + '"' } else { '' })) }
    $cmd.Trim()
}

function New-HooksFile {
    <# Writes a starting .streamhub/hooks.json (nothing runs until the user fills it in). #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $f = Get-HooksPath $ProjectRoot
    if (Test-Path -LiteralPath $f) { throw 'This project already has a hooks file.' }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $f)
    $text = @'
{
  "_help": "Your own commands at fixed moments. afterEdit: after Copilot writes or edits a file that matches 'match' ({file} is that file). beforeDone: when Copilot says done; a failure goes back to Copilot. afterTask: when a task ends. Commands run in the project folder; deleting or Microsoft 365 commands never run. Remove the leading _ from an example to use it.",
  "afterEdit": [],
  "beforeDone": [],
  "afterTask": [],
  "_examples": {
    "afterEdit": [ { "name": "Check PowerShell", "match": "*.ps1", "run": "powershell -NoProfile -Command \"$e=$null; $null=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path {file}),[ref]$null,[ref]$e); if ($e) { $e; exit 1 }\"" } ],
    "beforeDone": [ { "name": "Project check", "run": "powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/check.ps1" } ],
    "afterTask": [ { "name": "Export", "run": "powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/export.ps1" } ]
  }
}
'@
    [IO.File]::WriteAllText($f, $text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    '.streamhub/hooks.json'
}

Export-ModuleMember -Function Get-HooksPath, Read-Hooks, Test-HookMatch, Get-HookCommand, New-HooksFile
