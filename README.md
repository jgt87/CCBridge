# CCBridge

A local coding harness that uses **Microsoft 365 Copilot Chat** (in Microsoft Edge) as its model, with **zero installation**: it runs on Windows PowerShell 5.1 and the Edge browser that ship with Windows. No admin rights, no Node, no Python on the target machine.

You describe what you want in a web interface on `http://localhost:8765` (or from an MCP client such as Claude Code). CCBridge types the request into Copilot Chat, reads the reply, and carries out the actions Copilot asks for (read and search files, write and edit files, run commands) inside a project folder, with your approval.

```
 you ──► CCBridge web app / MCP client
            │  prompt + project context          ▲  actions, diffs, approvals, results
            ▼                                     │
         Copilot Chat in Edge (your sign-in) ─────┘
```

Automating Copilot Chat may be subject to your organisation's policies; check before use.

---

## Contents

- [Quick start](#quick-start)
- [Features](#features)
- [Using the web app](#using-the-web-app)
- [MCP server](#mcp-server)
- [Microsoft 365 data (Work IQ) and human in the loop](#microsoft-365-data-work-iq-and-human-in-the-loop)
- [Install and updates](#install-and-updates)
  - [Updating](#updating)
- [Configuration](#configuration)
- [Logging and diagnostics](#logging-and-diagnostics)
- [Troubleshooting](#troubleshooting)
- [Where CCBridge keeps its data](#where-ccbridge-keeps-its-data)
- [Development](#development)

---

## Quick start

1. Install (PowerShell, no admin rights):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/jgt87/CCBridge/main/install.ps1 | iex"
   ```
2. Start **CCBridge** from the desktop or Start menu. An Edge window opens Copilot Chat in a separate profile: sign in once with your Microsoft 365 account. The interface opens at `http://localhost:8765`.
3. Create a project (it lives in `OneDrive\CCBridge\<name>`), type what to build, and approve the changes Copilot proposes.
4. To update later: just restart CCBridge (it updates itself at every start), or double-click `update.cmd`. See [Updating](#updating).

Requirements: Windows 10/11, Windows PowerShell 5.1 in FullLanguage mode, Microsoft Edge, a Microsoft 365 Copilot Chat account, OneDrive for the web app. `probe.cmd` checks a machine and writes `probe-report.txt`.

---

## Features

### Web app
- Chat with Copilot about a project; replies render as markdown, with Copilot's actions shown as cards.
- **Three modes** (chat box, bottom left): *Ask before changes* (approve every file change and command), *Auto-accept edits* (file changes apply directly, commands still need approval), *Plan only* (Copilot can read and discuss, nothing is changed or run).
- **Approvals**: file changes show a diff with *Apply change* / *Reject* (optionally with a note for Copilot); commands need a press-and-hold on *Hold to run*. An action approved by another program (the local API or MCP) is marked *via API* / *via MCP* on its card and in the log, so you can always tell who approved what.
- **Stop** (square button while Copilot works) acts immediately: it presses Copilot's own Stop while it is writing, kills a running command with everything it started, or rejects a pending approval. Changes made so far stay undoable.
- **New chat** starts a fresh Copilot conversation and a clean chat view (stopping the current step first if needed); the Changes tab keeps the undo history.
- **Side panel** (left): *Files* (project tree, upload of source data, click to view a file; changed files show `+added -removed` line counts since the project was opened, folders show their totals), *Tasks* (Copilot's checklist), *Changes* (every message is a change set; *Undo last change set*).
- **Menu** (top right, or Ctrl+K): new Copilot chat, undo, switch project, attach a file, change mode, open any file, verbose logging on/off, export diagnostics.
- Attach files to a message with `@path` (or the @ button) so Copilot gets their full content.
- Monochrome, flat interface built with [Kokonut UI](https://kokonutui.com) components; served from prebuilt files, so the target machine never needs Node.

### Agent and actions
Copilot works through fenced *action blocks* that CCBridge executes and answers with results, in rounds, until Copilot reports `done`:

| Action | What CCBridge does | Approval |
|---|---|---|
| `read` | Returns full file contents | automatic |
| `glob` | Lists files matching a pattern | automatic |
| `grep` | Searches file contents (regex, optional file filter) | automatic |
| `write` | Creates or replaces a file | per mode |
| `edit` | Applies SEARCH/REPLACE pairs to a file (all or nothing) | per mode |
| `run` | Runs a command with cmd.exe in the project folder (output trimmed) | always, unless allow-listed |
| `todo` | Updates the task checklist | automatic |
| `done` | Ends the task with a summary | automatic |

- Project instructions in `AGENTS.md` (created with each project) are sent to Copilot at the start of every chat, together with the file list.
- Paths are confined to the project folder; existing line endings and byte-order marks are preserved.

### Safety
- **Undo**: every message is one change set; the previous versions of changed files are kept outside OneDrive and *Undo last change set* restores them (and removes files the task created).
- **Read-only source data**: files you add with *Add source data* go to the project's `source/` folder. Copilot may read them but never change, move or delete them: writes there are refused, and after every command CCBridge restores anything that was changed or deleted from a backup copy (files dropped into `source/` are moved to `work/`).
- **Human in the loop for Microsoft 365** (see [below](#microsoft-365-data-work-iq-and-human-in-the-loop)).
- The web API only accepts requests from the CCBridge page itself (per-installation token, localhost only).

### Copilot handling
- **Reply repair**: Copilot's own link/citation filter deletes code such as `[name]:` or `[guid]::NewGuid()` from its final text. CCBridge rebuilds replies from the raw stream and flags the rare cases where it had to guess.
- Copilot's page turns `<` and `>` in prompts into `&lt;`/`&gt;`; CCBridge matches and repairs that in code (not in HTML/XML/Markdown).
- **Limits**: shows the messages used in the current Copilot chat and starts a fresh chat with a summary before the per-chat limit; warns when daily Copilot credits run low and stops cleanly when they run out.
- Prompts up to the configured budget (default 75,000 characters); Copilot's page accepts up to 128,000.

### MCP server
The same bridge and agent loop for MCP clients (Claude Code, VS Code, ...), in any project folder, with background jobs, approvals and undo. See [MCP server](#mcp-server).

### Install, updates and diagnostics
- One-line install, automatic updates from GitHub Releases at every start, machine settings kept in `*.local.json` files.
- Diagnostic log with masking of personal data and a one-click diagnostics bundle for hand-off.

---

## Using the web app

1. **Projects**: on first start choose or create a project. Projects are folders in `OneDrive\CCBridge`; CCBridge reopens the last one next time. Switch with the project name in the header or Menu, *Switch project*.
2. **Ask**: type in the chat box and press Enter. Add files with `@path`. Pick the mode in the chat box.
3. **Watch and approve**: while Copilot works you see its text, its actions as cards and its checklist under *Tasks*. Approve or reject changes; hold to run commands.
4. **Review**: the *Changes* tab lists change sets; *Undo last change set* reverts the newest one. Click any file to view it.
5. **Source data**: drop files on *Add source data* (Files tab). They are read-only for Copilot; ask it to produce outputs from them (it writes to other folders).
6. **Stop**: the square button stops right away, also in the middle of Copilot's reply or a running command.
7. **New chat**: *New chat* in the chat box header starts a fresh Copilot conversation with an empty chat view (the project stays open). The counter next to it shows messages used in the current chat.

Command line, one prompt without the interface:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ccbridge.ps1 -Ping "say hi" -NewChat
```

`start.cmd` / `ccbridge.ps1` options: `-Port <n>`, `-NoBrowser`, `-NoUpdate` (skip the update check once), `-LogLevel off|info|verbose|trace`. If CCBridge is already running, `start.cmd` just opens it.

---

## MCP server

`mcp/ccbridge-mcp.ps1` exposes the bridge and agent loop to MCP clients over stdio, without the web interface, in **any** project folder.

Register it in Claude Code:

```powershell
claude mcp add ccbridge -s user -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\Programs\CCBridge\mcp\ccbridge-mcp.ps1"
```

or in any client's JSON config (with optional verbose logging):

```json
{ "mcpServers": { "ccbridge": {
  "command": "powershell.exe",
  "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\<you>\\AppData\\Local\\Programs\\CCBridge\\mcp\\ccbridge-mcp.ps1"],
  "env": { "CCBRIDGE_LOG": "verbose" } } } }
```

| Tool | What it does |
|---|---|
| `copilot_ask` | One prompt to Copilot, returns the repaired reply and cited sources; `new_chat`, `work_iq`, `timeout_sec` |
| `copilot_start_task` | Starts a coding task in `project_path` (created if missing) as a background job; `mode` `auto` / `plan` / `ask`, `allow_commands`, `new_chat`, `work_iq` |
| `copilot_task_status` | Long-polls (up to `wait_sec`) progress, plan, actions, pending approvals with unified diffs, sources, human-required notices |
| `copilot_approve` | Approves or rejects a pending action in `ask` mode, with an optional note for Copilot |
| `copilot_task_result` | Full report: every action with its output, files changed, done summary, Copilot's last reply |
| `copilot_cancel_task` | Stops a job immediately (Copilot's reply or a running command); changes made so far stay undoable |
| `copilot_new_chat` | Starts a fresh Copilot conversation |
| `copilot_undo` | Reverts the last change set in a project folder |

- Commands only run when the task allows them (`allow_commands`); commands that touch Microsoft 365 or delete data are always refused over MCP.
- The web app and the MCP server can run at the same time: a machine-wide lock makes them take turns with Copilot, and each starts a fresh chat when the other one used Copilot last.

---

## Microsoft 365 data (Work IQ) and human in the loop

With a Microsoft 365 Copilot licence and **Work IQ** on, Copilot can use your Outlook mail, Teams chats and meetings, calendar, OneDrive/SharePoint files and people in your organisation. CCBridge tells Copilot it may use that data when a task needs it, to name its sources, and to write extracted information into project files. **Sources** Copilot cited are listed under each answer (web app) and in MCP results.

- **Work IQ switch**: CCBridge can set the Work IQ toggle per task (chat box header in the web app, `work_iq` in MCP). Because the toggle differs per tenant, run `capture.cmd` once on a licensed machine: it records the toggle's controls (labels and states only, no content) in `capture-report.json`, from which the selector goes into `config\selectors.local.json`. Until then CCBridge leaves the toggle as it is and says so.
- **Human in the loop, always**:
  - Copilot is instructed to use Microsoft 365 data **read-only**: no sending or forwarding mail, no creating, changing or cancelling meetings, no posting in Teams, no sharing or deleting data. When a task needs such an action it prepares it (for example an email draft in `drafts/`) for you to do yourself.
  - CCBridge never clicks anything in Copilot's replies. If Copilot proposes a Microsoft 365 action (a confirmation card or action message), the task **stops** and you are asked to review and confirm or cancel it yourself in the Copilot window.
  - If Copilot's text claims it sent, cancelled or deleted something, CCBridge flags it so you can check Outlook/Teams.
  - Commands that would send mail or reach Outlook, Teams, Exchange, SharePoint or Microsoft Graph, and commands that delete data, always need your explicit approval in the web app (even in auto mode, with a warning) and are refused over MCP.

---

## Install and updates

**Install** (no admin rights; into `%LOCALAPPDATA%\Programs\CCBridge`, with desktop and Start menu shortcuts):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/jgt87/CCBridge/main/install.ps1 | iex"
```

Set `$env:CCBRIDGE_DIR` first to install elsewhere. Alternatively download `CCBridge-<version>.zip` from [Releases](https://github.com/jgt87/CCBridge/releases), unzip it anywhere and run `start.cmd`.

### Updating

New versions are published as [GitHub Releases](https://github.com/jgt87/CCBridge/releases). The easiest ways to get one, from least to most effort:

1. **Restart CCBridge.** Every start of CCBridge (and of its MCP server) checks GitHub and installs the newest release before it opens; this takes a few seconds. Offline, or if anything goes wrong, it simply starts the version you have. So normally you do nothing: close the CCBridge window and start it again from the shortcut.
2. **Double-click `update.cmd`** in the CCBridge folder (`%LOCALAPPDATA%\Programs\CCBridge`). It updates right away and tells you the result, for example `updated v0.1.0 -> v0.1.1` or `Already up to date (v0.1.1)`. If CCBridge was running, close and start it again afterwards.
3. **Run the install command again** (see above). It updates the existing installation in place.

Your settings in `config\harness.local.json` and `config\selectors.local.json` are kept by every update. The installed version is in `version.txt` (also shown in `environment.json` of a diagnostics export).

- Turn automatic updates off with `"autoUpdate": false` in `config\harness.local.json` (`update.cmd` still works); for the MCP server alone set the environment variable `CCBRIDGE_NO_UPDATE=1`.
- A git clone updates with `git pull --ff-only` instead (skipped when it has local changes or is on another branch).
- MCP clients start the MCP server when they launch, so restarting the MCP client (for example a new Claude Code session) also picks up a new version.

---

## Configuration

Settings live in `config\harness.json` and `config\selectors.json`. Put your own values in **`config\harness.local.json`** / **`config\selectors.local.json`** (same keys, only the ones you change): updates never overwrite these files.

| `harness` key | Default | Meaning |
|---|---|---|
| `port` | 8765 | Web app port |
| `cdpPort` | 9333 | Edge debug port used to drive Copilot |
| `projectsFolder` | `CCBridge` | Folder under OneDrive for web-app projects |
| `maxRounds` | 12 | Copilot rounds per message before CCBridge pauses |
| `promptCharBudget` | 75000 | Maximum characters sent to Copilot per prompt |
| `resultCharBudget` | 40000 | Maximum characters of action results per round |
| `replyTimeoutSec` | 300 | Wait for one Copilot reply |
| `commandTimeoutSec` | 180 | Maximum run time of a command |
| `rolloverMargin` | 2 | Start a fresh chat this many messages before Copilot's per-chat limit |
| `autoApproveCommands` | `[]` | Regular expressions of commands that run without approval (never applies to risky commands) |
| `workIq` | `leave` | `on`, `off` or `leave` (do not touch the toggle) |
| `saveReplyFrames` | `true` | Keep the raw data of the last 30 Copilot replies for diagnosis |
| `autoUpdate` | (on) | `false` turns automatic updates off |
| `logLevel` | `info` | `off`, `info`, `verbose`, `trace` |

`selectors.json` holds the Copilot address, `chatUrl` (default `https://m365.cloud.microsoft/chat`, opened at start and for every new chat), and the CSS selectors for Copilot's message box, Send button and (via `capture.cmd`) the Work IQ toggle. If Microsoft changes the Copilot page, a selector fix in `selectors.local.json` is usually all that is needed.

---

## Logging and diagnostics

### Where and what
- Log files: **`%LOCALAPPDATA%\CCBridge\logs\ccbridge-yyyyMMdd.log`**, one per day, kept 14 days. The web app, the MCP server, the updater and the diagnostics tool all write to the same file.
- One line per event: time, process id, level, component, message, optional JSON data:
  ```
  2026-10-02 01:33:30.746 [33720] INFO    server   Web app started on http://localhost:8765/ {"ccbridge":"v0.1.0","powershell":"5.1.26100.9444",...}
  2026-10-02 02:04:12.118 [33720] VERBOSE bridge   Reply received {"ms":7412,"frames":38,"chars":1620,"uncertain":0,"result":"Success","chat":"3/30","credits":"41/50",...}
  ```
- Components: `server` (web app), `mcp`, `agent` (turns, rounds, actions, approvals), `bridge` (message box, sending, replies), `cdp` (Edge connection), `exec` (commands, risk checks), `source` (source-data protection), `update`, `diag`.
- **Masking**: in every line your Windows user name, profile path, OneDrive path, computer name, email addresses and GUIDs (conversation, message and user IDs) are replaced (`%USERPROFILE%`, `%OneDrive%`, `<email>`, `<id>`), so logs can be shared as they are.

### Levels

| Level | What it records |
|---|---|
| `off` | Nothing |
| `info` (default) | Startup with an environment summary (versions, PowerShell mode, Edge, settings), Edge start, Copilot connect, turn start/finish with duration, chat rollover, human-required notices, risky commands, source-data restores, updates, and every error with its PowerShell stack |
| `verbose` | Everything in `info` plus every step with timings: Edge debug-port reuse, page target, message box typing (lengths), Send, each reply (duration, frames, length, repair, result code, chat messages used, credits left, sources, proposed actions, **message types CCBridge does not know yet**), parsed actions per round, each action and its result, approval waits, command exit codes, Work IQ toggle results, web API and MCP calls with durations. **No message content.** |
| `trace` | Everything in `verbose` plus the full prompt and reply text and MCP tool arguments. Replies can contain Microsoft 365 data: use only when asked, and check before sharing. |

### Turning verbose logging on
- **Web app**: Menu (top right) → **Verbose logging: turn on**. Takes effect immediately and stays on after restarts (stored as `logLevel` in `config\harness.local.json`); the same menu item turns it off again.
- **For one session**: `start.cmd -LogLevel verbose` (or `trace`).
- **Permanently**: `config\harness.local.json` containing `{ "logLevel": "verbose" }`.
- **MCP server**: add `"env": { "CCBRIDGE_LOG": "verbose" }` to the server entry in your MCP client's config (environment variable `CCBRIDGE_LOG`), or use `harness.local.json`.

Precedence: `-LogLevel` parameter, then `CCBRIDGE_LOG`, then `logLevel` in the settings, then `info`.

### Handing diagnostics to someone
1. Turn verbose logging on and reproduce the problem.
2. Run **`diagnostics.cmd`** (in the CCBridge folder) or Menu → **Export diagnostics**.
3. Send the `CCBridge-diagnostics-yyyyMMdd-HHmm.zip` that appears on your desktop.

The zip contains:

| File | Content |
|---|---|
| `environment.json` | CCBridge version and install kind, PowerShell version and language mode, Windows, Edge version, OneDrive present, settings, whether the Work IQ toggle is configured, whether Edge's debug port is open |
| `config-*.json` | The settings files, including your `*.local.json` overrides (masked) |
| `page-check.json` | Whether CCBridge's selectors still find Copilot's message box, Send button, Stop button and Work IQ toggle (only when Edge with Copilot is open) |
| `logs\` | The last 2 days of logs (`diagnostics.cmd -Days 7` for more) |
| `replies\` | Only with `diagnostics.cmd -IncludeReplies`: raw Copilot replies, **full text, may contain Microsoft 365 data** |

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| `start.cmd` says the port is used by another program | Start with `start.cmd -Port 8766` |
| Edge opens but CCBridge waits for the message box | Sign in to Copilot in the Edge window CCBridge opened (it uses its own profile) |
| "Out of Copilot credits until …" | Copilot's daily limit; it resets at the time shown |
| "message box holds N characters, expected M" or "Send button never became clickable" | Copilot's page changed: export diagnostics (`page-check.json` shows which selector fails) |
| A reply is marked as repaired / "check this change carefully" | Copilot's filter removed text and CCBridge had to guess part of it; review the diff before approving |
| "Work IQ could not be switched" | Run `capture.cmd` on a licensed machine and configure the toggle selector |
| A fix is announced but you still see the old behaviour | Close CCBridge and start it again (or run `update.cmd`), then reload the browser tab (F5) |
| Anything else | Turn on verbose logging, reproduce, run `diagnostics.cmd` |

---

## Where CCBridge keeps its data

| Location | Content |
|---|---|
| `OneDrive\CCBridge\<project>` | Web-app projects (your files; `source/` = read-only source data) |
| `%LOCALAPPDATA%\Programs\CCBridge` | The installed application |
| `%LOCALAPPDATA%\CCBridge\edge-profile` | The Edge profile CCBridge uses for Copilot (your sign-in) |
| `%LOCALAPPDATA%\CCBridge\projects\…` | Undo backups and the source-data copy per project (not synced) |
| `%LOCALAPPDATA%\CCBridge\logs` | Diagnostic logs (14 days) |
| `%LOCALAPPDATA%\CCBridge\replies` | Raw data of the last 30 Copilot replies (`saveReplyFrames`) |
| `%LOCALAPPDATA%\CCBridge\session-token.txt` | Token that protects the local web API |

---

## Development

- Backend: `lib/*.psm1` (Cdp, CopilotBridge, Workspace, Protocol, Executor, Agent, Server, Config, Log) and `mcp/ccbridge-mcp.ps1`. The running web app keeps modules in memory: restart it after backend changes.
- Interface: React + Vite + Tailwind with Kokonut UI components (adapted in `ui-src/src/components/kokonutui`); `npm run build` in `ui-src` writes the committed `ui/` folder.
- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester .\tests"` (Pester 3.4, ships with Windows; run under Windows PowerShell 5.1).
- Release: `tools\build-release.ps1 -Version vX.Y.Z` builds `dist\CCBridge-vX.Y.Z.zip`; publish it as a GitHub Release asset.
- Contributor notes, PowerShell 5.1 pitfalls and Copilot quirks: [AGENTS.md](AGENTS.md).
