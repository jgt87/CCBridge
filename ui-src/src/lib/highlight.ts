// Syntax colors for code files and code blocks: highlight.js with only the languages projects use,
// bundled (no internet needed on the target machine).
import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import csharp from "highlight.js/lib/languages/csharp";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import dos from "highlight.js/lib/languages/dos";
import go from "highlight.js/lib/languages/go";
import ini from "highlight.js/lib/languages/ini";
import java from "highlight.js/lib/languages/java";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import markdown from "highlight.js/lib/languages/markdown";
import php from "highlight.js/lib/languages/php";
import powershell from "highlight.js/lib/languages/powershell";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import scss from "highlight.js/lib/languages/scss";
import sql from "highlight.js/lib/languages/sql";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";

const LANGUAGES = { bash, csharp, css, diff, dos, go, ini, java, javascript, json, markdown, php, powershell, python, rust, scss, sql, typescript, xml, yaml };
for (const [name, lang] of Object.entries(LANGUAGES)) hljs.registerLanguage(name, lang);
hljs.registerAliases(["ps1", "psm1", "psd1", "pwsh", "ps"], { languageName: "powershell" });
hljs.registerAliases(["cmd", "bat", "batch"], { languageName: "dos" });
hljs.registerAliases(["sh", "shell", "zsh", "console"], { languageName: "bash" });
hljs.registerAliases(["js", "jsx", "mjs", "cjs"], { languageName: "javascript" });
hljs.registerAliases(["ts", "tsx", "mts", "cts"], { languageName: "typescript" });
hljs.registerAliases(["html", "htm", "svg", "xaml", "csproj", "vue", "svelte"], { languageName: "xml" });
hljs.registerAliases(["yml"], { languageName: "yaml" });
hljs.registerAliases(["toml", "cfg", "conf", "properties"], { languageName: "ini" });
hljs.registerAliases(["py", "pyw"], { languageName: "python" });
hljs.registerAliases(["cs"], { languageName: "csharp" });
hljs.registerAliases(["jsonc"], { languageName: "json" });
hljs.registerAliases(["md"], { languageName: "markdown" });
hljs.registerAliases(["less"], { languageName: "scss" });
hljs.registerAliases(["rs"], { languageName: "rust" });
hljs.registerAliases(["patch"], { languageName: "diff" });

/** Bigger files are shown without colors: highlighting them would make the viewer slow. */
const MAX_CHARS = 300_000;

/** The language for a file name (by extension or a known name), or null for plain text. */
export function languageForPath(path: string): string | null {
  const name = path.split("/").pop()?.toLowerCase() ?? "";
  if (name === "dockerfile" || name === "makefile") return "bash";
  if (name.startsWith(".env") || name === ".gitignore" || name === ".editorconfig") return "ini";
  const ext = name.includes(".") ? name.split(".").pop()! : "";
  return ext && hljs.getLanguage(ext) ? ext : null;
}

/**
 * Syntax colors per line (for diffs): the whole text is highlighted at once, so comments and
 * strings over several lines keep their color, then split into lines with every open span
 * closed at the end of a line and opened again on the next. Null when there are no colors.
 */
export function highlightLines(text: string, language: string | null | undefined): string[] | null {
  const html = highlightCode(text, language);
  if (html === null) return null;
  const out: string[] = [];
  const open: string[] = [];
  for (const line of html.split("\n")) {
    let result = open.join("");
    for (const m of line.matchAll(/<span[^>]*>|<\/span>|[^<]+|</g)) {
      const t = m[0];
      if (t.startsWith("<span")) open.push(t);
      else if (t === "</span>") open.pop();
      result += t;
    }
    out.push(result + "</span>".repeat(open.length));
  }
  return out;
}

/** HTML with syntax colors (escaped by highlight.js), or null when the language is unknown or the text too big. */
export function highlightCode(text: string, language: string | null | undefined): string | null {
  if (!language || text.length > MAX_CHARS || !hljs.getLanguage(language)) return null;
  try {
    return hljs.highlight(text, { language, ignoreIllegals: true }).value;
  } catch {
    return null;
  }
}
