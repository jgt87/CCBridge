# API routes with logic of their own (lib/Server.psm1: Invoke-JobsApi, Invoke-ReviewApi), driven
# through Invoke-ApiRequest with a request as HttpListener gives it. /api/chat and
# /api/project-setup are tested in ProjectSetup.Tests.ps1. Made-up data; nothing reaches Copilot.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'Agent', 'Server') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

function New-FakeCtx([string]$Method, [string]$Path, $Body) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($(if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 5 } else { '' }))
    $res = [pscustomobject]@{ StatusCode = 200; ContentType = ''; Headers = @{}; ContentLength64 = 0; OutputStream = (New-Object IO.MemoryStream) }
    $res | Add-Member -MemberType ScriptMethod -Name Close -Value { }
    [pscustomobject]@{
        Request = [pscustomobject]@{ HttpMethod = $Method; Url = [Uri]"http://localhost:8765$Path"; Headers = @{ Origin = 'http://localhost:8765' }; InputStream = (New-Object IO.MemoryStream(, $bytes)); QueryString = @{} }
        Response = $res
    }
}
function Invoke-FakeApi($Ctx, $State) { & (Get-Module Server) { param($c, $st) Invoke-ApiRequest $c $st } $Ctx $State }
function Get-FakeJson($Ctx) { [Text.Encoding]::UTF8.GetString($Ctx.Response.OutputStream.ToArray()) | ConvertFrom-Json }
function New-TestState { $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.Config.port = 8765; $s }
function Get-QueuedTask($State) { $t = $null; $null = $State.Tasks.TryDequeue([ref]$t); $t }

Describe 'POST /api/jobs' {
    It 'queues an ask, a task in a new folder and a review, each with its job' {
        $p = Join-Path $env:TEMP ('ccb-jobs-' + [guid]::NewGuid().ToString('N'))
        try {
            $s = New-TestState
            $c = New-FakeCtx 'POST' '/api/jobs' @{ kind = 'ask'; text = 'Explain this'; thinkDeeper = $true; source = 'mcp' }
            Invoke-FakeApi $c $s
            $r = Get-FakeJson $c
            $r.ok | Should Be $true
            $r.job.id | Should Match '^job-[0-9a-f]{8}$'
            $t = Get-QueuedTask $s
            $t.kind | Should Be 'ask'
            $t.responseMode | Should Be 'deep'
            $t.jobId | Should Be $r.job.id
            $s.Jobs[$r.job.id].status | Should Be 'queued'

            $c = New-FakeCtx 'POST' '/api/jobs' @{ kind = 'task'; text = 'Add a page'; projectPath = $p; mode = 'plan' }
            Invoke-FakeApi $c $s
            Test-Path -LiteralPath $p -PathType Container | Should Be $true   # made for the task
            $t = Get-QueuedTask $s
            $t.kind | Should Be 'chat'
            $t.projectRoot | Should Be $p
            $t.mode | Should Be 'plan'
            $t.noCommands | Should Be $true      # commands only when allowCommands is sent
            $t.reviewByCaller | Should Be $true  # the calling model reviews unless copilotReview is sent
            $t.source | Should Be 'api'

            $c = New-FakeCtx 'POST' '/api/jobs' @{ kind = 'review'; projectPath = $p; paths = @('a.js') }
            Invoke-FakeApi $c $s
            $t = Get-QueuedTask $s
            $t.scope | Should Be 'paths'
            $t.reviewId | Should Match '^review-\d{8}-\d{6}$'
        } finally { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'refuses a job without text, a relative project path, an unknown mode or kind' {
        $s = New-TestState
        { Invoke-FakeApi (New-FakeCtx 'POST' '/api/jobs' @{ kind = 'ask'; text = ' ' }) $s } | Should Throw 'text is required'
        { Invoke-FakeApi (New-FakeCtx 'POST' '/api/jobs' @{ kind = 'task'; text = 'x'; projectPath = 'relative\folder' }) $s } | Should Throw 'absolute folder path'
        { Invoke-FakeApi (New-FakeCtx 'POST' '/api/jobs' @{ kind = 'task'; text = 'x'; projectPath = $env:TEMP; mode = 'yolo' }) $s } | Should Throw 'mode must be'
        { Invoke-FakeApi (New-FakeCtx 'POST' '/api/jobs' @{ kind = 'dance' }) $s } | Should Throw "Unknown job kind 'dance'"
        Get-QueuedTask $s | Should BeNullOrEmpty
    }
}

Describe 'POST /api/reviews/get|ignore|fix' {
    $p = Join-Path $env:TEMP ('ccb-review-' + [guid]::NewGuid().ToString('N'))
    $dir = Join-Path $p '.streamhub\Reviews'
    $id = 'review-20261024-101500'
    $json = Join-Path $dir "$id.json"
    $review = @{ id = $id; findings = @(
        @{ id = 'f1'; file = 'app.js'; line = 3; title = 'Unused variable'; quote = 'var unused = 1;'; status = 'verified' }
        @{ id = 'f2'; file = 'app.js'; line = 9; title = 'Missing check'; quote = 'return list[0].name;'; status = 'verified' }
    ) }
    It 'returns a saved review, and refuses an unknown id' {
        New-Item -ItemType Directory $dir -Force | Out-Null
        [IO.File]::WriteAllText($json, (ConvertTo-Json -InputObject $review -Depth 5))
        $s = New-TestState; $s.ProjectRoot = $p
        $c = New-FakeCtx 'POST' '/api/reviews/get' @{ id = $id }
        Invoke-FakeApi $c $s
        @((Get-FakeJson $c).review.findings).Count | Should Be 2
        { Invoke-FakeApi (New-FakeCtx 'POST' '/api/reviews/get' @{ id = '..\..\x' }) $s } | Should Throw 'Unknown review'
        { Invoke-FakeApi (New-FakeCtx 'POST' '/api/reviews/get' @{ id = 'review-1999' }) $s } | Should Throw 'Unknown review'
    }
    It 'ignores a finding, and queues fixes only for the ones not ignored' {
        $s = New-TestState; $s.ProjectRoot = $p
        Invoke-FakeApi (New-FakeCtx 'POST' '/api/reviews/ignore' @{ id = $id; ids = @('f1') }) $s
        $saved = [IO.File]::ReadAllText($json) | ConvertFrom-Json
        @($saved.findings | Where-Object { $_.ignored }).id | Should Be 'f1'
        $c = New-FakeCtx 'POST' '/api/reviews/fix' @{ id = $id; ids = @('f1', 'f2') }
        Invoke-FakeApi $c $s
        (Get-FakeJson $c).tasks | Should Be 1
        $t = Get-QueuedTask $s
        $t.text | Should Match 'Missing check'
        $t.text | Should Not Match 'Unused variable'
        $saved = [IO.File]::ReadAllText($json) | ConvertFrom-Json
        @($saved.findings | Where-Object { $_.fixQueueId }).id | Should Be 'f2'
        { Invoke-FakeApi (New-FakeCtx 'POST' '/api/reviews/fix' @{ id = $id; ids = @('f1') }) $s } | Should Throw 'Pick at least one finding'
    }
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'POST /api/runbook-from-chat and the other on-request features' {
    $p = Join-Path $env:TEMP ('ccb-onrequest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $p -Force | Out-Null
    It 'queues the runbook request as a coding task whose intent is change, also when the quoted request says not to change anything' {
        $s = New-TestState; $s.ProjectRoot = $p; $s.SaveHistory = $false
        Add-AgentEvent $s 'user' @{ text = 'List my meetings for next week with their organisers, do not change anything' }
        Add-AgentEvent $s 'kind' @{ taskKind = 'assistant' }
        $c = New-FakeCtx 'POST' '/api/runbook-from-chat' @{}
        Invoke-FakeApi $c $s
        $r = Get-FakeJson $c
        $r.ok | Should Be $true
        $t = Get-QueuedTask $s
        $t.kind | Should Be 'chat'
        $t.forceKind | Should Be 'coding'
        $t.intent | Should Be 'change'
        $t.text | Should Match 'do not change anything'
        (& (Get-Module Agent) { param($x) Get-TaskIntent $x } $t.text) | Should Be 'investigate'   # why the task carries its own intent
    }
    It 'queues the share package under its own kind, apart from the npm packages' {
        $s = New-TestState; $s.ProjectRoot = $p
        Invoke-FakeApi (New-FakeCtx 'POST' '/api/share-package' @{ includeSource = $true }) $s
        $t = Get-QueuedTask $s
        $t.kind | Should Be 'share-package'
        $t.includeSource | Should Be $true
        $t.projectRoot | Should Be $p
    }
    It 'queues nothing for a tidy-up with nothing ticked' {
        $s = New-TestState; $s.ProjectRoot = $p
        $c = New-FakeCtx 'POST' '/api/tidy/apply' @{ ids = @() }
        Invoke-FakeApi $c $s
        (Get-FakeJson $c).ok | Should Be $true
        Get-QueuedTask $s | Should BeNullOrEmpty
    }
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
