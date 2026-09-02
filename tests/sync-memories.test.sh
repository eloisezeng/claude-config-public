#!/usr/bin/env bash
set -u
ORIG="$(cd "$(dirname "$0")/.." && pwd)/sync-memories.sh"
fail=0
assert_true()  { eval "$1" && return; echo "FAIL: $2"; fail=1; }
assert_false() { eval "$1" && { echo "FAIL: $2"; fail=1; }; return 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
mkdir -p "$tmp/dotfiles/claude/memories"

# Run a COPY placed inside the sandbox, never the repo script in place. sync-memories.sh derives its
# repo from its own location (as sync.sh / install.sh / inject-global-memory.* all do), so invoking
# the real file with a fake $HOME would aim its writes at the LIVE memory store -- measured
# 2026-09-01, exactly that put a 47-byte test fixture into memories/global/ and autosync committed
# it. The old hardcoded REPO="$HOME/dotfiles/claude" made this test look hermetic when its isolation
# was actually coming from the bug it was meant to be independent of.
SRC="$tmp/dotfiles/claude/sync-memories.sh"
cp "$ORIG" "$SRC"
proj="$tmp/.claude1/projects/-Some-Proj/memory"
mkdir -p "$proj"
printf -- '---\nname: g\nmetadata:\n  scope: global\n---\nbody\n' > "$proj/g.md"
printf -- '---\nname: loc\n---\nlocal body\n' > "$proj/loc.md"

err="$(bash "$SRC" 2>&1 1>/dev/null)"

# global memory moved to FLAT global store, original removed, no silo path
assert_true  '[ -f "$tmp/dotfiles/claude/memories/global/g.md" ]' "g.md not in flat global store"
assert_false '[ -e "$proj/g.md" ]' "project g.md should be removed (no symlink-back)"
assert_false '[ -e "$tmp/dotfiles/claude/memories/claude1/-Some-Proj/g.md" ]' "must not use silo path"
# untagged memory untouched
assert_true  '[ -f "$proj/loc.md" ] && [ ! -L "$proj/loc.md" ]' "local memory must stay put"
# unindexed straggler warned (no pointer in a (missing) global MEMORY.md)
assert_true  'printf "%s" "$err" | grep -q "UNINDEXED global/g.md"' "should warn about unindexed straggler"

# conflict: differing content already at destination -> skip, keep nothing duplicated
mkdir -p "$tmp/.claude1/projects/-Other/memory"
printf -- '---\nname: g\nmetadata:\n  scope: global\n---\nDIFFERENT\n' > "$tmp/.claude1/projects/-Other/memory/g.md"
bash "$SRC"
assert_true '[ "$(cat "$tmp/dotfiles/claude/memories/global/g.md" | tail -1)" = "body" ]' "conflict must not overwrite"

# frontmatter-scoped: a body that merely mentions "scope: global" must NOT be promoted
mkdir -p "$tmp/.claude1/projects/-Body/memory"
printf -- '---\nname: bod\n---\nexample line: scope: global\n' > "$tmp/.claude1/projects/-Body/memory/bod.md"
bash "$SRC" >/dev/null 2>&1
assert_true  '[ -f "$tmp/.claude1/projects/-Body/memory/bod.md" ]' "body-only scope:global must stay local"
assert_false '[ -e "$tmp/dotfiles/claude/memories/global/bod.md" ]' "body-only scope:global must NOT be promoted"

# malformed: opening --- but NO closing --- (unclosed frontmatter) must stay local
mkdir -p "$tmp/.claude1/projects/-NoClose/memory"
printf -- '---\nname: nc\nscope: global\n' > "$tmp/.claude1/projects/-NoClose/memory/nc.md"
bash "$SRC" >/dev/null 2>&1
assert_true  '[ -f "$tmp/.claude1/projects/-NoClose/memory/nc.md" ]' "unclosed-frontmatter must stay local"
assert_false '[ -e "$tmp/dotfiles/claude/memories/global/nc.md" ]' "unclosed-frontmatter must NOT be promoted"

# dedupe branch must ALSO warn UNINDEXED (identical body already in store, no pointer)
mkdir -p "$tmp/.claude1/projects/-Dup/memory"
printf -- '---\nname: g\nmetadata:\n  scope: global\n---\nbody\n' > "$tmp/.claude1/projects/-Dup/memory/g.md"
err2="$(bash "$SRC" 2>&1 1>/dev/null)"
assert_false '[ -e "$tmp/.claude1/projects/-Dup/memory/g.md" ]' "identical dup dropped locally"
assert_true  'printf "%s" "$err2" | grep -q "UNINDEXED global/g.md"' "dedupe branch must warn UNINDEXED too"

[ "$fail" = 0 ] && echo "PASS: sync-memories" || exit 1
