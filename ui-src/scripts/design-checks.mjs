// Rendered design checks on the built UI (../ui), with invented data only (`npm run check:design`
// after `npm run build`). Starts a small server on the test port in design-check.json "base" that
// serves ../ui and answers /api/* from the config's "api" block, runs check-design-rules.mjs (every
// view in the config) and check-control-rows.mjs (the first screen at 1440, 720 and 390 px), then
// stops the server. Never the person's running StreamHub (port 8765). Ports: 5297 (page), 9571 and
// 9572 (the checks' browsers), chosen apart from the checks' defaults that other projects use.
// The two checks are CommonShared's starters (templates/scripts), copied in with their browser fix.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';

const here = import.meta.dirname;
const configPath = join(here, '..', 'design-check.json');
const cfg = JSON.parse(readFileSync(configPath, 'utf8'));
const ui = normalize(join(here, '..', '..', 'ui'));
const base = new URL(cfg.base);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.json': 'application/json', '.ico': 'image/x-icon' };

const server = createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (path.startsWith('/api/')) {
    const body = cfg.api?.[path];
    res.writeHead(body === undefined ? 404 : 200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(body === undefined ? { error: 'not in design-check.json "api"' } : body));
    return;
  }
  const file = normalize(join(ui, path === '/' ? 'index.html' : path));
  if (!file.startsWith(ui)) { res.writeHead(403); res.end(); return; }
  const send = async (f) => { const b = await readFile(f); res.writeHead(200, { 'Content-Type': types[extname(f)] || 'application/octet-stream' }); res.end(b); };
  try { await send(file); } catch { await send(join(ui, 'index.html')); }   // the app's own routes
});

const run = (args) => new Promise((resolve) => {
  const p = spawn(process.execPath, args, { stdio: 'inherit' });
  p.on('exit', (code) => resolve(code ?? 2));
  p.on('error', () => resolve(2));
});

server.on('error', (e) => { console.error(`design-checks: the test port ${base.port} is not free (${e.message})`); process.exit(2); });
server.listen(Number(base.port), base.hostname, async () => {
  const design = await run([join(here, 'check-design-rules.mjs'), '--config', configPath, '--port', '9571']);
  const rows = await run([join(here, 'check-control-rows.mjs'), cfg.base + '/', '--widths', '1440,720,390', '--port', '9572']);
  server.close();
  process.exit(Math.max(design, rows));
});
