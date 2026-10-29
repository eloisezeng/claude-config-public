#!/usr/bin/env python3
"""review_eval.py — the pure decision rules for grading a diff reviewer against past escapes.

## Why this file is separate, and why it holds no I/O

Everything here is a pure function over plain data. The rules decide outcomes — whether a
reviewer found a defect, whether a reviewer change may be kept, how deeply a change is reviewed
— and a rule that decides an outcome has to be exercisable without a repository, a network, a
model, or a clock. The harvesting, the runner and the ledger live elsewhere and call in here.

## Why it names no repository

The case data is private and lives in the repository under test; this module is published. It
therefore contains no repository name, no path literal belonging to any project, and no
reference to any particular change. Every project-specific value arrives as an argument or in a
config dict the caller loads. `assert_no_project_literals` is the guard that keeps it that way,
and it is called by this module's own tests rather than being a rule written down in prose.

## The shapes

Findings and defect locations arrive from JSON written by a model or by a harvester, so neither
is trusted. `parse_finding` and `parse_defect_location` are the boundary: they turn untrusted
dicts into narrowed values, or they return a malformed marker. Nothing past the boundary
re-checks a line number, because nothing past the boundary can hold an invalid one.
"""
from __future__ import annotations

import math
import re
from dataclasses import dataclass
from typing import Callable, Iterable, Mapping, Sequence

# ---------------------------------------------------------------------------
# Verdict vocabularies. One value per meaning, never two meanings on one value.
# ---------------------------------------------------------------------------

#: A finding's relation to a case's known defect locations.
CATCH = 'catch'
NEAR_MISS = 'near-miss'
MISS = 'miss'
OUT_OF_SCOPE = 'out-of-scope'
MALFORMED = 'malformed'

#: `malformed` and `out-of-scope` are deliberately NOT folded into `miss`. A reviewer that emits
#: an unparseable finding and a reviewer that read the right lines and said nothing are different
#: failures, and a grade that could not tell them apart would move for the wrong reason.
FINDING_VERDICTS = (CATCH, NEAR_MISS, MISS, OUT_OF_SCOPE, MALFORMED)

#: The verdicts that carry no information about the reviewer's AIM. A finding that did not parse,
#: and a finding citing a file the reviewer was never shown, both say something about the
#: plumbing between the reviewer and the harness rather than about whether the reviewer can find a
#: defect. A case made up entirely of these is therefore not a miss — it is a case that was never
#: graded, and `CaseScore.scorable` is false for it.
UNSCORABLE_VERDICTS = (MALFORMED, OUT_OF_SCOPE)

#: The keep rule's answers. `refuse` is a third value because "these two runs cannot be
#: compared" is not the same claim as "this reviewer change made things worse", and a gate that
#: returned `drop` for an uncomparable pair would reject a change on no evidence — while one that
#: returned `keep` would accept it on no evidence, which is worse.
KEEP = 'keep'
DROP = 'drop'
REFUSE = 'refuse'
KEEP_VERDICTS = (KEEP, DROP, REFUSE)

#: Review depth, shallowest first. The order is load-bearing: `max` over this sequence is how a
#: change touching several partitions is resolved, so the deepest always wins.
SINGLE_LENS = 'single-lens'
STANDARD = 'standard'
DEEP = 'deep'
DEPTHS = (SINGLE_LENS, STANDARD, DEEP)

#: The closed set of finding outcomes. Exactly one is recorded per finding once its round closes.
OUTCOME_FIXED = 'fixed'
OUTCOME_REVIEWER_WRONG = 'reviewer was wrong'
OUTCOME_INTENTIONAL = 'intentional'
OUTCOME_DIDNT_MATTER = "didn't matter"
OUTCOME_DEFERRED = 'deferred'
OUTCOME_NOT_REACHABLE = 'not reachable'
FINDING_OUTCOMES = (
    OUTCOME_FIXED,
    OUTCOME_REVIEWER_WRONG,
    OUTCOME_INTENTIONAL,
    OUTCOME_DIDNT_MATTER,
    OUTCOME_DEFERRED,
    OUTCOME_NOT_REACHABLE,
)

#: The outcomes that make a finding on a clean case a FALSE ALARM — one that would lead an author
#: to change working code for no reason. `intentional` and `didn't matter` describe a finding that
#: was right about the code and wrong about its importance, which is noise but not harm;
#: `deferred` has not been judged yet and so cannot be counted either way. Deriving the false
#: alarm from the recorded outcome reuses the one closed set rather than inventing a second
#: taxonomy that could disagree with it.
FALSE_ALARM_OUTCOMES = (OUTCOME_REVIEWER_WRONG, OUTCOME_NOT_REACHABLE)

#: How many lines may separate a finding's cited range from a defect location before the finding
#: stops being a near miss and becomes an outright miss.
#:
#: 10 is the span of one small function or one hunk's worth of context, which is the distance at
#: which a human reading the review would still say "it was looking at the right thing". Beyond
#: that the proximity is coincidence rather than evidence, because a defect-bearing file is
#: usually a file the reviewer has several remarks about. The constant is named rather than
#: inlined so that moving it is one edit with one reason, and so the tests can sweep both sides
#: of it instead of pinning whatever number happened to be typed.
NEAR_MISS_GAP_LINES = 10


# ---------------------------------------------------------------------------
# The boundary: untrusted JSON in, narrowed values out
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class LineRange:
    """A 1-based inclusive line range in one file. Cannot hold an invalid range.

    There is no validating constructor to remember to call and no interior re-check, because
    `parse_*` below is the only way to get one from untrusted input.
    """

    file: str
    start: int
    end: int


def _parse_range(raw: object, file_key: str, start_key: str, end_key: str) -> LineRange | None:
    """Narrow one untrusted mapping into a LineRange, or None when it cannot be one.

    Refuses, each for its own reason: a non-mapping; a missing or empty file; a line number that
    is not an integer (a float or a numeric string is a different producer than the one this
    contract describes, and silently coercing it would hide that); a line number below 1, since
    the line numbering is 1-based and 0 means the producer did not know; and a reversed range.
    `bool` is rejected explicitly because in Python `True` is an `int` and would otherwise parse
    as line 1.
    """
    if not isinstance(raw, Mapping):
        return None
    file = raw.get(file_key)
    if not isinstance(file, str) or not file:
        return None
    start, end = raw.get(start_key), raw.get(end_key)
    for v in (start, end):
        if isinstance(v, bool) or not isinstance(v, int) or v < 1:
            return None
    if start > end:  # type: ignore[operator]
        return None
    return LineRange(file=file, start=int(start), end=int(end))  # type: ignore[arg-type]


def parse_finding(raw: object) -> LineRange | None:
    """A reviewer finding's cited location, in the reviewer's own JSON field names."""
    return _parse_range(raw, 'file', 'line_start', 'line_end')


def parse_defect_location(raw: object) -> LineRange | None:
    """A harvested defect location, in the case record's field names."""
    return _parse_range(raw, 'file', 'lineStart', 'lineEnd')


# ---------------------------------------------------------------------------
# The catch rule
# ---------------------------------------------------------------------------


def _overlaps(a: LineRange, b: LineRange) -> bool:
    """Inclusive overlap. Two ranges sharing exactly one line DO overlap."""
    return a.start <= b.end and b.start <= a.end


def _gap(a: LineRange, b: LineRange) -> int:
    """Lines between two non-overlapping ranges in the same file; 0 when they overlap."""
    if _overlaps(a, b):
        return 0
    return b.start - a.end - 1 if a.end < b.start else a.start - b.end - 1


def catch_verdict(
    raw_finding: object,
    defects: Sequence[LineRange],
    diff_files: Iterable[str],
    near_miss_gap: int = NEAR_MISS_GAP_LINES,
) -> tuple[str, LineRange | None]:
    """How one finding relates to a case's defect locations.

    Returns `(verdict, matched_defect_or_None)`.

    The order of the checks is the rule, and it is this order because each earlier answer is
    about the finding itself rather than about the reviewer's aim:

    1. `malformed` — the finding did not parse. Nothing can be concluded about aim.
    2. `out-of-scope` — it cites a file the reviewed diff does not contain. The reviewer was
       looking outside what it was given, so this is neither a hit nor a missed shot. The manifest
       is a REQUIRED parameter with no default and `None` is refused: an earlier version defaulted
       it to None and skipped this check, so every caller that forgot it got `miss` for a finding
       the reviewer was never shown — a reviewer scored down for aiming outside a diff nobody
       told it about. Required means every call site fails at once, in one test run, rather than
       one production path failing later.
    3. `catch` — its lines overlap a defect location.
    4. `near-miss` — same file, within `near_miss_gap` lines. ONLY this verdict is escalated to
       a model judge; `catch` and `miss` are decided here and never re-judged, so the grade does
       not drift when the judge changes.
    5. `miss` — everything else.

    An empty `defects` is NOT handled here: see `score_escape_case`, which refuses such a case
    outright. A function that answered `miss` for every finding of a case with no known defect
    would quietly contribute a zero to the catch count, and a case with no known defect location
    has been measured to be the signature of a pair that is not an escape at all.
    """
    if diff_files is None:
        raise ValueError(
            'diff_files is required: without the reviewed diff\'s file manifest, a finding citing '
            'a file the reviewer was never shown scores as a MISS, which marks the reviewer down '
            'for a shot it did not take. A caller with no manifest has a case it cannot score, '
            'which is a routing decision and not a scoring one.'
        )
    finding = parse_finding(raw_finding)
    if finding is None:
        return MALFORMED, None
    if finding.file not in set(diff_files):
        return OUT_OF_SCOPE, None
    same_file = [d for d in defects if d.file == finding.file]
    for d in same_file:
        if _overlaps(finding, d):
            return CATCH, d
    near = [d for d in same_file if _gap(finding, d) <= near_miss_gap]
    if near:
        return NEAR_MISS, min(near, key=lambda d: _gap(finding, d))
    return MISS, None


@dataclass(frozen=True)
class CaseScore:
    """One escape case's result. `near_misses` is what the model judge is handed.

    `malformed`, `out_of_scope` and `scorable` exist because `caught=False` used to carry two
    different meanings. A reviewer that read the diff and said nothing, and a reviewer whose every
    finding was unparseable or cited a file outside the diff, both produced `caught=False` — and
    the second is not a miss at all, it is a case that was never graded. Counting it as a miss
    moves the grade for a plumbing failure, which is the direction that makes a reviewer change
    look worse than it is and gets a good change dropped.

    Every field is required. A `scorable` that defaulted to `True` would make the distinction
    opt-in, and an opt-in distinction is the one that is forgotten at exactly the site that needed
    it.
    """

    case_id: str
    caught: bool
    verdicts: tuple[str, ...]
    near_misses: tuple[int, ...]
    malformed: int
    out_of_scope: int
    scorable: bool


def score_escape_case(
    case_id: str,
    raw_findings: Sequence[object],
    defects: Sequence[LineRange],
    diff_files: Iterable[str],
    near_miss_gap: int = NEAR_MISS_GAP_LINES,
) -> CaseScore:
    """Score one escape case. Raises on a case with no known defect location.

    The raise is deliberate and is not a style choice. An escape case whose defect location set
    is empty cannot be graded: every finding would read `miss`, the case would contribute 0 to
    the catch count, and nothing downstream could tell that from a reviewer that genuinely found
    nothing. Measured over one repository's candidate pairs, an empty set was the signature of a
    pair that was not an escape — a repair that changed only a test. So the harness must stop and
    name the case rather than score it.
    """
    if not defects:
        raise ValueError(
            f'case {case_id!r} has no defect location, so it cannot be scored. '
            'An empty defect-location set means the repair changed no production line that the '
            'introducing change had touched, which means it is not an escape this reviewer could '
            'have caught. Classify the case and move it out of the escape set.'
        )
    verdicts: list[str] = []
    near: list[int] = []
    for i, raw in enumerate(raw_findings):
        v, _ = catch_verdict(raw, defects, diff_files, near_miss_gap)
        verdicts.append(v)
        if v == NEAR_MISS:
            near.append(i)
    # A case with NO findings is scorable: the reviewer was shown the diff and reported nothing,
    # which is an honest miss and is exactly what the grade exists to measure. Only a case that
    # produced findings, ALL of which carry no information about aim, is unscorable. Written as
    # `any(informative)` rather than `not all(unscorable)` because the empty case must fall on the
    # scorable side and the two forms disagree there.
    informative = [v for v in verdicts if v not in UNSCORABLE_VERDICTS]
    return CaseScore(
        case_id=case_id,
        caught=CATCH in verdicts,
        verdicts=tuple(verdicts),
        near_misses=tuple(near),
        malformed=sum(1 for v in verdicts if v == MALFORMED),
        out_of_scope=sum(1 for v in verdicts if v == OUT_OF_SCOPE),
        scorable=bool(informative) or not verdicts,
    )


def score_clean_case(case_id: str, outcomes: Sequence[str]) -> int:
    """How many false alarms a reviewer raised on one CLEAN case. Returns the count.

    A clean case is a merged change no repair ever named, so it has no known defect and therefore
    no defect LOCATION. `score_escape_case` refuses an empty location set outright, which is
    correct for an escape case and would make a clean case unscoreable — hence a separate function
    rather than a flag, and this one is explicitly exempt from that refusal. The exemption is in
    the shape: there is no `defects` parameter here to be empty.

    Zero findings on a clean case is the BEST possible result and scores zero, not a refusal. That
    is the difference between the two halves of the keep rule: a catch count of zero is evidence of
    a bad reviewer, while a false-alarm count of zero is evidence of a good one.

    Raises, naming the case, on an outcome outside the closed set. `false_alarms_on_clean_case`
    does the raising and this adds the case id to it, because a count that silently skipped an
    unrecognised outcome would UNDER-count false alarms, and under-counting is the direction that
    makes the keep rule approve a change it should reject.
    """
    try:
        return false_alarms_on_clean_case(outcomes)
    except ValueError as exc:
        raise ValueError(f'clean case {case_id!r}: {exc}') from exc


def false_alarms_on_clean_case(outcomes: Sequence[str]) -> int:
    """How many findings on a clean case are false alarms, from their recorded outcomes.

    Only `reviewer was wrong` and `not reachable` count. An unrecognised outcome raises rather
    than being ignored: silently skipping one would under-count false alarms, which is the
    direction that makes the keep rule approve a change it should reject.
    """
    bad = [o for o in outcomes if o not in FINDING_OUTCOMES]
    if bad:
        raise ValueError(f'not finding outcomes: {bad!r}; the closed set is {list(FINDING_OUTCOMES)}')
    return sum(1 for o in outcomes if o in FALSE_ALARM_OUTCOMES)


# ---------------------------------------------------------------------------
# The capacity admission bound
# ---------------------------------------------------------------------------

#: Bytes per token, as a CONSERVATIVE divisor for projecting a token count from a byte count.
#:
#: Measured over the fourteen kept cases of this project's first escape set, the worst (highest)
#: ratio was 3.70 bytes per token, so 3.5 bounds it: dividing by a number smaller than the true
#: ratio OVER-estimates the token count, which is the direction that refuses a case rather than
#: admitting one that will not fit. The number is named rather than inlined so that moving it is
#: one edit with one reason.
#:
#: This is a PROJECTION and never a measurement. `bytes / 4` was once used as an estimate and
#: undercounted the largest real case by 6.0% against the real tokenizer — the direction that
#: admits a case which then overflows the window mid-run. Anything deciding admission on a real
#: case uses a measured count; this exists for sizing a case that has not been tokenized yet.
CONSERVATIVE_BYTES_PER_TOKEN = 3.5


def project_tokens_from_bytes(n_bytes: int) -> int:
    """A conservative UPPER BOUND on the tokens in `n_bytes` of text. Not a measurement.

    Named a projection, and kept a separate function from any measurement, because the two
    answers differ and the difference has a direction: a projection that is quietly substituted
    for a measurement reads as a smaller number and admits a case that will not fit.
    """
    if n_bytes < 0:
        raise ValueError(f'a byte count cannot be negative: {n_bytes}')
    # Rounded UP: a projection that rounds down is a projection that under-states, and the whole
    # reason this function exists separately is that under-stating admits a case which will not fit.
    return math.ceil(n_bytes / CONSERVATIVE_BYTES_PER_TOKEN)


def admits_case(measured_tokens: int, envelope_tokens: int, window_tokens: int) -> tuple[bool, str]:
    """Whether one case fits the reviewer's context window. Returns `(admitted, reason)`.

    The bound is `measured + envelope <= window`, and each of the three arguments is separate on
    purpose:

    - `measured_tokens` is a MEASURED count for this case's diff, never a byte projection. A
      projection substituted here is smaller than the truth in the direction that admits a case
      which then overflows mid-run.
    - `envelope_tokens` is everything the run carries BESIDE the diff — the prompt, the schema,
      the instructions, the reviewer's own output. A bound that compared the diff alone to the
      window would admit a case that fits with nothing else in the window, which never happens.
    - `window_tokens` is the effective window, already discounted from the model's nominal one.

    The boundary is `<=` and that is DECIDED here rather than left to each reader: a case whose
    measured size plus envelope exactly equals the window is admitted. An undecided boundary is
    resolved differently by each caller, which is how two admission answers for one case appear.

    A refusal names the size, because "this case does not fit" is unactionable without the number
    that did not fit.
    """
    for name, n in (('measured_tokens', measured_tokens), ('envelope_tokens', envelope_tokens)):
        if n < 0:
            raise ValueError(f'{name} is {n}, and a token count cannot be negative')
    if window_tokens <= 0:
        raise ValueError(
            f'window_tokens is {window_tokens}: a non-positive window admits nothing and is a '
            'caller that failed to read the model catalog, not a case that is too large'
        )
    total = measured_tokens + envelope_tokens
    if total <= window_tokens:
        return True, (
            f'{measured_tokens} measured + {envelope_tokens} envelope = {total} tokens, within a '
            f'{window_tokens}-token window ({window_tokens - total} spare)'
        )
    return False, (
        f'{measured_tokens} measured + {envelope_tokens} envelope = {total} tokens, which exceeds '
        f'a {window_tokens}-token window by {total - window_tokens}'
    )


# ---------------------------------------------------------------------------
# The keep rule
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RunSummary:
    """One grading run's result. Every field is required and three counts are DERIVED.

    The shape is the rule here, and it is this shape because of what the integer version let
    through. `catches` used to be an integer a caller supplied, so a per-finding sum could be
    passed where a per-case count belongs — the catch rule is binary per case, and nothing in an
    `int` says so. `case_ids` used to default to `()`, so a caller who forgot it skipped the
    like-with-like gate silently. Both now fail at the construction site, which means every
    forgotten site fails at once in one test run instead of one production path failing later.

    Four sets, and each exists because two runs can agree on the one above it and differ here:

    - `case_ids` — the escape cases this run scored. Identity for a comparison.
    - `caught_case_ids` — those it caught. `catches` is its length, so a case counts at most once.
    - `scorable_case_ids` — those that could be graded at all. A case all of whose findings cite
      files outside the supplied diff is unscorable and leaves the catch total, so two runs can
      name identical cases and still have different denominators.
    - `clean_case_ids` — the clean cases the false-alarm count came from. Equal clean COUNTS over
      different clean cases make the noise halves incomparable, which is the same defect one
      field over.

    `case_manifest_hash` is the canonical hash over the scored cases' own content hashes, which is
    what distinguishes two runs over the same case IDs whose case CONTENT was corrected in place.

    `malformed_findings` and `out_of_scope_findings` are FINDING counts and not case counts, which
    is why an integer is the right type for them where it was the wrong type for `catches`. They
    sit here so that a run whose grade did not move because the plumbing broke can be told apart
    from one whose grade did not move because the reviewer missed; `build_run_summary` is the one
    producer, so neither is hand-assembled beside the sets it must agree with.
    """

    false_alarms: int
    case_ids: tuple[str, ...]
    caught_case_ids: tuple[str, ...]
    scorable_case_ids: tuple[str, ...]
    clean_case_ids: tuple[str, ...]
    case_manifest_hash: str
    malformed_findings: int
    out_of_scope_findings: int

    def __post_init__(self) -> None:
        """Refuse an incoherent summary at the PRODUCER rather than at the gate.

        `catches > escape_cases` used to be a refusal inside `keep_verdict`. That refusal could
        only fire for the one consumer that checked; the state itself was constructible and could
        be written to disk, reported, and read by anything else. A subset requirement here makes
        it unconstructible, so there is nothing for a later reader to check.
        """
        for name, ids in (('caught_case_ids', self.caught_case_ids),
                          ('scorable_case_ids', self.scorable_case_ids)):
            stray = sorted(set(ids) - set(self.case_ids))
            if stray:
                raise ValueError(
                    f'{name} names {stray!r}, which are not in case_ids; a run cannot catch or '
                    'score a case it did not cover'
                )
        # A caught case that was never scorable is incoherent in the same way: a catch requires a
        # finding that parsed AND cited a file inside the diff, so it cannot come out of a case
        # whose every finding failed one of those. Refused at the producer rather than checked by
        # whichever consumer remembers to.
        unscorable_catches = sorted(set(self.caught_case_ids) - set(self.scorable_case_ids))
        if unscorable_catches:
            raise ValueError(
                f'caught_case_ids names {unscorable_catches!r}, which are not in '
                'scorable_case_ids; a case whose every finding was malformed or out of scope '
                'cannot have produced a catch'
            )
        for name, n in (('malformed_findings', self.malformed_findings),
                        ('out_of_scope_findings', self.out_of_scope_findings)):
            if n < 0:
                raise ValueError(f'{name} is {n}, and a count of findings cannot be negative')

    @property
    def catches(self) -> int:
        """Cases caught. Derived, so a per-finding total can never be supplied here."""
        return len(self.caught_case_ids)

    @property
    def escape_cases(self) -> int:
        """Escape cases covered. Derived, so it cannot disagree with the set it counts."""
        return len(self.case_ids)

    @property
    def clean_cases(self) -> int:
        """Clean cases covered. Derived, for the same reason."""
        return len(self.clean_case_ids)


def build_run_summary(
    escape_scores: Sequence[CaseScore],
    clean_false_alarms: Mapping[str, int],
    case_manifest_hash: str,
) -> RunSummary:
    """The ONE producer of a `RunSummary`, deriving every field from the scores it summarises.

    Nothing here is a convenience. A summary assembled field by field at a call site is the shape
    that lets `caught_case_ids` and `scorable_case_ids` be computed from different readings of the
    same run — and the keep rule compares those two sets across runs, so a disagreement between
    them does not fail, it answers wrongly. One producer means one reading.

    `clean_false_alarms` maps each clean case's id to its own false-alarm count, rather than
    taking a pre-summed integer and a separate id list: a count and the set it came from are
    values that must agree, so they arrive as one object. The total is summed here.

    Refuses a duplicate escape case id. Two scores for one id would double its weight in the
    denominator and make the two sets disagree about how many cases there were.
    """
    ids = [s.case_id for s in escape_scores]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        raise ValueError(
            f'escape_scores names {dupes!r} more than once; one case scores once per run, and a '
            'duplicate would weight it twice in a denominator the keep rule compares'
        )
    bad = {k: v for k, v in clean_false_alarms.items() if v < 0}
    if bad:
        raise ValueError(f'negative false-alarm counts: {bad!r}')
    return RunSummary(
        false_alarms=sum(clean_false_alarms.values()),
        case_ids=tuple(ids),
        caught_case_ids=tuple(s.case_id for s in escape_scores if s.caught),
        scorable_case_ids=tuple(s.case_id for s in escape_scores if s.scorable),
        clean_case_ids=tuple(clean_false_alarms),
        case_manifest_hash=case_manifest_hash,
        malformed_findings=sum(s.malformed for s in escape_scores),
        out_of_scope_findings=sum(s.out_of_scope for s in escape_scores),
    )


def keep_verdict(baseline: RunSummary | None, candidate: RunSummary) -> tuple[str, str]:
    """Whether a reviewer change may be kept. Returns `(verdict, reason)`.

    A change is kept only if catches did not FALL and false alarms did not RISE. Equal counts on
    both halves is `keep`: the rule is "do not get worse", not "improve", because a change made
    for another reason (cost, clarity, a new lens) is allowed to be neutral.

    Every input that cannot support a comparison returns `refuse` with the half that refused
    named. `refuse` rather than `keep` is the whole point: this is a gate, and a gate that
    answers in the absence of its own input is fail-open. The measured reason it matters here is
    that no baseline exists or can be reconstructed — per-finding outcomes were not stored before
    this machinery, so the first honest answer this rule can give is `refuse`.
    """
    if baseline is None:
        return REFUSE, 'no baseline run: record one before judging a reviewer change'
    for name, run in (('baseline', baseline), ('candidate', candidate)):
        if run.escape_cases <= 0:
            return REFUSE, f'{name} run covered no escape case, so its catch count means nothing'
        if run.clean_cases <= 0:
            return REFUSE, (
                f'{name} run covered no clean case, so its false-alarm count is vacuously zero '
                'and the noise half of this rule would pass unconditionally'
            )
        if not run.scorable_case_ids:
            return REFUSE, (
                f'{name} run scored no case: every case it covered was unscorable, so its catch '
                'count is vacuously zero. This is the same shape as a run with no clean case, and '
                'it is NOT caught by the set comparison below — two runs that both scored nothing '
                'have equal (empty) scorable subsets, compare as like with like, and return keep '
                'on 0 catches against 0 catches'
            )
        if run.false_alarms < 0:
            return REFUSE, f'{name} run reports a negative false-alarm count'
    # `catches > escape_cases` and a negative catch count were refusals here. Both are now
    # unconstructible: `catches` is the length of a subset of `case_ids`. The check is not missing,
    # it moved into `RunSummary.__post_init__`, where it fails for every reader at once.
    #
    # The three set comparisons below are UNCONDITIONAL. Each used to be guarded by a truthiness
    # test on the sets themselves (`baseline.case_ids and candidate.case_ids and ...`), which meant
    # an empty set on either side skipped the gate — the exact shape that makes a gate fail open.
    #
    # Measured honestly: with the three per-run emptiness refusals above in place, the conditional
    # and unconditional forms are now EQUIVALENT, so a mutant restoring the conjunction survives
    # every test and is recorded `unobservable` rather than as a weak test. The unconditional form
    # stays because it stops being equivalent the moment any per-run refusal is relaxed, and
    # because a comparison that reads its own precondition from a sibling guard is one reordering
    # away from being skipped. What actually catches the all-empty state is the per-run refusal,
    # not this loop — the comment above `scorable_case_ids` says so and a test pins it.
    for label, b_ids, c_ids in (
        ('case sets', baseline.case_ids, candidate.case_ids),
        ('scorable case subsets', baseline.scorable_case_ids, candidate.scorable_case_ids),
        ('clean case sets', baseline.clean_case_ids, candidate.clean_case_ids),
    ):
        if set(b_ids) != set(c_ids):
            only_b = sorted(set(b_ids) - set(c_ids))
            only_c = sorted(set(c_ids) - set(b_ids))
            return REFUSE, (
                f'the two runs covered different {label}, so the comparison is not like with like; '
                f'only in baseline: {only_b}; only in candidate: {only_c}'
            )
    if baseline.case_manifest_hash != candidate.case_manifest_hash:
        return REFUSE, (
            'the two runs name the same cases over different case CONTENT, so the comparison is '
            'not like with like; a case corrected in place keeps its id. baseline manifest hash '
            f'{baseline.case_manifest_hash!r}, candidate {candidate.case_manifest_hash!r}'
        )
    if candidate.catches < baseline.catches:
        return DROP, f'catches fell from {baseline.catches} to {candidate.catches}'
    if candidate.false_alarms > baseline.false_alarms:
        return DROP, f'false alarms rose from {baseline.false_alarms} to {candidate.false_alarms}'
    return KEEP, (
        f'catches {baseline.catches} -> {candidate.catches} (did not fall) and '
        f'false alarms {baseline.false_alarms} -> {candidate.false_alarms} (did not rise)'
    )


# ---------------------------------------------------------------------------
# Review depth
# ---------------------------------------------------------------------------


def depth_verdict(
    changed_files: Sequence[str],
    deep_paths: Sequence[str],
    is_shallow_path: Callable[[str], bool],
) -> tuple[str, str]:
    """How deeply to review a change, from the files it touches. Returns `(depth, reason)`.

    `deep_paths` is a list of path prefixes and whole file paths — never a model classifier, and
    never a regular expression, so that a path cannot match by accident. A prefix matches at a
    directory boundary: `lib/money` matches `lib/money/pay.rb` and does NOT match `lib/moneybox/pay.rb`.

    `is_shallow_path` is supplied by the caller rather than defined here, because the set of
    documentation-ish paths belongs to the repository under review and this module may not carry
    another project's path literals. Passing the predicate in also means there is exactly one
    definition of it per repository instead of a second list that drifts from the first.

    The resolution order is the rule: DEEP wins over everything. A change touching one
    documentation file and one deep path is DEEP, because the documentation file cannot make the
    deep path safer. A change is SINGLE_LENS only when EVERY file it touches is shallow — "all",
    never "any", since one code file among ten notes is still a code change.

    An empty change is STANDARD, not SINGLE_LENS. An empty file list means the caller could not
    determine what changed, and the safe reading of "I do not know" is the ordinary depth rather
    than the shallowest.
    """
    if not changed_files:
        return STANDARD, 'no changed files were supplied, so depth cannot be lowered on evidence'
    hits = [f for f in changed_files if any(_path_matches(f, p) for p in deep_paths)]
    if hits:
        return DEEP, f'touches the deep-review list: {sorted(set(hits))[:5]}'
    if all(is_shallow_path(f) for f in changed_files):
        return SINGLE_LENS, 'every changed file is documentation or notes'
    return STANDARD, 'ordinary change'


def _path_matches(path: str, pattern: str) -> bool:
    """Whole-path equality, or a prefix match at a directory boundary."""
    if path == pattern:
        return True
    prefix = pattern if pattern.endswith('/') else pattern + '/'
    return path.startswith(prefix)


def matches_shallow_pattern(path: str, pattern: str) -> bool:
    """One entry of the repository's declared review-only shallow list, against one path.

    The grammar is CLOSED, and `_path_matches` above is deliberately NOT it. The two matchers
    answer different input classes and conflating them is a measured defect rather than a
    hypothetical one:

    - `_path_matches` is the DEEP list's matcher: whole-path equality or a prefix at a directory
      boundary, never a glob and never a regular expression, so a path cannot match by accident.
    - this is the SHALLOW list's matcher, and the shallow list has to be able to say "every
      markdown file at the root of the repository", which is not a whole path and not a directory
      prefix. Pointed at such an entry, `_path_matches` answers False and the change is reviewed
      at the ordinary depth instead of the single lens the repository asked for.

    An entry is exactly one of:

    - a whole path, carrying no `*`;
    - `*<ext>` — a DIRECT child of the repository root whose name ends with `<ext>`;
    - `<dir>/*<ext>` — a DIRECT child of `<dir>` whose name ends with `<ext>`.

    `<ext>` begins with a dot and carries no `/` or `*`. Anything else RAISES rather than quietly
    matching nothing: a pattern no reader can parse is a rule that silently stopped applying, with
    no diff line to point at. There is no recursive wildcard on purpose — `*.md` means a
    root-level file, never `notes/deep/sub/a.md` — because the wide reading is the one that LOWERS
    a code change's review depth.

    The twin of this function is `matchesReviewOnlyPattern` in the repository under review, which
    generates the artifact this parses. The two cannot import each other across the language
    boundary, so the integration test that runs with both checkouts present compares them over a
    table of absolute answers.
    """
    if not isinstance(path, str) or not isinstance(pattern, str):
        raise TypeError(
            f'a shallow pattern and a path must both be strings; got {type(pattern).__name__} '
            f'and {type(path).__name__}'
        )
    star = pattern.find('*')
    if star == -1:
        return path == pattern
    if pattern.find('*', star + 1) != -1:
        raise ValueError(
            f'shallow pattern {pattern!r} carries more than one "*"; the grammar is a whole path, '
            '"*<ext>", or "<dir>/*<ext>"'
        )
    extension = pattern[star + 1:]
    if not extension.startswith('.') or '/' in extension:
        raise ValueError(
            f'shallow pattern {pattern!r} does not end in an extension beginning with "."; the '
            'grammar is a whole path, "*<ext>", or "<dir>/*<ext>"'
        )
    directory = pattern[:star]
    if directory and not directory.endswith('/'):
        raise ValueError(
            f'shallow pattern {pattern!r} puts "*" inside a path segment; the grammar is a whole '
            'path, "*<ext>", or "<dir>/*<ext>"'
        )
    if not path.startswith(directory) or not path.endswith(extension):
        return False
    return '/' not in path[len(directory):]


def shallow_path_predicate(shallow_paths: object) -> Callable[[str], bool]:
    """Build `depth_verdict`'s `is_shallow_path` argument from a repository's own declaration.

    `shallow_paths` is the parsed `shallowPaths` object of the repository's generated depth
    configuration, and BOTH halves are read from it rather than from any constant here:

    - `ciDocsOnly` carries the repository's continuous-integration docs-only rule, whose two
      halves are both REQUIRED — a prefix is necessary and never sufficient, which is how that
      repository defines it. Widening it here would loosen a rule that governs whether a test
      suite runs, and skipping a suite is a different risk from choosing a review panel.
    - `reviewOnly` is the wider set review may additionally treat as shallow, read under
      `matches_shallow_pattern`'s closed grammar.

    This module holds no project's paths — it is published to a public mirror — so the predicate
    is BUILT from the artifact every time rather than carried. A missing or malformed declaration
    raises: a predicate that answered False for everything would quietly review every
    documentation change at the ordinary depth, and one that answered True would review code at
    the single lens.
    """
    if not isinstance(shallow_paths, dict):
        raise TypeError(
            'a shallow-path declaration must be the parsed `shallowPaths` object; got '
            f'{type(shallow_paths).__name__}'
        )
    ci = shallow_paths.get('ciDocsOnly')
    review_only = shallow_paths.get('reviewOnly')
    if not isinstance(ci, dict) or not isinstance(review_only, list):
        raise ValueError(
            '`shallowPaths` must carry a `ciDocsOnly` object and a `reviewOnly` list; it carries '
            f'{sorted(shallow_paths)}'
        )
    prefixes, extensions = ci.get('prefixes'), ci.get('extensions')
    if not isinstance(prefixes, list) or not isinstance(extensions, list):
        raise ValueError(
            '`ciDocsOnly` must carry `prefixes` and `extensions` lists; it carries '
            f'{sorted(ci)}'
        )

    def is_shallow(path: str) -> bool:
        if not isinstance(path, str) or path == '':
            return False
        ci_match = (any(path.startswith(p) for p in prefixes)
                    and any(path.endswith(e) for e in extensions))
        return ci_match or any(matches_shallow_pattern(path, p) for p in review_only)

    return is_shallow


# ---------------------------------------------------------------------------
# The publishing guard, as code rather than as a sentence
# ---------------------------------------------------------------------------

#: Shapes that would mean this published module had absorbed a private project's details.
#: Each entry is a SHAPE rather than a specific name, so the guard does not need to be told
#: about a project it has never heard of — which is the only way a deny list can hold.
#: One stable key per shape, so a caller can select a SUBSET by name instead of by index into a
#: tuple. A test module legitimately carries fictional paths and lens finding ids: an id matches
#: the pull-request shape and a fictional two-segment source path matches the source-path shape,
#: while a project DIRECTORY name standing in as a fixture is the private tree leaking either way. Selecting by key is what lets
#: the two file classes be scanned for different shapes with the reason written beside each,
#: instead of exempting named files, which is the hand-typed deny list this guard exists to avoid.
PULL_REQUEST_NUMBER = 'a pull-request number'
PROJECT_SOURCE_PATH = 'a path into a project source tree'
PROJECT_DIRECTORY_LITERAL = 'a project directory literal'

#: Shapes that would mean this published module had absorbed a private project's details.
# GUARD-PATTERNS-BEGIN  (this region is removed before scanning; see assert_no_project_literals)
_PROJECT_LITERAL_SHAPES = (
    (r'#\d{1,5}\b', PULL_REQUEST_NUMBER),
    (r'\b[a-z0-9_-]+/[a-z0-9_-]+\.(?:ts|tsx|mjs|sql)\b', PROJECT_SOURCE_PATH),
    (r'\bapp/|\bplugins/|\bsrc/core/', PROJECT_DIRECTORY_LITERAL),
)
# GUARD-PATTERNS-END

ALL_PROJECT_LITERAL_SHAPES = (PULL_REQUEST_NUMBER, PROJECT_SOURCE_PATH,
                              PROJECT_DIRECTORY_LITERAL)


def assert_no_project_literals(source: str, shapes=None) -> list[str]:
    """Return every project-specific literal found in `source`; empty means clean.

    This module is published to a public mirror that default-includes new files, and the case
    data it grades is private. A sentence saying "keep this repository-agnostic" is satisfiable
    by a file that quietly stops being so; this returns the offending strings instead. It reads
    the source it is HANDED rather than its own file, so the test can point it at the shipped
    artifact and at a deliberately dirty control.

    Occurrences inside this guard's own pattern definitions are not findings, so the region
    between the two marker comments is removed before scanning. Without that the guard reports
    its own patterns and nobody can tell a real hit from the rule itself. A second pair of
    markers, `GUARD-CONTROL-BEGIN`/`END`, does the same job for a POSITIVE CONTROL that has to
    be dirty to prove the guard can see a hit at all. Both are regions a reader can see in the
    file, which is the difference between this and a list of exempt file names: a region cannot
    quietly cover a literal somebody added elsewhere in the same file.

    `shapes` selects which shapes apply, by the label each one reports under; `None` means all of
    them. A caller narrowing the set says WHY in its own words — see `ALL_PROJECT_LITERAL_SHAPES`
    for the keys. An unknown label is refused rather than ignored, because a typo in a narrowing
    set would silently scan for nothing.
    """
    if shapes is None:
        wanted = _PROJECT_LITERAL_SHAPES
    else:
        unknown = sorted(set(shapes) - set(ALL_PROJECT_LITERAL_SHAPES))
        if unknown:
            raise ValueError(
                f'unknown project-literal shape(s) {unknown}; the keys are '
                f'{list(ALL_PROJECT_LITERAL_SHAPES)}'
            )
        if not shapes:
            raise ValueError('an empty shape set scans for nothing; pass None for every shape')
        wanted = tuple(s for s in _PROJECT_LITERAL_SHAPES if s[1] in set(shapes))
    scanned = re.sub(
        r'# GUARD-PATTERNS-BEGIN.*?# GUARD-PATTERNS-END'
        r'|# GUARD-CONTROL-BEGIN.*?# GUARD-CONTROL-END',
        '',
        source,
        flags=re.S,
    )
    found: list[str] = []
    for pattern, what in wanted:
        for m in re.finditer(pattern, scanned):
            found.append(f'{what}: {m.group(0)!r}')
    return found
