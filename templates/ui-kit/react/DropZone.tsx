/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui file-upload (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { useRef, useState } from "react";

/** True when a file matches an accept list (".csv,image/*,application/pdf"); no list takes every file. */
export function acceptsFile(file: { name: string; type: string }, accept?: string) {
  const parts = (accept ?? "").split(",").map((p) => p.trim().toLowerCase()).filter(Boolean);
  if (!parts.length) return true;
  const name = file.name.toLowerCase();
  const type = (file.type || "").toLowerCase();
  return parts.some((p) => (p.startsWith(".") ? name.endsWith(p) : p.endsWith("/*") ? type.startsWith(p.slice(0, -1)) : type === p));
}

/** A chosen file's row: the stem shrinks with an ellipsis, the extension stays; the full name is the title. */
function FileRow({ name }: { name: string }) {
  const at = name.lastIndexOf(".");
  return (
    <li className="kit-drop__file" title={name}>
      <span className="kit-drop__stem">{at > 0 ? name.slice(0, at) : name}</span>
      {at > 0 ? <span className="kit-drop__ext">{name.slice(at)}</span> : null}
    </li>
  );
}

/** A drop zone for files (click to choose, or drop), with an optional progress bar. */
export function DropZone({
  onFiles,
  accept,
  multiple = true,
  progress,
  title = "Drop files here",
  hint = "or click to choose",
  label,
}: {
  onFiles: (files: File[]) => void;
  accept?: string;
  multiple?: boolean;
  progress?: number;
  title?: string;
  hint?: string;
  /** The name of the file field for screen readers; the title by default. */
  label?: string;
}) {
  const [over, setOver] = useState(false);
  const [names, setNames] = useState<string[]>([]);
  const [refused, setRefused] = useState("");
  // dragenter/dragleave also fire over the zone's own children: count them so the highlight does not flicker.
  const depth = useRef(0);
  const take = (list: FileList | null, dropped: boolean) => {
    if (!list || !list.length) return;
    let files = Array.from(list);
    // The picker filters by accept and multiple itself; a drop does not, so check it here.
    if (dropped) {
      const wrong = files.filter((f) => !acceptsFile(f, accept));
      files = files.filter((f) => acceptsFile(f, accept));
      if (!multiple) files = files.slice(0, 1);
      setRefused(wrong.length ? "Not taken (" + accept + " only): " + wrong.map((f) => f.name).join(", ") : "");
    } else setRefused("");
    if (!files.length) return;
    setNames(files.map((f) => f.name));
    onFiles(files);
  };
  return (
    <label
      className={`kit-drop${over ? " is-over" : ""}`}
      onDragEnter={(e) => {
        e.preventDefault();
        depth.current += 1;
        setOver(true);
      }}
      onDragLeave={() => {
        depth.current = Math.max(0, depth.current - 1);
        if (depth.current === 0) setOver(false);
      }}
      onDragOver={(e) => {
        e.preventDefault();
        setOver(true);
      }}
      onDrop={(e) => {
        e.preventDefault();
        depth.current = 0;
        setOver(false);
        take(e.dataTransfer.files, true);
      }}
    >
      <input accept={accept} aria-label={label ?? title} multiple={multiple} onChange={(e) => take(e.target.files, false)} type="file" />
      <span className="kit-drop__title">{title}</span>
      <span>{hint}</span>
      {names.length > 0 && (
        <ul className="kit-drop__files">
          {/* Two files can share a name (from different folders): the key is the place plus the name. */}
          {names.map((n, i) => (
            <FileRow key={i + ":" + n} name={n} />
          ))}
        </ul>
      )}
      {refused ? (
        <span className="kit-error-text" role="alert">
          {refused}
        </span>
      ) : null}
      {progress !== undefined && (
        <div aria-label="Upload progress" aria-valuemax={100} aria-valuemin={0} aria-valuenow={progress} className="kit-progress" role="progressbar">
          <div className="kit-progress__bar" style={{ width: `${progress}%` }} />
        </div>
      )}
    </label>
  );
}
