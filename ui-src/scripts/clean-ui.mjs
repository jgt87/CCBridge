// Empties ../ui/assets file by file before a build. Vite would delete and recreate the folder, which
// fails on Windows while any program has the folder open (EPERM); deleting the files does not.
import { readdirSync, rmSync } from "node:fs";
import { join } from "node:path";

const dir = join(import.meta.dirname, "..", "..", "ui", "assets");
let removed = 0;
try {
  for (const name of readdirSync(dir)) {
    rmSync(join(dir, name), { recursive: true, force: true });
    removed++;
  }
} catch (e) {
  if (e.code !== "ENOENT") throw e;
}
console.log(`clean-ui: removed ${removed} old asset(s)`);
