import { describe, expect, it } from "vitest";
import { changeFileNote } from "./change-note";

describe("changeFileNote", () => {
  it("says what the change set did and what it is compared with", () => {
    expect(changeFileNote({ exists: true, deleted: false, after: "now" })).toBe("Changes made by this change set; compared with the file as it is now.");
    expect(changeFileNote({ exists: false, deleted: false, after: "later" })).toBe("Created by this change set; the file was changed again later, which is not shown here.");
    expect(changeFileNote({ exists: true, deleted: true, after: "now" })).toBe("Deleted later.");
  });
});
