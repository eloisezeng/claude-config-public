---
name: handoff-session-id-ansi-poisoning
description: "A dispatch record whose identity was captured from COLOURISED stdout matches nothing later, so the watchdog reads a live successor as gone and stands down — check the id byte-exact with od -c after every dispatch"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

An identity captured from a tool's **human-facing** output carries its colour codes, and every later
lookup keyed on it misses — silently, because a miss looks exactly like absence.

Measured 2026-08-25 on `~/dotfiles/claude/hooks/handoff.sh`.
`_short_backgrounded() { printf '%s' "$1" | awk '/^backgrounded/{print $NF; exit}'; }` (line 971)
parses the successor id out of `claude --bg`'s colourised stdout with no ANSI strip, so `rec_put`
wrote `session_id=<ESC>[36m8c1e31e3<ESC>[39m`.
`lookup` and `row_present` then matched nothing in `claude agents --json`, and the watcher's absence
rule turned "cannot find the row" into `finished=1 / finished_how=gone / alerted_finished=1` and
exited — **on a successor that was `status:busy, state:working` at that exact moment**.
So the dispatch verification records `state=unknown` and the seat runs unwatched, both looking like
ordinary degraded monitoring.

**What to do.** After any `handoff.sh` dispatch, read the identity BYTE-EXACT
(`grep '^session_id=' <rec> | od -c`) rather than eyeballing it — colour codes are invisible in
every normal read, including `cat` and a terminal transcript.
Repair by appending (`rec_get_raw` is `sed -n 's/^k=//p' | tail -1`, last-write-wins, and `rec_has`
requires the literal `1`): `session_id=<clean>`, `finished=0`, `alerted_finished=0`.
Re-arm with a FRESH generation (`--watch-gen <token>`), which scopes the finish key to
`finished_<token>` so the stale one cannot silence it, and prove the repair with a control that
forces the opposite answer — `--watch-once` printing `handoff: <id> working, heartbeat Nm old` where
before it printed nothing.

**Why it generalises past this one script.** The defect is not a missing `sed`; it is that the
identity was read from a channel formatted for a human when a machine-readable one existed
(`claude agents --json`). Any pipeline that keys on a value scraped from pretty output inherits this,
and it fails toward "the thing is gone" — the direction that disarms safety machinery rather than
tripping it. Prefer the structured channel; where you must scrape, strip control bytes at the capture
site and assert the value's SHAPE before storing it.

**"It's a captured pipe, not a terminal" is no defense.** Measured 2026-08-30: `code=$(node -e
'…console.log(r.status)…')` in a watcher predicate captured `ESC[33m500ESC[39m` — node colourises
`console.log(<number>)` even into a non-TTY subshell capture when the environment forces colour
(Claude Code's Bash env does) — so the `case 500` hold arm never matched and the watcher false-fired
its "state changed" arm on an unchanged 500. Emit machine-bound values with
`process.stdout.write(String(v))` (raw strings are never colourised), filter at the capture site
(`| tr -cd '0-9'`), and control-test BOTH arms byte-exact (`od -c`) before arming.

**FIXED 2026-08-25 17:38 in `0480d84`** — both capture sites now strip control bytes before parsing:
`_strip_csi()` sits in front of BOTH `_short_backgrounded` (awk `$NF`) and `_short_hexid`
(`\b[0-9a-f]{8}\b`), so the ordering trap this memory used to describe — the colourised line never
being empty, so the poisoned value always beat the clean fallback — no longer exists. It is not
reordering; it is stripping at the capture site, which is what the rule above prescribes.
Pinned by the call census in `tests/handoff.test.sh` (`_strip_csi` is listed in the closure).

Dated by ORDERING, not by a re-read: the fix commit is 2026-08-25, and this file's own last edit was
2026-08-30 — five days LATER, still carrying "STILL UNFIXED". A stale "unfixed" note is a standing
invitation to redo finished work, which is why it is corrected in place rather than appended to
(`[[re-read-cannot-tell-wrong-from-acted-on]]`).

What survives as standing practice: the repo still auto-commits to `main` (`auto: sync config`), so an
unattended seat that "just edits the hook" has pushed to a repo every session reads without ever
running `git commit` — fix things here on a branch with a test alongside AB2/AB3/AB4 in
`tests/handoff.test.sh` (`[[never-arm-a-fault-in-an-auto-syncing-tree]]`). And `od -c` on a value you
are about to match byte-exact stays worth doing on its own merits, not as a workaround for this bug.

Related: [[absence-needs-a-probe-that-could-see-presence]] — the script's own comment cites that rule
at the very branch this poisoning defeats from underneath; [[an-armed-watcher-holds-its-boot-config]];
[[a-revival-wave-must-read-detail-before-nudging]]; [[verify-claims-against-artifacts]].
