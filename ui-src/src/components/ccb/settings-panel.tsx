import { Monitor, Moon, RotateCcw, Sun, X } from "lucide-react";
import { getThemeChoice, setThemeChoice, type ThemeChoice } from "@/lib/theme";
import { ModalBackdrop } from "./modal-backdrop";
import { SsoSection } from "./sso-section";
import { actionClass, fieldClass, Segmented, SettingLine, SettingsGroup } from "./settings-ui";
import { useEffect, useMemo, useState } from "react";
import { api, type Setting } from "@/lib/api";
import { notifyEnabled, notifySupported, setNotifyEnabled } from "@/lib/notify";
import { cn } from "@/lib/utils";

/** A setting's value as text: a command list one per line, a switch as on/off. */
function asDraft(v: Setting["value"]): string {
  if (Array.isArray(v)) return v.join("\n");
  if (typeof v === "boolean") return v ? "on" : "off";
  return String(v ?? "");
}

function defaultText(s: Setting): string {
  if (s.type === "commands") return Array.isArray(s.default) && s.default.length ? s.default.join(", ") : "none";
  return asDraft(s.default);
}

/** A select whose options are exactly on and off (in any order). */
export function isOnOff(options: string[] | undefined): boolean {
  const o = [...(options ?? [])].sort();
  return o.length === 2 && o[0] === "off" && o[1] === "on";
}

/** How an option shows in a list: first letter capitalised, dashes as spaces ("named-sites" -> "Named sites"). */
export function optionLabel(o: string): string {
  const t = o.replace(/-/g, " ");
  return t.charAt(0).toUpperCase() + t.slice(1);
}

const ON_OFF = [
  { id: "on" as const, label: "On" },
  { id: "off" as const, label: "Off" },
];

/** One setting from the app (config\harness.local.json): saved on change, with "reset to default". */
function SettingRow({ s, onSaved }: { s: Setting; onSaved: (list: Setting[]) => void }) {
  const [draft, setDraft] = useState(asDraft(s.value));
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  useEffect(() => setDraft(asDraft(s.value)), [s.value]);

  const save = async (value: Setting["value"]) => {
    setError("");
    try {
      const r = await api.setSetting(s.key, value);
      onSaved(r.settings);
      setSaved(true);
      window.setTimeout(() => setSaved(false), 1500);
    } catch (e) {
      setError((e as Error).message);
      setDraft(asDraft(s.value));
    }
  };

  const side =
    s.type === "info" ? null : (
      <>
        <button
          className={cn("rounded p-1 text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5", !s.custom && "invisible")}
          onClick={() => save(null)}
          title={`Reset to the default (${defaultText(s)})`}
          type="button"
        >
          <RotateCcw className="h-3.5 w-3.5" />
        </button>
        <span className={cn("text-muted-foreground text-xs", !saved && "invisible")}>Saved</span>
      </>
    );
  const help = (
    <>
      {s.help}
      {s.type !== "info" && ` Default: ${defaultText(s)}.`}
    </>
  );
  const notes = error ? <div className="text-rose-500 text-xs">{error}</div> : null;

  // A list of commands: one per line, the full width under the text, saved when leaving the box.
  if (s.type === "commands") {
    return (
      <SettingLine
        below={
          <textarea
            aria-label={s.label}
            className="min-h-[4.5rem] w-full rounded-md border border-black/10 bg-transparent px-2 py-1 font-mono text-xs outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30"
            onBlur={() => draft !== asDraft(s.value) && save(draft.split("\n").map((l) => l.trim()).filter(Boolean))}
            onChange={(e) => setDraft(e.target.value)}
            placeholder="none (every command asks)"
            spellCheck={false}
            value={draft}
          />
        }
        help={help}
        notes={notes}
        side={side}
        title={s.label}
      />
    );
  }

  const control =
    s.type === "info" ? (
      <span className={cn(fieldClass, "inline-flex items-center border-transparent font-mono")}>{asDraft(s.value)}</span>
    ) : s.type === "toggle" ? (
      <Segmented label={s.label} onChange={(o) => save(o === "on")} options={ON_OFF} value={draft === "on" ? "on" : "off"} />
    ) : s.type === "select" && isOnOff(s.options) ? (
      // A choice of just on and off looks like every other switch (the value saved stays "on"/"off").
      <Segmented label={s.label} onChange={(o) => save(o)} options={ON_OFF} value={draft === "on" ? "on" : "off"} />
    ) : s.type === "select" ? (
      <select aria-label={s.label} className={fieldClass} onChange={(e) => save(e.target.value)} value={draft}>
        {(s.options ?? []).map((o) => (
          <option key={o} value={o}>
            {optionLabel(o)}
          </option>
        ))}
      </select>
    ) : (
      <input
        aria-label={s.label}
        className={fieldClass}
        max={s.max}
        min={s.min}
        onBlur={() => draft !== String(s.value ?? "") && save(draft)}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
        step="any"
        type="number"
        value={draft}
      />
    );
  return <SettingLine control={control} help={help} notes={notes} side={side} title={s.label} />;
}

/** Settings > Privacy: forget the open project's conversation (asks once more first). */
function ClearHistoryRow() {
  const [confirm, setConfirm] = useState(false);
  const [note, setNote] = useState("");
  const clear = async () => {
    setConfirm(false);
    try {
      await api.clearHistory();
      setNote("Cleared.");
    } catch (e) {
      setNote((e as Error).message);
    }
    window.setTimeout(() => setNote(""), 3000);
  };
  return (
    <SettingLine
      control={
        confirm ? (
          <div className="flex w-48 gap-1">
            <button className={cn(actionClass, "w-auto flex-1")} onClick={clear} type="button">
              Yes, clear
            </button>
            <button className={cn(actionClass, "w-auto flex-1 border-transparent")} onClick={() => setConfirm(false)} type="button">
              Cancel
            </button>
          </div>
        ) : (
          <button className={actionClass} onClick={() => setConfirm(true)} type="button">
            Clear
          </button>
        )
      }
      help="Removes the open project's kept conversation from this computer and empties the chat view. Change sets and PLAN.md stay."
      notes={note ? <div className="text-muted-foreground text-xs">{note}</div> : null}
      title="Clear chat history"
    />
  );
}

const THEMES: { id: ThemeChoice; label: string; icon: React.ReactNode }[] = [
  { id: "system", label: "System", icon: <Monitor className="h-3.5 w-3.5" /> },
  { id: "light", label: "Light", icon: <Sun className="h-3.5 w-3.5" /> },
  { id: "dark", label: "Dark", icon: <Moon className="h-3.5 w-3.5" /> },
];

/** Desktop notifications from this browser (kept in this browser only). */
function NotificationSetting() {
  const [on, setOn] = useState(notifyEnabled());
  const [note, setNote] = useState("");
  const change = async (want: "on" | "off") => {
    const result = await setNotifyEnabled(want === "on");
    setOn(result);
    setNote(want === "on" && !result ? "The browser blocked notifications; allow them for this page in the browser's site settings." : "");
  };
  return (
    <SettingLine
      control={<Segmented disabled={!notifySupported()} label="Desktop notifications" onChange={change} options={ON_OFF} value={on ? "on" : "off"} />}
      help="While this tab is in the background: approvals needed, Copilot's questions, a plan to approve, tasks done or failed, and the daily-limit pause."
      notes={note ? <div className="text-rose-500 text-xs">{note}</div> : null}
      title="Desktop notifications"
    />
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
  const [theme, setTheme] = useState<ThemeChoice>(getThemeChoice());
  const changeTheme = (t: ThemeChoice) => {
    setThemeChoice(t);
    setTheme(t);
  };
  const anyCustom = settings.some((s) => s.custom) || theme !== "system";
  const resetAll = async () => {
    setConfirmReset(false);
    try {
      const r = await api.resetSettings();
      setSettings(r.settings);
      const themeReset = theme !== "system";
      if (themeReset) changeTheme("system");
      const n = r.changed.length + (themeReset ? 1 : 0);
      setResetNote(n ? `${n} setting(s) set back to the app defaults.` : "All settings already had the app defaults.");
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
        className="flex max-h-[80vh] w-full max-w-[880px] flex-col overflow-hidden rounded-xl border border-black/10 bg-background shadow-xl dark:border-white/10"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header stays in place; only the settings below it scroll. */}
        <div className="flex shrink-0 items-center justify-between border-black/10 border-b px-5 py-3 dark:border-white/10">
          <div>
            <div className="font-semibold">Settings</div>
            <div className="text-muted-foreground text-xs">For this computer; changes apply right away and are kept across updates.</div>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            {confirmReset ? (
              <>
                <span className="text-muted-foreground text-xs">Reset all?</span>
                <button className="h-8 rounded-md border border-black/10 px-2.5 text-xs hover:bg-black/5 dark:border-white/10 dark:hover:bg-white/5" onClick={resetAll} type="button">
                  Yes, reset
                </button>
                <button className="h-8 rounded-md px-2.5 text-xs hover:bg-black/5 dark:hover:bg-white/5" onClick={() => setConfirmReset(false)} type="button">
                  Cancel
                </button>
              </>
            ) : (
              <button
                className="inline-flex h-8 items-center gap-1 rounded-md px-2.5 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5"
                disabled={!anyCustom}
                onClick={() => setConfirmReset(true)}
                title={anyCustom ? "Set every setting below back to the app default" : "All settings have the app defaults"}
                type="button"
              >
                <RotateCcw className="h-3.5 w-3.5" /> Reset all to defaults
              </button>
            )}
            <button className="rounded p-1.5 hover:bg-black/5 dark:hover:bg-white/5" onClick={onClose} title="Close (Esc)" type="button">
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-4">
          {error && <div className="pt-2 text-rose-500 text-sm">{error}</div>}
          {resetNote && <div className="pt-2 text-muted-foreground text-sm">{resetNote}</div>}
          <SettingsGroup first title="This browser">
            <SettingLine
              control={<Segmented label="Theme" onChange={changeTheme} options={THEMES} value={theme} />}
              help="System follows Windows (also when it switches). Default: System."
              title="Theme"
            />
            <NotificationSetting />
          </SettingsGroup>
          <SettingsGroup title="Sign-in">
            <SsoSection />
          </SettingsGroup>
          {groups.map(([group, list]) => (
            <SettingsGroup key={group} title={group}>
              {list.map((s) => (
                <SettingRow key={s.key} onSaved={setSettings} s={s} />
              ))}
              {group === "Privacy" && <ClearHistoryRow />}
            </SettingsGroup>
          ))}
        </div>
      </div>
    </ModalBackdrop>
  );
}
