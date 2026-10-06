/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui file-upload (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { useState } from "react";

/** A drop zone for files (click to choose, or drop), with an optional progress bar. */
export function DropZone({
  onFiles,
  accept,
  multiple = true,
  progress,
  title = "Drop files here",
  hint = "or click to choose",
}: {
  onFiles: (files: File[]) => void;
  accept?: string;
  multiple?: boolean;
  progress?: number;
  title?: string;
  hint?: string;
}) {
  const [over, setOver] = useState(false);
  const [names, setNames] = useState<string[]>([]);
  const take = (list: FileList | null) => {
    if (!list || !list.length) return;
    const files = Array.from(list);
    setNames(files.map((f) => f.name));
    onFiles(files);
  };
  return (
    <label
      className={`kit-drop${over ? " is-over" : ""}`}
      onDragLeave={() => setOver(false)}
      onDragOver={(e) => {
        e.preventDefault();
        setOver(true);
      }}
      onDrop={(e) => {
        e.preventDefault();
        setOver(false);
        take(e.dataTransfer.files);
      }}
    >
      <input accept={accept} multiple={multiple} onChange={(e) => take(e.target.files)} type="file" />
      <span className="kit-drop__title">{title}</span>
      <span>{hint}</span>
      {names.length > 0 && (
        <ul className="kit-drop__files">
          {names.map((n) => (
            <li key={n}>{n}</li>
          ))}
        </ul>
      )}
      {progress !== undefined && (
        <div aria-label="Upload progress" aria-valuemax={100} aria-valuemin={0} aria-valuenow={progress} className="kit-progress" role="progressbar">
          <div className="kit-progress__bar" style={{ width: `${progress}%` }} />
        </div>
      )}
    </label>
  );
}
