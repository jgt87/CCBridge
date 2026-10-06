# WCAG contrast (lib/Contrast.psm1): the ratio, the UI kit's colour pairs in light and dark, and a
# tokens.css change that makes a pair unreadable (Guardrails Find-UiSlop). The page-side check
# (lib/contrast-check.js) runs in Edge during the page check.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Contrast.psm1') -Force
Import-Module (Join-Path $root 'lib\Guardrails.psm1') -Force

Describe 'Get-ContrastRatio' {
    It 'gives the WCAG ratios for known pairs' {
        Get-ContrastRatio '#000000' '#ffffff' | Should Be 21
        Get-ContrastRatio '#ffffff' '#ffffff' | Should Be 1
        Get-ContrastRatio '#767676' '#ffffff' | Should Be 4.54    # the lightest grey that passes on white
        Get-ContrastRatio 'rgb(0, 0, 0)' 'rgba(255, 255, 255, 1)' | Should Be 21
    }
    It 'mixes a see-through colour onto the background first' {
        Get-ContrastRatio 'rgba(0, 0, 0, 0.5)' '#ffffff' | Should BeLessThan 4.5
        Get-ContrastRatio 'rgba(0, 0, 0, 0)' '#ffffff' | Should Be 1
    }
    It 'reads short and long hex and rgb notations' {
        (ConvertFrom-CssColor '#abc').r | Should Be 170
        (ConvertFrom-CssColor '#10069f').b | Should Be 159
        (ConvertFrom-CssColor '#10069f80').a | Should BeGreaterThan 0.49
        ConvertFrom-CssColor 'var(--x)' | Should BeNullOrEmpty
    }
}

Describe 'The UI kit tokens' {
    $css = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\tokens.css'))
    It 'reads the light values and the dark ones (from the dark media block)' {
        $b = Get-TokenBlocks $css
        $b.light['--kit-accent'] | Should Be '#10069f'
        $b.dark['--kit-accent'] | Should Be '#00a3e0'   # light blue: the blue is too dark on a dark page
        $b.dark['--kit-font'] | Should Not BeNullOrEmpty   # dark keeps the light values it does not change
    }
    It 'are readable: every colour pair meets WCAG AA in light and dark' {
        @(Test-TokenContrast $css) | Should BeNullOrEmpty
    }
    It 'report a change that makes a pair unreadable, and only that change' {
        $bad = $css.Replace('--kit-text-muted: #5a5b5e;', '--kit-text-muted: #b0b0bc;')
        $r = @(Find-UiSlop 'styles/kit/tokens.css' $css $bad)
        ($r -join ' ') | Should Match 'contrast \(light\): muted text'
        @(Find-UiSlop 'styles/kit/tokens.css' $bad $bad) | Where-Object { $_ -match 'contrast' } | Should BeNullOrEmpty
    }
}
