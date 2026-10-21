import { Cloud, FolderGit2, FolderOpen, Info, Loader2, RefreshCw } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import GradientButton from "@/components/kokonutui/gradient-button";
import { Input } from "@/components/ui/input";
import { api, type ProjectInfo } from "@/lib/api";
import { openWhenFree, type ProjectOpenAnswer } from "@/lib/project-open";
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
      disabled={isOpening}
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
  // Why opening waits (StreamHub still getting the open project ready, or a task running): a note, not an error.
  const [waitNote, setWaitNote] = useState("");
  const openGen = useRef(0);

  const refresh = async () => {
    setError("");
    setRefreshing(true);
    try {
      await reload();
    } finally {
      setRefreshing(false);
    }
  };

  // Opens when StreamHub is free: while it still gets the open project ready, it tries again by
  // itself and says so; a click on another project takes over from a waiting one.
  const openWith = async (attempt: () => Promise<ProjectOpenAnswer>, path: string) => {
    const gen = ++openGen.current;
    setError("");
    setWaitNote("");
    setOpening(path);
    try {
      const out = await openWhenFree(attempt, setWaitNote, () => gen !== openGen.current);
      if (out.status === "cancelled") return;
      if (out.status === "opened") onOpened();
      else setWaitNote(out.message);
    } catch (e) {
      if (gen === openGen.current) setError((e as Error).message);
    } finally {
      if (gen === openGen.current) setOpening("");
    }
  };
  const open = (path: string) => {
    if (opening === path) return;
    void openWith(() => api.openProject(path), path);
  };
  // The folder is made on the first try; while StreamHub is busy, later tries open that folder.
  const create = (name: string) => {
    let made = "";
    void openWith(async () => {
      if (made) return api.openProject(made);
      const r = await api.createProject(name);
      made = r.path;
      return r;
    }, name);
  };

  return (
    <div className="mx-auto w-full max-w-xl space-y-6 px-4 py-10">
      <PickerHeader onRefresh={() => void refresh()} refreshing={refreshing} root={root} />
      <NewProjectForm onCreate={create} />

      {waitNote && !error && (
        <p className="kit-notice text-sm" role="status">
          {opening ? <Loader2 className="mt-0.5 h-4 w-4 shrink-0 animate-spin" /> : <Info className="mt-0.5 h-4 w-4 shrink-0" />}
          <span>{waitNote}</span>
        </p>
      )}
      {error && <p className="text-(--kit-error) text-sm">{error}</p>}

      <div className="space-y-2">
        {projects.map((p) => (
          <ProjectRow key={p.path} onOpen={open} opening={opening} project={p} />
        ))}
        {!projects.length && root && (
          <p className="kit-empty py-4 text-sm">No projects yet. Create your first one above.</p>
        )}
      </div>
    </div>
  );
}
