#!/usr/bin/env bash
# Machine-local notification helper for the tracked Linux settings hooks.
# Usage: notify.sh <title> [message]      (hook JSON payload arrives on stdin)
#
# This host is a headless SSH cluster node reached from a VS Code Remote-SSH
# integrated terminal. That terminal supports neither OSC 9 nor OSC 777, so no
# escape sequence can raise an OS-level notification -- verified empirically,
# only a plain BEL and visible text get through. So there are two channels:
#
#   1. terminal bell  -- reaches the user only while she is looking at the window
#   2. email          -- the channel that actually works when she has walked away
#
# Always exits 0 so a hook failure can never break a turn.

set -u

title="${1:-Claude Code}"
message="${2:-}"

# Hooks deliver their JSON payload on stdin. Bound the read: if stdin is ever a
# terminal rather than a pipe, an unguarded `cat` would hang the turn forever.
payload=$(timeout 2 cat 2>/dev/null || true)
jqr() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }

event=$(jqr '.hook_event_name')
sid=$(jqr '.session_id')
cwd=$(jqr '.cwd')
transcript=$(jqr '.transcript_path')
notif_type=$(jqr '.notification_type')

# Diagnostic trail. Whether an async hook is handed its JSON on stdin is the one
# thing that cannot be established by reading the config, and an empty payload
# would silently disable email rather than fail loudly -- so record every call.
log="$HOME/.claude/state/notify.log"
mkdir -p "$(dirname "$log")" 2>/dev/null
logline() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$log" 2>/dev/null; }
if [ -f "$log" ] && [ "$(wc -c < "$log" 2>/dev/null)" -gt 262144 ] 2>/dev/null; then
  tail -n 200 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log" 2>/dev/null
fi
logline "call arg1=${title} payload_bytes=${#payload} event=${event:-NONE} sid=${sid:-NONE}"

# ---------------------------------------------------------------------------
# Bell gating: ring only when the user actually has to act (2026-08-14 request:
# "notify me when there are no background agents running and you need me to
# prompt you"). Ported from the Mac's stop-event.sh / notification-event.sh.
#
# Only Stop payloads carry background_tasks, so each Stop records this
# session's running-task count to ~/.claude/session-state/<sid>.bg and the
# later idle_prompt Notification reads it back. Every failure path fails OPEN
# (rings / clears state) so a wrong guess can't silently kill a real alert.
# ---------------------------------------------------------------------------
state_dir="$HOME/.claude/session-state"
sid_state_key=$(printf '%s' "${sid:-nosession}" | tr -c 'A-Za-z0-9._-' '_')
bg_file="$state_dir/$sid_state_key.bg"

ring=1
case "$event" in
  Stop)
    mkdir -p "$state_dir" 2>/dev/null
    running=$(jqr '[.background_tasks[]? | select(.status == "running")] | length')
    case "$running" in
      ''|*[!0-9]*) rm -f "$bg_file" 2>/dev/null; running=0 ;;  # fail open
      *) printf '%s\n' "$running" > "$bg_file" 2>/dev/null ;;
    esac
    [ "$running" -gt 0 ] && ring=0
    find "$state_dir" -name '*.bg' -mtime +7 -delete 2>/dev/null
    ;;
  Notification)
    case "$notif_type" in
      agent_completed|task_completed|auth_success|elicitation_complete|elicitation_response)
        ring=0 ;;  # completion/noise types: nothing for her to do
      idle_prompt)
        if [ -f "$bg_file" ]; then
          bg_running=$(tr -d '[:space:]' < "$bg_file" 2>/dev/null)
          case "$bg_running" in ''|*[!0-9]*) bg_running=0 ;; esac
          [ "$bg_running" -gt 0 ] && ring=0
        fi
        ;;
    esac  # permission prompts and unknown types always ring
    ;;
esac
logline "bell event=${event:-NONE} type=${notif_type:-NONE} ring=$ring"

# ---------------------------------------------------------------------------
# Channel 1: terminal bell
# ---------------------------------------------------------------------------
# $SSH_TTY goes stale the moment the session moves off the tty it was set on --
# e.g. `salloc` onto a compute node leaves SSH_TTY pointing at a /dev/pts that
# no longer exists, and every bell written to it is silently lost. So resolve
# the live controlling terminal by walking up the process ancestry to the
# nearest ancestor that still owns one, and only fall back to SSH_TTY.
resolve_tty() {
  local pid=$$ ppid t
  for _ in 1 2 3 4 5 6 7 8; do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$ppid" ] || [ "$ppid" -le 1 ] 2>/dev/null; then
      break
    fi
    t=$(ps -o tty= -p "$ppid" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$t" ] && [ "$t" != "?" ] && [ -w "/dev/$t" ]; then
      printf '/dev/%s' "$t"
      return 0
    fi
    pid=$ppid
  done
  if [ -n "${SSH_TTY:-}" ] && [ -w "${SSH_TTY}" ]; then
    printf '%s' "${SSH_TTY}"
    return 0
  fi
  return 1
}

# Send the BEL newline-flushed. srun/slurmstepd may line-buffer this pty's
# output, in which case a lone BEL sits in a buffer and is never forwarded --
# and the trailing newline costs nothing visually, since the fullscreen TUI
# repaints over it within milliseconds.
if [ "$ring" -eq 1 ] && tty_path=$(resolve_tty); then
  # BEL, newline-flushed. srun/slurmstepd may line-buffer this pty's output, in
  # which case a lone BEL sits in a buffer and is never forwarded -- and the
  # trailing newline costs nothing visually, since the fullscreen TUI repaints
  # over it within milliseconds.
  printf '\a\n' > "$tty_path" 2>/dev/null

  # Real OS-level desktop notifications, for terminals that support them.
  # VS Code supports NEITHER of these (verified empirically -- both produced
  # nothing) and silently swallows them, so emitting them is free here. If the
  # session is ever opened from iTerm2 / WezTerm / kitty / Windows Terminal
  # instead, notifications start working with no further change.
  osc_msg="${message:-$title}"
  printf '\033]9;%s\a' "$osc_msg" > "$tty_path" 2>/dev/null
  printf '\033]777;notify;%s;%s\a' "$title" "$osc_msg" > "$tty_path" 2>/dev/null
fi

if command -v notify-send >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  notify-send "$title" "$message" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Channel 2: email
# ---------------------------------------------------------------------------
# Email is DISABLED by default (the user's call, 2026-08-05). The whole path below
# is kept intact and working; it stays dormant only because no address is set.
# To turn it back on, export CLAUDE_NOTIFY_EMAIL=you@example.edu -- nothing
# else needs changing, and the gating below is already tested.
to="${CLAUDE_NOTIFY_EMAIL:-}"
threshold="${CLAUDE_NOTIFY_EMAIL_MIN_SECONDS:-300}"

[ -n "$to" ] || exit 0
command -v mail >/dev/null 2>&1 || exit 0

sid_key=$(printf '%s' "${sid:-nosession}" | tr -c 'A-Za-z0-9._-' '_')
stamp_file="$HOME/.claude/state/turns/$sid_key"

elapsed=""
if [ -f "$stamp_file" ]; then
  started=$(cat "$stamp_file" 2>/dev/null)
  case "$started" in
    ''|*[!0-9]*) : ;;
    *) elapsed=$(( $(date +%s) - started )) ;;
  esac
fi

# Gate on elapsed turn time so an active back-and-forth doesn't flood the inbox.
# A hard block on input always mails: The user cannot make progress until she acts,
# so that is worth interrupting her for however long the turn has been running.
notif_msg=$(jqr '.message')

send=0
case "$event" in
  Notification)
    # Claude Code fires Notification for two very different things: a hard
    # permission prompt (the user is blocked and cannot make progress until she
    # acts -- always worth an email), and merely going idle ~60s after a turn,
    # which happens after almost every turn and would mail her constantly.
    # Only the first is urgent; the second falls back to the elapsed gate.
    case "$notif_msg" in
      *ermission*|*pprove*|*llow*|*onfirm*) send=1 ;;
      *) if [ -n "$elapsed" ] && [ "$elapsed" -ge "$threshold" ]; then send=1; fi ;;
    esac
    ;;
  Stop|SubagentStop)
    if [ -n "$elapsed" ] && [ "$elapsed" -ge "$threshold" ]; then send=1; fi
    ;;
esac
logline "decide event=${event:-NONE} elapsed=${elapsed:-NONE} threshold=$threshold send=$send msg=${notif_msg:-}"
[ "$send" -eq 1 ] || exit 0

human_elapsed="unknown"
if [ -n "$elapsed" ]; then
  if [ "$elapsed" -ge 3600 ]; then
    human_elapsed="$(( elapsed / 3600 ))h $(( (elapsed % 3600) / 60 ))m"
  elif [ "$elapsed" -ge 60 ]; then
    human_elapsed="$(( elapsed / 60 ))m $(( elapsed % 60 ))s"
  else
    human_elapsed="${elapsed}s"
  fi
fi

project="unknown"
[ -n "$cwd" ] && project=$(basename "$cwd")

if [ "$event" = "Notification" ]; then
  subject="[claude] needs your input -- $project"
else
  subject="[claude] ready after $human_elapsed -- $project"
fi

# Lead with what she'd act on: the tail of what Claude actually said, so she can
# judge from her phone whether it is worth walking back to the terminal.
excerpt=""
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  excerpt=$(tail -n 400 "$transcript" 2>/dev/null | python3 -c '
import sys, json
out = ""
for line in sys.stdin:
    try:
        rec = json.loads(line)
    except Exception:
        continue
    if rec.get("type") != "assistant":
        continue
    content = (rec.get("message") or {}).get("content") or []
    parts = [c.get("text", "") for c in content
             if isinstance(c, dict) and c.get("type") == "text"]
    parts = [p for p in parts if p.strip()]
    if parts:
        out = "\n".join(parts)
print(out[:1200])
' 2>/dev/null)
fi

{
  [ -n "$message" ] && printf '%s\n\n' "$message"
  printf 'Project:   %s\n' "$cwd"
  printf 'Host:      %s\n' "$(hostname -f 2>/dev/null)"
  printf 'Turn took: %s\n' "$human_elapsed"
  printf 'Session:   %s\n' "${sid:-unknown}"
  if [ -n "$excerpt" ]; then
    printf '\n--- what Claude last said ---\n%s\n' "$excerpt"
  fi
} | mail -s "$subject" "$to" 2>/dev/null

# Clear the stamp so a repeated Stop for the same turn cannot mail twice. Only
# on Stop: an idle Notification arrives BEFORE the turn is over, and clearing
# there would erase the timing the Stop email depends on.
case "$event" in
  Stop|SubagentStop) rm -f "$stamp_file" 2>/dev/null ;;
esac

exit 0
