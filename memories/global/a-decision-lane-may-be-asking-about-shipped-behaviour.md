---
name: a-decision-lane-may-be-asking-about-shipped-behaviour
description: Before building either branch of a lane blocked on a product decision, measure the chosen option against the running code — one of the two options is often already the live behaviour, and the lane only ever recorded the question
metadata:
  type: feedback
  scope: global
---

A lane that parks on "should X happen, or Y?" records a QUESTION, and a question carries no claim
about which answer the code already implements. So when the answer arrives, the first move is not to
implement it — it is to measure the chosen option against the running code, link by link, because
the lane was written by whoever noticed the ambiguity rather than by whoever would have had to
measure it.

**Why:** the two options are rarely symmetric. One of them is usually the current behaviour, with the
real gap sitting in some third place the lane never named — reporting, or coverage over a subset of
cases. Implementing the chosen option then either duplicates what ships or, worse, ships a second
mechanism beside the first. Measured 2026-10-28 on `your-other-project`: a lane had blocked a four-step
arc's `done-check` for two days asking whether approved work whose deadline lapses should run late or
expire and be re-proposed. The user chose expire-and-re-propose, and all three links of it were already
in production — the claim refuses a lapsed deadline, `expireStale` terminalises the row, and a
per-tick wake re-files the ask, which had fired 961 times. The honest deliverable was a verification
and a documentation correction, not a feature. The real residue was a coverage fact nobody had
asked about: the re-propose wake covered only the two card types that had since stopped expiring.

**How to apply:** take the decision, then (1) name each link the chosen behaviour needs and find it or
fail to find it in the code, never inferring one link from another's comment; (2) measure the feared
outcome's live RATE, with a control proving the probe could see a positive — a zero from a probe that
cannot see presence is worth nothing (`[[absence-needs-a-probe-that-could-see-presence]]`); (3) if
the behaviour already ships, say so plainly and correct whatever document still presents the question
as open, since a converged-looking spec is what the next session will read as fact; (4) file the
residue you found instead of folding it into the closing lane, so a further decision stays visible as
a decision. The adjacent rule one level down is
`[[a-blocked-write-may-be-a-no-op]]`, and the measurement discipline is
`[[verify-claims-against-artifacts]]`.
