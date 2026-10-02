import { ChevronRight, CloudDownload, File, FileClock, Folder, FolderLock, FolderTree, ListTodo, Lock, RotateCcw, SquareCheck, Square } from "lucide-react";
import { useMemo, useState } from "react";
import FileUpload from "@/components/kokonutui/file-upload";
import GradientButton from "@/components/kokonutui/gradient-button";
import { api } from "@/lib/api";
import { ChangePill } from "./change-pill";
import SmoothTab from "@/components/kokonutui/smooth-tab";
import type { FetchItem, FileInfo, TodoItem } from "@/lib/api";
import { FetchPanel } from "./fetch-panel";
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

function TreeRows({ nodes, depth, onOpen }: { nodes: TreeNode[]; depth: number; onOpen: (p: string) => void }) {
  const [closed, setClosed] = useState<Record<string, boolean>>({});
  return (
    <>
      {nodes.map((n) =>
        n.children ? (
          <div key={n.path}>
            <button
              className="flex w-full items-center gap-1.5 rounded-md px-2 py-1 text-left text-sm hover:bg-black/5 dark:hover:bg-white/5"
              onClick={() => setClosed((c) => ({ ...c, [n.path]: !c[n.path] }))}
              style={{ paddingLeft: 8 + depth * 14 }}
              type="button"
            >
              <ChevronRight className={cn("h-3.5 w-3.5 text-muted-foreground transition-transform", !closed[n.path] && "rotate-90")} />
              {n.path === "source" ? (
                <FolderLock className="h-3.5 w-3.5 text-muted-foreground" />
              ) : (
                <Folder className="h-3.5 w-3.5 text-muted-foreground" />
              )}
              <span className="truncate">{n.name}</span>
              <ChangeBadge node={n} />
            </button>
            {!closed[n.path] && <TreeRows depth={depth + 1} nodes={n.children} onOpen={onOpen} />}
          </div>
        ) : (
          <button
            className="flex w-full items-center gap-1.5 rounded-md px-2 py-1 text-left text-sm hover:bg-black/5 dark:hover:bg-white/5"
            key={n.path}
            onClick={() => onOpen(n.path)}
            style={{ paddingLeft: 26 + depth * 14 }}
            title={`${n.path} (${n.size} bytes)${n.path.startsWith("source/") ? " - source data, read-only for Copilot" : ""}`}
            type="button"
          >
            {n.path.startsWith("source/") ? (
              <Lock className="h-3.5 w-3.5 text-muted-foreground" />
            ) : (
              <File className="h-3.5 w-3.5 text-muted-foreground" />
            )}
            <span className="truncate">{n.name}</span>
            <ChangeBadge node={n} />
          </button>
        )
      )}
    </>
  );
}

/** Files tab: source-data upload and the project tree. */
function FilesPanel({ files, onOpenFile, onUploaded }: { files: FileInfo[]; onOpenFile: (path: string) => void; onUploaded: () => void }) {
  const tree = useMemo(() => buildTree(files), [files]);
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
      {tree.length ? (
        <TreeRows depth={0} nodes={tree} onOpen={onOpenFile} />
      ) : (
        <p className="p-3 text-muted-foreground text-sm">No files yet. Ask Copilot to create some.</p>
      )}
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
}) {
  const filesPanel = <FilesPanel files={files} onOpenFile={onOpenFile} onUploaded={onUploaded} />;

  const tasksPanel = (
    <div className="space-y-1 p-3">
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
          content: <FetchPanel busy={busy} items={fetchItems} onAttach={onAttach} onOpen={onOpenFile} onRun={onRunFetch} onSave={onSaveFetch} />,
        },
      ]}
    />
  );
}
