#!/usr/bin/env bash
# Stop hook (macOS): log the event, then record this session's count of
# RUNNING background tasks (shell + subagent) to ~/.claude/session-state/.
# notification-event.sh reads that count to mute the idle_prompt chime while
# agents are still working — the Notification payload itself has no
# background_tasks field, only the Stop payload does.
# The "Response ready" turn-end chime is gated on ~/.claude/.enable-response-ready-notif
# and, since 2026-09-04, is ON -- muted while background tasks are still running
# (see the block at the foot of this file and memories/global/notify-on-response.md).
#
# Not redundant with Claude Code's built-in turn-end notification: the built-in
# LOCAL channel emits only a terminal escape sequence, which in VS Code resolves
# to nothing at all. The measurement is in hooks/notification-event.sh.
IN=$(cat)
printf '%s %s\n' "$(date +%FT%T)" "$IN" >> "$HOME/.claude/hook-events.log"

RING_LIB="$(dirname "$0")/notif-ring.sh"
if [ -r "$RING_LIB" ]; then
  . "$RING_LIB"
else
  printf '%s {"hook_event_name":"NotifRingLibMissing","hook":"stop-event","path":"%s"}\n' \
    "$(date +%FT%T)" "$RING_LIB" >> "$HOME/.claude/hook-events.log"
  echo "stop-event.sh: cannot source $RING_LIB - the turn-end chime is DEAD" >&2
  exit 1
fi

STATE_DIR="$HOME/.claude/session-state"
mkdir -p "$STATE_DIR"

SID=$(printf '%s' "$IN" | sed -n 's/.*"session_id":"\([A-Za-z0-9-]*\)".*/\1/p' | head -1)

# Hooks don't get the interactive shell's PATH; node lives under nvm.
NODE=$(command -v node 2>/dev/null || true)
if [ -z "$NODE" ]; then
  for c in "$HOME"/.nvm/versions/node/*/bin/node /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -x "$c" ] && NODE="$c"
  done
fi

if [ -n "$SID" ]; then
  if [ -n "$NODE" ]; then
    # On any parse/write failure, drop the state file so the notification
    # side fails OPEN (rings) instead of staying muted on stale state.
    printf '%s' "$IN" | "$NODE" -e '
      let raw = "";
      process.stdin.on("data", d => (raw += d));
      process.stdin.on("end", () => {
        const p = JSON.parse(raw);
        const tasks = Array.isArray(p.background_tasks) ? p.background_tasks : [];
        const running = tasks.filter(t => t && t.status === "running").length;
        require("fs").writeFileSync(process.argv[1], running + "\n");
      });
    ' "$STATE_DIR/$SID.bg" 2>/dev/null || rm -f "$STATE_DIR/$SID.bg"
  else
    rm -f "$STATE_DIR/$SID.bg"
  fi
fi
find "$STATE_DIR" -name '*.bg' -mtime +7 -delete 2>/dev/null || true

# --- turn-end "your turn to prompt" chime -------------------------------------
# Enabled 2026-09-04 on the user's "turn on my chime notifications". It was off
# before for TWO reasons, and enabling it required fixing both first:
#
#   1. It rang through `display notification ... sound name`, so the chime played
#      only if macOS chose to show the banner -- which it does not here. Turning
#      the gate on would have produced NOTHING, indistinguishable from the gate
#      not working. It now rings through the shared ring() (afplay), which needs
#      no notification permission.
#   2. It had no mute, so it fired at EVERY turn end including yields with
#      background agents still working -- the exact noise reported 2026-08-05
#      ("u chime even when background agents are still running"). It now reuses
#      the count computed directly above, which is the same signal
#      notification-event.sh uses to mute idle_prompt. The bell means "your turn
#      to prompt", so it must not ring while something is still working.
#
# Fails OPEN, matching notification-event.sh: an unreadable or absent count rings
# rather than staying silent, because a wrong guess must not kill a real alert.
if [ -f "$HOME/.claude/.enable-response-ready-notif" ]; then
  RUNNING=0
  if [ -n "$SID" ] && [ -f "$STATE_DIR/$SID.bg" ]; then
    RUNNING=$(tr -d '[:space:]' < "$STATE_DIR/$SID.bg" 2>/dev/null)
    case "$RUNNING" in ''|*[!0-9]*) RUNNING=0 ;; esac   # unparseable -> ring
  fi
  if [ "$RUNNING" -gt 0 ]; then
    printf '%s {"hook_event_name":"StopBellSuppressed","session_id":"%s","running_bg_tasks":%s}\n' \
      "$(date +%FT%T)" "$SID" "$RUNNING" >> "$HOME/.claude/hook-events.log"
  elif [ -n "${CLAUDE_NOTIF_DEBUG:-}" ]; then
    echo "RING-STOP"
  else
    ring "Response ready - your turn to prompt" "Claude Code" "Glass"
  fi
fi
exit 0
