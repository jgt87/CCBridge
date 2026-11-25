# Decisions

The settled decisions of StreamHub, one entry each: what the operator decided, and every
deviation from a CommonShared rule. Append; never rewrite an entry. A change of mind is a new
entry that replaces the old one (set the old one's status to `replaced` and add `Replaced by`).
Elsewhere, cite the id (`/* design: D-001 */`, `ui-rules: D-001`, an `acceptRules` reason of
`"D-001"`, "(D-001)" after a line in DESIGN.md or AGENTS.md) instead of restating the decision.
Format and checks: CommonShared docs/09 §8, `templates/scripts/decisions.mjs`.

- **By:** `operator`, or `agent` for a call the operator has not confirmed yet.
- **Rule:** the shared rule it is about, as `<rule file id>:<slug>` (the audit's key) with
  `follows` or `deviates`; left out when no shared rule covers it.
- **Intent** is the goal, worded so another solution could meet it; **Decision** is the
  solution chosen.

Entries D-001 to D-011 were moved here on 2026-11-25 from "(operator, <date>)" stamps in
AGENTS.md, DESIGN.md, `ui-src/src/index.css` and `streamhub.ps1`, from DESIGN.md "Accepted
deviations" and from a `design:` mark; each keeps the date it was first recorded.

## D-001 Fields and bordered controls have a 3:1 edge — active
- Date: 2026-11-16
- By: operator
- Rule: design:every-text-field-is-its-own — follows
- Intent: a place to type or choose reads as one at rest, in both themes
- Decision: every field and bordered control is outlined in Edge (`--input`: oklch(0.62 0 0) in light, white at 38% in dark), at least 3:1 against the surface and the 5% bands it sits on; dividers keep the Hairline (`--border`)

## D-002 On touch, selects and text fields are 44px themselves — active
- Date: 2026-11-16
- By: agent (a `design:` mark in `ui-src/src/index.css`; not confirmed by the operator)
- Rule: ui:coarse-pointer-reach-44px-via-padding — deviates
- Intent: every control reaches 44px on a coarse pointer, also those that cannot carry an invisible hit area
- Decision: buttons, `[role=button]` and tabs reach 44px through an invisible `::after`; selects and text fields (which take no `::after`) get `min-height: 44px` under `pointer: coarse`

## D-003 Secondary text keeps 4.5:1 on every band it sits on — active
- Date: 2026-11-24
- By: operator
- Rule: ui:text-muted-text-and-placeholders-4 — follows
- Intent: secondary text (labels, counts, help) stays readable on the darkest tint or shelf it is drawn on, in both themes
- Decision: light Pencil (`--muted-foreground`) is oklch(0.535 0 0), at 0.556 it was 4.2:1 on the 5% black tint and the Beta tag's shelf; dark Dust is oklch(0.765 0.003 84.6), at 0.751 it was 4.38:1 on a popover's 10% white active row

## D-004 One keyboard focus ring; fields show focus by their border — active
- Date: 2026-11-24
- By: operator
- Rule: ui:one-global-focus-visible-2px-solid — follows
- Intent: keyboard focus looks the same on every control, and a component can still draw its own
- Decision: one 2px `--ring` outline 2px away in `ui-src/src/index.css`'s base layer, inside `:where()`; text fields, selects and text areas are left out and turn their border Ink (Chalk in dark) instead

## D-005 Mode menu rows are 68px — active
- Date: 2026-11-24
- By: operator
- Rule: ui:one-shared-menu-component-rows-32 — deviates
- Intent: each mode explains itself where it is chosen
- Decision: a description line under each mode's name, so the mode menu's rows are 68px tall, above the usual menu row

## D-006 Modals keep the app's own overlay — active
- Date: 2026-11-24
- By: operator
- Rule: ui:dialogs-native-dialog-overlay-on-electron — deviates
- Intent: every modal behaves as a modal dialog to keyboard and screen-reader users, through the one modal part the app already uses
- Decision: `ModalBackdrop`, not a native `<dialog>`: role dialog, `aria-modal`, focus kept inside, the page behind inert, and the dialog named by its visible title (`aria-labelledby`)

## D-007 The console view keeps the Windows console's colours — active
- Date: 2026-11-24
- By: operator
- Rule: ui:components-use-role-tokens-only-bg — deviates
- Intent: a command's output looks like the window it would run in, so a person recognises it
- Decision: `console-view.tsx` draws the console's own colours (#0c0c0c page, #cccccc text, #1f1f1f title bar), the same in both themes, not the app's tokens

## D-008 UI kit differences from the element specs are listed, not yet aligned — active
- Date: 2026-11-24
- By: operator
- Intent: every place the UI kit differs from the shared element specs is known and kept on purpose until it is aligned or confirmed
- Decision: the differences are listed in the header of `templates/ui-kit/kit.js`; the kit-vs-spec pass on the Later list in `tasks/todo.md` aligns or keeps each one
- Revisit when: the kit-vs-spec pass is done

## D-009 The MCP contract stays unchanged — active
- Date: 2026-11-24
- By: operator
- Intent: MCP clients keep working without a change and find the job tools on their own
- Decision: the tool descriptions point to the job tools (`copilot_run_task`, `copilot_ask`); no tool is added, renamed or removed for this

## D-010 A new start stops only the old process, not its tree — active
- Date: 2026-11-24
- By: operator
- Rule: powershell:stop-a-process-with-its-tree — deviates
- Intent: a new start always serves the current files, without ending what the person runs in the old instance's visible run windows
- Decision: `streamhub.ps1` ends the older instance with `Stop-Process` on that one process, never `taskkill /T`, since its child processes include the commands it opened in run windows

## D-011 Strict mode one module at a time — active
- Date: 2026-11-24
- By: operator
- Rule: powershell:entry-slug-ps1-holds-parameters-and — deviates
- Intent: strict mode goes only where tests catch what it exposes, so it breaks nothing in use
- Decision: `Set-StrictMode -Version 2.0` in one module at a time where tests cover it (so far SyncedFiles, RepoMap, ChatScope, SecretFiles); the rest is on the Later list in `tasks/todo.md`
- Revisit when: a further module gets test cover

## D-012 Chat cards show each step's start time — active
- Date: 2026-11-25
- By: operator
- Intent: see when a step ran without hovering
- Decision: a `<time>` in the card header before the duration, showing HH:mm, with the full date on hover; the minute dividers stay
