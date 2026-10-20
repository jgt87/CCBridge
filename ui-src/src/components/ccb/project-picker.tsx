import { Cloud, FolderGit2, FolderOpen, Loader2, RefreshCw } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import GradientButton from "@/components/kokonutui/gradient-button";
import { Input } from "@/components/ui/input";
import { api, type ProjectInfo } from "@/lib/api";
import { overviewText } from "@/lib/project-overview";
import { projectRowStatus, projectsWatch } from "@/lib/projects-watch";
import { cn } from "@/lib/utils";

/** The projects folder and its list, kept up to date while the picker shows; `reload` reads it again in full. */
function useProjects(setError: (message: string) => void) {
  const [root, setRoot] = useState("");
  const [projects, setProjects] = useState<ProjectInfo[]>([]);
  // The full load, also for the Refresh button (folders, sizes and types read again).
  const loadRef = useRef<() => Promise<void>>(() => Promise.resolve());

  useEffect(() => {
    const watch = projectsWatch({
      full: api.projects,
      quick: api.projectsQuick,
      show: (r) => {
        setRoot(r.root);
        setProjects(r.projects);
      },
      fail: setError,
      hidden: () => document.hidden,
    });
    loadRef.current = watch.load;
    const check = watch.check;
    void watch.start();
    const timer = window.setInterval(check, 4000);
    window.addEventListener("focus", check);
    document.addEventListener("visibilitychange", check);
    return () => {
      watch.stop();
      window.clearInterval(timer);
      window.removeEventListener("focus", check);
      document.removeEventListener("visibilitychange", check);
    };
  }, [setError]);

  return { root, projects, reload: () => loadRef.current() };
}

function PickerHeader({ root, refreshing, onRefresh }: { root: string; refreshing: boolean; onRefresh: () => void }) {
  return (
    <div className="space-y-1">
      <h2 className="font-semibold text-xl tracking-tight">Choose a project</h2>
      <div className="flex items-center gap-1.5 text-muted-foreground text-sm">
        <Cloud className="h-4 w-4 shrink-0" />
        <span className="shrink-0">Projects live in your OneDrive:</span>
        <span className="min-w-0 flex-1 truncate font-mono text-xs">{root}</span>
        <button
          aria-label="Refresh the project list"
          className="kit-btn kit-btn--ghost kit-btn--sm shrink-0"
          disabled={refreshing}
          onClick={onRefresh}
          title="Read the folders in the projects folder again (names, sizes and file types)"
          type="button"
        >
          <RefreshCw className={cn("h-3.5 w-3.5", refreshing && "animate-spin")} /> Refresh
        </button>
      </div>
    </div>
  );
}

function NewProjectForm({ onCreate }: { onCreate: (name: string) => void }) {
  const [name, setName] = useState("");
  return (
    <form
      className="flex gap-2"
      onSubmit={(e) => {
        e.preventDefault();
        if (name.trim()) onCreate(name.trim());
      }}
    >
      <Input aria-label="New project name"
        className="h-12 flex-1"
        onChange={(e) => setName(e.target.value)}
        placeholder="New project name, e.g. budget-tracker"
        value={name}
      />
      <GradientButton className="h-12" disabled={!name.trim()} label="Create project" type="submit" variant="neutral" />
    </form>
  );
}

/** One project; while one opens, the others wait (dimmed). */
function ProjectRow({ project: p, opening, onOpen }: { project: ProjectInfo; opening: string; onOpen: (path: string) => void }) {
  const isOpening = opening === p.path;
  const overview = overviewText(p.overview);
  return (
    <button
      aria-busy={isOpening}
      className={cn(
        "flex w-full items-center gap-3 rounded-xl border border-(--kit-border) px-4 py-3 text-left transition-colors hover:bg-(--kit-surface-2)",
        opening && !isOpening && "opacity-50",
      )}
      disabled={Boolean(opening)}
      onClick={() => onOpen(p.path)}
      type="button"
    >
      <FolderGit2 className="h-5 w-5 text-muted-foreground" />
      <span className="flex-1">
        <span className="block font-medium text-sm">{p.name}</span>
        <span className="block text-muted-foreground text-xs">{projectRowStatus(p, opening)}</span>
        {overview && <span className="block text-muted-foreground text-xs">{overview}</span>}
      </span>
      {isOpening ? <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" /> : <FolderOpen className="h-4 w-4 text-muted-foreground" />}
    </button>
  );
}

export function ProjectPicker({ onOpened }: { onOpened: () => void }) {
  const [error, setError] = useState("");
  const { root, projects, reload } = useProjects(setError);
  const [refreshing, setRefreshing] = useState(false);
  // The project being opened: shown on its row, and further clicks wait for it.
  const [opening, setOpening] = useState("");

  const refresh = async () => {
    setError("");
    setRefreshing(true);
    try {
      await reload();
    } finally {
      setRefreshing(false);
    }
  };

  const open = async (path: string) => {
    if (opening) return;
    setError("");
    setOpening(path);
    try {
      await api.openProject(path);
      onOpened();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setOpening("");
    }
  };

  const create = async (name: string) => {
    setError("");
    try {
      await api.createProject(name);
      onOpened();
    } catch (e) {
      setError((e as Error).message);
    }
  };

  return (
    <div className="mx-auto w-full max-w-xl space-y-6 px-4 py-10">
      <PickerHeader onRefresh={() => void refresh()} refreshing={refreshing} root={root} />
      <NewProjectForm onCreate={(name) => void create(name)} />

      {error && <p className="text-(--kit-error) text-sm">{error}</p>}

      <div className="space-y-2">
        {projects.map((p) => (
          <ProjectRow key={p.path} onOpen={(path) => void open(path)} opening={opening} project={p} />
        ))}
        {!projects.length && root && (
          <p className="kit-empty py-4 text-sm">No projects yet. Create your first one above.</p>
        )}
      </div>
    </div>
  );
}
