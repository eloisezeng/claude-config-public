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
# Case 2 can fail by HANGING (a dropped 'got <= 0' break spins forever), and a hang is not a
# failure the runner can attribute. macOS has no timeout(1), so cap with perl's alarm, killing the
# process GROUP -- and map a terminating signal to 128+n, because `$? >> 8` is 0 for a killed child,
# i.e. a hang would otherwise read as a PASS.
run_node_capped() {
  local secs="$1"; shift
  perl -e '
    use POSIX ();
    my $t = shift @ARGV;
    my $p = fork; if (!$p) { POSIX::setpgid(0, 0); exec("node", @ARGV); exit 127 }
    POSIX::setpgid($p, $p);
    $SIG{ALRM} = sub { kill(-9, $p) or kill(9, $p); exit 124 };
    alarm $t; waitpid($p, 0); my $st = $?;
    exit($st & 127 ? 128 + ($st & 127) : $st >> 8)
  ' "$secs" "$@"
}
bad()  { echo "FAIL: $*"; fail=1; }

# Cases 1-3 run from FILES, not from `node -e "..."`. A double-quoted -e argument is still shell:
# an ordinary backtick in a comment becomes command substitution, and the mangled script can still
# exit 0 -- which is exactly what happened while writing this, printing `ok` for assertions that
# never ran. The module path arrives as argv, so nothing inside these files is interpolated.
cat > "$SANDBOX/case1.mjs" <<'JS'
const { blocks, renderable } = await import(process.argv[2])
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const cases = [
  // The 555-turn bug: the daemon writes a plain user turn as a STRING, not an array of blocks.
  [{ type: 'user', message: { content: 'Read the handoff file at ...' } },
   [{ type: 'text', text: 'Read the handoff file at ...' }], true],
  [{ type: 'user', message: { content: '   ' } }, [], true],
  [{ type: 'assistant', message: { content: [{ type: 'text', text: 'hi' }] } },
   [{ type: 'text', text: 'hi' }], true],
  // content absent -> null -> NOT renderable. Mutating the fallback from null to [] would make this
  // turn render as an empty line in both panes, so the alternative is reachable.
  [{ type: 'assistant', message: {} }, null, false],
  [{ type: 'summary', message: { content: 'x' } }, [{ type: 'text', text: 'x' }], false],
]
let bad = 0
for (const [d, want, wantRenderable] of cases) {
  if (!eq(blocks(d), want)) { console.log('  blocks mismatch for', JSON.stringify(d)); bad++ }
  if (renderable(d) !== wantRenderable) { console.log('  renderable mismatch for', JSON.stringify(d)); bad++ }
}
process.exit(bad ? 1 : 0)
JS

cat > "$SANDBOX/case2.mjs" <<'JS'
const { readRange, CHUNK } = await import(process.argv[2])
const fs = await import('node:fs')
const f = process.argv[3]
const size = fs.statSync(f).size
if (size <= CHUNK) { console.log('  fixture is not larger than one chunk'); process.exit(1) }
const whole = fs.readFileSync(f, 'utf8')

const r = readRange(f, 0, size)
if (r.text.length !== size || r.end !== size) { console.log('  full read short:', r.text.length, 'of', size); process.exit(1) }
if (r.text !== whole) { console.log('  chunked read differs from readFileSync'); process.exit(1) }

// Crosses a chunk boundary MID-FILE, not at EOF. That matters: the full read above sits exactly at
// EOF, where the OS short-reads the last chunk anyway, so it would not notice a want computed as
// buf.length instead of min(buf.length, to - at). This case would.
const part = readRange(f, 10, 10 + CHUNK + 7)
if (part.text !== whole.slice(10, 10 + CHUNK + 7)) { console.log('  bounded read wrong'); process.exit(1) }

if (readRange(f, 5, 5).text !== '') { console.log('  empty range not empty'); process.exit(1) }

// A range past the CURRENT end of the file -- what a caller that stat'd the transcript before
// another process truncated it asks for. This is the only case that reaches the got <= 0 guard;
// without that guard, at never advances and the loop spins forever. The caller caps the clock, so
// a hang fails rather than hanging the runner.
const past = readRange(f, 0, size + 50000)
if (past === null || past.end !== size || past.text.length !== size) {
  console.log('  read past EOF gave end=', past && past.end, 'want', size); process.exit(1)
}

// The whole reason it exists: the transcript belongs to another process and can vanish.
if (readRange(process.argv[4], 0, 10) !== null) { console.log('  missing file did not return null'); process.exit(1) }
process.exit(0)
JS

cat > "$SANDBOX/case3.mjs" <<'JS'
const { clip, hhmm } = await import(process.argv[2])
const t = (cond, why) => { if (!cond) { console.log('  ' + why); process.exit(1) } }
t(clip('abcdefghij', 5).length === 5, 'clip exceeded the column budget')
t(clip('abcdefghij', 5) === 'abcd…', 'clip did not reserve a column for the ellipsis')
// The boundary an earlier version of this test missed entirely: every other case here sits well
// clear of s.length === n, so mutating `s.length > n` to `>=` clipped a string that FITS EXACTLY --
// one character short of the budget, in every fleet pane -- with the suite still green.
t(clip('abcde', 5) === 'abcde', 'a string that fits exactly was clipped')
t(clip('abcdef', 5) === 'abcd…', 'one over the budget was not clipped')
t(clip('  a\n\n  b  ', 40) === 'a b', 'whitespace not collapsed')
t(clip(null, 10) === '', 'null not coerced to empty')
t(hhmm('2026-09-01T23:52:05.000Z') === '23:52:05', 'hhmm wrong')
t(hhmm('not a date') === '--:--:--', 'hhmm fallback wrong')
process.exit(0)
JS

COMMON="$BIN/fleet-common.mjs"

echo "case 1: blocks() normalises all three content shapes"
run_node_capped 20 "$SANDBOX/case1.mjs" "$COMMON" \
  && ok "string / empty-string / array / absent content, and renderable's type filter" \
  || bad "blocks() or renderable() disagreed with the pinned shapes"

echo "case 2: readRange crosses the 64K chunk boundary, stops at the caller's end, and survives EOF"
python3 -c "
import sys
open(sys.argv[1],'w').write(''.join(chr(97 + i % 26) for i in range(200000)))
" "$SANDBOX/big.txt"
run_node_capped 20 "$SANDBOX/case2.mjs" "$COMMON" "$SANDBOX/big.txt" "$SANDBOX/does-not-exist"
rc=$?
if [ "$rc" -eq 0 ]; then ok "multi-chunk, bounded, empty, past-EOF and vanished-file reads"
elif [ "$rc" -ge 124 ]; then
  # 124 = the alarm fired; >=128 = a terminating signal, which is what actually happens in practice:
  # measured 2026-09-01, deleting the guard aborts node with SIGABRT (134) as the parts array eats
  # the heap before the clock runs out. Both are "it never advanced", and both only surface because
  # run_node_capped maps a signal to 128+n instead of `$? >> 8`, which is 0 -- a green -- for a
  # killed child.
  bad "readRange never advanced (exit $rc) -- the got<=0 guard is gone"
else bad "readRange misread a range (exit $rc)"; fi

echo "case 3: clip keeps the ellipsis INSIDE the column budget, at the boundary too"
run_node_capped 20 "$SANDBOX/case3.mjs" "$COMMON" \
  && ok "budget, exact-fit boundary, whitespace collapse, null, and hhmm's fallback" \
  || bad "clip or hhmm drifted"

echo "case 4: the shared implementations exist in exactly ONE place"
# This is the drift guard, and the first version of it was a MENTION check, not a property check:
# `grep -qE "^(export )?(const|function) $n"` is anchored to column 0 and matches only a top-level
# single-declarator redefinition. It passed on an INDENTED redefinition inside a function, on a
# destructuring shadow (`const { blocks } = ...`), and -- worst -- on the actual failure mode the
# guard exists for: a RENAMED reimplementation (`function getBlocks(d) {...}` used instead of the
# import), which reintroduces exactly the "two panes silently disagree about which turns exist"
# divergence while leaving the imported name untouched.
#
# So assert on the IMPLEMENTATION, not the name. Each fragment below is a distinctive line from one
# shared helper's body; each must occur exactly once across bin/*.mjs, and that once must be
# fleet-common.mjs. A copy under any name, at any indentation, in either viewer, fails this.
FRAGMENTS_FILE="$SANDBOX/fragments"
cat > "$FRAGMENTS_FILE" <<'FRAGS'
fs.readSync(fd, buf, 0, want, at)
.toISOString().slice(11, 19)
d.message?.content
d.type === 'assistant' || d.type === 'user'
.replace(/\s+/g, ' ').trim()
FRAGS
while IFS= read -r frag; do
  [ -n "$frag" ] || continue
  hits=$(cd "$BIN" && grep -lF "$frag" ./*.mjs 2>/dev/null | sed 's|^\./||' | sort | tr '\n' ' ' | sed 's/ *$//')
  n=$(printf '%s\n' $hits | grep -c . )
  if [ "$n" -eq 1 ] && [ "$hits" = "fleet-common.mjs" ]; then
    ok "only fleet-common.mjs implements: $frag"
  else
    bad "shared implementation duplicated or moved -- \`$frag\` lives in: ${hits:-<nowhere>}"
  fi
done < "$FRAGMENTS_FILE"

# ...and both viewers must actually go THROUGH the import, not merely contain it.
for v in fleet-tail.mjs fleet-watch.mjs; do
  grep -q "from './fleet-common.mjs'" "$BIN/$v" || bad "$v does not import the shared module"
  for n in readRange clip hhmm blocks renderable; do
    # 1 = the import line only. A name imported and never used is a viewer that has quietly stopped
    # routing through the shared code, which is the same divergence arriving by the other door.
    uses=$(grep -c "\b$n\b" "$BIN/$v")
    [ "$uses" -ge 2 ] || bad "$v imports $n but never uses it ($uses occurrence(s))"
  done
done
[ "$fail" -eq 0 ] && ok "both viewers import and use all five; neither carries a copy"

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


echo "case 6: the dependency list is DERIVED, so a new import is checked with no edit to fleet"
# The point of the derivation is that nobody has to remember to update a list -- the old hand-written
# one had already gone stale on fleet-flags.mjs, so a partial install printed three cheerful ok lines
# and then died on a missing import. Prove it derives rather than merely agrees today: add a
# dependency the list has never heard of, in the OTHER quote style and via ../, and require doctor to
# report it MISSING without fleet being touched.
cp "$BIN/fleet-common.mjs" "$SANDBOX/home/.claude/bin/fleet-common.mjs"
printf '\nimport { nothing } from "../invented-dep.mjs"\n' >> "$SANDBOX/home/.claude/bin/fleet-tail.mjs"
HOME="$SANDBOX/home" "$SANDBOX/home/.claude/bin/fleet" doctor >"$SANDBOX/doctor.derived" 2>&1
grep -q 'invented-dep.mjs : \*\*\* MISSING \*\*\*' "$SANDBOX/doctor.derived" \
  && ok "an import fleet has never heard of is derived and reported MISSING" \
  || { bad "doctor ignored a new import -- the list is not really derived"; sed -n '/fleet-\|invented/p' "$SANDBOX/doctor.derived"; }

[ "$fail" -eq 0 ] && echo "PASS: the shared fleet helpers behave, and a partial install cannot read as healthy"
exit "$fail"
