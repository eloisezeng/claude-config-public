#!/usr/bin/env bash
# The Windows half of the public-remote push guard: bin/remote-visibility.ps1 and sync.ps1's gate.
#
# Windows is where this guard matters most -- watch.ps1 plus the ClaudeConfigSync scheduled task
# push on every file change, and the people most likely to fork a config template and aim it at
# their own public repo are the ones following the Windows setup doc. So the PowerShell half is
# not shipped on the strength of resembling the bash half; it is executed.
#
# Written in bash to match every other test in this repo, and it runs anywhere pwsh is installed
# (macOS and Linux included) -- which is how it is developed and how CI can run it. It SKIPS,
# loudly and with exit 0, where pwsh is absent.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO/bin/remote-visibility.ps1"
fail=0

if ! command -v pwsh >/dev/null 2>&1; then
  echo "SKIP: pwsh is not installed; the PowerShell guard was not exercised"
  exit 0
fi
[ -f "$HELPER" ] || { echo "FAIL: $HELPER is missing"; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export LOCALAPPDATA="$SANDBOX/appdata"
mkdir -p "$LOCALAPPDATA"

# Same isolation as the bash suites: sync.ps1 serializes on a named mutex, which
# .NET backs with files under $TMPDIR on Unix, so a sandbox TMPDIR keeps
# concurrent runs of this suite out of each other's way here. On Windows that
# mutex is genuinely machine-wide and this cannot isolate it; a real sync.ps1
# running there during the suite would make case B exit 0 for the wrong reason.
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
LOG_FILE="$LOCALAPPDATA/claude-config-sync.log"

check() {
  if [ "$1" = "$2" ]; then echo "  ok: $3"; else
    echo "FAIL: $3 (expected '$2', got '$1')"; fail=1
  fi
}

# ==============================================================================================
# A. the classifier
# ==============================================================================================

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

verdict() { # $1 label  $2 url  $3 expected
  : > "$STUB_LOG"
  local got
  got="$(PATH="$SANDBOX/stub:$PATH" pwsh -NoLogo -NoProfile -File "$HELPER" "$2" 2>"$SANDBOX/why")"
  check "$got" "$3" "$1"
  [ -s "$SANDBOX/why" ] || { echo "FAIL: $1 gave no reason on stderr"; fail=1; }
}

echo "A1: a filesystem remote is 'local' and needs no probe -- POSIX, file://, drive-letter, UNC"
STUB_RC=0 STUB_OUT= verdict "posix path"    "$SANDBOX/remote.git"        local
STUB_RC=0 STUB_OUT= verdict "file:// url"   "file://$SANDBOX/remote.git" local
STUB_RC=0 STUB_OUT= verdict "drive letter"  'C:\Users\x\claude-config'   local
STUB_RC=0 STUB_OUT= verdict "UNC share"     '\\server\share\config'      local
[ -s "$STUB_LOG" ] && { echo "FAIL: a local path was probed over the network"; fail=1; } \
  || echo "  ok: no probe was attempted for a local path"

echo "A2: an anonymous reader that CAN fetch the refs means public"
STUB_RC=0 STUB_OUT= verdict "ls-remote succeeds" "https://github.com/o/r.git" public

echo "A3: every way a host refuses an anonymous reader means private"
STUB_RC=128 STUB_OUT="remote: Repository not found." \
  verdict "github 404" "https://github.com/o/r.git" private
STUB_RC=128 STUB_OUT="fatal: could not read Username for 'https://gitlab.com': terminal prompts disabled" \
  verdict "prompt refused" "https://gitlab.com/o/r.git" private
STUB_RC=128 STUB_OUT="fatal: Authentication failed for 'https://example.com/o/r.git/'" \
  verdict "auth failed" "https://example.com/o/r.git" private

echo "A4: anything else is 'unknown' -- which the caller must treat as a refusal"
STUB_RC=128 STUB_OUT="fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com" \
  verdict "offline"           "https://github.com/o/r.git" unknown
STUB_RC=0 STUB_OUT= verdict "no url"            ""             unknown
STUB_RC=0 STUB_OUT= verdict "unrecognised form" "weird::thing"  unknown

echo "A5: the probe carries NO credentials -- the guard the whole verdict rests on"
: > "$STUB_LOG"
STUB_RC=0 STUB_OUT= PATH="$SANDBOX/stub:$PATH" pwsh -NoLogo -NoProfile -File "$HELPER" \
  "https://github.com/o/r.git" >/dev/null 2>&1
grep -q 'credential.helper=' "$STUB_LOG" \
  && echo "  ok: credential helpers reset on the command line" \
  || { echo "FAIL: no 'credential.helper=' in the probe"; cat "$STUB_LOG"; fail=1; }
for kv in "GIT_TERMINAL_PROMPT=0" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null"; do
  grep -qx "$kv" "$STUB_LOG" && echo "  ok: $kv" \
    || { echo "FAIL: probe ran without $kv"; cat "$STUB_LOG"; fail=1; }
done

echo "A6: the process environment is RESTORED after the probe"
# PowerShell has no per-command environment, so the probe mutates the process. If it did not put
# the values back, every later git call in sync.ps1 would run with no global config and no
# credential helper -- i.e. the guard would break the very push it just approved.
: > "$SANDBOX/env.log"
cat > "$SANDBOX/envcheck.ps1" <<'PS'
param([string] $Helper, [string] $Url, [string] $Out)
$env:GIT_CONFIG_GLOBAL = 'SENTINEL-GLOBAL'
$env:GIT_TERMINAL_PROMPT = 'SENTINEL-PROMPT'
[void](& $Helper $Url)
"GIT_CONFIG_GLOBAL=$($env:GIT_CONFIG_GLOBAL)"   | Add-Content -LiteralPath $Out
"GIT_TERMINAL_PROMPT=$($env:GIT_TERMINAL_PROMPT)" | Add-Content -LiteralPath $Out
PS
STUB_RC=0 STUB_OUT= PATH="$SANDBOX/stub:$PATH" pwsh -NoLogo -NoProfile -File "$SANDBOX/envcheck.ps1" \
  -Helper "$HELPER" -Url "https://github.com/o/r.git" -Out "$SANDBOX/env.log" >/dev/null 2>&1
grep -qx 'GIT_CONFIG_GLOBAL=SENTINEL-GLOBAL' "$SANDBOX/env.log" \
  && echo "  ok: GIT_CONFIG_GLOBAL restored" \
  || { echo "FAIL: the probe left GIT_CONFIG_GLOBAL clobbered"; cat "$SANDBOX/env.log"; fail=1; }
grep -qx 'GIT_TERMINAL_PROMPT=SENTINEL-PROMPT' "$SANDBOX/env.log" \
  && echo "  ok: GIT_TERMINAL_PROMPT restored" \
  || { echo "FAIL: the probe left GIT_TERMINAL_PROMPT clobbered"; cat "$SANDBOX/env.log"; fail=1; }

echo "A7: ssh, scp and userinfo urls are probed as the https url a stranger would use"
probe_url() {
  : > "$STUB_LOG"
  STUB_RC=0 STUB_OUT= PATH="$SANDBOX/stub:$PATH" pwsh -NoLogo -NoProfile -File "$HELPER" "$1" \
    >/dev/null 2>&1
  sed -n 's/.*\[\(https:[^]]*\)\].*/\1/p' "$STUB_LOG" | tail -1
}
check "$(probe_url 'git@github.com:o/r.git')"             "https://github.com/o/r.git" "scp-style -> https"
check "$(probe_url 'ssh://git@github.com/o/r.git')"       "https://github.com/o/r.git" "ssh:// -> https"
check "$(probe_url 'ssh://git@github.com:22/o/r.git')"    "https://github.com/o/r.git" "ssh:// with a port"
check "$(probe_url 'https://someone@github.com/o/r.git')" "https://github.com/o/r.git" "userinfo dropped"
check "$(probe_url 'https://github.com/o/re@po.git')"     "https://github.com/o/re@po.git" "@ in the path kept"

# ==============================================================================================
# B. sync.ps1's gate
# ==============================================================================================

[ -f "$REPO/sync.ps1" ] || { echo "FAIL: no sync.ps1 to gate"; exit 1; }

git init -q --bare "$SANDBOX/remote.git"
git clone -q "$SANDBOX/remote.git" "$SANDBOX/c" 2>/dev/null
git -C "$SANDBOX/c" config user.email c@test
git -C "$SANDBOX/c" config user.name  c
cp "$REPO/sync.ps1" "$SANDBOX/c/sync.ps1"
mkdir -p "$SANDBOX/c/bin"
cp "$HELPER" "$SANDBOX/c/bin/remote-visibility.ps1"
printf 'one\n' > "$SANDBOX/c/CLAUDE.md"
git -C "$SANDBOX/c" add -A && git -C "$SANDBOX/c" commit -qm init
git -C "$SANDBOX/c" push -q origin HEAD:main
git -C "$SANDBOX/c" branch -q --set-upstream-to=origin/main 2>/dev/null

stub_helper() { printf 'Write-Output "%s"\n' "$1" > "$SANDBOX/c/bin/remote-visibility.ps1"; }
run_ps1() { ( cd "$SANDBOX/c" && pwsh -NoLogo -NoProfile -File ./sync.ps1 >"$SANDBOX/out.c" 2>&1 ); }
tip() { git -C "$SANDBOX/remote.git" rev-parse main 2>/dev/null || echo none; }

echo "B1: a local remote still pushes (the real helper, no stub)"
printf 'two\n' >> "$SANDBOX/c/CLAUDE.md"
before="$(tip)"; run_ps1; rc=$?
check "$rc" 0 "push to a local remote exits 0"
[ "$(tip)" != "$before" ] && echo "  ok: the remote advanced" \
  || { echo "FAIL: nothing was pushed"; cat "$SANDBOX/out.c"; fail=1; }

echo "B2: a PUBLIC remote is refused and nothing is published"
printf 'three\n' >> "$SANDBOX/c/CLAUDE.md"
stub_helper public
before="$(tip)"; run_ps1; rc=$?
check "$rc" 1 "public remote exits non-zero"
check "$(tip)" "$before" "the remote tip did not move"
grep -qi 'refusing to push' "$SANDBOX/out.c" \
  && echo "  ok: said it was refusing" \
  || { echo "FAIL: did not say why"; cat "$SANDBOX/out.c"; fail=1; }
grep -q 'FAILED' "$LOG_FILE" 2>/dev/null \
  && echo "  ok: logged FAILED (raises the toast and the .FAILED marker)" \
  || { echo "FAIL: refusal not logged as FAILED"; fail=1; }

echo "B3: 'unknown', empty and multi-word verdicts are refused too"
for v in unknown "" "public and private"; do
  stub_helper "$v"
  before="$(tip)"; run_ps1; rc=$?
  check "$rc" 1 "verdict '$v' exits non-zero"
  check "$(tip)" "$before" "verdict '$v' published nothing"
done

echo "B4: a MISSING helper is refused, not skipped"
rm -f "$SANDBOX/c/bin/remote-visibility.ps1"
before="$(tip)"; run_ps1; rc=$?
check "$rc" 1 "missing helper exits non-zero"
check "$(tip)" "$before" "missing helper published nothing"
grep -qi 'missing' "$SANDBOX/out.c" \
  && echo "  ok: named the missing helper" \
  || { echo "FAIL: did not name the missing helper"; cat "$SANDBOX/out.c"; fail=1; }

echo "B5: a private remote pushes"
stub_helper private
before="$(tip)"; run_ps1; rc=$?
check "$rc" 0 "private remote exits 0"
[ "$(tip)" != "$before" ] && echo "  ok: the remote advanced" \
  || { echo "FAIL: a private remote was not pushed"; cat "$SANDBOX/out.c"; fail=1; }

echo "B6: the override publishes, and says so in the log"
printf 'four\n' >> "$SANDBOX/c/CLAUDE.md"
stub_helper public
before="$(tip)"
( cd "$SANDBOX/c" && CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH=1 pwsh -NoLogo -NoProfile -File ./sync.ps1 \
    >"$SANDBOX/out.c" 2>&1 )
check "$?" 0 "override exits 0"
[ "$(tip)" != "$before" ] && echo "  ok: the override pushed" \
  || { echo "FAIL: override did not push"; cat "$SANDBOX/out.c"; fail=1; }
grep -q 'CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH=1' "$LOG_FILE" \
  && echo "  ok: the override is recorded in the log" \
  || { echo "FAIL: an override left no trace"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: the Windows sync cannot push to a world-readable remote either"
exit "$fail"
