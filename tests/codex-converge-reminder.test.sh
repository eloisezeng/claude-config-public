#!/usr/bin/env bash
# Tests for hooks/codex-converge-reminder.mjs -- plain bash, no bats dependency.
# The hook is driven through its real interface: a UserPromptSubmit payload on stdin, in
# the shape Claude Code sends it (session_id, transcript_path, cwd, permission_mode,
# hook_event_name, prompt), and JSON on stdout.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/codex-converge-reminder.mjs"
fail=0
assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL[$3]: expected to contain: $1"; fail=1;; esac; }
assert_eq()       { [ "$1" = "$2" ] || { echo "FAIL[$3]: expected '$2' got '$1'"; fail=1; }; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"          # per-session state lives under os.tmpdir()
# A suite run from inside a dispatched seat inherits that seat's lane, which silences the
# hook by design. Clear it so every case measures the code, not the shell that ran it.
unset CLAUDE_HANDOFF_LANE

T="$tmp/transcript.jsonl"
: > "$T"
# $1 = prompt, $2 = session id, $3 = hook path (default: the real one)
run() {
  node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],transcript_path:process.argv[2],
    cwd:"/tmp",permission_mode:"bypassPermissions",hook_event_name:"UserPromptSubmit",prompt:process.argv[3]}))' \
    "$2" "$T" "$1" | node "${3:-$HOOK}"
}
ctx() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).hookSpecificOutput.additionalContext)}catch{}})'; }

BUILD_PROMPT='Fix the flaky login test and add a regression check for it.'

# ---- B1. a build/fix request fires, with the exact short reminder --------------
out="$(run "$BUILD_PROMPT" s1)"
assert_contains '`codex-converge` skill' "$(printf '%s' "$out" | ctx)" B1-fires
assert_contains '"hookEventName":"UserPromptSubmit"' "$out" B1-shape

# ---- B2. a second build prompt in the same session is silent (once per session) -
assert_eq "$(run 'Now implement the retry path too.' s1)" "" B2-once

# ---- Q1. a question is silent, and does NOT use up the session's one reminder ---
assert_eq "$(run 'Why is the build broken on main?' s2)" "" Q1-question
assert_contains 'codex-converge' "$(run "$BUILD_PROMPT" s2)" Q1-later-build-still-fires

# ---- H1. a dispatched-seat pointer is silent and marks the whole session -------
assert_eq "$(run 'Read the handoff file /x/handoffs/HANDOFF-fix-login.md and fix what it says.' s3)" "" H1-pointer
assert_eq "$(run "$BUILD_PROMPT" s3)" "" H1-seat-stays-quiet

# ---- H2. a seat's lane in the environment is silent ----------------------------
assert_eq "$(CLAUDE_HANDOFF_LANE=some-lane run "$BUILD_PROMPT" s4)" "" H2-env-lane

# ---- A1. automated prompts are silent ------------------------------------------
assert_eq "$(run '<task-notification><status>completed</status> fix landed</task-notification>' s5)" "" A1-notification
assert_eq "$(run 'Review this change for security vulnerabilities and fix them.' s5)" "" A1-security-review
assert_eq "$(run '/code-review fix the parser' s5)" "" A1-slash-command

# ---- N1. a prompt that already names the skill is silent ------------------------
assert_eq "$(run 'Use codex-converge to fix the parser.' s6)" "" N1-names-skill

# ---- I1. a session that already invoked the skill is silent ---------------------
# The line is the real shape of a Skill tool_use as Claude Code writes it to a transcript.
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_x","name":"Skill","input":{"skill":"codex-converge","args":"Build it"}}]}}' > "$T"
assert_eq "$(run "$BUILD_PROMPT" s7)" "" I1-already-invoked
# control: the same transcript without the invocation fires
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"codex-converge is a skill"}]}}' > "$T"
assert_contains 'codex-converge' "$(run "$BUILD_PROMPT" s8)" I1-control
: > "$T"

# ---- M1. mutants on COPIES: the cases above must notice each -------------------
mut="$tmp/mut-once.mjs"
sed 's/if (existsSync(stateFile)) return;/if (false) return;/' "$HOOK" > "$mut"
cmp -s "$HOOK" "$mut" && { echo "FAIL[M1]: once-per-session mutant did not arm"; fail=1; }
run "$BUILD_PROMPT" m1 "$mut" >/dev/null
assert_contains 'codex-converge' "$(run 'Now implement the retry path too.' m1 "$mut")" M1-once-mutant-speaks-twice

mut2="$tmp/mut-invoked.mjs"
sed 's/if (alreadyInvoked(hook.transcript_path))/if (false \&\& alreadyInvoked(hook.transcript_path))/' "$HOOK" > "$mut2"
cmp -s "$HOOK" "$mut2" && { echo "FAIL[M2]: already-invoked mutant did not arm"; fail=1; }
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"codex-converge"}}]}}' > "$T"
assert_contains 'codex-converge' "$(run "$BUILD_PROMPT" m2 "$mut2")" M2-invoked-mutant-speaks

[ "$fail" = 0 ] && echo "PASS: codex-converge-reminder" || exit 1
