---
name: pausing-a-service-is-not-pausing-the-mechanism
description: Unloading the launchd job that runs a script does not stop the script — enumerate every INVOKER of the path before declaring a pause
metadata:
  type: feedback
---

Before pausing any automation, grep the SCRIPT'S PATH across every invoker on the box —
launchd/systemd, `crontab -l`, `settings.json` hooks, git hooks, wrapper scripts — and disable
all of them.
Disabling the one registered service you know about leaves the others firing, and the pause reads
green because the registry honestly reports the service is gone.

**Why:** measured 2026-09-09.
`~/dotfiles/claude/sync.sh` commits and pushes claude-config.
I unloaded `com.your-org.claude-config-autopush` and verified the pause three times —
`launchctl print` answered `Could not find service ... in domain for user gui: 503` on every
check, and a `ps` sweep for the watcher found nothing.
Both readings were TRUE and the pause was still fake: `settings.json` runs the same script from a
**SessionStart hook**, so every session boot — my own compaction, a background agent's launch,
each subagent — commits and pushes.
Six `auto: sync config` commits went to `main` during a window I reported as paused, and one of
them swept in an unrelated agent's unrequested edit to her global `settings.json`.

The `ps` sweep from `[[a-standdown-must-disarm-the-shell-watchers]]` is necessary and not
sufficient: it finds an orphaned RUNNING watcher, and is blind to a DORMANT second trigger that
has not fired yet. The question is not "what is running?" but "what can start this?" —
`grep -rl '<script-path>' ~/.claude ~/dotfiles /etc/cron* ; crontab -l ; launchctl list` answers it
in one line, and a pause is not verified until that list is empty of armed entries.

Same shape as `[[enumerate-the-transforms-between-authoring-and-use]]`: audit the MECHANISM, not
the instance you happen to be looking at. Related: `[[an-armed-watcher-holds-its-boot-config]]`,
`[[never-arm-a-fault-in-an-auto-syncing-tree]]`.
