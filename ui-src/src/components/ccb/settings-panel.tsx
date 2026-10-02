import { RotateCcw, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { api, type Setting } from "@/lib/api";
import { cn } from "@/lib/utils";

/** One setting: a number field or a choice, saved on change, with "reset to default". */
function SettingRow({ s, onSaved }: { s: Setting; onSaved: (list: Setting[]) => void }) {
  const [draft, setDraft] = useState(String(s.value ?? ""));
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  useEffect(() => setDraft(String(s.value ?? "")), [s.value]);

  const save = async (value: string | number | null) => {
    setError("");
    try {
      const r = await api.setSetting(s.key, value);
      onSaved(r.settings);
      setSaved(true);
      window.setTimeout(() => setSaved(false), 1500);
    } catch (e) {
      setError((e as Error).message);
      setDraft(String(s.value ?? ""));
    }
  };

  const field = "w-28 rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30";
  return (
    <div className="flex items-start gap-3 py-2">
      <div className="min-w-0 flex-1">
        <div className="text-sm">{s.label}</div>
        <div className="text-muted-foreground text-xs">
          {s.help} Default: {String(s.default)}.
        </div>
        {error && <div className="text-rose-500 text-xs">{error}</div>}
      </div>
      <div className="flex shrink-0 items-center gap-1">
        {s.type === "select" ? (
          <select className={field} onChange={(e) => save(e.target.value)} value={draft}>
            {(s.options ?? []).map((o) => (
              <option key={o} value={o}>
                {o}
              </option>
            ))}
          </select>
        ) : (
          <input
            className={field}
            max={s.max}
            min={s.min}
            onBlur={() => draft !== String(s.value ?? "") && save(draft)}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
            step="any"
            type="number"
            value={draft}
          />
        )}
        <button
          className={cn("rounded p-1 text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5", !s.custom && "invisible")}
          onClick={() => save(null)}
          title={`Reset to the default (${s.default})`}
          type="button"
        >
          <RotateCcw className="h-3.5 w-3.5" />
        </button>
        <span className={cn("w-10 text-muted-foreground text-xs", !saved && "invisible")}>Saved</span>
      </div>
    </div>
  );
}

/** Settings for this computer (saved in config\harness.local.json; kept across updates). */
export function SettingsPanel({ onClose }: { onClose: () => void }) {
  const [settings, setSettings] = useState<Setting[]>([]);
  const [error, setError] = useState("");
  useEffect(() => {
    api.settings().then(setSettings, (e) => setError((e as Error).message));
  }, []);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  const groups = useMemo(() => {
    const m = new Map<string, Setting[]>();
    for (const s of settings) m.set(s.group, [...(m.get(s.group) ?? []), s]);
    return [...m.entries()];
  }, [settings]);

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center bg-black/30 p-4 pt-16" onClick={onClose}>
      <div
        className="max-h-[80vh] w-full max-w-xl overflow-y-auto rounded-xl border border-black/10 bg-background p-4 shadow-xl dark:border-white/10"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-2 flex items-center justify-between">
          <div>
            <div className="font-semibold">Settings</div>
            <div className="text-muted-foreground text-xs">For this computer; changes apply right away and are kept across updates.</div>
          </div>
          <button className="rounded p-1 hover:bg-black/5 dark:hover:bg-white/5" onClick={onClose} title="Close (Esc)" type="button">
            <X className="h-4 w-4" />
          </button>
        </div>
        {error && <div className="text-rose-500 text-sm">{error}</div>}
        {groups.map(([group, list]) => (
          <div className="border-black/10 border-t pt-2 dark:border-white/10" key={group}>
            <div className="mt-1 font-medium text-muted-foreground text-xs uppercase tracking-wide">{group}</div>
            {list.map((s) => (
              <SettingRow key={s.key} onSaved={setSettings} s={s} />
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}
