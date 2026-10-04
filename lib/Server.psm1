# Local web server: serves the built UI from ui\ and a small JSON API for it.
# Bound to localhost only; every API call must carry the per-session token that is
# injected into index.html, so other web pages cannot drive CCBridge.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Config', 'Cdp', 'Workspace', 'Executor', 'Prompts', 'Agent', 'Fetch', 'Runbook', 'Schedule', 'Review', 'AppWindow', 'PlanFile', 'Issues', 'Layout', 'Sso', 'Retention', 'Imports', 'Chain', 'Relink', 'EdgeCache') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

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
        [pscustomobject]@{ id = $e.id; kind = $e.kind; title = $e.title; source = $e.source; status = $e.status; project = $e.project; projectRoot = $e.projectRoot
            created = $e.created; started = $e.started; finished = $e.finished; messages = [int]$e.messages; summary = $e.summary; error = $e.error
            errId = $e.errId; resultPath = $e.resultPath; changed = @($e.changed | Where-Object { $_ }); jobId = $e.jobId; note = $e.note }
    }
}

function Get-ScheduleView($State) {
    <# Schedules for the app, soonest first; finished one-time schedules last. #>
    $list = foreach ($s in @($State.Schedules)) {
        [pscustomobject]@{ id = $s.id; title = $s.title; kind = $s.kind; name = $s.name; text = "$($s.text)"; repeat = $s.repeat; times = @(Get-ScheduleTimes $s); at = $s.at; days = @($s.days)
            when = (Format-ScheduleWhen $s); enabled = [bool]$s.enabled; nextRun = $s.nextRun; lastRun = $s.lastRun; lastQueueId = $s.lastQueueId
            project = $(if ($s.projectRoot) { Split-Path $s.projectRoot -Leaf } else { $null }); projectRoot = $s.projectRoot }
    }
    @($list | Sort-Object @{ Expression = { if ($_.enabled -and $_.nextRun) { 0 } else { 1 } } }, @{ Expression = { "$($_.nextRun)" } })
}

function ConvertTo-PlainHashtable($Object) {
    $h = @{}
    foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h
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
        responseMode = [string]$State.ResponseMode
        responseModeActual = $State.ResponseModeActual
        verify = $(if ($State.ProjectRoot) { Get-ProjectVerify $State.ProjectRoot } else { $null })
        schedules = @(Get-ScheduleView $State)
        pausedUntil = $State.PausedUntil
        release = $(if ($State.Build) { [string]$State.Build.version } else { [string]$State.Version })
        commit = $(if ($State.Build) { [string]$State.Build.commit } else { '' })
        workIq = $State.WorkIq; workIqActual = $State.WorkIqActual
        workIqAvailable = [bool](Get-CCBridgeConfig selectors $State.AppRoot).workIq.toggle
        activity = (Get-ActivityView $State)
        appWindow = [string]$State.Config.appWindow   # where the app opened (the Split screen hint is for copilot-tab)
        hints = (Get-UiHints $State)
        previewBase = "/preview/$($State.PreviewToken)/"   # images in Markdown files (read-only project files)
        issueStamp = $(if ($State.ProjectRoot) { $p = Get-IssueIndexPath $State.ProjectRoot; if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks.ToString() } else { '' } } else { '' })
    }
}

$script:HintsFile = Join-Path $env:LOCALAPPDATA 'CCBridge\ui-hints.json'

function Get-UiHints($State) {
    <# One-time hints already shown (e.g. splitView), kept in the data folder so they stay shown
       after a restart, an update or cleared browser data. Read once, then kept in $State. #>
    if ($null -eq $State.Hints) {
        $h = @{}
        if (Test-Path -LiteralPath $script:HintsFile) {
            try { foreach ($p in @(([IO.File]::ReadAllText($script:HintsFile) | ConvertFrom-Json).PSObject.Properties)) { $h[$p.Name] = "$($p.Value)" } } catch { }
        }
        $State.Hints = $h
    }
    $State.Hints
}

function Set-UiHintShown($State, [string]$Name) {
    if ($Name -notmatch '^[A-Za-z][\w-]{0,40}$') { throw 'Unknown hint.' }
    $h = Get-UiHints $State
    $h[$Name] = (Get-Date).ToString('s')
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $script:HintsFile)
    [IO.File]::WriteAllText($script:HintsFile, (ConvertTo-Json -InputObject $h -Compress), (New-Object Text.UTF8Encoding($false)))
}

function Get-ActivityView($State) {
    <# What StreamHub itself is busy with (indexing, scanning for issues), shown like "waiting for
       Copilot". The worker's step comes first; else the background index run. #>
    $view = $null
    foreach ($a in $State.Activity, $State.Indexing) {
        if ($a -and $a.label -and -not $view) { $view = @{ label = [string]$a.label; done = [int]$a.done; total = [int]$a.total; current = [string]$a.current; background = [bool]($a -eq $State.Indexing) } }
    }
    $view
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
            # Each project with its size and type (file names and sizes only).
            $list = @(Get-CCBridgeProjects $State.Config.projectsFolder | ForEach-Object {
                $pr = $_; $o = $null
                try { $o = Get-ProjectOverview $pr.path } catch { Write-CCBLogError server "project overview $($pr.name)" $_ }
                [pscustomobject]@{ name = $pr.name; path = $pr.path; modified = $pr.modified; overview = $o }
            })
            return Send-Json $Ctx @{ root = (Get-ProjectsRoot $State.Config.projectsFolder); projects = $list }
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
            # Line counts for the whole session, or only for the last change (setting fileChangeCounts).
            $since = [string]$State.SessionSince
            if ("$($State.Config.fileChangeCounts)" -eq 'last-change') {
                $since = Get-LastChangeStart $State.ProjectRoot ([string]$State.OpenedAt)
                $stats = Get-LastChangeStats $State.ProjectRoot $since   # every change of the last instruction added up
            } else { $stats = Get-SessionChangeStats $State.ProjectRoot $since }
            $files = @(Get-ProjectFiles $State.ProjectRoot | ForEach-Object {
                $s = $stats[$_.path]
                if ($s) { [pscustomobject]@{ path = $_.path; size = $_.size; added = $s.added; removed = $s.removed; created = [bool]$s.created } } else { $_ }
            })
            # StreamHub's own records (.streamhub/) show in the tree too, though Copilot's file list
            # leaves them out: issues, imports, schedules, task reports, reviews, earlier results, plans.
            $own = Join-Path $State.ProjectRoot '.streamhub'
            if (Test-Path -LiteralPath $own -PathType Container) {
                $base = $State.ProjectRoot.TrimEnd('\').Length + 1
                $files += @(Get-ChildItem -LiteralPath $own -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 2000 | ForEach-Object {
                    [pscustomobject]@{ path = $_.FullName.Substring($base).Replace('\', '/'); size = $_.Length; own = $true } })
            }
            return Send-Json $Ctx @{ files = $files }
        }
        '^GET /api/file$' {
            $full = Resolve-ProjectPath $State.ProjectRoot $req.QueryString['path']
            if ((Get-Item -LiteralPath $full).Length -gt 2MB) { throw 'File is larger than 2 MB' }
            return Send-Json $Ctx @{ path = $req.QueryString['path']; text = (Read-TextFile $full).Text }
        }
        '^GET /api/queue$' { return Send-Json $Ctx @{ queue = @(Get-QueueView $State 100); pausedUntil = $State.PausedUntil } }
        '^POST /api/response-mode$' {
            $b = Read-JsonBody $Ctx
            $v = [string]$b.value
            if (@('leave', 'auto', 'quick', 'deep') -notcontains $v) { throw 'value must be leave, auto, quick or deep' }
            $State.ResponseMode = $v
            $null = Set-CCBridgeSetting 'responseMode' $v $State.AppRoot
            $State.Config.responseMode = $v
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/queue/resume$' { Resume-AgentQueue $State 'resumed by you'; return Send-Json $Ctx @{ ok = $true } }
        '^POST /api/reviews/estimate$' {
            $b = Read-JsonBody $Ctx
            $plan = Get-ReviewPlan $State ([string]$b.scope) @($b.paths)
            return Send-Json $Ctx @{ files = @($plan.files).Count; skipped = @($plan.skipped).Count; batches = $plan.batches; messages = $plan.messages; scopeText = $plan.scopeText }
        }
        '^POST /api/reviews/run$' {
            $b = Read-JsonBody $Ctx
            $plan = Get-ReviewPlan $State ([string]$b.scope) @($b.paths)
            if (-not @($plan.files).Count) { throw "Nothing to review in $($plan.scopeText): no code files found." }
            $rid = 'review-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
            $task = @{ kind = 'review'; scope = [string]$b.scope; paths = @($b.paths | Where-Object { $_ }); focus = @($b.focus | Where-Object { $_ }); reviewId = $rid; projectRoot = $State.ProjectRoot }
            $entry = Submit-AgentTask $State $task 'user' "Code review ($($plan.scopeText), $(@($plan.files).Count) files, about $($plan.messages) Copilot messages)"
            return Send-Json $Ctx @{ ok = $true; id = $rid; queued = $entry.id }
        }
        '^GET /api/reviews$' {
            # An empty if-expression would become {} in JSON: assign the list explicitly.
            $list = @()
            if ($State.ProjectRoot) { $list = @(Get-Reviews $State.ProjectRoot) }
            return Send-Json $Ctx @{ reviews = $list }
        }
        '^POST /api/reviews/(get|fix|ignore)$' {
            $op = $Matches[1]
            $b = Read-JsonBody $Ctx
            if ("$($b.id)" -notmatch '^review-[\d-]+$') { throw "Unknown review '$($b.id)'" }
            $jsonPath = Resolve-ProjectPath $State.ProjectRoot (Get-LayoutPath Reviews "$($b.id).json")
            if (-not (Test-Path -LiteralPath $jsonPath)) { throw "Unknown review '$($b.id)'" }
            $rv = [IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json
            if ($op -eq 'get') { return Send-Json $Ctx @{ review = $rv } }
            $ids = @($b.ids | ForEach-Object { "$_" })
            if ($op -eq 'ignore') {
                # Not a real problem: hidden here, and a later review leaves the same line out.
                foreach ($f in @($rv.findings | Where-Object { $ids -contains $_.id })) {
                    Set-IgnoredFinding $State.ProjectRoot "$($f.file)" "$($f.title)" "$($f.quote)" -Undo:([bool]$b.undo)
                    $f | Add-Member -NotePropertyName ignored -NotePropertyValue (-not $b.undo) -Force
                }
                [IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $rv -Depth 6), (New-Object Text.UTF8Encoding($false)))
                return Send-Json $Ctx @{ ok = $true }
            }
            $picked = @($rv.findings | Where-Object { $ids -contains $_.id -and -not $_.ignored } | ForEach-Object { ConvertTo-PlainHashtable $_ })
            if (-not $picked.Count) { throw 'Pick at least one finding to fix' }
            $queued = 0
            foreach ($t in @(New-ReviewFixTasks $picked)) {
                $e = Submit-AgentTask $State @{ kind = 'chat'; text = $t.text } 'user' $t.title
                foreach ($f in @($rv.findings | Where-Object { $t.ids -contains $_.id })) { $f | Add-Member -NotePropertyName fixQueueId -NotePropertyValue $e.id -Force }
                $queued++
            }
            [IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $rv -Depth 6), (New-Object Text.UTF8Encoding($false)))
            Write-CCBLog info server "Review $($b.id): $($picked.Count) finding(s) queued for fixing in $queued task(s)"
            return Send-Json $Ctx @{ ok = $true; tasks = $queued }
        }
        '^GET /api/schedules$' { return Send-Json $Ctx @{ schedules = @(Get-ScheduleView $State) } }
        '^POST /api/schedules$' {
            $b = Read-JsonBody $Ctx
            $spec = @{ kind = [string]$b.kind; text = [string]$b.text; name = [string]$b.name; title = [string]$b.title; repeat = [string]$b.repeat; times = @($b.times | Where-Object { $_ }); at = [string]$b.at; days = @($b.days) }
            $sch = New-AgentSchedule $State $spec
            return Send-Json $Ctx @{ ok = $true; id = $sch.id }
        }
        '^POST /api/schedules/edit$' {
            $b = Read-JsonBody $Ctx
            $spec = @{ kind = [string]$b.kind; text = [string]$b.text; name = [string]$b.name; title = [string]$b.title; repeat = [string]$b.repeat; times = @($b.times | Where-Object { $_ }); at = [string]$b.at; days = @($b.days) }
            $null = Update-AgentSchedule $State ([string]$b.id) $spec
            return Send-Json $Ctx @{ ok = $true; schedules = @(Get-ScheduleView $State) }
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
            $deep = [bool]$b.thinkDeeper
            $task = switch ([string]$b.kind) {
                'ask' {
                    if (-not "$($b.text)".Trim()) { throw 'text is required' }
                    @{ kind = 'ask'; jobId = $id; text = [string]$b.text; newChat = [bool]$b.newChat; source = $source; responseMode = $(if ($deep) { 'deep' } else { $null }) }
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
                    @{ kind = 'chat'; jobId = $id; text = [string]$b.text; projectRoot = $full; newChat = [bool]$b.newChat; mode = $mode; noCommands = (-not [bool]$b.allowCommands); source = $source; reviewByCaller = (-not [bool]$b.copilotReview); responseMode = $(if ($deep) { 'deep' } else { $null }) }
                }
                'undo' {
                    $p = [string]$b.projectPath
                    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { throw 'projectPath must be an existing folder' }
                    @{ kind = 'undo'; jobId = $id; projectRoot = [IO.Path]::GetFullPath($p).TrimEnd('\'); source = $source }
                }
                'newchat' { @{ kind = 'newchat'; jobId = $id; source = $source } }
                'review' {
                    $p = [string]$b.projectPath
                    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { throw 'projectPath must be an existing folder' }
                    $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
                    $job.project = $full
                    @{ kind = 'review'; jobId = $id; projectRoot = $full; scope = $(if (@($b.paths | Where-Object { $_ }).Count) { 'paths' } else { 'all' }); paths = @($b.paths | Where-Object { $_ }); focus = @($b.focus | Where-Object { $_ }); reviewId = 'review-' + (Get-Date).ToString('yyyyMMdd-HHmmss'); source = $source }
                }
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
        '^GET /api/chains$' {
            $list = @(if ($State.ProjectRoot) { Get-Chains $State.ProjectRoot })
            return Send-Json $Ctx @{ chains = $list; scripts = @(if ($State.ProjectRoot) { Get-ProjectScripts $State.ProjectRoot }) }
        }
        '^POST /api/chains$' {
            if (-not $State.ProjectRoot) { throw 'Open or create a project first' }
            $b = Read-JsonBody $Ctx
            $item = New-ChainFile $State.AppRoot $State.ProjectRoot ([string]$b.name)
            return Send-Json $Ctx @{ ok = $true; item = $item }
        }
        '^POST /api/chains/steps$' {
            # Add a runbook or script step, remove one, or move one up or down (Automation tab).
            if (-not $State.ProjectRoot) { throw 'Open or create a project first' }
            $b = Read-JsonBody $Ctx
            $item = Set-ChainSteps $State.ProjectRoot ([string]$b.name) ([string]$b.op) -Kind ([string]$b.kind) -Target ([string]$b.target) -ArgText ([string]$b.args) -Index $(if ($null -ne $b.index) { [int]$b.index } else { -1 })
            return Send-Json $Ctx @{ ok = $true; item = $item }
        }
        '^POST /api/chains/run$' {
            if (-not $State.ProjectRoot) { throw 'Open or create a project first' }
            $b = Read-JsonBody $Ctx
            $null = Submit-AgentTask $State @{ kind = 'chain'; name = [string]$b.name } 'user'
            return Send-Json $Ctx @{ ok = $true }
        }
        '^GET /api/fetch$' {
            if (-not $State.ProjectRoot) { return Send-Json $Ctx @{ items = @() } }
            return Send-Json $Ctx @{ items = @(Get-FetchPrompts $State.ProjectRoot) }
        }
        '^POST /api/fetch$' {
            if (-not $State.ProjectRoot) { throw 'Open or create a project first' }
            $b = Read-JsonBody $Ctx
            $more = @{}   # agent and files only when the form sends them (else the file's own lines stay)
            if ($null -ne $b.agent) { $more.Agent = [string]$b.agent }
            if ($null -ne $b.files) { $more.Files = [string]$b.files }
            $item = Save-FetchPrompt $State.ProjectRoot ([string]$b.name) ([string]$b.prompt) -Sources ([string]$b.sources) -Sites ([string]$b.sites) -Pages ([string]$b.pages) @more
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
            $task = @{ kind = 'chat'; text = [string]$b.text }
            # A message to one of Copilot's agents (picked in the message box), or an answer to its plan.
            if ("$($b.agent)" -in 'researcher', 'analyst') {
                $t = @{ kind = 'agent'; agent = [string]$b.agent; text = [string]$b.text; followUp = [bool]$b.agentAnswer }
                $null = Submit-AgentTask $State $t 'user'
                return Send-Json $Ctx @{ ok = $true }
            }
            $title = ''
            # The request's section in PLAN.md, when this message belongs to a clarify-first flow.
            $planId = if ($b.planId -and (Test-PlanId ([string]$b.planId))) { [string]$b.planId } else { $null }
            if ($planId) { $task.planId = $planId }
            $planNote = {
                param($Heading, $Body, $Status)
                if (-not $planId -or -not $State.ProjectRoot) { return }
                try { Add-PlanSection $State.ProjectRoot $planId $Heading $Body $Status } catch { Write-CCBLogError server 'PLAN.md' $_ }
            }
            if ($b.asCoding) { $task.forceKind = 'coding' }
            if ($b.clarify) { $task.clarify = $true; $task.request = [string]$b.text }
            elseif ($b.planFirst) {
                # Plan first: read-only turn that ends with a plan to approve in the app.
                $task.planFirst = $true; $task.mode = 'plan'; $task.forceKind = 'coding'
                $task.request = if ($b.request) { [string]$b.request } else { [string]$b.text }
                $task.text = (Get-PromptPart $State.AppRoot 'plan-first') + "`n`n" + [string]$b.text
                $title = "Plan: $($task.request)"
                if (@($b.answers).Count) { & $planNote 'Your answers' (Format-PlanAnswers @($b.answers)) 'planning' }
                elseif ($b.skipped) { & $planNote 'Your answers' 'Skipped: Copilot plans with its own assumptions.' 'planning' }
                if ("$($b.feedback)".Trim()) { & $planNote 'Change requested' ([string]$b.feedback) 'planning' }
            }
            if ($b.approve -and $planId) {
                & $planNote 'Approved' "Approved on $((Get-Date).ToString('yyyy-MM-dd HH:mm')); building started." 'building'
                $task.planBuild = $true
                $task.text += "`n`nEvery decision for this task (questions, answers, plan versions) is in PLAN.md, in the section marked plan:$planId. Read it if you need it."
            }
            if ($b.thinkDeeper) { $task.responseMode = 'deep' }
            $entry = Submit-AgentTask $State $task 'user' $title
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
        '^GET /api/issues$' {
            $items = @(); $summary = $null
            if ($State.ProjectRoot) { $items = @(Get-IssueReport $State.ProjectRoot) }
            $projects = @(Get-AppIssueIndex -AlsoProjects @($State.ProjectRoot))
            if ($State.ProjectRoot) { $summary = @($projects | Where-Object { $_.root -eq $State.ProjectRoot.TrimEnd('\') }) | Select-Object -First 1 }
            return Send-Json $Ctx @{ items = $items; summary = $summary; projects = $projects; indexing = @{ running = [bool]$State.Indexing.running; last = $State.Indexing.last; error = $State.Indexing.error }; settings = (Get-IssueSettings $State) }
        }
        '^POST /api/issues/reindex$' {
            if (-not $State.ProjectRoot) { throw 'Open a project first.' }
            $b = Read-JsonBody $Ctx
            $started = Start-IssueIndexer $State $State.ProjectRoot -Force:([bool]$b.force)
            return Send-Json $Ctx @{ ok = $true; started = $started }
        }
        '^POST /api/issues/fix$' {
            # Fix on a file (or all files): one queued task per file, the same cycle as after a task.
            if (-not $State.ProjectRoot) { throw 'Open a project first.' }
            $b = Read-JsonBody $Ctx
            $cats = @($b.categories | Where-Object { $_ }); if (-not $cats.Count) { $cats = @('error', 'secret', 'health') }
            $paths = @($b.paths | Where-Object { $_ })
            $todo = @(Get-IssueReport $State.ProjectRoot | Where-Object { $_.status -in 'open', 'gave up' -and $_.category -in $cats -and (-not $paths.Count -or $_.path -in $paths) })
            $n = 0
            foreach ($g in @($todo | Group-Object path)) { if (Submit-IssueFix $State $g.Name @($g.Group) 1 $cats) { $n++ } }
            return Send-Json $Ctx @{ ok = $true; queued = $n; issues = $todo.Count }
        }
        '^POST /api/issues/ignore$' {
            if (-not $State.ProjectRoot) { throw 'Open a project first.' }
            $b = Read-JsonBody $Ctx
            $ids = @($b.ids | Where-Object { $_ }); if (-not $ids.Count) { throw 'No issues given.' }
            Set-IssueState $State.ProjectRoot $ids $(if ($b.undo) { 'open' } else { 'ignored' }) -Attempts 0
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/settings/reset$' {
            $changed = @(Reset-CCBridgeSettings $State.AppRoot)
            $keep = @{ port = $State.Config.port; cdpPort = $State.Config.cdpPort }
            $State.Config = Get-CCBridgeConfig harness $State.AppRoot
            $State.Config.port = $keep.port; $State.Config.cdpPort = $keep.cdpPort
            $State.SaveHistory = ($State.Config.chatHistory -ne $false -and "$($State.Config.chatHistory)" -ne 'off')
            Write-CCBLog info server 'Settings reset to the app defaults' @{ changed = $changed -join ', ' }
            return Send-Json $Ctx @{ ok = $true; changed = $changed; settings = @(Get-CCBridgeSettings $State.AppRoot) }
        }
        '^GET /api/sso$' {
            # Settings > Sign-in: work account on this PC, the profile switch, the Copilot tab.
            $st = Get-SsoStatus -Port ([int]$State.Config.cdpPort)
            $st.signIn = $(if ("$($State.Config.signIn)" -eq 'private') { 'private' } else { 'single-sign-on' })
            return Send-Json $Ctx @{ status = $st }
        }
        '^POST /api/sso(/setup|/open)?$' {
            # Only the StreamHub page itself (its Origin) changes how Edge signs in.
            if ($Ctx.Request.Headers['Origin'] -ne "http://localhost:$($State.Config.port)") { return Send-Json $Ctx @{ error = 'Only the StreamHub page can change single sign-on.' } 403 }
            $port = [int]$State.Config.cdpPort
            if ($Matches[1] -eq '/open') { $null = Open-SsoSettingsPage $port; return Send-Json $Ctx @{ ok = $true } }
            if ($Matches[1] -eq '/setup') {
                $r = Invoke-SsoSetup -Port $port -On $true
                return Send-Json $Ctx @{ ok = $true; result = $r.Result; logFile = $r.LogFile; status = (Get-SsoStatus -Port $port -NoPage) }
            }
            $b = Read-JsonBody $Ctx
            $result = Set-ProfileSso -Port $port -On ([bool]$b.on)
            return Send-Json $Ctx @{ ok = $true; result = $result; status = (Get-SsoStatus -Port $port) }
        }
        '^POST /api/hints$' {
            # A one-time hint was shown (it is not shown again, also after a restart).
            $b = Read-JsonBody $Ctx
            Set-UiHintShown $State ([string]$b.name)
            return Send-Json $Ctx @{ ok = $true }
        }
        '^GET /api/edge-cache$' { return Send-Json $Ctx (Get-EdgeCacheInfo) }
        '^POST /api/edge-cache/clear$' {
            # Settings > Privacy: Edge's caches in StreamHub's profile (never the sign-in).
            if ($Ctx.Request.Headers['Origin'] -ne "http://localhost:$($State.Config.port)") { return Send-Json $Ctx @{ error = 'Only the StreamHub page can clear the cache.' } 403 }
            return Send-Json $Ctx (Request-EdgeCacheClear -Port ([int]$State.Config.cdpPort))
        }
        '^POST /api/history/clear$' {
            # Settings > Privacy: forget this project's conversation (the chat view empties too).
            if (-not $State.ProjectRoot) { throw 'Open a project first.' }
            $f = Get-ChatHistoryPath $State.ProjectRoot
            if (Test-Path -LiteralPath $f) { [IO.File]::Delete($f) }
            Reset-ChatHistoryCount $f
            Add-AgentEvent $State 'history-cleared' @{ text = 'Chat history of this project cleared.' }
            Write-CCBLog info server 'Chat history cleared' @{ project = $State.ProjectRoot }
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
            $State.SaveHistory = ($State.Config.chatHistory -ne $false -and "$($State.Config.chatHistory)" -ne 'off')
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
    $State.OpenedAt = $State.SessionSince   # "last change" counts only changes made after this open
    $State.Todos = @()
    $State.NeedNewChat = $State.NeedNewChat -or $State.ChatStarted   # a new project starts a fresh Copilot chat
    Add-AgentEvent $State 'project' @{ name = (Split-Path $Path -Leaf); path = $Path }
    # Older projects move to the current layout once (Runbooks/, StreamHub's records in .streamhub/,
    # capitalised folders); then the project's own code and documents follow the moves.
    # What these change is shown as action cards after the earlier conversation is back (below).
    $moved = @(); $re = $null
    try {
        $moves = New-Object System.Collections.ArrayList
        $moved = @(Move-ProjectLayout $State.ProjectRoot -Moves $moves)
        if ($moves.Count) { $re = Update-MovedReferences $State.ProjectRoot $moves }
    } catch { Write-CCBLogError server 'project layout' $_ }
    try { $null = Invoke-ProjectRetention $State.ProjectRoot $State.Config } catch { Write-CCBLogError server 'retention' $_ }
    $mark = $State.Seq
    if ($State.SaveHistory) { try { $null = Restore-ChatHistory $State $State.ProjectRoot } catch { Write-CCBLogError server 'chat history' $_ } }   # the earlier conversation, back in the chat
    # A new instance of the app starts on a new chat (the earlier one stays in the history file and
    # Arrow Up still recalls its messages); switching projects later shows each project's conversation.
    if (-not $State.FirstProjectOpened) { $State.FirstProjectOpened = $true; Add-AgentEvent $State 'newchat' @{ text = 'New chat: StreamHub started.' } }
    if ($moved.Count) { Add-OwnChangeEvent $State 'move' "$($moved.Count) item(s) to the current folder layout" "Project folders tidied to the current layout: fetch prompts and runbooks in Runbooks/, their data in Runbooks/Exports/, StreamHub's own records (evidence, reviews, plans, earlier data versions) in .streamhub/, folder names with a capital." -Output ($moved -join "`n") }
    foreach ($f in @(if ($re) { $re.files })) {
        # Each file whose links now point at the moved folders: an edit card with its diff.
        $old = try { (Read-TextFile (Join-Path $re.backup $f.path.Replace('/', ''))).Text } catch { $null }
        $new = try { (Read-TextFile (Join-Path $State.ProjectRoot $f.path.Replace('/', ''))).Text } catch { $null }
        Add-OwnChangeEvent $State 'edit' $f.path "$($f.count) link(s) or reference(s) now point at the new folders. The earlier version is kept in $($re.backup)." @{ path = $f.path; exists = $true; old = $old; new = $new }
    }
    Sync-DataMirrors $State   # data copies (JS wrapping a JSON file) follow their JSON
    # Line counts and "new" marks in the Files tab cover the change sets in the restored chat too.
    try { $State.SessionSince = Get-ChangeCountStart $State $mark ([string]$State.SessionSince) } catch { Write-CCBLogError server 'change counts' $_ }
    try { $null = Reset-StaleIssueFixes $State $State.ProjectRoot } catch { Write-CCBLogError server 'issue fix reset' $_ }
    try { $null = Sync-ProjectSchedules $State -Roots @($State.ProjectRoot) -Force } catch { Write-CCBLogError server 'schedule import' $_ }
    $indexing = $false
    try { $indexing = Start-IssueIndexer $State $State.ProjectRoot } catch { Write-CCBLogError server 'issue index' $_ }   # step 1 of the issue cycle, in the background (with the import index)
    if (-not $indexing) { try { $null = Update-ImportIndex $State.ProjectRoot } catch { Write-CCBLogError server 'import index' $_ } }   # issues off: the import index alone
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
    # Instance start: undo backups and chat history of every project get the retention limits.
    try { $null = Invoke-StateRetention $State.Config } catch { Write-CCBLogError server 'state retention' $_ }
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
    if (-not $NoBrowser) {
        # In the Copilot window (default), side by side with it, or in the default browser.
        $mode = if ($State.Config.appWindow) { "$($State.Config.appWindow)" } else { 'copilot-tab' }
        $edgePath = try { Get-EdgePath } catch { $null }
        try { Start-AppWindow -Url $url -Mode $mode -AppPort ([int]$State.Config.port) -CdpPort ([int]$State.Config.cdpPort) -EdgePath $edgePath }
        catch { Write-CCBLogError server 'Opening the app window' $_; Start-Process $url }
    }

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
