<#
.SYNOPSIS
    Adds the current version of every UI kit file to templates/ui-kit/kit-history.json (SHA-256, LF
    and CRLF forms). A catalogue file with one of these hashes is StreamHub's, whatever its manifest
    says (UiKit Test-KitFileOwned). Run it after a change to a kit file; the release gate checks it.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$kit = Join-Path $root 'templates\ui-kit'
$file = Join-Path $kit 'kit-history.json'
$j = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) | ConvertFrom-Json } else { [pscustomobject]@{ note = ''; files = [pscustomobject]@{} } }
$map = @{}
foreach ($p in $j.files.PSObject.Properties) { $map[$p.Name] = New-Object 'System.Collections.Generic.SortedSet[string]' (, [string[]]@($p.Value)) }
$sha = [Security.Cryptography.SHA256]::Create()
$hex = { param($b) ([BitConverter]::ToString($sha.ComputeHash($b))).Replace('-', '').ToLowerInvariant() }
$added = 0
foreach ($f in Get-ChildItem -LiteralPath $kit -Recurse -File) {
    $rel = $f.FullName.Substring($kit.Length + 1).Replace('\', '/')
    if ($rel -match '^(vendor|icons)/' -or $rel -match '\.(json|png)$') { continue }
    $text = [IO.File]::ReadAllText($f.FullName)
    if (-not $map.ContainsKey($rel)) { $map[$rel] = New-Object 'System.Collections.Generic.SortedSet[string]' }
    $lf = $text.Replace("`r`n", "`n")
    foreach ($form in @([IO.File]::ReadAllBytes($f.FullName), [Text.Encoding]::UTF8.GetBytes($lf), [Text.Encoding]::UTF8.GetBytes($lf.Replace("`n", "`r`n")))) { if ($map[$rel].Add((& $hex $form))) { $added++ } }
}
$out = [ordered]@{ note = 'SHA-256 of every version of each kit file a StreamHub release shipped (LF and CRLF). A catalogue file with one of these hashes is StreamHub''s, whatever its manifest says. Kept up to date by tools/update-kit-history.ps1 (the release gate checks it).'; files = [ordered]@{} }
foreach ($k in @($map.Keys | Sort-Object)) { $out.files[$k] = @($map[$k]) }
[IO.File]::WriteAllText($file, (ConvertTo-Json $out -Depth 4), (New-Object Text.UTF8Encoding($false)))
Write-Host "kit-history.json: $added new hash(es)"
