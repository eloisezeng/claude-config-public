---
name: schedule-beyond-a-week-needs-launchd
description: CronCreate is session-only and its recurring jobs expire after 7 days, so anything owed further out is armed with a launchd LaunchAgent that deletes its own plist, because StartCalendarInterval has no year field
scope: global
metadata:
  type: reference
---

**The session scheduler cannot hold a date.**
`CronCreate` jobs live only as long as the Claude session that created them, and a recurring one auto-expires after seven days.
Arming a check owed two weeks out there reads green and fires nothing, which is the "armed watcher reads green" class in `[[an-armed-watcher-holds-its-boot-config]]`.

**Use a macOS LaunchAgent for anything further out than a few days.**
Write `~/Library/LaunchAgents/com.your-org.<name>.plist`, `plutil -lint` it, then `launchctl bootstrap gui/$(id -u) <plist>` with `launchctl load -w` as the fallback, and confirm with `launchctl list`.

**`StartCalendarInterval` has no year field.**
It takes Month, Day, Hour, Minute and Weekday only, so a date-pinned job fires on that date every year forever unless the script it runs boots the job out and deletes its own plist.
A one-shot is therefore a property of the SCRIPT, never of the plist.

**Make every path an environment override with a default**, so the positive control can drive the real script against temporary copies.
Without that the only way to exercise the self-disable branch is to arm a fault in a tree that auto-commits, which `[[never-arm-a-fault-in-an-auto-syncing-tree]]` forbids.
Prove the disable branch is reachable on BOTH outcome branches, and hash the live plist before and after to show the control never touched it.

**Deliver the result where a session will actually see it.**
A verdict appended to the body of a lane reaches nobody until someone opens that lane; the open-lane list injected at every session start shows lane NAMES, so the verdict belongs in a lane filename — see `[[ops-lane-ledger]]`.

Worked example armed 2026-09-15: `com.your-org.compaction-stats-verdict`, running `~/dotfiles/claude/bin/compaction-stats-verdict.sh` on 29 September to measure whether raising `autoCompactWindow` cut compaction thrash — `[[handoff-at-boundaries-saves-tokens]]`.
