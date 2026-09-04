#!/usr/bin/env bash
# fleet-open.sh — open the CURRENT live background-Claude fleet in one VS Code window,
# every session a terminal tab in one shared terminal panel.
#
# The fleet churns (sessions hand off to successors constantly), so this enumerates
# live jobs at run time and regenerates the workspace. Never hard-code session ids.
#
#   fleet-open.sh              # tabs in one panel  (readable; the default)
#   fleet-open.sh --split      # literal side-by-side panes (narrow past ~4)
#   fleet-open.sh --max-age 30 # only sessions touched in the last 30 min (default 60)
#   fleet-open.sh --print      # regenerate the workspace, don't open VS Code

set -euo pipefail

# Overridable so a test can assert the GENERATED artifact without overwriting the workspace the
# user has open. Asserting against the source text instead would pass on a script that never
# reaches this line.
WS="${FLEET_WORKSPACE:-$HOME/.claude/fleet.code-workspace}"
TAIL="$HOME/.claude/bin/fleet-tail.mjs"

# The cwd for the interactive `claude agents` task is DERIVED, not named -- see
# bin/fleet-trusted-dir.sh. This used to be a hardcoded personal project path with no override at
# all, so the one writable task in the generated workspace pointed at a directory that only
# existed on one machine. Resolved here in bash and passed into the heredoc through the
# environment, because writing the rule a second time in Python is the defect, not the fix.
SELF="$0"
while [ -L "$SELF" ]; do
  _l="$(readlink "$SELF")"
  case "$_l" in /*) SELF="$_l" ;; *) SELF="$(cd "$(dirname "$SELF")" && pwd)/$_l" ;; esac
done
SELFDIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)" || SELFDIR="$HOME/.claude/bin"
TRUSTED="$("$SELFDIR/fleet-trusted-dir.sh" 2>/dev/null)" || TRUSTED=""
VSCODE="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"

SPLIT=0; MAXAGE=60; PRINT_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --split) SPLIT=1; shift ;;
    --max-age) MAXAGE="$2"; shift 2 ;;
    --print) PRINT_ONLY=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "fleet-open: unknown flag $1" >&2; exit 2 ;;
  esac
done

[[ -f "$TAIL" ]] || { echo "fleet-open: missing $TAIL" >&2; exit 1; }

SPLIT=$SPLIT MAXAGE=$MAXAGE WS="$WS" TAIL="$TAIL" TRUSTED="$TRUSTED" python3 - <<'PY'
import json, os, glob, sys, time

split   = os.environ['SPLIT'] == '1'
maxage  = float(os.environ['MAXAGE']) * 60
ws_path = os.environ['WS']
tail    = os.environ['TAIL']
trusted = os.environ.get('TRUSTED', '')
home    = os.path.expanduser('~')

sessions = []
for p in glob.glob(os.path.join(home, '.claude', 'jobs', '*', 'state.json')):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if d.get('state') not in ('working', 'blocked'):
        continue
    age = time.time() - os.path.getmtime(p)
    if age > maxage:
        continue
    if not d.get('linkScanPath'):
        continue
    sessions.append({
        'short': os.path.basename(os.path.dirname(p)),
        'state': d.get('state'),
        'tokens': d.get('tokens') or 0,
        'cwd': d.get('cwd') or home,
        'name': (d.get('name') or os.path.basename(os.path.dirname(p)))[:40],
        'age': age,
    })

if not sessions:
    raise SystemExit('fleet-open: no live background sessions found')

# Newest activity first, so the freshest work sits at the top of the tab list.
sessions.sort(key=lambda s: s['age'])

# Multi-root: one folder per distinct cwd, deepest-name-first for readable labels.
folders, seen = [], set()
for s in sessions:
    cwd = s['cwd']
    if cwd in seen or not os.path.isdir(cwd):
        continue
    seen.add(cwd)
    folders.append({'name': os.path.basename(cwd) or cwd, 'path': cwd})

tasks = []

# PRIMARY: the whole fleet multiplexed into one terminal. Auto-discovers successors,
# so it survives the handoff churn that makes any hard-coded session list stale.
watch = tail.replace('fleet-tail.mjs', 'fleet-watch.mjs')
tasks.append({
    'label': '\u2605 Fleet \u2014 all sessions, one terminal',
    'type': 'shell',
    'command': f"node {watch}",
    'options': {'cwd': home},
    'presentation': {'reveal': 'always', 'panel': 'dedicated', 'group': 'fleet',
                     'showReuseMessage': False, 'clear': True, 'echo': False},
    'problemMatcher': [],
    'runOptions': {'runOn': 'folderOpen', 'instanceLimit': 1},
})

# SECONDARY: one focused tab per session, for when you want to read just one.
for s in sessions:
    pres = {
        'reveal': 'always',
        'panel': 'dedicated',
        'showReuseMessage': False,
        'clear': True,
        'echo': False,
    }
    if split:
        pres['group'] = 'fleet'          # shared group == side-by-side split panes
    tasks.append({
        'label': f"\u25c6 {s['short']}  {s['name']}",
        'type': 'shell',
        'command': f"node {tail} {s['short']} --back 14",
        'options': {'cwd': s['cwd']},
        'presentation': pres,
        'problemMatcher': [],
        'runOptions': {'instanceLimit': 1},
    })

# INTERACTIVE: the built-in fleet view is the only surface that can talk back.
# Omitted entirely when nothing resolved. A task with no cwd runs in whatever directory VS Code
# happens to open the workspace at — which can be $HOME, the one place `claude agents` must never
# be launched from, because it widens the picker to every session on the machine.
#
# The resolver returns an explicit CLAUDE_FLEET_DIR override even when it names nothing that
# exists, deliberately, so the caller can report the typo instead of hiding it. Reporting is this
# caller's job too: a task whose options.cwd does not exist cannot start, and VS Code says so with
# an error that names neither the override nor this file. `fleet write` already refuses the same
# state, so writing it here would leave the two write surfaces disagreeing about one input.
if trusted and not os.path.isdir(trusted):
    print(f"fleet-open: not adding the interactive fleet task — the resolved directory "
          f"{trusted!r} does not exist (check CLAUDE_FLEET_DIR)", file=sys.stderr)
    trusted = ''

if trusted:
    tasks.append({
        'label': '\u2630 Fleet view (claude agents) \u2014 interactive',
        'type': 'shell',
        'command': 'claude agents',
        'options': {'cwd': trusted},
        'presentation': {'reveal': 'always', 'panel': 'dedicated',
                         'showReuseMessage': False, 'clear': True, 'echo': False},
        'problemMatcher': [],
    })

tasks.append({
    'label': '\u25b6 Every session as its own tab',
    'dependsOn': [t['label'] for t in tasks if t['label'].startswith('\u25c6')],
    'dependsOrder': 'parallel',
    'problemMatcher': [],
})

workspace = {
    'folders': folders,
    'settings': {
        'terminal.integrated.tabs.enabled': True,
        'terminal.integrated.tabs.location': 'right',
        'terminal.integrated.scrollback': 4000,
        'terminal.integrated.persistentSessionReviveProcess': 'never',
        'task.allowAutomaticTasks': 'on',
        'window.title': 'Claude fleet — ${activeEditorShort}',
        'files.exclude': {'**/.claude/worktrees': False},
    },
    'tasks': {'version': '2.0.0', 'tasks': tasks},
}

with open(ws_path, 'w') as f:
    json.dump(workspace, f, indent=2)
    f.write('\n')

print(f"fleet-open: {len(sessions)} live session(s), {len(folders)} folder root(s)"
      f"{' — SPLIT panes' if split else ' — tabs in one panel'}")
for s in sessions:
    print(f"  {s['short']}  {s['state']:8} {s['tokens']//1000:>4}k  {int(s['age']):>4}s  {s['name']}")
print(f"fleet-open: wrote {ws_path}")
PY

if [[ "$PRINT_ONLY" == "1" ]]; then
  echo "fleet-open: --print given; not opening VS Code"
  exit 0
fi

if [[ -x "$VSCODE" ]]; then
  "$VSCODE" "$WS"
else
  open -a "Visual Studio Code" "$WS"
fi
echo "fleet-open: opened $WS"
echo "fleet-open: tails are READ-ONLY (~30MB each). To talk to a session use the ★ Fleet view tab."
