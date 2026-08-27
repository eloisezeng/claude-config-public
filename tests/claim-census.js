#!/usr/bin/env node
// Census of every population primitive reachable while fd 7, 8 or 9 is held.
//
// The population and its four classes are defined in docs/handoff-successor.md
// ("Work under a held claim"). This script IS the guard the suite runs: it
// derives the claim closure from the source, finds every primitive site inside
// it, and reports each site's `# CLAIM:` tag. Nothing here is hand-maintained
// except the region table and the pattern list, and the suite asserts both --
// a census that silently stops matching would agree with a count of zero, so
// the caller checks a floor as well as the totals.
//
// Usage: node claim-census.js <script> [--list] [--json] [--audit]

'use strict';
const fs = require('fs');

function fatal(msg) { console.error('census: ' + msg); process.exit(2); }

const PATH = process.argv[2];
if (!PATH) { console.error('usage: claim-census.js <script> [--list] [--json]'); process.exit(2); }
const SRC = fs.readFileSync(PATH, 'utf8').split('\n');

// ---------------------------------------------------------------------------
// decode: strip comments and quoted TEXT, but keep everything that is still
// code -- $( ) substitutions (which fork) and $VAR expansions (which can be the
// command word, as in "$NODE" -e). Line numbering is preserved exactly: a
// quoted span or a line continuation may cross lines, and losing one newline
// silently shifts every finding after it.
// ---------------------------------------------------------------------------
function decode(text) {
  const out = [''];
  const emit = (c) => { if (c === '\n') out.push(''); else out[out.length - 1] += c; };
  const isWordChar = (c) => /[A-Za-z0-9_?@#*]/.test(c);

  const stack = [['code', 0]];            // [kind, paren-depth-for-substitutions]
  let i = 0; const n = text.length;
  while (i < n) {
    const ch = text[i];
    const kind = stack[stack.length - 1][0];

    if (ch === '\n') { emit('\n'); i += 1; continue; }

    if (ch === '\\' && i + 1 < n) {
      if (text[i + 1] === '\n') emit('\n');
      else if (kind === 'code') emit(' ');
      i += 2; continue;
    }

    if (kind === 'sq') {
      if (ch === "'") { stack.pop(); emit(' '); }
      i += 1; continue;
    }

    if (kind === 'dq') {
      if (ch === '"') { stack.pop(); emit(' '); i += 1; continue; }
      if (text.substr(i, 2) === '$(') { stack.push(['sub', 0]); emit('$'); emit('('); i += 2; continue; }
      if (ch === '$') {                   // keep the expansion: it can be a command word
        let j = i + 1;
        if (j < n && text[j] === '{') { while (j < n && text[j] !== '}') j += 1; j += 1; }
        else { while (j < n && isWordChar(text[j])) j += 1; }
        for (const c of text.slice(i, j)) emit(c);
        i = j; continue;
      }
      emit(' '); i += 1; continue;
    }

    // code or sub
    const tail = out[out.length - 1];
    if (ch === '#' && (tail === '' || ' \t;|&('.includes(tail[tail.length - 1]))) {
      const j = text.indexOf('\n', i);
      i = j < 0 ? n : j;
      continue;
    }
    if (ch === "'") { stack.push(['sq', 0]); emit(' '); i += 1; continue; }
    if (ch === '"') { stack.push(['dq', 0]); emit(' '); i += 1; continue; }
    if (text.substr(i, 2) === '$(') { stack.push(['sub', 0]); emit('$'); emit('('); i += 2; continue; }
    if (ch === '(' && kind === 'sub') stack[stack.length - 1][1] += 1;
    else if (ch === ')' && kind === 'sub') {
      if (stack[stack.length - 1][1] === 0) { stack.pop(); emit(')'); i += 1; continue; }
      stack[stack.length - 1][1] -= 1;
    }
    emit(ch); i += 1;
  }
  return out;
}

const CODE = decode(SRC.join('\n'));
if (CODE.length !== SRC.length) fatal(`decode lost lines: ${CODE.length} != ${SRC.length}`);
const codeOf = (n) => CODE[n - 1];

// ---------------------------------------------------------------------------
// function table and call graph
// ---------------------------------------------------------------------------
const defs = [];
SRC.forEach((l, idx) => {
  const m = /^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{/.exec(l);
  if (m) defs.push([m[1], idx + 1, l]);
});
const FN = new Map();
defs.forEach(([name, ln, l], k) => {
  if (/\}\s*$/.test(l)) { FN.set(name, [ln, ln]); return; }
  let end = k + 1 < defs.length ? defs[k + 1][1] - 1 : SRC.length;
  while (end > ln && !SRC[end - 1].startsWith('}')) end -= 1;
  FN.set(name, [ln, end]);
});

const WORD = /(?:^|[\s;|&(`{]|\$\()\s*([A-Za-z_][A-Za-z0-9_]*)\b/g;
function called(a, b) {
  const out = new Set();
  for (let n = a; n <= b; n++) {
    // A definition's own NAME is not a call to itself. The line used to be SKIPPED
    // for that reason, which was right for a multi-line header and wrong for a
    // ONE-LINE function, whose whole body sits on the definition line: every call
    // that body made was invisible to the walk, so the callee never entered the
    // closure and its forks were never counted. That is not hypothetical -- it hid
    // `_strip_csi` and its `awk`, a fork that runs while fd 9 is held, and the only
    // symptom was a stray tag. Strip the `name() {` PREFIX instead of the line: a
    // multi-line header has nothing left after it, so its behaviour is unchanged.
    const c = codeOf(n).replace(/^\s*[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{?/, ' ');
    WORD.lastIndex = 0;
    let m;
    while ((m = WORD.exec(c)) !== null) if (FN.has(m[1])) out.add(m[1]);
  }
  return out;
}

// Regions: the lines executed while a claim descriptor is HELD. They are read
// from MARKERS in the source, not from a table of line numbers here, for two
// reasons: an edit that moves code cannot silently move a boundary (moving a
// marker is a deliberate act), and the definition of the population is visible
// at the place it applies. Each region excludes the arm on which the take
// FAILED -- see docs/handoff-successor.md, "What is deliberately OUTSIDE it".
const EXPECTED_REGIONS = ['alert', 'lease', 'watch', 'claim', 'dispatch'];
const REGIONS = (() => {
  const begins = new Map(), ends = new Map();
  SRC.forEach((l, idx) => {
    let m = /^\s*#\s*CLAIM-REGION-BEGIN\s+(\S+)\s*$/.exec(l);
    if (m) {
      if (begins.has(m[1])) fatal(`two CLAIM-REGION-BEGIN markers for "${m[1]}"`);
      begins.set(m[1], idx + 1);
    }
    m = /^\s*#\s*CLAIM-REGION-END\s+(\S+)\s*$/.exec(l);
    if (m) {
      if (ends.has(m[1])) fatal(`two CLAIM-REGION-END markers for "${m[1]}"`);
      ends.set(m[1], idx + 1);
    }
  });
  const out = [];
  for (const name of EXPECTED_REGIONS) {
    if (!begins.has(name)) fatal(`no CLAIM-REGION-BEGIN marker for "${name}"`);
    if (!ends.has(name)) fatal(`no CLAIM-REGION-END marker for "${name}"`);
    const a = begins.get(name) + 1, b = ends.get(name) - 1;
    if (a > b) fatal(`region "${name}" is empty or inverted (${a} > ${b})`);
    out.push([name, a, b]);
  }
  for (const name of begins.keys()) {
    if (!EXPECTED_REGIONS.includes(name)) fatal(`unknown claim region "${name}"`);
  }
  return out;
})();

const closure = new Set();
{
  const stack = [];
  for (const [, a, b] of REGIONS) stack.push(...called(a, b));
  while (stack.length) {
    const f = stack.pop();
    if (closure.has(f) || !FN.has(f)) continue;
    closure.add(f);
    for (const c of called(...FN.get(f))) if (!closure.has(c)) stack.push(c);
  }
}

// ---------------------------------------------------------------------------
// primitive patterns
// ---------------------------------------------------------------------------
// Every external command this script may invoke. It is an ALLOWLIST, which is a
// coverage hole in one direction: a binary used but not listed is a fork the
// census cannot see. `--audit` closes it -- it re-scans the decoded source for a
// curated set of common commands and reports any that is used and not listed, so
// the list is a checked invariant rather than an assumption. `dirname` and
// `uname` were found that way: both are used (resolve_path, HOST_OS), neither
// was listed, and neither is in the closure today -- so the omission was
// invisible until the day one of them moved inside it.
const BINARIES = 'date|osascript|notify-send|basename|mktemp|cat|rm|perl|awk|grep|head|tail'
               + '|sed|stat|readlink|sleep|nohup|pkill|pwd|cd|kill|touch|mkdir|ln|mv|cp|find'
               + '|dirname|uname|ps';
// Common external commands a shell script of this kind might reach for. Being
// on this list is not permission to use one -- it is the census promising to
// NOTICE if you do.
// Shell BUILTINS are deliberately absent: `printf`, `echo`, `test`, `[`, `type`
// and `:` fork nothing, so listing them would report a hit on almost every line
// and the audit would be noise nobody reads. `node` is absent for the opposite
// reason -- the census already matches it through `$NODE`, which is how this
// script always invokes it, and the literal word appears only in the variable's
// own default.
const AUDIT = ('ls|xargs|jq|python|python3|openssl|df|du|chmod|chown|dd|tar|wc|sort|uniq|tr|cut'
             + '|expr|seq|tee|env|timeout|gtimeout|dirname|realpath|install|who|uname|logger'
             + '|say|afplay|md5|shasum|sha256sum|diff|patch|nc|ssh|scp|rsync|git').split('|');
const PATS = [
  ['exec',     new RegExp('(?<![\\w./$-])(' + BINARIES + ')(?![\\w./-])')],
  ['exec',     /\$(NODE|CLAUDE_BIN)\b/],
  ['cmdsub',   /\$\((?!\()/],                       // $(( )) is arithmetic, not a fork
  // The class is every unary test that has to touch the filesystem, not the
  // handful this file happened to use when it was written: `-h` and `-O` were
  // both absent, so `[ -h "$1" ]` -- a symlink check, which is a stat -- would
  // have entered the closure as no site at all. A census whose pattern list is
  // a sample of the code it censuses cannot report a population.
  ['filetest', /\[\s+!?\s*-[rfdLsxewbcgGhkOpSuN]\s/],
  // `eval` is a site because the census CANNOT SEE what it runs: the code is a
  // string, and decode() blanks string literals. An `open` pattern was here
  // instead and matched ZERO lines -- the one real `exec N>>` in this script is
  // inside an eval -- so it was a control that could not fail. Removed; the eval
  // it was written for is now a site in its own right and must carry a tag.
  ['eval',     /(?<![\w./$-])eval(?![\w./-])/],
  ['write',    /(?<![0-9<>&])>>|:\s+>[^&>]|>&9/],
];
const TAG = /#\s*CLAIM:([abcd])\b/;

const lines = new Set();
for (const f of closure) { const [a, b] = FN.get(f); for (let n = a; n <= b; n++) lines.add(n); }
for (const [, a, b] of REGIONS) for (let n = a; n <= b; n++) lines.add(n);

function owner(n) {
  let best = null;
  for (const [f, [a, b]] of FN) {
    if (a <= n && n <= b) {
      if (best === null) best = f;
      else { const [ba, bb] = FN.get(best); if ((b - a) < (bb - ba)) best = f; }
    }
  }
  return best || '<top>';
}

const rows = [];
const consumedTags = new Set();
for (const n of [...lines].sort((x, y) => x - y)) {
  const c = codeOf(n);
  if (!c.trim()) continue;
  const kinds = [...new Set(PATS.filter(([, p]) => p.test(c)).map(([k]) => k))].sort();
  if (!kinds.length) continue;
  // The tag goes on the site's own line as a trailing comment -- except where
  // the shell will not take one: a line ending in `\`, or one that opens a
  // quoted script that continues below. For those the tag is a standalone
  // `# CLAIM:` comment on the line IMMEDIATELY above, which must be a
  // comment-only line: if it were code it could be another site, and the two
  // would share one tag.
  let m = TAG.exec(SRC[n - 1]);
  let tagLine = m ? n : 0;
  if (!m && n >= 2 && /^\s*#/.test(SRC[n - 2])) { m = TAG.exec(SRC[n - 2]); if (m) tagLine = n - 1; }
  if (tagLine) consumedTags.add(tagLine);
  rows.push({ line: n, fn: owner(n), kinds, cls: m ? m[1] : null, text: c.trim().slice(0, 86) });
}

// A tag that no row consumed is the OTHER half of the coverage question, and it
// is the half that fails quietly. An untagged site is loud -- it lands in the
// UNTAGGED count and the suite floors that at zero. A tag whose site moved out
// from under it is silent: the population simply comes back one smaller, which
// looks exactly like a site that was legitimately removed. The stray tag is the
// residue that tells the two apart, and it is also how a tag comes to sit above
// the WRONG line and answer for a site nobody classified. So: every `# CLAIM:`
// in the file must have been read by the loop above.
const strays = [];
for (let n = 1; n <= SRC.length; n++) {
  if (!TAG.test(SRC[n - 1])) continue;
  if (consumedTags.has(n)) continue;
  strays.push(`line ${n} carries a # CLAIM: tag that no primitive site reads: ${SRC[n - 1].trim().slice(0, 76)}`);
}
if (strays.length && !process.argv.includes('--json')) {
  for (const v of strays) console.error('census: ' + v);
}

// ---------------------------------------------------------------------------
// `a` is a CLAIM, so it is checked, not believed.
//
// A tag nothing evaluates is not a classification -- it is a comment that
// happens to look like one, and this loop has now found that shape eleven
// times. `a` says "this runs inside timed_to_file's deadline-killed child", and
// that is decidable from the call graph: either the site's own line IS the
// bounded invocation (`fs_get T f …` / `timed_to_file T out f …`), or the site
// sits in a helper whose EVERY call site is one. A probe that acquires one
// ordinary caller stops being bounded, and this is what says so.
// ---------------------------------------------------------------------------
function boundedInvocation(line, name) {
  const w = line.trim().split(/[\s;|&()]+/).filter(Boolean);
  for (let i = 0; i < w.length; i++) {
    if (w[i] !== name) continue;
    if (i >= 2 && w[i - 2] === 'fs_get') continue;
    if (i >= 3 && w[i - 3] === 'timed_to_file') continue;
    return false;             // an occurrence that is not a bounded invocation
  }
  return true;
}
const WORDRE = (n) => new RegExp('(?:^|[\\s;|&(`{])' + n + '(?![\\w-])');
const aViolations = [];
{
  const checked = new Map();
  const inProgress = new Set();
  const isBoundedHelper = (f) => {
    if (checked.has(f)) return checked.get(f);
    // A cycle proves nothing, so it is not evidence of bounding.
    if (inProgress.has(f)) return false;
    inProgress.add(f);
    const [fa, fb] = FN.get(f);
    let calls = 0, ok = true;
    for (let n = 1; n <= CODE.length; n++) {
      if (n === fa) continue;                       // its own definition line
      const c = CODE[n - 1];
      if (!WORDRE(f).test(c)) continue;
      calls += 1;
      if (boundedInvocation(c, f)) continue;
      // ...OR the call site sits inside a helper that is itself bounded, which
      // is the same deadline-killed child one frame down. The rule was
      // single-level and reported `path_state` — called only by mtime_of and
      // file_exists, each invoked only as `fs_get T <f>` — as unbounded
      // (round 6, C4's fix). Transitive, because the boundedness is.
      const site = owner(n);
      if (!site || site === '<top>' || site === f || !FN.has(site) || !isBoundedHelper(site)) ok = false;
    }
    // No call site at all is not "bounded" -- it is dead code, and a tag on
    // dead code is a claim about nothing.
    const verdict = calls > 0 && ok;
    inProgress.delete(f);
    checked.set(f, verdict);
    return verdict;
  };
  for (const r of rows) {
    if (r.cls !== 'a') continue;
    const own = CODE[r.line - 1];
    if (WORDRE('fs_get').test(own) || WORDRE('timed_to_file').test(own)) continue;
    if (!FN.has(r.fn)) { aViolations.push(`line ${r.line} is tagged 'a' but sits at top level, where nothing bounds it`); continue; }
    if (!isBoundedHelper(r.fn)) aViolations.push(`line ${r.line} is tagged 'a', but ${r.fn}() is reached from a call site that is not "fs_get T ${r.fn}" or "timed_to_file T out ${r.fn}"`);
  }
}
if (aViolations.length && !process.argv.includes('--json')) {
  for (const v of aViolations) console.error('census: ' + v);
}

const counts = {};
for (const r of rows) { const k = r.cls || 'UNTAGGED'; counts[k] = (counts[k] || 0) + 1; }

if (process.argv.includes('--audit')) {
  const listed = new Set(BINARIES.split('|'));
  const bad = [];
  for (const name of new Set(AUDIT)) {
    if (listed.has(name)) continue;
    const re = new RegExp('(?<![\\w./$-])' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(?![\\w./-])');
    for (let n = 1; n <= CODE.length; n++) if (re.test(CODE[n - 1])) { bad.push(`${name} line ${n}`); break; }
  }
  if (bad.length) {
    console.log('UNLISTED ' + bad.join('; '));
    process.exit(3);
  }
  console.log('AUDIT-CLEAN ' + listed.size + ' listed, ' + new Set(AUDIT).size + ' audited');
  process.exit(0);
}

if (process.argv.includes('--json')) {
  console.log(JSON.stringify({ closure: [...closure].sort(), total: rows.length, counts, aViolations, strays, rows }, null, 1));
} else {
  console.log(`closure: ${closure.size} functions`);
  console.log(`population: ${rows.length} primitive sites`);
  for (const k of ['a', 'b', 'c', 'd', 'UNTAGGED']) if (k in counts) console.log(`  ${k}: ${counts[k]}`);
  if (aViolations.length) console.log(`  a-UNVERIFIED: ${aViolations.length}`);
  if (strays.length) console.log(`  stray-TAGS: ${strays.length}`);
  if (process.argv.includes('--list')) {
    for (const r of rows) {
      console.log(`  ${String(r.line).padStart(5)} ${r.cls || '-'} ${r.kinds.join(',').padEnd(16)} `
                + `${r.fn.padEnd(19)} ${r.text}`);
    }
  }
}
if (aViolations.length || strays.length) process.exit(2);
