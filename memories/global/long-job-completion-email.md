---
name: long-job-completion-email
description: "Turn on the scheduler's completion mail (END and FAIL) for every batch job expected to run ≥ 1 h, so the job pings you instead of you polling it"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When authoring any new batch submission — or retro-modifying one already queued — that is expected to run an hour or more, turn on the scheduler's completion mail for the END and FAIL events.
Most batch schedulers expose this two ways: a directive block at the top of the submission script, and a command that sets the same fields on a job that is already queued or running.
Both take a mail address and a mail-type list; set the type to end-and-failure rather than all-events, or the queue itself becomes the noise.

**Why:** a multi-hour job finishes while you are doing something else, and the only alternative to a push notification is polling.
Polling is worst exactly where it is most tempting: when the poller is a model, every look costs money and returns "not yet" nearly every time — see [[no-extra-cash-without-permission]].
Mail costs nothing and arrives on the state change rather than on a timer.

**How to apply:**

- Default-on for any submission whose requested wall time is ≥ 1 h.
- Skip it only for smoke tests, or when the person you are working for says "no email" for that job.
- For work that is already running, set the fields on the live job rather than resubmitting.
- Pair it with a harvest command written down next to the artifact path, so the mail is actionable on its own ([[handoff-at-boundaries-saves-tokens]]).
