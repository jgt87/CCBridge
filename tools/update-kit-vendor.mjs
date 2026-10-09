// Development only (needs Node.js): copies the third-party engines of the UI kit's SQL and Python parts
// into templates/ui-kit/vendor/ from unpacked npm packages:
//   node tools/update-kit-vendor.mjs <sql.js package folder> <pyodide package folder>
// sql.js: the pure-JavaScript build (sql-asm.js: no WebAssembly file to fetch, so it also works in a page
// opened from disk). Pyodide: the core files (works when the page is served). Links to other GitHub
// repositories in text files become plain words (tests/Repository.Tests.ps1).
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [sqlDir, pyDir] = process.argv.slice(2);
if (!sqlDir || !pyDir) { console.error('usage: node tools/update-kit-vendor.mjs <sql.js folder> <pyodide folder>'); process.exit(1); }
const vendor = path.join(repo, 'templates', 'ui-kit', 'vendor');
const unlink = (t) => t.replace(/https?:\/\/(?:www\.)?(?:github\.com|raw\.githubusercontent\.com|gist\.github\.com)\/(?!jgt87\/CCBridge\b)[\w.\-/#?=&%~]*/g, 'the library documentation');
const copyText = (from, to) => { fs.mkdirSync(path.dirname(to), { recursive: true }); fs.writeFileSync(to, unlink(fs.readFileSync(from, 'utf8'))); };
const copyBin = (from, to) => { fs.mkdirSync(path.dirname(to), { recursive: true }); fs.copyFileSync(from, to); };
const version = (dir) => JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8')).version;

const sq = path.join(vendor, 'sqljs');
copyText(path.join(sqlDir, 'dist', 'sql-asm.js'), path.join(sq, 'sql-asm.js'));
copyText(path.join(sqlDir, 'LICENSE'), path.join(sq, 'LICENSE-sqljs.txt'));
fs.writeFileSync(path.join(sq, 'README.txt'), 'sql.js ' + version(sqlDir) + ' (MIT licence, LICENSE-sqljs.txt): SQLite compiled to JavaScript (sql-asm.js, unmodified apart from links in comments). Used by the UI kit\'s kit-sql.js.\n');

const py = path.join(vendor, 'pyodide');
for (const f of ['pyodide.js', 'pyodide.asm.mjs', 'pyodide-lock.json']) copyText(path.join(pyDir, f), path.join(py, f));
for (const f of ['pyodide.asm.wasm', 'python_stdlib.zip']) copyBin(path.join(pyDir, f), path.join(py, f));
fs.writeFileSync(path.join(py, 'README.txt'), 'Pyodide ' + version(pyDir) + ': Python (CPython, PSF licence) compiled to WebAssembly, by the Pyodide project (Mozilla Public License 2.0; source and licence text at pyodide.org). Unmodified core files apart from links in text. Used by the UI kit\'s kit-python.js; it loads its parts from this folder, so it works when the page is served (Open app), not when opened from disk.\n');
for (const d of [sq, py]) for (const f of fs.readdirSync(d)) console.log(path.relative(repo, path.join(d, f)).padEnd(52), (fs.statSync(path.join(d, f)).size / 1024 / 1024).toFixed(2), 'MB');
