# Protocol-level tests for mcp\ccbridge-mcp.ps1: starts the server as a child process and
# talks JSON-RPC over stdio. Needs no Copilot access (no tool here reaches Copilot).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$server = Join-Path $root 'mcp\ccbridge-mcp.ps1'

function Start-McpServer {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$server`""
    $psi.UseShellExecute = $false
$psi.EnvironmentVariables['CCBRIDGE_MCP_STANDALONE'] = '1'   # never hand the calls to a running web app
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.AutoFlush = $true
    $p
}

function Send-Rpc($Proc, [string]$Line) { $Proc.StandardInput.Write($Line + "`n") }

function Read-Rpc($Proc, [int]$TimeoutMs = 20000) {
    $t = $Proc.StandardOutput.ReadLineAsync()
    if (-not $t.Wait($TimeoutMs)) { throw 'no response from MCP server' }
    $t.Result
}

Describe 'CCBridge MCP server (stdio JSON-RPC)' {
    $proc = Start-McpServer

    It 'answers initialize with server info and the tools capability' {
        Send-Rpc $proc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pester","version":"1"}}}'
        $raw = Read-Rpc $proc 30000
        $r = $raw | ConvertFrom-Json
        $r.id | Should Be 1
        $r.result.serverInfo.name | Should Be 'ccbridge'
        $r.result.protocolVersion | Should Be '2025-06-18'
        $r.result.instructions | Should Match 'WHEN TO USE IT'
        $r.result.instructions | Should Not Match 'CCBridge'
        $null -ne $r.result.capabilities.tools | Should Be $true
    }

    It 'does not answer notifications, and lists nine tools with schemas, run_task first' {
        Send-Rpc $proc '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        Send-Rpc $proc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
        $r = (Read-Rpc $proc) | ConvertFrom-Json
        $r.id | Should Be 2   # the notification produced no line before this one
        $names = @($r.result.tools | ForEach-Object name)
        $names.Count | Should Be 9
        $names[0] | Should Be 'copilot_run_task'
        @($r.result.tools | Where-Object name -eq 'copilot_run_task')[0].inputSchema.required -join ',' | Should Be 'project_path,task'
        ($names -join ',') | Should Match 'copilot_ask'
        ($names -join ',') | Should Match 'copilot_start_task'
        @($r.result.tools | Where-Object { -not $_.inputSchema -or $_.inputSchema.type -ne 'object' }).Count | Should Be 0
        @($r.result.tools | Where-Object name -eq 'copilot_start_task')[0].inputSchema.required -join ',' | Should Be 'project_path,task'
    }

    It 'answers ping' {
        Send-Rpc $proc '{"jsonrpc":"2.0","id":3,"method":"ping"}'
        $r = (Read-Rpc $proc) | ConvertFrom-Json
        $r.id | Should Be 3
        $null -ne $r.result | Should Be $true
    }

    It 'reports tool errors as isError results, not protocol errors' {
        Send-Rpc $proc '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"copilot_task_status","arguments":{}}}'
        $r = (Read-Rpc $proc) | ConvertFrom-Json
        $r.result.isError | Should Be $true
        $r.result.content[0].text | Should Match 'Unknown job'

        Send-Rpc $proc '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"copilot_start_task","arguments":{"project_path":"relative\\dir","task":"x"}}}'
        $r = (Read-Rpc $proc) | ConvertFrom-Json
        $r.result.isError | Should Be $true
        $r.result.content[0].text | Should Match 'absolute'

        Send-Rpc $proc '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"copilot_approve","arguments":{"job_id":"job-nope","action_id":"1","decision":"approve"}}}'
        ((Read-Rpc $proc) | ConvertFrom-Json).result.content[0].text | Should Match 'Unknown job'
    }

    It 'returns JSON-RPC errors for unknown methods and unparsable input' {
        Send-Rpc $proc '{"jsonrpc":"2.0","id":7,"method":"does/not/exist"}'
        ((Read-Rpc $proc) | ConvertFrom-Json).error.code | Should Be -32601
        Send-Rpc $proc 'this is not json'
        ((Read-Rpc $proc) | ConvertFrom-Json).error.code | Should Be -32700
    }

    It 'exits cleanly when stdin closes and wrote nothing but JSON to stdout' {
        $proc.StandardInput.Close()
        $proc.WaitForExit(15000) | Should Be $true
        $rest = $proc.StandardOutput.ReadToEnd()
        $rest.Trim() | Should Be ''
        $proc.StandardError.ReadToEnd() | Should Match 'started'
    }

    if (-not $proc.HasExited) { $proc.Kill() }
}
