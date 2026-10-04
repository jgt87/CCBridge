import { ChevronRight, CloudDownload, ExternalLink, File, FileClock, Folder, FolderLock, FolderOpen, FolderTree, ListTodo, Lock, RefreshCw, RotateCcw, SquareCheck, Square } from "lucide-react";
import type React from "react";
import { createContext, useContext, useEffect, useMemo, useState } from "react";
import FileUpload from "@/components/kokonutui/file-upload";
import GradientButton from "@/components/kokonutui/gradient-button";
import { api } from "@/lib/api";
import { ChangePill } from "./change-pill";
import SmoothTab from "@/components/kokonutui/smooth-tab";
import type { ChainItem, FetchItem, FetchWeb, FileInfo, RunbookItem, RunbookTemplate, TodoItem } from "@/lib/api";
import { FetchPanel } from "./fetch-panel";
import { RunbooksPanel } from "./runbooks-panel";
import { ChainsPanel } from "./chains-panel";
import { QueuePanel } from "./queue-panel";
import { SchedulesSummary } from "./schedules-modal";
import { BetaTag } from "./beta-tag";
import { IssuesPanel } from "./issues-panel";
import { openSection, PanelSection, SectionButton, SectionCount } from "./panel-section";
import { ReviewPanel } from "./review-panel";
import type { Activity, QueueEntry, ScheduleItem } from "@/lib/api";
import type { ScheduleTarget } from "./schedule-form";
import { cn } from "@/lib/utils";

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
    <span className="ml-auto shrink-0 rounded px-1 text-[10px] text-muted-foreground ring-1 ring-black/10 dark:ring-white/15" title={`${n} open issue(s); see Issues in the Changes tab`}>
      {n}
    </span>
  );
}

/** The issue index of the project: a bar that runs left to right while it indexes, and a short status line. */
function IndexBar({
  activity,
  files,
  withIssues,
  updated,
  onShowIssues,
}: { activity: Activity | null; files: number; withIssues: number; updated: string | null; onShowIssues?: () => void }) {
  const running = Boolean(activity?.label);
  const pct = running && activity?.total ? Math.min(100, Math.round((activity.done / activity.total) * 100)) : null;
  const when = updated ? new Date(updated).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "";
  return (
    <div>
      <div className="flex min-w-0 items-center gap-1 text-muted-foreground text-xs">
        {running ? (
          <span className="truncate">{`${activity?.label.replace(/ for issues.*$/, "")}...`}</span>
        ) : files && !withIssues ? (
          // Nothing found: only when it was indexed, no issue text.
          <span className="truncate">{`Indexed${when ? ` at ${when}` : ""}`}</span>
        ) : files ? (
          <>
            <span className="shrink-0">{`Indexed${when ? ` at ${when}` : ""},`}</span>
            {onShowIssues ? (
              // The issue count leads to the issues overview (Changes tab > Issues).
              <button className="min-w-0 truncate underline-offset-2 hover:text-foreground hover:underline" onClick={onShowIssues} title="Show the issues (Changes tab)" type="button">
                {`${withIssues} file(s) with issues`}
              </button>
            ) : (
              <span className="truncate">{`${withIssues} file(s) with issues`}</span>
            )}
            <BetaTag title="Beta: still being refined. The checks run without a language model and can miss problems or report ones that are not real." />
          </>
        ) : (
          <span className="truncate">Not indexed yet</span>
        )}
      </div>
      {/* The bar only while an index run is busy. */}
      {running && (
        <div className="mt-1.5 h-0.5 w-full overflow-hidden rounded-full bg-black/5 dark:bg-white/10">
          <div
            className={cn("h-full rounded-full bg-foreground/60 transition-[width] duration-500", pct === null && "w-1/3 animate-pulse")}
            style={pct === null ? undefined : { width: `${pct}%` }}
          />
        </div>
      )}
    </div>
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
  const read = () => {
    try {
      const v = JSON.parse(localStorage.getItem(key) ?? "{}");
      return v && typeof v === "object" ? (v as Record<string, boolean>) : {};
    } catch {
      return {};
    }
  };
  const [closed, setClosed] = useState<Record<string, boolean>>(read);
  useEffect(() => setClosed(read()), [key]);
  const toggle = (path: string) =>
    setClosed((c) => {
      const next = { ...c };
      if (next[path]) delete next[path];
      else next[path] = true;
      try {
        localStorage.setItem(key, JSON.stringify(next));
      } catch {
        /* storage blocked: closed until the page reloads */
      }
      return next;
    });
  return { closed, toggle };
}

function TreeRows({ nodes, onOpen }: { nodes: TreeNode[]; onOpen: (p: string) => void }) {
  const { closed, toggle } = useContext(ClosedFolders);
  return (
    <ul>
      {nodes.map((n) => (
        <li className={ITEM} key={n.path}>
          {n.children ? (
            <>
              <button aria-expanded={!closed[n.path]} className={ROW} onClick={() => toggle(n.path)} title={n.path} type="button">
                <ChevronRight className={cn("h-3.5 w-3.5 shrink-0 text-muted-foreground transition-transform", !closed[n.path] && "rotate-90")} />
                {n.path === "source" ? (
                  <FolderLock className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
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
              title={`${n.path} (${n.size} bytes)${n.path.startsWith("source/") ? " - source data, read-only for Copilot" : ""}`}
              type="button"
            >
              {n.path.startsWith("source/") ? (
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
}: {
  files: FileInfo[];
  onOpenFile: (path: string) => void;
  onUploaded: () => void;
  project?: { name: string; path: string; location?: string[] } | null;
  activity: Activity | null;
  issueStamp: string;
  refreshing?: boolean;
  onShowIssues?: () => void;
}) {
  const tree = useMemo(() => buildTree(files), [files]);
  const folders = useClosedFolders(project?.path);
  // The issue index: open issues per file, reloaded when the project's details change.
  const [index, setIndex] = useState<{ counts: Map<string, number>; files: number; updated: string | null }>({ counts: new Map(), files: 0, updated: null });
  const indexing = Boolean(activity?.label);
  useEffect(() => {
    if (!project) return;
    const load = () =>
      api.issues().then(
        (r) => {
          const counts = new Map<string, number>();
          for (const i of r.items) if (i.status !== "ignored") counts.set(i.path, (counts.get(i.path) ?? 0) + 1);
          setIndex({ counts, files: r.summary?.files ?? 0, updated: r.summary?.updated ?? null });
        },
        () => undefined
      );
    load();
    if (!indexing) return;
    const t = window.setInterval(load, 3000);
    return () => window.clearInterval(t);
  }, [project, issueStamp, indexing]);
  // The upload area is collapsed by default; the choice is remembered in this browser.
  const [uploadOpen, setUploadOpenState] = useState(() => {
    try {
      return localStorage.getItem("ccb.uploadOpen") === "1";
    } catch {
      return false;
    }
  });
  const setUploadOpen = (open: boolean) => {
    setUploadOpenState(open);
    try {
      localStorage.setItem("ccb.uploadOpen", open ? "1" : "0");
    } catch {
      /* storage blocked: only this session remembers it */
    }
  };
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
        summary="Read-only files for Copilot, in source/. Drop files here."
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
          project && (
            <SectionButton onClick={() => void api.showProject()} title="Open the project folder in File Explorer">
              <ExternalLink className="h-3.5 w-3.5" />
            </SectionButton>
          )
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
  try {
    const t = localStorage.getItem("ccb.sideTab");
    return t && ["files", "tasks", "changes", "fetch"].includes(t) ? t : "files";
  } catch {
    return "files";
  }
}

export function SidePanel({
  files,
  todos,
  changes,
  onOpenFile,
  onUndo,
  onUploaded,
  busy,
  fetchItems,
  onRunFetch,
  onSaveFetch,
  onAttach,
  project,
  runbooks,
  runbookTemplates,
  onCreateRunbook,
  onRunRunbook,
  chains = [],
  scripts = [],
  onCreateChain,
  onRunChain,
  queue,
  schedules,
  pausedUntil,
  onSchedule,
  reviewTick,
  issueStamp = "",
  activity = null,
  filesRefreshing = false,
}: {
  reviewTick: number;
  /** Changes when the project's issue details change. */
  issueStamp?: string;
  /** The file tree is being refreshed (a bar shows in the Files section). */
  filesRefreshing?: boolean;
  /** What StreamHub is busy with besides Copilot (indexing, scanning). */
  activity?: Activity | null;
  schedules: ScheduleItem[];
  pausedUntil?: string | null;
  /** Opens the schedules modal: with a target to schedule it, or null for the list. */
  onSchedule: (target: ScheduleTarget | null) => void;
  files: FileInfo[];
  todos: TodoItem[];
  changes: { seq: number; time: string; files: string[] }[];
  onOpenFile: (path: string) => void;
  onUndo: () => void;
  onUploaded: () => void;
  busy: boolean;
  fetchItems: FetchItem[];
  onRunFetch: (name: string) => void;
  onSaveFetch: (name: string, prompt: string, web: FetchWeb) => Promise<void>;
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
  queue: QueueEntry[];
}) {
  // "N file(s) with issues" on the Files tab leads to Changes > Issues: the section is opened,
  // the tab switched, and the section scrolled into view once it is shown.
  const [tabRequest, setTabRequest] = useState<{ id: string; n: number } | null>(null);
  // Open issues (not ignored) for the count next to the Issues heading; reloaded like the index line.
  const [openIssues, setOpenIssues] = useState(0);
  const issuesBusy = Boolean(activity?.label);
  useEffect(() => {
    if (!project) {
      setOpenIssues(0);
      return;
    }
    const load = () => api.issues().then((r) => setOpenIssues(r.items.filter((i) => i.status !== "ignored").length), () => undefined);
    load();
    if (!issuesBusy) return;
    const t = window.setInterval(load, 3000);
    return () => window.clearInterval(t);
  }, [project, issueStamp, issuesBusy]);
  const showIssues = () => {
    openSection("changes.issues");
    setTabRequest((r) => ({ id: "changes", n: (r?.n ?? 0) + 1 }));
    window.setTimeout(() => document.getElementById("section-changes.issues")?.scrollIntoView({ behavior: "smooth", block: "start" }), 450);
  };
  const filesPanel = (
    <FilesPanel activity={activity} files={files} issueStamp={issueStamp} onShowIssues={showIssues} refreshing={filesRefreshing} onOpenFile={onOpenFile} onUploaded={onUploaded} project={project} />
  );

  const tasksPanel = (
    <div>
      <PanelSection badge={todos.length ? <SectionCount n={todos.filter((t) => !t.done).length} /> : null} id="tasks.plan" title="Plan">
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
        <p className="text-muted-foreground text-sm">Copilot's plan for the current task shows up here.</p>
      )}
      </div>
      </PanelSection>
      <PanelSection
        badge={queue.some((q) => q.status === "queued" || q.status === "running") ? <SectionCount n={queue.filter((q) => q.status === "queued" || q.status === "running").length} /> : null}
        id="tasks.queue"
        title="Queue"
      >
        <QueuePanel onOpen={onOpenFile} pausedUntil={pausedUntil} queue={queue} />
      </PanelSection>
      <PanelSection id="tasks.scheduled" title="Scheduled">
        <SchedulesSummary onOpen={() => onSchedule(null)} schedules={schedules} />
      </PanelSection>
    </div>
  );

  const changesPanel = (
    <div>
      <PanelSection badge={changes.length ? <SectionCount n={changes.length} /> : null} id="changes.sets" title="Change sets">
      <div className="flex flex-col gap-2">
      <GradientButton
        className="h-9 w-full"
        disabled={busy || !changes.length}
        label="Undo last change set"
        onClick={onUndo}
        variant="subtle"
      />
      {changes.length ? (
        [...changes].reverse().map((c) => (
          <div className="rounded-lg border border-black/10 p-2 dark:border-white/10" key={c.seq}>
            <div className="mb-1 flex items-center gap-1.5 text-muted-foreground text-xs">
              <RotateCcw className="h-3 w-3" /> {c.time}
            </div>
            {c.files.map((f) => (
              <button
                className="block w-full truncate text-left font-mono text-xs hover:underline"
                key={f}
                onClick={() => onOpenFile(f)}
                type="button"
              >
                {f}
              </button>
            ))}
          </div>
        ))
      ) : (
        <p className="text-muted-foreground text-sm">Files changed in this session are listed here. Each message is one undoable change set.</p>
      )}
      </div>
      </PanelSection>
      <PanelSection
        badge={
          <>
            {openIssues > 0 && <SectionCount n={openIssues} />}
            <BetaTag title="Beta: still being refined. The checks run without a language model and can miss problems or report ones that are not real; use Ignore for those." />
          </>
        }
        id="changes.issues"
        title="Issues"
      >
        <IssuesPanel activity={activity} onOpen={onOpenFile} tick={issueStamp} />
      </PanelSection>
      <PanelSection
        badge={<BetaTag title="Beta: still being refined. Findings are checked against the files, but review them before fixing." />}
        id="changes.review"
        title="Code review"
      >
        <ReviewPanel onOpen={onOpenFile} tick={reviewTick} />
      </PanelSection>
    </div>
  );

  return (
    <SmoothTab
      columns={2}
      request={tabRequest}
      defaultTabId={lastTab()}
      onChange={(id) => {
        try {
          localStorage.setItem("ccb.sideTab", id); // per browser: the side panel reopens on this tab
        } catch {
          /* storage blocked */
        }
      }}
      items={[
        { id: "files", title: "Files", icon: FolderTree, color: "bg-zinc-700", content: filesPanel },
        { id: "tasks", title: "Tasks", icon: ListTodo, color: "bg-zinc-700", content: tasksPanel },
        { id: "changes", title: "Changes", icon: FileClock, color: "bg-zinc-700", content: changesPanel },
        {
          id: "fetch",
          title: "Fetch",
          icon: CloudDownload,
          color: "bg-zinc-700",
          content: (
            <div>
              <PanelSection badge={runbooks.length ? <SectionCount n={runbooks.length} /> : null} id="fetch.runbooks" title="Runbooks">
                <RunbooksPanel
                  busy={busy}
                  onAttach={onAttach}
                  onCreate={onCreateRunbook}
                  onOpen={onOpenFile}
                  onRun={onRunRunbook}
                  onSchedule={(name) => onSchedule({ kind: "runbook", name })}
                  runbooks={runbooks}
                  templates={runbookTemplates}
                />
              </PanelSection>
              {onCreateChain && onRunChain && (
                <PanelSection badge={chains.length ? <SectionCount n={chains.length} /> : null} id="fetch.chains" title="Chains">
                  <ChainsPanel
                    busy={busy}
                    chains={chains}
                    onCreate={onCreateChain}
                    onOpen={onOpenFile}
                    onRun={onRunChain}
                    onSchedule={(name) => onSchedule({ kind: "chain", name })}
                    scripts={scripts}
                  />
                </PanelSection>
              )}
              <PanelSection badge={fetchItems.length ? <SectionCount n={fetchItems.length} /> : null} id="fetch.prompts" title="Fetch prompts">
                <FetchPanel busy={busy} items={fetchItems} onAttach={onAttach} onOpen={onOpenFile} onRun={onRunFetch} onSave={onSaveFetch} onSchedule={(name) => onSchedule({ kind: "fetch", name })} />
              </PanelSection>
            </div>
          ),
        },
      ]}
    />
  );
}
