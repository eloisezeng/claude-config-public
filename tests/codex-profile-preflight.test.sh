#!/usr/bin/env bash
# `codex exec -p <name>` with a profile that does not exist is NOT an error — codex silently
# layers nothing and runs the base config. On 2026-08-13 a Windows machine autosynced its own
# profile names (`terrax`, `terramax`) into the shared codex-converge skill; on the Mac those
# did not exist, so every adversarial-diff / security / money / migration review ran at
# reasoning effort `none` for four days while reporting perfectly normal verdicts.
#
# run-codex.sh therefore refuses an unknown -p up front. These tests pin that refusal, and
# pin that it happens BEFORE codex is launched — a guard that fires after the spend has
# already happened is not a guard.
#
# A stub `codex` on PATH stands in for the real CLI, so this test costs nothing to run.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$REPO/skills/codex-converge/run-codex.sh"
fail=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export CODEX_HOME="$SANDBOX/codex"
mkdir -p "$CODEX_HOME" "$SANDBOX/work" "$SANDBOX/art" "$SANDBOX/bin"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$CODEX_HOME/sol.config.toml"
printf 'prompt\n' > "$SANDBOX/prompt.txt"

# Stub codex: records that it was invoked, emits a banner on stdout (which run-codex.sh
# captures as the log), and writes the -o file so the run counts as a success.
cat > "$SANDBOX/bin/codex" <<'STUB'
#!/bin/sh
: > "$CODEX_STUB_MARKER"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
echo "model: gpt-5.6-sol"
echo "reasoning effort: high"
[ -n "$out" ] && printf '{"ok":true}\n' > "$out"
exit 0
STUB
chmod +x "$SANDBOX/bin/codex"
export PATH="$SANDBOX/bin:$PATH"
export CODEX_STUB_MARKER="$SANDBOX/codex-was-invoked"

# run-codex.sh refuses any launch that does not acknowledge the CURRENT convergence policy,
# and it refuses FIRST -- before it looks at -p. From 2026-08-30 until this was fixed
# (2026-09-01) every case below therefore passed for the wrong reason: `expect_refused`
# saw exit 2 from the policy gate and reported the profile guard as working, while the
# profile guard was never reached at all. Read the version out of the script rather than
# repeating it, so bumping the policy does not redden a test about something else -- the
# gate itself is pinned once, deliberately, in case 0.
POLICY="$(sed -n 's/^POLICY_VERSION="\(.*\)"$/\1/p' "$RUN")"
[ -n "$POLICY" ] || { echo "FAIL: could not read POLICY_VERSION out of $RUN"; exit 1; }

run() {
  rm -f "$CODEX_STUB_MARKER" "$SANDBOX/art/out.json"
  bash "$RUN" --policy-version "$POLICY" \
       "$SANDBOX/prompt.txt" "$SANDBOX/art/out.json" "$SANDBOX/art/run.log" \
       "$SANDBOX/work" "$@" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
}

# The same call with an EXPLICIT acknowledgement, so the two ways the gate can be defeated are
# pinned separately. Passing "" reproduces "no --policy-version at all"; passing a wrong version
# reproduces the case the gate actually exists for -- a session that read an OLD policy and is
# still quoting it. Testing only the empty case leaves `[ "$ACK" != "$POLICY" ]` mutable to
# `[ -z "$ACK" ]` with the whole suite still green, which is the same vacuity that let the
# 2026-08-30 breakage hide for two days, one level up.
run_acked() {
  local ack="$1"; shift
  rm -f "$CODEX_STUB_MARKER" "$SANDBOX/art/out.json"
  if [ -n "$ack" ]; then set -- --policy-version "$ack" \
       "$SANDBOX/prompt.txt" "$SANDBOX/art/out.json" "$SANDBOX/art/run.log" "$SANDBOX/work" "$@"
  else set -- "$SANDBOX/prompt.txt" "$SANDBOX/art/out.json" "$SANDBOX/art/run.log" "$SANDBOX/work" "$@"
  fi
  bash "$RUN" "$@" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
}

expect_policy_refusal() {
  local what="$1"; shift
  run_acked "$@"; local rc=$?
  [ "$rc" -eq 2 ] \
    && echo "  ok: $what refused (exit 2)" \
    || { echo "FAIL: $what expected exit 2, got $rc"; cat "$SANDBOX/stderr"; fail=1; }
  [ -e "$CODEX_STUB_MARKER" ] \
    && { echo "FAIL: $what — codex was LAUNCHED anyway"; fail=1; } \
    || echo "  ok: $what — codex never launched"
  grep -q "policy" "$SANDBOX/stderr" \
    && echo "  ok: $what — said why (policy), so it is not confusable with the -p guard" \
    || { echo "FAIL: $what — refusal did not mention the policy"; cat "$SANDBOX/stderr"; fail=1; }
}

expect_refused() {
  local what="$1"; shift
  run "$@"; local rc=$?
  if [ "$rc" -eq 2 ]; then echo "  ok: $what refused (exit 2)"
  else echo "FAIL: $what expected exit 2, got $rc"; cat "$SANDBOX/stderr"; fail=1; fi
  if [ -e "$CODEX_STUB_MARKER" ]; then
    echo "FAIL: $what — codex was LAUNCHED anyway; the guard fired too late"; fail=1
  else
    echo "  ok: $what — codex never launched"
  fi
}

echo "case 0: a launch that does not acknowledge the current policy is refused, and refused FIRST"
expect_policy_refusal "unacknowledged launch" "" -p sol

echo "case 0b: a STALE acknowledgement is refused too — the case the gate actually exists for"
expect_policy_refusal "stale --policy-version" "2026-08-01-some-older-policy" -p sol

echo "case 1: an unknown -p is refused before codex is launched"
expect_refused "-p nope" -p nope
grep -q "nope" "$SANDBOX/stderr" \
  && echo "  ok: named the missing profile" \
  || { echo "FAIL: stderr did not name the profile"; fail=1; }
grep -q -- "- sol" "$SANDBOX/stderr" \
  && echo "  ok: listed the profiles that DO exist here" \
  || { echo "FAIL: did not list installed profiles"; cat "$SANDBOX/stderr"; fail=1; }

echo "case 2: the --profile=NAME spelling is checked too"
expect_refused "--profile=nope" --profile=nope

echo "case 3: -p with no name is a usage error, not a silent pass"
expect_refused "-p with no argument" -p

echo "case 4: a profile that exists as a FILE is accepted"
run -p sol; rc=$?
if [ "$rc" -eq 0 ]; then echo "  ok: -p sol ran (exit 0)"
else echo "FAIL: -p sol expected exit 0, got $rc"; cat "$SANDBOX/stderr"; fail=1; fi
[ -e "$CODEX_STUB_MARKER" ] && echo "  ok: codex was launched" \
  || { echo "FAIL: codex never launched for a valid profile"; fail=1; }

echo "case 5: a profile declared INSIDE config.toml is accepted, not just a *.config.toml"
printf '[profiles.inline]\nmodel = "gpt-5.6-luna"\n' > "$CODEX_HOME/config.toml"
run -p inline; rc=$?
if [ "$rc" -eq 0 ]; then echo "  ok: -p inline accepted from config.toml"
else echo "FAIL: -p inline expected exit 0, got $rc"; cat "$SANDBOX/stderr"; fail=1; fi

echo "case 6: the run reports the tier ACTUALLY used, read from codex's own banner"
grep -q 'tier actually used: model=gpt-5.6-sol effort=high' "$SANDBOX/stdout" \
  && echo "  ok: banner reported" \
  || { echo "FAIL: no tier banner in output"; cat "$SANDBOX/stdout"; fail=1; }

echo "case 7: effort=none is called out as a void review, not reported as normal"
cat > "$SANDBOX/bin/codex" <<'STUB'
#!/bin/sh
: > "$CODEX_STUB_MARKER"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
echo "model: gpt-5.6-sol"
echo "reasoning effort: none"
[ -n "$out" ] && printf '{"ok":true}\n' > "$out"
exit 0
STUB
chmod +x "$SANDBOX/bin/codex"
run -p sol
grep -qi 'none' "$SANDBOX/stdout" && grep -qiE 'warn|void|not trust|effort=none' "$SANDBOX/stdout" \
  && echo "  ok: warned about effort=none" \
  || { echo "FAIL: effort=none passed without a warning"; cat "$SANDBOX/stdout"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: an unknown codex profile cannot silently downgrade a review"
exit "$fail"
