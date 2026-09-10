#!/usr/bin/env bash
# Machine-local fallback watcher for the claude-config repo on this cluster:
# systemd user units have no bus here and crontab is PAM-blocked, so a
# detached daemon runs sync.sh once a minute (sync.sh itself no-ops when
# clean and holds its own lock, so overlap with the SessionStart hook is safe).
#
# Launched from inside a scheduler allocation it dies with that allocation
# (slurmstepd kills the job cgroup — setsid does not escape it); the tracked
# SessionStart sync.sh hook remains the durable baseline. Relaunch from a
# login node for a longer-lived instance.
#
# Single instance: check `pgrep -fa claude-config-sync-daemon.sh` BEFORE
# launching (the PID file can go stale — see round5b-autosync-daemon memory).
#   setsid nohup bash ~/.claude/hooks/claude-config-sync-daemon.sh \
#     >/dev/null 2>&1 </dev/null &
# The repo is NOT at a path typed in here. install.sh links this script into
# ~/.claude/hooks/, so resolve our own location through that link and take the
# parent of hooks/ -- the daemon then syncs the checkout it was installed from,
# wherever that is (~/claude-config on the cluster, ~/dotfiles/claude on the
# laptop). readlink -f is GNU-only, so the loop below is the portable form.
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do
  _link="$(readlink "$SELF")"
  case "$_link" in
    /*) SELF="$_link" ;;
     *) SELF="$(dirname "$SELF")/$_link" ;;
  esac
done
REPO_DIR="$(cd "$(dirname "$SELF")/.." && pwd -P)"
SYNC="$REPO_DIR/sync.sh"
# Fail CLOSED. A daemon that cannot find sync.sh must not spin once a minute
# logging nothing while every check reads "the watcher is running".
if [ ! -f "$SYNC" ]; then
  printf 'claude-config-sync-daemon: no sync.sh at %s -- refusing to start.\n' "$SYNC" >&2
  exit 1
fi

PIDFILE="$HOME/.claude/hooks/claude-config-sync.pid"
LOG="$HOME/.claude/hooks/claude-config-sync.log"
echo $$ > "$PIDFILE"
echo "[$(date '+%F %T')] daemon start pid=$$ host=$(hostname)" >> "$LOG"
while true; do
  bash "$SYNC" >> "$LOG" 2>&1
  sleep 60
done
