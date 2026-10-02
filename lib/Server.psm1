# Local web server: serves the built UI from ui\ and a small JSON API for it.
# Bound to localhost only; every API call must carry the per-session token that is
# injected into index.html, so other web pages cannot drive CCBridge.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Config', 'Workspace', 'Executor', 'Agent', 'Fetch', 'Runbook', 'Schedule') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:Mime = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
    '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.json' = 'application/json'
    '.woff2' = 'font/woff2'; '.woff' = 'font/woff'
}

function Get-QueueView($State, [int]$Max = 40) {
    <# The queue for the app, newest first, as plain objects. #>
    $list = @($State.Queue)
    [array]::Reverse($list)
    foreach ($e in ($list | Select-Object -First $Max)) {
        [pscustomobject]@{ id = $e.id; kind = $e.kind; title = $e.title; source = $e.source; status = $e.status; project = $e.project
            created = $e.created; started = $e.started; finished = $e.finished; messages = [int]$e.messages; summary = $e.summary; error = $e.error
            errId = $e.errId; resultPath = $e.resultPath; changed = @($e.changed | Where-Object { $_ }); jobId = $e.jobId; note = $e.note }
    }
}

function Get-ScheduleView($State) {
    <# Schedules for the app, soonest first; finished one-time schedules last. #>
    $list = foreach ($s in @($State.Schedules)) {
        [pscustomobject]@{ id = $s.id; title = $s.title; kind = $s.kind; name = $s.name; repeat = $s.repeat; times = @(Get-ScheduleTimes $s); at = $s.at; days = @($s.days)
            when = (Format-ScheduleWhen $s); enabled = [bool]$s.enabled; nextRun = $s.nextRun; lastRun = $s.lastRun; lastQueueId = $s.lastQueueId
            project = $(if ($s.projectRoot) { Split-Path $s.projectRoot -Leaf } else { $null }) }
    }
    @($list | Sort-Object @{ Expression = { if ($_.enabled -and $_.nextRun) { 0 } else { 1 } } }, @{ Expression = { "$($_.nextRun)" } })
}

function Get-JobView($State, $Job) {
    $view = @{}
    foreach ($k in @($Job.Keys)) { $view[$k] = $Job[$k] }
    $view
}

$script:LocationCache = @{}
function Get-ProjectLocation([string]$ProjectRoot) {
    <# The folders the project sits in, for the side panel: OneDrive, CCBridge, <project>. Cached:
       the snapshot is built several times a second. #>
    if (-not $script:LocationCache.ContainsKey($ProjectRoot)) {
        $loc = try { Get-OneDriveLocation $ProjectRoot } catch { $null }
        $script:LocationCache[$ProjectRoot] = if ($loc) { @($loc.Display -split ' > ') } else { @($ProjectRoot.TrimEnd('\').Split('\') | Select-Object -Last 3) }
    }
    $script:LocationCache[$ProjectRoot]
}
function Send-Response($Ctx, [int]$Status, [string]$ContentType, [byte[]]$Bytes) {
    $res = $Ctx.Response
    $res.StatusCode = $Status
    $res.ContentType = $ContentType
    $res.Headers['Cache-Control'] = 'no-store'
    $res.ContentLength64 = $Bytes.Length
    $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $res.Close()
}

function Send-Json($Ctx, $Object, [int]$Status = 200) {
    $json = ConvertTo-Json -InputObject $Object -Depth 10 -Compress
    Send-Response $Ctx $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-JsonBody($Ctx) {
    $reader = New-Object IO.StreamReader($Ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    if ($body) { $body | ConvertFrom-Json } else { [pscustomobject]@{} }
}

function Get-StateSnapshot($State) {
    @{
        project = $(if ($State.ProjectRoot) { @{ name = (Split-Path $State.ProjectRoot -Leaf); path = $State.ProjectRoot; location = @(Get-ProjectLocation $State.ProjectRoot) } } else { $null })
        mode = $State.Mode; busy = $State.Busy; progress = $State.Progress
        copilot = $State.Copilot; copilotMessage = $State.CopilotMessage
        throttle = $State.Throttle; credits = $State.Credits; todos = @($State.Todos)
        promptLimit = $State.Config.promptCharBudget
        logLevel = (Get-CCBLogLevel)
        version = [string]$State.Version
        queue = @(Get-QueueView $State 40)
        schedules = @(Get-ScheduleView $State)
        pausedUntil = $State.PausedUntil
        release = $(if ($State.Build) { [string]$State.Build.version } else { [string]$State.Version })
        commit = $(if ($State.Build) { [string]$State.Build.commit } else { '' })
        workIq = $State.WorkIq; workIqActual = $State.WorkIqActual
        workIqAvailable = [bool](Get-CCBridgeConfig selectors $State.AppRoot).workIq.toggle
    }
}

function Invoke-ApiRequest($Ctx, $State) {
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    switch -Regex ("$method $path") {
        '^GET /api/poll$' {
            $after = [int]('0' + $req.QueryString['after'])
            return Send-Json $Ctx @{ events = @(Get-AgentEvents $State $after); state = (Get-StateSnapshot $State) }
        }
        '^GET /api/projects$' {
            return Send-Json $Ctx @{ root = (Get-ProjectsRoot $State.Config.projectsFolder); projects = @(Get-CCBridgeProjects $State.Config.projectsFolder) }
        }
        '^POST /api/projects$' {
            $b = Read-JsonBody $Ctx
            $path = New-CCBridgeProject -Name $b.name -FolderName $State.Config.projectsFolder
            Set-Project $State $path
            return Send-Json $Ctx @{ ok = $true; path = $path }
        }
        '^POST /api/project/open$' {
            $b = Read-JsonBody $Ctx
            if (-not (Test-Path -LiteralPath $b.path -PathType Container)) { throw "Folder not found: $($b.path)" }
            if (-not (Test-UnderOneDrive $b.path)) { throw 'Projects must be inside your OneDrive folder.' }
            Set-Project $State (Resolve-Path -LiteralPath $b.path).Path
            return Send-Json $Ctx @{ ok = $true }
        }
        '^GET /api/files$' {
            if (-not $State.ProjectRoot) { return Send-Json $Ctx @{ files = @() } }
            $stats = Get-SessionChangeStats $State.ProjectRoot ([string]$State.SessionSince)
            $files = @(Get-ProjectFiles $State.ProjectRoot | ForEach-Object {
                $s = $stats[$_.path]
                if ($s) { [pscustomobject]@{ path = $_.path; size = $_.size; added = $s.added; removed = $s.removed } } else { $_ }
            })
            return Send-Json $Ctx @{ files = $files }
        }
        '^GET /api/file$' {
            $full = Resolve-ProjectPath $State.ProjectRoot $req.QueryString['path']
            if ((Get-Item -LiteralPath $full).Length -gt 2MB) { throw 'File is larger than 2 MB' }
            return Send-Json $Ctx @{ path = $req.QueryString['path']; text = (Read-TextFile $full).Text }
        }
        '^GET /api/queue$' { return Send-Json $Ctx @{ queue = @(Get-QueueView $State 100); pausedUntil = $State.PausedUntil } }
        '^POST /api/queue/resume$' { Resume-AgentQueue $State 'resumed by you'; return Send-Json $Ctx @{ ok = $true } }
        '^GET /api/schedules$' { return Send-Json $Ctx @{ schedules = @(Get-ScheduleView $State) } }
        '^POST /api/schedules$' {
            $b = Read-JsonBody $Ctx
            $spec = @{ kind = [string]$b.kind; text = [string]$b.text; name = [string]$b.name; title = [string]$b.title; repeat = [string]$b.repeat; times = @($b.times | Where-Object { $_ }); at = [string]$b.at; days = @($b.days) }
            $sch = New-AgentSchedule $State $spec
            return Send-Json $Ctx @{ ok = $true; id = $sch.id }
        }
        '^POST /api/schedules/(update|delete|run)$' {
            $op = $Matches[1]
            $b = Read-JsonBody $Ctx
            $sch = @($State.Schedules) | Where-Object { $_.id -eq [string]$b.id } | Select-Object -First 1
            if (-not $sch) { throw "Unknown schedule '$($b.id)'" }
            switch ($op) {
                'update' {
                    if ($null -ne $b.enabled) {
                        $sch.enabled = [bool]$b.enabled
                        # Turned back on: the next run counts from now (no catch-up of the paused time).
                        if ($sch.enabled) { $n = Get-NextRun $sch (Get-Date); $sch.nextRun = if ($n) { $n.ToString('s') } else { $null } }
                    }
                }
                'delete' { $State.Schedules.Remove($sch) }
                'run' { $e = Start-ScheduledItem $State $sch; $sch.lastQueueId = $e.id }
            }
            Save-Schedules $State
            Write-CCBLog info server "Schedule $($b.id) $op"
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/queue/cancel$' {
            $b = Read-JsonBody $Ctx
            $e = Get-QueueEntry $State ([string]$b.id)
            if (-not $e) { throw "Unknown queue entry '$($b.id)'" }
            if ($e.status -eq 'queued') { $e.status = 'cancelled'; $e.finished = (Get-Date).ToString('s') }
            elseif ($e.status -in 'running', 'awaiting') { $e.cancelRequested = $true; $State.Cancel = $true; if ($e.jobId -and $State.Jobs[$e.jobId]) { $State.Jobs[$e.jobId].cancelled = $true } }
            Write-CCBLog info server "Queue $($e.id) cancel requested ($($e.status))"
            Save-AgentQueue $State
            return Send-Json $Ctx @{ ok = $true; status = $e.status }
        }
        '^POST /api/jobs$' {
            # Tasks from other programs (the MCP server): queued like everything else, visible in the app.
            $b = Read-JsonBody $Ctx
            $source = if ($b.source) { [string]$b.source } else { 'api' }
            $id = 'job-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $job = [hashtable]::Synchronized(@{ id = $id; kind = [string]$b.kind; status = 'queued'; created = (Get-Date).ToString('s'); queuedSeq = $State.Seq })
            if ($null -ne $b.workIq) { $State.WorkIq = $(if ([bool]$b.workIq) { 'on' } else { 'off' }); $State.WorkIqWarned = $false }
            $task = switch ([string]$b.kind) {
                'ask' {
                    if (-not "$($b.text)".Trim()) { throw 'text is required' }
                    @{ kind = 'ask'; jobId = $id; text = [string]$b.text; newChat = [bool]$b.newChat; source = $source }
                }
                'task' {
                    $p = [string]$b.projectPath
                    if (-not $p -or -not [IO.Path]::IsPathRooted($p)) { throw 'projectPath must be an absolute folder path' }
                    if (-not "$($b.text)".Trim()) { throw 'text is required' }
                    $mode = if ($b.mode) { [string]$b.mode } else { 'auto' }
                    if (@('auto', 'plan', 'ask') -notcontains $mode) { throw 'mode must be auto, plan or ask' }
                    $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
                    if (-not (Test-Path -LiteralPath $full)) { $null = New-Item -ItemType Directory -Path $full }
                    $job.project = $full; $job.mode = $mode; $job.allowCommands = [bool]$b.allowCommands; $job.task = [string]$b.text
                    @{ kind = 'chat'; jobId = $id; text = [string]$b.text; projectRoot = $full; newChat = [bool]$b.newChat; mode = $mode; noCommands = (-not [bool]$b.allowCommands); source = $source; reviewByCaller = (-not [bool]$b.copilotReview) }
                }
                'undo' {
                    $p = [string]$b.projectPath
                    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { throw 'projectPath must be an existing folder' }
                    @{ kind = 'undo'; jobId = $id; projectRoot = [IO.Path]::GetFullPath($p).TrimEnd('\'); source = $source }
                }
                'newchat' { @{ kind = 'newchat'; jobId = $id; source = $source } }
                default { throw "Unknown job kind '$($b.kind)'" }
            }
            $State.Jobs[$id] = $job
            $entry = Submit-AgentTask $State $task $source
            return Send-Json $Ctx @{ ok = $true; job = (Get-JobView $State $job); queueId = $entry.id }
        }
        '^GET /api/jobs/(job-[0-9a-f]+)$' {
            $job = $State.Jobs[$Matches[1]]
            if (-not $job) { throw "Unknown job '$($Matches[1])'" }
            $from = if ($null -ne $job.startSeq) { [int]$job.startSeq } else { [int]$job.queuedSeq }
            $events = @(Get-AgentEvents $State $from)
            if ($null -ne $job.endSeq) { $events = @($events | Where-Object { $_.seq -le $job.endSeq }) }
            return Send-Json $Ctx @{ job = (Get-JobView $State $job); events = $events
                info = @{ workIq = $State.WorkIq; workIqActual = $State.WorkIqActual; throttle = $State.Throttle; credits = $State.Credits; seq = $State.Seq } }
        }
        '^GET /api/runbooks$' {
            # @(if ...): an if expression would unroll a list of one into a single object.
            $list = @(if ($State.ProjectRoot) { Get-Runbooks $State.ProjectRoot })
            return Send-Json $Ctx @{ runbooks = $list; templates = @(Get-RunbookTemplates $State.AppRoot) }
        }
        '^POST /api/runbooks$' {
            if (-not $State.ProjectRoot) { throw 'Open or create a project first' }
            $b = Read-JsonBody $Ctx
            $item = New-RunbookFromTemplate $State.AppRoot $State.ProjectRoot ([string]$b.template) ([string]$b.name)
            Write-CCBLog info server "Runbook created: $($item.name) from $($b.template)"
            return Send-Json $Ctx @{ ok = $true; item = $item }
        }
        '^POST /api/runbooks/run$' {
            if (-not $State.ProjectRoot) { throw 'Open or create a project first' }
            $b = Read-JsonBody $Ctx
            $null = Submit-AgentTask $State @{ kind = 'runbook'; name = [string]$b.name } 'user'
            return Send-Json $Ctx @{ ok = $true }
        }
        '^GET /api/fetch$' {
            if (-not $State.ProjectRoot) { return Send-Json $Ctx @{ items = @() } }
            return Send-Json $Ctx @{ items = @(Get-FetchPrompts $State.ProjectRoot) }
        }
        '^POST /api/fetch$' {
            if (-not $State.ProjectRoot) { throw 'Open or create a project first' }
            $b = Read-JsonBody $Ctx
            $item = Save-FetchPrompt $State.ProjectRoot ([string]$b.name) ([string]$b.prompt)
            Write-CCBLog info server "Fetch prompt saved: $($item.name)" @{ chars = $item.prompt.Length }
            return Send-Json $Ctx @{ ok = $true; item = $item }
        }
        '^POST /api/fetch/run$' {
            if (-not $State.ProjectRoot) { throw 'Open or create a project first' }
            $b = Read-JsonBody $Ctx
            $null = Submit-AgentTask $State @{ kind = 'fetch'; name = [string]$b.name } 'user'
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/chat$' {
            $b = Read-JsonBody $Ctx
            if (-not $b.text -or -not $b.text.Trim()) { throw 'Empty message' }
            # While Copilot is busy the message waits in the queue.
            $entry = Submit-AgentTask $State @{ kind = 'chat'; text = [string]$b.text } 'user'
            return Send-Json $Ctx @{ ok = $true; queued = $entry.id }
        }
        '^POST /api/approve$' {
            $b = Read-JsonBody $Ctx
            # Who decided. "user" only for the StreamHub page itself: the browser adds its Origin header,
            # which other programs (the MCP server, scripts) do not send. Microsoft 365 actions and
            # deleting data can only be approved by "user" (Wait-Approval).
            $fromPage = $Ctx.Request.Headers['Origin'] -eq "http://localhost:$($State.Config.port)"
            $by = if ($fromPage -and $b.by -eq 'user') { 'user' } elseif ($b.by -eq 'mcp') { 'mcp' } else { 'api' }
            $State.Approvals[[string]$b.id] = @{ decision = [string]$b.decision; note = [string]$b.note; by = $by }
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/mode$' {
            $b = Read-JsonBody $Ctx
            if (@('ask', 'auto', 'plan') -notcontains $b.mode) { throw "Unknown mode $($b.mode)" }
            $State.Mode = [string]$b.mode
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/source$' {
            if (-not $State.ProjectRoot) { throw 'Open a project first' }
            if ($req.ContentLength64 -gt 500MB) { throw 'File is larger than 500 MB' }
            $rel = Save-SourceFile $State.ProjectRoot $req.QueryString['name'] $req.InputStream
            Add-AgentEvent $State 'status' @{ text = "Added source data: $rel (read-only for Copilot)" }
            return Send-Json $Ctx @{ ok = $true; path = $rel }
        }
        '^POST /api/workiq$' {
            $b = Read-JsonBody $Ctx
            if (@('on', 'off', 'leave') -notcontains $b.value) { throw "Work IQ must be on, off or leave" }
            $State.WorkIq = [string]$b.value; $State.WorkIqWarned = $false
            return Send-Json $Ctx @{ ok = $true }
        }
        '^GET /api/settings$' { return Send-Json $Ctx @{ settings = @(Get-CCBridgeSettings $State.AppRoot) } }
        '^POST /api/settings$' {
            $b = Read-JsonBody $Ctx
            $value = Set-CCBridgeSetting ([string]$b.key) $b.value $State.AppRoot
            # In effect right away: the worker reads $State.Config on every turn.
            $keep = @{ port = $State.Config.port; cdpPort = $State.Config.cdpPort }   # ports in use stay (also -Port)
            $State.Config = Get-CCBridgeConfig harness $State.AppRoot
            $State.Config.port = $keep.port; $State.Config.cdpPort = $keep.cdpPort
            Write-CCBLog info server "Setting $($b.key) = $(if ($null -eq $b.value) { '(default)' } else { $b.value })"
            return Send-Json $Ctx @{ ok = $true; value = $value; settings = @(Get-CCBridgeSettings $State.AppRoot) }
        }
        '^POST /api/logging$' {
            $b = Read-JsonBody $Ctx
            if (@('info', 'verbose', 'trace', 'off') -notcontains $b.level) { throw 'level must be off, info, verbose or trace' }
            Set-CCBLogLevel $b.level
            $State.LogLevel = [string]$b.level   # the worker runspace follows
            Set-CCBridgeLocalSetting harness logLevel ([string]$b.level) $State.AppRoot
            Write-CCBLog info server "Log level set to $($b.level) from the web app"
            return Send-Json $Ctx @{ ok = $true; level = $b.level }
        }
        '^POST /api/diagnostics$' {
            $zip = & (Join-Path $State.AppRoot 'tools\collect-diagnostics.ps1') -NoOpen
            return Send-Json $Ctx @{ ok = $true; path = (Protect-LogText $zip); fullPath = $zip }
        }
        '^POST /api/project/show$' {
            if ($State.ProjectRoot -and (Test-Path -LiteralPath $State.ProjectRoot)) { Start-Process explorer.exe "`"$($State.ProjectRoot)`"" }
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/diagnostics/show$' {
            $b = Read-JsonBody $Ctx
            if ($b.path -and (Test-Path -LiteralPath $b.path)) { Start-Process explorer.exe "/select,`"$($b.path)`"" }
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/clientlog$' {
            $b = Read-JsonBody $Ctx
            $detail = @{}
            foreach ($p in $b.PSObject.Properties) { if ($p.Name -ne 'message') { $detail[$p.Name] = $p.Value } }
            Write-CCBLog info ui ([string]$b.message) $detail
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/newchat$' {
            if ($State.Busy) { $State.Cancel = $true }   # stop the current step now; the new chat follows
            $null = Submit-AgentTask $State @{ kind = 'newchat' } 'user'
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/undo$'    { $null = Submit-AgentTask $State @{ kind = 'undo' } 'user'; return Send-Json $Ctx @{ ok = $true } }
        '^POST /api/stop$'    { $State.Cancel = $true; return Send-Json $Ctx @{ ok = $true } }
        '^POST /api/connect$' { $State.Tasks.Enqueue(@{ kind = 'connect' }); return Send-Json $Ctx @{ ok = $true } }
    }
    Send-Json $Ctx @{ error = "Unknown API $method $path" } 404
}

function Set-Project($State, [string]$Path) {
    $State.ProjectRoot = $Path.TrimEnd('\')
    $State.SessionSince = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')   # line-change counts start here
    $State.Todos = @()
    $State.NeedNewChat = $State.NeedNewChat -or $State.ChatStarted   # a new project starts a fresh Copilot chat
    Add-AgentEvent $State 'project' @{ name = (Split-Path $Path -Leaf); path = $Path }
    try { [IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'CCBridge\last-project.txt'), $State.ProjectRoot) } catch { }
}

$script:PreviewTypes = @{ '.html' = 'text/html; charset=utf-8'; '.htm' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.mjs' = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.webp' = 'image/webp'
    '.ico' = 'image/x-icon'; '.woff' = 'font/woff'; '.woff2' = 'font/woff2'; '.txt' = 'text/plain; charset=utf-8'; '.csv' = 'text/csv; charset=utf-8'; '.xml' = 'application/xml' }

function Send-PreviewFile($Ctx, $State, [string]$RelPath) {
    <# The project's files, read-only, for the page check (GET only, confined to the project). #>
    $res = $Ctx.Response
    try {
        if ($Ctx.Request.HttpMethod -ne 'GET' -or -not $State.ProjectRoot) { $res.StatusCode = 404; return }
        $rel = [Uri]::UnescapeDataString($RelPath); if (-not $rel) { $rel = 'index.html' }
        $full = Resolve-ProjectPath $State.ProjectRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $res.StatusCode = 404; return }
        $bytes = [IO.File]::ReadAllBytes($full)
        $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
        $res.ContentType = if ($script:PreviewTypes[$ext]) { $script:PreviewTypes[$ext] } else { 'application/octet-stream' }
        $res.Headers['Cache-Control'] = 'no-store'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch { try { $res.StatusCode = 404 } catch { } }
    finally { try { $res.Close() } catch { } }
}

function Send-StaticFile($Ctx, [string]$UiDir, [string]$Token) {
    $rel = [Uri]::UnescapeDataString($Ctx.Request.Url.AbsolutePath).TrimStart('/')
    if (-not $rel) { $rel = 'index.html' }
    $full = [IO.Path]::GetFullPath((Join-Path $UiDir $rel.Replace('/', '\')))
    if (-not $full.StartsWith($UiDir + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $full = Join-Path $UiDir 'index.html'   # single-page app fallback
    }
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    $type = if ($script:Mime.ContainsKey($ext)) { $script:Mime[$ext] } else { 'application/octet-stream' }
    if ($ext -eq '.html') {
        $html = [IO.File]::ReadAllText($full).Replace('</head>', "<meta name=`"ccb-token`" content=`"$Token`"></head>")
        return Send-Response $Ctx 200 $type ([Text.Encoding]::UTF8.GetBytes($html))
    }
    Send-Response $Ctx 200 $type ([IO.File]::ReadAllBytes($full))
}

function Start-CCBridgeServer {
    <# Serves until Ctrl+C. The agent worker runs in its own runspace. #>
    param([Parameter(Mandatory)]$State, [switch]$NoBrowser)
    $appRoot = $State.AppRoot
    $uiDir = (Join-Path $appRoot 'ui').TrimEnd('\')
    if (-not (Test-Path (Join-Path $uiDir 'index.html'))) { throw "UI not built: $uiDir\index.html is missing" }
    # The token survives restarts, so an open browser tab keeps working after CCBridge restarts.
    $tokenFile = Join-Path $env:LOCALAPPDATA 'CCBridge\session-token.txt'
    $token = if (Test-Path $tokenFile) { [IO.File]::ReadAllText($tokenFile).Trim() } else { '' }
    if ($token -notmatch '^[0-9a-f]{32}$') {
        $token = [guid]::NewGuid().ToString('N')
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $tokenFile)
        [IO.File]::WriteAllText($tokenFile, $token)
    }
    $port = $State.Config.port

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'   # clipboard access needs STA
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('State', $State)
    $worker = [powershell]::Create()
    $worker.Runspace = $rs
    [void]$worker.AddScript("`$ErrorActionPreference = 'Stop'; Import-Module '$(Join-Path $appRoot 'lib\Agent.psm1')'; Start-AgentWorker -State `$State")
    $handle = $worker.BeginInvoke()
    $State.Tasks.Enqueue(@{ kind = 'connect' })
    $last = Join-Path $env:LOCALAPPDATA 'CCBridge\last-project.txt'
    if (Test-Path $last) {
        $lp = [IO.File]::ReadAllText($last).Trim()
        if ($lp -and (Test-Path -LiteralPath $lp -PathType Container) -and (Test-UnderOneDrive $lp)) { Set-Project $State $lp }
    }

    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()
    $url = "http://localhost:$port/"
    Write-Host "StreamHub is running at $url  (Ctrl+C to stop)"
    Write-Host "Log: $(Get-CCBLogDir) (level $(Get-CCBLogLevel))"
    Write-CCBLog info server "Web app started on $url" (Get-CCBridgeEnvironment $appRoot)
    $State.PreviewPort = $port   # the page check can open project pages through this server
    if (-not $NoBrowser) { Start-Process $url }

    try {
        $pending = $listener.GetContextAsync()
        while ($listener.IsListening) {
            if (-not $pending.Wait(250)) {
                if ($handle.IsCompleted) { Write-Warning ('Agent worker stopped: ' + ($worker.Streams.Error | Select-Object -Last 1)); break }
                continue
            }
            $ctx = $pending.Result
            $pending = $listener.GetContextAsync()
            $reqWatch = [Diagnostics.Stopwatch]::StartNew()
            $reqPath = $ctx.Request.Url.AbsolutePath
            try {
                $previewPrefix = "/preview/$($State.PreviewToken)/"
                if ($ctx.Request.Url.AbsolutePath.StartsWith($previewPrefix)) {
                    Send-PreviewFile $ctx $State $ctx.Request.Url.AbsolutePath.Substring($previewPrefix.Length)
                } elseif ($ctx.Request.Url.AbsolutePath.StartsWith('/api/')) {
                    $origin = $ctx.Request.Headers['Origin']
                    if (($origin -and $origin -ne "http://localhost:$port") -or $ctx.Request.Headers['X-CCB-Token'] -ne $token) {
                        Send-Json $ctx @{ error = 'forbidden' } 403
                        continue
                    }
                    Invoke-ApiRequest $ctx $State
                } else {
                    Send-StaticFile $ctx $uiDir $token
                }
            } catch {
                $errId = New-CCBErrorId
                $help = Get-CCBErrorHelp $_.Exception.Message
                Write-CCBLogError server "$errId [$($help.code)] $($ctx.Request.HttpMethod) $reqPath" $_
                try { Send-Json $ctx @{ error = $_.Exception.Message; errId = $errId; code = $help.code; hint = $help.hint } 400 } catch { }
            }
            if ($reqPath -ne '/api/poll' -and $reqPath.StartsWith('/api/')) { Write-CCBLog verbose server "$($ctx.Request.HttpMethod) $reqPath ($($reqWatch.ElapsedMilliseconds) ms)" }
        }
    } finally {
        $State.Stop = $true
        $listener.Stop()
        if ($handle.AsyncWaitHandle.WaitOne(5000)) { $worker.EndInvoke($handle) | Out-Null }
        $worker.Dispose(); $rs.Dispose()
        Write-Host 'StreamHub stopped.'
    }
}

Export-ModuleMember -Function Start-CCBridgeServer
