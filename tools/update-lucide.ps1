<#
  Development tool: rebuilds the UI kit's icon set (templates/ui-kit/icons/) from the lucide-static
  npm package. Writes lucide-icons.json (icon name -> the SVG markup inside <svg>, Lucide's 24 x 24
  grid) and copies Lucide's licence. Run on a computer with npm:
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\update-lucide.ps1
  With -Package FOLDER it uses an unpacked package instead of downloading one.
#>
param([string]$Package)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = $null
if (-not $Package) {
    $work = Join-Path $env:TEMP ('lucide-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work
    Push-Location $work
    try {
        cmd /c "npm pack lucide-static --silent >nul 2>&1"
        $tgz = Get-ChildItem -Filter 'lucide-static-*.tgz' | Select-Object -First 1
        if (-not $tgz) { throw 'npm pack lucide-static failed (is npm installed and the registry reachable?)' }
        tar -xzf $tgz.Name
    } finally { Pop-Location }
    $Package = Join-Path $work 'package'
}
# Every icon file, aliases included (old names Lucide keeps working): the markup inside <svg>.
$files = @(Get-ChildItem (Join-Path $Package 'icons') -Filter *.svg | Sort-Object Name)
$version = ([IO.File]::ReadAllText((Join-Path $Package 'package.json')) | ConvertFrom-Json).version
$out = New-Object System.Text.StringBuilder
[void]$out.Append('{"version":"' + $version + '","icons":{')
$first = $true
foreach ($f in $files) {
    $svg = [IO.File]::ReadAllText($f.FullName)
    $m = [regex]::Match($svg, '(?s)<svg\b[^>]*>(.*)</svg>')
    if (-not $m.Success) { continue }
    $inner = [regex]::Replace($m.Groups[1].Value, '\s+', ' ').Replace(' />', '/>').Replace('> <', '><').Trim()
    $json = $inner | ConvertTo-Json -Compress
    if (-not $first) { [void]$out.Append(',') }
    [void]$out.Append('"' + $f.BaseName + '":' + $json)
    $first = $false
}
[void]$out.Append('}}')
$dir = Join-Path $root 'templates\ui-kit\icons'
$null = New-Item -ItemType Directory -Force -Path $dir
[IO.File]::WriteAllText((Join-Path $dir 'lucide-icons.json'), $out.ToString(), (New-Object Text.UTF8Encoding($false)))
$lic = "The UI kit's icons (icons/lucide-icons.json, and kit-icons.js in a project) are Lucide icons, version $version (https://lucide.dev), turned into compact markup. Their licence:`n`n" + [IO.File]::ReadAllText((Join-Path $Package 'LICENSE'))
[IO.File]::WriteAllText((Join-Path $root 'templates\ui-kit\LICENSE-lucide.txt'), $lic, (New-Object Text.UTF8Encoding($false)))
"Wrote $($files.Count) icons (Lucide $version) to templates\ui-kit\icons\lucide-icons.json"
if ($work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
