#!/usr/bin/env bash
# `handoff.sh --close ... --note '<text>'` records the note WITHOUT its own flag
# name in it.
#
# `--note` is in the documented usage — the dispatch preamble that tells a seat
# how to close its lane passes it — and the option-parse block had no arm for
# it, so it fell through to the catch-all that collects a bare trailing note.
# The recorded `disposition_note` therefore began with the literal word
# `--note`. Nothing caught it because the note WAS written: a probe asking "did
# the note land?" reads green on the broken version, which is why this test asks
# what the note's first word IS.
#
# The control below is the bare trailing form, which must keep working — the
# catch-all is still there and this fix must not have moved the note to being
# flag-only.
set -u
HS="$(cd "$(dirname "$0")/../hooks" && pwd)/handoff.sh"
[ -x "$HS" ] || { echo "FAIL: $HS is not executable"; exit 1; }

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then printf 'ok  %s\n' "$1"
  else printf 'not ok  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

# A throwaway ops root (the env override is CLAUDE_OPS_DIR), so this never touches the real ledger.
OPS="$(mktemp -d)"; trap 'rm -rf "$OPS"' EXIT
mkdir -p "$OPS/dispatches" "$OPS/lanes"
LANE=probe-note-arm
cat > "$OPS/lanes/$LANE.md" <<'EOF'
---
lane: probe-note-arm
status: open
pointer: this file
---

# A lane that exists only to be closed

done-check: true
EOF
seed() { # the dispatch record --close reads and rewrites, in the real shape:
         # the record lives beside the handoff file as `<file>.dispatch`, and
         # `dispatches/<key>` is a SYMLINK to it. A plain file there is not
         # recognised, and a record with no `cwd` is refused outright, because
         # the done-check has to run in the tree the lane was dispatched in.
  cat > "$OPS/lanes/$LANE.md.dispatch" <<EOF
state=verified
dispatched_at=2026-01-01T00:00:00Z
handoff=$OPS/lanes/$LANE.md
cwd=$OPS
objective=a lane that exists only to be closed
EOF
  rm -f "$OPS/dispatches/$LANE"
  ln -s "$OPS/lanes/$LANE.md.dispatch" "$OPS/dispatches/$LANE"
}
noteOf() { sed -n 's/^disposition_note=//p' "$OPS/lanes/$LANE.md.dispatch" | head -1; }
LESSON='none: this lane is a test fixture and teaches nothing general'

seed
CLAUDE_OPS_DIR="$OPS" "$HS" --close "$LANE" completed --lesson "$LESSON" --note 'the note itself' >/dev/null 2>&1
check '--note <value> records the value and not the flag name' 'the note itself' "$(noteOf)"

seed
CLAUDE_OPS_DIR="$OPS" "$HS" --close "$LANE" completed --lesson "$LESSON" --note='joined form' >/dev/null 2>&1
check '--note=<value> records the value' 'joined form' "$(noteOf)"

seed
CLAUDE_OPS_DIR="$OPS" "$HS" --close "$LANE" completed --lesson "$LESSON" bare trailing note >/dev/null 2>&1
check 'the bare trailing form still works' 'bare trailing note' "$(noteOf)"

if [ "$fails" = 0 ]; then echo "PASS: close-note-flag"; exit 0; fi
echo "FAIL: close-note-flag -- $fails assertion(s)"; exit 1
