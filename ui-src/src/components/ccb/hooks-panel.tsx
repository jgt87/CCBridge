import { FileCode2, Plus } from "lucide-react";
import { useEffect, useState } from "react";
import { api, type HookItem } from "@/lib/api";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";

const MOMENTS: { id: HookItem["event"]; label: string; help: string }[] = [
  { id: "afterEdit", label: "After Copilot edits a file", help: "{file} is the edited file; a failure goes back to Copilot" },
  { id: "beforeDone", label: "Before a task is done", help: "a failure goes back to Copilot" },
  { id: "afterTask", label: "After a task", help: "shown in the chat" },
];

/** Automation > Hooks: the project's own commands at fixed moments (.streamhub/hooks.json). */
export function HooksPanel({ onOpen, refreshKey }: { onOpen: (path: string) => void; refreshKey?: unknown }) {
  const [state, setState] = useState<{ exists: boolean; error: string | null; hooks: HookItem[]; path: string } | null>(null);
  const [note, setNote] = useState("");
  const load = () => api.hooks().then(setState, () => setState(null));
  // biome-ignore lint/correctness/useExhaustiveDependencies: reloads when files change
  useEffect(() => {
    void load();
  }, [refreshKey]);

  const create = async () => {
    try {
      const r = await api.createHooks();
      await load();
      onOpen(r.path);
    } catch (e) {
      setNote((e as Error).message);
    }
  };

  return (
    <div className="space-y-2">
      <p className="text-muted-foreground text-xs">
        Your own commands at fixed moments of a task, for example a formatter after each edit or a check before a task counts as done. They live in{" "}
        <span className="font-mono">.streamhub/hooks.json</span>, which Copilot cannot change; you approve the file once, and again after it changes. Deleting or Microsoft 365 commands never
        run. Settings &gt; Changes and commands can pause them.
      </p>
      {state?.error && <p className="text-rose-500 text-xs">{state.error}</p>}
      {state?.exists ? (
        <>
          {MOMENTS.map((m) => {
            const list = state.hooks.filter((h) => h.event === m.id);
            return (
              <div className="rounded-lg border border-black/10 p-2 dark:border-white/10" key={m.id}>
                <div className="text-xs" title={m.help}>
                  {m.label} <span className="text-muted-foreground">({list.length})</span>
                </div>
                {list.map((h, i) => (
                  <div className="mt-0.5 truncate font-mono text-[11px] text-muted-foreground" key={`${m.id}-${i}`} title={h.run}>
                    {h.name ? `${h.name}: ` : ""}
                    {h.match ? `[${h.match}] ` : ""}
                    {h.run}
                  </div>
                ))}
              </div>
            );
          })}
          <button className={flatButton} onClick={() => onOpen(state.path)} title="View the hooks file; edit it in the project folder" type="button">
            <FileCode2 className="h-3 w-3" /> View hooks file
          </button>
        </>
      ) : (
        <button className={flatButton} onClick={create} title="Write .streamhub/hooks.json with examples; nothing runs until you fill it in" type="button">
          <Plus className="h-3 w-3" /> Create hooks file
        </button>
      )}
      {note && <p className="text-muted-foreground text-xs">{note}</p>}
    </div>
  );
}
