# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests\KitTheme.Tests.ps1
# Theme from your colours: the kit's colour tokens derived from an accent (and a second colour and a
# neutral tint), readable in light and dark, written into the project's tokens.css and nothing else.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\KitTheme.psm1') -Force
Import-Module (Join-Path $root 'lib\Contrast.psm1') -Force
Import-Module (Join-Path $root 'lib\UiKit.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
$template = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\tokens.css'))

Describe 'Colour maths' {
    It 'turns a colour into HSL and back' {
        foreach ($c in '#10069f', '#ffd100', '#00a3e0', '#5a5b5e', '#ffffff', '#000000') {
            $h = ConvertTo-Hsl $c
            ConvertFrom-Hsl $h.h $h.s $h.l | Should Be $c
        }
    }
    It 'says nothing for a value that is not a colour' {
        ConvertTo-Hsl 'var(--kit-accent)' | Should Be $null
    }
}

Describe 'Tokens from the person''s colours' {
    It 'derives every colour token and the whole file passes the kit''s contrast check, light and dark' {
        foreach ($set in @(@('#10069f', '', ''), @('#e91e63', '#00bcd4', '#6b7280'), @('#2e7d32', '', '#8d6e63'), @('#888888', '', ''))) {
            $t = ConvertTo-ThemeTokens -Accent $set[0] -Accent2 $set[1] -Neutral $set[2] -Css $template
            $t.ok | Should Be $true
            foreach ($k in '--kit-accent', '--kit-accent-hover', '--kit-accent-soft', '--kit-on-accent', '--kit-accent-2', '--kit-gradient-from', '--kit-gradient-to', '--kit-on-gradient', '--kit-title', '--kit-icon', '--kit-chart-1', '--kit-chart-6') { $t.light.Contains($k) | Should Be $true }
            foreach ($k in '--kit-accent', '--kit-accent-hover', '--kit-accent-soft', '--kit-on-accent', '--kit-chart-1', '--kit-chart-6') { $t.dark.Contains($k) | Should Be $true }
            @(Test-TokenContrast (Set-ThemeText $template $t)).Count | Should Be 0
        }
    }
    It 'darkens a light accent until it reads, and says so' {
        $t = ConvertTo-ThemeTokens -Accent '#ffd100' -Css $template
        $t.ok | Should Be $true
        $t.light['--kit-accent'] | Should Not Be '#ffd100'
        (Get-ContrastRatio '#ffffff' $t.light['--kit-accent']) -ge 4.5 | Should Be $true
        (@($t.adjusted) -join ' ') | Should Match 'accent darkened from #ffd100'
        (Format-ThemeSummary $t) | Should Match 'Adjusted to read'
    }
    It 'gives neighbouring chart colours hues far apart' {
        $t = ConvertTo-ThemeTokens -Accent '#10069f' -Css $template
        @(Test-TokenContrast (Set-ThemeText $template $t) | Where-Object { $_ -match 'chart colours' }).Count | Should Be 0
    }
    It 'tints the neutrals only when a tint is given' {
        (ConvertTo-ThemeTokens -Accent '#10069f' -Css $template).light.Contains('--kit-bg') | Should Be $false
        $t = ConvertTo-ThemeTokens -Accent '#10069f' -Neutral '#6b7280' -Css $template
        $t.light.Contains('--kit-text-muted') | Should Be $true
        (Get-ContrastRatio $t.light['--kit-text-muted'] $t.light['--kit-surface-2']) -ge 4.5 | Should Be $true
    }
    It 'leaves a light-only project light only' {
        $light = Remove-DarkTokens $template
        $t = ConvertTo-ThemeTokens -Accent '#10069f' -Css $light
        $t.dark.Count | Should Be 0
        (Set-ThemeText $light $t) | Should Not Match 'prefers-color-scheme: dark'
        (Format-ThemeSummary $t) | Should Match 'light only'
    }
    It 'refuses a colour that is not one' {
        $t = ConvertTo-ThemeTokens -Accent 'blue-ish' -Css $template
        $t.ok | Should Be $false
        $t.error | Should Match 'not a colour'
    }
    It 'refuses with the reason when no shade can read' {
        $grey = $template -replace '--kit-bg: #000000;', '--kit-bg: #777777;' -replace '--kit-surface: #1b1b1c;', '--kit-surface: #777777;'
        $t = ConvertTo-ThemeTokens -Accent '#10069f' -Css $grey
        $t.ok | Should Be $false
        $t.error | Should Match 'dark mode'
    }
}

Describe 'Writing the theme' {
    It 'changes only the colour values, keeping every other line and the line breaks' {
        $crlf = $template.Replace("`r`n", "`n").Replace("`n", "`r`n")
        $t = ConvertTo-ThemeTokens -Accent '#e91e63' -Css $crlf
        $new = Set-ThemeText $crlf $t
        ([regex]::Matches($new, "(?<!`r)`n")).Count | Should Be 0
        $a = $crlf -split "`r`n"; $b = $new -split "`r`n"
        $b.Count | Should Be $a.Count
        $names = @(@($t.light.Keys) + @($t.dark.Keys) | Select-Object -Unique)
        for ($i = 0; $i -lt $a.Count; $i++) {
            if ($a[$i] -ceq $b[$i]) { continue }
            $m = [regex]::Match($a[$i], '^\s*(--kit-[\w-]+)\s*:')
            $m.Success | Should Be $true
            $names -contains $m.Groups[1].Value | Should Be $true
            ($b[$i] -replace ':\s*[^;]+;', ':;') | Should Be ($a[$i] -replace ':\s*[^;]+;', ':;')   # comments after the value stay
        }
        $new | Should Match '--kit-accent-tint-1: color-mix\(in srgb, var\(--kit-accent\) 8%'
        $new | Should Match '--kit-space-4: 1rem;'
    }

    $proj = Join-Path $env:TEMP ('ccb-theme-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $kit = Join-Path $proj 'styles\kit'
    $null = New-Item -ItemType Directory -Force -Path $kit
    $file = Join-Path $kit 'tokens.css'
    $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + (New-Object Text.UTF8Encoding($false)).GetBytes($template))
    [IO.File]::WriteAllBytes($file, $bytes)

    It 'writes the project''s tokens.css with its BOM, in one change set, and keeps the colours given' {
        $t = ConvertTo-ThemeTokens -Accent '#2e7d32' -Accent2 '#ff9800' -Css $template
        $r = Set-ProjectThemeTokens $proj $t
        $r.changed | Should Be $true
        $r.path | Should Be 'styles/kit/tokens.css'
        @($r.names) -contains '--kit-accent' | Should Be $true
        $r.checkpoint.Files['styles/kit/tokens.css'] | Should Be 'existed'
        $after = [IO.File]::ReadAllBytes($file)
        "$($after[0]),$($after[1]),$($after[2])" | Should Be '239,187,191'
        (Get-TokenBlocks ([IO.File]::ReadAllText($file))).light['--kit-accent'] | Should Be $t.light['--kit-accent']
        (Get-ProjectThemeInputs $proj).accent | Should Be '#2e7d32'
        (Get-ProjectThemeInputs $proj).accent2 | Should Be '#ff9800'
    }
    It 'stays the project''s own when a newer kit changes its defaults (the token base is left alone)' {
        $cur = [IO.File]::ReadAllText($file)
        $newDefault = $template.Replace('  --kit-accent: #10069f;', '  --kit-accent: #0a0a80;')
        $merged = Update-KitTokens $cur $template $newDefault
        (Get-TokenBlocks $merged).light['--kit-accent'] | Should Be (Get-TokenBlocks $cur).light['--kit-accent']
    }
    It 'is undone by Undo like any change set' {
        $null = Undo-LastCheckpoint $proj
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) | Should Be ([Convert]::ToBase64String($bytes))
        (Get-TokenBlocks ([IO.File]::ReadAllText($file))).light['--kit-accent'] | Should Be '#10069f'
    }
    It 'previews for the card without writing anything' {
        $before = [IO.File]::ReadAllText($file)
        $p = Get-ThemePreview $proj -Accent '#e91e63' -Neutral '#6b7280'
        $p.ok | Should Be $true
        $p.light['--kit-accent'] | Should Match '^#[0-9a-f]{6}$'
        $p.dark['--kit-accent'] | Should Match '^#[0-9a-f]{6}$'
        $p.summary | Should Match 'neutrals tinted'
        (ConvertTo-Json -InputObject $p -Depth 4) | Should Match '"--kit-chart-6"'
        [IO.File]::ReadAllText($file) | Should Be $before
        (Get-ThemePreview $proj -Accent 'nope').error | Should Match 'not a colour'
    }
    It 'refuses a project without the kit''s tokens' {
        $empty = Join-Path $env:TEMP ('ccb-theme-empty-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path $empty
        $t = ConvertTo-ThemeTokens -Accent '#2e7d32' -Css $template
        { Set-ProjectThemeTokens $empty $t } | Should Throw 'no styles/kit/tokens.css'
        Remove-Item -LiteralPath $empty -Recurse -Force
    }

    Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
