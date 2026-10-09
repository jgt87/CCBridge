# Project pages served for the page check and "Open app" run code Copilot wrote. They are never the
# StreamHub page: the preview answers carry a sandbox policy (an opaque origin, so the session token
# in the app's page is out of reach and the API refuses "Origin: null"), and the app's own page loads
# nothing from the web (no remote images that could carry data out). What changes settings, the mode
# or the machine is for the person at the app's page only (its Origin), not for any token holder.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-origin-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'Agent', 'Server', 'CheckPolicy') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

function New-FakeCtx([string]$Method, [string]$Path, $Body = $null, [string]$Origin = '') {
    $bytes = [Text.Encoding]::UTF8.GetBytes($(if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 5 } else { '' }))
    $res = [pscustomobject]@{ StatusCode = 200; ContentType = ''; Headers = @{}; ContentLength64 = 0; OutputStream = (New-Object IO.MemoryStream) }
    $res | Add-Member -MemberType ScriptMethod -Name Close -Value { }
    $headers = @{}; if ($Origin) { $headers.Origin = $Origin }
    [pscustomobject]@{
        Request = [pscustomobject]@{ HttpMethod = $Method; Url = [Uri]"http://localhost:8765$Path"; Headers = $headers; InputStream = (New-Object IO.MemoryStream (, $bytes)); ContentEncoding = [Text.Encoding]::UTF8; ContentLength64 = $bytes.Length }
        Response = $res
    }
}
function Get-FakeJson($Ctx) { [Text.Encoding]::UTF8.GetString($Ctx.Response.OutputStream.ToArray()) | ConvertFrom-Json }

Describe 'Preview pages are not the StreamHub page' {
    $p = Join-Path $env:TEMP ('ccb-prev-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $p | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'index.html'), '<html><body>hi</body></html>')
    $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p
    It 'serves a project page in a sandbox without its own origin, readable by the page itself' {
        $c = New-FakeCtx 'GET' '/preview/x/index.html'
        & (Get-Module Server) { param($c, $st) Send-PreviewFile $c $st 'index.html' } $c $s
        $c.Response.StatusCode | Should Be 200
        $csp = $c.Response.Headers['Content-Security-Policy']
        $csp | Should Match '^sandbox\b'
        $csp | Should Match 'allow-scripts'
        $csp | Should Not Match 'allow-same-origin'
        $c.Response.Headers['Access-Control-Allow-Origin'] | Should Be '*'
    }
    It 'serves the app page with a policy that loads nothing from the web' {
        $ui = Join-Path $env:TEMP ('ccb-ui-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $ui | Out-Null
        [IO.File]::WriteAllText((Join-Path $ui 'index.html'), '<html><head></head><body></body></html>')
        try {
            $c = New-FakeCtx 'GET' '/'
            & (Get-Module Server) { param($c, $d) Send-StaticFile $c $d 'tok123' } $c $ui
            $csp = $c.Response.Headers['Content-Security-Policy']
            $csp | Should Match "default-src 'self'"
            $csp | Should Match "img-src 'self' data: blob:"
            $csp | Should Not Match 'img-src[^;]*http'
            $csp | Should Match "frame-src 'none'"
            [Text.Encoding]::UTF8.GetString($c.Response.OutputStream.ToArray()) | Should Match 'ccb-token" content="tok123"'
        } finally { Remove-Item $ui -Recurse -Force }
    }
    It 'treats a page that reads storage unguarded as a note, not a page error' {
        Get-CheckLevel 'index.html reads localStorage (app.js:3), and storage is not available where the helper program checks the page (nor in a private window): wrap it in try/catch so the page works without it' 'script' | Should Be 'warning'
    }
    Remove-Item $p -Recurse -Force
}

Describe 'Settings, mode, tools, links, undo and history change only from the app page' {
    $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.Config.port = 8765
    $page = 'http://localhost:8765'
    $calls = @(
        @{ path = '/api/mode'; body = @{ mode = 'auto' } },
        @{ path = '/api/settings'; body = @{ key = 'autoApproveCommands'; value = @('powershell') } },
        @{ path = '/api/settings/reset'; body = @{} },
        @{ path = '/api/logging'; body = @{ level = 'trace' } },
        @{ path = '/api/open-link'; body = @{ url = 'https://example.test/' } },
        @{ path = '/api/undo'; body = @{} },
        @{ path = '/api/history/clear'; body = @{} },
        @{ path = '/api/tools/install'; body = @{ tool = 'node' } }
    )
    It 'refuses the call without the page''s Origin (another program with the token, a preview page)' {
        foreach ($call in $calls) {
            foreach ($origin in '', 'null', 'http://127.0.0.1:8765') {
                $c = New-FakeCtx 'POST' $call.path $call.body $origin
                & (Get-Module Server) { param($c, $st) Invoke-ApiRequest $c $st } $c $s
                "$($call.path) [$origin]: $($c.Response.StatusCode)" | Should Be "$($call.path) [$origin]: 403"
                (Get-FakeJson $c).error | Should Match 'Only the StreamHub page'
            }
        }
        $s.Mode | Should Be 'ask'
    }
    It 'takes the mode from the page itself' {
        $c = New-FakeCtx 'POST' '/api/mode' @{ mode = 'auto' } $page
        & (Get-Module Server) { param($c, $st) Invoke-ApiRequest $c $st } $c $s
        $c.Response.StatusCode | Should Be 200
        $s.Mode | Should Be 'auto'
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
