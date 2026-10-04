<#
.SYNOPSIS
    Summarises the STRUCTURE of Copilot's recent replies (no content), so the reply format of a tenant
    (for example StreamHub) can be supported without sharing any answer text.
.DESCRIPTION
    Reads the newest reply recordings in %LOCALAPPDATA%\CCBridge\replies (CCBridge keeps the last 30)
    and lists, per record type, every field path with its type, string lengths and how often and in
    which frames it occurs. Only short single-word values (status words such as "Completed",
    "Progress", "Success") and booleans are shown; all other text is replaced by its length.
    The summary is written to C:\temp\CCBridge-stream-shape-<date>.txt.
    -Path summarises one recording instead (agent-capture.ps1 uses it), -OutFile sets the file.
.EXAMPLE
    stream-shape.cmd
    stream-shape.cmd -Count 5
#>
param([int]$Count = 3, [string]$OutRoot = 'C:\temp', [string]$Path = '', [string]$OutFile = '')

$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'CCBridge\replies'
$files = if ($Path) { @(Get-Item -LiteralPath $Path) } else { @(Get-ChildItem $dir -Filter *.jsonl -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $Count) }
if (-not $files.Count) { Write-Host 'No reply recordings found. Ask Copilot something in StreamHub first, then run this again.' -ForegroundColor Yellow; exit 1 }

$sep = [char]0x1e
function Get-Shape($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return "bool:$Value" }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return 'number' }
    if ($Value -is [string]) {
        # Status-like single words are shown; everything else only as a length.
        if ($Value.Length -le 40 -and $Value -match '^[A-Za-z][A-Za-z_.]*$') { return "'$Value'" }   # letters only: no ids, numbers or codes
        return "text($($Value.Length))"
    }
    'object'
}
function Add-Paths($Node, [string]$Path, $Stats, [int]$Frame, [int]$Depth = 0) {
    if ($Depth -gt 8) { return }
    if ($Node -is [array]) {
        $key = "$Path[]"
        if (-not $Stats.ContainsKey("$key#count")) { $Stats["$key#count"] = New-Object System.Collections.Generic.List[int] }
        $Stats["$key#count"].Add($Node.Count)
        foreach ($el in ($Node | Select-Object -First 30)) { Add-Paths $el $key $Stats $Frame ($Depth + 1) }
        return
    }
    if ($Node -is [pscustomobject]) {
        foreach ($p in $Node.PSObject.Properties) { Add-Paths $p.Value $(if ($Path) { "$Path.$($p.Name)" } else { $p.Name }) $Stats $Frame ($Depth + 1) }
        return
    }
    $shape = Get-Shape $Node
    if (-not $Stats.ContainsKey($Path)) { $Stats[$Path] = @{ shapes = (New-Object 'System.Collections.Generic.HashSet[string]'); n = 0; first = $Frame; last = $Frame } }
    $e = $Stats[$Path]; $e.n++; $e.last = $Frame
    if ($e.shapes.Count -lt 12) { [void]$e.shapes.Add(($shape -replace 'text\(\d+\)', 'text')) }
    if ($shape -like 'text(*') { if (-not $e.lens) { $e.lens = New-Object System.Collections.Generic.List[int] }; $e.lens.Add([int]($shape -replace '\D', '')) }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("CCBridge reply structure $(Get-Date -Format 'yyyy-MM-dd HH:mm') - field names, types and status words only; no answer text.")
foreach ($f in $files) {
    $lines.Add(''); $lines.Add("=== $($f.Name) ($((Get-Content $f.FullName).Count) frames)")
    $byType = @{}
    $frame = 0
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
        $frame++
        $kinds = @()
        foreach ($part in $line.Split($sep)) {
            if (-not $part.Trim()) { continue }
            try { $o = $part | ConvertFrom-Json } catch { $kinds += 'non-json'; continue }
            $kind = if ($null -ne $o.type) { "type$($o.type)$(if ($o.target) { ":$($o.target)" })" } else { '{' + ((@($o.PSObject.Properties.Name) | Select-Object -First 4) -join ',') + '}' }
            $kinds += $kind
            if (-not $byType.ContainsKey($kind)) { $byType[$kind] = @{} }
            Add-Paths $o '' $byType[$kind] $frame
        }
        $order.Add("$frame`: $($kinds -join ' + ')")
    }
    $lines.Add('Frames in order:')
    foreach ($o in $order) { $lines.Add("  $o") }
    foreach ($kind in $byType.Keys) {
        $lines.Add(''); $lines.Add("-- $kind")
        $stats = $byType[$kind]
        foreach ($path in ($stats.Keys | Where-Object { $_ -notlike '*#count' } | Sort-Object)) {
            $e = $stats[$path]
            $len = if ($e.lens) { " len $(($e.lens | Measure-Object -Minimum).Minimum)-$(($e.lens | Measure-Object -Maximum).Maximum)" } else { '' }
            $lines.Add(("  {0} : {1}{2} (x{3}, frames {4}-{5})" -f $path, (@($e.shapes) -join ' | '), $len, $e.n, $e.first, $e.last))
        }
    }
}
$out = if ($OutFile) { $OutFile } else { $null = New-Item -ItemType Directory -Force -Path $OutRoot; Join-Path $OutRoot ("CCBridge-stream-shape-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt") }
[IO.File]::WriteAllLines($out, [string[]]$lines)
Write-Host "Written: $out" -ForegroundColor Green
Write-Host 'It contains field names, types, lengths and status words only - no answer text. Please send this file.'
