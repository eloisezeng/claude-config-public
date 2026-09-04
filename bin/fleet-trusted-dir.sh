#!/usr/bin/env bash
# fleet-trusted-dir.sh — resolve a directory `claude agents` may be launched from.
#
#   fleet-trusted-dir.sh          -> the directory, one line on stdout
#   fleet-trusted-dir.sh --why    -> and a second line: override | live | historical | trusted | repo
#   exit 0                        -> a path was resolved
#   exit 3                        -> nothing resolved; stdout is EMPTY (fail CLOSED)
#
# WHY THIS EXISTS.
# `claude agents` gates on folder trust, so the fleet's write surface has to be launched from
# somewhere Claude already trusts. That used to be a literal — one personal project's path,
# written into `fleet` and again into `fleet-open.sh`. A control (or a default) that NAMES a
# subject can be pointed at a corpse: rename the project, move it, hand the config to a second
# machine, and the fleet's only write surface silently stops working while every other command
# still reads fine. Derive it from the live set instead.
#
# TWO independent pieces of evidence are combined, because each answers half the question.
#
#   * Is this folder TRUSTED?  `~/.claude.json` records `hasTrustDialogAccepted` per project —
#     the very flag `claude agents` gates on. That is a direct answer, not a proxy.
#   * Is it the folder being WORKED IN?  `~/.claude/jobs/*/state.json` records a cwd per
#     background session, so counting them says what the machine is actually doing right now.
#
# Neither alone is enough, and the measured data says why. The trust list on this machine holds
# nine entries, of which four no longer exist, one is `$HOME/Coding` (a workspace root, which
# offers every project at once) and one is `$HOME/.claude` (harness scratch) — so trust without
# the candidate filter and without a live signal would answer badly. Conversely the session cwds
# include harness scratch under `~/.claude/jobs/*/tmp/`, which no one ever trusted. Trust ranks
# first, session volume breaks the tie, and the filter throws out what neither should offer:
# a candidate must exist, sit strictly under $HOME, sit outside the harness tree, and be inside a
# git work tree — which is what separates a project from the drawer that holds projects.
#
# On this machine that resolves to the same directory the old literal named — which is the point:
# it agrees today and keeps agreeing after the project moves.
#
# ONE implementation, not two. `fleet` is bash and `fleet-open.sh` is bash wrapping a Python
# heredoc; writing this rule twice in two languages would recreate exactly the defect it fixes.
set -uo pipefail

why=0
case "${1:-}" in
  --why) why=1 ;;
  '') ;;
  *) printf 'usage: fleet-trusted-dir.sh [--why]\n' >&2; exit 2 ;;
esac

emit() { # path provenance
  printf '%s\n' "$1"
  [ "$why" -eq 1 ] && printf '%s\n' "$2"
  exit 0
}

# --- 1. the operator's explicit instruction --------------------------------------------------
# Returned even when it does not exist. An override is an instruction, not a hint: silently
# substituting a working directory for the one the operator named would hide the typo instead of
# reporting it. Callers check existence and say so themselves (`fleet doctor` prints
# `*** MISSING ***`; `fleet write` refuses).
#
# Existence is the operator's business. $HOME is not: `claude agents --cwd $HOME` admits every
# session on the machine, which is the exact opposite of narrowing, and `fleet` documents that as
# the one thing it must never do. So the two hazards that cannot be anyone's deliberate choice --
# $HOME itself and / -- are REFUSED here rather than emitted, and an override that exists is
# emitted as its PHYSICAL path: `.` and a symlink both resolve, and a task file that records `.`
# records a different directory for every process that reads it.
#
# The rest of the candidate filter below still does NOT apply. An operator naming a directory
# outside $HOME, or inside the harness tree, has made a choice this script has no better
# information than; only the two answers that widen the picker to the whole machine are refused.
if [ -n "${CLAUDE_FLEET_DIR:-}" ]; then
  if fd_p="$(cd "$CLAUDE_FLEET_DIR" 2>/dev/null && pwd -P)"; then
    fd_home="$(cd "$HOME" 2>/dev/null && pwd -P)" || fd_home="$HOME"
    case "$fd_p" in
      "$fd_home"|/)
        printf 'fleet-trusted-dir: CLAUDE_FLEET_DIR=%s resolves to %s, which would open the fleet picker over every session on the machine. Name a project directory.\n' \
          "$CLAUDE_FLEET_DIR" "$fd_p" >&2
        exit 3 ;;
    esac
    emit "$fd_p" override
  fi
  emit "$CLAUDE_FLEET_DIR" override   # names nothing that exists: emitted so the caller can say so
fi

# VS Code terminal profiles and launchd agents run this with NO shell, so PATH is the bare
# /usr/bin:/bin:/usr/sbin:/sbin. Resolve python3 by searching real locations, the same way
# `fleet` resolves node and claude, rather than trusting PATH.
PY=""
for p in "$(command -v python3 2>/dev/null || true)" \
         /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [ -n "$p" ] && [ -x "$p" ]; then PY="$p"; break; fi
done

# --- 2, 3 and 4. trust record + the cwds Claude sessions actually ran in ----------------------------
# `live` (working/blocked) is preferred over `historical` (any state) because a directory some
# session is in RIGHT NOW is the one the fleet view most wants to be pointed at. A finished
# session still proves its directory was trusted, so it is the second rank rather than discarded.
# Defined as a function and CALLED from the substitution, never inlined as
# `out="$("$PY" - <<'PYEOF' ...)"`. bash 3.2 (what /usr/bin/env bash is on macOS) matches the
# closing paren of a command substitution with a lexer that tracks quotes but not heredocs, so a
# single apostrophe anywhere in the Python below would make the whole script a syntax error.
probe() { "$PY" - <<'PYEOF'
import calendar, collections, glob, json, os, sys, time

# A record whose state is still `working` is evidence of a LIVE session only while it is fresh:
# a session killed by a crash, a reboot or a `kill -9` never writes its terminal state, so its
# directory would otherwise outrank the one actually in use forever. `fleet ids` already answers
# this question -- state in (working, blocked) AND the record younger than MAXAGE minutes -- and
# 60 is the default it ships. The two constants must agree, and a control in
# tests/fleet-trusted-dir.test.sh reads both files and asserts they do.
#
# A stale record is DEMOTED, never discarded: it still proves that directory was worked in, which
# is exactly what rank 3 (`historical`) is for.
LIVE_MAX_AGE_MIN = 60

# Work in PHYSICAL paths throughout — filter, COUNT and return. macOS resolves /var through
# /private/var and a home directory can itself be a link, so the same directory reaches this
# script spelled two ways. Filtering on the resolved form while counting the raw one splits one
# directory's evidence across two tallies and can hand the election to a third; and a lexical
# `$HOME/link-to-root` would pass a prefix test that a resolved one rejects.
home = os.path.realpath(os.path.expanduser("~"))
harness = os.path.join(home, ".claude")

def acceptable(d):
    # A candidate must be a directory that still exists: a live session's worktree can be
    # removed out from under it, and returning a path that is gone is worse than returning
    # nothing, because the caller cannot tell the difference from a working answer.
    if not d or not os.path.isdir(d):
        return False
    d = os.path.realpath(d)
    # Strictly UNDER $HOME. Never $HOME itself and never "/": `claude agents --cwd $HOME`
    # admits every session on the machine, which is the exact opposite of narrowing, and
    # `fleet` already documents that as the thing it must not do.
    if not d.startswith(home + os.sep):
        return False
    # $HOME/.claude is harness scratch — job dirs, transcripts, worktree bookkeeping — not a
    # workspace anyone means by "the trusted repo". The root ITSELF has to be named, not just
    # its children: it carries hasTrustDialogAccepted on this machine, so a prefix-only test
    # hands `claude agents` the harness directory the moment session evidence runs out.
    # A project's own .claude/worktrees/* is a different thing and stays eligible.
    if d == harness or d.startswith(harness + os.sep):
        return False
    # ...and it must be a REPOSITORY, not a drawer that holds repositories. $HOME/Coding carries
    # hasTrustDialogAccepted on this machine, and handing `claude agents` a workspace root offers
    # every project at once -- the same widening as $HOME, one level down. Walking up for .git is
    # what git itself does to answer "am I in a work tree" (a directory in a checkout, a file in a
    # linked worktree), and it is the only measurable difference between the two: every real
    # candidate here is inside a checkout, and no aggregator root is.
    p = d
    while p.startswith(home + os.sep):
        if os.path.exists(os.path.join(p, ".git")):
            return True
        p = os.path.dirname(p)
    return False

# --- the folder-trust record ------------------------------------------------------------
# `~/.claude.json` holds one entry per project Claude has been opened in, and
# `hasTrustDialogAccepted` is the flag the trust dialog sets. It is the closest thing the
# machine has to a direct answer, so it ranks ahead of session volume. `lastStartTime` (epoch
# ms) orders trusted directories that carry no session evidence at all.
trusted, started = set(), {}
try:
    with open(os.path.join(home, ".claude.json")) as fh:
        for path, rec in (json.load(fh).get("projects") or {}).items():
            if isinstance(rec, dict) and rec.get("hasTrustDialogAccepted"):
                rp = os.path.realpath(path)
                trusted.add(rp)
                ts = rec.get("lastStartTime")
                started[rp] = ts if isinstance(ts, (int, float)) else -1
except Exception:
    pass              # absent or hand-broken: fall through to session evidence alone

# --- how old is a session, really ---------------------------------------------------------
# NOT `state.json`'s mtime. That file is rewritten by anything that touches the job -- the
# daemon on a wake, a notification, a peer's kill of an unrelated process, a supervisor's
# guard write -- so a seat that has produced no output for hours reads as freshly active and
# keeps its directory at rank 1 forever. Age from the last ASSISTANT record in the session's
# own transcript instead: that timestamp only moves when the session actually produced a turn.
# `[[liveness-ages-from-the-last-turn-not-file-mtime]]`
#
# THE BOUND, stated beside the code: only the last TAIL_BYTES of the transcript is read, so a
# session whose final assistant turn is further back than that falls through to the weaker
# signals below rather than being reported ancient. Transcripts here reach hundreds of KB and
# this runs on every `fleet-open`, so reading them whole is not on offer.
#
# Three tiers, strongest first, because each weaker one answers a case the stronger cannot:
#   1. the last `assistant` record  -- real progress, the property being measured;
#   2. the last record of ANY type  -- a seat dispatched moments ago has a user turn and no
#      assistant turn yet, and it IS live; a seat that died holding only its dispatch prompt
#      is correctly old, which mtime alone would report as fresh;
#   3. `state.json`'s mtime         -- no readable transcript at all (the path is absent or
#      gone: 3 of this machine's 51 working rows already pointed at a vanished linkScanPath).
#      Weakest and last, never first.
TAIL_BYTES = 256 * 1024

def transcript_age_epoch(path):
    if not path or not isinstance(path, str):
        return None
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            fh.seek(max(0, size - TAIL_BYTES))
            chunk = fh.read()
    except OSError:
        return None
    # A seek into the middle of the file lands mid-line, so the first element may be a fragment.
    # It is NOT dropped: `json.loads` rejects it, which is the same outcome by a rule that also
    # covers a hand-edited or half-written record, and dropping it blind would discard a whole
    # record on the seeks that happen to land on a boundary. A mutant disabling a pop here was
    # unkillable for exactly that reason -- the parse was always what protected this.
    # `[[a-surviving-mutant-may-mean-the-property-is-unobservable]]`
    lines = chunk.split(b"\n")
    any_ts = None
    for raw in reversed(lines):
        raw = raw.strip()
        if not raw:
            continue
        try:
            rec = json.loads(raw)
        except Exception:
            continue
        if not isinstance(rec, dict):
            continue
        ts = rec.get("timestamp")
        if not isinstance(ts, str):
            continue
        try:
            # The harness writes UTC with a trailing Z. `timegm` reads the tuple as UTC;
            # `mktime` would read it as local time and shift every age by the offset.
            epoch = calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
        except Exception:
            continue
        if rec.get("type") == "assistant":
            return epoch                      # tier 1: stop at the first one walking backwards
        if any_ts is None:
            any_ts = epoch                    # tier 2: remember the latest record of any type
    return any_ts

now = time.time()
records = []
for p in glob.glob(os.path.join(home, ".claude", "jobs", "*", "state.json")):
    try:
        with open(p) as fh:
            d = json.load(fh)
    except Exception:
        continue          # a half-written or hand-edited record is skipped, never fatal
    if not isinstance(d, dict):
        continue
    turn = transcript_age_epoch(d.get("linkScanPath"))
    if turn is None:
        try:
            turn = os.stat(p).st_mtime        # tier 3
        except OSError:
            continue
    records.append((d.get("state"), d.get("cwd"), (now - turn) / 60.0))

def mode(cwds):
    counts = collections.Counter(os.path.realpath(c) for c in cwds if acceptable(c))
    if not counts:
        return None
    # Deterministic total order, so two machines with the same jobs give the same answer:
    # an explicitly TRUSTED directory first (that is the property being resolved, and the
    # session count is only a proxy for it), then the highest count, then the SHALLOWEST path
    # (a project root beats a worktree nested inside it), then by code point — Python compares
    # str by code point, so unlike a shell `sort` this does not move with the locale.
    # No ancestor walking: the parent of a trusted repo is not itself known to be trusted.
    return min(counts.items(),
               key=lambda kv: (kv[0] not in trusted, -kv[1], kv[0].count(os.sep), kv[0]))[0]

live = mode(c for s, c, age in records
            if s in ("working", "blocked") and age <= LIVE_MAX_AGE_MIN)
if live:
    print(live); print("live"); sys.exit(0)

hist = mode(c for _, c, _age in records)
if hist:
    print(hist); print("historical"); sys.exit(0)

# --- no session has ever run anywhere acceptable ------------------------------------------
# Still better than guessing: a folder the operator explicitly trusted, most recently opened
# first. Same filter, so `$HOME/Coding` survives but `$HOME/.claude` and the four trusted
# directories that no longer exist do not.
cand = sorted((d for d in trusted if acceptable(d)),
              key=lambda d: (-started.get(d, -1), d.count(os.sep), d))
if cand:
    print(os.path.realpath(cand[0])); print("trusted"); sys.exit(0)
sys.exit(1)
PYEOF
}

if [ -n "$PY" ]; then
  out="$(probe 2>/dev/null)"
  if [ -n "$out" ]; then
    emit "$(printf '%s' "$out" | sed -n 1p)" "$(printf '%s' "$out" | sed -n 2p)"
  fi
fi

# --- 5. the repo this script ships in ---------------------------------------------------------
# The weakest rank, and deliberately last: that this script SHIPS somewhere is not evidence that
# the folder is trusted. It is reached only on a machine with no trust record and no session
# history at all, it is reported as provenance `repo` so a reader can see the answer is a guess
# rather than a measurement, and it is still subject to the same filter — an unpacked copy in
# /opt or directly in $HOME falls through to the exit 3 below rather than being returned.
#
# The installer links `~/.claude/bin` at the repo's `bin/`, so $0 arrives through a symlink and
# `dirname $0` is the LINK's directory, not the repo's. Resolve it before asking git.
self="$0"
while [ -L "$self" ]; do
  link="$(readlink "$self")"
  case "$link" in
    /*) self="$link" ;;
    *)  self="$(cd "$(dirname "$self")" && pwd)/$link" ;;
  esac
done
selfdir="$(cd "$(dirname "$self")" 2>/dev/null && pwd)" || selfdir=""

if [ -n "$selfdir" ]; then
  # git must ANSWER. Without it there is no evidence this is a checkout at all -- an unpacked
  # tarball, a stray copy, a `bin/` someone rsynced -- and `dirname "$selfdir"` would hand
  # `claude agents` a directory chosen for no reason but where this file happens to sit. That is
  # a guess with nothing behind it, so it falls through to the exit 3 below instead.
  repo="$(git -C "$selfdir" rev-parse --show-toplevel 2>/dev/null || true)"
  # The same filter as rules 2 and 3: a copy dropped in /opt or directly in $HOME is not an
  # answer, and pretending otherwise would launch the picker over the whole machine.
  # git answers with a RESOLVED path while $HOME may not be one (macOS /var -> /private/var), so
  # resolve both sides before comparing. Comparing the two as typed is how this rule rejected a
  # perfectly good repo under a symlinked home.
  home_p="$(cd "$HOME" 2>/dev/null && pwd -P)" || home_p="$HOME"
  repo_p="$(cd "$repo" 2>/dev/null && pwd -P)" || repo_p=""
  case "$repo_p" in
    ""|"$home_p"/.claude/*) : ;;
    "$home_p"/*) emit "$repo_p" repo ;;
  esac
fi

# Nothing resolved. Say nothing on stdout so a caller substituting `$(...)` gets the empty string
# rather than a plausible wrong directory, and fail closed.
exit 3
