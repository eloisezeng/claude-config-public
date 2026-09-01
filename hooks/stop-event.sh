#!/usr/bin/env bash
# Stop hook (macOS): log the event, then record this session's count of
# RUNNING background tasks (shell + subagent) to ~/.claude/session-state/.
# notification-event.sh reads that count to mute the idle_prompt chime while
# agents are still working — the Notification payload itself has no
# background_tasks field, only the Stop payload does.
# The "Response ready" turn-end chime stays gated on a sentinel that is
# deliberately absent (see memories/global/notify-on-response.md).
IN=$(cat)
printf '%s %s\n' "$(date +%FT%T)" "$IN" >> "$HOME/.claude/hook-events.log"

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

[ -f "$HOME/.claude/.enable-response-ready-notif" ] && osascript -e 'display notification "Response ready" with title "Claude Code" sound name "Glass"' >/dev/null 2>&1 || true
exit 0
