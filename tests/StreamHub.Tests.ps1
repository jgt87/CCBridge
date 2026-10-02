# StreamHub: replies delivered as a SignalR stream of type-2 items (some tenants).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Log.psm1') -Force
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force

function Rec([string]$Json) { $Json | ConvertFrom-Json }

Describe 'Add-StreamRecord' {
    It 'collects writeAtCursor chunks and ends on a result' {
        $s = New-StreamState
        Add-StreamRecord $s (Rec '{"type":2,"invocationId":"1","item":{"writeAtCursor":"Hello "}}')
        Add-StreamRecord $s (Rec '{"type":2,"invocationId":"1","item":{"writeAtCursor":"[x]: y"}}')
        $s.Done | Should Be $false
        Add-StreamRecord $s (Rec '{"type":2,"invocationId":"1","item":{"messages":[{"author":"bot","text":"Hello y"}],"result":{"value":"Success"},"throttling":{"numUserMessagesInConversation":1,"maxNumUserMessagesInConversation":30}}}')
        $s.Done | Should Be $true
        $s.Merger.Text | Should BeExactly 'Hello [x]: y'
        $s.Throttling.maxNumUserMessagesInConversation | Should Be 30
    }
    It 'finds the parts when they are nested deeper in the item' {
        $s = New-StreamState
        Add-StreamRecord $s (Rec '{"type":2,"item":{"event":{"payload":{"writeAtCursor":"abc"}}}}')
        Add-StreamRecord $s (Rec '{"type":2,"item":{"event":{"isFinal":true}}}')
        $s.Done | Should Be $true
        $s.Why | Should Be 'isFinal=true'
        $s.Merger.Text | Should BeExactly 'abc'
        $s.Keys -contains 'event.payload.writeAtCursor' | Should Be $true
    }
    It 'ends on a state field with a final value' {
        $s = New-StreamState
        Add-StreamRecord $s (Rec '{"type":2,"item":{"status":"Streaming","messages":[{"author":"bot","text":"Hi"}]}}')
        $s.Done | Should Be $false
        Add-StreamRecord $s (Rec '{"type":2,"item":{"status":"Completed"}}')
        $s.Done | Should Be $true
        $s.Merger.Text | Should BeExactly 'Hi'
    }
    It 'ends on a completion record after items, and reports a non-success result' {
        $s = New-StreamState
        Add-StreamRecord $s (Rec '{"type":3,"invocationId":"1"}')
        $s.Done | Should Be $false
        Add-StreamRecord $s (Rec '{"type":2,"item":{"writeAtCursor":"x"}}')
        Add-StreamRecord $s (Rec '{"type":3,"invocationId":"1"}')
        $s.Done | Should Be $true
        $t = New-StreamState
        Add-StreamRecord $t (Rec '{"type":2,"item":{"result":{"value":"OutOfCredits","message":"limit"}}}')
        $t.Done | Should Be $true
        $t.Why | Should Be 'result OutOfCredits'
    }
    It 'does not end on a success result without any text' {
        $s = New-StreamState
        Add-StreamRecord $s (Rec '{"type":2,"item":{"result":{"value":"Success"}}}')
        $s.Done | Should Be $false
    }
}
Describe 'Page texts that are not an answer' {
    $m = Get-Module CopilotBridge
    It 'recognises usage-limit banners' {
        (& $m { $args[0] -match $script:LimitPattern } "You've reached your daily limit. Get more usage now or check back at 2:00 AM.") | Should Be $true
        (& $m { $args[0] -match $script:LimitPattern } 'Here is the recursion explanation.') | Should Be $false
    }
    It 'recognises progress placeholders but not real answers' {
        $ell = [string][char]0x2026
        (& $m { $args[0] -match $script:PlaceholderPattern } ('Working on it' + $ell)) | Should Be $true
        (& $m { $args[0] -match $script:PlaceholderPattern } 'Taking a look...') | Should Be $true
        (& $m { $args[0] -match $script:PlaceholderPattern } 'Recursion is when a function calls itself to solve smaller parts of a problem.') | Should Be $false
    }
}