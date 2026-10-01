# Pester 3.4 (ships with Windows PowerShell 5.1). Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force
$fixtures = Join-Path $PSScriptRoot 'fixtures'

function Get-Fixture([string]$Name) {
    [IO.File]::ReadAllLines((Join-Path $fixtures $Name), [Text.Encoding]::UTF8)
}

Describe 'Cited sources (Work IQ / web)' {
    It 'lists sourceAttributions and references once, with title, url and kind' {
        $bot = '{"sourceAttributions":[{"providerDisplayName":"Q3 budget.xlsx","seeMoreUrl":"https://contoso.sharepoint.com/x","sourceType":"File"},{"providerDisplayName":"Q3 budget.xlsx","seeMoreUrl":"https://contoso.sharepoint.com/x","sourceType":"File"}],"references":[{"title":"RE: planning","type":"Email"},{"imageLink":"only-an-image"}]}' | ConvertFrom-Json
        $refs = @(& (Get-Module CopilotBridge) { param($b) Get-ReplyReferences $b } $bot)
        $refs.Count | Should Be 2
        $refs[0].title | Should Be 'Q3 budget.xlsx'
        $refs[0].kind | Should Be 'File'
        $refs[1].title | Should Be 'RE: planning'
        $refs[1].kind | Should Be 'Email'
    }

    It 'returns nothing for a reply without sources' {
        @(& (Get-Module CopilotBridge) { param($b) Get-ReplyReferences $b } ('{"text":"hi"}' | ConvertFrom-Json)).Count | Should Be 0
    }
}

Describe 'Reply reconstruction from Chathub frames' {
    It 'keeps bracketed code that Copilot''s link filter deletes' {
        $r = Get-ReplyFromFrames (Get-Fixture 'brackets.jsonl')
        $r.Text | Should Match ([regex]::Escape('[math]::Round($x[0], 2); $h = @{a=1}; Write-Host "[1] [^2] [link](http://x)"'))
        $r.ServerText | Should Not Match ([regex]::Escape('[math]::'))
        $r.Text.TrimEnd() | Should Match '```$'
    }

    It 'rebuilds a long code reply exactly, including indentation after a filtered line' {
        $r = Get-ReplyFromFrames (Get-Fixture 'python-inventory.jsonl')
        $r.Text | Should Match ([regex]::Escape("if quantity >= self.items[name]:`n            del self.items[name]"))
        $r.Text | Should Match ([regex]::Escape("if not self.items:`n            print(""Inventory is empty"")"))
        # Apart from the filtered line, the rebuilt text must equal the server's text.
        $r.Text.Replace("[name]:`n            ", '') | Should BeExactly $r.ServerText
    }
}
