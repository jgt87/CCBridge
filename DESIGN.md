---
name: StreamHub
description: A quiet grey workbench for directing Microsoft 365 Copilot through code, files and automation.
colors:
  paper: "oklch(1 0 0)"
  ink: "oklch(0.145 0 0)"
  ink-press: "oklch(0.205 0 0)"
  pencil: "oklch(0.556 0 0)"
  shelf: "oklch(0.97 0 0)"
  hairline: "oklch(0.922 0 0)"
  graphite: "oklch(0.18 0 0)"
  graphite-raised: "oklch(0.215 0 0)"
  graphite-float: "oklch(0.225 0 0)"
  graphite-shelf: "oklch(0.285 0 0)"
  chalk: "oklch(0.93 0 0)"
  dust: "oklch(0.745 0 0)"
  signal-red: "oklch(0.577 0.245 27.325)"
  signal-red-night: "oklch(0.704 0.191 22.216)"
  added-green: "oklch(0.596 0.145 163.225)"
  removed-rose: "oklch(0.586 0.253 17.585)"
typography:
  headline:
    fontFamily: "Geist Variable, sans-serif"
    fontSize: "1rem"
    fontWeight: 500
    lineHeight: 1.5
  title:
    fontFamily: "Geist Variable, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 500
    lineHeight: 1.43
  body:
    fontFamily: "Geist Variable, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 400
    lineHeight: 1.625
  meta:
    fontFamily: "Geist Variable, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 400
    lineHeight: 1.33
  label:
    fontFamily: "Geist Variable, sans-serif"
    fontSize: "0.6875rem"
    fontWeight: 500
    letterSpacing: "0.025em"
  code:
    fontFamily: "ui-monospace, SFMono-Regular, Consolas, monospace"
    fontSize: "0.75rem"
    fontWeight: 400
    lineHeight: 1.67
rounded:
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "10px"
  xl: "14px"
  2xl: "18px"
spacing:
  hair: "2px"
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
components:
  button-flat:
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "4px 8px"
    height: "28px"
  button-flat-hover:
    backgroundColor: "oklch(0 0 0 / 5%)"
  button-tinted:
    backgroundColor: "oklch(0 0 0 / 5%)"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "4px 8px"
  button-solid:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.md}"
    padding: "2px 8px"
  input-field:
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "0 8px"
    height: "32px"
    width: "192px"
  segmented:
    rounded: "{rounded.md}"
    height: "32px"
    width: "192px"
  segmented-selected:
    backgroundColor: "oklch(0 0 0 / 10%)"
    textColor: "{colors.ink}"
    rounded: "{rounded.xs}"
  count-chip:
    textColor: "{colors.pencil}"
    rounded: "{rounded.xs}"
    padding: "0 4px"
  change-card:
    rounded: "{rounded.lg}"
    padding: "8px"
  message-user:
    backgroundColor: "oklch(0 0 0 / 5%)"
    textColor: "{colors.ink}"
    rounded: "{rounded.2xl}"
    padding: "10px 16px"
---

# Design System: StreamHub

## 1. Overview

**Creative North Star: "The Quiet Workbench"**

StreamHub is the bench Copilot's work is laid out on. Replies, diffs, file trees, runs and checks are the material; the interface is the grey wood underneath them. Everything the app draws itself is neutral, so the only things that ever carry colour are content: syntax in code, lines added and removed, and errors. A user should be able to read a long reply, scan a diff and approve a command without anything in the chrome asking for attention.

The system is dense and calm. Panels stack in narrow columns with small uppercase section labels, controls sit flat on the surface until hovered, and depth comes from faint tints and hairlines rather than shadows. Both themes are first-class: light is paper and ink for daytime office use; dark is a lifted graphite for long sessions, softened on purpose so long replies do not glare.

It rejects **colourful SaaS dashboards**: blue or purple brand accents, gradient buttons, hero metrics, and coloured status pills. StreamHub sits next to Copilot in the same window and earns trust by staying out of the way.

**Key Characteristics:**
- Monochrome chrome: zero-chroma greys in both themes; colour only as content.
- Flat by default: tints (3 to 15% black or white) and 1px hairlines, never shadows.
- One family: Geist for every UI role, a system monospace for code.
- Dense columns: a left side panel with collapsible sections; one fixed control width in Settings.
- Small, consistent radii: 8px for controls, 10px for cards, 18px for the composer and user messages.

## 2. Colors

A grey scale with no hue, plus three content signals that appear only where they mean something.

### Primary
- **Ink** (oklch(0.145 0 0), light theme) and **Chalk** (oklch(0.93 0 0), dark theme): all primary text and icons, and the one solid button style (Ink fill with Paper text in light; Chalk fill with Graphite text in dark). The solid fill marks a single active choice at a time, for example an enabled "Clarify first".

### Neutral
- **Paper** (oklch(1 0 0)): the light page and every light surface.
- **Shelf** (oklch(0.97 0 0)): light muted surfaces and secondary fills.
- **Hairline** (oklch(0.922 0 0)): light borders and inputs; in practice drawn as black at 10%.
- **Pencil** (oklch(0.556 0 0)): light secondary text, labels, counts, placeholders' darker cousin.
- **Graphite** (oklch(0.18 0 0)): the dark page. Lifted from near-black on purpose: dark mode reads best without the extremes.
- **Graphite Raised** (oklch(0.215 0 0)) and **Graphite Float** (oklch(0.225 0 0)): dark cards, the side panel, popovers and menus, one step above the page.
- **Graphite Shelf** (oklch(0.285 0 0)): dark muted surfaces.
- **Dust** (oklch(0.745 0 0)): dark secondary text (about 8:1 on Graphite).

### Tertiary (content signals only)
- **Signal Red** (oklch(0.577 0.245 27.325); **Signal Red Night** oklch(0.704 0.191 22.216) in dark): errors, failed steps, destructive confirmation.
- **Added Green** (oklch(0.596 0.145 163.225), emerald) and **Removed Rose** (oklch(0.586 0.253 17.585), rose): only in change counts (+N / -N pills) and diff rows. They describe the content of a change; they are never used as UI accents.
- Syntax highlighting uses GitHub's light and dark palettes (`src/styles/markdown.css`); it is content, not chrome.

### Named Rules
**The Colour Is Content Rule.** The app's own chrome never carries hue. Colour appears only when it describes the material: code syntax, added and removed lines, errors. A blue or green button, badge, link or status dot is prohibited.

**The No Extremes Rule.** Dark mode never uses near-black with near-white. Page Graphite (about #121212) and text Chalk keep body text near 15:1, not 19:1; secondary text stays clearly secondary at about 8:1.

**The Tint, Don't Paint Rule.** Hover, selection and grouping are black (light) or white (dark) at 3, 5, 10 or 15 percent over the surface. Never a new grey value, never a colour.

## 3. Typography

**Display Font:** none (product UI has no display role)
**Body Font:** Geist Variable (with sans-serif)
**Label/Mono Font:** ui-monospace, SFMono-Regular, Consolas, monospace (code, paths, diffs, change counts)

**Character:** One quiet, technical sans carries every role; hierarchy comes from weight and a tight size scale, not from a second family. Monospace marks anything a machine reads: code, paths, commands, counts.

### Hierarchy
- **Headline** (500, 16px, 1.5): the empty-chat question and the Settings window title. Rare.
- **Title** (500, 14px, 1.43): tab names, card titles, bold lead-ins in notes.
- **Body** (400, 14px, 1.625): chat replies and messages (Markdown); prose keeps a 65 to 75 character measure in the centred chat column.
- **Meta** (400, 12px, 1.33): help text, timestamps, summaries, buttons in dense rows, helper notes.
- **Label** (500, 11px, 0.025em, uppercase): section headings in the side panel and Settings groups ("CHECKLIST", "RUNS", "THIS BROWSER").
- **Code** (400, monospace, 12px in diffs and code views; 0.9em inside replies).
- **Tag** (400, 10px, uppercase, wide tracking): the "Beta" tag and count chips only.

### Named Rules
**The One Family Rule.** Geist for every UI role, monospace for machine text. A display or serif font is prohibited.

**The Small Caps Are Signposts Rule.** Uppercase is reserved for section labels and tags. Never uppercase a button, a title or a sentence.

## 4. Elevation

StreamHub is flat. There is no shadow vocabulary: surfaces separate by tonal steps (Paper to Shelf; Graphite to Graphite Raised) and 1px hairlines at 10% black or white. The only overlays are the modal backdrop (black at 40% with a light blur) and menus, which sit on Graphite Float or Paper with a hairline. A single `shadow-sm` appears on the solid button; it is the exception, not a pattern.

### Named Rules
**The Flat-By-Default Rule.** Surfaces are flat at rest and in every state. Depth is a tint or a hairline. If a panel needs a shadow to be told apart from the page, its tint is wrong.

**The No Glass Rule.** The modal backdrop is the only blur. Blurred or translucent panels are prohibited.

## 5. Components

Flat and unassuming: controls look like part of the page until you need them.

### Buttons
- **Shape:** gently rounded (8px); small icon buttons 4px.
- **Flat (default):** no fill, Ink or Pencil text, 12px Meta type, 4px by 8px padding. Hover adds a 5% tint (white 5% in dark) and lifts Pencil text to Ink.
- **Tinted:** the default action in a row (Create, Send answer): a 5% tint at rest (10% in dark), 10% on hover.
- **Solid:** Ink fill with Paper text (inverted in dark), for the one active choice; hover at 85% opacity.
- **Disabled:** 40% opacity and no hover tint.
- **Bordered (Settings):** a 1px hairline, 32px tall, one fixed width (192px) so every control column lines up.

### Chips
- **Count chip:** 10px tabular numbers in Pencil inside a 1px ring at 10%, 4px radius, beside section labels.
- **Beta tag:** the same ring, uppercase 10px.
- **Change pill:** a split monospace pill, Added Green "+N" and Removed Rose "-N" on 15% tints of their own colour. The only coloured chip in the system.

### Cards / Containers
- **Corner Style:** 10px for change-set and action cards; 18px for the composer.
- **Background:** transparent with a 1px hairline (10%), or a 3 to 5% tint for grouped detail.
- **Shadow Strategy:** none (see Elevation).
- **Highlight:** a card being pointed to (from Runs) shows a 40% border and a 5% tint for 2.5 seconds.
- **Internal Padding:** 8px for list cards, 12px for panel sections.

### Inputs / Fields
- **Style:** 1px hairline, transparent fill, 8px radius, 32px tall, 14px text.
- **Focus:** the border darkens to 30% (black or white); no glow, no colour ring.
- **Composer:** a 5% tinted well with 18px outer radius; placeholder at 70% (light) or 50% (dark).
- **Segmented choice:** a bordered strip, the selected option on a 10% tint (15% in dark); used for every on/off and small set of choices in Settings.

### Navigation
- **Side panel tabs:** a two-column grid of tab buttons (Files, Automation, History, Actions, Code health); the selected tab sits on a solid tint pill; icons at 14px beside a 14px Title label.
- **Panel sections:** a 36px header with a rotating chevron and an uppercase Label; collapsed sections show a one-line Meta summary.
- **Top bar:** product name, Switch project, the Copilot state as plain text with a small icon (never a coloured pill), Settings and Menu as flat buttons.

### Transcript (signature)
- **User message:** right-aligned, 5% tint (10% in dark), 18px radius with a 2px top-right corner.
- **Copilot reply:** no container at all; Markdown on the page in Body type.
- **Action cards:** a hairline card per step with a 16px Pencil icon; diffs inside use hairline tables, line numbers in Pencil at 75%.
- **Notes:** one line with a 16px icon; errors in Signal Red; required human action on a 5% tint with a 20% border.

## 6. Do's and Don'ts

### Do:
- **Do** keep all chrome on the zero-chroma grey scale (Paper, Shelf, Hairline, Pencil; Graphite, Graphite Raised, Graphite Shelf, Dust, Chalk).
- **Do** express hover, selection and grouping as black or white at 3, 5, 10 or 15 percent.
- **Do** separate surfaces with 1px hairlines at 10% and one tonal step, never with shadows.
- **Do** keep dark-mode body text near 15:1 and secondary text near 8:1 (Chalk and Dust on Graphite).
- **Do** use the 192px control width and 32px height for every Settings control so the columns align.
- **Do** keep colour for content only: syntax, Added Green / Removed Rose change counts and diff rows, Signal Red errors.
- **Do** show state as plain words with a small grey icon ("Copilot connected").
- **Do** let native controls follow the theme (`color-scheme: dark` under `.dark`, options on the popover colors); a native select list is drawn by the browser, not by the page's classes.

### Don't:
- **Don't** make it look like a colourful SaaS dashboard: no blue or purple accents, no gradient buttons, no hero metrics, no coloured status pills.
- **Don't** use blue or green as an accent anywhere in the chrome; green exists only as "+N" added lines.
- **Don't** use near-black with near-white in dark mode, and don't add surfaces darker than the page (no `bg-black` panels in dark).
- **Don't** add shadows, glass or blur to panels; the modal backdrop is the only blur.
- **Don't** use `border-left` or `border-right` wider than 1px as a coloured or grey stripe on cards, notes or alerts. (Markdown callouts in replies still use a 3px left rule; that is existing drift to replace with a full tint, not a pattern to copy.)
- **Don't** introduce a second typeface or uppercase anything but section labels and tags.
- **Don't** wrap a Copilot reply in a card; replies sit directly on the page.
