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

# This suite drives run-codex.sh, which verifies CC_LOOP_JOB/CC_LOOP_ARC against loop.py's
# ledger by PARENT PID. Launched under `loop.py run`, those are inherited from an outer job
# whose recorded pid is the runner's -- so every case below would be refused by the handshake
# before it ever reached the profile guard it is about. Drop the inherited identity, then say
# so out loud: a leak reintroduced later should redden as one legible line, not as five
# failures that all point at the wrong thing.
unset CC_LOOP_JOB CC_LOOP_ARC CC_ARC CC_TRACK CC_ROUND
if [ -z "${CC_LOOP_JOB:-}${CC_LOOP_ARC:-}${CC_ARC:-}${CC_TRACK:-}${CC_ROUND:-}" ]; then
  echo "case 0a: no outer loop.py job identity is inherited into these cases"
else
  echo "FAIL: a CC_LOOP_*/CC_* job identity survived the unset -- every case below would be"
  echo "      refused by the inner handshake, not by the guard it claims to test"
  fail=1
fi

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
  bash "$RUN" --policy-version "$POLICY" --one-off \
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

# ---------------------------------------------------------------------------
# The launcher's own option parsing. Every other guard in this file is reached
# THROUGH it, so a parsing bug is upstream of all of them.
#
# `--flag=value` used to fall through the option loop's `*) break` arm and become
# the <prompt-file> POSITIONAL. The observable damage was not a parse error: with
# `--policy-version=<v>` the acknowledgement stayed empty, so the launcher printed
# "convergence policy changed" and sent the caller off to re-read SKILL.md over a
# shell-quoting difference; with `--arc=DIR` the directory would have been opened
# as the prompt. Both forms must mean the same thing, and an option the launcher
# does not recognise must be REFUSED rather than silently reinterpreted.
echo "case 8: --flag=value and --flag value are the same launch"
RCF="$SANDBOX/rcflags"; rm -rf "$RCF"; mkdir -p "$RCF/wd"; printf 'prompt\n' > "$RCF/prompt.txt"
# An ATTRIBUTED launch, because it is the one that proves the VALUE landed rather than
# merely that the token was consumed: loop.py's gate quotes the arc directory back, so a
# swallowed --arc could not produce this message. A one-off launch would exercise the
# option loop while asserting nothing about what it stored.
rcflags_run() {  # $1 = eq|sp
  rm -rf "$RCF/arc" "$CODEX_STUB_MARKER"; mkdir -p "$RCF/arc"
  if [ "$1" = eq ]; then
    set -- --policy-version="$POLICY" --arc="$RCF/arc" --track=alpha --round=1 --name=n1
  else
    set -- --policy-version "$POLICY" --arc "$RCF/arc" --track alpha --round 1 --name n1
  fi
  bash "$RUN" "$@" "$RCF/prompt.txt" "$RCF/out.json" "$RCF/run.log" "$RCF/wd" -p sol
}
rcflags_run eq >"$RCF/eq.out" 2>"$RCF/eq.err"; rc_eq=$?
rcflags_run sp >"$RCF/sp.out" 2>"$RCF/sp.err"; rc_sp=$?
[ "$rc_eq" -eq "$rc_sp" ] \
  && echo "  ok: same exit status either way ($rc_eq)" \
  || { echo "FAIL: --flag=value exited $rc_eq, --flag value exited $rc_sp"; fail=1; }
if diff -q "$RCF/eq.err" "$RCF/sp.err" >/dev/null && diff -q "$RCF/eq.out" "$RCF/sp.out" >/dev/null; then
  echo "  ok: byte-identical output either way"
else
  echo "FAIL: the two option forms produced different output"; diff "$RCF/sp.err" "$RCF/eq.err"; fail=1
fi
# The load-bearing half: the arc DIRECTORY is echoed back, so --arc=DIR was stored and not
# consumed as a positional. Without this the diff above would still pass if BOTH forms broke.
grep -qF -- "$RCF/arc" "$RCF/eq.err" \
  && echo "  ok: --arc=DIR reached loop.py (the refusal names the directory)" \
  || { echo "FAIL: --arc=DIR did not reach loop.py"; cat "$RCF/eq.err"; fail=1; }
[ -e "$CODEX_STUB_MARKER" ] \
  && { echo "FAIL: codex was launched by an ungated attributed run"; fail=1; } \
  || echo "  ok: neither form got past the round gate"

echo "case 8b: control — with the =-form split removed, the equals form is NOT accepted"
# A PARTIAL break, not a rewrite: only the line that splits `--flag=value` is deleted, so the
# space form still works and the difference the case measures is the only thing that moved. A
# fully broken parser would refuse both forms and prove nothing about which assertion is live.
BRK="$SANDBOX/run-codex-broken.sh"
grep -v -- '--\*=\*) _val=' "$RUN" > "$BRK"
[ "$(wc -l < "$BRK")" -lt "$(wc -l < "$RUN")" ] \
  || { echo "FAIL: control did not remove the =-form split; it is asserting against an UNBROKEN copy"; fail=1; }
rm -rf "$RCF/arc"; mkdir -p "$RCF/arc"
bash "$BRK" --policy-version="$POLICY" --one-off \
     "$RCF/prompt.txt" "$RCF/out.json" "$RCF/run.log" "$RCF/wd" -p sol \
     >"$RCF/brk.out" 2>"$RCF/brk.err"
brk_rc=$?
[ "$brk_rc" -ne 0 ] \
  && echo "  ok: the broken parser refuses --policy-version=<v> (exit $brk_rc), so case 8 is not vacuous" \
  || { echo "FAIL: the broken parser ACCEPTED the equals form — case 8 proves nothing"; fail=1; }
# And the same broken copy still accepts the SPACE form, which is what makes it a control for
# the =-split specifically rather than a copy that is broken in general.
rm -f "$CODEX_STUB_MARKER"
bash "$BRK" --policy-version "$POLICY" --one-off \
     "$RCF/prompt.txt" "$RCF/out.json" "$RCF/run.log" "$RCF/wd" -p sol \
     >/dev/null 2>&1
[ -e "$CODEX_STUB_MARKER" ] \
  && echo "  ok: the broken copy still runs the space form — only the =-split is missing" \
  || { echo "FAIL: the control is broken in general, not in the one way case 8 measures"; fail=1; }

echo "case 9: an unrecognised option before <prompt-file> is refused, never taken as a positional"
rm -f "$CODEX_STUB_MARKER"
bash "$RUN" --policy-version "$POLICY" --one-off --bogus \
     "$RCF/prompt.txt" "$RCF/out.json" "$RCF/run.log" "$RCF/wd" -p sol \
     >"$RCF/unk.out" 2>"$RCF/unk.err"
unk_rc=$?
[ "$unk_rc" -eq 2 ] \
  && echo "  ok: refused (exit 2)" \
  || { echo "FAIL: an unrecognised option expected exit 2, got $unk_rc"; cat "$RCF/unk.err"; fail=1; }
grep -q -- '--bogus' "$RCF/unk.err" \
  && echo "  ok: named the option it did not recognise" \
  || { echo "FAIL: the refusal did not name --bogus"; cat "$RCF/unk.err"; fail=1; }
[ -e "$CODEX_STUB_MARKER" ] \
  && { echo "FAIL: codex was launched with an unrecognised launcher option"; fail=1; } \
  || echo "  ok: codex never launched"
# codex's OWN flags come after <workdir> and must keep working -- the refusal is scoped to the
# launcher's own option region, not to every token starting with two dashes.
rm -f "$CODEX_STUB_MARKER" "$RCF/out.json"
bash "$RUN" --policy-version "$POLICY" --one-off \
     "$RCF/prompt.txt" "$RCF/out.json" "$RCF/run.log" "$RCF/wd" -p sol --output-schema /dev/null \
     >/dev/null 2>&1
[ -e "$CODEX_STUB_MARKER" ] \
  && echo "  ok: a codex flag after <workdir> is still passed through" \
  || { echo "FAIL: the unknown-option refusal swallowed a codex flag after <workdir>"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: an unknown codex profile cannot silently downgrade a review"
exit "$fail"
