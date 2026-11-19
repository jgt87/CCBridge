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
