import { X } from "lucide-react";
import { useEffect, useState } from "react";
import { languageForPath } from "@/lib/highlight";
import { cn } from "@/lib/utils";
import type { Preview } from "@/lib/api";
import { CodeView, CopyButton } from "./code-block";
import { DiffView } from "./diff-view";
import { MarkdownView } from "./markdown-view";
import { ModalBackdrop } from "./modal-backdrop";

const isMarkdown = (path: string) => /\.(md|markdown)$/i.test(path);
const isImage = (path: string) => /\.(png|jpe?g|gif|webp|svg|bmp)$/i.test(path);

/** What a change set did to the file (opened from History): the diff and a line about what it compares. */
export interface ViewerChange {
  preview: Preview;
  note: string;
}

/** A project file in a modal: Markdown rendered (with a Source view), code with colors and line numbers.
 *  Opened from History, it starts on the lines that change set added and removed. */
export function FileViewer({
  file,
  onClose,
  onOpenFile,
  previewBase,
}: {
  file: { path: string; text: string; change?: ViewerChange };
  onClose: () => void;
  onOpenFile: (path: string) => void;
  previewBase?: string;
}) {
  const md = isMarkdown(file.path);
  const [source, setSource] = useState(false);
  const [showChange, setShowChange] = useState(Boolean(file.change));
  useEffect(() => {
    setSource(false);
    setShowChange(Boolean(file.change));
  }, [file.path, file.change]);
  const change = showChange ? file.change : undefined;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const tab = (on: boolean) =>
    cn("rounded-md px-2 py-0.5 text-xs", on ? "bg-black/10 text-foreground dark:bg-white/10" : "text-muted-foreground hover:text-foreground");

  return (
    <ModalBackdrop center onClose={onClose}>
      <div className="flex max-h-full w-full max-w-4xl flex-col overflow-hidden rounded-2xl bg-background shadow-2xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center gap-2 border-black/10 border-b px-4 py-2 dark:border-white/10">
          <span className="min-w-0 flex-1 truncate font-mono text-sm">{file.path}</span>
          {file.change && (
            <div className="flex items-center gap-0.5">
              <button className={tab(showChange)} onClick={() => setShowChange(true)} title="The lines this change set added and removed" type="button">
                Changes
              </button>
              <button className={tab(!showChange)} onClick={() => setShowChange(false)} title="The whole file" type="button">
                File
              </button>
            </div>
          )}
          {md && !change && (
            <div className="flex items-center gap-0.5">
              <button className={tab(!source)} onClick={() => setSource(false)} type="button">
                Rendered
              </button>
              <button className={tab(source)} onClick={() => setSource(true)} type="button">
                Source
              </button>
            </div>
          )}
          {!isImage(file.path) && <CopyButton text={file.text} />}
          <button className="rounded p-1 hover:bg-black/5 dark:hover:bg-white/10" onClick={onClose} title="Close (Esc)" type="button">
            <X className="h-4 w-4" />
          </button>
        </div>
        {change && <div className="border-black/10 border-b px-4 py-1.5 text-muted-foreground text-xs dark:border-white/10">{change.note}</div>}
        <div className="min-h-0 flex-1 overflow-auto">
          {change ? (
            <div className="p-3">
              <DiffView preview={change.preview} tall />
            </div>
          ) : isImage(file.path) && previewBase ? (
            <div className="flex justify-center p-4">
              <img alt={file.path} className="max-h-[75vh] max-w-full" src={previewBase + file.path.split("/").map(encodeURIComponent).join("/")} />
            </div>
          ) : md && !source ? (
            <MarkdownView className="px-6 py-4" onOpenFile={onOpenFile} path={file.path} previewBase={previewBase} text={file.text} />
          ) : (
            <CodeView language={md ? "markdown" : languageForPath(file.path)} text={file.text} />
          )}
        </div>
      </div>
    </ModalBackdrop>
  );
}
