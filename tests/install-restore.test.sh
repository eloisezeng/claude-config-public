#!/usr/bin/env bash
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
assert_true()  { eval "$1" && return; echo "FAIL: $2"; fail=1; }
assert_false() { eval "$1" && { echo "FAIL: $2"; fail=1; }; return 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"

# restore_memories links repo files into the config dir, and install.sh is
# unix-only by design (symlinks + launchd/systemd — see its header). Where
# `ln -s` silently copies instead (Git Bash without Developer Mode), the
# symlink assertions below can never hold: skip loudly rather than fail.
: > "$tmp/.probe-target"
ln -s "$tmp/.probe-target" "$tmp/.probe-link" 2>/dev/null
if [ ! -L "$tmp/.probe-link" ]; then
  echo "SKIP: install-restore (no real symlink support on this platform)"
  exit 0
fi
rm -f "$tmp/.probe-link" "$tmp/.probe-target"

mem="$tmp/dotfiles/claude/memories"
mkdir -p "$mem/global" "$mem/claude1/-Proj"
printf -- '- [x](x.md)\n' > "$mem/global/MEMORY.md"
printf -- 'gbody\n'       > "$mem/global/x.md"
printf -- 'legacy\n'      > "$mem/claude1/-Proj/foo.md"

# Run restore in a SUBSHELL: sourcing install.sh enables `set -euo pipefail`,
# which must not leak into the assertion shell.
bash -c "source '$REPO/install.sh' --source-only; restore_memories '$mem'"

# global store must NOT be restored into a ~/.global config dir
assert_false '[ -e "$tmp/.global" ]' "must not create ~/.global from memories/global"
# legacy silo memory MUST still restore as a symlink into the project memory dir
link="$tmp/.claude1/projects/-Proj/memory/foo.md"
assert_true '[ -L "$link" ]' "legacy memory must restore as a symlink"
assert_true '[ "$(readlink "$link")" = "$mem/claude1/-Proj/foo.md" ]' "legacy symlink must point at the repo file"

[ "$fail" = 0 ] && echo "PASS: install-restore" || exit 1
