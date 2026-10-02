import { ChevronRight, CloudDownload, ExternalLink, File, FileClock, Folder, FolderLock, FolderOpen, FolderTree, ListTodo, Lock, RotateCcw, SquareCheck, Square } from "lucide-react";
import type React from "react";
import { useMemo, useState } from "react";
import FileUpload from "@/components/kokonutui/file-upload";
import GradientButton from "@/components/kokonutui/gradient-button";
import { api } from "@/lib/api";
import { ChangePill } from "./change-pill";
import SmoothTab from "@/components/kokonutui/smooth-tab";
import type { FetchItem, FileInfo, RunbookItem, RunbookTemplate, TodoItem } from "@/lib/api";
import { FetchPanel } from "./fetch-panel";
import { RunbooksPanel } from "./runbooks-panel";
import { QueuePanel } from "./queue-panel";
import type { QueueEntry } from "@/lib/api";
import { cn } from "@/lib/utils";

interface TreeNode {
  name: string;
  path: string;
  size?: number;
  added?: number;
  removed?: number;
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
      child = { name: part, path: parts.slice(0, idx + 1).join("/"), ...(isFile ? { size: f.size, added: f.added, removed: f.removed } : { children: [] }) };
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

function TreeRows({ nodes, onOpen }: { nodes: TreeNode[]; onOpen: (p: string) => void }) {
  const [closed, setClosed] = useState<Record<string, boolean>>({});
  return (
    <ul>
      {nodes.map((n) => (
        <li className={ITEM} key={n.path}>
          {n.children ? (
            <>
              <button className={ROW} onClick={() => setClosed((c) => ({ ...c, [n.path]: !c[n.path] }))} title={n.path} type="button">
                <ChevronRight className={cn("h-3.5 w-3.5 shrink-0 text-muted-foreground transition-transform", !closed[n.path] && "rotate-90")} />
                {n.path === "source" ? (
                  <FolderLock className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                ) : (
                  <Folder className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                )}
                <span className="truncate">{n.name}</span>
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
              <ChangeBadge node={n} />
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
          className="ml-auto shrink-0 rounded p-0.5 text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5"
          onClick={() => api.showProject()}
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
}: {
  files: FileInfo[];
  onOpenFile: (path: string) => void;
  onUploaded: () => void;
  project?: { name: string; path: string; location?: string[] } | null;
}) {
  const tree = useMemo(() => buildTree(files), [files]);
  const rows = tree.length ? (
    <TreeRows nodes={tree} onOpen={onOpenFile} />
  ) : (
    <p className="p-2 text-muted-foreground text-sm">No files yet. Ask Copilot to create some.</p>
  );
  return (
    <div className="p-2">
      <FileUpload
        className="mb-2 max-w-none"
        hint="Any file type. Copilot can read it but never change it;"
        maxFileSize={500 * 1024 * 1024}
        onUploadSuccess={onUploaded}
        title="Add source data"
        upload={api.uploadSource}
      />
      {project ? <ProjectRoot project={project}>{rows}</ProjectRoot> : rows}
    </div>
  );
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
  queue,
}: {
  files: FileInfo[];
  todos: TodoItem[];
  changes: { seq: number; time: string; files: string[] }[];
  onOpenFile: (path: string) => void;
  onUndo: () => void;
  onUploaded: () => void;
  busy: boolean;
  fetchItems: FetchItem[];
  onRunFetch: (name: string) => void;
  onSaveFetch: (name: string, prompt: string) => Promise<void>;
  onAttach: (path: string) => void;
  project?: { name: string; path: string; location?: string[] } | null;
  runbooks: RunbookItem[];
  runbookTemplates: RunbookTemplate[];
  onCreateRunbook: (template: string, name: string) => Promise<void>;
  onRunRunbook: (name: string) => void;
  queue: QueueEntry[];
}) {
  const filesPanel = <FilesPanel files={files} onOpenFile={onOpenFile} onUploaded={onUploaded} project={project} />;

  const tasksPanel = (
    <div className="space-y-4 p-3">
      <div className="space-y-1">
      <div className="font-medium text-sm">Plan</div>
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
      <div className="space-y-1.5 border-black/10 border-t pt-3 dark:border-white/10">
        <div className="font-medium text-sm">Queue</div>
        <QueuePanel onOpen={onOpenFile} queue={queue} />
      </div>
    </div>
  );

  const changesPanel = (
    <div className="flex h-full flex-col gap-3 p-3">
      <GradientButton
        className="h-10 w-full"
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
  );

  return (
    <SmoothTab
      columns={2}
      defaultTabId="files"
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
              <div className="border-black/10 border-b p-3 dark:border-white/10">
                <RunbooksPanel
                  busy={busy}
                  onAttach={onAttach}
                  onCreate={onCreateRunbook}
                  onOpen={onOpenFile}
                  onRun={onRunRunbook}
                  runbooks={runbooks}
                  templates={runbookTemplates}
                />
              </div>
              <FetchPanel busy={busy} items={fetchItems} onAttach={onAttach} onOpen={onOpenFile} onRun={onRunFetch} onSave={onSaveFetch} />
            </div>
          ),
        },
      ]}
    />
  );
}
