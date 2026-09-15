#!/usr/bin/env bash
#
# Runs the compaction-window follow-up measurement once, on 2026-09-29, then
# removes the LaunchAgent that started it.
#
# The self-removal exists because launchd's StartCalendarInterval has no year
# field: Month/Day/Hour/Minute/Weekday only. A date-pinned job that did not
# disarm itself would fire again every 29 September forever.
#
# Every path is read from the environment with a default, so the test can run
# this exact script against temporary copies. Nothing here may be pointed at
# the live plist or the live lane by a test.

set -uo pipefail

STATS_BIN="${CSV_STATS_BIN:-$HOME/dotfiles/claude/bin/compaction-stats.py}"
LANE="${CSV_LANE:-$HOME/.claude/ops/lanes/2026-09-29-measure-whether-the-window-raise-cut-compaction-thrash.md}"
ALERT_LANE="${CSV_ALERT_LANE:-$HOME/.claude/ops/lanes/2026-09-29-compaction-window-verdict.md}"
LOG="${CSV_LOG:-$HOME/Library/Logs/compaction-stats-verdict.log}"
PLIST="${CSV_PLIST:-$HOME/Library/LaunchAgents/com.your-org.compaction-stats-verdict.plist}"
LABEL="${CSV_LABEL:-com.your-org.compaction-stats-verdict}"
SINCE="${CSV_SINCE:-2026-09-15}"

STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

OUTPUT="$("$STATS_BIN" measure --since="$SINCE" 2>&1)"
EC=$?

if [ "$EC" -eq 0 ]; then
  VERDICT="PASS"
else
  VERDICT="FAIL"
fi

mkdir -p "$(dirname "$LOG")"
{
  printf '=== %s  verdict=%s  exit=%s ===\n' "$STAMP" "$VERDICT" "$EC"
  printf '%s\n\n' "$OUTPUT"
} >>"$LOG"

# The open lane is the record that this measurement was owed. The verdict is
# appended to it rather than replacing it, so the original criterion stays
# readable next to the number it judged.
if [ -f "$LANE" ]; then
  {
    printf '\n## Result (%s): %s\n\n' "$STAMP" "$VERDICT"
    printf 'The measurement ran from its LaunchAgent and exited %s.\n' "$EC"
    printf 'The tool exits 0 only when the worst-sixty-minute-window p90 has fallen to 3 or fewer.\n\n'
    printf '```\n%s\n```\n\n' "$OUTPUT"
    printf 'The full output is also at `%s`.\n' "$LOG"
  } >>"$LANE"
fi

# A second lane carries the verdict in its own filename, because the open-lane
# list injected at every session start shows lane names. A verdict buried in
# the body of an existing lane would reach nobody until someone opened it.
mkdir -p "$(dirname "$ALERT_LANE")"
cat >"$ALERT_LANE" <<LANEEOF
---
status: open
opened: 2026-09-29
pointer: $LOG
---

# The compaction-window change measured $VERDICT

Raising \`autoCompactWindow\` to 400,000 on 2026-09-15 was approved together with the test that
decides whether it worked. That test ran on $STAMP and the verdict is **$VERDICT**.

The criterion was that the worst-sixty-minute-window p90 fall from the measured baseline of 6 to
3 or fewer. "Improved but short of target" counts as a failure, which was deliberate.

\`\`\`
$OUTPUT
\`\`\`

The implementation lane is \`2026-09-14-compaction-thrash-fixed-two-numbers-need-her-call.md\`
and the measurement lane is \`$(basename "$LANE")\`.
Close this lane once the result has been written up.
LANEEOF

# Disarm. The unload is attempted first so launchd is not left holding a job
# whose plist has gone; a failure there is not a reason to keep the plist.
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 \
  || launchctl unload "$PLIST" >/dev/null 2>&1
rm -f "$PLIST"

printf 'compaction-stats verdict=%s exit=%s; disarmed %s\n' "$VERDICT" "$EC" "$LABEL"
exit 0
