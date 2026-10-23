import { describe, expect, it } from "vitest";
import { chosenByKeys, opensThroughEdge } from "./links";

const keys = (k: Partial<{ ctrlKey: boolean; metaKey: boolean; shiftKey: boolean }> = {}) => ({ ctrlKey: false, metaKey: false, shiftKey: false, ...k });

describe("external links", () => {
  it("sends only web addresses through Edge, and only while the app is in Edge", () => {
    expect(opensThroughEdge("https://example.test/a", true)).toBe(true);
    expect(opensThroughEdge("HTTP://example.test/", true)).toBe(true);
    expect(opensThroughEdge("https://example.test/a", false)).toBe(false);
    expect(opensThroughEdge("mailto:someone@example.test", true)).toBe(false);
    expect(opensThroughEdge("file:///C:/x.html", true)).toBe(false);
  });

  it("leaves a click with Ctrl, Cmd or Shift to the browser", () => {
    expect(chosenByKeys(keys())).toBe(false);
    expect(chosenByKeys(keys({ ctrlKey: true }))).toBe(true);
    expect(chosenByKeys(keys({ metaKey: true }))).toBe(true);
    expect(chosenByKeys(keys({ shiftKey: true }))).toBe(true);
  });
});
