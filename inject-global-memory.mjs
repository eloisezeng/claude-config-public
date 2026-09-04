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
// 12000 → 20000 on 2026-09-02: since the cap abbreviates HOOKS instead of dropping memories,
// 12000 left each hook at ~50 chars (a label, not a summary). 20000 buys ~123 chars for
// +1,850 tokens/session. Keep equal to `budget=` in inject-global-memory.sh.
const BUDGET = 20000;

let raw = '';
try { raw = readFileSync(join(dir, 'MEMORY.md'), 'utf8'); } catch { process.exit(0); }
// Strip HTML doc comments so the scaffold/explanatory comment is never injected.
// Compact `- [slug](slug.md) — hook` to `- slug — hook`. The header below already
// states that bodies live at <dir>/<name>.md, so the markdown link duplicates the
// slug for ~42 chars an entry and buys nothing. Lossless: the slug a Read needs
// survives. Only rewrites when link text and filename match. Keep in step with the
// awk `compact` program in inject-global-memory.sh — one behaviour, two runtimes.
const body = raw
  .replace(/<!--[\s\S]*?-->/g, '')
  .replace(/^- \[([A-Za-z0-9._-]+)\]\(\1\.md\)/gm, '- $1')
  .trim();
if (body === '') process.exit(0);

const header =
  `# Global memory (cross-project) — bodies at ${dir}/<name>.md, unfold with Read; ` +
  `project-local memory overrides these defaults\n\n`;

let out = header + body + '\n';
if (out.length > BUDGET) {
  // ABBREVIATE THE HOOKS, DO NOT DROP THE MEMORIES.
  //
  // The old behaviour sliced at the budget and threw away every entry past the
  // cut: 58 of 123 memories (47%) reached no session, and a memory that is not
  // listed can never be unfolded — the mistake it exists to prevent just gets
  // made again. A memory whose hook is cut short is still listed by SLUG, so it
  // can still be Read. Truncating text is recoverable; dropping a name is not.
  //
  // Find the largest per-hook cap H that makes the WHOLE index fit and cut only
  // the hooks longer than H; short hooks are untouched, so the cost falls on the
  // longest lines. Keep in step with inject-global-memory.sh — the two runtimes'
  // output is asserted IDENTICAL by tests/inject-budget-parity.test.sh.
  const RESERVE = 200;
  const SEP = ' \u2014 ';
  const avail = BUDGET - RESERVE - header.length - 1;
  const count = (s) => s.split('\n').filter((l) => l.startsWith('- ')).length;

  const rows = body.split('\n').map((line) => {
    const i = line.indexOf(SEP);
    return i === -1
      ? { prefix: line, hook: '' }
      : { prefix: line.slice(0, i + SEP.length), hook: line.slice(i + SEP.length) };
  });
  const fixed = rows.reduce((n, r) => n + r.prefix.length + 1, 0);

  if (fixed > avail) {
    // Even bare slugs overflow. Fall back to slice-and-drop, naming the count —
    // the only surface on which that loss is visible at all.
    const slice = out.slice(0, BUDGET - RESERVE);
    const atLineBoundary = slice.slice(0, slice.lastIndexOf('\n'));
    const dropped = count(body) - count(atLineBoundary);
    let notice =
      `\u2026 (TRUNCATED: ${dropped} of ${count(body)} memories are NOT loaded — ` +
      `read ${dir}/MEMORY.md in full; run bin/context-budget.py --report)`;
    if (notice.length > RESERVE) {
      notice = `\u2026 (TRUNCATED: ${dropped} of ${count(body)} memories are NOT loaded)`;
    }
    out = atLineBoundary + '\n' + notice + '\n';
  } else {
    const maxHook = rows.reduce((n, r) => Math.max(n, r.hook.length), 0);
    let lo = 0;
    let hi = maxHook;
    while (lo < hi) {
      const mid = Math.floor((lo + hi + 1) / 2);
      const tot = rows.reduce((n, r) => n + Math.min(r.hook.length, mid), fixed);
      if (tot <= avail) lo = mid;
      else hi = mid - 1;
    }
    const cap = lo;

    let abbreviated = 0;
    let lost = 0;
    const lines = rows.map(({ prefix, hook }) => {
      if (hook.length <= cap) return prefix + hook;
      lost += hook.length - cap;
      abbreviated += 1;
      if (cap >= 1) return prefix + hook.slice(0, cap - 1) + '\u2026';
      return prefix.endsWith(SEP) ? prefix.slice(0, -SEP.length) : prefix;
    });
    const total = count(body);
    // Both forms carry the same phrase "N hooks abbreviated to C chars", so a
    // test (and a reader) can key on one string whichever fired.
    let notice =
      `\u2026 (all ${total} memories above are listed; ${abbreviated} hooks ` +
      `abbreviated to ${cap} chars, ${lost} chars cut — read ${dir}/MEMORY.md ` +
      `for the full line)`;
    if (notice.length > RESERVE) {
      notice = `\u2026 (${abbreviated} of ${total} hooks abbreviated to ${cap} chars)`;
    }
    out = header + lines.join('\n') + '\n' + notice + '\n';
  }
}

process.stdout.write(out);
process.exit(0);
