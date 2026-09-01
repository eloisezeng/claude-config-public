#!/usr/bin/env bash
# Notification hook (macOS): log every event, then route by notification_type.
#
# 2026-08-30 — the user's "go local" decision. agent_needs_input and
# agent_completed are NOT separate hook events; they are notification_type
# values delivered on THIS hook, and they already fire heavily (measured in
# ~/.claude/hook-events.log: 271 and 585). The built-in switches for them
# (inputNeededNotifEnabled, agentPushNotifEnabled) push to MOBILE -- "Push to
# mobile when a permission prompt or question is waiting" / "Allow Claude to
# push proactive mobile notifications" -- so the LOCAL surface is here.
# Until now this hook muted agent_completed outright (it was in the same
# blanket case as task_completed) and gave agent_needs_input a content-free
# "Claude needs your input" chime naming neither the session nor the ask,
# even though the payload carries a usable summary. Both now ring with the
# payload's own message and the project it came from.
#
# TWO GATES, deliberately independent:
#   ~/.claude/.enable-fleet-notif  -> agent_needs_input + agent_completed
#   ~/.claude/.enable-stop-notif   -> the generic ring for everything else
# Separate so turning the generic chime off cannot silently kill the fleet
# events. Permission prompts and unknown types still ring (fail OPEN) so a
# wrong guess can't kill a real alert.
# CLAUDE_NOTIF_DEBUG=1 prints the decision instead of ringing (for tests).
IN=$(cat)
printf '%s %s\n' "$(date +%FT%T)" "$IN" >> "$HOME/.claude/hook-events.log"

# Pass text to osascript as ARGUMENTS, never interpolated into the script
# source: a message containing a quote would otherwise break the AppleScript
# (or inject into it). argv keeps it data.
ring() { # ring <message> <title> <sound>
  osascript -e 'on run argv' \
            -e 'display notification (item 1 of argv) with title (item 2 of argv) sound name (item 3 of argv)' \
            -e 'end run' -- "$1" "$2" "$3" >/dev/null 2>&1 || true
}

NTYPE=$(printf '%s' "$IN" | sed -n 's/.*"notification_type":"\([A-Za-z0-9_]*\)".*/\1/p' | head -1)

case "$NTYPE" in
  agent_needs_input|agent_completed)
    [ -f "$HOME/.claude/.enable-fleet-notif" ] || { [ -n "${CLAUDE_NOTIF_DEBUG:-}" ] && echo "FLEET-OFF ($NTYPE)"; exit 0; }
    # Decode with python3 (handles \uXXXX and embedded quotes); if it is not
    # on the scheduler's PATH, fall back to a plain-text label rather than
    # dropping the alert.
    MSG=$(printf '%s' "$IN" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); m=" ".join((d.get("message") or "").split())
    print(m[:180] if m else "(no message)")
except Exception:
    print("")' 2>/dev/null)
    [ -n "$MSG" ] || MSG="(unreadable payload -- see ~/.claude/hook-events.log)"
    PROJ=$(printf '%s' "$IN" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p' | head -1)
    PROJ=${PROJ##*/}; [ -n "$PROJ" ] || PROJ="claude"
    if [ "$NTYPE" = "agent_needs_input" ]; then
      TITLE="Needs you - $PROJ"; SOUND="Glass"
    else
      TITLE="Finished - $PROJ";  SOUND="Pop"
    fi
    if [ -n "${CLAUDE_NOTIF_DEBUG:-}" ]; then echo "RING-FLEET [$TITLE] $MSG"; else ring "$MSG" "$TITLE" "$SOUND"; fi
    exit 0 ;;
esac

case "$IN" in
  *task_completed*|*auth_success*|*elicitation_complete*|*elicitation_response*) exit 0 ;;
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
    ring "Claude needs your input" "Claude Code" "Glass"
  fi
fi
exit 0
