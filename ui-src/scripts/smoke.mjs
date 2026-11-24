// Smoke test of the built UI (../ui), with invented data only (`npm run smoke` after `npm run build`).
//  1. Build output: ui/index.html exists and every script, stylesheet and icon it names is in ui/.
//  2. Serves ../ui read-only on a free port the system hands out (never a reserved one below), answers
//     /api/* from design-check.json "api", and loads every view of design-check.json in headless Edge
//     or Chrome over the DevTools protocol (the browser ships with Windows; nothing is installed).
//  3. Fails on a console error, an uncaught error or unhandled rejection, or an asset that does not
//     load (a 4xx/5xx answer or a failed request for anything outside /api/).
// Never the person's running StreamHub (8765). Exit 0 = clean; 1 = a problem (view, what); 2 = setup.
//   node scripts/smoke.mjs [--browser <path>] [--ui <folder>]   (--ui: another built copy, to prove a failure)
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { extname, join, normalize, sep } from "node:path";

const here = import.meta.dirname;
const arg = (name) => { const i = process.argv.indexOf(name); return i > 1 ? process.argv[i + 1] || "" : ""; };
const ui = normalize(arg("--ui") || join(here, "..", "..", "ui"));
const cfg = JSON.parse(readFileSync(join(here, "..", "design-check.json"), "utf8"));
// Ports other tools on a dev machine hold, and the design checks' own: never served on, even if free.
const RESERVED = new Set([3000, 3100, 4291, 4300, 4305, 5297, 7420, 8765, 9571, 9572]);
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2", ".woff": "font/woff", ".json": "application/json", ".ico": "image/x-icon", ".wasm": "application/wasm" };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const setup = (msg) => { console.error(`smoke: ${msg}`); process.exit(2); };

/** Step 1: the files index.html names, missing from ui/ (relative ./ or / paths only). */
export function missingBuildFiles(root) {
  const index = join(root, "index.html");
  if (!existsSync(index)) return ["index.html"];
  const html = readFileSync(index, "utf8");
  const refs = [...html.matchAll(/\b(?:src|href)="([^"]+)"/g)].map((m) => m[1]).filter((u) => !/^[a-z]+:/i.test(u) && !u.startsWith("//") && !u.startsWith("#"));
  if (!refs.some((u) => u.endsWith(".js"))) return ["a script in index.html"];
  return refs.filter((u) => { const f = join(root, u.replace(/^\.?\//, "")); return !existsSync(f) || statSync(f).size === 0; });
}

function serve() {
  const server = createServer(async (req, res) => {
    const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (path.startsWith("/api/")) {
      const body = cfg.api?.[path];
      res.writeHead(body === undefined ? 404 : 200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(body === undefined ? { error: 'not in design-check.json "api"' } : body));
      return;
    }
    const file = normalize(join(ui, path === "/" ? "index.html" : path));
    if (file !== ui && !file.startsWith(ui + sep)) { res.writeHead(403); res.end(); return; }
    // A path with a file extension must exist (a missing asset is a 404, never the page); the app's own
    // routes (no extension) get index.html.
    const target = extname(path) ? file : join(ui, "index.html");
    try {
      const b = await readFile(target);
      res.writeHead(200, { "Content-Type": types[extname(target)] || "application/octet-stream" });
      res.end(b);
    } catch { res.writeHead(404); res.end(); }
  });
  const listen = () => new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
  return (async () => {
    for (let i = 0; i < 10; i++) {
      const port = await listen();
      if (!RESERVED.has(port)) return { server, port };
      await new Promise((r) => server.close(r));
    }
    setup("no free port outside the reserved ones");
  })();
}

function findBrowser(given) {
  const pf = process.env["ProgramFiles"] || "C:\\Program Files";
  const pf86 = process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)";
  const local = process.env.LOCALAPPDATA || "";
  const list = [given, process.env.BROWSER,
    join(pf86, "Microsoft", "Edge", "Application", "msedge.exe"), join(pf, "Microsoft", "Edge", "Application", "msedge.exe"),
    join(pf, "Google", "Chrome", "Application", "chrome.exe"), join(pf86, "Google", "Chrome", "Application", "chrome.exe"),
    local && join(local, "Google", "Chrome", "Application", "chrome.exe"),
    "/usr/bin/microsoft-edge", "/usr/bin/google-chrome", "/usr/bin/chromium"];
  return list.find((p) => p && existsSync(p)) || null;
}

/** A headless browser on a port of its own choosing (DevToolsActivePort), and one page to drive. */
async function launch(exe) {
  const profile = mkdtempSync(join(tmpdir(), "ccb-smoke-"));
  const proc = spawn(exe, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--disable-gpu", "about:blank"], { stdio: "ignore" });
  proc.on("error", (e) => console.error(`smoke: could not start the browser: ${e.message}`));
  let port = 0;
  for (let i = 0; i < 100 && !port; i++) {
    await wait(100);
    const f = join(profile, "DevToolsActivePort");
    // The browser may still hold the file open while it writes it (EBUSY): try again on the next round.
    try { if (existsSync(f)) port = Number(readFileSync(f, "utf8").split("\n")[0]) || 0; } catch { /* still being written */ }
  }
  if (!port) { proc.kill(); setup("the browser did not open its DevTools port"); }
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === "page"); } catch { /* not up yet */ }
    if (!target) await wait(100);
  }
  if (!target) { proc.kill(); setup("the browser has no page to drive"); }
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.addEventListener("open", resolve); ws.addEventListener("error", reject); });
  let id = 0;
  const pending = new Map();
  const handlers = [];
  ws.addEventListener("message", (m) => {
    const d = JSON.parse(m.data);
    if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
    else if (d.method) for (const h of handlers) h(d);
  });
  const S = (method, params = {}) => new Promise((resolve) => { const i = ++id; pending.set(i, resolve); ws.send(JSON.stringify({ id: i, method, params })); });
  const js = async (expression) => (await S("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result?.result?.value;
  const close = async () => {
    try { ws.close(); } catch { /* gone */ }
    proc.kill();
    for (let i = 0; i < 20; i++) { try { rmSync(profile, { recursive: true, force: true }); break; } catch { await wait(150); } }
  };
  return { S, js, on: (h) => handlers.push(h), close };
}

const clickByText = (text) => `(() => { const want = ${JSON.stringify(text)}; const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim();
  const shown = [...document.querySelectorAll('button, a, [role=button], [role=tab], [role^=menuitem], [role=option]')].filter((e) => e.getBoundingClientRect().width > 0);
  const b = shown.find((e) => norm(e.textContent) === want) || shown.find((e) => norm(e.getAttribute('aria-label')) === want) || shown.find((e) => norm(e.textContent).startsWith(want));
  if (b) b.click(); return !!b; })()`;
const clickBySelector = (sel) => `(() => { const b = document.querySelector(${JSON.stringify(sel)}); if (b) b.dispatchEvent(new MouseEvent('click', { bubbles: true })); return !!b; })()`;

/** One view: load it, wait for its ready element, take its steps; returns its problems. */
async function view(page, base, v, seen) {
  seen.length = 0;
  await page.S("Page.navigate", { url: "about:blank" });
  await page.S("Page.navigate", { url: base + (v.path || "/") });
  const problems = [];
  let ready = !v.ready;
  for (let k = 0; k < 100 && !ready; k++) {
    ready = Boolean(await page.js(`!!document.querySelector(${JSON.stringify(v.ready)})`));
    if (!ready) await wait(100);
  }
  if (!ready) problems.push(`"${v.ready}" never appeared`);
  else {
    await wait(cfg.wait ?? 500);
    for (const s of v.steps || []) {
      if (s.wait) { await wait(s.wait); continue; }
      if (!(await page.js(s.click ? clickByText(s.click) : clickBySelector(s.clickSelector)))) { problems.push(`step ${JSON.stringify(s)} found nothing to click`); break; }
      await wait(300);
    }
    await wait(300);
  }
  return [...problems, ...seen];
}

async function main() {
  const given = arg("--browser");
  const missing = missingBuildFiles(ui);
  if (missing.length) { console.log(`smoke: the build output is incomplete (run npm run build): missing ${missing.join(", ")}`); process.exit(1); }
  console.log("smoke: build output complete (ui/index.html and every file it names)");
  const exe = findBrowser(given);
  if (!exe) setup("no Edge or Chrome found: pass --browser <path> or set BROWSER");
  const { server, port } = await serve();
  const base = `http://127.0.0.1:${port}`;
  const page = await launch(exe);
  const seen = [];
  page.on((d) => {
    const p = d.params || {};
    if (d.method === "Runtime.consoleAPICalled" && p.type === "error") seen.push(`console error: ${p.args.map((a) => a.value ?? a.description ?? "").join(" ").slice(0, 200)}`);
    else if (d.method === "Runtime.exceptionThrown") seen.push(`uncaught: ${(p.exceptionDetails.exception?.description || p.exceptionDetails.text || "").split("\n")[0].slice(0, 200)}`);
    else if (d.method === "Network.responseReceived" && p.response.status >= 400 && p.response.url.startsWith(base) && !new URL(p.response.url).pathname.startsWith("/api/")) seen.push(`asset ${p.response.status}: ${new URL(p.response.url).pathname}`);
    else if (d.method === "Network.loadingFailed" && !p.canceled && seen.reqs?.get(p.requestId)?.startsWith(base) && !new URL(seen.reqs.get(p.requestId)).pathname.startsWith("/api/")) seen.push(`asset failed: ${new URL(seen.reqs.get(p.requestId)).pathname} (${p.errorText})`);
    if (d.method === "Network.requestWillBeSent") (seen.reqs ||= new Map()).set(p.requestId, p.request.url);
  });
  const out = [];
  try {
    for (const m of ["Runtime.enable", "Network.enable", "Page.enable"]) await page.S(m);
    await page.S("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
    for (const v of cfg.views) {
      const problems = await view(page, base, v, seen);
      if (problems.length) for (const p of problems) out.push(`${v.name}: ${p}`);
      else console.log(`smoke: ${v.name}: loaded, no console error, no missing asset`);
    }
  } finally {
    await page.close();
    server.close();
  }
  if (out.length) { console.log("smoke: problems\n" + out.join("\n")); process.exit(1); }
  console.log(`smoke: OK, ${cfg.views.length} view(s) on port ${port}`);
  process.exit(0);
}

if (process.argv[1] && normalize(process.argv[1]) === normalize(join(here, "smoke.mjs"))) {
  main().catch((e) => setup(e.message));
}
