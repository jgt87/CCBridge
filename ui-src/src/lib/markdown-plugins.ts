// Small helpers for the Markdown view: GitHub callouts, front matter, safe HTML, project paths.
import { defaultSchema } from "rehype-sanitize";

type HastNode = { type: string; tagName?: string; value?: string; properties?: Record<string, unknown>; children?: HastNode[] };

const ALERT = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*/i;

/** GitHub callouts: a blockquote that starts with [!NOTE], [!TIP], [!IMPORTANT], [!WARNING] or [!CAUTION]. */
export function rehypeAlerts() {
  const walk = (node: HastNode) => {
    for (const child of node.children ?? []) {
      if (child.type === "element" && child.tagName === "blockquote") {
        const p = child.children?.find((c) => c.type === "element" && c.tagName === "p");
        const first = p?.children?.[0];
        const m = first?.type === "text" && first.value ? ALERT.exec(first.value) : null;
        if (m && p && first) {
          const kind = m[1].toLowerCase();
          first.value = first.value!.slice(m[0].length).replace(/^\n/, "");
          child.properties = { ...child.properties, className: ["md-alert", `md-alert-${kind}`] };
          child.children = [
            { type: "element", tagName: "p", properties: { className: ["md-alert-title"] }, children: [{ type: "text", value: kind[0].toUpperCase() + kind.slice(1) }] },
            ...(child.children ?? []),
          ];
        }
      }
      walk(child);
    }
  };
  return (tree: HastNode) => walk(tree);
}

/** HTML allowed inside Markdown: GitHub's rules (no scripts, styles or event handlers) plus
 *  the classes the renderer itself adds (code languages, math, callouts). */
export const sanitizeSchema = {
  ...defaultSchema,
  clobberPrefix: "",
  attributes: {
    ...defaultSchema.attributes,
    code: [...(defaultSchema.attributes?.code ?? []), ["className", /^language-./, "math-inline", "math-display"]],
    span: [...(defaultSchema.attributes?.span ?? []), ["className", "math", "math-inline", "math-display"]],
    div: [...(defaultSchema.attributes?.div ?? []), ["className", "math", "math-display"]],
    img: [...(defaultSchema.attributes?.img ?? []), "width", "height", "align"],
  },
};

export interface FrontMatter {
  fields: [string, string][];
  body: string;
}

/** Splits a leading --- front matter block off the text; simple "key: value" lines become fields. */
export function splitFrontMatter(text: string): FrontMatter {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
  if (!m) return { fields: [], body: text };
  const fields: [string, string][] = [];
  let last: [string, string] | null = null;
  for (const line of m[1].split(/\r?\n/)) {
    const kv = /^([A-Za-z0-9_.-]+):\s*(.*)$/.exec(line);
    if (kv) {
      last = [kv[1], kv[2].replace(/^["']|["']$/g, "")];
      fields.push(last);
    } else if (last && line.trim()) {
      last[1] = `${last[1]}${last[1] ? " " : ""}${line.trim().replace(/^- /, "")}`;
    }
  }
  return { fields, body: text.slice(m[0].length) };
}

/** A link or image target relative to a project file, as a project path; null for web links and anchors. */
export function resolveProjectPath(fromFile: string, target: string): string | null {
  if (!target || /^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith("//") || target.startsWith("#")) return null;
  const clean = decodeURIComponent(target.split("#")[0].split("?")[0]);
  if (!clean) return null;
  const parts = clean.startsWith("/") ? [] : fromFile.split("/").slice(0, -1);
  for (const seg of clean.split("/")) {
    if (!seg || seg === ".") continue;
    if (seg === "..") {
      if (!parts.length) return null; // outside the project
      parts.pop();
    } else parts.push(seg);
  }
  return parts.join("/");
}
