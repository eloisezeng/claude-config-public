#!/bin/bash
# ask-codex.sh — one-shot second opinion from Codex on a claim Claude just made.
#
#   ask-codex.sh <claim-file> [--tier luna|sol|terra] [--workdir DIR] [--out DIR]
#
# Wraps the claim in the framing that makes a second opinion worth having (disagree, argue
# against yourself, name what was not checked) and hands it to the watchdogged launcher.
# Read-only sandbox. Prints the verdict path and the tier READ FROM THE LOG BANNER.
#
# Exit: 0 verdict promoted | 1 codex failed | 2 bad usage

set -uo pipefail

# Derived, not hardcoded: this skill lives beside codex-converge in whatever checkout it was
# installed from ($HOME/dotfiles/claude on macOS, $HOME/claude-config on Linux).
RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../codex-converge" && pwd)/run-codex.sh"
TIER=luna
WORKDIR="$PWD"
OUTDIR="${CLAUDE_JOB_DIR:-${TMPDIR:-/tmp}}/tmp"
CLAIM=""

die() { printf 'ask-codex: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tier)    TIER="${2:-}"; shift 2 || die "--tier needs a value" ;;
    --workdir) WORKDIR="${2:-}"; shift 2 || die "--workdir needs a value" ;;
    --out)     OUTDIR="${2:-}"; shift 2 || die "--out needs a value" ;;
    -*)        die "unknown flag $1" ;;
    *)         [ -z "$CLAIM" ] || die "only one claim file"; CLAIM="$1"; shift ;;
  esac
done

[ -n "$CLAIM" ] || die "usage: ask-codex.sh <claim-file> [--tier luna|sol|terra] [--workdir DIR]"
[ -f "$CLAIM" ] || die "claim file not found: $CLAIM"
[ -s "$CLAIM" ] || die "claim file is empty: $CLAIM"
[ -x "$RUNNER" ] || die "launcher not executable: $RUNNER"
[ -d "$WORKDIR" ] || die "workdir not a directory: $WORKDIR"

case "$TIER" in
  luna|sol|terra) ;;
  *) die "tier '$TIER' needs the user's explicit permission (luna|sol|terra are the free ones)" ;;
esac

mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
PROMPT="$OUTDIR/opinion-$STAMP.prompt.txt"
VERDICT="$OUTDIR/opinion-$STAMP.md"
LOG="$OUTDIR/opinion-$STAMP.log"

{
  cat <<'FRAME'
You are giving an INDEPENDENT second opinion on the claim below, which another assistant just
made. Your job is to be right, not agreeable. If the reasoning is wrong, say so and say why.
Do not restate the claim back as agreement.

You have read-only access to the repository at the working directory. Prefer READING the code
over reasoning about it, and cite `file:line` for anything you assert about this repo.

Answer these, in order:

1. Your verdict on the claim: correct, wrong, or correct-but-for-the-wrong-reason. Give the
   reasoning that actually decides it — not a summary of the claim's own reasoning.
2. Anything the claim states as verified that you can CHECK: check it, and say plainly whether
   you confirm or contradict it, quoting what you read.
3. The strongest argument AGAINST your own verdict.
4. What was NOT checked that could flip the answer. Be concrete and specific to this repo.
5. If the real issue is somewhere other than where the claim is looking, say so.

Say which of your statements you actually executed and which you reasoned about.

--- THE CLAIM UNDER REVIEW ---

FRAME
  cat "$CLAIM"
} > "$PROMPT" || die "cannot write prompt to $PROMPT"

# Both the tier AND the effort, always: profile defaults are per-machine and luna's is `low`.
# --policy-version is REQUIRED by run-codex.sh since 2026-08-30; without it the launcher
# refuses the call as a stale-session launch (measured 2026-09-01, rc=2).
"$RUNNER" --policy-version 2026-08-30-regression-v1 "$PROMPT" "$VERDICT" "$LOG" "$WORKDIR" \
  -p "$TIER" -c model_reasoning_effort="high"
rc=$?

# The banner is the measurement; the flag above is only a request.
banner_model="$(grep -a -m1 -E '^.?\[?[0-9;]*m?model:' "$LOG" 2>/dev/null | tr -d '\033' | sed 's/\[[0-9;]*m//g; s/^ *//')"
banner_effort="$(grep -a -m1 -E 'reasoning effort:' "$LOG" 2>/dev/null | tr -d '\033' | sed 's/\[[0-9;]*m//g; s/^ *//')"

if [ "$rc" -ne 0 ]; then
  printf 'ask-codex: codex FAILED (rc=%d). log: %s\n' "$rc" "$LOG" >&2
  exit 1
fi

printf 'verdict : %s\n' "$VERDICT"
printf 'log     : %s\n' "$LOG"
printf 'ran as  : %s / %s   (verified from the banner, not the flag)\n' \
  "${banner_model:-UNREADABLE}" "${banner_effort:-UNREADABLE}"
[ -n "$banner_model" ] || printf 'ask-codex: WARNING - could not read the tier from the log; do not report a tier you did not verify.\n' >&2
