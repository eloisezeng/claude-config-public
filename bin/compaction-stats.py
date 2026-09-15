#!/usr/bin/env python3
"""Measure auto-compaction thrashing, and judge a change against a pinned baseline.

WHY THIS EXISTS
---------------
On 2026-09-15 the user approved raising `autoCompactWindow` from 200,000 to
400,000, and asked that the fix be judged on the WORST 60-MINUTE WINDOW PER
SESSION rather than on an average: a session that compacts six times inside one
hour is thrashing even if its all-day rate looks calm.

The success criterion she set:

    the p90 of `max_boundaries_per_60min`, taken over the sessions in the
    window, drops from the pinned baseline of 6 to <= 3.

The baseline is `compaction-stats.baseline.csv` in this directory: 616 real
sessions over the 30 days ending 2026-09-14, measured BEFORE the change. It is
pinned as a fixture so the after-measurement runs the identical rule over the
identical definition. Re-deriving the baseline later would let the rule drift
and quietly re-define success, which is the failure this file exists to stop.

Every number the report prints is COUNTED from the transcripts named in its own
output. Nothing here reads a configured setting and reports it as a rate.

USAGE
-----
    compaction-stats.py measure --since 2026-09-15 [--roots ~/.claude ~/.claude1]
        Scan transcripts, print per-session stats and the p90 verdict.

    compaction-stats.py baseline
        Print the pinned baseline's statistics without scanning anything.

    compaction-stats.py measure --since 2026-09-15 --csv out.csv
        Also write the per-session rows, in the baseline's own column order.

PRIVACY
-------
The `project` column of any emitted CSV is a salted hash, never the directory
name: this repository is sanitized to a PUBLIC mirror, and a worktree name such
as `netorg-notification-consolidation` describes unreleased work that no token
sanitizer would flag. Hashing keeps per-project grouping available without
publishing the names.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import os
import sys
from pathlib import Path

WINDOW_SECONDS = 60 * 60
BASELINE_P90 = 6          # measured; see compaction-stats.baseline.csv
TARGET_P90 = 3            # the user's success criterion, 2026-09-15
PROJECT_SALT = "compaction-stats-v1"

HERE = Path(__file__).resolve().parent
BASELINE_CSV = HERE / "compaction-stats.baseline.csv"

COLUMNS = [
    "session", "root", "project", "start_utc", "end_utc", "duration_h",
    "boundaries", "boundaries_per_hour", "max_boundaries_per_60min",
]


# --------------------------------------------------------------------------
# The decision rule, as pure functions. These are what the tests pin.
# --------------------------------------------------------------------------

def worst_window(timestamps, window_seconds=WINDOW_SECONDS):
    """Largest number of timestamps falling inside any window_seconds interval.

    The interval is half-open on the right and anchored on an observation, so a
    run of boundaries exactly window_seconds apart counts as 2, not 1: two
    compactions an hour apart are two events in one hour's span.

    timestamps: an iterable of epoch seconds, in any order.
    """
    xs = sorted(float(t) for t in timestamps)
    if not xs:
        return 0
    best = 1
    lo = 0
    for hi in range(len(xs)):
        while xs[hi] - xs[lo] > window_seconds:
            lo += 1
        best = max(best, hi - lo + 1)
    return best


def nearest_rank_percentile(values, q):
    """Nearest-rank percentile: the smallest value at or above rank ceil(q*N).

    Chosen over interpolation because the statistic is a COUNT. An interpolated
    "p90 of 5.4 compactions" is not a thing any session did, and a verdict that
    turns on a fractional count invites an argument about the interpolation
    rather than about the change.
    """
    xs = sorted(values)
    if not xs:
        raise ValueError("nearest_rank_percentile of an empty set is undefined")
    if not 0.0 < q <= 1.0:
        raise ValueError(f"quantile must be in (0, 1], got {q!r}")
    k = max(1, math.ceil(q * len(xs)))
    return xs[k - 1]


def verdict(observed_p90, baseline_p90=BASELINE_P90, target_p90=TARGET_P90):
    """Judge one measurement. Returns (passed: bool, line: str).

    PASS requires observed <= target. A drop that misses the target is reported
    as IMPROVED-BUT-SHORT rather than as a pass, because the criterion the user
    set is an absolute ceiling and not a direction of travel.
    """
    if observed_p90 <= target_p90:
        return True, (
            f"PASS: p90 worst-60-minute window is {observed_p90}, "
            f"at or below the target of {target_p90} (baseline {baseline_p90})."
        )
    if observed_p90 < baseline_p90:
        return False, (
            f"IMPROVED BUT SHORT: p90 is {observed_p90}, down from the baseline "
            f"{baseline_p90} but above the target of {target_p90}."
        )
    if observed_p90 == baseline_p90:
        return False, (
            f"NO CHANGE: p90 is {observed_p90}, equal to the baseline; "
            f"the target is {target_p90}."
        )
    return False, (
        f"WORSE: p90 is {observed_p90}, above the baseline {baseline_p90}; "
        f"the target is {target_p90}."
    )


def hash_project(name, salt=PROJECT_SALT):
    """Stable, non-reversing label for a project directory name."""
    return hashlib.sha256((salt + "\x00" + name).encode()).hexdigest()[:12]


# --------------------------------------------------------------------------
# Measurement
# --------------------------------------------------------------------------

def parse_ts(s):
    """Parse a transcript ISO-8601 timestamp into epoch seconds, or None."""
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def scan_transcript(path, automatic_only=True):
    """Return (boundary_epochs, first_ts, last_ts) for one .jsonl transcript.

    A boundary is a record with type "system" and subtype "compact_boundary".
    With automatic_only, a boundary whose compactMetadata.trigger is present and
    is not "auto" is excluded: a compaction the user asked for by hand is not
    thrashing, and counting it would let a deliberate /compact redden the report.
    """
    bounds = []
    first = last = None
    try:
        fh = open(path, "r", errors="replace")
    except OSError:
        return [], None, None
    with fh:
        for line in fh:
            # Cheap prefilter: the vast majority of lines are not boundaries,
            # and json.loads on a 150 MB transcript is the whole runtime.
            is_boundary = "compact_boundary" in line
            if not is_boundary and '"timestamp"' not in line:
                continue
            try:
                r = json.loads(line)
            except (ValueError, TypeError):
                continue
            ts = parse_ts(r.get("timestamp"))
            if ts is not None:
                if first is None:
                    first = ts
                last = ts
            if not is_boundary:
                continue
            if r.get("type") != "system" or r.get("subtype") != "compact_boundary":
                continue
            if r.get("isSidechain"):
                continue
            trigger = (r.get("compactMetadata") or {}).get("trigger")
            if automatic_only and trigger is not None and trigger != "auto":
                continue
            if ts is not None:
                bounds.append(ts)
    return bounds, first, last


def find_transcripts(roots):
    for root in roots:
        projects = Path(root).expanduser() / "projects"
        if not projects.is_dir():
            continue
        for path in projects.glob("*/*.jsonl"):
            yield Path(root).expanduser().name, path.parent.name, path


def measure(roots, since_epoch=None, until_epoch=None, automatic_only=True):
    """Per-session rows for every session with at least one counted boundary."""
    rows = []
    for root_name, project, path in find_transcripts(roots):
        bounds, first, last = scan_transcript(path, automatic_only=automatic_only)
        if not bounds:
            continue
        if since_epoch is not None:
            bounds = [b for b in bounds if b >= since_epoch]
        if until_epoch is not None:
            bounds = [b for b in bounds if b <= until_epoch]
        if not bounds:
            continue
        span_h = ((last - first) / 3600.0) if (first and last and last > first) else 0.0
        rows.append({
            "session": path.stem[:8],
            "root": root_name,
            "project": hash_project(project),
            "start_utc": dt.datetime.fromtimestamp(first, dt.timezone.utc).isoformat()
                          .replace("+00:00", "Z") if first else "",
            "end_utc": dt.datetime.fromtimestamp(last, dt.timezone.utc).isoformat()
                        .replace("+00:00", "Z") if last else "",
            "duration_h": round(span_h, 3),
            "boundaries": len(bounds),
            "boundaries_per_hour": round(len(bounds) / span_h, 3) if span_h > 0 else "",
            "max_boundaries_per_60min": worst_window(bounds),
        })
    return rows


def load_baseline(path=BASELINE_CSV):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def summarize(rows, label):
    worsts = [int(r["max_boundaries_per_60min"]) for r in rows]
    if not worsts:
        print(f"{label}: no sessions with a counted boundary.")
        return None
    p = lambda q: nearest_rank_percentile(worsts, q)
    print(f"{label}")
    print(f"  sessions counted:           {len(rows)}")
    print(f"  boundaries counted:         {sum(int(r['boundaries']) for r in rows)}")
    print(f"  worst 60-minute window      p50 {p(.50)}  p75 {p(.75)}  "
          f"p90 {p(.90)}  p95 {p(.95)}  max {max(worsts)}")
    return p(.90)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("measure", help="scan transcripts and judge against the baseline")
    m.add_argument("--roots", nargs="+", default=["~/.claude", "~/.claude1"],
                   help="config roots to scan (default: both roots on this machine)")
    m.add_argument("--since", help="ISO date; count only boundaries at or after it")
    m.add_argument("--until", help="ISO date; count only boundaries at or before it")
    m.add_argument("--csv", help="also write the per-session rows here")
    m.add_argument("--include-manual", action="store_true",
                   help="count hand-invoked /compact boundaries too (default: automatic only)")

    sub.add_parser("baseline", help="print the pinned baseline's statistics")

    args = ap.parse_args(argv)

    if args.cmd == "baseline":
        rows = load_baseline()
        p90 = summarize(rows, f"PINNED BASELINE ({BASELINE_CSV.name}, measured before 2026-09-15)")
        if p90 != BASELINE_P90:
            print(f"  WARNING: the fixture's p90 is {p90}, not the pinned {BASELINE_P90}.",
                  file=sys.stderr)
            return 2
        print(f"  success criterion:          p90 <= {TARGET_P90}")
        return 0

    since = parse_ts(args.since + "T00:00:00Z") if args.since and "T" not in args.since \
        else parse_ts(args.since)
    until = parse_ts(args.until + "T23:59:59Z") if args.until and "T" not in args.until \
        else parse_ts(args.until)

    rows = measure([os.path.expanduser(r) for r in args.roots],
                   since_epoch=since, until_epoch=until,
                   automatic_only=not args.include_manual)

    base = load_baseline()
    summarize(base, f"PINNED BASELINE ({len(base)} sessions, 30 days to 2026-09-14)")
    print()
    window = f"since {args.since}" if args.since else "all time"
    observed = summarize(rows, f"MEASURED ({window}, roots {', '.join(args.roots)})")
    print()
    if observed is None:
        print("VERDICT: not measurable — no session in the window recorded a boundary.")
        return 1
    passed, line = verdict(observed)
    print(f"VERDICT: {line}")

    if args.csv:
        with open(args.csv, "w", newline="") as fh:
            # lineterminator="\n": csv defaults to CRLF, and the pinned baseline
            # is a committed artifact. A fixture that differs from a fresh
            # measurement only by line endings makes every diff unreadable.
            w = csv.DictWriter(fh, fieldnames=COLUMNS, lineterminator="\n")
            w.writeheader()
            w.writerows(rows)
        print(f"per-session rows written to {args.csv}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
