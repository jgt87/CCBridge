# Changelog

All notable changes to StreamHub are listed here, newest first.

## [Unreleased]

Nothing yet.

## [v0.1.51] - 2026-10-04

### Added

- `agent-test.cmd`: tests Copilot's Researcher and Analyst agents the way StreamHub will invoke them (mentioned in the message box): a new chat, the mention picked from the @ list, a fixed harmless prompt (Analyst gets a made-up CSV), one automatic answer when the agent first asks questions or shows a plan, and a stop once the run has finished. Each run writes a zip with a step log, timings and the reply structure, without reply text.
- `agent-capture.cmd`: records a run you do by hand the same way.
- Settings > Sign-in: single sign-on with your Windows work account in StreamHub's Edge profile, so Copilot signs in by itself after a restart. It shows the status (work account on this PC, the profile switch, the Copilot tab), turns Edge's "single sign-on for work or school sites" switch on or off in StreamHub's own profile only, and has "Run setup" (with a log) and "Open Edge's profile settings". No password is stored, and Edge policies are never changed. `sso-setup.cmd` does the same from a command window.
- The system check at start shows whether this PC can use single sign-on.
- README: "How a prompt is typed and sent", "Staying signed in" and "Tech stack".

## [v0.1.50] - 2026-10-04

### Added

- Project folder layout: `src/` for new code, `Scripts/` for helper scripts, `Runbooks/` for everything that gets data from Microsoft 365 or Work IQ (runbooks and fetch prompts), `Runbooks/Exports/` for their data, `History/` for earlier versions, `Logs/` for the project's own logs, and `.streamhub/` for StreamHub's own records. Copilot gets the same rules, and web projects also get the usual web folders (`public/`, `src/components/`, `src/pages/`, `src/styles/`, `src/assets/`).
- Older projects are moved to the new layout once, when they open. Nothing is overwritten.
- Fetch answers keep their earlier versions in `History/`.
- Import index: which file imports or uses which (ids, inline handlers, custom hooks), with line numbers kept current after every round. Copilot sees "Used by" when it reads a file. Imports of moved or deleted files, and removed ids, functions or hooks that others still use, are reported with the line to fix.
- Pages opened from disk: local `fetch()`, JSON imports and module scripts, which the browser blocks there, are reported with the replacement (a `.js` data file and the `<script>` tag to add).
- Files tab: new files get a "new" tag, a bar shows while the tree refreshes, and the tree refreshes after each step and when the window gets focus.

### Changed

- Line counts and "new" tags in the Files tab cover the changes in the restored chat after a restart.
- Copilot may not write in `.streamhub/`.
- Settings has an "Update automatically" switch (Updates). It says plainly that a new release installs only when a new instance of the app starts.
- The commit id next to the version (bottom left) links to the changelog on GitHub as of that commit.
- The "waiting for the reply" indicator no longer names the product and mixes in light-hearted lines ("Consulting the rubber duck...", "Herding semicolons..."), in a new order for each message.

### Fixed

- Undoing a step that created files also removes the folders it left empty.
- Tests no longer leave state folders behind in `%LOCALAPPDATA%`.

## [v0.1.49] - 2026-10-04

### Added

- Undo now shows an undo card in the chat with a diff per file: the lines that come back and the lines that go.

### Changed

- Commands that StreamHub runs are now backed up too: files are copied aside before a command, and whatever it changed, deleted or created becomes part of the step's change set.
- The Changes list drops a change set once it has been undone.

### Fixed

- Undo after a step that only ran commands restored an earlier step instead, because such a step had no change set.

## [v0.1.48] - 2026-10-03

### Changed

- Files tab: folders you close stay closed across tab switches, reloads and projects (remembered in the browser per project).
- The diff view was split into smaller parts and covered by snapshot tests (no visible change).

## [v0.1.47] - 2026-10-03

### Added

- Chat history per project: the chat is kept locally (never in OneDrive), up to 1500 events, and restored when the project opens. Open approvals come back marked as interrupted, with a note that Copilot starts a fresh chat.
- The chat shows the newest 30 items and loads 30 more as you scroll up.
- Settings: theme (System / Light / Dark, per browser), mode at start, commands that run without asking (entered as command starts), privacy options (keep chat history, keep raw replies, Clear chat history) and the ports (shown only).

### Fixed

- A switch setting saved as "off" was read back as on.

## [v0.1.46] - 2026-10-03

### Added

- The system check shows official download links for missing parts (Edge, .NET Framework 4.8, OneDrive, WMF 5.1).
- The system check repairs what it safely can: a busy port moves to a free one (saved in `harness.local.json`; a `-Port` given at start is kept) and OneDrive is opened when it is installed but not signed in. It runs at start, after install and in `check.cmd` (`-NoFix` only reports). Policies and anything needing admin rights are never changed.
- Notes in the app that schedules and queued tasks run only while StreamHub is open.

### Changed

- The side panel follows the open project: the queue and schedules are filtered to it, and Issues and Code review reload per project.
- A busy port counts as StreamHub's own only when it answers with StreamHub's page, so detecting an already running copy no longer depends on the page title.

## [v0.1.45] - 2026-10-03

### Changed

- Internal cleanup of the message box and the API client, with new UI unit tests (no visible change).

## [v0.1.44] - 2026-10-03

### Added

- Edit button on each schedule: the form opens with its settings, and the schedule keeps its id, project and history.

### Changed

- Schedules are stored in each project (`<project>\.streamhub\schedules.json`), saved on every change and picked up at start, on project open and once a minute (so changes made by hand or synced by OneDrive are seen). A project at another path runs its schedules there. The old app-wide schedules file is moved into the projects once.
- Split screen hint: the pointer now sits under Edge's menu.

### Fixed

- On a narrow window, opening the sidebar no longer dims the chat.

## [v0.1.43] - 2026-10-03

### Added

- A one-time hint in Edge that explains how to use Split screen when the app opens as a tab in the Copilot window.
- Connect animation: the Copilot status spinner closes into a circle with a check mark once connected.

## [v0.1.42] - 2026-10-03

### Added

- Issues (beta): every project file is indexed for errors, secrets and code health. After a change, the changed files are scanned again and a fix task is queued per file for new issues, up to a set number of attempts.
- File checks per file type, encoding guardrails and code health checks without scores.
- File viewer: Markdown rendered like on GitHub (Mermaid, math, callouts, safe HTML) and code with syntax colors and line numbers. Action cards use the same views (colored diffs, rendered Markdown, read and edit results).
- Indexing progress on the Files tab and in the chat.
- Settings > Reset all to defaults.

### Changed

- The side panel is organized in sections and always visible on wide windows; the chat uses 80% of wide screens.
- `build-release.ps1` now tags and publishes every version.

### Fixed

- `build-release.ps1`: one-line git results were misread, and git/gh messages on stderr stopped the script.

## [v0.1.41] - 2026-10-03

### Added

- System check at start, after install and with `check.cmd`: PowerShell 5.1 and its language mode, execution policy, .NET Framework, Edge and its policies, the local web server, ports, OneDrive, the data folder, and optionally GitHub and Copilot reachability. Each line shows OK / WARN / FAIL with a hint; a FAIL stops the start (`-NoCheck` skips the check).
- README: "How it works" section with six diagrams, plus an updated data-locations table and module list.

## [v0.1.40] - 2026-10-03

### Added

- `PLAN.md` in the project root records every step of a Clarify first request: the request, Copilot's questions, the answers, each plan version, requested changes, the approval and the result. The question and plan cards link to it.

## [v0.1.39] - 2026-10-03

### Added

- Clarify first: Copilot asks at most 5 questions, shown as a form; the answers start a plan that you approve in the app before anything is built.
- Verification: a `verify: COMMAND` line in `AGENTS.md` runs after a task that changed files; failures go back to Copilot (at most twice).
- Evidence files: each task that changed files can write `evidence/task-<stamp>.md` (setting `evidence`).
- Desktop notifications while the app's browser tab is hidden.
- New actions for Copilot: `find NAME` to locate a definition and `remember FACT` to add a note to the "Learned" section of `AGENTS.md` (always needs approval).
- Copilot response mode (Auto / Quick / Think deeper) from the app and over MCP (`think_deeper`).
- Setting `appWindow`: open the app as a tab in the Copilot window (default), side by side, or in the default browser.

### Changed

- The version line in the side panel is centered.

### Fixed

- A project with one file was described to Copilot as empty.
- The app's own tab is never taken for the Copilot tab.

## [v0.1.38] - 2026-10-03

### Added

- A write or edit that leaves a placeholder for left-out code is refused.
- A write that shrinks an existing file below 40% needs approval, even in auto mode.
- Each edit reports the changed lines as they now are in the file.
- Files changed in a round get a syntax check (JSON, PowerShell, JavaScript); "done" is refused while one is broken (at most twice).

### Changed

- Ranged reads that cut through a block are widened to the whole block; the half-block refusal shows the block's current lines.
- An unclosed last write, edit or run block (a reply that may be cut off) is not applied; Copilot is asked to send it again.
- Only risky commands need a person's approval; warnings no longer do.

## [v0.1.37] - 2026-10-03

### Changed

- The Queue button sits next to Stop/Send on the right.
- Adding source data is a collapsed row that opens the upload area (remembered); dragging a file over the Files tab opens it.
- When the same step fails the same way, StreamHub warns the second time and stops the message the third time, instead of asking Copilot to resend.

### Fixed

- The half-block guard raised false alarms: braces now count only in brace languages (and in HTML only inside script and style), strings and comments are ignored, and the refusal names the line where the braces stop matching.

## [v0.1.36] - 2026-10-03

### Added

- Run a runbook by naming it in the chat (by name, title or `@runbooks/...` path), or by asking to run "the runbook". Requests to create or change a runbook, and questions about one, stay normal messages.

## [v0.1.35] - 2026-10-02

### Fixed

- Schedule form: a typed time now counts without pressing "+ Time", and the form lists what is still missing next to the Schedule button.

## [v0.1.34] - 2026-10-02

### Added

- Code review in Copilot for the whole project, changes since opening, or chosen files: read-only, with line numbers; every finding must quote lines that exist in the file, or it is marked unverified. Reports are saved in `reviews/`, progress survives the daily limit and restarts, and "Fix selected" queues fix tasks. Available in the Changes tab and as the MCP tool `copilot_review`.
- The chat shows how a message was sent, with "Send again as a coding task".
- The schedule form has an @ picker for runbooks and Markdown instructions.

### Changed

- Better coding detection in projects with code: change requests, app parts, problem reports, how/why questions and project file names count as coding. Tasks from MCP or the API are never plain chat.
- Runbooks that Copilot writes must be `runbooks/NAME.runbook.md` with the template header; requests about runbooks include the rules and the blank template.
- Scheduled opens as a modal, with a summary in the Tasks tab.
- All modals share the same dimmed, blurred backdrop; the Settings header stays in place while the list scrolls.

## [v0.1.33] - 2026-10-02

### Added

- Schedules for a message, fetch prompt or runbook: once at a date and time, or on chosen days at one or more times. Due schedules go into the queue; a run missed while StreamHub was closed runs once at the next start. Calendar button in the message box, Schedule on runbooks and fetch prompts, and a Scheduled list with run now, pause and delete.
- Copilot's daily limit pauses the queue until it resets, with a Resume now banner; a task that did nothing yet goes back to the front. The pause survives restarts.
- Error category SCHEDULE for incomplete schedules.

### Changed

- Run buttons for fetches and runbooks add to the queue while Copilot is busy.
- An empty message box shortly after a limit counts as the limit.

## [v0.1.32] - 2026-10-02

### Added

- The queue survives restarts: waiting tasks run again and a task that was running is marked failed.
- Hard boundary for deleting and moving: commands that delete or move files are refused unless every target is a plain path inside the project. No approval overrides this.
- Paths through junctions or symbolic links that lead outside the project are refused for reads, writes and undo.

### Changed

- Copilot's instructions say to delete only inside the project.

## [v0.1.31] - 2026-10-02

### Added

- Python outlines; Python tab/space mixing and `.psd1` data files in the local checks.
- Changed `.js` files get a compile-only syntax check in Edge.

### Changed

- Edits matched while ignoring indentation are re-indented to the file's style; uneven shifts are refused in Python.
- Local imports are resolved like a bundler (extensions, index files, `.js` to `.ts`); packages and path aliases are skipped.
- Coding instructions are a small core plus modules sent only when relevant (commands, web apps, moving code, Python, PowerShell 5.1, read-only source data).

## [v0.1.30] - 2026-10-02

### Added

- Task queue: every task (messages, fetches, runbooks, new chat, undo, MCP) shows in a Queue under the Tasks tab with source, status, timing, Copilot messages used and result. Messages sent while Copilot is busy are queued; queued tasks can be removed and running ones stopped.
- The MCP server hands its tasks to the running app, and works on its own when the app is not running.
- MCP task reports have a CHECK section with every change as a diff, local check results, failed or already applied actions and repaired replies.

### Changed

- MCP tasks are reviewed by the calling program instead of by Copilot (`copilot_review=true` keeps Copilot's review).
- Approvals from other programs are recorded as mcp/api; Microsoft 365 actions and deletions need a person in the app.
- Diffs list removed lines before added ones.

### Fixed

- A prompt refused at Copilot's daily limit now reports the limit.

## [v0.1.29] - 2026-10-02

### Added

- Runbooks: repeatable, read-only Microsoft 365 exports to JSON, with templates for meetings, email follow-ups, Teams actions, recent documents, a topic digest and a blank explained template. Placeholders such as `{{today}}`, validation of the JSON shape, one correction round, history in `exports/history`, and a failed run keeps the previous output.
- Runbooks section in the Fetch tab: create from a template, run, view the result, attach.

### Fixed

- The Runbooks section stayed empty when there was exactly one runbook.

## [v0.1.28] - 2026-10-02

### Changed

- The updater, installer, launchers and MCP notes use the StreamHub name; the installer's shortcut is now `StreamHub.lnk` (an old `CCBridge.lnk` is replaced).
- `update.cmd` points to `start.cmd`, which replaces a running copy.

## [v0.1.27] - 2026-10-02

### Changed

- The product is now called StreamHub in the interface, messages and README. Scripts, data folders, the MCP id and the repository keep the name CCBridge, so existing installs keep working.
- Microsoft's reply endpoint is called the "Copilot stream connection" in visible texts and logs.

## [v0.1.26] - 2026-10-02

### Added

- File outlines for large files: structure with line numbers for HTML, JavaScript/TypeScript, CSS, PowerShell and Markdown, sent after a file is cut and available with `read PATH:outline`.
- Page check: after a task changed web files, the page opens in a spare Edge tab and JavaScript errors, console errors and missing files go to Copilot (setting `pageCheck`).
- Copilot page health check after each connect, naming the selector to fix when something is missing.
- Settings panel (gear next to Menu): settings in groups with explanation, default, validation and reset, applied at once.
- `stream-shape.cmd` records the structure of recent Copilot replies (no content) so a tenant's reply format can be supported.

### Changed

- Replies without Copilot's own message count are counted locally, so the chat still rolls over at the limit.

## [v0.1.25] - 2026-10-02

### Added

- Every error has an id, category, hint and copyable technical details; the same id is in the log.
- Failed steps (read, grep, edit, write, run) show a category, possible reasons and what happens next.
- README: how to read an error.

## [v0.1.24] - 2026-10-02

### Added

- Suggested next steps from Copilot's reply appear as one-click prompts under the reply (never sent automatically).

### Fixed

- The half-block guard refused edits that repaired a file broken by an earlier edit; it now only refuses edits that make the file worse.

## [v0.1.23] - 2026-10-02

### Added

- Edits may shorten SEARCH text with a line of `...`, standing for everything in between.
- Edits that would leave half a block (unbalanced braces or style/script tags) are refused before anything changes.

## [v0.1.22] - 2026-10-02

### Added

- Consistency review after big changes: local checks plus one review round by Copilot for leftovers and broken references (setting `reviewAfterChanges`).
- Check and cross icons for the Copilot connection status.

### Changed

- An edit whose result is already in the file counts as "already applied (verified)" and needs no approval.
- Lines that differ only in indentation match.
- When SEARCH text is not found, the error shows the closest current lines.
- An edit that moves code out to a new file is refused until that file contains it, so nothing is lost.

## [v0.1.21] - 2026-10-02

### Added

- Arrow Up / Down in the message box steps through your earlier messages in this project.
- After a reload that lands on a sign-in page, StreamHub asks you to sign in and waits up to 5 minutes.

### Fixed

- In long chats StreamHub kept waiting although Copilot had answered; new replies are now recognized by their id.

## [v0.1.20] - 2026-10-02

### Changed

- When Copilot explains steps instead of writing action blocks, the task is sent again with the full instructions (setting `actionRetries`, default 2), then a clear status is shown.
- Instructions now explain that the helper program applies Copilot's action blocks.

## [v0.1.19] - 2026-10-02

### Changed

- Follow-ups in a work chat keep the chat's task kind, end with a short recap of the instructions, and get the full instructions again after a turn without actions or every 5 follow-ups.
- Stop does nothing when Copilot is already done, and keeps a reply that had already finished (shown, actions not carried out).
- A reply with no Stop button and no change for 8 seconds counts as finished.

### Fixed

- Light mode: flat buttons kept a dark label on a dark hover background.

## [v0.1.18] - 2026-10-02

### Changed

- Starting StreamHub replaces a copy that is still running, so an update takes effect right away.
- Copilot opens at microsoft365.com/chat, which avoids an extra sign-in on some tenants; the tab is recognized on all Copilot hosts.
- An ambiguous edit is resolved in file order, and the result names the matching lines; otherwise the error lists every match.

## [v0.1.17] - 2026-10-02

### Changed

- Clearer, structured instructions for Copilot (how the helper works, action blocks, task steps, rules).
- A plain code block that starts with an action (such as `read FILE`) counts as that action.

### Fixed

- grep with an invalid regular expression (such as `fetch(`) failed; it now searches the text literally.

## [v0.1.16] - 2026-10-02

### Changed

- Follow-ups in a coding chat end with a short reminder to make the change with action blocks.

## [v0.1.15] - 2026-10-02

### Added

- Ranged reads (`read PATH:START-END`) and ranged attachments (`@path:START-END`).
- Switch worktree button next to the title, and a flat New chat button.

### Changed

- A file that does not fit is cut at a whole line with a note on how to read the rest; file contents get most of the result budget (raised to 60,000 characters).
- grep results are given as PATH:LINE.
- The side panel tab highlight appears instantly on load; menu items appear faster.

## [v0.1.14] - 2026-10-02

### Changed

- When Copilot answers a coding task with steps instead of action blocks, it is asked once to make the changes itself.

## [v0.1.13] - 2026-10-02

### Added

- Side panel tabs in a 2x2 grid; the Files tab shows the project folder as the top of the tree with guide lines, its OneDrive location on hover, and a button to open it in File Explorer.
- The footer shows the release and the commit.

### Fixed

- Replies read from the page lost edit markers in long code blocks; the exact text is now taken from the page state.
- Edit blocks with escaped or indented markers, or a missing final REPLACE, are accepted.
- Short real answers that start like a progress message were dropped.

## [v0.1.12] - 2026-10-02

### Added

- Fetch prompts: saved prompts (for example today's meetings) whose answers are saved as files you can attach, with the time and cited sources. Fetch tab with New, Run/Refresh, Attach and View.

### Fixed

- Replies with many code blocks ended as "no answer" although Copilot had answered.

## [v0.1.11] - 2026-10-02

### Added

- Pacing: short pauses around each send, because completing tasks matters more than speed.

### Changed

- A request that gets no reply within 25 seconds is sent once more in the same chat.
- When the message box is missing after New chat, the page is reloaded; if still missing, the error says what the page shows and a screenshot is saved.

### Fixed

- A dropped connection to the Copilot tab now gives a clear error and reconnects instead of failing.

## [v0.1.10] - 2026-10-02

### Changed

- The complexity test has seven harder steps and writes each run to its own folder.

### Fixed

- A prompt is typed again when the message box was rebuilt right after it appeared.

## [v0.1.9] - 2026-10-02

### Fixed

- A prompt sent right after a new chat could hang: new chats now use Copilot's own New chat button and StreamHub waits until the page is ready.
- A spinner that never ends now stops after the stall time instead of the full timeout.
- Progress messages such as "Working on it..." are no longer taken as the answer.
- A usage-limit banner on the page now ends the wait as out of credits.

## [v0.1.8] - 2026-10-02

### Changed

- Replies delivered over the Copilot stream connection are read directly, which removes a wait of 1-2 seconds per reply on those tenants.
- The complexity test records the exact timeline of every step.

## [v0.1.7] - 2026-10-02

### Added

- `reply-timing.cmd` records the exact timing of each step of a reply.

### Changed

- Faster reading of replies from the page (about 2.5 seconds saved per reply).

## [v0.1.6] - 2026-10-02

### Added

- The header shows the Copilot connection status, with Retry when not connected.
- The side panel can be collapsed on wide windows and opens as a drawer on narrow ones.

## [v0.1.5] - 2026-10-02

### Fixed

- On some tenants StreamHub kept waiting although Copilot had answered; the reply is now also read from the page when it does not arrive over the usual connection.

## [v0.1.4] - 2026-10-02

### Added

- `complexity-test.cmd` sends prompts from simple to complex to find where Copilot starts to fail, and writes a masked report.

### Changed

- Minimal prompts: a greeting or general question goes to Copilot exactly as typed; other requests add only the instructions the chat has not had yet.
- The project context tells Copilot the folder's OneDrive location.
- After a failed connect, StreamHub retries every 30 seconds.

## [v0.1.3] - 2026-10-02

### Added

- MCP tool `copilot_run_task`: start a task, wait for it and get the full report in one call.
- The installed version is shown at the bottom of the side panel.

### Changed

- Copilot's role follows the task: developer, personal assistant, or developer with Microsoft 365 data.
- Text sent to Copilot never mentions the tool's name.
- Lines added and removed are shown as one +/- pill in the file tree, diff header and action cards.

### Fixed

- Copilot gave no reply when its tab was in a background window: the tab is now kept active.
- An empty reply or a hanging Copilot now ends with a clear error instead of a long wait.

## [v0.1.2] - 2026-10-02

### Added

- The file tree shows added and removed line counts for files changed since the project was opened.
- Action cards show who approved them ("via API", "via MCP").

### Changed

- StreamHub finds the Copilot tab again when Edge replaces it, and lost connections report the real cause.
- Internal cleanup of the chat view and side panel (no visible change).

### Fixed

- A blank screen after a malformed reply: the page now shows the error with Continue / Reload and reports it to the log.
- Only the first line of a multi-line run block was carried out.

## [v0.1.1] - 2026-10-02

### Added

- `update.cmd` updates right away and reports the result.

### Changed

- Stop acts at once: it stops Copilot's reply, ends a running command with its child processes and rejects a pending approval (also over MCP).
- New chat clears the chat view and shows "Starting..." until Copilot is ready.

## [v0.1.0] - 2026-10-02

### Added

- First release: a coding harness that uses Microsoft 365 Copilot Chat in Edge as its model, with nothing to install beyond Windows PowerShell 5.1 and Edge.
- Web app with ask, auto and plan modes, diff approvals, hold-to-run commands, undo of change sets, a file tree, read-only `source/` data and attachments.
- MCP server with `copilot_ask`, background tasks (status, approve, result, cancel), new chat and undo, for any folder.
- Reliable reply handling: replies rebuilt from the raw stream, repair of escaped characters, chat rollover, credit limits and a machine-wide send lock.
- Microsoft 365 data with cited sources, with a person always in the loop: Copilot actions are never confirmed and risky commands need a person.
- Diagnostic logging with masking and a diagnostics bundle; local config overrides, self-update from GitHub Releases, an installer and a release builder.

[Unreleased]: https://github.com/jgt87/CCBridge/compare/v0.1.51...HEAD
[v0.1.51]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.51
[v0.1.50]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.50
[v0.1.49]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.49
[v0.1.48]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.48
[v0.1.47]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.47
[v0.1.46]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.46
[v0.1.45]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.45
[v0.1.44]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.44
[v0.1.43]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.43
[v0.1.42]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.42
[v0.1.41]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.41
[v0.1.40]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.40
[v0.1.39]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.39
[v0.1.38]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.38
[v0.1.37]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.37
[v0.1.36]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.36
[v0.1.35]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.35
[v0.1.34]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.34
[v0.1.33]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.33
[v0.1.32]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.32
[v0.1.31]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.31
[v0.1.30]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.30
[v0.1.29]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.29
[v0.1.28]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.28
[v0.1.27]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.27
[v0.1.26]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.26
[v0.1.25]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.25
[v0.1.24]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.24
[v0.1.23]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.23
[v0.1.22]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.22
[v0.1.21]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.21
[v0.1.20]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.20
[v0.1.19]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.19
[v0.1.18]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.18
[v0.1.17]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.17
[v0.1.16]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.16
[v0.1.15]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.15
[v0.1.14]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.14
[v0.1.13]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.13
[v0.1.12]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.12
[v0.1.11]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.11
[v0.1.10]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.10
[v0.1.9]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.9
[v0.1.8]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.8
[v0.1.7]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.7
[v0.1.6]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.6
[v0.1.5]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.5
[v0.1.4]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.4
[v0.1.3]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.3
[v0.1.2]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.2
[v0.1.1]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.1
[v0.1.0]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.0
