# CCBridge - instructions for coding agents

> Product name shown to people: **StreamHub** (UI, messages, README, releases). The code, scripts, data folder (`%LOCALAPPDATA%\CCBridge`), projects folder (`OneDrive\CCBridge`), MCP id (`ccbridge`) and the repository keep the name CCBridge. In visible texts and logs, Microsoft's own reply endpoint (`m365Copilot/StreamHub`) is called the "Copilot stream connection" so the two never get confused.

CCBridge is a zero-install coding harness that uses Microsoft 365 Copilot Chat (in Edge) as its model. It ships two front ends over one engine:
- **Web app**: `ccbridge.ps1` / `start.cmd` serves `ui/` on http://localhost:8765 (projects must be under OneDrive).
- **MCP server**: `mcp/ccbridge-mcp.ps1` (stdio), so MCP clients can offload work to Copilot (any project folder).

Target machines have only what ships with Windows: **Windows PowerShell 5.1 + Edge, nothing installed.** Node is only needed on a dev machine to rebuild the UI.

## Layout

Short index; each module's functions, settings, files and tests are in `docs/architecture.md` (read the row before changing a module).

| Path | Role |
|---|---|
| `lib/Cdp.psm1` | Minimal Chrome DevTools Protocol client (Edge with a debug port, WebSocket, events) |
| `lib/CopilotBridge.psm1` | Types into Copilot Chat, reads the reply (Chathub / StreamHub / page), rebuilds damaged replies, machine-wide send lock `Use-CopilotLock` |
| `lib/Workspace.psm1` | OneDrive projects, path confinement (`Resolve-ProjectPath`), file listing, read-only `Source/` vault, shared library `.streamhub` beside the projects |
| `lib/Protocol.psm1` | Parses `ACTION NAME` blocks from replies; edit markers `####### SEARCH/REPLACE/END` |
| `lib/Fetch.psm1`, `lib/Runbook.psm1`, `lib/RunbookFromChat.psm1` | Runbooks (text and checked JSON), their jobs, saving a request as a runbook |
| `lib/Chain.psm1`, `lib/Schedule.psm1`, `lib/Download.psm1` | Chains of runbook/script/download steps, schedules, Copilot's daily limit |
| `lib/Review.psm1` | Code review batches, verified findings, fresh-chat review |
| `lib/Layout.psm1`, `lib/Relink.psm1` | Project folder layout, moving older layouts, rewriting references after moves |
| `lib/Imports.psm1`, `lib/RepoMap.psm1`, `lib/ChatScope.psm1` | Import index, code map for the context, new chat when the work moves elsewhere |
| `lib/Update.psm1` | Release updates, install integrity check, rollback |
| `lib/RunWindow.psm1` | Own environment variables kept from project code, commands in a visible window, live output |
| `lib/Packages.psm1` | npm packages missing, install on request |
| `lib/Sso.psm1`, `lib/EdgeCache.psm1`, `lib/AppWindow.psm1` | Edge profile sign-in, cache clearing, where the app opens |
| `lib/Guardrails.psm1`, `lib/CheckPolicy.psm1`, `lib/AutoFix.psm1` | Checks on what a change adds, finding levels and disputes, mechanical fixes and rollback |
| `lib/Lint.psm1`, `lib/Health.psm1`, `lib/Issues.psm1`, `lib/FixCases.psm1` | File checks per type, code health, issue index and fix cycle |
| `lib/WebFetch.psm1` | `ACTION web`: public pages only, approvals per site, saving web data |
| `lib/Retention.psm1` | Settings > Retention for history, evidence, reviews, screenshots, reports |
| `lib/FileActions.psm1` | `move`, `delete`, `refs`, `changes`, `test` actions |
| `lib/DataMirror.psm1`, `lib/DataImport.psm1`, `lib/DataProfile.psm1`, `lib/DataQuery.psm1` | Data copies, converted data for Copilot, profile report, `ACTION sql` |
| `lib/SqlServer.psm1` | Read-only SQL Server queries with the person's sign-in |
| `lib/TestRunner.psm1`, `lib/Hooks.psm1`, `lib/ToolChecks.psm1` | The project's own tests, hooks, build and check tools |
| `lib/TaskNotes.psm1`, `lib/Handoff.psm1`, `lib/Progress.psm1`, `lib/LoopGuard.psm1`, `lib/PlanFile.psm1` | Done when checks, chat rollover, progress across chats, loop detection, PLAN.md |
| `lib/Office.psm1`, `lib/SecretFiles.psm1` | Office files without Office, secret files masked and refused |
| `lib/UiKit.psm1`, `lib/Contrast.psm1`, `lib/KitTheme.psm1` | The UI kit (`templates/ui-kit/`), contrast checks, theme from colours |
| `lib/ProjectSetup.psm1`, `lib/OneFile.psm1`, `lib/FileIntake.psm1` | Setup questions, one-file pages and generated pages, files put in a new project |
| `lib/WebBuild.psm1`, `lib/GuiTest.psm1` | Built-in React/TypeScript builder in Edge, PowerShell window app tests |
| `lib/SharePointPage.psm1`, `lib/SharePointLink.psm1` | SharePoint HTML pages and publishing |
| `lib/PageExport.psm1`, `lib/PageReport.psm1`, `lib/PageCompare.psm1`, `lib/ShotDiff.psm1` | PDF/PowerPoint export, full page check, compare with an earlier version, screenshot diffs |
| `lib/Pptx*.psm1` | PowerPoint templates and decks from outlines |
| `lib/ProjectOverview.psm1`, `lib/ProjectPackage.psm1`, `lib/TidyUp.psm1` | Overview for a colleague, zip for sharing, tidy-up list |
| `lib/SessionReport.psm1`, `lib/TestRuns.psm1` | Session report from the log, saved test runs |
| `lib/Prereq.psm1`, `lib/ToolInstall.psm1` | System check, optional tools on request |
| `lib/Executor.psm1` | Carries out actions, checkpoints and undo, edit matching, read results |
| `lib/Agent.psm1`, `lib/WorkStatus.psm1` | Agent loop and worker runspace (`$State`), round check, done gates, waiting status |
| `lib/Server.psm1` | HTTP server and JSON API, origins and the preview sandbox |
| `lib/Prompts.psm1`, `lib/TaskGuidance.psm1`, `prompts/` | Task kind and prompt parts assembled per request; `Format-TaskMessage` |
| `lib/Config.psm1`, `lib/Log.psm1` | Settings (`config/*.json` + `.local.json`, `$script:SettingDefs`), logging (`Write-CCBLog`) |
| `mcp/ccbridge-mcp.ps1` | MCP stdio server; hands tasks to the running web app |
| `config/` | `harness.json` (ports, budgets), `selectors.json` (Copilot page selectors) |
| `ui-src/` | React + Vite + Tailwind source, builds into `ui/` (committed); controls drawn with the UI kit |
| `tests/` | Pester 3.4 tests; `tests/fixtures` = recorded Copilot traffic |
| `test-tools/` | Test and capture launchers run on a machine; scripts in `tools/` |

## Commands

```powershell
# Tests - always with Windows PowerShell 5.1, not pwsh 7 (5.1 is the target and parses differently)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester .\tests"
# The whole suite in parallel processes, as the release gate runs it (about 2 minutes; -Workers 1 = one process).
# A test file that uses something machine-wide (a window, the Copilot lock, the real last-project.txt)
# goes into $script:Alone in tools\run-tests.ps1, so it runs on its own after the parallel part.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-tests.ps1
# Third-party parts StreamHub ships with a newer release on npm (read from their own files: kit vendor
# READMEs, templates/build/VERSIONS.txt, the Lucide JSON, ui-src/package-lock.json). The release gate
# runs it as information, and .github/workflows/dependency-check.yml weekly, keeping one issue current.
# A major version the repo does not take on purpose goes into its $held list with the reason (TypeScript 7:
# no browser build for the built-in builder); it shows as held, and the next major version as major again.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-deps.ps1
# Parse-check a script under 5.1
powershell -NoProfile -Command "$e=$null; $null=[Management.Automation.Language.Parser]::ParseFile('<file>',[ref]$null,[ref]$e); $e"
# Rebuild the UI after any change in ui-src (writes ui/); UI unit tests (vitest, dev only: src/**/*.test.ts)
cd ui-src; npm run build; npm test
# Build a release zip (dist\) and publish it as a GitHub Release
# (it also creates and pushes the annotated tag of the same name on HEAD and publishes the GitHub
# Release "StreamHub vX.Y.Z" with the zip; needs a clean, pushed tree and refuses an existing tag or
# release. Every version bump gets its tag and release; -NoPublish builds the zip only.)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-release.ps1 -Version v0.1.0 -NotesFile NOTES.md
# Run the web app / one prompt / the MCP server
.\start.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File ccbridge.ps1 -Ping "say hi" -NewChat
powershell -NoProfile -ExecutionPolicy Bypass -File mcp\ccbridge-mcp.ps1
```

The running web server holds `lib/*.psm1` in memory: restart it after backend changes (the UI files are read fresh from disk).

Project routing: `Submit-AgentTask` captures the project in every project task's payload; `Start-AgentWorker` applies it before preferences, vault sync and execution (including MCP undo), then restores the selected project after cleanup. `ProjectGate` excludes `Set-Project` for the whole task and idle project maintenance, including gaps when Busy is false. Tests: `tests/ProjectRouting.Tests.ps1`. Linked paths: `Resolve-ProjectLinkPath` follows complete junction/symlink chains with confinement and cycle checks; `Assert-Writable` applies protections to the resolved destination too. Project listings skip links, as vault traversal does. Tests: `tests/LinkedPaths.Tests.ps1`.

## PowerShell 5.1 rules (each of these has bitten this repo)

- Keep `.ps1`/`.psm1` **ASCII-only**; BOM-less files are read as ANSI. Write non-ASCII as `\u` escapes in JS strings or `[char]0x..`.
- An `if` without `else` assigned to a variable yields AutomationNull, which `ConvertTo-Json` writes as `{}`. Assign `$null` explicitly first.
- `return , $array` plus a caller's `@()` nests the array. Return arrays plainly and wrap at the call site.
- `$hashtable + @{...}` throws on duplicate keys; use `Join-Hash` (Agent.psm1).
- The comma binds tighter than `+`: `@($x, $i + 1)` is `($x, $i) + 1`. Write `@($x, ($i + 1))`.
- A `[pscustomobject]` has no `.Count` in 5.1: wrap single results in `@()` before counting.
- `@($list)` around a `List[object]` that holds hashtables throws "Argument types do not match" (the array binder): return `$list.ToArray()`.
- `Invoke-RestMethod` emits a JSON array as one object; wrap the call in parentheses before piping.
- 2-D array indexes with commas inside method arguments do not parse; use flat arrays.
- Native-command stderr with `$ErrorActionPreference = 'Stop'` becomes a terminating error; silence via `cmd /c "... >nul 2>&1"`.
- Don't name functions like built-in cmdlets (`Wait-Job`, `New-Job`).
- `[IO.Path]::IsPathRooted` (and other `[IO.Path]` methods) throw "Illegal characters in path" on `"`, `<`, `>`, `|` in 5.1: use Workspace `Test-RootedPath`, `Get-PathLeaf` (the file name) and `Test-PathChars` on text that may not be a path (quoted strings from scripts, pasted paths, a script src a template writes, a path Copilot names); `Resolve-ProjectPath` refuses such characters in plain words.
- In strings, `"$name: ..."` parses as a scope-qualified variable; write `"${name}: ..."`.
- Log with `Write-CCBLog info|verbose|trace <component> <message> [data]` (lib/Log.psm1). Each process starts every log file it writes to with `Get-LogHeader` (version and commit from `Initialize-CCBLog -Build (Format-CCBBuild (Get-CCBridgeBuild $root)) -Role`, kept in `$env:CCBRIDGE_LOG_BUILD`/`_ROLE`/`_HEADER` so worker runspaces share it; without -Build, version.txt/commit.txt or dev). Never put prompt/reply text or file contents below `trace`.
- Tests that create a temporary project set `$env:CCBRIDGE_STATE_ROOT` to a temporary folder at the top and delete it at the end (see `tests/Undo.Tests.ps1`): `Get-ProjectStateDir` then keeps their backups and chat history out of `%LOCALAPPDATA%\CCBridge\projects`. The log does this by itself: with Pester loaded, `Log.psm1` (`Get-DefaultLogDir`) writes to `%TEMP%\CCBridge-test-logs` (`$env:CCBRIDGE_LOG_DIR`, inherited by worker runspaces and child processes), so tests never add lines to the person's real log, which the session report and Export diagnostics read. Read the log folder through `Get-CCBLogDir`, never a path of its own.
- Coding agents editing this repo: never put a regex or Windows path in a Bash heredoc, in `python -c`, or in a Python string that is not raw. The shell or Python turns `\b` into a backspace byte (0x08), and a doubled quote inside `r"..."` ends the raw string early, so the rest is read as a normal string. Write patch scripts to a file with the editor tool, use `r"""..."""` for patterns, refuse to write text that holds `chr(8)`, and check afterwards with `grep -rlP '\x08' lib tests tools templates AGENTS.md`.
- In the MCP server, stdout is the protocol channel: never let pipeline output or `Write-Host` reach it; log to stderr.

## Copilot Chat quirks the code depends on

- The message box is a **Lexical** editor (`#m365-chat-editor-target-element`): it is re-mounted about 3 times after load (wait until the same element is stable), ignores `execCommand` (clear with Ctrl+A/Backspace key events), and turns `\r` into extra characters (send `\n` only).
- Replies arrive on `substrate.office.com/m365Copilot/Chathub` (SignalR, records separated by `0x1e`); a `type:2` record ends the reply and carries throttling (messages per chat) and metering (daily credits, `OutOfCredits`).
- Copilot's **link/citation filter damages code** in snapshots and the final text (`[name]:`, `[guid]::`, `[x](...)` vanish). The reply is rebuilt from raw `writeAtCursor` chunks (`Add-ReplySnapshot`). Never use the server's final text for code.
- Copilot's page escapes a bracket that looks like a Markdown link definition, so `[regex]::Match` can arrive as `[regex\]::Match`: `Repair-EscapedTypeName` (Executor) puts a .NET type name directly before `::` back, in `.ps1/.psm1/.psd1` files (`Repair-CodeText`) and run commands (`Repair-RunCommand`, also `&lt;`/`&gt;`). `Test-LongPowerShellCommand` refuses `powershell -Command` scripts over 300 characters (write a script and run it with `-File`: one-off scripts in `Work/`, scripts to keep in `Scripts/`; `prompts/rules/folders.md`, `prompts/actions-run.md`). Tests: `tests/RunCommandRepair.Tests.ps1`.
- The page escapes `<` and `>` in prompts to `&lt;`/`&gt;`, so Copilot may copy entities into SEARCH text or code; Executor repairs this except in markup files, where only a page part written as entities throughout (tags like `&lt;div&gt;` and not one real `<` or `>`; not Markdown) is turned back into tags (`Repair-CodeText`, tests in `tests/DamagedHtml.Tests.ps1`), since the browser would show it as text.
- Some tenants deliver the reply over **StreamHub** (`substrate.svc.cloud.microsoft/m365Copilot/StreamHub`): SignalR type-2 stream items. `Add-StreamRecord` finds chunks (`writeAtCursor`), snapshots (`messages`) and the end (`result`, a final flag such as `isLastUpdate` or a final state, or a type-3 completion) by field name; `Complete-StreamReply` returns at that end, taking the text from the stream or, if none is recognised, straight from the page state. Sockets are classified per request id in `$Bridge.HubSockets` (`chat` / `stream`) by URL or traffic shape (`Get-SocketKind`).
- Some tenants do not deliver the reply over Chathub. `Send-CopilotPromptUnlocked` also watches the page (`Get-PageReplyState`: Stop gone, new reply with a Copy button) and then reads the raw markdown from the page's React state (`Get-PageReplyText`: `response.text` / `legacyReplyMessage`); such replies carry `Source = 'page'` and no throttling/metering. The Copy button gives plain text only. `CCBRIDGE_TEST_IGNORE_HUB=1` forces this route for testing.
- Pacing over speed: `harness.json` `pacing` (newChatSettleSec, beforeSendSec, betweenPromptsSec) adds pauses around each send. A request with no reply records (pings and handshakes do not count) within 25 s returns `Lost` from `Send-CopilotPromptUnlocked`, and `Send-CopilotPrompt` resends it once in the same chat; never while the page shows Copilot at work (`$pageBusyAt`, Stop or agentBusy within 5 s, and one more page look before deciding), since that would send the prompt twice (`tests/BusyCopilot.Tests.ps1`). On some tenants the page opens its StreamHub connection only at the first send, which loses that first request.
- Damaged tags in received replies: some tenants deliver `<script src="PATH.js"></script>` as `PATH.jsscript>` while the page shows it intact. `Update-LateReply` (CopilotBridge) swaps in the page's fresh state copy when `Test-DamagedTagText` finds damage in the received text but not in the page copy (same start, similar length; `TagRepaired` on the reply); Executor `Repair-StrippedScriptTag` (via `Repair-CodeText`, page files only, never SEARCH text) puts back what is left, and also rebuilds a `<link rel="stylesheet">` or `<script src>` tag from a stylesheet or script path left alone on a line (`$script:BareAssetLine`: another route strips the whole tag to its address; `Test-DamagedTagText` counts such a line as damage, Lint `Find-LeakedMarkup` reports it in a page as kind `bare-path` and AutoFix writes the tag); an edit whose REPLACE equals its SEARCH (the tags lost the same way) is an error that says so, never "already applied"; `Find-DamagedHtmlLine` refuses anything else (also a link stripped down to its address glued to its text with a closing tag and no opener, `#mainSkip to content</a>`). Copilot's own output can be damaged too (seen on its page): `Get-EditMarker` (Protocol) takes a damaged start marker (`SEARCH`/`EARCH` alone; a block with no start marker and one `=======` is one pair, `Get-EditPairs`) and a damaged end marker (`</EPLACE`, `REPLACE` alone, `>>>`; upper case only) as REPLACE, and `Repair-StrippedScriptTag` closes a lone `<script src="...">` line. Tests: `tests/DamagedHtml.Tests.ps1`.
- Never press Stop on a busy Copilot: `Send-CopilotPromptUnlocked -MaxTimeoutSec` (Agent passes `agentTimeoutSec`) keeps waiting at `TimeoutSec` while `Get-PageReplyState` shows `stop` or `agentBusy`, a minute at a time up to the cap (OnStatus line "Copilot is still working"); the stall check (`StallSec`) still ends a silent reply. Pressing Stop cancels Copilot's work, including its background tasks for long Microsoft 365 requests. Tests: `tests/BusyCopilot.Tests.ps1`.
- Raw frames of the last 30 replies are kept in `%LOCALAPPDATA%\CCBridge\replies` for replay with `Get-ReplyFromFrames`.

## Product rules

The rules below hold for every change; their mechanisms, the rest of the product rules and their tests are in `docs/architecture.md` (Product rules).

- **CCBridge has no language model of its own.** Copilot is the only intelligence; everything CCBridge decides is a fixed, testable rule on text and page state, covered by a Pester test. Never write code that assumes CCBridge understands a request.
- **The person's request comes first**, over earlier choices of Copilot or StreamHub.
- **Human in the loop for Microsoft 365 (non-negotiable)**: CCBridge never confirms a Microsoft 365 action; risky commands always need a person in the web app and are refused headless. Do not add an auto-approve path around this.
- **Deleting and moving stay inside the project** (hard boundary, no approval overrides it): `Test-DeleteScope`, `Resolve-ProjectPath` (`tests/DeleteScope.Tests.ps1`).
- **User source data is read-only**: files in a project's `Source/` are never edited, moved or deleted; links are never followed.
- Keep prompts minimal; text sent to Copilot never mentions the name CCBridge ("the helper program").
- Project instruction files are named `AGENTS.md` (sent to Copilot at the start of each chat).
- UI: monochrome white/grey, flat buttons, no blue/green accents; side panel on the left.
- Every task goes through `Submit-AgentTask`; every agent turn is one checkpoint (backups in `%LOCALAPPDATA%`, never OneDrive).

## Repository

- Public: https://github.com/jgt87/CCBridge. Commit with the repo-local GitHub noreply email; never with a personal address.
- New test fixtures are recorded Copilot traffic: scrub GUIDs, IDs, names and `locationInfo` before committing.
- No links to other GitHub repositories anywhere in the repo or the built `ui/` (only `jgt87/CCBridge`): `tests/Repository.Tests.ps1` checks it. The UI build turns such links in bundled libraries into plain words (`ui-src/vite.config.ts`); third-party components keep their author, licence and website lines. `ui-src/package-lock.json` (written by npm, not shipped) is the exception.

<!-- REPOWISE_DISTILL:START — Do not edit below this line. Auto-generated by Repowise. -->
### Output Distillation

- Prefer `repowise distill <cmd>` for noisy commands: test runs, builds, `git status`/`log`/`diff`, searches, file listings. It runs the command unchanged (exit code preserved) and prints a compact, errors-first rendering; every error line survives.
- Output may contain a marker like `[repowise#a1b2c3d4e5f6: 230 lines omitted (~6.1k tokens); restore: repowise expand a1b2c3d4e5f6]`. The omitted content is fully preserved: run `repowise expand <ref>` to retrieve it, or `repowise expand <ref> -q <regex>` for just the matching lines.
- Never re-run a command to see omitted output; expand the marker instead.
- For structure-level questions about a large indexed file ("what's in here", "which function handles X"), `get_context(["path"], include=["skeleton"])` returns the file with bodies elided (every signature plus the bodies of the most central symbols) at a fraction of the cost of a full Read.
<!-- REPOWISE_DISTILL:END -->

<!-- commonshared:begin (managed by __CommonShared/sync; edit it there, not here) -->
## Shared practices
This project follows the generic best practices in `C:/Files/Apps/__CommonShared`. This file
and the project's own DESIGN.md / PRODUCT.md win where they are more specific.
- Conventions: its `docs/` (visual design 01, interaction 02, testing 04, structure and
  release 05, code organisation 08, change management 09, gitignore 11, line endings 12,
  agent workflow 14, lessons learned 15, UI fixes 17).
- Rules: `.claude/rules/commonshared-*.md` are managed copies of its `rules/` (loaded by
  file type; refreshed at session start and by its sync). Do not edit them: put this
  project's own rules in `.claude/rules/project-<area>.md`, which win on conflict.
- Starters: its `templates/` (tokens, gitignore, gitattributes, editorconfig, check scripts,
  design-rule tests). Copy in; do not link.
- Audit: `python -I C:/Files/Apps/__CommonShared/.claude/skills/new-project/scripts/check_project.py .`
- A lesson learned here that would hold in any project goes in `tasks/lessons.md` (rule,
  Why with date, check). It is pulled upstream into the shared lessons, which load at every
  session start through the shared-lessons hook.
<!-- commonshared:end -->
