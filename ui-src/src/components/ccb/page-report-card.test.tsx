// The page report card (Check this page in full) and the Compare page button (History).
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { AgentEvent } from "@/lib/api";
import { canSendFixList, comparePage, pageReportItem } from "./page-report";
import { PageReportCard } from "./page-report-card";
import { PageCompareButton } from "./page-compare-button";

const ev = (extra: Partial<AgentEvent> & { fixRequest?: string }): AgentEvent => ({ seq: 4, type: "status", time: "10:00:00", ...extra }) as AgentEvent;

describe("PageReportCard", () => {
  const item = pageReportItem(ev({ text: "index.html: 2 findings (1 contrast, 1 keyboard)", path: ".streamhub/Reports/page-check-index-1.md", fixRequest: "A full check of index.html found..." }));

  it("reads the event", () => {
    expect(item).toEqual({ kind: "pageReport", seq: 4, text: "index.html: 2 findings (1 contrast, 1 keyboard)", path: ".streamhub/Reports/page-check-index-1.md", fixRequest: "A full check of index.html found...", restored: false });
  });
  it("offers the fix list once, only with findings and a way to send", () => {
    expect(canSendFixList(item, false, true)).toBe(true);
    expect(canSendFixList(item, true, true)).toBe(false);
    expect(canSendFixList(item, false, false)).toBe(false);
    expect(canSendFixList({ ...item, fixRequest: "" }, false, true)).toBe(false);
    expect(canSendFixList({ ...item, restored: true }, false, true)).toBe(false);
  });
  it("shows the summary, the report and the button", () => {
    const html = renderToStaticMarkup(<PageReportCard item={item} onOpenFile={() => {}} onSend={() => {}} />);
    expect(html).toContain("2 findings");
    expect(html).toContain("Open the report");
    expect(html).toContain("Send to Copilot as a fix list");
  });
  it("has no button when nothing was found", () => {
    const html = renderToStaticMarkup(<PageReportCard item={{ ...item, fixRequest: "" }} onSend={() => {}} />);
    expect(html).not.toContain("fix list");
  });
});

describe("Compare page", () => {
  it("compares a page the change set changed, else the app's entry page", () => {
    expect(comparePage(["css/site.css", "pages\\about.html", "index.html"], "index.html")).toBe("pages/about.html");
    expect(comparePage(["css/site.css"], "dist/index.html")).toBe("dist/index.html");
    expect(comparePage(["old.html", "css/a.css"], "index.html", ["old.html"])).toBe("index.html");
    expect(comparePage(["css/site.css"], null)).toBeNull();
  });
  it("shows nothing without a page", () => {
    expect(renderToStaticMarkup(<PageCompareButton busy={false} onCompare={() => {}} page={null} />)).toBe("");
    expect(renderToStaticMarkup(<PageCompareButton busy={false} onCompare={() => {}} page="index.html" />)).toContain("Compare page");
  });
});
