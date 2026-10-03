import "katex/dist/katex.min.css";
import { isValidElement, useRef } from "react";
import type React from "react";
import ReactMarkdown from "react-markdown";
import rehypeKatex from "rehype-katex";
import rehypeRaw from "rehype-raw";
import rehypeSanitize from "rehype-sanitize";
import rehypeSlug from "rehype-slug";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import { rehypeAlerts, resolveProjectPath, sanitizeSchema, splitFrontMatter } from "@/lib/markdown-plugins";
import { cn } from "@/lib/utils";
import { CodeBlock } from "./code-block";
import { MermaidBlock } from "./mermaid-block";

const remarkPlugins = [remarkGfm, remarkMath];
// HTML in the text is parsed, then cleaned (no scripts, styles or event handlers: Copilot writes
// these files), and only then are math, heading anchors and callouts added.
const rehypePlugins = [rehypeRaw, [rehypeSanitize, sanitizeSchema], rehypeKatex, rehypeSlug, rehypeAlerts] as never[];

function textOf(node: React.ReactNode): string {
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(textOf).join("");
  if (isValidElement(node)) return textOf((node.props as { children?: React.ReactNode }).children);
  return "";
}

/**
 * Markdown as GitHub shows it: tables, task lists, footnotes, callouts, HTML (cleaned), math,
 * Mermaid diagrams, code with colors. With `path` (a project file), relative links open other
 * project files and relative images load from the project.
 */
export function MarkdownView({
  text,
  path,
  onOpenFile,
  previewBase,
  className,
  frontMatter = true,
}: {
  text: string;
  path?: string;
  onOpenFile?: (path: string) => void;
  /** Where the project is served read-only (for images), e.g. /preview/TOKEN/. */
  previewBase?: string;
  className?: string;
  /** Show a leading --- block as a small table (files); off for chat replies. */
  frontMatter?: boolean;
}) {
  const root = useRef<HTMLDivElement>(null);
  const { fields, body } = frontMatter ? splitFrontMatter(text) : { fields: [], body: text };

  const components = {
    pre({ children }: { children?: React.ReactNode }) {
      const code = Array.isArray(children) ? children[0] : children;
      const props = isValidElement(code) ? (code.props as { className?: string; children?: React.ReactNode }) : {};
      const language = /language-([\w+-]+)/.exec(props.className ?? "")?.[1]?.toLowerCase();
      const source = textOf(props.children).replace(/\n$/, "");
      if (language === "mermaid") return <MermaidBlock code={source} />;
      return <CodeBlock code={source} language={language} />;
    },
    a({ href = "", children, ...rest }: { href?: string; children?: React.ReactNode }) {
      if (href.startsWith("#")) {
        // Jump within this text (heading anchors, footnotes), not the app's address.
        return (
          <a
            {...rest}
            href={href}
            onClick={(e) => {
              e.preventDefault();
              const id = decodeURIComponent(href.slice(1));
              root.current?.querySelector(`[id="${CSS.escape(id)}"]`)?.scrollIntoView({ behavior: "smooth", block: "start" });
            }}
          >
            {children}
          </a>
        );
      }
      const target = path ? resolveProjectPath(path, href) : null;
      if (target && onOpenFile) {
        return (
          <a
            {...rest}
            href={href}
            onClick={(e) => {
              e.preventDefault();
              onOpenFile(target);
            }}
            title={`Open ${target}`}
          >
            {children}
          </a>
        );
      }
      return (
        <a {...rest} href={href} rel="noreferrer" target="_blank">
          {children}
        </a>
      );
    },
    img({ src = "", alt, ...rest }: { src?: string; alt?: string }) {
      const target = path && typeof src === "string" ? resolveProjectPath(path, src) : null;
      const url = target && previewBase ? previewBase + target.split("/").map(encodeURIComponent).join("/") : src;
      return <img {...rest} alt={alt ?? ""} loading="lazy" src={url} />;
    },
  };

  return (
    <div className={cn("ccb-markdown text-sm leading-relaxed", className)} ref={root}>
      {fields.length > 0 && (
        <table className="md-frontmatter">
          <tbody>
            {fields.map(([k, v]) => (
              <tr key={k}>
                <th>{k}</th>
                <td>{v}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <ReactMarkdown components={components as never} rehypePlugins={rehypePlugins} remarkPlugins={remarkPlugins}>
        {body}
      </ReactMarkdown>
    </div>
  );
}
