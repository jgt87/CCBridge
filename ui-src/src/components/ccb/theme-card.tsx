import { Palette } from "lucide-react";
import { useEffect, useId, useState } from "react";
import type { ThemeColours, ThemePreview } from "@/lib/api";
import { isHexColour, normalizeHex, type Swatch, themeAdjustedText, themeAppliedText, themeInputProblem, themeRequest, themeSwatches } from "./theme-card-view";

const loadApi = () => import("@/lib/api").then((m) => m.api);

/** One colour: the browser's picker and the value as text (both edit the same colour). */
function ColourField({ label, value, optional, disabled, onChange }: { label: string; value: string; optional?: boolean; disabled: boolean; onChange: (v: string) => void }) {
  const id = useId();
  return (
    <div className="space-y-1">
      <label className="text-muted-foreground text-xs" htmlFor={id}>
        {label}
        {optional ? " (optional)" : ""}
      </label>
      <div className="flex items-center gap-2">
        <input
          aria-label={`${label}: pick`}
          className="h-8 w-10 cursor-pointer rounded border border-(--kit-border) bg-(--kit-surface) p-0.5"
          disabled={disabled}
          onChange={(e) => onChange(e.target.value)}
          type="color"
          value={isHexColour(value) ? normalizeHex(value) : "#000000"}
        />
        <input
          className="kit-input h-8 min-h-8 w-28 font-mono text-xs"
          disabled={disabled}
          id={id}
          onChange={(e) => onChange(e.target.value)}
          placeholder={optional ? "none" : "#rrggbb"}
          spellCheck={false}
          value={value}
        />
        {optional && value && (
          <button className="kit-btn kit-btn--ghost kit-btn--sm" disabled={disabled} onClick={() => onChange("")} type="button">
            Clear
          </button>
        )}
      </div>
    </div>
  );
}

/** A row of colour chips with their values in the tooltip. */
function SwatchRow({ title, swatches }: { title: string; swatches: Swatch[] }) {
  if (!swatches.length) return null;
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <span className="w-20 shrink-0 text-muted-foreground text-xs">{title}</span>
      {swatches.map((s) => (
        <span
          aria-label={`${s.label} ${s.value}`}
          className="inline-block h-6 w-6 rounded border border-(--kit-border)"
          key={s.token}
          role="img"
          style={{ background: s.value }}
          title={`${s.label} ${s.value}`}
        />
      ))}
    </div>
  );
}

/** The derived colours of one mode: a sample button, the accent family and the chart colours. */
function ModePreview({ title, tokens }: { title: string; tokens: Record<string, string> }) {
  const sw = themeSwatches(tokens);
  return (
    <div className="space-y-1.5">
      <div className="flex items-center gap-2 font-medium text-xs">
        {title}
        {tokens["--kit-accent"] && (
          <span className="rounded px-2 py-0.5 text-xs" style={{ background: tokens["--kit-accent"], color: tokens["--kit-on-accent"] }}>
            Button
          </span>
        )}
      </div>
      <SwatchRow swatches={sw.accent} title="Accent" />
      <SwatchRow swatches={sw.charts} title="Charts" />
    </div>
  );
}

/** Asks StreamHub for the derived colours a moment after the person stops typing. */
function usePreview(colours: ThemeColours, problem: string) {
  const [result, setResult] = useState<{ key: string; preview: ThemePreview | null; error: string }>({ key: "", preview: null, error: "" });
  const key = JSON.stringify(themeRequest(colours));
  useEffect(() => {
    if (problem) return;
    let live = true;
    const t = setTimeout(() => {
      loadApi()
        .then((api) => api.themePreview(JSON.parse(key) as ThemeColours))
        .then(
          (p) => { if (live) setResult({ key, preview: p, error: "" }); },
          (e) => { if (live) setResult({ key, preview: null, error: (e as Error).message }); }
        );
    }, 300);
    return () => { live = false; clearTimeout(t); };
  }, [key, problem]);
  // Only the answer for the colours shown now counts (an older one is dropped while typing).
  const current = !problem && result.key === key;
  return { preview: current ? result.preview : null, error: current ? result.error : "" };
}

/**
 * Theme from your colours (command menu): an accent, and if wanted a second colour and a neutral
 * tint. StreamHub derives the UI kit's colour tokens from them, readable in light and dark, and the
 * card shows them before anything changes; Apply writes the project's styles/kit/tokens.css as one
 * change set (Undo brings the old colours back).
 */
export function ThemeCard({ colours: start, hasKit, dark, restored }: { colours: ThemeColours; hasKit: boolean; dark: boolean; restored: boolean }) {
  const [colours, setColours] = useState<ThemeColours>(start);
  const [done, setDone] = useState("");
  const [busy, setBusy] = useState(false);
  const problem = themeInputProblem(colours);
  const { preview, error } = usePreview(colours, problem);
  if (restored) return null; // an earlier card: the command menu opens a new one
  const set = (k: keyof ThemeColours) => (v: string) => setColours((c) => ({ ...c, [k]: v }));
  const apply = async () => {
    setBusy(true);
    try {
      setDone(themeAppliedText((await (await loadApi()).themeApply(themeRequest(colours))).queued));
    } catch (e) {
      setDone((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const locked = busy || Boolean(done);
  return (
    <div className="kit-panel space-y-3 text-sm">
      <div className="flex items-center gap-2 font-medium">
        <Palette className="h-4 w-4 text-muted-foreground" />
        Theme from your colours
      </div>
      {!hasKit ? (
        <div className="text-muted-foreground text-xs">This project has no UI kit yet (styles/kit/tokens.css). It comes in with the first page Copilot builds; then open this again.</div>
      ) : (
        <>
          <div className="flex flex-wrap gap-4">
            <ColourField disabled={locked} label="Accent" onChange={set("accent")} value={colours.accent} />
            <ColourField disabled={locked} label="Second colour" onChange={set("accent2")} optional value={colours.accent2} />
            <ColourField disabled={locked} label="Neutral tint" onChange={set("neutral")} optional value={colours.neutral} />
          </div>
          {problem && !done && <div className="text-muted-foreground text-xs">{problem}</div>}
          {error && <div className="kit-notice text-xs">{error}</div>}
          {preview && !preview.ok && <div className="kit-notice text-xs">{preview.error}</div>}
          {preview?.ok && (
            <div className="space-y-2">
              <ModePreview title="Light" tokens={preview.light} />
              {dark && Object.keys(preview.dark).length > 0 && <ModePreview title="Dark" tokens={preview.dark} />}
              <div className="text-muted-foreground text-xs">{themeAdjustedText(preview)}</div>
            </div>
          )}
          {done ? (
            <div className="text-muted-foreground text-xs">{done}</div>
          ) : (
            <button className="kit-btn kit-btn--primary kit-btn--sm" disabled={busy || !preview?.ok} onClick={() => void apply()} type="button">
              Apply to this project
            </button>
          )}
        </>
      )}
    </div>
  );
}
