import type { ChangeFileDiff } from "@/lib/api";

/** The note above a change set's file in the viewer (History): what it shows and compared with what. */
export function changeFileNote(d: Pick<ChangeFileDiff, "exists" | "deleted" | "after">): string {
  const what = d.exists ? (d.deleted ? "Deleted later" : "Changes made by this change set") : "Created by this change set";
  const against = d.after === "later" ? "; the file was changed again later, which is not shown here." : d.deleted ? "." : "; compared with the file as it is now.";
  return what + against;
}
