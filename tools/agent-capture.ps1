<#
.SYNOPSIS
    Records how a Microsoft 365 Copilot agent run (Researcher, Analyst) looks on the wire and on the
    page, while you use the agent yourself in StreamHub's Edge window. Nothing is sent by this tool.
.DESCRIPTION
    Attaches to the Copilot tab (starting Edge with StreamHub's profile if needed) and records until
    you press Enter (or -MaxMinutes):
      summary.txt   duration, frames per connection, record and message types, silent gaps,
                    when the Stop button showed, agent ids (titleId) seen        - no text
      timeline.txt  every frame, request and page change with its time: record kinds, field
                    names, status words and text lengths                           - no text
      page.txt      how the page shows the run: element ids/roles in the last reply, busy and
                    live regions, agents offered after typing @                    - no text
      shape.txt     field structure of all frames (tools\stream-shape.ps1)         - no text
      frames.jsonl  the raw frames (full replies, for replay); share only if you are fine
                    with its content
    The four text-free files are also zipped (agent-capture-<label>.zip) for sending.
    -KeepStepText adds the text of progress steps ("Searching the web...") to timeline.txt.
    -Seconds N stops after N seconds and -NoPicker skips the @ step (for unattended tests).

    -Agent Researcher|Analyst runs the test by itself, the way StreamHub will: a new chat, the
    prompt starting with "@Name" (-PickFromList picks the agent from the @ list), a fixed harmless test
    prompt (Analyst: a made-up CSV is attached), Send, one automatic answer if the agent first
    asks questions or shows a plan, and stop when the run has finished (or -RunMinutes).
    Every step goes to run.log (no reply text), and the zip includes it. -AgentName sets the
    name shown in the @ list when it differs (another language).
.EXAMPLE
    agent-capture.cmd -Label researcher
    agent-capture.cmd -Label analyst -KeepStepText
    agent-capture.cmd -Agent Researcher
    agent-test.cmd   (both agents, one after the other)
#>
param([string]$Label = 'agent', [int]$MaxMinutes = 90, [string]$OutRoot = 'C:\temp', [switch]$KeepStepText, [int]$Seconds = 0, [switch]$NoPicker,
    [ValidateSet('', 'Researcher', 'Analyst')][string]$Agent = '', [string]$AgentName = '', [int]$RunMinutes = 40,
    [switch]$SkipMention,   # test aid: the same run in a plain chat, without the agent
    [switch]$PickFromList)  # pick the agent from the @ list instead of typing "@Name" in the prompt
if ($Agent) { $Label = $Agent; if (-not $AgentName) { $AgentName = $Agent }; $MaxMinutes = $RunMinutes }

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Log', 'Cdp', 'Config', 'CopilotBridge') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$sel = Get-CCBridgeConfig selectors $root
$cfg = Get-CCBridgeConfig harness $root
$port = if ($cfg.cdpPort) { [int]$cfg.cdpPort } else { 9333 }
$Label = ($Label.ToLowerInvariant() -replace '[^a-z0-9-]', '')
if (-not $Label) { $Label = 'agent' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $OutRoot "StreamHub-agent-capture-$Label-$stamp"
$null = New-Item -ItemType Directory -Force -Path $out
$enc = New-Object Text.UTF8Encoding($false)
$framesW = New-Object IO.StreamWriter((Join-Path $out 'frames.jsonl'), $false, $enc)
$timeline = New-Object System.Collections.Generic.List[string]
$pageLog = New-Object System.Collections.Generic.List[string]
$runLog = New-Object System.Collections.Generic.List[string]
$sep = [char]0x1e
$clock = [Diagnostics.Stopwatch]::StartNew()
function T { '{0,8:N1}s' -f $clock.Elapsed.TotalSeconds }
function Write-Run([string]$Text, [string]$Color = 'Gray') { $runLog.Add("$(T)  $Text"); $timeline.Add("$(T)  run       $Text"); Write-Host "  $Text" -ForegroundColor $Color }
function Add-Line([string]$Text) { $timeline.Add("$(T)  $Text") }

# --- What is kept: status words only (letters, short), lengths for everything else -------------
$statusKeys = '^(messageType|contentOrigin|contentType|author|state|status|kind|result|value|type|target|messageSubType|invocationType|renderType|stage|phase|step|stepType|toolName|tool|language|mimeType|format|finishReason|isFinal|final|done|completed)$'
function Test-Word([string]$S) { $S.Length -le 40 -and $S -match '^[A-Za-z][A-Za-z_.]*$' }
function Scrub-Path([string]$Url) {
    try { $u = [uri]$Url } catch { return '?' }
    $segs = @($u.AbsolutePath.Split('/') | ForEach-Object { if ($_ -match '^[0-9a-fA-F-]{16,}$|\d{5,}|^[A-Za-z0-9_-]{24,}$|%40|@') { '*' } else { $_ } })
    "$($u.Host)$($segs -join '/')"
}
$seenPaths = New-Object 'System.Collections.Generic.HashSet[string]'
function Get-RecordInfo($Node, [string]$Path, $Words, $NewPaths, [ref]$TextLen, $Steps, [int]$Depth = 0) {
    if ($null -eq $Node -or $Depth -gt 10) { return }
    if ($Node -is [array]) { foreach ($el in ($Node | Select-Object -First 50)) { Get-RecordInfo $el "$Path[]" $Words $NewPaths $TextLen $Steps ($Depth + 1) }; return }
    if ($Node -is [pscustomobject]) {
        $mt = if ($Node.PSObject.Properties['messageType']) { "$($Node.messageType)" } else { '' }
        if ($KeepStepText -and $mt -and $Node.PSObject.Properties['text'] -and "$($Node.text)") { $t = "$($Node.text)" -replace '\s+', ' '; $Steps.Add("${mt}: $($t.Substring(0, [Math]::Min(120, $t.Length)))") }
        foreach ($p in $Node.PSObject.Properties) {
            $pp = if ($Path) { "$Path.$($p.Name)" } else { $p.Name }
            if ($seenPaths.Add($pp)) { $NewPaths.Add($pp) }
            $v = $p.Value
            if ($v -is [string]) {
                if ($p.Name -match $statusKeys -and (Test-Word $v)) { [void]$Words.Add("$($p.Name)=$v") }
                elseif ($p.Name -eq 'text') { $TextLen.Value += $v.Length }
            } elseif ($v -is [bool]) { if ($p.Name -match $statusKeys) { [void]$Words.Add("$($p.Name)=$v") } }
            elseif ($p.Name -match '^(type|status|state)$' -and $null -ne $v -and ($v -is [int] -or $v -is [long])) { [void]$Words.Add("$($p.Name)=$v") }
            else { Get-RecordInfo $v $pp $Words $NewPaths $TextLen $Steps ($Depth + 1) }
        }
    }
}
$stats = @{ frames = 0; bytes = 0; kinds = @{}; words = @{}; sockets = @{}; lastFrame = 0.0; gaps = New-Object System.Collections.Generic.List[string]; firstIn = $null; type2 = New-Object System.Collections.Generic.List[string] }
function Add-Payload([string]$Conn, [string]$Dir, [string]$Payload) {
    $now = $clock.Elapsed.TotalSeconds
    if ($Dir -eq 'in') {
        if ($stats.lastFrame -gt 0 -and ($now - $stats.lastFrame) -ge 15) { $stats.gaps.Add(('{0:N0}s at {1:N0}s' -f ($now - $stats.lastFrame), $stats.lastFrame)) }
        $stats.lastFrame = $now
        if ($null -eq $stats.firstIn) { $stats.firstIn = $now }
        $stats.frames++; $stats.bytes += $Payload.Length
        $framesW.WriteLine($Payload.Replace("`r", ' ').Replace("`n", ' '))
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($rec in $Payload.Split($sep)) {
        if (-not $rec.Trim()) { continue }
        try { $o = $rec | ConvertFrom-Json } catch { $parts.Add("non-json($($rec.Length))"); continue }
        $kind = if ($null -ne $o.type) { "type$($o.type)$(if ($o.target) { ":$($o.target)" })" } elseif ($o -is [pscustomobject]) { '{' + ((@($o.PSObject.Properties.Name) | Select-Object -First 3) -join ',') + '}' } else { 'value' }
        $stats.kinds[$kind] = 1 + [int]$stats.kinds[$kind]
        if ($kind -like 'type2*' -and $Dir -eq 'in') { $stats.type2.Add((T)) }
        $words = New-Object 'System.Collections.Generic.HashSet[string]'
        $newPaths = New-Object System.Collections.Generic.List[string]
        $steps = New-Object System.Collections.Generic.List[string]
        $tl = 0
        if ($Dir -eq 'in') { Get-RecordInfo $o '' $words $newPaths ([ref]$tl) $steps }
        foreach ($w in $words) { $stats.words[$w] = 1 + [int]$stats.words[$w] }
        $desc = "$kind len=$($rec.Length)$(if ($tl) { " text=$tl" })$(if ($words.Count) { ' [' + ((@($words) | Where-Object { $_ -notmatch '^(type|target)=' } | Sort-Object) -join ' ') + ']' })"
        if ($newPaths.Count) { $desc += "`n            + new fields: " + ((@($newPaths) | Select-Object -First 40) -join ', ') }
        foreach ($s in $steps) { $desc += "`n            step: $s" }
        $parts.Add($desc)
    }
    Add-Line ("ws-$Dir {0,-10} {1}" -f $Conn, ($parts -join ' + '))
}

# --- Page probe: structure only ----------------------------------------------------------------
$stopSel = ($sel.stopButton -replace "'", "\'")
$replySel = ($sel.replyContainer -replace "'", "\'")
$probeJs = @"
(() => {
  const words = (s) => (s || '').trim().length <= 40 && /^[A-Za-z][A-Za-z ']*$/.test((s || '').trim()) ? (s || '').trim() : '';
  const u = new URL(location.href);
  const replies = document.querySelectorAll('$replySel');
  const last = replies[replies.length - 1];
  const sig = {};
  if (last) for (const e of last.querySelectorAll('*')) {
    const r = e.getAttribute('role'), t = e.getAttribute('data-testid'), tag = e.tagName.toLowerCase();
    if (!(r || t || /^(pre|code|img|canvas|svg|table|details|summary|iframe|button|a|ol|ul)$/.test(tag))) continue;
    const k = tag + (r ? '[role=' + r + ']' : '') + (t ? '[testid=' + t + ']' : '');
    sig[k] = (sig[k] || 0) + 1;
  }
  const testids = {};
  for (const e of document.querySelectorAll('[data-testid]')) { const t = e.getAttribute('data-testid'); if (/progress|step|reason|think|research|analy|agent|code|chart|plan|status|activity|citation|reference|source|message|reply|turn|loader|spinner/i.test(t)) testids[t] = (testids[t] || 0) + 1; }
  const live = [...document.querySelectorAll('[role=status],[role=progressbar],[aria-busy=true],[aria-live]')].map(e => e.tagName.toLowerCase() + (e.getAttribute('role') ? '[role=' + e.getAttribute('role') + ']' : '') + (e.getAttribute('data-testid') ? '[testid=' + e.getAttribute('data-testid') + ']' : '') + (e.getAttribute('aria-busy') === 'true' ? '[busy]' : ''));
  const lastButtons = last ? [...last.querySelectorAll('button')].map(b => words(b.getAttribute('aria-label'))).filter(Boolean) : [];
  const lt = last ? (last.innerText || '') : '';
  const lines = lt.split('\n').map(l => l.trim()).filter(Boolean);
  let jsonOk = 0, jsonBad = 0;
  if (last) for (const p of last.querySelectorAll('pre')) { const c = (p.innerText || '').trim(); if (/^[\[{]/.test(c)) { try { JSON.parse(c); jsonOk++; } catch (e) { jsonBad++; } } }
  const ana = { questions: lines.filter(l => /\?\s*$/.test(l)).length, numbered: lines.filter(l => /^\d+[.)]\s/.test(l)).length,
    asks: /\b(proceed|confirm|shall I|should I|would you like|do you want|let me know)\b/i.test(lt), pre: last ? last.querySelectorAll('pre').length : 0,
    jsonOk, jsonBad, links: last ? last.querySelectorAll('a[href]').length : 0, headings: last ? last.querySelectorAll('h1,h2,h3,h4').length : 0,
    images: last ? last.querySelectorAll('img,canvas,svg[role=img]').length : 0, tables: last ? last.querySelectorAll('table').length : 0 };
  return JSON.stringify({ path: u.pathname, titleId: u.searchParams.get('titleId') || '', stop: !!document.querySelector('$stopSel'),
    replies: replies.length, lastTextLen: last ? (last.innerText || '').length : 0, ana,
    last: Object.entries(sig).sort().map(([k, v]) => k + ' x' + v).slice(0, 80),
    buttons: [...new Set(lastButtons)].slice(0, 20), live: [...new Set(live)].slice(0, 20),
    testids: Object.entries(testids).sort().map(([k, v]) => k + ' x' + v).slice(0, 80) });
})()
"@
$agentsJs = @'
(() => {
  const out = []; const seen = new Set();
  for (const e of document.querySelectorAll('[href*="titleId="], [data-titleid], [data-title-id]')) {
    const href = e.getAttribute('href') || '';
    const m = href.match(/titleId=([A-Za-z0-9_-]+)/);
    const id = m ? m[1] : (e.getAttribute('data-titleid') || e.getAttribute('data-title-id') || '');
    const name = (e.innerText || e.getAttribute('aria-label') || '').trim().split('\n')[0].slice(0, 40);
    if (id && !seen.has(id)) { seen.add(id); out.push(name + ' = ' + id); }
  }
  return JSON.stringify(out.slice(0, 60));
})()
'@
$pickerJs = @'
(() => {
  const opts = [...document.querySelectorAll('[role=option],[role=menuitem],[role=listbox] [role=button],[data-testid*=mention i],[data-testid*=agent i]')];
  return JSON.stringify(opts.slice(0, 40).map(e => ({ role: e.getAttribute('role') || '', testid: e.getAttribute('data-testid') || '',
    name: (e.innerText || e.getAttribute('aria-label') || '').trim().split('\n')[0].slice(0, 40), cls: (typeof e.className === 'string' ? e.className : '').split(/\s+/).filter(c => /^(fui-|fai-|ms-)/.test(c)).slice(0, 3).join(' ') })));
})()
'@

# --- Connect -------------------------------------------------------------------------------------
Write-Host "StreamHub agent capture ($Label)" -ForegroundColor White
Write-Host "Output: $out"
$null = Start-CdpEdge -Port $port -Url $sel.chatUrl
$target = Get-CopilotTarget -Port $port -Selectors $sel
$s = Connect-Cdp $target.webSocketDebuggerUrl
$null = Invoke-Cdp $s 'Network.enable'
$null = Invoke-Cdp $s 'Page.enable'
$pageLog.Add("Edge: $((Invoke-RestMethod "http://127.0.0.1:$port/json/version").Browser)")

if ($Label -like '*analyst*') {
    # A small made-up data file to attach (no real data).
    $csv = New-Object System.Collections.Generic.List[string]
    $csv.Add('date,region,product,units,unit_price')
    $rnd = New-Object Random 7
    $products = 'Widget', 'Gadget', 'Gizmo', 'Doohickey'; $regions = 'North', 'South', 'East', 'West'
    for ($i = 0; $i -lt 240; $i++) {
        $d = (Get-Date '2026-01-01').AddDays($rnd.Next(0, 270)).ToString('yyyy-MM-dd')
        $p = $products[$rnd.Next(0, 4)]
        $csv.Add("$d,$($regions[$rnd.Next(0, 4)]),$p,$($rnd.Next(1, 40)),$([Math]::Round(5 + 3 * [Array]::IndexOf($products, $p) + $rnd.NextDouble(), 2))")
    }
    [IO.File]::WriteAllLines((Join-Path $out 'sample-sales.csv'), [string[]]$csv)
}

# --- Automatic run (-Agent): the steps StreamHub will take -------------------------------------
$editorSel = ($sel.editor -replace "'", "\'")
$sendSel = ($sel.sendButton -replace "'", "\'")
function Send-Key($k, $c, $code, $mod = 0, $cmds = @()) {
    $d = @{ type = 'rawKeyDown'; key = $k; code = $c; windowsVirtualKeyCode = $code; modifiers = $mod }; if ($cmds) { $d.commands = $cmds }
    $null = Invoke-Cdp $s 'Input.dispatchKeyEvent' $d
    $null = Invoke-Cdp $s 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = $k; code = $c; windowsVirtualKeyCode = $code; modifiers = $mod }
}
function Get-EditorLength { Invoke-CdpEval $s "(() => { const e = document.querySelector('$editorSel'); return e ? (e.innerText || '').replace(/[\u200b\u200c\r\n]/g, '').length : -1 })()" }
function Clear-Editor {
    $null = Invoke-CdpEval $s "(() => { const e = document.querySelector('$editorSel'); if (e) e.focus(); return !!e })()"
    for ($i = 0; $i -lt 3 -and (Get-EditorLength) -gt 0; $i++) { Send-Key 'a' 'KeyA' 65 2 @('selectAll'); Send-Key 'Backspace' 'Backspace' 8; Start-Sleep -Milliseconds 200 }
    Get-EditorLength
}
function Get-EditorShape([string]$Name) {
    # Elements in the message box: tags and attribute names only; text only when it is the agent name.
    $n = ($Name -replace "'", "\'")
    Invoke-CdpEval $s @"
(() => { const e = document.querySelector('$editorSel'); if (!e) return 'no editor';
  return [...e.querySelectorAll('*')].slice(0, 30).map(x => { const t = (x.innerText || '').trim();
    const attrs = [...x.attributes].map(a => a.name + (/^(role|contenteditable|data-lexical-[a-z-]+|aria-label|spellcheck|data-[a-z-]*mention[a-z-]*)$/.test(a.name) && a.value.length <= 30 && !/@/.test(a.value) ? '=' + a.value : '')).join(' ');
    return x.tagName.toLowerCase() + '[' + attrs + '] ' + (t.replace(/[\u200b\u200c]/g, '') === '$n' || t.replace(/[\u200b\u200c]/g, '') === '@$n' ? JSON.stringify(t.replace(/[\u200b\u200c]/g, '')) : 'len=' + t.length); }).join(' | ');
})()
"@
}
$listJs = @'
(() => { const lb = document.querySelector('[id^=peek-listbox], [role=listbox]'); if (!lb) return JSON.stringify({ listbox: false });
  const opts = [...lb.querySelectorAll('[role=option], [role=menuitem], [role=menuitemradio]')];
  return JSON.stringify({ listbox: true, id: (lb.id || '').replace(/_r_[a-z0-9]+_?/i, '*'), aria: lb.getAttribute('aria-label') || '', noResults: !!lb.querySelector('[data-testid=no-results-svg]'),
    options: opts.slice(0, 25).map(o => ({ role: o.getAttribute('role'), testid: o.getAttribute('data-testid') || '', selected: o.getAttribute('aria-selected') || '',
      name: (o.innerText || o.getAttribute('aria-label') || '').trim().split('\n')[0].slice(0, 40) })) }); })()
'@
function Invoke-Mention([string]$Name) {
    if ((Clear-Editor) -gt 0) { Write-Run 'could not clear the message box' 'Yellow' }
    $null = Invoke-Cdp $s 'Input.insertText' @{ text = '@' }
    Start-Sleep -Milliseconds 1500
    Write-Run ('after typing @: ' + (Invoke-CdpEval $s $listJs))
    $null = Invoke-Cdp $s 'Input.insertText' @{ text = $Name }
    $n = ($Name -replace "'", "\'")
    # The list's entries do not carry a standard role, so the entry is found by its visible name:
    # the innermost visible element whose first text line is the name, outside the message box,
    # preferring the suggestion pop-up. Returns its centre and its structure (for the log).
    $findJs = @"
(() => {
  const want = '$n'.toLowerCase();
  const editor = document.querySelector('$editorSel');
  const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const first = (e) => ((e.innerText || '').trim().split('\n')[0] || '').trim().toLowerCase();
  const all = [...document.querySelectorAll('body *')].filter(e => !(editor && (editor === e || editor.contains(e))) && vis(e) && first(e) === want);
  const inner = all.filter(e => !all.some(o => o !== e && e.contains(o)));
  if (!inner.length) return '';
  const inPopup = (e) => !!e.closest('[id^=peek-listbox], [role=listbox], [role=dialog], [role=menu], [data-portal-node], .fui-Popover, [class*=popover i], [class*=suggest i]');
  const er = editor ? editor.getBoundingClientRect() : null;
  const dist = (e) => { if (!er) return 0; const r = e.getBoundingClientRect(); return Math.abs((r.top + r.bottom) / 2 - (er.top + er.bottom) / 2); };
  inner.sort((a, b) => (inPopup(b) - inPopup(a)) || (dist(a) - dist(b)));
  const el = inner[0];
  const hit = el.closest('[role=option], [role=menuitem], [role=menuitemradio], [role=button], button, li, [tabindex], [data-testid]') || el;
  hit.scrollIntoView({ block: 'nearest' });
  const r = hit.getBoundingClientRect();
  const chain = []; for (let p = hit, i = 0; p && i < 6; p = p.parentElement, i++) chain.push(p.tagName.toLowerCase() + (p.getAttribute('role') ? '[role=' + p.getAttribute('role') + ']' : '') + (p.getAttribute('data-testid') ? '[testid=' + p.getAttribute('data-testid') + ']' : '') + (p.id ? '#' + p.id.replace(/_r_[a-z0-9]+_?/i, '*') : ''));
  const box = hit.parentElement || hit;
  const items = [...box.children].slice(0, 10).map(x => x.tagName.toLowerCase() + (x.getAttribute('role') ? '[role=' + x.getAttribute('role') + ']' : '') + ' "' + ((x.innerText || '').trim().split('\n')[0] || '').slice(0, 30) + '"');
  return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2, matches: inner.length, inPopup: inPopup(el), chain, siblings: items });
})()
"@
    $found = $null
    for ($i = 0; $i -lt 40 -and -not $found; $i++) {
        Start-Sleep -Milliseconds 250
        $j = Invoke-CdpEval $s $findJs
        if ($j) { $found = $j | ConvertFrom-Json }
    }
    if (-not $found) {
        # The agents are assumed to be there: the test goes on with "@Name" as typed. Never press
        # Enter here (in Copilot's message box Enter sends the message).
        Write-Run ("after typing @${Name}: " + (Invoke-CdpEval $s $listJs)) 'Yellow'
        Write-Run "no entry named $Name found in the @ list; going on with '@$Name' as typed (the agent is assumed to be there)" 'Yellow'
        return $true
    }
    Write-Run ("list entry for ${Name}: " + (@{ matches = $found.matches; inPopup = $found.inPopup; chain = @($found.chain) -join ' < '; siblings = @($found.siblings) -join ' | ' } | ConvertTo-Json -Compress))
    # A real mouse click on the entry (some lists ignore a scripted click).
    foreach ($t in 'mouseMoved', 'mousePressed', 'mouseReleased') {
        $ev = @{ type = $t; x = [double]$found.x; y = [double]$found.y; button = 'left'; clickCount = 1 }
        if ($t -eq 'mouseMoved') { $ev.button = 'none'; $ev.clickCount = 0 }
        $null = Invoke-Cdp $s 'Input.dispatchMouseEvent' $ev
        Start-Sleep -Milliseconds 60
    }
    $picked = 'mouse click'
    Write-Run "clicked the list item for $Name ($picked)"
    Start-Sleep -Milliseconds 1200
    $shape = Get-EditorShape $Name
    Write-Run "message box after the mention: $shape"
    $plain = Invoke-CdpEval $s "(() => { const e = document.querySelector('$editorSel'); return !!e && [...e.querySelectorAll('[data-lexical-text=true]')].some(x => /@$n/i.test(x.innerText || '')) })()"
    $ok = -not $plain -and (Get-EditorLength) -ge 0
    Write-Run $(if ($ok) { "mention inserted (no plain '@$Name' text left)" } else { "the mention still looks like plain '@$Name' text; going on anyway (the agent is assumed to be there)" }) $(if ($ok) { 'Green' } else { 'Yellow' })
    $true
}
function Invoke-Send {
    for ($i = 0; $i -lt 40; $i++) {
        $r = Invoke-CdpEval $s "(() => { const b = document.querySelector('$sendSel'); if (!b || b.disabled || b.getAttribute('aria-disabled') === 'true') return false; b.click(); return true })()"
        if ($r) { return $true }
        Start-Sleep -Milliseconds 250
    }
    $false
}
function Add-FileUpload([string]$Path) {
    $doc = Invoke-Cdp $s 'DOM.getDocument' @{ depth = -1; pierce = $true }
    $q = Invoke-Cdp $s 'DOM.querySelectorAll' @{ nodeId = $doc.root.nodeId; selector = 'input[type=file]' }
    $ids = @($q.nodeIds)
    Write-Run "file inputs on the page: $($ids.Count)"
    foreach ($id in $ids) {
        $a = @((Invoke-Cdp $s 'DOM.getAttributes' @{ nodeId = $id }).attributes)
        $acc = ''; for ($i = 0; $i + 1 -lt $a.Count; $i += 2) { if ($a[$i] -eq 'accept') { $acc = $a[$i + 1] } }
        if ($acc -and $acc -notmatch '(?i)csv|text|\*|spreadsheet|excel|xlsx') { Write-Run "  skipped an input that accepts: $acc"; continue }
        $null = Invoke-Cdp $s 'DOM.setFileInputFiles' @{ nodeId = $id; files = @($Path) }
        Write-Run "  file handed to an input (accept='$acc'); waiting for the attachment to show"
        for ($w = 0; $w -lt 40; $w++) {
            Start-Sleep -Milliseconds 500
            $chip = Invoke-CdpEval $s "(() => [...document.querySelectorAll('[data-testid]')].filter(e => /attach|file|chip|upload|reference/i.test(e.getAttribute('data-testid'))).map(e => e.getAttribute('data-testid')).slice(0, 10).join(', '))()"
            if ($chip) { Write-Run "  attachment elements: $chip"; return $true }
        }
        Write-Run '  no attachment element appeared' 'Yellow'
    }
    $false
}
$prompts = @{
    researcher = 'Using web sources only: compare three popular open-source static site generators by language, license and release cadence. Keep the report short, and end with a json code block listing each one with name, language and license.'
    analyst = 'Using the attached file: give the monthly revenue (units x unit_price) and the top 3 products by revenue, make one chart of monthly revenue, and end with a json code block of the monthly totals.'
}
$answers = @{
    researcher = 'Proceed with your best assumptions and list them at the start of the report. Use web sources only and keep it short.'
    analyst = 'Proceed with the plan. Keep the output short and end with the json code block.'
}
$auto = $null
if ($Agent) {
    $null = Invoke-Cdp $s 'Emulation.setFocusEmulationEnabled' @{ enabled = $true }
    $key = $Agent.ToLowerInvariant()
    Write-Host ''
    Write-Host "Automatic test of $Agent (mentioned as @$AgentName). Watch the Copilot window; press Enter here to stop early." -ForegroundColor Cyan
    Write-Run "new chat: $($sel.chatUrl)"
    $null = Invoke-Cdp $s 'Page.navigate' @{ url = $sel.chatUrl }
    $stable = 0
    for ($i = 0; $i -lt 120 -and $stable -lt 6; $i++) { Start-Sleep -Milliseconds 500; if ((Get-EditorLength) -ge 0) { $stable++ } else { $stable = 0 } }
    if ($stable -lt 6) { Write-Run 'the message box did not appear; is this window signed in?' 'Red' }
    Start-Sleep -Seconds 2
    $pageLog.Add('Agent links on the page: ' + (Invoke-CdpEval $s $agentsJs))
    # "@Name" at the start of the prompt invokes the agent; -PickFromList uses the @ list instead.
    $prefix = ''
    $mentioned = if ($SkipMention) { Write-Run 'mention skipped (-SkipMention): plain chat'; $true }
        elseif ($PickFromList) { Invoke-Mention $AgentName }
        else { $prefix = "@$AgentName"; $null = Clear-Editor; Write-Run "the prompt starts with '@$AgentName' (typed as text)"; $true }
    if (-not $mentioned) { Write-Run 'stopped without sending anything' 'Red' }
    if ($mentioned -and $key -eq 'analyst') {
        if (-not (Add-FileUpload (Join-Path $out 'sample-sales.csv'))) {
            Write-Host "  Attach $(Join-Path $out 'sample-sales.csv') yourself with the + button in the Copilot window, then press Enter here." -ForegroundColor Yellow
            [void](Read-Host)
            Write-Run 'file attached by hand'
        }
    }
    if ($mentioned) {
        $null = Invoke-Cdp $s 'Input.insertText' @{ text = "$prefix " + $prompts[$key] }
        Start-Sleep -Milliseconds 800
        Write-Run "prompt typed ($($prompts[$key].Length) chars); message box: $(Get-EditorShape $AgentName); length $(Get-EditorLength)"
        if (Invoke-Send) { Write-Run 'sent' 'Green' } else { Write-Run 'the Send button never became clickable' 'Red' }
        $auto = @{ key = $key; sentAt = $clock.Elapsed.TotalSeconds; sawStop = $false; doneSince = $null; lastLen = -1; answered = 0; finished = $false }
    } else {
        $auto = @{ key = $key; sentAt = 0; finished = $true; result = 'not sent: the agent could not be mentioned'; answered = 0 }
    }
}

if ($Agent) { } else {
Write-Host ''
Write-Host 'Step 1 (optional): in the Copilot window, open a NORMAL chat, click into the message box and type a single @ (do not send).' -ForegroundColor Cyan
Write-Host '        Leave the list that opens visible. Press Enter here to record it, or type s and Enter to skip.'
if (-not $NoPicker -and (Read-Host) -ne 's') {
    $pageLog.Add('Agents offered after typing @: ' + (Invoke-CdpEval $s $pickerJs))
    Write-Host '        Recorded. Clear the message box again.' -ForegroundColor Green
}
$pageLog.Add('Agent links on the page: ' + (Invoke-CdpEval $s $agentsJs))

Write-Host ''
Write-Host 'Step 2: open the agent (Agents > Researcher or Analyst) and run it yourself. Suggested test:' -ForegroundColor Cyan
if ($Label -like '*analyst*') {
    Write-Host "  Attach $(Join-Path $out 'sample-sales.csv') with the + button, then send:" -ForegroundColor Yellow
    Write-Host '  "Using the attached file: give the monthly revenue (units x unit_price) and the top 3 products by revenue, make one chart of monthly revenue, and end with a json code block of the monthly totals."' -ForegroundColor Yellow
} else {
    Write-Host '  "Using web sources only: compare three popular open-source static site generators by language, license and release cadence. Keep the report short, and end with a json code block listing each one with name, language and license."' -ForegroundColor Yellow
}
Write-Host '  Answer any questions it asks (that is part of what is recorded) and wait until the run has fully finished.'
Write-Host "  Recording now. Press Enter here when the run is complete (stops by itself after $MaxMinutes minutes)." -ForegroundColor Cyan
}

# --- Record --------------------------------------------------------------------------------------
$sockets = @{}      # requestId -> label
$requests = @{}     # requestId -> scrubbed path (http)
$lastProbe = ''; $nextProbe = 0.0; $nextBeat = 15.0; $stopSince = $null
$stopWindows = New-Object System.Collections.Generic.List[string]
$deadline = if ($Seconds -gt 0) { $Seconds } else { $MaxMinutes * 60 }
while ($clock.Elapsed.TotalSeconds -lt $deadline) {
    $key = $false
    try { if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'Enter') { $key = $true } } } catch { }
    if ($key) { break }
    $ev = $null
    try { $ev = Receive-CdpEvent $s 250 } catch { Add-Line "connection lost: $($_.Exception.Message)"; Write-Host 'Lost the connection to the tab; stopping.' -ForegroundColor Yellow; break }
    if ($ev -and $ev.method) {
        $p = $ev.params
        switch ($ev.method) {
            'Network.webSocketCreated' {
                $lbl = if ($p.url -match '(?i)/Chathub/') { 'chathub' } elseif ($p.url -match '(?i)/StreamHub/') { 'streamhub' } else { 'ws' + ($sockets.Count + 1) }
                $sockets[$p.requestId] = $lbl
                Add-Line "ws-open   $lbl $(Scrub-Path $p.url)"
            }
            'Network.webSocketClosed' { Add-Line "ws-close  $($sockets[$p.requestId])" }
            'Network.webSocketFrameReceived' {
                $lbl = if ($sockets[$p.requestId]) { $sockets[$p.requestId] } else { 'ws?' }
                $stats.sockets[$lbl] = 1 + [int]$stats.sockets[$lbl]
                if ($p.response.opcode -eq 1) { Add-Payload $lbl 'in' "$($p.response.payloadData)" } else { Add-Line "ws-in     $lbl binary len=$("$($p.response.payloadData)".Length)" }
            }
            'Network.webSocketFrameSent' {
                $lbl = if ($sockets[$p.requestId]) { $sockets[$p.requestId] } else { 'ws?' }
                if ($p.response.opcode -eq 1) { Add-Payload $lbl 'out' "$($p.response.payloadData)" }
            }
            'Network.eventSourceMessageReceived' {
                Add-Line "sse       $($requests[$p.requestId]) event=$(if (Test-Word "$($p.eventName)") { $p.eventName } else { '?' }) len=$("$($p.data)".Length)"
                $stats.sockets['sse'] = 1 + [int]$stats.sockets['sse']
                Add-Payload 'sse' 'in' "$($p.data)"
            }
            'Network.requestWillBeSent' {
                $t = "$($p.type)"
                if ($t -notin 'Image', 'Font', 'Stylesheet', 'Script', 'Media', 'Manifest' -and "$($p.request.url)" -match '(?i)^https://[^/]*(substrate|cloud\.microsoft|office|microsoft365|bing|sharepoint|graph|sydney|copilot)') {
                    $requests[$p.requestId] = Scrub-Path $p.request.url
                    Add-Line "http      $($p.request.method) $($requests[$p.requestId]) ($t)"
                }
            }
            'Network.responseReceived' { if ($requests[$p.requestId]) { Add-Line "http-resp $($p.response.status) $($p.response.mimeType) $($requests[$p.requestId])" } }
            'Network.loadingFinished' { if ($requests[$p.requestId]) { Add-Line "http-done len=$($p.encodedDataLength) $($requests[$p.requestId])" } }
            'Page.frameNavigated' { if (-not $p.frame.parentId) { $u = [uri]$p.frame.url; $tid = [regex]::Match($u.Query, 'titleId=([A-Za-z0-9_-]+)').Groups[1].Value; Add-Line "navigate  $($u.Host)$($u.AbsolutePath)$(if ($tid) { " titleId=$tid" })" } }
        }
    }
    $now = $clock.Elapsed.TotalSeconds
    if ($now -ge $nextProbe) {
        $nextProbe = $now + 2
        try {
            $pj = Invoke-CdpEval $s $probeJs
            $po = $pj | ConvertFrom-Json
            if ($po.stop -and -not $stopSince) { $stopSince = $now; Add-Line 'page      Stop button shown' }
            if (-not $po.stop -and $stopSince) { $stopWindows.Add(('{0:N1}s-{1:N1}s' -f $stopSince, $now)); $stopSince = $null; Add-Line 'page      Stop button gone' }
            $cmp = $pj -replace '"lastTextLen":\d+', '' -replace '"stop":(true|false)', ''
            if ($cmp -ne $lastProbe) {
                $lastProbe = $cmp
                $pageLog.Add(''); $pageLog.Add("$(T)  path=$($po.path) titleId=$($po.titleId) replies=$($po.replies) lastTextLen=$($po.lastTextLen) stop=$($po.stop)")
                $pageLog.Add('  last reply: ' + (@($po.last) -join ', '))
                if (@($po.buttons).Count) { $pageLog.Add('  its buttons: ' + (@($po.buttons) -join ', ')) }
                if (@($po.live).Count) { $pageLog.Add('  busy/live regions: ' + (@($po.live) -join ', ')) }
                $pageLog.Add('  test ids: ' + (@($po.testids) -join ', '))
                Add-Line "page      changed (replies=$($po.replies) lastTextLen=$($po.lastTextLen)); see page.txt"
            }
            if ($auto -and -not $auto.finished) {
                if ($po.stop) { $auto.sawStop = $true }
                $quietFrames = $now - [Math]::Max($stats.lastFrame, $auto.sentAt)
                $settled = -not $po.stop -and $po.lastTextLen -gt 0 -and $po.lastTextLen -eq $auto.lastLen -and $quietFrames -ge 20
                $auto.lastLen = $po.lastTextLen
                if (-not $settled) { $auto.doneSince = $null }
                elseif (-not $auto.doneSince) { $auto.doneSince = $now }
                $waited = $now - $auto.sentAt
                if ($auto.doneSince -and ($now - $auto.doneSince) -ge 10 -and ($auto.sawStop -or $waited -ge 90)) {
                    $a = $po.ana
                    $shape = "len=$($po.lastTextLen) questions=$($a.questions) numbered=$($a.numbered) asks=$($a.asks) codeBlocks=$($a.pre) json=$($a.jsonOk) badJson=$($a.jsonBad) links=$($a.links) headings=$($a.headings) images=$($a.images) tables=$($a.tables)"
                    $checkpoint = $po.lastTextLen -lt 4000 -and $a.jsonOk -eq 0 -and ($a.questions -ge 1 -or $a.asks)
                    if ($checkpoint -and $auto.answered -lt 1) {
                        Write-Run "reply settled after $([int]$waited) s and looks like a checkpoint (questions or a plan): $shape" 'Cyan'
                        $null = Clear-Editor
                        $null = Invoke-Cdp $s 'Input.insertText' @{ text = $answers[$auto.key] }
                        Start-Sleep -Milliseconds 600
                        if (Invoke-Send) { Write-Run 'answered with the fixed reply (no mention), to see whether the agent continues' 'Green' } else { Write-Run 'could not send the answer' 'Red' }
                        $auto.answered++; $auto.sentAt = $now; $auto.sawStop = $false; $auto.doneSince = $null
                    } else {
                        Write-Run "run finished after $([int]$waited) s since the last send: $shape" 'Green'
                        $auto.finished = $true
                        $auto.result = $shape
                    }
                }
            }
        } catch { Add-Line "page      probe failed: $($_.Exception.Message)" }
    }
    if ($auto -and $auto.finished) { break }
    if ($now -ge $nextBeat) {
        $nextBeat = $now + 15
        $quiet = if ($stats.lastFrame) { [int]($now - $stats.lastFrame) } else { [int]$now }
        Write-Host ("  {0:N0}s: {1} frames received, last one {2}s ago{3}" -f $now, $stats.frames, $quiet, $(if ($stopSince) { ', Stop button showing' } else { '' }))
    }
}
if ($stopSince) { $stopWindows.Add(('{0:N1}s-(still showing)' -f $stopSince)) }
try { $pageLog.Add(''); $pageLog.Add('Agent links on the page at the end: ' + (Invoke-CdpEval $s $agentsJs)) } catch { }
$wantName = $AgentName.ToLowerInvariant()
# Whether the agent's name shows next to the last reply (read before disconnecting).
$agentPageSays = $false
if ($Agent -and -not $SkipMention) {
    $agentPageSays = $false
    try {
        $agentPageSays = [bool](Invoke-CdpEval $s @"
(() => { const rs = document.querySelectorAll('$replySel'); const last = rs[rs.length - 1]; if (!last) return false;
  const want = '$($wantName -replace "'", "\'")';
  let p = last; for (let i = 0; i < 5 && p.parentElement; i++) p = p.parentElement;
  const around = (p.innerText || '').replace(last.innerText || '', '');
  return around.toLowerCase().split('\n').some(l => l.trim() === want || l.trim().startsWith(want + ' '));
})()
"@)
    } catch { }
}
try { Disconnect-Cdp $s } catch { }
$framesW.Close()

# --- Write ---------------------------------------------------------------------------------------
$sum = New-Object System.Collections.Generic.List[string]
$sum.Add("StreamHub agent capture '$Label' $(Get-Date -Format 'yyyy-MM-dd HH:mm') - structure and timing only, no text.")
$sum.Add("Recorded: $([Math]::Round($clock.Elapsed.TotalSeconds, 1)) s; first frame in at $(if ($null -ne $stats.firstIn) { '{0:N1}s' -f $stats.firstIn } else { '-' }); frames in: $($stats.frames) ($($stats.bytes) chars)")
$sum.Add('Frames per connection: ' + ((@($stats.sockets.GetEnumerator()) | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))
$sum.Add('Completion records (type2) at: ' + $(if ($stats.type2.Count) { ($stats.type2 | ForEach-Object { $_.Trim() }) -join ', ' } else { 'none' }))
$sum.Add('Stop button shown: ' + $(if ($stopWindows.Count) { $stopWindows -join ', ' } else { 'never seen' }))
$sum.Add('Silent gaps of 15 s or more (no frame in): ' + $(if ($stats.gaps.Count) { $stats.gaps.ToArray() -join ', ' } else { 'none' }))
$sum.Add(''); $sum.Add('Record kinds:')
foreach ($k in ($stats.kinds.GetEnumerator() | Sort-Object Value -Descending)) { $sum.Add("  $($k.Name): $($k.Value)") }
$sum.Add(''); $sum.Add('Status words (key=value: count):')
foreach ($w in ($stats.words.GetEnumerator() | Sort-Object Name)) { $sum.Add("  $($w.Name): $($w.Value)") }
[IO.File]::WriteAllLines((Join-Path $out 'summary.txt'), [string[]]$sum)
[IO.File]::WriteAllLines((Join-Path $out 'timeline.txt'), [string[]]$timeline)
[IO.File]::WriteAllLines((Join-Path $out 'page.txt'), [string[]]$pageLog)
if ($Agent -and -not $SkipMention) {
    # Did the agent answer? Words in the reply stream that name it, and its name next to the reply.
    $want = $AgentName.ToLowerInvariant()
    $wire = @($stats.words.Keys | Where-Object { $_.ToLowerInvariant() -match [regex]::Escape($want) -or $_ -match '(?i)research|analyst|deep.?reason' })
    $pageSays = [bool]$agentPageSays
    $verdict = if ($wire.Count -or $pageSays) { "the agent answered" } else { "no sign that $AgentName answered (it may have been plain Copilot)" }
    $runLog.Add("$(T)  agent check: stream words naming it: $(if ($wire.Count) { $wire -join ', ' } else { 'none' }); name shown with the reply: $(if ($pageSays) { 'yes' } else { 'no' }) => $verdict")
    Write-Host "  agent check: $verdict" -ForegroundColor $(if ($wire.Count -or $pageSays) { 'Green' } else { 'Yellow' })
}
if ($Agent) {
    $runLog.Insert(0, "StreamHub agent test: $Agent mentioned as @$AgentName, $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Steps and counts only, no reply text.")
    if (-not ($auto -and $auto.finished)) { $runLog.Add("$(T)  stopped before the run had clearly finished (Enter, time limit or lost connection)") }
    [IO.File]::WriteAllLines((Join-Path $out 'run.log'), [string[]]$runLog)
    [IO.File]::AppendAllText((Join-Path $out 'summary.txt'), "`r`nAutomatic run: $(if ($auto -and $auto.result) { $auto.result } else { 'not finished' }); answers sent: $(if ($auto) { $auto.answered } else { 0 })`r`n")
}
try { & (Join-Path $root 'tools\stream-shape.ps1') -Path (Join-Path $out 'frames.jsonl') -OutFile (Join-Path $out 'shape.txt') | Out-Null } catch { Write-Host "shape.txt not written: $($_.Exception.Message)" -ForegroundColor Yellow }
$safe = @('summary.txt', 'run.log', 'timeline.txt', 'page.txt', 'shape.txt') | ForEach-Object { Join-Path $out $_ } | Where-Object { Test-Path $_ }
$zip = Join-Path $out "agent-capture-$Label.zip"
Compress-Archive -Path $safe -DestinationPath $zip -Force
Write-Host ''
Write-Host "Done. Please send: $zip" -ForegroundColor Green
Write-Host '  (summary, timeline, page and shape: field names, status words, lengths and timings; no text)'
Write-Host '  frames.jsonl next to it holds the full replies; send it only if you are fine with its content.'
if ($KeepStepText) { Write-Host '  Note: -KeepStepText put progress step texts in timeline.txt; check them before sending.' -ForegroundColor Yellow }
