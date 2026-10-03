import { RotateCcw, X } from "lucide-react";
import { ModalBackdrop } from "./modal-backdrop";
import { useEffect, useMemo, useState } from "react";
import { api, type Setting } from "@/lib/api";
import { notifyEnabled, notifySupported, setNotifyEnabled } from "@/lib/notify";
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

/** Desktop notifications from this browser (kept in this browser only). */
function NotificationSetting() {
  const [on, setOn] = useState(notifyEnabled());
  const [note, setNote] = useState("");
  const toggle = async () => {
    const result = await setNotifyEnabled(!on);
    setOn(result);
    setNote(!on && !result ? "The browser blocked notifications; allow them for this page in the browser's site settings." : "");
  };
  return (
    <div className="pt-2">
      <div className="mt-1 font-medium text-muted-foreground text-xs uppercase tracking-wide">This browser</div>
      <div className="flex items-start gap-3 py-2">
        <div className="min-w-0 flex-1">
          <div className="text-sm">Desktop notifications</div>
          <div className="text-muted-foreground text-xs">While this tab is in the background: approvals needed, Copilot's questions, a plan to approve, tasks done or failed, and the daily-limit pause.</div>
          {note && <div className="text-rose-500 text-xs">{note}</div>}
        </div>
        <button
          className="w-28 shrink-0 rounded-md border border-black/10 px-2 py-1 text-sm hover:bg-black/5 disabled:opacity-40 dark:border-white/10 dark:hover:bg-white/5"
          disabled={!notifySupported()}
          onClick={toggle}
          type="button"
        >
          {on ? "On" : "Off"}
        </button>
      </div>
    </div>
  );
}

/** Settings for this computer (saved in config\harness.local.json; kept across updates). */
export function SettingsPanel({ onClose }: { onClose: () => void }) {
  const [settings, setSettings] = useState<Setting[]>([]);
  const [error, setError] = useState("");
  const [confirmReset, setConfirmReset] = useState(false);
  const [resetNote, setResetNote] = useState("");
  useEffect(() => {
    api.settings().then(setSettings, (e) => setError((e as Error).message));
  }, []);
  const anyCustom = settings.some((s) => s.custom);
  const resetAll = async () => {
    setConfirmReset(false);
    try {
      const r = await api.resetSettings();
      setSettings(r.settings);
      setResetNote(r.changed.length ? `${r.changed.length} setting(s) set back to the app defaults.` : "All settings already had the app defaults.");
      window.setTimeout(() => setResetNote(""), 4000);
    } catch (e) {
      setError((e as Error).message);
    }
  };
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
    <ModalBackdrop onClose={onClose}>
      <div
        className="flex max-h-[80vh] w-full max-w-xl flex-col overflow-hidden rounded-xl border border-black/10 bg-background shadow-xl dark:border-white/10"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header stays in place; only the settings below it scroll. */}
        <div className="flex shrink-0 items-center justify-between border-black/10 border-b px-4 py-3 dark:border-white/10">
          <div>
            <div className="font-semibold">Settings</div>
            <div className="text-muted-foreground text-xs">For this computer; changes apply right away and are kept across updates.</div>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            {confirmReset ? (
              <>
                <span className="text-muted-foreground text-xs">Reset all?</span>
                <button className="rounded-md border border-black/10 px-2 py-1 text-xs hover:bg-black/5 dark:border-white/10 dark:hover:bg-white/5" onClick={resetAll} type="button">
                  Yes, reset
                </button>
                <button className="rounded-md px-2 py-1 text-xs hover:bg-black/5 dark:hover:bg-white/5" onClick={() => setConfirmReset(false)} type="button">
                  Cancel
                </button>
              </>
            ) : (
              <button
                className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5"
                disabled={!anyCustom}
                onClick={() => setConfirmReset(true)}
                title={anyCustom ? "Set every setting below back to the app default" : "All settings have the app defaults"}
                type="button"
              >
                <RotateCcw className="h-3.5 w-3.5" /> Reset all to defaults
              </button>
            )}
            <button className="rounded p-1 hover:bg-black/5 dark:hover:bg-white/5" onClick={onClose} title="Close (Esc)" type="button">
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-4">
          {error && <div className="pt-2 text-rose-500 text-sm">{error}</div>}
          {resetNote && <div className="pt-2 text-muted-foreground text-sm">{resetNote}</div>}
          <NotificationSetting />
          {groups.map(([group, list], i) => (
            <div className={cn("pt-2", i > 0 && "border-black/10 border-t dark:border-white/10")} key={group}>
              <div className="mt-1 font-medium text-muted-foreground text-xs uppercase tracking-wide">{group}</div>
              {list.map((s) => (
                <SettingRow key={s.key} onSaved={setSettings} s={s} />
              ))}
            </div>
          ))}
        </div>
      </div>
    </ModalBackdrop>
  );
}
