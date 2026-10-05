# The scripts inside an HTML page are checked like .js files (Executor Get-InlineScripts, Agent
# Test-ScriptSyntax), and commands that cannot check them here are refused with that explanation
# (Executor Get-UselessCheckCommand). File names are made up.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

Describe 'Get-InlineScripts' {
    It 'returns the JavaScript blocks of a page with the line each starts on' {
        $html = "<html>`n<head>`n<script src=`"app.js`"></script>`n<script type=`"application/json`">{`"a`": 1}</script>`n</head>`n<body>`n<script>`nlet a = 1;`n</script>`n<script type=`"module`">import x from './x.js';</script>`n</body>`n</html>"
        $parts = @(Get-InlineScripts $html)
        $parts.Count | Should Be 2
        $parts[0].line | Should Be 7
        $parts[0].code | Should Match 'let a = 1;'
        $parts[1].line | Should Be 10
    }
    It 'returns nothing for a page without inline scripts' {
        @(Get-InlineScripts '<p>no scripts</p>').Count | Should Be 0
    }
}

Describe 'Get-UselessCheckCommand' {
    It 'refuses node --check on a page and bash here-strings, with what to do instead' {
        Get-UselessCheckCommand 'node --check index.html' | Should Match 'only reads JavaScript files .* compiles the scripts'
        Get-UselessCheckCommand 'powershell -NoProfile -Command "$m = 1; node -e `"x`" <<< $m"' | Should Match 'bash here-string'
    }
    It 'leaves useful commands alone' {
        Get-UselessCheckCommand 'node --check src/app.js' | Should BeNullOrEmpty
        Get-UselessCheckCommand 'npm test' | Should BeNullOrEmpty
        Get-UselessCheckCommand "powershell -Command `"Write-Output '<<<'`"" | Should BeNullOrEmpty
    }
}
