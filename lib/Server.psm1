# Local web server: serves the built UI from ui\ and a small JSON API for it.
# Bound to localhost only; every API call must carry the per-session token that is
# injected into index.html, so other web pages cannot drive CCBridge.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Config', 'Workspace', 'Executor', 'Agent', 'Fetch') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:Mime = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
    '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.json' = 'application/json'
    '.woff2' = 'font/woff2'; '.woff' = 'font/woff'
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
            if ($State.Busy) { throw 'StreamHub is still working on the previous message' }
            $State.Busy = $true
            $State.Tasks.Enqueue(@{ kind = 'fetch'; name = [string]$b.name })
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/chat$' {
            $b = Read-JsonBody $Ctx
            if (-not $b.text -or -not $b.text.Trim()) { throw 'Empty message' }
            if ($State.Busy) { throw 'StreamHub is still working on the previous message' }
            $State.Busy = $true   # set now so a quick second click is refused
            $State.Tasks.Enqueue(@{ kind = 'chat'; text = [string]$b.text })
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/approve$' {
            $b = Read-JsonBody $Ctx
            # Who decided: the web app sends "user"; anything else calling the API is recorded as "api".
            $by = if ($b.PSObject.Properties['by'] -and $b.by -eq 'user') { 'user' } else { 'api' }
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
            $State.Tasks.Enqueue(@{ kind = 'newchat' })
            return Send-Json $Ctx @{ ok = $true }
        }
        '^POST /api/undo$'    { $State.Tasks.Enqueue(@{ kind = 'undo' }); return Send-Json $Ctx @{ ok = $true } }
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
