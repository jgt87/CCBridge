import { X } from "lucide-react";
import { useEffect, useState } from "react";
import { isImagePath } from "@/lib/app-view";
import { isMarkdownPath, previewImageSrc, viewerBody } from "@/lib/file-viewer";
import { languageForPath } from "@/lib/highlight";
import type { Preview } from "@/lib/api";
import { CodeView, CopyButton } from "./code-block";
import { DiffView } from "./diff-view";
import { MarkdownView } from "./markdown-view";
import { ModalBackdrop } from "./modal-backdrop";

/** What a change set did to the file (opened from History): the diff and a line about what it compares. */
export interface ViewerChange {
  preview: Preview;
  note: string;
}

type ViewerFile = { path: string; text: string; change?: ViewerChange; note?: string };

const tab = "px-2 py-0 text-xs";

/** Two segmented buttons: the first pressed when `first` is true. */
function Toggle({
  first,
  onFirst,
  onSecond,
  labels,
  titles,
}: {
  first: boolean;
  onFirst: () => void;
  onSecond: () => void;
  labels: [string, string];
  titles?: [string, string];
}) {
  return (
    <div className="kit-segmented">
      <button aria-pressed={first} className={tab} onClick={onFirst} title={titles?.[0]} type="button">
        {labels[0]}
      </button>
      <button aria-pressed={!first} className={tab} onClick={onSecond} title={titles?.[1]} type="button">
        {labels[1]}
      </button>
    </div>
  );
}

/** The line under the header: the change set's note, else the file's own (a cut-off large file). */
function ViewerNote({ change, note }: { change?: ViewerChange; note?: string }) {
  if (!change && !note) return null;
  return <div className="border-(--kit-border) border-b px-4 py-1.5 text-muted-foreground text-xs">{change ? change.note : note}</div>;
}

function ViewerContent({
  file,
  change,
  source,
  onOpenFile,
  previewBase,
}: {
  file: ViewerFile;
  change?: ViewerChange;
  source: boolean;
  onOpenFile: (path: string) => void;
  previewBase?: string;
}) {
  const md = isMarkdownPath(file.path);
  const body = viewerBody(file.path, Boolean(change), previewBase, source);
  if (change)
    return (
      <div className="p-3">
        <DiffView preview={change.preview} tall />
      </div>
    );
  switch (body) {
    case "image":
      return (
        <div className="flex justify-center p-4">
          <img alt={file.path} className="max-h-[75vh] max-w-full" src={previewImageSrc(previewBase ?? "", file.path)} />
        </div>
      );
    case "markdown":
      return <MarkdownView className="px-6 py-4" onOpenFile={onOpenFile} path={file.path} previewBase={previewBase} text={file.text} />;
    default:
      return <CodeView language={md ? "markdown" : languageForPath(file.path)} text={file.text} />;
  }
}

/** A project file in a modal: Markdown rendered (with a Source view), code with colors and line numbers.
 *  Opened from History, it starts on the lines that change set added and removed. */
export function FileViewer({
  file,
  onClose,
  onOpenFile,
  previewBase,
}: {
  /** `note`: a line about the text (a file over 2 MB shows its first part). */
  file: ViewerFile;
  onClose: () => void;
  onOpenFile: (path: string) => void;
  previewBase?: string;
}) {
  const md = isMarkdownPath(file.path);
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

  return (
    <ModalBackdrop center onClose={onClose}>
      <div className="kit-dialog flex max-h-full w-full max-w-4xl flex-col overflow-hidden p-0" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center gap-2 border-(--kit-border) border-b px-4 py-2">
          <span className="min-w-0 flex-1 truncate font-mono text-sm">{file.path}</span>
          {file.change && (
            <Toggle
              first={showChange}
              labels={["Changes", "File"]}
              onFirst={() => setShowChange(true)}
              onSecond={() => setShowChange(false)}
              titles={["The lines this change set added and removed", "The whole file"]}
            />
          )}
          {md && !change && <Toggle first={!source} labels={["Rendered", "Source"]} onFirst={() => setSource(false)} onSecond={() => setSource(true)} />}
          {!isImagePath(file.path) && <CopyButton text={file.text} />}
          <button className="kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm" onClick={onClose} title="Close (Esc)" type="button">
            <X className="h-4 w-4" />
          </button>
        </div>
        <ViewerNote change={change} note={file.note} />
        <div className="min-h-0 flex-1 overflow-auto">
          <ViewerContent change={change} file={file} onOpenFile={onOpenFile} previewBase={previewBase} source={source} />
        </div>
      </div>
    </ModalBackdrop>
  );
}
