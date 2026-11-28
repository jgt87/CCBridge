// Line-ending check (docs/12-line-endings.md). Read-only; uses `git ls-files --eol`.
//
//   node scripts/check-eol.mjs            fail on CRLF or mixed text in the index,
//                                         and on mixed files in the working tree
//   node scripts/check-eol.mjs --strict   also fail when a working-tree file's
//                                         endings differ from its eol attribute
//
// Run it in CI and before a release; a project that has added the shared
// .gitattributes passes --strict after one clean checkout.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** Under an audit, the files it lists (AUDIT_FILES: one repo-relative path a line, the tracked files
 *  minus vendored folders), else null for every file. A vendored corpus filled this check's findings
 *  while every other check left it out (a test audit, 26 Nov 2026). */
function auditList(env = process.env) {
  if (!env.AUDIT_FILES) return null;
  try { return new Set(readFileSync(env.AUDIT_FILES, 'utf8').split(/\r?\n/).map((l) => l.trim().replace(/\\/g, '/')).filter(Boolean)); } catch { return null; }
}

// A working-tree file with plain LF or CRLF endings other than its eol attribute asks for.
const differs = (work, want) => Boolean(want) && (work === 'lf' || work === 'crlf') && work !== want;

/** The problems of one `git ls-files --eol` line; binary (-text) files have none. */
function lineProblems(line, strict) {
  const m = line.match(/^i\/(\S*)\s+w\/(\S*)\s+attr\/(.*?)\t(.*)$/);
  if (!m) return [];
  const [, index, work, attr, file] = m;
  if (index === '-text' || attr.includes('-text')) return [];
  const problems = [];
  if (index === 'crlf' || index === 'mixed') problems.push(`index ${index}: ${file}`);
  if (work === 'mixed') problems.push(`working tree mixed: ${file}`);
  const want = attr.match(/eol=(lf|crlf)/)?.[1];
  if (strict && differs(work, want)) problems.push(`working tree ${work}, attribute eol=${want}: ${file}`);
  return problems;
}

/** The problems in `git ls-files --eol -z` output (NUL-separated, so an unusual path is read as it is;
 *  newline-separated output is read too); with strict, also endings that differ from the eol attribute.
 *  Without -z, git quotes non-ASCII paths and a reader splitting on newlines misreads them (L-MCP). */
export const eolProblems = (out, strict, only = null) => out.split(/\0|\n/)
  .filter((line) => !only || only.has(line.split('\t')[1]))
  .flatMap((line) => lineProblems(line, strict));

function main() {
  const strict = process.argv.includes('--strict');
  const problems = eolProblems(execFileSync('git', ['ls-files', '--eol', '-z'], { encoding: 'utf8', maxBuffer: 1 << 28 }), strict, auditList());
  if (problems.length) {
    console.error(`line endings: ${problems.length} problem(s)`);
    problems.slice(0, 50).forEach((p) => console.error(`  ${p}`));
    if (problems.length > 50) console.error(`  ... and ${problems.length - 50} more`);
    console.error('Fix: normalize the file to its eol (LF unless .gitattributes says crlf), then `git add --renormalize .`.');
    process.exitCode = 1;
  } else {
    console.log(`line endings: ok${strict ? ' (strict)' : ''}`);
  }
}

// Runs only as a program: the test imports eolProblems.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
