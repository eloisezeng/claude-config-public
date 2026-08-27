#!/usr/bin/env bash
# Two suites, both cheap enough to run on every edit.
#
#   run.js             drives extension.js against a stubbed VS Code API, and a
#                      FAKE `fleet`, so the grouping assertions do not depend on
#                      how many sessions happen to be alive. Asserts the thing
#                      that cannot be read off the source: that panes 2..N are
#                      created with `location: { parentTerminal }` (a SPLIT) and
#                      not as new tabs.
#   fleet-open-pty.py  drives the REAL `fleet open` under a pty, against a fake
#                      `claude` on PATH and a fabricated $HOME roster — so it
#                      proves the argv, the header and the writability without
#                      opening a session or spending any usage.
#
# $FLEET_BIN names the fleet script UNDER TEST -- this repo's copy, never the
# installed one. Both are usually the same file (bin/fleet is symlinked into
# ~/.claude/bin), but "usually" is how a `fleet.sh` mutated to `exec /usr/bin/false`
# passed the whole suite: the test was executing a different file than the one
# being reviewed. The pty suite refuses to run without it.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# Parse the shell script FIRST. `fleet` embeds a node program inside a single-quoted
# shell string, so one apostrophe in a comment closes the quote and turns the rest of
# the file into shell -- a failure mode that reaches every caller at once and that no
# assertion below can reach, because nothing runs at all.
bash -n "$here/../../../bin/fleet"

EXT="$(dirname "$here")" NODE_PATH="$here/node_modules" node "$here/run.js"
echo
FLEET_BIN="$(cd "$here/../../../bin" && pwd)/fleet" exec /usr/bin/python3 "$here/fleet-open-pty.py"
