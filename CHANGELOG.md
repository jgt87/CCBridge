# Changelog

All notable changes to StreamHub are listed here, newest first.

## [Unreleased]

Nothing yet.

## [v0.1.119] - 2026-10-10

### Added
- A project from an older kit gets the newer kit at open, not only at its next kit task: the catalogue, the kit files the pages use that the project had not changed, and its `styles/kit/tokens.css`: tokens the file lacks are added, a value still equal to the old default takes the new default, a value you changed yourself stays (light-only files get no dark block). Both as StreamHub change cards.

### Changed
- "Apply the UI kit" and "upgrade the kit" count as coding tasks in a project with code (apply and upgrade are change words, the UI kit a part of the app).
- The run instruction tells Copilot never to run syntax checks such as `node --check`: StreamHub checks every changed file itself.
- The changelog link in the app's bottom-left corner always opens the changelog on the main branch, so it also shows releases newer than the build.
- A StreamHub change card shows its summary once: the summary is the card's own line, the details are the output.

### Fixed
- The page check reported the browser's own request for `/favicon.ico` as a problem of the page when the load failed outright, which sent Copilot into adding an icon link and a failing edit loop.
- The "SEARCH text not found" error printed its closest current lines after two backticks and an "n" instead of a code fence.
- `node --check styles/kit/kit.js` (or any run of a JavaScript or Python script) was refused as deleting files: the script's text was read as a command line, where a DOM `remove()` looked like a delete and `//` like a path. Scripts are checked as code only; a script that really deletes outside the project is still refused.
- A page part Copilot wrote with its tags as entities (`&lt;div&gt;` throughout, not one real tag), copied from the escaped prompt, was written as is and the browser showed the markup as text. It is turned back into tags; real entities in a code sample and Markdown are left alone.

## [v0.1.118] - 2026-10-10

### Added
- UI kit: an app shell (band header, side navigation that folds behind a menu button on a narrow screen, content), format helpers (`KitUI.format.number`, `percent`, `date`, `relative`, following the page's language, dates always as "9 Oct 2026"), row selection on tables (`data-kit-select`: a checkbox column, select all, a bar with the count and the actions for the picked rows), a busy state for buttons (`aria-busy="true"`) and forms, and a scatter chart (`data-kit-chart="scatter"`).
- Blue shades in the kit's tokens: `--kit-palette-blue-1` to `-3`, the vivid blues `--kit-palette-light-blue-3` to `-5`, and `--kit-accent-tint-1` to `-3` (the accent over the surface at 8, 16 and 32 %); in the light theme titles (kit-h1 to h3, panel titles) and icons are the blue (`--kit-title`, `--kit-icon`), bars and other first-series chart parts the light blue `#019adc` (`--kit-chart-1`), and text on any blue (a primary button, the band, a band block) is white, titles and icons included; the contrast check measures the new pairs.
- Tests of the kit's behaviour in a browser-like document (`ui-src/src/lib/kit-ui.test.ts`), and a check that neighbouring chart colours tell apart.
- The release build refuses a version that is not in CHANGELOG.md; the changelog has the entries of v0.1.112 to v0.1.117 again.

### Changed
- UI kit accessibility: a solid focus ring visible on any background (the old halo was 1.6:1), white text on the header band at 4.5:1 (the band starts in a darker light blue, and the check measures it), placeholder text readable, invalid, disabled and read-only fields, a pressed state on buttons, focus on tabs, segmented buttons, navigation and menu items and the drop zone, legend entries big enough to click, screen-reader roles for named groups, the search box as a combo box, tabs with the arrow keys, charts with buttons announced as groups and keeping focus across a redraw, the calendar as a group of day buttons.
- UI kit tables: the header row is one piece (titles left, numeric columns right with the sort arrow after the title, the same fill in every header cell, also the sticky first column); the search box splits on spaces (it split on the letter "s"); numeric columns sort numbers as people write them (1,234.56, 1.234,56, 41,7 %, (1,234), empty cells last); the empty-state row shows by itself when a search leaves nothing; paging no longer moves every row; a paged table prints all its rows.
- UI kit charts: a value that is not a number leaves a gap in a line instead of blanking the chart, a chart with values below zero gets an axis below zero, a chart that cannot be drawn says so and leaves the next chart alone, rings, gauges, heat maps and sparklines have empty states, a colour by meaning works on gauges and sparklines, horizontal bars give long labels room and shorten them with the whole name on hover, resizes are drawn once per frame without the grow animation.
- UI kit layout on a phone: tabs scroll sideways instead of widening the page, the tip bubble and the multi-select panel stay on the screen; `hidden` always hides a kit block; print styles keep buttons, tabs and toolbars off paper and boards whole.
- The kit keeps to its own tokens (sizes, corners, speeds, backdrops) and chart colours are ordered so neighbours differ in hue; the neutral preset's dark chart colours too.
- The icon rule says where icons belong (toolbar and row actions, the menu button, navigation items, notices, empty states; the same icon for the same action everywhere); the one-file and light-only rules no longer contradict the kit rule; the kit's scripts are safe to load twice and one broken part no longer stops the rest.
- Kit delivery: one pruned file walk per update (never into node_modules), classes the kit's scripts write at run time copied only for the parts a page has, icons chosen in code found, template file types scanned, keyframes kept by prefix.
- The data reader guesses the CSV delimiter from the first ten lines, strips a byte order mark, reads ISO dates with a zone, and `KitData.toCsv` takes a delimiter (`;` for Excel on a Dutch or German computer).
- React kit parts: a board card drops where it was dragged, a chart redraws only when its data changed, tabs take the arrow keys.

### Fixed
- The colour guardrail no longer reports ids that look like colours (`#add`, `querySelector("#fab")`), and does report colours set from code in a page's own script and in CSS-in-JS.
- A table search box filtered on the letter "s" instead of spaces.

## [v0.1.117] - 2026-10-09

### Added
- Helpers for Copilot: every project with a window app gets `styles/kit/wpf/KitWpf.ps1`, with functions for the window, tables with search, bar lists, file pickers, CSV/TSV/JSON import and CSV export, background work that keeps the window responsive, shortcuts, timers, saved settings and one copy of the app at a time. Copilot's instructions list what a window app can have and which helper does it.
- UI kit look, when the kit is on: the WPF theme covers more controls (tabs, menus, lists, tree views, date pickers, sliders and more), and a Windows Forms app gets a matching theme. With the kit off, the app keeps the Windows look and still gets the helpers.
- Alignment and uniform sizes, written into the app: Copilot marks panels as a row, an action bar or a form, and StreamHub writes the matching layout into the window's XAML. Buttons and fields get one height, field widths come from one scale (120, 240, 360), and fields above each other are the same width.
- More tests of the window: after a change, StreamHub opens the app and:
  - runs the steps of its `.guitest` file (click, type, select, expect);
  - catches error messages the app shows;
  - checks that controls have names for screen readers, are big enough to click and are not cut off;
  - measures what does not line up.

  Checks of the XAML catch centred fields, controls placed by coordinates, controls with their own heights and odd widths.
- A missing or wrong launcher (`.cmd`) is reported. On computers where a company policy runs scripts in Constrained Language Mode, Copilot is told a window app cannot run there.

### Fixed
- What the window test reports no longer contains your user folder, account or computer name; paths inside the project are shown relative.
- The probe test tool's report is masked the same way.
- A new repository test keeps personal paths and names out of everything the repository publishes.

## [v0.1.116] - 2026-10-09

### Added
- Built-in builder for React and TypeScript (Settings > Checks and issues > Built-in builder): on a computer without Node.js or npm, StreamHub builds the app itself in a hidden Edge tab (esbuild and TypeScript ship with StreamHub), after every change to `src/`. The app runs from `dist/app.js`, also when the page is opened from disk; build errors and TypeScript type errors go back to Copilot with file and line. `Scripts/Build-App.ps1` builds the app while StreamHub is closed. React, ReactDOM and the JSX runtime are included; other npm packages are not available this way.
- SQL in the page (UI kit, on): `KitSql` turns the page's data into tables to query with SQL (SQLite through sql.js); works from disk too.
- Python in the page (UI kit, off by default, 13 MB): `KitPython` runs Python with its standard library on the page's data (Pyodide); works when the page is served (Open app).
- PowerShell apps with a window (WPF): rules for Copilot, the UI kit's look as a WPF theme made from the project's colours (buttons, fields, sortable tables, progress bars, titles, panels), checks for what stops a window from opening or breaks its look, and a start test at the end of a task that opens the window, takes a picture of it for Copilot and closes it.
- Cards while StreamHub runs something itself: the build, the type check, each tool check and the window test show as running, then their result.
- The page check also reports a chart that draws nothing, a table with no rows and no empty-state message, an error message the page shows, and (as a warning) a page that scrolls sideways at phone width, naming what causes it.
- A page or script that uses a data name no data file defines is reported, with the names that exist.
- The project's own build and check tools at the end of a task, when they are installed: TypeScript (tsc), C# (dotnet build), Go (go vet), Java (javac) and PowerShell (PSScriptAnalyzer). Their errors go back to Copilot.

### Fixed
- The UI kit's period filter and icon toolbar wrap on narrow screens instead of making the page scroll sideways.

## [v0.1.115] - 2026-10-09

### Fixed
- A page Copilot writes in one go is no longer refused when a script tag arrives damaged on the way (only `data/file.jsscript>` left of `<script src="data/file.js"></script>`): StreamHub puts the tag back and writes the page. Before, the refusal could send Copilot into workarounds.
- A command that ends with exit code 0 but printed PowerShell errors now counts as failed, and the card and Copilot are told which error it was. Before, a script that broke halfway looked successful.
- `DataTools.min` and `DataTools.max` work on date columns (the earliest and latest date, as stored) and on very long lists. Before, `max` of a date column gave nothing, which could stop a dashboard from loading. Projects get the new data tools by themselves.
- Bars in a track are round at both ends again: bar lists, progress bars and status bars. Only bars drawn against a chart axis stay flat at the axis. Projects get it with the next kit update.

### Added
- Pages whose tags are written with stand-ins (such as `[[LT]]div>`) or escaped as a whole are reported and repaired into real tags; a script that generates a page with stand-ins is reported, and Copilot is told to write the page itself.
- PowerShell code that calls `.Replace('text', [char]60)` (which Windows PowerShell rejects) is reported before it runs.
- While StreamHub converts a data file for Copilot at the start of a request, the chat says which file and the waiting indicator shows it.

## [v0.1.114] - 2026-10-09

### Added
- UI kit dashboard parts (Settings > UI kit > Dashboard parts): a side panel for row details, short confirmations (toasts), info tips, loading placeholders, trends on key figures ("+4.2% vs last month", coloured by whether it is good or bad), a filter for several values with search, a period filter (last 7 or 30 days, this week, month, quarter or year, custom dates), a search box over a table, a totals row, a fixed first column and a "Data as of" line (filled in by StreamHub for one-file pages).
- More components (Settings > UI kit > More components): switch, dropdown menu, icon toolbar, avatars and avatar groups, breadcrumbs, stepper, collapsible sections, key and value list, timeline, sliders (also for a range), tag input, kanban board, calendar month, bento grid, changing loading text and a success check. The switch, menu, toolbar, avatars, bento grid and success check are adapted from kokonutui, on the kit's colours and with calm motion. On a phone the side panel opens from the bottom.
- React versions of all of these for React projects.
- Tailwind CSS (Settings > UI kit > Tailwind CSS): in a project that uses Tailwind, the kit's colours, sizes, corners and shadows become Tailwind names (bg-kit-accent, text-kit-muted, rounded-kit, p-kit-4 ...) that follow the colour preset; Copilot builds components from the kit and uses Tailwind only with those names, and Tailwind's own colours, made-up values, gradient text and blur are reported.
- Charts: dashed target lines on bar, line and area charts, 100% stacked bars, and KitCharts.palette for code that draws its own charts. Every chart with more than one colour uses the preset's chart colours.
- Print styles (Settings > UI kit > Print styles, Print page orientation): pages print cleanly, without buttons and filters, with panels and charts kept whole, in the light theme; a print button needs only data-kit-print.
- Settings for the first day of the week (period filter, calendar) and for dark mode.
- Guards for what a page shows: text with broken characters (such as "14-27 days") is found and repaired, a page without `<meta charset="utf-8">` gets it, and PowerShell scripts that read or write files without -Encoding are warned about. The page check in Edge also reports broken characters, a bar next to a percentage that does not fill to it, and a table whose columns cannot be sorted.
- A look you ask for wins: when a follow-up asks to change how something looks (colour, size, corners, font, dark mode ...), Copilot does exactly that even where it differs from the kit, marks it, and keeps it in later work; the kit's look checks rest for that change.

### Changed
- Apps and dashboards are light only by default: no dark mode and no light/dark switch unless you ask for one, or choose it in Settings > UI kit > Dark mode in apps.
- Every table can be sorted by its columns, also tables a script writes after the page loaded; a kit progress bar fills itself from aria-valuenow.
- Chart bars are flat where they meet the axis (also in bar lists and in charts Copilot draws itself); progress and status bars are round at both ends.
- Opening a project no longer converts its CSV and Excel files: that happens when a request needs them, and the open answers at once. Choose a project shows which project is opening.

### Fixed
- The kit's hidden chart data tables could make a page a little wider than the screen.

## [v0.1.113] - 2026-10-09

### Added
- Project setup: when a new project's first request builds a page, dashboard, report or app without saying how, StreamHub first asks how to build it: one HTML file, separate files (styles, scripts, data), or let Copilot decide. A request that already says it ("in one file", "separate files") is followed without asking. The choice is kept for the project, goes with every task, and can be changed under Files > Project setup.
- Live data: a project with data can follow a file outside the project, for example a CSV in a SharePoint folder synced by OneDrive. StreamHub only reads that file. It copies it into `Source/Live/` whenever it changes: when the project opens, when a task starts, once a minute while idle, and every time a page opened with Open app loads or reloads it. `Scripts/Refresh-Data.ps1` does the same while StreamHub is closed.
- One-file pages: StreamHub fills the kit styles, kit scripts, icons and data into marked blocks of the page (`data-streamhub="kit"` and `data-streamhub="data"`), so the page works opened straight from disk. Copilot never sees or edits those blocks; the rest of the page is edited as usual.
- Choose a project has a Refresh button that reads the projects folder again (names, sizes and file types).

### Changed
- File reads, search, file checks and code review leave out the blocks StreamHub fills in one-file pages; an edit that would change such a block is refused with an explanation.

## [v0.1.112] - 2026-10-09

### Added
- UI kit bar lists and rings take colours by meaning on their items: `"color": "ok"`, `"warn"`, `"error"`, `"muted"`, `"accent"` or `"chart-1"` to `"chart-6"` (always kit colours; a colour of a page's own is not used). The legend follows the same colours.
- Bar lists show each value with its share (`"share": true`, `"total"` for the share of something other than the sum) and draw a funnel with `"base": "first"` (every step against the first).
- A bar chart can draw a series as a line over the bars (`"type": "line"`), on its own scale at the right with `"axis": "right"`: for example a running total next to the counts per date.
- Key figures can carry their share as a bar under them (`kit-progress kit-figure__bar`, with `kit-progress--ok`, `--warn` or `--error`), and a list box that holds an active filter can show it (`kit-select is-active`).
- Tables with thousands of rows: `data-kit-rows="external"` lets the kit draw the sort buttons and the pager while the page writes only the rows shown; `kit-table-wrap--scroll` keeps the header row in view while the table scrolls.
- A light/dark switch in the UI kit: a button with `data-kit-theme` follows the computer's setting until clicked and remembers the choice.
- Export the rows shown as CSV with `KitData.toCsv` and `KitData.download` (opens correctly in Excel).
- The kit's examples page shows all of these: coloured bar lists with shares, a funnel, a ring with colours by meaning, a bar chart with a running total, key figures with bars, a 5,000-row table and the theme switch.

### Changed
- Copilot decides which data to show and in which form (any kind of chart, table or list, vertical bars included); with the UI kit on, the kit's rule only makes sure the chosen element looks like the kit, with the kit part for that form. The design rules no longer limit when a chart may be used either.
- The UI kit check also reports a table, button, field, list box, text area or dialog written as markup inside a script (for example for innerHTML) without its kit class.

### Fixed
- Panel titles in the UI kit have their own size, instead of the browser's large heading size.
- A project that has a whole copy of an older kit.css in `styles/kit/` gets the current one (with only the rules its pages use) when the kit is updated; a kit.css the project changed itself stays.

## [v0.1.111] - 2026-10-08

### Changed
- Choose a project shows a folder pasted into the projects folder without reopening it: while it is open it looks for new, removed or changed folders every few seconds and when the window gets focus (names and times only, `/api/projects?quick=1`; the full list with sizes and types only when something changed).

## [v0.1.110] - 2026-10-08

### Added
- UI kit charts: stacked bars (`"stacked": true`), a bar list for long category lists (`data-kit-chart="barlist"`: label, bar and value per row, with Show all past a limit), and a ring legend with each value and its share (`"legend": "values"`). With `"selectable": true` a click on a bar, ring part, list row or legend item filters the page: the chart sends `kit:select` and the page draws every chart again with what is picked; the rest fades. The React Chart part has `onSelect`.
- UI kit pieces for dashboards: filter chips (`kit-chips`, `kit-chip`), a filter bar that stays at the top (`kit-panel--sticky`) and a chart grid (`kit-grid--charts`, `kit-grid__wide` for a chart across the row).
- The kit's examples page starts with the gradient header band and has a dashboard example (invented city bike rentals): filter bar, key figures and a grid of charts that filter each other on a click.
- Sortable tables with pages in the UI kit: `data-kit-sort` on a kit-table makes every header a sort button (numbers in a kit-num column sort as numbers, `data-sort` on a cell sorts dates or formatted numbers by their value), and `data-kit-pages="N"` shows N rows at a time with Previous and Next under the table. Rows the page writes again are sorted again. The examples page shows both, and a table's empty state.

### Changed
- The UI kit rule for Copilot names the gradient header band (`kit-header--band`) as the header of every app and dashboard page, asks that anything a page draws itself takes its colours from `--kit-chart-1` to `--kit-chart-6` in order with the kit's legend and tooltip classes, points to the dashboard example, and lists every kit class (also section, title and spacer classes it left out).
- The file check after each change, in a project with the UI kit, also reports colours written into markup (style attributes, colour attributes, style blocks) and into scripts (colour strings, for example in chart settings or canvas code), and a chart library added to a page, script or package.json (it brings its own colours; the kit has charts). The kit's own files are left alone.
- In a project with the UI kit, the file check also reports a table, button, field, list box, text area or dialog a change adds without its kit class, and fonts, font sizes, shadows and rounded corners written into styles instead of the kit's tokens. In any project it reports an emoji used as an icon in a button, heading, label or link (with the kit: use a kit icon).
- When Copilot reports a task as done and a page it changed shows a table or draws a chart without an empty state, StreamHub reminds it once to add one (with a loading and an error message for data that loads).
- Copilot always knows what the UI kit offers in a project that uses it: every task's project context lists the kit's parts with the lines of their example in the catalogue (`.streamhub/ui-kit/kit-examples.html`) and the classes each uses, the kit's scripts with what each does (tables with sorting and pages, charts, icons, file readers), the React parts in a React project, and the kit files the project already uses. The kit's rule says the kit comes first for every piece of interface, in a fixed order, that Copilot never builds its own version of a kit part and names any part that was missing, and it also goes with any change or fix to a web project that has the kit, not only with interface requests.
- The UI kit rule names the kit's type sizes, corners and shadows, asks for an empty state for every table, list and chart, and says never to use an emoji as an icon.
- Bars in the kit's charts are rounded only at their outer end, so they stand on the axis; in stacked bars only the top part.
- A project's UI kit catalogue is updated to a newer kit when StreamHub brings one: the catalogue's files (not the project's colours) and the kit files the pages use that the project did not change; a change card in the chat says which.

### Fixed
- A project with the UI kit no longer counts as a React project because of the React parts in the kit's catalogue.
- Links and buttons in the gradient header band take the band's text colour, instead of the link colour on the gradient.
- A ring chart sits centred above its legend, draws nothing for an item at 0 (keeping the colours of the items after it), and shows a full ring for a single item.

## [v0.1.109] - 2026-10-08

### Fixed
- Opening a submenu of Copilot's response picker (GPT > the models) also tries the Right arrow key on the entry, the way these menus open by keyboard, when pointing at it and clicking do not open it.

## [v0.1.108] - 2026-10-07

### Changed
- Every step card in the chat (read, search, edit, run ...) now starts expanded, not only Write and Edit. Settings > This browser > Cards has Auto-collapse instead: a card folds up to one line once its step is finished, while cards waiting for approval, running or failed stay open. The earlier "Collapsed" choice becomes Auto-collapse.
- The Automation tab says less: each section (Runbooks, Scripts, Hooks, Chains) has one short line, and the details (where the files are, approvals, examples) are behind an info button that shows them in a box on hover, focus or a click. The empty-state lines are shorter too.

## [v0.1.107] - 2026-10-07

### Added
- Every option of Copilot's response picker: when StreamHub connects it reads what the picker offers on your tenant, including entries in a submenu, and the Response menu next to New chat lists them besides Auto, Quick and Think deeper (for example Advanced reasoning (Experimental) or a model such as GPT-6.1 Sol). The choice is saved by its menu path and picked by its name before each message, so new or renamed options need no StreamHub update. test-tools\capture.cmd has a step that records the open picker and its submenu, should a tenant build it differently.
- The response options are kept and read again weekly: StreamHub saves what the picker offers and reads it again when it is older than Settings > Copilot > Re-read response options (days), default 7, when it connects or while it is idle. Settings > Copilot shows when they were last read and which options there are, with Read now to read them at once (the result also shows in the chat).

## [v0.1.106] - 2026-10-07

### Added
- The task worker restarts itself: when the part of StreamHub that runs tasks stops on an unexpected error, it is started again (at most five times in ten minutes) instead of StreamHub stopping. The task that was running is marked failed (its changes can be undone), an error card says what happened with an error id, Copilot is connected again and the queue carries on.
- The install is checked at every start: a release now lists every file with its checksum (`manifest.json`), and StreamHub compares its folder with it. Files missing or different from the release (an update that stopped halfway) are repaired by installing the same version again, also by update.cmd when the version is already the newest. If that cannot be done, a banner in the app names the files and what to do.
- Settings > Retention: page screenshots. The page check's screenshots in `.streamhub/Screenshots/` (each with its layout file and the close-up of the changes, which count as one) are kept to the newest 60 and 30 days by default, like task reports; other images there are never touched.
- Updates use the newest updater: once a release is downloaded, its own updater does the install when it differs from the one installed, so a fix to the updater applies with that same update instead of one later (from the update after this one).
- An update never leaves two versions mixed: before copying, every file it replaces or removes is backed up, and a copy that fails halfway puts the previous version back whole (and removes the files it added). The message says so; the update runs again at the next start.

### Fixed
- The side panel's tab buttons (Files, Automation, History, Actions) line their icons up: each icon sits as far from its button's left edge as the icon of the widest tab, whose icon and title stay centred.
- The console view on run cards keeps to the newest line while a command runs, like a console window, instead of staying at the top once the output is longer than the view; scrolling up to read stops the following until you scroll back down. Finished output opens at its last lines, where errors usually are.

## [v0.1.105] - 2026-10-07

### Added
- Commands are visible while they run: the run card shows the output as it comes in a console view (black, Consolas), with the time it has been running. Finished runs use the same view. When a command shows no output for 30 seconds the card says so, and whether it still uses the processor or seems to wait for something; when its last line asks a question (`(y/N)`, "Enter a name:", "Press any key") it says that nobody can answer it here. This covers Copilot's commands, scripts, hooks, npm install and the project's verify command and tests (shown under the waiting indicator). StreamHub's own file checks show which file they check, and when `prisma validate` runs.
- Open in a window: a run card has a button that runs the command again in its own console window in the project folder, where you can watch it and answer its questions (for example `prisma migrate dev`). It is offered more prominently when a command needed a terminal or seems to ask something. The card follows the window and records the exit code when the command ends; the output stays in the window. Deleting or moving outside the project is refused here too, and Source/ is put back afterwards as after any command.
- The before/after check says where a page changed, in words and close up: each changed area separately (up to four), with its place on the page (top left, bottom right...) and the parts of the page it is in, such as "in footer, around button#export 'Export'" or a heading's text. The page check records where the page's headings, landmarks and named elements are with every screenshot. Copilot also gets one image of the changed areas with before on the left and after on the right, so it can check that it changed the right part and nothing else; the chat links the image.
- More Windows PowerShell 5.1 traps in the code Copilot writes, reported as likely mistakes with the fix: a foreach loop variable that overwrites a parameter differing only in case (`$to` and `$To`), `$Matches` read after a `-match` whose result is not checked (it keeps an older match), a function that returns its list with a leading comma called inside `@(...)` (a list inside a list), `.Count` on what can be a single object from Import-Csv, ConvertFrom-Json or Select-Object (no `.Count` in 5.1), and a function named like a built-in cmdlet. Copilot's PowerShell rules name the same traps, so it avoids them in the first place.
- Parameter names travel with a part of a PowerShell script: when Copilot reads only some lines of a .ps1 or .psm1, or gets the changed lines back after an edit, and the function's header is not among them, StreamHub adds one line naming the function those lines are in, its parameters and the script's own parameters, with the reminder that variable names ignore case. A variable that still overwrites a parameter is reported with all of that function's parameter names, so the new name does not collide either.

## [v0.1.104] - 2026-10-07

### Fixed
- The StreamHub tab did not open next to Copilot when another local web app was open in StreamHub's Edge on an address without a port number (`http://localhost/`): StreamHub took that tab for its own and brought it to the front instead. Only a tab on StreamHub's own port counts now.

## [v0.1.103] - 2026-10-07

### Fixed
- An automatic update no longer fails halfway when a file it would replace or remove is open in another program (for example a test tool's window still waiting at "press any key"). StreamHub now checks for such files before copying anything. An open file with the same content as the release, or one the release no longer has, is simply left as it is. Only an open file that really changes holds the update up: then nothing is copied, the current version keeps running, and the message names the files and what to close; the update runs at the next start. If a copy still fails, the message names the files robocopy could not copy. The copy also retries a little longer.

## [v0.1.102] - 2026-10-07

### Added
- Checks when a task ends without "done": when Copilot stops before reporting a task that changed files as done (the round limit, a reply without actions, Copilot stopping), StreamHub runs the done step's checks anyway: problems the task added to its files, the page check and the script check of changed pages, and new files that nothing loads. A card says Copilot did not finish, lists what was found and has Continue, which sends the findings back; the task report records it.
- Page errors hold up "done": JavaScript errors the page check still finds after Copilot's fix are sent back within the same number of tries as other errors (enforcement). If they are still there when the tries are used up, the chat shows them as an error and the task report says Copilot said done anyway.
- New files that nothing loads: a script or stylesheet written in a task that no page, script or stylesheet loads (by the import index, or named anywhere in the project) is sent back once at "done": add it where it is needed, or delete it. Tests, configs, tools, build output, data copies and the UI kit are left out.
- The UI kit's tokens used without loading them: a page that uses `var(--kit-...)` (itself or through a stylesheet it links) but loads no `tokens.css` is reported with the exact `<link>` to add; a project that imports `tokens.css` from its code counts as loading it. And `var(--name)` without a fallback where nothing in the project defines `--name` is reported as a likely mistake, with a close name when there is one (common library prefixes such as `--tw-` and `--bs-`, and pages that load stylesheets from the web, are left out).
- Edits to the UI kit's own files (`styles/kit/` other than `tokens.css`) get a note to Copilot to restyle through the tokens, its own stylesheet or the component's options instead, and are listed in the task report.
- HTML tags written escaped in scripts (`'&lt;span&gt;Join&lt;/span&gt;'` in a `.js` file or a page's `<script>`): the page shows them as text instead of making them. They are reported, and the fix-up step writes them as tags; escape functions (`'&lt;'` on its own) and template blocks are left alone.
- A helper script in `Work/` or `Scripts/` that writes a whole copy of a page gets a warning: running it again later undoes every change made to the page since.
- Disputing a check needs a one-line reason, and size and complexity findings (a measurement) cannot be disputed: split the code, or say why in the done summary.
- The task report says "the page check passed" instead of only "Verify: not configured" when there is no verify command.
- Fix case logs: every problem that needed more than one try, fixed or not, gets its own file in `.streamhub/FixCases/`: the problem, the request and the change that brought it (a diff), every try with Copilot's diagnosis and what was still there after it, the outcome and the StreamHub version. This covers fix tasks (tries 1 to 3) and file-check errors still there after Copilot's next change within a task. The chat links each case, the main log notes it, and Export diagnostics collects them (they contain code lines), so the checks and rules can be improved to catch or prevent such problems.
- The log says which build wrote it: every process (web app, MCP server, a ping) starts each log file it writes to with a line naming StreamHub's version and commit, its role and PowerShell's version (`StreamHub v0.1.102 (commit abc1234) (web app), PowerShell 5.1...: lines with process 1234 come from this build`). That holds after midnight (a new day's file) and when several processes write to the same file, so a log shows which version a problem came from.

## [v0.1.101] - 2026-10-07

### Changed
- Fix attempts for detected issues go further each time instead of repeating the same request. Attempt 1 lists the problems as before. Attempt 2 asks Copilot to find the cause before changing anything, in Think deeper, with evidence StreamHub gathers: the file as it is now around each problem (whole blocks), a map of the brackets still open at the problem line and where each one started, what the previous attempt changed (a short diff), and the lines in other files that use the file; Copilot starts its reply with a Cause: line. Attempt 3 starts a new chat (earlier attempts' context can anchor the wrong idea), in Think deeper, with the earlier diagnosis and how the file differs from the last version without the problem, and asks to rebuild the broken part from that version instead of patching it again. A problem still there after that is marked "gave up" with Copilot's diagnosis in its note (Code health > Issues). The default number of attempts is now 3 (Settings > Checks and issues > Fix attempts per file).
- Within one task, a file-check error that is still there after Copilot's next change gets the same evidence (the file now, the bracket map, its users) and a request to state the cause before changing it again.

## [v0.1.100] - 2026-10-07

### Added
- Prisma support:
  - **Schema check after every change** to a `.prisma` file, by fixed rules: brackets and unclosed strings, lines outside a `datasource`/`generator`/`model`/`enum` block, field lines that are not `name Type ...`, types that are neither Prisma's own nor a model or enum in the schema (with the close name: `Strng`, did you mean `String`; names are case-sensitive as in Prisma), a model or enum defined twice, a field or enum value twice, optional lists (`String[]?`), unknown `@` and `@@` attributes, a model without `@id`/`@@id`/`@unique`/`@@unique`, an unknown database provider, `@relation(fields: [...], references: [...])` naming fields that do not exist or that do not pair up, and a relation without a field pointing back.
  - **Against the project:** `env("...")` names that the project's `.env` (or Windows' environment) does not set, and a datasource without a url (unless a `prisma.config` file holds it). Only the names in `.env` are read.
  - **Prisma's own check:** when the project has Prisma installed, `prisma validate` runs on the saved schema too (the project's own Prisma, never one npx downloads; offline, asks nothing, at most 60 s). It finds what fixed rules cannot, such as a native type the database does not support. Checked against Prisma 6.19.
  - **Commands:** `prisma migrate dev` and `prisma studio` are refused before they run, with the way that works here (`prisma db push` while prototyping, or `prisma migrate diff --script` into a migration folder and then `prisma migrate deploy`; or the command for you to run in your own terminal). `prisma migrate reset` and `db push --force-reset` / `--accept-data-loss` count as deleting data: you approve them every time, and they never run unattended or from MCP.
  - **Prisma rules for Copilot** (`prompts/rules/prisma.md`), sent when the project has a `.prisma` file or the request names Prisma: the non-interactive workflow, `prisma generate` after a schema change, the connection in `.env`, ids and relations.
- Commands that want to ask questions in a terminal (such as `prisma migrate dev`, or a script waiting for input) failed with the generic reasons "a tool is not installed" or "another shell". StreamHub runs commands without a terminal, so nobody can answer prompts: Copilot is now told so with every command instruction (use non-interactive forms), and when the output shows a command needed a terminal (non-interactive, not a TTY, EOF when reading a line and similar), the card says so (code RUN-INTERACTIVE) and Copilot gets what to do instead: the tool's form for scripts and CI, or the exact command for you to run in your own terminal.

## [v0.1.99] - 2026-10-06

### Added
- npm install on a click: when a project's `package.json` (the root, or a folder up to two levels down) lists packages that `node_modules` does not have, the chat shows a card "This project needs its packages" with which ones and a *Run npm install* button (or *Not now*); it comes once per set of missing packages, after a task and when the project opens. Settings > This computer > *Project packages (npm install)* shows the same for the open project and runs it from there. StreamHub never runs npm install by itself, since it downloads code and runs its install steps; only the StreamHub page can start it. The output shows on a run card, `package-lock.json` changes are a change set (Undo), a blocked registry or proxy gets a hint, and without npm the card points to Settings > This computer > Node.js.

## [v0.1.98] - 2026-10-06

### Added
- Chains can download a file from SharePoint or OneDrive: a step `download: LINK to Downloads/NAME.csv` (or Automation > Chains > Add a step > Download a file from SharePoint or OneDrive). StreamHub's own Edge fetches it with your Microsoft 365 sign-in, so it works with the company sign-in and nothing has to be synced; on a schedule each run gets the latest version, and the data conversion and `DataTools.load` pick it up. Only https links to SharePoint or OneDrive, only into the project (by default `Downloads/` with the file's own name), never into `Source/`, `.streamhub/` or protected files. You approve each link and place once (never from MCP); after that it runs unattended. A sign-in page, a viewer page or a folder link instead of the file is reported with what to do, and the earlier download stays. Each download is part of the chain's change set (Undo).
- A dashboard builds on the CSV itself: `DataTools.load("Source/sales.csv")` in `data/data-tools.js` (version 2) gives a page the rows of a data file. Served over http(s) (Open app, a dev server), it reads and parses the CSV, TSV or JSON itself, so the page shows the latest file; opened from disk, where a browser lets a page read no files, it loads the converted copy StreamHub keeps (`data/NAME.js`) with a script tag. StreamHub writes `data/data-index.js` (which copy belongs to which file) after each task, Copilot is told to load data only this way (one script tag, no fetch of its own), and a project's older `data-tools.js` is replaced by the new version (one the project wrote itself is left alone). Copilot's edits to both files are refused. Checked in Edge both ways: from disk and served, and a row added to the CSV shows at once when served.

### Fixed
- The chat did not always scroll to the newest line: it followed only new items, not a reply streaming in, a card getting its output or code and images laying out, and its smooth scroll stopped short when more arrived meanwhile. It now stays at the bottom while anything grows, stops following when you scroll up to read, and comes back down when you send a message or a step waits for your approval.

## [v0.1.97] - 2026-10-06

### Added
- Data files ready for Copilot: StreamHub converts the project's CSV, TSV and Excel files (and JSON files in `Source/`) to `data/NAME.json` itself, before Copilot works on the project, so a dashboard no longer starts with Copilot writing its own parser. Rules: the delimiter is the most common of `,` `;` tab `|` in the header line; the encoding is UTF-8 when the bytes are valid UTF-8, else Windows-1252; a column is a number, true/false or a date only when every value in it is one; decimal commas are read in files that use `;`; dates become `yyyy-MM-dd`, and day or month first is taken only when the data shows it; codes with a leading zero (`007`) stay text; empty cells and N/A are null. Excel dates come from the cell's number format; hidden sheets are left out, and several sheets become one object with a list per sheet. Every converted file also gets a `data/NAME.js` copy that sets `window.NAMEData`, so a web app loads it with a script tag (kept up to date by the data copies). There is also `data/data-tools.js` with tested helpers for that data: rows per sheet, filter, sort, distinct values, sum/avg/min/max/count, group and summarize, by month, dates without time zone shifts, number and date formats. Copilot gets each file's place, its global, its rows and its columns with their types, and is told to use them instead of parsing. A file is made again when its source changes; one someone changed since is left alone (said once), and a `data/` file StreamHub did not make is never overwritten. Each conversion is a change set (Undo) with a Write card by StreamHub. Settings > Changes and commands > *Prepare data files for Copilot*.
- The UI kit lives in the project's `.streamhub/ui-kit/` (copied once, so the project keeps the kit version it started with), and `styles/kit/` holds only what the pages use. `tokens.css` is copied once and is the project's own to restyle. `kit.css` is written by StreamHub after each change with only the rules of the kit classes the pages and code use; class names built in code (`"kit-badge--" + tone`) count by their prefix. Kit scripts, React parts, pdf.js and icons arrive when a page loads or imports them (`styles/kit/NAME`), each with the licence it needs. A project that only shows a few buttons and a table gets 9 KB of the 21 KB stylesheet and none of the scripts. Copilot reads the examples from the catalogue, and its edits to the generated `kit.css` are refused with where the change belongs (tokens.css or its own stylesheet). A project that already has the whole kit in `styles/kit/` keeps it as it is.
- Copilot's glob and grep also search the UI kit catalogue (`.streamhub/ui-kit/`), so a search for a kit class finds its example; the rest of `.streamhub/` stays out, and pdf.js is not searched.
- Settings > UI kit > Colours has a third choice, None: no colours are set for the project. The kit starts from the neutral values only so its parts show, and Copilot is told to use the colours the project has or the request asks for, in `tokens.css` or its own CSS. Hard-coded colours and other gradients are not reported then; the readability (contrast) checks still apply.
- UI kit file readers (`kit-data.js`): a page reads a file a person picks or drops, in the browser and without uploading it: CSV, TSV and Excel as typed tables (the same rules as above), JSON, Word (headings, paragraphs, lists, tables), PowerPoint (slides in order with titles and notes) and PDF text per page. Office files are unzipped with the browser's own decompression, so no library is needed. PDF reading uses pdf.js 3.11 (Mozilla, Apache 2.0, shipped in the kit under `vendor/pdfjs/`); its worker runs on the page itself, so it also works for pages opened from disk. React projects get `react/useFileData.ts`. The examples page has a file picker that previews what was read. Settings > UI kit > *File readers* and *PDF reading (pdf.js)*.

### Fixed
- Building an approved plan told Copilot that the decisions are in `PLAN.md`, but that file has been in `.streamhub/PLAN.md` since the folder layout changed; the message now names the right path (tested against the layout).
- Waiting for another StreamHub program: only one program sends to Copilot at a time (the MCP server's own engine, a second app window or a test launcher can hold the turn). That wait used to look like "waiting for the reply" for up to 15 minutes, with nothing in the log. The waiting line now names who holds the turn and since when (`%LOCALAPPDATA%\CCBridge\copilot-lock.json`), the log says when the wait starts and ends, and Stop ends the wait.

## [v0.1.96] - 2026-10-06

### Added
- UI kit: when Copilot builds an interface, StreamHub adds its UI kit to the project (`styles/kit/`: `tokens.css` with colours, type, space and shadows for light and dark, `kit.css` with buttons, forms, toolbar, tabs, navigation, tables, badges, notices, key figures, empty states and dialogs, and `kit-examples.html` with the markup of each) and tells Copilot to build from it and restyle through the tokens. The default accent is a deep blue (#10069F). The kit is copied once and never overwritten, so a project can restyle it. Settings > Copilot > Use the UI kit turns it off. The kit also has interactive parts adapted from kokonutui (MIT, with its licence in the kit): hold to confirm, search with suggestions, a file drop zone with progress, animated tabs and segmented choice, loading text, a composer and a command button. Plain pages get them through `kit.js` (no build step, works from disk); React projects also get `styles/kit/react/` with the same parts as React components that need nothing but React.
- UI kit icons: the Lucide icon set (all 2,000+ icons, ISC licence, in the kit) through `data-kit-icon="NAME"` on any element, drawn as inline SVG in the text colour (works from disk). A project gets the common icons in `styles/kit/kit-icons.js`, and every other icon its pages use is added after each change; a name Lucide does not have is reported with close names (also typos). React projects get `react/Icon.tsx`. Settings > UI kit > Icons. `tools/update-lucide.ps1` rebuilds the set from the `lucide-static` package.
- UI kit scrollbars: thin, on a see-through track so they take the colour of the panel or page they are in, with a handle that meets 3:1 and turns the accent on hover, in light and dark (the kit also sets `color-scheme`, so the browser's own parts follow dark mode).
- Settings sections have Lucide icons in their list.
- UI kit colours: Settings > UI kit > Colours chooses the palette a project gets. Blue (the default): blue and light blue accents with teal, green, light green, yellow, orange, magenta and violet, each with a lighter and darker variation, plus white, greys and black (`--kit-palette-*`), and the light-blue-to-blue gradient from bottom left to top right as the only gradient. Neutral: greys with a near-black accent and chart colours that stay apart for colour-blind readers. The working tokens pick readable shades for light and dark (darker variations where a colour is too light on white, light blue as the accent on dark pages), and every pair passes WCAG AA in both palettes. Other gradients are reported.
- UI kit typography: Arial first; headings, table headers, labels and buttons in sentence case (the kit's own capital table headers are gone), and a change that adds capital headings or `text-transform: uppercase` is reported.
- Alignment: one page grid (`--kit-page-width`, `--kit-page-pad`, a `kit-header` whose contents share the page edges), a design rule for Copilot, and a page check that reports blocks (header contents, sections, headings, panels, tables) whose left or right edge is a few pixels off the edge the rest of the page uses.
- Settings > UI kit: the kit is its own section with a switch per part: the kit itself, interactive parts, charts, React versions, design rules for Copilot, checks for generated-looking interfaces, and readability and accessibility. A part that is off is not copied into projects (its sections are left out of the examples page) and not mentioned to Copilot; switching it on later adds its files at the next interface task.
- Design rules for Copilot, written for StreamHub: one main action per screen, feedback and empty/loading/error states, dialogs only for blocking decisions, forms, tables and charts, light and dark, motion, accessibility. A request to review the design (also in Dutch) gets fixed review steps: screenshots of each view, then layout, interaction, accessibility, consistency and craft, reported as Critical / Improvements / What works.
- More accessibility checks: click targets under 24 x 24 px that crowd other targets (WCAG 2.5.8, with its spacing and in-sentence link exceptions), buttons, links and images without a name, a removed focus outline without a :focus-visible replacement, and animations without a reduced-motion version.
- UI kit charts: `kit-charts.js` draws bar (grouped or horizontal), line, area, ring, gauge, heatmap and sparkline charts as plain SVG on the kit's colours, with no library and no build step (a `data-kit-chart` element or `KitCharts.bar(element, data)`); the design (dashed grid, rounded bars, fading area fill, hover highlight with tooltip, legend, grow-in) is adapted from bklit-ui (MIT, with its licence in the kit). Each chart has a summary and a hidden data table for screen readers; axis labels thin out to fit, and the chart colours (`--kit-chart-1` to `-6`) stand out 3:1 in light and dark. React projects get `react/Chart.tsx`.
- Readability (WCAG AA contrast): the page check measures the visible text of a changed page against the background it sits on, in light and in dark (4.5:1 for normal text, 3:1 for large text and for the edges of form fields), and reports what falls short with the colours and the ratio needed; text over images or gradients is left out. A change to the UI kit's `tokens.css` that makes a colour pair unreadable is reported too. The kit's own field and button borders were darkened to meet 3:1. Settings > Checks and issues > Readability (contrast) turns it off.
- Checks for interfaces that look generated, on what a change adds: gradient text, thick coloured side stripes, decorative blur, and (with the kit in the project) hard-coded colours instead of the kit's tokens.

## [v0.1.95] - 2026-10-06

### Fixed
- A SharePoint or OneDrive link in a message: Copilot tried StreamHub's web action, got a sign-in page and said it could not see the data, while Copilot itself can open the file with your access. The web action no longer fetches Microsoft 365 links and tells Copilot to open the file itself; a message with such a link also gets a short rule saying so, and that data the project needs goes into a project file (for example `data/NAME.csv`).

## [v0.1.94] - 2026-10-06

### Changed
- More light lines while waiting for and receiving a reply, including a set about making chips (cleanrooms, wafers, lithography, yield) and a mad-scientist set.
- The waiting indicator says what StreamHub itself is doing (opening a new chat, checking or screenshotting a page, checking scripts, running tests, checks and hooks, indexing, pausing in a chain, an agent at work, Copilot still busy) instead of Copilot's waiting lines, with light lines of its own for each.

### Fixed
- JSON data in JavaScript files (data copies such as `window.NAME = [...]`, object and array literals, tables) was reported as "these lines repeat" in Issues: repeated lines that are only data no longer count; repeated code still does. When the checks change like this, the issue index scans every file again once, so old reports disappear; ignored issues are kept.
- Screenshots with click steps (`ACTION screenshot` with `click` lines) left their browser tab open in StreamHub's Edge; the tab is closed again.

## [v0.1.93] - 2026-10-06

### Added
- Before/after check for visual changes: before the first change to a web file in a task, StreamHub takes a screenshot of the page, and after the change compares it pixel for pixel with the new one. When the page looks exactly the same, the chat says so, Copilot gets both screenshots with that finding (it is measured, not Copilot's opinion), and after Copilot's fix the page is checked once more. When it changed, Copilot is told how much and where. It cannot tell whether a change is right, only whether anything changed.

### Changed
- Edits whose SEARCH text is in the file more than once are less strict. StreamHub now takes the only match inside the lines Copilot read in this task (`read FILE:START-END`); Copilot can point with `<<<<<<< SEARCH line NUMBER` (the match nearest that line) or change every match with `<<<<<<< SEARCH all`; and when nothing shows which one is meant, the card says "needs a more exact SEARCH" (grey, not a red failure) and Copilot is told exactly how to point, instead of being asked to read the file again.
- Settings opens on the App section, now first in the list.

### Changed
- A reply that stops before the change (Copilot ends with "Need to inspect the CSS before making the change" or "I will update ..." and changed nothing) gets a card "Copilot stopped before making the change" with Continue and build, which sends Copilot back to make the change. A proposal's card is now titled "Copilot's proposal".
- `html-echo-test.cmd` compares lines by content, so an extra line in the reply no longer marks every line after it as damaged.
- New edit markers: Copilot is taught `####### SEARCH`, `####### REPLACE` and `####### END` (each alone on its line, with `line NUMBER` or `all` after SEARCH when needed). They have none of the `<` and `>` that the chat damaged on some tenants, and no line in any language or file format looks like them, so a `=======` line in the code (a reStructuredText heading, a merge conflict) is no longer mistaken for the divider. Only an exact whole line counts (seven `#`, the word in capitals), and only inside an edit block, so comments such as `# SEARCH` or `##### END` stay code. The old `<<<<<<<` / `=======` / `>>>>>>>` markers are still read. `html-echo-test.cmd` checks that the new markers arrive intact.

### Fixed
- Edits whose `<<<<<<< SEARCH` line was damaged or removed on the way (the edit then failed three times with "edit block has no SEARCH/REPLACE pairs"): `SEARCH` or `EARCH` alone on a line, with leftover arrows, counts as the start marker, and a block without one but with a single `=======` line is read as one pair (the lines before it are the SEARCH).
- The screenshot action failed when Copilot copied the placeholder `PAGE` from the hint: the hint now names the page that was screenshotted, and a name that is not a page file uses that page (and says so).

## [v0.1.92] - 2026-10-06

### Changed
- Write and Edit cards in the chat now start expanded, showing the changed lines at once. Settings > This browser > Change cards switches back to collapsed (kept per browser). A card you open or close yourself stays that way; cards waiting for approval are always open.
- Settings is no longer one long page: a list of sections on the left (This browser, This computer, Sign-in, then the app's groups) shows one section at a time, which scrolls on its own when it is long. The window keeps one height, the last section is remembered per browser, and on a narrow window the list becomes a row of buttons at the top.

## [v0.1.91] - 2026-10-06

### Added
- Screenshots of the part that changed: the automatic screenshot shows a page as it first opens, so a change in another view, tab or dialog (a Month view behind a toggle) was not visible. Copilot can now send `ACTION screenshot PAGE` with up to five steps (`click CSS-SELECTOR`, `click text=LABEL`, `wait MILLISECONDS`); StreamHub opens the page in its preview tab, follows the steps, and attaches the new screenshot, saying when a step matched nothing or caused a JavaScript error. Every automatic screenshot message tells Copilot about it.

## [v0.1.90] - 2026-10-05

### Added
- The JavaScript written inside HTML pages (inline `<script>` blocks; not `src`, JSON or template blocks) is now compiled after every round like `.js` files, and a syntax error comes back to Copilot with its line in the page.

### Fixed
- Commands that cannot work here are not run, with the reason: `node --check` on a page or other non-JavaScript file (Copilot used it to check HTML), and commands with a bash here-string (`<<<`). Copilot is told that StreamHub checks page scripts itself.

## [v0.1.89] - 2026-10-05

### Added
- When Copilot answers a question with a proposal instead of doing the work (a heading such as "Proposed ...:" or words such as "I suggest" or "Would you like me to implement", with a list of at least three points) and the turn changed no files, the proposal becomes a plan card with Approve and build, like a plan-first plan; it is also written to `.streamhub/PLAN.md`.

### Fixed
- A prompt could be sent to Copilot twice: when no part of the reply arrived within 25 seconds, StreamHub took the request as lost, tried to stop Copilot and sent the same prompt again in the same chat, even while Copilot was still thinking (a Microsoft 365 question can take longer than that before the first word). It now does so only when Copilot's page does not show it at work.

### Changed
- The test and capture tools (`probe`, `capture`, `complexity-test`, `reply-timing`, `stream-shape`, `agent-capture`, `agent-test`, `render-test`, `m365-fields-test`, `html-echo-test`, `rate-limit-test`) moved from the app folder into `test-tools\`. The app folder keeps only the everyday launchers (`start`, `install`, `check`, `update`, `diagnostics`, `sso-setup`); an update removes the old copies.

## [v0.1.88] - 2026-10-05

### Added
- `rate-limit-test.cmd`: sends tiny made-up prompts back to back (40 at most; options for a gap, a new chat every N prompts and when to stop) and reports per prompt whether Copilot answered, how long it took, what it said instead, and the chat and daily-credit counters when Copilot reports them. Each prompt uses one Copilot message.

### Fixed
- Long chains no longer stop when Copilot stops answering after many requests in a row ("Sorry, I wasn't able to respond to that", then no answer): a runbook or fetch step that got no usable answer waits and is tried again in a new chat (after 2 and then 5 minutes, `pacing.chainRetrySec`), and Copilot steps get a 10-second pause between them (`pacing.chainStepSec`). Other errors, such as a runbook whose answer does not fit its shape, still stop the chain at once. Stop ends a wait right away.

## [v0.1.87] - 2026-10-05

### Fixed
- Edits whose text Copilot's own output damaged around a script tag (seen on Copilot's page: `<script src="PATH.js"></script>` followed by the end marker came out as `<script src="PATH.js">` and `</EPLACE`): a damaged end marker (`</EPLACE`, `REPLACE` alone, or only `>>>`) now ends the edit instead of being written into the file, and a `<script src="...">` line whose `</script>` was eaten is closed again (unless the next line closes it).

## [v0.1.86] - 2026-10-05

### Fixed
- HTML tags damaged on the way back from Copilot (`<script src="PATH.js"></script>` arriving as `PATH.jsscript>` while Copilot's page shows the line intact): when a received reply holds such a damaged tag and the page's own copy of the same reply does not, StreamHub uses the page's copy. A script tag that still arrives as `PATH.jsscript>` in a page file is put back as `<script src="PATH.js"></script>` (in write and REPLACE text, not in SEARCH, so the damaged line already in a file is still found).
- The HTML file check reports what is left of a damaged tag (`PATH.jsscript>`, `PATH.csslink>`), so a page already damaged by an earlier write shows under Issues and is sent back to Copilot after a change; before, it was plain text to the check.

## [v0.1.85] - 2026-10-05

### Added
- `html-echo-test.cmd`: asks Copilot to repeat made-up HTML and PowerShell lines exactly, once on the normal route and once read from the page, and reports line by line what arrived (escaped, damaged or intact).

### Fixed
- An edit or write to a markup file whose new lines hold an HTML tag damaged on the way (an attribute quote never closed, like `src="x.jsd>`, or the end of a tag left without its start, like `x.jsscript>`) is refused before anything is written; Copilot is asked to send it once more and otherwise to tell you the exact line to add by hand.
- PowerShell where the chat removed the `[Type]` in front of `::` (`:Match(` instead of `[regex]::Match(`) is refused in commands and `.ps1` files with the safe forms to use instead; the PowerShell rules tell Copilot to avoid `[Type]::Member`.
- Settings > This computer: updating Node.js no longer loops. The tools list no longer runs `npm config get registry` every few seconds (only the system check asks npm's registry), and when Node.js is in use the update waits and runs at StreamHub's next start (button "Updates at next start").
- PowerShell commands from Copilot failed with parser errors ("Missing closing '}'") because Copilot's page turns [regex]::Match into [regex\]::Match (brackets that look like a Markdown link definition are escaped). StreamHub now puts .NET type names before :: back in run commands and in .ps1/.psm1/.psd1 files, and repairs &lt; / &gt; in run commands as it already did in files.
- Scripts packed into one powershell -Command "..." line longer than 300 characters are not run: Copilot is told to write a script file and run it with -File, so it gets the PowerShell syntax check first and can be read when you approve it. One-off scripts (run once, for example to change many files) go in Work/, scripts worth keeping and running again in Scripts/ (they show under Automation > Scripts). Scripts are kept, not deleted afterwards: deleting would need your approval each time, and a kept script records how files were changed.

## [v0.1.84] - 2026-10-05

### Added

- Copilot can run a runbook: when it reads a request as "run this runbook" (for example "can you give me the day-01 data again"), it uses a new action (ACTION runbook NAME) and the runbook runs right after its reply, like the Run button; in Ask before changes mode you approve it first. Copilot gets this action with the runbook rules, which are now also sent when a message names one of the project's runbooks.
- When a longer message names a runbook without saying to run it or to change it, the chat asks instead of guessing: Run it, or Send to Copilot. Neither costs a Copilot message until you choose.

### Fixed

- A chat message that mentioned a runbook while asking to change it (for example "the runbooks day-01 to day-31 are incorrect, they should ...") ran that runbook instead of going to Copilot. A runbook named in the chat now runs only from a short message (8 words at most, such as just its name) or with a run word (run, execute, start), and never when the message reports a problem or asks for a different result (incorrect, wrong, should, instead, error, missing, and Dutch equivalents).

## [v0.1.83] - 2026-10-05

### Fixed

- Long Microsoft 365 requests were cancelled: when Copilot took longer than the reply limit (5 minutes), StreamHub pressed Stop, which cancels Copilot's work (a month-wide summary that Copilot ran as a background task was lost this way). At the limit StreamHub now looks at the page: while Copilot still shows that it is working, it keeps waiting, a minute at a time, up to the agent limit (Settings: agentTimeoutSec, 30 minutes) and shows "Copilot is still working (N min)". A Copilot that has gone silent is still caught by the stall check.
- Complexity test (complexity-test.cmd): the near-limit step was over the message box's 128,000 characters and is now 123,000; failed steps show their error message instead of empty fields; steps wait up to 30 minutes while Copilot is working.

## [v0.1.82] - 2026-10-05

### Added

- Open app: the Files section has an Open app button when the project has a page to start from (a build's dist/, build/ or out/index.html, else index.html at the root). It opens the page in a new tab from StreamHub's read-only project address, where built apps with module scripts (Vite, React) work, unlike a file opened from disk, and without a development server. The address now also serves WebAssembly, source maps, more fonts and web app manifests.
- React and Node.js: Copilot's React instructions follow what the computer has. Without Node.js and npm it is told to build plain HTML, CSS and JavaScript instead; with them, to use Vite with base './' and npm run build, and never to start a development server. The system check's Node.js line says whether npm can reach its package registry (a warning when it cannot, so npm projects cannot be built).
- `m365-fields-test.cmd`: asks Copilot (Work IQ, read-only) which fields and filters it can use for Teams channel, group chat and 1:1 messages, emails and calendar items, and writes a report of field names, types, filters and limits to C:\temp, without any item content. It says why a topic gave no fields (no Work IQ licence, Copilot's verification check, the daily limit, no answer).

### Fixed

- Links in the app (the changelog link at the bottom of the side panel, cited sources and web links in replies) opened in the other pane of Edge's Split screen, replacing Copilot, instead of in a new tab. When the app is a tab in StreamHub's Edge, these links now open as a real new tab through Edge itself; in any other browser or window they open as before.

## [v0.1.81] - 2026-10-05

### Added

- Dark mode matches the Copilot window beside it: the page is Copilot's own base color (a warm dark grey, measured from its page) and all surfaces, menus, the selected tab and text follow from it (text uses Copilot's greys: about 11:1, secondary 7:1). Hard-coded cold greys in the command palette, mode menu, upload box, chain steps and action cards now use the theme's colors, the command preview in action cards is a tinted block instead of a black one, and red text and code comments are a little lighter in dark mode so they stay readable on the new base. Light mode is unchanged.
- History: opening a file from a change set shows the lines that change set added and removed (the same view as the action cards), with a File tab for the whole text. A note says what is compared: a file created or deleted by the change set, or changed again later (then only this change set's part is shown), or compared with the file as it is now. Binary files open as before.

Nothing yet.

## [v0.1.80] - 2026-10-05

### Added

- The Copilot window follows StreamHub's theme: choose Light or Dark in Settings > This browser > Theme and the Copilot tab next to it switches too (System leaves Copilot to follow Windows). Only the Copilot tab is told which theme to show, through StreamHub's own connection to it; nothing changes in Edge or your Microsoft 365 account, and it is applied again after every reconnect. Copilot must be set to follow the system theme, which is its default. Setting Copilot > "Copilot follows the app's theme" turns it off.

Nothing yet.

## [v0.1.79] - 2026-10-05

### Fixed

- Drop-down lists (Response and Agent above the message box, and the selects in Settings and schedules) were unreadable in dark mode: the browser drew the list in light colors under light text. The page now tells the browser which theme is on, so native lists, scrollbars and pickers follow it, and options use the theme's menu colors.

## [v0.1.78] - 2026-10-05

### Added

- A research role for runbooks that read only the web (`sources: web`, as in the web-pages template): Copilot is told to take each value from a named public source, prefer the official one, give dates and never guess a value, and gets none of the Microsoft 365 instructions (`prompts/roles/research.md`, `prompts/runbook-web.md`). Before, every runbook was sent as a Microsoft 365 assistant task. Runbooks without a sources line, or with work or both, are sent as before.

### Changed

- Dark mode is easier to read: the background is a lifted near-black (about #121212 instead of #0a0a0a) and text is softened from near-white, so long replies no longer glare (body text about 15:1 instead of 19:1; secondary text about 8:1). Code in replies is a little larger, line numbers in code and diffs are clearer (5:1 instead of 3.4:1), the message box's tool buttons and tab descriptions are no longer faint, and a few panels that were darker than the page (the upload box, the Undo button, the command list) now use the theme's colors. Light mode is unchanged apart from the larger code and clearer line numbers.
- Messages to Analyst get their own instructions instead of the line written for Researcher: work only from the data provided, say which files, sheets and columns were used and which rows were left out, state assumptions (units, currency, periods, date formats), show how each figure was calculated, and say so when the data cannot answer the question (`prompts/agent-scope-analyst.md`, always sent); and a layout with key findings, method, result tables, charts with labelled axes and the data as JSON (`prompts/agent-output-analyst.md`, left out when your message names a format). Researcher keeps its line; runbooks and text runbooks with an agent are unchanged (their answer is the runbook's JSON).
- Project work that is not coding (documents, data, notes, reports, Office files) gets a work method for Copilot: keep the user's structure and wording, take facts from the files and name where they come from, check figures against their source, write results to a new file instead of changing source data, and say what was left out (`prompts/roles/project.md`).
- The side panel and the Settings window are split into smaller parts (no change in what they show or do): the index line, the tab bodies, the setting controls and the reset-all confirmation are their own components; remembered browser choices go through one helper (`ui-src/src/lib/stored.ts`) and the issue list is loaded by one shared hook.

## [v0.1.77] - 2026-10-05

### Added

- Images (.png, .jpg, .gif, .webp, .bmp): when Copilot reads an image in the project (a mockup, a design, a screenshot you saved), the image is attached to its next message so Copilot can look at it. Images are never written; Copilot can write an SVG when a drawing is needed. Copilot asks once for consent to images; you give it yourself.
- Secret files (`lib/SecretFiles.psm1`): .env files, .npmrc, .pypirc, .netrc, .git-credentials, secrets.json and similar, private keys and certificate stores. Copilot sees which keys are set, never their values: reads and searches show `<hidden>`, a key file is not shown at all, and the values are also taken out of command output (so `type .env` shows nothing secret). Copilot does not write or edit these files (it tells you what to add), they are never attached to a message and never sent for code review. Example files (`.env.example`, `.sample`, `.template`) stay as they are.
- Outlines for C#, Java and Kotlin (types and methods), Go (types and functions), SQL (CREATE and ALTER statements), JSON (keys of the first two levels) and INI/TOML (sections), so Copilot can read just the part it needs of a large file.
- PDF files: when Copilot reads a PDF in the project, the file is attached to its next message so Copilot reads it itself (as with old .doc, .ppt and .xls files; at most 50 MB). PDFs are never written: Copilot is told to write a .docx instead, which can be saved as PDF from Word. The Office rules for Copilot now also go with requests that mention a PDF and with projects that hold PDFs.

## [v0.1.76] - 2026-10-05

### Added

- Office files (`lib/Office.psm1`), without Office installed: reading a .docx, .pptx or .xlsx gives Copilot its text as Markdown (Word: headings, lists, tables, bold/italic/code; PowerPoint: one section per slide in slide order, with speaker notes; Excel: one table per sheet), with a note on what is left out (images, comments, rows). Copilot can make Word documents: writing NAME.docx with Markdown content saves a real Word file (headings, nested bullet and numbered lists, tables, code blocks, quotes), and such a document can be changed later with write or edit, with the usual diff, checks and Undo. A .docx made or saved in Word is never rewritten (its layout would be lost): Copilot writes a new document instead. PowerPoint and Excel files are read only (slides go to Markdown, data to .csv). Old .doc, .ppt and .xls files are attached to Copilot's next message when it reads one, so Copilot reads them itself. Office rules for Copilot (`prompts/rules/office.md`) go with requests about Word, PowerPoint or Excel files and with projects that hold them.
- Agent: Auto, now the default in the agent picker: StreamHub picks who answers by fixed words. Analyst when you ask for analysis, a chart, a trend or statistics of a data file you attach or name (csv, xlsx, json); Researcher when you ask to research or investigate something, about competitors or the market, or for sources; Copilot itself for everything else, and always for work on code or an app. The chat says which agent was picked and why. A choice made earlier in the picker is kept.
- Outlines for XML files (.xml, .csproj, .config, .xaml, .resx, .svg and similar: elements of the first three levels with their name, id or key) and YAML files (keys of the first two levels), so Copilot can read just the part it needs of a large file.
- Late reply parts are no longer lost: after Copilot signals the end of a reply, StreamHub waits a moment (`pacing.lateReplySec`, 2 s; 0 = off), waits while Copilot is still writing, and reads the reply from the page once more; when the page holds a longer version of the same reply, the missing part is added (only the new tail, so code received intact stays intact). Before, anything that arrived after the end signal was dropped at the next send.

- Nine more instruction modules for Copilot, each sent once per chat and only when it applies: answering questions (a how/why/where question without a change request is answered with file:line references and no edits), data files (delimiter, encoding, decimal comma, columns by name, dates with a time zone; `.csv`/`.xlsx` files or `Source/`), bigger tasks (a todo first, one working step per reply), scripts and automation (safe to run twice, dry-run for changes, parameters, a log in Logs/, exit codes), user interface (loading, empty and error states, keyboard and focus, responsive, the app's own look), web services (timeouts, status checks, retries with Retry-After, no keys in code), C# and .NET (with the csc.exe that ships with Windows when there is no SDK), React (hooks, keys, derived state, small components) and personal data (none in logs, tests or samples; data stays local). New project traits: data, csharp, react.
- File checks for mistakes typical of generated code (`Find-GeneratedCodeIssues`), sent back to Copilot after every round like the other file checks: typographic quotes used as code quotes, non-breaking and zero-width spaces, citation markers from the chat answer in the code, HTML entities in code, a chat sentence as the first line, a whole file of escaped line breaks; JavaScript: TypeScript syntax in .js, imports inside blocks, ES modules mixed with module.exports, a second export default, a top-level const/let/class declared twice; Python: Python 2 print, the same quotes inside f-string braces; PowerShell: PowerShell 7-only commands and parameters in a 5.1 script (unless it says #Requires -Version 7 or defines that name itself); CSS: // comments and SCSS syntax; batch: %i in for loops, !name! without delayed expansion. When those rules find nothing, the language's own syntax check runs if its tool is installed (`node --check`, `python -m py_compile`), on the changed files only.

- Guards against wrong checks (`lib/CheckPolicy.psm1`): every finding has a level, error (it breaks the file: done waits for a fix) or warning (a likely mistake: said once per task, never blocking); Copilot can dispute a wrong finding with `ACTION dispute PATH` (the finding and why), which leaves it out for the rest of the task and records it; the round's findings show in the chat as a File check card with Ignore per finding (the same ignore list as Code health > Issues, so it never comes back for that code); disputes and ignores are kept in `.streamhub/check-disputes.json` and included in Export diagnostics, to turn real false alarms into test samples.
- Settings > Checks and issues > Enforcement, a three-way switch with what each tier does: Light (only what breaks a file goes back, done waits once, failing tests and hooks are shown only), Standard (default: errors hold up done twice, likely mistakes are said once, tests and hooks go back twice) and Strict (likely mistakes hold up done too, three tries; more Copilot messages). Plus a switch per check family: chat-answer leftovers, syntax check with installed tools, PowerShell 7 features, quality notes.
- Release gate: `build-release.ps1` runs the whole Pester suite (Windows PowerShell 5.1, its own module paths) and `tools/scan-repo.ps1` (all file checks over this repository, 0 reports) before it builds, tags or publishes anything; `-SkipGate` for emergencies.

- Run-time pitfalls found while building StreamHub itself, now checked in projects too (`Find-LanguagePitfalls`): control characters where a backslash got lost (\t or \v in a path or string), a tab inside a quoted Windows path, mixed CRLF/LF line endings, and Windows PowerShell 5.1 traps: inner double quotes in a program's arguments (5.1 drops them), stderr becoming an error under ErrorActionPreference Stop, a JSON array arriving as one object, a parameter overwritten by a variable that only differs in case, automatic variables used as names, and `a, b + c` (the comma binds first); in TypeScript a member declared twice in one type. The checks found real bugs in StreamHub's own code, now fixed (a task report could record the check summary as the request; a tool printing its version to stderr was reported as missing).
- Mechanical fixes (`lib/AutoFix.psm1`) for problems with one right answer, in code only: curly quotes used as code quotes, non-breaking and zero-width spaces, HTML entities, mixed line endings, // comments in CSS, a single % in a batch for loop. They follow the enforcement tier: Light fixes silently, Standard fixes and tells Copilot, Strict leaves them to Copilot. A fix that would add a problem is not applied; each fix is a card with its diff (Undo).
- Rolling back a fix that made things worse: when Copilot changes a file to fix a reported problem and the file gets a new problem that breaks it, the change is rolled back (a card in the chat) and Copilot gets a wider read of the code around the original problem (whole blocks) to understand the context and confirm the cause before trying again; at most twice per file per task.

### Changed

- The check-and-fix flow: afterEdit hooks (a formatter) now run before the file checks, so the checks see the files as they stay; beforeDone hooks have their own two tries (failing tests no longer stop them); and pages in which the page check found errors are opened again after Copilot's fix, with what is left sent back once more.

## [v0.1.75] - 2026-10-05

### Added

- A new Copilot chat when the work moves to another part of the project (`lib/ChatScope.psm1`): a message that names files only in other folders or modules than the chat worked on so far (not connected through imports), and does not continue the earlier work ("also", "again", "fix it"...), starts a fresh chat, with a line in the chat saying why. Setting *New chat for another part of the project* (Settings > Copilot, on by default).
- README: a table of the parts of an agentic coding harness and how StreamHub covers each (and which it does not).
- The project's tests run after a change (`lib/TestRunner.psm1`): without a `verify:` line in AGENTS.md, StreamHub finds the project's own tests for the changed files (Pester `*.Tests.ps1` named after or mentioning a changed script; pytest or unittest when Python is installed; `npm test` when package.json has a real test script and npm is installed) and runs them when Copilot says done; a failure goes back to Copilot, at most twice. Setting *Run the project's tests* (Checks and issues, on).
- Hooks (`lib/Hooks.psm1`, Automation > Hooks): your own commands from `.streamhub/hooks.json` (Copilot cannot write there) at three moments: `afterEdit` after Copilot writes or edits a matching file (`{file}`), `beforeDone` when Copilot says done (a failure goes back to Copilot), `afterTask` after a task. A person approves the file once per version; deleting or Microsoft 365 commands never run; each run is a card in the chat. *Create hooks file* writes a starting file with examples. Setting *Run the project's hooks* (on) pauses them all.
- Protected files (Settings > Changes and commands > *Protected files*): files, folders (`docs/`) or patterns (`*.env`), one per line, that are read-only like `Source/`: Copilot's writes and edits are refused, a command that changes or deletes one sees it put back, and Copilot is told which they are. The protected copy is refreshed at the start of every task, so your own edits are kept.
- History > Restore: any change set but the newest can be restored to, which undoes it and every newer one (newest first) after a confirmation; one undo card per change set.
- Copilot sees the changed page (setting *Show Copilot the changed page*, on): with the page check, a screenshot of the changed page (1280x800, in `.streamhub/Screenshots/`) goes to Copilot once per task to compare with what was asked. When Copilot asks its one-time question about processing images, StreamHub answers "Not now" (the consent is yours to give in the Copilot window) and sends the message without the screenshot, with a line saying why.
- Code map (`lib/RepoMap.psm1`, setting *Code map size*, 4000 characters, 0 = off): with the first message of a chat about the project, the functions, classes, ids and headings per file with line numbers, files the message names first, then the files the chat works on, then files many others import; a big project gets a more selective map, not a bigger one.
- Settings can be lists of lines (type `list`), used by *Protected files*.
- Six instruction modules for Copilot, each sent once per chat and only when it applies: what this computer has installed (Windows PowerShell 5.1 and Edge, plus Python, Node.js, npm, .NET SDK, Git or Java when present; what is missing is never suggested or installed), a work method in the coding role (change only what was asked, follow the project's style, read before changing, small edits, ask when a guess would be costly), fixing bugs (find and fix the cause, add a test), tests (the project's framework and names the helper finds; failures come back), security (untrusted input, textContent, SQL parameters, no secrets in code), and JavaScript/TypeScript and batch file rules. New project traits: javascript, batch, tests.
- check.cmd and the installer list optional tools with their versions: Pester, Python (with pytest or not), Node.js with npm, the .NET SDK and Git. A missing tool is information, never a failure (StreamHub runs without it); a version too old to work well (Python before 3.8, Node.js before 18) is a warning.
- Optional tools on request (`lib/ToolInstall.psm1`, Settings > This computer, `check.cmd -Install NAME`): Python, pytest, Node.js, the .NET SDK and Git install or update for your user only, never with admin rights: winget with --scope user where it works, else the official package checked before use (the Node.js zip by the SHA-256 nodejs.org publishes, the python.org installer and Microsoft's dotnet-install.ps1 by their signature). Each install runs in its own process; a blocked download, a refused winget or a tool the computer's rules do not let run leaves it informational, with the reason, and StreamHub works without it. Installed tools are found at once (added to StreamHub's search path) and the line Copilot gets about this computer follows. Pester is listed, not installed (a newer major version changes how tests run). When the python found first is a virtual environment (often another program's), it is labelled so and StreamHub never installs into it. Updates too: besides the minimum versions (WARN), each tool's newest release is looked up at its official source (python.org, nodejs.org LTS, Microsoft's .NET release index, PyPI, winget for Git; kept 12 hours, skipped offline) and offered as *Update to X* in Settings and in check.cmd. An update of a tool installed for all users goes into StreamHub's own tools folder, used first by StreamHub's commands only; when the older version would still be found first, that is said.

### Changed

- New chat clears the chat view at once and shows the landing page; Copilot's new chat opens in the background (and a message sent before that is ready still goes to a new chat).

### Fixed

- Attaching a file to a Copilot message (Researcher and Analyst files, screenshots) failed with "RecursionLimit exceeded": the whole page structure was read as JSON, too deep for Windows PowerShell 5.1. The file input is now found inside the page.
- An attached image was not recognised as attached (Copilot shows a thumbnail, not the file name), so the attachment timed out.

## [v0.1.74] - 2026-10-04

### Changed

- Code health > Issues shows only the open project; the list of all projects at the bottom is gone. The empty-list line "No problems of the shown kinds." is gone too.

## [v0.1.73] - 2026-10-04

### Added

- Automation > Scripts: the project's scripts (`Scripts/`, .ps1, .cmd, .bat, .py) with Run, Schedule and View, like runbooks. A script runs as its own task (Actions > Runs) with the same rules as a script step in a chain: inside the project, approved the first time and again after it changes (setting *Scripts in chains* applies), a script that deletes data or uses Microsoft 365 asks a person every time, and what it changes is one change set in History. Schedules can run a script.

### Changed

- Re-index (Files tab and Code health > Issues) also brings data copies up to date with their JSON first, so a JSON changed outside StreamHub is picked up without running a task. Not while a task runs; the copies follow after it as before.

### Fixed

- The chat view stopped with "Cannot read properties of undefined (reading 'split')" when a chain asked to run a script: the card sent the script as plain text where a file preview was expected. The card now shows the script as code, and saved chat history with such cards opens again.

## [v0.1.72] - 2026-10-04

### Changed

- A new chain without steps no longer shows a warning: it says to pick a runbook or script and click Add. Run and Schedule stay unavailable until it has a step.

## [v0.1.71] - 2026-10-04

### Changed

- The Progress tab is now called Actions (Checklist and Runs); messages that pointed at it say Actions > Runs.
- The Changes tab is now called History, and its change sets no longer have an icon before the time.

### Fixed

- Chat messages after a code review or an issue scan pointed at the Changes tab; issues and code reviews are under Code health.
- The single sign-on setup log listed every switch on Edge's profile page as "switch: [off]", which read as if single sign-on were off. Each line now says whether it is the single sign-on switch or another setting.

## [v0.1.70] - 2026-10-04

### Fixed

- Settings > Sign-in said "no Copilot tab open" when Copilot's tab was on a sign-in page outside Microsoft's own (for example an organisation's sign-in page). It now names that site, so it is clear single sign-on did not sign in and where it stopped.

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
- `render-test.cmd`: shows how Copilot's page displays code blocks per label (a plain code block, a "not fully supported" note, or a Chart.js chart with "Invalid JSON"), one short message per label, with a report in `C:\temp`. On this tenant `read` gets a note, while `text`, `plaintext` and `text read` show as plain code.

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

[Unreleased]: https://github.com/jgt87/CCBridge/compare/v0.1.111...HEAD
[v0.1.111]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.111
[v0.1.110]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.110
[v0.1.109]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.109
[v0.1.108]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.108
[v0.1.107]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.107
[v0.1.106]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.106
[v0.1.105]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.105
[v0.1.104]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.104
[v0.1.103]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.103
[v0.1.102]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.102
[v0.1.101]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.101
[v0.1.100]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.100
[v0.1.99]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.99
[v0.1.98]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.98
[v0.1.97]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.97
[v0.1.96]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.96
[v0.1.95]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.95
[v0.1.94]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.94
[v0.1.93]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.93
[v0.1.92]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.92
[v0.1.91]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.91
[v0.1.90]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.90
[v0.1.89]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.89
[v0.1.88]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.88
[v0.1.87]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.87
[v0.1.86]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.86
[v0.1.85]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.85
[v0.1.84]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.84
[v0.1.83]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.83
[v0.1.82]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.82
[v0.1.81]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.81
[v0.1.80]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.80
[v0.1.79]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.79
[v0.1.78]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.78
[v0.1.77]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.77
[v0.1.76]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.76
[v0.1.75]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.75
[v0.1.74]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.74
[v0.1.73]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.73
[v0.1.72]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.72
[v0.1.71]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.71
[v0.1.70]: https://github.com/jgt87/CCBridge/releases/tag/v0.1.70
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
