import { ChevronRight, ExternalLink, File, FileClock, Folder, FolderCog, FolderLock, FolderOpen, FolderTree, HeartPulse, ListTodo, Lock, Plus, RefreshCw, SquareCheck, Square, Workflow } from "lucide-react";
import type React from "react";
import { createContext, useContext, useEffect, useMemo, useState } from "react";
import FileUpload from "@/components/kokonutui/file-upload";
import GradientButton from "@/components/kokonutui/gradient-button";
import { api } from "@/lib/api";
import { ChangePill } from "./change-pill";
import SmoothTab from "@/components/kokonutui/smooth-tab";
import type { ChainItem, ChangeSetView, FetchItem, FetchWeb, FileInfo, IssueReport, RunbookItem, RunbookTemplate, TodoItem } from "@/lib/api";

import { RunbooksPanel, runbookRows } from "./runbooks-panel";
import { ScriptsPanel } from "./scripts-panel";
import { HooksPanel } from "./hooks-panel";
import { ChainsPanel } from "./chains-panel";
import { QueuePanel } from "./queue-panel";
import { SchedulesList } from "./schedules-panel";
import { BetaTag } from "./beta-tag";
import { IssuesPanel } from "./issues-panel";
import { openSection, PanelSection, SectionButton, SectionCount } from "./panel-section";
import { ReviewPanel } from "./review-panel";
import type { Activity, QueueEntry, ScheduleItem } from "@/lib/api";
import type { ScheduleTarget } from "./schedule-form";
import { cn } from "@/lib/utils";
import { appEntryUrl, findAppEntry } from "@/lib/app-entry";
import { openExternal } from "@/lib/links";
import { readStored, readStoredJson, writeStored } from "@/lib/stored";
import { useIssueReport } from "@/lib/use-issue-report";
import { IndexBar } from "./index-bar";

interface TreeNode {
  name: string;
  path: string;
  size?: number;
  added?: number;
  removed?: number;
  /** Created since the project was opened. */
  created?: boolean;
  children?: TreeNode[];
}

/** Adds one file to the tree, creating the folders on its path as needed. */
function addFileToTree(root: TreeNode, f: FileInfo) {
  const parts = f.path.split("/");
  let node = root;
  parts.forEach((part, idx) => {
    const isFile = idx === parts.length - 1;
    node.children ??= [];
    let child = node.children.find((c) => c.name === part && Boolean(c.children) === !isFile);
    if (!child) {
      child = { name: part, path: parts.slice(0, idx + 1).join("/"), ...(isFile ? { size: f.size, added: f.added, removed: f.removed, created: f.created } : { children: [] }) };
      node.children.push(child);
    }
    node = child;
  });
}

/** Folders first, then files, each alphabetically; recursively. */
function sortTree(nodes: TreeNode[]) {
  nodes.sort((a, b) => (a.children ? 0 : 1) - (b.children ? 0 : 1) || a.name.localeCompare(b.name));
  for (const n of nodes) if (n.children) sortTree(n.children);
}

function buildTree(files: FileInfo[]): TreeNode[] {
  const root: TreeNode = { name: "", path: "", children: [] };
  for (const f of files) addFileToTree(root, f);
  sortTree(root.children!);
  return root.children!;
}

/** Lines added/removed in a file, or summed over a folder. */
function changeTotals(n: TreeNode): { added: number; removed: number } {
  if (!n.children) return { added: n.added ?? 0, removed: n.removed ?? 0 };
  return n.children.reduce(
    (t, c) => {
      const s = changeTotals(c);
      return { added: t.added + s.added, removed: t.removed + s.removed };
    },
    { added: 0, removed: 0 }
  );
}

/** A file created since the project was opened, or a folder holding only such files. */
function isNew(n: TreeNode): boolean {
  if (!n.children) return Boolean(n.created);
  return n.children.length > 0 && n.children.every(isNew);
}

/** The "new" tag next to a file or folder made in this session (shown with or without line counts). */
function NewTag({ node }: { node: TreeNode }) {
  if (!isNew(node)) return null;
  return (
    <span
      className="shrink-0 rounded px-1 font-medium text-[9px] text-muted-foreground uppercase tracking-wide ring-1 ring-black/15 dark:ring-white/20"
      title={node.children ? "New folder: everything in it was created since the project was opened" : "New file: created since the project was opened"}
    >
      new
    </span>
  );
}

/** Open issues per file path, from the project's issue index (shown next to each file). */
const IssueCounts = createContext<Map<string, number>>(new Map());

function IssueBadge({ path }: { path: string }) {
  const n = useContext(IssueCounts).get(path);
  if (!n) return null;
  return (
    <span className="ml-auto shrink-0 rounded px-1 text-[10px] text-muted-foreground ring-1 ring-black/10 dark:ring-white/15" title={`${n} open issue(s); see Issues in the Code health tab`}>
      {n}
    </span>
  );
}

function ChangeBadge({ node }: { node: TreeNode }) {
  const { added, removed } = changeTotals(node);
  if (!added && !removed) return null;
  return (
    <ChangePill added={added} className="ml-auto" removed={removed} title={`${added} line(s) added, ${removed} removed since the project was opened`} />
  );
}

// Tree guide lines: every item gets a short horizontal tick from its parent's vertical line; the
// vertical line stops at the last item's tick, as in a file explorer.
const LINE = "border-black/15 dark:border-white/15";
const ITEM = cn(
  "relative pl-4",
  "before:pointer-events-none before:absolute before:top-[14px] before:left-0 before:w-3 before:border-t before:content-['']",
  "after:pointer-events-none after:absolute after:top-0 after:left-0 after:h-full after:border-l after:content-[''] last:after:h-[14px]",
  "before:border-black/15 after:border-black/15 dark:before:border-white/15 dark:after:border-white/15"
);
const ROW = "flex h-7 w-full items-center gap-1.5 rounded-md px-1.5 text-left text-sm hover:bg-black/5 dark:hover:bg-white/5";

/** Folders you closed in the tree, for the whole tree at once (see useClosedFolders). */
const ClosedFolders = createContext<{ closed: Record<string, boolean>; toggle: (path: string) => void }>({ closed: {}, toggle: () => {} });

/**
 * The folders closed in this project's tree, kept in this browser per project: they stay closed
 * when you switch tabs, reload the page or come back to the project.
 */
function useClosedFolders(projectPath: string | undefined) {
  const key = `ccb.closedFolders.${(projectPath ?? "").toLowerCase()}`;
  const read = () => readStoredJson(key, {}, (v): v is Record<string, boolean> => Boolean(v) && typeof v === "object");
  const [stored, setClosed] = useState<Record<string, boolean>>(read);
  useEffect(() => setClosed(read()), [key]);
  // StreamHub's own folder starts closed; every other folder starts open.
  const byDefault = (path: string) => path === ".streamhub";
  const closed = new Proxy(stored, { get: (t, p: string) => (p in t ? t[p] : byDefault(p)) }) as Record<string, boolean>;
  const toggle = (path: string) =>
    setClosed((c) => {
      const next = { ...c };
      const now = path in next ? next[path] : byDefault(path);
      if (!now === byDefault(path)) delete next[path];
      else next[path] = !now;
      writeStored(key, JSON.stringify(next)); // storage blocked: closed until the page reloads
      return next;
    });
  return { closed, toggle };
}

/** An on/off choice remembered in this browser ("1" / "0" under the key). */
function useStoredFlag(key: string): [boolean, (on: boolean) => void] {
  const [on, setOn] = useState(() => readStored(key) === "1");
  const set = (v: boolean) => {
    setOn(v);
    writeStored(key, v ? "1" : "0");
  };
  return [on, set];
}

/** Open issues per file (ignored ones left out), the number of files indexed and when. */
function issueIndex(report: IssueReport | null) {
  const counts = new Map<string, number>();
  for (const i of report?.items ?? []) if (i.status !== "ignored") counts.set(i.path, (counts.get(i.path) ?? 0) + 1);
  return { counts, files: report?.summary?.files ?? 0, updated: report?.summary?.updated ?? null };
}

function TreeRows({ nodes, onOpen }: { nodes: TreeNode[]; onOpen: (p: string) => void }) {
  const { closed, toggle } = useContext(ClosedFolders);
  return (
    <ul>
      {nodes.map((n) => (
        <li className={ITEM} key={n.path}>
          {n.children ? (
            <>
              <button
                aria-expanded={!closed[n.path]}
                className={ROW}
                onClick={() => toggle(n.path)}
                title={n.path === ".streamhub" ? "StreamHub's own records: issues, imports, schedules, task reports, code reviews, earlier runbook results and plans. Not part of the project's code; Copilot does not see or change them." : n.path}
                type="button"
              >
                <ChevronRight className={cn("h-3.5 w-3.5 shrink-0 text-muted-foreground transition-transform", !closed[n.path] && "rotate-90")} />
                {/^source$/i.test(n.path) ? (
                  <FolderLock className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                ) : n.path === ".streamhub" ? (
                  <FolderCog className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                ) : (
                  <Folder className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                )}
                <span className="truncate">{n.name}</span>
                <NewTag node={n} />
                <ChangeBadge node={n} />
              </button>
              {!closed[n.path] && (
                <div className="ml-[13px]">
                  <TreeRows nodes={n.children} onOpen={onOpen} />
                </div>
              )}
            </>
          ) : (
            <button
              className={ROW}
              onClick={() => onOpen(n.path)}
              title={`${n.path} (${n.size} bytes)${/^source\//i.test(n.path) ? " - source data, read-only for Copilot" : ""}`}
              type="button"
            >
              {/^source\//i.test(n.path) ? (
                <Lock className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
              ) : (
                <File className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
              )}
              <span className="truncate">{n.name}</span>
              <NewTag node={n} />
              <ChangeBadge node={n} />
              <IssueBadge path={n.path} />
            </button>
          )}
        </li>
      ))}
    </ul>
  );
}

/** The project folder as the top of the tree; its OneDrive location shows on hover. */
function ProjectRoot({ project, children }: { project: { name: string; path: string; location?: string[] }; children: React.ReactNode }) {
  const where = project.location?.length ? project.location.join(" > ") : project.path;
  return (
    <div>
      <div className="flex h-7 items-center gap-1.5 rounded-md px-1.5 text-sm" title={`${where}\n${project.path}`}>
        <FolderOpen className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
        <span className="truncate font-medium">{project.name}</span>
        <button
          aria-label="Open the project folder in File Explorer"
          className="ml-auto shrink-0 rounded-md p-1 text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5"
          onClick={() => void api.showProject()}
          title="Open the project folder in File Explorer"
          type="button"
        >
          <ExternalLink className="h-3.5 w-3.5" />
        </button>
      </div>
      <div className={cn("ml-[13px]", LINE)}>{children}</div>
    </div>
  );
}

/** Files tab: source-data upload and the project tree under the project folder. */
function FilesPanel({
  files,
  onOpenFile,
  onUploaded,
  project,
  activity,
  issueStamp,
  refreshing = false,
  onShowIssues,
  previewBase,
}: {
  files: FileInfo[];
  onOpenFile: (path: string) => void;
  onUploaded: () => void;
  project?: { name: string; path: string; location?: string[] } | null;
  activity: Activity | null;
  issueStamp: string;
  refreshing?: boolean;
  onShowIssues?: () => void;
  /** Where the project is served read-only (/preview/TOKEN/): Open app opens its entry page there. */
  previewBase?: string;
}) {
  const entry = useMemo(() => findAppEntry(files.map((f) => f.path)), [files]);
  const tree = useMemo(() => buildTree(files), [files]);
  const folders = useClosedFolders(project?.path);
  // The issue index: open issues per file, reloaded when the project's details change.
  const indexing = Boolean(activity?.label);
  const report = useIssueReport(project, issueStamp, indexing);
  const index = useMemo(() => issueIndex(report), [report]);
  // The upload area is collapsed by default; the choice is remembered in this browser.
  const [uploadOpen, setUploadOpen] = useStoredFlag("ccb.uploadOpen");
  const rows = tree.length ? (
    <TreeRows nodes={tree} onOpen={onOpenFile} />
  ) : (
    <p className="p-2 text-muted-foreground text-sm">No files yet. Ask Copilot to create some.</p>
  );
  return (
    // Dragging a file over the panel opens the Add data section, so drag-and-drop works while it is folded.
    <div onDragEnter={() => setUploadOpen(true)}>
      <PanelSection
        id="files.source"
        onOpenChange={setUploadOpen}
        open={uploadOpen}
        summary="Read-only files for Copilot, in Source/. Drop files here."
        title="Add data"
      >
        <FileUpload
          className="max-w-none p-0"
          hint="Any file type. Copilot can read it but never change it;"
          maxFileSize={500 * 1024 * 1024}
          onUploadSuccess={onUploaded}
          title="Add source data"
          upload={api.uploadSource}
        />
      </PanelSection>
      {project && (
        <PanelSection
          actions={
            <SectionButton disabled={indexing} onClick={() => void api.reindexIssues(true)} title="Scan every file again">
              <RefreshCw className={cn("h-3.5 w-3.5", indexing && "animate-spin")} />
            </SectionButton>
          }
          id="files.index"
          title="Index"
        >
          <IndexBar activity={activity} files={index.files} onShowIssues={onShowIssues} updated={index.updated} withIssues={index.counts.size} />
        </PanelSection>
      )}
      <PanelSection
        actions={
          entry && previewBase ? (
            <a
              className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-muted-foreground text-xs hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5"
              href={appEntryUrl(previewBase, entry)}
              onClick={openExternal}
              rel="noopener noreferrer"
              target="_blank"
              title={`Open ${entry} in a new tab, served read-only by StreamHub (also works for built apps with module scripts)`}
            >
              <ExternalLink className="h-3.5 w-3.5" /> Open app
            </a>
          ) : null
        }
        id="files.tree"
        title="Files"
      >
        {/* While the tree refreshes: a thin bar sweeping left to right. */}
        <div aria-hidden className={cn("mb-1 h-0.5 overflow-hidden rounded-full", refreshing ? "bg-black/5 dark:bg-white/10" : "bg-transparent")}>
          {refreshing && <div className="h-full w-1/3 animate-[ccb-sweep_0.9s_ease-in-out_infinite] rounded-full bg-foreground/60" />}
        </div>
        <ClosedFolders.Provider value={folders}>
          <IssueCounts.Provider value={index.counts}>{project ? <ProjectRoot project={project}>{rows}</ProjectRoot> : rows}</IssueCounts.Provider>
        </ClosedFolders.Provider>
      </PanelSection>
    </div>
  );
}
function lastTab() {
  const t = readStored("ccb.sideTab");
  if (t === "fetch") return "automation"; // the Fetch tab became part of Automation
  return t && ["files", "tasks", "changes", "health", "automation"].includes(t) ? t : "files";
}

type SidePanelProps = {
  reviewTick: number;
  /** Changes when the project's issue details change. */
  issueStamp?: string;
  /** The file tree is being refreshed (a bar shows in the Files section). */
  filesRefreshing?: boolean;
  /** Where the project is served read-only, for Open app (/preview/TOKEN/). */
  previewBase?: string;
  /** What StreamHub is busy with besides Copilot (indexing, scanning). */
  activity?: Activity | null;
  schedules: ScheduleItem[];
  pausedUntil?: string | null;
  /** Opens the schedules modal: with a target to schedule it, or null for the list. */
  onSchedule: (target: ScheduleTarget | null) => void;
  files: FileInfo[];
  todos: TodoItem[];
  changes: ChangeSetView[];
  onOpenFile: (path: string) => void;
  /** Opens a file of a change set with the lines it added and removed (History). */
  onOpenChangeFile?: (changeSet: string, path: string) => void;
  onUndo: () => void;
  /** Undoes this change set and every newer one (History > Restore). */
  onUndoTo?: (changeSet: string) => void;
  onUploaded: () => void;
  busy: boolean;
  fetchItems: FetchItem[];
  onRunFetch: (name: string) => void;
  onSaveFetch: (name: string, prompt: string, web: FetchWeb) => Promise<void>;
  /** Opens the schedules window on this schedule's form. */
  onEditSchedule?: (s: ScheduleItem) => void;
  onAttach: (path: string) => void;
  project?: { name: string; path: string; location?: string[] } | null;
  runbooks: RunbookItem[];
  runbookTemplates: RunbookTemplate[];
  onCreateRunbook: (template: string, name: string) => Promise<void>;
  onRunRunbook: (name: string) => void;
  chains?: ChainItem[];
  /** Script files in Scripts/ a chain can run. */
  scripts?: string[];
  onCreateChain?: (name: string) => Promise<void>;
  onRunChain?: (name: string) => void;
  /** Runs one script from Scripts/ (Automation > Scripts). */
  onRunScript?: (path: string) => void;
  onChainSteps?: (name: string, op: "add" | "remove" | "up" | "down", opts?: { kind?: "runbook" | "script"; target?: string; args?: string; index?: number }) => Promise<void>;
  queue: QueueEntry[];
};

/** Actions tab: Copilot's checklist for the current task and the runs in the queue. */
function TasksPanel({
  todos,
  queue,
  pausedUntil,
  onOpenFile,
  onShowChange,
}: Pick<SidePanelProps, "todos" | "queue" | "pausedUntil" | "onOpenFile"> & { onShowChange: (seq: number) => void }) {
  const active = queue.filter((q) => q.status === "queued" || q.status === "running").length;
  return (
    <div>
      <PanelSection badge={todos.length ? <SectionCount n={todos.filter((t) => !t.done).length} /> : null} id="tasks.plan" title="Checklist">
      <div className="space-y-1">
      {todos.length ? (
        todos.map((t, i) => (
          <div className="flex items-start gap-2 text-sm" key={i}>
            {t.done ? (
              <SquareCheck className="mt-0.5 h-4 w-4 shrink-0 text-foreground" />
            ) : (
              <Square className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
            )}
            <span className={cn(t.done && "text-muted-foreground line-through")}>{t.text}</span>
          </div>
        ))
      ) : (
        <p className="text-muted-foreground text-sm">Copilot's checklist for the current task shows up here.</p>
      )}
      </div>
      </PanelSection>
      <PanelSection badge={active ? <SectionCount n={active} /> : null} id="tasks.queue" title="Runs">
        <QueuePanel onOpen={onOpenFile} onShowChange={onShowChange} pausedUntil={pausedUntil} queue={queue} />
      </PanelSection>
    </div>
  );
}

/** Restore on an older change set: a button, then a confirmation in its place. */
function RestoreControl({
  newer,
  busy,
  confirming,
  onAsk,
  onCancel,
  onRestore,
}: { newer: number; busy: boolean; confirming: boolean; onAsk: () => void; onCancel: () => void; onRestore: () => void }) {
  if (!confirming) {
    return (
      <button
        className="ml-auto shrink-0 rounded px-1 hover:bg-black/5 hover:text-foreground disabled:opacity-40 dark:hover:bg-white/5"
        disabled={busy}
        onClick={onAsk}
        title={`Put the files back as they were before this change set: undoes it and the ${newer} newer one(s), newest first`}
        type="button"
      >
        Restore
      </button>
    );
  }
  return (
    <span className="ml-auto flex shrink-0 items-center gap-1">
      <span>Restore: undo {newer + 1} change sets?</span>
      <button className="rounded bg-black/10 px-1.5 text-foreground hover:bg-black/15 dark:bg-white/15 dark:hover:bg-white/20" onClick={onRestore} type="button">
        Yes
      </button>
      <button className="rounded px-1.5 hover:bg-black/5 dark:hover:bg-white/5" onClick={onCancel} type="button">
        Cancel
      </button>
    </span>
  );
}

/** One change set in History: its time, title and files with their line counts. */
function ChangeSetCard({
  change: c,
  newer,
  lit,
  busy,
  confirming,
  onConfirm,
  onUndoTo,
  onOpenFile,
  onOpenChangeFile,
}: {
  change: ChangeSetView;
  /** How many change sets are newer (0 = the latest). */
  newer: number;
  lit: boolean;
  busy: boolean;
  confirming: boolean;
  onConfirm: (seq: number | null) => void;
  onUndoTo?: (changeSet: string) => void;
  onOpenFile: (path: string) => void;
  onOpenChangeFile?: (changeSet: string, path: string) => void;
}) {
  const counts = new Map((c.counts ?? []).map((x) => [x.path, x]));
  // Restore on an older change set; a confirmation that is open stays until it is answered.
  const restore = newer > 0 && Boolean(c.changeSet) && (Boolean(onUndoTo) || confirming);
  return (
    <div
      className={cn("rounded-lg border p-2 transition-colors", lit ? "border-black/40 bg-black/5 dark:border-white/40 dark:bg-white/10" : "border-black/10 dark:border-white/10")}
      id={`change-${c.seq}`}
    >
      <div className="mb-1 flex items-center gap-1.5 text-muted-foreground text-xs">
        {c.time}
        {newer === 0 && <span className="ml-auto shrink-0">latest: Undo takes this back</span>}
        {restore && (
          <RestoreControl
            busy={busy}
            confirming={confirming}
            newer={newer}
            onAsk={() => onConfirm(c.seq)}
            onCancel={() => onConfirm(null)}
            onRestore={() => {
              onConfirm(null);
              onUndoTo?.(c.changeSet as string);
            }}
          />
        )}
      </div>
      {c.title && (
        <div className="mb-1 line-clamp-2 text-sm" title={c.title}>
          {c.title}
        </div>
      )}
      {c.files.map((f) => {
        const n = counts.get(f);
        return (
          <button className="flex w-full items-center gap-2 mb-px text-left font-mono last:mb-0 text-xs hover:underline" key={f} onClick={() => (c.changeSet && onOpenChangeFile ? onOpenChangeFile(c.changeSet, f) : onOpenFile(f))} title={c.changeSet && onOpenChangeFile ? `${f}: the lines this change set added and removed` : f} type="button">
            <span className="min-w-0 flex-1 truncate">{f}</span>
            {n && (n.deleted ? <span className="shrink-0 font-sans text-muted-foreground">deleted</span> : <ChangePill added={n.added} removed={n.removed} />)}
          </button>
        );
      })}
    </div>
  );
}

/** History tab: Undo, and the change sets of this session, newest first. */
function ChangesPanel({
  changes,
  busy,
  litChange,
  confirmUndo,
  onConfirmUndo,
  onUndo,
  onUndoTo,
  onOpenFile,
  onOpenChangeFile,
}: Pick<SidePanelProps, "changes" | "busy" | "onUndo" | "onUndoTo" | "onOpenFile" | "onOpenChangeFile"> & {
  litChange: number | null;
  confirmUndo: number | null;
  onConfirmUndo: (seq: number | null) => void;
}) {
  return (
    <div>
      <div className="flex flex-col gap-2">
      <GradientButton
        className="h-9 w-full"
        disabled={busy || !changes.length}
        label="Undo last change set"
        onClick={onUndo}
        variant="subtle"
      />
      {changes.length ? (
        [...changes].reverse().map((c, i) => (
          <ChangeSetCard
            busy={busy}
            change={c}
            confirming={confirmUndo === c.seq}
            key={c.seq}
            lit={litChange === c.seq}
            newer={i}
            onConfirm={onConfirmUndo}
            onOpenChangeFile={onOpenChangeFile}
            onOpenFile={onOpenFile}
            onUndoTo={onUndoTo}
          />
        ))
      ) : (
        <p className="text-muted-foreground text-sm">Files changed in this session are listed here. Each message is one undoable change set.</p>
      )}
      </div>
    </div>
  );
}

/** Code health tab: the issues and the code review. */
function HealthPanel({
  openIssues,
  activity,
  issueStamp,
  reviewTick,
  onOpenFile,
}: { openIssues: number; activity: Activity | null; issueStamp: string; reviewTick: number; onOpenFile: (path: string) => void }) {
  return (
    <div>
      <PanelSection
        badge={
          <>
            {openIssues > 0 && <SectionCount n={openIssues} />}
            <BetaTag title="Beta: still being refined. The checks run without a language model and can miss problems or report ones that are not real; use Ignore for those." />
          </>
        }
        id="health.issues"
        title="Issues"
      >
        <IssuesPanel activity={activity} onOpen={onOpenFile} tick={issueStamp} />
      </PanelSection>
      <PanelSection
        badge={<BetaTag title="Beta: still being refined. Findings are checked against the files, but review them before fixing." />}
        id="health.review"
        title="Code review"
      >
        <ReviewPanel onOpen={onOpenFile} tick={reviewTick} />
      </PanelSection>
    </div>
  );
}

/** Automation tab: schedules, runbooks, scripts, hooks and chains. */
function AutomationPanel({
  schedules,
  onSchedule,
  onEditSchedule,
  runbooks,
  runbookTemplates,
  fetchItems,
  busy,
  onAttach,
  onCreateRunbook,
  onSaveFetch,
  onOpenFile,
  onRunFetch,
  onRunRunbook,
  scripts,
  onRunScript,
  files,
  chains,
  onCreateChain,
  onRunChain,
  onChainSteps,
}: Pick<
  SidePanelProps,
  | "schedules"
  | "onSchedule"
  | "onEditSchedule"
  | "runbooks"
  | "runbookTemplates"
  | "fetchItems"
  | "busy"
  | "onAttach"
  | "onCreateRunbook"
  | "onSaveFetch"
  | "onOpenFile"
  | "onRunFetch"
  | "onRunRunbook"
  | "onRunScript"
  | "files"
  | "onCreateChain"
  | "onRunChain"
  | "onChainSteps"
> & { scripts: string[]; chains: ChainItem[] }) {
  return (
    <div>
      <PanelSection badge={schedules.length ? <SectionCount n={schedules.length} /> : null} id="automation.scheduled" title="Scheduled">
        <div className="space-y-2">
          <button
            className="inline-flex w-full items-center justify-center gap-1 rounded-md border border-black/10 px-2 py-1.5 text-xs hover:bg-black/5 dark:border-white/10 dark:hover:bg-white/5"
            onClick={() => onSchedule({ kind: "chat" })}
            type="button"
          >
            <Plus className="h-3.5 w-3.5" /> New schedule
          </button>
          <SchedulesList onEdit={onEditSchedule} schedules={schedules} />
        </div>
      </PanelSection>
      <PanelSection badge={runbooks.length + fetchItems.length ? <SectionCount n={runbooks.length + fetchItems.length} /> : null} id="automation.runbooks" title="Runbooks">
        <RunbooksPanel
          busy={busy}
          onAttach={onAttach}
          onCreate={onCreateRunbook}
          onCreateText={onSaveFetch}
          onOpen={onOpenFile}
          onRun={(kind, name) => (kind === "text" ? onRunFetch(name) : onRunRunbook(name))}
          onSchedule={(kind, name) => onSchedule({ kind: kind === "text" ? "fetch" : "runbook", name })}
          runbooks={runbooks}
          templates={runbookTemplates}
          texts={fetchItems}
        />
      </PanelSection>
      {onRunScript && (
        <PanelSection badge={scripts.length ? <SectionCount n={scripts.length} /> : null} id="automation.scripts" title="Scripts">
          <ScriptsPanel busy={busy} onOpen={onOpenFile} onRun={onRunScript} onSchedule={(path) => onSchedule({ kind: "script", name: path })} scripts={scripts} />
        </PanelSection>
      )}
      <PanelSection id="automation.hooks" title="Hooks">
        <HooksPanel onOpen={onOpenFile} refreshKey={files} />
      </PanelSection>
      {onCreateChain && onRunChain && (
        <PanelSection badge={chains.length ? <SectionCount n={chains.length} /> : null} id="automation.chains" title="Chains">
          <ChainsPanel
            busy={busy}
            chains={chains}
            onCreate={onCreateChain}
            onOpen={onOpenFile}
            onRun={onRunChain}
            onSchedule={(name) => onSchedule({ kind: "chain", name })}
            onSteps={onChainSteps}
            runbookNames={runbookRows(runbooks, fetchItems).map((r) => ({ name: r.name, title: r.kind === "text" ? `${r.title} (text)` : r.title }))}
            scripts={scripts}
          />
        </PanelSection>
      )}
    </div>
  );
}

export function SidePanel(props: SidePanelProps) {
  const { files, todos, changes, onOpenFile, onUndo, onUndoTo, onUploaded, busy, project, queue, pausedUntil, reviewTick } = props;
  const { chains = [], scripts = [], issueStamp = "", activity = null, filesRefreshing = false } = props;
  // "N file(s) with issues" on the Files tab leads to Changes > Issues: the section is opened,
  // the tab switched, and the section scrolled into view once it is shown.
  const [tabRequest, setTabRequest] = useState<{ id: string; n: number } | null>(null);
  // Open issues (not ignored) for the count next to the Issues heading; reloaded like the index line.
  const report = useIssueReport(project, issueStamp, Boolean(activity?.label));
  const openIssues = project && report ? report.items.filter((i) => i.status !== "ignored").length : 0;
  const showIssues = () => {
    openSection("health.issues");
    setTabRequest((r) => ({ id: "health", n: (r?.n ?? 0) + 1 }));
    window.setTimeout(() => document.getElementById("section-health.issues")?.scrollIntoView({ behavior: "smooth", block: "start" }), 450);
  };
  // From Runs: the History tab, scrolled to that task's change set, which lights up briefly.
  const [litChange, setLitChange] = useState<number | null>(null);
  const [confirmUndo, setConfirmUndo] = useState<number | null>(null);
  const showChange = (seq: number) => {
    setTabRequest((r) => ({ id: "changes", n: (r?.n ?? 0) + 1 }));
    setLitChange(seq);
    window.setTimeout(() => document.getElementById(`change-${seq}`)?.scrollIntoView({ behavior: "smooth", block: "center" }), 450);
    window.setTimeout(() => setLitChange((x) => (x === seq ? null : x)), 2500);
  };

  return (
    <SmoothTab
      columns={2}
      request={tabRequest}
      defaultTabId={lastTab()}
      onChange={(id) => writeStored("ccb.sideTab", id)} // per browser: the side panel reopens on this tab
      items={[
        {
          id: "files",
          title: "Files",
          icon: FolderTree,
          color: "bg-zinc-700 dark:bg-muted",
          content: (
            <FilesPanel activity={activity} files={files} issueStamp={issueStamp} onShowIssues={showIssues} previewBase={props.previewBase} refreshing={filesRefreshing} onOpenFile={onOpenFile} onUploaded={onUploaded} project={project} />
          ),
        },
        { id: "automation", title: "Automation", icon: Workflow, color: "bg-zinc-700 dark:bg-muted", content: <AutomationPanel {...props} chains={chains} scripts={scripts} /> },
        {
          id: "changes",
          title: "History",
          icon: FileClock,
          color: "bg-zinc-700 dark:bg-muted",
          content: (
            <ChangesPanel
              busy={busy}
              changes={changes}
              confirmUndo={confirmUndo}
              litChange={litChange}
              onConfirmUndo={setConfirmUndo}
              onOpenChangeFile={props.onOpenChangeFile}
              onOpenFile={onOpenFile}
              onUndo={onUndo}
              onUndoTo={onUndoTo}
            />
          ),
        },
        { id: "tasks", title: "Actions", icon: ListTodo, color: "bg-zinc-700 dark:bg-muted", content: <TasksPanel onOpenFile={onOpenFile} onShowChange={showChange} pausedUntil={pausedUntil} queue={queue} todos={todos} /> },
        {
          id: "health",
          title: "Code health",
          icon: HeartPulse,
          color: "bg-zinc-700 dark:bg-muted",
          badge: <BetaTag title="Beta: Issues and Code review are still being refined; their checks run without a language model and can miss problems or report ones that are not real." />,
          content: <HealthPanel activity={activity} issueStamp={issueStamp} onOpenFile={onOpenFile} openIssues={openIssues} reviewTick={reviewTick} />,
        },
      ]}
    />
  );
}
