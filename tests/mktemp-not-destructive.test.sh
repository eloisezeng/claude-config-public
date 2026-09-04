#!/usr/bin/env bash
# Class guard: no tracked script may canonicalise an UNCHECKED `mktemp -d`.
#
# WHY THIS EXISTS. `TMPROOT="$(cd "$(mktemp -d)" && pwd -P)"` reads as defensive — it resolves the
# path so later comparisons are physical — but it swallows the one failure that matters. When
# mktemp fails it prints nothing, and bash treats `cd ""` as a SUCCESSFUL no-op, so the variable
# becomes the CURRENT directory. The next line is almost always `trap 'rm -rf "$TMPROOT"' EXIT`,
# and the script deletes the checkout it is running in, uncommitted work included.
#
# THE TWO SHAPES, both measured here on 2026-09-03 across 40 `mktemp -d` sites in 28 tracked files:
#
#   DESTRUCTIVE (2 sites, both fixed): `$(cd "$(mktemp -d)" && pwd -P)` — resolves to the cwd.
#   INERT (38 sites): a bare `X="$(mktemp -d)"` — the variable is EMPTY, `rm -rf ""` is a no-op,
#     and the script then fails loudly on paths like `/copy`. Wrong, but it destroys nothing and
#     announces itself, so it is out of this guard's scope rather than silently covered by it.
#
# THE PATTERN IS A SHAPE, NOT ONE SPELLING. The first version of this guard required `cd` to be
# followed immediately by a double quote, which is one way of writing the bug out of at least
# five. Measured 2026-09-04 with a stubbed failing mktemp, all in the same fixture:
#
#   cd "$(mktemp -d)"      -> the CWD          caught by the original pattern
#   cd -- "$(mktemp -d)"   -> the CWD          MISSED
#   cd  "$(mktemp  -d)"    -> the CWD          MISSED (any extra space inside `mktemp -d`)
#   pushd "$(mktemp -d)"   -> the CWD          MISSED
#   cd $(mktemp -d)        -> $HOME            MISSED, and WORSE than the rest: with no argument
#                                              at all `cd` goes home, so the EXIT trap deletes the
#                                              home directory rather than one checkout
#   cd -P "$(mktemp -d)"   -> refuses          inert; `cd -P ""` errors where plain `cd ""` does not
#
# A guard matching one spelling of a class reads green while four siblings sit in the tree, which
# is `[[a-mention-is-not-a-property]]` in regex form. The pattern below matches the STRUCTURE --
# a chdir builtin whose argument is a command substitution running mktemp -- and every row above
# is executed as a positive control, so the table cannot rot into a comment.
#
# The control below does not merely check that the grep matches: it RUNS the shapes against a
# stubbed failing mktemp and shows where each one lands. A guard whose subject was never
# demonstrated to be dangerous is a style rule wearing a safety rule's clothes.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0

TMPROOT="$(mktemp -d)" || { printf '%s: cannot create a temp directory\n' "$0" >&2; exit 1; }
[ -n "$TMPROOT" ] || { printf '%s: mktemp -d produced no directory\n' "$0" >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

# The pattern is assembled from pieces so this file is not its own first violation — the same
# reason tests/no-hardcoded-project-path.test.sh builds its plant at run time.
#
#   \$\( *(cd|pushd)[[:space:]][^"'$]*"?\$\( *mktemp
#
# reading left to right: a command substitution, a chdir builtin, its options (`-P`, `--`, or
# nothing — anything that is not a quote or another substitution), an OPTIONAL quote so the
# unquoted `cd $(mktemp -d)` is covered too, then a nested substitution running mktemp. `-d` is
# deliberately not required: the flag can be spelled with any spacing, and `cd` into a plain
# `mktemp` file is a bug of the same family.
CD='cd'; PUSHD='pushd'; MK='mktemp'
PAT="\\\$\\( *($CD|$PUSHD)[[:space:]][^\"'\$]*\"?\\\$\\( *$MK"

# THE BOUND, stated beside the assertion: tracked files that are not prose, and lines that are
# not COMMENTS. Documentation quotes the dangerous shape in order to warn about it -- this very
# file does, three lines up -- and a guard that cannot tell a warning from the thing it warns
# about makes writing the warning impossible.
scan() { # tree -> "file:line" per hit
  ( cd "$1" && git ls-files -z \
      | xargs -0 grep -nE "$PAT" /dev/null 2>/dev/null \
      | grep -vE '\.(md|txt)+:[0-9]+:' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
      | cut -d: -f1,2 )
}

echo "mktemp-not-destructive"

hits="$(scan "$REPO")"
if [ -z "$hits" ]; then
  printf '  PASS  no tracked script canonicalises an unchecked mktemp -d\n'; pass=$((pass+1))
else
  printf '  FAIL  the destructive shape is present:\n'
  printf '%s\n' "$hits" | sed 's/^/          /'
  printf '        Assign, CHECK, then cd -- never cd into the substitution.\n'
  fail=$((fail+1))
fi

# --- every row of the table above, EXECUTED ---------------------------------------------------
# Without this the guard asserts a preference; with it, it asserts a measured fact. Each variant
# runs with mktemp stubbed to fail exactly as a full disk would, in a victim directory, under a
# REDIRECTED HOME -- the unquoted row lands in `$HOME`, and pointing that at the real home would
# make the row unassertable (and the demonstration itself a little bit rude).
victim="$TMPROOT/victim"; mkdir -p "$victim"; : > "$victim/PRECIOUS"
VICTIM_P="$(cd "$victim" && pwd -P)"
FAKEHOME="$TMPROOT/fakehome"; mkdir -p "$FAKEHOME"
FAKEHOME_P="$(cd "$FAKEHOME" && pwd -P)"

# Every variant is ASSEMBLED from $CD/$PUSHD/$MK rather than written out, for the same reason
# $PAT is: spelled in full it would be a real occurrence of the shape in a tracked script, and
# this guard caught its own fixture the moment the file was `git add`ed -- the scan list comes
# from `git ls-files`, so an unstaged file is invisible to itself. A guard that cannot express
# its own subject is unwritable.
V1='T="$(%s "$(%s -d)" && pwd -P)"\n'
V2='T="$(%s -- "$(%s -d)" && pwd -P)"\n'
V3='T="$(%s  "$(%s  -d)" && pwd -P)"\n'
V4='T="$(%s "$(%s -d)" >/dev/null && pwd -P)"\n'
V5='T="$(%s $(%s -d) && pwd -P)"\n'
V6='T="$(%s -P "$(%s -d)" && pwd -P)"\n'

plant_line() { # fmt chdir-word -> the one line, on stdout
  # shellcheck disable=SC2059  -- the format IS the datum here
  printf "$1" "$2" "$MK"
}

lands() { # name fmt chdir-word expected
  local name="$1" got
  { printf '#!/usr/bin/env bash\nset -uo pipefail\nmktemp() { return 1; }\n'
    plant_line "$2" "$3"
    printf 'printf "%%s\\n" "$T"\n'
  } > "$TMPROOT/variant.sh"
  got="$( cd "$victim" && HOME="$FAKEHOME_P" bash "$TMPROOT/variant.sh" 2>/dev/null )"
  if [ "$got" = "$4" ]; then
    printf '  PASS  %s lands in %s when mktemp fails\n' "$name" "${4:-nowhere (it refuses)}"; pass=$((pass+1))
  else
    printf '  FAIL  %s landed in %s, expected %s\n' "$name" "${got:-<empty>}" "${4:-<empty>}"; fail=$((fail+1))
  fi
}

lands 'cd "$(mktemp -d)"'    "$V1" "$CD"    "$VICTIM_P"
lands 'cd -- "$(mktemp -d)"' "$V2" "$CD"    "$VICTIM_P"
lands 'cd  "$(mktemp  -d)"'  "$V3" "$CD"    "$VICTIM_P"
lands 'pushd "$(mktemp -d)"' "$V4" "$PUSHD" "$VICTIM_P"
lands 'cd $(mktemp -d)'      "$V5" "$CD"    "$FAKEHOME_P"
# The inert row, pinned as an outcome so the table cannot quietly become wrong: `cd -P ""` errors
# where plain `cd ""` succeeds, so the `&&` short-circuits and T is empty. The guard still MATCHES
# it, deliberately -- it is one deleted flag away from the destructive form, and the remedy the
# guard prints (assign, check, then cd) is the right advice for it either way.
lands 'cd -P "$(mktemp -d)"' "$V6" "$CD"    ""

# The contrast: the idiom every fixed site now uses.
cat > "$TMPROOT/checked.sh" <<'INNER'
#!/usr/bin/env bash
set -uo pipefail
mktemp() { return 1; }
T="$(mktemp -d)" || exit 9
[ -n "$T" ] && [ -d "$T" ] || exit 9
T="$(cd "$T" && pwd -P)"
printf '%s\n' "$T"
INNER
out="$( cd "$victim" && bash "$TMPROOT/checked.sh" )"; rc=$?
if [ "$rc" -eq 9 ] && [ -z "$out" ]; then
  printf '  PASS  ...and the checked idiom refuses instead, printing nothing\n'; pass=$((pass+1))
else
  printf '  FAIL  the checked idiom exited %s printing %s, expected 9 and nothing\n' "$rc" "${out:-<empty>}"; fail=$((fail+1))
fi

# --- positive control: the guard must FAIL on every row, one row at a time --------------------
# Planted into a COPY. This repo has an auto-sync watcher that commits main, so arming the fault
# in the tracked tree would COMMIT it. [[never-arm-a-fault-in-an-auto-syncing-tree]]
#
# ONE variant per plant, restoring the file in between, because a single six-line plant that
# scored 6 hits could not say WHICH row the pattern is blind to -- and a pattern blind to one row
# is exactly the defect this section exists to catch.
COPY="$TMPROOT/copy"
git -C "$REPO" ls-files -z | (cd "$REPO" && xargs -0 tar cf -) | (mkdir -p "$COPY" && tar xf - -C "$COPY")
( cd "$COPY" && git init -q . && git add -A ) >/dev/null 2>&1
before="$(scan "$COPY" | grep -c .)"

target="tests/run-all.sh"
before_hash="$(git -C "$REPO" hash-object "$target")"

control() { # name fmt chdir-word
  local name="$1" after delta
  cp "$REPO/$target" "$COPY/$target"
  plant_line "$2" "$3" >> "$COPY/$target"
  ( cd "$COPY" && git add -A ) >/dev/null 2>&1
  after="$(scan "$COPY")"
  delta=$(( $(printf '%s\n' "$after" | grep -c .) - before ))
  if printf '%s\n' "$after" | grep -qx "$target:[0-9]*" && [ "$delta" -eq 1 ]; then
    printf '  PASS  a planted %s IS caught, and adds exactly one hit\n' "$name"; pass=$((pass+1))
  else
    printf '  FAIL  planting %s changed the hit count by %s and %s\n' \
      "$name" "$delta" "$(printf '%s\n' "$after" | grep -qx "$target:[0-9]*" && echo "was seen" || echo "was NOT seen")"
    fail=$((fail+1))
  fi
}

control 'cd "$(mktemp -d)"'    "$V1" "$CD"
control 'cd -- "$(mktemp -d)"' "$V2" "$CD"
control 'cd  "$(mktemp  -d)"'  "$V3" "$CD"
control 'pushd "$(mktemp -d)"' "$V4" "$PUSHD"
control 'cd $(mktemp -d)'      "$V5" "$CD"
control 'cd -P "$(mktemp -d)"' "$V6" "$CD"

if [ "$(git -C "$REPO" hash-object "$target")" = "$before_hash" ]; then
  printf '  PASS  the tracked %s is byte-identical to before the plants\n' "$target"; pass=$((pass+1))
else
  printf '  FAIL  the tracked %s changed -- a fault was armed in the real tree\n' "$target"; fail=$((fail+1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
