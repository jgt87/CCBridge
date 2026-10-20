import { useState } from "react";
import type { ViewerChange } from "@/components/ccb/file-viewer";
import { api } from "@/lib/api";
import { isImagePath } from "@/lib/app-view";
import { changeFileNote } from "@/lib/change-note";

export interface ViewerFile {
  path: string;
  text: string;
  change?: ViewerChange;
  note?: string;
}

/** The file viewer: a project file, or one file of a change set from History. Opening one closes the side drawer. */
export function useFileViewer(closeDrawer: () => void, fail: (e: unknown) => void) {
  const [viewer, setViewer] = useState<ViewerFile | null>(null);

  const openFile = async (path: string) => {
    closeDrawer();
    try {
      // Images are shown from the project's read-only preview address, not read as text.
      if (isImagePath(path)) setViewer({ path, text: "" });
      else setViewer(await api.file(path));
    } catch (e) {
      fail(e);
    }
  };

  // From History: the file with the lines that change set added and removed (and the whole file a tab away).
  const openChangeFile = async (changeSet: string, path: string) => {
    closeDrawer();
    try {
      const d = await api.changeFile(changeSet, path);
      if (d.binary) return openFile(path); // no line view for binary files
      setViewer({ path, text: d.new, change: { note: changeFileNote(d), preview: { path, exists: d.exists, old: d.old ?? "", new: d.new } } });
    } catch (e) {
      fail(e);
    }
  };

  return { viewer, closeViewer: () => setViewer(null), openFile, openChangeFile };
}
