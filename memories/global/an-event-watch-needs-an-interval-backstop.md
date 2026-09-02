---
name: an-event-watch-needs-an-interval-backstop
description: "A file-event watcher silently misses whole classes of change — macOS WatchPaths on a directory does not fire on in-place edits — so any unattended sync built on events alone needs a periodic backstop and an alert channel that survives being ignored"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

An event watch only sees what it can see, and what it cannot see it loses **silently**.

- **macOS launchd `WatchPaths` on a DIRECTORY fires when an entry is added or removed, NOT when a
  file already inside it is edited in place** — which is what most edits are. A watcher listing
  `skills/` looks like it covers skills; it covers *creating and deleting* them.
- Directory watches are not recursive on either platform, so a nested edit fires nothing.
- A watch list is a hand-picked subset that rots. Measured 2026-09-01 on `~/dotfiles/claude`: the
  list covered **5 of 22** top-level entries, so edits to `sync.sh`, `hooks/`, `bin/`, `docs/` and
  `plugins/` fired nothing at all. Combined with a wrong-account credential, 105 commits sat
  unpushed for four days.

**How to apply.** Three things, and the first two are not optional:

1. **Add an interval backstop** (`StartInterval`, a systemd `.timer` with `Persistent=true`). It is
   what bounds worst-case drift; the events are only an optimisation on top. A sync that no-ops on a
   clean tree costs nothing to run every 15 minutes. Assert the backstop's existence in its own test —
   deleting it leaves every other assertion green.
2. **Derive the watch set instead of curating it** ("every top-level entry except `.git`"), from ONE
   array feeding every platform's encoder, and assert it against the real repo listing in BOTH
   directions — a missing entry is unwatched work, an extra one is a typo, and neither direction
   catches the other.
3. **Alert somewhere that survives being ignored.** The failure here WAS detected and correctly
   classified — 626 times — but it was raised as a desktop toast that vanishes. Write it to a durable
   surface the next session reads (an ops lane), and close it on success.

Related: [[absence-needs-a-probe-that-could-see-presence]] · [[verify-claims-against-artifacts]] ·
[[a-mention-is-not-a-property]] · [[an-armed-watcher-holds-its-boot-config]]

**Tool fact met on the way:** `gh`'s token lookup is **HOME-scoped** — `gh auth token --user X`
returns nothing under an overridden `$HOME` even with `GH_CONFIG_DIR` pointed at the real config,
because the tokens live in the OS keyring. A test that overrides `HOME` for isolation will see
"no token" and can mislead you into thinking a credential path is dead code. Check the production
shape (real `HOME`, the scheduler's minimal `PATH`) before believing it.
