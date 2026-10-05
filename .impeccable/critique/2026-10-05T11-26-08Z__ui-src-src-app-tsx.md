---
target: StreamHub main app
total_score: 25
p0_count: 0
p1_count: 3
timestamp: 2026-10-05T11-26-08Z
slug: ui-src-src-app-tsx
---
# Critique: StreamHub main app (ui-src/src/App.tsx)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Rich status (thinking line, activity, credits, throttle), but 0 aria-live/status regions; the header shows "Switch project", not the project name |
| 2 | Match System / Real World | 2 | Jargon: change set, Work IQ, "Response: as set in Copilot", hooks, chains, beforeDone; help text cites internal folder paths |
| 3 | User Control and Freedom | 3 | Undo, Restore, Stop, Esc all exist; Undo runs on one click while Restore asks first |
| 4 | Consistency and Standards | 2 | Three confirmation patterns (inline Yes/Cancel, "Yes, reset", hold-to-run) plus none on Undo; native selects beside a custom dropdown in one bar |
| 5 | Error Prevention | 3 | Hold-to-run, person-only approvals for M365 and deletes; Work IQ (M365 data access) is a one-click toggle with only a fill as state |
| 6 | Recognition Rather Than Recall | 2 | Icon-only composer tools; ~900-character tooltip explaining the agent picker; Ctrl+K only in a title; 136 Settings controls, no search |
| 7 | Flexibility and Efficiency | 3 | Ctrl+K palette, history, queueing, schedules; no keyboard approve/reject, no batch apply |
| 8 | Aesthetic and Minimalist Design | 2 | Calm chrome, but composer shows up to 8+ controls; prose runs ~2470px wide on a 3440px window; empty state leads with "Limitations" |
| 9 | Error Recovery | 3 | Error notes with code, hint and Copy details; failed actions explain reasons and next step |
| 10 | Help and Documentation | 2 | Help lives in title tooltips (invisible to touch, unreliable for keyboard); no help entry in the palette |
| **Total** | | **25/40** | **Acceptable: significant improvements needed** |

## Anti-Patterns Verdict

LLM assessment: mostly passes. Honest monochrome, flat, dense; no hero metrics, card grids, glass or coloured pills. Three AI-product leftovers in prominent places: the shimmering gradient-text thinking indicator (ai-text-loading.tsx:61), joke loading lines ("Reticulating splines...", lib/thinking-texts.ts), and a gradient mode dropdown darker than the page (ai-prompt.tsx:113). Smaller drift: an em dash in the empty-state limitations list (limitations-note.tsx:15), bg-black/80 command block (action-card.tsx:193), shadows on drawer and palette, and a latent blue --sidebar-primary in dark tokens.

Deterministic scan (npx impeccable detect, 56 files): 9 findings in 3 rules. ai-color-palette x6 (gradient-button.tsx:88-94): false positive in render, the purple variants are dead vendored code, but worth deleting. gradient-text x1 (ai-text-loading.tsx:61): grey, not a palette violation, but it is the same indicator the review flags, so both agree it should go. side-tab x2 (markdown.css:10, 32): blockquote rules in rendered Markdown; the plain quote is acceptable, the callout variant is drift already recorded in DESIGN.md. The detector missed the joke copy, the reading measure, the composer density and every accessibility issue. Browser overlay not run: impeccable live requires PRODUCT.md and would write project files.

## Overall Impression

The visual discipline is real: the Quiet Workbench reads as a calm tool, and colour only ever means content. The losses are not taste but use: density in the composer, jargon, inconsistent confirmations, and accessibility gaps at the exact moment that matters most (approving a command). Biggest opportunity: make the approve/compose loop keyboard-complete, quiet and unambiguous.

## What's Working

1. Approval friction scales with risk: edits are one click with an inline diff, commands need Hold to run, M365 and deletes are person-only.
2. Monochrome discipline: zero-chroma tokens, lifted Graphite dark mode; red and green read instantly because nothing else is coloured.
3. Undo/Restore: change-set cards with per-file counts, "latest: Undo takes this back", Restore names how many sets it undoes, Runs link back with a highlight.

## Priority Issues

- [P1] Hold to run has no keyboard path. hold-button.tsx binds mouse and touch only; it is the only way to approve a command. Fix: hold Space/Enter (keydown/keyup), announce progress, aria-describedby "hold for 1 second". Command: /impeccable harden
- [P1] Prose ignores the reading measure. max-w-[max(48rem,80%)] (App.tsx:620, transcript.tsx:458) lets replies run ~300 characters per line on wide screens. Fix: cap Markdown and user bubbles at ~72ch; let diffs, action cards and the composer go wider (64-72rem). Command: /impeccable layout
- [P1] Inconsistent safety at anxious moments. Undo runs on one click (side-panel.tsx:540, palette) while Restore asks; Work IQ toggles M365 data access with only a fill change. Fix: one confirmation pattern app-wide, or instant Undo with a "Put back" note; a persistent "Using your Microsoft 365 data" label when Work IQ is on. Command: /impeccable harden
- [P2] Composer overload; Send has no priority. 8+ controls, four separate settings decide how one message is handled; Send is the same grey square as Stop and Attach. Fix: group Agent/Response/Clarify into one handling control with a summary line; Send as the solid button; credits/throttle in one quiet meta line. Command: /impeccable distill
- [P2] Loading indicator is decoration. Gradient shimmer plus joke lines for minutes per task, no reduced-motion handling. Fix: plain grey phase text with elapsed time and the activity label; drop the joke lists; respect prefers-reduced-motion. Command: /impeccable quieter

## Persona Red Flags

Sam (accessibility-dependent): cannot approve a command (Hold to run); no live regions, so approvals needed, errors and queue notes are silent; Settings has no dialog role or focus trap; no headings to jump between turns.

Jordan (first-timer office worker): first screen leads with "Limitations: No Git integration, No MCP support..."; header hides the project name; unexplained Work IQ, change set, hooks, chains; Automation help cites folder paths; Settings opens on 136 controls.

Alex (power user): no keyboard approve/reject on the awaiting card; no batch apply; Ctrl+K hidden behind "Menu"; joke loading lines become noise by the third task.

## Minor Observations

- tracking-tighter on 12px composer header text (ai-prompt.tsx:281,284).
- Mode trigger animates on every change (motion without information).
- Dashed borders on the thinking indicator and next steps: a third border style.
- User icon inside the user bubble is redundant.
- Version footer links a raw commit hash; "What's new" reads better.
- Undo wording differs between palette ("before the last message") and History ("change set").
- Create project button at h-12, taller than the 32-40px vocabulary.
- Stale comment side-panel.tsx ("leads to Changes > Issues").
- Global error banner is the only full-width coloured strip.
