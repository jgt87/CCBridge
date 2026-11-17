// @vitest-environment jsdom
// The upload box (Add data in the side panel): what it does with a chosen or dropped file. The checks
// themselves (size, type, the hint line) are tested in lib/file-upload.test.ts; this is the wiring:
// a refused file shows why and uploads nothing, an accepted one goes to the given upload with its
// progress on show, several dropped files go one after another, and a failed upload says why.
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

// Motion stands in as plain elements that keep every prop but the animation ones (the drop area's
// handlers sit on a motion.div), so what shows is what the box renders.
vi.mock("motion/react", () => {
  const Plain = ({ animate: _a, exit: _e, initial: _i, transition: _t, ...rest }: Record<string, unknown>) => <div {...(rest as React.HTMLAttributes<HTMLDivElement>)} />;
  return { motion: new Proxy({}, { get: () => Plain }), AnimatePresence: ({ children }: { children?: React.ReactNode }) => <>{children}</> };
});

import FileUpload from "./file-upload";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let root: Root | null = null;
let host: HTMLDivElement | null = null;

function render(ui: React.ReactNode) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  act(() => root!.render(ui));
  return host;
}
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  root = null;
  host = null;
  vi.useRealTimers();
});

const fileOf = (name: string, type: string, text = "data") => new File([text], name, { type });
// The browser's file picker: the input's files, then its change event.
function choose(box: HTMLElement, files: File[]) {
  const input = box.querySelector<HTMLInputElement>('input[type="file"]')!;
  Object.defineProperty(input, "files", { value: files, configurable: true });
  act(() => void input.dispatchEvent(new Event("change", { bubbles: true })));
}
// Files dropped on the drop area (the element with the drop handler: the dropzone's outer box).
function drop(box: HTMLElement, files: File[]) {
  const zone = box.querySelector('input[type="file"]')!.parentElement!;
  const e = new Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(e, "dataTransfer", { value: { files } });
  act(() => void zone.dispatchEvent(e));
}
// An upload the test finishes when it wants to.
function controlledUpload() {
  const calls: { file: File; progress: (p: number) => void; done: () => void; fail: (e: Error) => void }[] = [];
  const upload = vi.fn((file: File, progress: (p: number) => void) => new Promise<void>((done, fail) => { calls.push({ file, progress, done, fail }); }));
  return { upload, calls };
}

describe("FileUpload", () => {
  it("refuses a file of the wrong type: says why, reports it, uploads nothing, and clears the note after a while", () => {
    vi.useFakeTimers();
    const onUploadError = vi.fn();
    const { upload } = controlledUpload();
    const box = render(<FileUpload acceptedFileTypes={["image/png"]} onUploadError={onUploadError} upload={upload} />);

    choose(box, [fileOf("notes.txt", "text/plain")]);

    expect(box.textContent).toContain("File type must be image/png");
    expect(onUploadError).toHaveBeenCalledWith({ message: "File type must be image/png", code: "INVALID_FILE_TYPE" });
    expect(upload).not.toHaveBeenCalled();
    act(() => void vi.advanceTimersByTime(3000));
    expect(box.textContent).not.toContain("File type must be");
  });

  it("uploads an accepted file with the given upload: its name and progress while it runs, then success", async () => {
    const onUploadSuccess = vi.fn();
    const { upload, calls } = controlledUpload();
    const box = render(<FileUpload onUploadSuccess={onUploadSuccess} title="Drop data here" upload={upload} />);
    const file = fileOf("sales.csv", "text/csv");

    choose(box, [file]);
    expect(upload).toHaveBeenCalledTimes(1);
    expect(calls[0].file).toBe(file);
    act(() => calls[0].progress(40));
    expect(box.textContent).toContain("sales.csv");
    expect(box.textContent).toContain("40%");
    expect(box.textContent).not.toContain("Drop data here");

    await act(async () => calls[0].done());
    expect(onUploadSuccess).toHaveBeenCalledWith(file);
    expect(box.textContent).toContain("Drop data here");
  });

  it("uploads several dropped files one after another, not at once", async () => {
    const onUploadSuccess = vi.fn();
    const { upload, calls } = controlledUpload();
    const box = render(<FileUpload onUploadSuccess={onUploadSuccess} upload={upload} />);
    const a = fileOf("a.csv", "text/csv"), b = fileOf("b.csv", "text/csv");

    drop(box, [a, b]);
    expect(calls.map((c) => c.file)).toEqual([a]);

    await act(async () => calls[0].done());
    expect(calls.map((c) => c.file)).toEqual([a, b]);
    await act(async () => calls[1].done());
    expect(onUploadSuccess.mock.calls.map(([f]) => f)).toEqual([a, b]);
  });

  it("shows why an upload failed and reports it", async () => {
    const onUploadError = vi.fn();
    const { upload, calls } = controlledUpload();
    const box = render(<FileUpload onUploadError={onUploadError} upload={upload} />);

    choose(box, [fileOf("big.xlsx", "application/vnd.ms-excel")]);
    await act(async () => calls[0].fail(new Error("The disk is full")));

    expect(box.textContent).toContain("The disk is full");
    expect(onUploadError).toHaveBeenCalledWith({ message: "The disk is full", code: "UPLOAD_FAILED" });
  });
});
