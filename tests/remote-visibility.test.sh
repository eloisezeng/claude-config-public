#!/usr/bin/env bash
# This repo is pushed by an unattended watcher (launchd WatchPaths on macOS, a systemd path unit
# on Linux). It carries memories, transcripts, hook wiring and machine paths. So the failure this
# file exists to prevent is: the remote gets repointed at a world-readable repo -- by a fork, a
# template copy, a typo, or a helpful "publish this" -- and the watcher publishes the lot before
# anyone notices the URL changed.
#
# Two halves, tested separately because they fail differently:
#
#   A. bin/remote-visibility.sh -- the CLASSIFIER. Driven by a stub `git` on PATH, so every host
#      response is reproducible and no network is touched. The assertion that matters most is not
#      any single verdict but that the probe runs with NO credentials: a keychain helper that
#      quietly authenticates makes a PRIVATE repo answer, and the classifier would then say
#      "public" -- or worse, on the mirror case, "private" about a repo the whole world can read.
#
#   B. sync.sh's GATE -- driven by a stubbed helper, and asserted on the REMOTE TIP, not on the
#      exit code. "It refused" is only interesting if nothing was published.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO/bin/remote-visibility.sh"
fail=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
mkdir -p "$HOME"

# ...and its own $TMPDIR. sync.sh puts its lock -- and the mail-dedupe stamp --
# under ${TMPDIR:-/tmp}, which is MACHINE-GLOBAL: any second sync on the box,
# another suite's or the real one's, makes the runs below exit 0 having done and
# logged nothing, and the assertions then fail for a reason that has nothing to
# do with the code under test. A sandbox TMPDIR gives this suite its own lock
# namespace -- and stops it deleting a lock a LIVE sync is holding.
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
case "$(uname)" in
  Darwin) LOG_FILE="$HOME/Library/Logs/claude-config-sync.log" ;;
  *)      LOG_FILE="$HOME/.local/state/claude-config-sync.log" ;;
esac

check() {
  if [ "$1" = "$2" ]; then echo "  ok: $3"; else
    echo "FAIL: $3 (expected '$2', got '$1')"; fail=1
  fi
}

# ==============================================================================================
# A. the classifier
# ==============================================================================================

# A stub `git` that records how it was called and answers however the case wants. The classifier
# deliberately does not reset PATH, which is what makes this possible without a test-only seam in
# the shipped script.
mkdir -p "$SANDBOX/stub"
cat > "$SANDBOX/stub/git" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'
  printf 'GIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT-<unset>}"
  printf 'GIT_CONFIG_GLOBAL=%s\n'   "${GIT_CONFIG_GLOBAL-<unset>}"
  printf 'GIT_CONFIG_SYSTEM=%s\n'   "${GIT_CONFIG_SYSTEM-<unset>}"
  printf 'GIT_ASKPASS=%s\n'         "${GIT_ASKPASS-<unset>}"
} >> "$STUB_LOG"
[ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT" >&2
exit "${STUB_RC:-0}"
STUB
chmod +x "$SANDBOX/stub/git"
export STUB_LOG="$SANDBOX/stub.log"

# $1 label  $2 url  $3 expected verdict. STUB_RC/STUB_OUT come from the caller's environment.
verdict() {
  : > "$STUB_LOG"
  local got
  got="$(PATH="$SANDBOX/stub:$PATH" bash "$HELPER" "$2" 2>"$SANDBOX/why")"
  check "$got" "$3" "$1"
  # Every verdict carries a reason. An unattended refusal with no reason is undiagnosable.
  [ -s "$SANDBOX/why" ] || { echo "FAIL: $1 gave no reason on stderr"; fail=1; }
  # Exactly one word on stdout: sync.sh strips whitespace from this and compares it, so a second
  # line would concatenate into a token matching nothing -- refusing a legitimate private push.
  local lines; lines="$(PATH="$SANDBOX/stub:$PATH" bash "$HELPER" "$2" 2>/dev/null | wc -l | tr -d ' ')"
  check "$lines" 1 "$1: one line on stdout"
}

echo "A1: a filesystem remote is 'local' and needs no probe at all"
STUB_RC=0 STUB_OUT= verdict "absolute path" "$SANDBOX/remote.git" local
STUB_RC=0 STUB_OUT= verdict "file:// url"   "file://$SANDBOX/remote.git" local
[ -s "$STUB_LOG" ] && { echo "FAIL: a local path was probed over the network"; fail=1; } \
  || echo "  ok: no probe was attempted for a local path"

echo "A2: an anonymous reader that CAN fetch the refs means public"
STUB_RC=0 STUB_OUT= verdict "ls-remote succeeds" "https://github.com/o/r.git" public

echo "A3: every way a host refuses an anonymous reader means private"
# GitHub answers 'not found' for a private repo rather than leaking its existence.
STUB_RC=128 STUB_OUT="remote: Repository not found." \
  verdict "github 404" "https://github.com/o/r.git" private
STUB_RC=128 STUB_OUT="fatal: could not read Username for 'https://gitlab.com': terminal prompts disabled" \
  verdict "prompt refused" "https://gitlab.com/o/r.git" private
STUB_RC=128 STUB_OUT="fatal: Authentication failed for 'https://example.com/o/r.git/'" \
  verdict "auth failed" "https://example.com/o/r.git" private
STUB_RC=128 STUB_OUT="fatal: unable to access 'https://x/o/r.git/': The requested URL returned error: 403" \
  verdict "403" "https://x/o/r.git" private

echo "A4: anything else is 'unknown' -- which the caller must treat as a refusal"
STUB_RC=128 STUB_OUT="fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com" \
  verdict "offline" "https://github.com/o/r.git" unknown
STUB_RC=0 STUB_OUT= verdict "no url"            ""                  unknown
STUB_RC=0 STUB_OUT= verdict "unrecognised form" "weird::thing"       unknown
# `PATH=/nonexistent bash ...` would prevent the shell from finding BASH, so the assignment has
# to be scoped by env(1) around an already-resolved interpreter.
BASH_BIN="$(command -v bash)"
got="$(env PATH=/nonexistent "$BASH_BIN" "$HELPER" "https://github.com/o/r.git" 2>/dev/null)"
check "$got" unknown "git missing from PATH is unknown, not a pass"

echo "A5: the probe carries NO credentials -- the guard the whole verdict rests on"
: > "$STUB_LOG"
STUB_RC=0 STUB_OUT= PATH="$SANDBOX/stub:$PATH" bash "$HELPER" "https://github.com/o/r.git" >/dev/null 2>&1
grep -q 'credential.helper=' "$STUB_LOG" \
  && echo "  ok: credential helpers reset on the command line" \
  || { echo "FAIL: no 'credential.helper=' in the probe"; cat "$STUB_LOG"; fail=1; }
for kv in "GIT_TERMINAL_PROMPT=0" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null"; do
  grep -qx "$kv" "$STUB_LOG" && echo "  ok: $kv" \
    || { echo "FAIL: probe ran without $kv"; cat "$STUB_LOG"; fail=1; }
done

echo "A6: ssh and scp remotes are probed as the https url a stranger would use"
probe_url() { # last url argument the stub was handed
  : > "$STUB_LOG"
  STUB_RC=0 STUB_OUT= PATH="$SANDBOX/stub:$PATH" bash "$HELPER" "$1" >/dev/null 2>&1
  sed -n 's/.*\[\(https:[^]]*\)\].*/\1/p' "$STUB_LOG" | tail -1
}
check "$(probe_url 'git@github.com:o/r.git')"          "https://github.com/o/r.git" "scp-style -> https"
check "$(probe_url 'ssh://git@github.com/o/r.git')"    "https://github.com/o/r.git" "ssh:// -> https"
check "$(probe_url 'ssh://git@github.com:22/o/r.git')" "https://github.com/o/r.git" "ssh:// with a port -> https"

echo "A7: URL-embedded userinfo is dropped, but an @ in the PATH is not"
# Fail-OPEN if this regresses: `https://someone@host/o/r.git` on a PUBLIC repo prompts for a
# password, prompts are disabled, and the repo reads as 'private' -- so the push is allowed.
check "$(probe_url 'https://someone@github.com/o/r.git')" "https://github.com/o/r.git" \
  "https userinfo dropped"
check "$(probe_url 'https://github.com/o/re@po.git')"     "https://github.com/o/re@po.git" \
  "an @ inside the path is left alone"
check "$(probe_url 'ssh://github.com/o/re@po.git')"       "https://github.com/o/re@po.git" \
  "ssh:// with an @ inside the path"

# ==============================================================================================
# B. sync.sh's gate
# ==============================================================================================

git init -q --bare "$SANDBOX/remote.git"

make_clone() {
  git clone -q "$SANDBOX/remote.git" "$SANDBOX/$1"
  git -C "$SANDBOX/$1" config user.email "$1@test"
  git -C "$SANDBOX/$1" config user.name  "$1"
  cp "$REPO/sync.sh" "$SANDBOX/$1/sync.sh"
  mkdir -p "$SANDBOX/$1/bin"
  cp "$HELPER" "$SANDBOX/$1/bin/remote-visibility.sh"
}

# Replace the clone's helper with one that always returns $2. The classifier is tested above; this
# half is about what sync.sh DOES with a verdict, so the verdict is made an input.
stub_helper() {
  printf '#!/usr/bin/env bash\necho %s\n' "$2" > "$SANDBOX/$1/bin/remote-visibility.sh"
  chmod +x "$SANDBOX/$1/bin/remote-visibility.sh"
}

run_sync() {
  rm -rf "${TMPDIR:-/tmp}/claude-config-sync.lock.d"
  ( cd "$SANDBOX/$1" && bash ./sync.sh >"$SANDBOX/out.$1" 2>&1 )
}

tip() { git -C "$SANDBOX/remote.git" rev-parse main 2>/dev/null || echo none; }

make_clone c
printf 'one\n' > "$SANDBOX/c/CLAUDE.md"
git -C "$SANDBOX/c" add -A && git -C "$SANDBOX/c" commit -qm init
git -C "$SANDBOX/c" push -q origin HEAD:main
git -C "$SANDBOX/c" branch -q --set-upstream-to=origin/main 2>/dev/null

echo "B1: a local remote still pushes (the real helper, no stub)"
printf 'two\n' >> "$SANDBOX/c/CLAUDE.md"
before="$(tip)"; run_sync c; rc=$?
check "$rc" 0 "push to a local remote exits 0"
[ "$(tip)" != "$before" ] && echo "  ok: the remote advanced" \
  || { echo "FAIL: nothing was pushed"; cat "$SANDBOX/out.c"; fail=1; }

echo "B2: a PUBLIC remote is refused and nothing is published"
printf 'three\n' >> "$SANDBOX/c/CLAUDE.md"
stub_helper c public
before="$(tip)"; run_sync c; rc=$?
check "$rc" 1 "public remote exits non-zero"
check "$(tip)" "$before" "the remote tip did not move"
grep -qi 'refusing to push' "$SANDBOX/out.c" \
  && echo "  ok: said it was refusing" \
  || { echo "FAIL: did not say why"; cat "$SANDBOX/out.c"; fail=1; }
grep -q 'FAILED' "$LOG_FILE" 2>/dev/null \
  && echo "  ok: logged FAILED (raises the desktop/mail notification)" \
  || { echo "FAIL: refusal not logged as FAILED"; fail=1; }

echo "B3: 'unknown' is refused too -- a broken probe is not a pass"
for v in unknown "" "public and private"; do
  stub_helper c "$v"
  before="$(tip)"; run_sync c; rc=$?
  check "$rc" 1 "verdict '$v' exits non-zero"
  check "$(tip)" "$before" "verdict '$v' published nothing"
done

echo "B4: a MISSING helper is refused, not skipped"
rm -f "$SANDBOX/c/bin/remote-visibility.sh"
before="$(tip)"; run_sync c; rc=$?
check "$rc" 1 "missing helper exits non-zero"
check "$(tip)" "$before" "missing helper published nothing"
grep -qi 'missing' "$SANDBOX/out.c" \
  && echo "  ok: named the missing helper" \
  || { echo "FAIL: did not name the missing helper"; cat "$SANDBOX/out.c"; fail=1; }

echo "B5: a private remote pushes"
stub_helper c private
before="$(tip)"; run_sync c; rc=$?
check "$rc" 0 "private remote exits 0"
[ "$(tip)" != "$before" ] && echo "  ok: the remote advanced" \
  || { echo "FAIL: a private remote was not pushed"; cat "$SANDBOX/out.c"; fail=1; }

echo "B6: the override publishes, and says so in the log"
printf 'four\n' >> "$SANDBOX/c/CLAUDE.md"
stub_helper c public
before="$(tip)"
rm -rf "${TMPDIR:-/tmp}/claude-config-sync.lock.d"
( cd "$SANDBOX/c" && CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH=1 bash ./sync.sh >"$SANDBOX/out.c" 2>&1 )
check "$?" 0 "override exits 0"
[ "$(tip)" != "$before" ] && echo "  ok: the override pushed" \
  || { echo "FAIL: override did not push"; cat "$SANDBOX/out.c"; fail=1; }
grep -q 'CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH=1' "$LOG_FILE" \
  && echo "  ok: the override is recorded in the log" \
  || { echo "FAIL: an override left no trace"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: the config repo cannot be pushed to a world-readable remote"
exit "$fail"
