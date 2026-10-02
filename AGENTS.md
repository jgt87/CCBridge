# CCBridge - instructions for coding agents

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
| `lib/Executor.psm1` | Carries out actions, checkpoints/undo, `&lt;`/`&gt;` repair |
| `lib/Agent.psm1` | Agent loop + worker runspace; talks to front ends via a synchronized `$State` |
| `lib/Server.psm1` | HTTP server + JSON API for the web UI (token in `%LOCALAPPDATA%\CCBridge\session-token.txt`) |
| `mcp/ccbridge-mcp.ps1` | MCP stdio server reusing `Agent.psm1` with `$State.Headless` |
| `prompts/` | Small parts assembled per request by `lib/Prompts.psm1` (`New-PromptMessage`): `Get-TaskKind` picks chat / assistant / project / coding / mixed; chat sends the text alone; other kinds add only the parts the chat has not had (`roles/*.md`, `actions.md`, `rules.md`, `m365.md`, `save.md`, plus the project context from `Get-ProjectContext` with the OneDrive location) |
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

- **Human in the loop for Microsoft 365 (non-negotiable)**: CCBridge never confirms a Microsoft 365 action (sending/forwarding mail, creating/changing/cancelling meetings, posting in Teams, sharing or deleting data). The bridge only ever clicks the composer's Send button. Proposed actions (`Get-ProposedActions`) stop the turn with a `human-required` event; risky commands (`Get-CommandRisk`: Microsoft 365 access or deletion) always need a person in the web app and are refused when `$State.Headless` (MCP). Do not add an auto-approve path around this.
- **Work IQ**: the toggle selector lives in `config\selectors.local.json` (from `capture.cmd`); `harness.json` `workIq` = on/off/leave. Saved reply frames may contain Microsoft 365 data: they stay in `%LOCALAPPDATA%` and must never become test fixtures without scrubbing (`"saveReplyFrames": false` turns them off).
- **User source data is read-only**: files in a project's `source/` must never be edited, moved or deleted. Write working copies elsewhere (`work/`, `output/`). The executor refuses writes there and restores `source/` after every command.
- Keep prompts minimal: plain chat is sent as typed; never add example file names or commands that look real (use capitalised placeholders); include AGENTS.md only when it has real content. The read-only Microsoft 365 rule goes with every assistant/mixed request, and the code-level human-in-the-loop guards apply always.
- Text sent to Copilot (prompts/, results, notes, the AGENTS.md template) never mentions the name CCBridge; refer to "the helper program" instead. The UI, logs and docs may use the name.
- Project instruction files are named `AGENTS.md` (sent to Copilot at the start of each chat).
- UI: monochrome white/grey, flat buttons, no blue/green accents; side panel on the left. Kokonut components are adapted in place in `ui-src/src/components/kokonutui`.
- Every agent turn is one checkpoint (backups under `%LOCALAPPDATA%\CCBridge\projects\...`, never in OneDrive).

## Repository

- Public: https://github.com/jgt87/CCBridge. Commit with the repo-local GitHub noreply email; never with a personal address.
- New test fixtures are recorded Copilot traffic: scrub GUIDs, IDs, names and `locationInfo` before committing.
