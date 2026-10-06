# A project's npm packages: which package.json files list packages that node_modules does not have
# yet. StreamHub never installs them by itself (npm install downloads code and runs its install
# scripts): it shows a card with "Run npm install", and Settings > This computer has the same
# button. The job is Invoke-PackagesJob in Agent.psm1.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:SkipDir = '(?i)(^|/)(node_modules|\.streamhub|\.git|dist|build|out|coverage|Source|Logs|\.venv|venv)(/|$)'

function Find-PackageFiles([string]$ProjectRoot) {
    <# The package.json files of a project: its root and folders up to two levels down (an app in
       web/ or apps/site/), not in node_modules or build output. Folder paths relative, '' = root. #>
    $root = $ProjectRoot.TrimEnd('\')
    $out = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@{ dir = $root; depth = 0 })
    while ($queue.Count) {
        $d = $queue.Dequeue()
        $rel = if ($d.dir.Length -gt $root.Length) { $d.dir.Substring($root.Length + 1).Replace('\', '/') } else { '' }
        if ($rel -and $rel -match $script:SkipDir) { continue }
        if (Test-Path -LiteralPath (Join-Path $d.dir 'package.json') -PathType Leaf) { $out.Add($rel) }
        if ($d.depth -lt 2) { foreach ($sub in [IO.Directory]::GetDirectories($d.dir)) { $queue.Enqueue(@{ dir = $sub; depth = $d.depth + 1 }) } }
    }
    $out.ToArray()
}

function Test-PackageInstalled([string]$ProjectRoot, [string]$Folder, [string]$Name) {
    # In the folder's node_modules, or one further up (workspaces put packages in the root).
    $dir = if ($Folder) { Join-Path $ProjectRoot $Folder.Replace('/', '\') } else { $ProjectRoot }
    $root = $ProjectRoot.TrimEnd('\')
    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $dir ('node_modules\' + $Name.Replace('/', '\') + '\package.json')) -PathType Leaf) { return $true }
        if ($dir.TrimEnd('\') -eq $root) { return $false }
        $dir = Split-Path -Parent $dir
        if (-not $dir -or $dir.Length -lt $root.Length) { return $false }
    }
}

function Get-PackageState {
    <# Per package.json: @{ folder ('' = root); total (dependencies + devDependencies); missing
       (names not in node_modules); lock (a package-lock.json is there); error (not valid JSON) }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    foreach ($folder in @(Find-PackageFiles $ProjectRoot)) {
        $file = Join-Path $ProjectRoot (($(if ($folder) { "$folder/" } else { '' }) + 'package.json').Replace('/', '\'))
        $names = @()
        try {
            $j = [IO.File]::ReadAllText($file) | ConvertFrom-Json
            foreach ($k in 'dependencies', 'devDependencies') {
                if ($j.$k) { $names += @($j.$k.PSObject.Properties | ForEach-Object { $_.Name }) }
            }
        } catch {
            [pscustomobject]@{ folder = $folder; total = 0; missing = @(); lock = $false; error = 'package.json is not valid JSON' }
            continue
        }
        $names = @($names | Select-Object -Unique)
        $missing = @($names | Where-Object { -not (Test-PackageInstalled $ProjectRoot $folder $_) })
        $lock = Test-Path -LiteralPath (Join-Path (Split-Path $file) 'package-lock.json')
        [pscustomobject]@{ folder = $folder; total = $names.Count; missing = $missing; lock = $lock; error = '' }
    }
}

function Get-PackagesKey($State) {
    # What a "packages needed" card was shown for: folder and the missing names, so it comes back
    # only when something else is missing.
    "$($State.folder)|$(@($State.missing | Sort-Object) -join ',')"
}

function Format-PackageNeed($Item) {
    <# One line for the card: "web/: 12 of 14 packages are not installed yet (react, vite, ...)". #>
    $where = if ($Item.folder) { "$($Item.folder)/: " } else { '' }
    $some = @($Item.missing | Select-Object -First 4)
    $more = @($Item.missing).Count - $some.Count
    "$where$(@($Item.missing).Count) of $($Item.total) package(s) are not installed yet ($($some -join ', ')$(if ($more -gt 0) { ", and $more more" }))"
}

function Get-NpmInstallCommand([string]$Folder) {
    # npm install for one package.json; quiet about funding and audit (they need extra requests).
    $cmd = 'npm install --no-fund --no-audit'
    if ($Folder) { $cmd += ' --prefix "' + $Folder + '"' }
    $cmd
}

Export-ModuleMember -Function Find-PackageFiles, Test-PackageInstalled, Get-PackageState, Get-PackagesKey, Format-PackageNeed, Get-NpmInstallCommand
