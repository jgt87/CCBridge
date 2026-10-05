<#
  Which parts of HTML tags reach StreamHub unchanged from Copilot. Some replies arrive with tags
  damaged (for example <script src="x.js"></script> as "x.jsscript>"): this test asks Copilot to
  repeat a block of made-up HTML lines exactly and compares, line by line, what arrived. It runs the
  same question once per route: the normal route, and the page route (the reply read from Copilot's
  page, as some tenants deliver it), so the report shows where the damage happens.
  Uses one Copilot message per route, in new chats. Only made-up lines are sent and reported.
  Report: C:\temp\StreamHub-html-echo-<time>.txt
#>
param([ValidateSet('both', 'normal', 'page')][string]$Route = 'both', [string]$OutRoot = 'C:\temp')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Log', 'Config', 'Cdp', 'CopilotBridge') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$cfg = Get-CCBridgeConfig harness $root
Initialize-CCBLog -Level info -Config $cfg

# Made-up lines covering the tags and characters that get damaged.
$expected = @(
    '<script src="data/example-manifest.js"></script>'
    '<script src="app.js" defer></script>'
    '<script>window.exampleData = { "a": 1 };</script>'
    '<link rel="stylesheet" href="styles.css">'
    '<style>body { color: #333; }</style>'
    '<img src="images/logo.png" alt="Logo">'
    '<a href="report.html">Report</a>'
    '<iframe src="frame.html" title="Frame"></iframe>'
    '<button onclick="go()">Go</button>'
    '<input type="text" name="q" placeholder="Search">'
    '<!-- a comment -->'
    '<div class="card">Text &amp; more</div>'
    'if (a < b && c > d) { x = [1, 2]; }'
    '$m = [regex]::Match($t, "x")'
)
$fence = '````'
$prompt = "Repeat the text inside the block below exactly, character for character, inside one ${fence}text block, with no other words before or after it and no changes. Write real less-than and greater-than characters, not &lt; or &gt;.`n`n${fence}text`n" + ($expected -join "`n") + "`n${fence}"

$null = New-Item -ItemType Directory -Force -Path $OutRoot
$out = Join-Path $OutRoot ('StreamHub-html-echo-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt')
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$t, [string]$Color = '') { if ($Color) { Write-Host $t -ForegroundColor $Color } else { Write-Host $t }; $lines.Add($t) }

function Get-EchoedLines([string]$Text) {
    # The lines of the first code block in the reply (the fence may be 3 or 4 backticks).
    $m = [regex]::Match($Text, '(?s)`{3,}[^\n]*\n(.*?)\n`{3,}')
    $body = if ($m.Success) { $m.Groups[1].Value } else { $Text }
    @($body.Replace("`r`n", "`n").Split("`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' })
}

Say "StreamHub HTML echo test, $((Get-Date).ToString('yyyy-MM-dd HH:mm')); $($expected.Count) made-up lines"
$routes = if ($Route -eq 'both') { @('normal', 'page') } else { @($Route) }
$bridge = Connect-Copilot -Port ([int]$cfg.cdpPort)
try {
    foreach ($rt in $routes) {
        Say ''
        Say "== Route: $rt"
        $env:CCBRIDGE_TEST_IGNORE_HUB = $(if ($rt -eq 'page') { '1' } else { '' })
        try {
            New-CopilotChat $bridge
            $r = Send-CopilotPrompt $bridge $prompt -TimeoutSec 180
            $src = if ($r.Source) { $r.Source } else { 'stream' }
            Say "   reply: $($r.Result), read from: $src, repaired merges: $([int]$r.Uncertain)"
            $got = @(Get-EchoedLines "$($r.Text)")
            $bad = 0; $esc = 0
            for ($i = 0; $i -lt $expected.Count; $i++) {
                $want = $expected[$i]
                $have = if ($i -lt $got.Count) { $got[$i] } else { '(missing)' }
                if ($have -ceq $want) { Say ("   ok       {0}" -f $want) }
                elseif (($have.Replace('&lt;', '<').Replace('&gt;', '>')) -ceq $want) { $esc++; Say ("   ESCAPED  {0}   (came back as &lt; / &gt;: the page escapes them in the question)" -f $want) 'DarkGray' }
                else { $bad++; Say ("   DAMAGED  sent: {0}" -f $want) 'Yellow'; Say ("            got:  {0}" -f $have) 'Yellow' }
            }
            if ($got.Count -gt $expected.Count) { Say "   (the reply had $($got.Count - $expected.Count) extra line(s))" }
            Say "   $bad of $($expected.Count) line(s) damaged, $esc only escaped (&lt; / &gt;)" $(if ($bad) { 'Yellow' } else { 'Green' })
        } catch { Say "   Error: $($_.Exception.Message)" 'Yellow' }
    }
} finally {
    $env:CCBRIDGE_TEST_IGNORE_HUB = ''
    Disconnect-Copilot $bridge
}
[IO.File]::WriteAllLines($out, $lines)
Write-Host ''
Write-Host "Saved: $out" -ForegroundColor Green
