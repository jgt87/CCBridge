# Files a person put in a new project: listed by type with their uses, the choice applied (data
# into Source/, roles kept), what is to be done now sent to Copilot, and every file asked about once.
# Made-up files.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\FileIntake.psm1') -Force

function New-IntakeProject {
    $p = Join-Path $env:TEMP ('ccb-intake-' + [guid]::NewGuid().ToString('N'))
    foreach ($f in 'sales.csv', 'notes/requirements.docx', 'brief.md', 'app/main.js', 'design/mockup.png', 'AGENTS.md', '.streamhub/project.json', 'styles/kit/kit.css', 'Source/old.csv', 'data/data-tools.js', 'data/sales.json', 'archive.zip') {
        $full = Join-Path $p $f; $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full); [IO.File]::WriteAllText($full, 'x')
    }
    [IO.File]::WriteAllText((Join-Path $p '.streamhub\data-imports.json'), '{ "version": 1, "items": [ { "output": "data/sales.json", "source": "sales.csv", "js": "data/sales.js" } ] }')
    $p
}

Describe 'Files in a new project' {
    It 'lists the person''s files by type, without the helper program''s own' {
        $p = New-IntakeProject
        try {
            $g = @(Get-IntakeGroups $p)
            ($g | ForEach-Object { "$($_.kind)=$(@($_.files) -join '+')" }) -join ' ' | Should Be 'data=sales.csv document=brief.md+notes/requirements.docx code=app/main.js image=design/mockup.png'
            ($g | Where-Object kind -eq 'data').default | Should Be 'source'
            @(($g | Where-Object kind -eq 'document').options | ForEach-Object { $_.value }) -join ',' | Should Be 'reference,page,summarise,keep'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'applies the choices, asks about each file once, and says what to do now' {
        $p = New-IntakeProject
        try {
            [IO.File]::WriteAllText((Join-Path $p 'Source\sales.csv'), 'already there')
            $r = Save-IntakeChoices $p @{ data = 'source'; document = 'summarise'; code = 'continue'; image = 'look' }
            @($r.moved) -join ',' | Should Be 'sales.csv -> Source/sales (2).csv'
            [IO.File]::ReadAllText((Join-Path $p 'Source\sales.csv')) | Should Be 'already there'
            Test-Path -LiteralPath (Join-Path $p 'sales.csv') | Should Be $false
            $r.request | Should Match '(?s)^I added these files.*- Summarise brief\.md, notes/requirements\.docx'
            $r.request | Should Not Match 'Analyse'
            @(Get-IntakeGroups $p).Count | Should Be 0
            $c = Format-IntakeContext $p
            $c | Should Match 'Data the user added for the app \(read-only in Source/; never change it\): Source/sales \(2\)\.csv'
            $c | Should Match 'Existing code the user added: build on it .*: app/main\.js'
            $c | Should Match 'Pictures of the look the user wants .*: design/mockup\.png'
            [IO.File]::WriteAllText((Join-Path $p 'later.csv'), 'x')
            @(Get-IntakeGroups $p | ForEach-Object { $_.files }) -join ',' | Should Be 'later.csv'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'sends nothing when everything is kept or only described, and refuses unknown choices' {
        Get-IntakeRequest @(@{ kind = 'data'; role = 'keep'; files = @('a.csv') }, @{ kind = 'document'; role = 'reference'; files = @('b.md') }) | Should Be ''
        Get-IntakeRequest @(@{ kind = 'data'; role = 'analyse'; files = @('a.csv') }) | Should Match 'Analyse the data in a\.csv.*Do not build anything yet'
        $p = New-IntakeProject
        try {
            $r = Save-IntakeChoices $p @{ data = 'delete-everything' }
            @($r.moved).Count | Should Be 0
            (Read-Intake $p).files['sales.csv'].role | Should Be 'keep'
        } finally { Remove-Item $p -Recurse -Force }
    }
}
