// Characterization test for DiffView: its HTML for the four kinds of change, recorded before the
// component was split up, so the split cannot change what users see.
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { Preview } from "@/lib/api";
import { DiffView } from "./diff-view";

const render = (preview: Preview) => renderToStaticMarkup(<DiffView preview={preview} />);

describe("DiffView", () => {
  it("an edit: changed lines with colors, unchanged runs folded into a gap", () => {
    const old = ["# Greets", "function Hi($Name) {", "  'Hello'", "}", "a", "b", "c", "d", "e", "f", "g", "Hi"].join("\n");
    const neu = ["# Greets", "function Hi($Name, $Times) {", "  'Hello'", "}", "a", "b", "c", "d", "e", "f", "g", "Hi -Times 2"].join("\n");
    const html = render({ path: "hello.ps1", exists: true, old, new: neu });
    expect(html).toContain("unchanged line");
    expect(html).toMatchSnapshot();
  });

  it("a new file: every line added, marked new file", () => {
    const html = render({ path: "notes.txt", exists: false, old: null, new: "one\ntwo" });
    expect(html).toContain("new file");
    expect(html).toMatchSnapshot();
  });

  it("a Markdown file: the Changes / Rendered switch, showing the changes", () => {
    const html = render({ path: "README.md", exists: true, old: "# Title", new: "# Title\n\nMore." });
    expect(html).toContain("Rendered");
    expect(html).toMatchSnapshot();
  });

  it("too big to compare line by line: the new text with line numbers", () => {
    const old = Array.from({ length: 2100 }, (_, i) => `old ${i}`).join("\n");
    const neu = Array.from({ length: 2100 }, (_, i) => `new ${i}`).join("\n");
    const html = render({ path: "big.txt", exists: true, old, new: neu });
    expect(html).not.toContain("<table");
    expect(html.length).toBeGreaterThan(1000);
    expect(html.slice(0, 2000)).toMatchSnapshot();
  });
});
