import { describe, expect, it } from "vitest";
import type { AgentEvent } from "@/lib/api";
import { changeSets, chatView, endsNewChat, inProject, keptView, projectKey, projectView, promptHistory, touchesFiles, touchesReview } from "./event-views";

let seq = 0;
const ev = (type: string, more: Partial<AgentEvent> = {}): AgentEvent => ({ seq: ++seq, type, time: "12:00:00", ...more }) as AgentEvent;

describe("event views", () => {
  it("starts the project view at the last project switch", () => {
    const a = [ev("user"), ev("project"), ev("user"), ev("project"), ev("assistant")];
    expect(projectView(a)).toEqual(a.slice(3));
    expect(projectView(a.slice(0, 1))).toEqual(a.slice(0, 1));
  });

  it("drops everything up to and including a history clear", () => {
    const a = [ev("user"), ev("history-cleared"), ev("user")];
    expect(keptView(a)).toEqual([a[2]]);
  });

  it("starts the chat at the last new chat", () => {
    const a = [ev("user"), ev("newchat"), ev("user")];
    expect(chatView(a)).toEqual(a.slice(1));
  });

  it("keeps the user's messages trimmed, consecutive repeats once", () => {
    const a = [ev("user", { text: " a " }), ev("user", { text: "a" }), ev("assistant", { text: "x" }), ev("user", { text: "" }), ev("user", { text: "b" }), ev("user", { text: "a" })];
    expect(promptHistory(a)).toEqual(["a", "b", "a"]);
  });

  it("lists change sets and takes the newest off for an undo with files", () => {
    const a = [
      ev("checkpoint", { files: ["a.js"], title: "one", changeSet: "cs1" }),
      ev("checkpoint", { files: "b.js" as unknown as string[], counts: { path: "b.js", added: 1, removed: 0 } as never }),
      ev("undo", { files: [] }),
      ev("undo", { files: ["b.js"] }),
    ];
    const list = changeSets(a);
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ files: ["a.js"], title: "one", changeSet: "cs1", counts: [] });
    expect(changeSets(a.slice(0, 2))[1]).toMatchObject({ files: ["b.js"], title: undefined, changeSet: undefined, counts: [{ path: "b.js" }] });
  });

  it("tells which events refresh the tree, the review panel and the New chat button", () => {
    expect(touchesFiles([ev("assistant")])).toBe(false);
    expect(touchesFiles([ev("chain")])).toBe(true);
    expect(touchesFiles([ev("action-result", { changed: true } as never)])).toBe(true);
    expect(touchesFiles([ev("action-result")])).toBe(false);
    expect(touchesReview([ev("checkpoint")])).toBe(false);
    expect(touchesReview([ev("review")])).toBe(true);
    expect(endsNewChat([ev("error")])).toBe(true);
    expect(endsNewChat([ev("user")])).toBe(false);
  });

  it("keeps items of the open project and those of every project", () => {
    const key = projectKey("C:\\Proj\\A\\");
    expect(key).toBe("c:\\proj\\a");
    const items = [{ id: 1, projectRoot: "c:\\PROJ\\a" }, { id: 2, projectRoot: "C:\\Proj\\B" }, { id: 3 }, { id: 4, projectRoot: null }];
    expect(inProject(items, key).map((x) => x.id)).toEqual([1, 3, 4]);
    expect(inProject(undefined, key)).toEqual([]);
  });
});
