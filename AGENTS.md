# CCBridge - instructions for coding agents

> Product name shown to people: **StreamHub** (UI, messages, README, releases). The code, scripts, data folder (`%LOCALAPPDATA%\CCBridge`), projects folder (`OneDrive\CCBridge`), MCP id (`ccbridge`) and the repository keep the name CCBridge. In visible texts and logs, Microsoft's own reply endpoint (`m365Copilot/StreamHub`) is called the "Copilot stream connection" so the two never get confused.

CCBridge is a zero-install coding harness that uses Microsoft 365 Copilot Chat (in Edge) as its model. It ships two front ends over one engine:
- **Web app**: `ccbridge.ps1` / `start.cmd` serves `ui/` on http://localhost:8765 (projects must be under OneDrive).
- **MCP server**: `mcp/ccbridge-mcp.ps1` (stdio), so MCP clients can offload work to Copilot (any project folder).

Target machines have only what ships with Windows: **Windows PowerShell 5.1 + Edge, nothing installed.** Node is only needed on a dev machine to rebuild the UI.

## Layout

| Path | Role |
|---|---|
| `lib/Cdp.psm1` | Minimal Chrome DevTools Protocol client (launch Edge with a debug port, WebSocket, events) |
| `lib/CopilotBridge.psm1` | Types into Copilot Chat, reads the reply from the Chathub SignalR WebSocket, rebuilds damaged replies, machine-wide send lock |
| `lib/Workspace.psm1` | OneDrive projects, path confinement, file listing, read-only `source/` + vault |
| `lib/Protocol.psm1` | Parses action blocks (`read glob grep write edit run todo done`) from replies |
| `lib/Fetch.psm1` | Saved fetch prompts (`fetch/<name>.prompt.md`) and their answer files (`fetch/<name>.md`); the agent job `Invoke-FetchJob` runs one in a fresh chat with kind `fetch` / `fetch-m365` and writes the answer itself (no actions) |
| `lib/Runbook.psm1` | Runbooks (`runbooks/<name>.runbook.md`, templates in `templates/runbooks/`): header parsing, placeholders, JSON extraction and validation against `required` / `itemsKey` / `requiredItemFields`, saving to the output and `exports/history`; the agent job `Invoke-RunbookJob` runs one read-only in a fresh chat with one correction round. Every template's own example must pass its header (tested). |
| `lib/Review.psm1` | Code review rules: `Get-ReviewFiles` (code only; no build output, lock files, data, `source/`), `New-ReviewBatches` (numbered lines, large files in parts, `reviewBatchChars`), `Test-ReviewOutput`, `Test-ReviewQuote` (a finding is verified only when its quoted lines are in the file; line corrected), report `reviews/<id>.md` + `.json`, `New-ReviewFixTasks`. The job `Invoke-ReviewJob` (Agent) is read-only (replies are never executed), keeps progress per part so the daily-limit pause or a restart resumes it, and ends with one whole-project pass. Prompts: `review-code.md`, `review-cross.md`. MCP tool `copilot_review`. |
| `lib/Schedule.psm1` | Schedule rules (`Get-NextRun`: once, daily, weekdays, weekly on chosen days, at one or more HH:mm times; `Test-ScheduleSpec`, `Format-ScheduleWhen`) and Copilot's daily limit (`Test-LimitText`, `Get-LimitResetTime` from metering or "check back at 2:00 AM"). Agent.psm1 keeps the schedules (`schedules.json`), puts due ones in the queue with source `schedule` (`Invoke-DueSchedules`, missed runs once at the next start), and pauses the queue at the limit (`Set-QueuePause`, saved in `queue-pause.json`); a task that did nothing yet goes back to the front (`$State.Held`). |
| `lib/Runbook.psm1` (files) | Runbooks Copilot writes must be `runbooks/NAME.runbook.md` (lowercase, `-`) with the template header (`title`, `output` = a `.json` path inside the project) and a ```json shape: `Test-RunbookFile`, checked in `Invoke-AgentAction` before any write/edit; a misplaced runbook (e.g. `RUNBOOK.md`) is refused with the right path when the request is about runbooks. Requests about runbooks get `prompts/rules/runbook.md` plus `templates/runbooks/blank.runbook.md`. A chat message that names a runbook (name, title, `@runbooks/...` path), or says runbook with a run word, runs it through `Invoke-RunbookJob` like the Run button (`Get-RunbookRunRequest`; not for create/change/question messages). |
| `lib/Executor.psm1` | Carries out actions, checkpoints/undo, `&lt;`/`&gt;` repair. Language helpers: `Get-FileOutline` (HTML, JS/TS, CSS, PowerShell, Markdown, Python), `Set-EditIndent` (re-indents REPLACE after an indentation-insensitive match; refuses uneven matches in Python), `Test-ProjectConsistency` (JSON, PowerShell syntax, `.psd1` as data, Python tab/space mixing, local references with imports resolved like a bundler; packages and aliases skipped), `ConvertTo-CheckableScript` (module JS to classic script for `Test-ScriptSyntax` in Agent, which compiles changed `.js` in Edge without running it). No type checks or linters: nothing like that ships with Windows. |
| `lib/Agent.psm1` | Agent loop + worker runspace; talks to front ends via a synchronized `$State` |
| `lib/Server.psm1` | HTTP server + JSON API for the web UI (token in `%LOCALAPPDATA%\CCBridge\session-token.txt`) |
| `mcp/ccbridge-mcp.ps1` | MCP stdio server: hands its tasks to the running web app (`POST /api/jobs`, shown in the Queue); without the app (or with `CCBRIDGE_MCP_STANDALONE=1`) it runs `Agent.psm1` itself with `$State.Headless` |
| `prompts/` | Small parts assembled per request by `lib/Prompts.psm1` (`New-PromptMessage`): `Get-TaskKind` picks chat / assistant / project / coding / mixed; chat sends the text alone; other kinds add only the parts the chat has not had (`roles/*.md`, `actions.md`, `rules.md` (core), `m365.md`, `save.md`, plus case-specific modules from `Get-PromptModules`: `actions-run.md` unless commands are off, `rules/web.md`, `rules/moving.md`, `rules/python.md`, `rules/powershell.md`, `rules/source.md`, chosen by request words or the project's files (`Get-ProjectTraits`) and sent once per chat; plus the project context from `Get-ProjectContext` with the OneDrive location) |
| `config/` | `harness.json` (ports, budgets), `selectors.json` (Copilot page selectors) |
| `ui-src/` | React + Vite + Tailwind + Kokonut UI source; builds into `ui/` (committed) |
| `tests/` | Pester 3.4 tests; `tests/fixtures` = recorded Copilot traffic |

## Commands

```powershell
# Tests - always with Windows PowerShell 5.1, not pwsh 7 (5.1 is the target and parses differently)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester .\tests"
# Parse-check a script under 5.1
powershell -NoProfile -Command "$e=$null; $null=[Management.Automation.Language.Parser]::ParseFile('<file>',[ref]$null,[ref]$e); $e"
# Rebuild the UI after any change in ui-src (writes ui/)
cd ui-src; npm run build
# Build a release zip (dist\) and publish it as a GitHub Release
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-release.ps1 -Version v0.1.0
# Run the web app / one prompt / the MCP server
.\start.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File ccbridge.ps1 -Ping "say hi" -NewChat
powershell -NoProfile -ExecutionPolicy Bypass -File mcp\ccbridge-mcp.ps1
```

The running web server holds `lib/*.psm1` in memory: restart it after backend changes (the UI files are read fresh from disk).

## PowerShell 5.1 rules (each of these has bitten this repo)

- Keep `.ps1`/`.psm1` **ASCII-only**; BOM-less files are read as ANSI. Write non-ASCII as `\u` escapes in JS strings or `[char]0x..`.
- An `if` without `else` assigned to a variable yields AutomationNull, which `ConvertTo-Json` writes as `{}`. Assign `$null` explicitly first.
- `return , $array` plus a caller's `@()` nests the array. Return arrays plainly and wrap at the call site.
- `$hashtable + @{...}` throws on duplicate keys; use `Join-Hash` (Agent.psm1).
- `Invoke-RestMethod` emits a JSON array as one object; wrap the call in parentheses before piping.
- 2-D array indexes with commas inside method arguments do not parse; use flat arrays.
- Native-command stderr with `$ErrorActionPreference = 'Stop'` becomes a terminating error; silence via `cmd /c "... >nul 2>&1"`.
- Don't name functions like built-in cmdlets (`Wait-Job`, `New-Job`).
- In strings, `"$name: ..."` parses as a scope-qualified variable; write `"${name}: ..."`.
- Log with `Write-CCBLog info|verbose|trace <component> <message> [data]` (lib/Log.psm1). Never put prompt/reply text or file contents below `trace`.
- In the MCP server, stdout is the protocol channel: never let pipeline output or `Write-Host` reach it; log to stderr.

## Copilot Chat quirks the code depends on

- The message box is a **Lexical** editor (`#m365-chat-editor-target-element`): it is re-mounted about 3 times after load (wait until the same element is stable), ignores `execCommand` (clear with Ctrl+A/Backspace key events), and turns `\r` into extra characters (send `\n` only).
- Replies arrive on `substrate.office.com/m365Copilot/Chathub` (SignalR, records separated by `0x1e`); a `type:2` record ends the reply and carries throttling (messages per chat) and metering (daily credits, `OutOfCredits`).
- Copilot's **link/citation filter damages code** in snapshots and the final text (`[name]:`, `[guid]::`, `[x](...)` vanish). The reply is rebuilt from raw `writeAtCursor` chunks (`Add-ReplySnapshot`). Never use the server's final text for code.
- The page escapes `<` and `>` in prompts to `&lt;`/`&gt;`, so Copilot may copy entities into SEARCH text or code; Executor repairs this except in markup files.
- Some tenants deliver the reply over **StreamHub** (`substrate.svc.cloud.microsoft/m365Copilot/StreamHub`): SignalR type-2 stream items. `Add-StreamRecord` finds chunks (`writeAtCursor`), snapshots (`messages`) and the end (`result`, a final flag/state, or a type-3 completion) by field name; `Complete-StreamReply` returns at that end, taking the text from the stream or, if none is recognised, straight from the page state. Sockets are classified per request id in `$Bridge.HubSockets` (`chat` / `stream`) by URL or traffic shape (`Get-SocketKind`).
- Some tenants do not deliver the reply over Chathub. `Send-CopilotPromptUnlocked` also watches the page (`Get-PageReplyState`: Stop gone, new reply with a Copy button) and then reads the raw markdown from the page's React state (`Get-PageReplyText`: `response.text` / `legacyReplyMessage`); such replies carry `Source = 'page'` and no throttling/metering. The Copy button gives plain text only. `CCBRIDGE_TEST_IGNORE_HUB=1` forces this route for testing.
- Pacing over speed: `harness.json` `pacing` (newChatSettleSec, beforeSendSec, betweenPromptsSec) adds pauses around each send. A request with no reply records (pings and handshakes do not count) within 25 s returns `Lost` from `Send-CopilotPromptUnlocked`, and `Send-CopilotPrompt` resends it once in the same chat. On some tenants the page opens its StreamHub connection only at the first send, which loses that first request.
- Raw frames of the last 30 replies are kept in `%LOCALAPPDATA%\CCBridge\replies` for replay with `Get-ReplyFromFrames`.

## Product rules

- **CCBridge has no language model of its own.** Copilot is the only intelligence; everything CCBridge decides (task kind, which instructions to send, follow-up recaps and re-sends, nudges, when a reply is finished, how an edit is applied) is a fixed, testable rule on text and page state. Never write code that assumes CCBridge understands a request. When Copilot misbehaves, fix it with clearer instructions sent to Copilot or a deterministic rule, and cover the rule with a Pester test.
- Task kind (`Get-TaskKind`, Prompts.psm1): coding words, Microsoft 365 words and project words as before; in a project with code (trait `code` from `Get-ProjectTraits`) a request also counts as coding when it asks for a change, names a part of an app (button, header, page...), reports a problem, asks how/why, or names a project file (`Test-NamesProjectFile`); Microsoft 365 requests stay assistant work. Each turn emits a `kind` event; the app shows how a message was sent and offers "Send again as a coding task" (`/api/chat` `asCoding`, `forceKind = coding`). Tasks from MCP/API are never plain chat (`forceKind = work`). Add misdetected phrases to `tests/Prompts.Tests.ps1`.
- Follow-ups in a work chat (`Get-TurnKind`): a chat-like follow-up inherits the chat's task kind; each follow-up gets the recap in `prompts/reminder.md`; the full instructions are sent again after a turn without actions or after every 5 follow-ups.

- **Human in the loop for Microsoft 365 (non-negotiable)**: CCBridge never confirms a Microsoft 365 action (sending/forwarding mail, creating/changing/cancelling meetings, posting in Teams, sharing or deleting data). The bridge only ever clicks the composer's Send button. Proposed actions (`Get-ProposedActions`) stop the turn with a `human-required` event; risky commands (`Get-CommandRisk`: Microsoft 365 access or deletion) always need a person in the web app and are refused when `$State.Headless` (MCP). Do not add an auto-approve path around this.
- **Work IQ**: the toggle selector lives in `config\selectors.local.json` (from `capture.cmd`); `harness.json` `workIq` = on/off/leave. Saved reply frames may contain Microsoft 365 data: they stay in `%LOCALAPPDATA%` and must never become test fixtures without scrubbing (`"saveReplyFrames": false` turns them off).
- **Deleting and moving stay inside the project (hard boundary, no approval overrides it)**: `Test-DeleteScope` (Executor) refuses a `run` command that deletes or moves files unless every target is a plain path inside the project: no `..`, variables, environment paths, folder changes, encoded commands; deleting code in `-c`/`-e`/`-Command` text and in project scripts the command runs (one level) is checked by its quoted paths. `Resolve-ProjectPath` refuses paths through a junction or symbolic link that leads outside (`Assert-NoOutsideLink`), which also covers write, edit and undo. Keep both covered in `tests/DeleteScope.Tests.ps1`.
- **User source data is read-only**: files in a project's `source/` must never be edited, moved or deleted. Write working copies elsewhere (`work/`, `output/`). The executor refuses writes there and restores `source/` after every command.
- Keep prompts minimal: plain chat is sent as typed; never add example file names or commands that look real (use capitalised placeholders); include AGENTS.md only when it has real content. The read-only Microsoft 365 rule goes with every assistant/mixed request, and the code-level human-in-the-loop guards apply always.
- Text sent to Copilot (prompts/, results, notes, the AGENTS.md template) never mentions the name CCBridge; refer to "the helper program" instead. The UI, logs and docs may use the name.
- Project instruction files are named `AGENTS.md` (sent to Copilot at the start of each chat).
- UI: monochrome white/grey, flat buttons, no blue/green accents; side panel on the left. Kokonut components are adapted in place in `ui-src/src/components/kokonutui`.
- Every task goes through `Submit-AgentTask` (Agent.psm1), so it shows in the Queue (under the Tasks tab) with its source, status, timing and Copilot messages. The web app saves the queue to `%LOCALAPPDATA%\CCBridge\queue.json` on every change (`Save-AgentQueue`; `$State.QueueFile`, unset in the MCP server's own engine) and `Restore-AgentQueue` runs waiting tasks again after a restart; a task that was running is marked failed. Approvals from other programs are recorded as `mcp`/`api`; Microsoft 365 actions and deletions can only be approved by `user` (the app page, checked by its Origin).
- MCP tasks are reviewed by the calling model, not by Copilot (`ReviewByCaller`, unless `copilot_review=true`): no Copilot review round; the local checks still run, and the full report has a CHECK section (every change as a diff from `Get-ChangeSetContents`, local check results, failed or "already applied" actions, repaired replies).
- Every agent turn is one checkpoint (backups under `%LOCALAPPDATA%\CCBridge\projects\...`, never in OneDrive).

## Repository

- Public: https://github.com/jgt87/CCBridge. Commit with the repo-local GitHub noreply email; never with a personal address.
- New test fixtures are recorded Copilot traffic: scrub GUIDs, IDs, names and `locationInfo` before committing.
