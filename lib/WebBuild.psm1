# StreamHub's built-in builder (templates/build): React and TypeScript apps built without Node.js or
# npm, in a hidden Edge tab. esbuild (WebAssembly) bundles the project's src/ into dist/app.js (a
# classic script, so the page also runs when opened from disk) and dist/app.css; TypeScript checks
# the types. Edge is the one program a locked-down work computer always lets run, so the compilers run
# inside it rather than as programs of their own. Used after each change of such a project (Agent),
# and by the project's Scripts/Build-App.ps1 while StreamHub is closed. Setting webBuild.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Cdp', 'Config') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:BuildEntries = @('src/main.tsx', 'src/main.jsx', 'src/main.ts', 'src/main.js', 'src/index.tsx', 'src/index.jsx', 'src/index.ts')
$script:BuildText = '(?i)\.(tsx?|jsx?|mjs|cjs|json|css)$'
$script:BuildBinary = '(?i)\.(svg|png|jpe?g|gif|webp|ico|woff2?|ttf|otf)$'

function Test-WebBuildOn([string]$AppRoot) {
    # Setting webBuild (on unless turned off). Read from disk, so every runspace sees a change.
    try { $v = (Get-CCBridgeConfig harness $AppRoot).webBuild; ($null -eq $v) -or [bool]$v } catch { $true }
}

function Get-WebBuildEntry([string]$ProjectRoot) {
    <# The app's entry file (src/main.tsx, .jsx, .ts, .js, or src/index.*), or $null. #>
    foreach ($e in $script:BuildEntries) { if (Test-Path -LiteralPath (Join-Path $ProjectRoot $e.Replace('/', '\')) -PathType Leaf) { return $e } }
    $null
}

function Test-WebBuildProject {
    <# A project StreamHub builds itself: it has an entry in src/, and it does not build with npm of its
       own (a package.json with a build script and its packages installed). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$AppRoot = '')
    if ($AppRoot -and -not (Test-WebBuildOn $AppRoot)) { return $false }
    if (-not (Get-WebBuildEntry $ProjectRoot)) { return $false }
    $pkg = Join-Path $ProjectRoot 'package.json'
    if ((Test-Path -LiteralPath $pkg) -and (Test-Path -LiteralPath (Join-Path $ProjectRoot 'node_modules'))) {
        $t = try { [IO.File]::ReadAllText($pkg) } catch { '' }
        if ($t -match '"build"\s*:') { return $false }
    }
    $true
}

function Get-WebBuildInput {
    <# The files esbuild and TypeScript get: everything under src/ they can use (text as text, images
       and fonts as base64), at most 2 MB a file and 25 MB in all. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = $ProjectRoot.TrimEnd('\')
    $files = @{}; $binary = @{}; $total = 0
    $src = Join-Path $root 'src'
    if (-not (Test-Path -LiteralPath $src)) { return @{ files = $files; binary = $binary } }
    foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($f.Length -gt 2MB -or $total + $f.Length -gt 25MB) { continue }
        if ($rel -match $script:BuildText) { $files[$rel] = [IO.File]::ReadAllText($f.FullName); $total += $f.Length }
        elseif ($rel -match $script:BuildBinary) { $files[$rel] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName)); $binary[$rel] = $true; $total += $f.Length }
    }
    @{ files = $files; binary = $binary }
}

function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p
}

function Invoke-WebBuild {
    <# Builds the project in a hidden Edge tab: in StreamHub's own Edge when it runs ($CdpPort), else in
       a headless Edge of its own. Writes dist/app.js (and dist/app.css) when the build works.
       Returns @{ ok; entry; written; errors; warnings; typeErrors; ms } (errors as @{ file; line; column; text }). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot, [switch]$TypeCheck, [int]$CdpPort = 0, [switch]$Minify)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $entry = Get-WebBuildEntry $ProjectRoot
    if (-not $entry) { return [pscustomobject]@{ ok = $false; entry = $null; written = @(); errors = @(@{ file = ''; line = 0; column = 0; text = 'no entry file: write src/main.tsx (or .jsx, .ts, .js)' }); warnings = @(); typeErrors = @(); ms = 0 } }
    $in = Get-WebBuildInput $ProjectRoot
    $payload = @{ entry = $entry; files = $in.files; binary = $in.binary; typecheck = [bool]$TypeCheck; minify = [bool]$Minify } | ConvertTo-Json -Depth 4 -Compress
    $page = 'file:///' + (Join-Path $AppRoot 'templates\build\build.html').Replace('\', '/')
    $own = $null; $port = $CdpPort; $target = $null; $s = $null
    try {
        if (-not $port -or -not (Test-CdpEndpoint $port)) {
            $port = Get-FreePort
            $own = Start-CdpEdge -Port $port -ProfileDir (Join-Path $env:LOCALAPPDATA 'CCBridge\build-edge') -Headless
        }
        $target = Invoke-RestMethod -Method Put "http://127.0.0.1:$port/json/new?about:blank"
        $s = Connect-Cdp $target.webSocketDebuggerUrl
        $null = Invoke-Cdp $s 'Runtime.enable'
        $null = Invoke-Cdp $s 'Page.navigate' @{ url = $page }
        $ready = $false
        for ($i = 0; $i -lt 80 -and -not $ready; $i++) {
            Start-Sleep -Milliseconds 250
            $ready = try { [bool](Invoke-Cdp $s 'Runtime.evaluate' @{ expression = '!!(window.KitBuild && window.KitBuild.ready)'; returnByValue = $true }).result.value } catch { $false }
        }
        if (-not $ready) { throw 'the builder page did not start in Edge' }
        $r = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = "KitBuild.run($payload)"; awaitPromise = $true; returnByValue = $true } -TimeoutMs 240000
        if ($r.exceptionDetails) { throw "the builder failed: $($r.exceptionDetails.exception.description)" }
        $res = ConvertFrom-Json "$($r.result.value)"
    } finally {
        if ($s) { try { Disconnect-Cdp $s } catch { } }
        if ($target) { try { $null = Invoke-RestMethod "http://127.0.0.1:$port/json/close/$($target.id)" } catch { } }
        if ($own) {
            $prof = Join-Path $env:LOCALAPPDATA 'CCBridge\build-edge'
            Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)" -like "*$prof*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    }
    $written = New-Object System.Collections.Generic.List[string]
    if ($res.ok) {
        foreach ($p in $res.outputs.PSObject.Properties) {
            $full = Join-Path $ProjectRoot $p.Name.Replace('/', '\')
            $old = if (Test-Path -LiteralPath $full) { [IO.File]::ReadAllText($full) } else { $null }
            if ($old -ne $p.Value) {
                $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
                [IO.File]::WriteAllText($full, $p.Value, (New-Object Text.UTF8Encoding($false)))
                $written.Add($p.Name)
            }
        }
    }
    Write-CCBLog info build 'Built-in build' @{ project = $ProjectRoot; ok = [bool]$res.ok; errors = @($res.errors).Count; typeErrors = @($res.typeErrors).Count; ms = $watch.ElapsedMilliseconds }
    [pscustomobject]@{ ok = [bool]$res.ok; entry = $entry; written = $written.ToArray(); errors = @($res.errors); warnings = @($res.warnings); typeErrors = @($res.typeErrors); ms = $watch.ElapsedMilliseconds }
}

function Format-WebBuildProblems {
    <# The build's errors and type errors as "FILE:LINE: text" lines (at most 20). #>
    param($Result)
    @(@($Result.errors) + @($Result.typeErrors) | Where-Object { $_ } | Select-Object -First 20 | ForEach-Object {
        if ($_.file) { "$($_.file):$($_.line): $($_.text)" } else { "$($_.text)" }
    })
}

function Get-BuildScriptText([string]$AppRoot) {
    <# Scripts/Build-App.ps1 for the project: builds it with StreamHub's builder while StreamHub is closed. #>
    @"
<#
  Builds this app (src/ into dist/app.js and dist/app.css) with StreamHub's built-in builder, which
  runs in Edge: no Node.js or npm needed. StreamHub does this by itself after every change; run this
  script when you changed files yourself while StreamHub was closed. Written by StreamHub.
#>
`$ErrorActionPreference = 'Stop'
`$app = '$($AppRoot.Replace("'", "''"))'
`$project = Split-Path -Parent `$PSScriptRoot
Import-Module (Join-Path `$app 'lib\WebBuild.psm1')
`$r = Invoke-WebBuild -ProjectRoot `$project -AppRoot `$app -TypeCheck
foreach (`$p in @(Format-WebBuildProblems `$r)) { Write-Output `$p }
if (`$r.ok) { Write-Output "Built: `$((`$r.written) -join ', ') (`$(`$r.ms) ms)" } else { exit 1 }
"@
}

function Write-BuildScript {
    <# Writes Scripts/Build-App.ps1 when it is missing or StreamHub's copy changed. Returns its path or ''. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot)
    $path = Join-Path $ProjectRoot 'Scripts\Build-App.ps1'
    $text = Get-BuildScriptText $AppRoot
    $old = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { $null }
    if ($null -ne $old -and ($old -eq $text -or $old -notmatch 'Written by StreamHub')) { return '' }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $path)
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($true)))
    'Scripts/Build-App.ps1'
}

Export-ModuleMember -Function Test-WebBuildOn, Get-WebBuildEntry, Test-WebBuildProject, Get-WebBuildInput, Invoke-WebBuild, Format-WebBuildProblems, Get-BuildScriptText, Write-BuildScript
