#!/usr/bin/env bash
# The tracked unix settings files are shared across machines whose usernames
# differ, so no hook/statusLine command may hardcode an absolute home directory.
# (settings.windows.json is exempt: maintained by the PowerShell path, and
# Windows hook commands cannot expand $HOME.)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

for f in settings.json settings.linux.json; do
  if hits="$(grep -nE '/(Users|home)/[A-Za-z]' "$REPO/$f")"; then
    echo "FAIL: $f hardcodes an absolute home path (use \$HOME):"
    echo "$hits"
    fail=1
  fi
done

# install.sh must generate the same portable form, or its idempotency check
# would append a duplicate absolute-path hook next to the tracked $HOME one.
run() { bash -c "source '$REPO/install.sh' --source-only; $1"; }

got="$(run 'HOME=/Users/alice portable_hook_cmd /Users/alice/dotfiles/claude')"
want='bash "$HOME/dotfiles/claude/inject-global-memory.sh"'
[ "$got" = "$want" ] || { echo "FAIL: repo under \$HOME: expected '$want' got '$got'"; fail=1; }

got="$(run 'HOME=/Users/alice portable_hook_cmd /opt/claude-config')"
want='bash "/opt/claude-config/inject-global-memory.sh"'
[ "$got" = "$want" ] || { echo "FAIL: repo outside \$HOME: expected '$want' got '$got'"; fail=1; }

# $HOME itself a symlink (common on clusters): REPO_DIR is physical, so the
# logical-$HOME prefix never matches; the physical-$HOME match must still
# yield the portable form, not leak an absolute path into tracked settings.
# Needs a REAL symlink: on Git Bash without Developer Mode `ln -s` silently
# copies, which would make this assert a condition the platform cannot express.
tmp="$(mktemp -d)"
mkdir -p "$tmp/phys/home/alice/claude-config"
ln -s "$tmp/phys/home/alice" "$tmp/alice-link" 2>/dev/null
if [ -L "$tmp/alice-link" ]; then
  got="$(run "HOME='$tmp/alice-link' portable_hook_cmd '$tmp/phys/home/alice/claude-config'")"
  want='bash "$HOME/claude-config/inject-global-memory.sh"'
  [ "$got" = "$want" ] || { echo "FAIL: symlinked \$HOME: expected '$want' got '$got'"; fail=1; }
else
  echo "SKIP: symlinked \$HOME case (no real symlink support on this platform)"
fi
rm -rf "$tmp"

# The mirror image: $HOME physical, but the repo reached through a symlinked
# ANCESTOR (/var -> /private/var on macOS, an automounted /home on clusters).
# Neither prefix matches as spelled, and only a physical-to-physical comparison
# keeps a machine-specific absolute path out of the shared settings file.
tmp="$(mktemp -d)"
mkdir -p "$tmp/real/alice/claude-config"
ln -s "$tmp/real" "$tmp/link" 2>/dev/null
if [ -L "$tmp/link" ]; then
  home_phys="$(cd "$tmp/real/alice" && pwd -P)"
  got="$(run "HOME='$home_phys' portable_hook_cmd '$tmp/link/alice/claude-config'")"
  want='bash "$HOME/claude-config/inject-global-memory.sh"'
  [ "$got" = "$want" ] || { echo "FAIL: symlinked repo ancestor: expected '$want' got '$got'"; fail=1; }
else
  echo "SKIP: symlinked repo-ancestor case (no real symlink support on this platform)"
fi
rm -rf "$tmp"

# The opposite error to the two above: a path that merely LOOKS like it lives
# under $HOME. $HOME/shortcut is a symlink OUT of the home directory, so emitting
# "$HOME/shortcut/..." would produce a settings file that only works on the one
# host that happens to have that shortcut — and, worse, on a host where the name
# exists but points somewhere else it silently loads the wrong repo. The physical
# absolute path is the honest answer here, which is why the physical resolution
# cannot be a fallback taken after the literal cases: a literal case that returns
# early is never corrected.
tmp="$(mktemp -d)"
mkdir -p "$tmp/home" "$tmp/outside/claude-config"
ln -s "$tmp/outside" "$tmp/home/shortcut" 2>/dev/null
if [ -L "$tmp/home/shortcut" ]; then
  outside_phys="$(cd "$tmp/outside" && pwd -P)"
  got="$(run "HOME='$tmp/home' portable_hook_cmd '$tmp/home/shortcut/claude-config'")"
  want="bash \"$outside_phys/claude-config/inject-global-memory.sh\""
  [ "$got" = "$want" ] || { echo "FAIL: \$HOME/shortcut out of home: expected '$want' got '$got'"; fail=1; }
else
  echo "SKIP: \$HOME-shortcut case (no real symlink support on this platform)"
fi
rm -rf "$tmp"

# The macOS settings' repo-path hooks must agree with portable_hook_cmd's
# canonical location, ~/dotfiles/claude (sync-memories.sh hardcodes it too) —
# and there must be EXACTLY ONE inject hook: a mismatched install (e.g. run
# through a symlinked repo path) appends a duplicate beside the canonical entry.
njq='[.hooks.SessionStart[]?.hooks[]? | select((.command? // "") | test("inject-global-memory"))]'
n="$(jq "$njq | length" "$REPO/settings.json")"
[ "$n" = "1" ] || { echo "FAIL: settings.json has $n inject hooks (want exactly 1)"; fail=1; }
if ! jq -e "$njq | .[0].command == \"bash \\\"\$HOME/dotfiles/claude/inject-global-memory.sh\\\"\"" "$REPO/settings.json" >/dev/null; then
  echo "FAIL: settings.json inject hook does not point at \$HOME/dotfiles/claude"
  fail=1
fi

# Same invariant for the Linux settings, whose canonical repo location is
# ~/claude-config.
n="$(jq "$njq | length" "$REPO/settings.linux.json")"
[ "$n" = "1" ] || { echo "FAIL: settings.linux.json has $n inject hooks (want exactly 1)"; fail=1; }
if ! jq -e "$njq | .[0].command == \"bash \\\"\$HOME/claude-config/inject-global-memory.sh\\\"\"" "$REPO/settings.linux.json" >/dev/null; then
  echo "FAIL: settings.linux.json inject hook does not point at \$HOME/claude-config"
  fail=1
fi

# ---- the emitted command EXECUTES, for every character it escapes ---------
# shq_in_dq exists because the path is embedded in a DOUBLE-quoted shell word, so
# `"`, `\`, `$` and a backtick each change what the command means — `$HOME` inside
# a directory name would expand at hook time, a quote would end the word, and a
# backtick would run whatever followed it. Every earlier case uses ordinary
# alphanumeric paths, so deleting the escaping entirely keeps them all green.
# This runs the generated command and compares the argv the script actually
# received, byte for byte, with the path on disk.
argv_case() { # $1=label $2=directory name (may contain anything but / and NUL)
  local label="$1" name="$2" t d shim cmd got want
  t="$(mktemp -d)"
  d="$t/home/$name"
  mkdir -p "$d" 2>/dev/null || { echo "SKIP[$label]: the filesystem refused the name"; rm -rf "$t"; return; }
  printf '#!/usr/bin/env bash\nprintf "%%s" "$0" > "%s/argv.txt"\n' "$t" > "$d/inject-global-memory.sh"
  cmd="$(run "HOME=$(printf '%q' "$t/home") portable_hook_cmd $(printf '%q' "$d")")" \
    || { echo "FAIL[$label]: portable_hook_cmd refused $d"; fail=1; rm -rf "$t"; return; }
  # $HOME is LITERAL in the emitted command — expanded by the shell that runs the
  # hook, which is the whole point of emitting it — so it is set here, not baked in.
  ( export HOME="$t/home"; eval "$cmd" ) >/dev/null 2>&1
  got="$(cat "$t/argv.txt" 2>/dev/null || printf '<the command did not run>')"
  # $HOME is expanded by the shell that RUNS the hook, so the argv carries the
  # $HOME that shell had — the point of the assertion is the suffix, which is
  # where every character being escaped lives.
  want="$t/home/$name/inject-global-memory.sh"
  [ "$got" = "$want" ] || { echo "FAIL[$label]: argv was '$got', want '$want'  (command: $cmd)"; fail=1; }
  rm -rf "$t"
}
argv_case dq       'repo"dir'
argv_case bslash   'repo\dir'
argv_case dollar   'repo$HOME-dir'
argv_case backtick 'repo`whoami`dir'
argv_case squote    "repo'dir"
argv_case space    'repo dir'
argv_case glob     'repo*dir?[x]'
argv_case shellops 'repo;&|()<>dir'
argv_case hashbang 'repo#!dir'
argv_case nonascii 'repo—naïve-dir'
argv_case all      'a"b\c$d`e'"'"'f g;h'

# ...and the one character that cannot be escaped into a single-line command at
# all: a newline would split the hook into two commands, so it must be REFUSED,
# not escaped. (The guard needs a literal newline in the pattern; written as
# `$(printf '\n')` it was the empty string and matched every path, refusing all.)
t="$(mktemp -d)"
nl_dir="$t/home/repo"$'\n'"dir"
if mkdir -p "$nl_dir" 2>/dev/null; then
  out="$(run "HOME=$(printf '%q' "$t/home") portable_hook_cmd $(printf '%q' "$nl_dir")" 2>&1)"; code=$?
  [ "$code" != 0 ] || { echo "FAIL[newline]: a newline in the repo path must be refused, got '$out'"; fail=1; }
  case "$out" in *newline*) ;; *) echo "FAIL[newline]: the refusal must name the cause, got '$out'"; fail=1 ;; esac
  # and an ordinary path must still be accepted by that same guard
  mkdir -p "$t/home/plain"
  out="$(run "HOME=$(printf '%q' "$t/home") portable_hook_cmd $(printf '%q' "$t/home/plain")")"; code=$?
  assert_ok() { :; }
  [ "$code" = 0 ] || { echo "FAIL[newline]: the guard refused an ordinary path: $out"; fail=1; }
  case "$out" in 'bash "$HOME/plain/inject-global-memory.sh"') ;; *) echo "FAIL[newline]: ordinary path emitted '$out'"; fail=1 ;; esac
else
  echo "SKIP[newline]: the filesystem refused a name containing a newline"
fi
rm -rf "$t"

[ "$fail" = 0 ] && echo "PASS: settings-portable-paths" || exit 1
