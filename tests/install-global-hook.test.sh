#!/usr/bin/env bash
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
assert_eq() { [ "$1" = "$2" ] && return; echo "FAIL: expected '$2' got '$1'"; fail=1; }
# null-safe count of inject hooks; .command? // "" avoids errors on command-less entries
CNT='[.hooks.SessionStart[]?.hooks[]? | select((.command? // "") | test("inject-global-memory"))] | length'

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo '{"hooks":{}}' > "$tmp/settings.json"
HOOK="node $REPO/inject-global-memory.mjs"

# install.sh is bash (your interactive shell is zsh) -> always invoke via bash -c
run() { bash -c "source '$REPO/install.sh' --source-only; $1"; }

run "install_global_memory_hook '$tmp/settings.json' '$HOOK'"
assert_eq "$(jq "$CNT" "$tmp/settings.json")" "1"

# Idempotent: second install adds no duplicate
run "install_global_memory_hook '$tmp/settings.json' '$HOOK'"
assert_eq "$(jq "$CNT" "$tmp/settings.json")" "1"

# Not async (no async key on the inject entry)
asynccount="$(jq '[.hooks.SessionStart[]?.hooks[]? | select((.command? // "")|test("inject-global-memory")) | .async] | map(select(. != null)) | length' "$tmp/settings.json")"
assert_eq "$asynccount" "0"


# --- END TO END: the real installer, against a throwaway $HOME ---------------
# The unit checks above drive install_global_memory_hook with a hand-written
# command, so nothing here has ever exercised the WIRING: portable_hook_cmd's
# output actually reaching the settings file that gets persisted and read. Both
# past bugs lived in that seam (a machine-specific absolute path baked into a
# shared file; a duplicate hook appended beside the canonical one), and both are
# invisible to a test that supplies the command itself.
#
# SKIP_WATCHER / SKIP_OPENSUPERWHISPER keep the run off the host's launchd and
# Homebrew; everything else is redirected by $HOME alone.
inject_cnt()  { jq "$CNT" "$1"; }
inject_cmds() { jq -r '.hooks.SessionStart[]?.hooks[]? | select((.command? // "") | test("inject-global-memory")) | .command' "$1"; }

e2e_install() { # $1 = repo dir (inside the fake HOME)  $2 = fake HOME  [$3 = PATH prefix dir]
  local pfx="${3:-}"
  ( HOME="$2" PATH="${pfx:+$pfx:}$PATH" SKIP_WATCHER=1 SKIP_OPENSUPERWHISPER=1 \
      bash "$1/install.sh" "$2/.claude" ) >/dev/null 2>&1
}

# A PATH-scoped `uname`, so the OS-specific half of the installer can be driven
# from either branch on one machine. install.sh picks its settings source from
# `uname` (settings.linux.json on Linux, settings.json otherwise) and nothing had
# ever exercised the Linux branch — a rename or a typo there would first be found
# by whoever installs on Linux, which for this repo is your cluster box.
#
# Only the argless form is faked; anything else execs the real uname, so a future
# `uname -m` in the installer is not silently answered wrong.
shim_uname() { # $1 = dir to create the shim in  $2 = what argless `uname` prints
  mkdir -p "$1"
  cat > "$1/uname" <<SHIMEOF
#!/usr/bin/env bash
[ "\$#" -eq 0 ] && { printf '%s\\n' "$2"; exit 0; }
exec /usr/bin/uname "\$@"
SHIMEOF
  chmod +x "$1/uname"
}

# A copy, not the repo itself: install_global_memory_hook writes into the
# tracked settings file, and a test must never mutate the thing it tests.
seed_repo() { mkdir -p "$1"; cp -R "$REPO/." "$1/" 2>/dev/null || true; rm -rf "$1/.git"; }

# $1 = fake HOME, $2 = repo subpath under it, $3 = label. Asserts the persisted
# hook is the portable form for THAT repo location, appears exactly once, carries
# no machine-specific path, and that a second install grows nothing.
#
# Deliberately stated per-command rather than as a total count: which entries the
# tracked settings file already ships depends on the OS (settings.json is
# canonically ~/dotfiles/claude, settings.linux.json is ~/claude-config), so a
# total-count assertion would encode this machine instead of the invariant.
# $4/$5 are optional: the OS to fake for this run and the repo file the active
# settings.json must then resolve to. Omit both to run on the host's own uname.
e2e_case() {
  local home="$1" sub="$2" label="$3" os="${4:-}" src="${5:-}" mode="${6:-}" active want wantsrc n before after got shim=""
  mkdir -p "$home"; seed_repo "$home/$sub"
  want="bash \"\$HOME/$sub/inject-global-memory.sh\""
  # $6 states which of the two seams this case exercises, and it is checked
  # BEFORE the install: "append" means the selected settings source does not yet
  # carry this command, "match" means it already does. Without that precondition
  # a case whose expectation the seed already satisfies proves nothing — which is
  # how a mutation hardcoding settings.json in place of $SETTINGS_SRC survived
  # every green run: both OS-pinned cases installed from that OS's CANONICAL
  # location, where the tracked file already held the command being asserted.
  if [ -n "$src" ] && [ -n "$mode" ]; then
    n="$(inject_cmds "$home/$sub/$src" | grep -cxF "$want" || true)"
    case "$mode" in
      append) [ "$n" = 0 ] || { echo "FAIL[$label]: precondition — seeded $src already carries '$want'"; fail=1; } ;;
      match)  [ "$n" = 1 ] || { echo "FAIL[$label]: precondition — seeded $src should already carry '$want', got $n"; fail=1; } ;;
    esac
  fi
  [ -n "$os" ] && { shim="$home/shim-bin"; shim_uname "$shim" "$os"; }
  e2e_install "$home/$sub" "$home" "$shim" || { echo "FAIL[$label]: installer exited non-zero"; fail=1; return; }
  active="$home/.claude/settings.json"
  [ -e "$active" ] || { echo "FAIL[$label]: no settings.json was installed"; fail=1; return; }
  if [ -n "$src" ]; then
    # WHICH source file the link resolves to, not its contents: the two OS
    # branches differ only in that choice and both files carry the same hook
    # shape, so a content assertion would be satisfied by either one.
    # The expectation is resolved PHYSICALLY: install.sh resolves its own repo
    # path physically (so a repo behind a symlinked ancestor cannot bake a
    # machine-specific spelling into shared settings — commit 8bbfdec), and $tmp
    # here lives under /var -> /private/var. Comparing the spellings would fail
    # on that fix rather than on the branch this case is about.
    got="$(readlink "$active" 2>/dev/null)"
    wantsrc="$(cd "$home/$sub" && pwd -P)/$src"
    [ "$got" = "$wantsrc" ] || { echo "FAIL[$label]: settings.json -> '$got', want '$wantsrc'"; fail=1; }
  fi
  n="$(inject_cmds "$active" | grep -cxF "$want" || true)"
  [ "$n" = 1 ] || { echo "FAIL[$label]: want exactly 1 '$want', got $n:"; inject_cmds "$active" | sed 's/^/    /'; fail=1; }
  # $tmp sits under a symlinked ancestor on macOS (/var -> /private/var), so a
  # literal prefix comparison would have leaked an absolute path into a file that
  # is shared across machines. Nothing persisted may name this run's directories.
  case "$(inject_cmds "$active")" in
    *"$tmp"*|*/private/*) echo "FAIL[$label]: persisted a machine-specific path"; inject_cmds "$active" | sed 's/^/    /'; fail=1 ;;
  esac
  before="$(inject_cnt "$active")"
  # Idempotence is about the WHOLE file, not the hook being counted. Counting one
  # filtered family cannot see a second install duplicating a statusLine, adding
  # a second SessionStart group, or reordering entries — the settings file is
  # shared across machines, so any of those is a real regression.
  sig_before="$(jq -S . "$active")"
  e2e_install "$home/$sub" "$home" "$shim" || { echo "FAIL[$label]: second install exited non-zero"; fail=1; return; }
  after="$(inject_cnt "$active")"
  [ "$before" = "$after" ] || { echo "FAIL[$label]: second install grew the hooks $before -> $after"; fail=1; }
  sig_after="$(jq -S . "$active")"
  if [ "$sig_before" != "$sig_after" ]; then
    echo "FAIL[$label]: the second install CHANGED settings.json beyond the inject hook:"
    diff <(printf '%s\n' "$sig_before") <(printf '%s\n' "$sig_after") | sed 's/^/    /'
    fail=1
  fi
  n="$(inject_cmds "$active" | grep -cxF "$want" || true)"
  [ "$n" = 1 ] || { echo "FAIL[$label]: after re-install want exactly 1 '$want', got $n"; fail=1; }
}

# The canonical macOS location (already tracked, so a correct run appends
# nothing) and a non-canonical one under $HOME (which must genuinely append,
# and append only once) — the match path and the append path.
e2e_case "$tmp/e2e1" "dotfiles/claude" e2e-canonical
e2e_case "$tmp/e2e2" "claude-config"   e2e-appended

# Both settings branches, each asserted to pick its own file. The Darwin case is
# not redundant: without it, a collapsed `case "$(uname)"` that always chose
# settings.linux.json would still satisfy the Linux assertion, and the pair is
# what makes either assertion mean "the branch was taken".
e2e_case "$tmp/e2e3" "claude-config"   e2e-linux-settings  Linux  settings.linux.json match
e2e_case "$tmp/e2e4" "dotfiles/claude" e2e-darwin-settings Darwin settings.json      match

# ...and the OTHER half of each OS: the location that is NOT canonical for it, so
# the command genuinely has to be written into the file this OS selected. These
# are the cases with something to prove — under a hardcoded settings.json the
# Linux run writes into the inactive macOS file, the active settings.linux.json
# never gains the hook, and the installer aborts at preflight having already
# relinked the configuration.
e2e_case "$tmp/e2e5" "dotfiles/claude" e2e-linux-noncanonical  Linux  settings.linux.json append
e2e_case "$tmp/e2e6" "claude-config"   e2e-darwin-noncanonical Darwin settings.json      append

[ "$fail" = 0 ] && echo "PASS: install-global-hook" || exit 1
