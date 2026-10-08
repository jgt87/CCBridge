import { Cloud, FolderGit2, FolderOpen } from "lucide-react";
import { useEffect, useState } from "react";
import GradientButton from "@/components/kokonutui/gradient-button";
import { Input } from "@/components/ui/input";
import { api, type ProjectInfo } from "@/lib/api";
import { overviewText, projectsSignature } from "@/lib/project-overview";

export function ProjectPicker({ onOpened }: { onOpened: () => void }) {
  const [root, setRoot] = useState("");
  const [projects, setProjects] = useState<ProjectInfo[]>([]);
  const [name, setName] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    let shown = "";
    let busy = false;
    let stopped = false;
    const load = () =>
      api.projects().then((r) => {
        if (stopped) return;
        shown = projectsSignature(r.projects);
        setRoot(r.root);
        setProjects(r.projects);
      }, (e) => setError(String(e.message ?? e)));
    // A folder pasted into the projects folder (or one still being copied) shows without reopening the picker:
    // a quick look at names and times, the full list only when they changed.
    const check = async () => {
      if (busy || stopped || document.hidden) return;
      busy = true;
      try {
        const r = await api.projectsQuick();
        if (!stopped && projectsSignature(r.projects) !== shown) await load();
      } catch {
        // the next check tries again
      } finally {
        busy = false;
      }
    };
    busy = true;
    load().finally(() => {
      busy = false;
    });
    const timer = window.setInterval(check, 4000);
    window.addEventListener("focus", check);
    document.addEventListener("visibilitychange", check);
    return () => {
      stopped = true;
      window.clearInterval(timer);
      window.removeEventListener("focus", check);
      document.removeEventListener("visibilitychange", check);
    };
  }, []);

  const open = async (path: string) => {
    setError("");
    try {
      await api.openProject(path);
      onOpened();
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const create = async () => {
    setError("");
    try {
      await api.createProject(name.trim());
      onOpened();
    } catch (e) {
      setError((e as Error).message);
    }
  };

  return (
    <div className="mx-auto w-full max-w-xl space-y-6 px-4 py-10">
      <div className="space-y-1">
        <h2 className="font-semibold text-xl tracking-tight">Choose a project</h2>
        <p className="flex items-center gap-1.5 text-muted-foreground text-sm">
          <Cloud className="h-4 w-4" /> Projects live in your OneDrive: <span className="truncate font-mono text-xs">{root}</span>
        </p>
      </div>

      <form
        className="flex gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          if (name.trim()) create();
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

      {error && <p className="text-rose-500 dark:text-rose-400 text-sm">{error}</p>}

      <div className="space-y-2">
        {projects.map((p) => (
          <button
            className="flex w-full items-center gap-3 rounded-xl border border-black/10 px-4 py-3 text-left transition-colors hover:bg-black/5 dark:border-white/10 dark:hover:bg-white/5"
            key={p.path}
            onClick={() => open(p.path)}
            type="button"
          >
            <FolderGit2 className="h-5 w-5 text-muted-foreground" />
            <span className="flex-1">
              <span className="block font-medium text-sm">{p.name}</span>
              <span className="block text-muted-foreground text-xs">changed {p.modified.replace("T", " ")}</span>
              {overviewText(p.overview) && <span className="block text-muted-foreground text-xs">{overviewText(p.overview)}</span>}
            </span>
            <FolderOpen className="h-4 w-4 text-muted-foreground" />
          </button>
        ))}
        {!projects.length && root && (
          <p className="text-muted-foreground text-sm">No projects yet. Create your first one above.</p>
        )}
      </div>
    </div>
  );
}
