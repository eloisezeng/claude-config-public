#!/usr/bin/env bash
# Class guard: no code in this repo may name a concrete personal project directory.
#
# WHY THIS EXISTS. This repo is GLOBAL config — installed on every machine, published to a public
# mirror. Four sites nonetheless hardcoded one sibling checkout: the colour-hook's controls
# asserted against that project's live file layout, `fleet` and `fleet-open.sh` launched the
# fleet's only write surface from it, and `sync-to-public.sh` excluded a mirror clone by a path
# the caller had already passed in. Each was written separately, so fixing the four instances
# fixes nothing — the class needs a guard. `[[fix-the-class-not-the-reported-instance]]`
#
# THE BOUND, stated beside the assertion: this scans every TRACKED file except prose (.md, .txt).
# It used to scan only bin/ hooks/ tests/ scripts/ and to skip .json wholesale, which left the
# repo's most load-bearing execution surfaces invisible: `install.sh`, `sync.sh`, `sync.ps1` and
# `inject-*.sh` sit at the root, and settings.json / settings.linux.json / settings.windows.json
# are nothing BUT hook command lines. A project path planted in any of those runs on every
# machine this config installs to, and the narrow scan reported clean. Measured after widening:
# two files needed an allowlist entry, and both state why below.
#
# Documentation and memories are still out of scope. They cite where a lesson was MEASURED, which
# is the provenance `[[verify-claims-against-artifacts]]` asks for, and the publish-time sanitizer
# rewrites the name. Code is different: it RUNS.
#
# WHAT IT CANNOT SEE: a path assembled at runtime from pieces; a project directory that happens to
# sit directly in $HOME rather than inside a workspace root; and a hardcoded reference to THIS
# repo's own install location, which is_self() exempts. That last exemption is load-bearing and
# not free -- measured 2026-09-03, 15 tracked files name `~/dotfiles/claude` -- so a hardcoded
# install path is a portability defect this guard deliberately does not cover, distinct from the
# personal-project coupling it does.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0

TMPROOT="$(mktemp -d)" || { printf '%s: cannot create a temp directory\n' "$0" >&2; exit 1; }
[ -n "$TMPROOT" ] || { printf '%s: mktemp -d produced no directory\n' "$0" >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

# The repo's own install location is derived LIVE, never listed: `--git-common-dir` points at the
# main checkout even when this runs from a linked worktree. A guard that named its own path would
# be the same defect it exists to catch.
#
# Overridable by env for ONE reason: a mutation battery has to run this file against a COPY of the
# tree (this repo auto-commits, so a fault may never be armed in it --
# `[[never-arm-a-fault-in-an-auto-syncing-tree]]`), and a copy sits at a different path.
# `scan()` below is already parameterised by TREE and SELF for exactly this; without the same seam
# here the battery's baseline is contaminated and every mutant reads SURVIVED.
# `[[a-control-must-match-the-probes-shape]]`
LIVE_SELF="${NHPP_SELF_PATH:-$(cd "$(dirname "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)}"

# SELF is a SET, not one path, and this is the whole reason. This repo has TWO legitimate homes:
# the checkout you are running from, and the canonical install location -- which is load-bearing,
# named by 46 tracked files, and DECLARED BY THE README. Deriving self from the live checkout
# alone was correct only by coincidence: it holds while the two are the same directory, and
# silently stops holding at the public mirror clone, where every one of those 46 references
# becomes a foreign two-segment path and the guard reddens on its own install path. Measured: the
# published copy failed on 15 files the moment it first reached the mirror.
#
# The canonical path is READ FROM THE README rather than written here, because a guard that names
# its own subject is the defect it exists to catch, and because a value spelled in two places
# drifts. If the README stops declaring it, this fails LOUDLY below rather than quietly exempting
# less. `[[an-armed-watcher-holds-its-boot-config]]`
CANON_SELF="$(sed -n 's|^git clone <this-repo> ~/\([A-Za-z0-9._/-]*\).*|'"$HOME"'/\1|p' "$REPO/README.md" | head -1)"
SELF_PATH="$LIVE_SELF${CANON_SELF:+:$CANON_SELF}"

# The ONE hand-maintained part, and every entry states its reason. The friction is the mechanism:
# adding a line here means writing down why, and the assertions below refuse an entry that has
# stopped matching, so a carve-out cannot outlive its subject.
#
#   file <TAB> max_hits <TAB> digest,digest,... <TAB> reason
#
# WHY A COUNT AND A DIGEST, rather than the filename alone. A whole-file excuse is a permanent
# hole: `bin/sanitize-to-public.test.sh` is excused because the project name IS its input, and a
# filename-only allowlist then excuses a SECOND, unrelated private path added to that file next
# month -- the guard reads green on exactly the file where nobody is looking. The count and the
# digest pin WHICH hits were excused, so any change to that file's token set reddens and has to
# be re-excused deliberately.
#
# Each digest is the first 12 hex of sha1 over ONE token. The tokens cannot be spelled here: this
# file is not itself allowlisted, so a literal private path in it would make the guard its own
# first violation -- the same constraint that makes every plant below assemble its literal at run
# time.
#
# The comparison is a SUBSET, and the count a CEILING: an excused file may hold FEWER of these
# tokens than recorded, never a token that is not among them. That asymmetry is not slack, it is
# what makes the entry correct in both trees -- the public mirror is published through a sanitizer
# that rewrites private names, so an excused file legitimately holds fewer tokens there, and a
# strict equality is UNSATISFIABLE at the mirror. The first version of this file was, and shipped
# red on its first publish. `[[a-guard-must-be-satisfiable-not-just-failable]]`
#
# n_hits counts scanner OUTPUT LINES for that file, not distinct tokens: two different paths on
# one source line are two hits and one line. Stating the rule matters, because the same file
# counted the other way gives a different number and neither reading is wrong.
# `[[surprising-result-check-metric-identity]]`
allow_list() { cat <<'EOF'
bin/sanitize-to-public.test.sh	5	d9993690abb0,e7f40aa0b435,f3ad0efd9b59,ff30a10b8b74	the literal IS the input under test — this file asserts that the sanitizer rewrites a project name on publish, so removing it deletes the coverage
tests/settings-portable-paths.test.sh	5	622719b7a59c,bb0fbb9f471e,d5fc56b69b2d	synthetic homes and the mirror's install path are the inputs under test — this file exists to prove hook commands stay portable across install locations
bin/install-lavish-fork.sh	1	9ddad9dbe005	lavish-axi is a global TOOL, not a project; its fork path is specified in CLAUDE.md and LAVISH_FORK_DIR already overrides it
install.sh	3	18641e1365d1,37be033df8f7,a28d385d10ee	the matches are synthetic fixtures inside install.sh's own self-test -- directories it creates and deletes in a temp home, naming no project on any machine
settings.linux.json	3	2301edea749a,4096b62780f6,622719b7a59c	it names this repo's own install location on Linux, which a settings JSON has nowhere to derive from; tests/settings-portable-paths.test.sh is the file that proves these commands stay portable
EOF
}

# The scanner. Parameterised by TREE and SELF so the positive control below runs this exact code
# against a mutated COPY — a control that tested the pieces separately would be a second
# measurement that happens to be red. `[[a-control-must-match-the-probes-shape]]`
scan() { # tree self-path -> "file:line<TAB>token" per hit, one per line
  TREE="$1" SELF="$2" python3 - <<'PY'
import os, re, subprocess, sys

tree = os.environ["TREE"]
self_paths = [os.path.realpath(p) for p in os.environ["SELF"].split(":") if p]
home = os.path.expanduser("~")

files = [f for f in subprocess.run(["git", "ls-files"], cwd=tree, capture_output=True,
                                   text=True).stdout.split("\n")
         if f and not f.endswith((".md", ".txt"))]

SEG = r"[A-Za-z][A-Za-z0-9._+-]*"
# A concrete path into a user's home with at least two literal segments. `$HOME/x` alone is not
# it — the shape that names a PROJECT is a workspace root plus a project directory.
PAT = re.compile(r"(?:\$HOME|\$\{HOME\}|~|/Users/[^/\s\"'$]+)/(" + SEG + r")/(" + SEG + r")")
# Harness- and OS-owned trees, which are locations rather than projects. `~/.claude/bin` names
# where this config installs itself; `~/Library/Logs` is macOS's.
SKIP = {".claude", ".local", ".config", ".codex", ".cache", ".npm", ".ssh", "Library"}

def is_self(tok):
    p = tok.replace("${HOME}", home).replace("$HOME", home)
    if p.startswith("~"):
        p = home + p[1:]
    p = os.path.realpath(p.rstrip("."))        # prose often ends a path with a full stop
    return any(p == s or s.startswith(p + os.sep) or p.startswith(s + os.sep) for s in self_paths)

for f in files:
    try:
        body = open(os.path.join(tree, f), encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for n, line in enumerate(body.split("\n"), 1):
        for m in PAT.finditer(line):
            if m.group(1) in SKIP or is_self(m.group(0)):
                continue
            print(f"{f}:{n}\t{m.group(0)}")
PY
}

allowed_file() { # path -> 0 if allowlisted
  allow_list | cut -f1 | grep -qxF "$1"
}

# The same summary the allowlist records, derived from a scan. Run over the real tree it says
# whether an excused file still holds exactly the hits it was excused for; run over a mutated
# copy it is what the positive controls below assert has CHANGED.
digests() { # hits-blob -> "file<TAB>n_hits<TAB>d1,d2,..." per file, sorted
  HITS="$1" python3 - <<'PY'
import hashlib, os

# Per-TOKEN digests, not one digest of the set, and the reason is the public mirror. The mirror is
# published through a sanitizer that REWRITES private names, so an excused file legitimately holds
# FEWER tokens there than here -- and a single set-digest can only be compared for equality, which
# is unsatisfiable in the published tree. Measured: the first version of this file shipped RED to
# the mirror on its first publish. Per-token digests make the comparison a SUBSET test, which is
# what the guard actually means: an excused file may lose excused tokens, and may never gain one
# nobody reviewed. `[[a-guard-must-be-satisfiable-not-just-failable]]`
per = {}
for line in os.environ["HITS"].split("\n"):
    if not line.strip():
        continue
    f, tok = line.split(":", 1)[0], line.split("\t", 1)[1]
    per.setdefault(f, []).append(tok)
for f in sorted(per):
    ds = sorted(hashlib.sha1((t + "\n").encode()).hexdigest()[:12] for t in set(per[f]))
    print("%s\t%d\t%s" % (f, len(per[f]), ",".join(ds)))
PY
}

echo "no-hardcoded-project-path"

# --- the guard itself: the real tree must be clean ---------------------------------------------
hits="$(scan "$REPO" "$SELF_PATH")"
unallowed=""
while IFS= read -r h; do
  [ -n "$h" ] || continue
  f="${h%%:*}"
  allowed_file "$f" || unallowed="$unallowed$h"$'\n'
done <<< "$hits"

if [ -z "$(printf '%s' "$unallowed" | tr -d '[:space:]')" ]; then
  printf '  PASS  no unallowlisted project path in tracked code\n'; pass=$((pass+1))
else
  printf '  FAIL  a concrete project path is hardcoded in tracked code:\n'
  printf '%s' "$unallowed" | sed 's/^/          /'
  printf '        Derive it from a live predicate, or add the file to ALLOW with a reason.\n'
  fail=$((fail+1))
fi

# --- every allowlist entry is pinned to the exact hits it excuses ------------------------------
# An entry that has stopped matching is a carve-out outliving its subject -- the shape of
# `[[an-armed-watcher-holds-its-boot-config]]`. An entry that matches MORE than it was written for
# is worse: the file's excuse silently grew to cover a path nobody reviewed. Both are one
# comparison, in both directions. `[[a-guard-must-be-satisfiable-not-just-failable]]`
# It is a FUNCTION so the controls below can assert the guard's own verdict rather than a proxy
# for it. A control that re-implemented this comparison would be a second measurement that happens
# to be red. `[[a-control-must-match-the-probes-shape]]`
stale_entries() { # digests-blob [allowlist-text] -> one complaint per problem, empty when it holds
  # The allowlist is an ARGUMENT, defaulting to the real one, because the mirror-shaped controls
  # below have to drive this with a synthetic entry: at the published mirror the sanitizer has
  # removed the real excused tokens, so a control built from them is inert exactly where it is
  # needed. A synthetic pair means the same thing in both trees.
  local blob="$1" list="${2-}" f n d reason got got_n got_d one out=""
  [ -n "$list" ] || list="$(allow_list)"
  while IFS=$'\t' read -r f n d reason; do
    [ -n "$f" ] || continue
    [ -n "$reason" ] || { out="$out  $f (no reason given)"$'\n'; continue; }
    got="$(printf '%s\n' "$blob" | awk -v f="$f" -F'\t' '$1 == f { print $2 "\t" $3 }')"
    if [ -z "$got" ]; then
      # NOT an error. The sanitizer rewrites private names on publish, so at the mirror an excused
      # file legitimately holds nothing -- the excuse is simply unused there. What would be an
      # error is an excuse that GREW, and that is what the two checks below are.
      continue
    fi
    got_n="${got%%	*}"; got_d="${got#*	}"
    [ "$got_n" -le "$n" ] || out="$out  $f (excused for at most $n hits, scan finds $got_n)"$'\n'
    for one in $(printf '%s' "$got_d" | tr ',' ' '); do
      case ",$d," in
        *",$one,"*) ;;
        *) out="$out  $f (holds a token that was never excused: $one)"$'\n' ;;
      esac
    done
  done <<< "$list"
  printf '%s' "$out"
}

actual="$(digests "$hits")"
stale="$(stale_entries "$actual")"

if [ -z "$(printf '%s' "$stale" | tr -d '[:space:]')" ]; then
  printf '  PASS  every excused file holds only hits it was excused for, and states a reason\n'; pass=$((pass+1))
else
  printf '  FAIL  the allowlist no longer describes the tree:\n%s' "$stale"
  printf '        Re-read the file, then update the count and digest -- do not widen by filename.\n'
  fail=$((fail+1))
fi

# --- the allowlist is pinned, not merely self-consistent ---------------------------------------
# The check above proves each entry still matches something. It cannot notice a FOURTH entry
# appearing: adding a violating file with any nonempty reason turns both checks above green. The
# allowlist is the guard's only hand-maintained part, so widening it is the failure mode, and the
# count is the ratchet that makes widening a deliberate two-place edit rather than a quiet one.
#
# The same argument applies WITHIN a row, and this is why the ratchet counts three things rather
# than one. Because the count is a ceiling and the digests a superset, raising a row's number from
# 3 to 4, or appending one more digest to it, only ever ADMITS -- no scan of the tree can redden
# on a permission nobody exercised yet. Measured: mutants doing exactly that survived the whole
# suite until the budget below was added. A ratchet on the allowlist TEXT sees them, and unlike a
# tree-derived check it means the same thing in the published mirror.
# `[[a-surviving-mutant-may-mean-the-property-is-unobservable]]`
EXPECTED_ALLOW=5        # entries
EXPECTED_HITS=17        # the sum of their ceilings
EXPECTED_TOKENS=14      # the number of distinct token digests they list between them
n_allow="$(allow_list | grep -c .)"
n_hits="$(allow_list | cut -f2 | paste -sd+ - | bc)"
n_tokens="$(allow_list | cut -f3 | tr ',' '\n' | grep -c .)"
if [ "$n_allow" -eq "$EXPECTED_ALLOW" ] && [ "$n_hits" -eq "$EXPECTED_HITS" ] \
   && [ "$n_tokens" -eq "$EXPECTED_TOKENS" ]; then
  printf '  PASS  the allowlist budget is unchanged: %s entries, %s hits, %s tokens\n' \
    "$EXPECTED_ALLOW" "$EXPECTED_HITS" "$EXPECTED_TOKENS"; pass=$((pass+1))
else
  printf '  FAIL  the allowlist budget moved: %s/%s/%s entries/hits/tokens, expected %s/%s/%s\n' \
    "$n_allow" "$n_hits" "$n_tokens" "$EXPECTED_ALLOW" "$EXPECTED_HITS" "$EXPECTED_TOKENS"
  printf '        Widening an excuse is a deliberate two-place edit, in either direction.\n'
  fail=$((fail+1))
fi

# --- the two properties that only the PUBLIC MIRROR can see, made observable here -------------
# Both fixes below were written for a tree this suite never runs in, and in THIS tree both are
# invisible: the live checkout and the canonical install path are the same directory, and no
# sanitizer has removed anything. So a mutant reverting either one survives the whole suite while
# the guard ships RED on its first publish -- which is exactly what happened, measured in the
# published mirror clone: 23 passed, 2 failed, on a file that was green here. (The clone's
# path is not written out even in a comment: this file is not allowlisted, so the guard
# caught this very sentence when it was.)
# `[[a-surviving-mutant-may-mean-the-property-is-unobservable]]`
#
# The remedy is not to trust the mirror run: it is to FORCE the mirror's conditions in-process.
# `[[a-control-must-match-the-probes-shape]]`

if [ -n "$CANON_SELF" ]; then
  printf '  PASS  the README still declares this repo canonical install path, and SELF reads it\n'
  pass=$((pass+1))
else
  printf '  FAIL  README.md no longer declares a `git clone <this-repo> ~/...` path\n'
  printf '        SELF then covers only the live checkout, and the published mirror reddens on\n'
  printf '        every tracked file naming the canonical location.\n'
  fail=$((fail+1))
fi

# The mirror is a SECOND clone: its live checkout is somewhere else entirely, while its tracked
# files still name the canonical one. Forcing a foreign live-self reproduces that exactly.
FOREIGN_SELF="$TMPROOT/elsewhere/claude-config-public"
foreign_only="$(scan "$REPO" "$FOREIGN_SELF" | grep -c .)"
foreign_canon="$(scan "$REPO" "$FOREIGN_SELF${CANON_SELF:+:$CANON_SELF}")"
here="$(scan "$REPO" "$SELF_PATH")"

if [ "$foreign_canon" = "$here" ]; then
  printf '  PASS  a clone at a foreign path sees the SAME hits as this checkout (%s)\n' \
    "$(printf '%s\n' "$here" | grep -c .)"; pass=$((pass+1))
else
  printf '  FAIL  the guard verdict depends on WHERE the repo is checked out -- it will not\n'
  printf '        survive publication. Here: %s hits, at a foreign path: %s.\n' \
    "$(printf '%s\n' "$here" | grep -c .)" "$(printf '%s\n' "$foreign_canon" | grep -c .)"
  fail=$((fail+1))
fi

# ...and the control for that, because "same count" is only meaningful if the canonical exemption
# was doing work. Measured 2026-09-04: 49 hits across 20 files without it, 17 with.
if [ "$foreign_only" -gt "$(printf '%s\n' "$foreign_canon" | grep -c .)" ]; then
  printf '  PASS  ...and dropping the canonical path really does redden it (%s hits)\n' \
    "$foreign_only"; pass=$((pass+1))
else
  printf '  FAIL  dropping the canonical path changed nothing (%s hits) -- this control is inert,\n' \
    "$foreign_only"
  printf '        so the check above proves nothing about the mirror.\n'
  fail=$((fail+1))
fi

# The other half: at the mirror the sanitizer REWRITES private names, so an excused file holds
# fewer tokens there than here. An equality test on the recorded digest is unsatisfiable in that
# tree; a subset test is not. These four cases pin the asymmetry in both directions, feeding
# stale_entries() hits blobs shaped like a published tree rather than waiting for a publish.
#
# They run against a SYNTHETIC allowlist entry, not a real one, and the reason is the same defect
# one level down: the first version of this section duplicated a real excused hit, which at the
# mirror had already been sanitized away -- so the ceiling case had nothing to duplicate and the
# control was inert in the one tree it was written for. Measured: green here, red there.
# A synthetic pair is identical in every tree. `[[a-control-must-match-the-probes-shape]]`
fake_tok="$(printf '$HOME/%s/%s' Coding a-reviewed-project)"
fake_two="$(printf 'fake/f.sh:1\t%s\nfake/f.sh:2\t%s' "$fake_tok" "$fake_tok")"
# The row is DERIVED by running digests() over that blob, so the control cannot drift from the
# hashing rule it is testing -- and the digest need not be spelled here either.
fake_row="$(digests "$fake_two" | sed 's/$/\tsynthetic, for the controls below/')"

case_is() { # name  hits-blob  expected-substring-or-empty
  local got; got="$(stale_entries "$(digests "$2")" "$fake_row")"
  if [ -z "$3" ]; then
    if [ -z "$(printf '%s' "$got" | tr -d '[:space:]')" ]; then
      printf '  PASS  %s\n' "$1"; pass=$((pass+1))
    else
      printf '  FAIL  %s -- got:\n%s' "$1" "$got"; fail=$((fail+1))
    fi
  elif printf '%s' "$got" | grep -q "$3"; then
    printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else
    printf '  FAIL  %s -- got: %s\n' "$1" "${got:-<nothing>}"; fail=$((fail+1))
  fi
}

case_is "an excused file that lost every token to the sanitizer is still green" "" ""
case_is "...and one that kept only some of them is green too" \
  "$(printf 'fake/f.sh:1\t%s' "$fake_tok")" ""
case_is "...but one MORE hit than it was excused for trips the ceiling" \
  "$(printf '%s\nfake/f.sh:3\t%s' "$fake_two" "$fake_tok")" "excused for at most"
case_is "...and a token nobody reviewed reddens it, subset test or not" \
  "$(printf '%s\nfake/f.sh:4\t$HOME/%s/%s' "$fake_two" Coding an-unreviewed-project)" "never excused"

# --- positive controls: the guard must be able to FAIL, on every surface it claims -------------
# Planted into a COPY. This repo has an auto-sync watcher that commits main, so arming a fault in
# the tracked tree would COMMIT it. `[[never-arm-a-fault-in-an-auto-syncing-tree]]`
#
# Every planted literal is ASSEMBLED at run time and never spelled in this file, because a guard
# whose own source contains the string it hunts is its own first violation -- and allowlisting the
# guard would be the widest carve-out in the file. That the scan cannot see a path built from
# pieces is the bound stated at the top, not a loophole exploited here.
COPY="$TMPROOT/copy"
git -C "$REPO" ls-files -z | (cd "$REPO" && xargs -0 tar cf -) | (mkdir -p "$COPY" && tar xf - -C "$COPY")
( cd "$COPY" && git init -q . && git add -A ) >/dev/null 2>&1
running="$(scan "$COPY" "$SELF_PATH" | grep -c .)"

# One plant per SURFACE the widened scan claims, because "the scanner reads bin/" and "the scanner
# reads the root executables and the settings JSON" are different claims and the narrow version of
# this file passed the first while failing the second in silence.
#
#   bin/fleet             a bin/ script -- the original coupling's own home
#   sync.sh               a ROOT executable, invisible to the old bin|hooks|tests|scripts prefix
#   settings.json         a command-bearing JSON, invisible to the old .json exclusion
#   bin/sync-to-public.sh the exact BASE regression, planted with the shape it actually had: a
#                         hardcoded MIRROR CLONE path. is_self() exempts this repo's own install
#                         location, so on a machine where the checkout IS the mirror clone that
#                         site would go unseen -- this control pins the site regardless of where
#                         the repo is installed, using a name that is nobody's install path.
plant() { # file workspace project label
  local file="$1" ws="$2" proj="$3" label="$4" before_hash after n
  before_hash="$(git -C "$REPO" hash-object "$file")"
  printf 'CF="$HOME/%s/%s"\n' "$ws" "$proj" >> "$COPY/$file"
  ( cd "$COPY" && git add -A ) >/dev/null 2>&1
  after="$(scan "$COPY" "$SELF_PATH")"

  if printf '%s\n' "$after" | grep -q "^$file:.*$ws/$proj\$"; then
    printf '  PASS  a planted project path in %s IS caught\n' "$label"; pass=$((pass+1))
  else
    printf '  FAIL  the scan did not see the plant in %s\n' "$label"; fail=$((fail+1))
  fi

  n="$(printf '%s\n' "$after" | grep -c .)"
  if [ "$(( n - running ))" -eq 1 ]; then
    printf '  PASS  ...and it added exactly one hit, not a blanket failure\n'; pass=$((pass+1))
  else
    printf '  FAIL  planting one path in %s changed the hit count by %s, expected 1\n' \
      "$label" "$(( n - running ))"; fail=$((fail+1))
  fi
  running="$n"

  # The mutant lived only in the copy. Compared against the hash taken just before the plant, not
  # against git's index -- the branch has its own legitimate edits in flight, and a
  # `git diff --quiet` here would assert about those instead of about what this script did.
  if [ "$(git -C "$REPO" hash-object "$file")" = "$before_hash" ]; then
    printf '  PASS  ...and the tracked %s is byte-identical to before the plant\n' "$file"; pass=$((pass+1))
  else
    printf '  FAIL  the tracked %s changed -- a fault was armed in the real tree\n' "$file"; fail=$((fail+1))
  fi
}

plant bin/fleet             Coding some_project     "a bin/ script"
plant sync.sh               Coding some_project     "a ROOT executable"
plant settings.json         Coding some_project     "a command-bearing settings JSON"
plant bin/sync-to-public.sh Coding a-mirror-clone   "the BASE sync-to-public regression"


# --- positive control: an excused file is excused for ITS hits, not forever --------------------
# This is the whole reason the allowlist carries a count and a digest. A filename-only excuse
# passes this section trivially -- planting a brand-new private path into an already-excused file
# changes nothing it looks at -- so without these five controls the rework would be untested and
# the hole it closes unproven. One control per excused file, derived from the allowlist rather
# than listed, so a sixth entry cannot be added without a control appearing for it.
while IFS=$'\t' read -r f n d reason; do
  [ -n "$f" ] || continue
  # Hashed BEFORE the plant, not compared against the restored copy afterwards: restoring makes
  # the two files equal by construction, which would be an assertion that cannot fail.
  before_hash="$(git -C "$REPO" hash-object "$f")"
  printf 'CF="$HOME/%s/%s"\n' Coding an-unreviewed-project >> "$COPY/$f"
  ( cd "$COPY" && git add -A ) >/dev/null 2>&1
  planted="$(digests "$(scan "$COPY" "$SELF_PATH")")"
  verdict="$(stale_entries "$planted")"
  got="$(printf '%s\n' "$planted" | awk -v f="$f" -F'\t' '$1 == f { print $2 "\t" $3 }')"
  cp "$REPO/$f" "$COPY/$f"
  ( cd "$COPY" && git add -A ) >/dev/null 2>&1

  if printf '%s' "$verdict" | grep -q "^  $f ("; then
    printf '  PASS  a NEW private path in the excused %s reddens the guard\n' "$f"; pass=$((pass+1))
  else
    printf '  FAIL  %s absorbed a new private path silently (summary %s) -- the excuse is a hole\n' \
      "$f" "${got:-<nothing>}"; fail=$((fail+1))
  fi

  if [ "$(git -C "$REPO" hash-object "$f")" = "$before_hash" ]; then
    printf '  PASS  ...and the tracked %s is byte-identical to before that plant\n' "$f"; pass=$((pass+1))
  else
    printf '  FAIL  the tracked %s changed -- a fault was armed in the real tree\n' "$f"; fail=$((fail+1))
  fi
done < <(allow_list)

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
