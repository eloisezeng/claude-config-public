#!/usr/bin/env python3
"""The near-miss judge (spec §3.10), which is the only model on the catch-count path.

Four of the five finding verdicts are decided mechanically by `review_eval.catch_verdict` and are
never re-judged, so the grade does not drift when the judge model changes. Only `near-miss` is
escalated here, and only a `yes` moves anything.

The contract is stated rather than implied, because this sits directly on the number the keep rule
compares across runs:

- The result enum is exactly `yes` / `no` / `unjudged`.
- A `yes` promotes its CASE to caught under §3.1.1, and a second `yes` in the same case changes
  nothing, because a catch is binary per case and not per finding.
- Every failure — timeout, unparseable output, missing field, launcher failure, retries exhausted
  — resolves to `unjudged`, which is FAIL-CLOSED: it never changes the catch total in either
  direction. Treating a judge failure as a catch would inflate the grade and treating it as a miss
  would deflate it, and both are worse than reporting that the question was not answered.
- The judge is given the finding's title, body and cited range, the location's file and range, and
  the two line excerpts. It is given neither the repair diff nor the case's expected answer, and
  `JudgeRequest` has no field either could arrive through — the redaction is in the shape, so no
  call site can leak one by forgetting to strip it.
- Its model identity and effort are persisted in the run summary, so a drift is attributable.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

from review_eval import LineRange

JUDGE_YES = 'yes'
JUDGE_NO = 'no'

#: Not a model answer. `unjudged` is the HARNESS's word for "the question was not answered", and
#: `parse_judge_result` refuses it from the model for that reason: a model declining and a
#: launcher failing are two different facts, and one spelling would record them as the same one.
JUDGE_UNJUDGED = 'unjudged'

JUDGE_RESULTS = (JUDGE_YES, JUDGE_NO, JUDGE_UNJUDGED)

#: The wording is part of the contract, not a paraphrase of it. "Is this finding relevant to the
#: defect" and "is it near it" both conform to a looser reading and produce a different catch
#: total, so the sentence is pinned by a test rather than described in a docstring.
JUDGE_QUESTION = (
    'Does this finding describe the SAME underlying defect as the cited defect location?'
)

#: At most two retries AFTER the first attempt, so three invocations at the outside. A judge that
#: retried without a bound would turn a dead launcher into a hang rather than into an `unjudged`.
MAX_RETRIES = 2

#: Declared, and enforced by `parse_judge_result` rather than merely published. `additionalProperties`
#: is left permissive because a launcher that wraps the answer in envelope fields is not a judge
#: that answered wrongly; the `result` field is what this contract is about.
JUDGE_RESULT_SCHEMA = {
    'type': 'object',
    'properties': {'result': {'type': 'string', 'enum': [JUDGE_YES, JUDGE_NO, JUDGE_UNJUDGED]}},
    'required': ['result'],
}


@dataclass(frozen=True)
class JudgeIdentity:
    """Which judge ran. Both halves required, because a model with no effort identifies nothing.

    Travels as one object rather than as two arguments for the same reason `deepBatchPricing`
    does on the product side: two values that must agree are one value, and a pair assembled at a
    call site can be assembled from two different readings.
    """

    model: str
    effort: str

    def __post_init__(self) -> None:
        for name, value in (('model', self.model), ('effort', self.effort)):
            if not isinstance(value, str) or not value:
                raise ValueError(
                    f'JudgeIdentity.{name} is {value!r}: a model identity with no effort does not '
                    'identify the judge that ran, and an unattributable judge makes a drift in '
                    'the catch total impossible to explain'
                )

    def as_row(self) -> dict:
        """The shape `loop.run_summary_row` persists."""
        return {'model': self.model, 'effort': self.effort}


@dataclass(frozen=True)
class JudgeRequest:
    """Everything the judge is shown, and nothing else.

    There is deliberately no field for the repair diff or for the case's expected answer. A
    redaction enforced by a call site is a redaction forgotten by the second call site; a
    redaction enforced by the type cannot be forgotten at all.
    """

    case_id: str
    finding_index: int
    finding_title: str
    finding_body: str
    finding_range: LineRange
    location: LineRange
    finding_excerpt: str
    location_excerpt: str


@dataclass(frozen=True)
class JudgeOutcome:
    """One judged near miss. `failure` is None exactly when the judge answered."""

    case_id: str
    finding_index: int
    result: str
    attempts: int
    failure: str | None


def build_judge_prompt(request: JudgeRequest) -> str:
    """The prompt, built from the six declared inputs.

    Built here rather than at the call site so that the redaction and the wording are one
    artifact a test can read, instead of two things that agree today.
    """
    return '\n'.join((
        JUDGE_QUESTION,
        '',
        'Answer with JSON: {"result": "yes"} or {"result": "no"}. Nothing else.',
        '',
        f'## The reviewer said, at {request.finding_range.file} lines '
        f'{request.finding_range.start}-{request.finding_range.end}',
        '',
        request.finding_title,
        '',
        request.finding_body,
        '',
        'The lines it cited:',
        '',
        request.finding_excerpt,
        '',
        f'## The cited defect location: {request.location.file} lines '
        f'{request.location.start}-{request.location.end}',
        '',
        request.location_excerpt,
        '',
    ))


def parse_judge_result(raw: object) -> str | None:
    """Narrow an untrusted judge answer into `yes` or `no`, or None when it is neither.

    None means "the question was not answered", and every caller turns that into `unjudged`.
    Returning the string `unjudged` from here would make the model able to produce the harness's
    own failure word, so the two facts could not be told apart afterwards.
    """
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except (ValueError, TypeError):
            return None
    if not isinstance(raw, dict):
        return None
    result = raw.get('result')
    # `bool` is excluded by the isinstance check against str; an enum member is required exactly,
    # so `YES` is refused rather than folded, because a judge whose casing changed is a judge
    # whose output format changed and that is worth seeing.
    if result in (JUDGE_YES, JUDGE_NO):
        return result
    return None


def judge_near_miss(request: JudgeRequest, invoke, max_retries: int = MAX_RETRIES) -> JudgeOutcome:
    """Ask the judge about one near miss, retrying at most `max_retries` times after the first.

    `invoke` is a callable taking the built prompt and returning the judge's raw answer. It is a
    parameter rather than a module-level launcher call so that every failure path here is
    reachable from a test without a model; the one thing this function must get right is that
    NOTHING escapes it as an exception, because an exception on the judging path would abort a
    grading run over a question whose answer never changes the total.
    """
    last_failure = 'no attempt was made'
    attempts = 0
    for attempt in range(1 + max_retries):
        attempts = attempt + 1
        try:
            raw = invoke(build_judge_prompt(request))
        except BaseException as exc:  # noqa: BLE001 - see the docstring: nothing may escape
            last_failure = f'{type(exc).__name__}: {exc}'
            continue
        parsed = parse_judge_result(raw)
        if parsed is not None:
            return JudgeOutcome(
                case_id=request.case_id, finding_index=request.finding_index,
                result=parsed, attempts=attempts, failure=None,
            )
        last_failure = f'unparseable judge answer: {raw!r}'
    return JudgeOutcome(
        case_id=request.case_id, finding_index=request.finding_index,
        result=JUDGE_UNJUDGED, attempts=attempts,
        failure=f'{attempts} attempts, last failure: {last_failure}',
    )


def apply_judgements(scores, outcomes):
    """Apply judged near misses to a run's case scores, returning a new tuple of scores.

    Refuses a judgement about anything but a near miss. §3.9 decides `catch`, `miss`,
    `out-of-scope` and `malformed` mechanically and never re-judges them, and a judgement that
    was silently ignored is one a caller believes was applied — so the refusal is loud and names
    the verdict it was handed.

    Promotion is per CASE. Two `yes` answers in one case produce one catch, which is §3.1.1, and
    is why this sets a flag on the case rather than counting the answers.
    """
    by_id = {s.case_id: s for s in scores}
    promoted: set[str] = set()
    for outcome in outcomes:
        score = by_id.get(outcome.case_id)
        if score is None:
            raise ValueError(
                f'judgement names case {outcome.case_id!r}, which this run did not score; a '
                'judgement about a case nobody ran cannot be applied to anything'
            )
        if not 0 <= outcome.finding_index < len(score.verdicts):
            raise ValueError(
                f'judgement names finding {outcome.finding_index} of case '
                f'{outcome.case_id!r}, which produced {len(score.verdicts)} findings'
            )
        verdict = score.verdicts[outcome.finding_index]
        from review_eval import NEAR_MISS  # noqa: PLC0415 - local to keep the import surface small
        if verdict != NEAR_MISS:
            raise ValueError(
                f'judgement names finding {outcome.finding_index} of case '
                f'{outcome.case_id!r}, whose verdict is {verdict!r}. Only a near-miss is '
                'escalated to the judge: the other four verdicts are decided mechanically and '
                'are never re-judged, so the grade does not drift when the judge changes'
            )
        if outcome.result == JUDGE_YES:
            promoted.add(outcome.case_id)
    if not promoted:
        return tuple(scores)
    import dataclasses  # noqa: PLC0415
    return tuple(
        dataclasses.replace(s, caught=True) if s.case_id in promoted else s
        for s in scores
    )
