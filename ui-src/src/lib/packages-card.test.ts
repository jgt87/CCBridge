import { describe, expect, it } from "vitest";
import type { ToolItem } from "@/lib/api";
import { nodeInstallUpdate, packagesNotes } from "./packages-card";

const tool = (name: string, install: ToolItem["install"]): ToolItem => ({ name, label: name, status: "INFO", detail: "", hint: "", canInstall: true, install });

describe("nodeInstallUpdate", () => {
  it("waits while the install runs or Node.js is not listed", () => {
    expect(nodeInstallUpdate([])).toBeNull();
    expect(nodeInstallUpdate([tool("node", null)])).toBeNull();
    expect(nodeInstallUpdate([tool("node", { state: "running", message: "x", at: "" })])).toBeNull();
    expect(nodeInstallUpdate([tool("python", { state: "done", message: "", at: "" })])).toBeNull();
  });
  it("reports done, failed and pending with the message", () => {
    expect(nodeInstallUpdate([tool("node", { state: "done", message: "ok", at: "" })])).toEqual({ node: "done", message: "" });
    expect(nodeInstallUpdate([tool("node", { state: "failed", message: "blocked", at: "" })])).toEqual({ node: "failed", message: "blocked" });
    expect(nodeInstallUpdate([tool("node", { state: "pending", message: "in use", at: "" })])).toEqual({ node: "pending", message: "in use" });
  });
});

describe("packagesNotes", () => {
  it("says npm is missing until a Node.js install starts", () => {
    expect(packagesNotes(false, "", "", false).map((n) => n.text)).toEqual([
      "npm is not installed. Node.js brings it: an install for this user only, from nodejs.org (nothing needs admin rights).",
    ]);
    expect(packagesNotes(true, "", "", false)).toEqual([]);
  });
  it("follows the Node.js install", () => {
    expect(packagesNotes(false, "installing", "", false)).toEqual([{ text: "Installing Node.js in the background...", error: false }]);
    expect(packagesNotes(false, "pending", "Restart.", false)).toEqual([{ text: "Node.js is in use; it is installed at the next start of StreamHub. Restart.", error: false }]);
    expect(packagesNotes(true, "done", "", false)).toEqual([{ text: "Node.js and npm are installed.", error: false }]);
    expect(packagesNotes(false, "failed", "Blocked.", false)).toEqual([{ text: "Node.js could not be installed. Blocked.", error: true }]);
  });
  it("adds a failed npm install last, as an error", () => {
    expect(packagesNotes(true, "done", "", true)).toEqual([
      { text: "Node.js and npm are installed.", error: false },
      { text: "npm install could not be started.", error: true },
    ]);
  });
});
