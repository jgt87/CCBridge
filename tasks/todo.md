# Microsoft 365 items from ObsidiNote (2026-11-17)

Source: a read-only survey of ObsidiNote; the operator asked for all five ("do all 5").

## 1. Work IQ switch: make it settable, and honest until it is (me)
- [x] `Get-WorkIqToggleCandidates` (CopilotBridge): from the capture's two control snapshots (Work IQ
      on / off), the controls whose checked/pressed/selected state flipped, each with a selector,
      `stateAttribute` and `onValue`. Pure, tested.
- [x] `tools/capture-copilot.ps1` prints the proposal and, on a yes, writes it to
      `config/selectors.local.json` (merged over selectors.json).
- [x] MCP `work_iq` descriptions and instructions: only when the switch is set up on the machine;
      otherwise the result says "unavailable" and Copilot keeps its own setting.
- [ ] (open) Live capture on a licensed tenant: needs the operator (not possible from here).

## 2. Summarise a Microsoft 365 or web link (me)
- [x] Runbook template `link-summary.runbook.md`: header `link:`; checked JSON with readable,
      problem (no-access | not-found | other), title, where, kind, summary, keyFacts, useFor,
      sensitivity; read-only, with the person's own access.

## 3. Copilot still working at the time cap: leave it running, read the answer later (me)
- [x] Bridge: at the cap, when the page still shows Copilot at work, do not press Stop; keep the
      chat's address (https, Copilot host, path only) and end with a distinct "still working" result.
- [x] Agent: the task ends saying so and keeps the address; a "Read the answer" task reopens that
      chat, waits until Copilot is idle and reads its last reply into the transcript.
- [x] Web app: the button on that message; MCP: the status says so.

## 4. Web address of a synced OneDrive / SharePoint file (helper A)
- [x] `lib/SyncedFiles.psm1`: sync roots from `HKCU\Software\SyncEngines\Providers\OneDrive`
      (MountPoint, UrlNamespace), a project file's https address; tests with registry stand-ins.
- [x] API route and a "Copy web address" control where a file opens in the app.

## 5. Edge with forced sign-in (BrowserSignin = 2) on locked-down tenants (helper B)
- [x] Policy check, profile account type from Local State, profile already open without the debug
      port; a Microsoft login tab is never sent back to Copilot. Port from ObsidiNote with tests.

## After all
- [x] Combined checks: Pester for the changed areas, tsc -b, lint, vitest, `npm run build`, 0x08.
- [x] CHANGELOG, docs/architecture.md rows, AGENTS.md rows and quirks (prompt budget untouched).

Released in v0.1.167; CI fixes in v0.1.168 (main run green, 2026-11-17).

# Operator decisions (2026-11-24)

Done now: muted text contrast (light Pencil 0.535, dark Dust 0.765), neutral MCP client wording, unused
brand icon components removed, dialogs named by their visible title, one global keyboard focus ring,
mode menu rows and kit spec differences recorded as deliberate, "Undo to here" (was Restore), console
view colours marked, `npm run smoke` (also in CI), kit.js kept as one file, React rule line for the new
kit parts, Stop-Process kept, strict mode in RepoMap, ChatScope and SecretFiles. Not committed yet.

## Later
- [ ] Tab panels always rendered (decision 6).
- [ ] Motion and wording pass over the app (decision 7).
- [ ] Kit vs spec pass: align or keep each difference listed in the header of `templates/ui-kit/kit.js`.
- [ ] React versions of the 15 kit form and touch parts (listbox, number field, typed fields, password,
      code boxes, address, period, sheet, carousel, reorder, swipe, split panes, disclosure, overflow
      toolbar, breadcrumbs); then drop the React line in `prompts/rules/uikit.md`.
- [ ] `Set-StrictMode -Version 2.0`, one module at a time where tests cover it, fixing what it exposes.
      Not yet: Agent, AppWindow, AutoFix, Cdp, Chain, CheckPolicy, Config, Contrast, CopilotBridge,
      DataImport, DataMirror, DataProfile, DataQuery, Download, EdgeCache, Executor, Fetch, FileActions,
      FileIntake, FixCases, Guardrails, GuiTest, Handoff, Health, Hooks, Imports, Issues, KitTheme,
      Layout, Lint, Log, LoopGuard, Office, OneFile, Packages, PageCompare, PageExport, PageReport,
      PlanFile, PptxChoices, PptxDeck, PptxLayoutMatch, PptxRetheme, Prereq, Progress, ProjectOverview,
      ProjectPackage, ProjectSetup, Prompts, Protocol, Relink, Retention, Review, Runbook,
      RunbookFromChat, RunWindow, Schedule, Server, SessionReport, SharePointLink, SharePointPage,
      ShotDiff, SqlServer, Sso, TaskGuidance, TaskNotes, TestRunner, TestRuns, TidyUp, ToolChecks,
      ToolInstall, UiKit, Update, WebBuild, WebFetch, Workspace, WorkStatus.
- [ ] Keep the stored token with DPAPI (protected for the user) instead of plain text.
- [ ] Document the SharePoint page CSP (what a published page may load).
- [ ] A gzip size budget for the built UI.
- [ ] Schedule form: ask first before it creates a schedule.
