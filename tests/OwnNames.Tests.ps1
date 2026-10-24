# Names StreamHub and project code must not share: the UI kit's helpers that a window app dot-sources
# (Lint Find-KitHelperClashes, the __kit variable names in the helpers) and StreamHub's own CCBRIDGE_*
# environment variables, which never reach project code (Executor Remove-OwnEnvironment, the run
# window's batch).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\RunWindow.psm1') -Force

Describe 'A window app and the kit helpers it dot-sources' {
    $app = @'
. (Join-Path $PSScriptRoot 'styles\kit\wpf\KitWpf.ps1')
function Show-KitMessage($Text) { [Windows.MessageBox]::Show($Text) }
$script:__kitRoot = $PSScriptRoot
function Get-Rows { $__kitThemePath = 'local only'; @() }
$ui = New-KitWindow -Path (Join-Path $PSScriptRoot 'MainWindow.xaml')
'@
    It 'reports a function with a helper''s name and a helper''s variable set at script level, each at its line' {
        $f = @(Find-KitHelperClashes 'App.ps1' $app)
        $f.Count | Should Be 2
        $f[0] | Should Match '^line 2: function Show-KitMessage has the name of one of the UI kit''s helpers in KitWpf\.ps1'
        $f[1] | Should Match '^line 3: \$__kitRoot is a variable the UI kit''s helpers in KitWpf\.ps1 keep for themselves'
    }
    It 'leaves a script that does not load a helper, and the kit''s own files, alone' {
        @(Find-KitHelperClashes 'App.ps1' ($app -replace 'KitWpf\.ps1', 'Other.ps1')).Count | Should Be 0
        @(Find-KitHelperClashes 'styles/kit/wpf/KitWpf.ps1' $app).Count | Should Be 0
    }
    It 'knows the Windows Forms theme''s names too' {
        $forms = ". (Join-Path `$root 'styles\kit\winforms\KitTheme.ps1')`nfunction Set-KitFormStyle(`$c) { }`n`$__kitColors = @{}"
        $f = @(Find-KitHelperClashes 'Form.ps1' $forms)
        $f.Count | Should Be 2
        $f[0] | Should Match 'helpers in KitTheme\.ps1'
    }
    It 'is part of the file check, and only for what a change added' {
        @(Get-NewFileIssues 'App.ps1' '' $app | Where-Object { $_ -match 'UI kit''s helpers' }).Count | Should Be 2
        @(Get-NewFileIssues 'App.ps1' $app ($app + "`n`$x = 1") | Where-Object { $_ -match 'UI kit''s helpers' }).Count | Should Be 0
    }
    It 'keeps every variable the helpers set for themselves under the reserved __kit start' {
        foreach ($h in @(& (Get-Module Lint) { Get-KitHelperNames })) {
            $h.variables.Count | Should BeGreaterThan 0
            @($h.variables | Where-Object { $_ -notmatch '^__kit' }) | Should BeNullOrEmpty
        }
    }
}

Describe 'StreamHub''s own environment variables stay out of project code' {
    $project = Join-Path $env:TEMP ('ccb-env-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $project -Force | Out-Null
    It 'starts a command without them, and with the rest of the environment' {
        $env:CCBRIDGE_OWN_PROBE = 'secret'; $env:OTHER_PROBE = 'kept'
        try { $r = Invoke-RunAction $project 'echo [%CCBRIDGE_OWN_PROBE%] [%OTHER_PROBE%]' 30 }
        finally { Remove-Item Env:CCBRIDGE_OWN_PROBE, Env:OTHER_PROBE -ErrorAction SilentlyContinue }
        $r.output | Should Match '\[%CCBRIDGE_OWN_PROBE%\] \[kept\]'
        $env:CCBRIDGE_OWN_PROBE | Should BeNullOrEmpty   # StreamHub's own process keeps its environment as it was
    }
    It 'clears them at the start of a run window''s batch' {
        $env:CCBRIDGE_OWN_PROBE = 'secret'
        try { $b = New-RunWindowBatch $project 'npm test' 'C:\x.code' } finally { Remove-Item Env:CCBRIDGE_OWN_PROBE -ErrorAction SilentlyContinue }
        $b | Should Match '(?m)^set "CCBRIDGE_OWN_PROBE="\r?$'
        $b.IndexOf('set "CCBRIDGE_OWN_PROBE="') | Should BeLessThan $b.IndexOf('cmd /d /s /c "npm test"')
    }
    Remove-Item $project -Recurse -Force -ErrorAction SilentlyContinue
}
