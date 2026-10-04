import { Cloud, FolderGit2, FolderOpen } from "lucide-react";
import { useEffect, useState } from "react";
import GradientButton from "@/components/kokonutui/gradient-button";
import { Input } from "@/components/ui/input";
import { api, type ProjectInfo } from "@/lib/api";

export function ProjectPicker({ onOpened }: { onOpened: () => void }) {
  const [root, setRoot] = useState("");
  const [projects, setProjects] = useState<ProjectInfo[]>([]);
  const [name, setName] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    api.projects().then((r) => {
      setRoot(r.root);
      setProjects(r.projects);
    }, (e) => setError(String(e.message ?? e)));
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

      {error && <p className="text-rose-500 text-sm">{error}</p>}

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
