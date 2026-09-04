#!/usr/bin/env bash
# Tests for install.sh's macOS desktop-notification GATES.
#
# WHY THIS EXISTS. Measured 2026-09-04: settings.json wired hooks/notification-event.sh
# into the Notification hook, the hook fired 36 times (21 idle_prompt, 8 agent_completed,
# 4 agent_needs_input, 2 permission_prompt, 1 push_notification), and every one of them
# rang NOTHING -- because the hook gates on ~/.claude/.enable-*-notif files that no
# installer, sync script or hook ever created. Silence is indistinguishable from "no
# events happened", so the gap had persisted since the hook was written. Claude Code's
# built-in `preferredNotifChannel` does not cover it: it emits a terminal escape
# sequence, and in VS Code's integrated terminal resolves to `no_method_available`.
#
# The names are DERIVED from the hook rather than retyped, so a rename cannot leave the
# installer behind -- docs/replicate-setup-prompt.md had already drifted that way, telling
# the reader to create `.enable-response-ready-notif`, a gate the hook stopped reading.
# These cases pin the derivation in BOTH directions and pin its fail-closed branch.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
fail=0
assert_eq()       { [ "$1" = "$2" ] || { echo "FAIL[$3]: expected '$2' got '$1'"; fail=1; }; }
assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL[$3]: expected to contain: $1"; fail=1;; esac; }

tmp="$(mktemp -d)" || { printf '%s: cannot create a temp directory\n' "$0" >&2; exit 1; }
[ -n "$tmp" ] && [ -d "$tmp" ] \
  || { printf '%s: mktemp -d produced no directory\n' "$0" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# install.sh is unix-only by design. Where `ln -s` silently copies, none of the
# surrounding installation can hold -- skip loudly rather than reporting green.
ln -s "$tmp" "$tmp/.lntest" 2>/dev/null && [ -L "$tmp/.lntest" ] || {
  echo "SKIP: this filesystem has no symlinks"; exit 0; }
rm -f "$tmp/.lntest"

seed_repo() { mkdir -p "$1"; cp -R "$REPO/." "$1/" 2>/dev/null || true; rm -rf "$1/.git"; }
shim_bin() { # $1 = dir, $2 = what argless `uname` prints
  mkdir -p "$1"
  cat > "$1/uname" <<SH
#!/usr/bin/env bash
[ "\$#" -eq 0 ] && { printf '%s\n' "$2"; exit 0; }
exec /usr/bin/uname "\$@"
SH
  for c in launchctl systemctl loginctl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1/$c"
  done
  chmod +x "$1"/uname "$1"/launchctl "$1"/systemctl "$1"/loginctl
}
run_install() { # $1 = repo, $2 = HOME, $3 = shim dir, rest = install.sh args
  local repo="$1" home="$2" pfx="$3"; shift 3
  # SKIP_NOTIF_FLAGS is passed as a literal assignment, never one produced by an
  # expansion: bash recognises assignment prefixes BEFORE expanding words, so
  # `${VAR:+VAR=$VAR}` is run as a COMMAND and the install exits 127.
  out="$( HOME="$home" PATH="${pfx:+$pfx:}$PATH" SKIP_OPENSUPERWHISPER=1 SKIP_WATCHER=1 \
          SKIP_NOTIF_FLAGS="${SKIP_NOTIF_FLAGS:-0}" \
          bash "$repo/install.sh" "$@" 2>&1 )"; rc=$?
  return 0
}
# The gate names the HOOK actually reads, read off the hook's conditional tests.
# Independent of the installer's own grep so the two can be compared, not assumed.
hook_gates() { # $1 = hooks DIRECTORY (every gated hook, not just one)
  grep -rho '\$HOME/\.claude/\.enable-[a-z0-9-]*-notif' "$1" | sed 's|.*/||' | sort -u
}
# The gate files an install actually left behind.
home_gates() { # $1 = fake HOME
  ( cd "$1/.claude" 2>/dev/null && ls -A | grep '^\.enable-.*-notif$' | sort -u ) || true
}

WANT="$(hook_gates "$REPO/hooks")"
# A derivation over an empty set proves nothing, and the installer's own branch
# fails closed on it -- so the test must refuse to run green on one too.
[ -n "$WANT" ] || { echo "FAIL[N0]: no hook names any .enable-*-notif gate"; exit 1; }

# ---- N1. a macOS install creates EXACTLY the gates the hook reads ----------
mkdir -p "$tmp/n1/home"; seed_repo "$tmp/n1/home/dotfiles/claude"
shim_bin "$tmp/n1/bin" Darwin
run_install "$tmp/n1/home/dotfiles/claude" "$tmp/n1/home" "$tmp/n1/bin" "$tmp/n1/home/.claude"
assert_eq "$rc" 0 N1-exit
# Both directions: no gate the hook reads is missing, and no extra gate is invented.
assert_eq "$(home_gates "$tmp/n1/home")" "$WANT" N1-set
assert_contains "Enabled notification gate" "$out" N1-log

# ---- N2. re-running does not TRUNCATE a gate a user has annotated ----------
# `: > file` would blank it; the installer must notice the file already exists.
printf 'user note\n' > "$tmp/n1/home/.claude/$(printf '%s' "$WANT" | head -1)"
run_install "$tmp/n1/home/dotfiles/claude" "$tmp/n1/home" "$tmp/n1/bin" "$tmp/n1/home/.claude"
assert_eq "$rc" 0 N2-exit
assert_eq "$(cat "$tmp/n1/home/.claude/$(printf '%s' "$WANT" | head -1)")" "user note" N2-preserved
assert_contains "already on" "$out" N2-log

# ---- N3. SKIP_NOTIF_FLAGS=1 creates none ----------------------------------
# The opt-out for terminals that already toast from the escape sequence.
mkdir -p "$tmp/n3/home"; seed_repo "$tmp/n3/home/dotfiles/claude"
shim_bin "$tmp/n3/bin" Darwin
SKIP_NOTIF_FLAGS=1 run_install "$tmp/n3/home/dotfiles/claude" "$tmp/n3/home" "$tmp/n3/bin" \
                               "$tmp/n3/home/.claude"
assert_eq "$rc" 0 N3-exit
assert_eq "$(home_gates "$tmp/n3/home")" "" N3-none

# ---- N4. a hook that names no gate FAILS the install, it does not go quiet -
# The mutant is PARTIAL on purpose: the hook still exists and still runs, it just
# stopped naming any gate. Deleting the file outright would take the other branch
# (the "hook missing" warning) and prove nothing about the derivation.
mkdir -p "$tmp/n4/home"; seed_repo "$tmp/n4/home/dotfiles/claude"
shim_bin "$tmp/n4/bin" Darwin
for h in "$REPO"/hooks/*.sh; do
  sed 's/\.enable-\([a-z0-9-]*\)-notif/.RENAMED-\1/g' "$h" \
    > "$tmp/n4/home/dotfiles/claude/hooks/$(basename "$h")"
done
run_install "$tmp/n4/home/dotfiles/claude" "$tmp/n4/home" "$tmp/n4/bin" "$tmp/n4/home/.claude"
[ "$rc" != 0 ] || { echo "FAIL[N4]: installer accepted a hook naming no gate"; fail=1; }
assert_contains "derivation is stale" "$out" N4-msg
# Positive control on the mutant itself: it really did remove every gate name,
# so N4 is testing the empty-set branch and not some unrelated failure.
assert_eq "$(hook_gates "$tmp/n4/home/dotfiles/claude/hooks")" "" N4-mutant

# ---- N5. a Linux install creates no macOS gates ---------------------------
# The gates exist only because the macOS hook is the only local surface there;
# settings.linux.json calls notify.sh unconditionally and needs no flag.
mkdir -p "$tmp/n5/home"; seed_repo "$tmp/n5/home/dotfiles/claude"
shim_bin "$tmp/n5/bin" Linux
run_install "$tmp/n5/home/dotfiles/claude" "$tmp/n5/home" "$tmp/n5/bin" "$tmp/n5/home/.claude"
assert_eq "$(home_gates "$tmp/n5/home")" "" N5-none

# ---- N6. every gated event actually INVOKES the audible channel ------------
# Grepping the hook for "afplay" would pass on a hook that only MENTIONS it in a
# comment -- and this hook has a long comment about it. So stub afplay on PATH
# and assert the CALL and its argument. osascript is stubbed too, so the suite
# never reaches the real Notification Center.
#
# WHY THE SOUND IS THE ASSERTED CHANNEL. `display notification` returns 0 whether
# the banner is shown, dropped, or filed silently, and macOS 26 no longer exposes
# com.apple.ncprefs, so the banner has NO observable success. afplay does: it
# blocks for the sound's real duration (measured 2026-09-04: 2.40s for Glass.aiff,
# against 0.02s and exit 1 for a missing file). The audible path is the one that
# can be tested, so it is the one the alert depends on.
stub_bin() { # $1 = dir, $2 = afplay argv log
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$2" > "$1/afplay"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/osascript"
  chmod +x "$1/afplay" "$1/osascript"
}
fire() { # $1 = fake HOME, $2 = shim dir, $3 = notification_type -> waits for the detached afplay
  local home="$1" pfx="$2" ntype="$3"
  printf '{"hook_event_name":"Notification","notification_type":"%s","message":"m","cwd":"/x/proj","session_id":"s"}' "$ntype" \
    | HOME="$home" PATH="$pfx:$PATH" bash "$REPO/hooks/notification-event.sh" >/dev/null 2>&1
  # ring() detaches afplay so a hook never blocks on audio; poll rather than sleep a fixed guess.
  local i=0; while [ "$i" -lt 40 ] && [ ! -s "$pfx/../afplay.log" ]; do /bin/sleep 0.05; i=$((i+1)); done
}
mkdir -p "$tmp/n6/home/.claude"
: > "$tmp/n6/afplay.log"
stub_bin "$tmp/n6/bin" "$tmp/n6/afplay.log"
# Gates ON: each ringing type must reach afplay with its own sound.
for g in $WANT; do : > "$tmp/n6/home/.claude/$g"; done
for pair in "agent_needs_input:Glass" "idle_prompt:Glass"; do
  ntype="${pair%%:*}"; want_snd="${pair##*:}"
  : > "$tmp/n6/afplay.log"
  fire "$tmp/n6/home" "$tmp/n6/bin" "$ntype"
  assert_contains "/System/Library/Sounds/$want_snd.aiff" "$(cat "$tmp/n6/afplay.log")" "N6-$ntype"
done
# agent_completed must ring NOTHING even with every gate ON ("the chime shouldn't
# ring when a background agent finishes", 2026-09-04). Asserted with the gates ON
# because that is the only state where the bug is reachable: every type falling
# past the explicit cases hits the fail-open generic ring, so a hook that merely
# DROPPED agent_completed from the fleet case would still chime here -- and would
# announce it as "Claude needs your input". A gates-off assertion could not tell
# the two implementations apart.
for g in $WANT; do : > "$tmp/n6/home/.claude/$g"; done
: > "$tmp/n6/afplay.log"
fire "$tmp/n6/home" "$tmp/n6/bin" "agent_completed"
assert_eq "$(cat "$tmp/n6/afplay.log")" "" N6-agent_completed-silent
# ...and the silence is RECORDED, so a suppressed event stays countable rather
# than being indistinguishable from an event that never arrived -- the exact
# ambiguity that hid the dead gates for months.
assert_contains '"notification_type":"agent_completed"' \
  "$(cat "$tmp/n6/home/.claude/hook-events.log" 2>/dev/null)" N6-agent_completed-logged

# Control: with the gates removed the SAME probe must record nothing. Without
# this, N6 would pass against a hook that rang unconditionally.
for g in $WANT; do rm -f "$tmp/n6/home/.claude/$g"; done
: > "$tmp/n6/afplay.log"
fire "$tmp/n6/home" "$tmp/n6/bin" "agent_needs_input"
assert_eq "$(cat "$tmp/n6/afplay.log")" "" N6-control

# ---- N7. the turn-end chime rings, and STAYS QUIET while agents work -------
# Enabling this gate used to be a no-op: stop-event.sh rang through
# `display notification ... sound name`, so the chime depended on a banner macOS
# does not show here. It now shares ring(). The mute is the other half -- the bell
# means "your turn to prompt", so it must not fire while something is still
# running (reported 2026-08-05: "u chime even when background agents are still
# running"). Both directions are asserted; ringing is worthless if it always rings.
stop_fire() { # $1 = fake HOME, $2 = shim dir, $3 = running-task JSON array
  printf '{"hook_event_name":"Stop","session_id":"n7sid","background_tasks":%s}' "$3" \
    | HOME="$1" PATH="$2:$PATH" bash "$REPO/hooks/stop-event.sh" >/dev/null 2>&1
  local i=0; while [ "$i" -lt 40 ] && [ ! -s "$tmp/n7/afplay.log" ]; do /bin/sleep 0.05; i=$((i+1)); done
}
mkdir -p "$tmp/n7/home/.claude"
stub_bin "$tmp/n7/bin" "$tmp/n7/afplay.log"
# stop-event.sh needs node to read background_tasks out of the payload. Without it
# the hook drops the state file and FAILS OPEN (rings), which cannot show the mute.
if [ -z "$(command -v node || true)" ]; then
  echo "SKIP[N7]: no node on PATH - the mute path cannot be exercised"
else
  RRN=".enable-response-ready-notif"
  : > "$tmp/n7/home/.claude/$RRN"
  # (a) nothing running -> rings
  : > "$tmp/n7/afplay.log"
  stop_fire "$tmp/n7/home" "$tmp/n7/bin" '[]'
  assert_contains "/System/Library/Sounds/Glass.aiff" "$(cat "$tmp/n7/afplay.log")" N7-rings
  # (b) an agent still running -> silent, and it says so in the log
  : > "$tmp/n7/afplay.log"
  stop_fire "$tmp/n7/home" "$tmp/n7/bin" '[{"status":"running"}]'
  assert_eq "$(cat "$tmp/n7/afplay.log")" "" N7-muted
  assert_contains "StopBellSuppressed" "$(cat "$tmp/n7/home/.claude/hook-events.log")" N7-logged
  # (c) gate removed -> silent even with nothing running (control for (a))
  rm -f "$tmp/n7/home/.claude/$RRN"
  : > "$tmp/n7/afplay.log"
  stop_fire "$tmp/n7/home" "$tmp/n7/bin" '[]'
  assert_eq "$(cat "$tmp/n7/afplay.log")" "" N7-gate-off
fi

# ---- N8. a missing shared library RAISES, it does not go quiet --------------
# ring() lives in hooks/notif-ring.sh and is imported by both hooks. If that file
# is ever unresolvable the alerts are dead, and dead alerts must not look like a
# quiet success -- that is the whole failure this arc started from.
mkdir -p "$tmp/n8/hooks" "$tmp/n8/home/.claude"
cp "$REPO"/hooks/notification-event.sh "$REPO"/hooks/stop-event.sh "$tmp/n8/hooks/"   # library NOT copied
for h in notification-event stop-event; do
  out8="$( printf '{"hook_event_name":"x","notification_type":"agent_needs_input","session_id":"s"}' \
           | HOME="$tmp/n8/home" bash "$tmp/n8/hooks/$h.sh" 2>&1 )"; rc8=$?
  [ "$rc8" != 0 ] || { echo "FAIL[N8-$h]: exited 0 with its alert channel missing"; fail=1; }
  assert_contains "notif-ring.sh" "$out8" "N8-$h-msg"
done
assert_contains "NotifRingLibMissing" "$(cat "$tmp/n8/home/.claude/hook-events.log")" N8-logged

[ "$fail" = 0 ] && echo "notif-gates: PASS" || echo "notif-gates: FAIL"
exit "$fail"
