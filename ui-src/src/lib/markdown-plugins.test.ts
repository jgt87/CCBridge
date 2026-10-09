import { describe, expect, it } from "vitest";
import { imageSource, safeHost, sanitizeSchema } from "./markdown-plugins";

describe("images in replies and files", () => {
  it("shows project images through the preview address and embedded images as they are", () => {
    expect(imageSource("shots/a.png", "docs/README.md", "/preview/t/")).toEqual({ url: "/preview/t/docs/shots/a.png" });
    expect(imageSource("data:image/png;base64,AAAA", undefined, undefined)).toEqual({ url: "data:image/png;base64,AAAA" });
  });
  it("never loads an image from the web: a reply cannot carry data out by rendering", () => {
    expect(imageSource("https://example.test/p?d=secret", undefined, undefined)).toEqual({ remote: "https://example.test/p?d=secret" });
    expect(imageSource("//example.test/p.png", "a.md", "/preview/t/")).toEqual({ remote: "//example.test/p.png" });
    expect(imageSource("../outside.png", "a.md", "/preview/t/")).toBeNull();
    expect(imageSource("x.png", undefined, undefined)).toBeNull();
  });
  it("keeps the sanitiser from passing web image addresses through, and keeps clobber protection", () => {
    expect((sanitizeSchema as { protocols: { src: string[] } }).protocols.src).toEqual(["data"]);
    expect((sanitizeSchema as { clobberPrefix?: string }).clobberPrefix).toBe("user-content-");
  });
  it("names only the host of a remote image", () => {
    expect(safeHost("https://example.test:8443/p?d=secret")).toBe("example.test:8443");
    expect(safeHost("//cdn.example.test/x.png")).toBe("cdn.example.test");
  });
});
