#!/usr/bin/env bash
# Guards the two halves of "a private codename must not reach the public mirror":
#   1. bin/private-name-scan.py DERIVES the private-name set and can SEE a planted name.
#   2. bin/sanitize-to-public.py substitutes the codename that actually leaked, and its
#      verify pass FAILS CLOSED when the rule is removed (mutant run on a COPY, never here).
#
# Why this exists: `your-module` reached the public mirror in 14 files -- 11 memories, the
# codex-converge skill, and a CI fixture that is a real workflow file carrying the
# `your-module/provider-data` package path and its job names. Every sanitize run reported
# "zero forbidden tokens survived", because the forbidden list is hand-maintained and
# nobody had typed that token. A guard for that class is itself an artifact that acts, so
# it gets a positive control here: plant a name, demand a hit.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$REPO/bin/private-name-scan.py"
SANITIZE="$REPO/bin/sanitize-to-public.py"
fail=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fail=1; }
check(){ # check <desc> <expected-ec> <cmd...>
  local desc="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local got=$?
  if [ "$got" -eq "$want" ]; then ok "$desc (ec=$got)"; else
    bad "$desc: expected ec=$want got ec=$got"; printf '%s\n' "$out" | sed 's/^/       | /' | head -6
  fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# A tiny word list, so the coined-word filter is exercised against a KNOWN vocabulary
# rather than whatever the host machine happens to ship.
dict="$tmp/words"
printf '%s\n' tree cue work space middle ware test hook config share click able > "$dict"

mkrepo() { # mkrepo <path> <top-level names...>
  local d="$1"; shift; mkdir -p "$d"; git -C "$d" init -q
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name t
  for n in "$@"; do mkdir -p "$d/$n"; : > "$d/$n/.keep"; done
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm init
}

roots="$tmp/roots"; mkdir -p "$roots"
# projA owns a COINED name plus a generic compound; projB and projC share the infra names,
# so the rarity test has something to reject and something to keep.
mkrepo "$roots/projA" Zorbcue workspace tests hooks
mkrepo "$roots/projB" tests hooks config
mkrepo "$roots/projC" tests hooks config
pub="$tmp/pubrepo"; mkrepo "$pub" docs
mkdir -p "$pub/hooks"; : > "$pub/hooks/handoff.sh"
git -C "$pub" add -A >/dev/null; git -C "$pub" commit -qm handoff

common=(--roots "$roots" --dict "$dict" --public-repo "$pub" --max-repos 2)

# --- the derived set: it must contain the coined name and NOT the furniture ----------
toks="$(python3 "$SCAN" --list-tokens --tree "$tmp" "${common[@]}" 2>&1)"
printf '%s\n' "$toks" | grep -qx 'zorbcue' && ok "derives the coined name" \
  || { bad "derived set must contain the coined name"; printf '       | %s\n' "$toks"; }
for reject in tests hooks config workspace handoff; do
  printf '%s\n' "$toks" | grep -qx "$reject" \
    && bad "derived set must NOT contain '$reject' (it would cry wolf)" \
    || ok "rejects '$reject'"
done

# --- the scan: both directions over the SAME tree shape -------------------------------
dirty="$tmp/dirty"; mkdir -p "$dirty/sub"
printf 'a line\nnpm --prefix Zorbcue/provider-data test\ntail\n' > "$dirty/sub/wf.yml"
check "planted name is a HIT" 1 python3 "$SCAN" --tree "$dirty" "${common[@]}"

clean="$tmp/clean"; mkdir -p "$clean/sub"
printf 'a line\nnpm --prefix your-module/provider-data test\ntail\n' > "$clean/sub/wf.yml"
check "substituted name is CLEAN" 0 python3 "$SCAN" --tree "$clean" "${common[@]}"

# The furniture must not trip it, or the guard gets switched off and protects nothing.
furn="$tmp/furniture"; mkdir -p "$furn"
printf 'tests hooks config workspace handoff shared\n' > "$furn/prose.md"
check "furniture does not trip it" 0 python3 "$SCAN" --tree "$furn" "${common[@]}"

# --- fail CLOSED: an incomplete scan is a failure, never an approval -----------------
check "missing word list fails"   1 python3 "$SCAN" --tree "$clean" --roots "$roots" --dict "$tmp/nope"
check "missing roots fails"       1 python3 "$SCAN" --tree "$clean" --roots "$tmp/nope" --dict "$dict"
check "missing tree fails"        1 python3 "$SCAN" --tree "$tmp/nope" "${common[@]}"
# An empty derived set can hit nothing; passing on it would be the fail-open this guards.
empty="$tmp/emptyroots"; mkrepo "$empty/onlyfurniture" tests hooks
check "empty derived set fails"   1 python3 "$SCAN" --tree "$clean" --roots "$empty" --dict "$dict" --public-repo "$pub"

# --- the sanitizer rule itself, with a mutant on a COPY ------------------------------
# Never arm the fault in this tree: it auto-commits. Copy the tool, break the copy.
src="$tmp/src"; mkdir -p "$src/memories/global"
git -C "$src" init -q; git -C "$src" config user.email t@example.com; git -C "$src" config user.name t
printf 'The YOUR-MODULE arc: run `npm --prefix your-module/provider-data test`, see fix(your-module).\n' \
  > "$src/memories/global/m.md"
git -C "$src" add -A >/dev/null; git -C "$src" commit -qm init
out="$tmp/out"
if python3 "$SANITIZE" --src "$src" --out "$out" >/dev/null 2>&1; then
  if grep -riq your-module "$out"; then bad "sanitizer left the codename in its output"
  else ok "sanitizer substitutes the codename"; fi
  grep -q 'YOUR-MODULE' "$out/memories/global/m.md" && ok "uppercase form substituted" \
    || bad "uppercase YOUR-MODULE not substituted"
else
  bad "sanitizer failed on a clean fixture"
fi

# The mutant is PARTIAL on purpose: it removes only the lowercase rule, leaving the
# uppercase one. A fully broken copy would fail whatever the verify pass checked, so it
# would prove nothing about which property this test actually pins.
mut="$tmp/sanitize-mutant.py"
sed "/'\[Tt\]reecue',/d" "$SANITIZE" > "$mut"
if ! cmp -s "$mut" "$SANITIZE"; then ok "mutant differs from the tool"; else bad "mutant is identical -- the sed matched nothing"; fi
out2="$tmp/out2"
if python3 "$mut" --src "$src" --out "$out2" >/dev/null 2>&1; then
  bad "mutant sanitizer EXITED 0: the verify pass does not fail closed on this token"
else
  ok "mutant sanitizer fails closed"
fi
# ...and the tracked tool is untouched by any of the above.
git -C "$REPO" diff --quiet -- bin/sanitize-to-public.py && ok "tracked sanitizer unmodified" \
  || bad "tracked sanitizer was modified by this test"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
