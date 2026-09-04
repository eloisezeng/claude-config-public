#!/usr/bin/env bash
# Class guard: no tracked file is recorded EXECUTABLE unless it starts with a shebang.
#
# WHY THIS EXISTS. Until 2026-09-04 the exec bit was invisible here. `tests/run-all.sh` invokes
# every suite as `bash "$s"`, so a script with the bit and a script without it behave identically,
# and nothing in this repo ever noticed which files carried it. That changed when
# `bin/sanitize-to-public.py` started copying git's RECORDED mode to the public mirror
# (see `tracked_modes()` there): the bit is now a published fact. It was added because the
# opposite defect had shipped -- every script in the mirror's `bin/` was published 100644, so a
# clone of the public repo could not run any of them, and a test invoking one directly exited 126
# there while passing here.
#
# Copying the mode faithfully then surfaced the mode that was wrong. Measured 2026-09-04 over
# 50 tracked files recorded `100755`: exactly one was not a program --
# `skills/email-drafter/SKILL.md`, a Markdown document. Nothing ever execs a document, so the
# bit meant nothing here; at the mirror it published a doc as a program. Fixed with
# `git update-index --chmod=-x`, and this guard is what keeps the class at zero.
#
# THE BOUND, stated beside the assertion. This checks ONE direction: bit implies shebang. The
# converse is deliberately NOT asserted. Measured in the same sweep, 22 tracked files start with
# a shebang and are recorded `100644` (`tests/handoff.test.sh`, `skills/codex-converge/mutate.py`,
# `sync.ps1`, ...). Every one of them is invoked through an interpreter by its callers, so the
# missing bit costs nothing, and demanding it would be a 22-file churn that buys no behaviour.
# A guard that asserts the direction with a consequence is worth more than one that asserts
# tidiness in both.
#
# Git's mode, not the filesystem's. `git ls-files -s` reports what the COMMIT records, which is
# what the sanitizer reads and what a fresh clone gets. A working copy's permissions depend on
# the umask that happened to be in force when the file was written, so checking `[ -x ]` would
# assert about this machine rather than about the artifact. Measured here 2026-09-04: index and
# disk agree on all 300 tracked entries -- which is exactly why reading the wrong one would have
# looked correct.
# MUTATION-VERIFIED 2026-09-04 on a COPY (tracked hash asserted unchanged): 6 mutants, 4 killed.
# The two survivors are recorded rather than chased, because neither is observable from a tree
# that does not already hold the defect -- weakening a test to kill them would be the mistake.
# [[a-surviving-mutant-may-mean-the-property-is-unobservable]]
#   * `hits=""` -- the real-tree read forced empty. Every "this tree is clean" guard has this
#     line, and the only witness would be a repo that already carries an offender.
#   * the witness pinned by content but not by MODE. Nothing here chmods a tracked file, and
#     making it observable would mean arming exactly the fault the copy exists to avoid.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0

TMPROOT="$(mktemp -d)" || { printf '%s: cannot create a temp directory\n' "$0" >&2; exit 1; }
[ -n "$TMPROOT" ] || { printf '%s: mktemp -d produced no directory\n' "$0" >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

echo "exec-bit-matches-shebang"

# scan: tree -> one path per line, for every tracked 100755 entry whose body does not begin `#!`.
# Reads the mode from the index and the first two bytes from the file, so a tree with no worktree
# content would report every executable -- which is why the control below builds a real checkout
# rather than a bare repo.
scan() { # tree -> offending paths
  ( cd "$1" && git ls-files -s | awk '$1=="100755" {print $4}' | while IFS= read -r f; do
      [ -f "$f" ] || { printf '%s\n' "$f"; continue; }
      case "$(head -c 2 "$f" 2>/dev/null)" in '#!') ;; *) printf '%s\n' "$f";; esac
    done )
}

n_exec() { ( cd "$1" && git ls-files -s | awk '$1=="100755"' | grep -c . ); }

# --- the guard ---------------------------------------------------------------------------------
hits="$(scan "$REPO")"
if [ -z "$hits" ]; then
  printf '  PASS  every tracked executable starts with a shebang\n'; pass=$((pass+1))
else
  printf '  FAIL  tracked as executable but not a program:\n'
  printf '%s\n' "$hits" | sed 's/^/          /'
  printf '        The mirror publishes this mode. Drop the bit with:\n'
  printf '          git update-index --chmod=-x <path>\n'
  fail=$((fail+1))
fi

# --- satisfiability: the guard must be checking a NON-EMPTY set -------------------------------
# `set(offenders) == {}` is trivially true over an empty subject, so a repo that recorded no
# executable at all would read green while the rule tested nothing.
# [[a-guard-must-be-satisfiable-not-just-failable]]
EXEC_FLOOR=20
enough() { [ "$(n_exec "$1")" -ge "$EXEC_FLOOR" ]; }

n="$(n_exec "$REPO")"
if enough "$REPO"; then
  printf '  PASS  ...over a real subject: %s tracked entries are recorded 100755\n' "$n"; pass=$((pass+1))
else
  printf '  FAIL  only %s tracked entries are executable -- too few for this guard to mean anything\n' "$n"
  fail=$((fail+1))
fi

# --- the converse, MEASURED rather than asserted -----------------------------------------------
# Printed, never failed on. It is the number the bound above quotes, and printing it is what stops
# that paragraph from rotting into a stale comment: if this count moves, the reason the converse
# is out of scope should be re-read rather than assumed.
#
# Written as a FUNCTION, not inlined into the assignment below. macOS ships bash 3.2, which
# re-parses the body of a `$(...)` and cannot read a `case` whose pattern is the quoted `'#!'`
# in that position: it printed `syntax error near unexpected token 'newline'` to stderr and then
# substituted the tail of its own source as the count, so the line read
# `note  printf 'x\n';; esac ... tracked files ...` while the suite still exited 0.
# A reporter that mangles its own number and stays green is the shape this repo keeps finding.
# [[a-tail-window-is-not-a-failure-report]]
n_shebang_nonexec() { # tree -> count of tracked 100644 entries beginning with a shebang
  ( cd "$1" && git ls-files -s | awk '$1=="100644" {print $4}' | while IFS= read -r f; do
      [ -f "$f" ] || continue
      case "$(head -c 2 "$f" 2>/dev/null)" in '#!') printf 'x\n';; esac
    done | grep -c . )
}
n_shebang_644="$(n_shebang_nonexec "$REPO")"
printf '  note  %s tracked files start with a shebang and are NOT executable -- out of scope, see the header\n' \
  "$n_shebang_644"

# --- positive control: the guard must FAIL on a planted offender -------------------------------
# Planted into a COPY. This repo has an auto-sync watcher that commits main, so arming the fault
# in the tracked tree would COMMIT it. [[never-arm-a-fault-in-an-auto-syncing-tree]]
COPY="$TMPROOT/copy"
git -C "$REPO" ls-files -z | (cd "$REPO" && xargs -0 tar cf -) | (mkdir -p "$COPY" && tar xf - -C "$COPY")
( cd "$COPY" && git init -q . && git add -A ) >/dev/null 2>&1

# The witness is the file this guard's own fix touched, pinned by CONTENT and by the MODE the
# index records -- the two things a plant could move. Not `git status --porcelain`: this repo has
# an auto-sync watcher that commits `main` within seconds of a write, so a fault armed in the
# tracked tree would be COMMITTED and `status` would read clean over it. A status check here is
# fail-open by construction, and it also reports every path as added in a fresh uncommitted copy,
# which quietly reddens the baseline any mutation battery has to run against.
witness="skills/email-drafter/SKILL.md"
tracked_state() { # -> "<blob> <index mode>" for the witness, in $REPO
  printf '%s %s\n' \
    "$(git -C "$REPO" hash-object "$witness" 2>/dev/null)" \
    "$(git -C "$REPO" ls-files -s -- "$witness" 2>/dev/null | awk '{print $1}')"
}
before_state="$(tracked_state)"
before="$(scan "$COPY" | grep -c .)"
if [ "$before" -eq 0 ]; then
  printf '  PASS  the copy starts clean, so a plant below is the only cause of a hit\n'; pass=$((pass+1))
else
  printf '  FAIL  the copy is already dirty (%s hits) -- no plant can be attributed\n' "$before"; fail=$((fail+1))
fi

plant() { # name  first-line  chmod-arg  expect-caught(yes|no)
  local name="$1" first="$2" mode="$3" want="$4" p="planted-fixture" caught
  printf '%s\nbody\n' "$first" > "$COPY/$p"
  chmod "$mode" "$COPY/$p"
  ( cd "$COPY" && git add -A ) >/dev/null 2>&1
  if scan "$COPY" | grep -qxF "$p"; then caught=yes; else caught=no; fi
  rm -f "$COPY/$p"; ( cd "$COPY" && git add -A ) >/dev/null 2>&1
  if [ "$caught" = "$want" ]; then
    printf '  PASS  %s\n' "$name"; pass=$((pass+1))
  else
    printf '  FAIL  %s (caught=%s, expected %s)\n' "$name" "$caught" "$want"; fail=$((fail+1))
  fi
}

# The offender this guard exists for: the bit on something that is not a program.
plant 'an executable file with NO shebang is caught'        '# A document'      755 yes
# A PARTIALLY-broken sibling: the bit is right, the body is a program. A guard that merely
# noticed "this file is executable" would flag this too, and would then have to be widened by
# hand until it caught nothing. [[a-mention-is-not-a-property]]
plant '...but an executable file WITH one is not'           '#!/bin/sh'         755 no
# The same non-program without the bit: nothing to publish, nothing to say.
plant '...and a non-executable file with no shebang is not' '# A document'      644 no
# The converse, pinned as an OUTCOME so the out-of-scope decision above is executable rather than
# merely written down: a shebang with no bit is deliberately green.
plant '...nor is a shebang recorded non-executable'         '#!/bin/sh'         644 no

# --- the satisfiability check needs its own control --------------------------------------------
# `enough` is a FLOOR, and lowering a floor only ever admits -- so no scan of a healthy tree can
# see it move. Mutating `-ge 20` to `-ge 0` survived every other case in this file, which is the
# same shape as an allowlist ceiling raised by one. The kill is a tree where the answer must be
# NO: strip every exec bit from the copy's index and require `enough` to refuse there. With the
# floor at 0 that refusal never comes, and the mutant reddens.
STRIPPED="$TMPROOT/stripped"
git -C "$REPO" ls-files -z | (cd "$REPO" && xargs -0 tar cf -) | (mkdir -p "$STRIPPED" && tar xf - -C "$STRIPPED")
# Strip the bit from FILES only. A `chmod -R a-x` would take it off the directories too, and a
# directory with no execute bit cannot be traversed -- `find` then fails to descend, git cannot
# read the tree, and even `rm -rf` on the temp dir is refused. Measured here: that spelling made
# every count read EMPTY, so this control failed on the real repo and then "killed" all five
# mutants for a reason that had nothing to do with any of them. A broken control that reddens is
# still a broken control. [[a-control-must-match-the-probes-shape]]
( cd "$STRIPPED" && git init -q . && find . -type f -exec chmod a-x {} + && git add -A ) >/dev/null 2>&1
if [ "$(n_exec "$STRIPPED")" -eq 0 ] && ! enough "$STRIPPED"; then
  printf '  PASS  ...and that check REFUSES a tree with no executables at all\n'; pass=$((pass+1))
else
  printf '  FAIL  a tree with %s executables still satisfied the floor of %s -- the check is vacuous\n' \
    "$(n_exec "$STRIPPED")" "$EXEC_FLOOR"
  fail=$((fail+1))
fi

# --- the INDEX, not the disk -------------------------------------------------------------------
# The header claims this guard reads git's recorded mode rather than the filesystem's, and in this
# repo the two agree on every tracked entry -- so no fixture built from real files could tell the
# two implementations apart, and a mutant swapping `git ls-files -s` for `[ -x ]` would survive
# every case above. That is the property being unobservable, not the guard being weak, and the
# remedy is to MAKE it observable rather than to soften the claim.
# [[a-surviving-mutant-may-mean-the-property-is-unobservable]]
#
# So: stage a non-program at 100644, then set the bit on DISK ONLY, leaving the index alone. Git
# says "not executable", the filesystem says "executable", and the two implementations disagree
# out loud. This is the only case in the file where the copy is deliberately left inconsistent.
divergent="divergent-fixture"
printf '# A document\nbody\n' > "$COPY/$divergent"
chmod 644 "$COPY/$divergent"
( cd "$COPY" && git add -A ) >/dev/null 2>&1
chmod +x "$COPY/$divergent"            # disk only -- NOT re-added, so the index still says 100644
idx_mode="$( cd "$COPY" && git ls-files -s -- "$divergent" | awk '{print $1}' )"
if [ "$idx_mode" = "100644" ] && [ -x "$COPY/$divergent" ]; then
  if scan "$COPY" | grep -qxF "$divergent"; then
    printf '  FAIL  the guard read the DISK bit, not the mode git records\n'; fail=$((fail+1))
  else
    printf '  PASS  a file +x on disk but 100644 in the index is NOT flagged -- git is the source\n'
    pass=$((pass+1))
  fi
else
  printf '  FAIL  could not build the divergent fixture (index=%s, disk-x=%s) -- the case is inert\n' \
    "$idx_mode" "$([ -x "$COPY/$divergent" ] && echo yes || echo no)"
  fail=$((fail+1))
fi
rm -f "$COPY/$divergent"; ( cd "$COPY" && git add -A ) >/dev/null 2>&1

after_state="$(tracked_state)"
if [ "$after_state" = "$before_state" ]; then
  printf '  PASS  %s is unchanged in content and mode (%s)\n' "$witness" "$after_state"; pass=$((pass+1))
else
  printf '  FAIL  %s moved from [%s] to [%s] -- a fault was armed in the real tree\n' \
    "$witness" "$before_state" "$after_state"; fail=$((fail+1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
