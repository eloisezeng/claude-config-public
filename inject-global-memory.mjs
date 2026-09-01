#!/usr/bin/env node
// SessionStart hook: print the global (cross-project) memory index to stdout
// so it loads in EVERY project. Plain stdout (no JSON), always exit 0.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const dir = process.env.CLAUDE_GLOBAL_MEMORY_DIR || join(scriptDir, 'memories', 'global');
// 8000 → 12000 on the user's word (2026-08-19): the index hit a 287-char margin and she chose
// raising the budget over trimming. The cost is always-on context in EVERY session, so raise
// deliberately, not reflexively.
const BUDGET = 12000;

let raw = '';
try { raw = readFileSync(join(dir, 'MEMORY.md'), 'utf8'); } catch { process.exit(0); }
// Strip HTML doc comments so the scaffold/explanatory comment is never injected.
const body = raw.replace(/<!--[\s\S]*?-->/g, '').trim();
if (body === '') process.exit(0);

const header =
  `# Global memory (cross-project) — bodies at ${dir}/<name>.md, unfold with Read; ` +
  `project-local memory overrides these defaults\n\n`;

let out = header + body + '\n';
if (out.length > BUDGET) {
  const notice = `\n… (truncated — read ${dir}/MEMORY.md in full)\n`;
  const slice = out.slice(0, BUDGET - notice.length);   // reserve room so total <= BUDGET
  const atLineBoundary = slice.slice(0, slice.lastIndexOf('\n'));
  out = atLineBoundary + notice;
}
process.stdout.write(out);
process.exit(0);
