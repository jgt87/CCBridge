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