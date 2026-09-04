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
#
# WHY THIS IS NOT REDUNDANT WITH CLAUDE CODE'S BUILT-IN NOTIFICATIONS.
# Measured against the 2.1.258 binary, 2026-09-01. Re-measure before deleting
# this hook on the theory that the product now covers it:
#
#   * `preferredNotifChannel` is the only built-in LOCAL channel, and every one
#     of its values emits a TERMINAL ESCAPE SEQUENCE, never an OS banner:
#     iterm2 -> OSC 9, terminal_bell -> \a, kitty -> OSC 99, ghostty -> OSC 777,
#     iterm2_with_bell -> both, notifications_disabled -> nothing.
#   * Its default `auto` resolves by terminal: Apple_Terminal -> bell (and only
#     if that profile's Bell is enabled), iTerm.app -> iterm2, kitty -> kitty,
#     ghostty -> ghostty. EVERYTHING ELSE -- including VS Code's integrated
#     terminal, which is what this machine actually runs -- resolves to
#     `no_method_available` and delivers nothing at all.
#   * The binary carries no `display notification` for these events; its one
#     osascript banner is the re-authentication prompt.
#   * inputNeededNotifEnabled / agentPushNotifEnabled push to MOBILE over Remote
#     Control. A different device, not this Mac.
#
# So the built-in channel and this hook are not two ways of doing one thing: in
# VS Code the built-in surface is empty. Deleting this hook removes local
# notification entirely, and with it the idle_prompt suppression below, which
# the built-in has no equivalent for (measured in ~/.claude/hook-events.log:
# 63 of 83 idle_prompt events muted because background agents were still up).
#
# They DO double up on a terminal that raises its own OS toast from the escape
# sequence (iTerm2, kitty, ghostty). On such a terminal pick one surface: remove
# the gate files below, or set preferredNotifChannel to notifications_disabled.
# agent_needs_input used to get a content-free "Claude needs your input" chime
# naming neither the session nor the ask, even though the payload carries a
# usable summary; it now rings with the payload's own message and the project it
# came from. agent_completed rang alongside it from 2026-08-30 until 2026-09-04,
# when it was silenced again -- see the suppression case below for why.
#
# TWO GATES, deliberately independent:
#   ~/.claude/.enable-fleet-notif  -> agent_needs_input
#   ~/.claude/.enable-stop-notif   -> the generic ring for everything else
# Separate so turning the generic chime off cannot silently kill the fleet
# events. Permission prompts and unknown types still ring (fail OPEN) so a
# wrong guess can't kill a real alert.
# CLAUDE_NOTIF_DEBUG=1 prints the decision instead of ringing (for tests).
IN=$(cat)
printf '%s %s\n' "$(date +%FT%T)" "$IN" >> "$HOME/.claude/hook-events.log"

# ONE shared alert channel, defined in hooks/notif-ring.sh and IMPORTED here.
# Never copied: a second copy is exactly how this hook and stop-event.sh drifted
# apart, leaving the other one silently on the banner-only path. An unresolvable
# import RAISES -- losing every local alert must not look like a quiet success.
RING_LIB="$(dirname "$0")/notif-ring.sh"
if [ -r "$RING_LIB" ]; then
  . "$RING_LIB"
else
  printf '%s {"hook_event_name":"NotifRingLibMissing","hook":"notification-event","path":"%s"}\n' \
    "$(date +%FT%T)" "$RING_LIB" >> "$HOME/.claude/hook-events.log"
  echo "notification-event.sh: cannot source $RING_LIB - local alerts are DEAD" >&2
  exit 1
fi

NTYPE=$(printf '%s' "$IN" | sed -n 's/.*"notification_type":"\([A-Za-z0-9_]*\)".*/\1/p' | head -1)

# 2026-09-04, "the chime shouldn't ring when a background agent finishes": a
# finish asks nothing of her, and agentPushNotifEnabled already carries it to her
# phone for the walk-away case. It is suppressed EXPLICITLY, and HERE, rather than
# by dropping it from the fleet case below -- every type that falls past these
# cases reaches the fail-open generic ring at the foot of this file, so a mere
# deletion would still chime, and would do it with the wrong "Claude needs your
# input" text. Logged, so a silenced event is still countable in hook-events.log.
case "$NTYPE" in
  agent_completed)
    printf '%s {"hook_event_name":"NotificationSuppressed","notification_type":"agent_completed","reason":"a-finish-asks-nothing-of-her"}\n' \
      "$(date +%FT%T)" >> "$HOME/.claude/hook-events.log"
    [ -n "${CLAUDE_NOTIF_DEBUG:-}" ] && echo "SUPPRESS (agent_completed)"
    exit 0 ;;
esac

case "$NTYPE" in
  agent_needs_input)
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
    TITLE="Needs you - $PROJ"; SOUND="Glass"
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
