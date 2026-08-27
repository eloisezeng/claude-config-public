---
name: a-revival-wave-must-read-detail-before-nudging
description: A nudge wave wakes a session regardless of state.json, so `failed` is two facts — cap-killed (revivable) vs retired-by-decision (never) — and the distinguishing evidence sits in `detail`
metadata:
  type: feedback
scope: global
---

**`failed` is not one fact, it is two**, and a revival pass that cannot tell them apart manufactures
exactly the hazard the retirement was written to prevent:

1. **killed by a cap / crash / turn-1 safeguard** → revivable.
2. **retired by a decision** (a sibling marked it `failed` so it could not come back as a second
   holder of a one-seat job) → **never** revivable.

The distinguishing evidence is **already written in the `detail` field** by whoever retired it. So the
rule is: **read `detail` BEFORE nudging or re-dispatching, and if it names a retiring actor or a
reason, do not revive — surface it instead.** Preserve the prior `detail` rather than overwriting it;
it is the only record that the retirement was intentional, and a revival that overwrites it destroys
the evidence on the way past.

**`detail` is only trustworthy in the NEGATIVE direction.** An *explanatory* `detail` plus flat tokens
plus a flat transcript means dead-on-arrival, and a `detail` naming a retiring actor means hands off.
A `detail` that merely echoes the dispatch prompt means **nothing** — it is stale text on a healthy
session, and `state` is stale the same way (a 32-job rate-limit wave cleared with neither field ever
rewritten). So `detail` can veto a revival; it can never authorise one. Liveness is settled only by
post-lift turn count / transcript age.

**Why marking it `failed` is not protection: `failed` stops only the DAEMON.** A `SendMessage` wave
wakes a session regardless of what `state.json` says — the message lands in its transcript and it
takes a turn. So the kill recipe (`state=failed` first, then kill the pid —
`[[kill-bg-claude-sessions-via-job-state]]`) defends against auto-revival and against nothing else.
A revived seat resumes with its **original dispatch instructions still live**, which is the real
damage: on 2026-08-22 a seat retired at 02:27Z specifically to stop a second writer on
`feat/shelf-scheme-flip` was woken by a reachability-keyed nudge at 03:15:07Z carrying *"when the gate
opens, rebase and merge"* — for a seat that had settled two-sided to a different holder while it was
down. Fourth writer on a one-seat job. It cost nothing only because the peer re-read the artifact and
stood down on its own, which is a well-behaved peer, not a design.

Two corollaries:

- **A revived session's first act must be re-reading the artifact**, never acting on the instructions
  it woke up holding — they are as stale as the `detail` field.
- **Attribute a revival by ORDERING, not by re-reading state** —
  `[[re-read-cannot-tell-wrong-from-acted-on]]`. A seat that stayed dead for 3.5 minutes *after* the
  cap lifted and then took its first turn 15 s after a message arrived was woken by the message, not
  the lift. That is checkable from two transcripts and settles authorship of the mistake.

Keep **dropped-the-seat** and **dead-the-session** strictly separate: the artifact settles who holds
the seat, a transcript-age sample settles who is breathing, and neither answers the other. Reading a
two-sided seat drop as a death nearly retired three working sessions in the same episode.

**Dedup by the SEAT the handoff document defines, never by worktree or branch.** A runbook may split
one branch across several seats ON PURPOSE, each with an explicit "you do NOT hold" list (measured
2026-08-22: `HANDOFF-mr34-dispatch.md` splits PR #304 into review-loop / colour-build / CI-merge).
"One live seat per runbook" keyed on the worktree would have collapsed a deliberate split and
destroyed the boundary that keeps a review loop from grading its own colour change. Read the
document's own seat definition before deciding what is a duplicate.

**Stopped is not one fact either.** A `blocked` seat's `detail` distinguishes a *session* limit with a
stated reset time (clock — revivable once it passes), a *weekly* limit (days out), and an *individual
spend* limit (a ceiling, not a clock — no reset clears it). A revival dispatches a NEW session on the
CURRENT account, so the old text explains why a seat stopped, never whether a successor may run.
