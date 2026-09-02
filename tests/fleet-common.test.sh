#!/usr/bin/env bash
# The fleet viewers had NO test of any kind (measured 2026-09-01, while extracting the five
# helpers that fleet-tail.mjs and fleet-watch.mjs had copy-pasted between them). This pins the
# shared module's behaviour, plus the two things the extraction itself could break silently.
#
# Everything that mutates runs against a COPY of bin/ in a sandbox: this repo autocommits and
# autopushes every few seconds, so a fault armed in the tracked tree ships before it is disarmed.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/bin"
fail=0
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()   { echo "  ok: $*"; }
bad()  { echo "FAIL: $*"; fail=1; }

echo "case 1: blocks() normalises all three content shapes"
node --input-type=module -e "
import { blocks, renderable } from '$BIN/fleet-common.mjs'
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const cases = [
  // The 555-turn bug: the daemon writes a plain user turn as a STRING, not an array of blocks.
  [{ type: 'user', message: { content: 'Read the handoff file at ...' } },
   [{ type: 'text', text: 'Read the handoff file at ...' }], true],
  [{ type: 'user', message: { content: '   ' } }, [], true],
  [{ type: 'assistant', message: { content: [{ type: 'text', text: 'hi' }] } },
   [{ type: 'text', text: 'hi' }], true],
  [{ type: 'assistant', message: {} }, null, false],
  [{ type: 'summary', message: { content: 'x' } }, [{ type: 'text', text: 'x' }], false],
]
let bad = 0
for (const [d, want, wantRenderable] of cases) {
  if (!eq(blocks(d), want)) { console.log('  blocks mismatch for', JSON.stringify(d)); bad++ }
  if (renderable(d) !== wantRenderable) { console.log('  renderable mismatch for', JSON.stringify(d)); bad++ }
}
process.exit(bad ? 1 : 0)
" && ok "string / empty-string / array / absent content, and renderable's type filter" \
  || bad "blocks() or renderable() disagreed with the pinned shapes"

echo "case 2: readRange reads ACROSS the 64K chunk boundary and stops at the caller's end"
python3 -c "
import sys
open(sys.argv[1],'w').write(''.join(chr(97 + i % 26) for i in range(200000)))
" "$SANDBOX/big.txt"
node --input-type=module -e "
import { readRange, CHUNK } from '$BIN/fleet-common.mjs'
import fs from 'node:fs'
const f = '$SANDBOX/big.txt'
const size = fs.statSync(f).size
if (size <= CHUNK) { console.log('  fixture is not larger than one chunk'); process.exit(1) }
const r = readRange(f, 0, size)
if (r.text.length !== size || r.end !== size) { console.log('  full read short:', r.text.length, 'of', size); process.exit(1) }
const whole = fs.readFileSync(f, 'utf8')
if (r.text !== whole) { console.log('  chunked read differs from readFileSync'); process.exit(1) }
const part = readRange(f, 10, 10 + CHUNK + 7)
if (part.text !== whole.slice(10, 10 + CHUNK + 7)) { console.log('  bounded read wrong'); process.exit(1) }
if (readRange(f, 5, 5).text !== '' ) { console.log('  empty range not empty'); process.exit(1) }
// The whole reason it exists: the transcript belongs to another process and can vanish.
if (readRange('$SANDBOX/does-not-exist', 0, 10) !== null) { console.log('  missing file did not return null'); process.exit(1) }
process.exit(0)
" && ok "multi-chunk, bounded, empty and vanished-file reads" \
  || bad "readRange misread across the chunk boundary or threw on a missing file"

echo "case 3: clip keeps the ellipsis INSIDE the column budget"
node --input-type=module -e "
import { clip, hhmm } from '$BIN/fleet-common.mjs'
if (clip('abcdefghij', 5).length !== 5) process.exit(1)
if (clip('abcdefghij', 5) !== 'abcd…') process.exit(1)
if (clip('  a\n\n  b  ', 40) !== 'a b') process.exit(1)
if (clip(null, 10) !== '') process.exit(1)
if (hhmm('2026-09-01T23:52:05.000Z') !== '23:52:05') process.exit(1)
if (hhmm('not a date') !== '--:--:--') process.exit(1)
process.exit(0)
" && ok "budget, whitespace collapse, null, and hhmm's fallback" \
  || bad "clip or hhmm drifted"

echo "case 4: neither viewer keeps its own copy of a shared helper"
# This is the drift guard. The two files were byte-identical forks whose COMMENTS had already
# diverged; a re-added local definition would shadow the import with no error anywhere, and the
# two panes would silently disagree about which turns exist.
for v in fleet-tail.mjs fleet-watch.mjs; do
  grep -q "from './fleet-common.mjs'" "$BIN/$v" \
    || bad "$v does not import the shared module"
  for n in readRange clip hhmm blocks renderable; do
    if grep -qE "^(export )?(const|function|let|var) $n\b" "$BIN/$v"; then
      bad "$v redefines $n locally, shadowing the shared one"
    fi
  done
done
[ "$fail" -eq 0 ] && ok "both import; neither redefines readRange/clip/hhmm/blocks/renderable"

echo "case 5: fleet doctor REPORTS a missing dependency (control: break a COPY, never the tree)"
# `fleet` derives everything from $HOME (BIN=$HOME/.claude/bin), so the honest way to test the
# INSTALL check is to build a whole fake install under a sandbox HOME. Copying bin/ elsewhere and
# running it there proves nothing -- the first attempt did exactly that, deleted the sandbox copy,
# and doctor cheerfully read the real install and said ok. That miss is why this case has a control.
mkdir -p "$SANDBOX/home/.claude/bin"
cp "$BIN"/fleet "$BIN"/fleet-*.mjs "$BIN"/fleet-*.sh "$SANDBOX/home/.claude/bin/" 2>/dev/null
HOME="$SANDBOX/home" "$SANDBOX/home/.claude/bin/fleet" doctor >"$SANDBOX/doctor.clean" 2>&1
grep -q 'fleet-common.mjs : ok' "$SANDBOX/doctor.clean" \
  && ok "an intact install reports fleet-common.mjs ok" \
  || { bad "doctor did not report fleet-common.mjs ok on an intact install"; sed -n '/fleet-/p' "$SANDBOX/doctor.clean"; }
grep -q 'fleet-flags.mjs : ok' "$SANDBOX/doctor.clean" \
  && ok "and fleet-flags.mjs, which the old hand-written list had never been updated to name" \
  || bad "doctor does not check fleet-flags.mjs"

rm -f "$SANDBOX/home/.claude/bin/fleet-common.mjs"
HOME="$SANDBOX/home" "$SANDBOX/home/.claude/bin/fleet" doctor >"$SANDBOX/doctor.broken" 2>&1
grep -q 'fleet-common.mjs : \*\*\* MISSING \*\*\*' "$SANDBOX/doctor.broken" \
  && ok "a partial install is reported MISSING, not certified ok" \
  || { bad "doctor stayed green with a dependency deleted"; sed -n '/fleet-/p' "$SANDBOX/doctor.broken"; }
# And the tracked tree must be exactly as we found it -- this repo autocommits.
[ -f "$BIN/fleet-common.mjs" ] \
  && ok "tracked bin/fleet-common.mjs untouched by this test" \
  || bad "THIS TEST DELETED THE REAL FILE"

[ "$fail" -eq 0 ] && echo "PASS: the shared fleet helpers behave, and a partial install cannot read as healthy"
exit "$fail"
