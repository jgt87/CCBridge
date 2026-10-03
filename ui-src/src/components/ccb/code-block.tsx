import { Check, Copy } from "lucide-react";
import { useMemo, useState } from "react";
import { highlightCode } from "@/lib/highlight";
import { cn } from "@/lib/utils";

/** Copies text, with a short "copied" tick. */
export function CopyButton({ text, className }: { text: string; className?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      className={cn("rounded p-1 text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/10", className)}
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text);
          setDone(true);
          window.setTimeout(() => setDone(false), 1200);
        } catch {
          /* clipboard blocked: nothing to do */
        }
      }}
      title="Copy"
      type="button"
    >
      {done ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
    </button>
  );
}

/** A fenced code block in Markdown: syntax colors, the language, and a copy button. */
export function CodeBlock({ code, language }: { code: string; language?: string }) {
  const html = useMemo(() => highlightCode(code, language), [code, language]);
  return (
    <div className="md-code group relative">
      <div className="absolute top-1 right-1 flex items-center gap-1 opacity-0 transition-opacity group-hover:opacity-100">
        {language && <span className="text-[10px] text-muted-foreground">{language}</span>}
        <CopyButton text={code} />
      </div>
      <pre>{html ? <code className="hljs" dangerouslySetInnerHTML={{ __html: html }} /> : <code>{code}</code>}</pre>
    </div>
  );
}

/** A whole code file: line numbers and syntax colors (plain text when the language is unknown or the file is big). */
export function CodeView({ text, language, startLine = 1 }: { text: string; language: string | null; startLine?: number }) {
  const html = useMemo(() => highlightCode(text, language), [text, language]);
  const lines = useMemo(() => text.replace(/\n$/, "").split("\n").length, [text]);
  const numbers = useMemo(() => Array.from({ length: lines }, (_, i) => i + startLine).join("\n"), [lines, startLine]);
  return (
    <div className="flex min-w-max font-mono text-xs leading-5">
      <pre aria-hidden className="select-none border-black/10 border-r py-4 pr-3 pl-4 text-right text-muted-foreground/60 dark:border-white/10">
        {numbers}
      </pre>
      <pre className="py-4 pr-4 pl-3">{html ? <code className="hljs" dangerouslySetInnerHTML={{ __html: html }} /> : <code>{text}</code>}</pre>
    </div>
  );
}
