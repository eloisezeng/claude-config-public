#!/usr/bin/env bash
# Notification hook (macOS): log every event, mute completion/noise types,
# and mute the idle_prompt ("Claude is waiting for your input") chime while
# THIS session still has background tasks running — that state is written
# per-Stop by stop-event.sh, because only Stop payloads carry
# background_tasks. Permission prompts and unknown types always ring
# (fail OPEN) so a wrong guess can't silently kill a real alert.
# CLAUDE_NOTIF_DEBUG=1 prints the decision instead of ringing (for tests).
IN=$(cat)
printf '%s %s\n' "$(date +%FT%T)" "$IN" >> "$HOME/.claude/hook-events.log"

case "$IN" in
  *agent_completed*|*task_completed*|*auth_success*|*elicitation_complete*|*elicitation_response*) exit 0 ;;
esac

case "$IN" in
  *'"notification_type":"idle_prompt"'*)
    SID=$(printf '%s' "$IN" | sed -n 's/.*"session_id":"\([A-Za-z0-9-]*\)".*/\1/p' | head -1)
    if [ -n "$SID" ] && [ -f "$HOME/.claude/session-state/$SID.bg" ]; then
      RUNNING=$(tr -d '[:space:]' < "$HOME/.claude/session-state/$SID.bg" 2>/dev/null)
      case "$RUNNING" in ''|*[!0-9]*) RUNNING=0 ;; esac
      if [ "$RUNNING" -gt 0 ]; then
        printf '%s {"hook_event_name":"NotificationSuppressed","notification_type":"idle_prompt","session_id":"%s","running_bg_tasks":%s}\n' \
          "$(date +%FT%T)" "$SID" "$RUNNING" >> "$HOME/.claude/hook-events.log"
        [ -n "${CLAUDE_NOTIF_DEBUG:-}" ] && echo "SUPPRESS (bg tasks running: $RUNNING)"
        exit 0
      fi
    fi
    ;;
esac

if [ -f "$HOME/.claude/.enable-stop-notif" ]; then
  if [ -n "${CLAUDE_NOTIF_DEBUG:-}" ]; then
    echo "RING"
  else
    osascript -e 'display notification "Claude needs your input" with title "Claude Code" sound name "Glass"' >/dev/null 2>&1 || true
  fi
fi
exit 0
