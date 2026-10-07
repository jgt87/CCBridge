import { AppWindow, Bot, Cpu, Lock, LogIn, Monitor, Moon, Palette, RotateCcw, ShieldCheck, Settings2, SquareTerminal, Sun, Timer, X } from "lucide-react";
import { getThemeChoice, setThemeChoice, type ThemeChoice } from "@/lib/theme";
import { type CardView, getCardView, setCardView } from "@/lib/card-view";
import { readStored, writeStored } from "@/lib/stored";
import { ModalBackdrop } from "./modal-backdrop";
import { SsoSection } from "./sso-section";
import { ToolsSection } from "./tools-section";
import { actionClass, fieldClass, Segmented, SettingLine, SettingsGroup } from "./settings-ui";
import { useEffect, useMemo, useState } from "react";
import { api, type EdgeCacheInfo, type Setting } from "@/lib/api";
import type { ResponseOption } from "@/lib/response-modes";
import { formatBytes } from "@/lib/project-overview";
import { notifyEnabled, notifySupported, setNotifyEnabled } from "@/lib/notify";
import { cn } from "@/lib/utils";
import { settingControlKind } from "./setting-kind";
import { cachedEdgeCache, cachedSettings, loadEdgeCache, loadSettings, rememberEdgeCache, rememberSettings } from "@/lib/settings-cache";

/** A setting's value as text: a command list one per line, a switch as on/off. */
function asDraft(v: Setting["value"]): string {
  if (Array.isArray(v)) return v.join("\n");
  if (typeof v === "boolean") return v ? "on" : "off";
  return String(v ?? "");
}

function defaultText(s: Setting): string {
  if (s.type === "commands" || s.type === "list") return Array.isArray(s.default) && s.default.length ? s.default.join(", ") : "none";
  return asDraft(s.default);
}

// A select whose options are exactly on and off: kept exported from here as before.
export { isOnOff } from "./setting-kind";

/** How an option shows in a list: first letter capitalised, dashes as spaces ("named-sites" -> "Named sites"). */
// Values whose plain capitalised form would not say what they do.
const OPTION_LABELS: Record<string, string> = {
  leave: "As set in Copilot",
  quick: "Quick response",
  deep: "Think deeper",
};

export function optionLabel(o: string): string {
  if (OPTION_LABELS[o]) return OPTION_LABELS[o];
  const t = o.replace(/-/g, " ");
  return t.charAt(0).toUpperCase() + t.slice(1);
}

const ON_OFF = [
  { id: "on" as const, label: "On" },
  { id: "off" as const, label: "Off" },
];

/** The control of one setting (not lists: see ListSettingRow), by settingControlKind. */
function SettingControl({ s, draft, setDraft, save }: { s: Setting; draft: string; setDraft: (v: string) => void; save: (value: Setting["value"]) => void }) {
  const kind = settingControlKind(s);
  if (kind === "info") return <span className={cn(fieldClass, "inline-flex items-center border-transparent font-mono")}>{asDraft(s.value)}</span>;
  // A toggle saves true/false; a select of just on and off looks like every other switch but keeps saving "on"/"off".
  if (kind === "switch") return <Segmented label={s.label} onChange={(o) => save(s.type === "toggle" ? o === "on" : o)} options={ON_OFF} value={draft === "on" ? "on" : "off"} />;
  if (kind === "tiers") {
    return <Segmented label={s.label} onChange={(v) => save(v)} options={(s.options ?? []).map((o) => ({ id: o, label: optionLabel(o) }))} value={String(s.value ?? "standard")} />;
  }
  if (kind === "select") {
    return (
      <select aria-label={s.label} className={fieldClass} onChange={(e) => save(e.target.value)} value={draft}>
        {(s.options ?? []).map((o) => (
          <option key={o} value={o}>
            {optionLabel(o)}
          </option>
        ))}
      </select>
    );
  }
  return (
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
}

/** A list setting (commands, protected paths): one entry per line, saved when leaving the box. */
function ListBox({ s, draft, setDraft, save }: { s: Setting; draft: string; setDraft: (v: string) => void; save: (value: Setting["value"]) => void }) {
  return (
    <textarea
      aria-label={s.label}
      className="min-h-[4.5rem] w-full rounded-md border border-black/10 bg-transparent px-2 py-1 font-mono text-xs outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30"
      onBlur={() => draft !== asDraft(s.value) && save(draft.split("\n").map((l) => l.trim()).filter(Boolean))}
      onChange={(e) => setDraft(e.target.value)}
      placeholder={s.type === "commands" ? "none (every command asks)" : (s.placeholder ?? "none")}
      spellCheck={false}
      value={draft}
    />
  );
}

/** Enforcement: what the chosen tier does, under the switch, changing as you switch. */
function EnforcementNotes({ value, notes }: { value: Setting["value"]; notes: React.ReactNode }) {
  const tier = ENFORCEMENT_TIERS[String(value ?? "standard")] ?? ENFORCEMENT_TIERS.standard;
  return (
    <>
      <ul className="mt-1.5 space-y-0.5 text-xs">
        {tier.map((line) => (
          <li className="flex gap-1.5" key={line}>
            <span className="text-muted-foreground">&bull;</span>
            <span>{line}</span>
          </li>
        ))}
      </ul>
      {notes}
    </>
  );
}

/** "Saved" for a moment after a change, and reset to the default (only when the setting was changed). */
function SettingSide({ s, saved, onReset }: { s: Setting; saved: boolean; onReset: () => void }) {
  if (s.type === "info") return null;
  return (
    <>
      <span className={cn("text-muted-foreground text-xs", !saved && "invisible")}>Saved</span>
      <button
        className={cn("rounded p-1 text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5", !s.custom && "invisible")}
        onClick={onReset}
        title={`Reset to the default (${defaultText(s)})`}
        type="button"
      >
        <RotateCcw className="h-3.5 w-3.5" />
      </button>
    </>
  );
}

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

  const side = <SettingSide onReset={() => save(null)} s={s} saved={saved} />;
  const help = (
    <>
      {s.help}
      {s.type !== "info" && ` Default: ${defaultText(s)}.`}
    </>
  );
  const notes = error ? <div className="text-rose-500 dark:text-rose-400 text-xs">{error}</div> : null;
  const kind = settingControlKind(s);

  // A list (commands, protected paths): the box goes the full width under the text.
  if (kind === "list") return <SettingLine below={<ListBox draft={draft} s={s} save={save} setDraft={setDraft} />} help={help} notes={notes} side={side} title={s.label} />;
  const control = <SettingControl draft={draft} s={s} save={save} setDraft={setDraft} />;
  if (kind === "tiers") {
    return (
      <SettingLine
        control={control}
        help="How strictly the file checks, tests and hooks hold Copilot to their findings. Problems that break a file always go back to Copilot; the tiers differ in how often a task waits for a fix and what happens with likely mistakes. Default: Standard."
        notes={<EnforcementNotes notes={notes} value={s.value} />}
        side={side}
        title={s.label}
      />
    );
  }
  return <SettingLine control={control} help={help} notes={notes} side={side} title={s.label} />;
}

/** What each enforcement tier does (lib/CheckPolicy.psm1, Get-Enforcement). */
const ENFORCEMENT_TIERS: Record<string, string[]> = {
  light: [
    "Light: fewest Copilot messages, for quick changes or when the daily limit is close.",
    "Problems that break a file go back to Copilot; done waits for a fix once.",
    "Likely mistakes are only shown in the chat, not sent to Copilot.",
    "Failing tests and beforeDone hooks are shown in the chat, not sent back.",
    "Mechanical slips (curly quotes, odd spaces, HTML entities in code, mixed line endings) are fixed by StreamHub without a word.",
  ],
  standard: [
    "Standard: the balance for everyday work (recommended).",
    "Problems that break a file go back to Copilot; done waits for a fix up to twice.",
    "Likely mistakes go to Copilot once per task and never hold up done.",
    "Failing tests and beforeDone hooks go back to Copilot up to twice.",
    "Mechanical slips are fixed by StreamHub, and Copilot is told so it stops making them.",
  ],
  strict: [
    "Strict: most thorough, for code that runs unattended (chains, schedules); costs more Copilot messages.",
    "Problems that break a file go back to Copilot; done waits for a fix up to three times.",
    "Likely mistakes go to Copilot and hold up done once.",
    "Failing tests and beforeDone hooks go back to Copilot up to three times.",
    "Mechanical slips are not fixed by StreamHub: Copilot fixes them itself, so every change is its own and checked.",
  ],
};

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
      help="Removes the open project's kept conversation from this computer and empties the chat view. Change sets and the plans in .streamhub/PLAN.md stay."
      notes={note ? <div className="text-muted-foreground text-xs">{note}</div> : null}
      title="Clear chat history"
    />
  );
}

/** Settings > Privacy: Edge's caches in StreamHub's own profile; the Copilot sign-in stays. */
/** Settings > Copilot: what Copilot's response picker offers (read weekly) and Read now. */
function ResponseOptionsRow() {
  const [read, setRead] = useState("");
  const [options, setOptions] = useState<ResponseOption[]>([]);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const load = () =>
    api.responseOptions().then((r) => {
      setRead(r.read);
      setOptions(r.options);
      return r.read;
    });
  useEffect(() => {
    load().catch(() => {});
  }, []);
  const refresh = async () => {
    setBusy(true);
    setNote("");
    try {
      const before = read;
      await api.refreshResponseOptions();
      // The worker reads the picker when it is free: look again for up to a minute.
      for (let i = 0; i < 30; i++) {
        await new Promise((r) => setTimeout(r, 2000));
        if ((await load()) !== before) {
          setNote("Read just now.");
          return;
        }
      }
      setNote("Queued: it is read when Copilot is free (see Actions > Runs).");
    } catch (e) {
      setNote((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const when = read ? new Date(read).toLocaleString() : "never";
  return (
    <SettingLine
      control={
        <button className={actionClass} disabled={busy} onClick={refresh} type="button">
          {busy ? "Reading..." : "Read now"}
        </button>
      }
      help={`Opens Copilot's response picker and reads what it offers, for the Response menu next to New chat. Last read: ${when}.${
        options.length ? ` Offered: ${options.map((o) => (o.parent ? `${o.title} (${o.parent})` : o.title)).join(", ")}.` : ""
      }`}
      notes={note ? <div className="text-muted-foreground text-xs">{note}</div> : null}
      title="Copilot's response options"
    />
  );
}

function ClearEdgeCacheRow() {
  const [info, setInfoState] = useState<EdgeCacheInfo | null>(cachedEdgeCache());
  const setInfo = (i: EdgeCacheInfo) => {
    rememberEdgeCache(i);
    setInfoState(i);
  };
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    loadEdgeCache().then(setInfoState, () => {});
  }, []);
  const clear = async () => {
    setBusy(true);
    try {
      const r = await api.clearEdgeCache();
      setInfo(r.info);
      setNote(
        `Cleared ${formatBytes(r.freedNow)} now.` +
          (r.pending ? " Edge keeps the rest locked while it runs; it is removed the next time StreamHub starts Edge." : ""),
      );
    } catch (e) {
      setNote((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const size = info ? `${formatBytes(info.cacheBytes)} of ${formatBytes(info.profileBytes)}` : "";
  return (
    <SettingLine
      control={
        <button className={actionClass} disabled={busy} onClick={clear} type="button">
          {busy ? "Clearing..." : "Clear"}
        </button>
      }
      help={`Removes Edge's caches in StreamHub's own Edge profile: stored web files, compiled code, graphics caches and downloaded updates. Your Copilot sign-in, cookies and settings stay.${size ? ` Cache now: ${size} (the whole profile).` : ""}${info?.pending ? " A clear waits for the next start." : ""}`}
      notes={note ? <div className="text-muted-foreground text-xs">{note}</div> : null}
      title="Clear Edge's cache"
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
      notes={note ? <div className="text-rose-500 dark:text-rose-400 text-xs">{note}</div> : null}
      title="Desktop notifications"
    />
  );
}

/** Closes on Escape while the window is open. */
function useEscapeKey(onClose: () => void) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
}

/** "Reset all to defaults", asking once more first. */
function ResetAllControl({ anyCustom, onReset }: { anyCustom: boolean; onReset: () => void }) {
  const [confirm, setConfirm] = useState(false);
  if (!confirm) {
    return (
      <button
        className="inline-flex h-8 items-center gap-1 rounded-md px-2.5 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5"
        disabled={!anyCustom}
        onClick={() => setConfirm(true)}
        title={anyCustom ? "Set every setting below back to the app default" : "All settings have the app defaults"}
        type="button"
      >
        <RotateCcw className="h-3.5 w-3.5" /> Reset all to defaults
      </button>
    );
  }
  return (
    <>
      <span className="text-muted-foreground text-xs">Reset all?</span>
      <button
        className="h-8 rounded-md border border-black/10 px-2.5 text-xs hover:bg-black/5 dark:border-white/10 dark:hover:bg-white/5"
        onClick={() => {
          setConfirm(false);
          onReset();
        }}
        type="button"
      >
        Yes, reset
      </button>
      <button className="h-8 rounded-md px-2.5 text-xs hover:bg-black/5 dark:hover:bg-white/5" onClick={() => setConfirm(false)} type="button">
        Cancel
      </button>
    </>
  );
}

/** The settings themselves: a list of sections on the left (this browser, this computer,
    sign-in, then the app's groups) and the chosen section on the right. */
function SettingsBody({
  settings,
  resetNote,
  theme,
  onTheme,
  onSaved,
}: { settings: Setting[]; resetNote: string; theme: ThemeChoice; onTheme: (t: ThemeChoice) => void; onSaved: (list: Setting[]) => void }) {
  const groups = useMemo(() => {
    const m = new Map<string, Setting[]>();
    for (const s of settings) if (s.group !== "Sign-in") m.set(s.group, [...(m.get(s.group) ?? []), s]);
    return [...m.entries()];
  }, [settings]);
  // App first, then this browser, this computer and sign-in, then the other groups.
  const sections = useMemo(() => {
    const names = groups.map(([g]) => g);
    const first = names.filter((g) => g === FIRST_SECTION);
    return [...first, ...FIXED_SECTIONS, ...names.filter((g) => g !== FIRST_SECTION)];
  }, [groups]);
  const [chosen, setChosen] = useState<string>(() => readStored(SECTION_KEY) ?? FIRST_SECTION);
  const current = sections.includes(chosen) ? chosen : sections[0];
  const choose = (name: string) => {
    setChosen(name);
    writeStored(SECTION_KEY, name);
  };
  const list = groups.find(([g]) => g === current)?.[1] ?? [];
  return (
    <div className="flex min-h-0 flex-1 flex-col sm:flex-row">
      <nav aria-label="Settings sections" className="flex shrink-0 gap-1 overflow-x-auto border-black/10 border-b p-2 sm:w-52 sm:flex-col sm:overflow-x-visible sm:overflow-y-auto sm:border-r sm:border-b-0 sm:p-3 dark:border-white/10">
        {sections.map((name) => (
          <button
            aria-current={name === current ? "page" : undefined}
            className={cn(
              "shrink-0 whitespace-nowrap rounded-md px-3 py-1.5 text-left text-sm hover:bg-black/5 dark:hover:bg-white/5",
              name === current ? "bg-black/5 font-medium text-foreground dark:bg-white/10" : "text-muted-foreground",
            )}
            key={name}
            onClick={() => choose(name)}
            type="button"
          >
            <span className="inline-flex items-center gap-2">
              <SectionIcon name={name} />
              {name}
            </span>
          </button>
        ))}
      </nav>
      <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-4 [scrollbar-gutter:stable]">
        {resetNote && <div className="pt-2 text-muted-foreground text-sm">{resetNote}</div>}
        {current === "This browser" && (
          <SettingsGroup first title="This browser">
            <SettingLine
              control={<Segmented label="Theme" onChange={onTheme} options={THEMES} value={theme} />}
              help="System follows Windows (also when it switches). Default: System."
              title="Theme"
            />
            <CardViewSetting />
            <NotificationSetting />
          </SettingsGroup>
        )}
        {current === "This computer" && (
          <SettingsGroup first title="This computer">
            <ToolsSection />
          </SettingsGroup>
        )}
        {current === "Sign-in" && (
          <SettingsGroup first title="Sign-in">
            <SsoSection />
          </SettingsGroup>
        )}
        {list.length > 0 && (
          <SettingsGroup first title={current}>
            {list.map((s) => (
              <SettingRow key={s.key} onSaved={onSaved} s={s} />
            ))}
            {current === "Privacy and retention" && <ClearHistoryRow />}
            {current === "Privacy and retention" && <ClearEdgeCacheRow />}
            {current === "Copilot" && <ResponseOptionsRow />}
          </SettingsGroup>
        )}
      </div>
    </div>
  );
}

/** The group shown at the top of the list, and the first time Settings opens. */
const FIRST_SECTION = "App";
/** A Lucide icon per settings section (a plain one for groups added later). */
const SECTION_ICONS: Record<string, typeof Monitor> = {
  App: AppWindow,
  "This browser": Monitor,
  "This computer": Cpu,
  "Sign-in": LogIn,
  Copilot: Bot,
  Timing: Timer,
  "Changes and commands": SquareTerminal,
  "Checks and issues": ShieldCheck,
  "Privacy and retention": Lock,
  "UI kit": Palette,
};

function SectionIcon({ name }: { name: string }) {
  const Icon = SECTION_ICONS[name] ?? Settings2;
  return <Icon aria-hidden="true" className="h-4 w-4 shrink-0" />;
}

/** Sections that are not app settings groups, right after it. */
const FIXED_SECTIONS = ["This browser", "This computer", "Sign-in"];
/** The section shown last time (this browser). */
const SECTION_KEY = "ccb.settingsSection";

const CARD_VIEWS: { id: CardView; label: string }[] = [
  { id: "expanded", label: "Expanded" },
  { id: "collapsed", label: "Collapsed" },
];

/** How change cards start in the chat (this browser only). */
function CardViewSetting() {
  const [view, setView] = useState<CardView>(getCardView());
  const onChange = (v: CardView) => {
    setCardView(v);
    setView(v);
  };
  return (
    <SettingLine
      control={<Segmented label="Change cards" onChange={onChange} options={CARD_VIEWS} value={view} />}
      help="How Write and Edit cards start in the chat: expanded shows the changed lines at once, collapsed shows one line you can open. Default: Expanded."
      title="Change cards"
    />
  );
}

/** Settings for this computer (saved in config\harness.local.json; kept across updates). */
export function SettingsPanel({ onClose }: { onClose: () => void }) {
  // Shown at once from what was loaded in the background; refreshed quietly while open.
  const [settings, setSettingsState] = useState<Setting[] | null>(cachedSettings());
  const setSettings = (list: Setting[]) => {
    rememberSettings(list);
    setSettingsState(list);
  };
  const [error, setError] = useState("");
  const [resetNote, setResetNote] = useState("");
  useEffect(() => {
    loadSettings().then(setSettingsState, (e) => setError((e as Error).message));
  }, []);
  const [theme, setTheme] = useState<ThemeChoice>(getThemeChoice());
  const changeTheme = (t: ThemeChoice) => {
    setThemeChoice(t);
    setTheme(t);
  };
  const anyCustom = (settings ?? []).some((s) => s.custom) || theme !== "system";
  const resetAll = async () => {
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
  useEscapeKey(onClose);

  return (
    <ModalBackdrop onClose={onClose}>
      <div
        className="flex h-[min(80vh,760px)] w-full max-w-[960px] flex-col overflow-hidden rounded-xl border border-black/10 bg-background shadow-xl dark:border-white/10"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header stays in place; only the settings below it scroll. */}
        <div className="flex shrink-0 items-center justify-between overflow-hidden border-black/10 border-b px-5 py-3 [scrollbar-gutter:stable_both-edges] dark:border-white/10">
          <div>
            <div className="font-semibold">Settings</div>
            <div className="text-muted-foreground text-xs">For this computer; changes apply right away and are kept across updates.</div>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <ResetAllControl anyCustom={anyCustom} onReset={resetAll} />
            <button className="rounded p-1.5 hover:bg-black/5 dark:hover:bg-white/5" onClick={onClose} title="Close (Esc)" type="button">
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>
        {error && <div className="shrink-0 px-5 pt-2 text-rose-500 dark:text-rose-400 text-sm">{error}</div>}
        {/* The first time, before the background load: everything at once, not group by group. */}
        {!settings && !error && <div className="px-5 pt-4 text-muted-foreground text-sm">Loading settings...</div>}
        {settings && <SettingsBody onSaved={setSettings} onTheme={changeTheme} resetNote={resetNote} settings={settings} theme={theme} />}
      </div>
    </ModalBackdrop>
  );
}
