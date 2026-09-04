#!/usr/bin/env bash
# Shared local-alert channel for the macOS hooks. SOURCED, never executed.
#
# ONE definition, imported by hooks/notification-event.sh and hooks/stop-event.sh.
# It is a library rather than a copy in each hook because the two had already
# drifted: notification-event.sh was fixed on 2026-09-04 to ring through afplay,
# and stop-event.sh was left on the banner-only path -- so enabling its gate
# would have produced no sound at all, which is indistinguishable from the gate
# not working. A second copy is how that happens; an import is how it cannot.
#
# WHY THE SOUND CARRIES THE ALERT AND THE BANNER DOES NOT.
#   * `display notification` is delivered only if the RESPONSIBLE app -- whatever
#     owns the hook's process tree, here VS Code -- holds notification permission.
#     osascript returns 0 whether the banner is shown, silently dropped, or filed
#     straight into Notification Center without a sound.
#   * macOS 26 no longer exposes com.apple.ncprefs, so that permission cannot be
#     read and a delivered banner cannot be told apart from a suppressed one.
#   * A channel whose only success signal is an unconditional 0 has no success
#     signal, and must not be the sole alert. Measured 2026-09-04: it returned 0
#     for every one of 36 events while the user saw and heard nothing.
#   * afplay is not TCC-gated, needs no permission, and IS observable -- it blocks
#     for the sound's true duration (measured: 2.40s for Glass.aiff) and exits 1
#     in 0.02s on a missing file, so success and failure are distinguishable.
#
# The sound is played by afplay and NOT by AppleScript's `sound name`, so a
# delivered banner and the afplay call cannot double-ring: one event, one chime,
# whether or not the banner survives.
ring() { # ring <message> <title> <sound-name>
  local snd="/System/Library/Sounds/$3.aiff"
  [ -r "$snd" ] || snd="/System/Library/Sounds/Glass.aiff"   # named sound gone -> still ring
  [ -r "$snd" ] && ( afplay "$snd" >/dev/null 2>&1 & )       # detached: a hook never waits on audio
  # Text passed as ARGUMENTS, never interpolated into the script source: a message
  # containing a quote would otherwise break (or inject into) the AppleScript.
  osascript -e 'on run argv' \
            -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
            -e 'end run' -- "$1" "$2" >/dev/null 2>&1 || true
}
