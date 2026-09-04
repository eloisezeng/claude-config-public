#!/usr/bin/env bash
# Controls for bin/fleet-trusted-dir.sh — the derived "directory `claude agents` may run from".
#
# Every fixture here is built so the WRONG answer is REACHABLE. A filter test whose bad candidate
# does not exist in the fixture proves nothing: the resolver would return the right path even with
# the filter deleted. So each rejection case gives the bad candidate the HIGHEST count, and puts a
# good candidate below it — a resolver without that filter returns the bad one, and the assertion
# can tell the two implementations apart. `[[plan-assertions-need-reachable-alternatives]]`
#
# Two rejections are OVER-DETERMINED and are marked as such below rather than dressed up as
# decisive: `$HOME` itself and `/` are refused by the strictly-under-$HOME rule AND by the
# git-work-tree walk, which is bounded by $HOME and therefore cannot accept either. That is a
# property of the resolver, not a gap in these fixtures — no fixture can make those two reachable —
# so they are pinned as OUTCOME controls and the bound is written next to them.
#
# HOME is redirected per case, because the resolver reads `~/.claude/jobs/*/state.json`. That also
# keeps the machine's real fleet out of the assertions: a control that reads live fleet state
# passes by accident. `[[liveness-ages-from-the-last-turn-not-file-mtime]]`
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$REPO/bin/fleet-trusted-dir.sh"
pass=0; fail=0

# PHYSICAL path: macOS puts $TMPDIR under /var, which is a link to /private/var. The resolver
# canonicalises before it counts and returns, so a fixture spelled the other way would make every
# expectation below differ from the answer by a prefix that has nothing to do with the rule.
# mktemp failing is not hypothetical -- a full disk, a read-only or hostile TMPDIR -- and in the
# `$(cd "$(mktemp -d)" && pwd -P)` shape the failure is SILENT and DESTRUCTIVE: bash treats
# `cd ""` as a successful no-op, so TMPROOT becomes the CURRENT directory and the EXIT trap below
# deletes the checkout, uncommitted work included. Measured with mktemp stubbed to fail, not
# reasoned about. Check it BEFORE canonicalising, and before arming the trap.
TMPROOT="$(mktemp -d)" || { printf '%s: cannot create a temp directory\n' "$0" >&2; exit 1; }
[ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] \
  || { printf '%s: mktemp -d produced no directory\n' "$0" >&2; exit 1; }
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT

check() { # name expected-stdout actual-stdout
  if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n        expected: %s\n        got     : %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# A candidate must be a git WORK TREE, because a project is a repository and a workspace root is
# only a drawer that holds repositories. mkproj builds the smallest thing that predicate can see.
# The aggregator roots below are deliberately built WITHOUT it — that is what makes the
# workspace-root rejection a reachable wrong answer rather than a comment.
mkproj() { local d; for d in "$@"; do mkdir -p "$d/.git"; done; }

# Build a fake HOME with a synthetic jobs directory.
#   mkjobs <home> <state>[@<mtime-minutes>][~[u]<turn-minutes>]:<cwd> ...  — one record per argument
#
# TWO CLOCKS, spellable INDEPENDENTLY, because the whole point is that they can disagree:
#
#   @<mins>   backdates `state.json`'s mtime. `working` alone is not liveness -- a session killed
#             by a crash, a reboot or a `kill -9` never writes its terminal state -- and without a
#             way to spell an OLD record every fixture record was fresh, so the stale-record answer
#             was unreachable and a resolver with no age gate at all passed the whole suite.
#   ~<mins>   writes a real transcript whose last ASSISTANT turn is that old, and points
#             linkScanPath at it. `~u<mins>` writes one holding only USER turns, which is a seat
#             that was dispatched and never answered.
#
# Spelling only `@` leaves linkScanPath pointing at a directory, which no transcript reader can
# open -- that is the mtime fallback, and it is what every case written before this helper grew a
# second clock exercises. Spelling BOTH is the case that matters: a fresh mtime over an ancient
# last turn is what a dead seat actually looks like, because anything that touches the job rewrites
# state.json. A fixture that could not separate the two clocks could not see that.
# `[[a-fixture-helpers-default-pins-the-swept-axis]]` `[[liveness-ages-from-the-last-turn-not-file-mtime]]`
#
# `linkScanPath` is written on every record because bin/fleet-open.sh requires it to consider a
# session live; the call-site controls at the bottom drive the real generator against this same
# fixture rather than a second, divergent one.
mkjobs() {
  local home="$1"; shift
  mkdir -p "$home/.claude/jobs"
  local i=0 spec head state age turn cwd link jdir
  for spec in "$@"; do
    i=$((i+1))
    head="${spec%%:*}"; cwd="${spec#*:}"
    turn=""; case "$head" in *~*) turn="${head#*~}"; head="${head%%~*}" ;; esac
    age="";  case "$head" in *@*) age="${head#*@}";  head="${head%%@*}" ;; esac
    state="$head"
    jdir="$home/.claude/jobs/job$i"; mkdir -p "$jdir"

    link="$cwd"
    if [ -n "$turn" ]; then
      link="$jdir/transcript.jsonl"
      python3 - "$link" "$turn" <<'TRANSCRIPT_PY'
import json, re, sys, time
path, spec = sys.argv[1], sys.argv[2]

# Three spellings, and the third exists because the first two cannot tell tier 1 from tier 2:
#   <mins>        an ordinary session -- dispatch prompt, then an assistant turn <mins> ago
#   u<mins>       dispatched and never answered -- USER turns only, newest <mins> ago
#   a<A>u<U>      both clocks named. `a180u5` is a dead seat that was NUDGED five minutes ago: the
#                 newest record is fresh, the newest ANSWER is three hours old. A reader taking
#                 the last record of any type calls that live; one taking the last assistant turn
#                 does not, and nothing else in this file distinguishes them.
m = re.match(r"^a([0-9.]+)u([0-9.]+)$", spec)
if m:
    turns = [("assistant", float(m.group(1))), ("user", float(m.group(2)))]
elif spec.startswith("u"):
    turns = [("user", float(spec[1:]) + 10), ("user", float(spec[1:]))]
else:
    # THREE records, and the oldest one is the reason: a real transcript holds many answers, so
    # the tail window opens on an ancient assistant turn. A reader walking the window FORWARDS
    # returns that one and reports every long-running session stale -- nothing is ever live. Two
    # records could not tell the two directions apart, and the mutant survived the whole suite.
    turns = [("assistant", float(spec) + 240),
             ("user", float(spec) + 10),
             ("assistant", float(spec))]

def stamp(mins_ago):
    # UTC with a trailing Z, exactly as the harness writes it -- the reader parses it as UTC, so
    # a local-time stamp here would shift every age by this machine's offset and the control
    # would measure the timezone instead of the code.
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - mins_ago * 60)) + ".000Z"

# Written oldest-first, the way a transcript actually grows: the reader walks backwards from the
# end, so an out-of-order file would be testing a shape the harness never produces.
turns.sort(key=lambda t: -t[1])
open(path, "w").write("".join(
    json.dumps({"type": k, "timestamp": stamp(a), "message": {"content": "a turn"}}) + "\n"
    for k, a in turns))
TRANSCRIPT_PY
    fi

    printf '{"state":"%s","cwd":"%s","linkScanPath":"%s"}\n' \
      "$state" "$cwd" "$link" > "$jdir/state.json"
    [ -z "$age" ] || python3 -c 'import os, sys, time
t = time.time() - float(sys.argv[2]) * 60
os.utime(sys.argv[1], (t, t))' "$jdir/state.json" "$age"
  done
}

# Write a `~/.claude.json` holding the folder-trust flags the resolver reads.
#   mktrust <home> [!]<lastStartTime>:<dir> ...
#
# A leading `!` writes the entry with hasTrustDialogAccepted FALSE. Without that spelling every
# fixture entry was trusted, so the one-line mutation of `rec.get("hasTrustDialogAccepted")` to a
# bare `isinstance(rec, dict)` survived the entire suite — while on this machine the real record is
# 9 trusted against 15 untrusted of 24 entries, so ignoring the flag promotes fifteen directories
# nobody trusted. The helper's default pinned the very axis the flag is about.
# `[[a-fixture-helpers-default-pins-the-swept-axis]]`
mktrust() {
  local home="$1"; shift
  python3 - "$home" "$@" <<'MKTRUST_PY'
import json, sys
home, specs = sys.argv[1], sys.argv[2:]
projects = {}
for spec in specs:
    trusted = not spec.startswith("!")
    ts, path = spec.lstrip("!").split(":", 1)
    projects[path] = {"hasTrustDialogAccepted": trusted, "lastStartTime": int(ts)}
json.dump({"projects": projects}, open(home + "/.claude.json", "w"))
MKTRUST_PY
}

echo "fleet-trusted-dir controls"

# --- A2: the override is an instruction, not a hint -------------------------------------------
H="$TMPROOT/h-override"; mkdir -p "$H"
mkproj "$H/decoy" "$H/named"
ln -s "$H/named" "$H/named-link"
mkjobs "$H" "working:$H/decoy"
out=$(HOME="$H" CLAUDE_FLEET_DIR="$H/named" "$RESOLVER" --why); rc=$?
check "override wins over a live job record" "$H/named
override" "$out"
check "override exits 0" "0" "$rc"

# The override is returned even when it does NOT exist, so `fleet doctor` can print it as MISSING
# and `fleet write` can name the typo. A resolver that silently fell through to a working
# directory would hide the mistake — and the live decoy above makes that fall-through reachable.
out=$(HOME="$H" CLAUDE_FLEET_DIR="$H/gone" "$RESOLVER" --why); rc=$?
check "a nonexistent override is still returned verbatim" "$H/gone
override" "$out"
check "...and still exits 0" "0" "$rc"

# An override that EXISTS is emitted as its PHYSICAL path. The generated workspace records this
# value as a task's `options.cwd`, and `.` or a relative name records a different directory for
# every process that later reads the file.
out=$(HOME="$H" CLAUDE_FLEET_DIR="$H/named-link" "$RESOLVER" --why); rc=$?
check "an existing override is emitted RESOLVED, not as the symlink spelled" "$H/named
override" "$out"
out=$( cd "$H" && HOME="$H" CLAUDE_FLEET_DIR="named" "$RESOLVER" --why )
check "...and a relative override is resolved too, not passed through" "$H/named
override" "$out"

# The two answers that widen the picker to the whole machine are REFUSED, not emitted: `claude
# agents --cwd $HOME` admits every session on the box, which is the exact opposite of narrowing.
# The live decoy is still in this fixture, so a resolver that fell back instead of refusing
# returns `$H/decoy` and these go red.
out=$(HOME="$H" CLAUDE_FLEET_DIR="$H" "$RESOLVER" --why 2>/dev/null); rc=$?
check "an override resolving to \$HOME prints NOTHING on stdout" "" "$out"
check "...and exits 3" "3" "$rc"
err=$(HOME="$H" CLAUDE_FLEET_DIR="$H" "$RESOLVER" --why 2>&1 >/dev/null)
case "$err" in
  *"open the fleet picker over every session"*) printf '  PASS  ...and says why on stderr\n'; pass=$((pass+1)) ;;
  *) printf '  FAIL  refusal printed no explanation, got: %s\n' "$err"; fail=$((fail+1)) ;;
esac
out=$(HOME="$H" CLAUDE_FLEET_DIR="/" "$RESOLVER" --why 2>/dev/null); rc=$?
check "an override of / is refused too (empty stdout, exit 3)" "3" "$rc$out"
# Spelled so it only RESOLVES to $HOME — a string comparison against $HOME lets this through.
out=$(HOME="$H" CLAUDE_FLEET_DIR="$H/named/.." "$RESOLVER" --why 2>/dev/null); rc=$?
check "the refusal is on the resolved path, not the spelling" "3" "$rc$out"

# --- A3: the mode of live cwds, and the tie-break ----------------------------------------------
H="$TMPROOT/h-mode"; mkproj "$H/a" "$H/b"
mkjobs "$H" "working:$H/a" "blocked:$H/a" "working:$H/b"
check "returns the mode of live session cwds" "$H/a
live" "$(HOME="$H" "$RESOLVER" --why)"

# `blocked` is LIVE, and this is the case that says so. A resolver counting only `working` sees one
# record for `$H/waiting` and one for `$H/running`, and the tie-break hands it `$H/running`; the
# two blocked records are what make `$H/waiting` win. Without this, narrowing liveness to `working`
# alone — which is exactly what a reader trimming that tuple would do — passes every other case.
H="$TMPROOT/h-blocked"; mkproj "$H/waiting" "$H/running"
mkjobs "$H" "blocked:$H/waiting" "blocked:$H/waiting" "working:$H/running"
check "a blocked session counts as live" "$H/waiting
live" "$(HOME="$H" "$RESOLVER" --why)"

# Equal counts: the SHALLOWER path wins — a project root beats a worktree nested inside it. This
# is also the all-counts-are-one case, where the depth rule is the ONLY thing deciding, so the
# behaviour is pinned here rather than left as an emergent property of the sort key.
# `$H/deep/nested/wt` sorts BEFORE `$H/root` lexicographically, so a resolver that broke the tie
# alphabetically would answer the nested one. That is what makes this an assertion.
H="$TMPROOT/h-tie"; mkproj "$H/root" "$H/deep/nested/wt"
mkjobs "$H" "working:$H/root" "working:$H/deep/nested/wt"
check "a tie goes to the shallower path, not the alphabetical one" "$H/root
live" "$(HOME="$H" "$RESOLVER" --why)"

# --- live beats historical, even at a far lower count ------------------------------------------
H="$TMPROOT/h-live"; mkproj "$H/now" "$H/before"
mkjobs "$H" "working:$H/now" "done:$H/before" "done:$H/before" "done:$H/before" "done:$H/before"
check "one live session outranks four finished ones" "$H/now
live" "$(HOME="$H" "$RESOLVER" --why)"

# ...but a finished session is still evidence when nothing is live.
H="$TMPROOT/h-hist"; mkproj "$H/before"
mkjobs "$H" "done:$H/before" "done:$H/before"
check "with nothing live, a finished session's dir is used" "$H/before
historical" "$(HOME="$H" "$RESOLVER" --why)"

# --- a stale `working` record is not a live session ---------------------------------------------
# A crash, a reboot or a `kill -9` leaves `state: working` on disk forever. Three such records
# against one fresh one: a resolver reading state alone answers `$H/crashed`, which is what makes
# the age gate visible here.
H="$TMPROOT/h-stale"; mkproj "$H/crashed" "$H/fresh"
mkjobs "$H" "working@180:$H/crashed" "working@180:$H/crashed" "working@180:$H/crashed" \
            "working:$H/fresh"
check "a three-hour-old 'working' record loses to one fresh session" "$H/fresh
live" "$(HOME="$H" "$RESOLVER" --why)"

# ...and it is DEMOTED, never discarded — it still proves that directory was worked in, which is
# what rank 3 is for. A gate that dropped stale records outright answers nothing here.
H="$TMPROOT/h-stale2"; mkproj "$H/crashed"
mkjobs "$H" "working@180:$H/crashed"
check "...but a stale record still answers as historical" "$H/crashed
historical" "$(HOME="$H" "$RESOLVER" --why)"

# --- the two clocks, forced to DISAGREE ---------------------------------------------------------
# Everything above ages from `state.json`'s mtime because it names no transcript, so all of it is
# equally green whichever clock the resolver reads. These four cases force the clocks apart, which
# is the only way to see which one it actually used. `[[liveness-ages-from-the-last-turn-not-file-mtime]]`
#
# Case 1 is the one that bites in production: nothing here is backdated, so every state.json mtime
# is fresh -- exactly what a dead seat looks like, because the daemon, a notification or a peer's
# kill rewrites that file without the session producing anything. `$H/dead` is BOTH trusted and
# ahead 3-to-1, so an mtime-aged resolver ranks it live and answers it; only aging from the last
# assistant turn demotes it and leaves `$H/active` as the single live session.
H="$TMPROOT/h-turnclock"; mkproj "$H/dead" "$H/active"
mkjobs "$H" "working~180:$H/dead" "working~180:$H/dead" "working~180:$H/dead" "working~5:$H/active"
mktrust "$H" "900:$H/dead"
check "a fresh state.json over a 3-hour-old last turn is NOT live" "$H/active
live" "$(HOME="$H" "$RESOLVER" --why)"

# ...and the demotion is a demotion here too: with the active session removed, the dead seat is
# still the historical answer. A resolver that DISCARDED it would answer nothing.
H="$TMPROOT/h-turnclock2"; mkproj "$H/dead"
mkjobs "$H" "working~180:$H/dead"
check "...and that fresh-mtime dead seat is still historical" "$H/dead
historical" "$(HOME="$H" "$RESOLVER" --why)"

# The other direction, so the transcript is shown to WIN rather than merely to be consulted: a
# three-hour-old state.json whose last assistant turn is two minutes old is live. A resolver
# preferring mtime demotes `$H/working` and answers the fresher-by-mtime `$H/idle`.
H="$TMPROOT/h-turnclock3"; mkproj "$H/working" "$H/idle"
mkjobs "$H" "working@180~2:$H/working" "working@180~2:$H/working" "working:$H/idle"
check "a stale state.json over a 2-minute-old last turn IS live" "$H/working
live" "$(HOME="$H" "$RESOLVER" --why)"

# Tier 2, which is what separates "read the last assistant turn" from "read the last record": a
# seat dispatched and never answered holds only USER turns. Its transcript's newest record is
# three hours old, so it is not live -- while `mkjobs` writes the dispatch prompt ten minutes
# BEFORE the pinned turn in every record, so a reader taking the FIRST timestamp it finds rather
# than the last would answer differently here and in case 1 both.
H="$TMPROOT/h-turnclock4"; mkproj "$H/unanswered" "$H/answered"
mkjobs "$H" "working~u180:$H/unanswered" "working~u180:$H/unanswered" "working~5:$H/answered"
check "a seat holding only an old USER turn is not live either" "$H/answered
live" "$(HOME="$H" "$RESOLVER" --why)"

# ...and tier 1 is specifically the ASSISTANT turn, not the newest record. `$H/nudged` was sent a
# message five minutes ago and has not answered since three hours ago -- which is precisely the
# state a stall-nudge leaves behind, so this is the shape a revival wave produces, not a contrived
# one. Reading the newest record of any type calls it live and answers it on count; reading the
# newest ANSWER does not.
H="$TMPROOT/h-turnclock5"; mkproj "$H/nudged" "$H/answering"
mkjobs "$H" "working~a180u5:$H/nudged" "working~a180u5:$H/nudged" "working~5:$H/answering"
check "a nudged-but-unanswering seat is not live" "$H/answering
live" "$(HOME="$H" "$RESOLVER" --why)"

# The age gate is `fleet ids`'s rule, not a second opinion about liveness, and the same 60 minutes
# is written in three languages in three files. Nothing renders them from one source — bash, a JS
# heredoc and a Python heredoc — so the ratchet available here is EQUALITY, checked against the
# artifacts. A NOT-FOUND from either pattern fails this case rather than passing it, so moving or
# renaming a constant cannot make the guard quietly stop looking.
# `[[name-a-shared-constant-once-and-guard-the-artifact]]`
ages=$(python3 - "$REPO" <<'AGES_PY'
import re, sys
repo = sys.argv[1]
sites = [("bin/fleet-trusted-dir.sh", r"LIVE_MAX_AGE_MIN\s*=\s*(\d+)"),
         ("bin/fleet",                r"let\s+MAXAGE\s*=\s*(\d+)"),
         ("bin/fleet-open.sh",        r"MAXAGE=(\d+)")]
for path, pat in sites:
    try:
        m = re.search(pat, open(repo + "/" + path).read())
    except Exception:
        m = None
    print("%s=%s" % (path, m.group(1) if m else "NOT-FOUND"))
AGES_PY
)
distinct=$(printf '%s\n' "$ages" | sed 's/.*=//' | sort -u | tr '\n' ' ')
case "$distinct" in
  "60 ") printf '  PASS  the liveness window agrees across all three files (60 min)\n'; pass=$((pass+1)) ;;
  *) printf '  FAIL  liveness window disagrees or is unreadable: %s\n' "$(printf '%s' "$ages" | tr '\n' ' ')"
     fail=$((fail+1)) ;;
esac

# --- A4: the candidate filter, each with the wrong answer reachable ----------------------------
# In every case the REJECTED candidate has the higher count, so a resolver missing that filter
# returns it and the assertion goes red — except where marked over-determined.

# OVER-DETERMINED (see the header): $HOME is rejected by the under-$HOME rule, and the work-tree
# walk is bounded by $HOME so it cannot accept $HOME either. No fixture can make the wrong answer
# reachable here; this pins the OUTCOME, which is the part that matters — `claude agents --cwd
# $HOME` admits every session on the machine.
H="$TMPROOT/h-home"; mkproj "$H/ok"
mkjobs "$H" "working:$H" "working:$H" "working:$H" "working:$H/ok"
check "never \$HOME itself, even as the clear mode" "$H/ok
live" "$(HOME="$H" "$RESOLVER" --why)"

# OVER-DETERMINED for the same reason.
H="$TMPROOT/h-root"; mkproj "$H/ok"
mkjobs "$H" "working:/" "working:/" "working:/" "working:$H/ok"
check "never /" "$H/ok
live" "$(HOME="$H" "$RESOLVER" --why)"

# The gone directory is spelled INSIDE a checkout — `$H/proj` carries the `.git` — because a
# candidate that is neither present nor in a work tree is rejected twice and cannot show which
# rule did it. A live session's worktree being removed out from under it is exactly this shape: the
# repo is still there, the directory is not.
H="$TMPROOT/h-gone"; mkproj "$H/ok" "$H/proj"
mkjobs "$H" "working:$H/proj/deleted" "working:$H/proj/deleted" "working:$H/proj/deleted" \
            "working:$H/ok"
check "never a directory that no longer exists" "$H/ok
live" "$(HOME="$H" "$RESOLVER" --why)"

# The harness's own scratch. The job dir is given its own `.git` ON PURPOSE: without it the
# work-tree rule rejects this candidate too and the case cannot see whether the harness rule
# exists at all. With it, deleting the harness rule returns `$H/.claude/jobs/x/tmp`.
# A project's OWN .claude/worktrees/* is a different thing and stays eligible — the case below
# pins that, so the exclusion cannot be widened into a rule that swallows real worktrees.
H="$TMPROOT/h-harness"; mkdir -p "$H/.claude/jobs"; mkproj "$H/.claude/jobs/x/tmp" "$H/ok"
mkjobs "$H" "working:$H/.claude/jobs/x/tmp" "working:$H/.claude/jobs/x/tmp" \
            "working:$H/.claude/jobs/x/tmp" "working:$H/ok"
check "never a path under \$HOME/.claude/" "$H/ok
live" "$(HOME="$H" "$RESOLVER" --why)"

# The `.git` marker sits on `$H/proj`, not on the worktree directory, so this also pins that the
# rule WALKS UP rather than demanding a marker in the candidate itself. A subdirectory of a
# checkout is inside a work tree, and that is what the resolver has to agree with.
H="$TMPROOT/h-wt"; mkproj "$H/proj"; mkdir -p "$H/proj/.claude/worktrees/feature"
mkjobs "$H" "working:$H/proj/.claude/worktrees/feature"
check "a PROJECT's own .claude/worktrees/* is still eligible" "$H/proj/.claude/worktrees/feature
live" "$(HOME="$H" "$RESOLVER" --why)"

# --- a workspace ROOT is not a project ----------------------------------------------------------
# A drawer full of repositories carries the trust flag on this machine just like a project does,
# and handing `claude agents` one offers every project at once — the same widening as $HOME, one
# level down. `$H/Workspace` exists, sits strictly under $HOME and is nowhere near the harness
# tree, so the work-tree rule is the ONLY thing that can reject it; it holds three records against
# the project's one.
H="$TMPROOT/h-workspace"; mkdir -p "$H/Workspace"; mkproj "$H/Workspace/proj"
mkjobs "$H" "working:$H/Workspace" "working:$H/Workspace" "working:$H/Workspace" \
            "working:$H/Workspace/proj"
check "a workspace root loses to a repository inside it" "$H/Workspace/proj
live" "$(HOME="$H" "$RESOLVER" --why)"

# ...and the same filter applies to the trust list, where the drawer is the MORE recent entry.
H="$TMPROOT/h-workspace2"; mkdir -p "$H/.claude/jobs" "$H/Ws"; mkproj "$H/Ws/proj"
mktrust "$H" "900:$H/Ws" "100:$H/Ws/proj"
check "...including when the trust record names the drawer most recently" "$H/Ws/proj
trusted" "$(HOME="$H" "$RESOLVER" --why)"

# A record that will not parse must be skipped, not fatal — one half-written state.json should
# never take the fleet's write surface down with it.
H="$TMPROOT/h-junk"; mkproj "$H/ok"
mkjobs "$H" "working:$H/ok"
mkdir -p "$H/.claude/jobs/broken"; printf '{not json' > "$H/.claude/jobs/broken/state.json"
check "a corrupt job record is skipped, not fatal" "$H/ok
live" "$(HOME="$H" "$RESOLVER" --why)"

# --- A5: no job records at all -> the repo this script ships in --------------------------------
H="$TMPROOT/h-norecords"; mkdir -p "$H/.claude/jobs" "$H/proj/bin"
cp "$RESOLVER" "$H/proj/bin/fleet-trusted-dir.sh"
( cd "$H/proj" && git init -q . ) >/dev/null 2>&1
out=$(HOME="$H" "$H/proj/bin/fleet-trusted-dir.sh" --why); rc=$?
# macOS resolves $TMPDIR through /private, and `git rev-parse --show-toplevel` answers with the
# resolved path while $H does not — compare against the same resolution git will report.
expected="$(cd "$H/proj" && pwd -P)"
check "with no job records, falls back to its own repo" "$expected
repo" "$out"
check "...and exits 0" "0" "$rc"

# ...but git must ANSWER. A copy that is not in a checkout at all — an unpacked tarball, a `bin/`
# someone rsynced — is evidence of nothing, and `dirname` of wherever the file happens to sit is a
# guess with nothing behind it. This directory is under $HOME and passes every other test, so only
# the git requirement can reject it: restoring the old `repo="$(dirname "$selfdir")"` fallback
# turns this case red by answering `$H/loose`.
H="$TMPROOT/h-nogit"; mkdir -p "$H/.claude/jobs" "$H/loose/bin"
cp "$RESOLVER" "$H/loose/bin/fleet-trusted-dir.sh"
out=$(HOME="$H" "$H/loose/bin/fleet-trusted-dir.sh" --why); rc=$?
check "a copy outside any checkout resolves NOTHING" "" "$out"
check "...and exits 3, rather than guessing its parent" "3" "$rc"

# --- fail CLOSED: nothing resolved -> empty stdout, exit 3 -------------------------------------
# The script is copied OUTSIDE the (fake) HOME, so the repo rule's own candidate filter rejects it.
OUTSIDE="$TMPROOT/outside/bin"; mkdir -p "$OUTSIDE"
cp "$RESOLVER" "$OUTSIDE/fleet-trusted-dir.sh"
H="$TMPROOT/h-empty"; mkdir -p "$H/.claude/jobs"
out=$(HOME="$H" "$OUTSIDE/fleet-trusted-dir.sh" --why); rc=$?
check "unresolvable prints NOTHING on stdout" "" "$out"
check "...and exits 3, not 0" "3" "$rc"

# --- A6: the two call sites read the resolver, not a literal -----------------------------------
# Asserted against the EMITTED artifacts, never against the scripts' source text: a grep for the
# right identifier passes on a script that never reaches the line.
#
# Driven on a FIXTURE-owned HOME with an override no machine would produce. Run against the LIVE
# HOME, as these two controls used to be, they compared the real resolver's answer with itself — so
# they stayed green on a `fleet` and a `fleet-open.sh` that had each hardcoded the same literal the
# resolver happens to return on this machine, which is the whole defect this file is about.
# `[[an-armed-watcher-holds-its-boot-config]]`
# The `.claude/bin` link is what the installer makes; fleet-open.sh refuses without it.
H="$TMPROOT/h-callsite"; mkdir -p "$H/.claude"
ln -s "$REPO/bin" "$H/.claude/bin"
mkproj "$H/only-this-one"
mkjobs "$H" "working:$H/only-this-one"
CS_HOME="$H"; CS_DIR="$H/only-this-one"

resolved=$(HOME="$CS_HOME" CLAUDE_FLEET_DIR="$CS_DIR" "$RESOLVER" --why 2>/dev/null | sed -n 1p)
why=$(HOME="$CS_HOME" CLAUDE_FLEET_DIR="$CS_DIR" "$RESOLVER" --why 2>/dev/null | sed -n 2p)
check "the fixture override is what the resolver answers" "$CS_DIR override" "$resolved $why"

doc_all=$(HOME="$CS_HOME" CLAUDE_FLEET_DIR="$CS_DIR" "$REPO/bin/fleet" doctor 2>/dev/null); rc=$?
check "fleet doctor exits 0 on the fixture HOME" "0" "$rc"
doc=$(printf '%s\n' "$doc_all" | sed -n 's/^  trusted dir  : //p')
check "fleet doctor prints the resolved dir, its provenance and its existence" \
  "$resolved [$why] (exists)" "$doc"

agents_cwd() { # workspace-file -> the cwd of the `claude agents` task, or empty
  python3 - "$1" <<'WS_PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit(0)
tasks = d['tasks']['tasks'] if isinstance(d.get('tasks'), dict) else d.get('tasks', [])
print(next((t['options']['cwd'] for t in tasks if 'claude agents' in str(t.get('command', ''))), ''))
WS_PY
}

ws="$TMPROOT/probe.code-workspace"
HOME="$CS_HOME" CLAUDE_FLEET_DIR="$CS_DIR" FLEET_WORKSPACE="$ws" \
  "$REPO/bin/fleet-open.sh" --print >/dev/null 2>&1; rc=$?
check "fleet-open.sh --print exits 0" "0" "$rc"
if [ -f "$ws" ]; then printf '  PASS  ...and wrote the workspace file it was pointed at\n'; pass=$((pass+1))
else printf '  FAIL  fleet-open.sh --print wrote no workspace at %s\n' "$ws"; fail=$((fail+1)); fi
check "the generated workspace's 'claude agents' task uses the resolver's answer" \
  "$resolved" "$(agents_cwd "$ws")"

# The resolver hands back a nonexistent override deliberately, so the caller can report the typo.
# Reporting is this caller's job: a task whose cwd does not exist cannot start, and VS Code's error
# names neither the override nor the script. The task must be OMITTED and the reason said out loud
# — and the rest of the workspace must still be written, or a typo in one variable takes the
# session tabs away too.
ws2="$TMPROOT/probe-missing.code-workspace"
err=$(HOME="$CS_HOME" CLAUDE_FLEET_DIR="$H/typo-here" FLEET_WORKSPACE="$ws2" \
  "$REPO/bin/fleet-open.sh" --print 2>&1 >/dev/null); rc=$?
check "fleet-open.sh still exits 0 when the override names nothing" "0" "$rc"
check "...and omits the interactive task rather than writing a dead cwd" "" "$(agents_cwd "$ws2")"
if [ -f "$ws2" ]; then printf '  PASS  ...while still writing the rest of the workspace\n'; pass=$((pass+1))
else printf '  FAIL  wrote no workspace at all when the override was missing\n'; fail=$((fail+1)); fi
case "$err" in
  *"typo-here"*) printf '  PASS  ...and names the directory it refused to use\n'; pass=$((pass+1)) ;;
  *) printf '  FAIL  omitted the task silently, stderr was: %s\n' "$err"; fail=$((fail+1)) ;;
esac

# --- trust ranks ahead of session volume -------------------------------------------------------
# `hasTrustDialogAccepted` is the flag `claude agents` itself gates on, so it is a direct answer
# where a session count is only a proxy. The busy directory gets THREE live records against the
# trusted one's single record: a resolver that ranked on count alone returns `$H/busy`, so this
# assertion can tell the two implementations apart.
H="$TMPROOT/h-trust"; mkproj "$H/busy" "$H/quiet"
mkjobs "$H" "working:$H/busy" "working:$H/busy" "working:$H/busy" "working:$H/quiet"
mktrust "$H" "100:$H/quiet"
check "an explicitly trusted dir outranks a busier untrusted one" "$H/quiet
live" "$(HOME="$H" "$RESOLVER" --why)"

# ...and the FLAG is what counts, not the entry. `$H/busy` is IN `.claude.json` with the flag
# false; a resolver reading `isinstance(rec, dict)` and ignoring the flag treats both as trusted,
# falls through to the count and answers `$H/busy`. Being listed only means Claude has been opened
# there, which is not the same as the operator having said yes.
H="$TMPROOT/h-untrusted"; mkproj "$H/busy" "$H/quiet"
mkjobs "$H" "working:$H/busy" "working:$H/busy" "working:$H/busy" "working:$H/quiet"
mktrust "$H" "!900:$H/busy" "100:$H/quiet"
check "a listed but UNtrusted dir does not outrank a trusted one" "$H/quiet
live" "$(HOME="$H" "$RESOLVER" --why)"

# The same with no session evidence at all, where `lastStartTime` is the only other signal: the
# untrusted entry is the most recent, so a resolver ignoring the flag answers the untrusted one.
H="$TMPROOT/h-untrusted2"; mkdir -p "$H/.claude/jobs"; mkproj "$H/recent-untrusted" "$H/older-trusted"
mktrust "$H" "!900:$H/recent-untrusted" "100:$H/older-trusted"
check "...and an untrusted entry is not a trusted-rank candidate either" "$H/older-trusted
trusted" "$(HOME="$H" "$RESOLVER" --why)"

# --- one directory spelled two ways is ONE candidate -------------------------------------------
# Sessions record the cwd they were given, so a repo reached through a symlink lands in the
# records under both spellings. Counting them apart splits that directory's evidence and hands
# the election to a third: here `$H/other` has 3 records against 2+2 for the same real directory,
# so a resolver that tallies raw strings answers `$H/other`.
H="$TMPROOT/h-alias"; mkproj "$H/real" "$H/other"
ln -s "$H/real" "$H/link"
mkjobs "$H" "working:$H/real" "working:$H/real" "working:$H/link" "working:$H/link" \
            "working:$H/other" "working:$H/other" "working:$H/other"
check "the same dir reached through a symlink counts once, not twice" "$H/real
live" "$(HOME="$H" "$RESOLVER" --why)"

# --- the filter is applied to the RESOLVED path, not the spelling ------------------------------
# `$H/sneaky` is lexically under $HOME and passes every prefix test as written, while actually
# living OUTSIDE it. It is given the top count so a lexical filter returns it.
#
# The target is a fixture-owned repository outside H, NOT `/`. Pointing it at `/` looked decisive
# and was not: the work-tree walk follows the symlink to `/`, finds no `.git` there, and rejects
# the candidate for the repository rule -- so a resolver with `realpath` deleted still passed, and
# the case was green for a reason it did not claim. Giving the target its own `.git` closes that
# door (the same treatment the harness-root case below already had), which leaves physical-path
# normalization as the only rule that can reject it. `[[plan-assertions-need-reachable-alternatives]]`
H="$TMPROOT/h-lexical"; mkproj "$H/ok"
OUTSIDE="$TMPROOT/outside-any-home"; mkproj "$OUTSIDE/repo"
ln -s "$OUTSIDE/repo" "$H/sneaky"
mkjobs "$H" "working:$H/sneaky" "working:$H/sneaky" "working:$H/sneaky" "working:$H/ok"
check "a \$HOME-spelled symlink OUT of \$HOME is still rejected" "$H/ok
live" "$(HOME="$H" "$RESOLVER" --why)"

# ...and the same for one pointing into the harness root, which is given its own `.git` so the
# work-tree rule cannot be what rejects it.
H="$TMPROOT/h-lexical2"; mkproj "$H/ok" "$H/.claude"; mkdir -p "$H/.claude/jobs"
ln -s "$H/.claude" "$H/sneaky"
mkjobs "$H" "working:$H/sneaky" "working:$H/sneaky" "working:$H/ok"
check "a \$HOME-spelled symlink into \$HOME/.claude is still rejected" "$H/ok
live" "$(HOME="$H" "$RESOLVER" --why)"

# --- with NO session records, a trusted folder still beats the repo guess ----------------------
# Ordered by `lastStartTime`, most recent first. The older entry is deliberately the SHALLOWER
# one, so a resolver that fell back to the depth tie-break returns `$H/old` instead.
H="$TMPROOT/h-trustonly"; mkdir -p "$H/.claude/jobs"; mkproj "$H/old" "$H/deep/recent"
mktrust "$H" "100:$H/old" "900:$H/deep/recent"
check "with no sessions at all, the most recently opened trusted dir wins" "$H/deep/recent
trusted" "$(HOME="$H" "$RESOLVER" --why)"

# The candidate filter still applies to the trust list. On the real machine that list holds four
# directories that no longer exist plus the harness root, so this is measured behaviour, not a
# hypothetical. Both rejections are INDEPENDENTLY decisive: the gone directory is the MOST recent
# entry and is spelled inside `$H/proj`'s checkout so the work-tree rule cannot also reject it, so
# dropping the existence test alone answers `$H/proj/never-created`, and the harness root is
# the next most recent, so dropping the harness test alone answers `$H/.claude`. Ordered the other
# way round — which is how this case was first written — either rejection could be deleted and the
# assertion would not notice. The harness root again carries its own `.git`.
H="$TMPROOT/h-trustfilter"; mkdir -p "$H/.claude/jobs"; mkproj "$H/keep" "$H/.claude" "$H/proj"
mktrust "$H" "900:$H/proj/never-created" "800:$H/.claude" "700:$H/keep"
check "a trusted dir that is harness scratch or gone is still filtered out" "$H/keep
trusted" "$(HOME="$H" "$RESOLVER" --why)"

# A hand-broken trust file must not take the resolver down — session evidence still answers.
H="$TMPROOT/h-badtrust"; mkproj "$H/ok"
mkjobs "$H" "working:$H/ok"
printf '{not json' > "$H/.claude.json"
check "an unparseable ~/.claude.json falls through to session evidence" "$H/ok
live" "$(HOME="$H" "$RESOLVER" --why)"

# --- the no-shell launch path ------------------------------------------------------------------
# VS Code terminal profiles and LaunchAgents run with launchd's bare PATH and no shell rc, which
# is where `bin/fleet` gets its "resolve binaries absolutely" rule. The resolver needs python3, so
# run it with exactly that PATH and nothing else inherited.
H="$TMPROOT/h-path"; mkproj "$H/ok"
mkjobs "$H" "working:$H/ok"
out=$(env -i HOME="$H" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$RESOLVER" --why); rc=$?
check "resolves under the bare launchd PATH with no shell" "$H/ok
live" "$out"
check "...and exits 0 there" "0" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
