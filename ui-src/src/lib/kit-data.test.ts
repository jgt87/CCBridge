/// <reference types="node" />
// The UI kit's file readers (templates/ui-kit/kit-data.js) and the data tools that go with
// converted data files (templates/data/data-tools.js). Both are plain scripts for pages without a
// build step; they also export themselves for CommonJS, which is how these tests load them.
import { createRequire } from "node:module";
import path from "node:path";
import { describe, expect, it } from "vitest";

const require = createRequire(import.meta.url);
const repo = path.resolve(import.meta.dirname, "../../..");
const KitData = require(path.join(repo, "templates/ui-kit/kit-data.js"));
const DataTools = require(path.join(repo, "templates/data/data-tools.js"));

const enc = new TextEncoder();

async function deflateRaw(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([bytes as BlobPart]).stream().pipeThrough(new CompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** A zip file (stored or deflated entries, no checksums: the reader does not need them). */
async function makeZip(parts: Record<string, string>, deflate = true): Promise<ArrayBuffer> {
  const chunks: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;
  for (const [name, text] of Object.entries(parts)) {
    const nameBytes = enc.encode(name);
    const raw = enc.encode(text);
    const data = deflate ? await deflateRaw(raw) : raw;
    const local = new Uint8Array(30 + nameBytes.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(8, deflate ? 8 : 0, true);
    lv.setUint32(18, data.length, true);
    lv.setUint32(22, raw.length, true);
    lv.setUint16(26, nameBytes.length, true);
    local.set(nameBytes, 30);
    const cd = new Uint8Array(46 + nameBytes.length);
    const cv = new DataView(cd.buffer);
    cv.setUint32(0, 0x02014b50, true);
    cv.setUint16(10, deflate ? 8 : 0, true);
    cv.setUint32(20, data.length, true);
    cv.setUint32(24, raw.length, true);
    cv.setUint16(28, nameBytes.length, true);
    cv.setUint32(42, offset, true);
    cd.set(nameBytes, 46);
    chunks.push(local, data);
    central.push(cd);
    offset += local.length + data.length;
  }
  const cdSize = central.reduce((n, c) => n + c.length, 0);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, central.length, true);
  ev.setUint16(10, central.length, true);
  ev.setUint32(12, cdSize, true);
  ev.setUint32(16, offset, true);
  const all = [...chunks, ...central, end];
  const out = new Uint8Array(all.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of all) { out.set(c, at); at += c.length; }
  return out.buffer;
}

const fileOf = (name: string, data: ArrayBuffer | string) => {
  const buf = typeof data === "string" ? enc.encode(data).buffer : data;
  return { name, arrayBuffer: () => Promise.resolve(buf) };
};

const S = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';

describe("KitData.parseCsv", () => {
  it("reads a semicolon file with decimal commas, day-first dates, codes and true/false", () => {
    const t = KitData.parseCsv('Datum;Regio;Bedrag;Code;Actief\r\n31-01-2024;Noord;1.250,50;007;true\r\n01-02-2024;"Zuid; west";3,5;012;FALSE\r\n02-02-2024;Oost;;013;true\r\n');
    expect(t.columns).toEqual([
      { name: "Datum", type: "date" }, { name: "Regio", type: "text" }, { name: "Bedrag", type: "number" },
      { name: "Code", type: "text" }, { name: "Actief", type: "boolean" },
    ]);
    expect(t.rows[0]).toEqual({ Datum: "2024-01-31", Regio: "Noord", Bedrag: 1250.5, Code: "007", Actief: true });
    expect(t.rows[1].Regio).toBe("Zuid; west");
    expect(t.rows[2].Bedrag).toBeNull();
  });
  it("keeps quotes, line breaks inside quotes and thousands separators apart", () => {
    const t = KitData.parseCsv('Name,Note,Amount\n"A ""big"" one","line 1\nline 2","1,234.5"\nB,,7\n\n');
    expect(t.rows).toEqual([
      { Name: 'A "big" one', Note: "line 1\nline 2", Amount: 1234.5 },
      { Name: "B", Note: null, Amount: 7 },
    ]);
  });
  it("names empty and repeated headers and leaves dates it cannot order as text", () => {
    const t = KitData.parseCsv("Date,,Date\n01/02/2024,x,1\n03/04/2024,y,2\n");
    expect(t.columns.map((c: { name: string }) => c.name)).toEqual(["Date", "Column 2", "Date 2"]);
    expect(t.columns[0].type).toBe("text");
    expect(KitData.parseCsv("D\n12/31/2024\n").rows[0].D).toBe("2024-12-31");
    expect(KitData.parseCsv("D\n31.12.2024\n01.02.2024\n").rows[1].D).toBe("2024-02-01");
  });
});

describe("KitData Office files", () => {
  it("reads a workbook: shared and inline strings, date styles, true/false, sheet order, hidden sheets left out", async () => {
    const buf = await makeZip({
      "xl/workbook.xml": `<workbook ${S}><sheets><sheet name="Sales" sheetId="1" r:id="rId1"/><sheet name="Secret" sheetId="2" state="hidden" r:id="rId2"/><sheet name="Notes" sheetId="3" r:id="rId3"/></sheets></workbook>`,
      "xl/_rels/workbook.xml.rels": '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="x/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="x/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="x/worksheet" Target="/xl/worksheets/sheet3.xml"/></Relationships>',
      "xl/sharedStrings.xml": `<sst ${S}><si><t>Date</t></si><si><t>Region</t></si><si><r><t>Am</t></r><r><t>ount</t></r></si><si><t>North &amp; East</t></si></sst>`,
      "xl/styles.xml": `<styleSheet ${S}><numFmts count="1"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/></numFmts><cellXfs count="3"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/></cellXfs></styleSheet>`,
      "xl/worksheets/sheet1.xml": `<worksheet ${S}><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="inlineStr"><is><t>Paid</t></is></c></row><row r="2"><c r="A2" s="1"><v>45322</v></c><c r="B2" t="s"><v>3</v></c><c r="C2"><v>1250.5</v></c><c r="D2" t="b"><v>1</v></c></row><row r="3"><c r="A3" s="2"><v>45323</v></c><c r="C3"><v>3</v></c><c r="D3" t="b"><v>0</v></c></row></sheetData></worksheet>`,
      "xl/worksheets/sheet2.xml": `<worksheet ${S}><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>x</t></is></c></row></sheetData></worksheet>`,
      "xl/worksheets/sheet3.xml": `<x:worksheet xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><x:sheetData><x:row r="1"><x:c r="B1" t="inlineStr"><x:is><x:t>Note</x:t></x:is></x:c></x:row><x:row r="2"><x:c r="B2" t="inlineStr"><x:is><x:t>Hello</x:t></x:is></x:c></x:row></x:sheetData></x:worksheet>`,
    });
    const r = await KitData.readFile(fileOf("Sales.xlsx", buf));
    expect(r.kind).toBe("table");
    expect(r.sheets.map((s: { name: string }) => s.name)).toEqual(["Sales", "Notes"]);
    expect(r.sheets[0].columns.map((c: { type: string }) => c.type)).toEqual(["date", "text", "number", "boolean"]);
    expect(r.rows).toEqual([
      { Date: "2024-01-31", Region: "North & East", Amount: 1250.5, Paid: true },
      { Date: "2024-02-01", Region: null, Amount: 3, Paid: false },
    ]);
    expect(r.sheets[1].rows).toEqual([{ "Column 1": null, Note: "Hello" }]);
  });

  it("reads a Word document: headings by style name, lists, tables, no tab stops or field codes", async () => {
    const W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';
    const buf = await makeZip({
      "word/styles.xml": `<w:styles ${W}><w:style w:styleId="Kop1"><w:name w:val="heading 1"/></w:style><w:style w:styleId="Titel"><w:name w:val="Title"/></w:style></w:styles>`,
      "word/document.xml": `<w:document ${W}><w:body>` +
        '<w:p><w:pPr><w:pStyle w:val="Titel"/><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr><w:r><w:t>Report</w:t></w:r></w:p>' +
        '<w:p><w:pPr><w:pStyle w:val="Kop1"/></w:pPr><w:r><w:t xml:space="preserve">Results </w:t></w:r><w:r><w:t>2024</w:t></w:r></w:p>' +
        '<w:p><w:r><w:t>Plain</w:t></w:r><w:r><w:tab/><w:t>text</w:t></w:r><w:r><w:instrText>PAGE</w:instrText></w:r></w:p>' +
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p>' +
        '<w:p/>' +
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc></w:tr></w:tbl>' +
        "</w:body></w:document>",
    }, false);
    const r = await KitData.readFile(fileOf("Report.docx", buf));
    expect(r.blocks).toEqual([
      { type: "heading", level: 1, text: "Report" },
      { type: "heading", level: 1, text: "Results 2024" },
      { type: "paragraph", text: "Plain\ttext", list: false },
      { type: "paragraph", text: "Item", list: true },
      { type: "table", rows: [["A", "B"], ["1", "2"]] },
    ]);
    expect(r.text).toContain("A\tB\n1\t2");
  });

  it("reads slides in presentation order with titles and notes", async () => {
    const P = 'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
    const slide = (title: string, body: string) => `<p:sld ${P}><p:cSld><p:spTree>` +
      `<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>${title}</a:t></a:r></a:p></p:txBody></p:sp>` +
      `<p:sp><p:txBody><a:p><a:r><a:t>${body}</a:t></a:r></a:p><a:p><a:r><a:t>Second</a:t></a:r></a:p></p:txBody></p:sp>` +
      `<p:sp><p:nvSpPr><p:nvPr><p:ph type="sldNum"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>9</a:t></a:r></a:p></p:txBody></p:sp>` +
      "</p:spTree></p:cSld></p:sld>";
    const buf = await makeZip({
      "ppt/presentation.xml": `<p:presentation ${P}><p:sldIdLst><p:sldId id="256" r:id="rId7"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst></p:presentation>`,
      "ppt/_rels/presentation.xml.rels": '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId2" Type="x/slide" Target="slides/slide1.xml"/><Relationship Id="rId7" Type="x/slide" Target="slides/slide2.xml"/></Relationships>',
      "ppt/slides/slide1.xml": slide("Later", "B"),
      "ppt/slides/slide2.xml": slide("First", "A"),
      "ppt/slides/_rels/slide2.xml.rels": '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide1.xml"/></Relationships>',
      "ppt/notesSlides/notesSlide1.xml": `<p:notes ${P}><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Say hello</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>`,
    });
    const r = await KitData.readFile(fileOf("Deck.pptx", buf));
    expect(r.slides).toEqual([
      { number: 1, title: "First", lines: ["A", "Second"], notes: "Say hello" },
      { number: 2, title: "Later", lines: ["B", "Second"], notes: "" },
    ]);
  });

  it("says what is wrong with old formats, non-zip files and PDFs without pdf.js", async () => {
    await expect(KitData.readFile(fileOf("Old.xls", "x"))).rejects.toThrow(/older Office format/);
    await expect(KitData.readFile(fileOf("Fake.xlsx", "not a zip"))).rejects.toThrow(/Not a zip-based/);
    await expect(KitData.readFile(fileOf("A.pdf", "%PDF"))).rejects.toThrow(/needs pdf.js/);
  });

  it("reads JSON, TSV and plain text, and decodes Windows-1252", async () => {
    expect((await KitData.readFile(fileOf("a.json", '{"a":[1,2]}'))).data).toEqual({ a: [1, 2] });
    expect((await KitData.readFile(fileOf("a.tsv", "x\ty\n1\t2\n"))).rows).toEqual([{ x: 1, y: 2 }]);
    expect((await KitData.readFile(fileOf("a.md", "# Hi"))).kind).toBe("text");
    expect(KitData._internal.decodeText(new Uint8Array([0x63, 0x61, 0x66, 0xe9]).buffer)).toBe("café");
    expect(KitData._internal.serialToText(45322.5, false)).toBe("2024-01-31T12:00:00");
  });
});

describe("KitData PDF through pdf.js", () => {
  it("reads the text of each page with the shipped pdf.js", async () => {
    const g = globalThis as Record<string, unknown>;
    g.window = g;
    g.pdfjsLib = require(path.join(repo, "templates/ui-kit/vendor/pdfjs/pdf.min.js"));
    g.pdfjsWorker = require(path.join(repo, "templates/ui-kit/vendor/pdfjs/pdf.worker.min.js"));
    try {
      const r = await KitData.readFile(fileOf("Hello.pdf", minimalPdf(["Hello PDF", "Page two"])));
      expect(r.kind).toBe("pdf");
      expect(r.pages.map((p: { text: string }) => p.text)).toEqual(["Hello PDF", "Page two"]);
    } finally {
      delete g.window; delete g.pdfjsLib; delete g.pdfjsWorker;
    }
  });
});

/** A small valid PDF with one line of Helvetica text per page. */
function minimalPdf(lines: string[]): ArrayBuffer {
  const objs: string[] = [];
  const pageIds = lines.map((_, i) => 4 + i * 2);
  objs[1] = "<< /Type /Catalog /Pages 2 0 R >>";
  objs[2] = `<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(" ")}] /Count ${lines.length} >>`;
  objs[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>";
  lines.forEach((text, i) => {
    const content = `BT /F1 24 Tf 72 720 Td (${text}) Tj ET`;
    objs[4 + i * 2] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents " + (5 + i * 2) + " 0 R >>";
    objs[5 + i * 2] = `<< /Length ${content.length} >>\nstream\n${content}\nendstream`;
  });
  let out = "%PDF-1.4\n";
  const offsets: number[] = [];
  for (let i = 1; i < objs.length; i++) {
    offsets[i] = out.length;
    out += `${i} 0 obj\n${objs[i]}\nendobj\n`;
  }
  const xref = out.length;
  out += `xref\n0 ${objs.length}\n0000000000 65535 f \n`;
  for (let i = 1; i < objs.length; i++) out += `${String(offsets[i]).padStart(10, "0")} 00000 n \n`;
  out += `trailer\n<< /Size ${objs.length} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return enc.encode(out).buffer;
}

describe("DataTools", () => {
  const rows = [
    { Date: "2024-01-31", Region: "North", Amount: 100 },
    { Date: "2024-02-01", Region: "South", Amount: 50 },
    { Date: "2024-01-15", Region: "North", Amount: null },
    { Date: "2024-02-20", Region: "North", Amount: 25 },
  ];
  it("picks rows from a list or a workbook's sheets", () => {
    expect(DataTools.rows(rows)).toBe(rows);
    expect(DataTools.rows({ Q1: rows })).toBe(rows);
    expect(DataTools.rows({ Q1: rows, Q2: [] }, "Q2")).toEqual([]);
    expect(() => DataTools.rows({ Q1: rows, Q2: [] })).toThrow(/several sheets/);
    expect(DataTools.sheets({ Q1: rows, Q2: [] })).toEqual(["Q1", "Q2"]);
    expect(DataTools.columns(rows)).toEqual(["Date", "Region", "Amount"]);
  });
  it("filters, sorts with nulls last, and lists distinct values", () => {
    expect(DataTools.where(rows, { Region: "South" })).toHaveLength(1);
    expect(DataTools.where(rows, { Region: ["North", "South"], Amount: (v: number) => v > 30 })).toHaveLength(2);
    expect(DataTools.sortBy(rows, "Amount").map((r: { Amount: number }) => r.Amount)).toEqual([25, 50, 100, null]);
    expect(DataTools.sortBy(rows, "Amount", true).map((r: { Amount: number }) => r.Amount)).toEqual([100, 50, 25, null]);
    expect(DataTools.unique(rows, "Region")).toEqual(["North", "South"]);
  });
  it("totals, groups and summarizes, leaving out empty values", () => {
    expect(DataTools.sum(rows, "Amount")).toBe(175);
    expect(DataTools.avg(rows, "Amount")).toBeCloseTo(175 / 3);
    expect(DataTools.count(rows, "Amount")).toBe(3);
    expect(DataTools.max(rows, "Amount")).toBe(100);
    expect(DataTools.summarize(rows, "Region", { Total: ["sum", "Amount"], Rows: ["count"] })).toEqual([
      { key: "North", Total: 125, Rows: 3 },
      { key: "South", Total: 50, Rows: 1 },
    ]);
    expect(() => DataTools.summarize(rows, "Region", { X: ["median", "Amount"] })).toThrow(/Unknown measure/);
  });
  it("works with date texts without time zone shifts", () => {
    expect(DataTools.byMonth(rows, "Date").map((g: { key: string; rows: unknown[] }) => [g.key, g.rows.length])).toEqual([["2024-01", 2], ["2024-02", 2]]);
    const d = DataTools.toDate("2024-02-01");
    expect([d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()]).toEqual([2024, 1, 1, 0]);
    expect(DataTools.toDate("01/02/2024")).toBeNull();
    expect(DataTools.year("2024-02-01")).toBe(2024);
    expect(DataTools.percent(1, 8)).toMatch(/^12[.,]5%$/);
    expect(DataTools.percent(1, 0)).toBe("");
  });
});

describe("DataTools.load", () => {
  const index = { "Source/Sales Q1.csv": { source: "Source/Sales Q1.csv", json: "data/sales-q1.json", js: "data/sales-q1.js", global: "salesQ1Data" } };
  const g = globalThis as Record<string, unknown>;

  it("reads the CSV itself when the page is served, and the converted JSON when that fails", async () => {
    const asked: string[] = [];
    g.location = { protocol: "http:" };
    g.DataIndex = index;
    g.fetch = (url: string) => {
      asked.push(url);
      if (url.endsWith(".csv") && asked.length === 1) return Promise.resolve(new Response("Date;Amount\n31-01-2024;1,5\n"));
      if (url.endsWith(".json")) return Promise.resolve(new Response('[{"Date":"2024-01-31","Amount":9}]'));
      return Promise.resolve(new Response("", { status: 404 }));
    };
    try {
      DataTools.configure({ base: "http://x/" });
      expect(await DataTools.load("Source/Sales Q1.csv")).toEqual([{ Date: "2024-01-31", Amount: 1.5 }]);
      expect(asked[0]).toBe("http://x/Source/Sales Q1.csv");
      expect(await DataTools.load("sales-q1")).toEqual([{ Date: "2024-01-31", Amount: 9 }]);   // the CSV is gone (404): the JSON
    } finally {
      delete g.location; delete g.DataIndex; delete g.fetch;
    }
  });

  it("loads the converted copy with a script tag when the page is opened from disk", async () => {
    const added: string[] = [];
    g.location = { protocol: "file:" };
    g.window = g;
    g.document = {
      head: {
        appendChild(el: { src: string; onload: () => void }) {
          added.push(el.src);
          if (el.src.endsWith("data-index.js")) g.DataIndex = index;
          if (el.src.endsWith("sales-q1.js")) g.salesQ1Data = [{ Amount: 1 }];
          el.onload();
        },
      },
      createElement: () => ({}),
    };
    try {
      DataTools.configure({ base: "file:///p/" });
      expect(await DataTools.load("data/sales-q1.json")).toEqual([{ Amount: 1 }]);
      expect(added).toEqual(["file:///p/data/data-index.js", "file:///p/data/sales-q1.js"]);
      await expect(DataTools.load("Source/other.csv")).rejects.toThrow(/No converted copy/);
    } finally {
      delete g.location; delete g.window; delete g.document; delete g.DataIndex; delete g.salesQ1Data;
    }
  });

  it("types CSV values exactly as the page file readers do", () => {
    for (const text of ['Datum;Bedrag;Code\n31-01-2024;1.250,50;007\n', 'a,b\n"x ""y""",1e3\n,\n', "D\n12/31/2024\n"]) {
      expect(DataTools.parseCsv(text)).toEqual(KitData.parseCsv(text));
    }
  });
});

describe("KitData.toCsv", () => {
  it("writes a header row and quotes values with commas, quotes or line breaks", () => {
    const rows = [
      { name: "Ann", team: "Sales, North", note: 'Said "yes"', score: 7 },
      { name: "Bob", team: "Support", note: "Line one\nline two", score: null },
    ];
    expect(KitData.toCsv(rows, [{ key: "name", label: "Name" }, { key: "team", label: "Team" }, { key: "note", label: "Note" }, "score"])).toBe(
      'Name,Team,Note,score\r\nAnn,"Sales, North","Said ""yes""",7\r\nBob,Support,"Line one\nline two",',
    );
  });
  it("takes the first row's keys when no columns are given, and gives only the header for no rows", () => {
    expect(KitData.toCsv([{ a: 1, b: "x" }])).toBe("a,b\r\n1,x");
    expect(KitData.toCsv([], ["a", "b"])).toBe("a,b");
  });
});
