import { useEffect, useId, useState } from "react";

/** A Mermaid diagram. The library (large) loads only when a diagram is shown; a diagram with a
 *  mistake shows its source and the error instead of nothing. */
export function MermaidBlock({ code }: { code: string }) {
  const id = `mmd-${useId().replace(/[^a-zA-Z0-9]/g, "")}`;
  const [svg, setSvg] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { default: mermaid } = await import("mermaid");
        const dark = document.documentElement.classList.contains("dark");
        // strict: no scripts or click handlers from the diagram text.
        mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: dark ? "dark" : "neutral", fontFamily: "inherit" });
        const out = await mermaid.render(id, code);
        if (!cancelled) {
          setSvg(out.svg);
          setError("");
        }
      } catch (e) {
        document.getElementById(`d${id}`)?.remove(); // mermaid leaves its error drawing in the page
        if (!cancelled) setError((e as Error).message || "The diagram could not be drawn.");
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [code, id]);

  if (error) {
    return (
      <div className="md-diagram-error">
        <div className="text-muted-foreground text-xs">Diagram could not be drawn: {error.split("\n")[0]}</div>
        <pre>
          <code>{code}</code>
        </pre>
      </div>
    );
  }
  if (!svg) return <div className="md-diagram text-muted-foreground text-xs">Drawing diagram...</div>;
  // The SVG comes from mermaid in strict mode (sanitized).
  return <div className="md-diagram" dangerouslySetInnerHTML={{ __html: svg }} />;
}
