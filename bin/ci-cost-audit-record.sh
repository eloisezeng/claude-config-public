#!/usr/bin/env bash
# Record that a CI cost audit actually COMPLETED for the repo containing the current
# directory, so hooks/ci-cost-reaudit-prompt.mjs does not raise it again for a month.
#
# Run this only when an audit has genuinely finished and its findings have been reported.
# Recording an audit that did not happen sets the window forward and buys silence rather
# than a measurement, which is the failure this whole mechanism exists to prevent.
#
# Usage:  ci-cost-audit-record.sh [note...]
# The note is free text kept beside the timestamp, e.g. a PR number or a measured figure.

set -euo pipefail

STATE_DIR="$HOME/.claude/ops/ci-cost-audits"

if ! common=$(git rev-parse --git-common-dir 2>/dev/null); then
  echo "ci-cost-audit-record: not inside a git repository, so there is no repo to record against." >&2
  exit 1
fi

# Match the hook's key exactly: the realpath of the common git dir, so every worktree of
# one repository shares a single record.
abs=$(cd "$(dirname "$common")" && pwd -P)/$(basename "$common")
abs=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$abs")
top=$(git rev-parse --show-toplevel)
key=$(printf '%s' "$abs" | sed 's/[^A-Za-z0-9][^A-Za-z0-9]*/-/g; s/^-//; s/-$//' | tail -c 121)

mkdir -p "$STATE_DIR"
note="${*:-}"

python3 - "$STATE_DIR/$key.json" "$top" "$note" <<'PY'
import json, os, sys, time
path, top, note = sys.argv[1], sys.argv[2], sys.argv[3]
state = {}
if os.path.exists(path):
    try:
        state = json.load(open(path))
    except Exception:
        state = {}
now = int(time.time() * 1000)
state["repo"] = top
state["lastAuditedAt"] = now
if note:
    state.setdefault("audits", []).append({"at": now, "note": note})
json.dump(state, open(path, "w"), indent=2)
print(f"recorded a completed CI cost audit for {top}")
print(f"the re-audit reminder is now quiet for 30 days ({path})")
PY
