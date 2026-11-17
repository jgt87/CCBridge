import { describe, expect, it } from "vitest";
import { webUrlOf } from "./file-viewer";

describe("webUrlOf", () => {
  it("takes an https address from the answer", () => {
    const url = "https://contoso.sharepoint.com/sites/Team/Shared%20Documents/Site/index.html";
    expect(webUrlOf({ url })).toBe(url);
    expect(webUrlOf({ url: "https://d.docs.live.net/0123456789abcdef/a.txt" })).toBe("https://d.docs.live.net/0123456789abcdef/a.txt");
  });
  it("gives null for no address, a reason only, or an address that is not https", () => {
    expect(webUrlOf({ url: null, reason: "The file is not in a folder OneDrive or SharePoint syncs." })).toBeNull();
    expect(webUrlOf({})).toBeNull();
    expect(webUrlOf(null)).toBeNull();
    expect(webUrlOf("https://contoso.sharepoint.com/a")).toBeNull();
    expect(webUrlOf({ url: "http://contoso.sharepoint.com/a" })).toBeNull();
    expect(webUrlOf({ url: "javascript:alert(1)" })).toBeNull();
    expect(webUrlOf({ url: "https://contoso.sharepoint.com/a b" })).toBeNull();
  });
});
