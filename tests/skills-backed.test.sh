#!/usr/bin/env bash
# Every skill this machine offers must be BACKED BY THIS REPO, and every path
# install.sh claims to link must really BE a link.
#
# WHY THIS EXISTS. Two defects of one shape, found together on 2026-09-09:
#
#   1. Three skills (grill-with-docs, grilling, domain-modeling) were vendored
#      straight into ~/.claude/skills as real directories on 2026-09-08. The
#      auto-sync watcher only sees files INSIDE the repo, so they reached no
#      commit, no second machine and no mirror, and nothing noticed for a day.
#   2. hooks/context-mode-cache-heal.mjs -- a path install.sh names as a link
#      target -- was a real COPY in ~/.claude/hooks, three months out of step
#      with the repo. settings.json invokes it through the ~/.claude path, so
#      the copy is what RAN; the repo's version had never once executed here.
#
# Both read green under every check that already existed, because a check that
# reads the AUTHORED file is blind to a transform between authoring and use. So
# this test asserts at the POINT OF USE: it looks at the installed config
# directory, not at the repo's own files.
#
# install.sh now DERIVES its skills from the repo directory instead of naming
# them. Deriving fixes additions and silently breaks subtractions -- a member the
# glob misses leaves no diff line to point at -- so the set is asserted in BOTH
# directions.
#
# bash 3.2 (macOS system bash) -- no mapfile, no associative arrays.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
fail=0

# ---------------------------------------------------------------- predicate --
# phys <path> -> the path with every symlink in its PARENTS resolved, the leaf
# left alone. Both sides of the comparison go through this: on macOS $TMPDIR is
# itself a symlink (/var -> /private/var), so comparing a resolved target against
# an unresolved expectation reports every correct link as wrong.
phys() { printf '%s/%s\n' "$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" "$(basename "$1")"; }

# classify <repo> <configdir> <relpath> -> ok | missing | copy | wrong-target
# The whole guard reduces to this function, so the fixture below can drive it.
classify() {
  local repo=$1 cfg=$2 rel=$3 p="$2/$3" tgt
  [ -e "$p" ] || [ -L "$p" ] || { echo missing; return; }
  [ -L "$p" ] || { echo copy; return; }        # a real file/dir shadowing the repo
  tgt="$(cd "$(dirname "$p")" 2>/dev/null && phys "$(readlink "$p")")"
  [ "$tgt" = "$(phys "$repo/$rel")" ] && echo ok || echo wrong-target
}

# disposition <verdict> -> ok | fail. Section 2 routes EVERY verdict through
# this, so no verdict can quietly have no consequence. `missing` used to be
# excused here on the grounds that settings.linux.json names cluster-only hooks
# -- but no ITEM is cluster-only, and measured 2026-09-09 all 16 of them are live
# links on this machine, so the excuse covered nothing and blinded the guard to
# its most likely failure: a path the installer claims to link that simply is not
# linked. Proven by control: deleting output-styles/tolerable.md's link left this
# test green. If a genuinely machine-specific ITEM ever appears, name it here --
# do not restore a blanket excuse.
disposition() {
  case "$1" in
    ok) echo ok ;;
    *)  echo fail ;;
  esac
}

# ------------------------------------------------- control: prove it can do --
# A guard is only worth the alternatives its fixture makes reachable, so each
# verdict is forced on a throwaway tree. A predicate that can only fail gets
# widened by hand until it passes; one that can only pass catches nothing.
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/repo/skills/good" "$t/repo/skills/astray" "$t/repo/elsewhere" "$t/cfg/skills"
ln -s "$t/repo/skills/good" "$t/cfg/skills/good"         # a correct link
mkdir -p "$t/cfg/skills/shadowed"                        # a copy, not a link
mkdir -p "$t/repo/skills/shadowed"
ln -s "$t/repo/elsewhere"   "$t/cfg/skills/astray"       # a link, wrong target
for probe in "good ok" "shadowed copy" "astray wrong-target" "absent missing"; do
  set -- $probe
  got="$(classify "$t/repo" "$t/cfg" "skills/$1")"
  [ "$got" = "$2" ] || { echo "FAIL[control]: classify skills/$1 -> '$got', expected '$2'"; fail=1; }
done

# ...and every verdict's CONSEQUENCE is pinned too, so a verdict cannot be added
# (or excused) without a line here saying what it does.
for probe in "ok ok" "missing fail" "copy fail" "wrong-target fail"; do
  set -- $probe
  got="$(disposition "$1")"
  [ "$got" = "$2" ] || { echo "FAIL[control]: disposition $1 -> '$got', expected '$2'"; fail=1; }
done

# ------------------------------------------- 1. derived set, both directions --
# Read ITEMS out of install.sh itself rather than re-deriving it here: a test
# that reimplements the logic it checks agrees with itself, not with the
# installer. (`--source-only` returns before anything is installed.)
items=()
while IFS= read -r line; do [ -n "$line" ] && items+=("$line"); done < <(
  bash -c "source '$REPO/install.sh' --source-only >/dev/null 2>&1; printf '%s\n' \"\${ITEMS[@]}\""
)
[ "${#items[@]}" -gt 0 ] || { echo "FAIL: could not read ITEMS out of install.sh"; fail=1; }

declared=""; ondisk=""
for it in ${items[@]+"${items[@]}"}; do
  case "$it" in skills/*) declared="$declared${it#skills/}"$'\n';; esac
done
for d in "$REPO"/skills/*/; do
  [ -d "$d" ] && ondisk="$ondisk$(basename "$d")"$'\n'
done
declared="$(printf '%s' "$declared" | sort)"
ondisk="$(printf '%s' "$ondisk" | sort)"

[ -n "$ondisk" ] || { echo "FAIL: repo has no skills/ directories -- refusing to pass over an empty set"; fail=1; }

if [ "$declared" != "$ondisk" ]; then
  echo "FAIL: the set install.sh would link != the repo's skills/ directory."
  comm -3 <(printf '%s\n' "$declared") <(printf '%s\n' "$ondisk") \
    | sed $'s/^\t/  on disk but the installer would NOT link it: /; s/^\\([^ ]\\)/  named by the installer but absent from disk: \\1/'
  fail=1
fi

# --------------------------------- 2. installed paths are links, not copies --
# Skipped unless THIS checkout is the installed one: in a worktree or on another
# machine ~/.claude belongs to a different checkout (or to nothing), and
# asserting against it would measure that other tree.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ "$(classify "$REPO" "$CFG" CLAUDE.md)" = ok ]; then
  for rel in ${items[@]+"${items[@]}"}; do
    v="$(classify "$REPO" "$CFG" "$rel")"
    if [ "$(disposition "$v")" != ok ]; then
      case "$v" in
        missing)      echo "FAIL: $CFG/$rel is not linked at all -- install.sh claims to link it, so the config names something that is not there" ;;
        copy)         echo "FAIL: $CFG/$rel is a real file/dir, not a link into the repo -- edits there reach no commit, and it is the copy that actually RUNS" ;;
        wrong-target) echo "FAIL: $CFG/$rel is a symlink pointing outside this repo" ;;
        *)            echo "FAIL: $CFG/$rel classified '$v', which has no stated disposition" ;;
      esac
      fail=1
    fi
  done

  # 3. Nothing may sit in the config dir's skills/ without a home in the repo.
  #    This is the direction that catches a skill dropped in by hand -- the
  #    2026-09-08 defect.
  for d in "$CFG"/skills/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    if [ ! -L "${d%/}" ]; then
      echo "FAIL: $CFG/skills/$n is a real directory -- it is in no commit and exists only on this machine"; fail=1
    elif [ ! -d "$REPO/skills/$n" ]; then
      echo "FAIL: $CFG/skills/$n is a link to something that is not $REPO/skills/$n"; fail=1
    fi
  done
else
  echo "SKIP: $CFG is not installed from this checkout -- ran the control and set checks only"
fi

[ "$fail" -eq 0 ] && echo "PASS: skills-backed"
exit "$fail"
