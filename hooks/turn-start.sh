#!/usr/bin/env bash
# Machine-local UserPromptSubmit hook.
# Stamps when this turn started, keyed by session id, so the Stop hook can tell
# a quick back-and-forth (no email) from a long unattended run (email worth it).
# Prints NOTHING: UserPromptSubmit stdout is injected into Claude's context.
# Always exits 0 so a hook failure can never break a turn.

set -u

state_dir="$HOME/.claude/state/turns"
mkdir -p "$state_dir" 2>/dev/null || exit 0

# Hooks deliver their JSON payload on stdin. Bound the read: if stdin is ever a
# terminal rather than a pipe, an unguarded `cat` would hang the turn forever.
payload=$(timeout 2 cat 2>/dev/null || true)

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || sid="nosession"
sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')

date +%s > "$state_dir/$sid" 2>/dev/null

# Prune stamps from sessions that ended long ago, so this never grows unbounded.
find "$state_dir" -type f -mtime +7 -delete 2>/dev/null

exit 0
