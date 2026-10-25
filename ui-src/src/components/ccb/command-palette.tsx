import { AtSign, ClipboardCheck, ClipboardList, Eraser, FileArchive, FileCode2, FileText, FolderOpen, MessageSquarePlus, Palette, PencilRuler, Presentation, RotateCcw, ScrollText, Settings, ShieldCheck, Zap } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import ActionSearchBar, { type Action } from "@/components/kokonutui/action-search-bar";
import type { PromptMode } from "@/components/kokonutui/ai-prompt";
import { ModalBackdrop } from "@/components/ccb/modal-backdrop";
import { fetchedAge } from "@/components/ccb/fetch-panel";
import { dataCommands, dataProfileActions } from "@/components/ccb/data-commands";
import { findAppEntry } from "@/lib/app-entry";
import { type AppState, api, type DataProfileSource, type FetchItem, type FileInfo, type Mode, type TestRunItem } from "@/lib/api";

export const MODES: PromptMode[] = [
  { id: "ask", label: "Ask before changes", description: "Approve every file change and command", icon: <ShieldCheck className="h-3.5 w-3.5 text-muted-foreground" /> },
  { id: "auto", label: "Auto-accept edits", description: "Apply file changes directly; still ask for commands", icon: <Zap className="h-3.5 w-3.5 text-muted-foreground" /> },
  { id: "plan", label: "Plan only", description: "Read and discuss; no changes, no commands", icon: <PencilRuler className="h-3.5 w-3.5 text-muted-foreground" /> },
];

export type PaletteKind = "commands" | "attach" | "logging" | "testruns" | "dataprofile";

const PALETTE_TEXT: Record<PaletteKind, { label: string; placeholder: string }> = {
  commands: { label: "Commands and files", placeholder: "Type a command or file name..." },
  attach: { label: "Attach a project file", placeholder: "File name..." },
  logging: { label: "Logging level", placeholder: "Info, verbose or trace..." },
  testruns: { label: "Test runs", placeholder: "Test run name..." },
  dataprofile: { label: "Data profile", placeholder: "Data file name..." },
};

const LOG_LEVELS = [
  { id: "info", label: "Info", description: "The normal log: what StreamHub did, without details" },
  { id: "verbose", label: "Verbose", description: "Every step in detail, for finding a problem" },
  { id: "trace", label: "Trace", description: "Also the prompt and reply text, which can hold Microsoft 365 data: for a short test only" },
] as const;

export interface Notice {
  text: string;
  path?: string;
}

/** What the commands act on and how they report back. */
export interface CommandContext {
  state: AppState;
  files: FileInfo[];
  fetchItems: FetchItem[];
  attachPath: (path: string) => void;
  openFile: (path: string) => void;
  startNewChat: () => void;
  openSettings: () => void;
  openPicker: () => void;
  setLogLevel: (level: AppState["logLevel"]) => void;
  notice: (n: Notice) => void;
  fail: (message: string) => void;
}

const icon = (Icon: typeof FileText) => <Icon className="h-4 w-4 text-muted-foreground" />;

function fileActions(ctx: CommandContext, attach: boolean): Action[] {
  const fetchedByPath = new Map(ctx.fetchItems.map((it) => [it.output, it]));
  return ctx.files.map((f) => {
    const fetched = fetchedByPath.get(f.path);
    return {
      id: `file:${f.path}`,
      label: f.path.split("/").pop() ?? f.path,
      // Fetched data shows how old it is, so stale data is easy to spot before attaching.
      description: fetched ? `${f.path} - fetched ${fetchedAge(fetched.fetchedAt)}` : f.path,
      icon: <FileCode2 className="h-4 w-4 text-muted-foreground" />,
      end: attach ? "Attach" : "Open",
      onSelect: () => (attach ? ctx.attachPath(f.path) : ctx.openFile(f.path)),
    };
  });
}

function loggingActions(ctx: CommandContext): Action[] {
  return LOG_LEVELS.map((l) => ({
    id: `log:${l.id}`,
    label: l.label,
    description: l.description,
    icon: icon(ScrollText),
    end: (ctx.state.logLevel || "info") === l.id ? "Active" : "Logging",
    onSelect: () =>
      // The level the server reports back is the one in force.
      api.setLogging(l.id).then((r) => {
        const now = r.level ?? l.id;
        ctx.setLogLevel(now);
        ctx.notice({ text: now === l.id ? `Logging set to ${now}.` : `Logging asked for ${l.id}, but StreamHub is at ${now}.` });
      }),
  }));
}

// Test runs: the saved ones to start (a fresh project, every step, then the report).
function testRunActions(ctx: CommandContext, testRuns: TestRunItem[]): Action[] {
  return testRuns.map((t) => ({
    id: `testrun:${t.name}`,
    label: t.title,
    description: `${t.steps} step(s)${t.lastRun ? `, last run ${t.lastRun}` : ", not run yet"}: runs them in a new project, then writes a report compared with the last run`,
    icon: icon(ClipboardList),
    end: "Test run",
    onSelect: () =>
      api.runTestRun(t.name).then(
        (r) => ctx.notice({ text: `Test run started in a new project (${r.steps} step(s)). The report comes at the end, in .streamhub/TestRun-report.md.` }),
        (e) => ctx.fail((e as Error).message)
      ),
  }));
}

function exportActions(ctx: CommandContext, appEntry: string): Action[] {
  const exportAs = (kind: "pdf" | "pptx", text: string) => () =>
    api.exportPage(appEntry, kind).then(() => ctx.notice({ text }), (e) => ctx.fail((e as Error).message));
  return [
    {
      id: "export-pdf",
      label: "Export page as PDF",
      description: `${appEntry} as a PDF in Runbooks/Exports (the UI kit's print styles; a script for schedules comes with the first one)`,
      icon: icon(FileText),
      end: "Export",
      onSelect: exportAs("pdf", `Exporting ${appEntry} as a PDF...`),
    },
    {
      id: "export-pptx",
      label: "Export charts to PowerPoint",
      description: `Every chart and the key figures of ${appEntry}, one slide each, in Runbooks/Exports`,
      icon: icon(FileText),
      end: "Export",
      onSelect: exportAs("pptx", `Exporting the charts of ${appEntry} to PowerPoint...`),
    },
    {
      id: "check-page",
      label: "Check this page in full",
      description: `${appEntry} in light, dark and at phone width: every check in one report (.streamhub/Reports), with a fix list to send to Copilot`,
      icon: icon(ClipboardCheck),
      end: "Check",
      onSelect: () =>
        api.checkPage(appEntry).then(
          () => ctx.notice({ text: `Checking ${appEntry} in full...` }),
          (e) => ctx.fail((e as Error).message)
        ),
    },
  ];
}

/** For a colleague: a project overview (facts, then Copilot's explanation) and the project as a zip. */
function shareActions(ctx: CommandContext): Action[] {
  const packageAs = (includeSource: boolean, text: string) => () =>
    api.packageProject(includeSource).then(() => ctx.notice({ text }), (e) => ctx.fail((e as Error).message));
  return [
    {
      id: "project-overview",
      label: "Write a project overview",
      description: "Runbooks/Exports/project-overview.md for a colleague: the facts StreamHub gathers, then Copilot explains what it is for and how to use it",
      icon: icon(FileText),
      end: "Share",
      onSelect: () =>
        api.writeOverview().then(() => ctx.notice({ text: "Writing the project overview..." }), (e) => ctx.fail((e as Error).message)),
    },
    {
      id: "package-share",
      label: "Package for sharing",
      description: "The project as a zip in Runbooks/Exports with notes on how to open it; leaves out Source data, secrets, packages and StreamHub's records",
      icon: icon(FileArchive),
      end: "Share",
      onSelect: packageAs(false, "Packaging the project..."),
    },
    {
      id: "package-share-source",
      label: "Package for sharing, with Source data",
      description: "The same zip with the source data in Source/ too: only when the colleague may have that data",
      icon: icon(FileArchive),
      end: "Share",
      onSelect: packageAs(true, "Packaging the project with its Source data..."),
    },
  ];
}

/** On request only: the theme card and the tidy-up list (StreamHub never offers them by itself). */
function projectCareActions(ctx: CommandContext): Action[] {
  return [
    {
      id: "kit-theme",
      label: "Theme from your colours",
      description: "Set the UI kit's colours from your accent (and a second colour and a neutral tint), readable in light and dark",
      icon: icon(Palette),
      end: "Project",
      onSelect: () => api.themeOpen().then(() => ctx.notice({ text: "The theme card is in the chat." }), (e) => ctx.fail((e as Error).message)),
    },
    {
      id: "tidy",
      label: "Tidy-up list",
      description: "What the project likely no longer uses: files nothing loads, unused style rules, unread data, old files in Work/. Nothing goes without your tick",
      icon: icon(Eraser),
      end: "Project",
      onSelect: () =>
        api.tidyList().then(
          () => ctx.notice({ text: "Looking for what the project no longer uses; the list comes in the chat." }),
          (e) => ctx.fail((e as Error).message)
        ),
    },
  ];
}

/** PowerPoint, on request only: a template on a deck (the card asks which decks), or a deck built from Copilot's outline. */
function pptxActions(ctx: CommandContext): Action[] {
  return [
    {
      id: "pptx-retheme",
      label: "Apply a PowerPoint template",
      description: "Put a deck's slides on the layouts of a template (.pptx or .potx in the project), with a choice of looks for what is not formatted; the new deck goes to Runbooks/Exports, both decks stay as they are",
      icon: icon(Presentation),
      end: "PowerPoint",
      onSelect: () => api.pptxPlan("", "").then(() => ctx.notice({ text: "Choose the template and the deck in the card below." }), (e) => ctx.fail((e as Error).message)),
    },
    {
      id: "pptx-outline",
      label: "Build a deck from an outline",
      description: "Copilot's deck outline (Work/NAME.deck.json) on the layouts of your template; the deck goes to Runbooks/Exports",
      icon: icon(Presentation),
      end: "PowerPoint",
      onSelect: () => api.pptxOutline().then(() => ctx.notice({ text: "Choose the outline and the template in the card below." }), (e) => ctx.fail((e as Error).message)),
    },
  ];
}

/** A diagnostics command that says it started, then where the file went. */
function reportAction(ctx: CommandContext, a: { id: string; label: string; description: string; icon: typeof FileText; busyText: string; doneText: string; run: () => Promise<{ path: string; fullPath?: string }> }): Action {
  return {
    id: a.id,
    label: a.label,
    description: a.description,
    icon: icon(a.icon),
    end: "Diagnostics",
    onSelect: () => {
      ctx.notice({ text: a.busyText });
      a.run().then(
        (r) => ctx.notice({ text: `${a.doneText}: ${r.path}`, path: r.fullPath }),
        (e) => ctx.fail((e as Error).message)
      );
    },
  };
}

/** Saving this chat as a test run, and the list of saved test runs to run again. */
function testRunCommands(ctx: CommandContext, show: (p: PaletteKind) => void, setTestRuns: (items: TestRunItem[]) => void): Action[] {
  const saveName = (ctx.state.project?.name || "Test").replace(/[^\w .-]/g, "").trim().slice(0, 48) || "Test";
  return [
    {
      id: "testrun-save",
      label: "Save this chat as a test run",
      description: `The requests of this project's chat, its data files and setup, as test run "${saveName}" to run again later`,
      icon: icon(ClipboardList),
      end: "Test runs",
      onSelect: () =>
        api.saveTestRun(saveName).then(
          (r) => ctx.notice({ text: `Test run saved with ${r.steps} step(s): ${r.path}`, path: r.fullPath }),
          (e) => ctx.fail((e as Error).message)
        ),
    },
    {
      id: "testruns",
      label: "Test runs",
      description: "Run a saved test run again in a new project, with a report compared with the last run",
      icon: icon(ClipboardList),
      end: "Test runs",
      onSelect: () =>
        api.testRuns().then(
          (r) => {
            if (!r.items.length) { ctx.notice({ text: `No test runs saved yet. Use "Save this chat as a test run" first; they are kept in ${r.dir}.` }); return; }
            setTestRuns(r.items);
            setTimeout(() => show("testruns"), 0);
          },
          (e) => ctx.fail((e as Error).message)
        ),
    },
  ];
}

/** The session report and the diagnostics zip. */
function reportActions(ctx: CommandContext): Action[] {
  return [
    reportAction(ctx, {
      id: "session-report",
      label: "Session report",
      description: "What happened since StreamHub started: tasks, failed steps, loops, nudges and slow parts, in one page",
      icon: FileText,
      busyText: "Writing the session report...",
      doneText: "Session report saved",
      run: api.sessionReport,
    }),
    reportAction(ctx, {
      id: "diagnostics",
      label: "Export diagnostics",
      description: "Zip logs and an environment summary to your desktop",
      icon: FileArchive,
      busyText: "Collecting diagnostics...",
      doneText: "Diagnostics saved",
      run: api.diagnostics,
    }),
  ];
}

/** One entry per mode; the current one says Active. */
function modeActions(ctx: CommandContext): Action[] {
  return MODES.map((m) => ({ id: `mode:${m.id}`, label: `Mode: ${m.label}`, description: m.description, icon: m.icon, end: ctx.state.mode === m.id ? "Active" : "Mode", onSelect: () => api.setMode(m.id as Mode) }));
}

function commandActions(ctx: CommandContext, show: (p: PaletteKind) => void, setTestRuns: (items: TestRunItem[]) => void, appEntry: string | null, setDataSources: (items: DataProfileSource[]) => void): Action[] {
  const later = (f: () => void) => () => setTimeout(f, 0);
  return [
    { id: "new-chat", label: "New chat", description: "Start a fresh Copilot chat; the project stays open", icon: icon(MessageSquarePlus), end: "Command", onSelect: ctx.startNewChat },
    { id: "undo", label: "Undo last change set", description: "Restore files from before the last message", icon: icon(RotateCcw), end: "Command", onSelect: () => api.undo() },
    { id: "settings", label: "Settings", icon: icon(Settings), end: "Command", onSelect: later(ctx.openSettings) },
    { id: "project", label: "Switch project", description: "Open or create a OneDrive project folder", icon: icon(FolderOpen), end: "Command", onSelect: ctx.openPicker },
    { id: "attach", label: "Attach a file to the message", description: "Adds @path so Copilot gets the file", icon: icon(AtSign), end: "Command", onSelect: later(() => show("attach")) },
    {
      // Opens a second list with the levels to choose from (loggingActions).
      id: "logging",
      label: `Logging: ${ctx.state.logLevel || "info"}`,
      description: "Choose how much the diagnostic log records; stays on after restarts",
      icon: icon(ScrollText),
      end: "Diagnostics",
      onSelect: later(() => show("logging")),
    },
    ...(appEntry ? exportActions(ctx, appEntry) : []),
    // The on-request project features: only with a project open, and only when picked here.
    ...(ctx.state.project ? shareActions(ctx) : []),
    ...(ctx.state.project ? projectCareActions(ctx) : []),
    ...(ctx.state.project ? pptxActions(ctx) : []),
    ...testRunCommands(ctx, show, setTestRuns),
    ...(ctx.state.project ? dataCommands<PaletteKind>(ctx, show, "dataprofile", setDataSources, api) : []),
    ...reportActions(ctx),
    ...modeActions(ctx),
    ...fileActions(ctx, false),
  ];
}

/** The command palette (Menu, Ctrl/Cmd+K) and its second lists: files to attach, logging levels, test runs, data files to profile. */
export function useCommandPalette(ctx: CommandContext) {
  const [palette, setPalette] = useState<PaletteKind | null>(null);
  const [testRuns, setTestRuns] = useState<TestRunItem[]>([]);
  const [dataSources, setDataSources] = useState<DataProfileSource[]>([]);
  const appEntry = useMemo(() => findAppEntry(ctx.files.map((f) => f.path)), [ctx.files]);

  // Ctrl/Cmd+K opens the command palette.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPalette((p) => (p ? null : "commands"));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const actionsFor: Record<PaletteKind, () => Action[]> = {
    commands: () => commandActions(ctx, setPalette, setTestRuns, appEntry, setDataSources),
    attach: () => fileActions(ctx, true),
    logging: () => loggingActions(ctx),
    testruns: () => testRunActions(ctx, testRuns),
    dataprofile: () => dataProfileActions(ctx, dataSources, api),
  };
  const element = palette && (
    <ModalBackdrop className="pt-24" onClose={() => setPalette(null)}>
      <div className="kit-dialog w-full max-w-xl px-4 pt-0 pb-4">
        <ActionSearchBar actions={actionsFor[palette]()} key={palette} label={PALETTE_TEXT[palette].label} onClose={() => setPalette(null)} placeholder={PALETTE_TEXT[palette].placeholder} />
      </div>
    </ModalBackdrop>
  );
  return { open: setPalette, element };
}
