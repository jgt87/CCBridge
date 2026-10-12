# Files a person put in a new project before its first request: listed by type when the project
# opens, with what each type can be used for, so StreamHub and Copilot know what they are instead of
# guessing. A fixed table per file type (no model): data (the app's data in Source/, analyse it now),
# documents (reference for the work, a page or report made from them, a summary now), code (existing
# code to build on, an example only), images (used in the app, a picture of the look). The choice
# per type is kept in .streamhub/intake.json (each file asked about once), goes into the project
# context of every task (Format-IntakeContext), and what is to be done now goes to Copilot as one
# request (Get-IntakeRequest). Server Set-Project shows the card (event files-intake); POST
# /api/intake applies the choices. ASCII only (Windows PowerShell 5.1).

$script:IntakeKinds = @(
    @{ kind = 'data'; label = 'Data'; ext = '(?i)\.(csv|tsv|xlsx|xlsm|xls|json|xml)$'; default = 'source'
       options = @(
           @{ value = 'source'; label = 'Data for the app'; help = 'Moved into Source/: kept read-only, never changed; StreamHub converts it so Copilot can read it.' },
           @{ value = 'analyse'; label = 'Analyse it now'; help = 'Copilot looks at what it holds and what it could show, before anything is built.' },
           @{ value = 'keep'; label = 'Leave as is'; help = 'Nothing happens with it for now.' }) },
    @{ kind = 'document'; label = 'Documents'; ext = '(?i)\.(docx|doc|pptx|ppt|pdf|md|txt|rtf)$'; default = 'reference'
       options = @(
           @{ value = 'reference'; label = 'Reference for the work'; help = 'Copilot reads them when the work needs them (requirements, notes, examples); they are not changed.' },
           @{ value = 'page'; label = 'Make a page or report from them'; help = 'Copilot builds a web page or report with their content.' },
           @{ value = 'summarise'; label = 'Summarise them now'; help = 'Copilot sums up what they say.' },
           @{ value = 'keep'; label = 'Leave as is'; help = 'Nothing happens with them for now.' }) },
    @{ kind = 'code'; label = 'Code'; ext = '(?i)\.(m?js|cjs|tsx?|jsx|py|psm?1|html?|s?css|cs|java|go|php|rb|sql|vue|svelte|sh|bat|cmd)$'; default = 'continue'
       options = @(
           @{ value = 'continue'; label = 'Existing code to build on'; help = 'The project''s own code: Copilot continues it in its own style and structure.' },
           @{ value = 'example'; label = 'An example only'; help = 'Shows how something is done; it is not part of the app and is not changed.' },
           @{ value = 'keep'; label = 'Leave as is'; help = 'Nothing happens with it for now.' }) },
    @{ kind = 'image'; label = 'Images'; ext = '(?i)\.(png|jpe?g|gif|svg|webp|bmp)$'; default = 'asset'
       options = @(
           @{ value = 'asset'; label = 'Use them in the app'; help = 'Logos, icons or pictures the pages show.' },
           @{ value = 'look'; label = 'A picture of the look I want'; help = 'A screenshot or design: Copilot looks at it and builds that layout and style.' },
           @{ value = 'keep'; label = 'Leave as is'; help = 'Nothing happens with them for now.' }) }
)
# Not the person's own files: the helper program's folders and records, build output, the folders it keeps.
$script:IntakeSkip = '(?i)^(\.streamhub|\.git|node_modules|dist|build|out|Source|Work|Scripts|Runbooks|Logs|styles/kit)/|^data/data-(tools|index)\.js$|(^|/)\.[^/]+$|^AGENTS\.md$'

function Get-IntakePath([string]$ProjectRoot) { Join-Path $ProjectRoot '.streamhub\intake.json' }

function Read-Intake([string]$ProjectRoot) {
    # @{ files = @{ rel = @{ kind; role } } } from .streamhub/intake.json.
    $f = Get-IntakePath $ProjectRoot
    $files = @{}
    if (Test-Path -LiteralPath $f) {
        try { $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json; if ($o.files) { foreach ($p in $o.files.PSObject.Properties) { $files[$p.Name] = @{ kind = "$($p.Value.kind)"; role = "$($p.Value.role)" } } } } catch { }
    }
    @{ files = $files }
}

function Save-Intake([string]$ProjectRoot, $Intake) {
    $f = Get-IntakePath $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f)
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject @{ files = $Intake.files } -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

function Get-IntakeKind([string]$Rel) {
    foreach ($k in $script:IntakeKinds) { if ($Rel -match $k.ext) { return $k.kind } }
    ''
}

function Get-IntakeCandidates {
    <# The person's files of a known type not asked about yet (project-relative, with /): not the
       helper program's own folders and records, not what the data import wrote (its manifest). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [int]$Max = 2000)
    $known = (Read-Intake $ProjectRoot).files
    $generated = @{}
    $mf = Join-Path $ProjectRoot '.streamhub\data-imports.json'
    if (Test-Path -LiteralPath $mf) { try { foreach ($it in @(([IO.File]::ReadAllText($mf) | ConvertFrom-Json).items)) { foreach ($o in @($it.output, $it.js)) { if ($o) { $generated["$o".ToLowerInvariant()] = $true } } } } catch { } }
    $base = $ProjectRoot.TrimEnd('\').Length + 1
    @(foreach ($f in @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First $Max)) {
        $rel = $f.FullName.Substring($base).Replace('\', '/')
        if ($rel -match $script:IntakeSkip -or $known.ContainsKey($rel) -or $generated.ContainsKey($rel.ToLowerInvariant()) -or -not (Get-IntakeKind $rel)) { continue }
        $rel
    })
}

function Get-IntakeGroups {
    <# The person's files not asked about yet, by type: @(@{ kind; label; options; default; files; count }). #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $byKind = @{}
    foreach ($rel in @(Get-IntakeCandidates $ProjectRoot)) {
        $k = Get-IntakeKind $rel
        if (-not $byKind.ContainsKey($k)) { $byKind[$k] = New-Object System.Collections.Generic.List[string] }
        $byKind[$k].Add($rel)
    }
    @(foreach ($k in $script:IntakeKinds) {
        if (-not $byKind.ContainsKey($k.kind)) { continue }
        $files = @($byKind[$k.kind] | Sort-Object)
        [pscustomobject]@{ kind = $k.kind; label = $k.label; options = $k.options; default = $k.default; files = @($files | Select-Object -First 40); count = $files.Count }
    })
}

function Get-IntakeRequest($Chosen) {
    <# The request to Copilot for what the person wants done now: analyse data, summarise documents,
       or make a page or report from them. $Chosen: @(@{ kind; role; files }). '' when nothing. #>
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($Chosen)) {
        $list = (@($c.files) | Select-Object -First 20) -join ', '
        switch ("$($c.role)") {
            'analyse' { $lines.Add("- Analyse the data in $($list): what each file holds (its columns, the kinds of values, the size and period), what is notable, and what views or charts would make sense for it. Do not build anything yet.") }
            'summarise' { $lines.Add("- Summarise $($list): what each says, in a few points per file.") }
            'page' { $lines.Add("- Make a web page or report from $($list): its content in a clear layout, with the UI kit where the project has it.") }
        }
    }
    if (-not $lines.Count) { return '' }
    "I added these files to the project. Please do this with them:`n" + ($lines -join "`n")
}

function Save-IntakeChoices {
    <# Applies the person's choice per type: data used by the app is moved into Source/ (read-only;
       a file already there is never replaced: a numbered name), every file is recorded with its role
       so it is not asked about again. $Choices: @{ kind = role }. Returns @{ moved = @("FROM -> TO");
       request = text for Copilot or '' }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][hashtable]$Choices)
    $groups = @(Get-IntakeGroups $ProjectRoot)
    $candidates = @(Get-IntakeCandidates $ProjectRoot)
    $intake = Read-Intake $ProjectRoot
    $moved = New-Object System.Collections.Generic.List[string]
    $chosen = New-Object System.Collections.Generic.List[object]
    $all = @{}
    foreach ($g in $groups) {
        $def = $script:IntakeKinds | Where-Object { $_.kind -eq $g.kind } | Select-Object -First 1
        $role = "$($Choices[$g.kind])"
        if (-not $role -or -not @($def.options | Where-Object { $_.value -eq $role }).Count) { $role = 'keep' }
        # Every file of the type, not only the 40 the card showed.
        $files = @($candidates | Where-Object { (Get-IntakeKind $_) -eq $g.kind })
        $final = New-Object System.Collections.Generic.List[string]
        foreach ($rel in $files) {
            $target = $rel
            if ($role -eq 'source') {
                $dest = "Source/$rel"
                $full = Join-Path $ProjectRoot $dest.Replace('/', '\')
                $n = 2
                while (Test-Path -LiteralPath $full) { $dest = "Source/$([IO.Path]::GetDirectoryName($rel).Replace('\', '/'))/$([IO.Path]::GetFileNameWithoutExtension($rel)) ($n)$([IO.Path]::GetExtension($rel))".Replace('Source//', 'Source/'); $full = Join-Path $ProjectRoot $dest.Replace('/', '\'); $n++ }
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
                Move-Item -LiteralPath (Join-Path $ProjectRoot $rel.Replace('/', '\')) -Destination $full
                $moved.Add("$rel -> $dest"); $target = $dest
            }
            $intake.files[$target] = @{ kind = $g.kind; role = $role }
            $final.Add($target)
        }
        if ($final.Count) { $chosen.Add(@{ kind = $g.kind; role = $role; files = $final.ToArray() }) }
    }
    Save-Intake $ProjectRoot $intake
    @{ moved = $moved.ToArray(); request = (Get-IntakeRequest $chosen.ToArray()) }
}

function Format-IntakeContext([string]$ProjectRoot) {
    # The project-context lines for the files the person added and what they are for.
    $files = (Read-Intake $ProjectRoot).files
    if (-not $files.Count) { return '' }
    $by = @{}
    foreach ($k in $files.Keys) { $r = "$($files[$k].role)"; if (-not $by.ContainsKey($r)) { $by[$r] = New-Object System.Collections.Generic.List[string] }; $by[$r].Add($k) }
    $say = [ordered]@{
        source = 'Data the user added for the app (read-only in Source/; never change it)'
        reference = 'Reference documents the user added (read them when the work needs them; never change them)'
        continue = 'Existing code the user added: build on it in its own style and structure, not as a template to replace'
        example = 'Example code the user added for reference only (not part of the app; do not change it)'
        asset = 'Images the user added for the app (use them in the pages where they fit; keep the files where they are)'
        look = 'Pictures of the look the user wants (read them: they come as attachments; build that layout and style, with the UI kit where it applies)'
    }
    $lines = @(foreach ($r in $say.Keys) { if ($by.ContainsKey($r)) { "- $($say[$r]): $((@($by[$r]) | Sort-Object | Select-Object -First 25) -join ', ')$(if ($by[$r].Count -gt 25) { " and $($by[$r].Count - 25) more" })" } })
    $lines -join "`n"
}

Export-ModuleMember -Function Get-IntakeCandidates, Get-IntakeKind, Read-Intake, Save-Intake, Get-IntakeGroups, Get-IntakeRequest, Save-IntakeChoices, Format-IntakeContext
