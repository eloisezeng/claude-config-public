#!/usr/bin/env bash
#
# Portable bidirectional sync for the Claude config repo (macOS + Linux):
#   1. commit any local changes,
#   2. pull (rebase) ONLY if the remote advanced since our last fetch,
#   3. push if ahead.
#
# Triggered by:
#   - Linux: the systemd user path unit claude-config-sync.path (on file
#            change) and an async Claude SessionStart hook.
#   - macOS: the launchd agent com.your-org.claude-config-autopush on file
#            change (WatchPaths -> instant push); remote changes are pulled
#            by the async SessionStart hook.
#
# Safe to run anytime: no-ops when clean and already up to date, and serializes
# itself with an atomic mkdir lock (macOS has no flock) so overlapping triggers
# can't race the git index.
#
# FAILURES ARE NEVER SWALLOWED. This script runs unattended, so a git error that
# scrolls past silently is an error nobody ever sees — the repo then drifts for
# days while every session believes it is synced. Every git step is checked; a
# failure is logged with its stderr, raised as a desktop notification, and left
# in place (no auto-abort) so the half-finished state can be diagnosed. Exit
# status is non-zero on any failure.

# Schedulers (launchd / systemd) give a minimal PATH; cover both OSes' tool dirs.
export PATH="/opt/homebrew/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"

# Repo is wherever this script lives (portable; no hard-coded home path).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO" || exit 1

# The log lives OUTSIDE the repo: a log file inside the watched tree would
# re-trigger the watcher on every write and get committed as config.
case "$(uname)" in
  Darwin) LOG_DIR="$HOME/Library/Logs" ;;
  *)      LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}" ;;
esac
mkdir -p "$LOG_DIR" 2>/dev/null
LOG_FILE="$LOG_DIR/claude-config-sync.log"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s %s\n' "$(ts)" "$1" >> "$LOG_FILE"; }

# A failure must be visible without anyone thinking to open a log file.
notify() {
  case "$(uname)" in
    Darwin)
      osascript -e "display notification \"$1\" with title \"Claude config sync FAILED\"" \
        >/dev/null 2>&1 ;;
    *)
      command -v notify-send >/dev/null 2>&1 \
        && notify-send -u critical "Claude config sync FAILED" "$1" >/dev/null 2>&1
      # Headless/cluster fallback (2026-08-19, learned the hard way): over SSH a
      # desktop notification goes NOWHERE, which is how a broken sync stayed
      # silent for three days while the fix for it sat unreachable on the
      # remote. On non-Mac boxes, also EMAIL the failure — rate-limited to one
      # mail per distinct message per 12h so a recurring failure cannot spam.
      if command -v mail >/dev/null 2>&1; then
        local stamp
        stamp="${TMPDIR:-/tmp}/claude-config-sync-mail.$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
        local last=0 now
        now="$(date +%s)"
        [ -e "$stamp" ] && last="$(stat -c %Y "$stamp" 2>/dev/null || echo 0)"
        if [ $(( now - last )) -gt 43200 ]; then
          { printf 'claude-config sync FAILED on %s\n\n%s\n\nlog: %s\n\n' \
              "$(hostname)" "$1" "$LOG_FILE"
            tail -20 "$LOG_FILE" 2>/dev/null; } \
            | mail -s "claude-config sync FAILED on $(hostname)" \
                you@example.edu >/dev/null 2>&1 && touch "$stamp"
        fi
      fi ;;
  esac
  return 0
}

# Report, notify, and leave the tree exactly as it is for inspection.
fail() {
  local msg="$1" detail="${2:-}"
  log "FAILED: $msg"
  [ -n "$detail" ] && printf '%s\n' "$detail" | sed 's/^/    /' >> "$LOG_FILE"
  echo "sync.sh: $msg" >&2
  [ -n "$detail" ] && echo "$detail" >&2
  echo "sync.sh: repo left as-is for inspection: $REPO" >&2
  echo "sync.sh: log: $LOG_FILE" >&2
  notify "$msg — see $LOG_FILE"
  exit 1
}

# A macOS desktop toast is not a channel that reaches an unattended operator: it
# shows for a few seconds and is gone, and the non-Mac EMAIL fallback below has no
# Mac equivalent (postfix here is unconfigured, so `mail` would drop it silently --
# a fake fix). Measured 2026-09-01: this script correctly detected a broken backup
# and raised 8 toasts across two days while 105 commits sat unbacked, unnoticed.
#
# So ALSO write an operational lane. ~/.claude/ops/lanes/*.md is injected into every
# new Claude session's context by inject-ops-lanes.sh, which means a broken backup is
# restated to the operator at the start of every session until it is fixed -- a
# channel that persists instead of one that expires.
OPS_DIR="${CLAUDE_OPS_DIR:-$HOME/.claude/ops}"
OPS_LANE="$OPS_DIR/lanes/config-backup-broken.md"

ops_lane_open() {
  [ -d "$OPS_DIR/lanes" ] || return 0
  local unbacked
  unbacked="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
  cat > "$OPS_LANE" <<LANE
---
lane: config-backup-broken
status: open
owner: none
project: $REPO
objective: The Claude config auto-push is BROKEN and $unbacked commits are unbacked -- $1
pointer: $LOG_FILE
updated: $(date '+%Y-%m-%d')
---
Written automatically by sync.sh. This lane closes itself on the next successful push.

The desktop notification for this fires at most once every 6h and does not persist;
this lane is the channel that does. Diagnose with:

    cd "$REPO" && git push        # see the real error
    tail -40 "$LOG_FILE"

Do NOT close this lane by hand while the push still fails.
LANE
  log "wrote ops lane $OPS_LANE"
}

# --- credential self-repair -------------------------------------------------
# 2026-09-01: this repo stopped backing up for four days (105 commits) because
# the machine-wide keychain entry for github.com belonged to a DIFFERENT GitHub
# account of the same operator, which has no access here. GitHub answers such a
# request with "Repository not found" -- byte-identical to a deleted repo.
#
# The durable half of that fix cannot live in .git/config: that file is untracked,
# so it is lost on a re-clone and never reaches a second machine. It lives HERE
# instead. On an auth failure, ask the `gh` CLI for a token belonging to the
# account that OWNS the remote; if it has one, wire a repo-local helper that asks
# gh at call time. No token is ever written to disk, and the machine-wide keychain
# is left alone.
#
# Returns 0 if it changed something and the caller should retry, 1 otherwise.
credential_self_repair() {
  local url owner tok
  url="$(git remote get-url "${1:-origin}" 2>/dev/null)" || return 1
  case "$url" in
    https://github.com/*) ;;
    *) return 1 ;;                      # ssh or a local path: nothing to repair
  esac
  owner="${url#https://github.com/}"; owner="${owner%%/*}"
  [ -n "$owner" ] || return 1
  command -v gh >/dev/null 2>&1 || { log "credential repair: gh CLI not installed"; return 1; }
  tok="$(gh auth token --user "$owner" 2>/dev/null)" || tok=""
  [ -n "$tok" ] || { log "credential repair: gh has no token for account '$owner'"; return 1; }
  tok=""                                # proved one exists; never keep it around

  # Already wired? Then the credential is not what is wrong -- do not loop.
  # Has a gh-backed helper already been wired FOR THIS OWNER? A bare grep for
  # "gh auth token" answers a different question: it is also true of a helper
  # wired for a DIFFERENT account, which is precisely the case a repair exists to
  # fix -- so the repair declined to act and logged a message asserting an owner
  # its own predicate had never checked. Reachable whenever the remote's owner
  # changes after a previous repair (a `git remote set-url` is the write site).
  # Match the owner, so the mention is the property.
  if git config --local --get-all credential.helper 2>/dev/null \
     | grep -qF -- "gh auth token --user $owner"; then
    log "credential repair: a gh-backed helper for '$owner' is already wired; the failure is something else"
    return 1
  fi
  # Reset the inherited helper list FIRST. git uses the first helper that answers,
  # so a stale system keychain entry would shadow this one forever.
  git config --local --unset-all credential.helper 2>/dev/null || true
  git config --local --add credential.helper ''
  # Built by substitution rather than nested printf so the stored value is
  # readable in .git/config and obviously contains no token.
  local helper
  helper='!f(){ [ "$1" = get ] && printf "username=OWNER\npassword=%s\n" "$(gh auth token --user OWNER)"; }; f'
  git config --local --add credential.helper "${helper//OWNER/$owner}"
  git config --local --add credential.helper osxkeychain
  git config --local "credential.https://github.com.username" "$owner"
  log "credential repair: wired a gh-backed helper for account '$owner'; retrying"
  return 0
}

ops_lane_close() {
  [ -f "$OPS_LANE" ] || return 0
  # Only ever flips open -> closed; never deletes, so the record survives.
  if grep -q '^status: open' "$OPS_LANE" 2>/dev/null; then
    local tmp="$OPS_LANE.tmp.$$"
    sed 's/^status: open$/status: closed/' "$OPS_LANE" > "$tmp" && mv "$tmp" "$OPS_LANE"
    log "closed ops lane $OPS_LANE (push succeeded)"
  fi
}

# Debounce: editors often write a temp file then rename, firing WatchPaths in a
# burst. A brief pause lets the dust settle before we read the tree.
sleep 1

# Serialize with an atomic mkdir lock OUTSIDE the repo (a lock inside the watched
# tree would re-trigger macOS's recursive fsevents in a loop). If another run
# holds it, let that one handle this round.
LOCKDIR="${TMPDIR:-/tmp}/claude-config-sync.lock.d"
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# 0. Refuse to touch a repo that is already mid-operation. Committing or pulling
#    on top of an interrupted rebase/merge compounds the damage and destroys the
#    evidence of what went wrong.
GIT_DIR_PATH="$(git rev-parse --git-dir 2>/dev/null)" || fail "not a git repo: $REPO"
for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if [ -e "$GIT_DIR_PATH/$state" ]; then
    fail "a previous git operation is unfinished ($state); resolve it by hand, then sync will resume"
  fi
done

# 1. Commit local changes, if any. Cluster nodes have no git identity configured
#    (and config edits are off-limits), which attributes auto-commits to the
#    hostname — fall back to the real identity per-command, only when unset.
IDENT=()
git config user.email >/dev/null 2>&1 \
  || IDENT=(-c user.name="the user Zeng" -c user.email="you@example.com")
if [ -n "$(git status --porcelain)" ]; then
  if ! err="$(git add -A 2>&1)"; then
    fail "git add failed" "$err"
  fi
  if ! err="$(git "${IDENT[@]}" commit -q -m "auto: sync config $(ts)" 2>&1)"; then
    fail "git commit failed" "$err"
  fi
  log "committed $(git rev-parse --short HEAD)"
fi

# 2. Pull ONLY if the remote actually advanced since our last fetch (i.e. a new
#    push was made elsewhere). `git ls-remote` is a light network call that
#    returns the remote branch tip without downloading objects, so an idle tick
#    costs one ref lookup instead of a full pull + rebase. We pull when that tip
#    differs from both our HEAD and our last-known remote ref. --rebase keeps
#    history linear; --autostash guards any dirty state.
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
remote="$(git config "branch.$branch.remote" 2>/dev/null || echo origin)"
head_sha="$(git rev-parse HEAD 2>/dev/null)"
tracked_sha="$(git rev-parse "$remote/$branch" 2>/dev/null || true)"

# A network failure is not a sync failure — the machine may simply be offline,
# which is normal and must not raise an alarm. Skip the remote half instead.
if ! ls_out="$(git ls-remote "$remote" "refs/heads/$branch" 2>&1)"; then
  # A genuine network outage is normal and must stay quiet. An AUTH or
  # OWNERSHIP failure is the opposite: the repo has stopped backing up and
  # will keep not backing up until a human acts. Both arrive here, so the
  # error text is the only thing that tells them apart.
  #
  # 2026-08-30: a "Repository not found." (the remote had moved out from under
  # this credential) was classified as "offline" and skipped SILENTLY 505 times
  # across two days, while 33 commits -- 14 memory files, 2 skills, a hook and
  # CLAUDE.md -- sat unbacked. That is exactly the silent drift this script's
  # header promises never to allow, produced by the one branch that returns 0.
  case "$ls_out" in
    *"Repository not found"*|*"Authentication failed"*|*"could not read Username"*|\
    *"Permission denied"*|*"access denied"*|*"Invalid username or password"*|*"403"*)
      log "AUTH/OWNERSHIP FAILURE (not an outage): $(printf '%s' "$ls_out" | head -1)"
      # Try to fix the credential ourselves before waking anybody up. Only a
      # SUCCESSFUL retry counts as recovery -- a repair that wires a helper the
      # remote still refuses must fall through to the alarm, not read as green.
      auth_recovered=0
      if credential_self_repair "$remote"; then
        if ls_retry="$(git ls-remote "$remote" "refs/heads/$branch" 2>&1)"; then
          log "credential repair SUCCEEDED; backup resumed"
          ls_out="$ls_retry"; auth_recovered=1
          ops_lane_close
        else
          ls_out="$ls_retry"
        fi
      fi
      if [ "$auth_recovered" = "0" ]; then
      # This fires on every file change, so alarm at most once every 6h --
      # loud enough to be seen, not so loud it trains her to ignore it.
      ops_lane_open "$(printf '%s' "$ls_out" | head -1)"
      stamp="${TMPDIR:-/tmp}/claude-config-sync-authfail.stamp"
      last=0; now="$(date +%s)"
      [ -e "$stamp" ] && last="$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null || echo 0)"
      if [ "$(( now - last ))" -gt 21600 ]; then
        touch "$stamp"
        fail "config backup BROKEN: $remote refuses this credential. Not an outage -- $(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?') commits unbacked." "$ls_out"
      fi
      echo "sync.sh: config backup broken (auth/ownership); see $LOG_FILE" >&2
      exit 1
      fi ;;
  esac
  if [ "${auth_recovered:-0}" = "1" ]; then
    remote_sha="$(printf '%s' "$ls_out" | awk 'NR==1{print $1}')"
  else
  log "offline or remote unreachable; skipped pull/push ($(printf '%s' "$ls_out" | head -1))"
  exit 0
  fi
fi
remote_sha="${remote_sha:-$(printf '%s' "$ls_out" | awk 'NR==1{print $1}')}"

if [ -n "$remote_sha" ] && [ "$remote_sha" != "$head_sha" ] && [ "$remote_sha" != "$tracked_sha" ]; then
  if ! err="$(git pull --rebase --autostash -q 2>&1)"; then
    # Deliberately NOT `git rebase --abort`: the conflicted state is the only
    # record of what diverged, and discarding it hides a real collision between
    # two machines editing the same file.
    fail "git pull --rebase failed (likely a conflict with another machine)" "$err"
  fi
  log "pulled (remote advanced) -> $(git rev-parse --short HEAD)"
fi

# 3. Push only if the local branch is ahead of its upstream.
ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
if [ "$ahead" -gt 0 ]; then
  # This repo carries memories, transcripts, hook wiring and machine paths. Pushing it to a
  # WORLD-READABLE remote publishes all of that at once, and this script runs unattended from
  # launchd or systemd -- so the moment nobody is watching is exactly the moment it must refuse.
  #
  # The verdict comes from bin/remote-visibility.sh, which asks the only question that matters
  # (can an UNAUTHENTICATED reader fetch this remote's refs?) and answers local, private, public
  # or unknown. Only local and private may proceed. A missing, unreadable or inconclusive helper
  # yields `unknown`, and unknown FAILS: "we could not tell" and "it is safe" are not the same
  # fact, and a guard that passes when its own probe broke is not a guard.
  remote_url="$(git remote get-url "$remote" 2>/dev/null || true)"
  visibility=unknown
  if [ -z "$remote_url" ]; then
    vis_why="no url is configured for remote '$remote'"
  elif [ ! -f "$REPO/bin/remote-visibility.sh" ]; then
    vis_why="$REPO/bin/remote-visibility.sh is missing; install it alongside sync.sh"
  else
    visibility="$(bash "$REPO/bin/remote-visibility.sh" "$remote_url" 2>>"$LOG_FILE" || echo unknown)"
    visibility="$(printf '%s' "$visibility" | tr -d '[:space:]')"
    [ -n "$visibility" ] || visibility=unknown
    vis_why="bin/remote-visibility.sh classified the remote as '$visibility'"
  fi
  case "$visibility" in
    local|private) ;;
    *)
      if [ "${CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH:-0}" = "1" ]; then
        log "WARNING: pushing to $remote_url regardless: $vis_why (CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH=1)"
      else
        fail "refusing to push: the remote is not private" \
"remote:  ${remote_url:-<unset>}
verdict: $visibility
reason:  $vis_why

This repo is only ever pushed to a private remote or a local path. Point it at a private
remote, or set CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH=1 for one run if this remote really is
meant to be world-readable."
      fi ;;
  esac
  if ! push_err="$(git push -q 2>&1)"; then
    # Raced with another machine's push: rebase on the new tip and retry once.
    if ! pull_err="$(git pull --rebase --autostash -q 2>&1)"; then
      fail "push rejected, and the follow-up rebase failed" "$push_err
$pull_err"
    fi
    if ! push_err2="$(git push -q 2>&1)"; then
      fail "push failed after rebasing on the new remote tip" "$push_err2"
    fi
  fi
  log "pushed $(git rev-parse --short HEAD)"
  ops_lane_close
fi

exit 0
