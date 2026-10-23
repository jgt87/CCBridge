<#
.SYNOPSIS
    Development check: which third-party code StreamHub ships has a newer version that could be
    shipped. Reads the shipped version of each part from its own file (so this list never goes
    stale), asks npm's registry for the newest release, and reports per part: shipped, newest, how
    big the step is (major, minor, patch) and the tool that updates it.
.DESCRIPTION
    Shipped parts:
      - UI kit engines: pdf.js, sql.js, Pyodide (templates/ui-kit/vendor/*/README.txt)
      - the built-in builder: esbuild-wasm, TypeScript, React (templates/build/VERSIONS.txt)
      - the UI kit's icons: Lucide (templates/ui-kit/icons/lucide-icons.json)
      - the app's own npm packages, bundled into ui/ (ui-src/package.json, the installed versions)
    Run by the release gate (informational, never blocks) and weekly by
    .github/workflows/dependency-check.yml, which keeps one issue up to date.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-deps.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-deps.ps1 -Markdown report.md
#>
param(
    [string]$Markdown,        # also write the report as Markdown to this file
    [switch]$FailOnNewer,     # exit 1 when anything has a newer release (for a scheduled job)
    [switch]$Quiet,           # only the summary line and the parts with a newer release
    [switch]$Offline          # no registry requests: only reads the shipped versions (for tests)
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Read-Marker([string]$Rel, [string]$Pattern) {
    # The first capture of a pattern in a repository file, or '' when the file or the match is missing.
    $p = Join-Path $repo $Rel
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    $m = [regex]::Match([IO.File]::ReadAllText($p), $Pattern, 'Multiline')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

function ConvertTo-Parts([string]$Version) {
    # "1.14.2" -> 1, 14, 2 (pre-release text dropped); empty for no version.
    $m = [regex]::Match("$Version", '(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $m.Success) { return @() }
    @([int]$m.Groups[1].Value, $(if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 }), $(if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }))
}

function Get-UpdateStep([string]$Shipped, [string]$Newest) {
    # current, patch, minor, major, or unknown when either version cannot be read.
    $a = @(ConvertTo-Parts $Shipped); $b = @(ConvertTo-Parts $Newest)
    if (-not $a.Count -or -not $b.Count) { return 'unknown' }
    for ($i = 0; $i -lt 3; $i++) {
        if ($b[$i] -gt $a[$i]) { return @('major', 'minor', 'patch')[$i] }
        if ($b[$i] -lt $a[$i]) { return 'current' }   # shipped is ahead (a pre-release or a newer tag)
    }
    'current'
}

$registryCache = @{}
function Get-NpmLatest([string]$Package) {
    # The "latest" release npm's registry lists for a package, or '' when it cannot be reached.
    if ($Offline) { return '' }
    if ($registryCache.ContainsKey($Package)) { return $registryCache[$Package] }
    $url = 'https://registry.npmjs.org/' + $Package.Replace('/', '%2F') + '/latest'
    $v = try { "$((Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 20).version)" } catch { '' }
    $registryCache[$Package] = $v
    $v
}

# Parts StreamHub ships, each with the file that says its version and the tool that updates it.
$vendorTool = 'node tools/update-kit-vendor.mjs (sql.js, Pyodide); pdf.js by hand into templates/ui-kit/vendor/pdfjs'
$buildTool = 'node tools/update-build-tools.mjs (after npm install in ui-src)'
$parts = @(
    @{ name = 'pdf.js'; package = 'pdfjs-dist'; where = 'UI kit (PDF reading)'; shipped = (Read-Marker 'templates/ui-kit/vendor/pdfjs/README.txt' '^pdf\.js (\S+)'); update = $vendorTool }
    @{ name = 'sql.js'; package = 'sql.js'; where = 'UI kit (SQL in the page)'; shipped = (Read-Marker 'templates/ui-kit/vendor/sqljs/README.txt' '^sql\.js (\S+)'); update = $vendorTool }
    @{ name = 'Pyodide'; package = 'pyodide'; where = 'UI kit (Python in the page)'; shipped = (Read-Marker 'templates/ui-kit/vendor/pyodide/README.txt' '^Pyodide ([\d.]+)'); update = $vendorTool }
    @{ name = 'Lucide icons'; package = 'lucide-static'; where = 'UI kit (icons)'; shipped = (Read-Marker 'templates/ui-kit/icons/lucide-icons.json' '"version":"([^"]+)"'); update = 'tools\update-lucide.ps1' }
)
foreach ($pkg in 'esbuild-wasm', 'typescript', 'react', 'react-dom', 'scheduler', '@types/react', '@types/react-dom') {
    $parts += @{ name = $pkg; package = $pkg; where = 'built-in builder'; shipped = (Read-Marker 'templates/build/VERSIONS.txt' ('^' + [regex]::Escape($pkg) + ' (\S+)')); update = $buildTool }
}
# The app's own packages: the version the lock file pins (what the build bundles; no npm install
# needed, so the weekly job can read it), else the installed one, else the range's lower bound.
$pj = Join-Path $repo 'ui-src\package.json'
$lockFile = Join-Path $repo 'ui-src\package-lock.json'
$lock = if (Test-Path -LiteralPath $lockFile) { try { ([IO.File]::ReadAllText($lockFile) | ConvertFrom-Json).packages } catch { $null } } else { $null }
if (Test-Path -LiteralPath $pj) {
    $json = [IO.File]::ReadAllText($pj) | ConvertFrom-Json
    foreach ($section in 'dependencies', 'devDependencies') {
        if (-not $json.$section) { continue }
        foreach ($d in $json.$section.PSObject.Properties) {
            $locked = if ($lock) { $lock.PSObject.Properties["node_modules/$($d.Name)"] } else { $null }
            $installed = Join-Path $repo ("ui-src\node_modules\" + $d.Name.Replace('/', '\') + '\package.json')
            $ver = if ($locked -and $locked.Value.version) { "$($locked.Value.version)" }
                   elseif (Test-Path -LiteralPath $installed) { "$(([IO.File]::ReadAllText($installed) | ConvertFrom-Json).version)" }
                   else { "$($d.Value)" -replace '^[\^~>=<\s]+', '' }
            $parts += @{ name = $d.Name; package = $d.Name; where = $(if ($section -eq 'dependencies') { 'app (bundled into ui/)' } else { 'app build and tests (not shipped)' }); shipped = $ver
                update = 'cd ui-src; npm install PACKAGE@latest; npm run build; npm test' }
        }
    }
}

$rows = foreach ($p in $parts) {
    $newest = Get-NpmLatest $p.package
    $step = if (-not $p.shipped) { 'unknown' } elseif (-not $newest) { 'unreachable' } else { Get-UpdateStep $p.shipped $newest }
    [pscustomobject]@{ Part = $p.name; Where = $p.where; Shipped = $(if ($p.shipped) { $p.shipped } else { '?' }); Newest = $(if ($newest) { $newest } else { '?' }); Step = $step; Update = $p.update }
}
$rows = @($rows)
$newer = @($rows | Where-Object { $_.Step -in 'major', 'minor', 'patch' })
$unread = @($rows | Where-Object { $_.Step -in 'unknown', 'unreachable' })

$order = @{ major = 0; minor = 1; patch = 2; unknown = 3; unreachable = 4; current = 5 }
$sorted = @($rows | Sort-Object { $order[$_.Step] }, Part)
$shown = if ($Quiet) { @($sorted | Where-Object { $_.Step -ne 'current' }) } else { $sorted }
if ($shown.Count) { $shown | Format-Table Part, Where, Shipped, Newest, Step -AutoSize | Out-String -Width 160 | Write-Host }
$summary = "Dependencies: $($newer.Count) of $($rows.Count) have a newer release ($(@($newer | Where-Object Step -eq 'major').Count) major, $(@($newer | Where-Object Step -eq 'minor').Count) minor, $(@($newer | Where-Object Step -eq 'patch').Count) patch)$(if ($unread.Count) { "; $($unread.Count) could not be checked" })."
Write-Host $summary

if ($Markdown) {
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine('# Dependency check')
    [void]$md.AppendLine()
    [void]$md.AppendLine("$summary Checked $((Get-Date).ToString('yyyy-MM-dd')) against npm's registry.")
    [void]$md.AppendLine()
    [void]$md.AppendLine('A newer release is not shipped automatically: update it with the tool named, run the tests, and check the part in a project before the next release. A major step can change behaviour.')
    [void]$md.AppendLine()
    [void]$md.AppendLine('| Part | Where | Shipped | Newest | Step | How to update |')
    [void]$md.AppendLine('|---|---|---|---|---|---|')
    foreach ($r in $sorted) { [void]$md.AppendLine("| $($r.Part) | $($r.Where) | $($r.Shipped) | $($r.Newest) | $($r.Step) | $($r.Update.Replace('|', '/')) |") }
    [IO.File]::WriteAllText($Markdown, $md.ToString(), (New-Object Text.UTF8Encoding($false)))
}
if ($FailOnNewer -and $newer.Count) { exit 1 }
exit 0
