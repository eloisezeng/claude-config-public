#!/usr/bin/env python3
"""Measure and ratchet the SESSION-START context cost of this config repo.

WHY THIS EXISTS
---------------
Two files in this repo are injected into the context of *every* Claude session,
unconditionally, before the user has typed anything:

  * CLAUDE.md                   -- loaded as global instructions (via the
                                   ~/.claude/CLAUDE.md symlink), and loaded a
                                   SECOND time as project instructions whenever
                                   the session's cwd is this repo.
  * memories/global/MEMORY.md   -- injected by inject-global-memory.sh, a
                                   SessionStart hook, TRUNCATED to its
                                   `budget=` character cap.

Everything else is lazy.  In particular `skills/*/SKILL.md` is read only when a
skill is actually invoked, so skills are NOT part of the session-start bill and
trimming them buys nothing.

Measure what REACHES CONTEXT, not what is on disk.  MEMORY.md is 34,113 B /
8,479 tokens on disk but only ~11.7 K characters / 2,937 tokens are injected;
the rest is silently cut.  An early version of this tool billed the file and
overstated the session cost by 39%.  The real figures, measured 2026-09-02:
14,270 tokens in any project, 25,603 inside a claude-config clone (where the
same tracked CLAUDE.md is billed twice -- once as global instructions via the
~/.claude/CLAUDE.md symlink, once as project instructions from the cwd clone).

That truncation is the headline defect, and it is a CORRECTNESS problem rather
than an efficiency one: 69 of 123 memories (56%) never reach any session.  See
dropped_index_lines().

Both files carry an explicit one-line-per-entry invariant in their own prose
("The one-line rule lives here; the why/how is in the linked global memory",
"index lines stay one line per memory").  Both had drifted far past it -- the
longest directive was 1,535 B and the longest index line 735 B -- because
nothing measured the drift.  Prose invariants that nothing executes do not hold.

THE UNIT IS BYTES, NOT TOKENS
-----------------------------
Tokens are the quantity we actually care about, but a token count needs
tiktoken, which is not installed everywhere this repo is cloned.  A budget that
silently changes unit between machines is a budget that cannot ratchet: the
baseline recorded on one Mac would redden on the other for no reason.

So the ENFORCED unit is bytes -- exact, dependency-free, identical everywhere.
Tokens are reported as an informational column when tiktoken happens to be
importable.  A dependency-free token *approximation* was measured and rejected:
it ran +39% high on CLAUDE.md with per-line error up to 73%, which is far too
loose to hang a per-line ceiling on.  Bytes track tokens closely enough for a
ratchet (this corpus runs ~4.33 B/token) and are honest about what they are.

THE RATCHET
-----------
bin/context-budget.json holds, per metric, an enforced `limit` and an
aspirational `target`.  `--check` fails if any measurement exceeds its `limit`.
`--set-baseline` rewrites the limits from the current measurements but REFUSES
to raise any of them.  That is the whole anti-accumulation mechanism: the
budget is green the day it ships (limits start at today's values, so no risky
mass rewrite is forced) and can only ever move down.  Growth has to be paid for
by an equal-or-larger trim somewhere else in the same file.

`target` is the value the invariant actually asks for.  It is reported as debt,
never enforced, so that the gap stays visible instead of being quietly accepted.

TRIMMING SAFELY
---------------
`--report` does not just rank the offenders.  For each over-target line it
extracts the distinctive facts (backticked identifiers, measured numbers,
quoted strings) and reports which of them do NOT appear in the bodies of the
memories that line links to.  Those are the facts a naive trim would destroy;
they must be moved into the body first.  Measured 2026-09-02: 11 of the worst
directives carried facts -- `loop.py`, `ci-green.sh`, `30.5s`, `10x` -- that
existed nowhere else, so "the body already says it" was false.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "bin", "context-budget.json")

# ---------------------------------------------------------------------------
# Pure extraction helpers.  Every one takes text and returns data; none of them
# touches the filesystem, so the test can drive them on synthetic input.
# ---------------------------------------------------------------------------


def section(text: str, heading: str) -> str:
    """Return the lines under `heading` up to the next same-or-higher heading.

    Used to scope the directive scan to '## Working directives' so that bullets
    elsewhere in CLAUDE.md (the Memory and Tools sections) are not counted as
    directives.  Returns '' when the heading is absent rather than raising, so
    a renamed section shows up as an empty metric rather than a crash -- the
    caller checks for that explicitly.
    """
    lines = text.split("\n")
    try:
        i = lines.index(heading)
    except ValueError:
        return ""
    for j in range(i + 1, len(lines)):
        if lines[j].startswith("## "):
            return "\n".join(lines[i + 1 : j])
    return "\n".join(lines[i + 1 :])


def bullets(text: str) -> list[str]:
    """Top-level '- ' bullets, excluding indented continuation bullets.

    A directive or index entry is one physical line by construction; nested
    bullets belong to whatever bullet encloses them and are not separate
    entries.
    """
    return [l for l in text.split("\n") if l.startswith("- ")]


def index_lines(text: str) -> list[str]:
    """MEMORY.md index entries.

    Any top-level bullet, not just the `- [slug](slug.md) - hook` form: entries
    also get written pre-compacted as `- slug - hook`, and a predicate keyed to
    the link form silently under-counts them. That mattered -- it made the
    on-disk count one SHORT of the injected count and reported -1 dropped.
    Match what the injection matches.
    """
    return [l for l in text.split("\n")
            if l.startswith("- ") and not l.lstrip("- ").startswith("<!--")]


def links(line: str) -> list[str]:
    """The memory slugs a line points at, in EITHER of the two link forms.

    CLAUDE.md directives cite memories as `[[slug]]` wikilinks; MEMORY.md index
    lines cite them as `[slug](slug.md)` markdown links.  Matching only the
    wikilink form makes every index line look like it links nothing, which in
    turn reports all of its facts as orphaned -- a false positive that would
    send someone hand-copying text into a body that already contains it.
    """
    pairs = re.findall(r"\[\[([a-z0-9-]+)\]\]|\]\(([a-z0-9-]+)\.md\)", line)
    return [wiki or md for wiki, md in pairs]


_FACT = re.compile(
    r"`[^`]+`"  # backticked identifiers, paths, commands
    r"|\"[^\"]{4,}\""  # quoted phrases
    r"|\d[\d,.]*\s?(?:ms|s|B|KB|MB|%|x|×)"  # measured quantities with a unit
)


def facts(line: str) -> set[str]:
    """Distinctive, checkable claims in a line.

    Deliberately narrow: identifiers, quoted phrases and measured quantities.
    Bare integers are excluded because they match noise ('one of 3 lenses')
    and would drown the signal.  The wikilinks themselves are stripped -- a
    line always names the memory it points at, and that is not a fact the body
    needs to repeat.
    """
    out = set()
    for f in _FACT.findall(line):
        s = f.strip("`\" ")
        if s.startswith("[[") or len(s) < 3:
            continue
        out.add(s)
    return out


def orphan_facts(line: str, bodies: dict[str, str]) -> list[str]:
    """Facts in `line` that appear in none of the memory bodies it links to.

    These are exactly the facts that would be LOST by trimming the line down to
    its rule, so they have to be moved into the body first.  A line linking no
    memory returns all of its facts: there is nowhere for them to have been
    written down.
    """
    text = " ".join(bodies.get(n, "") for n in links(line))
    return sorted(f for f in facts(line) if f not in text)


# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------


def measure(root: str) -> dict:
    """Measure every eagerly-loaded artifact.  Returns plain data."""
    claude_md = open(os.path.join(root, "CLAUDE.md"), encoding="utf-8").read()
    memory_md = open(
        os.path.join(root, "memories", "global", "MEMORY.md"), encoding="utf-8"
    ).read()

    directives = bullets(section(claude_md, "## Working directives"))
    idx = index_lines(memory_md)

    mem_dir = os.path.join(root, "memories", "global")
    bodies = {}
    for fn in os.listdir(mem_dir):
        if fn.endswith(".md") and fn != "MEMORY.md":
            bodies[fn[:-3]] = open(
                os.path.join(mem_dir, fn), encoding="utf-8"
            ).read()

    return {
        "claude_md_bytes": len(claude_md.encode()),
        "memory_md_bytes": len(memory_md.encode()),
        "directive_count": len(directives),
        "index_count": len(idx),
        "directive_max_bytes": max((len(l.encode()) for l in directives), default=0),
        "index_max_bytes": max((len(l.encode()) for l in idx), default=0),
        "directive_mean_bytes": (
            sum(len(l.encode()) for l in directives) // max(len(directives), 1)),
        "index_mean_bytes": (
            sum(len(l.encode()) for l in idx) // max(len(idx), 1)),
        "index_dropped": dropped_index_lines(memory_md, root),
        "index_hook_chars_lost": hook_chars_lost(root),
        "_directives": directives,
        "_index": idx,
        "_bodies": bodies,
    }


def injection_budget(root: str) -> int:
    """The character cap inject-global-memory.sh applies to the memory index.

    Read from the hook rather than duplicated here, so the two cannot drift.
    A budget this code invented would measure a truncation that does not
    happen, or miss one that does.
    """
    src = open(os.path.join(root, "inject-global-memory.sh"), encoding="utf-8").read()
    m = re.search(r"^budget=(\d+)", src, re.M)
    if not m:
        raise SystemExit(
            "context-budget: could not find `budget=` in inject-global-memory.sh; "
            "the injection cap moved and this tool would silently measure nothing"
        )
    return int(m.group(1))


def run_hook(root: str) -> str:
    """The text inject-global-memory.sh actually injects.

    Run the hook; never reimplement its arithmetic here. A second copy of that
    arithmetic is a second thing to keep in sync, and its failure mode is
    reporting zero loss while the hook silently loses half the index.
    """
    return subprocess.run(
        ["bash", os.path.join(os.path.abspath(root), "inject-global-memory.sh")],
        capture_output=True,
        text=True,
        env={**os.environ,
             # ABSOLUTE: the hook embeds this path in its header line, so a
             # relative root shortens the header and leaves room for one extra
             # entry -- measuring a truncation that production does not have.
             "CLAUDE_GLOBAL_MEMORY_DIR": os.path.join(
                 os.path.abspath(root), "memories", "global")},
    ).stdout


def hook_chars_lost(root: str) -> int:
    """Hook text the injection abbreviates away, in characters.

    The injection no longer DROPS entries -- it caps every hook to the longest
    length that fits, so every memory stays listed by slug. What is lost is now
    hook prose, and this is the number that measures it. It falls when a long
    index line is rewritten shorter, which is exactly the trim worth making:
    the same budget then buys a higher cap for every other entry.

    Zero when nothing is abbreviated. Parsed from the hook's own notice rather
    than recomputed, for the reason in run_hook().
    """
    m = re.search(r"(\d+) chars cut", run_hook(root))
    return int(m.group(1)) if m else 0


def dropped_index_lines(memory_md: str, root: str) -> int:
    """How many index entries the SessionStart hook silently discards.

    This is the metric that actually matters, and it is not a token-efficiency
    metric -- it is a correctness one.  The hook truncates the index to
    `budget` characters and appends a one-line notice.  A memory past the cut
    is written, indexed, and completely invisible to every session: exactly
    the failure that left three memories in one project, one of them an open
    decision, unseen for five weeks.

    Measured 2026-09-02: 69 of 123 entries (56%) were being dropped, and
    nothing anywhere reported it.  The index is newest-first, so the entries
    lost are the OLDEST -- which is not the same as the least important.

    Counted by RUNNING the hook and diffing, never by reimplementing its
    truncation arithmetic here.  A second implementation of that arithmetic
    would be a second thing to keep in sync, and the failure mode of getting it
    wrong is reporting zero drops while the hook silently drops half the index.
    """
    total = len(index_lines(memory_md))
    injected = run_hook(root)
    # Count the INJECTED entries with a predicate that matches what the hook
    # actually emits. inject-global-memory.sh compacts `- [slug](slug.md)` to
    # `- slug`, so the on-disk `- [` predicate matches almost nothing there and
    # would report the whole index as dropped (measured: 122 of 123, while 65
    # were plainly present). Any top-level bullet in the injected text is an
    # entry — the only other bullets are inside the header, which has none.
    injected_entries = [l for l in injected.split("\n") if l.startswith("- ")]
    return total - len(injected_entries)


# `_`-prefixed keys are working data for the report, not budgeted metrics.
# ENFORCED, and the ratchet only lets them fall.
#
# Every one is PER ENTRY, or an invariant. That is deliberate: the totals grow
# whenever a genuinely new memory is written, and a guard that reddens on honest
# growth gets switched off. What must never grow is how VERBOSE an entry is --
# that is the lever, and it is the one a writer actually controls. Adding a
# memory is free; adding a bloated one is not.
#
# The two MEAN metrics used to be enforced here, and they broke exactly that
# promise: a mean is a total wearing a per-entry label. Measured 2026-09-02 --
# an honest 646 B directive, well inside the 977 B per-entry limit, pushed the
# mean 387 -> 389 and reddened a green tree; holding the mean would have
# required every future directive to come in under 372 B, below the corpus
# average. They are now part of the BILL: still measured, still shown against
# their targets, never able to fail a run.
METRICS = [
    ("index_dropped", "memories dropped by the injection cap"),
    ("directive_max_bytes", "longest working directive"),
    ("index_max_bytes", "longest MEMORY.md index line"),
]

# REPORTED, never enforced: the bill. These are what the corpus actually costs
# per session, and they rise with honest growth -- so they are shown, with their
# targets, and never used to fail a build. Hiding them would be worse: the point
# of the tool is that the cost is never invisible again.
REPORTED = [
    ("claude_md_bytes", "CLAUDE.md total", " B"),
    ("memory_md_bytes", "MEMORY.md total", " B"),
    ("directive_mean_bytes", "mean working directive", " B"),
    ("index_mean_bytes", "mean MEMORY.md index line", " B"),
    ("index_hook_chars_lost", "index hook text abbreviated away", " chars"),
]


def tokens(text: str):
    """cl100k token count, or None when tiktoken is unavailable.

    Informational only.  Nothing is enforced on this number precisely because
    it can be None -- see the module docstring.
    """
    try:
        import tiktoken
    except ImportError:
        return None
    return len(tiktoken.get_encoding("cl100k_base").encode(text))


def load_baseline() -> dict:
    with open(BASELINE, encoding="utf-8") as fh:
        return json.load(fh)


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------


def cmd_check(root: str) -> int:
    m = measure(root)
    base = load_baseline()
    fail = 0

    # A renamed or deleted section would silently zero a metric and read as a
    # huge improvement.  Refuse that outright: the guard must be able to tell
    # "we trimmed it" from "we lost the ability to see it".
    for key, label in (("directive_count", "## Working directives"),
                       ("index_count", "MEMORY.md index")):
        if m[key] == 0:
            print(f"FAIL: {label} matched 0 lines -- the scanner is broken, "
                  f"not the file")
            fail = 1

    for key, label in METRICS:
        got, lim = m[key], base["limits"][key]
        tgt = base["targets"][key]
        unit = "" if key == "index_dropped" else " B"
        if got > lim:
            print(f"FAIL: {label}: {got:,}{unit} exceeds limit {lim:,}{unit} "
                  f"(+{got - lim:,})")
            fail = 1
        else:
            debt = (f", {got - tgt:,}{unit} over target" if got > tgt
                    else ", at target")
            print(f"ok:   {label}: {got:,}{unit} / {lim:,}{unit}{debt}")

    for key, label, unit in REPORTED:
        got, tgt = m[key], base["targets"][key]
        debt = f", {got - tgt:,}{unit} over target" if got > tgt else ", at target"
        print(f"      {label}: {got:,}{unit} (not enforced){debt}")

    if fail:
        print("\nThe context budget only ratchets DOWN. To land this change, "
              "trim an equal-or-larger amount from the same file, then run "
              "`bin/context-budget.py --set-baseline`.")
    return fail


def injection_menu(root: str, budgets) -> list:
    """What each candidate injection budget would buy, measured not modelled.

    Runs the real hook against a copy with `budget=` rewritten, because the cap
    it settles on is the output of a search over the actual corpus -- any
    formula here would be a second implementation to keep in sync.
    """
    src_dir = os.path.abspath(root)
    hook = open(os.path.join(src_dir, "inject-global-memory.sh"), encoding="utf-8").read()
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        alt = os.path.join(tmp, "hook.sh")
        for b in budgets:
            open(alt, "w", encoding="utf-8").write(
                re.sub(r"^budget=\d+", f"budget={b}", hook, count=1, flags=re.M))
            out = subprocess.run(
                ["bash", alt], capture_output=True, text=True,
                env={**os.environ, "CLAUDE_GLOBAL_MEMORY_DIR":
                     os.path.join(src_dir, "memories", "global")}).stdout
            cap = re.search(r"hooks abbreviated to (\d+) chars", out)
            rows.append((b, len(out), len([l for l in out.split("\n")
                                           if l.startswith("- ")]),
                         int(cap.group(1)) if cap else None, out))
    return rows


def cmd_report(root: str) -> int:
    m = measure(root)
    base = load_baseline()

    claude_md = open(os.path.join(root, "CLAUDE.md"), encoding="utf-8").read()
    memory_md = open(
        os.path.join(root, "memories", "global", "MEMORY.md"), encoding="utf-8"
    ).read()

    ct, mt = tokens(claude_md), tokens(memory_md)
    unit = "tokens" if ct is not None else "tokens (tiktoken not installed)"
    print("SESSION-START CONTEXT COST")
    print(f"  CLAUDE.md                 {m['claude_md_bytes']:>9,} B  "
          f"{ct if ct is not None else '?':>9} {unit}")
    print(f"  memories/global/MEMORY.md {m['memory_md_bytes']:>9,} B  "
          f"{mt if mt is not None else '?':>9}  (ON DISK -- the hook abbreviates "
          f"every hook to fit the budget, so only the injection below is billed)")
    cur = injection_budget(root)
    rows = injection_menu(root, sorted({cur, 16000, 20000, 24000, 28000}))
    print()
    print("INJECTION (what MEMORY.md actually costs, and what more would buy)")
    print("  the index is capped per HOOK, so no memory is ever dropped; a bigger")
    print("  budget buys longer hooks, nothing else.")
    for b, chars, listed, cap, out in rows:
        capw = f"{cap} chars" if cap is not None else "FULL, no abbreviation"
        mark = " <- current" if b == cur else ""
        # Count with the same tokenizer as the totals below.  A chars/4.33
        # estimate here disagreed with the exact count in the `per session`
        # line by ~300 tokens -- two numbers for one artifact.
        tk = tokens(out)
        tkw = f"{tk:>5,} tok" if tk is not None else f"~{round(chars / 4.33):>5,} tok"
        print(f"    budget {b:>6,} -> {chars:>6,} chars  {tkw}  "
              f"| {listed:>3} listed | hooks {capw}{mark}")
    print("  Raising it is a permanent per-session cost: The user's call, not a default.")
    print()

    # Price the session off the INJECTED text, never MEMORY.md on disk: the hook
    # abbreviates each hook to fit `budget`, so the file is several times what any
    # session pays.  Using `mt` here overstated per-session cost by ~3,500 tokens
    # (measured 2026-09-02 at budget=20000: reported 19,690 / actual 16,186).
    inj = next((out for b, _c, _l, _cap, out in rows if b == cur), "")
    it = tokens(inj)
    if ct is not None and it is not None:
        print(f"  -> per session            {'':>9}   {ct + it:>9} tokens "
              f"(CLAUDE.md + the injection; MEMORY.md on disk is NOT billed)")
        print(f"  -> inside this repo       {'':>9}   {2 * ct + it:>9} tokens "
              f"(CLAUDE.md is billed twice: global + project)")
    print()

    for key, label, items in (
        ("directive_max_bytes", "WORKING DIRECTIVES", m["_directives"]),
        ("index_max_bytes", "MEMORY.md INDEX LINES", m["_index"]),
    ):
        tgt = base["targets"][key]
        over = sorted(
            (l for l in items if len(l.encode()) > tgt),
            key=lambda l: -len(l.encode()),
        )
        excess = sum(len(l.encode()) - tgt for l in over)
        print(f"{label}: {len(items)} entries, {len(over)} over the "
              f"{tgt:,} B target, {excess:,} B of debt")
        for l in over[:12]:
            orph = orphan_facts(l, m["_bodies"])
            head = re.sub(r"\s+", " ", l[2:])[:72]
            print(f"  {len(l.encode()):>5} B  {head}...")
            if orph:
                print(f"          MOVE TO BODY FIRST ({len(orph)}): "
                      f"{', '.join(repr(o) for o in orph[:4])}")
            else:
                print(f"          safe to trim: every fact is already in the "
                      f"linked body")
        if len(over) > 12:
            print(f"  ... and {len(over) - 12} more")
        print()
    return 0


def cmd_set_baseline(root: str) -> int:
    """Rewrite limits from current measurements, refusing every increase."""
    m = measure(root)
    base = load_baseline()
    raised, lowered = [], []
    for key, label in METRICS:
        got, lim = m[key], base["limits"][key]
        if got > lim:
            u = "" if key == "index_dropped" else " B"
            raised.append(f"  {label}: {got:,}{u} > current limit {lim:,}{u}")
        elif got < lim:
            u = "" if key == "index_dropped" else " B"
            lowered.append(f"  {label}: {lim:,} -> {got:,}{u} "
                           f"(-{lim - got:,})")
            base["limits"][key] = got

    if raised:
        print("REFUSED: the budget ratchets DOWN only. These exceed their "
              "current limits:")
        print("\n".join(raised))
        return 1
    if not lowered:
        print("No change: every metric is already at its limit.")
        return 0
    with open(BASELINE, "w", encoding="utf-8") as fh:
        json.dump(base, fh, indent=2)
        fh.write("\n")
    print("Ratcheted down:")
    print("\n".join(lowered))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true",
                    help="fail if any metric exceeds its ratchet limit")
    ap.add_argument("--report", action="store_true",
                    help="ranked offenders, with the facts a trim would lose")
    ap.add_argument("--set-baseline", action="store_true",
                    help="lower the limits to current values; never raises")
    ap.add_argument("--root", default=ROOT,
                    help="repo root to measure (the tests point this at a copy)")
    a = ap.parse_args()
    if a.set_baseline:
        return cmd_set_baseline(a.root)
    if a.report:
        return cmd_report(a.root)
    return cmd_check(a.root)


if __name__ == "__main__":
    sys.exit(main())
