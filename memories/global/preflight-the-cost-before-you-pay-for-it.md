---
name: preflight-the-cost-before-you-pay-for-it
description: Cost proportional to risk, decided BEFORE the loop starts — a preflight that names the critical path, what runs in parallel, what is not re-verified and a BOUNDED stop; Codex consulted on the plan not just the code; mutation testing reserved for logic a test could pass for the wrong reason, and a class repaired-and-sampled rather than enumerated; the round boundary asks expected value, not only "any findings left"
metadata:
  type: feedback
scope: global
---

The user, 2026-09-03: *"I should NOT have to ask 'can this be faster?' after the expensive work has already begun."*
The failure shape she named: a technically rigorous but needlessly serialized or open-ended plan, executed for hours, whose obvious parallelization / batching / scoping / stopping wins only surface once she asks.

**Why the existing rule did not fire — the trigger, not the wording.**
[[optimize-the-loop-unprompted]] already owed a speedup "unprompted at every round boundary", and it had already failed to fire twice before this.
The mechanism is `profile-loop.sh` + `loop.py close-round`/`lever`, and `loop.py gate()` reads, in code:

    if rnd == 1:
        return True, 'round 1: nothing to close yet'

**Round 1 is unconditionally free.** The whole efficiency apparatus keys on a CLOSED round, so its earliest possible fire is after the first round is already paid for — and the first round is where the plan's shape gets chosen.
The arc's only written start-of-work gate, the NECESSITY GATE, interrogates the *product* architecture ("what already does this?"), never the *process* cost.
So an over-serialized six-round plan sails through both gates and bills in full.
The fix is a gate at round 1, not a louder rule — a directive nothing calls does not fire.

**Preflight, before the first expensive launch.**
Any workflow likely to repeat substantial work — review/fix convergence, mutation batteries, repeated verification, multi-agent panels, large test matrices, long scans, chained agent sessions — gets its cost assessed against its risk FIRST, in writing:
what is actually on the critical path; which work is independent and runs in parallel; what can be batched; which checks are duplicated or re-prove a guarantee established elsewhere; which changed surfaces actually invalidate prior verification; whether a scoped review replaces a full one; whether a test-only change really needs the production correctness panel again; whether "safe to ship" can be separated from "all hardening done"; whether the stop is BOUNDED; what happens if the external reviewer is down; whether each commit buys real rollback value; and whether a cheaper order preserves the same guarantees.
Then consult Codex on the PLAN — lightweight, one call, before committing to the loop — asking specifically which checks are necessary, which are redundant, what can run in parallel, and what evidence would be sufficient to ship safely.
That is a planning consultation, not another review loop.
Codex being unavailable never blocks the preflight: do the same analysis yourself, or use another independent reviewer, and record which.

**The mechanism — a step with a script, at the only moment the answer is still free.**
`python3 ~/dotfiles/claude/skills/codex-converge/loop.py preflight --arc DIR` records six answers, and `gate()` now refuses round 1 (rc 6) without one:
`--critical-path`, `--parallel` (independent work that will run concurrently, or why none is), `--batch` (checks batched into one run, or which genuinely need isolation), `--scope` (what is NOT re-reviewed this time, and why it stays valid), `--stop` (the **bounded** stopping condition), `--drivers` (the projected top cost drivers, and the one being cut before execution).
`thin_answer` refuses a filled-in blank (`n/a`, `tbd`, under 12 chars) — a required field that accepts filler is a keystroke, not a gate.
`unbounded_stop` refuses a stop naming no bound: a round ceiling, the census/last-panel that ends a region, or the finding class that may reopen it.
"Repeat until no findings remain" and "until only lows remain" name none, and that is the wording measured to run a region for rounds after it stopped paying ([[convergence-loop-speed-rules]]: 15→10→14→9→7→6 across four rounds of one fold pipeline).
Its stated limit: any stray digit satisfies the bound check, so it makes you WRITE a bound rather than scoring the bound's quality.
`--codex <critique>` or `--codex-unavailable "<why>"` is required — one of the two, never neither: the critique is cheap and catches serialization the author cannot see, and an outage must be RECORDED rather than silently becoming the reason a workflow ran unexamined.

**The grandfather clause is derived, never a list of names.**
`preflight_decision(rnd, has_preflight, paid_jobs)` passes an arc that has already launched review/write jobs: it committed to its process before this gate existed, so refusing it wedges live work and saves nothing.
Verified against the real thing before shipping rather than asserted — live seat `0d22215b`'s ledger was an arc entirely in round 1 with 14 review events, and a naive round-1 gate would have wedged it.
Only review/write jobs count, so a brand-new arc cannot buy its way past by running one scoped test first.
That is [[an-armed-watcher-holds-its-boot-config]]'s rule about carve-outs: gate on a live predicate over the set, never on a subject that can move.
Being mounted one increment too late by construction is the class in [[enumerate-the-transforms-between-authoring-and-use]] — the trigger did not misfire, it could not fire.

**Defaults, absent stronger evidence or a safety-critical rule.**
Parallelize independent work.
Batch verification where isolation is not required.
Re-review only the surfaces the latest change invalidated.
Distinguish production-behaviour fixes from test/doc/hardening work.
Never hold an otherwise-safe release behind unrelated hardening for ceremonial convergence — [[merge-green-prs-without-asking]].
Prefer a bounded stop to "repeat until no findings" or "until only lows remain"; another round should normally need a new PRODUCTION-RISK finding, not one more low-value observation.
An external reviewer's outage must not silently serialize the workflow unless that reviewer is genuinely required for safety.
Measure the bottleneck rather than guessing it.
If a workflow is projected to be substantially expensive, name the top cost drivers and optimise them BEFORE execution.

**Depth is risk-gated too — mutation testing especially.**
Do not give every review finding its own mutant.
Reserve mutation testing for high-risk logic, subtle regressions, tests whose validity is genuinely uncertain, and any case where an ordinary test could plausibly pass for the WRONG reason — money, gates, thresholds, parsers, lifecycle, migrations.
Straightforward UI changes, field wiring, labels and already-obvious regressions need a targeted test, not exhaustive mutation proof.
This scopes, and does not repeal, [[verification-claims-are-earned-per-item]]: where mutation applies, it is still earned per ITEM and never per round.
Once a battery has exposed a CLASS of stale or false-positive tests, repair the class and sample enough cases for confidence; keep mutating only while the extra mutants keep finding new defects.
A flat kill-rate across a batch is the stop signal, exactly as a flat finding-rate across rounds is — [[codex-parallel-lenses-beat-serial-rounds]].

**At every round boundary, ask expected value — not only "are there findings left".**
What new information could another round realistically discover?
Is that worth the wall-clock and the tokens?
Can the independent checks run in parallel?
Can a narrower targeted review replace the full panel?
Has the code already reached a reasonable shipping threshold?
Optimise for the CHEAPEST evidence that establishes sufficient confidence, never the maximum evidence obtainable; hours of verification for a tiny cut in residual risk is only right when the code is genuinely high-risk.
And when implementation is complete and VERIFICATION has become the dominant cost, say so explicitly and simplify the remaining loop before continuing — noticing that silently is the original defect.

**The escape hatch, which outranks all of the above.**
Never trade away correctness, security, data integrity, deployment safety, or an explicitly required independent check to save time.
Money, migrations, schema, deploy and security paths keep the deep treatment.
The goal is EQUIVALENT safety with less serialization, less duplicated work, less wall-clock and fewer tokens — never less safety.
A speedup that changes what is VERIFIED is not a speedup; name its fail-open first.

**This is not only a codex-converge rule, and one thing is never a batching candidate.**
The gate is mechanical inside an attributed arc; the QUESTION is owed by any workflow that will repeat work — mutation batteries, repeated verification, multi-agent panels, large test matrices, long scans, a chain of sequential seats.
Outside an arc no launcher will refuse you, so ask the questions in writing anyway and say what you cut.
And author/reviewer independence is the whole thing the loop buys, so it is never batched away — [[codex-may-implement-never-self-review]].

Related: [[optimize-the-loop-unprompted]] (the round-boundary half, and why a rule needs a caller), [[convergence-loop-speed-rules]], [[a-surviving-mutant-may-mean-the-property-is-unobservable]], [[document-rounds-end-when-findings-turn-code-shaped]], [[standing-directives-are-standing-requests]], [[reduce-token-burn]], [[no-extra-cash-without-permission]].
