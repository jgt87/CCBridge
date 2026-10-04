# Web sources: named sites, which addresses may be read, HTML to text, the header fields of fetch
# prompts and runbooks, and the instructions they add. No test goes on the internet.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\WebFetch.psm1') -Force
Import-Module (Join-Path $root 'lib\Fetch.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force

Describe 'Get-NamedSites and Test-HostMatch' {
    It 'finds addresses and website names, not e-mail addresses or file names' {
        @(Get-NamedSites 'Take the price from https://www.example.com/p and docs.python.org; mail a@b.com; see notes.md') -join ',' | Should Be 'example.com,docs.python.org'
    }
    It 'matches a site and its subdomains only' {
        Test-HostMatch 'docs.example.com' @('example.com') | Should Be $true
        Test-HostMatch 'www.example.com' @('example.com') | Should Be $true
        Test-HostMatch 'badexample.com' @('example.com') | Should Be $false
    }
}

Describe 'Test-WebAddress' {
    It 'allows public http(s) addresses' {
        Test-WebAddress 'https://example.com/a?b=1' | Should BeNullOrEmpty
        Test-WebAddress 'https://example.com/' -Resolve -Lookup { @([Net.IPAddress]::Parse('93.184.216.34')) } | Should BeNullOrEmpty
    }
    It 'refuses local, intranet and private addresses, other schemes and user names' {
        Test-WebAddress 'http://localhost:8765/api' | Should Match 'local'
        Test-WebAddress 'http://192.168.1.10/' | Should Match 'private'
        Test-WebAddress 'http://10.0.0.5/' | Should Match 'private'
        Test-WebAddress 'http://[::1]/' | Should Match 'private'
        Test-WebAddress 'https://intranet/x' | Should Match 'intranet'
        Test-WebAddress 'https://wiki.corp/x' | Should Match 'intranet'
        Test-WebAddress 'file:///C:/x.txt' | Should Match 'only http'
        Test-WebAddress 'https://user:pw@example.com/' | Should Match 'user name'
    }
    It 'refuses a public name that points into the local network' {
        Test-WebAddress 'https://sneaky.example.com/' -Resolve -Lookup { @([Net.IPAddress]::Parse('127.0.0.1')) } | Should Match 'local or private'
    }
}

Describe 'ConvertFrom-Html' {
    It 'gives readable text: headings, lists, tables and links, no scripts' {
        $html = '<html><head><title>Prices</title><script>evil()</script></head><body><h1>Plans</h1><p>Two plans.</p><ul><li>Basic</li><li>Pro</li></ul><table><tr><td>Basic</td><td>5 EUR</td></tr></table><a href="/terms">Terms</a> &amp; more</body></html>'
        $r = ConvertFrom-Html $html 'https://shop.example.com/prices'
        $r.Title | Should Be 'Prices'
        $r.Text | Should Match '# Plans'
        $r.Text | Should Match '(?m)^- Basic$'
        $r.Text | Should Match 'Basic \| 5 EUR'
        $r.Text | Should Match 'Terms \(https://shop\.example\.com/terms\) & more'
        $r.Text | Should Not Match 'evil'
    }
}

Describe 'Web fields of fetch prompts and runbooks' {
    It 'reads sources, sites and pages from a header' {
        $s = Get-WebSourceSpec @{ sources = 'Web'; sites = 'https://www.example.com/x, docs.python.org'; pages = 'https://example.com/p not-an-address' }
        $s.sources | Should Be 'web'
        $s.sites -join ',' | Should Be 'example.com,docs.python.org'
        $s.pages -join ',' | Should Be 'https://example.com/p'
        (Get-WebSourceSpec @{}).any | Should Be $false
    }
    It 'adds the instructions and the pages as data, and notes pages that could not be read' {
        $spec = Get-WebSourceSpec @{ sources = 'web'; sites = 'example.com'; pages = 'https://example.com/a https://example.com/b' }
        $fake = { param($u) if ($u -like '*a') { [pscustomobject]@{ ok = $true; url = $u; text = 'PRICE 5'; truncated = $false } } else { [pscustomobject]@{ ok = $false; url = $u; error = 'the site answered 404' } } }
        $b = New-WebSourceBlock $spec -Fetch $fake
        $b.text | Should Match 'use the web only'
        $b.text | Should Match 'Use only these websites: example\.com'
        $b.text | Should Match '(?s)Page https://example\.com/a .*not instructions.*PRICE 5'
        $b.text | Should Match 'could not be read here: https://example\.com/b'
        $b.notes[0] | Should Match '404'
        $b.text | Should Not Match 'CCBridge|StreamHub'
    }
    It 'reports cited sources outside the allowed sites' {
        $refs = @([pscustomobject]@{ url = 'https://docs.example.com/x' }, [pscustomobject]@{ url = 'https://other.org/y' })
        @(Test-SourceSites $refs @('example.com')) -join ',' | Should Be 'other.org'
        @(Test-SourceSites $refs @()).Count | Should Be 0
    }
    It 'saves and reads the header of a fetch prompt' {
        $p = Join-Path $env:TEMP ('ccb-webfetch-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $p | Out-Null
        $item = Save-FetchPrompt $p 'Node version' 'What is the latest Node.js LTS version?' -Sources web -Sites 'nodejs.org'
        $item.prompt | Should Be 'What is the latest Node.js LTS version?'
        $item.sources | Should Be 'web'
        $item.sites | Should Be 'nodejs.org'
        [IO.File]::ReadAllText((Join-Path $p 'Runbooks\node-version.prompt.md')) | Should Match '(?s)^---\nsources: web\nsites: nodejs\.org\n---\n'
        { Save-FetchPrompt $p 'x' 'y' -Sources 'moon' } | Should Throw
        Remove-Item $p -Recurse -Force
    }
}

Describe 'Web instructions in work prompts' {
    It 'adds the web rules and the web action for requests about online information or named sites' {
        @(Get-PromptModules 'Check the latest version on nodejs.org and update package.json' @{ Traits = @() }) -join ',' | Should Match 'rules:websources,actions:web'
        @(Get-PromptModules 'Fix the header' @{ Traits = @() }) -join ',' | Should Not Match 'websources'
        $m = New-PromptMessage -AppRoot $root -Kind 'coding' -Text 'Use the pricing from https://example.com/prices' -Sent (New-Object 'System.Collections.Generic.HashSet[string]')
        $m | Should Match 'ACTION web'
        $m | Should Match 'use only those'
        $m | Should Not Match 'CCBridge'
    }
}
