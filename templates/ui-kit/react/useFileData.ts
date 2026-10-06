/**
 * UI kit file reading for React projects: reads a file a person picks or drops with ../kit-data.js
 * (CSV, TSV, JSON, Excel, Word, PowerPoint; PDF when pdf.js is loaded), in the browser, nothing
 * uploaded. Pair it with DropZone or an <input type="file" accept={KIT_ACCEPT}>.
 *
 * PDF: load ../vendor/pdfjs/pdf.min.js and ../vendor/pdfjs/pdf.worker.min.js with script tags in
 * index.html (or set window.pdfjsLib yourself) before a PDF is read.
 */
import { useCallback, useState } from "react";
import "../kit-data.js";

export type KitColumn = { name: string; type: "number" | "boolean" | "date" | "text" };
export type KitSheet = { name: string; columns: KitColumn[]; rows: Record<string, unknown>[] };
export type KitFileResult =
  | { kind: "table"; sheets: KitSheet[]; rows: Record<string, unknown>[] }
  | { kind: "json"; data: unknown }
  | { kind: "document"; blocks: Array<{ type: "heading"; level: number; text: string } | { type: "paragraph"; text: string; list: boolean } | { type: "table"; rows: string[][] }>; text: string }
  | { kind: "slides"; slides: Array<{ number: number; title: string; lines: string[]; notes: string }>; text: string }
  | { kind: "pdf"; pages: Array<{ number: number; text: string }>; text: string }
  | { kind: "text"; text: string };

declare global {
  interface Window {
    KitData: { accept: string; readFile: (file: File) => Promise<KitFileResult>; parseCsv: (text: string, options?: { delimiter?: string }) => { columns: KitColumn[]; rows: Record<string, unknown>[] } };
  }
}

export const KIT_ACCEPT = ".csv,.tsv,.txt,.json,.xlsx,.xlsm,.docx,.pptx,.pdf";

/** read(file) fills result; error holds a message a person can act on; busy while reading. */
export function useFileData() {
  const [result, setResult] = useState<KitFileResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const read = useCallback(async (file: File) => {
    setBusy(true);
    setError(null);
    try {
      const r = await window.KitData.readFile(file);
      setResult(r);
      return r;
    } catch (e) {
      setResult(null);
      setError(e instanceof Error ? e.message : String(e));
      return null;
    } finally {
      setBusy(false);
    }
  }, []);
  return { read, result, error, busy };
}
