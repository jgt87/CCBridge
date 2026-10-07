/** One entry of Copilot's response picker as StreamHub read it (Advanced reasoning, GPT > a model ...). */
export interface ResponseOption {
  /** "Title" or "Parent > Title": what StreamHub clicks (saved as pick:PATH). */
  path: string;
  title: string;
  description?: string;
  parent?: string;
}

export interface ResponseChoice {
  value: string;
  label: string;
  hint?: string;
}

const CLASSIC: ResponseChoice[] = [
  { value: "leave", label: "Response: as set in Copilot" },
  { value: "auto", label: "Response: Auto" },
  { value: "quick", label: "Response: Quick" },
  { value: "deep", label: "Response: Think deeper" },
];
const CLASSIC_TITLES = /^(auto|quick response|think deeper)$/i;

/**
 * The app's response picker: the classic modes, then every other option Copilot's own picker offers
 * on this tenant (as pick:PATH), and the current choice even when the options are not known yet.
 */
export function responseChoices(options: ResponseOption[] | ResponseOption | null | undefined, current?: string | null): ResponseChoice[] {
  const list = Array.isArray(options) ? options : options ? [options] : [];
  const out = [...CLASSIC];
  for (const o of list) {
    if (!o?.path || (!o.parent && CLASSIC_TITLES.test(o.title))) continue;
    const value = `pick:${o.path}`;
    if (out.some((c) => c.value === value)) continue;
    out.push({ value, label: `Response: ${o.parent ? `${o.title} (${o.parent})` : o.title}`, hint: o.description || undefined });
  }
  if (current && !out.some((c) => c.value === current)) {
    out.push({ value: current, label: `Response: ${current.replace(/^pick:/, "").replace(/\s*>\s*/g, " > ")}` });
  }
  return out;
}
