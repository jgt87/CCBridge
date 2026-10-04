# Changelog

All notable changes to StreamHub are listed here, newest first.

## [Unreleased]

Nothing yet.

## [v0.1.69] - 2026-10-04

### Changed

- The Tasks tab is now called Progress, and its Queue section is now called Runs (it lists every task waiting, running and done). Messages that pointed at the Queue say Progress > Runs.
- The Agent and Response pickers above the message box sit on the left; Work IQ, credits, the message count and New chat stay on the right.
- File lines in a change set (Changes tab) have a little more space, so their `+added -removed` counts no longer touch (1 pixel between them).
- Side panel tab order: Files and Automation on the top row, then Changes and Progress, then Code health.
- A chat note about a saved file (task report, saved chart) no longer has an "Open" link after it: the note itself opens the file (underlined on hover).

## [v0.1.68] - 2026-10-04

### Changed

- An option that is on stands out next to the message box: Clarify first turns solid (black, or white in dark mode) and shows its name, and Work IQ does the same when it is on.
- Settings opens complete instead of filling in piece by piece: the settings, the single sign-on status and the size of Edge's cache are loaded in the background a few seconds after the app starts, shown at once when Settings opens and refreshed quietly while it is open.

## [v0.1.67] - 2026-10-04

### Added

- Data copies follow their JSON: a `.js` file that only wraps a JSON file's data (made because a page opened from disk cannot load JSON) is rewritten from that JSON whenever it differs, after every task and when a project opens, with a "Generated from ... Do not edit" first line. The JSON is the one source of truth, so a mismatch between the two cannot stay: the chat says when a copy differed, a rewrite is an undoable change set, and a copy whose JSON is missing or invalid is reported and left alone. Copilot's edits to a copy are refused ("change the JSON instead"), code review no longer reports findings in copies (their data is the JSON's), and Copilot's web rules and the `file://` fix say the copy follows the JSON. JS files with other code are never touched. Setting "Data copies follow their JSON" (Settings > Changes and commands, on by default) turns all of this off.
- Changes StreamHub makes to a project itself now show in the chat as action cards, like Copilot's reads and writes, tagged "by StreamHub": a rewritten data copy (Write, with its diff), folders moved to the current layout (Move), files whose links were updated after a move (Edit, with the diff) and changes to Source/ that were put back (Restore). Before, these were plain notes. At project open they now appear below the earlier conversation instead of above it.

- Code review findings have an Ignore button (and Unignore). An ignored finding is greyed out, cannot be picked for fixing, and later reviews leave out findings about the same line.

### Fixed

- Issues you ignored came back: an ignore was tied to the issue's id, which changes when the same kind of problem appears earlier in the file, and it was forgotten as soon as the issue was briefly not found. Ignores are now remembered by what they are about (file, check, message and the code line), so they hold when lines move, other issues come and go, or the file is rescanned. Ignores made before this update are kept.
- Code review reported problems you had ignored in Issues: each review part now tells Copilot which findings in its files were ignored, and any finding that still quotes such a line is left out (the review's summary says how many).

### Changed

- StreamHub always opens on a new chat: the first project it opens after a start shows a fresh chat instead of the earlier conversation (that stays in the chat history; Arrow Up still recalls its messages). Switching projects later still shows each project's conversation.
- The line above the message box no longer repeats the project name and the mode's description (both are already shown in the side panel and the mode picker); it only shows the Queued note when a message waits.

## [v0.1.66] - 2026-10-04

### Changed

- A message to Researcher or Analyst now states the expected output, so the answer can be reused: Markdown with a title and short summary, figures and comparisons in tables, a link for each source, and the data at the end in one JSON block (`prompts/agent-output.md`). It is left out when your message already says how the answer should look (table, JSON, CSV, format, bullets, ...), and your answer to Researcher's plan goes as typed.

## [v0.1.65] - 2026-10-04

### Changed

- Side panel: *Code health* has a Beta tag and is the last tab, spanning the free width of its row so its name and the tag fit; *Automation* moved up next to *Changes*. Tabs have slightly less padding.
- Menu: *Settings* no longer has a description (it listed only a few of the settings).
- Settings in 8 groups instead of 17: This browser, Sign-in, Copilot, Timing, Changes and commands, Checks and issues, Privacy and retention, App. Only their place changed: every setting keeps its value.
- Clearer names: *Switch project* (was Switch worktree; StreamHub has no Git); the agent menu reads *Agent: none (Copilot) / Researcher / Analyst* (was *Ask:*, which clashed with the mode *Ask before changes*); Tasks > *Checklist* (was Plan, which clashed with Plan only and the clarify-first plans); *as set in Copilot* everywhere (was "page setting" in the message box and the Work IQ button); *New chat* in the Menu as in the message box; Settings > *Copilot checks its big changes* (was Review after changes, easily mixed up with Code review); Retention > *Earlier runbook results* (was History).
- *Task report (evidence)*: the setting, its retention numbers and the chat line ("Task report saved: ...", with *Open*) use one name, with a one-line explanation of what the report holds (was Evidence per task / Evidence saved).
- The Files tree shows the project's `.streamhub` folder (StreamHub's own records), closed at first and marked with a cog icon and an explanation; Copilot's file list still leaves it out.
- The read-only `Source/` folder has its lock icon in the tree again (it was lost when the folder got its capital).
- Start screen: the limitation reads *No artifact generator* and says that charts in Analyst answers are saved as images.

## [v0.1.64] - 2026-10-04

### Changed

- Side panel: new tabs *Code health* (Issues, Code review) and *Automation* (Scheduled, Runbooks, Chains). *Changes* shows only the change sets, without a fold-away section; *Tasks* keeps Plan and Queue. The *Fetch* tab is gone (a browser that last showed it opens Automation). The tabs sit in two columns so their names stay readable; the Files tab's "N file(s) with issues" opens Code health.
- Fetch prompts and runbooks are one thing now: **Runbooks**, with a *text answer* (Markdown; the former fetch prompts, still `NAME.prompt.md`) or *checked JSON* (`NAME.runbook.md`). One list with a kind tag and the same buttons for both (*Run*, *Schedule*, *View*, *Result*, *Attach*); *New runbook* asks which kind, and the text kind has the sources, sites, pages, agent and files fields. A chain's `runbook:` step runs either kind (`fetch:` still works); schedules, the queue and the chat say "Runbook".
- The Automation tab lists the schedules in place (Edit, Run now, Pause, Delete) with *New schedule*; Edit opens the schedule's form directly.
- Change sets show what asked for them (the message, or the chain) and `+added -removed` per file, and the newest says that Undo takes it back. In the Queue, a task's "N file(s) changed" opens its change set on the Changes tab and lights it up. A chain's script changes now appear as a change set too.
- Chains get their steps in the app: *Add a step...* on each chain adds a runbook (either kind) or a script from `Scripts/` with optional arguments, and each step can move up or down or be removed. StreamHub writes and renumbers the step lines in `Runbooks/NAME.chain.md` and checks a new step first. A new chain starts without steps (it had two placeholder steps that showed as problems), and the chain's *Chain* button is now *View*, like the runbooks' button.

### Added

- Settings > Retention: *Charts: kept per item* (default 20) and *Charts: days kept* (default 90) for the charts saved from Researcher and Analyst answers in `Runbooks/Exports/`, per runbook, fetch prompt or agent; the charts of one answer count as one. Only files with StreamHub's chart name pattern are removed, never the exports themselves.
- While Researcher or Analyst works, the waiting indicator shows the agent's own progress lines from Copilot's reply stream (for example "Researcher: Searching for release details") instead of a general waiting text.

### Fixed

- Copilot's page no longer draws StreamHub's action blocks as broken charts ("Chart.js", "Invalid JSON"). On some tenants the page draws every code block whose label it does not know as a chart, `text read` included (`render-test.cmd`). Copilot now writes each action as a `text` block whose first line is `ACTION` and the action (for example `ACTION read`, or `ACTION write PATH` in a four-backtick block), which the page shows as plain code. Replies in the old form (`read` as the label) still work, ordinary text blocks are never taken for actions, and the chat in StreamHub hides exactly the blocks that are carried out.
- On tenants where StreamHub reads replies from the page, a running Researcher is never taken for finished or stuck while Copilot's message box asks for "additional instructions for the ongoing research report".

## [v0.1.63] - 2026-10-04

### Added

- Settings > Privacy > *Clear Edge's cache*: removes the caches in StreamHub's own Edge profile (stored web files, compiled code, graphics caches, downloaded updates; about 320 MB of 810 MB here), never the Copilot sign-in, cookies or settings. The web cache is cleared at once; folders Edge keeps locked while it runs are removed the next time StreamHub starts Edge. The setting shows the cache and profile size.
- Code quality rules for Copilot (`prompts/rules/quality.md`), sent once per chat with requests that build or change code: reuse existing helpers, short focused functions, data out of code, no empty catch, no debug leftovers, no personal paths or secrets, no new packages unless needed, alt text and labels on pages, tests for changed logic when the project has tests.

### Changed

- The GitHub release notes of v0.1.50, v0.1.51 and v0.1.53 now match their changelog sections (entries added to the changelog after those releases).

## [v0.1.62] - 2026-10-04

### Added

- Files for Researcher and Analyst: `@` and a project file in a message to an agent (for example `@Source/sales.csv`) attaches that file the way Copilot's own + button does; at most 10 files of up to 50 MB, never StreamHub's own records.
- Charts in an agent's answer (Analyst draws them in the page) are saved as PNG files in `Runbooks/Exports/`, on a white background, with an *Open* link in the chat. The file viewer now shows images.
- Agents in runbooks, fetch prompts and chains: header lines `agent: researcher` or `agent: analyst` and `files: PATH, PATH`; the *New fetch prompt* form has *Ask* and *Files* fields. A runbook runs unattended, so a research plan from Researcher is answered with "go ahead with your plan and your own assumptions" (the runbook's instructions are the answer). Copilot's runbook instructions describe the new lines.

## [v0.1.61] - 2026-10-04

### Added

- Researcher and Analyst in StreamHub: the *Ask* menu in the message box (next to *Response*) sends the next message to Copilot, Researcher or Analyst. An agent gets the message as typed, in a new Copilot chat, mentioned the way a person does it (picked from Copilot's `@` list); when the agent is not available nothing is sent. StreamHub waits up to 30 minutes for an agent (new setting Agent timeout). Researcher's research plan gets a card to answer its questions or let it go ahead with its own assumptions (StreamHub never answers for you). Each answer is tagged with the agent that gave it, read from Copilot's reply, with a note when Copilot answered itself instead.
- Choose a project: each project shows its size and type under the last-changed date, for example "42 files · 1.2 MB · HTML, JavaScript, CSS · source data" (the main languages by number of files). Only file names and sizes are read, so OneDrive downloads nothing.

### Fixed

- `agent-test.cmd`: the agent check now reads the agent name the reply stream gives (`compliantAgentName`, for example `ResearcherAgent` or `AnalystAgent`). It said there was "no sign that Analyst answered" for a run where Analyst did answer, because the page does not show the agent's name for Analyst.
- `agent-test.cmd` still kept waiting after a finished Researcher run: Teams' notification connection counted as reply data, and the empty reply Copilot adds after an agent's report kept the reply text from settling. Only Copilot's own connections count now, and Copilot's completion record after the last message also ends the run.

## [v0.1.60] - 2026-10-04

### Changed

- StreamHub's own records are no longer mixed with the project's code: evidence, code review reports, earlier versions of runbook and fetch data, and the clarify-first plans now live in `.streamhub/` (`.streamhub/Evidence/`, `.streamhub/Reviews/`, `.streamhub/History/`, `.streamhub/PLAN.md`). Existing projects are moved once when they open; only files StreamHub made are moved, so a project's own `evidence/` or `reviews/` files stay. Copilot's searches and the issue and review scans no longer see them. The chat's *Evidence saved* line has an *Open* link, and the plan cards open the plan in its new place.
- StreamHub's folders start with a capital: `Source/` (read-only source data), `Scripts/`, `Logs/`, `Work/`, and inside `.streamhub/` `Evidence/`, `Reviews/`, `History/`. Existing lowercase folders are renamed once when the project opens. `src/` and conventional code folders such as `tests/`, `docs/` and `data/` keep their lowercase names, because tools expect them. The project's own code follows the move: links, imports, `fetch()` calls, script paths and Markdown links that point into a moved or renamed folder are rewritten to the new place in the same style (relative, root-relative, backslashes), web addresses and `Source/` stay as they are, the import index is rebuilt, and the chat lists the files that changed (their earlier versions are kept in StreamHub's local data folder).
- Files tab: the button that opens the project folder in File Explorer moved from the FILES header to the project's own row at the top of the tree.

## [v0.1.59] - 2026-10-04

### Added

- Chains (Fetch tab > Chains): runbooks, fetch prompts and scripts from the project's `Scripts/` folder that run one after another, as a file `Runbooks/NAME.chain.md` with one step per numbered line. A runbook step can take files from earlier steps as data (`with Runbooks/Exports/FILE.json`); `stopOnError: no` carries on after a failing step. Run, schedule (schedules now also run chains) or ask Copilot to write one. Scripts (`.ps1`, `.cmd`, `.bat`, `.py`, plain arguments only) follow the same safety rules as Copilot's commands: never deleting or moving outside the project, a person approves scripts that delete data or use Microsoft 365 every time, and `source/` is put back. New setting Settings > Chains > Scripts in chains: approve-once (default: a person approves a script the first time and after it changed, then it runs from a schedule without asking), always-ask or off. What the scripts change is one change set for Undo.
- `render-test.cmd`: shows how Copilot's page displays code blocks per label (a plain code block, a "not fully supported" note, or a Chart.js chart with "Invalid JSON"), one short message per label, with a report in `C:	emp`. On this tenant `read` gets a note, while `text`, `plaintext` and `text read` show as plain code.

### Fixed

- Files tab with line counts set to "last change": when one instruction made several changes to a file, a later change that rewrote lines an earlier one had added did not show. The counts now add up every write and edit of the instruction (each change as shown on its card).

## [v0.1.58] - 2026-10-04

### Fixed

- Download folders of earlier updates (`%LOCALAPPDATA%\Temp\ccbridge-update-*`) that could not be deleted right away, for example while a virus scanner still had the zip open, are removed at the next start (those older than an hour). A failed delete no longer marks a good update as skipped.
- `agent-test.cmd` did not see a Researcher report as finished: the report is not always where the reply text is measured. A run now also ends when Copilot's Stop button has gone and no reply data came for 30 seconds, and `timeline.txt` notes every 15 seconds what the test is waiting for.
- Files tab with line counts set to "last change": right after the app started, the counts of the last change from an earlier run still showed. They now start empty when a project opens and show only changes made since.
- Settings > Response mode: the option "Leave" is now called "As set in Copilot" (StreamHub leaves Copilot's picker alone), "Quick" and "Deep" read "Quick response" and "Think deeper" like in Copilot, and the help text explains each.

## [v0.1.57] - 2026-10-04

### Fixed

- `agent-test.cmd` kept waiting after the agent had finished: the connection's keep-alive pings counted as activity, so the run never looked quiet. Pings no longer count, and the progress line shows how long ago real reply data came in. A run also counts as finished once Copilot's Stop button is gone and the reply text has not changed for 20 seconds.
- `agent-test.cmd` (Analyst) clicked Send while the attached file was still uploading, so Copilot ignored it while the test logged "sent". It now waits until the file shows as uploaded, checks after Send that the message left the box (or Copilot's Stop button shows), and tries again up to 5 times.
- `agent-test.cmd` invokes Researcher and Analyst by picking them from the `@` list again (found by name, selected with a real click): typed `@Researcher` text reached plain Copilot, not the agent. `-TypeOnly` keeps the typed variant.

## [v0.1.56] - 2026-10-04

### Added

- Settings > Retention: how many and for how many days StreamHub keeps what it generates per project: earlier versions in `History/` (per runbook or fetch prompt; default 20 / 90 days), evidence per task (100 / 90 days), code review reports (20 / 180 days), undo change sets (100 / 30 days, the newest always stays) and chat history events (1500). 0 = no limit. Old items are removed when a project opens and after each task; `source/`, `Logs/` and other project files are never touched. At every start, StreamHub also applies the undo and chat history limits to all projects' state folders, so projects that are not opened any more do not keep growing.
- When a project opens, the import index is brought up to date in the background together with the issue index, so "Used by" and broken-link checks work before the first task.

### Changed

- Files tab > Index: the line "N file(s) with issues" has a Beta tag and leads to the issues overview: it opens the Changes tab with its Issues section unfolded and in view. When nothing was found, the line only says when the project was indexed.
- Changes tab: the Issues heading shows the number of open issues, like Change sets shows its count.

### Fixed

- `agent-test.cmd` reported Researcher and Analyst as not available although they were: Copilot's `@` list does not use the standard list roles. The test now starts the prompt with `@Researcher` / `@Analyst` (`-PickFromList` finds the entry by its name and clicks it), never stops on a check, and ends with an agent check: whether the reply stream or the page shows that the agent answered.

## [v0.1.55] - 2026-10-04

### Changed

- Settings > Sign-in: single sign-on can be switched off and on again, also when Edge turned it on by itself. Off makes Copilot open in a private session in StreamHub's Edge (like an InPrivate window), where the Windows account is not used and you sign in yourself once per Edge start; On returns to StreamHub's Edge profile and closes the private session. No Edge setting or policy is changed. Applies at the next start (setting `signIn`). The status list shows which session Copilot uses.
- Settings: the same padding left and right; reset and "Saved" sit just left of each control, so the controls end at the right padding.
- Settings > Sign-in shows its status as a list: single sign-on, work account on this PC, the Edge profile's account, and the Copilot tab.
- Files tab: a setting (Settings > Files > *Line counts in the Files tab*) to count added and removed lines for the last change only (the new default), so earlier counts and "new" tags disappear at the next change, or for the whole session as before.
- Files tab: the "Source data" section is now called "Add data".
- Every web link in the app, including the changelog link, opens in a new tab.
- The start screen's limitations list says plainly that Git is not part of StreamHub (no commits, branches or pushes).
- This changelog: entries that were missing for v0.1.50, v0.1.51 and v0.1.53 were added.
- The desktop and Start menu shortcuts from before the rename (`CCBridge.lnk`) are renamed to `StreamHub` when StreamHub starts, so no new install is needed. Only shortcuts that start StreamHub itself are touched.

## [v0.1.54] - 2026-10-04

### Changed

- Settings: the window is wider (up to 880 px), and every row has the same layout: label and help on the left, one control column of fixed width and height, and the same place for reset and "Saved". All on/off choices use the same switch, also Desktop notifications and the on/off settings that were drop-downs; drop-down values show capitalised.
- Settings > Sign-in reports single sign-on as on when Edge turned it on by itself for StreamHub's profile (on a work PC with one profile), instead of "the switch is not offered", and shows which account the Edge profile uses. The setup log names the profile's account kind and the open tabs (site and path only).

### Fixed

- Settings > Sign-in said "no Copilot tab open" when the Copilot tab was on another Copilot page than the chat; it now uses the same sites as the bridge.

## [v0.1.53] - 2026-10-04

### Added

- Data from the web:
  - requests about online information, or that name websites, get instructions for web sources: only the named sites, a link and date for each fact, exact numbers, no guessing;
  - a `web` action: StreamHub reads a public page and gives Copilot its text, as data. Sites your message names are read at once, other sites need your approval, and local or intranet addresses are never read. Setting: Settings > Web > *Read web pages*;
  - fetch prompts and runbooks take `sources`, `sites` and `pages` header fields: which data to use, the only websites to use (sources outside them are noted), and pages read up front for exact figures. The *New fetch prompt* form has fields for them;
  - a runbook template *Data from web pages*.
- When StreamHub manages the Work/Web switch, a fetch prompt or runbook with `sources` sets it for its run (web: off, work or both: on) and puts it back afterwards.
- Saved fetch prompts show their sources, sites and number of pages under the prompt text.
- The blank runbook template documents the `sources`, `sites` and `pages` fields.

### Fixed

- The JavaScript file check read a regular expression after `=>` or `return` (for example `(p) => /^https?:\/\//.test(p)`) as a comment and reported a bracket problem that was not there.

## [v0.1.52] - 2026-10-04

### Added

- Coding guardrails, on what a change adds:
  - writes into generated folders (`node_modules/`, `dist/`, `.git/`, build output) and lock files are refused;
  - new dependencies (packages, or scripts and stylesheets from other sites) and risky code (`eval`, `innerHTML` from a variable, `Invoke-Expression`, `shell=True`, SQL built from strings, ...) need your approval, also in auto mode;
  - debug leftovers and swallowed errors are sent back to Copilot to fix;
  - a new `.env` that `.gitignore` does not exclude is sent back to Copilot;
  - a PowerShell file that gets non-ASCII text is saved with a BOM, so Windows PowerShell 5.1 reads it correctly;
  - absolute paths into a user's folder, code files pushed over 400 lines, large blocks of inline data, images without alt text, buttons and form fields without a label, and new helper scripts without a header or without stopping on errors are sent back to Copilot;
  - at "done", one reminder per task when code changed without a test (in a project with tests), or a new part was added without a README line.
- A test that keeps the repository and the built interface free of links to other GitHub repositories.

### Changed

- The start screen lists StreamHub's limitations once Copilot is connected: no Git integration, no MCP support, no skill support, no artefact generator. The README has the same list.
- Accessibility: every form field and icon-only button in the app now has a label for screen readers (22 places, no visible change).
- Links to other GitHub repositories were removed: the Kokonut UI component headers (author, licence and website stay), the interface's template README, and the bundled libraries' messages in the build.

## [v0.1.51] - 2026-10-04

### Added

- `agent-test.cmd`: tests Copilot's Researcher and Analyst agents the way StreamHub will invoke them (mentioned in the message box): a new chat, the mention picked from the @ list, a fixed harmless prompt (Analyst gets a made-up CSV), one automatic answer when the agent first asks questions or shows a plan, and a stop once the run has finished. Each run writes a zip with a step log, timings and the reply structure, without reply text.
- `agent-capture.cmd`: records a run you do by hand the same way.
- Settings > Sign-in: single sign-on with your Windows work account in StreamHub's Edge profile, so Copilot signs in by itself after a restart. It shows the status (work account on this PC, the profile switch, the Copilot tab), turns Edge's "single sign-on for work or school sites" switch on or off in StreamHub's own profile only, and has "Run setup" (with a log) and "Open Edge's profile settings". No password is stored, and Edge policies are never changed. `sso-setup.cmd` does the same from a command window.
- The system check at start shows whether this PC can use single sign-on.
- README: "How a prompt is typed and sent", "Staying signed in", "Tech stack", and how to run the Researcher and Analyst test.
- `stream-shape.cmd` can summarise one recording (`-Path`, `-OutFile`); `agent-capture.cmd` uses it for its structure file.

## [v0.1.50] - 2026-10-04

### Added

- Project folder layout: `src/` for new code, `Scripts/` for helper scripts, `Runbooks/` for everything that gets data from Microsoft 365 or Work IQ (runbooks and fetch prompts), `Runbooks/Exports/` for their data, `History/` for earlier versions, `Logs/` for the project's own logs, and `.streamhub/` for StreamHub's own records. Copilot gets the same rules, and web projects also get the usual web folders (`public/`, `src/components/`, `src/pages/`, `src/styles/`, `src/assets/`).
- Older projects are moved to the new layout once, when they open. Nothing is overwritten.
- Fetch answers keep their earlier versions in `History/`.
- Import index: which file imports or uses which (ids, inline handlers, custom hooks), with line numbers kept current after every round. Copilot sees "Used by" when it reads a file. Imports of moved or deleted files, and removed ids, functions or hooks that others still use, are reported with the line to fix.
- Pages opened from disk: local `fetch()`, JSON imports and module scripts, which the browser blocks there, are reported with the replacement (a `.js` data file and the `<script>` tag to add).
- Files tab: new files get a "new" tag, a bar shows while the tree refreshes, and the tree refreshes after each step and when the window gets focus.
- `CHANGELOG.md`, with every release since v0.1.0.

### Changed

- Line counts and "new" tags in the Files tab cover the changes in the restored chat after a restart.
- The issue scan and the code review skip `History/`, `Logs/` and `Runbooks/Exports/`, which hold generated data (the review also skips `.streamhub/`).
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

[Unreleased]: https://github.com/jgt87/CCBridge/compare/v0.1.69...HEAD
[v0.1.69]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.69
[v0.1.68]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.68
[v0.1.67]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.67
[v0.1.66]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.66
[v0.1.65]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.65
[v0.1.64]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.64
[v0.1.63]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.63
[v0.1.62]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.62
[v0.1.61]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.61
[v0.1.60]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.60
[v0.1.59]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.59
[v0.1.58]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.58
[v0.1.57]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.57
[v0.1.56]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.56
[v0.1.55]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.55
[v0.1.54]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.54
[v0.1.53]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.53
[v0.1.52]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.52
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
